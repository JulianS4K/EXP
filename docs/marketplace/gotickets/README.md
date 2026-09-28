# GoTickets Seller Central API

Source: the **Seller Central API v1** OpenAPI 3.0.1 spec
(`https://sc.gotickets.com/api/open-api`), pasted by the operator on
2026-09-28. Server: `https://sc.gotickets.com`. The spec also points to a
"seller handbook" (for split types, stock types, flex listings), which we
don't have.

Code: `supabase/functions/_shared/marketplace/gotickets/`. The app uses it
through `src/lib/marketplace/gotickets`.

## Auth

Two headers on every request: `X-Api-Access-Id` and `X-Api-Access-Secret`
(secrets `GOTICKETS_ACCESS_ID` and `GOTICKETS_ACCESS_SECRET`). They never go
into a URL, an error message or a planned request.

## Endpoints

Access:
- **R**: read, fine to call.
- **W**: writes to GoTickets. Built in the writer, dry-run, and needs an
  operator `WriteAuthorization` to send (Hard Rule #2).
- **✖**: forbidden. Never sent, whatever the authorization.

| Endpoint | Access | Used by Exos | Notes |
|---|---|---|---|
| `POST /rest/listings` | W | listing plan | Up to 100 listings. The response splits them into `mappedListings`, `unmappedListings` and `errors`. |
| `POST /rest/listings/single` | W | | Returns 200 when mapped, 201 when not yet mapped to a GoTickets event. |
| `GET` / `PUT` / `DELETE` `/rest/listings/external-id/{externalId}` | R / W / W | update, delist | Keyed by our listing id. A PUT replaces the whole listing: no partial updates. |
| `DELETE /rest/listings/external-id` | W | delist plan | Up to 100 external ids per request. Missing ids fail silently. |
| `GET /rest/listings/bulk/snapshot/unmapped`, `GET /rest/listings/last-success-time` | R | | |
| `GET /rest/listings/{id}` | R | | |
| `PUT` / `DELETE /rest/listings/{id}`, `PUT` / `DELETE /rest/listings` | ✖ | | Keyed by GoTickets' own listing id. Exos addresses its listings only by `externalTicketId`. |
| `POST /rest/listings/bulk/snapshot` | ✖ | | "A snapshot of your entire inventory." On an account that also holds broker inventory, it would replace the broker listings. |
| `DELETE /rest/listings/by-event-id` | ✖ | | Deletes every listing for an event, the broker's included. |
| `GET /rest/sales`, `GET /rest/sales/{orderId}`, `GET /rest/sales/unconfirmed` | R | sales poll, webhook read-back | Filters: `orderTimeFrom` / `orderTimeTo` (`2023-01-01T00:00:00`), `sellerStatuses`, `externalTicketId`, … |
| `POST /rest/sales/{orderId}/confirm`, `/fulfill`, `/reject` | W | delivery plan | Fulfil with `{ method: "SUBMIT_TRANSFER_URL", transferUrl: [...] }`. |
| `POST /rest/sales/{orderId}/re-transfer` | W | | |
| `GET` / `POST /rest/webhooks`, `PUT` / `DELETE /rest/webhooks/{id}` | R / W | webhook setup | At most 3 webhooks per type. Types: `SALE`, `ORDER_CANCELLED`, `PURCHASE_CONFIRMED`, `PURCHASE_FULFILLED`, `RETRANSFER`, `HOLD`, `ORDER_EMAIL_ADDRESS_UPDATED`, `IN_HAND_DATE_CHANGE_REQUEST`. |
| `GET /rest/events`, `/rest/events/{id}`, `/rest/events/delta` | R | | Events updated in a time window. There's no name search. |
| `GET /rest/payments` | R | | |

## Facts from the spec

| Topic | What the spec says |
|---|---|
| Listing, required fields | `externalTicketId` (≤ 100 chars), `price` (unit asking price), `row` (≤ 20 chars), `splitType` (DEFAULT / ANY / NEVER_LEAVE_ONE / CUSTOM / NO_SPLIT), `stockType` (HARD / MOBILE_TICKETS / PRINT_AT_HOME / WALK_IN / AXS_TRANSFER). |
| Listing, other fields | `section`, `lowSeat` / `highSeat`, `notes`, `quantity`, `instant`, `inHandDate`, `faceValue`, `eventId`. When `eventId` is missing, GoTickets maps the listing from `eventName`, `venueName` and `eventDateTime`, and it also takes `stubhubEventId`, `seatgeekEventId` and other marketplace ids. A listing it hasn't mapped yet is "unmapped": still there, addressable only by `externalTicketId`. |
| Sale | `id` (the order id), `sellerStatus` (UNCONFIRMED, PENDING_FULFILLMENT, COMPLETED, PENDING_TRANSFER_PROOF, …, FRAUD_HOLD), `cancelReason` (REJECTED / CANCELLED), `quantity`, `externalTicketId`, `customerEmailAddress`, `totalPayout`, `event.id`, `section`, `row`, `lowSeat`, `highSeat`. |
| Webhook payload | `id`, `externalTicketId`, `section`, `row`, `payout`, `quantity`, `deliveryMethod`, `createTime`, `type`. **No signature or auth header is documented.** |

## How GoTickets ties into Exos

Same marketplace sync as the others (migration `20260928020000`; see
`docs/marketplace/README.md`).

1. **Tick and publish.** This queues the GoTickets event row. There's nothing
   to link or create: GoTickets maps listings to its events itself. Exos
   sends the event name, venue and start time, plus the StubHub and
   SeatGeek event ids when Exos has them linked.
2. **Pool.** The GoTickets column in the Marketplaces grid sets the cap.
   GoTickets holds 2 × the max per order at a time, topped up from free seats.
3. **List (planned).** The Exos listings:
   - blocks of at most the max per order;
   - `externalTicketId` = the `ex…` listing id;
   - `lowSeat` / `highSeat` = the block's internal seats, row `GA`;
   - `splitType` ANY, `stockType` MOBILE_TICKETS, `price` / `faceValue`;
   - `inHandDate` = the event day.

   Plans are created in batches of up to 100, updated with a full PUT by
   external id, and deleted by external id 100 at a time.
4. **Sell.**
   - **Polling:** sales placed in the last 6 hours, every unconfirmed sale,
     and a rolling recheck of known orders.
   - **Webhooks** carry our own token (secret `GOTICKETS_WEBHOOK_TOKEN`),
     because GoTickets doesn't sign them. Exos takes it from the
     `X-Exos-Webhook-Token` header, then `Authorization: Bearer …`, then the
     target URL's `?token=` (`exos-marketplace-sales?channel=gotickets&token=…`).
     Prefer a header when GoTickets lets the webhook carry one: a query-string
     secret can land in proxy and platform access logs. Exos never logs the
     request URL. The payload is only a pointer: Exos reads the sale back
     from the API before recording anything.
   - The buyer email comes from the sale. Names, phone and files are
     stripped from the stored raw copy.
   - Tickets take seats from the listing's own block.
5. **Deliver (planned).** `POST /confirm`, then
   `POST /fulfill { method: SUBMIT_TRANSFER_URL, transferUrl: [one Exos claim link per ticket] }`.
6. **Pull back.** Delist, then release: `DELETE /rest/listings/external-id`
   with our ids.

Nothing is sent to GoTickets.

## Still open

| Question | Where it matters |
|---|---|
| Does GoTickets accept an Exos claim link as a `SUBMIT_TRANSFER_URL`, and does it then ask for transfer proof (`PENDING_TRANSFER_PROOF`)? | delivery |
| Is `eventDateTime` read as UTC or venue-local? (Exos sends the UTC instant.) | listing mapping |
| Webhook authentication: will GoTickets sign deliveries, or is our token in the URL the way to do it? | webhooks |
| Rate limits (`429` is documented but the limits aren't). Reads retry 429 / 502 / 503 / 504; writes retry 429 only. | client, writer |
| Separate Exos account or the broker's? Either works with per-listing calls, as long as the forbidden endpoints stay forbidden. | account |

## Write roadmap

`GOTICKETS_WRITE_ROADMAP` in `gotickets/writer.ts`:
1. Listings by external id: create, update, delete.
2. Sales: confirm, fulfil with the claim links, reject.
3. Webhooks: `SALE` and `ORDER_CANCELLED`, sent to `exos-marketplace-sales`.

Going live needs:
- `GOTICKETS_ACCESS_ID`, `GOTICKETS_ACCESS_SECRET` and `GOTICKETS_WEBHOOK_TOKEN`;
- the migrations applied and the functions deployed;
- a recorded operator `WriteAuthorization` naming exactly the endpoints.
