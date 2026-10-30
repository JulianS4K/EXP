# Partner sales

Brokers and marketplaces (Automatiq, StubHub, Vivid Seats, SeatGeek, Ticket Network, Victory Live and others)
can sell an organizer's tickets through Exos with the same contract they already use with Opendate. They call
us; Exos never calls a marketplace for this. The full endpoint reference is on `/developers` under "Public:
Partner sales" (`docs/api/partner-sales.json`); this page is how it works.

- **Migration:** `supabase/migrations/20261031130000_exos_partner_sales.sql`. Harness:
  `tests/exos/test_partner_sales.sql`.
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
3. **Watch it.** Partner reservations and orders are in `exos_partner_reservations` (owners, managers and
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
- **All-in prices.** The price per ticket is what Exos checkout charges: the scheduled price, the organizer's
  passed-on fees and exclusive tax (`exos_all_in_unit_cents`). Partners see `price`, `calculated_fees`,
  `taxes_total` and `final_cost` per ticket type; they charge their buyer `final_cost`.

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
  them: the loser gets 409 before charging anyone. Up to 10 ticket types and 100 tickets.
- **Update** sets the attendee name and email, whether we email the tickets, and the partner's transaction id.
  It doesn't extend the hold.
- **Complete** consumes the holds and mints the tickets in one transaction, the way `exos_fulfill_checkout`
  does. It is idempotent: a repeat call answers 200 with the same order. After `expires_at` it answers 410 and
  the seats are released.
- **Cancel** releases the holds. A completed reservation can't be cancelled.
- **Comps** (`POST /v1/public/confirms/:id/comps`, keys with the comps scope) are a free reservation completed
  in the same call.
- **Organizer reservations** (`/v1/events/:id/organizer-reservations…`, an org credential with
  `tickets:write`) are the same core for the organizer's own systems: any ticket type of the event, hidden ones
  too, no distribution switch, `channel_source = 'api'`, and `/build` prices a reservation without holding.

Expired reservations stop counting at `expires_at` whatever happens; the record is flipped to `expired` on the
next touch or by `exos_partner_reservations_sweep()` (service role; not scheduled).

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
  tickets the buyer still holds (voided ones marked).

## Opendate mapping

| Opendate | Exos |
|---|---|
| `GET /public/confirms/{id}/ticket_types` | same path |
| `POST/PUT/DELETE /public/confirms/{id}/ticket_reservations[/{token}]`, `…/{token}/complete` | same paths (+ `GET …/{token}`) |
| `GET /public/orders`, `/public/orders/{id}`, `…/ticket_pdfs[/{ticket_id}]` | same paths; links instead of PDFs |
| `POST /public/confirms/{id}/comps` | same path; needs the comps scope |
| `POST /confirms/{id}/organizer_ticket_reservations[/build]`, `PUT/DELETE …/{token}`, `…/{token}/complete` | `/v1/events/:id/organizer-reservations[/build]`, `…/:token`, `…/:token/complete` |
| `…/organizer_ticket_reservations/{token}/gift_card_redemptions` | not built: Exos has no gift cards yet |
| `GET /confirms/{id}/ticket_reservations[/{id}]` | `GET /v1/events/:id/ticket-reservations[/:token]` |
