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
import os
import glob
import requests
from datetime import datetime
from urllib.parse import urlencode
import pyotp
import pandas as pd
import pytz


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


def is_market_hours():
    """
    Check if current time is within Indian stock market hours.
    Market hours: Monday-Friday, 9:15 AM - 3:30 PM IST
    Returns: (is_market_hours: bool, message: str)
    """
    # Get IST timezone
    ist = pytz.timezone('Asia/Kolkata')
    now_ist = datetime.now(ist)
    
    # Check if weekday (Monday=0, Friday=4)
    weekday = now_ist.weekday()
    if weekday >= 5:  # Saturday=5, Sunday=6
        return False, f"Market is closed. Today is {now_ist.strftime('%A')}."
    
    # Get current time in IST
    current_time = now_ist.time()
    market_open = datetime.strptime("09:15", "%H:%M").time()
    market_close = datetime.strptime("15:30", "%H:%M").time()
    
    if current_time < market_open:
        return False, f"Market opens at 9:15 AM IST. Current time: {now_ist.strftime('%I:%M %p %Z')}"
    
    if current_time > market_close:
        return False, f"Market closed at 3:30 PM IST. Current time: {now_ist.strftime('%I:%M %p %Z')}"
    
    return True, f"Market is open. Current time: {now_ist.strftime('%I:%M %p %Z')}"


def load_credentials(path="b.txt"):
    """Load credentials from file"""
    # Get the directory where this script is located
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # Construct the full path to b.txt relative to the script's directory
    if not os.path.isabs(path):
        path = os.path.join(script_dir, path)
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


