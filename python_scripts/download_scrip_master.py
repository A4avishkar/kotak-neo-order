#!/usr/bin/env python3
"""
Download F&O Scrip Master CSV Files
Downloads NSE F&O, BSE F&O, and other scrip master data files
Uses URL construction method (no SDK or API calls needed) - reads credentials from b.txt
"""

import os
import json
import requests
import urllib3
import pyotp
from datetime import datetime, timedelta

# Suppress SSL warnings
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
        print("❌ Could not find b.txt file")
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
        
        print(f"✓ Loaded credentials from: {file_path}")
        return credentials
    except Exception as e:
        print(f"❌ Error reading {file_path}: {e}")
        return None


def login_and_get_session(creds):
    """Login using direct API calls and return session token"""
    print("\n" + "=" * 60)
    print("Step 1: Login & Get Session")
    print("=" * 60)
    
    consumer_key = creds.get('KOTAK_CONSUMER_KEY') or creds.get('consumer_key')
    mobile_number = creds.get('KOTAK_MOBILE_NUMBER') or creds.get('mobile_number') or creds.get('mobile')
    mpin = creds.get('KOTAK_MPIN') or creds.get('mpin')
    ucc = creds.get('KOTAK_UCC') or creds.get('ucc') or creds.get('sid')
    totp_secret = creds.get('KOTAK_TOTP_SECRET') or creds.get('totp_secret')
    
    if not all([consumer_key, mobile_number, mpin, ucc]):
        print("❌ Missing required credentials in b.txt")
        return None
    
    # Generate TOTP
    print("Generating TOTP code...")
    totp_code = None
    if totp_secret and totp_secret.strip():
        secret_clean = totp_secret.strip().replace(' ', '').replace('"', '').replace("'", '')
        if secret_clean.isdigit() and len(secret_clean) == 6:
            print("⚠️  You have a TOTP code, not a secret. Using it for this run only.")
            totp_code = secret_clean
        else:
            try:
                totp = pyotp.TOTP(secret_clean)
                totp_code = totp.now()
                print(f"✓ TOTP code generated: {totp_code}")
            except Exception as e:
                print(f"❌ Failed to generate TOTP: {e}")
                totp_input = input("Enter 6-digit TOTP code manually: ").strip()
                if len(totp_input) == 6 and totp_input.isdigit():
                    totp_code = totp_input
                else:
                    return None
    else:
        totp_input = input("Enter 6-digit TOTP code: ").strip()
        if len(totp_input) != 6 or not totp_input.isdigit():
            print("❌ Invalid TOTP code")
            return None
        totp_code = totp_input
    
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
        
        totp_response = requests.post(totp_url, headers=totp_headers, json=totp_payload, timeout=15, verify=False)
        
        if totp_response.status_code != 200:
            print(f"❌ TOTP Login failed: {totp_response.text}")
            return None
        
        totp_data = totp_response.json()
        if totp_data.get("data", {}).get("status") != "success":
            print(f"❌ TOTP Login failed: {totp_data}")
            return None
        
        view_token = totp_data["data"].get("token")
        sid = totp_data["data"].get("sid")
        print("✓ TOTP Login successful")
        
    except Exception as e:
        print(f"❌ TOTP Login error: {e}")
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
        
        mpin_response = requests.post(mpin_url, headers=mpin_headers, json=mpin_payload, timeout=15, verify=False)
        
        if mpin_response.status_code != 200:
            print(f"❌ MPIN Validate failed: {mpin_response.text}")
            return None
        
        session_payload = mpin_response.json()
        if session_payload.get("data", {}).get("status") != "success":
            print(f"❌ MPIN Validate failed: {session_payload}")
            return None
        
        data = session_payload.get("data", {})
        session_token = data.get("token") or data.get("sessionToken")
        base_url = data.get("baseUrl") or "https://mis.kotaksecurities.com"
        
        print("✓ MPIN Validate successful")
        print("✓ Session token obtained")
        
        # Debug: Print full response to understand token structure
        print(f"\n📋 Full MPIN Response Data:")
        print(json.dumps(data, indent=2))
        
        return {
            "session_token": session_token,
            "base_url": base_url,
            "sid": data.get("sid") or sid,
            "full_data": data  # Include full data for debugging
        }
        
    except Exception as e:
        print(f"❌ MPIN Validate error: {e}")
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
            print(f"  📡 Calling API: {api_url}")
            response = requests.get(api_url, headers=headers, timeout=30, verify=False)
            
            if response.status_code == 200:
                data = response.json()
                if "data" in data and "filesPaths" in data["data"]:
                    file_paths = data["data"]["filesPaths"]
                    print(f"  ✓ Got {len(file_paths)} URLs from API")
                    return file_paths
                else:
                    print(f"  ⚠️  Unexpected API response format: {data}")
            elif response.status_code == 401:
                print(f"  ⚠️  Unauthorized (401) - trying next base URL...")
                continue
            else:
                print(f"  ⚠️  API returned {response.status_code}: {response.text[:200]}")
        except Exception as e:
            print(f"  ⚠️  API call failed for {base}: {e}")
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
        print("\n📡 Getting authenticated URLs from API for cash market segments...")
        api_urls = get_scrip_master_urls_from_api(consumer_key, base_url)
        
        if api_urls:
            # Map API URLs to segments
            for url in api_urls:
                url_lower = url.lower()
                for seg_code in auth_segments:
                    if seg_code in url_lower and seg_code not in final_urls:
                        final_urls[seg_code] = url
                        print(f"  ✓ Found {seg_code}: {url}")
    
    # Step 2: Construct direct URLs for F&O segments (and any missing segments)
    print("\n📋 Constructing direct URLs for F&O segments...")
    today = datetime.now().strftime("%Y-%m-%d")
    base_folder = f"https://lapi.kotaksecurities.com/wso2-scripmaster/v1/prod"
    
    for seg_code, filename in all_segments.items():
        if seg_code not in final_urls:
            url = f"{base_folder}/{today}/transformed/{filename}.csv"
            final_urls[seg_code] = url
            print(f"  📋 Constructed {seg_code}: {url}")
    
    # Return URLs in the same order as segments_pattern
    result_urls = [final_urls.get(seg) for seg in all_segments.keys() if seg in final_urls]
    
    if result_urls:
        print(f"\n✓ Got {len(result_urls)} URLs total")
        return result_urls
    
    print("❌ Could not get scrip master URLs.")
    return None


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
        
        # Ensure output directory exists
        os.makedirs(base_dir, exist_ok=True)
        abs_output = os.path.abspath(base_dir)
        print(f"📁 Output directory: {abs_output}")
        
        # Login and get session
        session_info = login_and_get_session(creds)
        if not session_info:
            print("❌ Failed to login")
            raise RuntimeError("Failed to login to Kotak API")
        
        # Get scrip master URLs
        ucc = creds.get('KOTAK_UCC') or creds.get('ucc') or creds.get('sid')
        consumer_key = creds.get('KOTAK_CONSUMER_KEY') or creds.get('consumer_key')
        consumer_secret = creds.get('KOTAK_CONSUMER_SECRET') or creds.get('consumer_secret')
        file_urls = get_scrip_master_urls(
            session_info["session_token"], 
            session_info["base_url"], 
            ucc,
            full_data=session_info.get("full_data"),
            consumer_key=consumer_key,
            consumer_secret=consumer_secret
        )
        if not file_urls:
            print("❌ Failed to get scrip master URLs")
            raise RuntimeError("Failed to get scrip master URLs from Kotak API")
        
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
            try:
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
                
                print(f"\n📊 {seg_name or 'Unknown'} ({seg_code or 'unknown'})...")
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
                                print(f"⏭️  Today's file already exists: {existing_name} ({file_size:,} bytes)")
                                print(f"    Modified: {file_mod_time.strftime('%Y-%m-%d %H:%M:%S')}")
                                # If it's not the expected filename, rename it to today's filename
                                if existing_name != os.path.basename(filename_today) and file_date_in_name != today_date:
                                    try:
                                        os.rename(existing_path, filename_today)
                                        print(f"    ✅ Renamed to: {os.path.basename(filename_today)}")
                                    except Exception as rename_err:
                                        print(f"    ⚠️  Could not rename: {rename_err}")
                            else:
                                # File is from a previous date, mark for deletion
                                files_to_delete.append((existing_name, existing_path, file_mod_date))
                
                except Exception as check_err:
                    print(f"⚠️  Error checking existing files: {check_err}")
                
                # If today's file exists, skip download
                if file_exists_today:
                    success_count += 1
                    # Still delete old files if any
                    if files_to_delete:
                        for old_name, old_path, old_date in files_to_delete:
                            try:
                                os.remove(old_path)
                                print(f"🧹 Deleted old file: {old_name} (date: {old_date})")
                            except Exception as del_err:
                                print(f"⚠️  Could not delete {old_name}: {del_err}")
                    continue
                
                # Delete any older files for this segment (files from previous dates)
                for old_name, old_path, old_date in files_to_delete:
                    try:
                        os.remove(old_path)
                        print(f"🧹 Deleted old file: {old_name} (date: {old_date})")
                    except Exception as del_err:
                        print(f"⚠️  Could not delete {old_name}: {del_err}")
                
                # Download and save new CSV for today
                print("📥 Downloading...")
                resp = requests.get(url, timeout=60, verify=False)
                resp.raise_for_status()
                content = resp.text
                
                with open(filename_today, 'w', encoding='utf-8') as f:
                    f.write(content)
                
                # Count lines and size
                line_count = len(content.splitlines())
                file_size = len(content)
                print(f"💾 Saved: {os.path.basename(filename_today)}")
                print(f"   Size: {file_size:,} bytes, {line_count:,} lines")
                success_count += 1
                
            except Exception as seg_err:
                print(f"❌ Failed: {seg_err}")
                failure.append((url, str(seg_err)))
        
        print("\n" + "=" * 80)
        print(f"✅ Download Complete!")
        print(f"   ✅ Successfully downloaded: {success_count} files")
        print(f"   ❌ Failed: {len(failure)} files")
        print(f"   📁 Output: {abs_output}")
        
        if failure:
            print("\nFailed downloads:")
            for url, reason in failure:
                print(f"   • {os.path.basename(url)}: {reason}")

        # Step 4: Automatically upload to Supabase
        print("\n" + "=" * 80)
        print("Step 4: Syncing with Supabase Database")
        print("=" * 80)
        try:
            import sys
            current_dir = os.path.dirname(os.path.abspath(__file__)) if '__file__' in globals() else os.getcwd()
            if current_dir not in sys.path:
                sys.path.append(current_dir)
            import upload_to_supabase
            # Ensure base_dir from download matches the upload script's base directory
            upload_to_supabase.main()
        except Exception as upload_err:
            print(f"⚠️ Could not trigger Supabase upload: {upload_err}")
        
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()


def main():
    """Main function"""
    import argparse
    parser = argparse.ArgumentParser(description="Download Kotak Neo Scrip Master CSV files")
    parser.add_argument("--output", "-o", default="scrip_masters", help="Output directory (default: scrip_masters)")
    parser.add_argument("--credentials", "-c", help="Path to b.txt credentials file")
    args = parser.parse_args()
    
    download_fno_scrip_master(base_dir=args.output)


if __name__ == "__main__":
    main()

