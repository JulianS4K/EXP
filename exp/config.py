"""Environment-driven settings. Every value has a safe default except the database URL,
which is deliberately absent so a misconfigured deploy fails loudly (503) rather than
silently serving nothing."""
from __future__ import annotations

import os


def _int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    return int(raw)


DATABASE_URL: str | None = os.environ.get("EXP_DATABASE_URL") or None
STOREFRONT_BASE_URL: str = os.environ.get(
    "EXP_STOREFRONT_BASE_URL", "https://vibepass-storefront-test.onrender.com"
).rstrip("/")
OWN_BROKERAGE_ID: int = _int("EXP_OWN_BROKERAGE_ID", 1768)
MAX_AGE_HOURS_DEFAULT: int = _int("EXP_MAX_AGE_HOURS", 24)
MAX_AGE_HOURS_CEILING: int = 72
LADDER_SIZE: int = _int("EXP_LADDER_SIZE", 8)
CACHE_TTL_SECONDS: int = _int("EXP_CACHE_TTL_SECONDS", 60)
RATE_LIMIT_PER_MINUTE: int = _int("EXP_RATE_LIMIT_PER_MINUTE", 60)
STATEMENT_TIMEOUT_MS: int = _int("EXP_STATEMENT_TIMEOUT_MS", 8000)
FEE_MODEL_JSON: str | None = os.environ.get("EXP_FEE_MODEL_JSON") or None
QTY_MIN, QTY_MAX = 1, 12
