# Server-side ad conversions

Exos reports paid orders to each organizer's ad accounts from the server, not only from the
browser pixel. The browser Purchase is lost to ad blockers, iOS tracking limits and in-app
browsers; the server copy isn't. Both carry the same dedupe id, so a platform that gets both
counts the order once.

Status (2026-09-30): built, **not live**. Migrations `20260930100000_exos_marketing_conversions.sql`
and `20260930102000_exos_oauth_google.sql` are not applied; `exos-conversions-drain` and
`exos-oauth-google` are not deployed (the drain isn't scheduled); the drain is dry-run until
`EXOS_CONVERSIONS_LIVE=true`.

Pieces:

| What | Where |
|---|---|
| Per-org credentials (public ids + a Vault-stored token) | `exos_org_ad_credentials`, RPCs `exos_set_ad_credential` / `exos_list_ad_credentials` |
| Outbox | `exos_marketing_conversions`, filled by triggers on `exos_checkout_sessions` and `exos_order_refunds` |
| Drain | `supabase/functions/exos-conversions-drain` (cron), `exos_conversions_claim_batch` / `exos_conversions_mark` |
| Request builders (pure) | `supabase/functions/_shared/conversions/{meta,tiktok,ga4,reddit,snap,googleAds}.ts`, send loop `send.ts` |
| Settings UI | Org settings → **Ads & conversions** (`AdConversionsSettings`, `lib/adCredentials.ts`), owner / manager |
| Google Ads sign-in | `supabase/functions/exos-oauth-google`, `exos_oauth_states` + RPCs (mig `20260930102000`), pure helpers `_shared/conversions/googleOAuth.ts`, see [Google Ads](#google-ads) |
| Tests | `tests/exos/test_marketing_conversions.sql`, `tests/exos/test_oauth_google.sql` (in `run_p0.sh`), `src/lib/marketingConversions.test.ts`, `src/lib/googleOAuth.test.ts`, `src/lib/googleAdsConnect.test.ts` |

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
| `em` | `sha256(lower(trim(buyer_email)))` | Meta, TikTok, Reddit, Snap |
| `em_google` | same, with the dots of a gmail.com / googlemail.com local part removed | GA4 `user_data`, Google Ads (Google's normalization) |
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
| Reddit Conversions API v3 | `POST ads-api.reddit.com/api/v3/pixels/<pixel_id>/conversion_events` | `Authorization: Bearer` | `tracking_type: Purchase`, `metadata.conversion_id`, `click_id` = `rdt_cid` | hashed email or `rdt_cid` |
| Snap Conversions API v3 | `POST tr.snapchat.com/v3/<pixel_id>/events?access_token=…` | `access_token` query parameter (as Snap documents it) | `PURCHASE`, `event_id`, `user_data.em / sc_click_id / client_user_agent` | hashed email or `ScCid` |
| Google Ads (Data Manager API) | `POST datamanager.googleapis.com/v1/events:ingest` | `Authorization: Bearer` with an OAuth access token (from the org's refresh token, per run) | `adIdentifiers.gclid / gbraid / wbraid`, `conversionValue`, `transactionId`, `userData.userIdentifiers[].emailAddress` | hashed email or a click id; the Exos OAuth client configured, see [Google Ads](#google-ads) |

Age limits (rows older are skipped): Meta, TikTok, Reddit and Snap 7 days, GA4 72 hours, Google
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
   the state row (first return only) and the browser goes back to
   `<EXOS_APP_URL>/orgs/<org>/settings?google_ads=finish&google_ads_state=<state>`. A refusal or an
   unknown / used / expired state comes back as `?google_ads=error&reason=…`.
3. The settings page posts the state to `…/exos-oauth-google/finish` with the user's JWT. The state
   is consumed only for the **same user** who started it, once, before it expires, while they're
   still owner / manager. The function exchanges the code at `https://oauth2.googleapis.com/token`,
   checks the Data Manager scope was granted (Google lets users untick scopes) and that a refresh
   token came back, and stores it in Vault as the org's `google_ads` secret
   (`exos_set_google_ads_token`, name `exos_ad:<org>:google_ads`, the same one
   `exos_set_ad_credential` uses). The ids, the on/off switch and the test code are kept. The page
   shows "Google Ads connected" and the row shows **Connected**.

Step 3 is why the callback doesn't finish on its own: a consent link started by someone else and
completed in a victim's browser would otherwise attach the victim's Google account to the other
person's org. The state and the code are never logged; the code is kept at most 10 minutes and
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

- **Reddit** (least certain): the v3 path (`/api/v3/pixels/<pixel_id>/conversion_events` vs
  `/conversions/events`) and the value field name (`value` vs `value_decimal`) differ between
  integrator docs.
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
- Snap Conversions API v3: https://developers.snap.com/api/marketing-api/Conversions-API/UsingTheAPI,
  https://developers.snap.com/marketing-api/Conversions-API/MigrationGuide
- Google Data Manager API: https://developers.google.com/data-manager/api/reference/rest/v1/events/ingest,
  https://developers.google.com/data-manager/api/devguides/events/google-ads/offline/send-events,
  https://developers.google.com/data-manager/api/devguides/concepts/destinations; offline import
  move: https://developers.google.com/google-ads/api/docs/conversions/upload-offline
