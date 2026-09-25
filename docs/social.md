# Social integrations

What Exos does for promoters and buyers on Instagram, Facebook, TikTok, WhatsApp and SMS: what's
built, and what's missing and why. Related docs: `docs/native-sharing.md` (app Stories bridge),
`docs/maps.md`, and `docs/gtm-nyc.md` (why Instagram-first).

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
| Both | Org pixels (Meta, GA4, TikTok), consent-gated, on that org's public pages only | `lib/pixels.ts` |
| App-ready | `window.ExosNative` v1 bridge for the native app's Instagram and Facebook Stories hand-off | `lib/nativeShare.ts` |
| Both | **Auto-tagging**: fan and promoter shares @-mention the organizer and the promoter where the platform takes pre-filled text (X, WhatsApp, SMS, share sheet; not Facebook's sharer), and story posters print the handles. Each account can switch it off: organizers in Settings, promoters on their kit page | `lib/socialTags.ts`, `hooks/useShareTags.ts`, mig `20260925010000` |

## Missing, and what each needs

| Missing | Why it isn't built | Needs |
|---|---|---|
| **The native app** (iOS and Android), including direct Stories sharing | No app project exists in any repo; the web half of the bridge is done | An app repo and shell (for example a Capacitor or React Native wrapper), plus a **Facebook App ID** |
| **Meta Conversions API** (server-side Purchase events to each organizer's pixel, which survive ad blockers and iOS tracking limits) | It sends buyer data (hashed email) to Meta from our server, which is a privacy and consent decision. It also needs a per-org token | Operator decision on consent wording; each organizer's Meta pixel **access token** stored server-side; a Meta app |
| **TikTok Events API** | Same as the Conversions API | Same, per org |
| **Instagram Shop / Facebook Shop** | Unclear whether Meta's commerce policy allows event tickets. Pushing a catalog through Meta's write APIs is a third-party inventory write, which our read-only rule forbids without sign-off | A policy check; Commerce Manager setup; operator sign-off (a pull feed Meta fetches from us avoids the write) |
| **Auto-posting events to an organizer's Instagram** (Graph API `media_publish`) | Needs Meta app review for `instagram_content_publish` and per-org Instagram login | A Meta app plus app review |
| **Apple Wallet / Google Wallet passes** | Signing needs certificates | An Apple Pass Type ID certificate; a Google Wallet issuer account |
| **SMS invites and reminders** | No SMS provider | A provider account (for example Twilio) and the 10DLC registration US carriers require |
| **Fan referral rewards** ("bring 3 friends, get in free") | Referrals are counted per fan per event; turning a count into a reward is a product call | A decision on the reward (comp ticket, discount voucher, perk) and its cap per event |
| **Link previews live in production** | Code is done | Terminal-2 #1003 merged and deployed; the SPA rebuilt from EXP and copied to `static/bridge/` (today's bundle is from 07-27 and has no SSR markers); `RENDER_EXTERNAL_URL` or `EXOS_PUBLIC_BASE_URL` set |
| **Clickable Instagram mentions** | Instagram's Stories sharing has no mention field (web or app), so the poster prints the handles and the sharer adds mention stickers | Nothing we can build today |
