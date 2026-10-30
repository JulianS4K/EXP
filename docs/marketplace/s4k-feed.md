# Exos → S4K inventory feed (built 2026-10-13, not live)

Status: **built, not applied or deployed.** Migration `20261014100000_exos_s4k_feed.sql`
(harness `tests/exos/test_s4k_feed.sql`), edge function `exos-s4k-feed`, shapes in
`_shared/s4kFeed/feed.ts` (tests `src/lib/s4kFeed/feed.test.ts`), and the organizer
switches (Organization settings → S4K network; event → Marketplaces → Who lists it).
It replaces the "Exos pushes to Automatiq" idea in [`automatiq.md`](automatiq.md)
with a pull model, so Exos never writes to a third party (Hard Rule #2 stays intact).

Operator decisions (2026-10-13): the contract is the Ticket Desk's two Paciolan
calls with the names changed; S4K calls the feed, and a signed webhook is the
secondary signal; an order Exos can't fill is **rejected** (nothing taken), and
any marketplace penalty from that is **S4K's** until the system is further along.

## The flow

```
Promoter's event on Exos: one shared GA count per ticket type
   ├─ Exos checkout                         (the count itself)
   ├─ Eventbrite (promoter's account)       two-way sync, eventbrite/README.md
   └─ S4K feed  ──pull──▶ S4K / Automatiq ──▶ StubHub · SeatGeek · Vivid · Gametime · GoTickets · TEvo
                ◀─buy───  (S4K fulfils a marketplace sale by buying from Exos)
```

S4K already mirrors primary box offices this way. Its Ticket Desk exposes
Paciolan / Ticketmaster inventory as a token-gated, read-only API, and S4K's
side polls it and lists through Automatiq. **Exos should look like one more
desk:** the same two calls, the same field names, the same polling rhythm. Then
the S4K consumer picks Exos up with a new base URL and token, not a new
integration.

Open source (Option A) uses the same contract. A self-hosted Exos serves the
feed to whatever lister the promoter runs (their own Automatiq, or another
POS), instead of to S4K.

## The pattern borrowed from the Ticket Desk

| Ticket Desk does | Exos feed does |
|---|---|
| Consumer API under `/api/v1`, `GET` only, `Cache-Control: no-store`, CORS open | `exos-s4k-feed` edge function, `GET` only, same headers |
| `Authorization: Bearer evd_…` (or `X-API-Key`), SHA-256 hash stored, prefix shown, revocable, `last_used_at` touched at most once a minute | Same, as a feed token (`exf_…`) on the existing `exos_api_keys` pattern (`exos-api`), scoped to **one consumer and the orgs that opted in**, not to one org |
| Event key resolves internal id → Event UID → Paciolan id | Resolves the consumer's `internalId` (AQ's id, once paired) → Exos event UUID |
| `ticket_uid` = UUIDv5 of event + section + row + seats, stable across pulls | `ticketId` = UUIDv5 of event + ticket type: one GA line per ticket type, stable forever |
| Two-call contract: `/paciolan/events?updatedSince=` and `/paciolan/events/{id}/tickets` | **The same two calls**, at `/exos/events` and `/exos/events/{id}/tickets` |
| Optional: `/feed/full` then `/feed/changes` with per-token baselines (`feed_seen`), `dry_run`, `/feed/status` | Phase 2, only if S4K wants it. With one line per ticket type, the two calls are already small |
| `/status`: newest pull per platform, so a stale desk isn't mistaken for a quiet market | `/exos/status`: `generatedAt` and per-event `updatedAt`. Exos is the source, so it is never stale, but the consumer's monitor still gets its health check |
| Nothing is sent back. A line that disappears was sold | Not enough for Exos: a marketplace sale has to become an Exos ticket. See "Sales back" |

## Call 1: active events

```
GET /exos/events
GET /exos/events?updatedSince=2026-10-13T00:00:00Z&limit=200&offset=0
```

Returns every event that is published, not cancelled, has doors at or after
now, belongs to an org that opted into the S4K network, and has
`channel_split_mode` set to anything other than primary-only. Each event comes
with S4K's pool count (see "The count").

