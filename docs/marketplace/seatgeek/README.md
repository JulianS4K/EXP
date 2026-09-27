# SeatGeek Seller Direct API

Sources, supplied by the operator 2026-09-27: the SeatGeek **Seller Direct
API 1.0.0** (OAS3) reference, and the Seller API guides: Managing Listings
via API, Listing Fields, Order Management, Obtaining Remittance Data and
Webhook Notifications. Server: `https://sellerdirect-api.seatgeek.com`
(production; no sandbox is listed).

What it covers: manage inventory (listings), take the orders SeatGeek
submits, update an order's status, fulfil an order (transfer URL, PDF or
barcodes), and remittances. There is **no event search and no event
creation**: a listing attaches to an existing SeatGeek event (`event_id`) or
carries the event as text.

Code: `supabase/functions/_shared/marketplace/seatgeek/` (shared with the
app through `src/lib/marketplace/seatgeek`).

## Auth

The seller API token in the `Authorization` header: the API spec recommends
`Bearer {token}`, while the guides' examples use `token {token}` and
`?token=`. The client takes `authScheme: 'Bearer' | 'token'` (default
Bearer) and never puts the token in the URL (it would end up in logs).
Secret: `SEATGEEK_API_TOKEN`.

Event search for linking uses SeatGeek's **public Platform API**
(`GET https://api.seatgeek.com/2/events`, read-only, `client_id` query
parameter; secret `SEATGEEK_CLIENT_ID`). It's optional: without it, a
platform admin links SeatGeek events by hand (organizers can only pick from
what a search found).

## Endpoints

