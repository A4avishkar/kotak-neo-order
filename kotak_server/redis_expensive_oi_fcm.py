#!/usr/bin/env python3
"""
Read Redis (written by nifty_oi_analyzer) and send FCM push when:

  1) Put (PE) is the expensive side AND PE is at least --price-pct more expensive than CE
     (relative premium on the cheaper leg), AND total put OI > total call OI
     → notification: buy call (CE).

  2) Call (CE) is the expensive side AND CE is at least --price-pct more expensive than PE
     AND total call OI > total put OI
     → notification: buy put (PE).

Data sources (no extra market fetch):
  - trading:oi:{index}:snapshot  → total_oi_ce, total_oi_pe
  - trading:oi:{index}:expensiveness → side, ce_price, pe_price (and diff_pct from analyzer)

Requires:
  pip install redis firebase-admin

FCM:
  Set GOOGLE_APPLICATION_CREDENTIALS to your Firebase service account JSON, or pass --credentials.
  Set FCM_DEVICE_TOKEN to one device token, or FCM_DEVICE_TOKENS=comma,separated,tokens,
  or pass --tokens.

Run once:
  python redis_expensive_oi_fcm.py --index NIFTY

Poll every 30s:
  python redis_expensive_oi_fcm.py --index NIFTY --interval 30
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

try:
    import redis
except ImportError:
    redis = None  # type: ignore

try:
    import firebase_admin
    from firebase_admin import credentials, messaging
except ImportError:
    firebase_admin = None  # type: ignore


def _json_loads(raw: Optional[str]) -> Dict[str, Any]:
    if not raw:
        return {}
    try:
        out = json.loads(raw)
        return out if isinstance(out, dict) else {}
    except Exception:
        return {}


def load_snapshot(r: "redis.Redis", index: str) -> Dict[str, Any]:
    return _json_loads(r.get(f"trading:oi:{index.lower()}:snapshot"))


def load_expensiveness(r: "redis.Redis", index: str) -> Dict[str, Any]:
    return _json_loads(r.get(f"trading:oi:{index.lower()}:expensiveness"))


def _f(x: Any) -> float:
    try:
        return float(x)
    except (TypeError, ValueError):
        return 0.0


def relative_expensive_premium_pct(side: str, ce_price: float, pe_price: float) -> float:
    """
    How much more expensive the winning side is vs the cheaper side (percent).
    PE expensive: (pe - ce) / ce * 100
    CE expensive: (ce - pe) / pe * 100
    """
    side_u = (side or "").upper().strip()
    if side_u == "PE" and pe_price > ce_price > 0:
        return (pe_price - ce_price) / ce_price * 100.0
    if side_u == "CE" and ce_price > pe_price > 0:
        return (ce_price - pe_price) / pe_price * 100.0
    return 0.0


def evaluate_signal(
    snapshot: Dict[str, Any],
    exp: Dict[str, Any],
    *,
    price_pct_threshold: float,
    min_option_price: float,
) -> Optional[Tuple[str, str, str]]:
    """
    Returns (signal_code, title, body) or None.
    signal_code: BUY_CE | BUY_PE
    """
    mode = str(exp.get("mode") or "")
    if mode in ("NO_SPOT", "NO_COMPARISON", "") and not exp.get("side"):
        return None

    side = str(exp.get("side") or "").upper().strip()
    if side not in ("CE", "PE"):
        return None

    ce_price = _f(exp.get("ce_price"))
    pe_price = _f(exp.get("pe_price"))
    if ce_price < min_option_price or pe_price < min_option_price:
        return None

    premium_pct = relative_expensive_premium_pct(side, ce_price, pe_price)
    if premium_pct < price_pct_threshold:
        return None

    total_ce = _f(snapshot.get("total_oi_ce"))
    total_pe = _f(snapshot.get("total_oi_pe"))

    idx_name = str(snapshot.get("index") or "").upper() or "INDEX"

    # PE expensive + Put OI > Call OI → Buy Call
    if side == "PE" and total_pe > total_ce:
        body = (
            f"{idx_name}: PE expensive vs CE by {premium_pct:.1f}% "
            f"(CE ₹{ce_price:.2f} vs PE ₹{pe_price:.2f}). "
            f"Total PE OI {total_pe:,.0f} > CE OI {total_ce:,.0f}. Idea: buy CE / calls."
        )
        return ("BUY_CE", f"{idx_name}: consider buying Call", body)

    # CE expensive + Call OI > Put OI → Buy Put
    if side == "CE" and total_ce > total_pe:
        body = (
            f"{idx_name}: CE expensive vs PE by {premium_pct:.1f}% "
            f"(CE ₹{ce_price:.2f} vs PE ₹{pe_price:.2f}). "
            f"Total CE OI {total_ce:,.0f} > PE OI {total_pe:,.0f}. Idea: buy PE / puts."
        )
        return ("BUY_PE", f"{idx_name}: consider buying Put", body)

    return None


def notification_fingerprint(signal: Tuple[str, str, str], snapshot: Dict[str, Any], exp: Dict[str, Any]) -> str:
    raw = json.dumps(
        {
            "sig": signal[0],
            "side": exp.get("side"),
            "ce": exp.get("ce_price"),
            "pe": exp.get("pe_price"),
            "tce": snapshot.get("total_oi_ce"),
            "tpe": snapshot.get("total_oi_pe"),
            "ts": snapshot.get("timestamp"),
        },
        sort_keys=True,
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def send_fcm(
    tokens: List[str],
    title: str,
    body: str,
    data: Optional[Dict[str, str]] = None,
) -> None:
    if not tokens:
        raise ValueError("No FCM device tokens configured.")
    if firebase_admin is None:
        raise RuntimeError("firebase-admin not installed. pip install firebase-admin")

    app = firebase_admin.get_app()
    data = dict(data or {})
    for t in tokens:
        msg = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            data=data,
            token=t.strip(),
        )
        messaging.send(msg, app=app)


def init_firebase(credentials_path: Optional[str]) -> None:
    if firebase_admin is None:
        raise RuntimeError("firebase-admin not installed. pip install firebase-admin")
    try:
        firebase_admin.get_app()
        return
    except ValueError:
        pass
    path = credentials_path or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not path or not os.path.isfile(path):
        raise RuntimeError(
            "Firebase credentials JSON not found. Set GOOGLE_APPLICATION_CREDENTIALS or pass --credentials."
        )
    cred = credentials.Certificate(path)
    firebase_admin.initialize_app(cred)


def parse_tokens(args_tokens: Optional[str]) -> List[str]:
    if args_tokens:
        return [x.strip() for x in args_tokens.split(",") if x.strip()]
    env = os.environ.get("FCM_DEVICE_TOKENS") or os.environ.get("FCM_DEVICE_TOKEN")
    if not env:
        return []
    if "," in env:
        return [x.strip() for x in env.split(",") if x.strip()]
    return [env.strip()]


def redis_connect(host: str, port: int, db: int) -> "redis.Redis":
    if redis is None:
        raise RuntimeError("redis package not installed. pip install redis")
    r = redis.Redis(host=host, port=port, db=db, decode_responses=True, socket_timeout=5)
    r.ping()
    return r


def main() -> None:
    p = argparse.ArgumentParser(description="Redis + expensive-side/OI → FCM notifier")
    p.add_argument("--index", default="NIFTY", help="NIFTY or SENSEX")
    p.add_argument("--redis-host", default=os.environ.get("REDIS_HOST", "localhost"))
    p.add_argument("--redis-port", type=int, default=int(os.environ.get("REDIS_PORT", "6379")))
    p.add_argument("--redis-db", type=int, default=int(os.environ.get("REDIS_DB", "0")))
    p.add_argument("--price-pct", type=float, default=30.0, help="Min relative premium %% of expensive vs cheap leg")
    p.add_argument("--min-option-price", type=float, default=1.0, help="Ignore quotes if CE/PE price below this")
    p.add_argument("--interval", type=float, default=0.0, help="Poll every N seconds (0 = run once)")
    p.add_argument("--credentials", default=None, help="Path to Firebase service account JSON")
    p.add_argument("--tokens", default=None, help="Comma-separated FCM registration tokens")
    p.add_argument(
        "--cooldown-seconds",
        type=int,
        default=300,
        help="Do not resend same fingerprint within this many seconds (stored in Redis)",
    )
    args = p.parse_args()

    tokens = parse_tokens(args.tokens)
    if not tokens:
        print("No FCM tokens: set --tokens or FCM_DEVICE_TOKEN(S)", file=sys.stderr)
        sys.exit(1)

    init_firebase(args.credentials)
    r = redis_connect(args.redis_host, args.redis_port, args.redis_db)
    index_l = args.index.lower()

    def tick() -> None:
        snap = load_snapshot(r, args.index)
        exp = load_expensiveness(r, args.index)
        sig = evaluate_signal(
            snap,
            exp,
            price_pct_threshold=args.price_pct,
            min_option_price=args.min_option_price,
        )
        if not sig:
            return

        code, title, body = sig
        fp = notification_fingerprint(sig, snap, exp)
        cool_key = f"kotak:fcm:cooldown:{index_l}:{code}:{fp}"
        if args.cooldown_seconds > 0:
            if r.set(cool_key, "1", nx=True, ex=args.cooldown_seconds):
                pass
            else:
                return

        send_fcm(
            tokens,
            title,
            body,
            data={
                "kind": "expensive_oi",
                "signal": code,
                "index": args.index.upper(),
            },
        )
        print(f"[FCM] sent {code}: {title}")

    if args.interval <= 0:
        tick()
        return

    while True:
        try:
            tick()
        except Exception as e:
            print(f"tick error: {e}", file=sys.stderr)
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
