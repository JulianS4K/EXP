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

## How the marketplaces tie into Exos

One layer, `supabase/functions/_shared/marketplace/`, shared by the edge
functions (Deno) and the app (`src/lib/marketplace`). Each marketplace is a
`MarketplaceChannel` adapter (`channel.ts`) with its capabilities:

| Channel | Find its event (read) | Create an event | List directly | Deliver by claim link | Where its sales come from |
|---|---|---|---|---|---|
| StubHub | catalog search (client credentials) | yes, `PUT /sellerevents` | yes | yes, `PATCH /sales/{id}` | `/sales/recentupdates` + Sales webhook (seller token) |
| SeatGeek | Platform API `/events` (`SEATGEEK_CLIENT_ID`), or Terminal-2's TEvo→SeatGeek map | no | no (via Automatiq) | no API we have docs for: by hand | Terminal-2's `seatgeek_orders` (already pulled) |

The flow, end to end:

1. **Event created in Exos.** An organizer publishes with networks ticked
   (`exos_events.distribution_networks`).
2. **Linked** (`exos-distribute` pass 0, `exos_channel_event_links`). Each
   ticked marketplace is searched read-only. The scorer (`match.ts`) needs the
   same venue-local day, then weighs start time, name, venue and city.
   - A clear winner is linked.
   - A close call goes to staff as `review`; the event editor shows the
     candidates with "This is it" and "None of these".
   - Two Exos events can't claim the same marketplace event.
   - SeatGeek, TEvo and Automatiq ids mirror into `bridge_event_xref`, which
     Terminal-2 reads.
3. **Created where needed** (pass 1). For StubHub:
   - linked: nothing to create;
   - `review`: waits on staff;
   - otherwise: the `PUT /sellerevents` request is planned (dry-run).
4. **Sold** (`exos-marketplace-sales`). A sale counts only if it sold from
   an Exos listing, matched by listing id, because the seller accounts also
   carry broker inventory. `exos_fulfil_marketplace_order` then:
   - mints the tickets with a claim-by-email transfer to the buyer;
   - claims the seat like every other mint, so Exos's own storefront and
     the other channels can't sell it again;
   - flags oversold orders, a missing buyer email or a missing ticket type
     for a human.
5. **Delivered.** One claim link per ticket
   (`<EXOS_APP_BASE_URL>/claim/<transfer>`). StubHub gets them through a
   planned `PATCH /sales/{id}`; SeatGeek's go by hand. Claiming rotates the
   barcode secret, so nothing scans before the buyer claims it.

Everything that would change something on a marketplace is stored as a
plan (`planned_request`, `delivery_plan`) and never sent. Going live needs,
per channel:
- the migrations applied (`20260926190000`, `191000`, `192000`);
- the two functions deployed with crons (`exos-marketplace-sales` with
  `--no-verify-jwt`);
- the secrets set;
- an operator `WriteAuthorization` for the specific endpoints;
- a live branch that sends the planned request.

All of these are operator-gated.

Not built yet:
- **Listings themselves:** creating and repricing them, reserving their
  seats, and syncing quantity across channels after a sale.
  `exos_distribution_listings.tier_id` and `requested_qty` are ready for it.
- **SeatGeek fulfilment:** waits on SellerDirect write docs.
