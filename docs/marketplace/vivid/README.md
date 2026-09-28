# Vivid Seats Broker Portal API

Source: the **Broker Portal API 1.0.0** OpenAPI 3.0.1 spec, pasted by the
operator on 2026-09-28 and saved as
[`openapi/broker-portal-api.json`](openapi/broker-portal-api.json). Server:
`https://brokers.vividseats.com/webservices`.

Code: `supabase/functions/_shared/marketplace/vivid/`. The app uses it
through `src/lib/marketplace/vivid`.

## Auth

The token is `VIVID_API_TOKEN`. Where it goes depends on the API generation:
- **v2 listings and events:** the `Api-token` header.
- **v1 orders:** an `apiToken` query parameter on a GET, or a form field on a POST.

Every call may also carry `X-Integrator-Token` (`VIVID_INTEGRATOR_TOKEN`, if
Vivid issues one for the integration).

The transport adds the token only when it sends a request. It never appears in
a planned request, and errors name the endpoint's path, not the URL. Any echo
of the token in a response body is redacted before it's kept.

## Endpoints

Access:
- **R**: read, fine to call.
- **W**: writes to Vivid Seats. Built in the writer, dry-run, and needs an
  operator `WriteAuthorization` to send (Hard Rule #2).
- **✖**: forbidden. Never sent, whatever the authorization.

| Endpoint | Access | Format | Used by Exos | Notes |
|---|---|---|---|---|
| `GET /events/search` | R | JSON | event linking | By `eventKeyword` / `venueKeyword` and `fromDate` + `toDate` (together). At most 1000 results with a keyword. `eventId` is the listings' `productionId`. **One request every 5 s.** |
| `GET /events/inventory/search` | R | JSON | | Events with your inventory. One request every 5 s. |
| `POST /listings/v2/create` | W | JSON | listing plan | `eventName`, `venue` and `eventDate` (venue-local) are required. `productionId` is optional; without it, "the create listing request may be sent to our mapping team". 50 per second. |
| `GET /listings/v2/get` | R | JSON | update read-back | By `internalTicketId` (our id), `listingId`, `productionId` or event dates. 10 per second. |
| `PUT /listings/v2/update` | W | JSON | update | "All the fields … will be updated with the object passed in", keyed by Vivid's `id`. So the writer reads the listing back by our ticketId first. |
| `DELETE /listings/v2/delete` | W | JSON | delist | By `internalTicketId` only. The `listingId` form is never used. |
| `GET /listings/v1/getListings` | R | XML | | Deprecated. One request per ticketId every 2 min. |
| `POST /listings/v1/updateListing`, `GET /listings/v1/deleteListing` | ✖ | XML | | Deprecated v1 writes; the delete is even a GET. Exos keeps to one write path (v2, by our id). |
| `GET /v1/getOrders` | R | XML | sales poll | `status`: only `UNCONFIRMED` or `PENDING_SHIPMENT` are returned. One request every 10 s per status, 60 s for `PENDING_SHIPMENT`. `pageSize` (≤ 10000) and `bookmark`. |
| `GET /v1/getOrder` | R | XML | recheck | Not rate-limited. |
| `GET /v1/getCompletedOrders`, `/v1/getPendingRetransferOrders` | R | XML | | One request every 10 s and 60 s respectively. |
| `POST /v1/confirmOrder` | W | form → XML | delivery plan | `orderId`; `seatNumbers`. Failures come back as HTTP 200 with `success: false`. |
| `POST /v1/transferOrderViaURL` | W | form → XML | delivery plan | `orderId`, `transferURLList[]`, `transferSource`, `transferSourceURL`. |
| `POST /v1/rejectOrder` | W | form → XML | | |
| `POST /v1/transferOrder`, `/transferOrderWithMobileQR`, `/moveMobileOrderToElectronicTransfer`, `/shipOrder` | W | form → XML | | Other delivery types. Not used. |
| `POST /v1/orders/{orderId}/integratedTransfer` | W | JSON | | Integrated (MLB / CBC) transfers. Not used. |
| `GET /v1/payments`, `/v1/payments/{id}`, `/v1/getPurchaseOrder`, `/v1/getAirbill` | R | XML / JSON | | |

Unlike SeatGeek, GoTickets and Gametime, this API has no account-wide or
bulk-destructive endpoint. The risk that remains is addressing a broker
listing by mistake, so the writer:
- refuses any `ticketId` that isn't an Exos `ex…` id;
- never deletes by `listingId`;
- only sends an update whose Vivid `id` came from reading back our own ticketId.

## Facts from the spec

| Topic | What the spec says |
|---|---|
| Listing (ManagedBrokerListingDoc) | `ticketId` (ours), `productionId`, `quantity`, `section`, `row`, `seatFrom` / `seatThru`, `hideSeats`, `notes`, `price`, `faceValue`, `inHandDate` (date-time), `splitType` (DEFAULT / ANY / CUSTOM / NEVERLEAVEONE), `stockType` (ELECTRONIC, FLASH, TMET, MOBILE_SCREENCAP, HARD, PAPERLESS…), `electronic`, `electronicTransfer`, `eventName`, `venue`, `venueCity` / `Region` / `CountryCode`, `eventDate` ("the Venue local timezone"), `priceCurrency`. |
| Order (XML) | `orderId`, `orderToken`, `brokerTicketId` (our ticketId), `listingId`, `productionId`, `eventId`, `quantity`, `cost` ("per ticket and the amount the seller will be paid"), `status` (UNCONFIRMED, PENDING_SHIPMENT, COMPLETED, VERIFICATION, PENDING_RESERVATION), `orderDate`, `expectedShipDate`, `emailAddress`, `firstName` / `lastName` / `mobilePhoneNumber`, `seats` (`<seats><seat>1</seat>…</seats>`), `transferViaURL`. |
| Webhooks | None. Polling only. |

## How Vivid Seats ties into Exos

Same marketplace sync as the others (migration `20260928030000`; see
`docs/marketplace/README.md`).

1. **Tick and publish.** This queues the Vivid Seats event row.
2. **Link** (`exos-distribute` pass 0, only when `VIVID_API_TOKEN` is set).
   - Exos searches `GET /events/search` by the event name and its venue-local
     day. Searches are spaced 5 s apart by the client, with at most 6 per run.
   - The usual scorer links it, sends it to staff review, or leaves it
     unmatched.
   - A linked event's id goes on the listings as `productionId`. Without one,
     Vivid's mapping team matches the listings, which can take a while.
3. **Pool.** The Vivid Seats column in the Marketplaces grid sets the cap.
   Vivid Seats holds 2 × the max per order at a time, topped up from free
   seats.
4. **List (planned).** The Exos listings:
   - blocks of at most the max per order;
   - `ticketId` = the `ex…` listing id;
   - `seatFrom` / `seatThru` = the block's internal seats, with `hideSeats` on;
   - row `GA`, `splitType` ANY;
   - `stockType` ELECTRONIC with `electronic` and `electronicTransfer`;
   - `price` / `faceValue` in USD;
   - `inHandDate` = the event day;
   - `eventDate` = the venue-local start (without it, the plan fails and asks
     for the event's timezone).

   Plans are created one at a time, updated with a full PUT (after the
   read-back), and deleted by `internalTicketId`.
5. **Sell (polling).**
   - Each `exos-marketplace-sales` run reads `getOrders` for `UNCONFIRMED`
     and `PENDING_SHIPMENT`, one call each. If one fails, the run goes on and
     the next run tries again.
   - It also rechecks known orders with `getOrder`.
   - `cost × quantity` is the payout. The buyer email is on the order. Names
     and phone numbers are stripped from the stored raw copy.
   - Tickets take seats from the listing's own block.
6. **Deliver (planned).** `confirmOrder` with the tickets' internal seats in
   `seatNumbers`, then `transferOrderViaURL` with:
   - `transferURLList` = one Exos claim link per ticket;
   - `transferSource` = `Exos`;
   - `transferSourceURL` = the app's origin.
7. **Pull back.** Delist, then release: `DELETE /listings/v2/delete?internalTicketId=` per listing.

Nothing is sent to Vivid Seats.

## Still open

| Question | Where it matters |
|---|---|
| Does Vivid accept an Exos claim link through `transferOrderViaURL`, and what should `transferSource` / `transferSourceURL` say? | delivery |
| What date format does `events/search` take for `fromDate` / `toDate`? Exos sends `YYYY-MM-DDTHH:MM:SS`, venue-local. | linking |
| How does a cancelled order show? No cancelled status is documented, and `getOrders` returns only open orders. Exos logs a recheck that returns nothing and leaves it to a human. | sales |
| Is an `X-Integrator-Token` needed for this integration? | auth |
| Separate Exos account or the broker's? Either works, as long as the writer's ticketId checks hold. | account |

## Write roadmap

`VIVID_WRITE_ROADMAP` in `vivid/writer.ts`:
1. Listings by our ticketId: create, update (after read-back), delete.
2. Orders: confirm, transfer via URL with the claim links, reject.

Going live needs:
- `VIVID_API_TOKEN` (and `VIVID_INTEGRATOR_TOKEN` if issued);
- the migrations applied and the functions deployed;
- a recorded operator `WriteAuthorization` naming exactly the endpoints.
