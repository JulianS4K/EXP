# Exos for AI assistants (MCP)

Exos runs a remote [Model Context Protocol](https://modelcontextprotocol.io) server, so fans and organizers can
use Exos from Claude, ChatGPT and any other MCP client. It's one server for every assistant: MCP is the shared
standard, so a new assistant that speaks it works without new code.

- **Endpoint:** `https://<project>.supabase.co/functions/v1/exos-mcp` (Streamable HTTP, stateless: `POST` only).
- **Organizer sign-in URL:** `https://<project>.supabase.co/functions/v1/exos-mcp/organizer`: the same server, but
  without a credential it answers 401 with the OAuth metadata, which is what makes claude.ai and ChatGPT start a
  sign-in. Use it for organizers; the plain URL stays open for fans.
- **Code:** `supabase/functions/exos-mcp/index.ts` (HTTP, auth, rate limits, database reads);
  `supabase/functions/_shared/mcp/protocol.ts` (JSON-RPC and MCP, no dependencies);
  `supabase/functions/_shared/mcp/exosTools.ts` (the tools), `_shared/mcp/exosWriteTools.ts` (the write tools),
  `_shared/mcp/discovery.ts` (OAuth discovery). Tests: `src/lib/mcp/mcp.test.ts`, `src/lib/mcp/mcpWrites.test.ts`,
  `supabase/functions/_shared/mcp/discovery_test.ts` (Deno), `tests/exos/test_mcp.sql`, `tests/exos/test_mcp_writes.sql`.
- **Migrations:** `20260929060000_exos_mcp.sql` (report functions and a rate limiter, service role only);
  `20261119130000_exos_mcp_writes.sql` (the write tools: user-token writes, confirmations, the hourly cap, the
  MCP write log).

## Tools

Nothing is ever bought or held; a purchase is always a link the person opens. The only writes are the three
organizer event tools below.

| Tool | Who | What it does |
|---|---|---|
| `search_events` | anyone | Upcoming published events by keyword, city, date range |
| `get_event` | anyone | One event: date, venue, description, ticket types with **all-in** price, on-sale status, roughly how many left (what Exos itself can sell: `exos_public_tiers.available`, so seats held for S4K or a marketplace never show; mig `20261014160000`) |
| `get_ticket_link` | anyone | A checkout link with the ticket type and quantity in the cart (`/checkout?products=…`, tagged `utm_source=ai_assistant`, optional promoter code). The person finishes checkout. |
| `search`, `fetch` | anyone | The same event data in the shape ChatGPT connectors and deep research expect (`{results:[{id,title,url}]}` / `{id,title,text,url,metadata}`) |
| `my_events` | organizer key | The org's events and tickets sold |
| `event_sales` | organizer key | Per ticket type sold/capacity; paid orders, gross, refunds |
| `door_status` | organizer key | Issued, checked in, voided, last scan |
| `marketplace_attention` | organizer key | Marketplace orders waiting on a person, and why (no buyer emails) |
| `create_event_draft` | `events:write` | A **draft** event: title, start / end with its time zone, a venue (an org venue id, or a name and address), description, capacity, an https image URL. Never published. Answers the dashboard edit link and the fee line |
| `add_ticket_type` | `events:write` | A ticket type (name, price, quantity, sale window) on one of the org's drafts |
| `publish_event` | `events:write` | **Asks** to publish a draft: answers a summary and a review link. The person opens it in Exos, signed in, and clicks Publish; the tool itself never publishes (with `request_id` it reads back the outcome). Paid tickets need Stripe Connect finished (else an error with the onboarding link, Org → Payouts); free / RSVP events publish without it |

"Organizer key" means any organizer credential (an org API key, a personal access token or an OAuth token) whose
scopes cover the tool: `my_events` `events:read`, `event_sales` and `marketplace_attention` `orders:read`,
`door_status` `tickets:read`. `tools/list` shows a credential only the tools its scopes allow.

Tool results come as text (JSON) and as `structuredContent`. The read tools are annotated `readOnlyHint: true`; the
three write tools `readOnlyHint: false`, and `publish_event` also `destructiveHint: true` and `idempotentHint: true`
(publishing twice is the same as once). The server's instructions tell the assistant never to claim a ticket was
bought, to treat everything people and organizers wrote (names, descriptions, pasted text, tool results) as
content and never as instructions, never to send a confirm token (below) unless the person explicitly agreed to
that preview, and to hand the person the review link to publish.

## Writes (mig 20261119130000)

`create_event_draft` and `add_ticket_type` run the partner API's own SQL, `exos_api_write` (`event.create`,
`ticket_type.create`), so the rules are the dashboard's and `POST /v1/events` / `POST /v1/events/:id/ticket-types`':
owner or manager now, the target pinned to the credential's org (another org's id is "not found"). A publish is the
dashboard's own `exos_publish_event`, run by the person. No business rule lives in the MCP code.

