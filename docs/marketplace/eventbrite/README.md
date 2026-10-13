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

## Read only, by construction

Hard Rule #2 (`CLAUDE.md`). Every request goes through `ebGet`, which sends
only `GET` to `www.eventbriteapi.com` (`ALLOWED_HTTP_METHODS = {GET}`;
`assertReadonlyMethod` throws on anything else). Exos never:
- writes check-ins back (`checked_in` stays Eventbrite's own),
- registers or changes webhooks (`POST /webhooks/` is a write, so the sync
  polls instead),
- creates, changes or cancels events, orders, ticket classes, discounts or
  anything else.

Every non-GET endpoint below is **✖ forbidden**, not merely unused.

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

## Endpoints

Access:
- **R**: read, fine to call.
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
| `POST /organizations/{organization_id}/events/` | ✖ |  | Create an Event |
| `POST /events/{event_id}/` | ✖ |  | Update an Event |
| `GET /venues/{venue_id}/events/` | R |  | List Events by Venue |
| `GET /organizations/{organization_id}/events/` | R | event picker (`status=live,started,draft`, `time_filter=current_future`) | List Events by Organization |
| `GET /series/{event_series_id}/events/` | R |  | List Events by Series |
| `POST /events/{event_id}/publish/` | ✖ |  | Publish an Event |
| `POST /events/{event_id}/unpublish/` | ✖ |  | Unpublish an Event |
| `POST /events/{event_id}/copy/` | ✖ |  | Copy an Event |
| `POST /events/{event_id}/cancel/` | ✖ |  | Cancel an Event |
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
| `POST /events/{event_id}/ticket_classes/` | ✖ |  | Create a Ticket Class |
| `POST /events/{event_id}/ticket_classes/{ticket_class_id}/` | ✖ |  | Update a Ticket Class |
| `GET /events/{event_id}/ticket_classes/` | R |  | List Ticket Classes by Event |
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
| `POST /organizations/{organization_id}/venues/` | ✖ |  | Create a Venue |
| `POST /venues/{venue_id}/` | ✖ |  | Update a Venue |
| `GET /organizations/{organization_id}/venues/` | R |  | List Venues by Organization |
| `POST /organizations/{organization_id}/webhooks/` | ✖ |  | Create Webhooks by Organization ID |
| `POST /webhooks/` | ✖ |  | Create Webhooks - deprecated |
| `GET /organizations/{organization_id}/webhooks/` | R |  | List Webhook by Organization ID |
| `GET /webhooks/` | R |  | List of Webhooks - deprecation |
| `DELETE /webhooks/{id}/` | ✖ |  | Delete Webhook by ID |
