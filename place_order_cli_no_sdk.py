#!/usr/bin/env python3
"""
Direct REST API Order Placement CLI (No SDK)

This version makes direct HTTP requests to Kotak Neo API without using the SDK.

Usage examples:

  # MARKET BUY 50 qty NIFTY FUT
  python place_order_cli_no_sdk.py \
      --segment nse_fo \
      --symbol NIFTY25NOVFUT \
      --tt B \
      --product MIS \
      --order MKT \
      --qty 50 \
      --yes

  # LIMIT SELL option @ 100.5
  python place_order_cli_no_sdk.py \
      --segment nse_fo \
      --symbol NIFTY04NOV2525700.00PE \
      --tt S \
      --product MIS \
      --order L \
      --price 100.5 \
      --qty 50 \
      --yes

Notes:
- Reads credentials from b.txt (KOTAK_CONSUMER_KEY, KOTAK_MOBILE_NUMBER, KOTAK_MPIN, KOTAK_UCC, KOTAK_TOTP_SECRET)
- Defaults to DRY-RUN unless --yes is passed
- Makes direct REST API calls without SDK dependency
"""

import argparse
import json
import sys
import requests
from datetime import datetime
from urllib.parse import urlencode
import pyotp


# API Configuration
BASE_URL = "https://mis.kotaksecurities.com"
TOTP_LOGIN_ENDPOINT = "login/1.0/tradeApiLogin"
TOTP_VALIDATE_ENDPOINT = "login/1.0/tradeApiValidate"
PLACE_ORDER_ENDPOINT = "quick/order/rule/ms/place"

# Default neo-fin-key for production
DEFAULT_NEO_FIN_KEY = "neotradeapi"

# Exchange segment mapping
EXCHANGE_SEGMENT_MAP = {
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
    "MCX": "mcx",
    "mcx": "mcx",
    "mcx_fo": "mcx"
}

# Product mapping
PRODUCT_MAP = {
    "Normal": "NRML",
    "NRML": "NRML",
    "CNC": "CNC",
    "cnc": "CNC",
    "Cash and Carry": "CNC",
    "MIS": "MIS",
    "mis": "MIS",
    "INTRADAY": "INTRADAY",
    "intraday": "INTRADAY",
    "Cover Order": "CO",
    "co": "CO",
    "CO": "CO",
    "BO": "BO",
    "Bracket Order": "BO",
    "bo": "BO"
}

# Order type mapping
ORDER_TYPE_MAP = {
    "Limit": "L",
    "L": "L",
    "l": "L",
    "MKT": "MKT",
    "mkt": "MKT",
    "Market": "MKT",
    "sl": "SL",
    "SL": "SL",
    "Stop loss limit": "SL",
    "Stop loss market": "SL-M",
    "SL-M": "SL-M",
    "sl-m": "SL-M",
    "Spread": "SP",
    "SP": "SP",
    "sp": "SP",
    "2L": "2L",
    "2l": "2L",
    "Two Leg": "2L",
    "3L": "3L",
    "3l": "3L",
    "Three leg": "3L"
}


def load_credentials(path="b.txt"):
    """Load credentials from file"""
    creds = {}
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1)
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                creds[k] = v
    return creds


def generate_totp_code(secret):
    """Generate TOTP code from secret"""
    return pyotp.TOTP(secret).now()


def totp_login(consumer_key, neo_fin_key, mobile_number, ucc, totp):
    """
    Step 1: TOTP Login - Get view token and session ID
    """
    url = f"{BASE_URL}/{TOTP_LOGIN_ENDPOINT}"
    
    headers = {
        'Authorization': consumer_key,
        'neo-fin-key': neo_fin_key,
        'Content-Type': 'application/json'
    }
    
    body = {
        "mobileNumber": mobile_number,
        "ucc": ucc,
        "totp": totp
    }
    
    try:
        response = requests.post(url, headers=headers, json=body, timeout=30)
        response.raise_for_status()
        
        data = response.json()
        if data.get('data', {}).get('status') != 'success':
            raise RuntimeError(f"TOTP login failed: {data}")
        
        view_token = data.get('data', {}).get('token')
        sid = data.get('data', {}).get('sid')
        
        if not view_token or not sid:
            raise RuntimeError(f"Missing token or sid in response: {data}")
        
        return view_token, sid, data
    except requests.exceptions.RequestException as e:
        raise RuntimeError(f"TOTP login request failed: {e}")


