from exp.compare import COMPARE_SQL
from exp.search import normalise_query
from tests.conftest import FakeDb, event_row, sample_rows


def test_healthz_reports_db_state(client):
    c = client(None)
    r = c.get("/healthz")
    assert r.status_code == 200 and r.json() == {"ok": True, "db_configured": False}


def test_api_503_without_database(client):
    c = client(None)
    assert c.get("/api/search?q=yankees").status_code == 503
    assert c.get("/api/events/1/compare").status_code == 503


def test_compare_happy_path_and_params(client):
    db = FakeDb(events=[event_row()], rows=sample_rows())
    c = client(db)
    r = c.get("/api/events/3091467/compare?qty=2")
    assert r.status_code == 200
    body = r.json()
    assert body["event"]["id"] == 3091467
    assert body["cheapest_buyable"] == "gotickets"
    compare_call = next(p for s, p in db.calls if s == COMPARE_SQL)
    assert compare_call["qty"] == 2 and compare_call["event_id"] == 3091467
    assert "own_brokerage_id" in compare_call and "ladder" in compare_call
    assert r.headers["Content-Security-Policy"].startswith("default-src 'self'")


def test_compare_is_cached_per_event_and_qty(client):
    db = FakeDb(events=[event_row()], rows=sample_rows())
    c = client(db)
    c.get("/api/events/3091467/compare?qty=2")
    c.get("/api/events/3091467/compare?qty=2")
    c.get("/api/events/3091467/compare?qty=4")
    assert sum(1 for s, _ in db.calls if s == COMPARE_SQL) == 2


def test_compare_validates_qty_and_unknown_event(client):
    c = client(FakeDb(events=[], rows=[]))
    assert c.get("/api/events/3091467/compare?qty=0").status_code == 422
    assert c.get("/api/events/3091467/compare?qty=99").status_code == 422
    assert c.get("/api/events/999/compare").status_code == 404


def test_search_validation_and_shape(client):
    db = FakeDb(search=[{"id": 1, "name": "A", "starts_at_local": "2026-09-13 13:35:00",
                         "venue_name": "V", "venue_location": "L", "performer": "P",
                         "event_type": "sports"}])
    c = client(db)
    assert c.get("/api/search?q=a").status_code == 400
    r = c.get("/api/search?q=yank")
    assert r.status_code == 200 and r.json()["events"][0]["venue"] == "V"


def test_normalise_query_escapes_like_wildcards():
    assert normalise_query("  50%  off_now ") == "50\\% off\\_now"
    assert normalise_query("a") is None
    assert normalise_query(None) is None


def test_index_serves_page(client):
    c = client(None)
    r = c.get("/")
    assert r.status_code == 200 and "Compare" in r.text
