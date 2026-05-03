import json
import argparse
import uvicorn
import asyncio
import redis
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from true_atm import determine_true_atm

# Defaults
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8000
REDIS_HOST = "localhost"
REDIS_PORT = 6379
REDIS_DB = 0

app = FastAPI(
    title="Kotak Neo Redis API",
    description="Live Trading Data API for Mobile App (Nifty/Sensex)",
    version="1.1"
)

# Enable CORS for Mobile Apps (Flutter, React Native, etc.)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Shared Redis instance
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

@app.get("/health")
def health():
    """Service health check."""
    redis_conn = get_redis()
    status = "ok" if redis_conn else "error"
    return {"status": status, "service": "Kotak-Neo-API", "redis": status}

@app.get("/snapshot/{index}")
def get_snapshot(index: str):
    """Get latest summary metrics (Spot, PCR, total OI) for an index."""
    redis_conn = get_redis()
    if not redis_conn:
        raise HTTPException(status_code=503, detail="Redis connection unavailable")
    
    # Fetch current snapshot
    key = f"trading:oi:{index.lower()}:snapshot"
    data_json = redis_conn.get(key)
    if not data_json:
        raise HTTPException(status_code=404, detail=f"No snapshot found for {index}")
    
    data = json.loads(data_json)
    
    # Fetch today's history
    history_key = f"trading:oi:{index.lower()}:history"
    history_json_list = redis_conn.lrange(history_key, 0, -1)
    
    data["history"] = []
    for item_json in history_json_list:
        try:
            data["history"].append(json.loads(item_json))
        except:
            pass
            
    return data

@app.get("/history/{index}")
def get_history(index: str, limit: int = 500):
    """Get the rolling history of OI calculations for an index."""
    redis_conn = get_redis()
    if not redis_conn:
        raise HTTPException(status_code=503, detail="Redis connection unavailable")
    
    key = f"trading:oi:{index.lower()}:history"
    history_json_list = redis_conn.lrange(key, -limit, -1)
    
    result = []
    for item_json in history_json_list:
        try:
            result.append(json.loads(item_json))
        except:
            pass
            
    return {"index": index, "count": len(result), "items": result}

@app.get("/expensiveness/{index}")
def get_expensiveness(index: str):
    """Get latest CE/PE expensiveness/cheapness detection."""
    redis_conn = get_redis()
    if not redis_conn:
        raise HTTPException(status_code=503, detail="Redis connection unavailable")
    
    key = f"trading:oi:{index.lower()}:expensiveness"
    data = redis_conn.get(key)
    if not data:
        raise HTTPException(status_code=404, detail=f"No expensiveness info found for {index}")
    
    return json.loads(data)

@app.get("/chain/{index}")
def get_chain(index: str):
    """Get full option chain quotes grouped by strike price."""
    redis_conn = get_redis()
    if not redis_conn:
        raise HTTPException(status_code=503, detail="Redis connection unavailable")
    
    key = f"trading:oi:{index.lower()}:live_quotes"
    # HGETALL returns a dict of strike -> JSON_string
    data = redis_conn.hgetall(key)
    if not data:
        raise HTTPException(status_code=404, detail=f"No live chain found for {index}")
    
    # Parse the inner JSON strings
    result = {}
    for strike, value in data.items():
        try:
            result[strike] = json.loads(value)
        except:
            result[strike] = value
            
    return result


@app.get("/true-atm/{index}")
def get_true_atm(index: str, window: int = 7, price: str = None):
    """
    Determine True ATM strike using Redis live_quotes (no refetching).

    Query params:
    - window: number of nearest strikes to evaluate (default 7)
    - price: force "open" or "ltp" (optional). If omitted, auto:
        <=09:15 IST -> open, else ltp.
    """
    redis_conn = get_redis()
    if not redis_conn:
        raise HTTPException(status_code=503, detail="Redis connection unavailable")

    force_price = price if price in ("open", "ltp") else None
    out = determine_true_atm(redis_conn, index, window_strikes=int(window), force_price=force_price)
    if not out.get("true_atm_strike"):
        raise HTTPException(status_code=404, detail=f"True ATM not available yet for {index} (missing live_quotes/open)")
    return out

@app.get("/expiry/{index}")
def get_expiry(index: str):
    """Get the daily processed expiry list used by the analyzer."""
    redis_conn = get_redis()
    if not redis_conn:
        raise HTTPException(status_code=503, detail="Redis connection unavailable")
    
    key = f"kotak:expiry:{index.lower()}"
    data = redis_conn.get(key)
    if not data:
        raise HTTPException(status_code=404, detail=f"No expiry list found for {index}")
    
    return json.loads(data)

@app.websocket("/ws/snapshot/{index}")
async def websocket_snapshot(websocket: WebSocket, index: str):
    """Stream live snapshot updates (Spot, PCR, total OI) via WebSocket."""
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
                # Only push if data has changed
                await websocket.send_text(data_json)
                last_data = data_json
            
            # Check for updates every 1 second (adjust as needed for latency vs CPU)
            await asyncio.sleep(1)
            
    except WebSocketDisconnect:
        pass
    except Exception as e:
        print(f"❌ WebSocket Error ({index}): {e}")
    finally:
        try:
            await websocket.close()
        except:
            pass

def main():
    global REDIS_HOST, REDIS_PORT, REDIS_DB
    
    parser = argparse.ArgumentParser(description="Standalone Redis-backed API for Kotak Neo Analysis")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"API Host (default: {DEFAULT_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"API Port (default: {DEFAULT_PORT})")
    parser.add_argument("--redis-host", default=REDIS_HOST, help=f"Redis Host (default: {REDIS_HOST})")
    parser.add_argument("--redis-port", type=int, default=REDIS_PORT, help=f"Redis Port (default: {REDIS_PORT})")
    parser.add_argument("--redis-db", type=int, default=REDIS_DB, help=f"Redis DB (default: {REDIS_DB})")
    
    args = parser.parse_args()
    
    REDIS_HOST = args.redis_host
    REDIS_PORT = args.redis_port
    REDIS_DB = args.redis_db
    
    print(f"🚀 Starting API Server on {args.host}:{args.port}")
    print(f"🔗 Connecting to Redis at {REDIS_HOST}:{REDIS_PORT} (DB {REDIS_DB})")
    
    uvicorn.run(app, host=args.host, port=args.port)

if __name__ == "__main__":
    main()
