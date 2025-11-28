#!/usr/bin/env python3
"""
Direct REST client to view Kotak Neo positions (no SDK required).

Steps performed:
1. Read credentials (consumer key, mobile, mpin, ucc, optional TOTP secret) from b.txt
2. Perform TOTP login + MPIN validation via the public REST endpoints
3. Fetch positions using the same REST session tokens and display them as a table or raw JSON
"""

import argparse
import json
import sys
from datetime import datetime
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple, Union

import requests
import pyotp


BASE_URL = "https://mis.kotaksecurities.com"
TOTP_LOGIN_ENDPOINT = "login/1.0/tradeApiLogin"
TOTP_VALIDATE_ENDPOINT = "login/1.0/tradeApiValidate"
POSITIONS_ENDPOINT = "quick/user/positions"
DEFAULT_NEO_FIN_KEY = "neotradeapi"


def load_credentials(path: str = "b.txt") -> Dict[str, str]:
    """Read key=value pairs from the credentials file."""
    creds: Dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            creds[key.strip()] = value.strip().strip('"').strip("'")
    return creds


def generate_totp_code(secret: str) -> str:
    """Return a 6-digit TOTP code from the provided secret."""
    clean_secret = secret.replace(" ", "")
    return pyotp.TOTP(clean_secret).now()


def format_mobile_number(mobile: str) -> str:
    """Return a Kotak-compatible mobile number (prefers +91XXXXXXXXXX)."""
    mobile = mobile.strip()
    if mobile.startswith("+"):
        return mobile
    digits = "".join(ch for ch in mobile if ch.isdigit())
    if len(digits) == 10:
        return "+91" + digits
    return mobile


def totp_login(consumer_key: str, neo_fin_key: str, mobile: str, ucc: str, totp_code: str):
    """Step 1: TOTP login (view token + SID)."""
    url = f"{BASE_URL}/{TOTP_LOGIN_ENDPOINT}"
    headers = {
        "Authorization": consumer_key,
        "neo-fin-key": neo_fin_key,
        "Content-Type": "application/json",
    }
    payload = {
        "mobileNumber": mobile,
        "ucc": ucc,
        "totp": totp_code,
    }
    response = requests.post(url, headers=headers, json=payload, timeout=30)
    response.raise_for_status()
    data = response.json()
    status = data.get("data", {}).get("status")
    if status != "success":
        raise RuntimeError(f"TOTP login failed: {json.dumps(data, indent=2)}")

    view_token = data.get("data", {}).get("token")
    sid = data.get("data", {}).get("sid")
    server_id = data.get("data", {}).get("hsServerId") or ""
    if not view_token or not sid:
        raise RuntimeError(f"Missing token/sid in login response: {json.dumps(data, indent=2)}")
    return view_token, sid, server_id, data


def totp_validate(consumer_key: str, neo_fin_key: str, sid: str, view_token: str, mpin: str):
    """Step 2: Validate MPIN to get edit token and base URL."""
    url = f"{BASE_URL}/{TOTP_VALIDATE_ENDPOINT}"
    headers = {
        "Authorization": consumer_key,
        "sid": sid,
        "Auth": view_token,
        "neo-fin-key": neo_fin_key,
        "Content-Type": "application/json",
    }
    payload = {"mpin": mpin}
    response = requests.post(url, headers=headers, json=payload, timeout=30)
    response.raise_for_status()
    data = response.json()
    status = data.get("data", {}).get("status")
    if status != "success":
        raise RuntimeError(f"TOTP validate failed: {json.dumps(data, indent=2)}")

    edit_token = data.get("data", {}).get("token")
    edit_sid = data.get("data", {}).get("sid")
    base_url = data.get("data", {}).get("baseUrl") or BASE_URL
    server_id = data.get("data", {}).get("hsServerId") or ""
    if not edit_token or not edit_sid:
        raise RuntimeError(f"Missing edit token/sid in validate response: {json.dumps(data, indent=2)}")
    return edit_token, edit_sid, server_id, base_url.rstrip("/"), data


