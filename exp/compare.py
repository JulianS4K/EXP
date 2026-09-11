"""Turn the compare query's rows into the fan-facing response.

Everything here is pure: rows in, JSON-able dict out. The SQL lives in ``sql/compare.sql``;
the fee model in ``fees.py``; link rules in ``links.py``. ``FORBIDDEN_KEYS`` is the
whitelist's teeth — a test walks every response and fails if a broker field ever leaks."""
from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from . import links
from .fees import Fee, total_price

SQL_DIR = Path(__file__).resolve().parent.parent / "sql"
COMPARE_SQL = (SQL_DIR / "compare.sql").read_text()
EVENT_SQL = (SQL_DIR / "event.sql").read_text()

SOURCES = ("vibepass", "seatgeek", "gotickets", "tevo_exchange")

SOURCE_META: dict[str, dict[str, Any]] = {
    "vibepass": {"label": "VibePass", "buyable": True, "kind": "storefront"},
    "seatgeek": {"label": "SeatGeek", "buyable": True, "kind": "marketplace"},
    "gotickets": {"label": "GoTickets", "buyable": True, "kind": "marketplace"},
    "tevo_exchange": {
        "label": "Broker exchange",
        "buyable": False,
        "kind": "wholesale",
        "note": "Wholesale asks from other brokers on the TEvo exchange. "
        "Not sold to fans directly; shown as a market reference.",
    },
}

# Broker-only fields that must never reach a fan. Guarded by tests/test_compare.py.
FORBIDDEN_KEYS = frozenset(
    {
        "wholesale_price",
        "brokerage_name",
        "brokerage_id",
        "office_id",
        "office_name",
        "is_owned",
        "sglid",
        "tevo_ticket_group_id",
        "seller_notes",
        "raw",
        "sg_event_id",
        "gt_event_id",
        "gt_section_id",
        "display_id",
        "sg_url",
    }
)

STATUS_PRICED = "priced"
STATUS_NO_MATCH = "no_match_for_qty"
STATUS_NO_FRESH = "no_fresh_prices"
STATUS_NOT_LISTED = "not_listed"


