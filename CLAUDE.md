# CLAUDE.md — EXP session rules

EXP is the fan-facing **cross-marketplace ticket price comparison** ("Trivago for tickets"), built as a read-only consumer of the Terminal-2 data plane. The product direction, live coverage numbers and phased plan live in Terminal-2 at `design/ticket-metasearch-2026-09-11.md` (PR JulianS4K/Terminal-2#974); this file holds the invariants every session must keep.

## Hard rules

1. **Read-only against the Terminal-2 database.** EXP connects with a read-only role and opens every connection with `default_transaction_read_only=on` (`exp/db.py`). No DDL, DML, cron or vault changes from this repo, ever. A schema change EXP needs (a public RPC, an index) is a migration **authored in Terminal-2** under its `MIGRATION_CONVENTIONS.md`, never here.
2. **No upstream marketplace calls.** There is no `*_client.py` in EXP and none may be added. TEvo, SeatGeek, GoTickets and every other source are read from Terminal-2's snapshot tables. A "refresh prices" feature enqueues a pull through Terminal-2's own queue; it never hits a marketplace API from a request handler.
3. **No checkout, holds or orders.** EXP hands the fan off via a buy link. The single-checkout ("Expedia") path is a separately authorised, security-CRIT change in Terminal-2 (`docs/buy_side_evo_gotickets.md`), not something to sketch here.
4. **Fans get only public data.** `exp/compare.py::FORBIDDEN_KEYS` is the whitelist's teeth and `tests/test_compare.py` walks every response. Wholesale prices, brokerage names, ownership flags, seller ids and raw payloads never leave the server. Add a field to a query only if you would print it on the ticket.
5. **A buy link is all-or-nothing.** Emit a listing-level URL only when every stored component exists (`exp/links.py`). Half a URL looks like a working link and sends someone to the wrong seats.
6. **Per-event, bounded SQL only.** `sql/compare.sql` reads the newest capture per source through the `(event, captured_at DESC)` indexes. Never widen it into a scan of `listings_snapshots` (tens of GB) or a cross-event aggregate; that belongs in a Terminal-2 view.

## Conventions

- Python 3.11, FastAPI, psycopg 3. Run: `pip install -r requirements-dev.txt && uvicorn server:app --reload`. Tests: `pytest -q`. Lint: `ruff check .`. CI runs both on every PR.
- SQL lives in `sql/*.sql` with `%(name)s` params; Python shaping in `exp/`; no SQL strings inside Python.
- Env in `.env.example`; `EXP_DATABASE_URL` is required in production and absent in tests (routes return 503, the fake DB in `tests/conftest.py` covers the rest).
- Fee model defaults in `exp/fees.py`; the VibePass fee schedule is a placeholder (zero) until the operator confirms it — say so in any UI copy that quotes a VibePass total.
- PR titles: `<type>(exp): <short imperative>`. Branch per task; CI green before merge.
