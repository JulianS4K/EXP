# DICE coverage: DICE's partner API, field by field, in Exos

DICE's partner API (the Ticket Holders API, GraphQL at `https://partners-endpoint.dice.fm/graphql`, a
Bearer token generated in MIO) is how a promoter gets data **out** of DICE: events, tickets and holders,
orders, returns, transfers, extras, genres. It is read only. This doc maps every DICE type and field to
its Exos equivalent, and says where a DICE import puts it.

Two columns matter for each field:

- **Exos** is where Exos keeps the same thing for its own sales: a table and column, an RPC or a
  partner API route (`/v1/...`, docs/api-reference.md).
- **Import** is where "Import from DICE" (mig `20261106100000`, `exos-dice-import`,
  `_shared/dice/`) puts the value DICE sends.

Status: **existing** (Exos had it before the import), **built** (added by the import), **planned** (a
numbered item in KANBAN.md "DICE gaps 2026-11-05"), **n/a** (not applicable, with the reason).

## How the import works

1. An owner or manager pastes the MIO token in Org settings → Integrations → Import from DICE. Exos
   checks it with `viewer { id name }` and stores it in Vault (`exos_dice:<org>`), exactly as the
   Eventbrite token is stored. No client role can read it back: `exos_dice_connections` has no client
   grant on `secret_id`, and only the service role can call `exos_dice_sync_claim` / `exos_dice_dry_run_begin`.
   Before the pasted token is sent to DICE at all, the database checks the caller is an owner or manager
   and within 10 connect attempts an hour (per org and per user), so Exos can't be used to test tokens.
2. **Preview** is a dry run: the same reads, counts only, nothing written but the run's log row, which
   is reserved before the first read (one preview at a time, none while a sync runs, 5 a minute).
3. **Import** runs `events`, then `tickets`, `orders`, `returns` and `transfers`, 50 per page, at most
   40 pages per entity and 5,000 rows per run; a run that hits a cap resumes from DICE's `endCursor`
   next time. After the first full pass every sync is incremental: `events` by `updatedAt`, `orders` by
   `purchasedAt`, `returns` by `returnedAt`, `transfers` by `transferredAt` (each `gte` the last pass's
   start minus 5 minutes). DICE's `TicketWhereInput` has no date filter, so `viewer.tickets` is read in
   full once; new tickets then arrive inside orders and new holders inside transfers. An hourly schedule
   (`exos-dice-import-sync-hourly`) exists but is created **inactive**.
4. Everything is keyed in `exos_dice_id_map` (org, entity, DICE id) → Exos id, so a re-run updates in
   place and never duplicates.
5. The whole feature is behind `EXOS_DICE_IMPORT=on` (503 otherwise) and only ever sends GraphQL
   **queries**: `_shared/dice/client.ts` parses each document and refuses any `mutation` or
   `subscription` before sending.

What a promoter gets:

- **Events.** Each upcoming DICE event becomes a **draft link-out event** (`exos_events.link_out`,
  `ticket_backend = 'dice'`, `primary_source = 'dice'`, an `exos_event_imports` row with `platform =
  'dice'`). Exos lists it once the promoter publishes it and sends buyers to the DICE page; it never sells
  that inventory (every Exos sell table refuses a row for a link-out event, mig `20261029170500`). A DICE
  event that is over, archived or cancelled is recorded in the id map and not created.
- **The door.** Each DICE ticket of an imported event becomes an entry on the event's `DICE` guest list
  (`exos_guest_list_entries`: `source = 'DICE'`, `external_ref = 'dice:<id>'`, `external_code` = the DICE
  `code`). The Exos door downloads those codes for offline use (`exos_event_door_extras`), finds a scanned
  one online with `exos_door_code_lookup` (exact, then without punctuation) and admits it once through
  `exos_guest_check_in`. So a holder's DICE barcode scans at the Exos door. A DICE return voids the entry
  (`voided_at`, `void_reason = 'returned on DICE'`): the door refuses it, by scan or by name, offline too.