def _age_minutes(captured_at: datetime | None, now: datetime) -> int | None:
    if captured_at is None:
        return None
    if captured_at.tzinfo is None:
        captured_at = captured_at.replace(tzinfo=UTC)
    return max(0, int((now - captured_at).total_seconds() // 60))


def _tags(row: dict[str, Any]) -> list[str]:
    tags: list[str] = []
    if row.get("accessible"):
        tags.append("accessible")
    if row.get("limited_view"):
        tags.append("limited view")
    return tags


def _buy_url(
    src: str, row: dict[str, Any], event_id: int, storefront_base: str | None
) -> str | None:
    if src == "vibepass":
        return links.vibepass_url(storefront_base, event_id, row.get("section"))
    if src == "seatgeek":
        return links.seatgeek_url(row.get("sg_url"), row.get("display_id"))
    if src == "gotickets":
        return links.gotickets_url(row.get("gt_event_id"), row.get("gt_section_id"))
    return None


def _shape_listing(
    src: str, row: dict[str, Any], qty: int, fee: Fee, event_id: int, storefront_base: str | None
) -> dict[str, Any]:
    unit = float(row["unit_price"])
    return {
        "section": row.get("section"),
        "row": row.get("row"),
        "quantity": int(row["quantity"]) if row.get("quantity") is not None else None,
        "unit_price": round(unit, 2),
        "total": total_price(fee, unit, qty),
        "buy_url": _buy_url(src, row, event_id, storefront_base),
        "tags": _tags(row),
    }


def _status_for_empty(src: str, event: dict[str, Any], by_src: dict[str, list]) -> str:
    """No rows at all for this source: distinguish 'never listed' from 'no fresh capture'."""
    if src == "seatgeek":
        return STATUS_NO_FRESH if event.get("sg_event_id") is not None else STATUS_NOT_LISTED
    if src == "gotickets":
        return STATUS_NO_FRESH if event.get("gt_event_id") is not None else STATUS_NOT_LISTED
    tevo_fresh = bool(by_src.get("vibepass") or by_src.get("tevo_exchange"))
    # vibepass with a fresh TEvo capture but no owned rows = we hold nothing for this event.
    return STATUS_NOT_LISTED if tevo_fresh else STATUS_NO_FRESH


def shape_event(event: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": int(event["id"]),
        "name": event.get("name"),
        "starts_at_local": event.get("starts_at_local"),
        "venue": event.get("venue_name"),
        "location": event.get("venue_location"),
        "performer": event.get("performer"),
        "event_type": event.get("event_type"),
        "listed_on": {
            "seatgeek": event.get("sg_event_id") is not None,
            "gotickets": event.get("gt_event_id") is not None,
        },
    }


def build_compare(
    event: dict[str, Any],
    rows: list[dict[str, Any]],
    *,
    qty: int,
    fee_model: dict[str, Fee],
    storefront_base: str | None,
    max_age_hours: int,
    now: datetime | None = None,
) -> dict[str, Any]:
    now = now or datetime.now(UTC)
    event_id = int(event["id"])
    by_src: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        by_src.setdefault(row["src"], []).append(row)

    sources: list[dict[str, Any]] = []
    for src in SOURCES:
        meta = SOURCE_META[src]
        fee = fee_model.get(src, Fee())
        srows = by_src.get(src, [])
        entry: dict[str, Any] = {
            "key": src,
            "label": meta["label"],
            "buyable": meta["buyable"],
            "kind": meta["kind"],
            "status": STATUS_NO_FRESH,
            "listings_total": 0,
            "listings_for_qty": 0,
            "captured_at": None,
            "age_minutes": None,
            "cheapest": None,
            "ladder": [],
        }
        if meta.get("note"):
            entry["note"] = meta["note"]
        if not srows:
            entry["status"] = _status_for_empty(src, event, by_src)
            sources.append(entry)
            continue
        head = srows[0]
        captured = head.get("captured_at")
        entry["listings_total"] = int(head.get("listings_total") or 0)
        entry["listings_for_qty"] = int(head.get("listings_for_qty") or 0)
        entry["captured_at"] = captured.isoformat() if isinstance(captured, datetime) else captured
        entry["age_minutes"] = (
            _age_minutes(captured, now) if isinstance(captured, datetime) else None
        )
        ladder = [
            _shape_listing(src, r, qty, fee, event_id, storefront_base)
            for r in srows
            if r.get("section") is not None or r.get("unit_price") is not None
        ]
        entry["ladder"] = ladder
        entry["cheapest"] = ladder[0] if ladder else None
        entry["status"] = STATUS_PRICED if ladder else STATUS_NO_MATCH
        sources.append(entry)

    priced_buyable = [s for s in sources if s["cheapest"] and s["buyable"]]
    priced_any = [s for s in sources if s["cheapest"]]
    cheapest_buyable = min(priced_buyable, key=lambda s: s["cheapest"]["total"], default=None)
    cheapest_any = min(priced_any, key=lambda s: s["cheapest"]["total"], default=None)

    return {
        "event": shape_event(event),
        "qty": qty,
        "max_age_hours": max_age_hours,
        "generated_at": now.isoformat(),
        "sources": sources,
        "cheapest_buyable": cheapest_buyable["key"] if cheapest_buyable else None,
        "cheapest_any": cheapest_any["key"] if cheapest_any else None,
        "fees_note": "Totals are for the requested quantity. SeatGeek and GoTickets prices "
        "are all-in as reported by the marketplace; the VibePass total applies the "
        "configured storefront fee schedule.",
    }


def walk_keys(obj: Any):
    """Yield every dict key in a nested structure (used by the whitelist test)."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield k
            yield from walk_keys(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from walk_keys(v)
