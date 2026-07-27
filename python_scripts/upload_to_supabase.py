import os
import glob
import csv
import requests

SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://lztwmrthpdkeeguedvqh.supabase.co")
# Service key is needed for DELETE+INSERT operations (anon key is read-only for destructive ops)
SUPABASE_KEY = os.environ.get("SUPABASE_SERVICE_KEY") or os.environ.get("SUPABASE_ANON_KEY", "sb_publishable_mSbAij70Af_IiloKZPnIgg_pm5Dkz8w")

def normalize_header(header):
    return header.strip().replace(';', '').lower()

def upload_segment_file(filepath):
    filename = os.path.basename(filepath)
    print(f"\nProcessing file: {filename}")
    
    # Extract segment code from filename (e.g. nse_fo_scrip_master_20260725.csv -> nse_fo)
    parts = filename.split('_scrip_master_')
    if len(parts) < 2:
        print(f"Skipping file with unrecognized format: {filename}")
        return
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
            return
        
        # 1. Delete existing records for this segment in Supabase
        delete_url = f"{SUPABASE_URL}/rest/v1/scrip_master?exch_seg=eq.{exch_seg_code}"
        headers = {
            "apikey": SUPABASE_KEY,
            "Authorization": f"Bearer {SUPABASE_KEY}"
        }
        print(f"Clearing old records for segment '{exch_seg_code}' in Supabase...")
        del_resp = requests.delete(delete_url, headers=headers)
        if del_resp.status_code not in [200, 204]:
            print(f"⚠️ Warning: Failed to clear old records: {del_resp.status_code} - {del_resp.text}")
        else:
            print("✓ Old records cleared successfully.")
        
        # 2. Bulk insert new records in batches
        insert_url = f"{SUPABASE_URL}/rest/v1/scrip_master"
        headers["Content-Type"] = "application/json"
        
        batch_size = 2000
        total_inserted = 0
        
        for i in range(0, len(records), batch_size):
            batch = records[i:i+batch_size]
            resp = requests.post(insert_url, headers=headers, json=batch)
            if resp.status_code not in [200, 201]:
                print(f"❌ Failed to insert batch {i//batch_size + 1}: {resp.status_code} - {resp.text}")
                break
            total_inserted += len(batch)
            print(f"   Uploaded {total_inserted:,} / {len(records):,} rows...")
            
        print(f"✓ Uploaded {total_inserted:,} records for '{exch_seg_code}' to Supabase successfully!")
        
    except Exception as e:
        print(f"❌ Error uploading {filename}: {e}")

def main():
    base_dir = "scrip_masters"
    csv_files = glob.glob(os.path.join(base_dir, "*_scrip_master_*.csv"))
    if not csv_files:
        print("No CSV files found in scrip_masters directory.")
        return
    
    print(f"Found {len(csv_files)} files to upload.")
    for filepath in csv_files:
        upload_segment_file(filepath)

if __name__ == '__main__':
    main()
