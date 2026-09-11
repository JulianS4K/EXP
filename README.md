# EXP — compare ticket prices across marketplaces

One event, one quantity, one price ladder: the cheapest total on every marketplace we observe, each row linking to where it can be bought. Our own inventory (the VibePass storefront) is one row among equals and is highlighted only when it actually wins.

EXP is the **Trivago shape** of the idea: read-only, click-out, no checkout. The **Expedia shape** (one checkout, we sell every row) is a later, separately authorised step; the design that gets from one to the other is in Terminal-2 at [`design/ticket-metasearch-2026-09-11.md`](https://github.com/JulianS4K/Terminal-2/pull/974).

## How it works

```
fan ──► EXP (FastAPI + static page)
             │  read-only role, statement timeout
             ▼
       Terminal-2 Supabase Postgres
         events · aq_event_map (hub)
         listings_snapshots (TEvo)       ─┐ newest capture per source,
         seatgeek_listings_snapshots     ─┤ qty-compatible rows, cheapest N
         gotickets_listings_snapshots    ─┘ (sql/compare.sql)
             │
             ▼
       per-source ladder → fee model → buy links
         VibePass  → /store/event/<id>?section=…
         SeatGeek  → <event url>#listing=<display_id>
         GoTickets → pro.gotickets.com/tickets/<id>/?sections=<section_id>
         Broker exchange → reference price only (no consumer buy path)
```

Every marketplace is read from Terminal-2's snapshot tables; EXP calls no marketplace API and writes nothing. See `CLAUDE.md` for the rules that keep it that way.

## Run it

```bash
pip install -r requirements-dev.txt
cp .env.example .env            # set EXP_DATABASE_URL to a READ-ONLY role
uvicorn server:app --reload     # http://127.0.0.1:8000
pytest -q && ruff check .
```

| Route | What |
|---|---|
| `GET /` | the compare page |
| `GET /api/search?q=` | upcoming events matching a name, performer or venue |
| `GET /api/events/{tevo_event_id}/compare?qty=2&max_age_hours=24` | the ladder (see below) |
| `GET /healthz` | liveness + whether a database is configured |

### Compare response, abridged

```json
{
  "event": {"id": 3091467, "name": "New York Mets at New York Yankees", "venue": "Yankee Stadium",
            "listed_on": {"seatgeek": true, "gotickets": true}},
  "qty": 2,
  "cheapest_buyable": "gotickets",
  "cheapest_any": "gotickets",
  "sources": [
    {"key": "vibepass",  "label": "VibePass",  "buyable": true,  "status": "priced",
     "listings_total": 324, "listings_for_qty": 270, "age_minutes": 3,
     "cheapest": {"section": "grandstand level 409", "row": "2", "quantity": 2,
                  "unit_price": 58.40, "total": 116.80, "buy_url": "https://…/store/event/3091467?section=…", "tags": []},
     "ladder": ["…up to 8 rows…"]},
    {"key": "seatgeek",  "…": "…"},
    {"key": "gotickets", "…": "…"},
    {"key": "tevo_exchange", "label": "Broker exchange", "buyable": false, "note": "Wholesale asks …"}
  ]
}
```

`status` is one of `priced`, `no_match_for_qty` (fresh listings, none sold in lots of `qty`), `no_fresh_prices` (listed there, nothing captured inside the window) or `not_listed`. Prices are totals for `qty`; SeatGeek and GoTickets are all-in as reported, the VibePass row applies the configured fee schedule (`EXP_FEE_MODEL_JSON`, default zero until confirmed).

## What the numbers mean today

Measured against production on 2026-09-11 for the Mets at Yankees game on 9/13, two seats: GoTickets $40.77 each, SeatGeek $47.37, broker exchange $47.71, VibePass $58.40. Coverage is TEvo × GoTickets at scale (thousands of events), SeatGeek only where Terminal-2's on-demand puller has been asked, and StubHub / Vivid / TickPick dark since the TicketsData contract lapsed. Widening that coverage is Terminal-2 work (phase 1 of the design doc), not an EXP change.

## Layout

```
server.py          FastAPI app: routes, headers, cache, rate limit
exp/compare.py     rows → fan-facing response (whitelist enforced here)
exp/fees.py        per-source fee model
exp/links.py       buy-link builders (all-or-nothing)
exp/search.py      event search
exp/db.py          read-only psycopg pool
sql/               event.sql · search.sql · compare.sql
static/            index.html · app.js · style.css
tests/             unit + API tests with an in-memory fake database
```
