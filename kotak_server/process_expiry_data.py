#!/usr/bin/env python3
"""
Process NIFTY and SENSEX Expiry Data
Combined script to process both NIFTY (NSE F&O) and SENSEX (BSE F&O) expiry data
Automatically selects current/nearest expiry and deletes old output files
Server-ready: No interactive input required
"""

import os
import sys
import glob
import pandas as pd
import re
import argparse
import json
from datetime import datetime

# Optional Redis support
try:
    import redis
    HAS_REDIS = True
except ImportError:
    HAS_REDIS = False


def find_csv_for_today_or_latest(base_dir='scrip_masters', segment='nse_fo'):
    """Find today's CSV file or the latest available one"""
    today_str = datetime.now().strftime('%Y%m%d')
    today_pattern = os.path.join(base_dir, f"{segment}_scrip_master_{today_str}.csv")
    if os.path.exists(today_pattern):
        return today_pattern
    # Fallback to most recent matching file
    pattern = os.path.join(base_dir, f"{segment}_scrip_master_*.csv")
    candidates = glob.glob(pattern)
    if not candidates:
        raise FileNotFoundError(f"No scrip master CSV found in {base_dir} for segment {segment}")
    # Sort by date portion in filename and take latest
    def extract_date_key(path):
        name = os.path.basename(path)
        try:
            date_str = name.split('_')[-1].split('.')[0]
            return datetime.strptime(date_str, '%Y%m%d')
        except Exception:
            return datetime.min
    candidates.sort(key=extract_date_key)
    return candidates[-1]


def extract_strike_price(scrip_ref_key, symbol_name):
    """Extract strike price from pScripRefKey based on symbol"""
    if symbol_name == 'NIFTY':
        match = re.search(r'NIFTY\d{2}[A-Z]{3}\d{2}(\d+)\.\d+(CE|PE)$', scrip_ref_key)
    elif symbol_name == 'SENSEX':
        match = re.search(r'SENSEX\d{2}[A-Z]{3}\d{2}(\d+)\.\d+(CE|PE)$', scrip_ref_key)
    else:
        return None
    
    if match:
        strike_price_str = match.group(1)
        return int(strike_price_str)
    return None


def extract_expiry(scrip_ref_key, symbol_name):
    """Extract expiry from pScripRefKey based on symbol"""
    if symbol_name == 'NIFTY':
        match = re.search(r'NIFTY(\d{2}[A-Z]{3}\d{2})', scrip_ref_key)
    elif symbol_name == 'SENSEX':
        match = re.search(r'SENSEX(\d{2}[A-Z]{3}\d{2})', scrip_ref_key)
    else:
        return None
    
    if match:
        return match.group(1)
    return None


def parse_expiry_to_datetime(expiry_str):
    """Parse expiry string to datetime"""
    try:
        return datetime.strptime(expiry_str, '%d%b%y')
    except:
        return None


def auto_select_current_expiry(expiry_list):
    """Automatically select the current/nearest future expiry"""
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    
    # Filter to only future expiries
    future_expiries = [(exp_str, exp_date) for exp_str, exp_date in expiry_list if exp_date >= today]
    
    if not future_expiries:
        # If no future expiries, use the latest one (closest to today)
        future_expiries = sorted(expiry_list, key=lambda x: x[1], reverse=True)[:1]
    
    if not future_expiries:
        return None, None
    
    # Select the earliest future expiry (current expiry)
    selected_expiry_str, selected_expiry_date = min(future_expiries, key=lambda x: x[1])
    return selected_expiry_str, selected_expiry_date


def cleanup_old_output_files(output_dir, symbol_name):
    """Delete all old output CSV files, keeping only today's files"""
    if not os.path.exists(output_dir):
        return
    
    today_date = datetime.now().date()
    today_str = datetime.now().strftime('%Y%m%d')
    deleted_count = 0
    deleted_size = 0
    
    # Pattern depends on symbol
    if symbol_name == 'NIFTY':
        pattern = os.path.join(output_dir, f"nifty_expiry_*.csv")
    elif symbol_name == 'SENSEX':
        pattern = os.path.join(output_dir, f"sensex_bse_expiry_*.csv")
    else:
        return
    
    try:
        candidates = glob.glob(pattern)
        
        for file_path in candidates:
            filename = os.path.basename(file_path)
            
            # Extract date from filename
            file_date = None
            try:
                # Format: nifty_expiry_{YYYYMMDD}_{expiry}.csv or sensex_bse_expiry_{YYYYMMDD}_{expiry}.csv
                parts = filename.replace('.csv', '').split('_')
                if symbol_name == 'NIFTY' and len(parts) >= 3:
                    # nifty_expiry_date_expiry
                    date_str = parts[2] if len(parts) > 2 else None
                elif symbol_name == 'SENSEX' and len(parts) >= 4:
                    # sensex_bse_expiry_date_expiry
                    date_str = parts[3] if len(parts) > 3 else None
                else:
                    date_str = None
                
                if date_str and len(date_str) == 8 and date_str.isdigit():
                    file_date = datetime.strptime(date_str, '%Y%m%d').date()
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
                    print(f"  🧹 Deleted old file: {filename} (date: {file_date}, size: {file_size:,} bytes)")
                except Exception as del_err:
                    print(f"  ⚠️  Could not delete {filename}: {del_err}")
        
        if deleted_count > 0:
            print(f"  \u2713 Cleanup complete: Deleted {deleted_count} old file(s), freed {deleted_size:,} bytes")
        else:
            print(f"  \u2713 No old files to clean up for {symbol_name}")
            
    except Exception as e:
        print(f"  \u26a0\ufe0f  Error during cleanup for {symbol_name}: {e}")


