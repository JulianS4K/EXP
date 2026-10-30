# Partner API (exos-api)

A REST API over one organization's data, for integrations: CRM and spreadsheet sync, a venue's own
site, reporting, booking tools. Everything is read-only except the sales counts (tickets sold on other
platforms) and booking (venues, rooms, holds, the show schedule, staff notes and contacts), which partners
can also write (docs/booking.md). The full reference, with every endpoint, parameter and example, is the public page
**`/developers`** (`/bridge/developers`), generated from `docs/api/*.json`; `openapi.json` sits next to it.

- **Base URL:** `https://<project-ref>.supabase.co/functions/v1/exos-api`, paths under `/v1` (`/v1/events`). Each
  path also answers without `/v1`, for clients of the first release.
- **Code:** `supabase/functions/exos-api/index.ts` (the edge function), `supabase/functions/_shared/api/`
  (`routes.ts` the route table, `scopes.ts` the scopes, `paging.ts` page/per_page, `booking.ts` the booking
  bodies). Pure TypeScript, so vitest imports the same files.
- **Migrations:** `20260616200000` (keys, webhooks), `20260925020000` (rate limiter), `20261027090000` (scopes,
  the 10-key cap), `20261030120000` (sales counts), `20261030100000` (booking). SQL harnesses:
  `tests/exos/test_api_scopes.sql`, `tests/exos/test_sales_counts.sql`, `tests/exos/test_booking.sql`.
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

## Paging, limits, errors

- Paged lists take `?page` (default 1) and `?per_page` (default 50, max 200) and answer
  `{ data, meta: { page, per_page, total, total_pages } }`. Unpaged lists answer `{ data }`.
- 120 requests per key per minute; over it, `429` with `Retry-After`. If the limiter fails, `503` (no limiter, no
  answer: the API returns personal data).
- Errors are `{ "error": "…" }`: `400` bad paging, filter or body, `401` missing or invalid key, `403` scope,
  `404` unknown path or another org's id, `405` a method the path doesn't answer (`Allow` lists the ones it
  does), `409` a write conflict, `413` a body over 64 KB (2 MB of CSV for a sales-count import), `415` a body
  that is neither JSON nor form-encoded, `422` a CSV import with errors, `500`, `503`.
- Bodies are read through `_shared/api/body.ts` (`readCapped`: counted while streaming, never read in full past
  the cap).

## Writes

Sales counts and booking routes write (POST / PUT / PATCH / DELETE, JSON body, a `:write` scope). The function
runs with the service role, so every query names the key's org itself. Hold writes call the `_exos_hold_*` SQL
functions (levels, promotion and convert in one transaction, `hold.*` webhooks); the other tables are written as
rows and their triggers and checks validate them. The SQL raises with fixed codes and `bookingDbError()`
(`_shared/api/booking.ts`) maps them: `22023` → 400, `P0002` → 404, `23505` / `55000` / `54000` → 409.
Opendate-style spellings answer the same routes through `aliases` in `routes.ts` (`/holds/:id/convert_to_confirm`,
`/venue_ownerships`, `/confirms/:id/show_activities`, `/calendar_event_contacts`).

## Adding a route

1. A row in `ROUTES` (`_shared/api/routes.ts`): id, method, path, scope (`:read` for GET, `:write` otherwise),
   paged, and any aliases.
2. A `case` for that id in `handle()` in `exos-api/index.ts`. Select explicit columns; never secrets (barcode
   secrets, webhook secrets, reserved emails). Scope every query to the key's org.
3. An endpoint in the right `docs/api/<area>.json` with the same `id`, the path under `/v1`, the same `scope`,
   its parameters (`page`/`per_page` if paged), and a response example with the columns it selects.

`src/lib/apiReference.test.ts` fails until all three agree: every route documented once with the same scope and
paging, every documented endpoint routed. `scripts/api-spec.mjs` validates the docs (`npm run api-spec -- --check`)
and writes `public/api-spec.json` + `public/openapi.json` (gitignored); the Vite plugin in `vite.config.ts` runs it
on every build and in dev, and a spec that does not validate fails the build.
