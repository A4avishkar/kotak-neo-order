import json
import os
from typing import Any, Dict, Optional

import pyotp
import requests
from requests import Response

# Aligned with Flutter [KotakApiService] / [kotak_place_all.py]
EXCHANGE_SEGMENT_MAP: Dict[str, str] = {
    "nse_cm": "nse_cm",
    "NSE": "nse_cm",
    "nse": "nse_cm",
    "BSE": "bse_cm",
    "bse": "bse_cm",
    "bse_cm": "bse_cm",
    "NFO": "nse_fo",
    "nse_fo": "nse_fo",
    "nfo": "nse_fo",
    "BFO": "bse_fo",
    "bse_fo": "bse_fo",
    "bfo": "bse_fo",
    "CDS": "cde_fo",
    "cde_fo": "cde_fo",
    "cds": "cde_fo",
    "BCD": "bcs-fo",
    "bcs-fo": "bcs-fo",
    "bcd": "bcs-fo",
    "MCX": "mcx_fo",
    "mcx": "mcx_fo",
    "mcx_fo": "mcx_fo",
}

PRODUCT_MAP: Dict[str, str] = {
    "Normal": "NRML",
    "NRML": "NRML",
    "CNC": "CNC",
    "cnc": "CNC",
    "MIS": "MIS",
    "mis": "MIS",
    "INTRADAY": "INTRADAY",
    "CO": "CO",
    "co": "CO",
    "BO": "BO",
    "bo": "BO",
    "MTF": "MTF",
    "mtf": "MTF",
}

ORDER_TYPE_MAP: Dict[str, str] = {
    "Limit": "L",
    "L": "L",
    "MKT": "MKT",
    "mkt": "MKT",
    "Market": "MKT",
    "SL": "SL",
    "sl": "SL",
    "SL-M": "SL-M",
    "sl-m": "SL-M",
}


def normalize_option_symbol(symbol: str) -> str:
    s = symbol.strip().upper()
    if not (s.endswith("CE") or s.endswith("PE")):
        return symbol.strip()
    if ".00" in s:
        return s.replace(".00", "")
    return symbol.strip()


def _fmt_price(v: Any) -> str:
    if v is None:
        return "0"
    try:
        return f"{float(v):.2f}"
    except (TypeError, ValueError):
        return "0"


def build_order_jdata(order_params: Dict[str, Any]) -> Dict[str, str]:
    segment = order_params.get("segment") or "nse_fo"
    es = EXCHANGE_SEGMENT_MAP.get(str(segment), str(segment))
    product_raw = order_params.get("product") or "MIS"
    pc = PRODUCT_MAP.get(str(product_raw), str(product_raw))

    ot_raw = order_params.get("order_type") or "MKT"
    order_type = ORDER_TYPE_MAP.get(str(ot_raw), str(ot_raw))
    otu = order_type.upper()

    qty = order_params.get("qty")
    if qty is None:
        raise ValueError("qty is required")

    price = order_params.get("price")
    trigger = order_params.get("trigger_price")

    if otu == "L":
        if price is None or float(price or 0) <= 0:
            raise ValueError("Limit order requires price > 0")
    if otu == "SL":
        if price is None or float(price or 0) <= 0:
            raise ValueError("SL requires limit price > 0")
        if trigger is None:
            raise ValueError("SL requires trigger_price")
    if otu == "SL-M" and trigger is None:
        raise ValueError("SL-M requires trigger_price")

    limit_price = "0" if otu == "SL-M" else _fmt_price(price)
    trigger_price = _fmt_price(trigger if trigger is not None else 0)

    sym_raw = order_params.get("symbol") or ""
    is_fno = "_fo" in str(es).lower()
    ts = normalize_option_symbol(sym_raw) if is_fno else sym_raw

    tag = order_params.get("tag") or "SERVER_PROXY"

    jdata: Dict[str, str] = {
        "am": "NO",
        "dq": "0",
        "es": es,
        "mp": "0",
        "pc": pc,
        "pf": "N",
        "pr": limit_price,
        "pt": order_type,
        "qt": str(int(qty)),
        "rt": "DAY",
        "tp": trigger_price,
        "ts": ts,
        "tt": str(order_params.get("transaction_type") or "B"),
        "ig": str(tag),
        "os": "NEOTRADEAPI",
    }

    if pc == "BO":
        st = order_params.get("scrip_token")
        if not st:
            raise ValueError("Bracket product BO requires scrip_token (pSymbol)")
        jdata["tk"] = str(st)
        if order_params.get("square_off_value") is not None:
            jdata["sov"] = str(order_params["square_off_value"])
        if order_params.get("square_off_type") is not None:
            jdata["sot"] = str(order_params["square_off_type"])
        if order_params.get("stop_loss_value") is not None:
            jdata["slv"] = str(order_params["stop_loss_value"])
        if order_params.get("stop_loss_type") is not None:
            jdata["slt"] = str(order_params["stop_loss_type"])
        jdata["lat"] = "LTP"
        jdata["tlt"] = "N"
        jdata["tsv"] = "0"

    return jdata


