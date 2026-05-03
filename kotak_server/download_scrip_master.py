#!/usr/bin/env python3
"""
Download F&O Scrip Master CSV Files
Downloads NSE F&O, BSE F&O, and other scrip master data files
Uses URL construction method (no SDK or API calls needed) - reads credentials from b.txt
"""

import os
import json
import sys
import requests
import urllib3
import pyotp
import time
from datetime import datetime, timedelta

# SSL verification policy (secure by default).
# Set KOTAK_INSECURE_SSL=true only for controlled troubleshooting.
ALLOW_INSECURE_SSL = str(os.getenv("KOTAK_INSECURE_SSL", "false")).strip().lower() in ("1", "true", "yes")
if ALLOW_INSECURE_SSL:
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


def find_b_txt():
    """Find b.txt file in various possible locations"""
    current_dir = os.path.dirname(os.path.abspath(__file__)) if '__file__' in globals() else os.getcwd()
    
    possible_paths = [
        os.path.join(current_dir, "b.txt"),
        os.path.join(current_dir, "..", "Kotak-neo-api-v2-main", "b.txt"),
        os.path.join(current_dir, "..", "b.txt"),
        "b.txt",  # Current working directory
    ]
    
    for path in possible_paths:
        abs_path = os.path.abspath(path)
        if os.path.exists(abs_path):
            return abs_path
    
    return None


def load_credentials(file_path=None):
    """Load credentials from b.txt file"""
    if not file_path:
        file_path = find_b_txt()
    
    if not file_path or not os.path.exists(file_path):
        print("[ERROR] Could not find b.txt file")
        print("   Please ensure b.txt is in the same directory or parent directory")
        return None
    
    credentials = {}
    try:
        with open(file_path, 'r') as f:
            for line in f:
                line = line.strip()
                if '=' in line and not line.startswith('#'):
                    key, value = line.split('=', 1)
                    key = key.strip()
                    value = value.strip()
                    
                    # Remove quotes if present
                    if value.startswith('"') and value.endswith('"'):
                        value = value[1:-1]
                    elif value.startswith("'") and value.endswith("'"):
                        value = value[1:-1]
                    
                    # Handle boolean values
                    if value.lower() == 'true':
                        credentials[key] = True
                    elif value.lower() == 'false':
                        credentials[key] = False
                    elif value == '':
                        credentials[key] = None
                    else:
                        credentials[key] = value
        
        print(f"[OK] Loaded credentials from: {file_path}")
        return credentials
    except Exception as e:
        print(f"[ERROR] Error reading {file_path}: {e}")
        return None