def store_in_redis(symbol_name, df, redis_host='localhost', redis_port=6379):
    """Store the processed expiry data in Redis"""
    if not HAS_REDIS:
        print(f"  \u26a0\ufe0f  Redis library not installed. Skipping Redis storage for {symbol_name}.")
        return False
    
    try:
        r = redis.Redis(host=redis_host, port=redis_port, db=0, decode_responses=True)
        # Test connection
        r.ping()
        
        # Key format: kotak:expiry:nifty
        redis_key = f"kotak:expiry:{symbol_name.lower()}"
        
        # Convert DataFrame to list of dictionaries
        data_list = df.to_dict(orient='records')
        
        # Store as JSON string
        r.set(redis_key, json.dumps(data_list))
        print(f"  \u2705 Stored {len(data_list)} rows in Redis key: {redis_key}")
        return True
    except Exception as e:
        print(f"  \u26a0\ufe0f  Redis error for {symbol_name}: {e}")
        return False


def process_symbol(symbol_name, segment, base_dir='scrip_masters', output_dir='outputs', redis_host='localhost', redis_port=6379):
    """Process a single symbol (NIFTY or SENSEX)"""
    print("\n" + "=" * 80)
    print(f"Processing {symbol_name} ({segment})")
    print("=" * 80)
    
    # Find and read CSV
    try:
        csv_path = find_csv_for_today_or_latest(base_dir=base_dir, segment=segment)
        print(f"📖 Reading CSV: {csv_path}")
        df = pd.read_csv(csv_path)
    except FileNotFoundError as e:
        print(f"❌ {e}")
        return False
    
    # Check required columns
    required_columns = ['pSymbolName', 'pSymbol', 'pOptionType', 'pScripRefKey']
    missing_columns = [col for col in required_columns if col not in df.columns]
    if missing_columns:
        print(f"❌ Error: Missing required columns: {missing_columns}")
        return False
    
    # Filter for symbol rows
    symbol_rows = df[df['pSymbolName'] == symbol_name]
    print(f"📊 Found {len(symbol_rows)} {symbol_name} rows in CSV")
    
    if len(symbol_rows) == 0:
        print(f"❌ Error: No {symbol_name} rows found in the CSV file")
        return False
    
    # Select columns
    result = symbol_rows[['pSymbol', 'pOptionType', 'pScripRefKey']].copy()
    
    # Extract strike price and expiry
    result['Strike Price'] = result['pScripRefKey'].apply(lambda x: extract_strike_price(x, symbol_name))
    result['Expiry'] = result['pScripRefKey'].apply(lambda x: extract_expiry(x, symbol_name))
    result['ExpiryDate'] = result['Expiry'].apply(parse_expiry_to_datetime)
    
    # Filter out rows where parsing failed
    result = result[result['ExpiryDate'].notna()].copy()
    
    if len(result) == 0:
        print(f"❌ Error: Could not parse any valid expiry dates from {symbol_name} rows")
        return False
    
    # Get unique expiry dates
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    unique_expiries = result[['Expiry', 'ExpiryDate']].drop_duplicates().sort_values('ExpiryDate')
    
    # Display available expiries
    print(f"\n📅 Available Expiry Dates for {symbol_name}:")
    print(f"{'Expiry':<15} {'Date':<15} {'Status':<15}")
    print("-" * 50)
    
    expiry_list = []
    for _, row in unique_expiries.iterrows():
        expiry_str = row['Expiry']
        expiry_date = row['ExpiryDate']
        status = "Future" if expiry_date >= today else "Past"
        date_str = expiry_date.strftime('%Y-%m-%d')
        print(f"{expiry_str:<15} {date_str:<15} {status:<15}")
        expiry_list.append((expiry_str, expiry_date))
    
    # Auto-select current expiry (no user input)
    selected_expiry_str, selected_expiry_date = auto_select_current_expiry(expiry_list)
    
    if not selected_expiry_str or not selected_expiry_date:
        print(f"❌ Error: Could not select expiry for {symbol_name}")
        return False
    
    print(f"\n✅ Auto-selected current expiry: {selected_expiry_str} ({selected_expiry_date.strftime('%Y-%m-%d')})")
    
    # Clean up old files FIRST
    print(f"\n🧹 Cleaning up old output files for {symbol_name}...")
    cleanup_old_output_files(output_dir, symbol_name)
    
    # Prepare output directory and filename
    os.makedirs(output_dir, exist_ok=True)
    today_str = datetime.now().strftime('%Y%m%d')
    today_date = datetime.now().date()
    
    if symbol_name == 'NIFTY':
        output_filename = f"nifty_expiry_{today_str}_{selected_expiry_str}.csv"
    elif symbol_name == 'SENSEX':
        output_filename = f"sensex_bse_expiry_{today_str}_{selected_expiry_str}.csv"
    else:
        output_filename = f"{symbol_name.lower()}_expiry_{today_str}_{selected_expiry_str}.csv"
    
    output_path = os.path.join(output_dir, output_filename)
    
    # Check if today's file already exists
    file_exists_today = False
    if os.path.exists(output_path):
        file_mod_time = datetime.fromtimestamp(os.path.getmtime(output_path))
        file_mod_date = file_mod_time.date()
        if file_mod_date == today_date:
            file_exists_today = True
            file_size = os.path.getsize(output_path)
            print(f"\n⏭️  Today's output file already exists: {output_filename} ({file_size:,} bytes)")
            print(f"    Modified: {file_mod_time.strftime('%Y-%m-%d %H:%M:%S')}")
    
    # If today's file exists, load it
    if file_exists_today:
        try:
            result = pd.read_csv(output_path)
            print(f"✅ Loaded existing file: {output_filename}")
            print(f"   Total rows: {len(result)}")
        except Exception as load_err:
            print(f"⚠️  Could not load existing file: {load_err}")
            print("   Will process new file instead...")
            file_exists_today = False
    
    # Process if file doesn't exist
    if not file_exists_today:
        # Filter to selected expiry
        result = result[result['ExpiryDate'] == selected_expiry_date].copy()
        
        # Sort by Strike Price
        result = result.sort_values('Strike Price')
        
        # Drop ExpiryDate column
        if 'ExpiryDate' in result.columns:
            result = result.drop(columns=['ExpiryDate'])
        
        # Save to CSV
        result.to_csv(output_path, index=False, encoding='utf-8')
        print(f"\n💾 Saved CSV: {output_path}")
        print(f"   Total rows: {len(result)}")
    else:
        # If loading existing file, filter to selected expiry just in case
        result = result[result['Expiry'] == selected_expiry_str].copy()
        result = result.sort_values('Strike Price')
        if 'ExpiryDate' in result.columns:
            result = result.drop(columns=['ExpiryDate'])
    
    # Store in Redis
    print(f"\n\U0001f4e6 Storing in Redis for {symbol_name}...")
    store_in_redis(symbol_name, result, redis_host=redis_host, redis_port=redis_port)
    
    # Display summary
    print(f'\n📊 {symbol_name} rows for SELECTED EXPIRY: {selected_expiry_str}')
    print('=' * 80)
    print(f"{'Row':<4} {'pSymbol':<8} {'pOptionType':<12} {'Strike Price':<12} {'Expiry':<10} {'pScripRefKey':<30}")
    print('-' * 80)
    
    # Show first 10 rows as sample
    for i, (idx, row) in enumerate(result.head(10).iterrows(), 1):
        print(f"{i:<4} {row['pSymbol']:<8} {row['pOptionType']:<12} {row['Strike Price']:<12} {row['Expiry']:<10} {row['pScripRefKey']:<30}")
    
    if len(result) > 10:
        print(f"... and {len(result) - 10} more rows")
    
    print('=' * 80)
    print(f'Total rows for selected expiry ({selected_expiry_str}): {len(result)}')
    
    return True


