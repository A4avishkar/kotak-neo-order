import csv
import glob
import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone

import requests

raw_url = os.environ.get("SUPABASE_URL", "").strip().strip('"').strip("'")
if not raw_url or not raw_url.startswith("http"):
    SUPABASE_URL = "https://lztwmrthpdkeeguedvqh.supabase.co"
else:
    SUPABASE_URL = raw_url.rstrip("/")

raw_key = (os.environ.get("SUPABASE_SERVICE_KEY") or os.environ.get("SUPABASE_ANON_KEY", "")).strip().strip('"').strip("'")
SUPABASE_KEY = raw_key if raw_key else "sb_publishable_mSbAij70Af_IiloKZPnIgg_pm5Dkz8w"


def _request_with_retry(method, url, *, headers, json_payload=None, timeout=60, retries=3):
    """Send an HTTP request with simple exponential backoff on transient failures."""
    last_exc = None
    for attempt in range(retries):
        try:
            resp = requests.request(
                method,
                url,
                headers=headers,
                json=json_payload,
                timeout=timeout,
            )
            if resp.status_code < 500 or attempt == retries - 1:
                return resp
            print(f"⚠️  Supabase {method} returned {resp.status_code}, retrying ({attempt + 1}/{retries})...")
        except requests.RequestException as exc:
            last_exc = exc
            if attempt == retries - 1:
                raise
            print(f"⚠️  Supabase {method} error: {exc}, retrying ({attempt + 1}/{retries})...")
        time.sleep(2 ** attempt)
    if last_exc:
        raise last_exc
    raise RuntimeError("Unexpected retry loop exit")


def normalize_header(header):
    return header.strip().replace(';', '').lower()

def upload_segment_file(filepath):
    filename = os.path.basename(filepath)
    print(f"\nProcessing file: {filename}")
    
    # Extract segment code from filename (e.g. nse_fo_scrip_master_20260725.csv -> nse_fo)
    parts = filename.split('_scrip_master_')
    if len(parts) < 2:
        print(f"Skipping file with unrecognized format: {filename}")
        return None
    exch_seg_code = parts[0]
    
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            reader = csv.reader(f)
            headers = next(reader)
            
            # Create a map from normalized header name to index
            header_map = {normalize_header(h): idx for idx, h in enumerate(headers)}
            
            # Find indices for required fields
            idx_token = header_map.get('psymbol')
            idx_symbol_name = header_map.get('psymbolname')
            idx_trading_symbol = header_map.get('ptrdsymbol')
            idx_exch_seg = header_map.get('pexchseg')
            idx_inst_type = header_map.get('pinsttype')
            idx_option_type = header_map.get('poptiontype')
            idx_strike_price = header_map.get('dstrikeprice')
            idx_expiry_date = header_map.get('lexpirydate')
            idx_lot_size = header_map.get('llotsize') or header_map.get('ilotsize')
            
            if idx_token is None or idx_trading_symbol is None:
                print(f"Error: Essential columns (pSymbol, pTrdSymbol) not found in {filename}")
                return
            
            records = []
            for row in reader:
                if not row or len(row) <= max(idx_token, idx_trading_symbol):
                    continue
                
                token = row[idx_token].strip()
                if not token:
                    continue
                
                symbol_name = row[idx_symbol_name].strip() if idx_symbol_name is not None and idx_symbol_name < len(row) else None
                trading_symbol = row[idx_trading_symbol].strip() if idx_trading_symbol < len(row) else None
                exch_seg = row[idx_exch_seg].strip() if idx_exch_seg is not None and idx_exch_seg < len(row) else exch_seg_code
                inst_type = row[idx_inst_type].strip() if idx_inst_type is not None and idx_inst_type < len(row) else None
                option_type = row[idx_option_type].strip() if idx_option_type is not None and idx_option_type < len(row) else None
                
                # Parse strike price (Kotak F&O strikes in CSV are multiplied by 100, e.g. 320000 -> 3200.00)
                strike_price = None
                if idx_strike_price is not None and idx_strike_price < len(row):
                    try:
                        val = row[idx_strike_price].strip()
                        if val and val != '-1':
                            strike_val = float(val)
                            # Convert back to actual strike price format
                            if exch_seg in ['nse_fo', 'bse_fo'] and strike_val >= 10000:
                                strike_price = strike_val / 100.0
                            else:
                                strike_price = strike_val
                    except ValueError:
                        pass
                
                # Parse expiry date
                expiry_date = None
                if idx_expiry_date is not None and idx_expiry_date < len(row):
                    try:
                        val = row[idx_expiry_date].strip()
                        if val and val != '-1':
                            expiry_date = int(val)
                    except ValueError:
                        pass
                
                # Parse lot size
                lot_size = None
                if idx_lot_size is not None and idx_lot_size < len(row):
                    try:
                        val = row[idx_lot_size].strip()
                        if val:
                            lot_size = int(val)
                    except ValueError:
                        pass

                records.append({
                    "token": token,
                    "symbol_name": symbol_name,
                    "trading_symbol": trading_symbol,
                    "exch_seg": exch_seg,
                    "inst_type": inst_type,
                    "option_type": option_type,
                    "strike_price": strike_price,
                    "expiry_date": expiry_date,
                    "lot_size": lot_size
                })
        
        print(f"Parsed {len(records):,} records from {filename}.")

        if not records:
            return (exch_seg_code, 0, False)

        # Delete any exch_seg values present in this CSV (plus filename prefix fallback)
        # so segments like mcx (which store pExchSeg='mcx_fo') don't accumulate stale rows.
        seg_values = sorted({r["exch_seg"] for r in records if r.get("exch_seg")} | {exch_seg_code})

        headers = {
            "apikey": SUPABASE_KEY,
            "Authorization": f"Bearer {SUPABASE_KEY}",
        }
        for seg_val in seg_values:
            delete_url = f"{SUPABASE_URL}/rest/v1/scrip_master?exch_seg=eq.{seg_val}"
            print(f"Clearing old records for segment '{seg_val}' in Supabase...")
            del_resp = _request_with_retry("DELETE", delete_url, headers=headers, timeout=60)
            if del_resp.status_code not in [200, 204]:
                print(f"⚠️ Warning: Failed to clear old records ({seg_val}): {del_resp.status_code} - {del_resp.text}")
            else:
                print(f"✓ Old records cleared successfully ({seg_val}).")

        # 2. Bulk insert new records in batches
        insert_url = f"{SUPABASE_URL}/rest/v1/scrip_master"
        headers["Content-Type"] = "application/json"
        headers["Prefer"] = "return=minimal"

        batch_size = 2000
        total_inserted = 0
        had_failure = False

        for i in range(0, len(records), batch_size):
            batch = records[i:i + batch_size]
            resp = _request_with_retry(
                "POST",
                insert_url,
                headers=headers,
                json_payload=batch,
                timeout=60,
            )
            if resp.status_code not in [200, 201]:
                print(f"❌ Failed to insert batch {i // batch_size + 1}: {resp.status_code} - {resp.text}")
                had_failure = True
                break
            total_inserted += len(batch)
            print(f"   Uploaded {total_inserted:,} / {len(records):,} rows...")

        if had_failure:
            return (exch_seg_code, total_inserted, True)

        print(f"✓ Uploaded {total_inserted:,} records for '{exch_seg_code}' to Supabase successfully!")
        return (exch_seg_code, total_inserted, False)

    except Exception as e:
        print(f"❌ Error uploading {filename}: {e}")
        return (exch_seg_code, 0, True)


