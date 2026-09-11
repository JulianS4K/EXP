"""Per-key token bucket. Protects the shared database from one hot client; not a
substitute for an edge rate limiter in front of the service."""
from __future__ import annotations

import threading
import time


class TokenBucket:
    def __init__(self, per_minute: int, burst: int | None = None):
        self._rate = float(per_minute) / 60.0
        self._burst = float(burst if burst is not None else max(per_minute, 1))
        self._state: dict[str, tuple[float, float]] = {}
        self._lock = threading.Lock()

    def allow(self, key: str, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        with self._lock:
            tokens, last = self._state.get(key, (self._burst, now))
            tokens = min(self._burst, tokens + (now - last) * self._rate)
            if tokens < 1.0:
                self._state[key] = (tokens, now)
                return False
            self._state[key] = (tokens - 1.0, now)
            return True
