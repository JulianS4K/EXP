# StubHub API reference

Source: <https://developer.stubhub.com/api-reference/> (printed 2026-09-14).
Auth on every endpoint: **OAuth2** (bearer token). Responses are
`application/hal+json` with `_links` / `_embedded`; lists are paged with
`page` / `page_size` / `sort` and return `total_items`.

| API | Version | PDF | Text |
|---|---|---|---|
| Account | 2.249.0.0 | [pdf](pdf/account.pdf) | [txt](text/account.txt) |
| Catalog | 1.0.0.75 | [pdf](pdf/catalog.pdf) | [txt](text/catalog.txt) |
| Catalog, Events section expanded | 1.0.0.75 | [pdf](pdf/catalog-events-expanded.pdf) | [txt](text/catalog-events-expanded.txt) |
| Inventory | 2.249.0.0 | [pdf](pdf/inventory.pdf) | [txt](text/inventory.txt) |
| Sales | 2.249.0.0 | [pdf](pdf/sales.pdf) | [txt](text/sales.txt) |
| Webhooks | 2.249.0.0 | [pdf](pdf/webhooks.pdf) | [txt](text/webhooks.txt) |

The "Event" PDF is the same Catalog API printed with the Events schemas
expanded, so it has the same endpoints with more field detail.

**R/W** column: **R** = read, fine to call. **W** = writes to StubHub and is
forbidden under Hard Rule #2 without operator sign-off. **R\*** = lookup
that uses a PUT/POST verb but changes nothing.

## Catalog: events, venues, categories

| R/W | Endpoint | Purpose |
|---|---|---|
| R | `GET /catalog/events` | List all events (full catalog sync) |
| R\* | `PUT /catalog/events` | List a given set of events by id |
| R | `GET /catalog/events/{eventId}` | Get an event |
| R | `GET /catalog/events/search` | Search events |
| R | `GET /catalog/events/external_mappings/{platform}/{externalEventId}` | Resolve an event from another platform's id (xref) |
| R | `GET /catalog/categories/map` | Match a category from a query string |
| R | `GET /catalog/categories/{categoryId}/events` | Events in a category |
| R | `GET /catalog/categories/{categoryId}/allevents` | Events in a category and all its children, de-duped |
| R\* | `POST /catalog/mapevent` | Map a request to a StubHub event/venue/category |
| R | `GET /catalog/venues` | List all venues |
| R | `GET /catalog/venues/{venueId}` | Get a venue |

Event ids can be merged: a lookup by an old id returns the surviving event
with a different `id`. Treat a changed id as a merge and update the xref.

## Inventory: seller listings, seller events, e-tickets

| R/W | Endpoint | Purpose |
|---|---|---|
| R | `GET /sellerlistings` | List own listings |
| R | `GET /sellerlistings/recentupdates` | Listings created or updated since a time (incremental sync) |
| R | `GET /sellerlistings/{listingId}` | Get a listing |
| R | `GET /externalsellerlistings/{externallistingId}` | Get a listing by our own external id |
| W | `POST /events/{eventId}/sellerlistings` | Create a listing |
| W | `POST /sellerlistings` | Create a listing for a *requested* (not yet catalogued) event |
| W | `PATCH /sellerlistings/{listingId}` | Update a listing (price, qty, seating…) |
| W | `PATCH /externalsellerlistings/{externalId}` | Update by external id |
| W | `DELETE /sellerlistings/{listingId}` | Delete a listing |
| W | `DELETE /externalsellerlistings/{externalId}` | Delete by external id |
| R\* | `POST /events/{eventId}/sellerlistingpreview` | Preview a listing (fees and proceeds); nothing is created |
| R\* | `POST /sellerlistingpreview` | Preview for a requested event |
| R\* | `POST /sellerlistings/{listingId}/updatepreview` | Preview an update; nothing is applied |
| R | `GET /events/{eventId}/listingconstraints` | Allowed values (splits, delivery, etc.) for an event |
| R | `GET /sellerlistings/{listingId}/constraints` | Constraints for a listing |
| R\* | `PUT /listingconstraints` | Constraints for a requested event |
| R | `GET /sellerevents` | Events where we have listings |
| R | `GET /sellerevents/{eventIdOrRequestedEventId}` | Get one |
| W | `PUT /sellerevents` | Ask StubHub to create an event |
| W | `POST /sellerlistings/{listingId}/eticketuploads` | Upload e-ticket PDFs to a listing |
| R | `GET /sellerlistings/{listingId}/eticketuploads` | List uploads |
| W | `POST /events/{eventId}/eticketuploads` | Upload e-tickets at event level |
| R | `GET /events/{eventId}/eticketuploads` | List them |
| R | `GET /sellerlistings/{listingId}/etickets` | List e-tickets on a listing |
| W | `POST /sellerlistings/{listingId}/etickets` | Save e-tickets to a listing |
| W | `PATCH /sellerlistings/{listingId}/etickets` | Mark back (withdraw) e-tickets |
| W | `DELETE /sellerlistings/{listingId}/etickets/{ETicketId}` | Remove an e-ticket |
| W | `DELETE /events/{eventId}/etickets/{eticketId}` | Remove an event-level e-ticket |
| R | `GET /sellerlistings/{listingId}/markedbacketickets/{markedBackETicketId}/document` | Download a marked-back ticket |
| R | `GET /sellerlistings/{listingId}/shipments` | List shipments |
| R | `GET /sellerlistings/{listingId}/shipments/{shipmentId}/label` | Get a shipping label |
| W | `PUT /sellerlistings/{listingId}/shipments` | Print (create) a shipping label |
| W | `PATCH /sellerlistings/{listingId}/shipments/{shipmentId}` | Update a shipment |

