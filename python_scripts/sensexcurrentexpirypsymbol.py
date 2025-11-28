import os
import sys
import glob
import pandas as pd
import re
from datetime import datetime

def find_csv_for_today_or_latest(base_dir='scrip_masters', segment='nse_fo'):
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
        # expected: {segment}_scrip_master_YYYYMMDD.csv
        try:
            date_str = name.split('_')[-1].split('.')[0]
            return datetime.strptime(date_str, '%Y%m%d')
        except Exception:
            return datetime.min
    candidates.sort(key=extract_date_key)
    return candidates[-1]

# Read the CSV file (auto-select today's or latest available)
csv_path = find_csv_for_today_or_latest(segment='bse_fo')
print(f"📖 Reading CSV: {csv_path}")
df = pd.read_csv(csv_path)

# Check if required columns exist
required_columns = ['pSymbolName', 'pSymbol', 'pOptionType', 'pScripRefKey']
missing_columns = [col for col in required_columns if col not in df.columns]
if missing_columns:
    print(f"❌ Error: Missing required columns: {missing_columns}")
    print(f"   Available columns: {list(df.columns)[:10]}...")
    sys.exit(1)

# Filter for SENSEX rows
sensex_rows = df[df['pSymbolName'] == 'SENSEX']
print(f"📊 Found {len(sensex_rows)} SENSEX rows in CSV")

if len(sensex_rows) == 0:
    print("❌ Error: No SENSEX rows found in the CSV file")
    sys.exit(1)

# Select the 3 original columns
result = sensex_rows[['pSymbol', 'pOptionType', 'pScripRefKey']].copy()

# Function to extract strike price from pScripRefKey
def extract_strike_price(scrip_ref_key):
    # Pattern: SENSEX[DDMMMYY][STRIKE].00[CE/PE]
    # Examples: SENSEX04NOV2519350.00PE -> 19350 (not 2519350)
    #          SENSEX30DEC2528800.00PE -> 28800 (not 2528800)
    #          SENSEX11NOV2525000.00PE -> 25000 (not 2525000)
    # First match the expiry pattern (DDMMMYY), then extract the strike price that follows
    match = re.search(r'SENSEX\d{2}[A-Z]{3}\d{2}(\d+)\.\d+(CE|PE)$', scrip_ref_key)
    if match:
        strike_price_str = match.group(1)
        # The strike price comes after the expiry date (DDMMMYY)
        return int(strike_price_str)
    return None

# Function to extract expiry from pScripRefKey
def extract_expiry(scrip_ref_key):
    # Pattern to match date format like 30DEC25, 25NOV25, 11NOV25
    # Examples: SENSEX30DEC2528800.00PE -> 30DEC25
    #          SENSEX25NOV2520550.00PE -> 25NOV25
    #          SENSEX11NOV2525000.00PE -> 11NOV25
    # The expiry comes after SENSEX and before the strike price
    match = re.search(r'SENSEX(\d{2}[A-Z]{3}\d{2})', scrip_ref_key)
    if match:
        expiry_str = match.group(1)
        return expiry_str
    return None

# Function to parse expiry string to datetime
def parse_expiry_to_datetime(expiry_str):
    # Format: 25NOV25 -> November 25, 2025
    # Parse: day (2 digits), month abbreviation (3 letters), year (2 digits)
    try:
        date_obj = datetime.strptime(expiry_str, '%d%b%y')
        return date_obj
    except:
        return None

# Add the new columns
result['Strike Price'] = result['pScripRefKey'].apply(extract_strike_price)
result['Expiry'] = result['pScripRefKey'].apply(extract_expiry)

# Add expiry datetime column for comparison
result['ExpiryDate'] = result['Expiry'].apply(parse_expiry_to_datetime)

# Filter out rows where parsing failed (invalid expiry format)
result = result[result['ExpiryDate'].notna()].copy()

if len(result) == 0:
    print("❌ Error: Could not parse any valid expiry dates from SENSEX rows")
    print("   Please check the pScripRefKey format in the CSV file")
    sys.exit(1)

# Get all unique expiry dates
today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
unique_expiries = result[['Expiry', 'ExpiryDate']].drop_duplicates().sort_values('ExpiryDate')

# Display all available expiry dates
print("\n" + "=" * 100)
print("📅 Available Expiry Dates:")
print("=" * 100)
print(f"{'Index':<8} {'Expiry':<15} {'Date':<15} {'Status':<15}")
print("-" * 100)

expiry_list = []
for idx, (_, row) in enumerate(unique_expiries.iterrows(), 1):
    expiry_str = row['Expiry']
    expiry_date = row['ExpiryDate']
    status = "Future" if expiry_date >= today else "Past"
    date_str = expiry_date.strftime('%Y-%m-%d')
    print(f"{idx:<8} {expiry_str:<15} {date_str:<15} {status:<15}")
    expiry_list.append((expiry_str, expiry_date))

print("=" * 100)

# Ask user to select expiry
if len(expiry_list) == 0:
    print("❌ Error: No expiry dates found")
    sys.exit(1)

while True:
    try:
        user_input = input(f"\n👉 Enter the index (1-{len(expiry_list)}) of the expiry date you want to view: ").strip()
        selected_idx = int(user_input)
        if 1 <= selected_idx <= len(expiry_list):
            selected_expiry_str, selected_expiry_date = expiry_list[selected_idx - 1]
            print(f"\n✅ Selected expiry: {selected_expiry_str} ({selected_expiry_date.strftime('%Y-%m-%d')})")
            break
        else:
            print(f"❌ Please enter a number between 1 and {len(expiry_list)}")
    except ValueError:
        print("❌ Please enter a valid number")
    except KeyboardInterrupt:
        print("\n\n👋 Exiting...")
        sys.exit(0)

