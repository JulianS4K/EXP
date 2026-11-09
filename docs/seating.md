# Reserved seating

Seat maps, a seat picker on the event page, seat holds during checkout and
the seat on every ticket, receipt, wallet pass and door result. Built
in-house (Opendate uses seats.io). Ticket types (tiers) stay the pricing
unit, so fees, tax, promo codes, add-ons, refunds and reports work as for
general admission. Box office, POS, comps, marketplaces and partner feeds
keep selling general-admission tiers only.

Code: migration `supabase/migrations/20261030140000_exos_seating.sql`, pure
model `src/lib/seating.ts` (validation, grid generator, price levels, best
available), wrappers `src/lib/seatingApi.ts`, UI in
`src/components/seating/` and `src/views/OrgSeatMaps.tsx`. Checks:
`tests/exos/test_seating.sql`, `src/lib/seating.test.ts`,
`src/lib/wallet/seatedPass.test.ts`.

## Data model

| Table | What |
|---|---|
| `exos_seat_maps` | An org's reusable map (jsonb: canvas, stage, sections → rows → seats, standing areas). `room_id` is an optional pointer for venue rooms (no FK yet). Checked on save (`_exos_seat_map_error`, same rules as `validateMap`): ids, labels, positions, at most 100 sections, 200 rows × 200 seats, 10,000 seats, 200 maps per org. |
| `exos_event_seating` | The event's snapshot of a map plus its price levels. Editing the org's map later never moves sold seats. |
| `exos_event_seats` | One row per seat of the event: id `<section>-<row>-<key>`, section / row / number, label ("Orchestra · Row C · Seat 12"), position, accessibility flags, and the tier it sells as (NULL = not on sale). |
| `exos_event_seat_claims` | Seats that aren't available: `held` (a cart hold), `sold` (a ticket) or `blocked`. A partial unique index allows one live claim per seat; `lapsed` / `released` rows are history. |
| `exos_ticket_tiers.seated` | Server-written. A seated tier's capacity is its seats minus blocked ones; the event editor can't change either. |
| `exos_tickets.seat_*` | `seat_id`, `seat_label`, `seat_section`, `seat_row`, `seat_number`. Server-written; kept after a void as the seat the buyer had. |

Price levels map a section id, `<section>-<row>` or a seat id to a tier;
the most specific wins. A tier is sold as seats or as a standing area,
never both, and a tier that already sold general admission (or is a table)
can't become seated. The map of an event is locked once a seat was held or
sold; block and unblock single seats instead.

## Hold lifecycle

1. **Pick.** The picker reads the layout and per-seat availability of a
   published event (`exos_public_event_seating`, `exos_public_event_seats`:
   ids, labels, positions, tier and an `available` flag, nothing about
   holders). Picking is local; best available runs in the browser
   (`bestAvailable`: the most central block of adjacent seats in one row,
   obstructed seats last, wheelchair / companion seats left out; split seats
   only when no block fits).
2. **Checkout.** `exos-checkout` takes `seat_ids` for a seated tier (quantity
   = seat count, one tier per order, up to 10). It creates the usual cart
   hold (`exos_create_hold` / `exos_create_guest_hold`, 30 minutes, matching
   the Stripe session), then `exos_hold_seats` claims the seats for that
   hold. A seat someone else holds, bought or blocked answers 409 with its
   name ("Sorry, Orchestra · Row A · Seat 2 was just taken by someone
   else"), and the hold is released. Two buyers racing for one seat: the
   unique index lets one insert win. Seated orders never skip the hold (no
   capacity-bypass vouchers), and free seats are issued right there for
   signed-in buyers too. Stripe's line item lists the seats.
3. **Expiry.** A claim lives as long as its hold. Released or expired holds
   (`exos_expire_holds`, checkout failure, a new hold by the same buyer)
   lapse their claims; a hold still `active` past `expires_at` already
   counts as free for the next buyer.
4. **Fulfillment.** `exos_fulfill_checkout` is unchanged: a BEFORE INSERT
   trigger on `exos_tickets` gives ticket *i* the hold's seat *i* in the same
   transaction and marks the claim sold. If the buyer's hold lapsed and the
   seat was taken meanwhile, the trigger raises XF001 and the order fails
   and is refunded like a sold-out order. Any other insert for a seated tier
   (comps, box office, POS, marketplace, partner feed, the free-claim RPC) is
   refused.
5. **Refunds and voids.** A ticket leaving `active` / `used` (void, refund,
   release) or deleted frees its seat. Transfers and resales keep the seat
   (same ticket row).

## Screens

- **Org settings → Seat maps** (`/orgs/:orgId/seat-maps`): owners and
  managers build maps (grid generator: rows × seats, numbering scheme, first
  number, row letters or numbers, spacing, curve, stagger; drag sections;
  "Mark seats" cycles wheelchair / companion / restricted view). Staff view.
- **Edit Event → Reserved seating**: pick a map, give each section (or row)
  a ticket type, save; block / unblock seats; counts by status.
- **Event page**: for a seated tier the quantity stepper becomes the picker:
  map view (zoom, pan, coloured by price) and a list view with one button
  per seat, best available, and a clear message when a seat was taken.
- **Seat on the ticket**: My Tickets, the ticket page, the receipt in the
  order mail, Apple Wallet (SECTION / ROW / SEAT) and Google Wallet
  (`seatInfo`), and the door's result card (`exos_event_seat_roster`,
  cached on the device for offline use).

## Partner API (`exos-api`)

`GET /v1/events/:id/ticket-types` carries `seated`; attendees and order
tickets carry the `seat_*` fields; `GET /v1/events/:id/seats` lists every
seat with its status; `GET /v1/events/:id/seat-reconciliation` lists seats
and tickets that disagree (Opendate's seat reconciliation). Owners and
managers release orphans with `exos_release_orphan_seats`, which re-runs the
check and refuses the whole call if any seat is still live.

## Known limits

- Seats are held at checkout, not at pick time: a seat can be taken between
  picking and paying (the buyer sees which, and picks again).
- One ticket type per order.
- The embedded checkout (`/embed/event/:id`) and the box office don't offer
  seated tiers yet.
- Standing areas on a map are drawn and can carry a tier, but their tier's
  capacity is still set in the event form.
