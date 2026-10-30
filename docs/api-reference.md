# Partner API (exos-api)

A REST API over one organization's data, for integrations: CRM and spreadsheet sync, a venue's own site, a box
office or door app, reporting. Reads everywhere; writes run the dashboard's own SQL (see *Writes* below). The full reference, with every endpoint, parameter and example, is the public page
**`/developers`** (`/bridge/developers`), generated from `docs/api/*.json`; `openapi.json` sits next to it.

- **Base URL:** `https://<project-ref>.supabase.co/functions/v1/exos-api`, paths under `/v1` (`/v1/events`). Each
  path also answers without `/v1`, for clients of the first release.
- **Code:** `supabase/functions/exos-api/index.ts` (the edge function), `exos-api/core.ts` (the core routes:
  event, ticket-type, add-on and promo-code writes, publish blockers, tickets and check-in, refunds, comps,
  guest lists, disputes, payouts, POS items, the write log), `supabase/functions/_shared/api/` (`routes.ts` the
  route table, `scopes.ts` the scopes, `paging.ts` page/per_page, `body.ts` capped write bodies) and
  `_shared/refundRun.ts` (the Stripe half of a refund, shared with `exos-refund`). Pure TypeScript, so vitest
  imports the same files.
- **Migrations:** `20260616200000` (keys, webhooks), `20260925020000` (rate limiter), `20261027090000` (scopes,
  the 10-key cap), `20261031110000` (writes: `exos_api_write`, the write log, publish blockers, `refunds:write`).
  SQL harnesses: `tests/exos/test_api_scopes.sql`, `tests/exos/test_core_api.sql`; by hand:
  `tests/exos/race_core_api.sh`.
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
  key, `402` a refund Stripe refused, `403` scope (or, for a write, the creator's role), `404` unknown path or
  another org's id, `405` an unknown method, `409` publish blockers / sold items / duplicates, `413` body over 64 KB,
  `500`, `502` a refund Stripe didn't answer (resend with the same key), `503`. The SQLSTATEs behind them are mapped
  in `sqlError()` (`core.ts`).

## Adding a route

1. A row in `ROUTES` (`_shared/api/routes.ts`): id, method, auth, path, scope, paged. Writes need a `:write` scope.
2. A `case` for that id in `handle()` in `exos-api/index.ts` (or `handleCore()` in `core.ts`). Select explicit
   columns; never secrets (barcode secrets, webhook secrets, reserved emails). Scope every query to the key's org.
   A write is a new action in `exos_api_write` (and `_exos_api_action_scope`) that pins its target to the org
   and calls the dashboard's existing function: never re-implement a business rule in TypeScript.
3. An endpoint in the right `docs/api/<area>.json` with the same `id`, the path under `/v1`, the same `scope`,
   its parameters (`page`/`per_page` if paged), and a response example with the columns it selects.

`src/lib/apiReference.test.ts` fails until all three agree: every route documented once with the same scope and
paging, every documented endpoint routed. `scripts/api-spec.mjs` validates the docs (`npm run api-spec -- --check`)
and writes `public/api-spec.json` + `public/openapi.json` (gitignored); the Vite plugin in `vite.config.ts` runs it
on every build and in dev, and a spec that does not validate fails the build.