def resolve_trading_symbol(symbol, segment="nse_fo"):
    """
    Resolve trading symbol from pScripRefKey or pSymbol using scrip master CSV.
    Returns the trading symbol (ts) if found, otherwise returns the original symbol.
    """
    # Get the directory where this script is located
    script_dir = os.path.dirname(os.path.abspath(__file__))
    
    # Try to find scrip master CSV files
    # First try in scrip_masters directory relative to script
    scrip_masters_dir = os.path.join(script_dir, "scrip_masters")
    if not os.path.exists(scrip_masters_dir):
        # Try parent directory
        scrip_masters_dir = os.path.join(os.path.dirname(script_dir), "scrip_masters")
    
    if not os.path.exists(scrip_masters_dir):
        # If still not found, return original symbol
        return symbol
    
    # Find the latest scrip master CSV for the segment
    today_str = datetime.now().strftime('%Y%m%d')
    pattern = os.path.join(scrip_masters_dir, f"{segment}_scrip_master_{today_str}.csv")
    if not os.path.exists(pattern):
        # Try to find latest matching file
        pattern = os.path.join(scrip_masters_dir, f"{segment}_scrip_master_*.csv")
        files = glob.glob(pattern)
        if not files:
            return symbol
        # Sort by modification time and get latest
        files.sort(key=os.path.getmtime, reverse=True)
        pattern = files[0]
    else:
        pattern = pattern
    
    try:
        # Read CSV and search for the symbol
        df = pd.read_csv(pattern)
        
        # Check if pScripRefKey column exists and match
        if 'pScripRefKey' in df.columns and 'pTrdSymbol' in df.columns:
            match = df[df['pScripRefKey'].astype(str).str.strip() == symbol.strip()]
            if not match.empty:
                ts = match.iloc[0]['pTrdSymbol']
                if pd.notna(ts) and str(ts).strip():
                    return str(ts).strip()
        
        # Also try matching by pSymbol (numeric token)
        if symbol.isdigit() and 'pSymbol' in df.columns and 'pTrdSymbol' in df.columns:
            match = df[df['pSymbol'].astype(str).str.strip() == symbol.strip()]
            if not match.empty:
                ts = match.iloc[0]['pTrdSymbol']
                if pd.notna(ts) and str(ts).strip():
                    return str(ts).strip()
    except Exception as e:
        # If any error occurs, just return original symbol
        pass
    
    return symbol


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
        server_id = data.get('data', {}).get('hsServerId') or ''  # May be in login response
        
        if not view_token or not sid:
            raise RuntimeError(f"Missing token or sid in response: {data}")
        
        return view_token, sid, server_id, data
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
        validate_server_id = data.get('data', {}).get('hsServerId') or ''  # May be in validate response
        base_url = data.get('data', {}).get('baseUrl')
        
        if not edit_token or not edit_sid or not base_url:
            raise RuntimeError(f"Missing required fields in response: {data}")
        
        # Use server_id from validate response, or fallback to login_server_id if empty
        # server_id can be empty, that's okay
        return edit_token, edit_sid, validate_server_id, base_url, data
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
    
    # Only include sId in query params if it's not empty
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
        response = requests.post(
            url,
            headers=headers,
            params=query_params,
            data=body,
            timeout=30
        )
        response.raise_for_status()
        
        return response.json()
    except requests.exceptions.HTTPError as e:
        # Get the actual error response from the API
        error_msg = str(e)
        try:
            error_data = response.json()
            error_msg += f"\nAPI Response: {json.dumps(error_data, indent=2)}"
        except:
            error_msg += f"\nAPI Response Text: {response.text}"
        raise RuntimeError(f"Place order request failed: {error_msg}")
    except requests.exceptions.RequestException as e:
        raise RuntimeError(f"Place order request failed: {e}")


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
    p.add_argument('--skip-market-hours-check', action='store_true', help='Skip market hours validation (use with caution)')
    args = p.parse_args()
    
    # Check market hours (unless explicitly skipped)
    if not args.skip_market_hours_check:
        is_open, msg = is_market_hours()
        if not is_open:
            print(f"⚠️  {msg}")
            print("Use --skip-market-hours-check to override (not recommended)")
            sys.exit(1)
        else:
            print(f"✓ {msg}")
    
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
        view_token, sid, login_server_id, login_data = totp_login(consumer_key, neo_fin_key, mobile, ucc, totp_code)
        print("✓ TOTP Login successful")
        
        # Step 2: TOTP Validate
        print("Step 2: TOTP Validate...")
        edit_token, edit_sid, validate_server_id, base_url, validate_data = totp_validate(
            consumer_key, neo_fin_key, sid, view_token, mpin
        )
        print("✓ TOTP Validate successful")
        print(f"  Base URL: {base_url}")
        # Use server_id from validate response, fallback to login response if empty
        server_id = validate_server_id or login_server_id
        print(f"  Server ID: {server_id if server_id else '(empty)'}")
        
        # Resolve trading symbol from pScripRefKey if needed
        trading_symbol = resolve_trading_symbol(args.symbol, args.segment)
        if trading_symbol != args.symbol:
            print(f"  Resolved symbol: {args.symbol} -> {trading_symbol}")
        
        # Step 3: Place Order
        # Try both formats: without .00 first, then with .00
        symbol_variants = []
        if trading_symbol and '.00' in trading_symbol and (trading_symbol.endswith('CE') or trading_symbol.endswith('PE')):
            # Try without .00 first
            symbol_without_dot_zero = trading_symbol.replace('.00', '')
            symbol_variants.append(symbol_without_dot_zero)
            # Then try with .00
            symbol_variants.append(trading_symbol)
        else:
            # If no .00, just try the symbol as-is
            symbol_variants.append(trading_symbol)
        
        tag = args.tag or f"ORDER_CLI_NO_SDK_{datetime.now().strftime('%Y%m%d_%H%M%S_%f')}"
        
        # Try each symbol variant until one succeeds
        last_error = None
        for symbol_variant in symbol_variants:
            try:
                print(f"Step 3: Placing Order with symbol: {symbol_variant}...")
                resp = place_order(
                    base_url,
                    edit_token,
                    edit_sid,
                    server_id,
                    segment=args.segment,
                    symbol=symbol_variant,
                    tt=args.tt,
                    product=args.product,
                    order=args.order,
                    qty=args.qty,
                    price=args.price,
                    tag=tag,
                )
                
                print("Order Response:")
                print(json.dumps(resp, indent=2) if isinstance(resp, dict) else resp)
                return  # Success, exit
            except Exception as e:
                last_error = e
                if symbol_variant != symbol_variants[-1]:
                    print(f"  Failed with symbol '{symbol_variant}', trying next variant...")
                    continue
                else:
                    # Last variant failed, re-raise the error
                    raise
        
        # If we get here, all variants failed
        if last_error:
            raise last_error
        
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()