# Prepare output directory and filename
output_dir = 'outputs'
os.makedirs(output_dir, exist_ok=True)
today_str = datetime.now().strftime('%Y%m%d')
today_date = datetime.now().date()
output_filename = f"sensex_bse_expiry_{today_str}_{selected_expiry_str}.csv"
output_path = os.path.join(output_dir, output_filename)

# Check if today's output file already exists (by filename date or modification date)
file_exists_today = False
files_to_delete = []

# Check all existing output files
try:
    pattern = os.path.join(output_dir, f"sensex_bse_expiry_*.csv")
    candidates = glob.glob(pattern)
    
    for existing_path in candidates:
        existing_name = os.path.basename(existing_path)
        
        # Check if file was modified today (using file's modification time)
        file_mod_time = datetime.fromtimestamp(os.path.getmtime(existing_path))
        file_mod_date = file_mod_time.date()
        
        # Check if filename contains today's date and selected expiry
        file_date_in_name = None
        try:
            # Extract date from filename: sensex_bse_expiry_{YYYYMMDD}_{expiry}.csv
            if existing_name.startswith(f"sensex_bse_expiry_{today_str}_"):
                file_date_in_name = today_date
        except:
            pass
        
        # If file was modified today OR filename has today's date, check if expiry matches
        if file_mod_date == today_date or file_date_in_name == today_date:
            # Extract expiry from filename: sensex_bse_expiry_{date}_{expiry}.csv
            try:
                parts = existing_name.replace('.csv', '').split('_')
                if len(parts) >= 5:  # sensex_bse_expiry_date_expiry
                    expiry_from_filename = parts[-1]  # Last part is the expiry
                    # Check if it's the same expiry file
                    if selected_expiry_str == expiry_from_filename or selected_expiry_str in existing_name:
                        file_exists_today = True
                        output_path = existing_path  # Use existing file
                        file_size = os.path.getsize(existing_path)
                        print(f"\n⏭️  Today's output file already exists: {existing_name} ({file_size:,} bytes)")
                        print(f"    Modified: {file_mod_time.strftime('%Y-%m-%d %H:%M:%S')}")
                        print(f"    Loading existing file instead of processing...")
                        break
            except:
                # Fallback: if we can't parse, just check if expiry string is in name
                if selected_expiry_str in existing_name:
                    file_exists_today = True
                    output_path = existing_path
                    file_size = os.path.getsize(existing_path)
                    print(f"\n⏭️  Today's output file already exists: {existing_name} ({file_size:,} bytes)")
                    print(f"    Modified: {file_mod_time.strftime('%Y-%m-%d %H:%M:%S')}")
                    print(f"    Loading existing file instead of processing...")
                    break
        else:
            # File is from a previous date, mark for deletion (optional - you may want to keep old files)
            # files_to_delete.append((existing_name, existing_path, file_mod_date))
            pass

except Exception as check_err:
    print(f"⚠️  Error checking existing files: {check_err}")

# If today's file exists, load it and skip processing
if file_exists_today:
    try:
        result = pd.read_csv(output_path)
        print(f"✅ Loaded existing file: {os.path.basename(output_path)}")
        print(f"   Total rows: {len(result)}")
    except Exception as load_err:
        print(f"⚠️  Could not load existing file: {load_err}")
        print("   Will process new file instead...")
        file_exists_today = False

# Delete old files if any
if files_to_delete:
    for old_name, old_path, old_date in files_to_delete:
        try:
            os.remove(old_path)
            print(f"🧹 Deleted old file: {old_name} (date: {old_date})")
        except Exception as del_err:
            print(f"⚠️  Could not delete {old_name}: {del_err}")

# Only process if today's file doesn't exist
if not file_exists_today:
    # Filter to show only the selected expiry
    result = result[result['ExpiryDate'] == selected_expiry_date].copy()
    
    # Sort by Strike Price
    result = result.sort_values('Strike Price')
    
    # Drop the ExpiryDate column as it's no longer needed for display
    result = result.drop(columns=['ExpiryDate'])
    
    # Save output to CSV
    result.to_csv(output_path, index=False, encoding='utf-8')
    print(f"\n💾 Saved CSV: {output_path}")
else:
    # If loading existing file, filter to selected expiry just in case
    result = result[result['Expiry'] == selected_expiry_str].copy()
    result = result.sort_values('Strike Price')
    if 'ExpiryDate' in result.columns:
        result = result.drop(columns=['ExpiryDate'])

print(f'\n📊 SENSEX rows for SELECTED EXPIRY: {selected_expiry_str}')
print('=' * 100)
print(f"{'Row':<4} {'pSymbol':<8} {'pOptionType':<12} {'Strike Price':<12} {'Expiry':<10} {'pScripRefKey':<30}")
print('-' * 100)

for i, (idx, row) in enumerate(result.iterrows(), 1):
    print(f"{i:<4} {row['pSymbol']:<8} {row['pOptionType']:<12} {row['Strike Price']:<12} {row['Expiry']:<10} {row['pScripRefKey']:<30}")

print('=' * 100)
print(f'Total rows for selected expiry ({selected_expiry_str}): {len(result)}')
