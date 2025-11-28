# QuantKey - Kotak Neo Trading Platform

A comprehensive trading solution consisting of a **Flutter mobile app** and **Python CLI scripts** for trading on Kotak Neo platform.

## 📱 Mobile App (QuantKey)

A modern, feature-rich mobile application for iOS and Android that provides real-time market data, order placement, position management, and advanced trading tools.

### Features

- 📊 **Real-time Market Data**: Live Nifty and Sensex quotes with WebSocket support
- 📈 **Option Chain Analysis**: Complete option chain with Open Interest (OI) data
- 💼 **Order Management**: Place, view, and manage orders
- 📍 **Position Tracking**: Monitor your current positions
- ⭐ **Watchlist**: Track your favorite instruments
- 🔍 **Scrip Search**: Search and find trading instruments from scrip master database
- ⚙️ **Settings**: Configure trading hours, OI update intervals, and credentials
- 🔐 **Secure Storage**: Credentials stored securely on device
- 🔄 **Background Services**: Automatic scrip master updates

### Installation & Setup

#### Prerequisites

- Flutter SDK 3.9.2 or higher
- Android Studio (for Android) or Xcode (for iOS)
- Kotak Neo API credentials:
  - Consumer Key
  - Mobile Number (10 digits)
  - MPIN
  - UCC
  - TOTP Secret
  - Neo Fin Key (optional, defaults to "neotradeapi")

#### Installation Steps

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd kotak_neo_order
   ```

2. **Install Flutter dependencies:**
   ```bash
   flutter pub get
   ```

3. **Run the app:**
   ```bash
   flutter run
   ```

   Or build for production:
   ```bash
   # Android
   flutter build apk --release
   
   # iOS
   flutter build ios --release
   ```

### Mobile App Usage Guide

#### First Time Setup

1. **Launch the app** - You'll see the QuantKey splash screen
2. **Enter Credentials** - On first launch, you'll be prompted to enter:
   - Consumer Key
   - Mobile Number (10 digits, without country code)
   - MPIN
   - UCC
   - TOTP Secret
   - Neo Fin Key (optional)
3. **Save** - Credentials are stored securely on your device

#### Main Features

**Dashboard Tab:**
- View live Nifty and Sensex prices
- Monitor Call/Put Open Interest ratios
- Real-time price updates with color-coded changes
- Quick access to search and settings

**Orders Tab:**
- View all your placed orders
- Check order status (Pending, Executed, Cancelled)
- Filter orders by date and status

**Positions Tab:**
- View current open positions
- Monitor P&L (Profit & Loss)
- Check position details

**Watchlist Tab:**
- Add instruments to your watchlist
- Track multiple instruments simultaneously
- Quick access to frequently traded instruments

**Option Chain Tab:**
- View complete option chain for Nifty/Sensex
- Analyze Call and Put options
- Monitor Open Interest changes
- Real-time price updates

**Settings:**
- **Database**: Manage scrip master database
  - Download/update scrip master files
  - Enable background auto-sync
  - View database status
- **Trading Hours**: Set automatic data fetch timing
- **OI Update Interval**: Configure how often Open Interest data refreshes (5-300 seconds)
- **WebSocket Connection**: Enable/disable real-time market data
- **OI & Option Chain Data**: Toggle Open Interest and Option Chain fetching
- **Credentials**: Update your Kotak Neo credentials
- **Terms and Conditions**: View app terms
- **Support Developer**: Support the development

#### Placing Orders

1. Navigate to **Dashboard** tab
2. Tap on any instrument or use **Search** to find a scrip
3. Fill in order details:
   - **Exchange Segment**: Select from dropdown (nse_cm, nse_fo, bse_cm, etc.)
   - **Trading Symbol**: Enter symbol (e.g., NIFTY25NOVFUT)
   - **Transaction Type**: BUY or SELL
   - **Product**: MIS, NRML, CNC, CO, or BO
   - **Order Type**: MKT (Market), L (Limit), SL (Stop Loss), SL-M (Stop Loss Market)
   - **Quantity**: Enter quantity
   - **Price**: Required for Limit orders
   - **Tag**: Optional custom tag
4. Review and place order

#### Database Management

The app uses a local scrip master database for searching instruments:

1. Go to **Settings** → **Database**
2. **Download Scrip Master**: Manually download latest scrip master files
3. **Enable Background Service**: Automatically sync scrip master daily
4. View database status and last update time

---

## 🐍 Python Scripts

A collection of Python CLI tools for automated trading, data fetching, and analysis. All scripts are located in the `python_scripts/` folder.

### Prerequisites

- Python 3.7 or higher
- pip (Python package manager)

### Installation

1. **Navigate to python_scripts folder:**
   ```bash
   cd python_scripts
   ```

2. **Install dependencies:**
   ```bash
   pip install -r requirements.txt
   ```

3. **Configure credentials:**
   
   Create a `b.txt` file in the `python_scripts/` folder with your credentials:
   ```ini
   KOTAK_CONSUMER_KEY = "your-consumer-key"
   KOTAK_MOBILE_NUMBER = "your-10-digit-mobile"
   KOTAK_MPIN = "your-mpin"
   KOTAK_UCC = "your-ucc"
   KOTAK_TOTP_SECRET = "your-totp-secret"
   KOTAK_NEO_FIN_KEY = "neotradeapi"
   DRY_RUN = true
   ```
   
   ⚠️ **Important**: Never commit `b.txt` to version control!

### Available Python Scripts

#### 1. Place Order (`place_order_cli_no_sdk.py`)

Place orders directly from command line.

**Usage:**
```bash
python place_order_cli_no_sdk.py \
    --segment nse_fo \
    --symbol NIFTY25NOVFUT \
    --tt B \
    --product MIS \
    --order MKT \
    --qty 50 \
    --yes
