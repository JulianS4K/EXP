# Kanban Board / Product Roadmap

## Prod state vs this repo (updated 2026-09-24, after the operator-approved apply)

- **DB caught up.** Applied to prod 2026-09-24: the 2026-09-11 Stage 2/3 set and
  `20260924200848_exos_audit_hardening_quota_transfer_waitlist` (which also carries the transfer secret leak fix).
  Then the P0 set and all-in pricing: `20260924205115`, `205508`, `205916`, `210103`, `211840` (verified on prod).
  `20260702121000` and `20260911130000` were not applied on their own; later migrations supersede them (see their headers).
- **The `/bridge/` bundle (Terminal-2 `static/bridge/`, built 07-27) still works**, and it's now safe to rebuild it from
  this repo and copy `dist/` over.
- **Payments are dormant by choice.** `stripe-webhook`, `exos-checkout`, `exos-reconcile-checkouts` have never been deployed.
  Before Stripe go-live: set `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` / `CRON_SECRET`, deploy the three functions,
  register the Stripe webhook endpoint. The existing `exos-reconcile-checkouts-15min` cron starts hitting the function once
  it's deployed.

## All-in pricing (operator decision 2026-09-24)

✅ **Every buyer-facing price is all-in.**
- Checkout folds exclusive tax into each line (no separate Tax line). Buyers pay no service fee.
- The storefront (event page, tier list, add-ons, home / org / profile "from" prices, price-rise
  nudges) shows the same figure, via `allInPrice` (client) and `allInCents` (server), which are
  parity-tested.
- The public views expose `exclusive_tax_percent` (mig `20260924211840`, applied).
- The storefront discount-code box was removed: it lowered the displayed price but checkout never
  applied it, so the charge could be higher than shown. Server-validated vouchers remain.
- Listing cards now load tiers, so "from $X" is no longer $0.
- **Follow-ups:**
  - Server-side discount codes, if still wanted.
  - A "buyers will see $X" preview in the organizer tier editor.
  - Counsel review of fee and tax display per market.

## Phases (plan: `docs/strategy.md`, go-to-market: `docs/gtm-nyc.md`)

| Phase | Theme | Status |
|---|---|---|
| 0 | Payments go-live + P1 audit fixes | 🟡 in progress: P0 live; P1 items below |
| 1 | NYC indie wedge: Instagram/Facebook in-app checkout, Maps, SEO, promoter links, CRM, wallet passes | 🟡 in-app browser ✅, Maps ✅, checkout links ✅, promoter kit ✅, fan/promoter sharing + app Stories bridge ✅; next: prerendered SEO pages, CRM, wallet passes |
| 2 | Face-value resale exchange + pricing intelligence (read-only from Terminal-2) | ⬜ |
| 3 | Venue POS (Toast): Stripe Terminal box office, bar/merch, settlement | ⬜ |
| 4 | Channel hub (Otter): one inventory across own channels, then authorized marketplaces (item 8) | ⬜ |
| 5 | Platform: DB split, public API, plugins, new cities | ⬜ |

## Roadmap (operator, 2026-09-24)

P0 (paid-ticketing blockers) is done and its migrations are live. Payments go live when the operator
works through `docs/payments-go-live.md`. **The phased build plan is `docs/strategy.md`; go-to-market
(NYC first) is `docs/gtm-nyc.md`.** P1 is in the audit list. Beyond
that:

**7. Social commerce, maps and SEO**
- **Checkout inside Instagram / Facebook in-app browsers.** Hosted event and checkout pages that
  work inside the Meta in-app webview. Plan for:
  - Stripe Checkout redirects inside the webview, with Apple/Google Pay fallback behaviour.
  - Sign-in without popups.
  - `og:` tags for rich link previews.
  - Pixel attribution. Meta's own checkout surfaces are a later, separate integration with its
    own review.
  **Built:**
  - `src/lib/inAppBrowser.ts` detects Instagram, Facebook, Messenger, TikTok and others.
  - Inside them, the sign-in modal hides Google and Microsoft (Google refuses OAuth in webviews)
    and keeps Apple and email.
  - Event and storefront pages show a banner: "buy here, or open in your browser for Apple Pay"
    (an Android intent link; on iOS, copy the link).
  - Checkout was already a same-tab redirect.

  **Still to do:** test on real devices (per iOS and Instagram release), and use `og:` data for
  richer previews.
- **Interactive maps, phase 1** ✅ (`docs/maps.md`):
  - `exos-geocode` is the server-side Geocoding proxy (organizers only, key stays server-side);
    `exos-geocode-refresh` is its daily cron.
  - Mig `20260924230000` stores pins; buyers see coordinates for 30 days at most, Place IDs are
    kept.
  - `@vis.gl/react-google-maps`: the event page gets an AdvancedMarker, and a new `/map` page
    shows all events.
  - The Terminal-2 CSP allows Maps hosts on map pages only.
  - **Not applied or deployed**; needs keys (see the doc).
  - Phase 2 (native SDKs) and Phase 3 (Places UI Kit intake) are scoped in the doc.
