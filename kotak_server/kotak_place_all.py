#!/usr/bin/env python3
"""
Kotak Neo — unified order CLI (no SDK)

Subcommands:
  order    — Single REST order: MKT, L, SL, SL-M with MIS / NRML / CNC / CO / native BO attempt
  bracket  — Synthetic bracket: MIS limit entry + poll fill + SL-M + target limit legs
            (use when native BO is rejected or needs a valid scrip token / still returns body invalid)

  Native BO: --scrip-token = pSymbol from scrip master; jData field lat must be the literal "LTP" (not a
  price). --ltp is ignored for BO placement. With tlt=N, tsv must be "0".

Credentials: b.txt (KOTAK_CONSUMER_KEY, KOTAK_MOBILE_NUMBER, KOTAK_UCC, KOTAK_MPIN,
                     KOTAK_TOTP_SECRET, optional KOTAK_NEO_FIN_KEY)

Examples (symbol: NIFTY26MAR22950CE):
  python kotak_place_all.py order --segment nse_fo --symbol NIFTY26MAR22950CE --tt B \\
      --product MIS --order MKT --qty 65 --yes

  python kotak_place_all.py order --segment nse_fo --symbol NIFTY26MAR22950CE \\
      --tt S --product MIS --order L --price 150 --qty 65 --yes

  python kotak_place_all.py order --segment nse_fo --symbol NIFTY26MAR22950CE --tt S \\
      --product MIS --order SL-M --qty 65 --trigger 150 --yes

  python kotak_place_all.py bracket --segment nse_fo --symbol NIFTY26MAR22950CE \\
      --tt B --price 150 --qty 65 --target 10 --stoploss 5 \\
      --skip-market-hours-check --yes
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import time
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

import pandas as pd
import pyotp
import pytz
import requests

try:
    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
except NameError:
    SCRIPT_DIR = os.path.dirname(os.path.abspath(sys.argv[0]))

# ─── API ──────────────────────────────────────────────────────────────────────
BASE_URL = "https://mis.kotaksecurities.com"
TOTP_LOGIN_ENDPOINT = "login/1.0/tradeApiLogin"
TOTP_VALIDATE_ENDPOINT = "login/1.0/tradeApiValidate"
PLACE_ORDER_ENDPOINT = "quick/order/rule/ms/place"
ORDER_BOOK_ENDPOINT = "quick/user/orders"
DEFAULT_NEO_FIN_KEY = "neotradeapi"

EXCHANGE_SEGMENT_MAP = {
    "nse_cm": "nse_cm", "NSE": "nse_cm", "nse": "nse_cm",
    "BSE": "bse_cm", "bse": "bse_cm", "bse_cm": "bse_cm",
    "NFO": "nse_fo", "nse_fo": "nse_fo", "nfo": "nse_fo",
    "BFO": "bse_fo", "bse_fo": "bse_fo", "bfo": "bse_fo",
    "CDS": "cde_fo", "cde_fo": "cde_fo", "cds": "cde_fo",
    "BCD": "bcs-fo", "bcs-fo": "bcs-fo", "bcd": "bcs-fo",
    "MCX": "mcx", "mcx": "mcx", "mcx_fo": "mcx",
}

PRODUCT_MAP = {
    "Normal": "NRML", "NRML": "NRML", "CNC": "CNC", "cnc": "CNC",
    "MIS": "MIS", "mis": "MIS", "INTRADAY": "INTRADAY", "intraday": "INTRADAY",
    "CO": "CO", "co": "CO", "Cover Order": "CO",
    "BO": "BO", "bo": "BO", "Bracket Order": "BO",
}

ORDER_TYPE_MAP = {
    "Limit": "L", "L": "L", "l": "L",
    "MKT": "MKT", "mkt": "MKT", "Market": "MKT",
    "SL": "SL", "sl": "SL", "Stop loss limit": "SL",
    "SL-M": "SL-M", "sl-m": "SL-M", "Stop loss market": "SL-M",
    "Spread": "SP", "SP": "SP", "2L": "2L", "3L": "3L",
}


def is_market_hours() -> Tuple[bool, str]:
    ist = pytz.timezone("Asia/Kolkata")
    now = datetime.now(ist)
    if now.weekday() >= 5:
        return False, f"Market is closed. Today is {now.strftime('%A')}."
    t = now.time()
    if t < datetime.strptime("09:15", "%H:%M").time():
        return False, f"Market opens at 9:15 AM IST. Current: {now.strftime('%I:%M %p %Z')}"
    if t > datetime.strptime("15:30", "%H:%M").time():
        return False, f"Market closed at 3:30 PM IST. Current: {now.strftime('%I:%M %p %Z')}"
    return True, f"Market is open. Current: {now.strftime('%I:%M %p %Z')}"


def load_credentials(path: str = "b.txt") -> Dict[str, str]:
    search: List[str] = []
    if os.path.isabs(path):
        search.append(path)
    else:
        search.append(os.path.join(SCRIPT_DIR, path))
        search.append(os.path.join(os.path.dirname(SCRIPT_DIR), path))
        search.append(os.path.abspath(path))
    creds_path = next((p for p in search if os.path.exists(p)), None)
    if not creds_path:
        raise FileNotFoundError(f"Credentials not found. Tried: {', '.join(search)}")
    creds: Dict[str, str] = {}
    with open(creds_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                creds[k.strip()] = v.strip().strip('"').strip("'")
    return creds


def _find_scrip_master(segment: str) -> Optional[str]:
    repo_scrip = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", "scrip_masters"))
    for base in (
        os.path.join(SCRIPT_DIR, "scrip_masters"),
        os.path.join(os.path.dirname(SCRIPT_DIR), "scrip_masters"),
        repo_scrip,
    ):
        if not os.path.exists(base):
            continue
        today_file = os.path.join(base, f"{segment}_scrip_master_{datetime.now().strftime('%Y%m%d')}.csv")
        if os.path.exists(today_file):
            return today_file
        files = sorted(
            glob.glob(os.path.join(base, f"{segment}_scrip_master_*.csv")),
            key=os.path.getmtime,
            reverse=True,
        )
        if files:
            return files[0]
    return None


def resolve_trading_symbol(symbol: str, segment: str = "nse_fo") -> str:
    csv_path = _find_scrip_master(segment)
    if not csv_path:
        return symbol
    try:
        df = pd.read_csv(csv_path)
        if "pScripRefKey" in df.columns and "pTrdSymbol" in df.columns:
            m = df[df["pScripRefKey"].astype(str).str.strip() == symbol.strip()]
            if not m.empty:
                ts = m.iloc[0]["pTrdSymbol"]
                if pd.notna(ts) and str(ts).strip():
                    return str(ts).strip()
        if symbol.isdigit() and "pSymbol" in df.columns and "pTrdSymbol" in df.columns:
            m = df[df["pSymbol"].astype(str).str.strip() == symbol.strip()]
            if not m.empty:
                ts = m.iloc[0]["pTrdSymbol"]
                if pd.notna(ts) and str(ts).strip():
                    return str(ts).strip()
    except Exception:
        pass
    return symbol


def get_scrip_token(symbol: str, segment: str = "nse_fo") -> Optional[str]:
    csv_path = _find_scrip_master(segment)
    if not csv_path:
        return None
    try:
        df = pd.read_csv(csv_path)
        for col in ("pScripRefKey", "pTrdSymbol"):
            if col in df.columns and "pSymbol" in df.columns:
                m = df[df[col].astype(str).str.strip() == symbol.strip()]
                if not m.empty:
                    tok = m.iloc[0]["pSymbol"]
                    if pd.notna(tok):
                        return str(tok).strip()
    except Exception:
        pass
    return None


def _fmt(val: Any) -> str:
    if val is None:
        return "0"
    try:
        return "{:.2f}".format(float(val))
    except (ValueError, TypeError):
        return str(val)


def totp_login(
    consumer_key: str, neo_fin_key: str, mobile: str, ucc: str, totp: str
) -> Tuple[str, str, str]:
    url = f"{BASE_URL}/{TOTP_LOGIN_ENDPOINT}"
    r = requests.post(
        url,
        headers={
            "Authorization": consumer_key,
            "neo-fin-key": neo_fin_key,
            "Content-Type": "application/json",
        },
        json={"mobileNumber": mobile, "ucc": ucc, "totp": totp},
        timeout=30,
    )
    r.raise_for_status()
    data = r.json()
    if data.get("data", {}).get("status") != "success":
        raise RuntimeError(f"TOTP login failed: {data}")
    d = data["data"]
    view_token, sid = d.get("token"), d.get("sid")
    if not view_token or not sid:
        raise RuntimeError(f"Missing token/sid: {data}")
    return view_token, sid, d.get("hsServerId", "")


def totp_validate(
    consumer_key: str, neo_fin_key: str, sid: str, view_token: str, mpin: str
) -> Tuple[str, str, str, str]:
    url = f"{BASE_URL}/{TOTP_VALIDATE_ENDPOINT}"
    r = requests.post(
        url,
        headers={
            "Authorization": consumer_key,
            "sid": sid,
            "Auth": view_token,
            "neo-fin-key": neo_fin_key,
        },
        json={"mpin": mpin},
        timeout=30,
    )
    r.raise_for_status()
    data = r.json()
    if data.get("data", {}).get("status") != "success":
        raise RuntimeError(f"TOTP validate failed: {data}")
    d = data["data"]
    edit_token, edit_sid, base_url = d.get("token"), d.get("sid"), d.get("baseUrl")
    if not edit_token or not edit_sid or not base_url:
        raise RuntimeError(f"Missing fields in validate response: {data}")
    return edit_token, edit_sid, d.get("hsServerId", ""), base_url


def authenticate() -> Tuple[str, str, str, str, str, str]:
    creds = load_credentials()
    consumer_key = creds["KOTAK_CONSUMER_KEY"]
    mobile = creds["KOTAK_MOBILE_NUMBER"]
    ucc = creds["KOTAK_UCC"]
    mpin = creds["KOTAK_MPIN"]
    totp_secret = creds["KOTAK_TOTP_SECRET"]
    neo_fin_key = creds.get("KOTAK_NEO_FIN_KEY", DEFAULT_NEO_FIN_KEY)
    if not all([consumer_key, mobile, ucc, mpin, totp_secret]):
        raise ValueError("Missing required keys in b.txt")
    if mobile.isdigit() and len(mobile) == 10 and not mobile.startswith("+"):
        mobile = "+91" + mobile
    totp_code = pyotp.TOTP(totp_secret).now()
    print("Step 1: TOTP Login...")
    view_token, sid, login_hs = totp_login(consumer_key, neo_fin_key, mobile, ucc, totp_code)
    print("[OK] Login OK")
    print("Step 2: TOTP Validate...")
    edit_token, edit_sid, validate_hs, base_url = totp_validate(
        consumer_key, neo_fin_key, sid, view_token, mpin
    )
    print(f"[OK] Validate OK | baseUrl={base_url}")
    server_id = validate_hs or login_hs
    return edit_token, edit_sid, server_id, base_url, consumer_key, neo_fin_key


# ═══════════════════════════════════════════════════════════════════════════════
# Single order
# ═══════════════════════════════════════════════════════════════════════════════


def place_single_order(
    base_url: str,
    edit_token: str,
    edit_sid: str,
    server_id: str,
    *,
    segment: str,
    symbol: str,
    tt: str,
    product: str,
    order: str,
    qty: int,
    price: Optional[float],
    tag: Optional[str],
    neo_fin_key: Optional[str],
    scrip_token: Optional[str] = None,
    target_value: Optional[str] = None,
    target_type: Optional[str] = None,
    stop_loss_value: Optional[str] = None,
    stop_loss_type: Optional[str] = None,
    ltp: Optional[str] = None,
    trigger: Optional[float] = None,
) -> Dict[str, Any]:
    exchange_segment = EXCHANGE_SEGMENT_MAP.get(segment, segment)
    product_mapped = PRODUCT_MAP.get(product, product)
    order_type = ORDER_TYPE_MAP.get(order, order)
    quantity = str(qty)
    limit_price = _fmt(price) if price is not None else "0"

    if order_type.upper() == "L" and price is None:
        raise ValueError("Limit order requires --price")

    otu = order_type.upper()
    if otu in ("SL", "SL-M") and trigger is None:
        raise ValueError("SL and SL-M require --trigger (trigger price)")
    if otu == "SL" and price is None:
        raise ValueError("SL (stop-loss limit) requires --price (limit price)")

    tp_field = _fmt(trigger) if trigger is not None else "0"
    if otu == "SL-M":
        limit_price = "0"

    if product_mapped == "BO":
        if not target_value or not stop_loss_value:
            raise ValueError("Native BO requires --target-value and --stop-loss-value")
        if not scrip_token:
            raise ValueError("Native BO requires --scrip-token")
        if target_type and target_type not in ("Absolute", "Ticks"):
            raise ValueError("--target-type must be Absolute or Ticks")
        if stop_loss_type and stop_loss_type not in ("Absolute", "Ticks"):
            raise ValueError("--stop-loss-type must be Absolute or Ticks")

    url = f"{base_url}/{PLACE_ORDER_ENDPOINT}"
    nfk = neo_fin_key or DEFAULT_NEO_FIN_KEY
    headers = {
        "Sid": edit_sid,
        "Auth": edit_token,
        "neo-fin-key": nfk,
        "accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
    }
    params = {"sId": server_id} if server_id else {}

    order_data: Dict[str, str] = {
        "am": "NO",
        "dq": "0",
        "es": exchange_segment,
        "mp": "0",
        "pc": product_mapped,
        "pf": "N",
        "pr": limit_price,
        "pt": order_type,
        "qt": quantity,
        "rt": "DAY",
        "tp": tp_field,
        "ts": symbol,
        "tt": tt,
        "ig": tag or "KOTAK_PLACE_ALL",
        "os": "NEOTRADEAPI",
    }

    if product_mapped == "BO":
        order_data["tk"] = str(scrip_token)
        if target_value is not None:
            order_data["sov"] = str(target_value)
        if target_type is not None:
            order_data["sot"] = str(target_type)
        if stop_loss_value is not None:
            order_data["slv"] = str(stop_loss_value)
        if stop_loss_type is not None:
            order_data["slt"] = str(stop_loss_type)
        # Official Place Order doc: lat is the static token "LTP", not a numeric last price.
        order_data["lat"] = "LTP"
        order_data["tlt"] = "N"
        # When tlt is N, docs require tsv "0" (not "N").
        order_data["tsv"] = "0"

    jdata_json = json.dumps(order_data)
    print(f"jData: {jdata_json}")

    r = requests.post(url, headers=headers, params=params, data={"jData": jdata_json}, timeout=30)
    try:
        r.raise_for_status()
    except requests.exceptions.HTTPError as e:
        err = str(e)
        try:
            err += f"\nAPI: {json.dumps(r.json(), indent=2)}"
        except Exception:
            err += f"\nAPI text: {r.text}"
        raise RuntimeError(err) from e
    return r.json()


# ═══════════════════════════════════════════════════════════════════════════════
# Synthetic bracket
# ═══════════════════════════════════════════════════════════════════════════════


def _place_raw(
    base_url: str,
    edit_token: str,
    edit_sid: str,
    server_id: str,
    jdata: Dict[str, str],
    *,
    neo_fin_key: Optional[str] = None,
    label: str = "Order",
) -> Dict[str, Any]:
    nfk = neo_fin_key or DEFAULT_NEO_FIN_KEY
    url = f"{base_url}/{PLACE_ORDER_ENDPOINT}"
    headers = {
        "Sid": edit_sid,
        "Auth": edit_token,
        "neo-fin-key": nfk,
        "accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
    }
    params = {"sId": server_id} if server_id else {}
    jdata_json = json.dumps(jdata)
    print(f"\n+--- {label} ------------------------------------------------")
    print(f"|  {jdata_json}\n+---------------------------------------------------\n")
    r = requests.post(url, headers=headers, params=params, data={"jData": jdata_json}, timeout=30)
    try:
        r.raise_for_status()
    except requests.exceptions.HTTPError as e:
        err = str(e)
        try:
            err += f"\nAPI: {json.dumps(r.json(), indent=2)}"
        except Exception:
            err += f"\nAPI text: {r.text}"
        raise RuntimeError(f"{label} failed: {err}") from e
    return r.json()


def _get_order_book(
    base_url: str,
    edit_token: str,
    edit_sid: str,
    server_id: str,
    *,
    neo_fin_key: Optional[str] = None,
) -> Any:
    nfk = neo_fin_key or DEFAULT_NEO_FIN_KEY
    url = f"{base_url}/{ORDER_BOOK_ENDPOINT}"
    headers = {
        "Sid": edit_sid,
        "Auth": edit_token,
        "neo-fin-key": nfk,
        "accept": "application/json",
    }
    params = {"sId": server_id} if server_id else {}
    r = requests.get(url, headers=headers, params=params, timeout=30)
    r.raise_for_status()
    return r.json()


def _entry_fully_filled(st: str, fqty: str, qty: int) -> bool:
    try:
        fq = int(float(str(fqty).strip() or "0"))
        qn = int(qty)
    except (ValueError, TypeError):
        return False
    if qn > 0 and fq >= qn:
        return True
    if not st:
        return False
    return st in ("COMPLETE", "COMPLETED", "TRADED", "FILLED", "EXECUTED", "OK")


def _order_status(
    base_url: str,
    edit_token: str,
    edit_sid: str,
    server_id: str,
    order_id: Any,
    *,
    neo_fin_key: Optional[str] = None,
) -> Tuple[Optional[str], str, str, Dict[str, Any]]:
    try:
        book = _get_order_book(base_url, edit_token, edit_sid, server_id, neo_fin_key=neo_fin_key)
        orders = book if isinstance(book, list) else book.get("data", book.get("orders", []))
        for o in orders:
            oid = str(o.get("nOrdNo") or o.get("orderId") or o.get("order_id") or "")
            if oid == str(order_id):
                st = (o.get("ordSt") or o.get("status") or o.get("orderStatus") or "").upper()
                filled_qty = o.get("fldQty") or o.get("filledQty") or o.get("traded_qty") or "0"
                avg_price = o.get("avgPrc") or o.get("averagePrice") or o.get("avg_price") or "0"
                return st, str(filled_qty), str(avg_price), o
    except Exception as e:
        print(f"  [WARN] Order book: {e}")
    return None, "0", "0", {}


def place_synthetic_bo(
    base_url: str,
    edit_token: str,
    edit_sid: str,
    server_id: str,
    *,
    segment: str,
    symbol: str,
    tt: str,
    qty: int,
    price: float,
    target_value: float,
    target_type: str,
    stoploss_value: float,
    stoploss_type: str,
    scrip_token: Optional[str] = None,
    neo_fin_key: Optional[str] = None,
    poll_timeout: int = 60,
    poll_interval: int = 2,
    tag: Optional[str] = None,
) -> Dict[str, Any]:
    exchange_segment = EXCHANGE_SEGMENT_MAP.get(segment, segment)
    now_tag = tag or f"SBO_{datetime.now().strftime('%m%d%H%M%S')}"

    def _to_points(val: float, vtype: str) -> float:
        v = float(val)
        if vtype == "Ticks":
            return round(v * 0.05, 2)
        return round(v, 2)

    tgt_pts = _to_points(target_value, target_type)
    sl_pts = _to_points(stoploss_value, stoploss_type)

    if tt == "B":
        exit_tt = "S"
        tgt_price = round(price + tgt_pts, 2)
        sl_trigger = round(price - sl_pts, 2)
    else:
        exit_tt = "B"
        tgt_price = round(price - tgt_pts, 2)
        sl_trigger = round(price + sl_pts, 2)

    print(f"\n{'='*60}\n  SYNTHETIC BO  {tt} {qty}x {symbol} @ {price}")
    print(f"  Target: {tgt_price}  |  SL trig: {sl_trigger}\n{'='*60}\n")

    entry_jdata: Dict[str, str] = {
        "am": "NO",
        "dq": "0",
        "es": exchange_segment,
        "mp": "0",
        "pc": "MIS",
        "pf": "N",
        "pr": _fmt(price),
        "pt": "L",
        "qt": str(qty),
        "rt": "DAY",
        "tp": "0",
        "ts": symbol,
        "tt": tt,
        "ig": f"ENTRY_{now_tag}",
        "os": "NEOTRADEAPI",
    }
    if scrip_token:
        entry_jdata["tk"] = str(scrip_token)

    entry_resp = _place_raw(
        base_url, edit_token, edit_sid, server_id, entry_jdata,
        neo_fin_key=neo_fin_key, label="ENTRY",
    )
    print(f"[OK] Entry: {json.dumps(entry_resp, indent=2)}")

    data_block = entry_resp.get("data", {})
    order_id = (
        entry_resp.get("nOrdNo")
        or entry_resp.get("orderId")
        or (data_block.get("nOrdNo") if isinstance(data_block, dict) else None)
    )
    if not order_id or str(order_id).lower() in ("none", ""):
        raise RuntimeError(f"No order id in entry response: {entry_resp}")

    print(f"\n[POLL] order_id={order_id} timeout={poll_timeout}s …")
    deadline = time.time() + poll_timeout
    fill_price = price

    while time.time() < deadline:
        st, fqty, avg_px, _raw = _order_status(
            base_url, edit_token, edit_sid, server_id, order_id, neo_fin_key=neo_fin_key
        )
        if st is None:
            print("  [WARN] status not found, retry…")
        else:
            print(f"  Status: {st} | Filled: {fqty}/{qty} | Avg: {avg_px}")
            if _entry_fully_filled(st, fqty, int(qty)):
                try:
                    fill_price = float(avg_px) if float(avg_px) > 0 else price
                except Exception:
                    fill_price = price
                print(f"\n[OK] Entry filled @ {fill_price}")
                break
            if any(x in st for x in ("REJECT", "CANCEL", "ERROR")):
                raise RuntimeError(f"Entry {order_id} -> {st}")
        time.sleep(poll_interval)
    else:
        print(f"\n[WARN] Poll timeout; using limit {price} for legs.")
        fill_price = price

    if tt == "B":
        tgt_price = round(fill_price + tgt_pts, 2)
        sl_trigger = round(fill_price - sl_pts, 2)
    else:
        tgt_price = round(fill_price - tgt_pts, 2)
        sl_trigger = round(fill_price + sl_pts, 2)

    sl_jdata: Dict[str, str] = {
        "am": "NO",
        "dq": "0",
        "es": exchange_segment,
        "mp": "0",
        "pc": "MIS",
        "pf": "N",
        "pr": "0",
        "pt": "SL-M",
        "tp": _fmt(sl_trigger),
        "qt": str(qty),
        "rt": "DAY",
        "ts": symbol,
        "tt": exit_tt,
        "ig": f"SL_{now_tag}",
        "os": "NEOTRADEAPI",
    }
    if scrip_token:
        sl_jdata["tk"] = str(scrip_token)

    tgt_jdata: Dict[str, str] = {
        "am": "NO",
        "dq": "0",
        "es": exchange_segment,
        "mp": "0",
        "pc": "MIS",
        "pf": "N",
        "pr": _fmt(tgt_price),
        "pt": "L",
        "tp": "0",
        "qt": str(qty),
        "rt": "DAY",
        "ts": symbol,
        "tt": exit_tt,
        "ig": f"TGT_{now_tag}",
        "os": "NEOTRADEAPI",
    }
    if scrip_token:
        tgt_jdata["tk"] = str(scrip_token)

    sl_resp = _place_raw(
        base_url, edit_token, edit_sid, server_id, sl_jdata,
        neo_fin_key=neo_fin_key, label="SL LEG",
    )
    tgt_resp = _place_raw(
        base_url, edit_token, edit_sid, server_id, tgt_jdata,
        neo_fin_key=neo_fin_key, label="TARGET LEG",
    )
    print(json.dumps({"sl": sl_resp, "target": tgt_resp}, indent=2))

    return {
        "entry_order_id": order_id,
        "fill_price": fill_price,
        "sl_trigger": sl_trigger,
        "target_price": tgt_price,
        "sl_response": sl_resp,
        "target_response": tgt_resp,
    }


# ═══════════════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════════════


def _check_market_hours(skip: bool) -> None:
    if skip:
        return
    ok, msg = is_market_hours()
    if not ok:
        print(f"[WARN] {msg}\nUse --skip-market-hours-check to override.")
        sys.exit(1)
    print(f"[OK] {msg}")


def _symbol_variants(trading_symbol: str) -> List[str]:
    if ".00" in trading_symbol and trading_symbol[-2:] in ("CE", "PE"):
        return [trading_symbol.replace(".00", ""), trading_symbol]
    return [trading_symbol]


def cmd_order(args: argparse.Namespace) -> None:
    product_mapped = PRODUCT_MAP.get(args.product, args.product)
    if product_mapped == "BO":
        if not args.target_value or not args.stop_loss_value:
            print("Error: native BO needs --target-value and --stop-loss-value")
            sys.exit(1)

    if not args.yes:
        print("DRY-RUN (add --yes to send):")
        preview = {
            "segment": args.segment,
            "symbol": args.symbol,
            "tt": args.tt,
            "product": args.product,
            "order": args.order,
            "qty": args.qty,
            "price": args.price,
            "trigger": args.trigger,
            "tag": args.tag,
        }
        if product_mapped == "BO":
            preview.update(
                {
                    "scrip_token": args.scrip_token,
                    "target_value": args.target_value,
                    "target_type": args.target_type,
                    "stop_loss_value": args.stop_loss_value,
                    "stop_loss_type": args.stop_loss_type,
                    "ltp": args.ltp,
                }
            )
        print(json.dumps(preview, indent=2))
        return

    _check_market_hours(args.skip_market_hours_check)
    edit_token, edit_sid, server_id, base_url, _ck, neo_fin_key = authenticate()
    segment_key = EXCHANGE_SEGMENT_MAP.get(args.segment, args.segment)
    trading_symbol = resolve_trading_symbol(args.symbol, segment_key)
    if trading_symbol != args.symbol:
        print(f"  Resolved: {args.symbol} -> {trading_symbol}")

    scrip_token = args.scrip_token
    if product_mapped == "BO" and not scrip_token:
        scrip_token = get_scrip_token(trading_symbol, segment_key)
        if scrip_token:
            print(f"  scrip token: {scrip_token}")

    tag = args.tag or f"PLACE_ALL_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    variants = _symbol_variants(trading_symbol)
    last_err: Optional[Exception] = None
    for sym in variants:
        try:
            print(f"Placing order symbol={sym} …")
            resp = place_single_order(
                base_url,
                edit_token,
                edit_sid,
                server_id,
                segment=args.segment,
                symbol=sym,
                tt=args.tt,
                product=args.product,
                order=args.order,
                qty=args.qty,
                price=args.price,
                tag=tag,
                neo_fin_key=neo_fin_key,
                scrip_token=scrip_token if product_mapped == "BO" else args.scrip_token,
                target_value=args.target_value,
                target_type=args.target_type,
                stop_loss_value=args.stop_loss_value,
                stop_loss_type=args.stop_loss_type,
                ltp=args.ltp,
                trigger=args.trigger,
            )
            print(json.dumps(resp, indent=2))
            return
        except Exception as e:
            last_err = e
            if sym != variants[-1]:
                print(f"  retry next symbol variant… ({e})")
    if last_err:
        raise last_err


def cmd_bracket(args: argparse.Namespace) -> None:
    segment_key = EXCHANGE_SEGMENT_MAP.get(args.segment, args.segment)
    trading_symbol = resolve_trading_symbol(args.symbol, segment_key)
    if trading_symbol != args.symbol:
        print(f"  Resolved: {args.symbol} -> {trading_symbol}")

    scrip_token = args.scrip_token or get_scrip_token(trading_symbol, segment_key)
    if scrip_token:
        print(f"  scrip token: {scrip_token}")
    else:
        print("  [WARN] No scrip token; add --scrip-token if API requires tk")

    if not args.yes:
        print("DRY-RUN synthetic bracket (add --yes):")
        print(
            json.dumps(
                {
                    "segment": args.segment,
                    "symbol": trading_symbol,
                    "tt": args.tt,
                    "price": args.price,
                    "qty": args.qty,
                    "target": args.target,
                    "stoploss": args.stoploss,
                    "scrip_token": scrip_token,
                },
                indent=2,
            )
        )
        return

    _check_market_hours(args.skip_market_hours_check)
    edit_token, edit_sid, server_id, base_url, _ck, neo_fin_key = authenticate()
    bvariants = _symbol_variants(trading_symbol)
    last_err: Optional[Exception] = None
    for sym in bvariants:
        try:
            out = place_synthetic_bo(
                base_url,
                edit_token,
                edit_sid,
                server_id,
                segment=args.segment,
                symbol=sym,
                tt=args.tt,
                qty=args.qty,
                price=args.price,
                target_value=args.target,
                target_type=args.target_type,
                stoploss_value=args.stoploss,
                stoploss_type=args.stoploss_type,
                scrip_token=scrip_token,
                neo_fin_key=neo_fin_key,
                poll_timeout=args.poll_timeout,
                poll_interval=args.poll_interval,
                tag=args.tag,
            )
            print("\n[DONE]", json.dumps(out, indent=2))
            return
        except Exception as e:
            last_err = e
            if sym != bvariants[-1]:
                print(f"  retry variant… ({e})")
    if last_err:
        raise last_err


def build_parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(
        description="Kotak Neo unified place-order CLI (no SDK)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = root.add_subparsers(dest="cmd", required=True)

    po = sub.add_parser("order", help="Single order (MKT, L, SL, SL-M, MIS/NRML/CNC/CO/BO)")
    po.add_argument("--segment", required=True)
    po.add_argument("--symbol", required=True)
    po.add_argument("--tt", required=True, choices=["B", "S"])
    po.add_argument("--product", default="MIS")
    po.add_argument("--order", required=True, choices=["L", "MKT", "SL", "SL-M"])
    po.add_argument("--qty", type=int, required=True)
    po.add_argument("--price", type=float, help="Limit price (required for L, SL)")
    po.add_argument("--trigger", type=float, help="Trigger price (required for SL, SL-M)")
    po.add_argument("--tag", default=None)
    po.add_argument("--scrip-token", default=None)
    po.add_argument("--target-value", default=None)
    po.add_argument("--target-type", choices=["Absolute", "Ticks"], default="Absolute")
    po.add_argument("--stop-loss-value", default=None)
    po.add_argument("--stop-loss-type", choices=["Absolute", "Ticks"], default="Absolute")
    po.add_argument(
        "--ltp",
        default=None,
        help="Ignored for native BO (API uses lat=LTP). Optional for other future use.",
    )
    po.add_argument("--yes", action="store_true")
    po.add_argument("--skip-market-hours-check", action="store_true")

    pb = sub.add_parser("bracket", aliases=["sbo"], help="Synthetic bracket (MIS + SL-M + target)")
    pb.add_argument("--segment", required=True)
    pb.add_argument("--symbol", required=True)
    pb.add_argument("--tt", required=True, choices=["B", "S"])
    pb.add_argument("--price", type=float, required=True)
    pb.add_argument("--qty", type=int, required=True)
    pb.add_argument("--target", type=float, required=True)
    pb.add_argument("--stoploss", type=float, required=True)
    pb.add_argument("--target-type", choices=["Absolute", "Ticks"], default="Absolute")
    pb.add_argument("--stoploss-type", choices=["Absolute", "Ticks"], default="Absolute")
    pb.add_argument("--scrip-token", default=None)
    pb.add_argument("--poll-timeout", type=int, default=60)
    pb.add_argument("--poll-interval", type=int, default=2)
    pb.add_argument("--tag", default=None)
    pb.add_argument("--yes", action="store_true")
    pb.add_argument("--skip-market-hours-check", action="store_true")

    return root


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.cmd == "order":
            cmd_order(args)
        elif args.cmd in ("bracket", "sbo"):
            cmd_bracket(args)
        else:
            parser.print_help()
            sys.exit(2)
    except SystemExit:
        raise
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        import traceback

        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
