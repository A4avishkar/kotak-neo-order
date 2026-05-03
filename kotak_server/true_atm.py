"""
Determine "True ATM" using Redis-updated option chain data (no refetching).

Logic (Jaikumar):
- For each strike: compute abs(CE_price - PE_price)
- True ATM = strike with minimum abs difference

Price selection:
- At market open (<= 09:15 IST): use option open price (from Redis live_quotes payload)
- After 09:15 IST: use option LTP

Strike narrowing (optional):
- Flat open: abs(index_open - prev_close) <= 30 pts -> evaluate strikes near prev_close
- Gap open: otherwise evaluate strikes near index_open
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

import redis

IST_OPEN_CUTOFF = (9, 15)  # HH, MM
FLAT_OPEN_POINTS = 30.0
DEFAULT_WINDOW_STRIKES = 7  # evaluate nearest N strikes around reference


def _as_float(v: Any) -> Optional[float]:
    if v is None:
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f


def _ist_now_hm() -> Tuple[int, int]:
    # Keep it simple: analyzer already writes timestamps in IST.
    now = datetime.now()
    return now.hour, now.minute


def _use_open_price_now() -> bool:
    h, m = _ist_now_hm()
    return (h, m) <= IST_OPEN_CUTOFF


def _get_snapshot(redis_conn: redis.Redis, index: str) -> Dict[str, Any]:
    raw = redis_conn.get(f"trading:oi:{index.lower()}:snapshot")
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except Exception:
        return {}


def _get_live_quotes(redis_conn: redis.Redis, index: str) -> Dict[int, Dict[str, Any]]:
    """
    Returns: { strike_int: { "strike": int, "ce": {...}, "pe": {...} } }
    Source: Redis hash `trading:oi:{index}:live_quotes` where field=strike, value=json.
    """
    h = redis_conn.hgetall(f"trading:oi:{index.lower()}:live_quotes") or {}
    out: Dict[int, Dict[str, Any]] = {}
    for strike_s, payload_s in h.items():
        try:
            strike_i = int(float(strike_s))
        except Exception:
            continue
        try:
            payload = json.loads(payload_s)
        except Exception:
            continue
        if isinstance(payload, dict):
            out[strike_i] = payload
    return out


def _pick_reference_strikes(
    strikes: List[int],
    *,
    index_open: Optional[float],
    index_prev_close: Optional[float],
    window: int,
) -> List[int]:
    if not strikes:
        return []
    if window <= 0 or window >= len(strikes):
        return strikes

    ref = None
    if index_open is not None and index_prev_close is not None:
        if abs(index_open - index_prev_close) <= FLAT_OPEN_POINTS:
            ref = index_prev_close
        else:
            ref = index_open
    elif index_open is not None:
        ref = index_open
    elif index_prev_close is not None:
        ref = index_prev_close

    if ref is None:
        return strikes

    # nearest strikes around ref (window total)
    strikes_sorted = sorted(strikes)
    nearest = sorted(strikes_sorted, key=lambda s: abs(s - ref))[:window]
    return sorted(set(nearest))


def determine_true_atm(
    redis_conn: redis.Redis,
    index: str,
    *,
    window_strikes: int = DEFAULT_WINDOW_STRIKES,
    force_price: Optional[str] = None,  # "open" | "ltp" | None(auto)
) -> Dict[str, Any]:
    """
    Returns a dict containing:
    - true_atm_strike
    - min_abs_diff
    - price_mode_used ("open" or "ltp")
    - evaluated_strikes_count
    - candidates (top few sorted by abs diff)
    """
    snap = _get_snapshot(redis_conn, index)
    chain = _get_live_quotes(redis_conn, index)

    # Snapshot fields written by analyzer:
    index_open = _as_float(snap.get("open"))
    index_prev_close = _as_float(snap.get("close"))

    strikes_all = sorted(chain.keys())
    strikes_eval = _pick_reference_strikes(
        strikes_all,
        index_open=index_open,
        index_prev_close=index_prev_close,
        window=window_strikes,
    )

    if force_price in ("open", "ltp"):
        price_mode = force_price
    else:
        price_mode = "open" if _use_open_price_now() else "ltp"

    results: List[Tuple[int, float, float, float]] = []  # strike, absdiff, ce_price, pe_price
    for s in strikes_eval:
        row = chain.get(s) or {}
        ce = row.get("ce") or {}
        pe = row.get("pe") or {}
        ce_price = _as_float(ce.get(price_mode))
        pe_price = _as_float(pe.get(price_mode))
        if ce_price is None or pe_price is None:
            # Fallback if open not present yet: use ltp
            if price_mode == "open":
                ce_price = _as_float(ce.get("ltp"))
                pe_price = _as_float(pe.get("ltp"))
        if ce_price is None or pe_price is None:
            continue
        absdiff = abs(ce_price - pe_price)
        results.append((s, absdiff, ce_price, pe_price))

    results.sort(key=lambda t: t[1])
    true_atm = results[0][0] if results else None
    min_abs_diff = results[0][1] if results else None

    top = [
        {
            "strike": s,
            "ce_price": ce_p,
            "pe_price": pe_p,
            "diff": ce_p - pe_p,
            "abs_diff": ad,
        }
        for (s, ad, ce_p, pe_p) in results[:10]
    ]

    return {
        "index": index.upper(),
        "price_mode_used": price_mode,
        "true_atm_strike": true_atm,
        "min_abs_diff": min_abs_diff,
        "evaluated_strikes_count": len(results),
        "evaluated_window_strikes": strikes_eval,
        "snapshot_open": index_open,
        "snapshot_prev_close": index_prev_close,
        "candidates": top,
    }


def main() -> None:
    p = argparse.ArgumentParser(description="Determine True ATM from Redis live_quotes")
    p.add_argument("--index", default="NIFTY", help="NIFTY or SENSEX")
    p.add_argument("--redis-host", default="localhost")
    p.add_argument("--redis-port", type=int, default=6379)
    p.add_argument("--redis-db", type=int, default=0)
    p.add_argument("--window", type=int, default=DEFAULT_WINDOW_STRIKES, help="How many nearest strikes to evaluate")
    p.add_argument("--price", default=None, choices=[None, "open", "ltp"], help="Force price mode")
    args = p.parse_args()

    r = redis.Redis(host=args.redis_host, port=args.redis_port, db=args.redis_db, decode_responses=True)
    out = determine_true_atm(r, args.index, window_strikes=args.window, force_price=args.price)
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()

