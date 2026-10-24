# Eventbrite API v3 (Exos Door attendee sync)

Source: the public **Eventbrite API v3** blueprint (API Blueprint 1A),
uploaded by the operator on 2026-10-13 and saved as
[`openapi/eventbrite-api-v3-public.apib`](openapi/eventbrite-api-v3-public.apib).
Host: `https://www.eventbriteapi.com/v3/`.

Unlike the marketplaces in this folder, Eventbrite is not a place Exos sells
into. It is where an organizer already sells, and **Exos Door** reads its
attendee list so the door can check those people in (mig `20261013100000`,
`docs/organizer-guide.md` "Tickets sold somewhere else").

Code: `supabase/functions/_shared/eventbrite/client.ts` (tested by
`src/lib/eventbrite.test.ts`), the `exos-eventbrite-sync` edge function, and
`src/lib/door/eventbrite.ts` + `src/components/EventbriteSync.tsx` in the app.

## Read only, except the capacity update and mirrored events

Hard Rule #2 (`CLAUDE.md`). Every read goes through `ebGet`, which sends only
`GET` to `www.eventbriteapi.com` (`ALLOWED_HTTP_METHODS = {GET}`;
`assertReadonlyMethod` throws on anything else).

The **one write** (mig `20261014110000`, operator choice 2026-10-13: "dry run,
then a per-org switch") is **Update a Ticket Class with the `capacity` field
only**, on a ticket class the organizer already has on Eventbrite and mapped
to an Exos ticket type. It lives in its own module,
`_shared/eventbrite/writer.ts`, whose `assertCapacityOnly` refuses any other
path or any other field. It is a dry run (the plan is recorded and shown, not
sent) unless **both** the org's owner switched sending on
(`exos_eventbrite_accounts.writes_enabled`) **and** the operator set
`EXOS_EVENTBRITE_WRITES=on` on `exos-eventbrite-sync`.

Exos never:
- creates ticket classes, events, discounts, holds or anything else (the
  organizer makes their Eventbrite tickets on Eventbrite),
- changes a price, a name, sale dates or any field but `capacity`,
- writes check-ins back (`checked_in` is read only there; Exos reads it, see
  "Check-ins at the Exos door"),
- registers or changes webhooks (`POST /webhooks/` is a write, so the sync
  polls instead).

**Mirrored events (mig `20261019090000`, operator decision 2026-10-19: "Exos,
Eventbrite and Luma mapped 1-1").** For an event the organizer creates in Exos
and chooses to also sell on Eventbrite, `exos-channel-sync`
(`_shared/channels/eventbrite.ts`) creates and keeps in step, on the
organizer's own account: the venue, the event (name, dates, description,
currency), its ticket classes (name, price, hidden; the first capacity), publish
and cancel. Only the paths in `EB_WRITES` (marked **M** below), under the same
gate (org switch + `EXOS_EVENTBRITE_WRITES=on`, dry run otherwise). Capacity
afterwards stays the inventory sync's job. The list above ("Exos never") holds
for every event Exos did not create there, and for orders, discounts, holds,
check-ins and webhooks on any event.

Every other non-GET endpoint below is **✖ forbidden**, not merely unused.

## Auth

The organizer pastes their **private token** (Eventbrite: Account settings →
Developer links → API keys). It is checked with `GET /users/me/`, then stored
in Supabase Vault as `exos_eventbrite:<org id>` (`exos_eventbrite_connect`).
It goes only in the `Authorization: Bearer` header, never in a URL, and is
never logged or returned to the browser. Disconnecting deletes it.

The OAuth app-partner flow (client id + secret, one Exos app for every
organizer) would replace pasting; it needs an Eventbrite app registration.
Not built.

## How the sync works

- **Link:** an owner / manager links an Exos event to one Eventbrite event.
  Attendees land in that event's **Eventbrite** guest list (no cap; does not
  count toward the house capacity). An attendee the CSV import already brought
  in with the same barcode is adopted, not duplicated.
- **Poll:** `GET /events/{id}/attendees/?changed_since=<cursor − 2 min>`, 50 per
  page, following `pagination.continuation`. Cron every 2 minutes
  (`exos-eventbrite-sync-2min`) from two days before the event, every 30
  minutes before that, never once the event is two days past. **Sync now**
  in `/door` runs one at most every 20 s.
