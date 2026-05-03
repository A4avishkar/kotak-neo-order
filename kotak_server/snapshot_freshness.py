"""
Same as python_scripts/ec2files/snapshot_freshness.py — keep in sync for VM deploys.
"""

from __future__ import annotations

import re
import time
from datetime import datetime, timezone
from typing import Any, Dict, Optional

try:
    from zoneinfo import ZoneInfo

    _IST = ZoneInfo("Asia/Kolkata")
except Exception:  # pragma: no cover
    _IST = None

STALE_AFTER_SECONDS = 15 * 60

_UTC = timezone.utc


def _epoch_from_utc_time_today(hms: str) -> Optional[int]:
    """VM / some builds store snapshot `timestamp` and Redis last_update as UTC HH:MM:SS."""
    hms = str(hms).strip()
    if not re.match(r"^\d{1,2}:\d{2}:\d{2}$", hms):
        return None
    try:
        parts = hms.split(":")
        h, m, s = int(parts[0]), int(parts[1]), int(parts[2])
        now = datetime.now(_UTC)
        dt = datetime(now.year, now.month, now.day, h, m, s, tzinfo=_UTC)
        return int(dt.timestamp())
    except Exception:
        return None


def _epoch_from_redis_last_update(redis_conn, index_l: str) -> Optional[int]:
    raw = redis_conn.get(f"trading:oi:{index_l}:last_update")
    if not raw:
        return None
    return _epoch_from_utc_time_today(str(raw))


def _epoch_from_snapshot_timestamp(data: Dict[str, Any]) -> Optional[int]:
    t = data.get("timestamp")
    if t is None:
        return None
    ts = str(t).strip()
    try:
        if len(ts) >= 10 and ("-" in ts[:10] or "T" in ts):
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=_UTC)
            return int(dt.timestamp())
    except Exception:
        pass
    # Prefer IST if analyzer tagged the payload (ec2files push_snapshot)
    tz_label = (data.get("tz_label") or data.get("timezone") or "").upper()
    if "IST" in tz_label or data.get("timezone") == "Asia/Kolkata":
        if _IST is None:
            return None
        d = data.get("date")
        date_s = d.strip() if isinstance(d, str) and d.strip() else datetime.now(_IST).strftime("%Y-%m-%d")
        try:
            time_part = ts[:8] if len(ts) >= 8 else ts
            dt = datetime.strptime(f"{date_s} {time_part}", "%Y-%m-%d %H:%M:%S")
            dt = dt.replace(tzinfo=_IST)
            return int(dt.timestamp())
        except Exception:
            return None
    return _epoch_from_utc_time_today(ts)


def _epoch_from_history_last(data: Dict[str, Any]) -> Optional[int]:
    hist = data.get("history") or []
    if not hist or not isinstance(hist[-1], dict):
        return None
    last = hist[-1]
    d = last.get("date")
    t = last.get("timestamp")
    if not d or not t or _IST is None:
        return None
    try:
        dt = datetime.strptime(f"{d} {t}", "%Y-%m-%d %H:%M:%S")
        dt = dt.replace(tzinfo=_IST)
        return int(dt.timestamp())
    except Exception:
        return None


def enrich_snapshot_payload(
    data: Dict[str, Any],
    redis_conn,
    index: str,
    stale_after_seconds: int = STALE_AFTER_SECONDS,
) -> Dict[str, Any]:
    now = int(time.time())
    index_l = index.lower()

    epoch: Optional[int] = None
    raw_epoch = data.get("updated_at_epoch")
    if raw_epoch is not None:
        try:
            epoch = int(raw_epoch)
        except (TypeError, ValueError):
            epoch = None

    if epoch is None:
        raw = redis_conn.get(f"trading:oi:{index_l}:updated_at_epoch")
        if raw:
            try:
                epoch = int(raw)
            except ValueError:
                epoch = None

    if epoch is None:
        epoch = _epoch_from_redis_last_update(redis_conn, index_l)

    if epoch is None:
        epoch = _epoch_from_snapshot_timestamp(data)

    if epoch is None:
        epoch = _epoch_from_history_last(data)

    age: Optional[int] = None
    if epoch is not None:
        age = max(0, now - epoch)

    stale = age is None or age > stale_after_seconds
    out = dict(data)
    out["snapshot_age_seconds"] = age
    out["snapshot_stale"] = stale
    if stale:
        out["snapshot_warning"] = (
            "Live OI snapshot is stale (not updated recently). "
            "On the server: check that nifty_oi_analyzer is running and writing Redis."
        )
    else:
        out.pop("snapshot_warning", None)
    return out