- **Fans.** Buyers and holders become `exos_fans` (source `dice`). Marketing consent (the org's email
  list: `email_opt_in_at`, source `dice:optInPartners`) is set **only** when DICE's `optInPartners` is
  `true`, and never over an Exos unsubscribe. If DICE later says `false`, the DICE-sourced consent is
  withdrawn. Everyone else is a ticket holder without marketing consent.

## Viewer

| DICE field | Exos | Import | Status |
|---|---|---|---|
| `id`, `name` | the organization (`exos_orgs`) | `exos_dice_connections.account_id` / `account_name` | built |
| `events` | `exos_events`, `GET /v1/events` | draft link-out events (below) | built |
| `tickets` | `exos_tickets`, `GET /v1/tickets`, `GET /v1/events/:id/attendees` | `DICE` door list entries | built |
| `extras` | `exos_event_addons`, `GET /v1/events/:id/add-ons` | kept on each ticket (`exos_dice_id_map.data.extras`) | built (as data); see Extra |
| `orders` | `exos_checkout_sessions`, `GET /v1/orders` | `exos_dice_orders` | built |
| `returns` | `exos_order_refunds`, `GET /v1/refunds` | voids the door entry; `exos_dice_id_map` entity `return` | built |
| `ticketTransfers` | `exos_transfers`, `/v1/me/transfers` | the door entry follows the new holder | built |
| `genreTypes` | `exos_tags` / `exos_canonical_tags`, `GET /v1/tags` | event `data.genre_types` | planned (5) |
| connections: `first` / `after` / `where` / `totalCount` / `pageInfo` | `?page` / `?per_page` and `meta.total` on every list | the client pages with `first` ≤ 50 and `after`; `totalCount` shown in the preview | built |

## Event

| DICE field | Exos | Import | Status |
|---|---|---|---|
| `id` | `exos_events.id` | `exos_dice_id_map` (entity `event`); `exos_event_imports.source_event_id` | built |
| `eventIdLive` | n/a | `exos_dice_id_map.data.live_id` | built (as data) |
| `name` | `exos_events.name` | `name` on create; the promoter's later edits are kept | built |
| `state` | `exos_events.status` | CANCELLED cancels the Exos event; ARCHIVED or over: not created; source status in `exos_event_imports.source_status` | built |
| `announceDatetime` | `exos_events` announce / publish time | `data.announce_at` | built (as data) |
| `onSaleDatetime` / `offSaleDatetime` | ticket type sale windows (`exos_ticket_tiers`) | `data`; `offSale` in the past → source status not `on_sale` | built (as data) |
| `startDatetime` / `endDatetime` | `exos_events.starts_at` / `ends_at` | set on create; a DICE reschedule moves them (`previous_starts_at` kept) | built |
| `description` | `exos_events.description` | set on create | built |
| `hidden` | unlisted / draft events | `data.hidden`; every import is a draft anyway | built (as data) |
| `totalTicketAllocationQty` | `exos_events.total_tickets` | `data.allocation` (link-out events sell nothing, so `total_tickets` stays 0) | built (as data) |
| `currency` | `exos_events.currency` | `currency` (lower case), `exos_event_imports.currency` | built |
| `url` | `external_ticket_url` (where to buy) | `external_ticket_url`, `exos_event_imports.source_url` (`https://dice.fm` when DICE sends none) | built |
| `updatedAt` | `updated_at` | the incremental filter | built |
| `artists` | `exos_artists`, lineups (`GET/PUT /v1/events/:id/lineup`) | `data.artists` (names) | existing in Exos; linking imported names to artists is n/a for now (DICE sends names only, no ids) |
| `genres` / `genreTypes` | tags (`exos_tags`, canonical tags) | `data.genres`, `data.genre_types` | planned (5): genre filter |
| `images` | `exos_events.image_url` | the LANDSCAPE image (else the first), https only; all in `data.images` | built |
| `ticketTypes` | `exos_ticket_tiers`, `/v1/events/:id/ticket-types` | display only: `exos_event_imports.ticket_types` (name, price range); full rows in `exos_dice_id_map` (entity `ticket_type`) | built |
| `ticketPools` | `exos_quotas` (shared limits across ticket types) | `data.ticket_pools` | existing (quotas); planned (3) shared capacity |
| `venues` | `exos_events.venue_name` / `venue_address`, `exos_venues`, `/v1/venues` | the first venue's name and address; all in `data.venue` / `data.venue_count` | built |
| `venueSpace` | `exos_venue_rooms` (`/v1/venues/:id/rooms`) | `data.venue_space` | built (as data) |
| `products` | `exos_event_addons` | `data.products` | built (as data) |
| `tickets` (Event.tickets) | `/v1/events/:id/attendees` | not used: `viewer.tickets` covers every event in one pass | n/a (same data) |
| `extras` (Event.extras) | `/v1/events/:id/add-ons` | not used: extras come on each ticket | n/a (same data) |
| `socialLinks` | promo links (vouchers with a channel label, `exos_promo_links`) | `data.social_links` | built (as data) |
| `promoters` | `exos_promoters`, co-hosts (mig 20261104180000) | `data.promoters` | built (as data) |