def login_and_get_session(creds):
    """Login using direct API calls and return session token"""
    print("\n" + "=" * 60)
    print("Step 1: Login & Get Session")
    print("=" * 60)
    
    consumer_key = creds.get('KOTAK_CONSUMER_KEY')
    mobile_number = creds.get('KOTAK_MOBILE_NUMBER')
    mpin = creds.get('KOTAK_MPIN')
    ucc = creds.get('KOTAK_UCC')
    totp_secret = creds.get('KOTAK_TOTP_SECRET')
    
    if not all([consumer_key, mobile_number, mpin, ucc]):
        print("[ERROR] Missing required credentials in b.txt")
        return None
    
    # Generate TOTP
    print("Generating TOTP code...")
    totp_code = None
    if totp_secret and totp_secret.strip():
        secret_clean = totp_secret.strip().replace(' ', '').replace('"', '').replace("'", '')
        if secret_clean.isdigit() and len(secret_clean) == 6:
            print("[WARN]  You have a TOTP code, not a secret. Using it for this run only.")
            totp_code = secret_clean
        else:
            try:
                totp = pyotp.TOTP(secret_clean)
                totp_code = totp.now()
                print(f"[OK] TOTP code generated: {totp_code}")
            except Exception as e:
                print(f"[ERROR] Failed to generate TOTP: {e}")
                print("[ERROR] Server mode: Cannot use interactive input. Please ensure KOTAK_TOTP_SECRET is a valid TOTP secret in b.txt")
                return None
    else:
        print("[ERROR] Missing KOTAK_TOTP_SECRET in b.txt")
        print("[ERROR] Server mode: Cannot use interactive input. Please add a valid TOTP secret to b.txt")
        return None
    
    # Format mobile number
    formatted_mobile = mobile_number
    if not mobile_number.startswith('+'):
        if len(mobile_number) == 10 and mobile_number.isdigit():
            formatted_mobile = '+91' + mobile_number
    
    # TOTP Login
    try:
        totp_url = "https://mis.kotaksecurities.com/login/1.0/tradeApiLogin"
        totp_headers = {
            "Content-Type": "application/json",
            "Authorization": consumer_key,
            "neo-fin-key": "neotradeapi"
        }
        totp_payload = {
            "mobileNumber": formatted_mobile,
            "ucc": ucc,
            "totp": totp_code
        }
        
        totp_response = requests.post(totp_url, headers=totp_headers, json=totp_payload, timeout=15, verify=not ALLOW_INSECURE_SSL)
        
        if totp_response.status_code != 200:
            print(f"[ERROR] TOTP Login failed: {totp_response.text}")
            return None
        
        totp_data = totp_response.json()
        if totp_data.get("data", {}).get("status") != "success":
            print(f"[ERROR] TOTP Login failed: {totp_data}")
            return None
        
        view_token = totp_data["data"].get("token")
        sid = totp_data["data"].get("sid")
        print("[OK] TOTP Login successful")
        
    except Exception as e:
        print(f"[ERROR] TOTP Login error: {e}")
        return None
    
    # MPIN Validation
    try:
        mpin_url = "https://mis.kotaksecurities.com/login/1.0/tradeApiValidate"
        mpin_headers = {
            "Content-Type": "application/json",
            "Authorization": consumer_key,
            "sid": sid,
            "Auth": view_token,
            "neo-fin-key": "neotradeapi"
        }
        mpin_payload = {"mpin": mpin}
        
        mpin_response = requests.post(mpin_url, headers=mpin_headers, json=mpin_payload, timeout=15, verify=not ALLOW_INSECURE_SSL)
        
        if mpin_response.status_code != 200:
            print(f"[ERROR] MPIN Validate failed: {mpin_response.text}")
            return None
        
        session_payload = mpin_response.json()
        if session_payload.get("data", {}).get("status") != "success":
            print(f"[ERROR] MPIN Validate failed: {session_payload}")
            return None
        
        data = session_payload.get("data", {})
        session_token = data.get("token") or data.get("sessionToken")
        base_url = data.get("baseUrl") or "https://mis.kotaksecurities.com"
        
        print("[OK] MPIN Validate successful")
        print("[OK] Session token obtained")
        
        # Debug output removed for server security (contains sensitive tokens)
        
        return {
            "session_token": session_token,
            "base_url": base_url,
            "sid": data.get("sid") or sid,
            "full_data": data  # Include full data for debugging
        }
        
    except Exception as e:
        print(f"[ERROR] MPIN Validate error: {e}")
        return None


def get_scrip_master_urls_from_api(consumer_key, base_url=None):
    """Get scrip master URLs from API (for segments that require authentication)"""
    # Try multiple base URLs (SDK uses mnapi.kotaksecurities.com for production)
    base_urls_to_try = [
        "https://mnapi.kotaksecurities.com",  # Standard production base URL
    ]
    
    if base_url:
        base_urls_to_try.insert(0, base_url.rstrip('/'))
    
    endpoint = "script-details/1.0/masterscrip/file-paths"
    
    headers = {
        "Authorization": consumer_key,
        "Content-Type": "application/x-www-form-urlencoded"
    }
    
    for base in base_urls_to_try:
        try:
            api_url = f"{base}/{endpoint}"
            print(f"  [API] Calling API: {api_url}")
            response = requests.get(api_url, headers=headers, timeout=30, verify=not ALLOW_INSECURE_SSL)
            
            if response.status_code == 200:
                data = response.json()
                if "data" in data and "filesPaths" in data["data"]:
                    file_paths = data["data"]["filesPaths"]
                    print(f"  [OK] Got {len(file_paths)} URLs from API")
                    return file_paths
                else:
                    print(f"  [WARN]  Unexpected API response format: {data}")
            elif response.status_code == 401:
                print(f"  [WARN]  Unauthorized (401) - trying next base URL...")
                continue
            else:
                print(f"  [WARN]  API returned {response.status_code}: {response.text[:200]}")
        except Exception as e:
            print(f"  [WARN]  API call failed for {base}: {e}")
            continue
    
    return None