def totp_validate(consumer_key, neo_fin_key, sid, view_token, mpin):
    """
    Step 2: TOTP Validate - Get edit token and server details
    """
    url = f"{BASE_URL}/{TOTP_VALIDATE_ENDPOINT}"
    
    headers = {
        'Authorization': consumer_key,
        'sid': sid,
        'Auth': view_token,
        'neo-fin-key': neo_fin_key
    }
    
    body = {
        "mpin": mpin
    }
    
    try:
        response = requests.post(url, headers=headers, json=body, timeout=30)
        response.raise_for_status()
        
        data = response.json()
        if data.get('data', {}).get('status') != 'success':
            raise RuntimeError(f"TOTP validate failed: {data}")
        
        edit_token = data.get('data', {}).get('token')
        edit_sid = data.get('data', {}).get('sid')
        # Try multiple possible field names for server ID
        server_id = (
            data.get('data', {}).get('hsServerId') or
            data.get('data', {}).get('serverId') or
            data.get('data', {}).get('sId') or
            data.get('data', {}).get('server_id') or
            ''
        )
        base_url = data.get('data', {}).get('baseUrl')
        
        if not edit_token or not edit_sid or not base_url:
            raise RuntimeError(f"Missing required fields in response: {data}")
        
        # Debug: Print full response to help troubleshoot
        print(f"  Debug - Full validate response: {json.dumps(data, indent=2)}")
        
        # server_id can be empty, that's okay
        return edit_token, edit_sid, server_id, base_url, data
    except requests.exceptions.RequestException as e:
        raise RuntimeError(f"TOTP validate request failed: {e}")


def place_order(base_url, edit_token, edit_sid, server_id, *, segment, symbol, tt, product, order, qty, price=None, tag=None):
    """
    Step 3: Place Order - Submit order to exchange
    """
    # Map convenience values
    exchange_segment = EXCHANGE_SEGMENT_MAP.get(segment, segment)
    product_mapped = PRODUCT_MAP.get(product, product)
    order_type = ORDER_TYPE_MAP.get(order, order)
    quantity = str(qty)
    limit_price = str(price) if price is not None else "0"
    
    if order_type.upper() == 'L' and price is None:
        raise ValueError("Limit order requires --price")
    
    url = f"{base_url}/{PLACE_ORDER_ENDPOINT}"
    
    headers = {
        "Sid": edit_sid,
        "Auth": edit_token,
        "Content-Type": "application/x-www-form-urlencoded"
    }
    
    # Only include sId query parameter if server_id is not empty
    query_params = {}
    if server_id:
        query_params["sId"] = server_id
    
    # Order body parameters
    order_data = {
        "am": "NO",  # AMO
        "dq": "0",  # Disclosed quantity
        "es": exchange_segment,
        "mp": "0",  # Market protection
        "pc": product_mapped,
        "pf": "N",  # Portfolio flag
        "pr": limit_price,
        "pt": order_type,
        "qt": quantity,
        "rt": "DAY",  # Validity
        "tp": "0",  # Trigger price
        "ts": symbol,  # Trading symbol
        "tt": tt,  # Transaction type (B/S)
        "ig": tag or "ORDER_CLI_NO_SDK",  # Tag
        "os": "NEOTRADEAPI"  # Order source
    }
    
    # Format as form-urlencoded with jData
    body = {
        "jData": json.dumps(order_data)
    }
    
    try:
        # Build full URL for debugging
        full_url = f"{url}?{urlencode(query_params)}" if query_params else url
        print(f"  Debug - Request URL: {full_url}")
        print(f"  Debug - Request headers: {headers}")
        print(f"  Debug - Request body: {body}")
        
        response = requests.post(
            url,
            headers=headers,
            params=query_params,
            data=body,
            timeout=30
        )
        
        # Try to get response body even if status is not 200
        try:
            response_data = response.json()
            print(f"  Debug - Response status: {response.status_code}")
            print(f"  Debug - Response body: {json.dumps(response_data, indent=2)}")
        except:
            print(f"  Debug - Response status: {response.status_code}")
            print(f"  Debug - Response body (text): {response.text}")
        
        response.raise_for_status()
        
        return response_data if 'response_data' in locals() else response.json()
    except requests.exceptions.RequestException as e:
        # Include response body in error if available
        error_msg = str(e)
        try:
            if hasattr(e, 'response') and e.response is not None:
                error_msg += f"\n  Response body: {e.response.text}"
        except:
            pass
        raise RuntimeError(f"Place order request failed: {error_msg}")


