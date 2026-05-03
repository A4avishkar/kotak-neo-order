#!/usr/bin/env bash
# Start NIFTY and SENSEX OI analyzers as two processes (two WebSocket connections
# to Kotak). Redis keys: trading:oi:nifty:* and trading:oi:sensex:*.
#
# Usage (cron or manual):
#   chmod +x start_oi_analyzers.sh
#   ./start_oi_analyzers.sh
#
set -euo pipefail
KOTAK_DIR="${KOTAK_DIR:-/home/ubuntu/kotakserver/kotak}"
VENV_PY="${VENV_PY:-$KOTAK_DIR/venv/bin/python3}"
ANALYZER="${ANALYZER:-$KOTAK_DIR/nifty_oi_analyzer.py}"
EXTRA_ARGS="${EXTRA_ARGS:---continuous --redis}"

cd "$KOTAK_DIR"

nohup "$VENV_PY" "$ANALYZER" --index NIFTY $EXTRA_ARGS \
  >> "$KOTAK_DIR/nifty_oi.log" 2>&1 &
echo "$(date -Iseconds) started NIFTY analyzer pid=$!"

nohup "$VENV_PY" "$ANALYZER" --index SENSEX $EXTRA_ARGS \
  >> "$KOTAK_DIR/sensex_oi.log" 2>&1 &
echo "$(date -Iseconds) started SENSEX analyzer pid=$!"
