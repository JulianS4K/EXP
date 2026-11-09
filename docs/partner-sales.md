# Partner sales

Brokers and marketplaces (Automatiq, StubHub, Vivid Seats, SeatGeek, Ticket Network, Victory Live and others)
can sell an organizer's tickets through Exos with the same contract they already use with Opendate. They call
us; Exos never calls a marketplace for this. The full endpoint reference is on `/developers` under "Public:
Partner sales" (`docs/api/partner-sales.json`); this page is how it works.

- **Migration:** `supabase/migrations/20261031130000_exos_partner_sales.sql`. Harness:
  `tests/exos/test_partner_sales.sql`. Checkout answers on reservations: `20261110120000_exos_leftovers_9.sql`,
  `tests/exos/test_leftovers_9.sql` (LO1, LO2). Answers on update and in order reads:
  `20261111140000_exos_api_leftovers.sql`, `tests/exos/test_api_leftovers.sql` (AL1-AL3), race
  `tests/exos/race_api_leftovers.sh`.
- **Code:** `supabase/functions/exos-api/index.ts` (`partnerApi`), `_shared/partners/sales.ts` (parsing),
  `_shared/api/routes.ts` (the `/public/…` rows). Wallet fallback: `exos-wallet` `POST /link-pass`.
- **UI:** Org settings → Distribution partners (`DistributionPartnersPanel`), Edit event → Sell through partners
  (`TierDistributionPanel`), the live ticket page `/t/:ticketId` (`LiveTicketLink`).

## For organizers

1. **Add a partner.** Org settings → Distribution partners (owners). Pick the partner, name it, tick "May issue
   comps" if it should. The key (`dk_live_` + 48 hex) is shown once; only its SHA-256 and a prefix are kept.
   Pause, allow / stop comps, or revoke it from the same list. Revoking cancels the partner's open
   reservations at once; its completed orders stay. At most 25 live keys.
2. **Open ticket types.** Edit event → Sell through partners (owners and managers). Per ticket type: switch it
   on, optionally tick which partners (none ticked means all of them), pause it. Off by default. Table ticket
   types are never offered. The API does the same: `GET/PUT /v1/events/:id/distribution`.
3. **Cap a partner (optional).** Same panel → Caps per partner: the most tickets one partner may hold or sell,
   for the whole event or one ticket type (`exos_partner_caps`, mig `20261104200000`). Blank means no cap, which
   is the default: partners share what is left. See "Caps" below. The API: `GET/PUT /v1/events/:id/partner-caps`.
4. **Watch it.** Partner reservations and orders are in `exos_partner_reservations` (owners, managers and
   finance can read them), and through `GET /v1/events/:id/ticket-reservations`. Tickets carry
   `channel_source = 'partner:<type>'` and `order_ref = 'po:<order id>'`.

## The rules partners sell under

- **Only what was opened to them.** A ticket type sells only with its switch on, not paused, and the partner in
  its list (or an empty list), inside its sales window.
- **Resale rules.** Partners are marketplaces, so `exos_resale_unlocked(event)` must be true: the free tier is
  never sold through a partner, and over it the organizer's resale opt-in applies once
  `20261029090000_exos_free_tier_resale_consent` is applied (it redefines that function; nothing here changes).
- **Last call and fixed blocks.** While `exos_event_last_call` (mig `20261029100000`) is on, new reservations
  are refused. A reservation held before last call or before a fixed block's release still completes: this
  migration adds `partner:%` to the pass-through of `exos_tg_ticket_last_call` and `exos_tg_ticket_fixed_block`
  when those functions exist (a guarded patch, skipped when they don't; if those migrations are applied after
  this one, re-run this one so the patch lands).
- **Channel namespace.** `channel_source` is always `partner:<partner_type>` for partner sales and `api` for
  organizer reservations, set only by the definer functions, never from the request (as `link:<slug>` is for
  free claims).
