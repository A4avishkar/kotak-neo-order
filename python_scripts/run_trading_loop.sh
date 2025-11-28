#!/bin/bash
# Continuous Trading Loop Script
# This script runs your trading script continuously during market hours

cd ~/kotak_trading || exit 1

# Create logs directory if it doesn't exist
mkdir -p logs

LOG_FILE="logs/trading_$(date +%Y%m%d).log"

echo "$(date): Starting trading loop..." >> "$LOG_FILE"

while true; do
    # Get current time in IST
    current_hour=$(TZ='Asia/Kolkata' date +%H)
    current_minute=$(TZ='Asia/Kolkata' date +%M)
    current_day=$(TZ='Asia/Kolkata' date +%u)  # 1=Monday, 7=Sunday
    current_time=$(TZ='Asia/Kolkata' date +"%Y-%m-%d %H:%M:%S %Z")
    
    # Check if weekday (1-5) and market hours (9:15 to 15:30)
    if [ $current_day -le 5 ]; then
        if [ $current_hour -ge 9 ] && [ $current_hour -lt 15 ]; then
            # Check if it's after 9:15 AM
            if [ $current_hour -eq 9 ] && [ $current_minute -lt 15 ]; then
                echo "$current_time: Waiting for market to open (9:15 AM IST)..." >> "$LOG_FILE"
                sleep 60  # Wait 1 minute
                continue
            fi
            
            # Market is open - run your trading script
            echo "$current_time: Market is open. Running trading script..." >> "$LOG_FILE"
            
            # MODIFY THIS COMMAND WITH YOUR ACTUAL TRADING PARAMETERS
            # Using venv python to ensure all packages are available
            ~/kotak_venv/bin/python3 place_order_cli_no_sdk.py \
                --segment nse_fo \
                --symbol NIFTY25NOVFUT \
                --tt B \
                --product MIS \
                --order MKT \
                --qty 50 \
                --yes >> "$LOG_FILE" 2>&1
            
            # Wait 5 minutes before next execution (adjust as needed)
            sleep 300
        elif [ $current_hour -ge 15 ] && [ $current_minute -gt 30 ]; then
            echo "$current_time: Market closed at 3:30 PM IST. Exiting." >> "$LOG_FILE"
            break
        else
            # Before market opens or after market closes
            echo "$current_time: Outside market hours. Waiting..." >> "$LOG_FILE"
            sleep 300  # Wait 5 minutes
        fi
    else
        echo "$current_time: Weekend detected. Exiting." >> "$LOG_FILE"
        break
    fi
done

echo "$(date): Trading loop ended." >> "$LOG_FILE"