def _write_sync_heartbeat(segment_counts):
    """Write a small sync manifest to repo-root scrip_masters/ so GitHub Actions commits a tiny heartbeat."""
    root_scrip_dir = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scrip_masters"))
    if not os.path.isdir(root_scrip_dir):
        return
    now_utc = datetime.now(timezone.utc)
    now_ist = now_utc.astimezone(timezone(timedelta(hours=5, minutes=30)))
    manifest = {
        "date_ist": now_ist.strftime("%Y-%m-%d"),
        "synced_at_ist": now_ist.isoformat(),
        "synced_at_utc": now_utc.isoformat(),
        "total_rows": sum(segment_counts.values()),
        "segments": segment_counts,
    }
    manifest_path = os.path.join(root_scrip_dir, "last_sync.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(f"✓ Updated sync heartbeat: {manifest_path}")


def main():
    base_dir = "scrip_masters"
    csv_files = sorted(glob.glob(os.path.join(base_dir, "*_scrip_master_*.csv")))
    if not csv_files:
        print("No CSV files found in scrip_masters directory.")
        sys.exit(1)

    print(f"Found {len(csv_files)} files to upload.")
    segment_counts = {}
    failed_segments = []

    for filepath in csv_files:
        result = upload_segment_file(filepath)
        if result is None:
            continue
        seg_code, inserted, failed = result
        segment_counts[seg_code] = inserted
        if failed:
            failed_segments.append(seg_code)

    if failed_segments or sum(segment_counts.values()) == 0:
        print(f"❌ Supabase upload incomplete. Failed segments: {failed_segments}")
        sys.exit(1)

    _write_sync_heartbeat(segment_counts)


if __name__ == '__main__':
    main()
