# Server-side ad conversions

Exos reports paid orders to each organizer's ad accounts from the server, not only from the
browser pixel. The browser Purchase is lost to ad blockers, iOS tracking limits and in-app
browsers; the server copy isn't. Both carry the same dedupe id, so a platform that gets both
counts the order once.

Status (2026-09-30): built, **not live**. Migrations `20260930100000_exos_marketing_conversions.sql`
and `20260930102000_exos_oauth_google.sql` are applied (prod history, checked 2026-11-17); `exos-conversions-drain` and
`exos-oauth-google` are not deployed (the drain isn't scheduled); the drain is dry-run until
`EXOS_CONVERSIONS_LIVE=true`.

Pieces:

| What | Where |
|---|---|
| Per-org credentials (public ids + a Vault-stored token) | `exos_org_ad_credentials`, RPCs `exos_set_ad_credential` / `exos_list_ad_credentials` |
| Outbox | `exos_marketing_conversions`, filled by triggers on `exos_checkout_sessions` and `exos_order_refunds` |
| Drain | `supabase/functions/exos-conversions-drain` (cron), `exos_conversions_claim_batch` / `exos_conversions_mark` |
| Request builders (pure) | `supabase/functions/_shared/conversions/{meta,tiktok,ga4,reddit,snap,googleAds,x}.ts`, send loop `send.ts`, X step `xDrain.ts` |
| Settings UI | Org settings → **Ads & conversions** (`AdConversionsSettings`, `lib/adCredentials.ts`), owner / manager |
| Google Ads sign-in | `supabase/functions/exos-oauth-google`, `exos_oauth_states` + RPCs (mig `20260930102000`), pure helpers `_shared/conversions/googleOAuth.ts`, see [Google Ads](#google-ads) |
| Tests | `tests/exos/test_marketing_conversions.sql`, `tests/exos/test_oauth_google.sql`, `tests/exos/test_ads.sql` (in `run_p0.sh`), `src/lib/marketingConversions.test.ts`, `src/lib/googleOAuth.test.ts`, `src/lib/googleAdsConnect.test.ts`, `supabase/functions/_shared/ads/ads_test.ts` |
| Ads (audiences, Boost this event, X), dry run only | see [Ads](#ads-dry-run-only) |

## When a conversion is queued

A **Purchase** row is written, one per enabled platform, when an `exos_checkout_sessions` row
becomes `fulfilled` and all of these hold:

- `amount_cents > 0`. Free claims have no value to report and don't create checkout sessions
  anyway.
- `consent_marketing = 'granted'`: the buyer accepted **advertising** cookies at checkout
  (`lib/consent.ts`). `denied`, `unknown` and NULL queue nothing. A Global Privacy Control browser
  is `denied` unless the buyer opted in.
- The org has that platform **enabled** in `exos_org_ad_credentials`. Enabling needs the
  platform's required ids and a saved token.

A **Refund** row is written when an `exos_order_refunds` row becomes `succeeded`, for platforms
that take a refund event (**GA4 only**), and only if that session's Purchase was queued for the
platform and it is still enabled. Meta, TikTok, Reddit and Snap have no standard refund event.
Google Ads retractions are a separate API and aren't queued.

Dedupe: `unique (platform, event_name, event_id_dedupe)`. For a Purchase, `event_id_dedupe` is the
**Stripe Checkout Session id**, the same id the browser Purchase sends (`lib/purchasePixel.ts`:
Meta `eventID`, TikTok `event_id`, GA4 `transaction_id`, Reddit `conversionId`, Snap
`client_dedup_id`). For a Refund it is `refund:<exos_order_refunds.id>`, so each partial refund is
reported once. A replayed webhook or a status flip back to `fulfilled` doesn't add a row.

The triggers never fail fulfilment or a refund: an error is logged as a Postgres WARNING and the
checkout goes on.

## What is sent

The outbox `payload` holds hashed or opaque data only:

| Field | From | Notes |
|---|---|---|
| `em` | `sha256(lower(trim(buyer_email)))` | Meta, TikTok, Snap, X |
| `em_google` | same, with the dots of a gmail.com / googlemail.com local part removed | GA4 `user_data`, Google Ads (Google's normalization) |
| `em_reddit` | Reddit's normalization: lower case, trimmed, and in the local part everything from the first `+` dropped and every dot removed (every domain) | Reddit; added to Reddit rows by a BEFORE INSERT trigger (`_exos_email_sha256_reddit`, mig `20261121190500`). A row queued before it has only `em`, which is sent instead |
| `ad_ids` | `exos_checkout_sessions.ad_ids` | click ids (`fbclid`, `ttclid`, `gclid` / `gbraid` / `wbraid`, `rdt_cid`, `ScCid`) and browser ids (`fbp`, `fbc`, `ga_client_id`) |
| `user_agent` | `exos_checkout_sessions.user_agent` | Meta requires it for website events |
| `transaction_id` | the Stripe session id | the order id on every platform |
| `event` | event id, slug, name | `content_ids` / `item_id`; the event page URL is built from `EXOS_APP_BASE_URL` |
| `quantity`, value, currency | the session | value = `amount_cents / 100` (tickets + add-ons + tax, after vouchers), the same number the browser Purchase uses |

**No IP address is sent.** Meta, TikTok and Snap match better with the buyer's raw IP, but Exos
stores only a salted hash of it (`client_ip_hash`, for the guest rate limit), which no platform
can use, and we chose not to start storing raw IPs for this. The cost is lower event match
quality, mostly on Meta; the hashed email, user agent and `fbp` / `fbc` carry most of the match.
Phone numbers aren't collected at checkout, so no `ph` is sent (the builders take one if it's
added later).

Per platform:

| Platform | Endpoint | Token placement | Event | Needs to send |
|---|---|---|---|---|
| Meta Conversions API | `POST graph.facebook.com/v25.0/<pixel_id>/events` | `access_token` in the JSON body | `Purchase`, `action_source: website`, `event_id`, `user_data.em / fbp / fbc / client_user_agent`, `custom_data.value / currency / content_ids / order_id` | user agent; fbc is the `_fbc` cookie or `fb.1.<ms>.<fbclid>` |
| TikTok Events API 2.0 | `POST business-api.tiktok.com/open_api/v1.3/event/track/` | `Access-Token` header | `Purchase`, `event_source: web`, `event_source_id` = pixel code, `user.email / ttclid / user_agent`, `properties.contents[]` | hashed email or `ttclid` |
| GA4 Measurement Protocol | `POST www.google-analytics.com/mp/collect?measurement_id=…&api_secret=…` | `api_secret` query parameter (the protocol's design) | `purchase` / `refund` with `transaction_id`, `value`, `currency`, `items[]`; `user_data.sha256_email_address`; `consent` granted | the GA client id from `_ga` (captured with analytics consent); events at most 72 h old |
| Reddit Conversions API v3 | `POST ads-api.reddit.com/api/v3/pixels/<pixel_id>/conversion_events` | `Authorization: Bearer` | `tracking_type: PURCHASE` (the v3 enum is UPPER_SNAKE: `PAGE_VISIT`, `ADD_TO_CART`, …; the browser pixel's PascalCase names are a different API), `metadata.conversion_id` / `value`, `click_id` = `rdt_cid`, `user.email` = `em_reddit`; at most 1,000 events a request (`redditBatches`) | hashed email or `rdt_cid` |
| Snap Conversions API v3 | `POST tr.snapchat.com/v3/<pixel_id>/events?access_token=…` | `access_token` query parameter (as Snap documents it) | `PURCHASE`, `event_id`, `user_data.em / sc_click_id / client_user_agent` | hashed email or `ScCid` |
| X Conversions API | `POST ads-api.x.com/12/measurement/conversions/<pixel_id>` | OAuth 1.0a `Authorization` header (HMAC-SHA1), signed per request by the `x_ads` adapter | `conversions[]`: `conversion_time`, `event_id` (`tw-<pixel>-<event>`), `identifiers` (`twclid`, `hashed_email`), `value`, `price_currency`, `number_items`, `conversion_id` | hashed email or `twclid`; see [X](#x-conversions) |
| Google Ads (Data Manager API) | `POST datamanager.googleapis.com/v1/events:ingest` | `Authorization: Bearer` with an OAuth access token (from the org's refresh token, per run) | `adIdentifiers.gclid / gbraid / wbraid`, `conversionValue`, `transactionId`, `userData.userIdentifiers[].emailAddress` | hashed email or a click id; the Exos OAuth client configured, see [Google Ads](#google-ads) |

Age limits (rows older are skipped): Meta, TikTok, Reddit, Snap and X 7 days, GA4 72 hours, Google
Ads 90 days.

Tokens are never stored in `exos_orgs.marketing` (public through `exos_public_orgs`), never
returned to a client, never logged, and are redacted (`[redacted]`) from `payload_planned` and
from stored error text. The drain only POSTs to the pinned hosts
(`_shared/conversions/common.ts` `ALLOWED_HOSTS`: the six platform hosts plus
`oauth2.googleapis.com` for the Google Ads token refresh).

## The drain and the dry-run switch

`exos-conversions-drain` is cron-invoked with the `x-cron-secret` header (`requireCronSecret`).
Each run claims up to 25 due rows (`exos_conversions_claim_batch`: `FOR UPDATE SKIP LOCKED`, a
10-minute lease, `attempts + 1`, a fresh `claim_token`), builds each request and marks the result
with `exos_conversions_mark`, which lands only while the run still holds the lease.

Statuses:

| Status | Meaning |
|---|---|
| `pending` | due at `next_attempt_at` |
| `sending` | claimed; a lease older than 10 minutes is reclaimed (or `failed` if it was the last attempt) |
| `sent` | the platform answered 2xx (`sent_at`) |
| `failed` | a 4xx other than 408 / 425 / 429, or 6 attempts used |
| `skipped` | not sendable (platform disabled, no token, nothing to match on, too old, a refund on a platform without one) or **dry-run**; `last_error` says which |

Retries (408, 425, 429, 5xx, network errors, timeouts) back off 2^attempts minutes, capped at
6 hours. `payload_planned` keeps the last request as built, with the token redacted.

**Dry-run is the default.** Unless the function's env has `EXOS_CONVERSIONS_LIVE=true`, each row
is built, its planned request stored, and the row marked `skipped` with
`last_error = 'dry-run: EXOS_CONVERSIONS_LIVE is not true'`. We chose `skipped` over leaving it
`pending` so a dry-run drain doesn't reclaim the same rows every five minutes. To send recent
dry-run rows after going live:

```sql
UPDATE public.exos_marketing_conversions
   SET status = 'pending', attempts = 0, next_attempt_at = now(), last_error = NULL
 WHERE status = 'skipped' AND last_error LIKE 'dry-run:%'
   AND occurred_at > now() - interval '3 days';
```

**Google Ads is planned only unless the Exos Google OAuth client is set** on the drain
(`GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET`). Without them the request is built and
stored and the row is `skipped` with `planned only: google_ads sender not enabled`. With them, a
live run swaps each org's stored refresh token for an access token (once per org per run) and sends.
A dry run never calls Google at all. The request shape still needs checking against the live
reference with `validateOnly: true` (see "Needs verification" and [Google Ads](#google-ads)).

Env for the function:

| Variable | Value |
|---|---|
| `CRON_SECRET` | shared with the other cron functions |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | set by Supabase |
| `EXOS_CONVERSIONS_LIVE` | `true` to send; anything else is dry-run |
| `EXOS_APP_BASE_URL` | `https://…` of the SPA, for `event_source_url` / `page.url` (optional) |
| `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` | the Exos Google OAuth client; without them Google Ads stays planned only (optional) |

### Schedule (operator, not done)

Every 5 minutes, through the same helper the other Exos crons use (it reads `CRON_SECRET` from
Vault; see `20260702144637_exos_reconcile_checkouts_cron.sql` for the exact call shape):

```sql
SELECT cron.schedule(
  'exos-conversions-drain-5min',
  '2,7,12,17,22,27,32,37,42,47,52,57 * * * *',
  $cron$
    SELECT public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/exos-conversions-drain',
      '{}'::jsonb
    );
  $cron$
);
```

(Off the :00 / :05 marks so it doesn't start with every other five-minute job.)

Applying the migration, deploying the function, setting the env and scheduling it each need
explicit operator permission (CLAUDE.md).

## Getting each platform's ids and token

Organizers paste these in Org settings → **Ads & conversions**. The token field is write-only: a
saved token shows as "•••• saved", leaving the field blank keeps it, and **Remove the saved
token** deletes it from Vault (and turns the platform off). The optional test code routes events
to the platform's test view.

| Platform | Ids | Token | Test code |
|---|---|---|---|
| Meta | Pixel (dataset) id, 15-16 digits | Events Manager → the pixel → Settings → Conversions API → **Generate access token** | Events Manager → Test events → test event code (`test_event_code`) |
| TikTok | Pixel code (`C…`) | TikTok Ads Manager → Events Manager → the pixel → Settings → **Generate access token** | Test events tab → test event code |
| GA4 | Measurement id (`G-…`) | GA4 Admin → Data streams → the web stream → **Measurement Protocol API secrets** → Create | any value: sends `debug_mode: 1` so events show in DebugView |
| Reddit | Pixel id (`a2_…`, older `t2_…`) | Reddit Ads → Events Manager → Conversions API → **Generate access token** | Reddit's `test_id` |
| Snap | Pixel id (UUID) | Snap Ads Manager → Events Manager → the pixel → Conversions API token | any value: sends to `/events/validate` (checked, not recorded) |
| Google Ads | Customer id (10 digits, no dashes), conversion action id (Goals → Conversions → the action; `ctId` in the URL), optional manager (MCC) id | **Connect Google Ads** (a Google sign-in, no token to paste) | any value: `validateOnly: true` |

## Google Ads

Google Ads conversions go through Google's **Data Manager API** (`events:ingest`), which replaced
the Google Ads API's offline conversion upload. It takes an OAuth 2.0 access token for a Google
account that can manage the Ads account; there's no token an organizer can copy from a settings
page, so Exos runs a Google sign-in ("Connect Google Ads") and keeps the **refresh token**.

- **Scope:** `https://www.googleapis.com/auth/datamanager` (the Data Manager API's own scope, not
  the Google Ads API's `https://www.googleapis.com/auth/adwords`). It's a sensitive scope, so the
  consent screen needs Google's verification before external users outside the test list can use it.
- **No developer token.** The Data Manager API doesn't take the Google Ads `developer-token` header,
  and the `login-customer-id` header becomes `destinations[].loginAccount` in the body (the optional
  manager id field). So there's no `GOOGLE_ADS_DEVELOPER_TOKEN`.

### The flow (`exos-oauth-google`, mig `20260930102000`)

1. **Connect Google Ads** (Settings → Ads & conversions → Google Ads) calls
   `GET /functions/v1/exos-oauth-google/start?org=<org id>` with the user's JWT. Owner / manager only.
   The function makes a random 256-bit state, stores only its SHA-256 in `exos_oauth_states` with the
   org, the user and a 10-minute expiry (at most 10 starts per user per 10 minutes), and answers
   `{ url }`: Google's consent page with `access_type=offline`, `prompt=consent` (so Google always
   returns a refresh token), the scope above and `redirect_uri` = `GOOGLE_OAUTH_REDIRECT_URI`.
2. Google sends the browser to `…/exos-oauth-google/callback?code&state`. The code is parked on
   the state row (first return only) with the SHA-256 of a fresh 256-bit **finish token**, and the
   browser goes back to
   `<EXOS_APP_URL>/orgs/<org>/settings?google_ads=finish&google_ads_state=<state>#google_ads_finish=<token>`
   (the token in the URL fragment, which browsers never send to a server). A refusal or an unknown /
   used / expired state comes back as `?google_ads=error&reason=…`.
3. The settings page takes both out of the address bar, shows which organization Google Ads will be
   connected to, and only when the user clicks **Confirm** posts `{state, finish}` to
   `…/exos-oauth-google/finish` with the user's JWT. It needs the finish token **and** the **same
   user** who started it, once, before it expires, while they're still owner / manager. The function exchanges the code at `https://oauth2.googleapis.com/token`,
   checks the Data Manager scope was granted (Google lets users untick scopes) and that a refresh
   token came back, and stores it in Vault as the org's `google_ads` secret
   (`exos_set_google_ads_token`, name `exos_ad:<org>:google_ads`, the same one
   `exos_set_ad_credential` uses). The ids, the on/off switch and the test code are kept. The page
   shows "Google Ads connected" and the row shows **Connected**.

Steps 2 and 3 stop account linking (mig 20261029140000): whoever starts a sign-in knows the state,
so without the finish token they could send the consent link to a victim and finish the victim's
sign-in with their own JWT, attaching the victim's Google account to their org. The starter never
sees the finish token, and the victim's browser, which has it, doesn't have the starter's JWT; either
attempt is refused and the page says nothing was connected. The state and the code are never logged; the code is kept at most 10 minutes and
cleared when used.

Then the organizer fills in the customer id and conversion action, turns Google Ads on and saves,
as for the other platforms. **Disconnect** + Save removes the refresh token from Vault (it doesn't
revoke it at Google; the organizer can do that under their Google account's third-party access).

### The drain

For each live Google Ads row the drain POSTs `grant_type=refresh_token` to
`https://oauth2.googleapis.com/token` (the first row of each org per run; the answer, an access
token or a failure, is reused for that org's other rows in the run and refreshed a minute before
it expires), puts the access token in `Authorization: Bearer`, and sends. `invalid_grant` (the
organizer revoked access, changed their password, or the OAuth app is still in "Testing", where
Google expires refresh tokens after 7 days) marks the row `failed` with "reconnect Google Ads";
429 / 5xx / network errors are retried like any send. The refresh token only goes to
`oauth2.googleapis.com` and the access token only to `datamanager.googleapis.com`; neither is
stored in `payload_planned` or error text.

### Setting up the Google Cloud OAuth client (operator, not done)

1. In a Google Cloud project owned by Exos: **APIs & Services → Library → Data Manager API →
   Enable**.
2. **Google Auth Platform → Branding / Audience**: app name "Exos", support email, the app domain,
   privacy policy and terms URLs; user type **External**. Add `…/auth/datamanager` under **Data
   Access**. While the app is in "Testing", add the organizers' Google accounts as test users (and
   expect their refresh tokens to expire after 7 days); publish it and complete Google's
   verification of the sensitive scope before general use.
3. **Clients → Create client → Web application**. Authorized redirect URI:
   `https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/exos-oauth-google/callback` (exactly;
   no JavaScript origins are needed). Copy the client id and secret.
4. Set the function secrets (Supabase → Edge Functions → Secrets):

| Variable | Used by | Value |
|---|---|---|
| `GOOGLE_OAUTH_CLIENT_ID` | `exos-oauth-google`, `exos-conversions-drain` | the web client's id (`….apps.googleusercontent.com`) |
| `GOOGLE_OAUTH_CLIENT_SECRET` | both | the web client's secret |
| `GOOGLE_OAUTH_REDIRECT_URI` | `exos-oauth-google` | the callback URL from step 3, identical to the registered one |
| `EXOS_APP_URL` | `exos-oauth-google` | the SPA base the browser returns to, e.g. `https://host/bridge`; its origin must be in `EXOS_REDIRECT_ORIGINS` |
| `EXOS_REDIRECT_ORIGINS` | `exos-oauth-google` | already set for checkout; also the CORS allow-list for `/start` and `/finish` |

5. Deploy `exos-oauth-google` **with `--no-verify-jwt`** (Google's redirect carries no Supabase
   JWT; `/start` and `/finish` verify the JWT themselves). If any Google / app variable is missing,
   every route answers 503 "Google Ads connection not configured" and the button shows that.

Applying the migration, setting the secrets and deploying need explicit operator permission
(CLAUDE.md).

### References

- Data Manager API access setup (OAuth, scope `https://www.googleapis.com/auth/datamanager`, no
  developer token): https://developers.google.com/data-manager/api/devguides/quickstart/set-up-access
- Google Ads API → Data Manager field mapping (developer-token / login-customer-id headers become
  destination fields): https://developers.google.com/data-manager/api/devguides/events/google-ads/store-sales/upgrade/field-mappings
- Scope constant in Google's client library: https://googleapis.dev/dotnet/Google.Apis.DataManager.v1/latest/api/Google.Apis.DataManager.v1.DataManagerService.Scope.html
- OAuth 2.0 for web server apps (consent URL, `access_type=offline`, `prompt=consent`, code
  exchange and refresh at `oauth2.googleapis.com/token`): https://developers.google.com/identity/protocols/oauth2/web-server
- Refresh token expiry (Testing apps: 7 days; `invalid_grant`): https://developers.google.com/identity/protocols/oauth2#expiration
- Data Manager API launch coverage: https://ppc.land/google-launches-data-manager-api-to-centralize-first-party-data-uploads/

developers.google.com was not reachable from the build environment; the scope and the
no-developer-token point come from search-result summaries of the pages above, which agreed.

## X conversions

X rows join the outbox with mig `20261121190500` (`'x'` on the platform CHECK). They are queued by
their own trigger (`exos_checkout_conversions_x`) under the same rules as the others (fulfilled,
paid, `consent_marketing = 'granted'`) when the org's **`ads_x`** row in the channel-core credential
store is on (`writes_enabled`, a secret, `config.pixel_id` and `config.event_id`). The store row is
written by an X sign-in that is **not built yet** (operator step below); the generic Integrations
save refuses `ads_x` (a managed provider).

| Piece | Where |
|---|---|
| Builder | `_shared/conversions/x.ts` (`buildX`): the unsigned request stored in `payload_planned` |
| Signing | `_shared/oauth1.ts` (OAuth 1.0a HMAC-SHA1; checked against the published test vector) |
| Sender | the `x_ads` adapter (`_shared/channels/adapters/xAds.ts`) through GatedHttp, allowlist `POST /12/measurement/conversions/<pixel>` only |
| Drain step | `_shared/conversions/xDrain.ts` (`drainXRow`), called by `exos-conversions-drain` |

**X is pinned off in code**: `X_CONVERSIONS_PINNED_OFF` (`xDrain.ts`) hands the `x_ads` GatedHttp an
org switch of false whatever the flags say, so an X row is only ever planned. Lifting the pin is a
reviewed change plus the CLAUDE.md write exception for X. Behind the pin, an X row would be sent only
when **all** of these hold, and none does today: `EXOS_CONVERSIONS_LIVE=true`
on the drain; Exos's X app keys (`X_ADS_CONSUMER_KEY`, `X_ADS_CONSUMER_SECRET`; without them the row
is "planned only"); and GatedHttp's decision for `x_ads` (the org's switch AND `EXOS_X_ADS_WRITES=on`).
Otherwise the row is `skipped` with the reason, like the others. The org's token and token secret
(`{"token","token_secret"}` in Vault) and the consumer secret never appear in `payload_planned`, an
audit step or an error.

Unverified (X's docs weren't readable from the build session): the `identifiers` shape, `value` as a
number, the `12` version segment, the batch size (500) and the age window (held to 7 days).

## Ads (dry run only)

Operator 2026-11-21: "For the APIs build and keep read only till build is complete." The ads phase
is built and **sends nothing**. Every ad-platform write goes through the channel core's GatedHttp
(`docs/security.md`, "Channel core") on its adapter's explicit allowlist; a write off the list is
refused (thrown); with the org's switch or the operator's `EXOS_<ID>_WRITES` off GatedHttp records the
exact payload and returns a stand-in. On top of that, `exos-ads` pins the org's switch **off**
(`_shared/ads/run.ts` `ADS_WRITES_PINNED_OFF`) and gives GatedHttp a fetch that refuses every call, so
not even a read reaches a platform from it. Campaigns, ad sets / groups and ads are always created
**PAUSED**. Hashed lists are summarized in the audit (`[2500 hashed rows (EMAIL_SHA256), not
recorded]`), never stored.

| Piece | Where |
|---|---|
| Migration | `20261121190500_exos_ads.sql` (Reddit hash + trigger, X rows, providers `ads_x` / `ads_meta_api` / `ads_reddit_api`, `exos_ads_campaign_context`, `exos_ads_audience_source`, `exos_ads_credential_meta`; patches `exos_org_audience_export` and `exos_delete_my_account`); tests `tests/exos/test_ads.sql` (AD1-AD9), `tests/exos/race_audience_cap.sh` |
| Audience builder | `_shared/ads/audience.ts` (consent filter, the SQL's hashes only, dedupe, per-platform rows) |
| Campaign planner | `_shared/ads/planner.ts` (one plan), `_shared/ads/geo.ts` (a small local city config; see below) |
| Adapters | `_shared/channels/adapters/{metaAds,redditAds,googleCustomerMatch,xAds}.ts` (core, in the registry) |
| Passes | `_shared/ads/run.ts`, edge function `exos-ads` (`/plan-audience`, `/plan-campaign`; owner / manager) |
| UI | Edit event → **Boost this event** (`BoostEventPanel`), Org settings → **Ad audiences** (`AdAudienceSyncPanel`); every plan is also in **What we'd send** (`ChannelAuditPanel`) |
| Tests | `_shared/ads/ads_test.ts` (in CI's Deno line), `src/components/BoostEventPanel.test.tsx` |

**Who is on an audience.** `exos_ads_audience_source` (service role) returns the org's buyers with a
fulfilled (or partly refunded) order who granted **advertising** consent at checkout, and its fans
whose latest advertising choice there (by email or account) is granted on an order that wasn't fully
refunded. A "yes" counts only from a paid or issued order with no open or lost dispute, whose email
the person proved: the email code for that very address, or their own account with the same address
and a verified email (a Google / Apple sign-in whose provider verified it, or, once the operator has
turned on Supabase Auth's "Confirm email" and set `auth_confirm_email_on`, a confirmation mail
answered; until then an email/password account's "yes" doesn't count). A stranger can type anyone's email into a guest checkout and prove their own phone, so an
SMS proof never makes a "yes", and nor does an organizer's correction of the address. Guest orders
from before proofs (Nov 2026) don't count as a "yes". A "no" counts from any checkout,
the latest counted choice wins, and at the same moment a "no" wins. Anyone unsubscribed from
marketing mail, off the org's email list, discarded, deleted or banned is left out. Joining the org's
list or following it is not advertising consent. The rows are hashes only, built in SQL (`em`,
`em_google`, `em_reddit`, `ph`, `ph_digits`, the names `hashedIds.ts` uses); no raw email or phone
leaves Postgres, and the builder keeps only 64-hex values and checks the consent flag again. Over
100,000 people, the first 100,000 go and the plan warns. Every call is logged in
`exos_audience_exports`: 3 a minute and 20 a day per org, shared with the hashed CSV export and
counted atomically. The hashed CSV export follows the same consent rules.

**The price.** What Exos charges for a boost is `EXOS_ADS_BOOST_PRICE_CENTS`, default **0** (free at
first). The ad budget is the organizer's daily budget, default $0 (the plan warns: a $0 campaign
can't run).

**Geo.** `geo.ts` keeps a small NYC config (boroughs, a starter ZIP list per borough, a 10-mile
radius, subreddits) because the shared city config (`_shared/discovery/cities.ts`) is on the
promotion branch, not this one; when they merge, point `adCityOf` at `cityOf` and move the ZIPs and
communities there. Meta gets a radius around the venue when its pin is public (never for a secret or
TBA location), else the city's ZIPs; Reddit has no radius, so it always gets the ZIP / borough list.

### Per platform

| Platform | Adapter (`EXOS_<ID>_WRITES`) | Credential (store provider) | Endpoints (all dry run) | Verified | Unverified |
|---|---|---|---|---|---|
| Meta Custom Audiences + campaigns | `meta_ads` (`EXOS_META_ADS_WRITES`) | `ads_meta_api`: a Marketing API token with `ads_management`; config `ad_account_id`, `page_id`, `pixel_id` (else the conversions pixel), `product_set_id` (optional, the catalog feed) | `POST /v25.0/act_<acct>/customaudiences`, `POST /v25.0/<audience>/users` (schema `EMAIL`, `PHONE`; 10,000 rows a request with `session`), `POST /v25.0/act_<acct>/campaigns` (`OUTCOME_SALES`, `PAUSED`), `/adsets` (`PAUSED`, `promoted_object` pixel + `PURCHASE`, radius or ZIP geo), `/adcreatives` (link ad, `BUY_TICKETS`), `/ads` (`PAUSED`); `GET /v25.0/<campaign>/insights` (stub) | the edges, the SHA-256 schema, `OUTCOME_SALES`, `PAUSED`, `BUY_TICKETS` (well-known public paths) | Advantage+ specifics (`advantage_audience`, campaign budget), the batch size and `session`, `picture`, the ~100-person minimum |
| Google Customer Match | `google_customer_match` (`EXOS_GOOGLE_CUSTOMER_MATCH_WRITES`) | `ads_google_ads` (the **Connect Google Ads** refresh token, Data Manager scope; reused) + config `customer_id` / `login_customer_id`; the list id comes with the request | `POST datamanager.googleapis.com/v1/audienceMembers:ingest` (destinations, `audienceMembers[].userData.userIdentifiers` email / phone hashes, `consent`, `encoding: HEX`, `termsOfService`) | the Data Manager API (new Google Ads API adopters are refused since 2026-04-01, so nothing is built on the Ads API) | every field, 10,000 members a request, `termsOfService`, the list size Google needs; the list is made in Google Ads (Exos can't create it there) |
| Reddit CUSTOMER_LIST + campaigns | `reddit_ads` (`EXOS_REDDIT_ADS_WRITES`); limits table `reddit` | `ads_reddit_api`: a Reddit Ads API OAuth token; config `ad_account_id`, `profile_id`, `pixel_id` (else the conversions pixel), `funding_instrument_id` | `POST /api/v3/ad_accounts/<acct>/custom_audiences` (`CUSTOMER_LIST`), `PATCH /api/v3/custom_audiences/<id>/users` (`EMAIL_SHA256`, Reddit-normalized, 2,500 rows a request), `POST …/campaigns` (`CONVERSIONS`, `PAUSED`), `POST …/ad_groups` (`PAUSED`, `optimization_goal: PURCHASE`, `conversion_pixel_id`, `targeting.geolocations` ZIP list + communities), `POST /api/v3/profiles/<profile>/structured_posts/jobs` (image, headline, CTA `BUY_TICKETS`; not the deprecated posts endpoint), `POST …/ads` (`PAUSED`) | from the brief: 2,500-row chunks of `EMAIL_SHA256`, 1,000+ matched users, up to 36 h to process, a 1-year expiry (all shown as warnings), the rate limits (writes 200 / min, reads 400 / min, targeting 100 / min, audience uploads 3,000 / 15 min) | the body shapes beyond the brief (`data` envelope, bid / goal fields, the `US-<zip>` geolocation code, the post job's answer, the insights read), whether the audience limit counts requests or rows (counted as requests) |
| X conversions | `x_ads` (`EXOS_X_ADS_WRITES`) | `ads_x` + `X_ADS_CONSUMER_KEY` / `_SECRET` | `POST ads-api.x.com/12/measurement/conversions/<pixel>` | OAuth 1.0a signing (test vector) | see [X](#x-conversions) |

`readInsights` is defined for Meta and Reddit and reads nothing until the org has a connected
credential (then one GET through GatedHttp, counted against Reddit's read rate); no test calls a
platform.

### Before anything goes live (operator)

1. **A CLAUDE.md write exception per platform.** CLAUDE.md's upstream rule makes third-party APIs
   read-only; the existing exceptions (the organizer's own Eventbrite / Luma, PayPal, the SMS relay)
   don't cover ad platforms. Each one (Meta, Google Data Manager audiences, Reddit, X conversions)
   needs the operator's recorded decision naming the paths above, before any flag is turned on.
2. **Remove the build pin** (`ADS_WRITES_PINNED_OFF` in `_shared/ads/run.ts`) and give `exos-ads` a
   real fetch, in a reviewed change; then the per-org switch and `EXOS_<ID>_WRITES=on` decide.
3. **App review and credentials.** Meta: a Business app with `ads_management` (Advanced Access
   through App Review), Custom Audience terms accepted in each ad account, and a "Connect Meta Ads"
   flow that writes `ads_meta_api` (not built). Google: the Data Manager scope on the existing OAuth
   client (already requested) and Customer Match terms accepted in Google Ads. Reddit: a Reddit Ads
   API app (developer access request) and a "Connect Reddit Ads" OAuth flow that writes
   `ads_reddit_api` (not built). X: X Ads API access for the Exos developer app, its consumer key /
   secret in the drain's env, and a "Connect X" (OAuth 1.0a three-legged) flow that writes `ads_x`
   (not built).
4. **Check every unverified field** above with each platform's test or validate mode.
5. Apply `20261121190500` (after `20261121162400`), deploy `exos-ads` (new, `--no-verify-jwt`),
   redeploy `exos-conversions-drain`, ship the SPA (`scripts/rollout-prod.sh`). Each needs explicit
   operator permission.

## Security

- `exos_org_ad_credentials` and `exos_marketing_conversions`: RLS on, no grants to `anon` or
  `authenticated`; `service_role` only.
- `exos_set_ad_credential` / `exos_list_ad_credentials`: `SECURITY DEFINER`, `search_path` pinned,
  owner / manager of the org (or a platform admin); the list returns `has_secret`, never the token.
- The token is in Supabase Vault (`vault.create_secret` / `vault.update_secret`, name
  `exos_ad:<org>:<platform>`); the row keeps only `secret_id`. It is decrypted only inside
  `exos_conversions_claim_batch` (service role). The SQL harness uses a Vault stub
  (`tests/exos/prereq_vault.sql`) with the same function names.
- Deleting an org cascades its credential rows but leaves their Vault secrets behind; remove the
  token in Settings first, or delete `vault.secrets` rows named `exos_ad:<org id>:%`.
- `exos_oauth_states` (mig `20260930102000`): RLS on, service role only; stores the SHA-256 of
  each state, never the state. `exos_oauth_state_begin` / `_return` / `_consume` and
  `exos_set_google_ads_token` are service-role only and re-check owner / manager for the user id
  the edge function took from the verified JWT.
- Sending hashed buyer data to ad platforms is sharing personal data under US state privacy laws
  and GDPR. Exos sends it only with advertising consent. Organizers need their own agreement with
  each platform; the privacy page names the vendors.

## Needs verification before `EXOS_CONVERSIONS_LIVE=true`

The vendors' developer sites (developers.facebook.com, business-api.tiktok.com,
developers.google.com, developers.snap.com) were not reachable from the build environment, so the
builders follow search-result summaries of the official docs. Send one test per platform with a
test code first, and check:

- **Reddit**: confirmed by the operator's brief (2026-11-21): the path
  `/api/v3/pixels/<pixel_id>/conversion_events`, the value in `metadata.value`, at most 1,000
  events a request, a 7-day window, `conversion_id` dedupe, and UPPER_SNAKE tracking types
  (`PURCHASE`; the builder sent `Purchase` before mig `20261121190500`). Still send one test with
  `test_id` first.
- **X**: every field (see [X](#x-conversions)).
- **Snap**: the `/events/validate` path and the `PURCHASE` casing.
- **Google Ads / Data Manager**: every field (`destinations[].operatingAccount`,
  `productDestinationId`, `encoding`, `adIdentifiers`, `eventSource`, `userData.userIdentifiers`,
  `consent`), with `validateOnly: true`. Also that no developer token is needed (search results say
  so; the drain sends none) and that a manager-account (`loginAccount`) setup works.
- **Meta**: `v25.0` is pinned in `meta.ts` (`META_GRAPH_VERSION`); bump it when Meta retires it.
- **GA4**: MP answers 2xx even for a malformed hit; check the first ones in DebugView (or against
  `/debug/mp/collect`). GA4 is documented to keep one purchase per `transaction_id`; confirm the
  browser and server purchase aren't both counted.

## References

- Meta Conversions API: https://developers.facebook.com/docs/marketing-api/conversions-api/using-the-api
  (v25.0 shipped 2026-02-18; endpoint `/{API_VERSION}/{PIXEL_ID}/events`); dedup:
  https://www.facebook.com/business/help/823677331451951
- TikTok Events API: https://ads.tiktok.com/help/article/getting-started-events-api,
  https://business-api.tiktok.com/portal/docs?id=1771101303285761; dedup:
  https://ads.tiktok.com/help/article/event-deduplication?lang=en
- GA4 Measurement Protocol: https://developers.google.com/analytics/devguides/collection/protocol/ga4/sending-events,
  reference https://developers.google.com/analytics/devguides/collection/protocol/ga4/reference,
  user-provided data https://developers.google.com/analytics/devguides/collection/ga4/uid-data
- Reddit Conversions API: https://business.reddithelp.com/s/article/Conversions-API
- X Conversions API: https://developer.x.com/en/docs/x-ads-api/measurement/web-conversions/conversion-api;
  OAuth 1.0a signing: https://developer.x.com/en/docs/authentication/oauth-1-0a/creating-a-signature
- Snap Conversions API v3: https://developers.snap.com/api/marketing-api/Conversions-API/UsingTheAPI,
  https://developers.snap.com/marketing-api/Conversions-API/MigrationGuide
- Google Data Manager API: https://developers.google.com/data-manager/api/reference/rest/v1/events/ingest,
  https://developers.google.com/data-manager/api/devguides/events/google-ads/offline/send-events,
  https://developers.google.com/data-manager/api/devguides/concepts/destinations; offline import
  move: https://developers.google.com/google-ads/api/docs/conversions/upload-offline
