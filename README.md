# Kotak Neo Order

A Flutter mobile application and Python CLI tool for placing orders on Kotak Neo trading platform using the REST API.

This repository contains:
- 📱 **Flutter Mobile App** - Cross-platform mobile application for iOS and Android
- 🐍 **Python CLI Tool** - Command-line interface for automated order placement

## Features

- 🔐 Secure credential management with local storage
- 📱 Modern, intuitive UI for order placement
- 🔄 TOTP-based authentication
- 🛡️ Dry-run mode for testing orders before execution
- 📊 Support for multiple exchange segments (NSE, BSE, MCX, etc.)
- 💼 Multiple product types (MIS, NRML, CNC, CO, BO)
- 📈 Multiple order types (Market, Limit, Stop Loss)

## Prerequisites

### For Flutter Mobile App
- Flutter SDK (3.9.2 or higher)
- Android Studio / Xcode (for mobile development)

### For Python CLI Tool
- Python 3.7 or higher
- pip (Python package manager)

### Required Credentials (for both)
- Kotak Neo API credentials:
  - Consumer Key
  - Mobile Number
  - MPIN
  - UCC
  - TOTP Secret

## Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd kotak_neo_order
```

### Flutter Mobile App

2. Install Flutter dependencies:
```bash
flutter pub get
```

3. Run the app:
```bash
flutter run
```

### Python CLI Tool

2. Install Python dependencies:
```bash
pip install -r requirements.txt
```

3. Configure credentials:
```bash
# Copy the example credentials file
cp b.txt.example b.txt

# Edit b.txt with your actual credentials
# DO NOT commit b.txt to version control
```

4. Run the CLI tool:
```bash
python place_order_cli_no_sdk.py --help
```

## Setup

### Flutter Mobile App - First Time Setup

1. **Configure Credentials:**
   - When you first launch the app, you'll be prompted to enter your Kotak Neo API credentials
   - Fill in all required fields:
     - Consumer Key
     - Mobile Number (10 digits, without country code)
     - MPIN
     - UCC
     - TOTP Secret
     - Neo Fin Key (optional, defaults to "neotradeapi")

2. **Credentials are stored securely** on your device using SharedPreferences

### Python CLI Tool - First Time Setup

1. **Configure Credentials:**
   - Copy `b.txt.example` to `b.txt`
   - Edit `b.txt` with your actual credentials:
     ```ini
     KOTAK_CONSUMER_KEY = "your-consumer-key"
     KOTAK_MOBILE_NUMBER = "your-10-digit-mobile"
     KOTAK_MPIN = "your-mpin"
     KOTAK_UCC = "your-ucc"
     KOTAK_TOTP_SECRET = "your-totp-secret"
     KOTAK_NEO_FIN_KEY = "neotradeapi"  # Optional
     DRY_RUN = true  # Set to false for live orders
     ```

2. **Test with dry-run:**
   - By default, the CLI runs in DRY-RUN mode
   - Use `--yes` flag to place actual orders

### Flutter Mobile App - Placing Orders

1. **Navigate to Order Placement Screen:**
   - The app will automatically show the order placement screen if credentials are configured

2. **Fill Order Details:**
   - **Exchange Segment:** Select from dropdown (nse_cm, nse_fo, bse_cm, etc.)
   - **Trading Symbol:** Enter the symbol (e.g., NIFTY25NOVFUT, NIFTY04NOV2525700.00PE)
   - **Transaction Type:** Select BUY or SELL
   - **Product:** Select product type (MIS, NRML, CNC, CO, BO)
   - **Order Type:** Select order type (MKT, L, SL, SL-M)
   - **Quantity:** Enter quantity
   - **Price:** Required for Limit orders, optional for Market orders
   - **Tag:** Optional custom tag

3. **Dry Run Mode:**
   - By default, the app runs in DRY RUN mode
   - Toggle the switch to enable LIVE mode for actual order placement
   - In DRY RUN mode, you'll see a preview before placing the order

4. **Place Order:**
   - Click "Preview Order" (in DRY RUN) or "Place Order" (in LIVE mode)
   - The app will:
     - Generate TOTP code
     - Authenticate with Kotak Neo API
     - Place the order
     - Show the result

### Python CLI Tool - Placing Orders

The CLI tool allows you to place orders from the command line, making it ideal for automation and scripting.

**Basic Usage:**
```bash
# Market Buy Order (Dry Run)
python place_order_cli_no_sdk.py \
    --segment nse_fo \
    --symbol NIFTY25NOVFUT \
    --tt B \
    --product MIS \
    --order MKT \
    --qty 50

# Limit Sell Order (Dry Run)
python place_order_cli_no_sdk.py \
    --segment nse_fo \
    --symbol NIFTY04NOV2525700.00PE \
    --tt S \
    --product MIS \
    --order L \
    --price 100.5 \
    --qty 50

# Place Actual Order (use --yes flag)
python place_order_cli_no_sdk.py \
    --segment nse_fo \
    --symbol NIFTY25NOVFUT \
    --tt B \
    --product MIS \
    --order MKT \
    --qty 50 \
    --yes