def main():
    p = argparse.ArgumentParser(description='Direct REST API Order Placement CLI (No SDK)')
    p.add_argument('--segment', required=True, help='Exchange segment (e.g., nse_fo, nse_cm)')
    p.add_argument('--symbol', required=True, help='Trading symbol (e.g., NIFTY04NOV2525700.00PE, NIFTY25NOVFUT)')
    p.add_argument('--tt', required=True, choices=['B', 'S'], help='Transaction type: B (Buy) or S (Sell)')
    p.add_argument('--product', default='MIS', help='Product (MIS, NRML, CNC)')
    p.add_argument('--order', required=True, choices=['L', 'MKT', 'SL', 'SL-M'], help='Order type')
    p.add_argument('--qty', type=int, required=True, help='Quantity')
    p.add_argument('--price', type=float, help='Price (required for L, SL)')
    p.add_argument('--tag', default=None, help='Custom tag')
    p.add_argument('--yes', action='store_true', help='Actually place the order (disable dry-run)')
    args = p.parse_args()
    
    # Dry-run preview
    if not args.yes:
        print("DRY-RUN (use --yes to execute):")
        print(json.dumps({
            "segment": args.segment, "symbol": args.symbol, "tt": args.tt,
            "product": args.product, "order": args.order, "qty": args.qty,
            "price": args.price, "tag": args.tag or "ORDER_CLI_NO_SDK"
        }, indent=2))
        sys.exit(0)
    
    try:
        # Load credentials
        creds = load_credentials()
        consumer_key = creds.get('KOTAK_CONSUMER_KEY')
        mobile = creds.get('KOTAK_MOBILE_NUMBER')
        ucc = creds.get('KOTAK_UCC')
        mpin = creds.get('KOTAK_MPIN')
        totp_secret = creds.get('KOTAK_TOTP_SECRET')
        neo_fin_key = creds.get('KOTAK_NEO_FIN_KEY', DEFAULT_NEO_FIN_KEY)
        
        if not all([consumer_key, mobile, ucc, mpin, totp_secret]):
            raise ValueError("Missing required credentials in b.txt")
        
        # Format mobile number
        if mobile.isdigit() and len(mobile) == 10 and not mobile.startswith('+'):
            mobile = '+91' + mobile
        
        # Generate TOTP
        totp_code = generate_totp_code(totp_secret)
        
        # Step 1: TOTP Login
        print("Step 1: TOTP Login...")
        view_token, sid, login_data = totp_login(consumer_key, neo_fin_key, mobile, ucc, totp_code)
        print("✓ TOTP Login successful")
        
        # Step 2: TOTP Validate
        print("Step 2: TOTP Validate...")
        edit_token, edit_sid, server_id, base_url, validate_data = totp_validate(
            consumer_key, neo_fin_key, sid, view_token, mpin
        )
        print("✓ TOTP Validate successful")
        print(f"  Base URL: {base_url}")
        print(f"  Server ID: {server_id}")
        
        # Step 3: Place Order
        print("Step 3: Placing Order...")
        tag = args.tag or f"ORDER_CLI_NO_SDK_{datetime.now().strftime('%Y%m%d_%H%M%S_%f')}"
        
        resp = place_order(
            base_url,
            edit_token,
            edit_sid,
            server_id,
            segment=args.segment,
            symbol=args.symbol,
            tt=args.tt,
            product=args.product,
            order=args.order,
            qty=args.qty,
            price=args.price,
            tag=tag,
        )
        
        print("Order Response:")
        print(json.dumps(resp, indent=2) if isinstance(resp, dict) else resp)
        
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()

