# Marketplace API references

Vendor API docs for the secondary marketplaces Exos distributes into (see
`docs/d4_bridge_charter.md` §2 and `supabase/functions/exos-distribute`).

| Marketplace | Folder | Snapshot |
|---|---|---|
| StubHub | [`stubhub/`](stubhub/README.md) | PDFs 2026-09-14 (API v2.249.0.0, Catalog v1.0.0.75) + OpenAPI specs from viagogo/stubhub-api-docs |
| SeatGeek | [`seatgeek/`](seatgeek/README.md) | Seller Direct API 1.0.0 (OAS3), 2026-09-27; event search via the public Platform API |
| Gametime | [`gametime/`](gametime/README.md) | API v3 (Swagger 2.0), onboarding guide, CSV columns, example CSV, Postman collection, 2026-09-27 |

Each folder has the vendor PDFs as printed (`pdf/`), a plain-text extraction
for grep (`text/`), machine-readable specs where the vendor publishes them
(`openapi/`), and a README with the endpoint map.

**Hard Rule #2 applies** (see `CLAUDE.md`): upstream ticketing APIs are
read-only. Every endpoint is tagged below as **read** or **write**. A write
(listing create/update/delete, sale fulfilment, account or webhook changes)
needs explicit operator authorization before any code calls it, per the
charter's §6.1 carve-out process.

## StubHub, SeatGeek and Gametime side by side

StubHub, SeatGeek and Gametime are wired; the rest come later, as adapters
in the same layer. What each one offers, and what Exos standardized on so
that one Exos model fits all three (mig `20260927050000`,
`_shared/marketplace/exosListing.ts`):

| | StubHub | SeatGeek | Gametime | **Exos standard** |
|---|---|---|---|---|
| Auth | OAuth2 (client credentials; seller refresh token) | seller token (`Authorization`) | API key in `?source=` | kept out of logs and plans on all three |
| Find the event | catalog search | Platform API search | none | linked when found; listings always carry the event as text |
| Create the event | `PUT /sellerevents`, or a requested-event listing | no | no | StubHub only; the others match on name, venue, date |
| Create listings | REST, one per call | REST `PUT /listings/single/{id}`, one per call | **CSV of the whole account on FTP, every < 6 h** | the same planned listings, sent each marketplace's way |
| Our listing id | `external_id` | `seller_listing_id` (≤ 32 chars) | `TicketID` (examples numeric) | `ex<base32 allocation id><n>`, stable across re-plans |
| Cap one order | `display_number_of_tickets` (not documented as a purchase cap) | no (CUSTOM splits must end at the quantity) | `lots` via edit | **listings of at most max per order** |
| Seats | optional | required with a row | optional | internal GA seat numbers per listing; row `GA` |
| Split | Any / AvoidOne / … | ANY / … | ANY / NEVERLEAVEONE / … | any, within the listing |
| Delivery type | ticket / mobile transfer (per event) | `mobile` | `mobile_transfer` | an Exos claim link per ticket |
| Update / delist | PATCH / DELETE by external id | PATCH / bulk-delete | edit quantity / DELETE; drop from the next file | one diff (create / update / delete) against what the marketplace has |
| Sale arrives | webhook + `/sales/recentupdates` | webhook + `GET /orders` | webhook + `GET /purchases` | normalized to one `MarketplaceSale` |
| Sale names the listing | `external_listing_id` | `listing.id` | `listing_reference_id` / `source_id` | `listing_ref` on the order: which block |
| Buyer email | `/sales/{id}/ticketholders` | `/orders/customer` | on the purchase | stored on the order; contact details stripped from the raw copy |
| Statuses | pending / confirmed / delivered / cancelled … | submitted / confirmed / fulfilled / denied / void | unconfirmed / unfulfilled / completed / rejected | pending / confirmed / delivered / cancelled / unknown |
| Deliver | PATCH sale: confirmed + e-ticket URLs | PATCH order: fulfilled + transfer URLs (GA: no confirm first) | confirm (+ seats), then confirm_transfer + URLs | the same plan everywhere: claim links, the tickets' internal seats, the steps in order |

