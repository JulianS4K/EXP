# Marketplace API references

Vendor API docs for the secondary marketplaces Exos distributes into (see
`docs/d4_bridge_charter.md` §2 and `supabase/functions/exos-distribute`).

| Marketplace | Folder | Snapshot |
|---|---|---|
| StubHub | [`stubhub/`](stubhub/README.md) | PDFs 2026-09-14 (API v2.249.0.0, Catalog v1.0.0.75) + OpenAPI specs from viagogo/stubhub-api-docs |

Each folder has the vendor PDFs as printed (`pdf/`), a plain-text extraction
for grep (`text/`), machine-readable specs where the vendor publishes them
(`openapi/`), and a README with the endpoint map.

**Hard Rule #2 applies** (see `CLAUDE.md`): upstream ticketing APIs are
read-only. Every endpoint is tagged below as **read** or **write**. A write
(listing create/update/delete, sale fulfilment, account or webhook changes)
needs explicit operator authorization before any code calls it, per the
charter's §6.1 carve-out process.

## How StubHub ties into Exos

StubHub is the only marketplace wired so far. SeatGeek and the rest come
later, as adapters in the same layer.

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
   ticket gets a pending Exos transfer to the buyer's email:
   - it shows under their tickets when they sign in with that email;
   - Exos emails them (`transfer-initiated`) with one claim link per ticket,
     `<EXOS_APP_BASE_URL>/claim/<transfer>`;
   - StubHub gets the same links through a planned `PATCH /sales/{id}`.

   Claiming rotates the barcode secret, so nothing scans before the buyer
   claims it.

### No double buys: StubHub gets its own seats

The seats on a StubHub listing are the same seats Exos sells, and StubHub's
sale reaches Exos minutes later (webhook or poll). So "sync the quantity after
each sale" can only narrow the window where both sides sell the last seat.
Exos closes it instead with disjoint pools (mig `20260926193000`):

- **Allocate.** The event editor's "Seats for StubHub" control, or
  `exos_set_channel_allocation`, sets N seats of one ticket type aside for
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
- **Give seats back.** Lowering the allocation, or delisting, releases the
  seats to Exos straight away.
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

Everything that would change something on StubHub is stored as a plan
(`planned_request`, `delivery_plan`) and never sent. The buyer's Exos email
is not a StubHub write, so it goes out as soon as `exos-marketplace-sales`
runs.

Going live needs:
- the migrations applied (`20260926190000`, `191000`, `192000`, `193000`);
- `exos-distribute` and `exos-marketplace-sales` deployed with crons
  (`exos-marketplace-sales` with `--no-verify-jwt`);
- the secrets set: `EXOS_APP_BASE_URL`, `STUBHUB_*`, and
  `STUBHUB_WEBHOOK_AUTHORIZATION`;
- StubHub seller API access;
- an operator `WriteAuthorization` for the specific endpoints;
- a live branch that sends the planned request.

All of these are operator-gated.

Not built yet:
- **Listings themselves:** creating and repricing them, and keeping the
  StubHub quantity equal to the allocation. The seats are already reserved.
  The listing table allows one StubHub row per event, so one ticket type per
  event on StubHub for now.
- **Other marketplaces** (SeatGeek next).
