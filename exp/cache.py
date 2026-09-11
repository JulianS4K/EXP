"""Tiny in-process TTL cache. Good enough for one web dyno; swap for Redis if EXP scales out."""
from __future__ import annotations

import threading
import time
from typing import Any


class TTLCache:
    def __init__(self, ttl_seconds: float, max_entries: int = 2000):
        self._ttl = float(ttl_seconds)
        self._max = int(max_entries)
        self._data: dict[Any, tuple[float, Any]] = {}
        self._lock = threading.Lock()

    def get(self, key: Any, now: float | None = None) -> Any | None:
        now = time.monotonic() if now is None else now
        with self._lock:
            hit = self._data.get(key)
            if hit is None:
                return None
            expires, value = hit
            if expires <= now:
                self._data.pop(key, None)
                return None
            return value

    def set(self, key: Any, value: Any, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        with self._lock:
            if len(self._data) >= self._max:
                self._data.pop(next(iter(self._data)))
            self._data[key] = (now + self._ttl, value)
