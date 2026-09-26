# Strategy and phased plan

Where Exos is going and the order we build it in. The go-to-market plan for the first market is
`docs/gtm-nyc.md`. Open work items live in `KANBAN.md`, which links back here by phase.

## Where we're headed

**Exos becomes the operating system for venues and events.** Toast is the model on the venue floor
(box office, bar, merch and settlement in one system). Otter is the model for distribution (one
inventory pushed to many sales channels, one place to see every order).

It gets there in two steps:

1. **Win ticketing** for independent promoters and small-to-mid venues. They're badly served by
   Ticketmaster and AXS (built for arenas), and they pay buyer fees on Posh and Eventbrite that
   their audiences resent.
2. **Expand into everything else that happens around a ticket:** the door, the bar, resale, and
   the other places tickets get sold.

## Competitive position

The full, sourced comparison and the build order that follows from it are in `docs/competition.md`.

| Competitor | Who they win | Where Exos wins |
|---|---|---|
| Ticketmaster, AXS | arenas, big rooms, exclusive contracts | no exclusivity, no buyer fees, a venue can set itself up in an afternoon |
| SeatGeek, StubHub | resale and aggregation | official face-value resale that the organizer controls (Phase 2), not a secondary markup |
| DICE | curated music, all-in app, waitlist | open to any organizer, the organizer owns the buyer relationship, the storefront is on the web (no app install) |
| Posh | NYC nightlife, Instagram-native promoters | all-in prices instead of buyer fees, a door app that works offline, anti-screenshot barcodes |
| Eventbrite | long tail and community events | better for paid live events: quotas, waitlist, transfers, door ops |
| hi.events, pretix | self-hosted open source | hosted, payments included, built for nightlife and venues rather than conferences |

**What we already have that's hard to copy:**

- **All-in prices.** They're live in the DB, and New York law and the FTC fee rule both point the same way.
- **Rotating signed barcodes.** Screenshots and forwarded codes stop working.
- **Offline door check-in.** This matters in NYC basements with no signal.
- **Pretix-grade inventory.** Quotas, holds, vouchers and waitlist offers that can't oversell. The P0
  work closed the last holes.

## Guardrails that hold in every phase

- **Upstream marketplaces are read-only** unless the operator authorizes a specific partner's write
  scope (`CLAUDE.md`). Every Phase 4 write integration needs its own sign-off.
- **Neutrality.** Exos shares a database with Terminal-2, a ticket broker's data platform. Venues
  will ask whether their buyer data reaches a broker, so the answer has to be "no" in code, not just
  in policy:
  - Terminal-2's broker lanes never read `exos_*` buyer or order data.
  - Phase 2 pricing intelligence flows from Terminal-2 to Exos only.
  - The DB split (Phase 5, or earlier if a venue asks) makes the wall physical.
- **Money paths get SQL harness coverage before they ship.** Each fix gets a case that fails
  without it, as the P0 work did.
- **Prod applies and function deploys need operator permission for each change.**

## Phases

Each phase has exit criteria. We don't start selling the next phase's story until the current
phase's criteria are met.

### Phase 0 — Go live, safely

**Payments go-live.** Follow `docs/payments-go-live.md`: Stripe keys, the two webhook endpoints,
deploying `exos-checkout`, `stripe-webhook` and `exos-reconcile-checkouts`, and the 11 test cases.

**P1 audit fixes** (listed in `KANBAN.md`):

- **Security headers.** Set per-path CSP/XFO in Terminal-2 `server.py` so the embed, the org pixels
  and Google Fonts work.
- **Pixels.** Pixels are scoped to the org whose page is showing: never fire another org's events,
  and no pixels on `/checkin`.
- **Redirects.** `success_url` / `cancel_url` / `return_url` are checked against an allowlist.
- **Add-on oversell.** Reserve add-ons at hold time rather than read-then-charge.
- **Check-in hardening.** The event scope is always enforced, HMAC is required, cancelled events
  are rejected, and `verification` is set by the server.
- **Webhook drain.** Claim rows before delivery and sign the timestamp.
- **Scanner roster.** Encrypt it at rest or keep it for a shorter time. Plaintext localStorage for
  7 days is too long.
- **Column reads.** Narrow what `authenticated` can read on events and orgs.
- **Dead code.** Delete the unused `server.ts` `/api/*` routes.

**Exit criteria:**

- 10 paid test events end to end in Stripe live mode.
- Refunds, transfers and disputes all reconcile.
- P1 list closed.
- An organizer can go from sign-up to a published paid event in under 15 minutes without help.

### Phase 1 — The NYC indie wedge

Build what an Instagram-first NYC promoter needs to switch from Posh or Eventbrite. See
`docs/gtm-nyc.md` for who and how.