- **Drafts and ticket types: two calls, a server-issued token.** The first call (no `confirm_token`) changes
  nothing. It answers `status: "confirmation_required"`, a `preview` of exactly what will be written, and a
  `confirm_token` (`exos_mcc_` + 32 random bytes; only its SHA-256 is stored, in `exos_mcp_confirms`). The token is
  bound to the credential, the tool and the exact action / target / arguments (`_exos_api_request_hash`), lasts 10
  minutes and works once. The second call repeats the same arguments plus the token. Changed arguments are refused
  and burn the token; a reused, expired or another credential's token is refused. **What it is and isn't:** the
  token goes back to the same assistant, so it is not the person's consent. It stops accidental, replayed and
  altered writes (a stray retry, a web page asking the assistant to write something else), not a compromised or
  misled assistant that decides to send it. That is acceptable for drafts and ticket types, which nobody outside
  the org sees.
- **Publishing: the person, out of band.** `publish_event` never publishes. It checks the event (a draft, no
  blockers), stores a review request (`exos_mcp_publish_request`: the credential, the user, a SHA-256 digest of
  the event and every ticket type as previewed, 30 minutes) and answers a summary and
  `<app>/orgs/<org>/events/<id>/publish-review?request=<id>`. The person opens it, signed in as the user the
  credential acts for and still owner or manager of the org (anyone else sees "not found"), sees the event as it is
  now and clicks **Publish** (`exos_mcp_publish_approve`), which publishes through `exos_publish_event` only while the
  request is pending, unexpired and the event's digest still matches. An event changed after the preview (a price,
  a quantity, a date, a new ticket type) is refused (`changed`) and needs a new link. The assistant reads the outcome
  with `publish_event` + `request_id`. MCP's elicitation (a form the client shows the person) isn't used: it needs
  the server to send a request to the client mid-call, and this server is stateless HTTP with no server-to-client
  channel, so the review link is the out-of-band step for every client.
- **Drafts stay private.** `search_events`, `get_event`, `search`, `fetch`, the event page and the feeds read
  `exos_public_events`, which shows published events only (`test_mcp_writes.sql` M3).
- **The fee line.** `create_event_draft` (preview and result) and `add_ticket_type` say plainly whether the event is
  on the free tier: an event whose size (its capacity, capped by what its ticket types add up to) is under 150
  (`FREE_TIER_MAX_CAPACITY` = 149, `exos_event_is_free_tier`) pays no Exos fee; at 150 or more, the standard Exos fee (2% of each
  order, paid by the organizer, the first 6 months free). The result's line comes from SQL
  (`exos_mcp_fee_outcome`); the preview's from the same rule in TypeScript.
- **Venues.** `venue_id` copies the org venue's name and address onto the event (the event API writes no venue
  link; link the venue record in the dashboard if you need it). A venue by address is saved on the event; the map
  pin comes from the existing geocode path (`exos-geocode`, run from the event editor). The MCP server calls no
  geocoder itself.
- **Who.** Only an owner or manager (now) gets a confirm token or a review link; anyone else is refused before
  anything is stored or counted.
