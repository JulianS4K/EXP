# Ticket Evolution (TEvo)

Channel id `evo`. Code: `supabase/functions/_shared/marketplace/tevo/` (app entry
`src/lib/marketplace/tevo/`). Source pages, supplied by the operator on 2026-09-28:
"HOWTO: Automate TEvo Order Processing", "HOW TO: Automate Flash & TM Mobile
Transfers", "HOW TO: Integrate the Riskified Fraud Service", "HOW TO: Process a
Substitution via the API", "HOWTO: Manually Review a Pending Order" and "Barcode
Encryption/Decryption" (TEvo Integrations wiki, victorylive.atlassian.net), and the API
reference pages Inventory / Create, Update, Delete, Bulk Update and Bulk Delete.

Exos is a **seller** on TEvo: each Exos listing goes up as a ticket group, orders for them
arrive, Exos accepts them and delivers a mobile transfer. Nothing is sent to TEvo today
(dry-run writer, Hard Rule #2).

## Endpoints

| Endpoint | Method + path | Access | Notes |
| --- | --- | --- | --- |
| listOrders | `GET /v9/orders` | read | Polling, TEvo's fail-safe to webhooks. Filters and paging **not in the supplied pages**; Exos sends `state=pending` (assumed) |
| showOrder | `GET /v9/orders/{order_id}` | read | Rechecks orders Exos already has |
| acceptOrder | `POST /v9/orders/{order_id}/accept` | write | `{reviewer_id, seats?}`; commits us to deliver |
| showShipment | `GET /v9/shipments/{shipment_id}` | read | |
| updateShipment | `PUT /v9/shipments/{shipment_id}` | write | `{mobile_transfer_type: TMMobileLink or TMMobile, transfer_source?}`; answers with a **new** shipment id |
| completeShipment | `PUT /v9/shipments/{shipment_id}/complete` | write | `{tm_mobile_link?, transfer_source?}`; marks shipment and order delivered |
| createInventory | `POST /v9/inventory` | write | `{inventory: {event, office, ticket, venue}}`; 201 with `inventory.id` |
| updateInventory | `PATCH /v9/inventory/{inventory_id}` | write | Changed ticket fields only; a new quantity recreates the group's tickets |
| deleteInventory | `DELETE /v9/inventory/{inventory_id}` | write | 204 |
| bulkUpdateInventory / bulkDeleteInventory | `PATCH` / `DELETE /v9/inventory` | forbidden | Up to 1,000 groups by TEvo id: one wrong id reaches broker inventory. Exos changes its listings one at a time |
| listListings | `GET /v9/listings` | read | Buyer-side search; not used for selling |
| listPayments | `GET /v9/payments?order_id=` | read | An order's payments (`order_id` required). For the payout ledger: did TEvo's EvoPay payment arrive |
| showPayment | `GET /v9/payments/{payment_id}` | read | One payment |
| paymentsStatus | `GET /v9/payments/status` | read | The office's payments across orders, filterable (`order_type`, `transaction_type`, `transaction_state`, `created_at.gte`, …). TEvo documents it as **POS only**: may be refused for an API token |
| createPayment | `POST /v9/payments` | forbidden | Moves money on an order |
| applyPayment | `GET /v9/payments/{id}/apply` | forbidden | **A GET that completes a pending payment.** Access is decided by the tag, never the method |
| cancelPayment | `GET /v9/payments/{id}/cancel` | forbidden | **A GET that cancels a pending payment** |
| refundPayment | `POST /v9/payments/{id}/refund` | forbidden | Reverses a payment (may void an unsettled card charge) |
| createOrder | `POST /v9/orders` | forbidden | A purchase (substitutions too). Exos never buys |
| add / finalize / remove etickets, deliver_etickets | `POST …/etickets` | forbidden | Static PDF/QR files can't carry a rotating Exos barcode |

Auth: `X-Token` + `X-Signature` on every call. The signature is base64 HMAC-SHA256 of
`"<METHOD> <host><path>?<sorted query or JSON body>"` with the API secret. **The
supplied pages show the headers but not how the signature is built**: this is TEvo v9's
scheme as we know it, in `transport.ts signatureBase()`. Check it against the sandbox
before any live use.

## Listings

The same Exos listings as every marketplace (`exosListing.ts`: blocks of at most max per
order, internal seats, stable `ex…` ids), planned by `exos-distribute` into
`planned_listing` and diffed against `listed_snapshot` (`tevo/listingPlan.ts`, `sync.ts`):

| TEvo field | Exos value |
| --- | --- |
| `event.id` | The linked TEvo event (`exos_channel_event_links`). Required; there's no TEvo event search in the supplied pages, so **staff link it**. Until then the event row says it's waiting and the plan lists it as unresolved |
| `event.name`, `occurs_at_date`, `occurs_at_time` | Event name, venue-local date and `HH:MM` |
| `office.id` | `TEVO_OFFICE_ID` |
| `ticket.remote_id` | A number from `exos_tevo_remote_ids` (mig 20260928080000): one per Exos listing, for good, from 1,900,000,001 up, never reused |
| `ticket.internal_notes` | The Exos listing id (`ex…`) |
| `ticket.format` | `TM_mobile` (mobile transfer; the claim link, below) |
| `section`, `row`, `seats` | Ticket type name (or section label), `GA`, the block's internal seats (`quantity` = seats) |
| `split_type` / `split_override` | the ticket type's split policy (`listingStandard.ts`): ANY, NEVERLEAVEONE, CUSTOM `[2,4…]` for pairs, NONE for all together; within the block (at most one order) |
| `in_hand` / `in_hand_on` | `false` / the event day |
| `price`, `face_value` | Marketplace price, ticket type price (USD only) |
| `external_notes` | How delivery works (Exos claim link) |
| `venue.name` | Venue name |

Updates send only the changed ticket fields (`{inventory: {ticket: {…}}}`); event, office,
`remote_id` and `internal_notes` are fixed once listed. Deletes and delists go one listing
at a time by TEvo's own id, which the live sender records on the snapshot entry
(`tevo_inventory_id`, from the create's 201); an entry without one is left for a person.
The writer only creates a group that carries an Exos listing id and an Exos `remote_id`,
in the configured office, as `TM_mobile`, with seats matching the quantity, and only
updates or deletes groups addressed by both.

**Use a TEvo office of its own for Exos.** The Terminal-2 broker office may carry other
inventory; the `remote_id` range keeps clear of a POS numbering from 1, but a dedicated
office rules out any clash and keeps TEvo's own reports clean.

## Orders

- **Sale to TEvo**: `buyer.type = Office` and `buyer.id = 6` (most sales). No buyer email
  on the order; for several tickets the email arrives with the shipment (below).
- **Sale to a Client** (TEvo-powered sites): `buyer.type = Client`. If
  `fraud_check_status = pending`, wait for Riskified (a `fraud_response_received` webhook
  follows each update); accept only at `null` or `approved`. The writer refuses otherwise.
- **Exos's orders only**: the account can carry Terminal-2 broker orders. An item is
  Exos's when its ticket group carries an Exos listing id (`ex…`). `exos-marketplace-sales`
  looks up each ticket group's `remote_id` in `exos_tevo_remote_ids` and writes the listing
  id on it (`annotateTevoOrder`); an `ex…` id in any other ticket-group field (internal
  notes, if TEvo echoes them) counts too. The writer refuses to accept any order with an
  item that has neither.
- Stored raw orders drop the buyer's and the shipments' names and emails (`stripTevoOrder`).

## Delivery (mobile transfer)

1. Accept (`reviewer_id` = the TEvo user id given to us, `TEVO_REVIEWER_ID`; internal seats).
2. One ticket: `updateShipment {mobile_transfer_type: TMMobileLink}`, then
   `completeShipment {tm_mobile_link: <Exos claim link>}` on the new shipment.
3. Several tickets: TEvo takes one link per shipment and Exos issues one claim link per
   ticket, so `updateShipment {mobile_transfer_type: TMMobile}`; TEvo answers with the
   recipient's email and name; Exos issues the order's transfers to that email; then
   `completeShipment`.

## Payments (how TEvo pays Exos)

TEvo pays the seller through EvoPay, after the event. Exos only **reads** payments (`tevo/payments.ts`,
`TevoClient.listPayments` / `getPayment` / `paymentsStatus`); every payment write is forbidden, since the office's orders
include Terminal-2's broker ones.

- **A payment:** `id`, `order_link_id` (the order), `type` (`cash`, `check`, `credit_card`, `evopay`, `money_order`,
  `offline`, `paypal`, `tbd`; Status says `EvopayTransaction`, …), `state` (`pending`, `completed`, `captured`, …),
  `amount` (a decimal string), `is_refund`, `refunded_from_id`.
- **Pending vs settled:** a pending payment only changes the order's *pending* balance; money has moved once it's
  `completed` / `captured`. `summarizeTevoPayments` nets settled payments minus settled refunds, keeps pending apart,
  and lists any state it doesn't know, so a person can look.
- **The payment is the gross; TEvo's fee comes off it.** The seller's fee is the order's top-level `fee`, not
  `service_fee`, which is the buyer's. On real order 8089940-19196777 (2026-09-26, office sale): `total` 32.48,
  `fee` 0.97 (2.99%), `service_fee` 0.0, one `evopay` payment of 32.48. TEvo's order page shows net 31.51. So Exos's
  sale proceeds (`normalizeTevoOrder`) are the items' price less `fee`. When broker items share the order, Exos's
  part of the fee is prorated by price.
- **TEvo's seller fee is 3% of the order total, rounded to the nearest cent, half up, per order** (not per ticket;
  `TEVO_SELLER_FEE_BPS`, `tevoSellerFeeCents`). Checked 2026-09-28 against every stored order the S4K office sold:
  4,371 of 4,371 match, May to September, to both Ticket Evolution and Victory Live, including all 41 half-cent cases
  (21.50 → 0.65). Purchases and internal transfers carry fee 0. When an order has no `fee`, Exos uses the 3%.
  `tevoFeeCheck` flags any order whose fee isn't 3%, for the payout ledger.
- **`completed` isn't "cash received".** On that order the EvoPay payment was `completed` one second after the sale,
  before the event. It means the payment is applied to the order. When EvoPay actually settles to the bank is
  separate, and the payout ledger has to reconcile that on its own.
- **Stored copies drop the personal fields:** `normalizeTevoPayment` keeps ids, type, state, direction and amount in
  cents. It drops `credit_card`, the `avs_*` / `cvv_*` results and `performed_by`, and the Status list's buyer and
  seller names, which can be a person's.
- **Not built yet:** the payout ledger that polls these for Exos's TEvo orders and matches them to what the
  organizer is owed. The operator decides that ledger's design, including whether Exos takes a fee on marketplace
  sales.

## Open questions for TEvo integrations

1. **Listing**: does an order's ticket group carry our `remote_id` (or internal notes)?
   That's how a sale maps back to its Exos listing. Is `TM_mobile` the right format for a
   non-Ticketmaster transfer? Which `occurs_at_time` format (Exos sends `HH:MM`)? Is there
   an event search, so events link themselves like StubHub and SeatGeek?
2. Signature scheme (PATCH signed like POST / PUT, with the body; DELETE like GET) (above) and `GET /v9/orders` filters and paging.
3. Webhook payloads ("Processing Orders via Webhooks") and Order Integration's hold /
   invoice / release requests ("Processing Orders via Order Integration"): Order
   Integration would let TEvo hold Exos seats at purchase time, which fits the pools.
4. Are `TMMobileLink` / `TMMobile` acceptable for a non-Ticketmaster transfer (an Exos
   claim link / Exos transfer), and which `transfer_source` value to send?
5. The order state names (Exos maps pending, accepted, completed/delivered,
   rejected/cancelled; anything else goes to a human).

Not used by Exos: Riskified beacon (buyer-side sites), substitutions (buyer side), manual
MOR review, Fernet barcode decryption (buyer side).

## Secrets (operator)

`TEVO_API_TOKEN`, `TEVO_API_SECRET`, `TEVO_ENV` (`production` or sandbox, the default),
`TEVO_REVIEWER_ID`, `TEVO_OFFICE_ID` (the office Exos inventory is created in). Reads
run in `exos-marketplace-sales` when the token and secret are set.
