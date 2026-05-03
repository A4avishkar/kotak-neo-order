import json
import os
import sys
import asyncio
import redis
import uvicorn
from typing import List, Optional, Dict, Any
from fastapi import FastAPI, Depends, HTTPException, status, WebSocket, WebSocketDisconnect, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from pydantic import BaseModel

# Add current directory to path for service imports
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from services.kotak_service import KotakService
from services.auth_service import AuthService
from services import user_kotak_store
from snapshot_freshness import enrich_snapshot_payload
from true_atm import determine_true_atm

# --- Configuration ---
REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", 6379))
REDIS_DB = int(os.getenv("REDIS_DB", 0))

app = FastAPI(
    title="Kotak Neo Unified Server",
    description="Unified API for Market Data, Auth, and Order Proxy",
    version="2.0"
)

# --- Services ---
auth_service = AuthService()
kotak_service = KotakService()
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token")

# --- Debug Middleware to see EXACTLY what the mobile app sends ---
@app.middleware("http")
async def log_proxy_attempts(request: Request, call_next):
    """Logs basic info about /kotak/order attempts without consuming body stream."""
    if request.url.path == "/kotak/order":
        auth_header = request.headers.get("Authorization", "MISSING")
        print(f"[DEBUG] Order Attempt | Method: {request.method} | Auth: {auth_header[:30]}...")
    return await call_next(request)

# Enable CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Redis Connection
r = None

def get_redis():
    global r
    if r is None:
        try:
            r = redis.Redis(
                host=REDIS_HOST,
                port=REDIS_PORT,
                db=REDIS_DB,
                decode_responses=True,
                socket_timeout=5
            )
            r.ping()
        except Exception as e:
            print(f"❌ Redis Connection Error: {e}")
            r = None
    return r


def _parse_json_or_500(raw: str, *, source_key: str) -> Dict[str, Any]:
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            return parsed
        raise ValueError("payload is not a JSON object")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Invalid JSON in Redis key '{source_key}': {e}")


def _scoped_sub(base_sub: str, request: Request) -> str:
    """
    Build per-app-user storage key. This prevents shared server login users
    (e.g. admin) from overwriting each other's Kotak credentials.
    """
    app_uid = (request.headers.get("X-App-User-Id") or "").strip()
    if not app_uid:
        return base_sub
    safe_uid = "".join(c if c.isalnum() or c in "-_@." else "_" for c in app_uid)[:200]
    if not safe_uid:
        return base_sub
    return f"{base_sub}__{safe_uid}"

# --- Dependency ---
def get_current_sub(token: str = Depends(oauth2_scheme)) -> str:
    try:
        sub = auth_service.decode_access_token_subject(token)
        print(f"[DEBUG] Valid JWT for sub: {sub}")
        return sub
    except ValueError as e:
        print(f"[DEBUG] JWT Rejected: {e} | Token starts with: {token[:15]}...")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid or expired token: {e}",
        )

# --- Models ---
class KotakClientSession(BaseModel):
    base_url: str
    edit_token: str
    edit_sid: str
    server_id: str = ""
    neo_fin_key: str = "neotradeapi"

class OrderRequest(BaseModel):
    symbol: str
    qty: int
    transaction_type: str = "B"
    order_type: str = "MKT"
    product: str = "MIS"
    price: Optional[float] = 0
    segment: str = "nse_fo"
    trigger_price: Optional[float] = None
    tag: Optional[str] = None
    scrip_token: Optional[str] = None
    square_off_value: Optional[str] = None
    square_off_type: Optional[str] = None
    stop_loss_value: Optional[str] = None
    stop_loss_type: Optional[str] = None
    last_traded_price: Optional[float] = None
    kotak_session: Optional[KotakClientSession] = None

class KotakCredsRegister(BaseModel):
    consumerKey: str
    mobileNumber: str
    mpin: str
    ucc: str
    totpSecret: str
    neoFinKey: Optional[str] = "neotradeapi"

