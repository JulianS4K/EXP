# Connect Eventbrite: the OAuth app and the App Marketplace

How organizers connect Eventbrite to Exos, what the operator registers on
Eventbrite to turn on one-click connect, and where Exos stands on Eventbrite's
App Marketplace (partner) application. Spec item 1 of the distribution layer.

Code: `supabase/functions/exos-eventbrite-oauth/` (the sign-in),
`supabase/functions/_shared/eventbrite/oauth.ts` (URLs, state, token exchange),
mig `20261029140000_exos_eventbrite_oauth.sql`, `src/components/EventbriteConnect.tsx`
(Org settings → Integrations) and `src/components/EventbriteSync.tsx` (event door tab).
Tests: `tests/exos/test_eventbrite_oauth.sql`, `src/lib/eventbriteOAuth.test.ts`.

> **Checked 2026-10-29, partly blind.** This session could not open
> eventbrite.com (the network policy blocked it). The OAuth facts below come
> from search-engine extracts of Eventbrite's own docs pages and from two
> client libraries on GitHub. Items marked **(unverified)** must be checked on
> Eventbrite's pages before the app is submitted.

## Two ways to connect

| | Connect Eventbrite (OAuth) | Private token (pasted) |
|---|---|---|
| When | `EXOS_EVENTBRITE_CLIENT_ID` and `EXOS_EVENTBRITE_CLIENT_SECRET` are set (and `EXOS_APP_URL` is allow-listed) | Always available; the only option when the OAuth app isn't configured |
| Organizer does | Clicks **Connect Eventbrite**, signs in on Eventbrite, clicks Allow, picks the event | Copies the private token from Eventbrite (Account settings → Developer links → API keys) and pastes it |
| Where | Event → door tab, or Org settings → Integrations | Event → door tab ("Use a private token instead" when OAuth is on) |
| Stored | Vault `exos_eventbrite:<org>`, `exos_eventbrite_accounts.auth_method = 'oauth'` | The same secret, `auth_method = 'private_token'` |

Both tokens act as the organizer's Eventbrite account and go through the same
code: the GET-only client (`_shared/eventbrite/client.ts`) and the
capacity-only writer (`_shared/eventbrite/writer.ts`). A new connection never
turns writes on (`writes_enabled` defaults to false; `EXOS_EVENTBRITE_WRITES`
is unchanged). The private token is how the pilot runs before Eventbrite
approves the app.

## The flow

1. **Start.** The SPA calls `GET /functions/v1/exos-eventbrite-oauth/start?org=<org>[&event=<event>]`
   with the user's Supabase JWT. Owner or manager only. A random 256-bit state is
   made; only its SHA-256 is stored (`exos_oauth_states`, provider `eventbrite`,
   10-minute expiry, single use, at most 10 starts per user per 10 minutes, shared
   with Connect Google Ads). The answer is Eventbrite's authorize URL; the SPA
   navigates to it.
2. **Eventbrite.** The organizer signs in and allows Exos. Eventbrite sends the
   browser to the registered redirect URI with `?code=…&state=…` (or `?error=access_denied`).
3. **Callback** (`/callback`, no JWT). The code is parked on the state row (first
   return only) together with the SHA-256 of a fresh 256-bit **finish token**, and the
   browser goes to
   `<EXOS_APP_URL>/orgs/<org>/settings?eventbrite=finish&eventbrite_state=<state>#eventbrite_finish=<token>`.
   The token is in the URL **fragment**: browsers never send it to a server, so it isn't
   in access logs and can't leak through a Referer. `EXOS_APP_URL`'s origin must be in
   `EXOS_REDIRECT_ORIGINS` (`_shared/redirects.ts`), and only that base plus the org's
   uuid go into the URL: no open redirect.
