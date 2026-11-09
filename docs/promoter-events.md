# Promoter-run events: no venue on Exos

Operator decision (Julian, 2026-11-05): a promoter or collective creates and sells its own events with no venue
organization on Exos: venues that aren't on Exos, pop-ups, warehouses, secret locations. The events get their own
event pages and checkout, like any other.

| Piece | Where |
|---|---|
| Schema, rules, reveal, cron | `supabase/migrations/20261105130000_exos_promoter_events.sql` |
| SQL tests | `tests/exos/test_promoter_events.sql` (PE1-PE13, run by `tests/exos/run_p0.sh`) |
| Pure rules (shared) | `supabase/functions/_shared/eventLocation.ts`; the editor's draft in `src/lib/eventLocation.ts` (tests: `src/lib/eventLocation.test.ts`) |
| Partner API | `exos-api/promoterEvents.ts`; reference `docs/api/event-location.json` (/developers, "Event location") |
| Dashboard | `src/components/LocationModePicker.tsx` (event editor), `src/components/OrgTypePicker.tsx` (onboarding, settings) |
| Event page, ticket | `src/views/EventDetails.tsx`, `src/components/TicketLocation.tsx` (ticket page and live link), wallet passes |

## What blocked or confused this before

- The event editor had one free-text "Venue" field, required unless the event was online. A pop-up or a warehouse
  party could only type its address there, and that is public everywhere: the event page, the map pin, the JSON-LD
  for Google, the calendar feeds, the listing feed, partners, the API.
- The publish blocker `missing_venue` refused an event with no venue, so "location to be announced" couldn't go live.
- Nothing said "this org has no venue": the dashboard led with the booking calendar and received venue requests.
- The venue gate of `docs/org-access.md` only gates venue records (`exos_venue_id`), not free text, but the editor
  didn't make that path a first-class choice, and nothing told a promoter when the name it typed is a venue that is on
  Exos.

## Org type

`exos_orgs.org_type`: `organizer` (the default; every existing org), `promoter` or `collective`. The owner picks it
when creating the org (the onboarding and "Create organization" forms) or in Org settings → Kind of organization
(`exos_org_type_set`). It is a label plus defaults and no permission reads it:

- a new event starts as "A venue not on Exos" instead of "At a venue";
- the dashboard hides the Booking calendar button, and Venue requests opens on Sent. The pages stay reachable.

## Location modes

`exos_events.location_mode`:

| Mode | The public sees | Notes |
|---|---|---|
| `venue_record` | as today | The default and every existing event: a venue record of the org (`exos_venue_id`, gated as in org-access) and/or free-text labels. Unchanged. |
| `unlisted_venue` | name and address | A venue not on Exos: free text (`venue_name`, `venue_address`), never a venue record. Needs a street or city to publish. |
| `secret_location` | the area only (`venue_location`), "Secret location", and when holders get the address | The exact place lives in `exos_event_secret_locations`, not on the event row. `location_reveal_at` is the reveal (before the start). |
| `tba` | "Location to be announced" (and an optional area) | `tba_allow_sales` is the organizer's explicit choice. `false`: published but not on sale. |

Set through `exos_event_location_set` (owners and managers; the editor's "Where it happens") or the API. Rules the
database keeps whatever the path:

- A `secret_location` or `tba` event's `venue_name` and `venue_address` stay empty: sending one is refused, and a
  switch into those modes clears what the previous mode had.
- None of the three promoter modes takes a venue record (refused when set, cleared on a switch).
- `location_reveal_at` only exists for `secret_location`; `tba_allow_sales` only for `tba`.
- A published event that would break a location rule is refused (`location: ...`): going live, or changing the
  location while live. A reschedule on its own is never refused: the reveal is always by the start
  (`least(location_reveal_at, starts_at)`).
- A live secret event keeps its address (it can be changed, not removed).

### The venue gate

The gate never blocks these modes: it only reads `exos_venue_id`, which they never carry. It also can't be used to get
around the gate: a `venue_record` event at another org's owned venue is still `venue_approval_required`, a promoter mode
can't carry the link, and switching back to `venue_record` with the link is gated again.

When an unlisted venue's name and city (or the secret place's) exactly match an owned venue of another organization
that takes requests, the editor shows "This venue is on Exos: request to book?" with a link to Venue requests → Sent,
prefilled. It is a suggestion only: never linked, never refused (the anti-squatting rule of org-access: anyone can call
a venue owned). `exos_location_venue_matches`, `GET /v1/venue-matches`, and `venue_suggestions` in the location answers.

## Capacity