## TicketType and PriceTier

| DICE field | Exos | Import | Status |
|---|---|---|---|
| TicketType `id`, `name`, `description` | `exos_ticket_tiers.id` / `name` / `description` | `exos_dice_id_map` (entity `ticket_type`, `data`); name as the door entry's `ticket_label` | built |
| `totalTicketAllocationQty` | `exos_ticket_tiers.capacity` | `data.allocation` | built (as data) |
| `archived` | tier `visibility` / closed | archived types left out of the display list | built |
| `faceValue`, `price`, `doorSalesPrice` | `exos_ticket_tiers.price` (all-in), box office price | `data` in cents; `price` (else tiers) is the display price range | built; door price planned (4) |
| `priceTierType`, `priceTiers` | `exos_ticket_tiers.price_schedule` (date steps) | `data.price_tiers` | existing (date steps); planned (4) quantity steps |
| PriceTier `id`, `name`, `allocation`, `time`, `faceValue`, `price`, `doorSalesPrice` | as above | `data.price_tiers[]`; the ticket's tier in the ticket's `data.price_tier` | planned (4) |
| `externalSkus` | n/a | `data.external_skus` | n/a (no warehouse integration) |
| `ticketPoolId` | `exos_quota_tiers` | `data.ticket_pool_id` | existing; planned (3) |

## Ticket

| DICE field | Exos | Import | Status |
|---|---|---|---|
| `id` | `exos_tickets.id` | `exos_dice_id_map` (entity `ticket`) → `exos_guest_list_entries.id`; `external_ref = 'dice:<id>'` | built |
| `code` | Exos's rotating HMAC barcode (`exos_tickets.barcode_secret`, never exported) | `exos_guest_list_entries.external_code`: scanned at the Exos door | built |
| `fullPrice`, `commission`, `diceCommission`, `total` | `price_paid`, fees (`exos_event_fee_terms`), `/v1/orders` amounts | `data.*_cents` | built (as data) |
| `fees` (`TicketFee`: `category`, `promoter`, `dice`) | fee rules (`/v1/events/:id/fee-rules`), all-in price | `data.fees` | built (as data) |
| `holder` (Fan) | the ticket's owner / `attendee_name` | the entry's name, email and phone; a fan profile | built |
| `ticketType` | `exos_tickets.tier_id` | `ticket_label`; resolves the event | built |
| `seat` | `exos_event_seats` (`/v1/events/:id/seats`) | `data.seat` | built (as data) |
| `claimedAt` | free-ticket claims and transfers (`exos_transfers`) | `data.claimed_at` | built (as data) |
| `priceTier` | the tier price step | `data.price_tier` | planned (4) |
| `address` | n/a | not asked for | n/a (Exos keeps no postal address for fans; DICE uses it for merch shipping) |
| `fanSurveyAnswers` (`fanSurveyQuestion.title`, `value`) | checkout questions | `data.survey_answers` | planned (2): checkout questions, then shown with the answers |
| `extras` | `exos_event_addons` on the order | `data.extras` (id, code, separate barcode, product) | built (as data); separate add-on barcode planned (6) |