- **Item 7a — Checkout inside Instagram and Facebook.** Detect the in-app browser. No popups
  anywhere in sign-in or checkout. Stripe Checkout with Apple Pay and Google Pay fallbacks. An
  "open in browser" escape hatch. Rich `og:` previews. Pixel attribution.
- **Item 7b — Google Maps** on event and venue pages: an embed with a referrer-restricted key, a
  static fallback, and "get directions".
- **Item 7c — SEO:**
  - Prerendered `/e/:slug` and `/o/:slug`.
  - `schema.org/Event` JSON-LD, sitemap, canonical URLs.
  - City and neighborhood landing pages ("this week in Bushwick").
- **Promoter tools:**
  - Per-promoter tracking links. Attribution already exists in analytics.
  - Promoter payouts or comps by referral count.
  - A promoter leaderboard for the organizer.
- **Buyer CRM:** follower lists per org, "new event from an organizer you follow" email, an
  abandoned-checkout reminder, and an SMS opt-in (later).
- **Wallet passes.** Apple Wallet and Google Wallet with the rotating code. hi.events has a model
  in `Services/Domain/Wallet/`.
- **Organizer self-serve gaps:** a quota editor screen, and a "buyers will see $X" preview in the
  tier editor.

**Exit criteria:**

- 25 active NYC organizers.
- At least 40% of GMV coming through Instagram in-app browsers, with checkout conversion there
  within 10% of desktop.
- Repeat organizers (a 2nd event within 60 days) of 60% or more.

### Phase 2 — Official resale and pricing intelligence

- **Face-value resale exchange.**
  - Built on the existing transfer and waitlist machinery, reusing the `exos_seats_available` gate:
    a listed ticket returns to inventory, and the next buyer or waitlister gets it.
  - The organizer sets the price cap (default: face value) and can take a cut.
  - Check this against New York Arts and Cultural Affairs Law Article 25 before launch.
- **Pricing intelligence for organizers,** from Terminal-2's read-only market data:
  - What comparable NYC shows sold for.
  - Where secondary prices say the organizer under-priced.
  - Suggested tier ladders and scheduled price steps.

  This is read-only and one-way, per the neutrality guardrail.
- **Exit criteria:**
  - Resale takes at least 5% of sold-out events' tickets off StubHub/SeatGeek (measured by
    Terminal-2 market data for those events).
  - No resale disputes unresolved after 7 days.

### Phase 3 — Venue POS (the Toast half)

- **Box office:** Stripe Terminal readers for walk-up sales, going through the same mint path
  (`exos_mint_tickets`, which is already quota-aware).
- **Bar and merch:** item catalog, tabs tied to a wristband or ticket, tips, and 86'ing items.
- **Settlement:** end-of-night report per event (tickets + bar + merch, cash vs card, promoter
  splits, artist deal math such as guarantee vs door split) and payout splits over Stripe Connect.
- **Hardware:** a supported-device list (iPad plus reader), plus offline card capture limits.
- **Exit criteria:**
  - 5 venues running their door and bar on Exos for a full month.
  - Settlement matches their bank deposits to the cent.

### Phase 4 — Channel hub (the Otter half)

- **One inventory, many channels.**
  - Own channels first: storefront, embed, Instagram, box office, promoter links, partner API
    (`exos-api`).
  - Then authorized marketplaces (item 8).
- **Marketplace reads** (item 8, allowed today): show organizers where their event is listed on
  secondary markets and at what price, using Terminal-2's GET-only clients.
- **Marketplace writes** (item 8, operator-gated):
  - One reviewed integration per partner. `exos-distribute` (Automatiq/Lysted) stays undeployed
    until each partner's write scope is signed off.
  - Each integration needs auth, idempotency and reconciliation.
  - A marketplace sale reserves an Exos seat through `exos_seats_available`, like every other sale.
- **Unified order inbox:** every channel's orders, refunds and chargebacks in one list with
  per-channel fees.
- **Exit criteria:**
  - An organizer runs one event across 3 or more channels with zero oversells.
  - Per-channel payouts reconcile.

### Phase 5 — Platform

- **DB split:** Exos gets its own Supabase project. Migrations and functions become authoritative
  here instead of in Terminal-2 (`supabase/README.md`).
- **Public REST API and webhooks** as a product: API keys, rate limits, docs. pretix's
  `src/pretix/api/` is the reference.
- **App marketplace and plugins:** pretix's `src/pretix/plugins/` and `base/signals.py` are the
  reference.
- **Expansion:** reserved seating maps, multi-language (Spanish first for NYC), more payment
  methods, more cities (see the expansion criteria in `docs/gtm-nyc.md`).

## How we build

- One phase at a time, in small PRs, each with tests (vitest for pure logic, SQL harnesses for DB
  logic).
- Borrow designs from hi.events and pretix (see `CLAUDE.md`). Never copy their AGPL code.
- Anything that needs a prod apply or deploy is authored and tested first, then applied with
  operator permission.