```

**Command Line Arguments:**
- `--segment` (required): Exchange segment (e.g., nse_fo, nse_cm, bse_cm)
- `--symbol` (required): Trading symbol (e.g., NIFTY25NOVFUT, NIFTY04NOV2525700.00PE)
- `--tt` (required): Transaction type - B (Buy) or S (Sell)
- `--product` (optional): Product type (MIS, NRML, CNC) - defaults to MIS
- `--order` (required): Order type (MKT, L, SL, SL-M)
- `--qty` (required): Quantity
- `--price` (optional): Price (required for Limit orders)
- `--tag` (optional): Custom tag for the order
- `--yes`: Actually place the order (disable dry-run)

**Examples:**
```bash
# Market order for NIFTY futures
python place_order_cli_no_sdk.py --segment nse_fo --symbol NIFTY25NOVFUT --tt B --product MIS --order MKT --qty 50 --yes

# Limit order for options
python place_order_cli_no_sdk.py --segment nse_fo --symbol NIFTY04NOV2525700.00PE --tt S --product MIS --order L --price 100.5 --qty 50 --yes

# Stop loss order
python place_order_cli_no_sdk.py --segment nse_fo --symbol NIFTY25NOVFUT --tt B --product MIS --order SL --price 19500 --qty 50 --yes
```

## API Flow

The app follows the same 3-step authentication flow as the Python CLI:

1. **TOTP Login:** Authenticates using mobile number, UCC, and TOTP code
2. **TOTP Validate:** Validates MPIN and gets edit token
3. **Place Order:** Submits the order using the edit token

## Supported Exchange Segments

- `nse_cm` - NSE Cash Market
- `bse_cm` - BSE Cash Market
- `nse_fo` - NSE Futures & Options
- `bse_fo` - BSE Futures & Options
- `cde_fo` - Currency Derivatives
- `bcs-fo` - BCS Futures & Options
- `mcx` - MCX Commodities

## Supported Products

- **MIS** - Margin Intraday Square-off
- **NRML** - Normal
- **CNC** - Cash and Carry
- **CO** - Cover Order
- **BO** - Bracket Order

## Supported Order Types

- **MKT** - Market Order
- **L** - Limit Order (requires price)
- **SL** - Stop Loss Limit
- **SL-M** - Stop Loss Market

## Security Notes

- Credentials are stored locally on your device
- TOTP codes are generated on-the-fly and never stored
- All API communications use HTTPS
- Consider using device-level encryption for production use

## Troubleshooting

### "Please configure credentials first"
- Go to Settings (gear icon) and enter your credentials

### "TOTP login failed"
- Verify your TOTP secret is correct
- Ensure your mobile number is in the correct format
- Check your internet connection

### "Limit order requires price"
- Enter a price when selecting Limit (L) order type

### Order placement fails
- Verify all credentials are correct
- Check if your account has sufficient balance
- Ensure the trading symbol is correct and tradable

## Building for Production

### Android
```bash
flutter build apk --release
```

### iOS
```bash
flutter build ios --release
```

## Development

### Project Structure

**Flutter Mobile App:**
```
lib/
├── main.dart                 # App entry point
├── models/                   # Data models
│   ├── credentials.dart
│   └── order_request.dart
├── services/                 # Business logic
│   ├── credentials_service.dart
│   └── kotak_api_service.dart
└── screens/                  # UI screens
    ├── credentials_screen.dart
    └── order_placement_screen.dart
```

**Python CLI Tool:**
```
place_order_cli_no_sdk.py    # Main CLI script
b.txt.example                 # Credentials template
requirements.txt              # Python dependencies
```

## GitHub Setup

To make this project available on GitHub:

1. **Create a new repository on GitHub:**
   - Go to [GitHub](https://github.com) and create a new repository
   - Choose a name (e.g., `kotak-neo-order`)
   - Set it as Public or Private (your choice)
   - **DO NOT** initialize with README, .gitignore, or license (we already have these)

2. **Initialize Git in your project (if not already done):**
   ```bash
   git init
   ```

3. **Add all files (except those in .gitignore):**
   ```bash
   git add .
   ```

4. **Verify that sensitive files are NOT included:**
   ```bash
   # Check that b.txt is NOT in the staging area
   git status
   # You should NOT see b.txt in the list
   ```

5. **Make your first commit:**
   ```bash
   git commit -m "Initial commit: Kotak Neo Order Flutter app and Python CLI"
   ```

6. **Add the remote repository:**
   ```bash
   git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPO_NAME.git
   # Replace YOUR_USERNAME and YOUR_REPO_NAME with your actual values
   ```

7. **Push to GitHub:**
   ```bash
   git branch -M main
   git push -u origin main
   ```

**Important Security Checklist:**
- ✅ Verify `b.txt` is NOT committed (check with `git status`)
- ✅ Verify `android/local.properties` is NOT committed
- ✅ Verify `.gitignore` includes all sensitive files
- ✅ Double-check before pushing to ensure no credentials are exposed

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Security

⚠️ **IMPORTANT:** Never commit your `b.txt` file or any files containing credentials to version control. The `.gitignore` file is configured to exclude sensitive files, but always double-check before committing.

## License

This project is for personal use. Ensure compliance with Kotak Neo API terms of service.

## Disclaimer

This app is provided as-is. Trading involves risk. Use at your own discretion. Always verify orders before placing them in LIVE mode. The authors are not responsible for any financial losses incurred while using this software.