- **Budget:** 10 pages a link per cron run (20 for Sync now); a longer first
  sync saves its continuation and resumes on the next run. After an error the
  cron waits 10 minutes. Eventbrite allows 2,000 calls an hour per token; one
  live event costs about 30.
- **Void:** an attendee who is `refunded`, `cancelled`, `Not Attending`,
  `Deleted` or `Transferred`, or whose barcodes are all `refunded`, is voided:
  the door refuses the scan and the name. A ticket that comes back is
  un-voided. A voided attendee never seen before is not added.
- **Key:** `external_ref = 'eb:<attendee id>'`; the barcode is the first one
  that isn't refunded.
- **Safety:** each run's writes carry the claim's lease id, so a run overtaken
  by a relink or reconnect writes nothing. A page that fails to save is read
  again. A pass in which a row failed (e.g. a barcode another guest holds)
  doesn't move the cursor, so it is retried; the panel shows how many.
  Voiding never changes the house capacity.

## Check-ins at the Exos door (mig `20261014120000`)

The API gives each attendee `checked_in`, `refunded`, `cancelled`, a status
word, and every barcode with `status` (`unused` / `used` / `refunded`) and
`checkin_type` (0 not validated, 1 scanner, 2 name). The sync stores them,
read only:

- **Two barcode stores.** Eventbrite's codes go to `exos_eventbrite_barcodes`
  with Eventbrite's status; Exos tickets keep their rotating codes in
  `exos_tickets`. They're never merged. The guest entry keeps one Eventbrite
  code as its door code, as before.
- **Two check-in records.** `exos_eventbrite_attendees` holds what Eventbrite
  saw (checked in, when, scan or name); the guest's `arrived` counts Exos door
  scans only. The door adds them: a guest Eventbrite checked in is refused
  online and offline as **already checked in on Eventbrite** (with the time),
  and a check-out on Eventbrite lets them in again after the next sync.
- **Limit:** the sync runs every 2 minutes near the event, so a ticket scanned
  on both apps within that window can still get in twice. One scanning app
  per event is still the advice.