```

**Parameters:**
- `--segment` (required): Exchange segment (nse_fo, nse_cm, bse_cm, etc.)
- `--symbol` (required): Trading symbol
- `--tt` (required): Transaction type - B (Buy) or S (Sell)
- `--product` (optional): Product type (MIS, NRML, CNC) - defaults to MIS
- `--order` (required): Order type (MKT, L, SL, SL-M)
- `--qty` (required): Quantity
- `--price` (optional): Price (required for Limit orders)
- `--tag` (optional): Custom tag
- `--yes`: Actually place order (disable dry-run)

**Examples:**
```bash
# Market Buy Order
python place_order_cli_no_sdk.py --segment nse_fo --symbol NIFTY25NOVFUT --tt B --product MIS --order MKT --qty 50 --yes

# Limit Sell Order
python place_order_cli_no_sdk.py --segment nse_fo --symbol NIFTY04NOV2525700.00PE --tt S --product MIS --order L --price 100.5 --qty 50 --yes

# Stop Loss Order
python place_order_cli_no_sdk.py --segment nse_fo --symbol NIFTY25NOVFUT --tt B --product MIS --order SL --price 19500 --qty 50 --yes
```

#### 2. View Orders (`order_book_cli_no_sdk.py`)

View your order book.

**Usage:**
```bash
python order_book_cli_no_sdk.py
```

#### 3. View Trades (`trade_book_cli_no_sdk.py`)

View your trade book (executed orders).

**Usage:**
```bash
python trade_book_cli_no_sdk.py
```

#### 4. View Positions (`view_positions.py`)

View your current positions.

**Usage:**
```bash
python view_positions.py
```

#### 5. Portfolio Holdings (`portfolio_holdings_cli_no_sdk.py`)

View your portfolio holdings.

**Usage:**
```bash
python portfolio_holdings_cli_no_sdk.py
```

#### 6. Download Scrip Master (`download_scrip_master.py`)

Download latest scrip master files for all exchanges.

**Usage:**
```bash
python download_scrip_master.py
```

This downloads scrip master files to the `scrip_masters/` folder:
- NSE Cash Market (nse_cm)
- NSE Futures & Options (nse_fo)
- BSE Cash Market (bse_cm)
- BSE Futures & Options (bse_fo)
- Currency Derivatives (cde_fo)
- MCX Commodities (mcx)

#### 7. Fetch Option Chain Data (`fetch_all_strikes_data.py`)

Fetch and save option chain data for Nifty.

**Usage:**
```bash
python fetch_all_strikes_data.py
```

Outputs CSV files to `outputs/` folder with:
- Expiry dates
- Strike prices
- Call/Put data
- Open Interest
- Current Market Price

#### 8. Fetch Sensex Option Chain (`fetch_all_strikes_sensex.py`)

Fetch and save option chain data for Sensex.

**Usage:**
```bash
python fetch_all_strikes_sensex.py
```

#### 9. Nifty Live Trading (`nifty_live_standalone.py`)

Standalone script for Nifty live data and trading.

**Usage:**
```bash
python nifty_live_standalone.py
```

#### 10. Get Current Expiry Symbols (`niftycurrentexpirypsymbol.py`, `sensexcurrentexpirypsymbol.py`)

Get current expiry symbols for Nifty and Sensex.

**Usage:**
```bash
python niftycurrentexpirypsymbol.py
python sensexcurrentexpirypsymbol.py
```

#### 11. Trading Loop Script (`run_trading_loop.sh`)

Shell script for running automated trading loops.

**Usage:**
```bash
bash run_trading_loop.sh
```

---

## 📋 Exchange Segments

Supported exchange segments:

- `nse_cm` - NSE Cash Market
- `bse_cm` - BSE Cash Market
- `nse_fo` - NSE Futures & Options
- `bse_fo` - BSE Futures & Options
- `cde_fo` - Currency Derivatives
- `bcs-fo` - BCS Futures & Options
- `mcx` - MCX Commodities

## 📦 Product Types

- **MIS** - Margin Intraday Square-off
- **NRML** - Normal
- **CNC** - Cash and Carry
- **CO** - Cover Order
- **BO** - Bracket Order

## 📊 Order Types

- **MKT** - Market Order
- **L** - Limit Order (requires price)
- **SL** - Stop Loss Limit
- **SL-M** - Stop Loss Market

## 🔒 Security Notes

- Credentials are stored locally on your device (mobile app) or in `b.txt` file (Python scripts)
- TOTP codes are generated on-the-fly and never stored
- All API communications use HTTPS
- **Never commit `b.txt` or any credential files to version control**
- The `.gitignore` file is configured to exclude sensitive files

## 🛠️ Troubleshooting

### Mobile App Issues

**"Please configure credentials first"**
- Go to Settings → Credentials and enter your credentials

**"TOTP login failed"**
- Verify your TOTP secret is correct
- Ensure mobile number is in correct format (10 digits)
- Check internet connection

**"Limit order requires price"**
- Enter a price when selecting Limit (L) order type

**Order placement fails**
- Verify all credentials are correct
- Check if account has sufficient balance
- Ensure trading symbol is correct and tradable

**WebSocket connection issues**
- Check internet connection
- Try disabling and re-enabling WebSocket in Settings
- Restart the app

### Python Script Issues

**"Module not found" error**
- Install dependencies: `pip install -r requirements.txt`

**"Credentials not found" error**
- Ensure `b.txt` file exists in `python_scripts/` folder
- Check file format matches the example

**"Authentication failed" error**
- Verify credentials in `b.txt` are correct
- Check TOTP secret is valid
- Ensure mobile number format is correct

## 📁 Project Structure

```
kotak_neo_order/
├── lib/                          # Flutter app source code
│   ├── main.dart                 # App entry point
│   ├── models/                   # Data models
│   ├── screens/                  # UI screens
│   ├── services/                 # Business logic
│   └── widgets/                  # Reusable widgets
├── android/                      # Android platform files
├── ios/                          # iOS platform files
├── python_scripts/               # Python CLI scripts
│   ├── place_order_cli_no_sdk.py
│   ├── order_book_cli_no_sdk.py
│   ├── requirements.txt
│   └── ...
├── assets/                       # App assets (images, etc.)
├── scrip_masters/               # Scrip master CSV files
├── outputs/                      # Output CSV files from scripts
└── README.md                     # This file
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## ⚠️ Disclaimer

This software is provided as-is for educational and personal use. Trading involves substantial risk of loss and is not suitable for every investor. The authors are not responsible for any financial losses incurred while using this software. Always verify orders before placing them in LIVE mode.

**Use at your own risk.**

## 📄 License

This project is for personal use. Ensure compliance with Kotak Neo API terms of service.

---

**Happy Trading! 📈**
