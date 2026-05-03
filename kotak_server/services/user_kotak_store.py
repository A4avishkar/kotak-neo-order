"""Per-JWT-sub Kotak credential files + short-lived session cache on the server."""

from __future__ import annotations

import json
import os
import time
from threading import Lock
from typing import Any, Dict, Optional

from services.kotak_service import kotak_login_from_creds

DATA_DIR = os.path.abspath(
    os.environ.get(
        "KOTAK_USER_DATA_DIR",
        os.path.join(os.path.dirname(__file__), "..", "data", "kotak_users"),
    )
)
# How long to reuse edit_token / sid without re-running TOTP+MPIN. Kotak sessions
# typically last longer than a few minutes; 660s caused a full login on almost
# every burst of orders. Override with KOTAK_SESSION_TTL_SEC (e.g. 1800).
SESSION_TTL_SEC = int(os.environ.get("KOTAK_SESSION_TTL_SEC", "3600"))

_lock = Lock()
_locks_lock = Lock()
_sub_login_locks: Dict[str, Lock] = {}
_sessions: Dict[str, Dict[str, Any]] = {}


def _login_lock_for(sub: str) -> Lock:
    with _locks_lock:
        if sub not in _sub_login_locks:
            _sub_login_locks[sub] = Lock()
        return _sub_login_locks[sub]


def _safe_filename(sub: str) -> str:
    return "".join(c if c.isalnum() or c in "-_@." else "_" for c in sub)[:200]


def _path(sub: str) -> str:
    return os.path.join(DATA_DIR, f"{_safe_filename(sub)}.json")


def save_credentials(sub: str, creds: Dict[str, str]) -> None:
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    path = _path(sub)
    with _lock:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(creds, f)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    invalidate_session(sub)


def load_credentials(sub: str) -> Optional[Dict[str, str]]:
    path = _path(sub)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        return None
    return {str(k): str(v) for k, v in data.items()}


def invalidate_session(sub: str) -> None:
    with _lock:
        _sessions.pop(sub, None)


def get_or_refresh_session(sub: str, creds: Dict[str, str]) -> Dict[str, Any]:
    now = time.monotonic()
    with _lock:
        ent = _sessions.get(sub)
        if ent and (now - ent["ts"]) < SESSION_TTL_SEC:
            return ent["session"]

    # Serialize TOTP+MPIN per user so concurrent /kotak/order calls do not each
    # start a full login (slow + can confuse broker session state).
    with _login_lock_for(sub):
        now = time.monotonic()
        with _lock:
            ent = _sessions.get(sub)
            if ent and (now - ent["ts"]) < SESSION_TTL_SEC:
                return ent["session"]

        session = kotak_login_from_creds(creds)

        with _lock:
            _sessions[sub] = {"session": session, "ts": time.monotonic()}
        return session