**One status vocabulary.** `exos_eb_status_word` maps Exos states to
Eventbrite's words: active → Attending, used → Checked In, transferred →
Transferred, voided → Not Attending (guests: expected / in / voided). The event
report's **Find an attendee** (`exos_attendee_lookup`, owner / manager)
searches Exos tickets, Eventbrite attendees and every guest list by name,
email, order or barcode, filters by those words, and says where each person
was checked in (Exos door, Eventbrite's app, or both).

## Inventory: one shared count (mig `20261014110000`)

With S4K's pools on (mig `20261014130000`, `docs/marketplace/s4k-feed.md`),
"free on Exos" below is pool 1: Exos and Eventbrite share what S4K's split
leaves.

Read from the spec before building: a ticket class has `capacity` (how many it
may sell in total, required for a normal non-tiered class) and `quantity_sold`
(read only); `quantity_total` is what is actually available after event and
inventory-tier limits. Update a Ticket Class takes `capacity`. A class inside
an **inventory tier** (`inventory_tier_id` set) is limited by the tier instead;
those classes are skipped for now (the tier endpoints would be a second write,
not built). The event-level capacity tier is left alone.

How it works:
1. **Map.** In `/door` (the event's Eventbrite card), an owner or manager picks
   which Exos ticket type each existing Eventbrite ticket class sells from
   (`POST /map`; one class per ticket type). The function re-reads the class
   from Eventbrite first. Free ticket types can be shared: Eventbrite may sell
   them, resale marketplaces don't. **Not shareable** (refused at map, skipped
   if it changes later): Eventbrite classes in an inventory tier, donation and
   add-on classes; Exos ticket types with no capacity set, or in a shared
   capacity group (a quota counts minted tickets, not these seats).
2. **Count.** Every 2 minutes for each link with a mapping
   (`exos_eventbrite_inventory_due`, apart from the attendee cadence) and on
   Sync now, the function reads `GET /events/{id}/ticket_classes/` and
   `exos_eventbrite_inventory_apply` takes each class's new Eventbrite sales
   from the Exos ticket type (refunds give seats back). A sale Exos had no seat
   left for is counted as **oversold** and shown in red; a later refund clears
   oversold first. A read older than the last one applied is ignored, so two
   overlapping passes can't turn into a false refund. An unmapped class keeps
   its count, so mapping it again doesn't count its sales twice. Locks: all the
   event's mapping rows (class order), then the ticket type, then the event
   (checkout's order).
3. **Set.** The target capacity is `quantity_sold + max(0, free on Exos - one
   pack)` (one pack = max per order, else 8), or `quantity_sold` once the event
   is cancelled or over (a cancelled event stays on the 2-minute schedule until
   Eventbrite is set). With a house cap, its remainder is split across the
   classes rather than offered to each. When the target differs from
   Eventbrite's capacity, the writer plans `{"ticket_class": {"capacity": N}}`
   and sends it only when sending is live. **A target of 0 is never sent**
   (Eventbrite refuses 0 on a normal class and reads it as unlimited on a
   donation): on a class Exos created (a mirror) the class is hidden instead
   (`{"hidden": true}`, shown again with the next capacity); on any other the
   panel says to hide or end that ticket on Eventbrite. With a Luma mirror on
   the same ticket type, the two split `free - 2 packs` (mig 20261020110000).

Simulated (`scripts/channel-sim/eventbrite_dual.py`, report `eventbrite-dual-report.txt`): with sending
live, a 2-minute sync and a 1-pack buffer, steady demand never oversold; an on-sale rush oversold about 1
order per 800-seat sell-out (2.7 tickets per 1,000). A late cron is the risk in a rush (10 minutes: about 11
orders per 800-seat sell-out). Sending off (count only) oversells about 20% of a sell-out. A velocity buffer
(at least one pack, or twice what Exos sold in the last window) cut the rush to 0.24 and the late cron to 0.

Known limits: Eventbrite's `quantity_sold` doesn't include carts in progress,
so at the very end a cart can complete into oversold (shown, not hidden).

Not checked against a live account yet: whether Eventbrite accepts a partial
update with only `capacity` (the spec lists the Update fields as required).
First live test: the operator's test org, one mapped class, with sending
switched on for that org only.

## Endpoints

Access:
- **R**: read, fine to call.
- **W**: the capacity write, gated as above.
- **M**: a mirrored-event write (`exos-channel-sync`), gated as above.
- **✖**: forbidden. Never sent.

| Endpoint | Access | Used by Exos | Name in the spec |
|---|---|---|---|
| `GET /events/{event_id}/attendees/{attendee_id}/` | R |  | Retrieve an Attendee |
| `GET /events/{event_id}/attendees/` | R | **the sync** (`changed_since`, `continuation`) | List Attendees by Event |
| `GET /organizations/{organization_id}/attendees/` | R |  | List Attendees by Organization |
| `GET /balance/<public_organization_id>/events/<public_event_id>/` | R |  | Remaining Balance |
| `GET /categories/{id}/` | R |  | Category by ID |
| `GET /subcategories/{subcategory_id}/` | R |  | Subcategory by ID |
| `GET /categories/` | R |  | List of Categories |
| `GET /subcategories/` | R |  | List of Subcategories |
| `GET /discounts/{discount_id}/` | R |  | Retrieve a Discount |
| `POST /organizations/{organization_id}/discounts/` | ✖ |  | Create a Discount |
| `POST /discounts/{discount_id}/` | ✖ |  | Update a Discount |
| `GET /organizations/{organization_id}/discounts/{?scope}` | R |  | Search Discounts by Organization |
| `DELETE /discounts/{discount_id}/` | ✖ |  | Delete a Discount |
| `GET /events/{event_id}/display_settings/` | R |  | Retrieve Display Settings |
| `POST /events/{event_id}/display_settings/` | ✖ |  | Update Display Settings |
| `GET /events/{event_id}/capacity_tier/` | R |  | Retrieve a Capacity Tier |
| `POST /events/{event_id}/capacity_tier/` | ✖ |  | Update a Capacity Tier |
| `GET /events/{event_id}/description/` | R |  | Retrieve Full HTML Description |
| `POST /events/{event_id}/schedules/` | ✖ |  | Create an event schedule |
| `GET /events/search/` | R |  | Search Events - deprecated |
| `GET /series/{event_series_id}/` | R |  | Retrieve an Event Series |
| `GET /events/{event_id}/teams/` | R |  | List by Event |
| `GET /events/{event_id}/teams/{team_id}/` | R |  | Retrieve Team |
| `GET /events/{event_id}/teams/{team_id}/attendees/` | R |  | List Attendees by Team |
| `POST /events/{event_id}/teams/create/` | ✖ |  | Create a Team |
| `POST /events/{event_id}/teams/{team_id}/check_password/` | ✖ |  | Verify password for a team |
| `GET /events/{event_id}/teams/search/?term={term}` | R |  | Search teams by name Team |
| `GET /events/{event_id}/` | R | link: confirms the token can read the event | Retrieve an Event |
| `POST /organizations/{organization_id}/events/` | **M** | channel sync: create the mirrored event | Create an Event |
| `POST /events/{event_id}/` | **M** | channel sync: update the mirrored event | Update an Event |
| `GET /venues/{venue_id}/events/` | R |  | List Events by Venue |
| `GET /organizations/{organization_id}/events/` | R | event picker (`status=live,started,draft`, `time_filter=current_future`) | List Events by Organization |
| `GET /series/{event_series_id}/events/` | R |  | List Events by Series |
| `POST /events/{event_id}/publish/` | **M** | channel sync: publish when Exos publishes | Publish an Event |
| `POST /events/{event_id}/unpublish/` | ✖ |  | Unpublish an Event |
| `POST /events/{event_id}/copy/` | ✖ |  | Copy an Event |
| `POST /events/{event_id}/cancel/` | **M** | channel sync: cancel when Exos cancels | Cancel an Event |
| `DELETE /events/{event_id}/` | ✖ |  | Delete an Event |
| `GET /formats/{format_id}/` | R |  | Retrieve a Format |
| `GET /formats/` | R |  | List Formats |
| `GET /events/{event_id}/inventory_tiers/{inventory_tier_id}/` | R |  | Retrieve an Inventory Tier |
| `POST /events/{event_id}/inventory_tiers/` | ✖ |  | Create an Inventory Tier |
| `POST /events/{event_id}/inventory_tiers/` | ✖ |  | Create Multiple Inventory Tiers |
| `POST /events/{event_id}/inventory_tiers/{inventory_tier_id}/` | ✖ |  | Update an Inventory Tier |
| `POST /events/{event_id}/inventory_tiers/` | ✖ |  | Update Multiple Inventory Tiers |
| `GET /events/{event_id}/inventory_tiers/` | R |  | List Inventory Tiers by Event |
| `DELETE /events/{event_id}/inventory_tiers/{inventory_tier_id}/` | ✖ |  | Delete an Inventory Tier |
| `GET /media/{media_id}/{?width,height}` | R |  | Retrieve Media |
| `POST /media/upload/` | ✖ |  | Upload a Media File |
| `GET /media/upload/` | R |  | Retrieve a Media Upload |
| `GET /orders/{order_id}/` | R |  | Retrieve Order by ID |
| `GET /organizations/{organization_id}/orders/` | R |  | List Orders by Organization ID |
| `GET /events/{event_id}/orders/` | R |  | List Orders by Event ID |
| `GET /users/{user_id}/orders/` | R |  | List Orders by User ID |
| `POST /orders/{order_id}/refunds/` | ✖ |  | Refund Order |
| `GET /orders/{order_id}/get_retention_policy_information/` | R |  | Get refund retention policy |
| `GET /organizations/{organization_id}/members/` | R |  | List Members of an Organization |
| `GET /organizations/{organization_id}/roles/` | R |  | List Roles by Organization |
| `GET /users/me/organizations/` | R | event picker | List your Organizations |
| `GET /users/{user_id}/organizations/` | R |  | List Organizations by User |
| `POST /pricing/calculate_price_for_item/` | ✖ |  | Calculate Items |
| `GET /pricing/fee_rates{?country,currency,plan,payment_type,channel,item_type}` | R |  | List Pricing |
| `GET /events/{event_id}/canned_questions/` | R |  | List Default Questions by Event |
| `GET /event/{event_id}/canned_questions/{question_id}` | R |  | Get Default Question by Id |
| `POST /events/{event_id}/canned_questions/` | ✖ |  | Create a Default Question for an Event |
| `POST /event/{event_id}/canned_questions/{question_id}` | ✖ |  | Update Default Question by Id |
| `DELETE /event/{event_id}/canned_questions/{question_id}` | ✖ |  | Delete Default Question by Id |
| `GET /events/{event_id}/questions/` | R |  | List Custom Questions by Event |
| `POST /events/{event_id}/questions/` | ✖ |  | Create a Custom question for an Event |
| `GET /events/{event_id}/questions/{question_id}/` | R |  | Get Custom Question by Id |
| `DELETE /events/{event_id}/questions/{question_id}/` | ✖ |  | Delete a Custom Question for an Event |
| `GET /reports/sales/` | R |  | Retrieve a Sales Report |
| `GET /reports/attendees/` | R |  | Retrieve a Attendee Report |
| `GET /organizations/{organization_id}/seatmaps/{?venue_id,venue_name_filter}` | R |  | List Seat Maps by Organization |
| `POST /events/{event_id}/seatmaps/` | ✖ |  | Create Seat Map For Event |
| `GET /events/{id}/structured_content/` | R |  | Retrieve Latest Published Version of Structured Content by Event Id |
| `GET /events/{id}/structured_content/edit/` | R |  | Retrieve Latest Working Version of Structured Content by Event Id |
| `POST /events/{id}/structured_content/{version}/` | ✖ |  | Set Structured Content by Event Id and Version |
| `GET /organizations/{organization_id}/text_overrides/{?locale,event_id,venue_id,text_codes}` | R |  | Retrieve Text Overrides |
| `POST /organizations/{organization_id}/text_overrides/` | ✖ |  | Create Text Overrides |
| `GET /events/{event_id}/ticket_buyer_settings/` | R |  | Retrieve Ticket Buyer Settings by Event |
| `POST /events/{event_id}/ticket_buyer_settings/` | ✖ |  | Update Ticket Buyer Settings for an Event |
| `GET /events/{event_id}/ticket_classes/{ticket_class_id}/` | R |  | Retrieve a Ticket Class |
| `POST /events/{event_id}/ticket_classes/` | **M** | channel sync: one per Exos ticket type | Create a Ticket Class |
| `POST /events/{event_id}/ticket_classes/{ticket_class_id}/` | **W** / **M** (gated) | inventory sync: `{"ticket_class": {"capacity": N}}`; channel sync: name, price, hidden of a mirrored class | Update a Ticket Class |
| `GET /events/{event_id}/ticket_classes/` | R | inventory sync + the mapping picker | List Ticket Classes by Event |
| `GET /events/{event_id}/ticket_classes/for_sale/` | R |  | List Ticket Classes Available For Sale by Event |
| `GET /ticket_groups/{ticket_group_id}/` | R |  | Retrieve a Ticket Group |
| `POST /organizations/{organization_id}/ticket_groups/` | ✖ |  | Create a Ticket Group |
| `POST /ticket_groups/{ticket_group_id}/` | ✖ |  | Update a Ticket Group |
| `POST /organizations/{organization_id}/events/{event_id}/ticket_classes/{ticket_class_id}/ticket_groups/` | ✖ |  | Add a Ticket Class to  Ticket Groups |
| `GET /organizations/{organization_id}/ticket_groups/` | R |  | List Ticket Groups by Organization |
| `DELETE /ticket_groups/{ticket_group_id}/` | ✖ |  | Delete a Ticket Group |
| `GET /users/{user_id}/` | R |  | Retrieve Information about a User Account |
| `GET /users/me/` | R | connect: checks the token, shows the account name | Retrieve Information About Your User Account |
| `GET /venues/{venue_id}/` | R |  | Retrieve a Venue |
| `POST /organizations/{organization_id}/venues/` | **M** | channel sync: the mirrored event's venue | Create a Venue |
| `POST /venues/{venue_id}/` | ✖ |  | Update a Venue |
| `GET /organizations/{organization_id}/venues/` | R |  | List Venues by Organization |
| `POST /organizations/{organization_id}/webhooks/` | ✖ |  | Create Webhooks by Organization ID |
| `POST /webhooks/` | ✖ |  | Create Webhooks - deprecated |
| `GET /organizations/{organization_id}/webhooks/` | R |  | List Webhook by Organization ID |
| `GET /webhooks/` | R |  | List of Webhooks - deprecation |
| `DELETE /webhooks/{id}/` | ✖ |  | Delete Webhook by ID |
