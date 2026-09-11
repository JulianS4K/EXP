"""EXP — cross-marketplace ticket price comparison.

Read-only over the Terminal-2 Supabase project; every marketplace row links out to where it
can be bought (or to the VibePass storefront for our own inventory). No upstream marketplace
API is ever called from here. Run: ``uvicorn server:app``."""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, Any

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from exp import config
from exp.cache import TTLCache
from exp.compare import COMPARE_SQL, EVENT_SQL, build_compare
from exp.db import Database, PostgresDatabase
from exp.fees import load_fee_model
from exp.ratelimit import TokenBucket
from exp.search import search_events

log = logging.getLogger("exp")
STATIC_DIR = Path(__file__).resolve().parent / "static"

CSP = (
    "default-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:; "
    "style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; "
    "base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    db = None
    if config.DATABASE_URL:
        db = PostgresDatabase(config.DATABASE_URL, config.STATEMENT_TIMEOUT_MS)
        db.open()
    elif getattr(app.state, "db", None) is None:
        log.warning("EXP_DATABASE_URL is not set; API routes will return 503")
    if db is not None:
        app.state.db = db
    try:
        yield
    finally:
        if db is not None:
            db.close()


app = FastAPI(title="EXP · ticket price compare", version="0.1.0", lifespan=lifespan)
app.state.db = None
app.state.fee_model = load_fee_model(config.FEE_MODEL_JSON)
app.state.cache = TTLCache(config.CACHE_TTL_SECONDS)
app.state.limiter = TokenBucket(config.RATE_LIMIT_PER_MINUTE)


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["Content-Security-Policy"] = CSP
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    return response


def get_db(request: Request) -> Database:
    db = getattr(request.app.state, "db", None)
    if db is None:
        raise HTTPException(status_code=503, detail="database not configured (EXP_DATABASE_URL)")
    return db


def enforce_rate_limit(request: Request) -> None:
    limiter: TokenBucket | None = getattr(request.app.state, "limiter", None)
    if limiter is None:
        return
    client = request.client.host if request.client else "unknown"
    if not limiter.allow(client):
        raise HTTPException(status_code=429, detail="too many requests; slow down")


@app.get("/healthz")
def healthz(request: Request) -> dict[str, Any]:
    return {"ok": True, "db_configured": getattr(request.app.state, "db", None) is not None}


@app.get("/api/search")
def api_search(
    request: Request,
    db: Annotated[Database, Depends(get_db)],
    q: str = Query(..., min_length=1, max_length=200),
    limit: int = Query(25, ge=1, le=50),
) -> dict[str, Any]:
    enforce_rate_limit(request)
    if len(" ".join(q.split())) < 2:
        raise HTTPException(status_code=400, detail="query must be at least 2 characters")
    return {"q": q, "events": search_events(db, q, limit)}


@app.get("/api/events/{event_id}/compare")
def api_compare(
    request: Request,
    event_id: int,
    db: Annotated[Database, Depends(get_db)],
    qty: int = Query(2, ge=config.QTY_MIN, le=config.QTY_MAX),
    max_age_hours: int = Query(config.MAX_AGE_HOURS_DEFAULT, ge=1, le=config.MAX_AGE_HOURS_CEILING),
) -> dict[str, Any]:
    enforce_rate_limit(request)
    if event_id <= 0:
        raise HTTPException(status_code=404, detail="event not found")
    cache: TTLCache | None = getattr(request.app.state, "cache", None)
    key = ("compare", event_id, qty, max_age_hours)
    if cache is not None:
        hit = cache.get(key)
        if hit is not None:
            return hit
    events = db.fetch(EVENT_SQL, {"event_id": event_id})
    if not events:
        raise HTTPException(status_code=404, detail="event not found")
    rows = db.fetch(
        COMPARE_SQL,
        {
            "event_id": event_id,
            "qty": qty,
            "max_age_hours": max_age_hours,
            "ladder": config.LADDER_SIZE,
            "own_brokerage_id": config.OWN_BROKERAGE_ID,
        },
    )
    payload = build_compare(
        events[0],
        rows,
        qty=qty,
        fee_model=request.app.state.fee_model,
        storefront_base=config.STOREFRONT_BASE_URL,
        max_age_hours=max_age_hours,
    )
    if cache is not None:
        cache.set(key, payload)
    return payload


@app.exception_handler(Exception)
async def unhandled(request: Request, exc: Exception):
    log.exception("unhandled error on %s", request.url.path)
    return JSONResponse(status_code=500, content={"detail": "internal error"})


@app.get("/", include_in_schema=False)
def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