def establish_session(creds: Dict[str, str], *, totp_override: Optional[str] = None) -> Dict[str, Any]:
    """Run the direct login flow and return tokens/base URL."""
    consumer_key = creds.get("KOTAK_CONSUMER_KEY")
    mobile = creds.get("KOTAK_MOBILE_NUMBER")
    ucc = creds.get("KOTAK_UCC")
    mpin = creds.get("KOTAK_MPIN")
    totp_secret = creds.get("KOTAK_TOTP_SECRET")
    neo_fin_key = creds.get("KOTAK_NEO_FIN_KEY", DEFAULT_NEO_FIN_KEY)

    missing = [k for k, v in {
        "KOTAK_CONSUMER_KEY": consumer_key,
        "KOTAK_MOBILE_NUMBER": mobile,
        "KOTAK_UCC": ucc,
        "KOTAK_MPIN": mpin,
    }.items() if not v]
    if missing:
        raise RuntimeError(f"Missing credentials: {', '.join(missing)}")

    totp_code = totp_override or (
        generate_totp_code(totp_secret) if totp_secret else None
    )
    if not totp_code:
        raise RuntimeError(
            "No TOTP secret found in b.txt and no --totp override was provided."
        )

    formatted_mobile = format_mobile_number(mobile)

    view_token, sid, login_server_id, login_payload = totp_login(
        consumer_key, neo_fin_key, formatted_mobile, ucc, totp_code
    )
    edit_token, edit_sid, validate_server_id, base_url, validate_payload = totp_validate(
        consumer_key, neo_fin_key, sid, view_token, mpin
    )

    server_id = validate_server_id or login_server_id or ""
    return {
        "base_url": base_url,
        "edit_token": edit_token,
        "edit_sid": edit_sid,
        "server_id": server_id,
        "login_payload": login_payload,
        "validate_payload": validate_payload,
    }


def fetch_positions(base_url: str, edit_token: str, edit_sid: str, server_id: str) -> Dict[str, Any]:
    """Call the positions endpoint via REST."""
    base_url = base_url.rstrip("/")
    url = f"{base_url}/{POSITIONS_ENDPOINT}"
    headers = {
        "Sid": edit_sid,
        "Auth": edit_token,
        "accept": "application/json",
    }
    params: Dict[str, str] = {}
    if server_id:
        params["sId"] = server_id

    response = requests.get(url, headers=headers, params=params, timeout=30)
    response.raise_for_status()
    return response.json()

def parse_number(value: Any) -> float:
    if value in (None, "", "-"):
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).replace(",", ""))
    except (ValueError, TypeError):
        return 0.0


def format_number(value: float, decimals: int = 2) -> str:
    if abs(value - int(value)) < 1e-9:
        return str(int(value))
    return f"{value:.{decimals}f}"


ColumnAccessor = Union[Sequence[str], Callable[[Dict[str, Any]], str]]
ColumnSpec = Tuple[str, ColumnAccessor]


def derive_symbol(entry: Dict[str, Any]) -> str:
    return entry.get("tradingSymbol") or entry.get("trdSym") or entry.get("symbol") or entry.get("sym") or "-"


def derive_segment(entry: Dict[str, Any]) -> str:
    return entry.get("segment") or entry.get("exchangeSegment") or entry.get("exSeg") or entry.get("exchange") or "-"


def derive_product(entry: Dict[str, Any]) -> str:
    return entry.get("product") or entry.get("productCode") or entry.get("prodType") or entry.get("prod") or "-"


def compute_net_qty(entry: Dict[str, Any]) -> float:
    buy_qty = parse_number(entry.get("netQty") or entry.get("netQuantity") or entry.get("flBuyQty") or entry.get("cfBuyQty"))
    sell_qty = parse_number(entry.get("flSellQty") or entry.get("cfSellQty"))
    net = buy_qty - sell_qty
    # If explicit net quantity exists, prefer that
    if "netQty" in entry or "netQuantity" in entry:
        net = parse_number(entry.get("netQty") or entry.get("netQuantity"))
    return net


def derive_net_qty(entry: Dict[str, Any]) -> str:
    return format_number(compute_net_qty(entry), 0)


def derive_avg_buy(entry: Dict[str, Any]) -> str:
    buy_amt = parse_number(entry.get("buyAmt"))
    qty = parse_number(entry.get("flBuyQty") or entry.get("netQty") or entry.get("netQuantity"))
    if qty:
        return format_number(buy_amt / qty)
    for key in ("buyAvgPrice", "buyAvg", "buyavgprice"):
        if key in entry:
            return format_number(parse_number(entry[key]))
    return "-"


def derive_avg_sell(entry: Dict[str, Any]) -> str:
    sell_amt = parse_number(entry.get("sellAmt"))
    qty = parse_number(entry.get("flSellQty") or entry.get("netQty") or entry.get("netQuantity"))
    if qty:
        return format_number(sell_amt / qty)
    for key in ("sellAvgPrice", "sellAvg", "sellavgprice"):
        if key in entry:
            return format_number(parse_number(entry[key]))
    return "-"


