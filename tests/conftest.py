from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient

from exp.cache import TTLCache
from exp.compare import COMPARE_SQL, EVENT_SQL
from exp.fees import load_fee_model
from exp.search import SEARCH_SQL

NOW = datetime(2026, 9, 11, 4, 0, tzinfo=UTC)
FRESH = NOW - timedelta(minutes=7)


def event_row(**over: Any) -> dict[str, Any]:
    base = {
        "id": 3091467,
        "name": "New York Mets at New York Yankees",
        "starts_at_local": "2026-09-13 13:35:00",
        "venue_name": "Yankee Stadium",
        "venue_location": "Bronx, NY",
        "performer": "New York Yankees",
        "event_type": "sports",
        "sg_event_id": 17691592,
        "sg_url": "https://seatgeek.com/new-york-yankees-tickets/9-13-2026/mlb/17691592",
        "gt_event_id": 555001,
    }
    base.update(over)
    return base


def listing(src: str, **over: Any) -> dict[str, Any]:
    base = {
        "src": src,
        "listings_total": 10,
        "listings_for_qty": 4,
        "captured_at": FRESH,
        "section": "205",
        "row": "4",
        "quantity": 2,
        "unit_price": 40.40,
        "sg_url": None,
        "display_id": None,
        "gt_event_id": None,
        "gt_section_id": None,
        "accessible": False,
        "limited_view": False,
        "rn": 1,
        # broker-only columns must NOT be in the SQL output; include them here on purpose so
        # the whitelist test proves the shaper drops anything unexpected.
        "wholesale_price": 30.0,
        "brokerage_name": "Some Broker LLC",
        "is_owned": src == "vibepass",
    }
    base.update(over)
    return base


def sample_rows() -> list[dict[str, Any]]:
    return [
        listing("vibepass", unit_price=40.40, section="205", row="4", rn=1),
        listing("vibepass", unit_price=44.00, section="205", row="9", rn=2),
        listing(
            "seatgeek",
            unit_price=54.26,
            section="230",
            row="12",
            sg_url="https://seatgeek.com/new-york-yankees-tickets/9-13-2026/mlb/17691592",
            display_id="A6rs2KO4wGY",
            rn=1,
        ),
        listing(
            "gotickets",
            unit_price=38.70,
            section="Bleachers 203",
            row="7",
            gt_event_id=555001,
            gt_section_id=9911,
            rn=1,
            limited_view=True,
        ),
        listing("tevo_exchange", unit_price=31.00, section="420", row="2", rn=1),
    ]


class FakeDb:
    """Routes each SQL text to canned rows and records the params it was called with."""

    def __init__(self, events=None, rows=None, search=None):
        self.events = [] if events is None else events
        self.rows = [] if rows is None else rows
        self.search = [] if search is None else search
        self.calls: list[tuple[str, dict[str, Any]]] = []

    def fetch(self, sql: str, params: dict[str, Any]) -> list[dict[str, Any]]:
        self.calls.append((sql, params))
        if sql == EVENT_SQL:
            return list(self.events)
        if sql == COMPARE_SQL:
            return list(self.rows)
        if sql == SEARCH_SQL:
            return list(self.search)
        raise AssertionError("unexpected SQL")


@pytest.fixture
def fee_model():
    return load_fee_model(None)


@pytest.fixture
def client():
    import server

    def make(db):
        server.app.state.db = db
        server.app.state.cache = TTLCache(60)  # fresh cache per test
        return TestClient(server.app)

    yield make
    server.app.state.db = None