def get_scrip_master_urls(session_token=None, base_url=None, ucc=None, full_data=None, consumer_key=None, consumer_secret=None):
    """Get scrip master file URLs - uses API for authenticated segments, direct URLs for F&O"""
    print("\n" + "=" * 60)
    print("Step 2: Fetching Scrip Master URLs")
    print("=" * 60)
    
    # Segments that typically work with direct URL construction (F&O)
    fo_segments = ["nse_fo", "bse_fo", "mcx_fo", "cde_fo"]
    
    # Segments that require authentication (Cash Market, Currency)
    auth_segments = ["nse_cm", "bse_cm", "nse_cd"]
    
    all_segments = {
        "nse_fo": "nse_fo",
        "nse_cm": "nse_cm",
        "nse_cd": "nse_cd",
        "bse_fo": "bse_fo",
        "bse_cm": "bse_cm",
        "mcx_fo": "mcx_fo",
        "cde_fo": "cde_fo"
    }
    
    final_urls = {}
    
    # Step 1: Try to get authenticated URLs from API for segments that need it
    if consumer_key and base_url:
        print("\n[API] Getting authenticated URLs from API for cash market segments...")
        api_urls = get_scrip_master_urls_from_api(consumer_key, base_url)
        
        if api_urls:
            # Map API URLs to segments
            for url in api_urls:
                url_lower = url.lower()
                for seg_code in auth_segments:
                    if seg_code in url_lower and seg_code not in final_urls:
                        final_urls[seg_code] = url
                        print(f"  [OK] Found {seg_code}: {url}")
    
    # Step 2: Construct direct URLs for F&O segments (and any missing segments)
    print("\n[LIST] Constructing direct URLs for F&O segments...")
    today = datetime.now().strftime("%Y-%m-%d")
    base_folder = f"https://lapi.kotaksecurities.com/wso2-scripmaster/v1/prod"
    
    for seg_code, filename in all_segments.items():
        if seg_code not in final_urls:
            url = f"{base_folder}/{today}/transformed/{filename}.csv"
            final_urls[seg_code] = url
            print(f"  [LIST] Constructed {seg_code}: {url}")
    
    # Return URLs in the same order as segments_pattern
    result_urls = [final_urls.get(seg) for seg in all_segments.keys() if seg in final_urls]
    
    if result_urls:
        print(f"\n[OK] Got {len(result_urls)} URLs total")
        return result_urls
    
    print("[ERROR] Could not get scrip master URLs.")
    return None


def cleanup_old_files(base_dir, keep_today_only=True):
    """Delete all old CSV files, keeping only today's files for each segment"""
    if not os.path.exists(base_dir):
        return
    
    today_date = datetime.now().date()
    today_str = datetime.now().strftime("%Y%m%d")
    deleted_count = 0
    deleted_size = 0
    
    print("\n" + "=" * 60)
    print("Step 0: Cleaning Up Old Files")
    print("=" * 60)
    
    try:
        for filename in os.listdir(base_dir):
            if not filename.endswith(".csv") or "_scrip_master_" not in filename:
                continue
            
            file_path = os.path.join(base_dir, filename)
            
            # Extract date from filename
            file_date = None
            try:
                # Format: {seg_code}_scrip_master_{YYYYMMDD}.csv
                parts = filename.replace(".csv", "").split("_scrip_master_")
                if len(parts) == 2 and len(parts[1]) == 8 and parts[1].isdigit():
                    file_date = datetime.strptime(parts[1], "%Y%m%d").date()
            except:
                # Fallback: check modification date
                file_mod_time = datetime.fromtimestamp(os.path.getmtime(file_path))
                file_date = file_mod_time.date()
            
            # Delete if not today's file
            if file_date != today_date:
                try:
                    file_size = os.path.getsize(file_path)
                    os.remove(file_path)
                    deleted_count += 1
                    deleted_size += file_size
                    print(f"[CLEAN] Deleted old file: {filename} (date: {file_date}, size: {file_size:,} bytes)")
                except Exception as del_err:
                    print(f"[WARN]  Could not delete {filename}: {del_err}")
        
        if deleted_count > 0:
            print(f"[OK] Cleanup complete: Deleted {deleted_count} old file(s), freed {deleted_size:,} bytes")
        else:
            print("[OK] No old files to clean up")
            
    except Exception as e:
        print(f"[WARN]  Error during cleanup: {e}")


