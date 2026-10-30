# Partner API (exos-api)

A REST API over one organization's data, for integrations: CRM and spreadsheet sync, a venue's own
site, a box office or door app, reporting, booking tools. Reads everywhere. Core writes (events, ticket types,
add-ons, promo codes, the door, comps, refunds, guest lists, POS) run the dashboard's own SQL (see *Writes*
below); so do the sales counts (tickets sold on other
platforms), booking (venues, rooms, holds, the show schedule, staff notes and contacts; docs/booking.md),
offers, budgets, deals, finance, settlements and P&L (docs/offers-settlements.md), fan contacts and tags
(docs/fans.md; never payments or a fan's consent) and
artists, lineups and listing-feed shared keys, which partners can also
write (a `:write` scope, or `org:admin`
for shared keys); plus a public listing feed for listing sites under `/v1/public/…` (shared-key auth,
`docs/listing-feed.md`). The full reference, with every endpoint, parameter and example, is the public page
**`/developers`** (`/bridge/developers`), generated from `docs/api/*.json`; `openapi.json` sits next to it.

- **Base URL:** `https://<project-ref>.supabase.co/functions/v1/exos-api`, paths under `/v1` (`/v1/events`). Each
  path also answers without `/v1`, for clients of the first release.
- **Code:** `supabase/functions/exos-api/index.ts` (the edge function), `exos-api/core.ts` (the core routes:
  event, ticket-type, add-on and promo-code writes, publish blockers, tickets and check-in, refunds, comps,
  guest lists, disputes, payouts, POS items, the write log), `exos-api/finance.ts` (offers and finance),
  `supabase/functions/_shared/api/` (`routes.ts` the route table, `scopes.ts` the scopes, `paging.ts`
  page/per_page, `body.ts` capped write bodies, `booking.ts` the booking bodies) and `_shared/refundRun.ts` (the
  Stripe half of a refund, shared with `exos-refund`). Pure TypeScript, so vitest imports the same files.
- **Migrations:** `20260616200000` (keys, webhooks), `20260925020000` (rate limiter), `20261027090000` (scopes,
  the 10-key cap), `20261030120000` (sales counts), `20261030100000` (booking), `20261030110000` (artists,
  lineups, listing feed), `20261031100000` / `20261031100500` (offers, budgets, pools, deals, finance,
  settlements, P&L, ticket counts; `docs/offers-settlements.md`), `20261031110000` (core writes: `exos_api_write`,
  the write log, publish blockers, `refunds:write`), `20261031120000` (fans, tags, refund requests; `fans:read` /
  `fans:write`, docs/fans.md). SQL harnesses: `tests/exos/test_api_scopes.sql`, `tests/exos/test_fans.sql`,
  `tests/exos/test_sales_counts.sql`, `tests/exos/test_booking.sql`, `tests/exos/test_artists_feed.sql`,
  `tests/exos/test_offers_settlements.sql`, `tests/exos/test_core_api.sql`; by hand: `tests/exos/race_core_api.sh`.
- **Writes:** reads are GET. The sales counts (`POST /v1/sales-counts`, `PUT` / `DELETE
  /v1/sales-counts/:id`, `POST /v1/events/:id/sales-counts/import`) need `finance:write`; they call
  service-role RPCs (`exos_api_sales_count_put` / `_delete`) that re-check the event or row belongs to the key's
  org. Booking writes are below. A new write route needs a `:write` scope (`apiRoutes.test.ts` checks it) and the
  same shape: validate in the function, write through an RPC (or a query) that takes the key's org id.
- **Deploy:** `exos-api` takes an API key, not a Supabase JWT, so it is deployed with `--no-verify-jwt`.

## Auth and scopes

`Authorization: Bearer sk_live_…`. Owners and managers create keys in Org settings → Developer
(`src/components/DeveloperSettings.tsx`), picking scopes; the key is shown once and stored as a SHA-256 hash.
At most 10 active keys per org. Keys are revoked automatically when their creator leaves the org.

Each route needs one scope (`routes.ts`); a key without it gets `403 { error: "insufficient scope",
required_scope }` and `WWW-Authenticate: Bearer error="insufficient_scope"`. A `:write` scope covers its own
`:read`; the legacy `read` scope (every key made before 2026-10-27) covers every `:read`. `GET /v1/me` needs no
scope and returns the key's stored and effective scopes. The vocabulary is `SCOPES` in `scopes.ts` and
`exos_api_scope_names()` in SQL; `src/lib/apiScopes.test.ts` keeps them equal.

## Writes

Every write route calls one SQL function, `exos_api_write(key, action, target, args, idempotency_key)`, and
`core.ts` only shapes the request and the answer. The SQL function:

- runs as the **member who created the key**: it sets the transaction's JWT claims to them, so the dashboard's
  RPCs (`exos_issue_voucher`, `exos_issue_comp_batch`, `exos_refund_claim`, `exos_check_in_ticket`, the guest-list
  functions, …) see that member and check their role *now*. A key whose creator left the org can't write.
  Where the dashboard writes a table under RLS (events, ticket types, add-ons, POS items) it checks the policy's
  roles (owner / manager) and writes only whitelisted columns; server-owned ones (status, sold, org) are refused;
- pins every target to the key's org first (anything else is 404), and re-checks the key's scope per action;
- logs the write in `exos_api_writes` (`GET /v1/api-writes`, `org:admin`); refunds and comps are `money_moving`.

Bodies are JSON (fields, or wrapped `{ "event": { … } }` as Opendate sends them) or form-encoded, at most 64 KB,
read capped while streaming (`body.ts`). An `Idempotency-Key` header (8-100 of `A-Za-z0-9_.:-`) makes a write safe
to resend: the key is unique per API key, the first request claims it before doing the work (a concurrent twin
waits, then replays), and a later resend replays the stored answer; the same key on another action or target is
400. **Refunds require one**: it becomes the refund request's nonce, so a resend returns the same request and the
Stripe call reuses its idempotency key. Publishing (`POST /v1/events/:id/publish`) goes through
`exos_publish_event`, which refuses while `_exos_event_publish_blockers` lists anything (409 with the list); the
dashboard's publish toggle (EditEvent) calls the same function after saving.

## Paging, limits, errors

- Paged lists take `?page` (default 1) and `?per_page` (default 50, max 200) and answer
  `{ data, meta: { page, per_page, total, total_pages } }`. Unpaged lists answer `{ data }`.
- 120 requests per key per minute; over it, `429` with `Retry-After`. If the limiter fails, `503` (no limiter, no
  answer: the API returns personal data).
- Errors are `{ "error": "…" }`: `400` bad paging, filter, body field or Idempotency-Key, `401` missing or invalid
  key, `402` a refund Stripe refused, `403` scope (or, for a core write, the creator's role), `404` unknown path or
  another org's id, `405` a method the path doesn't answer (`Allow` lists the ones it does), `409` a write
  conflict (publish blockers, sold items, duplicates such as a tag or fan email, a taken permalink, a merged artist, the shared-key cap),
  `413` a body over 64 KB (2 MB of CSV for a sales-count import), `415` a body that is neither JSON nor
  form-encoded, `422` a CSV import with errors, `500`, `502` a refund Stripe didn't answer (resend with the same
  key), `503`. Core-API SQLSTATEs are mapped in `sqlError()` (`core.ts`).
- Bodies are read through `_shared/api/body.ts` (`readCapped`: counted while streaming, never read in full past
  the cap).

## Writes

Core writes go through one SQL entry point, `exos_api_write` (mig 20261031110000): it runs as the member who
created the key, pins the target to the key's org, re-checks the key's scope, calls the dashboard's own
function and logs the write in `exos_api_writes`; an Idempotency-Key replays any core write, and refunds need
one. Sales counts, booking, artists, lineups and listing keys write too (POST / PUT / PATCH / DELETE, JSON
body, a `:write` scope). The function runs with the service role, so every query names the key's org itself. Hold writes call the `_exos_hold_*` SQL
functions (levels, promotion and convert in one transaction, `hold.*` webhooks); the other tables are written as
rows and their triggers and checks validate them. The SQL raises with fixed codes and `bookingDbError()`
(`_shared/api/booking.ts`) maps them: `22023` → 400, `P0002` → 404, `23505` / `55000` / `54000` → 409.
Opendate-style spellings answer the same routes through `aliases` in `routes.ts` (`/holds/:id/convert_to_confirm`,
`/venue_ownerships`, `/confirms/:id/show_activities`, `/calendar_event_contacts`, `/v3_offers…`, `/v3_offer_pools`,
`/confirms/:id/settlements/summary`, `/confirms/:id/finance_items`, `/general_ledger_codes`). Offer, budget, finance and
settlement routes live in `exos-api/finance.ts` (bodies in `_shared/api/finance.ts`); the offer and settlement PDFs
and the P&L CSV are the only non-JSON answers besides the sales-count handlers (the handler returns a `Response`).

Artists, lineups and shared keys call service-role SQL functions that take the key's org explicitly
(`_exos_artist_save`, `_exos_artist_merge`, `_exos_lineup_save`, `_exos_listing_key_create` / `_revoke`); their
SQLSTATEs map to HTTP in `rpcError()` (after `bookingDbError()`). Fan contacts and tags write the same way and
map with `rpcError()` alone; they never touch payments or a fan's consent, and a fan's tags also need
`fans:read` / `fans:write` on top of the route's `events:*` scope.

The listing feed (`/v1/public/events`, alias `/v1/public/confirms`) is the one route family without an API key:
`auth: 'shared_key'` in `routes.ts`, its own handler (`listingFeed()`), Opendate's
`{ current_page, per_page, total_entries, total_pages, collection }` envelope (`paged: 'opendate'`), CORS `*`,
`Cache-Control: public, max-age=60`, an ETag, and its own 120/min bucket per key.

## Adding a route

1. A row in `ROUTES` (`_shared/api/routes.ts`): id, method, auth, path, scope (`:read` for GET, `:write`
   otherwise), paged, and any aliases.
2. A `case` for that id in `handle()` in `exos-api/index.ts` (or `handleCore()` in `core.ts`). Select explicit
   columns; never secrets (barcode secrets, webhook secrets, reserved emails). Scope every query to the key's org.
   A core write is a new action in `exos_api_write` (and `_exos_api_action_scope`) that pins its target to the org
   and calls the dashboard's existing function: never re-implement a business rule in TypeScript.
3. An endpoint in the right `docs/api/<area>.json` with the same `id`, the path under `/v1`, the same `scope`,
   its parameters (`page`/`per_page` if paged), and a response example with the columns it selects.

`src/lib/apiReference.test.ts` fails until all three agree: every route documented once with the same scope and
paging, every documented endpoint routed. `scripts/api-spec.mjs` validates the docs (`npm run api-spec -- --check`)
and writes `public/api-spec.json` + `public/openapi.json` (gitignored); the Vite plugin in `vite.config.ts` runs it
on every build and in dev, and a spec that does not validate fails the build.
