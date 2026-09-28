# Competition: Exos vs the NYC field

Where Exos stands against the platforms NYC promoters, venues and comedy rooms actually use, and
what to build to win. `docs/strategy.md` has the phase plan and `docs/gtm-nyc.md` the sales motion;
this doc is the evidence behind both. Snapshot: 2026-09-26; Exos column re-checked against the code
2026-09-28.

**Sourcing.** Competitor facts come from search-result snippets (vendor pages, press, review
sites, and comparison pages written by rival vendors). Treat each figure as "reported". Check the
vendor's own pricing page before quoting a number publicly. Exos facts come from the code, not
`KANBAN.md`.

## The field in one line each

| Platform | Who they win | Buyer / organizer fee | Threat to Exos |
|---|---|---|---|
| **Posh** (NYC) | NYC nightlife, recurring parties | 10% + $0.99, usually on the buyer; +5% for instant payout | **Highest.** $37M Series B (Mar 2026), Kickback affiliates, free SMS, tables, tap-to-pay door |
| **DICE** (Fever) | Music clubs and indie rooms (Elsewhere, Knockdown, Public Records, Saint Vitus) | ~13% self-serve, negotiated for venues | High. Fever's audience; app-only, face-value waitlist |
| **Eventbrite** (Bending Spoons) | Long tail, community | 3.7% + $1.79 + 2.9% | Medium, falling. Taken private Mar 2026, layoffs, support behind a paid plan |
| **Shotgun** | Electronic / nightlife (House of Yes) | Buyer fee, capped; organizer rate unpublished | Medium. Auto-charge waitlist, resale, ambassadors |
| **Partiful** | House parties, small social events | Unpublished (~10% + $2 seen) | Medium for small events. Paid ticketing since Jun 2026, 500K MAU |
| **RA** | Underground electronic | ~10% | Genre-narrow; FIFO face-value resale |
| **Tixr** | Big clubs, festivals | Custom | Low at our size. Dynamic pricing, tables |
| **Ticket Tailor** | Cost-sensitive organizers | $0.30–$0.85 per ticket, no buyer fee | Price anchor, no audience |
| **Humanitix** | Community, charity | 5% + $1.29 | Low in nightlife |
| **Punchup** | Comedians (West Side Comedy Club, FUNY) | $1.75 + 2.5%, card fee shown apart | Medium in comedy |
| **Seat Engine** | Comedy clubs outside NYC | Unpublished | Low in NYC |
| **Tablelist / Discotech / SevenRooms** | Tables, bottles, guest lists | 10% hidden fee (Tablelist, sued); venue commission (Discotech); SaaS (SevenRooms) | Own the table layer Exos lacks |
| **KYD** (NYC) | Le Poisson Rouge, Brooklyn Monarch | "0% merchant fees", same-day payout | Small, crypto-framed |
| **Luma** | Community and tech events | 5%, or $59/mo for 0% | Low in nightlife |
| **Opendate** | Venue booking and settlement | SaaS | Owns venue settlement; Tixel resale since Jun 2026 |
| **TicketWeb / AXS / Eventim / Etix** | Venues under contract | 15–30%+ over face | Enterprise; Ticketmaster antitrust remedies may free NYC rooms late 2026 |
| **TickPick Organizer** | New, no-buyer-fee primary | ~5% + processing | Watch |

**Legal backdrop.** NY Arts & Cultural Affairs Law § 25.07 and the FTC fee rule (in force
2025-05-12) require the all-in price up front. Posh settled a fee-disclosure class action ($1.2M,
2026) and a TCPA text-spam one ($900K, 2025); Tablelist is being sued over a hidden 10% fee.

## Feature comparison

`Y` shipped · `P` partial · `N` no · `?` unknown. Exos column is code-verified; the notes say what
"partial" means.