- **All-in prices.** The price per ticket is what Exos checkout charges: the current price step's price
  (docs/price-steps.md), the organizer's passed-on fees and exclusive tax (`exos_all_in_unit_cents`). Partners
  see `price`, `calculated_fees`, `taxes_total` and `final_cost` per ticket type; they charge their buyer
  `final_cost`.
- **Price steps** (mig `20261107120000`). A reservation is priced like a checkout: each line at one step, the
  step's price locked when the seats are held. A line over what the step has left is refused with 409
  `reason: "price_step_remaining"`, `remaining`, `price_cents` and `ticket_type_id` (nothing is held; `/build`
  answers the same): reserve `remaining`, then the rest at the next price. The reservation's holds count against
  the step until it completes, is cancelled or expires, and complete mints at the quoted price on that step even
  if the step moved meanwhile. Comps take no step place.

## Caps

Without a cap, every partner sells from the same pool (what is left after other channels' allocations), so one
partner can take all of it. A cap limits one partner, per ticket type (`tier_id`) or across the event
(`tier_id` null); with both, the tighter one applies.

- **What counts.** The partner's live holds (active reservations, not past `expires_at`) plus the tickets it sold
  that are still valid (`active` or `used`). Cancelled and expired reservations and voided or refunded tickets
  give their place back. Comps through the partner count too. Organizer reservations (an org API key's box
  office) are never capped.
- **Race-safe.** `_exos_partner_reserve` checks the caps after every line and the house cap passed, under a
  per-partner, per-event advisory lock, so two reservations of the same partner, even on different ticket
  types, can't both pass on the same count (`tests/exos/race_sim_partner.sh`).
- **Over the cap.** `409` with `reason: "partner_cap_reached"`, `left` (what the partner may still reserve) and
  `ticket_type_id` (null for an event cap). Nothing is held. A dry run (`…/build`) is refused the same way.
- **What partners see.** `GET …/ticket_types` answers `available` as at most what the partner's cap leaves.
- **Lowering a cap** below what a partner already holds is allowed: it only stops new reservations.
- `PUT /v1/events/:id/partner-caps` takes `{ "caps": [{ partner_id, ticket_type_id?, max_tickets }] }`;
  `max_tickets` is 0-100000 (0 stops the partner), or null to remove that cap. Caps not listed are kept. Owners
  and managers (a user token of another role is refused). The dashboard calls `exos_set_partner_caps`.

## How a sale works

```
reserve ──201 token, expires_at──▶ charge your buyer ──▶ PUT attendee ──▶ complete ──201 order + live links
   │                                     │                                    │
   └─409 sold_out: don't charge          └─DELETE: seats back on sale         └─410 after expires_at: nothing sold
```

- **Reserve** holds the seats for 10 minutes with ordinary cart holds (`exos_cart_holds.partner_reservation_id`,
  at most 10 seats a row), taken under the same locks as `exos_create_hold` (quotas, then ticket types). Every
  availability check in Exos already subtracts live holds, so the seats are gone from the storefront, the feeds,
  the marketplaces and the other partners at once, and two partners racing for the last seats can't both get
  them: the loser gets 409 before charging anyone. Up to 10 ticket types and 100 tickets. On a type with price
  steps the holds also carry the step and its price, taken under the lock checkout's `exos_hold_lock_price`
  uses, so a partner and a buyer can't both get the last early birds (`tests/exos/race_partner_steps.sh`).
- **Update** sets the attendee name and email, whether we email the tickets, the partner's transaction id and the
  checkout answers (see "Checkout questions" below). It doesn't extend the hold.
- **Complete** consumes the holds and mints the tickets in one transaction, the way `exos_fulfill_checkout`
  does. It first locks every shared limit of every line by id, then the ticket types by id (the order holds
  use), so a multi-type reservation can't deadlock against a checkout. It is idempotent: a repeat call answers 200 with the same order. After `expires_at` it answers 410 and
  the seats are released.
- **Cancel** releases the holds. A completed reservation can't be cancelled.
- **Comps** (`POST /v1/public/confirms/:id/comps`, keys with the comps scope) are a free reservation completed
  in the same call.
- **Organizer reservations** (`/v1/events/:id/organizer-reservations…`, an org credential with
  `tickets:write`) are the same core for the organizer's own systems: any ticket type of the event, hidden ones
  too, no distribution switch, `channel_source = 'api'`, and `/build` prices a reservation without holding.

Expired reservations stop counting at `expires_at` whatever happens; the record is flipped to `expired` on the
next touch or by `exos_partner_reservations_sweep()` (service role), which pg_cron runs every minute
(`exos-partner-reservations-sweep`, mig 20261104130000) so a gift card held on an abandoned reservation gets its
balance back.

- **Retries:** send an `Idempotency-Key` header (8-100 of `A-Za-z0-9_.:-`) on reserve and on comps. A resend with
  the same key and body answers the first reservation (same token, `idempotent_replay: true`) instead of holding
  the seats again or minting a second comp; the same key with other lines is 400. Keys are per partner.
- **Checkout questions** (mig `20261110120000`, docs/checkout-questions.md). The organizer's questions ("T-shirt
  size?", "Company") are asked of partner buyers too. `GET /public/confirms/:id/questions` lists them (label, kind,
  options, required, per order or per ticket, ticket types, "show only if"); questions hidden from checkout are left
  out. Send the answers with the reserve call: `ticket_reservation[answers] = { order: { <question id>: value },
  tickets: [{ <question id>: value }, ...] }`, one tickets entry per ticket in the order the reservation lists its
  `order_items` (the ticket types' order; for one type, simply ticket 1..n). They are checked like Exos checkout
  (options, lengths, ranges, "show only if" conditions) before a seat is held, and **required questions are
  required**: without them the reserve answers 422 `reason: "questions_required"` with `missing: [{ question_id,
  label, ticket }]` and holds nothing, so ask your buyer before you charge. An invalid answer is 400. Answers are
  stored with the reservation (order ref `po:<reservation>`, like online answers) and attached to each ticket at
  complete; the organizer sees them in the event report and the API. Complete may carry answers when the reserve
  sent none (optional ones); reserve and complete keep one set, the first sent. Comps take `comp[answers]` the same
  way. Organizer reservations take `answers` on reserve, `/build` (checked, not stored) and complete: checked, hidden
  staff questions allowed, never required.
- **Changing the answers** (mig `20261111140000`). `PUT …/ticket_reservations/:token` with
  `ticket_reservation[answers]` replaces the whole set while the reservation is open (active, before `expires_at`,
  before complete), checked exactly as on reserve: required questions are required for partners (422
  `questions_required`, the stored set unchanged), an invalid answer is 400, a hidden question is refused. The
  organizer's `PUT /v1/events/:id/organizer-reservations/:token` does the same with the organizer's rules (hidden
  questions allowed, never required; `{}` clears the set). Leaving `answers` out keeps the stored set. A completed
  or cancelled reservation answers 409, an expired one 410; nothing changes. Each replacement is one org audit row
  (`reservation.answers_replace`, the number of answers before and after, never the values). The update and
  complete take the same row lock, so an update racing a complete either lands before the mint (and the tickets
  get the new set) or sees the reservation completed (`tests/exos/race_api_leftovers.sh`).
- **Member presales:** while an organizer's member presale runs on a ticket type, partners can't reserve it (422,
  `reason: not_available`); organizer reservations still can.
  That is the default (`block`); an organizer can set `allow` for the organization or one event, and partners then
  sell during the presale too (docs/org-access.md, `PUT /v1/partner-presale`).

## Delivery: a link to the live ticket

Tickets are minted on the org owner (as marketplace and guest orders are) with no transfer pending. Each ticket
in an order comes with `delivery.url`:

    https://<app>/t/<ticket id>#k=<key>
    key = base64url(HMAC-SHA256(barcode_secret, "ticket-link:<ticket>:<owner>"))

- The key sits in the URL fragment, which browsers never send to a server.
- The page calls `exos_ticket_link_view(ticket, key)` (anon). It recomputes the key, and answers the event,
  ticket type, attendee and the ticket's **current door code**: the same `T-…` code the app shows, signed in the
  database with the door's day key (`_exos_door_code_mac`), for the current 30-second bucket. The page refreshes
  it as it rotates; a screenshot won't scan. The barcode secret never leaves the database.
- A reissue or a transfer rotates the secret and changes the owner, so the old link stops working.
- There is no PDF: Opendate's `ticket_pdfs` endpoints answer each ticket's live link (`content_base64` is null).
- **Wallet fallback:** the page offers Apple / Google Wallet through `exos-wallet POST /link-pass
  { ticket_id, link_key, kind }`, checked by `exos_ticket_link_wallet_issue` with the same rules as the owner's
  `exos_wallet_issue_pass`.
- With `should_send_ticket_email` and an email, the buyer is mailed the links (`ticket-issued` template) when the
  reservation completes. Needs `EXOS_APP_BASE_URL` on `exos-api`.

## For partners

- Base URL: `https://<project-ref>.supabase.co/functions/v1/exos-api/v1/public`. If you call Opendate's
  `/api/v2/public/…`, change the base URL and key; paths (`/confirms/:id/ticket_reservations…`, `/orders…`),
  parameters (`ticket_reservation[...]`, `q[...]`) and shapes match. JSON (nested or flat) and Rails-style form
  bodies both work.
- Authenticate with `?shared_key=dk_live_…`, the `X-Shared-Key` header or `Authorization: Bearer`. 401 for a
  missing, wrong, paused or revoked key; 404 for anything outside your organizer or your own reservations.
  120 requests a minute per key.
- Orders: `GET /orders` lists your completed orders, newest first, in Opendate's envelope
  (`current_page, per_page, total_entries, total_pages, collection`; `per_page` up to 250), filterable by
  event, email, your transaction id and created / updated time. Money is in major units. Each order lists the
  tickets the buyer still holds (voided ones marked). `GET /orders/:id` is one order in the same shape.
- Each ticket in an order carries the checkout answers given for it (mig `20261111140000`): `answers` (`question_id`,
  `scope`, `label`, `kind`, `value`, `display`; the order's answers on every ticket, then the ticket's own) and
  Opendate's `custom_field_values` (`custom_field_id` = the question id, `name` = its label, `value` = the answer as
  text). Only the answers you submitted for that order (on reserve, comps, complete or update), only your own
  orders, and never a question the organizer keeps for staff (hidden from checkout). Answers added or changed after
  the order completed (by door staff, the organizer, or whoever holds the ticket later) are not returned: an answer
  someone else rewrote drops out of your read.