def main():
    """Main function"""
    parser = argparse.ArgumentParser(description="Process NIFTY and SENSEX expiry data")
    parser.add_argument("--scrip-dir", "-s", default="scrip_masters", help="Directory containing scrip master CSVs (default: scrip_masters)")
    parser.add_argument("--output-dir", "-o", default="outputs", help="Output directory (default: outputs)")
    parser.add_argument("--nifty-only", action="store_true", help="Process only NIFTY")
    parser.add_argument("--sensex-only", action="store_true", help="Process only SENSEX")
    parser.add_argument("--redis-host", default="localhost", help="Redis host (default: localhost)")
    parser.add_argument("--redis-port", type=int, default=6379, help="Redis port (default: 6379)")
    args = parser.parse_args()
    
    print("=" * 80)
    print("NIFTY & SENSEX Expiry Data Processor")
    print("=" * 80)
    print(f"📁 Scrip master directory: {args.scrip_dir}")
    print(f"📁 Output directory: {args.output_dir}")
    
    success_count = 0
    
    # Process NIFTY
    if not args.sensex_only:
        if process_symbol('NIFTY', 'nse_fo', base_dir=args.scrip_dir, output_dir=args.output_dir, redis_host=args.redis_host, redis_port=args.redis_port):
            success_count += 1
    
    # Process SENSEX
    if not args.nifty_only:
        if process_symbol('SENSEX', 'bse_fo', base_dir=args.scrip_dir, output_dir=args.output_dir, redis_host=args.redis_host, redis_port=args.redis_port):
            success_count += 1
    
    print("\n" + "=" * 80)
    print(f"✅ Processing Complete!")
    print(f"   ✅ Successfully processed: {success_count} symbol(s)")
    print("=" * 80)


if __name__ == "__main__":
    main()