- **Google Maps** ✅:
  - Event pages show a "Directions" link (keyless Maps URLs).
  - An embedded map appears when the build has `VITE_GOOGLE_MAPS_EMBED_KEY`. Restrict that key
    to the Embed API and our referrers.
  - Built in `src/lib/maps.ts` and `src/components/VenueMap.tsx`.
  - The storefront venue map is a follow-up.
- **SEO:**
  - Server-rendered or prerendered event pages. The SPA serves one shell today, and Terminal-2
    already has an event-page SSR pattern (`tests/test_event_page_ssr_meta.py` there).
  - ✅ `schema.org/Event` JSON-LD and canonical URLs (Terminal-2 `core/exos_seo.py`, server-side meta on
    `/bridge/event/:id` and `/bridge/o/:slug`).
  - ✅ `/bridge/sitemap.xml` (public, not-ended events + orgs with a slug) and a `Sitemap:` line in
    robots.txt (Terminal-2 `build_sitemap`, 2026-09-25; not deployed until that branch merges).

**7d. Checkout links, promoter kit, app-ready sharing** ✅ (`docs/native-sharing.md`)
- **`/checkout?products=<tierId>:<qty>,<addonId>:<qty>&coupon=…`** follows Meta's Shops checkout-URL
  format.
  - It resolves the event and pre-fills tier, quantity, add-ons and voucher on the event page.
  - The event page and `exos-checkout` re-check everything.
- **Paid checkout now keeps `?promoter=` and UTM, `fbclid` and `cart_origin`.**
  - The shared sanitizer is `_shared/attribution.ts`.
  - It's stored on the session by mig `20260924223000` (**not applied**), and fulfillment stamps
    `promoter_id` on tickets.
  - Before this, a promoter's paid sales never reached the Sales report.
- **Promoter kit.** Available on the Promote page, plus a no-login `/promoter/:eventId/:code` page
  the organizer sends each promoter. It has:
  - a buy-now link builder;
  - a story poster;
  - tracked links per channel.
- **Fan shares** (ticket and event pages) are tagged `utm_medium=fan_share` and pass along the
  promoter the fan came from. WhatsApp was added to the share sheet.
- **`window.ExosNative` bridge (v1)** for the future app's Instagram / Facebook Stories hand-off.
  The web keeps its share-sheet fallback.
- **Open:**
  - a Meta App ID (operator);
  - a sticker layer;
  - the Shop catalog (policy check, plus operator sign-off for any push).

**7e. Social: link previews and promoter records** ✅ (`docs/social.md` has the built / missing
list)
- **Link previews.** Terminal-2 `core/exos_seo.py` gives crawlers (WhatsApp, iMessage, Instagram
  and Facebook DMs, X) each event's and organizer's own preview.
  - It covers checkout and promoter links too.
  - The "from" price is all-in.
  - It goes live once the rebuilt bundle, with its SSR markers, is deployed.
- **Promoter records** (mig `20260924233000`, not applied).
  - The organizer's promoter manager has a leaderboard (`/orgs/:orgId/promoters`).
  - Each promoter gets a private portal (`/p/:token`) with their own sales and kit.
  - Links can be paused or rotated.

**7f. Link in bio and fan referrals** ✅
- **Promoter link in bio** (`/l/:orgSlug/:code`): one bio link that lists the organizer's upcoming
  events, credited to the promoter.
- **Fan referrals** (mig `20260924234500`, not applied): a code per ticket holder per event.
  - Friends who buy through it are counted, whether the tickets are paid or free.
  - The ticket page shows the count.
  - Rewards are not built; that's an operator decision (`docs/social.md`).

**8. Ticket marketplace APIs**
- **Reading (inventory, pricing and event data):** fine. Reuse Terminal-2's read-only clients
  (`*_client.py`, GET-only by construction).
- **Writing (listing Exos inventory on marketplaces, syncing sales back):** forbidden without
  explicit operator authorization. This is the project's read-only-upstream rule, enforced in
  Terminal-2 CI by `scripts/check_readonly.py`.
  - `exos-distribute` (Automatiq/Lysted) is written but must stay undeployed until the operator
    signs off on each partner's write scope.
  - Plan each partner as its own reviewed integration: auth, idempotency, inventory
    reconciliation, and how a marketplace sale reserves an Exos seat. That last one would go
    through `exos_seats_available`, like any other sale.

## Stabilization 2026-09-25

Review of both PRs, then every pending migration replayed on a local copy of prod's real schema
(all 85 functions and every table, policy and grant checksum-matched to prod). ✅ = fixed on
`claude/exos-p0` / Terminal-2 `claude/d4-exos-p0`.

- ✅ **Prod bug: creating an event series fails** whenever an org has discount codes. It's a
  syntax error in the code copy, and the offline harness never saw it because its stub has no
  `exos_discount_codes`. Fixed by mig `20260925001000`, tested in `test_event_series_codes.sql`.
- ✅ Hidden tiers unlocked by a voucher were unbuyable (the page fell back to tier 0). Mig
  `20260925000000` (`exos_voucher_tier`) plus `EventDetails` now shows the unlocked tier.
- ✅ Pending migrations re-run safely (replay tested in `run_p0.sh`).
- ✅ Pixels: no cross-org leak on reload, no late pixel on untracked pages. Checkout prefill
  survives sign-in. Toasts after checkout and free claims.
