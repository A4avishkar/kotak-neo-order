#!/usr/bin/env bash
# Optional: run every 5 minutes from cron during market hours (IST) on the Oracle VM.
# Restarts each analyzer if its Redis snapshot is older than STALE_SEC seconds.
#
# Crontab example (UTC times — adjust to match your server TZ):
#   */5 3-10 * * 1-5 /home/ubuntu/kotakserver/kotak/watchdog_oi_analyzer.sh >> /home/ubuntu/kotakserver/kotak/watchdog_oi.log 2>&1
#
set -euo pipefail
STALE_SEC="${STALE_SEC:-900}"
KOTAK_DIR="${KOTAK_DIR:-/home/ubuntu/kotakserver/kotak}"
VENV_PY="${VENV_PY:-$KOTAK_DIR/venv/bin/python3}"
ANALYZER="${ANALYZER:-$KOTAK_DIR/nifty_oi_analyzer.py}"

check_and_restart() {
  local index_key="$1"   # nifty | sensex
  local index_upper="$2"  # NIFTY | SENSEX
  local log_file="$3"

  local epoch_redis
  epoch_redis=$(redis-cli GET "trading:oi:${index_key}:updated_at_epoch" 2>/dev/null || echo "")

  if [[ -z "$epoch_redis" ]]; then
    echo "$(date -Iseconds) watchdog ${index_upper}: no updated_at_epoch — starting"
    pkill -f "nifty_oi_analyzer.py --index ${index_upper}" 2>/dev/null || true
    sleep 1
    nohup "$VENV_PY" "$ANALYZER" --index "${index_upper}" --continuous --redis >> "$log_file" 2>&1 &
    return 0
  fi

  local epoch_now age
  epoch_now=$(date +%s)
  age=$((epoch_now - 10#${epoch_redis:-0}))
  if (( age > STALE_SEC )); then
    echo "$(date -Iseconds) watchdog ${index_upper}: age ${age}s > ${STALE_SEC}s — restarting"
    pkill -f "nifty_oi_analyzer.py --index ${index_upper}" 2>/dev/null || true
    sleep 2
    nohup "$VENV_PY" "$ANALYZER" --index "${index_upper}" --continuous --redis >> "$log_file" 2>&1 &
  else
    echo "$(date -Iseconds) watchdog ${index_upper}: ok age=${age}s"
  fi
}

check_and_restart nifty NIFTY "$KOTAK_DIR/nifty_oi.log"
check_and_restart sensex SENSEX "$KOTAK_DIR/sensex_oi.log"
