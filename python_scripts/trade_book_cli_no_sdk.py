#!/usr/bin/env python3
"""
Direct REST API Trade Book CLI (No SDK).

Fetches trade history via:

    GET quick/user/trades

Authentication reuses the TOTP + MPIN flow from the other *_cli_no_sdk scripts.
"""

import argparse
import json
import os
import sys
from typing import Any, Dict

import pyotp
import requests


BASE_URL = "https://mis.kotaksecurities.com"
TOTP_LOGIN_ENDPOINT = "login/1.0/tradeApiLogin"
TOTP_VALIDATE_ENDPOINT = "login/1.0/tradeApiValidate"
TRADE_BOOK_ENDPOINT = "quick/user/trades"
DEFAULT_NEO_FIN_KEY = "neotradeapi"


def load_credentials(path: str = "b.txt") -> Dict[str, str]:
    """Load key=value style credentials from file."""
    if not os.path.isabs(path):
        script_dir = os.path.dirname(os.path.abspath(__file__))
        path = os.path.join(script_dir, path)

    creds: Dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            creds[k.strip()] = v.strip().strip('"').strip("'")
    return creds


def format_mobile_number(mobile: str) -> str:
    """Return a Kotak-compatible mobile number (prefers +91XXXXXXXXXX)."""
    mobile = mobile.strip()
    if mobile.startswith("+"):
        return mobile
    digits = "".join(ch for ch in mobile if ch.isdigit())
    if len(digits) == 10:
        return "+91" + digits
    return mobile


def generate_totp_code(secret: str) -> str:
    """Generate a 6-digit TOTP from secret."""
    clean_secret = secret.replace(" ", "")
    return pyotp.TOTP(clean_secret).now()


def totp_login(consumer_key: str, neo_fin_key: str, mobile: str, ucc: str, totp_code: str):
    """Step 1: TOTP Login - get view token and session ID."""
    url = f"{BASE_URL}/{TOTP_LOGIN_ENDPOINT}"
    headers = {
        "Authorization": consumer_key,
        "neo-fin-key": neo_fin_key,
        "Content-Type": "application/json",
    }
    body = {
        "mobileNumber": mobile,
        "ucc": ucc,
        "totp": totp_code,
    }
    resp = requests.post(url, headers=headers, json=body, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    if data.get("data", {}).get("status") != "success":
        raise RuntimeError(f"TOTP login failed: {json.dumps(data, indent=2)}")
    view_token = data["data"].get("token")
    sid = data["data"].get("sid")
    server_id = data["data"].get("hsServerId") or ""
    if not view_token or not sid:
        raise RuntimeError(f"Missing token/sid in TOTP login response: {json.dumps(data, indent=2)}")
    return view_token, sid, server_id, data


def totp_validate(consumer_key: str, neo_fin_key: str, sid: str, view_token: str, mpin: str):
    """Step 2: TOTP Validate - get edit token and base URL."""
    url = f"{BASE_URL}/{TOTP_VALIDATE_ENDPOINT}"
    headers = {
        "Authorization": consumer_key,
        "sid": sid,
        "Auth": view_token,
        "neo-fin-key": neo_fin_key,
        "Content-Type": "application/json",
    }
    body = {"mpin": mpin}
    resp = requests.post(url, headers=headers, json=body, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    if data.get("data", {}).get("status") != "success":
        raise RuntimeError(f"TOTP validate failed: {json.dumps(data, indent=2)}")
    edit_token = data["data"].get("token")
    edit_sid = data["data"].get("sid")
    base_url = data["data"].get("baseUrl") or BASE_URL
    server_id = data["data"].get("hsServerId") or ""
    if not edit_token or not edit_sid:
        raise RuntimeError(f"Missing edit token/sid in TOTP validate response: {json.dumps(data, indent=2)}")
    return edit_token, edit_sid, base_url.rstrip("/"), server_id, data


def establish_session(creds: Dict[str, str], totp_override: str | None = None) -> Dict[str, Any]:
    """Run login + validate and return tokens, base URL, server ID."""
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

    totp_code = totp_override or (generate_totp_code(totp_secret) if totp_secret else None)
    if not totp_code:
        raise RuntimeError("No TOTP secret found in b.txt and no --totp override was provided.")

    formatted_mobile = format_mobile_number(mobile)

    view_token, sid, login_server_id, login_payload = totp_login(
        consumer_key, neo_fin_key, formatted_mobile, ucc, totp_code
    )
    edit_token, edit_sid, base_url, validate_server_id, validate_payload = totp_validate(
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


def fetch_trade_book(base_url: str, edit_token: str, edit_sid: str, server_id: str) -> Dict[str, Any]:
    """GET trade history entries."""
    url = f"{base_url.rstrip('/')}/{TRADE_BOOK_ENDPOINT}"
    headers = {
        "Sid": edit_sid,
        "Auth": edit_token,
        "accept": "application/json",
    }
    params: Dict[str, str] = {}
    if server_id:
        params["sId"] = server_id

    resp = requests.get(url, headers=headers, params=params, timeout=30)
    resp.raise_for_status()
    return resp.json()


def main():
    parser = argparse.ArgumentParser(description="Direct REST API Trade Book CLI (No SDK)")
    parser.add_argument("--creds", default="b.txt", help="Path to credentials file (default: b.txt)")
    parser.add_argument("--totp", help="Override 6-digit TOTP code (if no secret stored)")
    parser.add_argument("--debug", action="store_true", help="Print login/validate payloads")
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

        trades = fetch_trade_book(
            base_url=session["base_url"],
            edit_token=session["edit_token"],
            edit_sid=session["edit_sid"],
            server_id=session["server_id"],
        )
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)

    print(json.dumps(trades, indent=2))


if __name__ == "__main__":
    main()