Listing bodies carry `ticket_price` (buyer-facing) *and* `ticket_proceeds`
(seller net) as `Money`. On PATCH, `seating` must be sent in full, because
omitted seating fields are blanked.

## Sales: orders, fulfilment, payouts

| R/W | Endpoint | Purpose |
|---|---|---|
| R | `GET /sales` | List sales |
| R | `GET /sales/recentupdates` | Sales created or updated since a time |
| R | `GET /sales/{saleId}` | Get a sale |
| W | `PATCH /sales/{saleId}` | Update a sale (confirm, attach e-ticket pages, etc.) |
| W | `DELETE /sales/{saleId}` | Reject a sale / report a problem |
| W | `POST /sales/{saleId}/eticketuploads` | Upload e-ticket PDFs; then PATCH the sale to pick pages |
| R | `GET /sales/{saleId}/eticketuploads` | List uploads |
| R | `GET /sales/{saleId}/etickets` | List e-tickets |
| W | `POST /sales/{saleId}/etickets` | Upload and save e-tickets |
| W | `DELETE /sales/{saleId}/etickets/{eticketId}` | Remove an e-ticket |
| R | `GET /etickets/{eticketId}/document` | Download an e-ticket PDF |
| R | `GET /etickets/{eticketId}/thumbnail` | E-ticket thumbnail |
| R | `GET /eticketuploads/{eticketUploadId}/document` | Original uploaded file |
| R | `GET /sales/{saleId}/shipments` | List shipments |
| R | `GET /sales/{saleId}/shipments/{shipmentId}/label` | Shipping label |
| W | `PUT /sales/{saleId}/shipments` | Print a shipping label |
| W | `PATCH /sales/{saleId}/shipments/{shipmentId}` | Update a shipment |
| R | `GET /sales/{saleId}/ticketholders` | Ticket-holder details |
| R | `GET /payments` | List payouts |
| R | `GET /payments/{paymentId}` | Get a payout |
| R | `GET /payments/next` | Preview the next payout |

## Account

| R/W | Endpoint | Purpose |
|---|---|---|
| R | `GET /user` | Authenticated user |
| W | `PATCH /user` | Update user |
| R | `GET /addresses`, `GET /addresses/{addressId}` | Addresses |
| W | `POST /addresses`, `PATCH /addresses/{addressId}`, `DELETE /addresses/{addressId}` | Manage addresses |
| R | `GET /paymentmethods`, `GET /paymentmethods/{paymentMethodId}` | Payout methods |
| R\* | `PUT /listings/{listingId}/paymentmethods` | Payment methods usable for a listing |

## Webhooks

Management endpoints (all W except the GETs, since registering a hook
changes StubHub-side config):

| R/W | Endpoint | Purpose |
|---|---|---|
| R | `GET /webhooks`, `GET /webhooks/{webhookId}` | List / get |
| W | `POST /webhooks` | Create: `{ name, url, authorization_header, topics[] }` |
| W | `PATCH /webhooks/{webhookId}` | Update |
| W | `DELETE /webhooks/{webhookId}` | Delete |
| W | `POST /webhooks/{webhookId}/ping` | Send a Ping payload |

StubHub authenticates deliveries only by echoing the `authorization_header`
value you registered (no HMAC signature is documented). The receiving edge
function should compare it in constant time, the same way as
`requireCronSecret`.

Topics (payload: `{ topic, action, barcodes[], _links, _embedded: { event, sale, seller_listing, venue, webhook } }`):

| Topic | Fires when |
|---|---|
| Sales | A sale happens or changes |
| ProvisionalSale | Provisional sale. The Sales topic confirms it later; to refuse, ignore this and reject the confirmed sale |
| CancelProvisionalSale | A provisional sale is cancelled |
| SaleUpdates | Updates to an existing sale |
| SellerListingUpdates | A listing changes on StubHub's side |
| ReTransferTicket | Buyer didn't receive the ticket, so re-transfer from the 3rd-party provider |
| Ping | Test delivery |

## Client

`src/lib/marketplace/stubhub/` is a dependency-free, `fetch`-based client:

- `endpoints.ts`: all 81 endpoints above with their R/W tag. A test checks
  it against `text/*.txt`, so a doc refresh that adds an endpoint fails CI
  until the endpoint is tagged.
- `client.ts`: `StubHubClient` with a method for every **R** and **R\***
  endpoint Exos needs, plus `paginate()`, 429/5xx retry, and
  `clientCredentialsToken()` (cached OAuth2 client-credentials). It has **no
  write methods**, and its transport throws `UpstreamWriteForbiddenError` for
  any `write` entry before calling `fetch`.
- `webhook.ts`: `verifyWebhookAuthorization` (constant-time, fails closed),
  `parseWebhookPayload`, `normalizeTopic`.

The reference gives neither the API host nor the OAuth token URL. Both are
constructor arguments; take them from the StubHub account onboarding
(suggested env: `STUBHUB_API_BASE_URL`, `STUBHUB_TOKEN_URL`,
`STUBHUB_CLIENT_ID`, `STUBHUB_CLIENT_SECRET`).

## Mapping to Exos

- **Event xref:** `GET /catalog/events/external_mappings/{platform}/{id}` and
  `POST /catalog/mapevent` are the read-only way to fill a StubHub column in
  `bridge_event_xref`.
- **Oversell guard / reconcile:** `GET /sellerlistings/recentupdates`,
  `GET /sales/recentupdates`, and the `Sales` / `SellerListingUpdates`
  webhooks are the read side of `exos-distribute`'s reconcile loop.
- **Listing push** (`POST .../sellerlistings`, keyed by
  `externalsellerlistings/{externalId}` = our `exos_distribution_listings.id`)
  is the gated write path. It stays a TODO until the operator signs off.
