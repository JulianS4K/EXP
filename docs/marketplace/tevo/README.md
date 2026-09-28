# Ticket Evolution (TEvo)

Channel id `evo`. Code: `supabase/functions/_shared/marketplace/tevo/` (app entry
`src/lib/marketplace/tevo/`). Source pages, supplied by the operator on 2026-09-28:
"HOWTO: Automate TEvo Order Processing", "HOW TO: Automate Flash & TM Mobile
Transfers", "HOW TO: Integrate the Riskified Fraud Service", "HOW TO: Process a
Substitution via the API", "HOWTO: Manually Review a Pending Order" and "Barcode
Encryption/Decryption" (TEvo Integrations wiki, victorylive.atlassian.net).

Exos is a **seller** on TEvo: orders for Exos tickets arrive, Exos accepts them and
delivers a mobile transfer. Nothing is sent to TEvo today (dry-run writer, Hard Rule #2).

## Endpoints

| Endpoint | Method + path | Access | Notes |
| --- | --- | --- | --- |
| listOrders | `GET /v9/orders` | read | Polling, TEvo's fail-safe to webhooks. Filters and paging **not in the supplied pages**; Exos sends `state=pending` (assumed) |
| showOrder | `GET /v9/orders/{order_id}` | read | Rechecks orders Exos already has |
| acceptOrder | `POST /v9/orders/{order_id}/accept` | write | `{reviewer_id, seats?}`; commits us to deliver |
| showShipment | `GET /v9/shipments/{shipment_id}` | read | |
| updateShipment | `PUT /v9/shipments/{shipment_id}` | write | `{mobile_transfer_type: TMMobileLink or TMMobile, transfer_source?}`; answers with a **new** shipment id |
| completeShipment | `PUT /v9/shipments/{shipment_id}/complete` | write | `{tm_mobile_link?, transfer_source?}`; marks shipment and order delivered |
| listListings | `GET /v9/listings` | read | Buyer-side search; not used for selling |
| createOrder | `POST /v9/orders` | forbidden | A purchase (substitutions too). Exos never buys |
| add / finalize / remove etickets, deliver_etickets | `POST …/etickets` | forbidden | Static PDF/QR files can't carry a rotating Exos barcode |

Auth: `X-Token` + `X-Signature` on every call. The signature is base64 HMAC-SHA256 of
`"<METHOD> <host><path>?<sorted query or JSON body>"` with the API secret. **The
supplied pages show the headers but not how the signature is built**: this is TEvo v9's
scheme as we know it, in `transport.ts signatureBase()`. Check it against the sandbox
before any live use.

## Orders

- **Sale to TEvo**: `buyer.type = Office` and `buyer.id = 6` (most sales). No buyer email
  on the order; for several tickets the email arrives with the shipment (below).
- **Sale to a Client** (TEvo-powered sites): `buyer.type = Client`. If
  `fraud_check_status = pending`, wait for Riskified (a `fraud_response_received` webhook
  follows each update); accept only at `null` or `approved`. The writer refuses otherwise.
- **Exos's orders only**: the account can carry Terminal-2 broker orders. An item is
  Exos's when its ticket group carries an Exos listing id (`ex…`); the writer refuses to
  accept any order with an item that doesn't.
- Stored raw orders drop the buyer's and the shipments' names and emails (`stripTevoOrder`).

## Delivery (mobile transfer)

1. Accept (`reviewer_id` = the TEvo user id given to us, `TEVO_REVIEWER_ID`; internal seats).
2. One ticket: `updateShipment {mobile_transfer_type: TMMobileLink}`, then
   `completeShipment {tm_mobile_link: <Exos claim link>}` on the new shipment.
3. Several tickets: TEvo takes one link per shipment and Exos issues one claim link per
   ticket, so `updateShipment {mobile_transfer_type: TMMobile}`; TEvo answers with the
   recipient's email and name; Exos issues the order's transfers to that email; then
   `completeShipment`.

## Open questions for TEvo integrations

1. **Listing**: how does a seller put inventory on TEvo by API (ticket groups create, or a
   POS/feed)? Without it no Exos listing reaches TEvo, so nothing sells there yet.
2. Signature scheme (above) and `GET /v9/orders` filters and paging.
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
`TEVO_REVIEWER_ID`. Reads run in `exos-marketplace-sales` when the token and secret are set.