- ✅ `stripe-webhook` ignores connected-account events except that org's `account.updated`.
  `exos-geocode` isn't an open proxy. A geo error keeps the pin.
- ✅ Promoter kit tokens are hidden from the content role and from the analytics roles
  (`coworker_readonly`, `analyst_ro`), and `referral_code` is readable by ticket owners.
- ✅ Browser smoke tests (`npm run smoke`, 9 flows, mocked Supabase) run in CI.
- **End-to-end trial run** on a local copy of prod: a fake event ("Exos Trial Run — Warehouse
  Party (TEST)") created, promoted, sold (with sold-out races), transferred and scanned at the door.
  Stripe was simulated. The core flow and access control passed. Fixed by mig `20260925003000`
  (`test_trial_run_fixes.sql`):
  - ✅ add-ons were folded into every ticket's `price_paid`, inflating promoter gross and analytics;
  - ✅ a full refund of a scanned order voided nothing. Analytics now show add-on revenue, partial
    refunds and **net revenue**: the trial's $54.44 had been reported as $82.44;
  - ✅ free claims now need a confirmed email (bots could drain free tiers);
  - ✅ a hidden tier can't be held without its voucher, and clients can no longer read hidden-tier
    stock.
- ✅ **Round 2** (mig `20260925010000`, `test_trial_run_fixes_2.sql` plus a real-schema run with a
  failing negative control):
  - referral credit attaches to free claims only;
  - a claimed transfer carries the recipient's email;
  - pre-doors test-window scans verify the ticket but don't use it up (the scanner shows "Test scan OK");
  - cancelling a transfer withdraws its unsent mail;
  - mail says Exos, not "the Bridge app";
  - a buyer whose paid order fails in a sold-out race is mailed.
- ✅ **Operator decisions 2026-09-25**, built:
  - **Shares auto-tag the organizer and promoter where allowed**:
    - @handles in the text on X, WhatsApp, SMS and the share sheet, with none on Facebook (its
      sharer drops text);
    - printed on story posters, since Instagram Stories can't be pre-filled;
    - organizers switch it off in Settings; promoters set their handles and switch on their kit
      page (`lib/socialTags.ts`, `hooks/useShareTags.ts`).
    - Fan shares still credit the promoter.
  - **Profiles are private by default**: readable by the owner, org staff for their ticket
    holders, teammates, or anyone once `is_public` is set.
- ✅ **Presales from the organizer UI** (mig `20260925012000`, `test_presale_vouchers.sql`):
  - the voucher editor picks the code (e.g. PRESALE), the ticket type, the number of uses and
    whether holders can buy when sold out;
  - codes match in any case;
  - the discount-code "unlocks hidden tiers" toggle, which checkout never honored, now points
    organizers to vouchers.
- **Applied to prod 2026-09-25**: `20260924215000`, `223000`, `230000`, `233000`, `234500`,
  `20260925000000`, `20260925001000`, `20260925003000`, `20260925010000`, `20260925012000`.
  Each was verified against the tested mirror by function checksum.
- **Operator decisions 2026-09-25, round 2**:
  - Holds don't reserve add-ons (unchanged).
  - **Door staff don't see buyer emails**: mig `20260925013000` (authored; the SPA already reads
    emails through `exos_ticket_buyer_emails`). ⚠ Apply it only after a bundle built from this
    branch is deployed to `/bridge`. The live 07-27 bundle selects `buyer_email` directly and would
    break.

## Audit 2026-09-24 — open findings