```json
{
  "generatedAt": "2026-10-13T14:03:11Z",
  "updatedSince": "2026-10-13T00:00:00Z",
  "count": 1, "total": 1, "limit": 200, "offset": 0,
  "events": [{
    "eventId": "6c1e…",                 // Exos event UUID
    "eventUid": "6c1e…",                // same value; kept for desk parity
    "internalId": "AQ-10442",           // null until paired (see Mappings)
    "organizer": "Brooklyn Bowl Presents", "host": "exos",
    "name": "DJ Night", "opponent": null,
    "venue": "Brooklyn Bowl", "city": "Brooklyn", "region": "NY",
    "date": "2026-11-07", "time": "21:00", "timezone": "America/New_York",
    "eventUrl": "https://…/bridge/e/dj-night",
    "availability": { "available": 412, "totalCapacity": 600, "pctAvailable": 68.7,
                      "soldOut": false, "asOf": "2026-10-13T14:03:11Z" },
    "updatedAt": "2026-10-13T13:58:40Z"
  }]
}
```

- `updatedAt` moves whenever anything in call 2 would change (a sale on any
  by S4K, a refund, a price or split change).
  `updatedSince` compares against it, as on the desk.
- `availability.available` is what S4K's pool holds (see "The count"), not
  the raw unsold count.
- An event that drops out (cancelled, unpublished, the org opts out, doors
  passed) comes back once with `"status": "withdrawn"` and `available: 0` on
  the next `updatedSince` call, so the consumer delists it. The desk has no
  equivalent: it simply stops listing expired events.
- `generatedAt` runs 15 seconds behind the clock on purpose: pass it back as
  the next `updatedSince` and a change that committed while you were reading
  still comes back (sometimes twice, never zero times).
- `updatedAt` comes from a per-event content hash (`exos_feed_events`), refreshed
  every minute by the cron and on every call 1 and every order, so a re-check
  that finds nothing new moves nothing (the desk's "only store a changed pull").
- An event is on the feed when its org joined the S4K network
  (`exos_orgs.s4k_network`, owner only), the event's route is `s4k`
  (`exos_events.distribution_route`, owner or manager), it is published, and
  doors (else start) are in the future. An `s4k` event gets no direct
  marketplace allocation, by hand or from the auto split, and an event with
  direct listings can't switch to `s4k` until they are set to 0: one route at
  a time, or a seat could sell twice.

## Call 2: tickets for one event

```
GET /exos/events/{eventId}/tickets
```

One line per GA ticket type that can be sold now: on sale, inside its sales
window, not hidden, not free (free seats stay off resale marketplaces by
default, `channel-sim.md`).

```json
{
  "eventId": "6c1e…", "internalId": "AQ-10442",
  "name": "DJ Night", "date": "2026-11-07",
  "asOf": "2026-10-13T14:03:11Z",
  "count": 1, "seats": 404,
  "tickets": [{
    "ticketId": "1f4b…",                 // UUIDv5(event, tier): stable forever
    "level": "", "section": "GA", "row": "GA",
    "seatFirst": null, "seatLast": null,
    "quantity": 404,                     // broadcast count for this tier
    "maxContiguous": 4,                  // max per order: the most one buyer can take
    "split": "any",                      // listingStandard.ts policy
    "priceLevel": "1f4b…", "priceLevelName": "General Admission",
    "price": 30.00, "fees": 4.20, "allInPrice": 34.20,
    "netToOrganizer": 30.00,
    "inventoryType": "primary",
    "inHandDate": "2026-11-07", "delivery": "mobile_transfer"
  }]
}
```

- `price`, `fees` and `allInPrice` follow the desk's meaning: what a buyer
  pays on Exos per ticket. The marketplace list price is S4K's call. The feed
  also carries `netToOrganizer` so S4K's net-equal pricing (`fees.ts`) has its
  floor.
- `seatFirst` and `seatLast` are null because the tickets are GA. Internal
  seat numbers are assigned at sale time, as today.
- Unknown `eventId`, or an event this token can't see: `404 {"error": …}`.

## The count: two pools (mig `20261014130000`)

Inventory is split into **two pools**, and the organizer picks the split per
ticket type (event editor → Distribution → "Two pools"):

```
pool 1, Exos + Eventbrite = capacity − S4K's split
pool 2, S4K               = S4K's split (its total, sold included)
feed quantity             = what S4K's pool holds now (split − S4K sold)
```

- S4K's pool is an allocation row (`exos_distribution_listings`, channel
  `s4k`). Every Exos sale path and the Eventbrite capacity sync read
  `exos_effective_available`, which leaves allocated seats out, so neither
  can sell S4K's seats, and Exos selling out its pool doesn't touch S4K's.