## Extra, Product, Variant

| DICE field | Exos | Import | Status |
|---|---|---|---|
| Extra `id`, `code`, `fullPrice`, `commission`, `diceCommission`, `total`, `fees` | `exos_event_addons`, add-on lines on the order | the ticket's `data.extras` (id, code) | built (as data) |
| `hasSeparateAccessBarcode` | `exos_event_addons.separate_access_barcode`; each unit an `exos_addon_passes` code (A-), scanned at a check-in list with `admits` add-ons | `data.extras[].separate_barcode` | built (mig 20261107110000) |
| `holder`, `product`, `ticket`, `variant` | add-on → order → ticket | `product` name kept | built (as data) |
| Product `id`, `name`, `description`, `totalAllocationQty`, `archived`, `faceValue`, `externalSku`, `ticketTypes` | `exos_event_addons` | event `data.products` | built (as data) |
| Variant `id`, `name`, `size`, `sku`, `externalSku` | n/a | not asked for | n/a (no merch variants in Exos) |

## Order

| DICE field | Exos | Import | Status |
|---|---|---|---|
| `id` | `exos_checkout_sessions.id`, `GET /v1/orders/:id` | `exos_dice_orders.dice_id` | built |
| `purchasedAt` | `created_at` / fulfilled time | `purchased_at`; the incremental filter | built |
| `quantity` | ticket count | `quantity`; `tickets` | built |
| `salesChannel` (INTERNET, DOOR, FREE, EXTERNAL) | `exos_tickets.channel_source`, box office (`exos_pos_*`), free claims | `sales_channel` | built |
| `fullPrice`, `commission`, `diceCommission`, `total`, `fees` | order amounts and the payment ledger | `full_price_cents`, `commission_cents`, `dice_commission_cents`, `total_cents`, `fees` | built |
| `ipCity`, `ipCountry` | n/a (Exos doesn't geolocate IPs) | `ip_city`, `ip_country` | built; buyer location from the card's billing address planned (5) |
| `event` | `event_id` | `dice_event_id`, `event_id` | built |
| `fan` | the buyer (`buyer_email`, `exos_fans`) | `fan_id`, `dice_fan_id`; a fan profile | built |
| `tickets` | the order's tickets | door entries (same as Ticket) | built |
| `returns` | refunds | voids the entries (same as Return) | built |
| `adjustments` (`reason`, `processedAt`, `ticket`, `feesChange`) | order edits (`exos_order_edits`) | `adjustments` | built (as data); a fee-change log planned (6) |
| `address` | n/a | not asked for | n/a (no postal addresses) |
| `promoCode`, `promoName`, `promoDiscount`, `promoType` | `exos_discount_codes` / vouchers, `/v1/events/:id/promo-codes` | `promo_code`, `promo_name`, `promo_discount_cents`, `promo_type` | built |

## Fan

| DICE field | Exos | Import | Status |
|---|---|---|---|
| `id` | `exos_fans.id` | `exos_dice_id_map` (entity `fan`) | built |
| `firstName`, `lastName` | `first_name`, `last_name` | fill empty names only | built |
| `email` | `email` (one fan per org and email) | upsert, source `dice` | built |
| `dob` | n/a | not asked for | n/a (Exos keeps no birthdays; age checks happen at the door) |
| `phoneNumber` | SMS list (`exos_sms_subscribers`, consent only from the fan's own confirmed opt-in) | the door entry's `phone`; never the SMS list | built (door only) |
| `optInPartners` | the org email list (`email_opt_in_at`), changed only by the fan | **the only path to consent**: true → on the list (source `dice:optInPartners`), never over an unsubscribe; false later → the DICE consent is withdrawn | built |

## Return, TicketTransfer, Adjustment

| DICE field | Exos | Import | Status |
|---|---|---|---|
| Return `id`, `ticket` / `ticketId`, `order`, `returnedAt`, `reason` | `exos_order_refunds` | `exos_dice_id_map` (entity `return`, `data`); the entry is voided (a return seen first voids the ticket when it arrives) | built |
| TicketTransfer `id`, `tickets`, `orders`, `transferredAt` | `exos_transfers` | the entry's holder, `data.transferred_at` | built |
| Adjustment `reason`, `processedAt`, `ticket`, `feesChange` | `exos_fee_adjustments` (`reason`, `processed_at`, `ticket_id`, `fees_change_cents`), `GET /v1/orders/:id/adjustments`, `GET /v1/events/:id/fee-adjustments` | `exos_dice_orders.adjustments` | built (mig 20261107110000; imported DICE adjustments stay as data) |

## Venue, VenueSpace, Address, Image, SocialLink, Genre

| DICE field | Exos | Import | Status |
|---|---|---|---|
| Venue `id`, `name`, `type`, `ageLimit` | `exos_venues` | `venue_name`; the rest in `data.venue` | built |
| `displayedAddress`, `streetAddress`, `city`, `state`, `region`, `country`, `postalCode`, `postOfficeBoxNumber` | `exos_events.venue_address` {street, city, region, postal, country} | mapped on create | built |
| `latitude`, `longitude` | `exos_event_geo` (geocoded by `exos-geocode`, docs/maps.md) | `data.venue`; not written to `exos_event_geo` (its rows come from the geocoder) | n/a (geocoded from the address) |
| `timezoneName` | `exos_events.timezone` | set when Postgres knows the zone | built |
| `venueSpaces` | `exos_venue_rooms` | `data.venue.spaces` | built (as data) |
| Image `type`, `url` | `image_url` | the landscape image | built |
| SocialLink `url`, `campaign`, `default` | promo links | `data.social_links` | built (as data) |
| Genre / GenreType `id`, `name`, `genres` | tags | names in `data` | planned (5) |
| Address (all fields) | n/a | not asked for | n/a (no postal addresses) |

## Where to read it in Exos

| What | Where |
|---|---|
| The connection, counts, last runs | `exos_dice_org_status` (dashboard), `GET /v1/dice-import` |
| Runs | `exos_dice_import_runs`, `GET /v1/dice-import/runs` |
| Start a sync or a preview | Integrations card, `exos-dice-import` `/sync`, `POST /v1/dice-import/sync` (`org:admin`) |
| Imported events | `GET /v1/events` (link-out, `ticket_backend` `dice`) |
| Imported ticket holders | `GET /v1/events/:id/guest-lists`, `GET /v1/migrated-attendees` |
| Imported fans and consent | `GET /v1/fans` (`consent.email_list.source` = `dice:optInPartners`) |
| DICE orders | `exos_dice_orders` (owner / manager, RLS) |

## What Exos has that DICE's API doesn't

DICE's partner API only reads. Exos's API (docs/api-reference.md) also:

- **Writes.** Create and edit events, ticket types, add-ons and promo codes; transfer, comp and check in
  tickets; refund orders; manage fans and tags; run the box office, booking, offers and settlements.
  Every write runs the dashboard's rules as the key's creator and takes an `Idempotency-Key`.
- **Webhooks.** Signed deliveries for orders, refunds, check-ins and the rest (`/v1/webhooks`), so a
  CRM doesn't have to poll.
- **OpenAPI.** `public/openapi.json` (OpenAPI 3.1) and the `/developers` reference, generated from
  `docs/api/*.json` and checked against the route table on every build.
- **MCP.** `exos-mcp` lets an assistant (Claude, ChatGPT) work with an organization's events and orders
  (docs/mcp.md).
- **Scoped tokens.** Org API keys with per-resource `:read` / `:write` scopes, personal access tokens and
  OAuth tokens narrowed to the member's live role, account tokens for the fan API
  (docs/developer-platform.md). DICE has one token per partner with no scopes.
- **A public listing feed and a partner sales contract** (docs/listing-feed.md, docs/partner-sales.md).
