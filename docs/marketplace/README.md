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
   - A clear winner is linked.
   - A close call goes to staff as `review`; the event editor shows the
     candidates with "This is it" and "None of these".
   - Two Exos events can't claim the same StubHub event.
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
   - Oversold orders, a missing buyer email or a missing ticket type go to a
     human.
5. **Issued to the buyer as a transfer, and as links on StubHub.** Each
   ticket gets a pending Exos transfer to the buyer's email:
   - it shows under their tickets when they sign in with that email;
   - Exos emails them (`transfer-initiated`) with one claim link per ticket,
     `<EXOS_APP_BASE_URL>/claim/<transfer>`;
   - StubHub gets the same links through a planned `PATCH /sales/{id}`.

   Claiming rotates the barcode secret, so nothing scans before the buyer
   claims it.

Everything that would change something on StubHub is stored as a plan
(`planned_request`, `delivery_plan`) and never sent. The buyer's Exos email
is not a StubHub write, so it goes out as soon as `exos-marketplace-sales`
runs.

Going live needs:
- the migrations applied (`20260926190000`, `191000`, `192000`);
- `exos-distribute` and `exos-marketplace-sales` deployed with crons
  (`exos-marketplace-sales` with `--no-verify-jwt`);
- the secrets set: `EXOS_APP_BASE_URL`, `STUBHUB_*`, and
  `STUBHUB_WEBHOOK_AUTHORIZATION`;
- StubHub seller API access;
- an operator `WriteAuthorization` for the specific endpoints;
- a live branch that sends the planned request.

All of these are operator-gated.

Not built yet:
- **Listings themselves:** creating and repricing them, reserving their
  seats, and syncing quantity after a sale. `exos_distribution_listings.tier_id`
  and `requested_qty` are ready for it. The listing table allows one StubHub
  row per event, so one ticket type per event on StubHub for now.
- **Other marketplaces** (SeatGeek next).
