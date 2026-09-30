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

## Missing, and what each needs

| Missing | Why it isn't built | Needs |
|---|---|---|
| **The native app** (iOS and Android), including direct Stories sharing | No app project exists in any repo; the web half of the bridge is done | An app repo and shell (for example a Capacitor or React Native wrapper), plus a **Facebook App ID** |
| **Server-side conversions live** (Meta CAPI, TikTok Events API, GA4, Reddit, Snap; code built, see [docs/marketing-conversions.md](marketing-conversions.md)) | Sends hashed buyer data to the platforms, so it waits on the operator; Reddit and Snap request shapes need a test send; Google Ads needs a Google OAuth flow | Operator: apply mig `20260930100000`, deploy `exos-conversions-drain`, schedule it, set `EXOS_CONVERSIONS_LIVE=true`; organizers paste each platform's token in Settings |
| **Instagram Shop / Facebook Shop** | Unclear whether Meta's commerce policy allows event tickets. Pushing a catalog through Meta's write APIs is a third-party inventory write, which our read-only rule forbids without sign-off | A policy check; Commerce Manager setup; operator sign-off (a pull feed Meta fetches from us avoids the write) |
| **Auto-posting events to an organizer's Instagram** (Graph API `media_publish`) | Needs Meta app review for `instagram_content_publish` and per-org Instagram login | A Meta app plus app review |
| **Apple Wallet / Google Wallet passes** | Signing needs certificates | An Apple Pass Type ID certificate; a Google Wallet issuer account |
| **SMS invites and reminders** | No SMS provider | A provider account (for example Twilio) and the 10DLC registration US carriers require |
| **Fan referral rewards** ("bring 3 friends, get in free") | Referrals are counted per fan per event; turning a count into a reward is a product call | A decision on the reward (comp ticket, discount voucher, perk) and its cap per event |
| **Link previews live in production** | Code is done | Terminal-2 #1003 merged and deployed; the SPA rebuilt from EXP and copied to `static/bridge/` (today's bundle is from 07-27 and has no SSR markers); `RENDER_EXTERNAL_URL` or `EXOS_PUBLIC_BASE_URL` set |
| **Clickable Instagram mentions** | Instagram's Stories sharing has no mention field (web or app), so the poster prints the handles and the sharer adds mention stickers | Nothing we can build today |
