# Kanban Board / Product Roadmap

## Prod state vs this repo (updated 2026-09-24, after the operator-approved apply)

- **DB caught up.** Applied to prod 2026-09-24: the 2026-09-11 Stage 2/3 set and
  `20260924200848_exos_audit_hardening_quota_transfer_waitlist` (which also carries the transfer secret leak fix).
  `20260702121000` and `20260911130000` were not applied on their own; later migrations supersede them (see their headers).
- **The `/bridge/` bundle (Terminal-2 `static/bridge/`, built 07-27) still works**, and it's now safe to rebuild it from
  this repo and copy `dist/` over.
- **Payments are dormant by choice.** `stripe-webhook`, `exos-checkout`, `exos-reconcile-checkouts` have never been deployed.
  Before Stripe go-live: set `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` / `CRON_SECRET`, deploy the three functions,
  register the Stripe webhook endpoint. The existing `exos-reconcile-checkouts-15min` cron starts hitting the function once
  it's deployed.

## Roadmap (operator, 2026-09-24)

P0 (paid-ticketing blockers) is done in code; see the audit list below. The operator still has to
apply the migrations and go through `docs/payments-go-live.md`. P1 is in the audit list. Beyond
that:

**7. Social commerce, maps and SEO**
- **Checkout inside Instagram / Facebook in-app browsers.** Hosted event and checkout pages that
  work inside the Meta in-app webview. Plan for:
  - Stripe Checkout redirects inside the webview, with Apple/Google Pay fallback behaviour.
  - Sign-in without popups.
  - `og:` tags for rich link previews.
  - Pixel attribution. Meta's own checkout surfaces are a later, separate integration with its
    own review.
  Blocked on the P1 security-header fix (the embed and pixels are currently blocked).
- **Google Maps** on event and venue pages: a Maps JS / Embed API key restricted by referrer, and
  a static-map fallback.
- **SEO:**
  - Server-rendered or prerendered event pages. The SPA serves one shell today, and Terminal-2
    already has an event-page SSR pattern (`tests/test_event_page_ssr_meta.py` there).
  - `schema.org/Event` JSON-LD, a sitemap, canonical URLs on `/e/:slug` and `/o/:slug`.

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

## Audit 2026-09-24 — open findings

Three parallel reviews (DB / edge functions / frontend). ✅ = fixed in the audit PRs (EXP `claude/exos-audit-fixes`,
Terminal-2 https://github.com/JulianS4K/Terminal-2/pull/1001). Everything else is open. The ✅ DB fixes are live in prod; the ✅ edge-function fixes ship when payments go live.

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
  sweep still ignores `{error}`.
- ✅ H — `account.updated` for organizers comes from a *connected-accounts* endpoint with its own secret; the
  webhook now accepts `STRIPE_CONNECT_WEBHOOK_SECRET` too (otherwise nobody could ever sell).
- M — reconcile sweep: `status='failed' LIMIT 100` with no order/marker can starve; webhook and reconcile use
  different refund idempotency keys.
- M — `exos-webhook-drain` has no row claim (duplicate deliveries on overlap) and doesn't sign the timestamp.
- L — open redirects via client `success_url`/`cancel_url`/`return_url`; add-on oversell (read-then-charge);
  SSRF blocklist gaps (198.18/15, 224/4, 240/4, NAT64, 6to4); no rate limit on `exos-api`; dispute marks
  session `refunded`.
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
- M — `authenticated` reads every column of published events and all orgs (`owner_uid`, `comp_budget`, …).
- M — check-in: event scope only when `p_event_id` is passed; HMAC skipped for non-camera; client-chosen
  `verification` is logged as-is; cancelled events not rejected.
- M — vouchers are consumed before capacity checks and burned when fulfillment fails; not re-validated.
- L — account enumeration via issue-to-email / comp batch; `comp_budget` bypassable; stale invites can
  re-enable/demote members. (✅ `exos_assert_purchase_limit` no longer callable by users.)

**Frontend**
- ✅ H — door scanner admitted on the offline registry after the server said `used`/`voided`/`in-transfer`.
- ✅ M — replayed offline check-ins dropped server refusals silently; now audited + surfaced.
- ✅ H (partial) — scanner registry (every ticket's barcode secret) now wiped on sign-out. Still open: it
  lives in plaintext localStorage for 7 days; pixels still load on `/checkin`.
- ✅ L — removed the `GEMINI_API_KEY` Vite `define` (a future reference would inline the key) and `@google/genai`.
- H (correctness) — production CSP/XFO from Terminal-2 (`frame-ancestors 'none'`, `script-src 'self'`) kills the
  embed, the org pixels, and Google Fonts. Needs per-path headers in Terminal-2 `server.py`.
- M — one org's pixels receive other orgs' events (never unloaded; fire to every loaded pixel).
- M — `server.ts` `/api/*` is unused but `/api/verify-session` is unauthenticated; delete it.
- L — dead Firebase rules/env vars/Stripe.js; unsigned legacy barcode fallback can never scan; SVG logo
  upload rejected by the bucket; embed snippet puts the raw title in an HTML comment.


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
