from datetime import UTC, datetime

from exp.compare import FORBIDDEN_KEYS, SOURCES, build_compare, walk_keys
from tests.conftest import NOW, event_row, listing, sample_rows

STORE = "https://store.example"


def build(rows, fee_model, event=None, qty=2):
    return build_compare(
        event or event_row(),
        rows,
        qty=qty,
        fee_model=fee_model,
        storefront_base=STORE,
        max_age_hours=24,
        now=NOW,
    )


def test_sources_are_ordered_and_complete(fee_model):
    out = build(sample_rows(), fee_model)
    assert [s["key"] for s in out["sources"]] == list(SOURCES)


def test_cheapest_buyable_ignores_the_wholesale_exchange(fee_model):
    out = build(sample_rows(), fee_model)
    assert out["cheapest_any"] == "tevo_exchange"  # 31.00 is cheapest but not buyable
    assert out["cheapest_buyable"] == "gotickets"  # 38.70 all-in
    exchange = next(s for s in out["sources"] if s["key"] == "tevo_exchange")
    assert exchange["buyable"] is False
    assert exchange["cheapest"]["buy_url"] is None


def test_totals_are_for_requested_quantity(fee_model):
    out = build(sample_rows(), fee_model, qty=2)
    by = {s["key"]: s for s in out["sources"]}
    assert by["gotickets"]["cheapest"]["total"] == 77.4
    assert by["seatgeek"]["cheapest"]["total"] == 108.52
    assert by["vibepass"]["cheapest"]["total"] == 80.8


def test_buy_links_follow_both_or_neither(fee_model):
    out = build(sample_rows(), fee_model)
    by = {s["key"]: s for s in out["sources"]}
    assert by["seatgeek"]["cheapest"]["buy_url"].endswith("#listing=A6rs2KO4wGY")
    assert by["gotickets"]["cheapest"]["buy_url"].endswith("sections=9911")
    assert by["vibepass"]["cheapest"]["buy_url"] == f"{STORE}/store/event/3091467?section=205"

    rows = [listing("seatgeek", sg_url=None, display_id="abc")]
    out = build(rows, fee_model)
    sg = next(s for s in out["sources"] if s["key"] == "seatgeek")
    assert sg["status"] == "priced" and sg["cheapest"]["buy_url"] is None


def test_no_broker_field_ever_reaches_the_fan(fee_model):
    out = build(sample_rows(), fee_model)
    leaked = FORBIDDEN_KEYS.intersection(set(walk_keys(out)))
    assert not leaked, f"broker-only keys leaked: {sorted(leaked)}"


def test_empty_sources_distinguish_not_listed_from_no_fresh(fee_model):
    # Event known on SeatGeek, not on GoTickets; only exchange rows fresh.
    ev = event_row(gt_event_id=None)
    out = build([listing("tevo_exchange")], fee_model, event=ev)
    by = {s["key"]: s for s in out["sources"]}
    assert by["seatgeek"]["status"] == "no_fresh_prices"
    assert by["gotickets"]["status"] == "not_listed"
    assert by["vibepass"]["status"] == "not_listed"  # TEvo fresh, but we hold nothing
    assert out["cheapest_buyable"] is None

    out = build([], fee_model, event=ev)
    by = {s["key"]: s for s in out["sources"]}
    assert by["vibepass"]["status"] == "no_fresh_prices"
    assert by["tevo_exchange"]["status"] == "no_fresh_prices"


def test_count_only_row_reports_no_match_for_qty(fee_model):
    row = listing("seatgeek", section=None, row=None, quantity=None, unit_price=None, rn=None)
    row["listings_total"], row["listings_for_qty"] = 12, 0
    out = build([row], fee_model)
    sg = next(s for s in out["sources"] if s["key"] == "seatgeek")
    assert sg["status"] == "no_match_for_qty"
    assert sg["listings_total"] == 12 and sg["cheapest"] is None and sg["ladder"] == []


def test_age_and_tags(fee_model):
    out = build(sample_rows(), fee_model)
    gt = next(s for s in out["sources"] if s["key"] == "gotickets")
    assert gt["age_minutes"] == 7
    assert gt["cheapest"]["tags"] == ["limited view"]
    assert out["generated_at"] == datetime(2026, 9, 11, 4, 0, tzinfo=UTC).isoformat()