# --- Auth Routes ---
@app.post("/token")
async def login_for_access_token(form_data: OAuth2PasswordRequestForm = Depends()):
    if not auth_service.users_db:
        raise HTTPException(
            status_code=503,
            detail="Server auth users are not configured. Set ADMIN_USERNAME and ADMIN_PASSWORD.",
        )
    if form_data.username in auth_service.users_db and auth_service.verify_password(form_data.password, auth_service.users_db[form_data.username]):
        access_token = auth_service.create_access_token(data={"sub": form_data.username})
        return {"access_token": access_token, "token_type": "bearer"}
    raise HTTPException(status_code=400, detail="Incorrect username or password")

@app.post("/app/kotak-credentials")
async def register_kotak_credentials(
    body: KotakCredsRegister,
    request: Request,
    sub: str = Depends(get_current_sub),
):
    scoped_sub = _scoped_sub(sub, request)
    normalized = {
        "KOTAK_CONSUMER_KEY": body.consumerKey.strip(),
        "KOTAK_MOBILE_NUMBER": body.mobileNumber.strip(),
        "KOTAK_MPIN": body.mpin.strip(),
        "KOTAK_UCC": body.ucc.strip(),
        "KOTAK_TOTP_SECRET": body.totpSecret.strip(),
        "KOTAK_NEO_FIN_KEY": (body.neoFinKey or "neotradeapi").strip(),
    }
    user_kotak_store.save_credentials(scoped_sub, normalized)
    return {"ok": True}

# --- Token Expiration Helper ---
def is_token_expired_error(resp: Dict[str, Any]) -> bool:
    """Detect Kotak Neo 'invalid or expired token' (often code 2885)."""
    if not isinstance(resp, dict):
        return False
    emsg = str(resp.get("emsg", "")).lower()
    # Kotak returns 401 or emsg contains 'expired' or 'invalid'
    return "expired" in emsg or "invalid" in emsg or resp.get("http") == 401

# --- Order Routes ---
@app.post("/kotak/login")
async def kotak_login(token: str = Depends(oauth2_scheme)):
    """Warms the server-side b.txt session (not for app orders)."""
    success = kotak_service.login()
    if success:
        return {"status": "success", "message": "Logged into Kotak Neo (Server Account)"}
    raise HTTPException(status_code=500, detail="Kotak login failed")

@app.post("/kotak/order")
async def place_order(order: OrderRequest, request: Request, sub: str = Depends(get_current_sub)):
    try:
        scoped_sub = _scoped_sub(sub, request)
        payload = order.model_dump(exclude_none=True)
        ks = payload.pop("kotak_session", None)
        user_creds = user_kotak_store.load_credentials(scoped_sub)
        
        # 1. Use session from app
        if ks:
            resp = kotak_service.place_order_with_client_session(payload, ks)
            # If app session is expired, try to fallback to stored creds if available
            if not is_token_expired_error(resp):
                return resp
            # If expired but no server creds, return error as-is
            if not user_creds:
                return resp

        # 2. Use stored per-user credentials (with retry)
        if user_creds:
            session = user_kotak_store.get_or_refresh_session(scoped_sub, user_creds)
            resp = kotak_service.place_order_with_client_session(payload, session)
            
            if is_token_expired_error(resp):
                # Force fresh login and retry ONCE
                user_kotak_store.invalidate_session(scoped_sub)
                session = user_kotak_store.get_or_refresh_session(scoped_sub, user_creds)
                return kotak_service.place_order_with_client_session(payload, session)
            
            return resp

        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="No Kotak context for this user. Register credentials first."
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# --- Market Data Routes (Redis) ---
@app.get("/snapshot/{index}")
def get_snapshot(index: str):
    redis_conn = get_redis()
    if not redis_conn:
        raise HTTPException(status_code=503, detail="Redis connection unavailable")
    
    key = f"trading:oi:{index.lower()}:snapshot"
    data_json = redis_conn.get(key)
    if not data_json:
        raise HTTPException(status_code=404, detail=f"No snapshot found for {index}")
    
    data = _parse_json_or_500(data_json, source_key=key)
    history_key = f"trading:oi:{index.lower()}:history"
    history_json_list = redis_conn.lrange(history_key, -100, -1)
    history_items = []
    for item in history_json_list:
        if not item:
            continue
        try:
            parsed = json.loads(item)
            if isinstance(parsed, dict):
                history_items.append(parsed)
        except Exception:
            continue
    data["history"] = history_items
    return enrich_snapshot_payload(data, redis_conn, index)