| Feature | Exos | Posh | DICE | Eventbrite | Shotgun | Partiful | Ticket Tailor | Punchup |
|---|---|---|---|---|---|---|---|---|
| All-in price, no buyer fee | **Y** | P | Y | P | P | Y | Y | N |
| Paid checkout live | **N** (built, not deployed) | Y | Y | Y | Y | Y | Y | Y |
| Checkout without an account | Y (paid tickets, email only; free claims still need sign-in) | ? | N (app account) | Y | ? | ? | Y | ? |
| Tiers, hidden tiers, access codes | Y | Y | Y | Y | Y | P | Y | ? |
| Scheduled price steps | Y (time-based) | Y | Y | Y | Y | ? | Y | ? |
| Discount codes | Y (vouchers: % off, $ off or a pinned price, redeemed at checkout) | Y | Y | Y | Y | Y | Y | ? |
| Recurring / timed entry | P (clones events; no slot picker) | P | ? | Y | ? | N | Y | Y |
| Reserved / table seating | P (table packages; no seat map) | P (tables) | ? | Y | ? | N | Y | ? |
| Tables, bottles, minimums | Y (table packages: deposit, party size, minimum spend; bottles as add-ons) | Y | N | N | ? | P | P | ? |
| Guest list / comps | Y (bulk comps, promoter-fed guest lists, guest-list door mode, works offline) | Y | ? | ? | ? | P | P | ? |
| Waitlist with auto-offer | **Y** (holds the seat) | ? | Y | Y | Y (auto-charge) | P | Y | ? |
| Transfers | Y (free) | ? | Y | P | Y | N | ? | ? |
| Face-value resale | **N** | ? | Y | via Tixel | Y | N | via Tixel | ? |
| Rotating signed barcodes | **Y** | ? | Y (app-only) | N | P | ? | N | ? |
| Offline door scanning | **Y** | ? (scan failures in reviews) | ? | Y | ? | ? | Y | ? |
| Box office / tap-to-pay door sales | **N** | Y | ? | Y | Y | N | Y | Y |
| Promoter links + leaderboard | Y | Y | ? | P | Y | N | P | ? |
| Promoter commissions / payouts | Y (per-promoter terms, accrual, reversal on refund, payout ledger; money is paid outside Exos) | Y (Kickback) | ? | N | Y | N | N | ? |
| Fan referral rewards | Y (organizer rule: free ticket after N referred sales; leaderboard) | Y | ? | N | Y | N | N | N |
| Email: follows, announcements, reminders | Y (needs Resend key) | Y | P | Y | Y | Y | P | Y |
| SMS campaigns | **N** | Y (free) | ? | N | ? | Y | N | Y |
| Abandoned-checkout recovery | P (one reminder email, server-side; live once payments and mail are) | ? | ? | ? | ? | ? | ? | ? |
| Discovery (feed, map, saves) | Y (web, no audience yet) | Y | Y (Fever reach) | Y | Y (8M users) | Y | N | Y |
| Instagram in-app checkout | Y (untested on devices) | ? | N (app) | ? | ? | ? | ? | P |
| Apple / Google Wallet | **N** (web pass only) | ? | N | ? | ? | Y (Apple) | ? | ? |
| Pixels + consent | Y (no server-side CAPI) | Y | P | Y | ? | ? | Y | ? |
| API / webhooks | P (read-only API) | P | P | Y | P | N | Y | ? |
| Embed widget | P (opens Exos in a tab) | P | Y | Y | ? | N | Y | ? |
| Spanish | P (buyer side only) | ? | Y | Y | Y | N | Y | ? |
| Organizer-initiated money refund | Y (full, per-ticket, partial or refund-everyone from the event report) | Y | Y | Y | Y | ? | Y | ? |
| Fee-compliance record (shown vs charged, export) | **Y** | ? | ? | ? | ? | ? | ? | ? |
| Settlement / door-deal splits | **N** | N | P | N | N | N | N | P |
| Push to StubHub / SeatGeek | N (scaffold, kept undeployed) | N | N (refuses) | P (Tixel) | ? | N | P (Tixel) | ? |

## Where Exos already wins

- **All-in pricing by design.** It's in the DB and checked in both price engines. Posh, Tablelist
  and Punchup have fee-display exposure in NY.
- **Rotating, signed barcodes that work in the browser.** DICE gets the same fraud protection only
  by forcing an app install.
- **Offline door check-in.** It keeps scanning with no signal. Posh reviews cite scan failures.
- **Inventory that can't oversell.** Quotas, holds, vouchers and a waitlist that holds the seat
  for the next buyer. This is pretty much pretix-grade.
- **Web-first checkout built for Instagram's in-app browser.** No app install; DICE requires one.

## Where Exos is behind (the gaps that lose deals)

1. **Paid checkout isn't live.** Every competitor takes money today. Nothing below matters to a
   paying promoter until `docs/payments-go-live.md` is done. Commissions, refunds, tables, guest
   checkout and vouchers are all built and wait on it.
