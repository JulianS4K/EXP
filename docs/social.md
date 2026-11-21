# Social integrations

What Exos does for promoters and buyers on Instagram, Facebook, TikTok, WhatsApp and SMS: what's
built, and what's missing and why. Related docs: `docs/native-sharing.md` (app Stories bridge),
`docs/maps.md`, and `docs/gtm-nyc.md` (why Instagram-first).

Ad catalog feeds (Meta, TikTok, Google) and the hashed custom-audience export: `docs/marketing-catalog.md`.

## Built

| For | What | Where |
|---|---|---|
| Buyers | Checkout works inside the Instagram, Facebook and TikTok in-app browsers: no Google sign-in there, plus an "open in browser" banner | `lib/inAppBrowser.ts`, `AuthModal`, `InAppBrowserBanner` |
| Buyers | "I'm going" shares (story poster, share sheet, X, Facebook, WhatsApp, copy link), tagged `utm_medium=fan_share`, passing on the promoter who brought them | `lib/shareLinks.ts`, `lib/poster.ts`, `ShareModal` |
| Buyers | Link previews: event, organizer, checkout-link and promoter links unfurl with the event's own title, date, venue, all-in "from" price and image in WhatsApp, iMessage, Instagram and Facebook DMs, X, Slack and Discord | Terminal-2 `core/exos_seo.py` (crawler-only, reads public views), `index.html` SSR_META markers |
| Promoters | Promoter records: an organizer adds a promoter (name → code), sends a **private portal link** `/p/:token`, and sees a **leaderboard** | mig `20260924233000`, `/orgs/:orgId/promoters`, `/p/:token` |
| Promoters | Portal: their tickets and gross per event, a buy-now link builder, a story poster, and tracked links per channel (Instagram bio and story, TikTok, WhatsApp, SMS, email) | `PromoterPortal`, `PromoterKitPanel` |
| Promoters | Buy-now links pre-fill the cart (Meta Shops checkout-URL format) | `/checkout`, `lib/checkoutLink.ts` |
| Promoters | **Link in bio**: one public page (`/l/:orgSlug/:code`) for their Instagram or TikTok bio, listing the organizer's upcoming events with their code on every link | `PromoterBio`, `exos_public_promoter` |
| Buyers | **Fan referrals**: each ticket holder gets a personal code per event; their shares carry `?ref=`; friends who buy (paid or free) are counted; the ticket page shows "3 friends coming"; self-referral is ignored | mig `20260924234500`, `lib/referrals.ts`, `TicketDetail` |
| Both | Paid **and** free tickets carry the promoter code, and UTM, `fbclid` and `cart_origin` are kept | mig `20260924223000`, `_shared/attribution.ts` |
| Both | Ad click ids per checkout (`gclid`, `gbraid`, `wbraid`, `ttclid`, `rdt_cid`, `ScCid`, `twclid`, `msclkid`, `fbclid`), browser ids (`_fbp`, `_fbc`, GA client id; read only with consent), the consent state, hashed IP and user agent, stored on the checkout session for a later Conversions API feed. Never copied onto share links | mig `20260929131000`, `_shared/adIds.ts`, `lib/adIds.ts` |
| Both | Org pixels (Meta, GA4, TikTok, Reddit, Snap, X), gated per consent category, on that org's public pages only (InitiateCheckout before the Stripe redirect, GA4 `begin_checkout`; Purchase carries GA4 `items`). See [Pixels and consent](#pixels-and-consent) | `lib/pixels.ts`, `lib/purchasePixel.ts`, `lib/consent.ts` |
| Organizers | **Sources report**: paid orders, tickets and gross by UTM, promoter code and ad platform, with CSV. See [Sources report](#sources-report) | `lib/sourceReport.ts`, `SourcesPanel` |
| Organizers | **Server-side conversions** (built, not live: dry-run until `EXOS_CONVERSIONS_LIVE=true`): paid Purchases (and GA4 refunds) sent from our server to Meta CAPI, TikTok Events API, GA4 Measurement Protocol, Reddit and Snap with the pixel's dedupe id, only with advertising consent; tokens in Vault; Google Ads planned only. See [docs/marketing-conversions.md](marketing-conversions.md) | mig `20260930100000`, `exos-conversions-drain`, `_shared/conversions/`, `AdConversionsSettings` |
| App-ready | `window.ExosNative` v1 bridge for the native app's Instagram and Facebook Stories hand-off | `lib/nativeShare.ts` |
| Both | **Auto-tagging**: fan and promoter shares @-mention the organizer and the promoter where the platform takes pre-filled text (X, WhatsApp, SMS, share sheet; not Facebook's sharer), and story posters print the handles. Each account can switch it off: organizers in Settings, promoters on their kit page | `lib/socialTags.ts`, `hooks/useShareTags.ts`, mig `20260925010000` |

## Pixels and consent

### Consent categories

The cookie banner (`ConsentBanner`, store in `lib/consent.ts`) has two categories:

| Category | Loads | Google Consent Mode signals |
|---|---|---|
| **Analytics** | GA4 | `analytics_storage` |
| **Advertising** | Meta, TikTok, Reddit, Snap and X pixels; Google's ad signals (remarketing) | `ad_storage`, `ad_user_data`, `ad_personalization` |

- The banner offers **Accept all**, **Reject all** and **Choose** (two toggles). The choice is kept
  in `localStorage` (`exos.consent.v2`, no cookie) and isn't asked again. **Cookie settings** in the
  footer reopens it, so a visitor can change their mind.
- The old single choice (`exos.consent.marketing.v1` = `granted` / `denied`) still counts: granted
  means both categories, denied means neither. The first new choice replaces it.
- A category that is withdrawn after its pixels loaded reloads the page, because vendor scripts
  can't be unloaded. Events fired before a category is granted are queued (up to 20) and replayed
  to that category's vendors once it is.
- Checkout records the **advertising** choice in `exos_checkout_sessions.consent_marketing`
  (`granted` / `denied` / `unknown`, the same server contract as before). The Meta browser ids
  (`_fbp`, `_fbc`) go with a checkout only with advertising consent, and the GA client id (`_ga`)
  only with analytics consent (`lib/adIds.ts`).

### Global Privacy Control

A browser that sends GPC (`navigator.globalPrivacyControl === true`) is treated as **advertising:
denied** until the visitor explicitly switches advertising on in the banner. The banner says so,
and the advertising toggle starts off. Analytics isn't affected by GPC. Checkout sends `denied` for
a GPC visitor who hasn't opted in.

### Google Consent Mode v2

Before gtag.js is requested, `lib/pixels.ts` puts the defaults on the dataLayer:
`gtag('consent', 'default', {ad_storage, ad_user_data, ad_personalization, analytics_storage:
'denied', wait_for_update: 500})`. It follows them straight away with `gtag('consent', 'update', …)`
carrying the visitor's actual choice, and sends another update on every later change. GA4 itself
loads only with analytics consent (basic mode), so with advertising denied it runs without ad
cookies. Consent Mode v2 is what Google requires for EEA / UK ads measurement
([Google Ads help](https://support.google.com/google-ads/answer/13695607?hl=en)).

### Pixels

Settings → Marketing & socials takes each org's public ids. They are stored in `exos_orgs.marketing.pixels`,
which is public through `exos_public_orgs`, so it never holds tokens. The editor checks formats
(`lib/pixelIds.ts`) and won't save a malformed id; the loaders also skip a malformed Reddit, Snap or
X id.

| Vendor | Id | PageView | ViewContent | InitiateCheckout | Purchase | Dedupe field |
|---|---|---|---|---|---|---|
| Meta | digits | on init | `ViewContent` | `InitiateCheckout` | `Purchase` | `eventID` |
| GA4 | `G-…` | `config` | `viewcontent` | `begin_checkout` | `purchase` (+`items`) | `transaction_id` |
| TikTok | `C…` | `ttq.page()` | `ViewContent` | `InitiateCheckout` | `Purchase` | `event_id` |
| Reddit | `a2_…` (older `t2_…`) | `PageVisit` | `ViewContent` | `AddToCart` (Reddit has no checkout event) | `Purchase` (`value`, `currency`, `itemCount`, `products`) | `conversionId` |
| Snap | UUID | `PAGE_VIEW` | `VIEW_CONTENT` | `START_CHECKOUT` | `PURCHASE` (`price`, `currency`, `number_items`, `item_ids`) | `client_dedup_id` (+ `transaction_id` on PURCHASE) |
| X | pixel id, plus an event id `tw-<pixel>-<event>` per conversion | `twq('config')` | org's view-content event | org's checkout event | org's purchase event (`value`, `currency`, `contents`) | `conversion_id` |

- The dedupe id is the same one Meta and TikTok already get: the Stripe session id for a paid
  Purchase, and a random id for InitiateCheckout (`lib/purchasePixel.ts`). A server-side event for
  the same order has to send the same value in the platform's Conversions API field.
- **X** has no fixed event names. Each conversion is an event the organizer creates in X Events
  Manager, and an event without an id in Settings isn't sent to X. X's pixel and Conversion API
  dedupe on **`conversion_id`** (not `event_id`), so that's what we send.
- **Snap** matches the pixel's `client_dedup_id` to the Conversions API `event_id`, and recommends
  also sending the order reference as `transaction_id` on purchases.
- CSP: the loader hosts (`www.redditstatic.com`, `sc-static.net`, `static.ads-twitter.com`) are in
  `PIXEL_SCRIPT`, and the event hosts (`alb.reddit.com`, `pixel-config.reddit.com`,
  `tr.snapchat.com`, `tr-shadow.snapchat.com`, `analytics.twitter.com`, `t.co`) are in
  `PIXEL_CONNECT` (`src/lib/hosting/headers.ts`). They apply on pixel routes only. Image beacons
  are covered by `img-src https:`.

Sources for the field names (checked 2026-09-30; the vendors' own docs sites weren't reachable from
the build sandbox, so some of these are integrator docs that mirror them):
- Reddit `conversionId` dedup and the event list: [Reddit Conversions API help](https://business.reddithelp.com/s/article/Conversions-API),
  [Segment: Reddit Conversions API](https://www.twilio.com/docs/segment/connections/destinations/catalog/reddit-conversions-api),
  [Tealium: Reddit Pixel](https://docs.tealium.com/client-side-tags/reddit-pixel-tag/).
- Snap `client_dedup_id` ↔ CAPI `event_id`, `transaction_id` on PURCHASE: [Snap Conversions API: Deduplication](https://developers.snap.com/api/marketing-api/Conversions-API/Deduplication),
  [Tealium: Snap Pixel](https://docs.tealium.com/client-side-tags/snap-pixel-tag/).
- X `conversion_id` in the pixel and the Conversion API, `twq('config')` / `twq('event', 'tw-…')`: [X Ads API: Web Conversions](https://developer.x.com/en/docs/x-ads-api/measurement/web-conversions/conversions).

## Sources report

Event report → **Marketing** → **Sources** (owner, manager and finance, the roles that can read
the org's `exos_checkout_sessions` under `exos_checkout_sel`).

- It counts paid checkouts in `fulfilled`, `partially_refunded` and `refunded`: orders, tickets,
  gross (what was charged, before refunds) and how many orders were refunded. Free claims don't
  create checkout sessions, so they aren't in it; the Sales report's promoter breakdown covers them.
- It groups by `utm_source` / `utm_medium` / `utm_campaign` (from `attribution`, lower-cased), the
  promoter code (`promoter_id`, else `attribution.promoter`) and the ad platform, and puts a
  checkout with none of these under **Direct / unknown**. A dropdown switches to one dimension at
  a time.
- The platform comes from the click id in `ad_ids`: `gclid`, `gbraid` or `wbraid` → Google;
  `fbclid` or `fbc` → Meta; `ttclid` → TikTok; `rdt_cid` → Reddit; `ScCid` → Snap; `twclid` → X;
  `msclkid` → Microsoft. A click id means the buyer came from that platform, not that the click was
  paid (Meta adds `fbclid` to organic links too).
- **Sources CSV** exports the full breakdown.
- It degrades on older schemas. Without `ad_ids` (mig `20260929131000`, not yet applied to prod when
  this was written), the platform falls back to `attribution.fbclid` and the panel says so. If the
  read is refused or `attribution` is missing, the panel hides. The pure aggregation is
  `src/lib/sourceReport.ts` (vitest).

## Posting and listing APIs (dry run only)

Operator 2026-11-21: "For the APIs build and keep read only till build is complete." Edit event →
**Post / list this event** plans the event's posts and listings on five platforms and **sends nothing**.
Each platform is a `ChannelAdapter` on the channel core (`docs/security.md`, "Channel core"): every write
goes through GatedHttp on the adapter's explicit allowlist (a write off it is refused, thrown); with the
org's switch or the operator's `EXOS_<ID>_WRITES` off, GatedHttp records the exact payload and returns a
stand-in. On top of that, `exos-social` pins the org's switch **off**
(`_shared/social/run.ts` `SOCIAL_WRITES_PINNED_OFF`, the same pin as the ads phase) and hands GatedHttp a
fetch that refuses every call, so not even a read reaches a platform. A stand-in or missing id is a
`planned_<kind>` placeholder, which `liveSafe` refuses to ever send live. Where the platform has a draft
or paused state the plan uses it (Meetup: a DRAFT); Instagram, TikTok, LinkedIn and Google Business
Profile have none in these APIs, and the plan says so.

**Plan, then a confirmed publish.** `/plan` never sends, pin or no pin: every plan runs with the org's
switch off. Each platform's plan carries `confirm`, a SHA-256 digest of exactly the requests it would send
(method, path, redacted body). `/publish` takes one platform and that digest, plans it again, and refuses
when the requests changed (`changed`), the plan stopped (`stopped`) or no digest came (`no_confirm`).
While the build pin is in it answers 409 `pinned` and sends nothing. So a LinkedIn event or a Business
Profile post (public once sent) only goes out as the payload the organizer reviewed, and **Meetup's DRAFT
is never published in the pass that creates it**: publishing a draft is its own plan (`meetupDraftId`, a
draft checked on Meetup) with its own confirm.

**TikTok: the creator decides** (TikTok's Content Sharing Guidelines for Direct Post). The panel asks;
nothing defaults on, and until the creator has chosen, the plan stops after `creator_info` with no post
built:
- who can see the post, from the account's own `privacy_level_options` (only `SELF_ONLY` until the app is
  audited), with no default;
- comments, duets and stitches, each off until turned on, and off for good when the creator's TikTok
  settings disable it; music added to a photo post only when asked;
- whether it promotes their own brand (`brand_organic_toggle`, labelled "Promotional content") or someone
  else's for something in return (`brand_content_toggle`, "Paid partnership"), or neither. Branded
  content can't be private;
- TikTok's declaration ("By posting, you agree to TikTok's Music Usage Confirmation", plus the Branded
  Content Policy for branded content), which the creator accepts.

| Piece | Where |
|---|---|
| Migration | `20261121203000_exos_social_listings.sql` (providers `ig_publish`, `tiktok_publish`, `meetup`, `linkedin`, `google_business`, all managed; `exos_social_post_context`); test `tests/exos/test_social_listings.sql` (SL1-SL4) |
| Post kit | `_shared/social/postKit.ts`: one composer for every platform's title, text, link and image, from the discovery strings (`_shared/discovery/copy.ts` `submissionCopy`) and the event cover; a secret / TBA location is never posted. The story poster (`lib/poster.ts`) is offered in the panel for Stories posted by hand |
| Adapters | `_shared/channels/adapters/{instagram,tiktok,meetup,linkedin,googleBusiness}.ts` (core, in the registry) |
| Vendor apps | `_shared/social/apps.ts`: one OAuth app per vendor family (below); every connect flow a stub |
| Pass | `_shared/social/run.ts` (`planSocial`, `publishSocial`), edge function `exos-social` (`/plan`, `/publish`; owner / manager) |
| UI | Edit event → **Post / list this event** (`PostListPanel`): each platform's status (connected / not connected, always "Dry run"), TikTok's choices and declaration, a Meetup draft id to publish and, once planned, the post, the warnings, each request's payload and a **Publish exactly this** button per platform (switched off in this build); every plan is also in **What we'd send** (`ChannelAuditPanel`) |
| Limits | `_shared/channels/limits.ts`: `instagram` (100 posts / 24 h, cap), `tiktok` (6 inits a minute, cap; a daily creator cap, warn; both unverified), `meetup` (500 points / 60 s, cap; the existing Starter 10 attendees), `linkedin` (the existing 1,000 invites a week, shown; no invites are sent), `google_business` (a profile verified 60+ days, block) |
| Tests | `_shared/social/social_test.ts` (in CI's Deno line), `src/components/PostListPanel.test.tsx` |

Two small core changes came with it: a `WriteRule` can carry a `body` check (Meetup's GraphQL has one
path for every operation, so its allowlist pins the two mutation documents, a create only as a DRAFT and
an edit only with its keys), and a cap now trims only a request in its own metric (before, Meetup's
Starter cap of 10 attendees would have trimmed a request for GraphQL points).

### Per platform

| Platform | Adapter (`EXOS_<ID>_WRITES`) | Credential (store provider; vendor app) | Endpoints (all dry run) | Verified | Unverified |
|---|---|---|---|---|---|
| Instagram content publishing | `instagram` (`EXOS_INSTAGRAM_WRITES`) | `ig_publish`: a token with `instagram_basic` + `instagram_content_publish` for the org's own professional account; config `ig_user_id`. The **Meta** app (the ads phase's `ads_meta_api` shape; Instagram is a second product on it) | `POST graph.facebook.com/v25.0/<ig-user>/media` (`image_url` + `caption`, or `media_type: REELS` + `video_url`), then `POST /v25.0/<ig-user>/media_publish` (`creation_id`); counted on publish | the two edges, the fields, the 2,200-character caption (well-known public Graph API paths) | that 100 / 24 h is current (`GET /<ig-user>/content_publishing_limit` reads it; not called), JPEG only, a reel's processing wait, v25.0 still current |
| TikTok Content Posting (Direct Post) | `tiktok` (`EXOS_TIKTOK_WRITES`) | `tiktok_publish`: a user token with `video.publish`; config `open_id`. One **TikTok** app (Login Kit) | `POST open.tiktokapis.com/v2/post/publish/creator_info/query/` (a read TikTok makes a POST), `POST /v2/post/publish/content/init/` (`media_type: PHOTO`, `post_mode: DIRECT_POST`, `PULL_FROM_URL` `photo_images`) or `/v2/post/publish/video/init/`, `post_info` carrying only the creator's choices (above) | from the brief: unaudited apps post `SELF_ONLY` (always warned until `EXOS_TIKTOK_APP_AUDITED=on`); no QR code or contact details in the creative; ad text takes no URL, @ or # (posts: a URL is warned about) | every field name, the 6-a-minute init rate and the daily cap, `PULL_FROM_URL` needing the image domain verified, the 90-character title, the scope names |
| Meetup (GraphQL) | `meetup` (`EXOS_MEETUP_WRITES`) | `meetup`: an OAuth token for a **Meetup Pro** network organizer; config `group_urlname`, `pro_network`, `plan`. One **Meetup** OAuth client | `POST api.meetup.com/gql` with exactly two documents: `createEvent` (`publishStatus: DRAFT`, `rsvpSettings.rsvpLimit`), or, in a later confirmed pass on a reviewed draft, `editEvent` (`publishStatus: PUBLISHED`); `editEvent` with `rsvpSettings` for the allocation (`list`) | from the brief: 500 points / 60 s; Starter takes 10 attendees per event (the plan unknown counts as Starter, so the RSVP limit is capped at 10) | the endpoint (`/gql` vs the announced `/gql-ext`), every input field, the local `startDateTime` format, the ISO 8601 `duration`, the answer shape, what a mutation costs in points (counted as 10), featured photos (need an upload; none planned) |
| LinkedIn Event Management | `linkedin` (`EXOS_LINKEDIN_WRITES`) | `linkedin`: a token for the org's **organization page** (a member profile is refused); config `organization_id`. One **LinkedIn** app | `POST api.linkedin.com/rest/events` (`organizer: urn:li:organization:<id>`, localized `name` / `description`, `eventFormat`, `startsAt` / `endsAt` in ms, `externalUrl` = the tagged ticket link), headers `LinkedIn-Version`, `X-Restli-Protocol-Version: 2.0.0` | the 1,000 invites a week (existing limit row; shown, nothing counted: Exos sends no invites) | every body field, the version header value (`202511`), the scopes (`rw_events`, `r_organization_admin`), that the API has no draft, partner-program access |
| Google Business Profile | `google_business` (`EXOS_GOOGLE_BUSINESS_WRITES`) | `google_business`: config `account_id`, `location_id`, `verified_at`, and its **own** refresh token from its own sign-in on the existing Google OAuth client with `business.manage` alone. It never borrows the Google Ads connection (which never carries that scope), and only its own secret counts as connected | `POST mybusiness.googleapis.com/v4/accounts/<a>/locations/<l>/localPosts` (`topicType: EVENT`, `event.schedule` Date + TimeOfDay in the event's zone, `media` PHOTO `sourceUrl`, `callToAction: BOOK` + the ticket link) | the v4 `localPosts` resource and those fields; venue orgs only (an owned venue in Booking); a profile verified 60+ days (a block; unknown counts as too young) | the 1,500-character summary and 58-character title, phone numbers rejected in the text, review time; the API access request (below) |

Captions and texts come from the post kit: Instagram and TikTok carry no link (not clickable there;
"Tickets: link in bio", and Instagram drops URLs from the description), Meetup and LinkedIn carry the
event link tagged `utm_source=<platform>&utm_medium=listing&utm_campaign=discovery` (the Sources report
counts it), and Business Profile puts it on the post's button. The discovery catalog still lists
Meetup as **manual** (`_shared/discovery/channels.ts`) until the write is allowed.

### One OAuth app per vendor family, one grant per product (connect flows not built)

An app's products never share a grant: each connection asks only for its own product's scopes and
writes (and reads) only its own store provider (`_shared/social/apps.ts` `products`, `scopesFor`).

| Family | App (env) | Grants (scopes → store provider) | Flow (stub) | Review before outside users can connect |
|---|---|---|---|---|
| Meta | `META_APP_ID` / `META_APP_SECRET` (the ads phase's Meta app) | ads: `ads_management`, `ads_read`, `business_management` → `ads_meta_api`; Instagram posts: `instagram_basic`, `instagram_content_publish`, `pages_show_list`, `pages_read_engagement` → `ig_publish` | Facebook Login for Business, one login per product; Instagram picks the Page and its Instagram professional account | App Review (Advanced Access for `instagram_content_publish` and `ads_management`), Business Verification |
| Google | `GOOGLE_OAUTH_CLIENT_ID` / `_SECRET` (existing) | Google Ads: `datamanager` (built) → `ads_google_ads`; Business Profile: `business.manage` alone → `google_business` | `exos-oauth-google` (built for Google Ads); Business Profile is its own sign-in on the same client (asked for when the organizer connects it, without `include_granted_scopes`, so neither token is widened), writing its own refresh token | the Business Profile API access request (below) and OAuth verification of the sensitive scopes |
| LinkedIn | `LINKEDIN_CLIENT_ID` / `_SECRET` | `rw_events`, `r_organization_admin` (unverified) → `linkedin` | 3-legged OAuth 2, then pick the organization page | LinkedIn's Event Management (Community Management) program |
| TikTok | `TIKTOK_CLIENT_KEY` / `_SECRET` | `user.info.basic`, `video.publish` (unverified) → `tiktok_publish` | Login Kit (web, PKCE) | Content Posting review, then the audit that lifts `SELF_ONLY` |
| Meetup | `MEETUP_CLIENT_ID` / `_SECRET` | `basic`, `event_management` (unverified) → `meetup` | OAuth 2 for a Pro network organizer, then pick the group | an approved Meetup OAuth client (Meetup Pro) |

Each flow, when built, follows `exos-oauth-google`'s shape (a hashed state in `exos_oauth_states`, a
finish token in the URL fragment, the same user confirming) and writes its provider through
`_exos_integration_put`. The providers are managed, so Integrations' generic save refuses them.

### Before anything goes live (operator)

1. **A CLAUDE.md write exception per platform.** CLAUDE.md makes third-party APIs read-only; the
   existing exceptions (the organizer's own Eventbrite / Luma, PayPal, the SMS relay) don't cover these.
   Each platform (Instagram, TikTok, Meetup, LinkedIn, Google Business Profile) needs the operator's
   recorded decision naming the paths above, before any flag is turned on.
2. **Remove the build pin** (`SOCIAL_WRITES_PINNED_OFF` in `_shared/social/run.ts`) and give
   `exos-social` a real fetch, in a reviewed change; then the per-org switch and `EXOS_<ID>_WRITES=on`
   decide.
3. **App review and access.** Meta: App Review for `instagram_content_publish` on the Meta app. TikTok:
   Content Posting review and the audit (then `EXOS_TIKTOK_APP_AUDITED=on`); verify the image host's
   domain for `PULL_FROM_URL`. Meetup: an approved OAuth client; organizers need Meetup Pro. LinkedIn:
   access to the Event Management API. Google: fill in **Google's Business Profile API access request
   form** (Google Business Profile APIs → "request access"; the Cloud project's quota is 0 until Google
   approves it), enable the My Business APIs on the existing Cloud project, and add `business.manage` to
   the existing OAuth client's consent screen (asked for only by the Business Profile sign-in).
4. **Build the connect flows** (the table above) and check every unverified field with each
   platform's test account (TikTok's `SELF_ONLY` posts, a Meetup test group, a LinkedIn test page, a
   Business Profile test location).
5. Apply `20261121203000` (after `20261121190500`), deploy `exos-social` (new, `--no-verify-jwt`), ship
   the SPA (`scripts/rollout-prod.sh`). Each needs explicit operator permission.

## Missing, and what each needs

| Missing | Why it isn't built | Needs |
|---|---|---|
| **The native app** (iOS and Android), including direct Stories sharing | No app project exists in any repo; the web half of the bridge is done | An app repo and shell (for example a Capacitor or React Native wrapper), plus a **Facebook App ID** |
| **Server-side conversions live** (Meta CAPI, TikTok Events API, GA4, Reddit, Snap; code built, see [docs/marketing-conversions.md](marketing-conversions.md)) | Sends hashed buyer data to the platforms, so it waits on the operator; Reddit and Snap request shapes need a test send; Google Ads needs a Google OAuth flow | Operator: apply mig `20260930100000`, deploy `exos-conversions-drain`, schedule it, set `EXOS_CONVERSIONS_LIVE=true`; organizers paste each platform's token in Settings |
| **Instagram Shop / Facebook Shop** | Unclear whether Meta's commerce policy allows event tickets. Pushing a catalog through Meta's write APIs is a third-party inventory write, which our read-only rule forbids without sign-off | A policy check; Commerce Manager setup; operator sign-off (a pull feed Meta fetches from us avoids the write) |
| **Auto-posting events to an organizer's Instagram** (Graph API `media_publish`; also TikTok, Meetup, LinkedIn, Google Business Profile) | Built as a dry run ([Posting and listing APIs](#posting-and-listing-apis-dry-run-only)); nothing is sent | Meta app review for `instagram_content_publish`, the connect flows, the CLAUDE.md write exception per platform, and the build pin removed |
| **Apple Wallet / Google Wallet passes** | Signing needs certificates | An Apple Pass Type ID certificate; a Google Wallet issuer account |
| **SMS invites and reminders** | No SMS provider | A provider account (for example Twilio) and the 10DLC registration US carriers require |
| **Fan referral rewards** ("bring 3 friends, get in free") | Referrals are counted per fan per event; turning a count into a reward is a product call | A decision on the reward (comp ticket, discount voucher, perk) and its cap per event |
| **Link previews live in production** | Code is done | Terminal-2 #1003 merged and deployed; the SPA rebuilt from EXP and copied to `static/bridge/` (today's bundle is from 07-27 and has no SSR markers); `RENDER_EXTERNAL_URL` or `EXOS_PUBLIC_BASE_URL` set |
| **Clickable Instagram mentions** | Instagram's Stories sharing has no mention field (web or app), so the poster prints the handles and the sharer adds mention stickers | Nothing we can build today |