@app.get("/chain/{index}")
def get_chain(index: str):
    redis_conn = get_redis()
    if not redis_conn:
        raise HTTPException(status_code=503, detail="Redis connection unavailable")
    
    key = f"trading:oi:{index.lower()}:live_quotes"
    data = redis_conn.hgetall(key)
    if not data:
        raise HTTPException(status_code=404, detail=f"No data found for {index}")
    
    out: Dict[str, Any] = {}
    for k, v in data.items():
        try:
            out[k] = json.loads(v)
        except Exception:
            out[k] = v
    return out


@app.get("/expensiveness/{index}")
def get_expensiveness(index: str):
    redis_conn = get_redis()
    if not redis_conn:
        raise HTTPException(status_code=503, detail="Redis connection unavailable")
    key = f"trading:oi:{index.lower()}:expensiveness"
    data_json = redis_conn.get(key)
    if not data_json:
        raise HTTPException(status_code=404, detail=f"No expensiveness data for {index}")
    return _parse_json_or_500(data_json, source_key=key)


@app.get("/true-atm/{index}")
def get_true_atm(index: str, window: int = 7, price: Optional[str] = None):
    """
    True ATM from Redis only (same as api_server). Requires live_quotes + snapshot in Redis.
    """
    redis_conn = get_redis()
    if not redis_conn:
        raise HTTPException(status_code=503, detail="Redis connection unavailable")
    force_price = price if price in ("open", "ltp") else None
    out = determine_true_atm(
        redis_conn, index, window_strikes=int(window), force_price=force_price
    )
    if not out.get("true_atm_strike"):
        raise HTTPException(
            status_code=404,
            detail=f"True ATM not available yet for {index} (missing live_quotes/open)",
        )
    return out


# --- Health & Misc ---
@app.get("/health")
async def health_check():
    redis_conn = get_redis()
    return {
        "status": "healthy",
        "redis": "ok" if redis_conn else "error",
        "kotak_b_txt_session": bool(kotak_service.session_data),
    }

@app.get("/")
async def root():
    return {"message": "Kotak Neo Unified Server v2.0 is running"}

# --- WebSockets ---
@app.websocket("/ws/snapshot/{index}")
async def websocket_snapshot(websocket: WebSocket, index: str):
    await websocket.accept()
    index_lower = index.lower()
    last_data = None
    try:
        while True:
            redis_conn = get_redis()
            if not redis_conn:
                await asyncio.sleep(5)
                continue
            
            key = f"trading:oi:{index_lower}:snapshot"
            data_json = redis_conn.get(key)
            if data_json and data_json != last_data:
                try:
                    payload = json.loads(data_json)
                    hk = f"trading:oi:{index_lower}:history"
                    hlist = redis_conn.lrange(hk, -100, -1)
                    payload["history"] = [
                        json.loads(j) for j in hlist if j
                    ]
                    payload = enrich_snapshot_payload(
                        payload, redis_conn, index_lower
                    )
                    out = json.dumps(payload)
                except Exception:
                    out = data_json
                await websocket.send_text(out)
                last_data = data_json
            await asyncio.sleep(1)
    except WebSocketDisconnect:
        pass
    except Exception as e:
        print(f"WS Error: {e}")

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    uvicorn.run("unified_server:app", host=args.host, port=args.port, reload=False)
