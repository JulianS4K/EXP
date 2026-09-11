"""Event search over the Terminal-2 catalogue (upcoming, non-ignored events)."""
from __future__ import annotations

from pathlib import Path
from typing import Any

from .db import Database

SEARCH_SQL = (Path(__file__).resolve().parent.parent / "sql" / "search.sql").read_text()

MIN_QUERY_CHARS = 2
MAX_QUERY_CHARS = 80


def normalise_query(q: str | None) -> str | None:
    """Trim, bound and LIKE-escape a user query; None when too short to search."""
    if q is None:
        return None
    q = " ".join(q.split())[:MAX_QUERY_CHARS]
    if len(q) < MIN_QUERY_CHARS:
        return None
    return q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def search_events(db: Database, q: str, limit: int = 25) -> list[dict[str, Any]]:
    needle = normalise_query(q)
    if needle is None:
        return []
    rows = db.fetch(SEARCH_SQL, {"pattern": f"%{needle}%", "limit": int(limit)})
    return [
        {
            "id": int(r["id"]),
            "name": r.get("name"),
            "starts_at_local": r.get("starts_at_local"),
            "venue": r.get("venue_name"),
            "location": r.get("venue_location"),
            "performer": r.get("performer"),
            "event_type": r.get("event_type"),
        }
        for r in rows
    ]