Operator rule: there is no unlimited capacity, and 0 closes sales (mig 20261105100000). An event in one of the three
promoter modes needs at least one ticket type sold on Exos with a capacity of 1 or more to publish: the publish
blocker `capacity_required`. Setting an existing type to 0 is allowed, on a live event too: it closes that type (it
shows sold out). A live event refuses only a missing or negative capacity (mig 20261105150000). A new ticket type
still needs 1 or more, as on every event.

## Publish blockers

Added to `_exos_event_publish_blockers` (the dashboard, `GET /v1/events/:id/publish-blockers`, `POST .../publish`):
`missing_venue_address` (unlisted), `missing_location_area`, `missing_secret_address`, `missing_reveal_time`,
`reveal_after_start` (secret), `tba_sales_choice` (tba), `capacity_required`. `missing_venue` no longer applies to
`secret_location` and `tba`. Promoter-mode events created in the dashboard are saved as drafts and published through
`exos_publish_event`, so the blockers apply.

## The reveal

Computed at read time: a ticket holder (an active or used ticket) sees the address from the reveal time, wherever they
look:

- the ticket page (`exos_event_location`) and a partner's live ticket link (`exos_ticket_link_location`, the link's
  256-bit key);
- the wallet pass: the payload carries it from then (`_exos_wallet_payload` → `location`). Apple: venue and address
  fields with a change message. Google: a text module on the ticket's own object, never on the event's class, which
  every holder's pass shares.

The mail, the text and the wallet push are sent by `exos_send_location_notices` (cron `exos-location-notices-5min`,
created **inactive**; the operator turns it on once the mail drain is live):

- at the reveal: a `location-revealed` mail to each holder (once per address version), an SMS to holders who opted in
  to the org's texts when the org has a connected Twilio / Telnyx number (quiet hours as campaigns), and the holders'
  wallet passes marked for a push;
- an address changed after the reveal: the same again, "New location";
- a live `tba` event gets a location: a `location-announced` mail (and text) with the public place, or the area and the
  reveal time when it became a secret location.

Org members aren't mailed. Voided tickets get nothing.

## Where the secret address could leak, and how each is closed

| Path | How it is closed |
|---|---|
| The event row (`exos_events`): anon's column grants and the published-read policy, `exos_public_events`, every public JSON builder, webhooks, channel mirrors, partners, the API's event answers, MCP | The address is never on the row: `venue_name` / `venue_address` are forced empty for `secret_location`, and the place lives in `exos_event_secret_locations`. Tested by a sweep of every relation anon, a stranger and a holder may read (PE9), and a scan of every table (only the secret table holds it before the reveal). |
| The secret table | RLS: org owners, managers, content, finance and the event's door staff read it; no client writes; anon nothing. Only this migration's functions read it (PE1 checks the set) and no view does. |
| Map pin / geocode (`exos_event_geo`, `exos_public_event_geo`, the Google feed, calendar GEO, wallet lat/lng) | The pin is dropped when an event becomes secret / tba, a later geocode write for it is skipped by a trigger, the public pin view filters the modes, and `exos-geocode` doesn't look them up. Only the public text is ever geocoded. |
| Google events feed, calendar feeds, catalog feeds, listing feed, s4k feed, discovery, recommendations | All read the event row (and the pin): only the area. JSON-LD on the event page publishes the area as the place name with no street. |
| Partners (distribution partners, the partner contract, co-hosts) | They read the event row only: the area. Partner reservations work on a secret event and carry no address (PE9). A venue that co-hosts never sees another org's secret (co-hosted events are venue-record events). |
| The org's own API keys | `GET /v1/events/:id/location` returns the address only to an `events:write` credential; event answers (`_exos_api_event_json`) never do. |
| Ticket page, live link, wallet | Only an active or used ticket of that event, only after the reveal. Before it, holders get the area and the time. |
| Mail and SMS | Sent to holders only after the reveal; stored in `exos_mail` / `exos_sms_*`, which no client role reads. |
| History | Switching a published event into `secret_location` clears its public name and address and drops its pin; a third-party mirror (Eventbrite / Luma) that already had the old address keeps it until the next sync pushes the area. |

## Partner API

- `GET /v1/events/:id/location` (`events:read`), `PUT /v1/events/:id/location` (`events:write`, a key made by an
  owner or manager), `GET /v1/venue-matches?name=&city=` (`events:read`).
- `POST /v1/events` and `PATCH /v1/events/:id` take `location_mode`, `location_reveal_at`, `tba_allow_sales`, and
  `secret_location` (an object, set in the same call; never echoed).

## Not in this change

- Guest-list guests and waitlisted fans don't get the address (they hold no ticket).
- Reveal mail is rendered in SQL (like the event reminder), not as a payload template.
- No per-ticket-type or per-holder reveal times.
