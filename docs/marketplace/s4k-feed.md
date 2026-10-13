# Exos → S4K inventory feed (design, 2026-10-13)

Status: **design only.** Nothing here is built or deployed. It replaces the
"Exos pushes to Automatiq" idea in [`automatiq.md`](automatiq.md) with a pull
model, so Exos never writes to a third party (Hard Rule #2 stays intact).

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
with its current shared count.

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
  channel, a refund, a price or cap change, the buffer stepping down at T-48h).
  `updatedSince` compares against it, as on the desk.
- `availability.available` is the **broadcast** count (see "The count"), not
  the raw unsold count.
- An event that drops out (cancelled, unpublished, the org opts out, doors
  passed) comes back once with `"status": "withdrawn"` and `available: 0` on
  the next `updatedSince` call, so the consumer delists it. The desk has no
  equivalent: it simply stops listing expired events.

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

## The count

The feed publishes **one shared count per ticket type**. Exos checkout,
Eventbrite and S4K all sell from it at once (the broadcast model in
`channel-sim.md`):

```
quantity = max(0, capacity − sold − active_holds − buffer)
buffer   = one pack (max per order, else 8)
```

- Exos checkout itself sells down to 0. The buffer only absorbs the lag of
  the slower channels: S4K's poll interval, then Automatiq's push to each
  marketplace.
- The simulation (`scripts/channel-sim/broadcast.py`) found a 1-pack buffer
  with lags of 3 to 10 minutes gives about one oversold order per 30
  sold-out events. With S4K polling every 5 minutes, add its interval to each
  marketplace's lag. Re-run the sim with those lags before going live. If the
  oversell rate is too high, the fix is a 2-pack buffer near sell-out, not a
  split.
- When the auto split (mig `20261014090000`) is on, its reserve still
  applies: `quantity` is capped at `capacity − sold − reserve` for the S4K
  feed. Broadcast and auto split are alternatives per event (open question
  below).

## Sales back: S4K buys from Exos

The desk is read-only because S4K fulfils a Paciolan sale by **buying the
seats on the storefront**. Exos copies that, through an API instead of a
browser:

```
POST /exos/events/{eventId}/orders        (feed token + Idempotency-Key)
{ "ticketId": "1f4b…", "quantity": 2, "externalRef": "AQ-order-88123",
  "marketplace": "stubhub", "unitNet": 30.00 }
→ 201 { "orderId": "…", "tickets": [{ "claimUrl": "https://…/bridge/claim/…", "seat": "GA-0153" }, …] }
→ 409 { "error": "not enough left", "available": 1 }        (the oversell, surfaced immediately)
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
- `unitNet` is checked against `netToOrganizer`, so a stale price can't sell
  below the organizer's floor.
- A 409 is the oversell. S4K then handles it the way it handles a Paciolan
  seat that sold out from under it. Whether that means cancel or substitute is
  the open oversell-policy question.
- Refunds and cancellations: `POST /exos/orders/{orderId}/cancel` before
  doors returns the seats to the shared count. After doors, refunds follow
  the organizer's policy.

## Mappings

The desk pairs events to the consumer's internal ids in its Map IDs tab, and
`internalId` stays blank until then. For Exos the pairing comes from S4K's
side: `PUT /exos/events/{eventId}/mapping {"internalId": "AQ-10442"}` (feed
token). After that, call 1 echoes it and either id resolves. Phase 1 can skip
this: S4K stores the Exos `eventId` and needs no pairing.

## What gets built (when S4K says go)

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

## Open questions for S4K

1. Is this two-call shape what the S4K consumer already reads? If so, should
   the paths be literally `/paciolan/…`-style so it can reuse the same parser
   (`/exos/events` here)?
2. Who calls the order POST: the Automatiq integration, or S4K's own
   fulfilment service? Do they want a webhook on sale-back instead of
   polling?
3. What poll interval will they use? It sets the buffer.
4. Fees and consignment: S4K's margin on top of `netToOrganizer`, and who
   eats an oversell.
5. Broadcast or auto split as the default for S4K-network events.