def download_fno_scrip_master(base_dir="scrip_masters"):
    """Download all available scrip master CSVs from Kotak Neo and save locally"""
    print("=" * 80)
    print("Kotak Neo - Download Scrip Master CSV Files")
    print("=" * 80)
    
    try:
        # Load credentials
        creds = load_credentials()
        if not creds:
            return
        
        # Ensure output directory exists (use absolute path)
        script_dir = os.path.dirname(os.path.abspath(__file__))
        if base_dir == "scrip_masters": 
            base_dir = os.path.join(script_dir, "scrip_masters")
        
        os.makedirs(base_dir, exist_ok=True)
        abs_output = os.path.abspath(base_dir)
        print(f"[DIR] Output directory: {abs_output}")
        
        # Clean up old files FIRST (before downloading new ones)
        cleanup_old_files(base_dir)
        
        # Login and get session
        session_info = login_and_get_session(creds)
        if not session_info:
            print("[ERROR] Failed to login")
            return
        
        # Get scrip master URLs
        ucc = creds.get('KOTAK_UCC')
        consumer_key = creds.get('KOTAK_CONSUMER_KEY')
        consumer_secret = creds.get('KOTAK_CONSUMER_SECRET')  # May be None
        file_urls = get_scrip_master_urls(
            session_info["session_token"], 
            session_info["base_url"], 
            ucc,
            full_data=session_info.get("full_data"),
            consumer_key=consumer_key,
            consumer_secret=consumer_secret
        )
        if not file_urls:
            print("[ERROR] Failed to get scrip master URLs")
            return
        
        # Segment mapping for display names
        segment_names = {
            "nse_cm": "NSE Cash",
            "nse_fo": "NSE F&O",
            "nse_cd": "NSE Currency",
            "cde_fo": "CDE F&O",
            "bse_cm": "BSE Cash",
            "bse_fo": "BSE F&O",
            "mcx": "MCX",
            "mcx_fo": "MCX F&O",
            "bcs_fo": "BCS F&O"
        }
        
        today_str = datetime.now().strftime("%Y%m%d")
        success_count = 0
        failure = []
        
        print("\n" + "=" * 60)
        print("Step 3: Downloading CSV Files")
        print("=" * 60)
        
        # Download each file
        for url in file_urls:
            # Determine segment from URL
            seg_code = None
            seg_name = None
            
            # Extract segment code from URL
            url_lower = url.lower()
            for seg, name in segment_names.items():
                if seg in url_lower:
                    seg_code = seg
                    seg_name = name
                    break
            
            if not seg_code:
                # Try to extract from filename
                filename = os.path.basename(url)
                seg_code = filename.replace(".csv", "").lower()
                seg_name = seg_code.upper()
            
            print(f"\n[DATA] {seg_name or 'Unknown'} ({seg_code or 'unknown'})...")
            print(f"   URL: {url}")
            
            # Desired filename for today
            filename_today = os.path.join(base_dir, f"{seg_code}_scrip_master_{today_str}.csv")
            
            # Get today's date for comparison (only date, no time)
            today_date = datetime.now().date()
            
            # Check if today's file already exists (by filename date or modification date)
            file_exists_today = False
            files_to_delete = []
            
            # Check all existing files for this segment
            try:
                for existing_name in os.listdir(base_dir):
                    if existing_name.startswith(f"{seg_code}_scrip_master_") and existing_name.endswith(".csv"):
                        existing_path = os.path.join(base_dir, existing_name)
                        
                        # Check if file was modified today (using file's modification time)
                        file_mod_time = datetime.fromtimestamp(os.path.getmtime(existing_path))
                        file_mod_date = file_mod_time.date()
                        
                        # Also check if filename contains today's date
                        file_date_in_name = None
                        try:
                            # Extract date from filename: {seg_code}_scrip_master_{YYYYMMDD}.csv
                            date_part = existing_name.replace(f"{seg_code}_scrip_master_", "").replace(".csv", "")
                            if len(date_part) == 8 and date_part.isdigit():
                                file_date_in_name = datetime.strptime(date_part, "%Y%m%d").date()
                        except:
                            pass
                        
                        # If file was modified today OR filename has today's date, skip download
                        if file_mod_date == today_date or file_date_in_name == today_date:
                            file_exists_today = True
                            file_size = os.path.getsize(existing_path)
                            print(f"[SKIP]  Today's file already exists: {existing_name} ({file_size:,} bytes)")
                            print(f"    Modified: {file_mod_time.strftime('%Y-%m-%d %H:%M:%S')}")
                            # If it's not the expected filename, rename it to today's filename
                            if existing_name != os.path.basename(filename_today) and file_date_in_name != today_date:
                                try:
                                    os.rename(existing_path, filename_today)
                                    print(f"    [OK] Renamed to: {os.path.basename(filename_today)}")
                                except Exception as rename_err:
                                    print(f"    [WARN]  Could not rename: {rename_err}")
                        else:
                            # File is from a previous date, mark for deletion
                            files_to_delete.append((existing_name, existing_path, file_mod_date))
            
            except Exception as check_err:
                print(f"[WARN]  Error checking existing files: {check_err}")
            
            # If today's file exists, skip download
            if file_exists_today:
                success_count += 1
                # Still delete old files if any
                if files_to_delete:
                    for old_name, old_path, old_date in files_to_delete:
                        try:
                            os.remove(old_path)
                            print(f"[CLEAN] Deleted old file: {old_name} (date: {old_date})")
                        except Exception as del_err:
                            print(f"[WARN]  Could not delete {old_name}: {del_err}")
                continue
            
            # Delete any older files for this segment (files from previous dates)
            for old_name, old_path, old_date in files_to_delete:
                try:
                    os.remove(old_path)
                    print(f"[CLEAN] Deleted old file: {old_name} (date: {old_date})")
                except Exception as del_err:
                    print(f"[WARN]  Could not delete {old_name}: {del_err}")
            
            # Determine if this file needs retry logic (nse_fo and bse_fo only)
            needs_retry = seg_code in ["nse_fo", "bse_fo"]
            max_retries = 3 if needs_retry else 1
            retry_delay = 2  # seconds
            
            download_success = False
            last_error = None
            
            for attempt in range(max_retries):
                try:
                    if attempt > 0:
                        print(f"[RETRY] Retry attempt {attempt + 1}/{max_retries} for {seg_code}...")
                        time.sleep(retry_delay)
                    
                    # Download and save new CSV for today
                    if attempt == 0:
                        print("[DOWN] Downloading...")
                    
                    resp = requests.get(url, timeout=60, verify=not ALLOW_INSECURE_SSL)
                    resp.raise_for_status()
                    content = resp.text
                    
                    with open(filename_today, 'w', encoding='utf-8') as f:
                        f.write(content)
                    
                    # Count lines and size
                    line_count = len(content.splitlines())
                    file_size = len(content)
                    print(f"[SAVE] Saved: {os.path.basename(filename_today)}")
                    print(f"   Size: {file_size:,} bytes, {line_count:,} lines")
                    
                    if attempt > 0:
                        print(f"[OK] Successfully downloaded on retry attempt {attempt + 1}")
                    
                    success_count += 1
                    download_success = True
                    break  # Success, exit retry loop
                    
                except Exception as seg_err:
                    last_error = seg_err
                    if attempt < max_retries - 1:
                        print(f"[WARN]  Attempt {attempt + 1} failed: {seg_err}")
                    else:
                        print(f"[ERROR] Failed after {max_retries} attempts: {seg_err}")
            
            # If all retries failed, add to failure list
            if not download_success:
                failure.append((url, str(last_error)))
        
        print("\n" + "=" * 80)
        print(f"[OK] Download Complete!")
        print(f"   [OK] Successfully downloaded: {success_count} files")
        print(f"   [ERROR] Failed: {len(failure)} files")
        print(f"   [DIR] Output: {abs_output}")
        
        # Check if any important file failed (ignore nse_cd)
        important_failures = []
        if failure:
            print("\nFailed downloads:")
            for url, reason in failure:
                filename = os.path.basename(url).lower()
                print(f"   • {filename}: {reason}")
                if "nse_cd" not in filename:
                    important_failures.append(filename)
        
        if important_failures:
            print(f"\n[CRITICAL] {len(important_failures)} important file(s) failed to download.")
            return False
        
        return True
        
    except Exception as e:
        print(f"[ERROR] Error: {e}")
        import traceback
        traceback.print_exc()
        return False


def main():
    """Main function"""
    import argparse
    parser = argparse.ArgumentParser(description="Download Kotak Neo Scrip Master CSV files")
    parser.add_argument("--output", "-o", default="scrip_masters", help="Output directory (default: scrip_masters)")
    parser.add_argument("--credentials", "-c", help="Path to b.txt credentials file")
    args = parser.parse_args()
    
    if not download_fno_scrip_master(base_dir=args.output):
        sys.exit(1)


if __name__ == "__main__":
    main()