4. **Confirm, then finish.** The settings page takes the state and token out of the
   address bar (keeping them in memory only), shows which organization the Eventbrite
   account will be connected to, and sends nothing until the user clicks **Confirm**.
   Then `POST /finish {state, finish}` with the user's JWT: it needs the finish token
   **and** the user who started the sign-in, once, before expiry. The code is exchanged
   server side with the client secret, the token is checked with `GET /users/me/`, and
   stored in Vault. The token, code and secret are never logged or sent to the browser.

   **Why the finish token (account linking).** Whoever starts a sign-in knows the
   state. Without the token they could send the authorize link to someone else, let
   them sign in on Eventbrite (their code lands on the starter's state), and finish
   with their own JWT, attaching the other person's Eventbrite account to their org.
   Checking that `/finish` comes from the starting user doesn't stop that: the starter
   is the attacker. Now the starter never sees the token (refused, state burned), and
   the browser that has it doesn't have the starter's JWT (refused as "started by
   another Exos account", state burned); the page says nothing was connected. Connect
   Google Ads has the same fix (`docs/marketing-conversions.md`).
5. **Pick the event.** If the sign-in started on an event's door tab, the SPA goes
   back to that event (`?tab=door&eventbrite=pick`) with the Eventbrite event list
   open, and the existing **Link and sync** step links it. From Integrations, each
   event is linked on its own door tab.

**Disconnect** (door tab or Integrations) deletes the Vault secret and the event
links, keeps imported guests, and writes a row to
`exos_eventbrite_connection_log` (who, how, when; shown under History). Exos
sends nothing to Eventbrite: Eventbrite documents no token revocation endpoint
**(unverified: none found)**. The organizer can also remove Exos from their
Eventbrite account's connected apps.

## Eventbrite's OAuth, as Exos uses it

| Fact | Value | Source |
|---|---|---|
| Authorize URL | `https://www.eventbrite.com/oauth/authorize?response_type=code&client_id=<API key>&redirect_uri=<uri>` (+ `state`) | [App OAuth Flow](https://www.eventbrite.com/platform/docs/app-oauth-flow), [Authentication](https://www.eventbrite.com/platform/docs/authentication), [oauth2-eventbrite](https://github.com/stevenmaguire/oauth2-eventbrite) |
| Token URL | `POST https://www.eventbrite.com/oauth/token`, form body `grant_type=authorization_code`, `client_id`, `client_secret`, `code`, `redirect_uri` | [App OAuth Flow](https://www.eventbrite.com/platform/docs/app-oauth-flow); [eventbrite.php](https://github.com/eventbrite/eventbrite.php/blob/master/OAUTH2-README.md) sends the same grant |
| Client id | The app's **API key**; the client secret is shown on the same page | [eventbrite.php OAuth README](https://github.com/eventbrite/eventbrite.php/blob/master/OAUTH2-README.md) |
| Redirect URI | Set on the API key in Eventbrite; users are sent there after allowing access | [Authentication](https://www.eventbrite.com/platform/docs/authentication), [App Approval Process](https://www.eventbrite.com/platform/docs/app-approval-process) |
| Server side | Eventbrite recommends the server-side (code) flow over the client-side `response_type=token` flow | [Authentication](https://www.eventbrite.com/platform/docs/authentication) |
| Scopes | None requested. The PHP League provider sends no scopes; one third-party guide shows `event_read,event_write` **(unverified; Exos asks for none)** | [oauth2-eventbrite](https://github.com/stevenmaguire/oauth2-eventbrite) |
| Expiry / refresh | No refresh token in Eventbrite's docs. A token stops working when the user changes their password or removes the app; they connect again (Exos shows "Disconnect and connect Eventbrite again"). A third-party guide shows a `refresh_token` grant **(unverified; Exos doesn't use one)** | [App OAuth Flow](https://www.eventbrite.com/platform/docs/app-oauth-flow); [support thread](https://theeventscalendar.com/support/forums/topic/your-eventbrite-token-is-not-valid-3/) |
| `state` | Standard OAuth: Eventbrite returns it on the redirect **(unverified: test it on the registered app before launch; without it the callback refuses every sign-in)** | — |
| Using the token | `Authorization: Bearer <token>` on `https://www.eventbriteapi.com/v3/…`, the same as a private token | [Authentication](https://www.eventbrite.com/platform/docs/authentication) |
| Revocation | No API endpoint found; removal is in the account's settings **(unverified)** | — |

## Registering the app (operator steps)

1. Sign in to Eventbrite with the S4K / Exos account that should own the app and
   open **Account settings → Developer links → API keys**
   (`https://www.eventbrite.com/platform/api-keys`). Create an API key (app) named
   **Exos**, with the Exos site as the application URL and a short description.
2. Set its **OAuth redirect URI** to exactly
   `https://<project-ref>.supabase.co/functions/v1/exos-eventbrite-oauth/callback`
   (the shared Supabase project). For a different callback, set the same value in
   `EXOS_EVENTBRITE_REDIRECT_URI`; it must end in `/exos-eventbrite-oauth/callback`
   with no query string, and must match the registered one character for character.
3. Copy the **API key** and the **client secret**. Set the edge-function secrets
   (operator-gated; Supabase → Project settings → Edge functions → Secrets):
   - `EXOS_EVENTBRITE_CLIENT_ID` = the API key
   - `EXOS_EVENTBRITE_CLIENT_SECRET` = the client secret
   - `EXOS_EVENTBRITE_REDIRECT_URI` only if step 2 used a non-default URL
   - check `EXOS_APP_URL` (the SPA base, e.g. `https://…/bridge`) and that its
     origin is in `EXOS_REDIRECT_ORIGINS`.
4. Apply mig `20261029140000_exos_eventbrite_oauth.sql`, then deploy
   `supabase functions deploy exos-eventbrite-oauth --no-verify-jwt` (Eventbrite's
   redirect carries no Supabase JWT; `/start` and `/finish` check it themselves).
   Redeploy `exos-oauth-google` and the SPA in the same window: the migration drops
   the old two-argument state functions, so Connect Google Ads fails closed (no
   connection, nothing leaked) until the new function and confirm screen are live.
   All of this is operator-gated.
5. Test with a throwaway org: Org settings → Integrations → **Connect Eventbrite**;
   it should come back connected ("Connected with Eventbrite sign-in"). Check the
   `state` round trip, a refusal (click Deny: "access was declined"), and
   **Disconnect**. `GET …/exos-eventbrite-oauth/config` answers `{"oauth": true}`
   once configured.
6. Until the app is approved for the Marketplace, organizers outside the app
   owner's account may see an unverified-app screen or be refused
   **(unverified: Eventbrite's pages don't say whether an unlisted app can be
   authorized by any Eventbrite user)**. The private token keeps working either
   way.

Leaving `EXOS_EVENTBRITE_CLIENT_ID` / `_SECRET` unset turns the whole thing off:
the button is hidden, `/start` answers 503, and organizers paste a private token.

## App Marketplace (partner) application

Eventbrite's [App Marketplace](https://www.eventbrite.com/platform/docs/what-is-app-marketplace)
lists partner apps to organizers. The [App Approval Process](https://www.eventbrite.com/platform/docs/app-approval-process)
starts with reviewing the partner program's information, qualifications and
requirements, then submitting the app with its directory listing (in **App
Management → Directory Listing**, including an icon and a banner image). The
spec's reading of the program page (2026-10-29): it requires the latest API,
OAuth with Eventbrite's assets, a self-service setup and current branding, and
says the program is being updated. **Confirm the current terms on Eventbrite's
pages before applying; this session couldn't open them.** See also
[Integrating with Eventbrite Manage](https://www.eventbrite.com/platform/docs/integrate-your-app).

| Requirement (as read) | Exos today | Missing |
|---|---|---|
| Latest API | API v3 (`www.eventbriteapi.com/v3`), the current version | Re-check for deprecations of `changed_since` / continuation on attendees and of the ticket class capacity update |
| OAuth | Done: server-side code flow, state, Vault storage, no token handling for the organizer | Verify `state` round trip on the registered app |
| "OAuth with Eventbrite's assets" (the Connect button) | Plain "Connect Eventbrite" text button | Use Eventbrite's official button / logo assets per their brand guidelines **(asset pack and rules unverified)** |
| Self-service setup | Connect, pick the event, link, sync: no Exos staff involved | — |
| Current branding | Eventbrite named in text only | Listing icon and banner (Exos assets), screenshots, Eventbrite logo per their guidelines |
| Directory listing | Not started | Name, short and long description, category, support email and URL, privacy policy and terms URLs (Exos has `/privacy` and `/terms`), pricing (free tier), screenshots |
| Data use | Read: events, attendees, ticket classes. Write: only ticket class `capacity`, off by default | State this in the listing; Eventbrite may review the write **(their review rules unverified)** |
| Disconnect / uninstall | Local disconnect deletes the token, keeps history | If Eventbrite sends an uninstall webhook or callback, handle it **(none found)** |

Submit once: the app is registered (above), the button follows Eventbrite's
assets, the listing copy and images are ready, and one real organizer has
connected through OAuth end to end.