def kotak_login_from_creds(
    creds: Dict[str, str],
    base_url: str = "https://mis.kotaksecurities.com",
) -> Dict[str, Any]:
    """Fully TOTP + MPIN login; returns session dict for [_post_jdata]."""
    consumer_key = creds.get("KOTAK_CONSUMER_KEY")
    mobile = creds.get("KOTAK_MOBILE_NUMBER")
    ucc = creds.get("KOTAK_UCC")
    mpin = creds.get("KOTAK_MPIN")
    totp_secret = creds.get("KOTAK_TOTP_SECRET")
    neo_fin_key = creds.get("KOTAK_NEO_FIN_KEY", "neotradeapi")

    if not all([consumer_key, mobile, ucc, mpin, totp_secret]):
        raise ValueError("Incomplete Kotak credentials")

    if str(mobile).isdigit() and len(str(mobile)) == 10 and not str(mobile).startswith("+"):
        mobile = "+91" + str(mobile)

    totp_code = pyotp.TOTP(totp_secret).now()

    def _raise_for_status_verbose(resp: Response, *, label: str) -> None:
        try:
            resp.raise_for_status()
        except requests.exceptions.HTTPError as e:
            body = resp.text
            try:
                body = json.dumps(resp.json(), indent=2)
            except Exception:
                pass
            raise RuntimeError(
                f"Kotak {label} failed ({resp.status_code}) @ {resp.url}\n"
                f"Response body:\n{body}"
            ) from e

    url_login = f"{base_url}/login/1.0/tradeApiLogin"
    headers_login = {
        "Authorization": consumer_key,
        "neo-fin-key": neo_fin_key,
        "Content-Type": "application/json",
        "Accept": "application/json, text/plain, */*",
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) kotak-neo-proxy/1.0",
    }
    body_login = {"mobileNumber": mobile, "ucc": ucc, "totp": totp_code}

    resp_login = requests.post(url_login, headers=headers_login, json=body_login, timeout=30)
    _raise_for_status_verbose(resp_login, label="tradeApiLogin")
    data_login = resp_login.json().get("data", {})

    view_token = data_login.get("token")
    sid = data_login.get("sid")
    if not view_token or not sid:
        raise RuntimeError(
            "Kotak tradeApiLogin response missing token/sid.\n"
            f"Response body:\n{resp_login.text}"
        )

    url_val = f"{base_url}/login/1.0/tradeApiValidate"
    headers_val = {
        "Authorization": consumer_key,
        "sid": sid,
        "Auth": view_token,
        "neo-fin-key": neo_fin_key,
        "Accept": "application/json, text/plain, */*",
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) kotak-neo-proxy/1.0",
    }
    body_val = {"mpin": mpin}

    resp_val = requests.post(url_val, headers=headers_val, json=body_val, timeout=30)
    _raise_for_status_verbose(resp_val, label="tradeApiValidate")
    data_val = resp_val.json().get("data", {})

    bu = data_val.get("baseUrl")
    return {
        "edit_token": data_val.get("token"),
        "edit_sid": data_val.get("sid"),
        "server_id": data_val.get("hsServerId") or data_login.get("hsServerId") or "",
        "api_base_url": bu,
        "base_url": bu,
        "neo_fin_key": neo_fin_key,
    }


class KotakService:
    def __init__(self, credentials_path: str = "b.txt"):
        self.credentials_path = credentials_path
        self.base_url = "https://mis.kotaksecurities.com"
        self.session_data: Dict[str, Any] = {}
        try:
            self.creds = self._load_credentials()
        except FileNotFoundError:
            self.creds = {}

    def _load_credentials(self) -> Dict[str, str]:
        possible_paths = [
            self.credentials_path,
            os.path.join(os.getcwd(), "b.txt"),
            os.path.join(os.path.dirname(os.getcwd()), "b.txt"),
        ]
        for path in possible_paths:
            if os.path.exists(path):
                creds: Dict[str, str] = {}
                with open(path, "r", encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if "=" in line and not line.startswith("#"):
                            k, v = line.split("=", 1)
                            creds[k.strip()] = v.strip().strip('"').strip("'")
                return creds
        raise FileNotFoundError("Could not find b.txt credentials file.")

    def login(self) -> bool:
        if not self.creds:
            return False
        try:
            self.session_data = kotak_login_from_creds(self.creds, self.base_url)
            return True
        except Exception as e:
            print(f"Login error: {e}")
            return False

    def _post_jdata(
        self, jdata: Dict[str, str], session: Dict[str, Any]
    ) -> Dict[str, Any]:
        base = session.get("api_base_url") or session.get("base_url")
        if not base:
            raise ValueError("Missing Kotak base URL in session")
        edit_sid = session["edit_sid"]
        edit_token = session["edit_token"]
        server_id = session.get("server_id") or ""
        neo_fin_key = session.get("neo_fin_key") or "neotradeapi"

        url = f"{str(base).rstrip('/')}/quick/order/rule/ms/place"
        headers = {
            "Sid": edit_sid,
            "Auth": edit_token,
            "neo-fin-key": neo_fin_key,
            "accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
        }
        params = {"sId": server_id} if server_id else {}
        body = {"jData": json.dumps(jdata)}
        resp = requests.post(url, headers=headers, params=params, data=body, timeout=30)
        try:
            return resp.json()
        except Exception:
            return {
                "stat": "Not_Ok",
                "emsg": resp.text,
                "http": resp.status_code,
            }

    def place_order_with_client_session(
        self,
        order_params: Dict[str, Any],
        kotak_session: Dict[str, Any],
    ) -> Dict[str, Any]:
        """Place order using session tokens sent by the mobile app (per-user)."""
        jdata = build_order_jdata(order_params)
        return self._post_jdata(jdata, kotak_session)

    def place_order(self, order_params: Dict[str, Any]) -> Dict[str, Any]:
        """Legacy: use server b.txt session only."""
        if not self.session_data:
            if not self.login():
                raise Exception("Authentication failed (server b.txt)")
        jdata = build_order_jdata(order_params)
        return self._post_jdata(jdata, self.session_data)