## Opendate mapping

| Opendate | Exos |
|---|---|
| `GET /public/confirms/{id}/ticket_types` | same path |
| (none) | `GET /public/confirms/{id}/questions`: the checkout questions a reservation answers |
| `POST/PUT/DELETE /public/confirms/{id}/ticket_reservations[/{token}]`, `…/{token}/complete` | same paths (+ `GET …/{token}`) |
| `GET /public/orders`, `/public/orders/{id}`, `…/ticket_pdfs[/{ticket_id}]` | same paths; links instead of PDFs; tickets add `answers` and `custom_field_values` |
| `PUT /public/confirms/{id}/ticket_reservations/{token}` (attendee only) | same path; also replaces the checkout answers while open |
| `POST /public/confirms/{id}/comps` | same path; needs the comps scope |
| `POST /confirms/{id}/organizer_ticket_reservations[/build]`, `PUT/DELETE …/{token}`, `…/{token}/complete` | `/v1/events/:id/organizer-reservations[/build]`, `…/:token`, `…/:token/complete` |
| `POST/DELETE …/organizer_ticket_reservations/{token}/gift_card_redemptions[/{id}]` | `/v1/events/:id/organizer-reservations/:token/gift-card-redemptions[/:rid]` (+ `GET`); `docs/gift-cards.md` "On reservations" |
| `GET /confirms/{id}/ticket_reservations[/{id}]` | `GET /v1/events/:id/ticket-reservations[/:token]` |