- **Limits.** 20 writes that ran (`done`) an hour per org (`mcp_writes_per_hour`); refusals don't count, so a
  member who can't write can't use up the org's hour. 60 attempts an hour per credential, every status
  (`mcp_attempts_per_hour`); past it the refusal isn't even logged, so a flood can't grow the log. At most 30 open
  confirm tokens and 10 open review links per credential. On top of the per-minute limit below. Over the org cap:
  an error with the wait, and the confirm token stays usable.
- **Audit.** Every attempt is a row in `exos_mcp_writes` (credential kind and id, the acting user, tool, route,
  action, target, event, status `done` / `failed` / `blocked` / `refused` and the `reason`: `credential`, `role`,
  `confirm_invalid`, `confirm_used`, `confirm_expired`, `confirm_mismatch`, `rate_limited`, `changed`, `not_found`,
  `not_draft`, `blockers`; owner / manager can read it). Writes that ran and publishes add an org audit row
  `mcp.write` (source `mcp`, `entity_id` = that row's id; a publish carries `approved: review_page`); refusals stay
  out of the append-only org audit. Drafts and ticket types also log in `exos_api_writes` with source `mcp` and the
  credential, and the audit rows the write itself causes carry source `mcp`.
- **Credentials.** Org API keys write as their creator, as on REST. Personal access tokens and OAuth tokens write as
  their own user (docs/developer-platform.md "Writes as yourself"). An OAuth token writes through exos-mcp only if it
  was issued for exos-mcp's canonical URL (below).

## Auth

- **No auth:** the public tools. This works today in every client.
- **`Authorization: Bearer <credential>`:** adds the organizer tools for that credential's org: an Exos API key
  (`sk_live_…`, created in org settings), a personal access token (`exos_pat_…`) or an OAuth access token
  (`exos_oat_…`), checked exactly as `exos-api` checks them (docs/developer-platform.md). Keys and tokens are stored
  hashed; revoked ones, keys whose creator left the org (mig 20260929010000) and tokens whose user left are refused
  (401 / 403). A wrong credential is never quietly treated as "no credential".
- **OAuth (claude.ai and ChatGPT connectors):** Exos's own authorization server, `exos-oauth`
  (docs/developer-platform.md "OAuth apps"): authorization code + PKCE (S256), dynamic client registration
  (RFC 7591, behind `EXOS_OAUTH_DCR=on`), RFC 8414 metadata, refresh-token rotation. See "Sign in with OAuth" below.

## Sign in with OAuth

How a connector finds its way, per the MCP authorization spec (2025-06-18 and later):

exos-mcp's one canonical resource is `…/functions/v1/exos-mcp/organizer`, exactly (no trailing slash). Its
protected-resource metadata is served there only; the plain URL's well-known path answers 404.

1. The connector `POST`s to `…/exos-mcp/organizer` without a token. exos-mcp answers 401 with
   `WWW-Authenticate: Bearer realm="exos", resource_metadata="…/exos-mcp/organizer/.well-known/oauth-protected-resource",
   scope="events:read events:write orders:read tickets:read"`.
2. It reads that protected-resource metadata (RFC 9728): `resource` (the `/organizer` URL), `authorization_servers`
   (`EXOS_OAUTH_ISSUER`, default `…/functions/v1/exos-oauth`), `scopes_supported`.
3. It reads the authorization server's metadata. The issuer has a path, so of the spec's three discovery URLs only
   the third can be served by an edge function: `…/functions/v1/exos-oauth/.well-known/openid-configuration`. Exos
   serves the RFC 8414 document there, unchanged: only what `exos-oauth` supports (code + PKCE S256, refresh,
   revoke, introspect, DCR when on). It is not an OpenID provider (no ID tokens, no `jwks_uri`, no `openid` scope)
   and doesn't claim to be; MCP clients read only the OAuth fields. `…/exos-oauth/.well-known/oauth-authorization-server`
   answers too.
   The first two (`https://<host>/.well-known/…/functions/v1/exos-oauth`) sit at the host's root, which Supabase
   doesn't let a function answer; a client that tries only those needs a custom domain (below).
4. It registers itself (`POST …/exos-oauth/register`, needs `EXOS_OAUTH_DCR=on`; such apps are marked unverified on
   the consent screen), sends the person to `/authorize` with PKCE and `resource=<the /organizer URL>`, and the
   person signs in to Exos and approves on the consent screen (`/oauth/authorize`): an organization, what the app
   could see, and, listed apart, what it could change (each write scope can be unticked).
5. It exchanges the code (`/token`, PKCE) and calls `…/exos-mcp/organizer` with the access token.

**Audience (RFC 8707).** `exos_oauth_authorize_approve` accepts a `resource` only if it is exactly exos-api's
canonical URL (`…/functions/v1/exos-api`) or exos-mcp's (`…/functions/v1/exos-mcp/organizer`); anything else is
`invalid_target` (`_exos_oauth_resources()`; platform setting `oauth_resources` for another install). The token keeps
its resource, and each server holds it to its own:

| Token's resource | exos-mcp | exos-api |
|---|---|---|
| exos-mcp's URL | reads and writes | refused (401) |
| exos-api's URL | refused (401) | reads and writes |
| none | reads only (write tools hidden; SQL refuses) | reads only (the three user-token writes refused) |
| anything else | refused (401) | refused (401) |

So a token a connector got for exos-mcp can't be replayed at exos-api to skip the confirm token, the review link
and the caps, and a server that named exos-oauth as its authorization server can't get an Exos token at all. SQL
checks the same: `exos_api_write`'s token branch and the MCP functions take the caller's canonical URL and refuse an
OAuth token whose resource isn't exactly it. Access tokens last an hour; the connector refreshes them.

The token is the person, in the org they picked, held to the scopes they approved and their role there now: a
demotion, a removal, a revoked grant or a deleted app stops it on the next call.

### Operator steps (dashboard and secrets; nothing here is code)

1. Apply `20261119130000_exos_mcp_writes.sql` (after `20261118120000`), then redeploy `exos-api`, `exos-mcp` and
   `exos-oauth` (all `--no-verify-jwt`), then ship the SPA (the consent screen).
2. `exos-oauth` secrets: `EXOS_APP_BASE_URL` (https; without it `/authorize` answers 503) and
   **`EXOS_OAUTH_DCR=on`**. claude.ai and ChatGPT register themselves; without DCR the operator would have to
   register each connector as an app at `/developers/apps` and paste its client id (claude.ai's "advanced
   settings" accept one; ChatGPT's connector screen may not).
3. `exos-mcp` secrets: `EXOS_APP_BASE_URL` (links), and `EXOS_OAUTH_ISSUER` only if the issuer isn't the default.
4. Supabase Auth: the consent page signs the person in with Supabase Auth, so keep **Confirm email** and the
   **CAPTCHA** on (docs/security.md "Operator settings").
5. Check it:
   `curl -si -X POST https://<project>.supabase.co/functions/v1/exos-mcp/organizer -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}'`
   must answer 401 with the `WWW-Authenticate` above;
   `curl -s https://<project>.supabase.co/functions/v1/exos-mcp/organizer/.well-known/oauth-protected-resource` and
   `curl -s https://<project>.supabase.co/functions/v1/exos-oauth/.well-known/openid-configuration` must answer JSON
   with a `registration_endpoint`.
6. Add the connector: claude.ai → Settings → Connectors → Add custom connector → the `/organizer` URL; ChatGPT →
   Settings → Connectors (developer mode) → the same URL with OAuth. Sign in, pick the org, approve, then ask it to
   "create a draft event …".
7. If a client only tries the root discovery URLs: put a custom domain in front (e.g. `api.<your domain>`) that
   serves `/.well-known/oauth-authorization-server` and `/.well-known/oauth-protected-resource` from
   `exos-oauth` / `exos-mcp`, and set `EXOS_OAUTH_ISSUER` to it. Not needed for the 2025-06-18 discovery order.
8. Optional: `exos_platform_settings` `mcp_writes_per_hour` (default 20), `mcp_attempts_per_hour` (default 60). On
   another install (not project `hzrizjeaxlqcxfrtczpq`), set `oauth_resources` to that project's two URLs
   (`["https://<ref>.supabase.co/functions/v1/exos-api", "https://<ref>.supabase.co/functions/v1/exos-mcp/organizer"]`),
   or every OAuth authorization with a resource is `invalid_target`.
9. The review page ships with the SPA (`/orgs/:orgId/events/:eventId/publish-review`); `EXOS_APP_BASE_URL` on
   exos-mcp must point at the SPA so the links work.

## Connecting

The client screens change often; the principle stays the same: add a custom MCP server with the URL above.

- **Claude (claude.ai, Desktop):** Settings → Connectors → Add custom connector → the endpoint URL (public tools).
- **Claude Code:**
  `claude mcp add --transport http exos https://<project>.supabase.co/functions/v1/exos-mcp`.
  For an organizer, add `--header "Authorization: Bearer sk_live_…"` (or a personal access token), or add the
  `/organizer` URL and sign in with OAuth.
- **Claude API:** the Messages API MCP connector (`mcp_servers: [{ type: "url", url, name: "exos",
  authorization_token }]`).
- **ChatGPT:** Settings → Connectors (developer mode) → add a custom MCP server with the URL. `search` and `fetch`
  make it usable in deep research too.
- **OpenAI API:** Responses API `tools: [{ type: "mcp", server_label: "exos", server_url, headers: { Authorization:
  "Bearer sk_live_…" }, require_approval: "never" }]`.
- **Anything else:** `POST` JSON-RPC 2.0 (`initialize`, `tools/list`, `tools/call`), protocol versions
  `2025-06-18`, `2025-03-26`, `2024-11-05`.

## Limits and safety

- 60 calls a minute per network without a key; 120 a minute per credential; 20 writes an hour per org (above). If
  the limiter itself errors, calls are refused (503).
- Request bodies are capped at 64 KB, batches at 20 messages, search results at 25.
- Search input is stripped to letters, numbers and a few punctuation marks before it reaches a PostgREST filter.
- Organizer reads are scoped in SQL to the key's org (`exos_mcp_event_sales` / `exos_mcp_door_status` return NULL
  for any other org's event); no tool returns buyer emails or barcode secrets.
- Unexpected errors reach the assistant as "something went wrong"; details go to the function log, redacted.

## Deploy (operator)

1. Apply `20260929060000_exos_mcp.sql` (and, for the write tools, `20261119130000_exos_mcp_writes.sql`: see
   "Operator steps" above).
2. `supabase functions deploy exos-mcp --no-verify-jwt`. Assistants don't send a Supabase JWT; the API key is
   checked in the function.
3. Secrets: `EXOS_APP_BASE_URL` (public app base for links, e.g. `https://…/bridge`). `SUPABASE_URL` and
   `SUPABASE_SERVICE_ROLE_KEY` are set by the platform. `EXOS_GUEST_IP_SALT` is optional.
4. Check it:
   `curl -s -X POST <url> -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'`.

## Next

- More write tools (comps, messages to ticket holders). Anything public or money-moving should use the review-link
  pattern, not a confirm token; each needs its action opened to user tokens in `_exos_api_user_token_actions` and
  its own review.
- MCP elicitation for publishing, once the server keeps a session (a server-to-client request mid-call).
- ChatGPT Apps SDK / MCP UI widgets (an event card with a Buy button) on top of the same tools.
- **Agent checkout** (operator direction 2026-10-14: Claude, ChatGPT and Meta). The assistant completes the
  purchase instead of handing a link: ChatGPT's Instant Checkout (Agentic Commerce Protocol: a product feed, then
  `create / update / complete checkout` endpoints the merchant hosts, paid with a delegated Stripe payment token),
  the same endpoints exposed as MCP tools for Claude, and Meta's checkout on the catalog products. All sell from
  the Exos + Eventbrite pool through the existing checkout (holds, quotas, the 250 rule doesn't apply: it's not
  resale). Blocked on Stripe going live (`docs/payments-go-live.md`); the product feed half is the catalog feed.
