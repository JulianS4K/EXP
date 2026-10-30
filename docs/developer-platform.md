# Developer platform: personal tokens, OAuth apps, the team API

Three kinds of credential reach the partner API (`exos-api`, docs/api-reference.md) and the MCP server
(`exos-mcp`, docs/mcp.md), with the same routes, scopes, rate limits and org scoping:

| Credential | Looks like | Made by | Acts as | For |
|---|---|---|---|---|
| Org API key | `sk_live_…` | An owner / manager, Org settings → Developer | The organization, held to its scopes | Your server, your org |
| Personal access token | `exos_pat_…` | Any member, Profile → Developer | That member, in one org | Scripts, reports, an AI agent working for you |
| OAuth access token | `exos_oat_…` | An app, after a member approves it | That member, in the org they picked | Products other organizers connect |

- **Migration:** `supabase/migrations/20261031130500_exos_developer_platform.sql`. Harness:
  `tests/exos/test_developer_platform.sql`.
- **Code:** `supabase/functions/_shared/api/credentials.ts` (formats, the role map, PKCE, redirect rules),
  `exos-api` (credential resolution, team routes), `exos-oauth` (the authorization server), `exos-mcp`.
- **UI:** Profile → Developer (`DeveloperTokensPanel`: tokens and connected apps), `/developers/apps`
  (`DeveloperApps`: register apps), `/oauth/authorize` (`OAuthAuthorize`: the consent screen), Org settings →
  Connected apps (`OrgConnectedApps`, owners).

## Scopes follow the live role

The scopes are the API's (`_shared/api/scopes.ts`). A user token also acts as its user, so on **every request**
`exos_api_token_auth` reads the user's current membership and narrows the token's scopes to what that role may
grant (`exos_role_token_scopes`, mirrored by `ROLE_SCOPES` and kept equal by `src/lib/credentials.test.ts`):

| Role | The most a token of this member can do |
|---|---|
| owner | every scope |
| manager | everything but `webhooks:*` and `org:admin` |
| finance | `events:read`, `orders:read`, `tickets:read`, `booking:read`, `finance:read`, `finance:write`, `commerce:read` |
| content | `events:read`, `events:write`, `booking:read` |
| scanner | `events:read`, `tickets:read`, `checkin:write` |

A `:write` the role has lost still gives its `:read` if the role has that. So:

- **A demotion takes effect at once**, on the next request, with no token change.
- **Leaving** (membership deleted) or being **disabled** revokes the member's personal tokens and OAuth grants
  for that org (the offboarding trigger, `exos_tg_membership_offboard`, which already revoked their API keys and
  webhooks). Until the trigger has run, the membership check refuses them anyway (403).
- Some routes check the role on top of the scope: partner-key management and the team routes need an owner
  (a user token's user, or an API key's creator), and the per-tier partner switch an owner or manager.

## Personal access tokens