**Access**: **R** = read, fine to call. **W** = writes to SeatGeek; built in
the writer, dry-run, and needs an operator `WriteAuthorization` to send
(Hard Rule #2). **✖** = forbidden: never sent, whatever the authorization.

| Endpoint | Access | Used by Exos | Notes |
|---|---|---|---|
| `GET /listings` | R | | All listings, cursor-paged (`per_page` ≤ 2000, `page_cursor`). Filters: `seller_listing_ids`, `event_id`, `only_barcode`. |
| `GET /listings/single/{seller_listing_id}` | R | | |
| `PUT /listings/single/{seller_listing_id}` | W | listing plan | Create one listing (JSON). 409 if re-creating a sold-out listing within 5 minutes of its last order. |
| `PATCH /listings/single/{seller_listing_id}` | W | roadmap 2 | Partial update. 409 for an inventory increase within 5 minutes of the last order (price/notes/decrease are fine). |
| `DELETE /listing?seller_listing_id=` | W | | Deprecated single delete. |
| `DELETE /listings?seller_listing_ids=` | W | | Deprecated bulk delete (up to 10,000 ids). |
| `POST /listings/bulk-delete` | W | roadmap 2 | Current bulk delete, body `{ seller_listing_ids: [...] }`. Marks listings inactive; a PUT with the same id re-enables. The writer refuses non-Exos ids. |
| `POST /listings`, `PUT /listings` (CSV) | ✖ | | **Syncs the whole account**: adds, updates and **deletes every listing missing from the file**. The seller account carries broker inventory, so this would delete it. |
| `GET /listings/purge` | R | | Purge job status (`RUNNING` / `NOT_STARTED`). |
| `POST /listings/purge` | ✖ | | Deletes the whole inventory. |
| `GET /order?order_id=` | R | sales recheck | One order. |
| `PATCH /order` (multipart) | W | fulfilment plan | `order_id`, `status`, `delivery_method` + `stock_type` (required when fulfilling), `transfer_url`, `seats`; venue/local pickup fields. |
| `PUT /v3/order` | W | | Fulfil with PDF `files[]` or barcode `tokens[]`. |
| `PUT /v1/order`, `PUT /v2/order` | W | | Deprecated barcode fulfilment. |
| `POST /v3/order/proofs` | W | | Pre-signed S3 upload URLs for proof-of-transfer files (order must be `fulfilled`). |
| `GET /orders` | R | sales poll | `status`, `start_date` / `end_date` (**when the order was placed**), `page`, `per_page` (default 200). |
| `GET /orders/customer?order_id=` | R | buyer email | `{ customer: { email, first_name, last_name, phone } }` (spec shows it bare; both handled). Not available after the event. |
| `GET /orders/label?order_id=` | R | | Shipping label (base64). |
| `GET /remittances`, `/remittances/current`, `/remittances/{invoice_id}` | R | | Payouts. |

## Facts from the guides

| Topic | What SeatGeek says |
|---|---|
| `seller_listing_id` | Max **32 chars**, unique per account. Exos: `ex` + allocation id in 26-char base32 + group number (≤ 32). |
| Required listing fields | `event`, `venue`, `event_date`, `quantity`, `cost`, `section`, **`row`**; `seat_from`/`seat_thru` when a row is given (Exos: internal seat numbers, below). `event_time` HH:MM:SS or TBA/TBD. `event_id` optional; events are matched on title + venue, so use SeatGeek's names. |
| `cost` | The broadcast price per ticket; the seller is paid this less fees. |
| `split_type` / `splits` | `ANY`, `DONTLEAVEONE`, `CUSTOM` (with `splits`), `DEFAULT`. A CUSTOM list must end at the listing quantity, else DEFAULT applies: **splits can't cap an order below the quantity**. |
| `stock_type` (listing) | `mobile` (transfer), `pdf`, `shipped`, `local pick-up`, `walk-in`, `gift card`. Unset or unknown: inferred from notes. **Integrated events** (e.g. Paciolan; `integrated` on Platform `GET /2/events/{id}`) are forced to `barcode`, and a listing without barcodes is hidden (`no_barcodes`). |
| `is_edelivery` | true for mobile and pdf. `is_instant` needs it. |
| Order statuses | `submitted`, `confirmed`, `denied`, `fulfilled`, `void`. PATCH sets `confirmed` / `denied` / `fulfilled`. |
| Transfer fulfilment | PATCH `/order`: `status=fulfilled`, `delivery_method=electronic`, `stock_type=mobile`, `transfer_url` (several **comma-separated**). SeatGeek shows the link to the buyer. |
| Order stock types | `mobile`, `paper`, `paperless`, `barcode`, `pdf` (differs from listing inputs). |
| Re-fulfilment | A `fulfillment_issue_message` allows re-fulfilment (barcode, pdf); retransfers use `retransfer_complete=true` with mobile. |
| Holds | No reservation/hold API. |
| Webhooks | One URL, `Authorization: Bearer {our token}`, envelope `{ metadata, data: [...] }` (schema_version 1, data always a list, may be batched). 2xx within 10 s, 3 retries 1 s apart, then dropped; a circuit breaker pauses failing endpoints. Set up through SeatGeek support. Types: `ping`, `order.created`, `order.retransfer`, `order.fulfillment.error`, `order.broken`, `listing.event.inactive`, `listing.visibility` (batched every 30 min), `listing.normalization.status`, `listing.normalization.status.changed`. |
| Remittances | Weekly invoices (`total_order_value`, `total_fees`, `total_finance`, `total`) with per-order `charges` (`order_payment` credit, `seller_fees` debit). |

## How SeatGeek ties into Exos

Same marketplace layer as StubHub (`docs/marketplace/README.md`):

1. **Link.** With `SEATGEEK_CLIENT_ID` set, `exos-distribute` pass 0 searches
   the Platform API (event name + venue-local date) and links a confident
   match; a close call goes to staff. No event creation: SeatGeek doesn't
   offer it. Unlinked listings carry the event as text for SeatGeek to match.
2. **Allocate.** The organizer fills the event editor's Marketplaces grid
   (a row per ticket type, a column per ticked marketplace;
   `exos_set_channel_allocation`, channel `seatgeek`). Exos stops selling
   those seats, so nobody can buy the same seat on both.
3. **List (planned).** `exos-distribute` pass 1b plans the listings into
   `planned_listing`: because splits can't cap an order, the allocation is
   split into listings of **at most the event's max per order** each
   (10 seats, max 4 → 4 + 4 + 2), `stock_type` `mobile`, `row` `GA`,
   `split_type` `ANY`, and each listing is a block of **internal seat
   numbers** (`seat_from`/`seat_thru`, below). The plan is diffed against
   what SeatGeek has (`listed_snapshot`): create, update (`PATCH`) or
   delete (`POST /listings/bulk-delete`). Listing numbers stay stable across
   re-plans.
4. **Sell.** Orders arrive by webhook (`order.created`) and by polling
   `GET /orders` (placed in the last 6 hours) plus a rolling `GET /order`
   recheck of up to 50 open orders per run, so a later `void`/`denied`
   still arrives. `order.broken` counts as cancelled. Orders on Exos
   listings are recorded and fulfilled: Exos tickets, one transfer per
   ticket, and a mail to the buyer (email from `GET /orders/customer`) with
   the claim links. Anyone with a link claims it into any Exos account.
5. **Deliver (planned).** `PATCH /order` with `status=fulfilled`,
   `delivery_method=electronic`, `stock_type=mobile` and the claim links
   comma-separated in `transfer_url`.
6. **Listing problems.** `listing.visibility` and `listing.event.inactive`
   are written on the allocation row; the event editor shows them.
7. **Pull back.** Unticking SeatGeek, primary-market-only, unpublishing,
   cancelling, or setting the grid cell to 0: delist, then release. Seats
   with nothing on SeatGeek return to Exos at once; a live listing is
   deleted first and its seats stay set aside until then.

### Internal seat numbers (general admission)

SeatGeek requires `seat_from`/`seat_thru` with a row, and GA has no seats.
Every allocated seat gets an internal number instead (mig
`20260927030000`): per ticket type, from a counter that never repeats, so
StubHub and SeatGeek never share one. `exos_distribution_listings.internal_seats`
holds the unsold numbers (growing adds new ones, shrinking drops the
highest). A sale gives each ticket one (`exos_tickets.internal_seat`): the
highest left on the SeatGeek listing the order was placed on, so the
listing's `seat_from` stays put. They're for staff and SeatGeek only: the
event editor's grid shows them to the organizer, buyers never see them, and
GA entry doesn't check them.

Nothing is sent to SeatGeek: listing creation and fulfilment are dry-run.

## Still open (confirm with SeatGeek before going live)

| Question | Where it matters |
|---|---|
| Is Exos's claim link acceptable as a `mobile` transfer URL (it isn't a Ticketmaster/AXS link)? | fulfilment |
| Should a `submitted` order be `confirmed` before it's fulfilled, or can it go straight to `fulfilled`? | fulfilment |
| Rate limits (not documented). Reads retry 429/502/503/504; writes retry 429 only, never 409. | client, writer |

## Write roadmap

`SEATGEEK_WRITE_ROADMAP` in `seatgeek/writer.ts`:

| # | Phase | Endpoints |
|---|---|---|
| 1 | Listing creation (one listing per max-per-order group) | `createListing` |
| 2 | Listing management (price/qty sync, delist): planned as `ops` in `planned_listing` | `updateListing`, `bulkDeleteListings` |
| 3 | Order confirm + fulfil (transfer URLs) | `updateOrder` |

Going live needs: `SEATGEEK_API_TOKEN` (+ `SEATGEEK_CLIENT_ID` for linking,
`SEATGEEK_WEBHOOK_TOKEN` and a webhook setup request to SeatGeek support),
the open questions above answered, and a recorded operator
`WriteAuthorization` listing exactly the endpoints.
