# Partner API (exos-api)

A REST API over one organization's data, for integrations: CRM and spreadsheet sync, a venue's own
site, reporting, a box office (organizer reservations), team management. It also carries Opendate's partner
contract for distribution partners under `/v1/public/…` (docs/partner-sales.md). The full reference, with every endpoint, parameter and example, is the public page
**`/developers`** (`/bridge/developers`), generated from `docs/api/*.json`; `openapi.json` sits next to it.

- **Base URL:** `https://<project-ref>.supabase.co/functions/v1/exos-api`, paths under `/v1` (`/v1/events`). Each
  path also answers without `/v1`, for clients of the first release.
- **Code:** `supabase/functions/exos-api/index.ts` (the edge function), `supabase/functions/_shared/api/`
  (`routes.ts` the route table, `scopes.ts` the scopes, `paging.ts` page/per_page, `body.ts` capped write
  bodies, `credentials.ts` user tokens), `supabase/functions/_shared/partners/sales.ts` (partner request
  parsing). Pure TypeScript, so vitest imports the same files.
- **Migrations:** `20260616200000` (keys, webhooks), `20260925020000` (rate limiter), `20261027090000` (scopes,
  the 10-key cap), `20261031130000` (partner sales), `20261031130500` (personal access tokens, OAuth apps).
  SQL harnesses: `tests/exos/test_api_scopes.sql`, `test_partner_sales.sql`, `test_developer_platform.sql`.
- **Deploy:** `exos-api` takes an API key, not a Supabase JWT, so it is deployed with `--no-verify-jwt`.

## Auth and scopes

`Authorization: Bearer sk_live_…`. Owners and managers create keys in Org settings → Developer
(`src/components/DeveloperSettings.tsx`), picking scopes; the key is shown once and stored as a SHA-256 hash.
At most 10 active keys per org. Keys are revoked automatically when their creator leaves the org.

The same header takes a member's personal access token (`exos_pat_…`) or an app's OAuth access token
(`exos_oat_…`): both act as their user in one org, with their scopes narrowed on every request to what the
user's current role allows (docs/developer-platform.md). Partner routes (`auth: 'partner_key'`) take a partner
key instead (`?shared_key=dk_live_…`, docs/partner-sales.md).

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
- Errors are `{ "error": "…" }`: `400` bad paging, filter or body, `401` missing or invalid key, `403` scope (or a
  user token whose user left the org), `404` unknown path or another org's id, `405` a method the path doesn't
  answer, `409` sold out / conflict, `410` an expired reservation, `413` a body over 64 KB, `422` not available,
  `500`, `503`. Write bodies are JSON or form-encoded, read with a byte cap (`body.ts`).

## Adding a route

1. A row in `ROUTES` (`_shared/api/routes.ts`): id, method, path, auth, scope, paged.
2. A `case` for that id in `handle()` in `exos-api/index.ts`. Select explicit columns; never secrets (barcode
   secrets, webhook secrets, reserved emails). Scope every query to the key's org. Writes go through a
   service-role SQL function that takes the org explicitly and raises SQLSTATEs `RPC_STATUS` maps.
3. An endpoint in the right `docs/api/<area>.json` with the same `id`, the path under `/v1`, the same `scope`,
   its parameters (`page`/`per_page` if paged), and a response example with the columns it selects.

`src/lib/apiReference.test.ts` fails until all three agree: every route documented once with the same scope and
paging, every documented endpoint routed. `scripts/api-spec.mjs` validates the docs (`npm run api-spec -- --check`)
and writes `public/api-spec.json` + `public/openapi.json` (gitignored); the Vite plugin in `vite.config.ts` runs it
on every build and in dev, and a spec that does not validate fails the build.