def derive_pnl(entry: Dict[str, Any]) -> str:
    if "pnl" in entry or "pAndL" in entry:
        return format_number(parse_number(entry.get("pnl") or entry.get("pAndL")))
    sell_amt = parse_number(entry.get("sellAmt"))
    buy_amt = parse_number(entry.get("buyAmt"))
    return format_number(sell_amt - buy_amt)


COL_CONFIG: List[ColumnSpec] = [
    ("Symbol", derive_symbol),
    ("Segment", derive_segment),
    ("Product", derive_product),
    ("NetQty", derive_net_qty),
    ("BuyAvg", derive_avg_buy),
    ("SellAvg", derive_avg_sell),
    ("P&L", derive_pnl),
]


def cell_value(entry: Dict[str, Any], accessor: ColumnAccessor) -> str:
    if callable(accessor):
        return accessor(entry)
    for key in accessor:
        if key in entry and entry[key] not in (None, ""):
            value = entry[key]
            if isinstance(value, float):
                return f"{value:.2f}"
            return str(value)
    return "-"


def find_position_list(payload: Any) -> Optional[List[Dict[str, Any]]]:
    """Attempt to locate the position list in an arbitrary response."""
    if isinstance(payload, list):
        return payload
    if not isinstance(payload, dict):
        return None

    for key in ("positions", "positionList", "data", "netPositions", "day", "dayPositions"):
        if key not in payload:
            continue
        value = payload[key]
        if isinstance(value, list):
            return value
        if isinstance(value, dict):
            # Look one level deeper
            for nested in value.values():
                if isinstance(nested, list):
                    return nested
    return None


def render_table(entries: List[Dict[str, Any]]) -> str:
    headers = [title for title, _ in COL_CONFIG]
    rows = [
        [cell_value(entry, accessor) for _, accessor in COL_CONFIG]
        for entry in entries
    ]

    widths = [len(h) for h in headers]
    for row in rows:
        for idx, cell in enumerate(row):
            widths[idx] = max(widths[idx], len(cell))

    def fmt_row(row_values: List[str]) -> str:
        return " | ".join(cell.ljust(widths[idx]) for idx, cell in enumerate(row_values))

    line = "-+-".join("-" * w for w in widths)
    output = [fmt_row(headers), line]
    output.extend(fmt_row(row) for row in rows)
    return "\n".join(output)


def summarize(entries: List[Dict[str, Any]]) -> Dict[str, Any]:
    total_positions = len(entries)
    total_pnl = sum(parse_number(entry.get("pnl") or entry.get("pAndL") or entry.get("sellAmt")) -
                    parse_number(entry.get("buyAmt"))
                    for entry in entries)
    total_qty = sum(compute_net_qty(entry) for entry in entries)

    return {
        "count": total_positions,
        "total_net_qty": round(total_qty, 2),
        "total_pnl": round(total_pnl, 2),
        "generated_at": datetime.now().isoformat(timespec="seconds"),
    }


def main():
    parser = argparse.ArgumentParser(description="Fetch and display Kotak Neo positions")
    parser.add_argument("--creds", default="b.txt", help="Path to credentials file (default: b.txt)")
    parser.add_argument("--totp", help="Override 6-digit TOTP code (if no secret stored)")
    parser.add_argument("--json", action="store_true", help="Print raw JSON response instead of a table")
    parser.add_argument("--debug", action="store_true", help="Print session payloads for troubleshooting")
    args = parser.parse_args()

    try:
        creds = load_credentials(args.creds)
    except FileNotFoundError:
        print(f"Error: credentials file '{args.creds}' not found", file=sys.stderr)
        sys.exit(1)

    try:
        session = establish_session(creds, totp_override=args.totp)
        if args.debug:
            print("Login Payload:")
            print(json.dumps(session["login_payload"], indent=2))
            print("Validate Payload:")
            print(json.dumps(session["validate_payload"], indent=2))

        response = fetch_positions(
            base_url=session["base_url"],
            edit_token=session["edit_token"],
            edit_sid=session["edit_sid"],
            server_id=session["server_id"],
        )
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)

    if args.json:
        print(json.dumps(response, indent=2))
        return

    positions = find_position_list(response) or []
    if not positions:
        print("No positions found (or response format not recognized). Use --json to inspect the payload.")
        return

    print(render_table(positions))
    summary = summarize(positions)
    print("\nSummary:")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