Profile → Developer: name, organization (a token is pinned to one, as Opendate's are), scopes your role allows,
expiry 30 / 90 / 365 days or none. Shown once (`exos_pat_` + 43 characters); only its SHA-256 and a
13-character prefix are kept. A confirmed email is required; at most 25 live tokens per user. Revoke in the same
panel, or with the token itself: `DELETE /v1/personal-access-tokens/current`.

## OAuth apps

Register at `/developers/apps`: name, homepage, redirect URIs, the scopes the app may ask for, and the type.

- **Confidential** (a server): gets a client secret (`exos_cs_…`), shown once, hashed, rotatable (the old one
  stops at once; issued tokens keep working).
- **Public** (browser, mobile, CLI, AI client): no secret, PKCE required.
- Redirect URIs: https, or http on `localhost` / `127.0.0.1` / `[::1]`; no fragment, credentials or wildcards;
  at most 10. The request must repeat one exactly. At most 20 apps per developer. Deleting an app revokes every
  grant and token it has.

### The flow

1. The app sends the user to `<exos-oauth>/authorize?response_type=code&client_id=…&redirect_uri=…&scope=…&state=…&code_challenge=…&code_challenge_method=S256`
   (optionally `resource=`). The function hands the browser to the app's consent page
   (`<EXOS_APP_BASE_URL>/oauth/authorize`) with the same query.
2. The consent page (signed in) shows the app (marked unverified if it registered itself), where it will send
   the user back, the scopes, and the user's organizations with what their role there can grant. A bad
   `client_id` or an unregistered redirect URI is shown on the page, never redirected to; other problems, and
   Deny, go back to the app as `error=…`.
3. Allow (`exos_oauth_authorize_approve`, the user's session): creates or updates the grant (one per app ×
   user × org, scopes narrowed to the role) and mints a single-use code for 10 minutes. The page redirects to
   the app with `code` and `state`.
4. The app calls `POST <exos-oauth>/token` (`grant_type=authorization_code`, `code`, `redirect_uri`,
   `code_verifier`; HTTP Basic or `client_secret_post`, or `client_id` alone for a public app). The code is
   spent whatever happens; a code presented twice revokes the tokens of its first exchange.
5. Access tokens last one hour, refresh tokens 60 days. A refresh token is single use: each refresh returns a
   new pair in the same family and retires the old pair. A used refresh token presented again means a copy
   leaked, so the whole family is revoked (`refresh.reuse_detected` in `exos_token_audit`) and the user
   authorizes again. A refresh may narrow the scopes, never widen them.

Also: `POST /revoke` (RFC 7009; a refresh token takes its family), `POST /introspect` (RFC 7662, the app's own
tokens, with the user's current role), `GET /.well-known/oauth-authorization-server` (RFC 8414), and
`POST /register` (RFC 7591 dynamic registration, for MCP clients): **off unless `EXOS_OAUTH_DCR=on`**; such apps
are marked unverified. Bodies are form-encoded or JSON, errors are `{ error, error_description }`, every answer
is `no-store`, and the endpoints share 30 requests a minute per network.

`exos-mcp` accepts personal and OAuth tokens with the same check as the API, answers
`GET /.well-known/oauth-protected-resource` (RFC 9728), and on a bad token says where to get one
(`WWW-Authenticate: Bearer resource_metadata=…`).

The finish-token pattern of the Eventbrite / Google sign-ins (`_shared/oauthFinish.ts`) solves a different
problem (Exos as an OAuth *client*, parking the provider's code until the starting user finishes); here Exos is
the authorization server and the code is minted in the signed-in user's own session, so it isn't needed.

### Connected apps

Members see the apps they connected in Profile → Developer and can disconnect them. Owners see every app
connected to their organization (who, which scopes, last use) in Org settings → Connected apps and can
disconnect any. Disconnecting revokes the grant and every token under it at once. Owners also read their org's
token audit (`exos_token_audit`, RLS).

## The team API

Opendate's teams map onto Exos organizations (`exos_orgs`, `exos_org_memberships`, `exos_org_invites`); the
routes are in `docs/api/team.json`: `GET/PATCH /v1/team`, `GET /v1/team/members`, `PATCH/DELETE
/v1/team/members/:id`, `GET/POST /v1/team/invitations`, `DELETE /v1/team/invitations/:id`, `GET /v1/team/roles`,
`GET /v1/me/memberships`. Owners only (as in the dashboard); owners themselves are changed in the dashboard.

## Setup

- `exos-oauth`: deploy with `--no-verify-jwt`. Secrets: `EXOS_APP_BASE_URL` (the consent page; without it
  `/authorize` answers 503). Optional `EXOS_OAUTH_ISSUER` (default `<SUPABASE_URL>/functions/v1/exos-oauth`),
  `EXOS_OAUTH_DCR=on`.
- `exos-mcp` uses `EXOS_OAUTH_ISSUER` the same way for its protected-resource metadata.
- No new dependency.

## Opendate mapping

| Opendate | Exos |
|---|---|
| `GET /oauth/authorize`, `POST /oauth/token` (code, refresh), `POST /oauth/revoke` | `exos-oauth` `/authorize`, `/token`, `/revoke` (+ `/introspect`, `/register`) |
| `POST /oauth/token` grant_type=password ("Log in") | not built: apps never see a password; use the code flow or a personal token |
| `POST /personal_access_tokens` | Profile → Developer (`exos_create_personal_token`, signed in) |
| `DELETE /personal_access_tokens/current` | `DELETE /v1/personal-access-tokens/current` |
| `GET /team_memberships`, `PUT …/{id}/switch` | `GET /v1/me/memberships`; switching doesn't apply (a token is pinned to one org) |
| `GET/PATCH /teams/{id}` | `GET/PATCH /v1/team` |
| `GET /teams/{id}/team_memberships`, `PATCH/DELETE …/{id}` | `GET /v1/team/members`, `PATCH/DELETE /v1/team/members/:id` |
| `GET/POST /teams/{id}/invitations`, `DELETE …/{id}` | `GET/POST /v1/team/invitations`, `DELETE /v1/team/invitations/:id` |
| `GET /teams/{id}/roles`, `GET /admin/roles` | `GET /v1/team/roles` |
| `POST /admin/teams/{id}/invitations` | `POST /v1/team/invitations` (owner credential) |
| `GET/POST/DELETE /admin/teams/{id}/api_keys` | Org settings → Developer (`exos_create_api_key`, `exos_list_api_keys`, `exos_revoke_api_key`); not over the API, so a key can't mint keys |
| `/admin/organizations` (5) | `exos_create_org` and the dashboard; platform admin tooling, not a partner API |
| `/admin/external_identities` (2) | doesn't apply: Exos uses Supabase Auth identities |
| `/users` (7: sign up, register, update, delete, current, reset password, resend confirmation) | Supabase Auth (GoTrue) does these; `GET /v1/me` names the token's user |
