#!/usr/bin/env bash
# Start Redis → FCM expensive+OI notifiers (NIFTY + SENSEX) after reboot or manually.
#
# Required on the VM (export in ~/.profile, systemd Environment=, or a small env file):
#   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/firebase-adminsdk.json
#   export FCM_DEVICE_TOKEN=...   OR   export FCM_DEVICE_TOKENS=tok1,tok2
# Optional:
#   export REDIS_HOST=localhost
#   export FCM_POLL_INTERVAL=60
#
# Crontab (see crontab.deploy):
#   @reboot ... ./start_redis_fcm_notifiers.sh >> fcm_notifier_boot.log 2>&1
#
set -euo pipefail
KOTAK_DIR="${KOTAK_DIR:-/home/ubuntu/kotakserver/kotak}"
VENV_PY="${VENV_PY:-$KOTAK_DIR/venv/bin/python3}"
SCRIPT="$KOTAK_DIR/redis_expensive_oi_fcm.py"
INTERVAL="${FCM_POLL_INTERVAL:-60}"
REDIS_HOST="${REDIS_HOST:-localhost}"

if [[ ! -f "$SCRIPT" ]]; then
  echo "$(date -Iseconds) redis_expensive_oi_fcm.py not found at $SCRIPT"
  exit 1
fi

if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  echo "$(date -Iseconds) FCM notifier skipped: set GOOGLE_APPLICATION_CREDENTIALS"
  exit 0
fi
if [[ -z "${FCM_DEVICE_TOKEN:-}${FCM_DEVICE_TOKENS:-}" ]]; then
  echo "$(date -Iseconds) FCM notifier skipped: set FCM_DEVICE_TOKEN or FCM_DEVICE_TOKENS"
  exit 0
fi

cd "$KOTAK_DIR"
nohup "$VENV_PY" "$SCRIPT" --index NIFTY --interval "$INTERVAL" --redis-host "$REDIS_HOST" \
  >> "$KOTAK_DIR/redis_fcm_nifty.log" 2>&1 &
echo "$(date -Iseconds) started redis_expensive_oi_fcm NIFTY pid=$! interval=${INTERVAL}s"

nohup "$VENV_PY" "$SCRIPT" --index SENSEX --interval "$INTERVAL" --redis-host "$REDIS_HOST" \
  >> "$KOTAK_DIR/redis_fcm_sensex.log" 2>&1 &
echo "$(date -Iseconds) started redis_expensive_oi_fcm SENSEX pid=$! interval=${INTERVAL}s"