- No buffer: nothing but S4K sells from its pool, so the count is exact. The
  lag between S4K's marketplaces is S4K's to manage; an order bigger than
  the pool is rejected (`sold_out`), never filled from pool 1.
- The pool holds its whole split at once: none of the direct marketplaces'
  top-up, stagnant-shrink or day-of cutoff rules apply.
- Lowering the split gives S4K's unsold seats back to pool 1 at once.
  Raising it takes only seats free in pool 1 right now (refused with how many
  are). It can't go below what S4K already sold.
- Only for events over the free tier (max capacity over 150) whose organizer
  opted in to resale (migs `20261014140000`, `20261029090000`,
  `docs/marketplace/README.md`): otherwise the route can't be chosen, the
  split refuses, and an S4K event that loses either leaves the feed and its
  pool is released (at once when the opt-in is withdrawn).
- Last call (mig `20261029100000`): near sell-out the event leaves the feed
  and its pool plans to 0, so only the primary checkout sells the rest.
- A released fixed block (mig `20261029160000`) leaves the feed the same way,
  its pool planned to 0.
- A ticket type with no split isn't on the feed. Not splittable: free
  ticket types (resale marketplaces don't sell them), table types, types with
  no capacity, and events whose overall cap is below the types' sum.
- Leaving the S4K route (or the owner leaving the network) releases every
  unsold S4K seat to pool 1; S4K's sold count is kept for when it comes back.
- A pool keeps its seats if its ticket type later leaves the feed (hidden,
  past its sales end): set S4K's seats to what it sold to give them back.
  A refund or void of an S4K ticket done in Exos (not an S4K cancel) gives the
  seat to pool 1, as for marketplaces.
- `exos_s4k_pool_status(event)` shows both pools per ticket type;
  `exos_set_s4k_split(event, [{tier_id, seats}])` sets them (owner /
  manager, all or none).

The earlier design (one shared count minus a 1-pack buffer, from the
broadcast simulation in `channel-sim.md`) is replaced: with disjoint pools
there is no Exos-side race to buffer against.

## Listings for Albert (mig `20261014150000`)

The chain is **Exos → Albert → S4K → Automatiq** (S4K's account). Exos publishes;
Albert reads and pushes on. Exos writes nothing to S4K or Automatiq.

- **Three listings per ticket type** in S4K's pool, in `exos_s4k_listings`, each up to
  the event's listing quantity L (`resale_listing_qty`, default 8, set by the organizer
  in the pools panel). Listing *i* shows `min(L, held − (i−1)·L)`, so a sale refills it
  from S4K's pool on the next sync. `listing_id` (`exos-<tier>-<slot>`) is stable.
- **Rebalance** (on by default, `s4k_rebalance`): when S4K's pool can't fill all three
  (held < 3L), the every-minute feed cron grows S4K's split with seats free in Exos +
  Eventbrite's pool, until one listing set (L seats) is left there.
- **The last set goes to the primary QR source** (`primary_source`):
  - `exos`: on an S4K-route event, Eventbrite's capacity sync keeps at least L back
    (buffer max(one pack, L)), so Exos sells the last set.
  - `eventbrite` (needs an Eventbrite link): on ticket types mapped to Eventbrite, the
    last L free seats are held off Exos checkout and Eventbrite's capacity includes them.
  - `external` (a fixed block for a platform Exos can't sync, mig `20261029160000`):
    the block's codes are Exos's, so the listing rows say `exos`.
- **How Albert reads it:** like Terminal-2's N2S feed. The table syncs by diff (a quiet
  minute writes nothing), has `REPLICA IDENTITY FULL` and is in the `supabase_realtime`
  publication. Albert signs in as a dedicated integration user linked to the S4K
  consumer, reads `GET /rest/v1/exos_s4k_listings`, and subscribes to Realtime
  `postgres_changes` (INSERT / UPDATE / DELETE; a DELETE means take that listing down).
  RLS lets only a live consumer's linked user read it.
- **Orders** still come back through `POST /exos/events/{id}/orders` (the S4K pool, all
  or nothing), so a sale on any of the three listings takes seats from the same pool.

Operator steps to connect Albert: create the consumer (`exos_feed_create_consumer`), create
a dedicated Supabase Auth user with a password for the integration (Auth → Users → Add user,
Auto Confirm; not a staff Google login), then link it as the service role:
`select exos_feed_link_user('S4K', '<integration user email>');`.

## Sales back: S4K buys from Exos

The desk is read-only because S4K fulfils a Paciolan sale by **buying the
seats on the storefront**. Exos copies that, through an API instead of a
browser:

```
POST /exos/events/{eventId}/orders        (feed token; Idempotency-Key = externalRef)
{ "ticketId": "1f4b…", "quantity": 2, "externalRef": "AQ-order-88123",
  "marketplace": "stubhub", "unitPrice": 30.00, "buyerEmail": "optional" }
→ 201 { "orderId": "…", "status": "fulfilled", "replayed": false,
        "tickets": [{ "seat": "GA-0153", "claimUrl": "https://…/bridge/claim/…?k=…", "status": "active" }, …] }
→ 200 the same body with "replayed": true   (same externalRef again)
→ 409 { "error": "not enough left", "reason": "sold_out", "available": 1, "price": 30 }
      reasons: sold_out · price_changed · over_max_per_order · no_delivery_email
→ 404 reason not_on_feed / ticket_not_on_feed

GET  /exos/orders/{orderId}               status + claim links again
POST /exos/orders/{orderId}/cancel        the marketplace cancelled: tickets voided, seats back
                                          (409 once doors opened or a ticket was scanned)
GET  /exos/status                         { generatedAt, activeEvents } for a monitor
```

- This is a write **into Exos**, by S4K, on Exos's own API. Exos still never
  writes to a third party.
- The order runs the same path as `exos_marketplace_orders` today
  (`via = 's4k'`). It takes seats under the checkout locks, issues tickets
  and claim links, and records the marketplace in `channel` for the payout
  ledger. S4K uploads the claim URLs to the marketplace through Automatiq,
  the same way it uploads Paciolan transfers.
- `Idempotency-Key` (or `externalRef`) makes a retried POST return the first
  order, not a second one.
- `unitPrice` is what S4K pays Exos per ticket. Below the ticket's current
  price the order is rejected (`price_changed`), so a stale feed can't sell
  under the organizer's price. Exos's fee comes out of it as on every
  marketplace order (`organizer_net`), which is what `netToOrganizer` shows.
- All or nothing: an order for more than S4K's pool holds takes nothing. The
  order locks the pool row first, so two S4K orders can't both take its last
  seats, and it is never filled from pool 1.
- **A 409 is the oversell, and it is S4K's.** Exos never accepts an order it
  can't fill, so no Exos buyer and no organizer is hurt; S4K cancels the
  marketplace sale and pays any marketplace penalty, the way it handles a
  Paciolan seat that sold out from under it. Every rejection is logged
  (`exos_feed_rejections`: marketplace, quantity, what was left) for that
  accounting and for sizing the split.
- With no `buyerEmail`, the claim links are mailed to the token's delivery
  inbox (`exos_feed_consumers.delivery_email`), and returned in the response
  either way.
- Cancel before doors returns the seats to S4K's pool (still its share). After doors, or
  once a ticket was scanned, it's refused; refunds then follow the
  organizer's policy.

## Webhook (secondary)

Polling is the contract; the webhook only says "something moved, poll now".
Each minute the cron refreshes the feed state and, for a token with a
`webhook_url`, POSTs one coalesced body of every event that moved since the
last delivered one:

```json
{ "type": "inventory.changed", "generatedAt": "2026-10-13T14:00:00Z",
  "events": [{ "eventId": "6c1e…", "status": "active", "available": 12, "updatedAt": "2026-10-13T13:58:40Z" }] }
```

Signed like Exos's other webhooks: `X-Exos-Timestamp`, `X-Exos-Signature:
sha256=<hex HMAC-SHA256(secret, timestamp + "." + body)>`, `X-Exos-Delivery`
(dedupe on it). Deliveries page on `(updatedAt, eventId)` and stay 15 seconds
behind the clock, so a batch never skips a change that was still committing.
A non-2xx keeps the cursor and backs off (1, 2, 4 … 30
minutes); the next success carries everything since. The URL must be https
and resolve to public addresses.

## Turning it on (operator)

1. Apply `20261014100000_exos_s4k_feed.sql` (prod apply needs OK).
2. Deploy `exos-s4k-feed` with `--no-verify-jwt`. Secrets: `CRON_SECRET`,
   `EXOS_APP_BASE_URL` (plus the platform's `SUPABASE_*`).
3. Mint S4K's token, run once with the service role:
   `select * from exos_feed_create_consumer('S4K', '<fulfilment inbox>', '<webhook https url>');`
   It returns the `exf_…` token (shown once; only its hash is kept) and the
   webhook secret. Hand both to S4K over a private channel.
4. The migration schedules `exos-s4k-feed-1min` when pg_cron is present.
5. Base URL for S4K: `https://<project>.supabase.co/functions/v1/exos-s4k-feed/exos`.

## Mappings

The desk pairs events to the consumer's internal ids in its Map IDs tab, and
`internalId` stays blank until then. For Exos the pairing comes from S4K's
side: `PUT /exos/events/{eventId}/mapping {"internalId": "AQ-10442"}` (feed
token). After that, call 1 echoes it and either id resolves. Phase 1 can skip
this: S4K stores the Exos `eventId` and needs no pairing.

## What the first plan said would be built (done, kept for the record)

1. Migration `…_exos_s4k_feed.sql`:
   - `exos_feed_tokens` (hash, prefix, consumer name, revoked_at, last_used_at);
   - `exos_orgs.s4k_network boolean default false` (the per-org opt-in, which
     is also the consignment-agreement flag);
   - `exos_events.feed_updated_at`, bumped by the triggers that already
     maintain sold and held counts;
   - SECDEF RPCs `exos_feed_events(token_hash, since, limit, offset)`,
     `exos_feed_tickets(token_hash, event)` and `exos_feed_order(…)`, with a
     `tests/exos` harness.
2. A pure shaper, `_shared/feed/s4kFeed.ts` (rows → the JSON above), with
   unit tests.
3. The `exos-s4k-feed` edge function: GETs plus the one order POST, rate
   limited by `exos_rate_hit`, deployed `--no-verify-jwt`. **Deploying it
   needs operator OK.**
4. Organizer UI: an "S4K network" switch per org (owner only), and per event
   a read-only "what S4K sees" preview.

Phase 2, only if asked: `/feed/full`, `/feed/changes` and `/feed/status`
with per-token baselines, copied from the desk's `feed_seen` design.

## Still open

1. S4K's poll interval: with disjoint pools it no longer races Exos, but it is
   still the lag between S4K's marketplaces on S4K's own pool (rejections are
   S4K's to absorb).
2. Fees: none for now (operator 2026-10-13: treated as growth spend). Consignment terms still to write.
3. Mapping S4K's internal ids (`internalId` is null until a pairing call exists).
4. Phase 2 if S4K wants it: `/feed/full` + `/feed/changes` with per-token baselines.
