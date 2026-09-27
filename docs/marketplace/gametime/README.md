# Gametime API

Sources:
- The **Gametime API v3** reference (Swagger 2.0), supplied by the operator on 2026-09-27.
- The files it links to, fetched the same day and kept here:
  - the supplier onboarding guide (`pdf/`, and `text/` for grep);
  - the CSV column descriptions (`pdf/`, `text/`);
  - the example CSV (`examples/`);
  - the Postman collection (`openapi/`).

Servers:
- API: `https://api.gametime.co/v3`; staging `https://api-staging.gametime.co/v3`.
- Inventory FTP: `gtftp.gametime.co`; staging `gtftp-staging.gametime.co`, port 21.

What it covers:
- Orders ("purchases"): query, confirm, reject, and fulfil by barcodes, PDF or transfer confirmation.
- Listing quantity edits and deletes.
- New listings come only through a **CSV file on the FTP server**.
- There is no event search and no event creation.

Code: `supabase/functions/_shared/marketplace/gametime/`. The app reaches it through `src/lib/marketplace/gametime`.

## Auth

- **API key** in the query string, `?source={api_key}` (Gametime's only scheme). Secret: `GAMETIME_API_KEY`.
  - The key is added by the transport at the last moment.
  - It never appears in an error message, a log line or a planned request.
  - A docs link carrying `?source=…` carries the key; don't share one.
- **FTP:** a username and password from Gametime.
- **Sales webhook:** Gametime sends an `Authorization` header, Basic or Bearer depending on setup. Exos compares the whole header with `GAMETIME_WEBHOOK_AUTHORIZATION`.

## Endpoints

**Access** key:
- **R** = read, fine to call.
- **W** = writes to Gametime. Built in the writer, dry-run, and needs an operator `WriteAuthorization` to send (Hard Rule #2).
- **U** = the inventory upload. It also needs `dedicatedAccount: true` in the authorization (see below). The FTP upload itself isn't built.

| Endpoint | Access | Used by Exos | Notes |
|---|---|---|---|
| `GET /purchases` | R | sales poll, webhook check | `status` (unconfirmed / unfulfilled / completed / rejected), `completed` (true = done, false = open), `order_number`, `page`, `per_page`, `sort_by_created_at`. Returns `{ results, page, per_page, page_size }`. Results can include rejected purchases. |
| `POST /purchases/{n}/confirm` | W | delivery plan | "Only confirm if delivery is guaranteed." Optional body `{ seats: [...] }`. |
| `POST /purchases/{n}/reject` | W | | |
| `POST /purchases/{n}/barcode_upload` | W | | `{ seats: { "<seat>": { barcode } } }` for `delivery_type` barcode. |
| `POST /purchases/{n}/confirm_transfer` | W | delivery plan | Multipart: `transfer_url[]` (repeatable), `screenshot[]`, `transfer_type` (`generic`, `sg`, `stubhub`, `ticket_master`, …), `transaction_id`. For `mobile` / `flashseats`. |
| `POST /purchases/{n}/pdf_upload` | W | | Base64 PDF, one page per seat. |
| `POST /listings/{id}` | W | listing sync | `{ quantity, lots }`: lots are the purchasable quantities; `quantity: 0` removes the listing. Optional TDC ids. |
| `DELETE /listings/{id}/delete` | W | delist plan | |
| FTP upload of the inventory CSV | U | inventory file plan | The account's whole inventory, at least every 6 hours. |

## Facts from the docs

| Topic | What Gametime says |
|---|---|
| Listing ingestion | A CSV uploaded to the FTP server, "repeated at least as often as your inventory updates". **If no file arrives for six hours, every listing on the account is disabled** until the next upload (the "heartbeat"). |
| CSV columns | `Edit`, `Event`\*, `Venue`\*, `EventDate`\* (M/D/YY), `EventTime`\* (3:00 PM), `Quantity`\*, `Section`\*, `Row`\*, `SeatFrom`, `SeatThru`, `Notes`, `Cost`\* ("GT cost to purchase ticket"), `TicketID`\*, `edelivery_ind`\* (Y/N), `InHandDate`, `Instant`\* (Y/N), `Splittype` (NEVERLEAVEONE / CUSTOM / NOSPLIT / TOGETHER / ANY), `Splitvalue` (e.g. `2:4`), `FaceValue`, `Stock` (mobile_transfer / mobile_screencap / eticket / commemorative), `Discount` (promo fee %), `ZonePrice`. \* required. `Edit` appears in the example file (`y`) but isn't described. |
| After a sale | The seller is notified by webhook and email. Check the purchase **status** first; `rejected` means stop (it's there for reconciliation). Then confirm or reject, then fulfil as the listing specified. |
| Statuses | `unconfirmed` (confirm or reject), `unfulfilled` (confirmed, awaiting delivery), `completed`, `rejected`. |
| Sales webhook | JSON, money in cents: `id`, `source_id` (our listing id), `quantity`, `unit_price`, `payout`, `event_id`, `event_name`, `event_date`, `venue`, `section`, `row`, `fulfill_type`, `deal`. Any 2xx is fine. It doesn't affect the order. |
| Purchase fields | `id`, `status`, `created_at`, `purchased_at` (`ISODate(…)`), `quantity`, `listing_reference_id`, `price` (cents), `seats`, **`email`**, `phone`, `first_name`, `last_name` (the transfer recipient), `delivery_type`, event, venue, section, row. |
| Test orders | Suppliers can't create them; ask the Gametime contact. Use staging for testing. |

## How Gametime ties into Exos

It uses the same marketplace sync as StubHub and SeatGeek (mig `20260927040000`, see `docs/marketplace/README.md`):

1. **Tick and publish.** Ticking Gametime and publishing queues its event row. There is nothing to link or create: listings carry the event name, venue and date.
2. **Allocate.** Fill in the Gametime column of the Marketplaces grid. Exos stops selling those seats.
3. **List (planned).**
   - `exos-distribute` plans each allocation as listings of at most the event's max per order, so no order can take more. Each listing is a block of the allocation's internal seat numbers (`SeatFrom`/`SeatThru`), with row `GA`, `Stock` `mobile_transfer`, `Splittype` `ANY`, and `TicketID` = `ex<base32 allocation id><n>`. Listing numbers stay the same across re-plans.
   - Every run also plans the **complete inventory file** from all Gametime listings of published events, the heartbeat Gametime needs.
4. **Sell.**
   - The sales webhook (`?channel=gametime` on `exos-marketplace-sales`) reads the purchase by order number before acting.
   - Polling reads every open purchase (`completed=false`) plus a rolling recheck of known ones, so a later rejection still arrives.
   - The recipient's email comes on the purchase; Exos stores it in its own column and strips it, along with phone, names and barcodes, from the saved raw record.
   - Exos mints the tickets and emails the buyer the claim links. The tickets get internal seats from the listing named on the purchase.
5. **Deliver (planned).**
   - First `POST /confirm` (the tickets exist, so delivery is guaranteed).
   - Then `POST /confirm_transfer` with one Exos claim link per ticket as `transfer_url[]`, and `transfer_type` `generic`.
6. **Pull back.** Delist, then release, as on the other marketplaces: live listings get a `DELETE /listings/{id}/delete` plan and drop out of the next file.

Nothing is sent to Gametime: files, listing edits and order updates are all dry-run.

## Which account: dedicated only

Each inventory file stands for the whole account's listings, and missing the six-hour heartbeat switches every listing off. So Exos may only upload a file to a Gametime account that holds **Exos listings alone**.

On an account shared with broker inventory, an Exos file would take over the broker's listings. Exos would then have to hand its rows to the broker's existing feed instead.

`GametimeWriter.uploadInventory` refuses to go live without `dedicatedAccount: true` in the `WriteAuthorization`. The operator's answer so far: **not sure yet**.

## Still open

| Question | Where it matters |
|---|---|
| Separate Exos Gametime account, or the broker's? | inventory file (see above) |
| Does Gametime accept non-numeric `TicketID`s (`ex…`)? Its examples are numeric. | inventory file (`unresolved`) |
| Is `price` on a purchase per ticket or the order total? (Exos takes proceeds from the webhook's `payout`.) | sales |
| Is the Exos claim link accepted as a `generic` transfer URL? | delivery |
| Can the FTP upload run from Supabase edge functions (plain FTP, port 21), or does it need another host? | going live |
| Rate limits (not documented). Reads retry 429/502/503/504; writes retry 429 only. | client, writer |

## Write roadmap

`GAMETIME_WRITE_ROADMAP` in `gametime/writer.ts`:

| # | Phase | Endpoints |
|---|---|---|
| 1 | Inventory file (dedicated account only) and a heartbeat under 6 hours | `uploadInventory` |
| 2 | Listing management between files | `editListing`, `deleteListing` |
| 3 | Orders: confirm, then confirm the transfer with the claim links | `confirmPurchase`, `rejectPurchase`, `confirmTransfer` |

Going live needs:
- the account question answered;
- `GAMETIME_API_KEY`, the FTP credentials and `GAMETIME_WEBHOOK_AUTHORIZATION` (plus the webhook URL registered with Gametime);
- test orders on staging from the Gametime contact;
- the FTP upload built;
- a recorded operator `WriteAuthorization` naming exactly the endpoints.