2. **Door sales.** Posh and Shotgun take tap-to-pay at the door. Exos can only comp.
3. **SMS.** Posh gives it away free. Exos has email only.
4. **Face-value resale.** DICE, RA and Shotgun have it, and Eventbrite, Ticket Tailor and Opendate
   get it through Tixel. Exos has free transfers only.
5. **Wallet passes.** Organizers and buyers expect Apple and Google Wallet.
6. **Seat maps.** Tables are sold as packages; there is no reserved-seat or section map yet.

## Openings nobody has closed

- **Fee compliance you can prove.** A per-order record of the exact all-in price shown and
  charged, exportable for a lawyer. Nobody sells this, and NY enforcement is active. Exos has it
  built (mig `20260926070000`, `PriceDisclosureExport` on the event report); it starts filling
  when payments go live.
- **Fast payouts without the 5% tax.** Posh charges 5% for instant payout, and DICE holds 5% for 6
  months. Stripe Connect Express already pays out on a rolling basis, so fast payouts are ours to
  lose.
- **One tool for GA, tables and cabaret seating.** Comedy rooms need front-table pricing and clubs
  need tables. No indie tool does both alongside Kickback-style promoters.
- **Wallet passes that keep the rotating code.** Fraud protection without an app. DICE can't offer
  this because it's app-only.
- **Human support on event nights.** Every major player gets "no human support" reviews. This is
  an ops commitment, not code (see `docs/gtm-nyc.md` readiness).
- **Promoter settlement.** Door-deal and split math for independent promoters. Opendate does it
  only for venues.

## What to build, in order

Each item states the competitor it neutralises. Items marked **Built** are in the code and go live
with paid events.

| # | Build | Beats | Size | Notes |
|---|---|---|---|---|
| 1 | **Payments go-live** | everyone | ops | `docs/payments-go-live.md`; operator-gated deploys. Blocks every paid feature |
| 2 | **Promoter commissions** | Posh Kickback, Shotgun | M | **Built** (mig `20260926020000`; `PromoterCommissionPanel`, promoter-portal earnings). Per-promoter rate, accrual on sale, reversal on refund, payout ledger |
| 3 | **Fan referral rewards** | Posh, Shotgun | S | **Built** (mig `20260926030000`; `ReferralRewardsPanel`, `ReferralProgress`). Reward rule and leaderboard on top of `exos_fan_referrals` |
| 4 | **Organizer refund button** | Posh, Eventbrite | S | **Built** (mig `20260926040000`, `exos-refund`; `RefundPanel` on the event report). Full, per-ticket, partial and refund-everyone |
| 5 | **Tables and guest lists** | Posh, Tablelist, Discotech | L | **Built** (mig `20260926050000`; `TableTierFields`, `TableAssignmentsPanel`, `GuestListDoor`). Table packages with deposit, party size and minimum spend; guest-list door mode, offline |
| 6 | **Wallet passes with the rotating code** | DICE, Posh | M | Apple `.pkpass` + Google Wallet; needs signing certs (operator). hi.events `Services/Domain/Wallet/` as reference |
| 7 | **SMS opt-in and blasts** | Posh | M | Twilio + 10DLC registration; strict opt-out handling (Posh's $900K TCPA settlement is the warning) |
| 8 | **Abandoned-checkout reminder** | — | S | **Built** (mig `20260926060000`). From expired `exos_checkout_sessions`, one email, opt-out respected |
| 9 | **Fee-compliance record** | Posh, Tablelist, Punchup | S | **Built** (mig `20260926070000`; `PriceDisclosureExport`). Displayed and charged all-in price per order, plus an export |
| 10 | **Face-value resale** | DICE, RA, Tixel partners | L | Phase 2 in `docs/strategy.md`; reuse transfers + `exos_seats_available`. Check NY Art. 25 first |
| 11 | **Door sales (tap-to-pay)** | Posh, Shotgun | L | Phase 3; Stripe Terminal / Tap to Pay through `exos_mint_tickets` |
| 12 | **Cabaret / section seating** | Seat Engine, Punchup | L | Priced sections and front tables before a full seat-map builder |

Recommended next build: **item 1, payments go-live**, then **item 6, wallet passes**. Items 2 to 5,
8 and 9 are built (and guest checkout and working discount codes shipped alongside them), so what
stands between Exos and a paying NYC promoter is turning payments on. After that, wallet passes
keep the rotating code without an app, which DICE can't match.