Three parallel reviews (DB / edge functions / frontend). ✅ = fixed in the audit PRs (EXP `claude/exos-audit-fixes`,
Terminal-2 https://github.com/JulianS4K/Terminal-2/pull/1001). Everything else is open. The ✅ DB fixes (including P0) are live in prod; the ✅ edge-function fixes ship when payments go live.

**Payments (edge functions)**
- ✅ H — auto-refunds on destination charges didn't set `reverse_transfer` / `refund_application_fee`, so the
  platform paid every refund and the organizer kept the money (`stripe-webhook`, `exos-reconcile-checkouts`).
- ✅ H (P0) — partial-then-full refunds could leave valid tickets: refunds are now recorded by Stripe id
  (`refunds.list`), NULL ids are refused, and the void is idempotent (mig `20260924205115`).
- ✅ M — Stripe session lives 24h but the seat hold lasts 30 min; now `expires_at` = 30 min.
- ✅ M — hidden (non-public) tiers were purchasable by UUID without a voucher.
- ✅ M (P0) — checkout charges the scheduled price (`supabase/functions/_shared/pricing.ts`, parity-tested
  against `src/lib/pricing.ts`).
- ✅ M (partly) — `stripe-webhook` ledger writes now return 500 on failure so Stripe retries; the reconcile
  sweep now records its refunds by id and surfaces errors too.
- ✅ H — `account.updated` for organizers comes from a *connected-accounts* endpoint with its own secret; the
  webhook now accepts `STRIPE_CONNECT_WEBHOOK_SECRET` too (otherwise nobody could ever sell).
- ✅ M — reconcile sweep: sessions are stamped (`exos_reconcile_mark`, backoff to 24h) and read oldest/due
  first; webhook and sweep share one refund key + params (`_shared/auto-refund.ts`), and the sweep checks
  Stripe's existing refunds first (mig `20260925020000`, not applied yet).
- ✅ M — `exos-webhook-drain` claims rows (`exos_webhook_claim_batch`, SKIP LOCKED + lease + claim token) and
  signs `<timestamp>.<body>`. Prod has no webhooks yet, so the signature change breaks no receiver.
- ✅ L — open redirects via client `success_url`/`cancel_url`/`return_url`: both functions now require the URL's
  origin to be in `EXOS_REDIRECT_ORIGINS` (`_shared/redirects.ts`).
- ✅ L — add-on oversell (read-then-charge): fulfillment claims add-ons atomically and rolls the whole order back
  if one is gone (mig `20260924215000`, not applied yet).
- ✅ L — SSRF blocklist (`_shared/ssrf.ts`, full IPv6 parsing, all reserved ranges); `exos-api` limits 120
  req/min per key (429); a dispute is recorded (`dispute_*`), and only a lost one voids tickets. Left: invalid
  keys aren't rate-limited; DNS rebinding in the SSRF check.
- INFO — `exos-distribute` exists to POST listings to Automatiq; keep undeployed until the operator signs off
  (read-only-upstream rule).

**Database**
- ✅ H — any signed-up user could map their own quota onto another org's tier and zero its availability
  (`exos_quota_tiers_wr` never checked the tier's org).
- ✅ H — transfer race: two concurrent transfers of one ticket both claimable; the sender can claw a sold ticket
  back. Claim now locks the ticket and requires `pending_transfer_id` + current owner to match.
- ✅ M — `authenticated` could UPDATE any column of its own waitlist row (queue position, status, voucher).
- ✅ H (P0) — one voucher use = one ticket; waitlist offers carry the group size, go out FIFO, and reserve
  their seats (`block_quota`) (mig `20260924205508`).
- ✅ H (P0) — one live cart hold per buyer per event, purchase limits at hold time, confirmed email, 30-min TTL
  (mig `20260924205916`). Residual: many confirmed accounts can each hold one cart.
- ✅ H (P0) — free-claim, issue-to-email, comp batch and box-office mint go through `exos_seats_available`
  (quotas + holds + offers) (mig `20260924210103`).
- ✅ M — signed-in users read `exos_orgs` only as members/admins and published events only through the public
  views (which now run as their owner); the invite page uses the public org (mig `20260925021000`, not applied).
- ✅ M — check-in: `p_event_id` required, cancelled events refused (`event-cancelled`), anything barcode-shaped must
  pass HMAC whatever the source, `verification` derived server-side (mig `20260925021000`).
- ✅ M — vouchers were consumed before capacity checks and burned when fulfillment failed; a failed house cap also
  leaked the tier's `sold`. Fulfillment is now all-or-nothing (mig `20260924215000`). ✅ Fulfillment re-checks
  the voucher (exists, not expired, email + tier) before consuming it (mig `20260925021000`). Decision open: expiry
  is strict, so a voucher that expires mid-payment fails and refunds that order.
- ✅ L — issue-to-email and the comp batch answer the same whether or not the recipient has an account; free
  box-office mints and issue-to-email count against `comp_budget`; claiming an invite never overrides a membership
  edited after it was sent or demotes an owner, and every invite expires (14 days default, 30 max)
  (mig `20260925021000`). (✅ `exos_assert_purchase_limit` no longer callable by users.) Left: staff can still infer
  an account from a comp's `owner_id`; a $0.01 mint isn't counted as a comp.

**Frontend**
- ✅ H — door scanner admitted on the offline registry after the server said `used`/`voided`/`in-transfer`.
- ✅ M — replayed offline check-ins dropped server refusals silently; now audited + surfaced.
- ✅ H (partial) — scanner registry (every ticket's barcode secret) now wiped on sign-out. Still open: it
  lives in plaintext localStorage for 7 days. (✅ Pixels no longer load on `/checkin`.)
- ✅ L — removed the `GEMINI_API_KEY` Vite `define` (a future reference would inline the key) and `@google/genai`.
- ✅ H (correctness) — production CSP/XFO from Terminal-2 killed the embed, the org pixels and Google Fonts. Fixed
  with a `/bridge/*` policy in Terminal-2 `server.py` (https://github.com/JulianS4K/Terminal-2/pull/1003); live
  once that merges and deploys.
- ✅ M — one org's pixels received other orgs' events. Now one org per page: switching org, or leaving to an
  untracked page (tickets, wallet, account, dashboards, `/checkin`), reloads to drop loaded pixels, and Meta's
  SPA auto-PageView is off (`src/lib/pixels.ts`, `isPixelRoute`).
- ✅ M — `server.ts` `/api/*` removed (unused; `/api/verify-session` was unauthenticated); `stripe` dependency dropped.
- ✅ L — dead Firebase rules and env vars deleted; SVG no longer offered for logos (the bucket rejects it);
  the embed snippet strips `--` and `<>` from the title. Stripe.js stays (EventDetails uses it).
- L — the unsigned legacy barcode fallback in check-in can never scan (left for the check-in hardening pass).


Current baseline: `af37caf` + tsconfig fix + 4 rebuild commits
(mail templateName rename, voided ticket status, pending-transfer
lock, ScanReport field rename).

## In Progress (rebuild queue, ~10 commits remaining)

- **Commit 5** — Scanner event-scoping reinforcement: clearer
  "Wrong event — this ticket is for [other title]" error copy +
  `events/{eventId}/scanRejects/{id}` audit collection so
  organizers can see attempted misdirected scans.
- **Commit 6** — Performer names. `event.performers?: string[]`
  field (max 10 × 80 chars), chip input on Create + Edit, render
  on EventDetails, threaded into email templates.
- **Commit 7** — EditEvent timing controls (Date / Doors /
  Show Start / Show End inputs in EditEvent's Logistics section,
  mirroring CreateEvent's `showPicker()` pattern).
- **Commit 8** — Event change notifications. EditEvent diffs
  date/doors/start/end/venue/title against pre-edit snapshot;
  queues `event-updated` email per active ticket holder
  summarizing only changed fields. (Price changes deliberately
  skipped until refund flow is wired.)
- **Commit 9** — Wallet pass route. `/wallet/pass/:ticketId`
  fullscreen browser-only pass with rotating QR + screen wake-lock
  + status overlays. Bare layout (no chrome).
- **Commit 10** — ✅ SHIPPED 2026-09-11 (Supabase form): "Send
  reminder now" on OrganizerEventReport (`RemindersPanel`) →
  `exos_send_event_reminder_now`, 6-hour cooldown via
  `exos_events.reminder_manual_sent_at`. Automatic T-24h / T-2h
  sends ride the `exos_send_event_reminders` cron (mig
  20260911051000). Not on OrganizerCheckIn (door staff don't mail).
- **Commit 11** — Scanner offline improvements: 5-min registry
  auto-refresh while online, attest-and-admit escape hatch,
  audit-backfill writes `events/{id}/checkIns` on sync with
  `offlineScannedAt`.
- **Commit 12** — Cap hardening, client-side only. EventDetails
  recount before checkout + MyTickets clamp at fulfillment.
  Server-side firebase-admin check deferred until Stripe Connect.
- **Commit 13** — Concentration flags. Owner-only
  `users/{uid}/concentrationFlags/{eventId}` collection +
  ClaimTicket post-claim count + write when over cap. Broker
  detection signal for when we scale.
- **Commit 14** — Apple/Google Wallet endpoint scaffolds. Server
  endpoints with idToken verify + ownership check, returning 503
  with setup hints until env vars set. APPLE + GOOGLE buttons on
  TicketDetail.

## Stage 3 — organizer side (2026-09-11, PR #976, Supabase form)

Shipped in source on `claude/d4-organizer-stage3` (stacked on #975); migrations
`20260911130000`–`133000` apply-pending. Customer-facing surfaces untouched.

- **Analytics + CSV** — `exos_event_analytics` → `EventAnalyticsPanel`
  (funnel · sales-by-day · tier/promoter/channel with scan-in) + Summary /
  Attendees CSV via the shared `lib/csv.ts`.
- **RSVP release** — `exos_release_ticket` (holder or staff; FREE only;
  returns tier + house capacity → waitlist auto-offer) + `ReleasePolicyPanel`
  + staff "Release seat". Attendee button → customer session (bot_chat #3652).
- **Guest list / comps** — `exos_issue_comp_batch` → `CompIssuancePanel`;
  org `comp_budget` on OrgSettings.
- **Refused-scan audit** — `ScanRejectAudit` on OrganizerCheckIn (reads
  `exos_scan_rejects`, which the scanner had written since phase 2).
- **Series** — `exos_event_series` + `exos_create_event_series` (template
  cloned per date, tiers included) → `CreateSeries` at
  `/dashboard/event/:id/series`; dashboard badge + link. Later: series-wide
  edit/cancel, storefront grouping.

## Competitor gap backlog (TM · AXS · SeatGeek · OpenDate — 2026-07-03)

Feature-parity gaps from a scan of Ticketmaster, AXS, SeatGeek, and
OpenDate against what Bridge ships today, ranked by impact for our
indie-primary + secondary-market positioning. `[ ]` = not started,
`[~]` = partial/scaffolded, `[x]` = shipped.

### Seller side (organizer)
- `[x]` **Scheduled / dynamic tier pricing** (early-bird → regular →
  last-minute time steps). *(TM, SeatGeek.)* Shipped v1: `price_schedule`
  on tiers (mig `20260703122000`), read-time effective price
  (`lib/pricing.ts`), `TierPricingPanel` editor on the event report,
  live price + "price rises on…" nudge on EventDetails. **Follow-up:**
  sold-%-based steps; server-side charge enforcement lands with
  exos-checkout (must recompute effective price server-side).
- `[ ]` **Reserved seating maps** — visual section/row/seat chart
  builder + per-seat pricing + buyer seat picker + ADA/accessible
  seats. *(TM, AXS, SeatGeek — table stakes.)* We only have a free-text
  `seatingManifest`. Largest single build; unblocks ADA + per-seat price.
- `[ ]` **Marketing automation + CRM** — segmented email/SMS/push
  campaigns to followers / past attendees / waitlist, **abandoned-cart
  recovery**, audience segments. *(OpenDate's moat; TM, SeatGeek.)*
  Reuses `exos_mail` + `exos_org_follows` + ticket history. Highest
  revenue leverage after resale.
- `[ ]` **Timed-entry / time-slot / recurring events** — capacity per
  slot; daily/recurring admissions. *(Most modern platforms.)* We're
  single-date only.
- `[ ]` **Season packages / memberships / multi-event bundles.** *(TM,
  AXS, SeatGeek.)* Single-event only today.
- `[ ]` **Box office / POS** — in-person sale, card reader, cash,
  physical ticket stock printing. *(OpenDate, AXS venues.)* Online-only.
- `[ ]` **Booking + artist settlement** — holds/offers calendar, deal
  terms, payout/settlement accounting. *(OpenDate signature.)*
- `[x]` **Auto pre-event reminders** (T-24h / T-2h). Shipped 2026-09-11:
  cron RPC `exos_send_event_reminders` + manual send-now (mig
  20260911051000); delivery still gated on the Resend key (D4-OPS-19).
- `[ ]` **Group sales / comp allocations** workflow. *(TM, AXS.)*
- `[ ]` **RFID / hardware access control + entry zones.** *(Enterprise
  venues.)* We have phone-camera scan only.

### Buyer side (fan)
- `[ ]` **Fan-to-fan resale / face-value exchange** — priced resale,
  barcode void+reissue to buyer, payout routing, price caps. *(TM Face
  Value Exchange, AXS Official Resale, SeatGeek marketplace.)* **#1
  strategic gap** — it *is* our secondary-market thesis, and the
  reissue-on-transfer + `channelSource` + Automatiq schema are already
  here. We only do free transfers today. **Recommended next build.**
- `[ ]` **Ticket insurance / refund protection.** *(TM, AXS, SeatGeek
  via XCover / Cover Genius.)* Add-on revenue; mostly a partner wire-up.
- `[ ]` **Installment / BNPL payment plans** (Affirm / Klarna /
  Afterpay). *(SeatGeek.)* Conversion on higher-priced tiers.
- `[ ]` **Smart queue / virtual waiting room + Verified Fan** (fair
  high-demand onsales). *(TM, AXS.)* Our waitlist is post-sellout only.
- `[ ]` **Deal Score / price transparency + personalized discovery.**
  *(SeatGeek.)* Basic discovery only today.
- `[ ]` **Event-day experience hub** (directions, food-to-seat, merch,
  rideshare, in-app upgrades — SeatGeek **Rally**). We stop at ticket +
  add-ons.
- `[~]` **Native Apple / Google Wallet passes.** *(TM, AXS, SeatGeek.)*
  Browser-only `WalletPass` today; native `.pkpass` / Google Wallet
  scaffolds still on the rebuild queue.
- `[ ]` **Self-service upgrades + gift cards / gifting.** *(TM,
  SeatGeek.)* Upgrades depend on the seat-map work.

## To Do (post-rebuild — borrowed from hi.events + pretix research)

The most public open-source alternatives are hi.events (Laravel +
React, ~2 years old, AGPL-3.0) and pretix (Django, ~10 years old,
mature plugin marketplace). Both are battle-tested in different
markets — hi.events on Eventbrite-replacement, pretix on
conferences. Items below are picked from feature comparison;
they're things they have that we don't, ranked by impact for our
indie-cap + secondary-market positioning.

### Stripe webhook fulfillment (server-side)

- Today: ticket-mint runs client-side in `MyTickets.tsx` after the
  Stripe redirect. Fragile — a buyer who closes the tab before
  fulfillment runs gets a paid receipt with no ticket.
- Need: Cloud Function on `checkout.session.completed` webhook
  that mints the ticket server-side, idempotent on `session.id`.
  Removes the entire client-side mint path.
- Blocker: Cloud Functions surface not yet built. Lands with the
  Stripe Connect work for Sprint 3.

### Tax + fee config (per-event, organizer-managed)

- Today: tickets carry `pricePaid` only. No way for organizer to
  add a $2 facility fee or 8.875% NYC sales tax separately.
- Need: `event.fees?: { name, type:'percent'|'fixed', value,
  taxable:bool }[]`. Stripe session emits a separate line item per
  fee. CSV export breaks them out.
- Blocker: requires Stripe line-item refactor. Wait for Stripe
  Connect.

### Plugin loader

- Today: zero. Adding a new payment method, integration, or
  custom workflow requires forking.
- Need: minimal plugin contract — `manifest.json` + entry-point
  module that registers handlers (event-cancel hook, custom
  payment method, custom email template). Pretix has a 10-year-
  old marketplace; we can start with 5 hooks and grow.
- Effort: large. Multi-week build. Long-term moat once it exists.

### Reserved seating maps

- Today: free-form `seatingManifest` text field.
- Need: structured zone/section/row data + visual seat-map editor
  for the organizer + per-tier seat assignment + buyer-facing seat
  picker. Pretix has this; hi.events doesn't.
- Already tagged: in-progress on the existing kanban under "Fully
  dynamic GA Seating & customized manifesting".

### Multi-language (English + Spanish)

- Today: every UI string is hardcoded English.
- Need: i18n framework (lightweight: `react-i18next` or
  similar — NOT one of the heavy SaaS solutions). Extract every
  user-facing string in views/ + components/ to translation keys.
  Ship es-US locale first (largest non-English language in US
  events).
- Scope: every view + email template. ~1-2 days of mechanical
  extraction + translation review. Spanish-only for v1; other
  languages added per-translator capacity.

### REST API for event creation + webhook delivery

- Today: events are created via Firestore SDK from the SPA. A
  partner who wants to sync events from their own CRM has no
  HTTP endpoint to call.
- Need: `POST /api/events` + `PATCH /api/events/:id` + signed
  outbound webhooks (mentioned earlier as Kanban #127).
- Pretix exposes their entire feature set via REST. We don't need
  100% parity — start with event create/update/cancel + ticket
  list + transfer create.

### XLSX export

- Today: CSV export only.
- Need: same data, XLSX format. Trivial — `xlsx` npm package, one
  new download button. Useful for organizers who pivot in Excel.
- Effort: half a day.

### More payment methods

- Today: Stripe Checkout only.
- Need: at minimum, support for bank transfer (for B2B/conference
  invoicing) + a free-ticket path that doesn't require a Stripe
  session id (currently the rule requires it).
- Pretix has a dozen payment methods via plugins. Once the plugin
  loader exists, this becomes someone-else's-problem.

## To Do (existing kanban, deferred)

- ~~**Auto-firing pre-event reminder emails**~~ — ✅ done 2026-09-11 as a
  pg_cron RPC (no Cloud Functions needed); see Commit 10 above.
- **Outbound webhook system** — per-org webhook config + signed
  HTTP delivery worker. Foundational for CRM/automation.
- **MailChimp / Salesforce / Zapier** — connectors that subscribe
  to outbound webhooks. Blocked on the webhook system.
- **Native CMS plugins** — WordPress / Wix / Squarespace embedding
  the existing `/embed/event/:id` route + checkout.
- **Google Maps + Google Places** — env-gated by
  `VITE_GOOGLE_MAPS_API_KEY`. Lazy script loader + Places
  Autocomplete on Create/Edit address fields + iframe-embed map
  on EventDetails.
- **Music identity OAuth** — Spotify / Apple Music / YouTube
  Music / Last.FM / Bandsintown to build a Music DNA profile per
  buyer.
- **Algorithmic discovery (Suggested for You)** — recommendation
  engine seeded by Music DNA + browsing/purchase history. Blocked
  on the music identity work.
- **Friends & social graph** — find friends, sync contacts, see
  what events friends are attending, form groups.
- **Advanced social marketing hub** — auto-publish to
  Instagram / Facebook, track ad ROI, generate AI copy.
- **Automatiq / Secondary Market Sync** — bi-directional API sync
  to forward inventory to StubHub / SeatGeek / Ticketmaster /
  Vivid + resend failed transfers. The `channelSource` field
  exists on tickets in our schema; this work makes it real.
- **Organizer profiles + follower system** — buyer-facing org
  pages with a follow button, notifications when followed orgs
  publish new events.

## Done

- **Prod apply — the five D4 migrations are LIVE + verified (2026-07-04).**
  `20260703120000`–`20260703124000` (saves · announcements · tier price
  schedule · announcement retract · reschedule) applied to prod
  (`hzrizjeaxlqcxfrtczpq`). Verified against actual schema objects, not
  the ledger — prod stamps migrations by MCP `apply_migration` timestamp,
  so repo filename version-keys never match; confirmed via `to_regclass`
  / `pg_policy` / column + grant introspection that every table, column,
  RPC, RLS policy, view option (`security_invoker`), and mail-allowlist
  value is present and matches. Security advisor clean for these surfaces
  (only the by-design "authenticated can execute SECDEF" WARN on the two
  RPCs — gate is inside the function body). Code merged to `main` via
  PR #777 (squash `85da7b7`).
  - `[ ]` **Follow-up (D4 · ops):** confirm the `exos_mail` drainer is
    configured + running (`RESEND_API_KEY` + `EXOS_MAIL_FROM`) — the
    schema is verified but email *delivery* for announcements + reschedule
    notices rides that drainer. In-app notices, saved events, and pricing
    display don't depend on it and are fully functional.
- **Reschedule events (seller → buyer).** First-class postpone/move
  action, distinct from a silent EditEvent field change: updates the
  event timing, logs old→new (`exos_event_reschedules`, staff + holder
  RLS), and emails every non-voided holder the new date (server-rendered
  in the event tz; new `event-rescheduled` mail template). Via the
  `exos_reschedule_event()` SECDEF RPC (owner/manager; mig
  `20260703124000`). `ReschedulePanel` on OrganizerEventReport
  (tz-aware inputs + history); `RescheduleNotice` on TicketDetail shows
  holders "was X → now Y". Tickets stay valid.
- **Scheduled / dynamic tier pricing (seller).** `price_schedule` jsonb
  on `exos_ticket_tiers` (mig `20260703122000`) — ordered
  `{startsAt, price}` time steps; effective price computed at read time
  (`lib/pricing.ts`), exposed through the security-invoker
  `exos_public_tiers` view (+ anon column grant). `TierPricingPanel`
  editor on OrganizerEventReport (owner/manager); EventDetails shows the
  live effective price + a "price rises to $X on <date>" urgency nudge.
  Own primary inventory — not a RULE-2 upstream reprice. Flesh-out:
  editor is event-timezone-aware (zonedWallClockToUtc); storefront
  strikes the opening price when a step marks it down; Home cards show
  the effective "from" price. **Follow-up:** sold-%-based steps +
  server-side charge enforcement (with exos-checkout).
- **Buyer saved events (wishlist).** `exos_event_saves` table (private
  per-user, RLS `user_id = auth.uid()`, no counter → plain RLS-gated
  writes). Heart toggle on EventDetails + Home discovery cards
  (`SaveEventButton`), a "Saved Events" section in My Tickets that
  un-hearts in place. Migration `20260703120000` (D4 authors; A1 applies).
- **Organizer → attendee announcements (two-sided).** Owner/manager
  broadcast a free-text update to non-voided ticket holders; buyers get
  it as an email (via the existing `exos_mail` queue, new
  `event-announcement` template) AND an in-app thread on their ticket
  ("Updates from the organizer"). Persisted in `exos_event_announcements`
  (staff + holder RLS read), sent via `exos_send_event_announcement()`
  SECDEF RPC (recipients server-derived, body tag-escaped — no open
  relay). Composer on OrganizerEventReport (`AnnouncementsPanel`);
  read-only thread on TicketDetail (`OrganizerUpdates`). Migration
  `20260703121000`. Flesh-out: owner/manager can **retract** an
  announcement (staff DELETE RLS, mig `20260703123000`) — pulls it from
  holders' in-app threads (sent emails aren't recalled).
- Live deployment to Firebase Hosting at
  `gen-lang-client-0961373515.web.app`.
- Tsconfig truncation fix (commit 6532147).
- Mail wire field rename `template → templateName` (Commit 1) —
  fixes Trigger Email extension misinterpreting our string field
  as template-mode rendering.
- Voided/refunded ticket status (Commit 2) — sticky transition,
  audit fields, scanner reject in online + offline paths,
  REFUNDED stamp on TicketDetail, Refund/Void button on
  OrganizerEventReport's Attendees list.
- Pending-transfer lock (Commit 3) — `pendingTransferId` field
  prevents sender double-spend during in-flight transfers, also
  closes the two-tabs race for concurrent transfers.
- ScanReport field rename (Commit 4) — onSnapshot now reads
  `organizerId`/`source`/`scannedAt` instead of stale
  `scanner`/`station`/`at` field names. Fixes silent "unknown"
  display for every scan.
- Stress simulation suite (`stress-sim.ts` + `scripts/stress-test.cjs`).
- Multi-tenant orgs (Phase 1) with RBAC roles
  (owner/manager/finance/scanner/content) + composite-id
  membership lookups.
- White-label theming per org (Phase 2).
- Embed widget (`/embed/event/:id`, chromeless iframe-friendly).
- Organizer onboarding flow.
- Email-based member invites with token-doc claim flow.
- Refund flow (organizer-initiated event-level cancellation +
  buyer notification).
- Real-time sales chart on organizer dashboard.
- SEO meta tags + sitemap + robots.txt + per-event Schema.org
  Event JSON-LD.
- Per-event analytics page with sales chart, tier breakdown,
  promoter and channel attribution.
- Promo codes with expiry + sub-collection counter +
  rule-enforced monotonic increment.
- Promoter / affiliate tracking (`?promoter=<id>` URL → stamped
  on ticket → rolled up in event report).
- Slug-based vanity URLs (`/e/:slug` resolver).
- Hardened Firestore security rules: organizer/admin gates,
  isEventStaff helper, append-only checkIns audit log,
  per-tier sold counters in `events/{id}/tierSales`,
  promoUses sub-collection counter.
- HMAC-signed rotating barcodes (Web Crypto API, 30-second
  buckets, per-ticket secret rotated on transfer claim).
- Offline organizer check-in with localStorage registry +
  pending-updates queue + camera scanner with flashlight.
- Per-event currency picker, structured address inputs,
  per-tier sale windows + visibility + ticketType.
- Production-hardened Express server: rate limiter, security
  headers, structured access log, /healthz, graceful shutdown.
- Code-split routes + chunked vendor bundles (firebase, stripe,
  motion, qr-code).
- ErrorBoundary at app root + Toast system replacing alert().
- Three-platform competitive simulation (Exos vs DICE.fm
  vs Eventbrite end-to-end roleplay).
- 250-cap event-day end-to-end stress simulation + Automatiq
  10-channel oversell race simulation (all invariants held).
- Social sharing (SMS, Instagram Story file share via
  `navigator.share` native sheet on mobile).
- Date/time picker UX fix on CreateEvent (showPicker on click).
- Repository hygiene — `.gitignore` patterns for service-account
  JSONs, README docs for HTTPS barcode requirement and admin
  grant flow, buyer-profile private-only policy.
