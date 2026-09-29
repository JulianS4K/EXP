# Automatiq as the distribution route (design, 2026-09-29)

Status: **design only.** No Automatiq API docs are in this repo or in
Terminal-2 (Terminal-2 only sees Automatiq indirectly, through the S4K CRM's
failed-order alerts). The scaffold in `exos-distribute` (pass 2,
`pushAutomatiq`) stays inert until `AUTOMATIQ_API_KEY` is set, and even then
its listing call is a TODO. Hard Rule #2 still applies: any Automatiq write
needs a recorded operator `WriteAuthorization`, and the writer is dry-run by
default like the StubHub, SeatGeek, Gametime, GoTickets, Vivid and TEvo ones.

## Why

Today Exos plans listings **directly** on six marketplaces
(`docs/marketplace/README.md`): one adapter, one set of credentials, one sale
feed and one fulfilment flow each. Automatiq is a broker point of sale that
already lists on those marketplaces (and more) from one inventory record. If
S4K routes Exos inventory through Automatiq, Exos maintains **one** outbound
integration instead of six, and the broker team sees Exos inventory in the
tool they already use.

## The model: a route per event, never both

Each event distributes one way:

| Route | Who lists on the marketplaces | Exos writes to | Sales come back from |
|---|---|---|---|
| `direct` (today) | Exos, per marketplace adapter | each marketplace | each marketplace's sale feed (webhooks / polling) |
| `automatiq` | Automatiq | Automatiq only | Automatiq's order feed (preferred), else the marketplaces' feeds read-only |

- A new column `exos_events.distribution_route text not null default 'direct'
  check (distribution_route in ('direct','automatiq'))` (migration name
  `…_exos_distribution_route.sql`).
- **Double-listing guard.** When an event is on `automatiq`, the direct passes
  in `exos-distribute` (1b/1c) skip it and plan a delist for anything already
  listed directly. When it's on `direct`, pass 2 skips it. The same
  allocation must never be live on both routes, or one seat sells twice
  (`automatiq-race.ts` simulates exactly that).
- **Switching routes** is a two-step state change: delist everywhere on the
  old route and wait until every listing is confirmed gone, then list on the
  new one. There's no "both for a moment".

## What Exos sends Automatiq

The Exos listing standard (`planExosListings`, `_shared/marketplace/exosListing.ts`)
is already shaped like a broker POS inventory record, so the Automatiq
adapter should only rename fields, like the other six:

| Exos listing | Automatiq inventory (to confirm against their API) |
|---|---|
| stable `ex…` listing id | external / internal reference |
| event as text (name, venue, venue-local date and time) + linked marketplace ids | event mapping |
| row `GA`, contiguous internal seat numbers | section / row / seats |
| quantity ≤ max per order, split policy | quantity, split rule |
| net-equal price (`fees.ts`) | list price, grossed up for Automatiq's own fee once measured |
| mobile transfer, else electronic transfer; in hand on the event day | delivery type, in-hand date |
| delivery = one Exos claim link per ticket | transfer URLs uploaded at fulfilment |

Allocations (`exos_channel_allocations`) still reserve the seats first, so an
Automatiq sale can never take a seat Exos already sold.

## Sales and fulfilment

1. Automatiq reports a sale → `normalizeSale` → one `MarketplaceSale` → the
   same `exos_marketplace_orders` row the direct route writes (`channel` = the
   marketplace, `via` = `automatiq`).
2. Exos issues the tickets and claim links exactly as today.
3. Fulfilment = hand Automatiq the claim URLs (planned, stored in
   `delivery_plan`, sent only when authorized).
4. The payout ledger (`20260929070000`) records the marketplace's fee and
   Automatiq's fee separately, so the organizer still nets the same price.

## What we need from the operator before building it

1. Automatiq API access and documentation (inventory create / update /
   delete, order feed, fulfilment upload), saved into `docs/marketplace/automatiq/`
   with each endpoint tagged read or write, like the other vendors.
2. An API key set as the Supabase secret `AUTOMATIQ_API_KEY` (never in the repo).
3. Which marketplaces Automatiq lists on for S4K, and Automatiq's fee (for
   net-equal pricing).
4. A written `WriteAuthorization` before anything leaves dry-run.

## Build order once the docs arrive

1. `docs/marketplace/automatiq/` endpoint map (read / write tags).
2. Read client + `normalizeSale` + tests (safe: read-only).
3. `planAutomatiqListings` (rename of the Exos standard) + dry-run writer.
4. `distribution_route` migration + the double-listing guard in `exos-distribute`, with a SQL harness.
5. Organizer UI: route picker on the distribution screen, showing what each route lists where.