**The Exos listing** (`planExosListings`): for each allocation, blocks of at
most the event's max per order, each a contiguous run of the allocation's
internal seat numbers, row `GA`, the listing price (face value = the ticket
type's price), split any, delivered by claim link, in hand on the event day,
with the event as text (name, venue, venue-local date and time) and a stable
`ex…` listing id. Every marketplace gets exactly these listings; its module
only renames the fields (StubHub `listingPlan.ts`, SeatGeek `listingPlan.ts`,
Gametime `inventory.ts`). Blocks are the one per-order cap that works on all
three, so StubHub moved from one display-capped listing to the same blocks.

**Stored plans** share one shape: `{ channel, listings: [{ listing_id,
seat_from, seat_thru, quantity, request: { endpoint, method, path, body } }],
per_order_cap, unresolved }`, plus `action` / `ops` from the sync. The sync,
the delist plan and the SQL seat claim read only the shared fields.

**A sale** records the listing it came from (`listing_ref`), and each ticket
takes a seat from that listing's block (`exos_claim_internal_seat`), on all
three marketplaces. **Delivery** is the same plan everywhere: the claim links,
the tickets' internal seats, and the marketplace's steps in order.

Details per marketplace: [`stubhub/`](stubhub/README.md),
[`seatgeek/`](seatgeek/README.md), [`gametime/`](gametime/README.md).

## How StubHub ties into Exos

### One sync for every marketplace (mig `20260927030000`)

- **Rows.** Per event and marketplace: one **event row** (`tier_id` NULL: the
  StubHub event request, or which SeatGeek event the listings attach to) and
  one **allocation row per ticket type**. Unique on (event, channel) for event
  rows and (event, channel, tier) for allocations.
- **The grid.** The event editor's Marketplaces section is a table: a row per
  ticket type, a column per ticked marketplace, each cell the seats set
  aside there (`exos_set_channel_allocation`). It can be filled before
  publishing; listings are planned once the event is published. A
  marketplace must be ticked to get seats.
- **Publish.** Queues the event row for each ticked marketplace.
- **Keep in step.** Every `exos-distribute` run re-plans each allocation's
  listings and diffs them against what the marketplace has
  (`listed_snapshot`, NULL while dry-run): create, update, delete
  (`_shared/marketplace/sync.ts`).
- **Pull back: delist, then release.** Unticking a marketplace, turning on
  primary-market-only, unpublishing, cancelling, or setting a cell to 0:
  seats with nothing on the marketplace go back to Exos at once; a live
  listing goes to `delisting` (a delete is planned) and keeps its seats until
  the marketplace has taken it down. While writes are dry-run nothing is
  live, so seats always come back at once.
- **Internal seat numbers.** Every allocated seat has a number, per ticket
  type and never shared between marketplaces, and every marketplace ticket
  records its own (`exos_tickets.internal_seat`). SeatGeek needs them as
  `seat_from`/`seat_thru`; they also let staff tell tickets apart. Buyers
  never see them.

The layer is `supabase/functions/_shared/marketplace/`, and it is shared by
the edge functions (Deno) and the app (`src/lib/marketplace`). Each
marketplace is a `MarketplaceChannel` adapter (`channel.ts`) that declares
its capabilities. The StubHub adapter (`stubhub/channel.ts`) provides:
- catalog search, with client credentials;
- event creation (`PUT /sellerevents`);
- sale mapping;
- delivery by claim link (`PATCH /sales/{id}`).

The flow, end to end:

1. **Event created in Exos.** An organizer publishes with StubHub ticked
   (`exos_events.distribution_networks`).
2. **Linked** (`exos-distribute` pass 0, `exos_channel_event_links`).
   StubHub's catalog is searched read-only. The scorer (`match.ts`) needs the
   same venue-local day, then weighs start time, name, venue and city.
   - A clear winner is linked. It also needs evidence it's the same place:
     overlapping venue names, or the same city when a venue name is missing.
   - A close call goes to staff as `review`; the event editor shows the
     candidates with "This is it" and "None of these". Organizers can only
     pick a candidate the search found; admins can enter any id.
   - Two Exos events can't claim the same StubHub event.
   - Changing the event's name, start or venue drops its automatic links,
     so they're searched again. Staff decisions are kept.
   - An event with no link row yet waits for the search before any creation
     is planned.
3. **Created where needed** (pass 1):
   - linked: nothing to create;
   - `review`: waits on staff;
   - otherwise: the `PUT /sellerevents` request is planned (dry-run).
4. **Sold** (`exos-marketplace-sales`: `/sales/recentupdates` plus the Sales
   webhook).
   - A sale counts only if it sold from an Exos listing, matched by listing
     id, because the seller account also carries broker inventory.
   - `exos_fulfil_marketplace_order` mints the tickets and claims the seat
     like every other mint, so Exos's own storefront can't sell it again.
   - Oversold orders, a missing buyer email, a missing ticket type or a
     table ticket type go to a human. A parked order retries when StubHub
     reports the sale again.
5. **Issued to the buyer as a transfer, and as links on StubHub.** Each
   ticket gets a pending Exos transfer, addressed to the order's buyer email:
   - Exos emails that address (`transfer-initiated`) with one claim link per
     ticket, `<EXOS_APP_BASE_URL>/claim/<transfer>`;
   - StubHub gets the same links through a planned `PATCH /sales/{id}`;
   - it also shows under their tickets if they sign in with that email.

   **Claimed into any Exos account** (mig `20260927010000`). A marketplace
   buyer email is often a relay address the marketplace forwards from, and
   people sign in with whichever account they want. So the email only
   decides where the claim link is sent: any verified Exos account that opens
   the link can claim, and the first claim wins (the row locks; a second
   claim is refused). The same holds for Exos-to-Exos transfers between
   friends and to box-office and comp tickets, whose mails now carry the
   claim links too (`{{app_url}}/claim/<id>`, filled by `exos-mail-drain`
   from `EXOS_APP_URL`; redeploy the drain with it set before applying the
   migration). The claim page reads the transfer through
   `exos_transfer_claim_preview`, which returns display fields only, with no
   emails.

   **Sender paper trail.** For an Exos-to-Exos transfer the database mails
   the sender twice: a `transfer-sent` receipt (recipient email, the name
   they typed, the claim link, "cancel until claimed") and, on claim, a
   `transfer-claimed` receipt naming who accepted it (Exos display name and
   email) and when. Comps, box office and marketplace sales don't mail the
   organizer per ticket.

   Claiming rotates the barcode secret, so nothing scans before the buyer
   claims it.

### No double buys: StubHub gets its own seats

The seats on a StubHub listing are the same seats Exos sells, and StubHub's
sale reaches Exos minutes later (webhook or poll). So "sync the quantity after
each sale" can only narrow the window where both sides sell the last seat.
Exos closes it instead with disjoint pools (mig `20260926193000`):

- **Allocate.** The event editor's Marketplaces grid, or
  `exos_set_channel_allocation`, sets N seats of a ticket type aside for
  StubHub (`exos_distribution_listings.requested_qty`). Exos's availability
  (`exos_tier_available`, `exos_quota_available`) leaves them out. Every Exos
  path that sells or reserves a seat reads that availability: checkout
  holds, free claims, comps, box office, waitlist offers.
- **It only takes free seats.** It runs under the same locks as a cart hold
  and writes the tier row, so a concurrent Exos checkout re-checks and can't
  take a seat that was just allocated.
- **A StubHub sale uses its own seats.** It takes them out of the allocation
  in the same transaction that mints them, so it never competes with Exos
  buyers. StubHub selling more than was allocated goes to a human.
- **Give seats back.** Lowering the allocation releases the seats to Exos
  straight away; taking a live listing down releases them once it's down
  (delist, then release).
- **Keep the StubHub listing quantity equal to the allocation.** StubHub
  stops at its quantity, and Exos stops at capacity minus the allocation.

Two limits are enforced, not papered over:
- Allocation is refused when the event's overall cap is lower than its
  ticket types add up to, because a tier-level reservation can't protect a
  tighter house cap.
- Table ticket types aren't sold on StubHub.

`tests/exos/test_channel_allocations.sql` covers the rules.
`tests/exos/race_channel_allocations.sh` races two real sessions for the last
seat in three orders, and never sells it twice.

### One order can't take the whole allocation; over-limit accounts are flagged

- **Per order: capped by listing size, everywhere.** Each allocation becomes
  listings of at most the event's max per order (the Exos standard above),
  planned by `exos-distribute` into
  `exos_distribution_listings.planned_listing` (dry-run). One order takes at
  most one listing, so no marketplace order can take more than an Exos buyer
  could. (StubHub used to get one listing with `display_number_of_tickets`,
  which its docs don't describe as a purchase cap.)
- **Per person: the account is flagged, the sale is not.** No marketplace
  can enforce Exos's max per account: one person can place several orders
  there. So nothing is blocked. Instead, once an Exos **account** actually
  holds more of an event's tickets than `maxPerAccount`, it's flagged
  (`exos_account_limit_flags`, mig `20260926194000`).
  - A sale, or tickets still on their way by transfer, never raises a flag.
  - Tickets parked on the organizer for delivery don't count, and the org's
    own staff are exempt.
  - Each flag records the promoter codes the tickets were sold through.
  - **Org tab:** owners and managers review flags under Org settings →
    **Limit flags** (`/orgs/:orgId/flags`, also linked from the dashboard)
    and mark them reviewed with a note.
  - **Promoter tab:** the promoter portal has a **Limit flags** tab listing
    flagged accounts that bought through that promoter's links. The email is
    masked, and the promoter can leave a note for the organizer.
  - A reviewed flag re-opens if the account later holds more than ever.

### Dry run

**End to end:** `bash scripts/e2e-dry-run.sh` builds a throwaway Postgres
from every migration. It takes one event from creation to the door, through
Exos's own checkout, StubHub and SeatGeek, using the real database functions
and the real TypeScript planners. What it covers:
1. Create a draft, fill the Marketplaces grid (GA on StubHub, VIP on
   SeatGeek), then publish.
2. Plan the StubHub event and listing, and the SeatGeek listings with their
   internal seat numbers.
3. An Exos paid checkout through a promoter.
4. StubHub sales and their buyer transfers.
5. Claims, including a buyer whose StubHub email is a relay claiming into
   an account with a different email, and a second claim on the same link.
6. Account flags, with the promoter note and the org review.
7. Exos selling out while StubHub still sells its own seats.
8. StubHub overselling its allocation, and a StubHub cancellation.
   A SeatGeek sale on its second listing (tickets get that listing's
   internal seats), then pulling back: SeatGeek unticked (released at once)
   and a live StubHub listing set to 0 (delist, then release).
9. The door: valid, used, expired screenshot, wrong event, voided, and
   unclaimed tickets.

Stripe, StubHub, SeatGeek, the clock and email delivery are simulated. Every step
asserts.

**One event only:**
`npx tsx scripts/stubhub-dry-run.ts event.json` puts one `exos_events` row
(as JSON) through the same code as `exos-distribute`, and prints:
- what Exos reads off the event;
- the venue-local search date;
- the `PUT /sellerevents` plan, or what the organizer must fix;
- what `StubHubWriter` would send (it never sends in dry-run);
- the event-editor status line.

Run on 2026-09-26 against prod's one event, it was refused because the event
has no venue address, so there's no city to send. With an address added, the
plan is `PUT /sellerevents`:
- start `2028-05-16T23:11:00-04:00`, the venue-local time with its offset;
- venue Somewhere, Brooklyn, NY;
- country US.

Everything that would change something on StubHub is stored as a plan
(`planned_request`, `delivery_plan`) and never sent. The buyer's Exos email
is not a StubHub write, so it goes out as soon as `exos-marketplace-sales`
runs.

Going live needs:
- the migrations applied (`20260926190000`, `191000`, `192000`, `193000`, `194000`,
  `20260927010000`, `020000`, `030000`);
- `exos-distribute` and `exos-marketplace-sales` deployed with crons
  (`exos-marketplace-sales` with `--no-verify-jwt`);
- the secrets set: `EXOS_APP_BASE_URL`, `STUBHUB_*`, and
  `STUBHUB_WEBHOOK_AUTHORIZATION`;
- StubHub seller API access;
- an operator `WriteAuthorization` for the specific endpoints;
- a live branch that sends the planned request.

All of these are operator-gated.

Not built yet:
- **Sending listings:** sending the planned create / update / delete ops
  from `planned_listing`, recording `listed_snapshot` and
  `external_listing_id`, and marking a `delisting` row `delisted` once the
  marketplace confirms. The seats are already reserved and every op is
  already planned.
- **Other marketplaces** (Vivid, TickPick, ...).
