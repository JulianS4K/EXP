# Series, collections and timed entry

Three features for organizers who sell the same thing many times. Migration
`supabase/migrations/20261030150000_exos_series_timed_entry.sql`, SQL harness
`tests/exos/test_series_timed_entry.sql`.

- **Series**: one event repeated on a schedule. Each date is an ordinary
  event, so tickets, fees, tax, add-ons, refunds, reports and the door work
  unchanged.
- **Collections**: a public page grouping events, at `/c/<org slug>/<slug>`,
  with schema.org `EventSeries` JSON-LD.
- **Timed entry**: chosen ticket types sell a date and a time slot, with a
  capacity per slot that is never oversold, and an entry window at the door.

All times are wall clock in the event's timezone. `src/lib/recurrence.ts`
(`zonedToUtcMs`) and SQL `_exos_zoned_ts` agree: a time in the spring-forward
gap moves forward by the gap, a repeated time takes the earlier instant.

## Series

| Where | What |
|---|---|
| `exos_event_series` | + `status` (active / archived / cancelled), `description`, `image_url`, `cancelled_at`. `rule` is the recurrence (`src/lib/recurrence.ts` `SeriesRule`). |
| `exos_series_occurrences` | One row per date `(series_id, occ_date)`: `generated`, `cancelled`, `skipped` (cancelled before an event existed) or `removed` (detached). `fingerprint` = md5 of title, description and image as the series last wrote them. |
| `exos_events.series_id / series_index` | Membership (template = 0), unchanged. |

The dashboard expands the rule (`recurrence.ts`, previewed in
`/dashboard/event/:id/recurring`) and sends dates to `exos_series_generate`
(≤ 120 per call). The database inserts each date's row first, `ON CONFLICT DO
NOTHING`, and clones the template (`exos_create_event_series`, drafts) only for
rows it inserted, so generating twice or concurrently never duplicates a date.
Past dates and the rule's `exceptions` are skipped.

RPCs (owner / manager of the series' org): `exos_series_create`,
`_generate`, `_publish` (generated drafts not yet started), `_cancel_date`
(event cancelled; holders mailed by the existing trigger; the dashboard then
runs `exos-refund cancel_event`), `_propagate` (title, description, image,
prices by ticket type name; skips `edited`, `has_sales`, `past`, `cancelled`
and reports each), `_update` (details, rule, archive), `_cancel` (scope
`series_only` / `all_shows` / `selected`, required), `_delete` (only with no
tickets; unsold drafts deleted, the rest detached), `_attach_event` /
`_detach_event` (by reference). Public: `exos_public_series(id, page,
per_page)` and `exos_public_org_series(org_slug)`: active series, upcoming
published dates only. The event page's "More dates" reads `exos_public_events`
by `series_id`.

Screens: `SeriesEditor.tsx` (create), `SeriesManager.tsx`
(`/dashboard/series/:id`), the series list in `OrgCollections.tsx`.

## Collections

`exos_collections`: `name`, `slug` (unique per org), `description`,
`image_url`, `mode` `manual` (`event_ids`, ≤ 100) or `rule` (`rule_kind`
series / artist / venue / tag, `rule_value`, case-insensitive), `published`.
RLS: org staff read; owner, manager, content write. The public page calls
`exos_public_collection(org_slug, slug)`, which returns only a published
collection and only its upcoming published events (`_exos_public_event_json`:
no status, counts or buyer data). Screens: `OrgCollections.tsx`
(`/orgs/:id/collections`), `CollectionPage.tsx`.

## Timed entry

| Where | What |
|---|---|
| `exos_timed_entry` | Per event: `tier_ids`, `slot_minutes` (5-480), `capacity` per slot (all timed types), `tier_capacity`, `entry_window_minutes` (null = until the slot ends), `early_entry_minutes`, `hours` (`'0'` = Sunday → ≤ 4 ranges), `start_date`, `end_date` (≤ 400 days), `closed_dates`. Written by `exos_set_timed_entry` / `exos_clear_timed_entry`. |
| `exos_event_slots` | Sparse: a row once a slot held, sold or was changed. `capacity` null = the config's; `closed`, `sold`, `tier_sold`. |
| `exos_cart_holds.slot_id`, `exos_checkout_sessions.slot_id` | The slot a hold / order is for. |
| `exos_tickets.slot_id`, `slot_starts_at`, `slot_ends_at`, `slot_entry_from`, `slot_entry_until` | Set at mint. |

Slot ids are the wall-clock start, `YYYYMMDDTHHMM`; a slot must end by closing
time, at most 96 a day.

**Never oversold.** `exos-checkout` takes `slot_id` for a timed type: after the
tier hold it calls `exos_attach_hold_slot` (service role), which locks the slot
row and counts sold plus live slot holds. Fulfillment (`exos_fulfill_checkout`,
patched) runs `_exos_slot_commit` inside its all-or-nothing block, in the same
transaction as the tier counter, locking the same row; a full slot fails the
order with `XF001` and it is refunded like a sold-out order. A `BEFORE INSERT`
trigger refuses any ticket of a timed type that fulfillment didn't count
(comps, free claims, box office, partners: "Please pick a date and time
slot"), and a void, refund or release gives the place back. Free timed
tickets go through `exos-checkout`'s free path (signed in too). A config
change can't strand a sale: slots with sales stay scheduled with room for what
they sold.

Public reads: `exos_public_timed_entry(event)` (config, no counts) and
`exos_public_event_slots(event, from, to)` (≤ 62 days; remaining overall and per
timed type), for published or cancelled events; drafts only for org staff.
Staff: `exos_event_slot_report`, `exos_set_event_slot` (capacity ≥ sold, close).

**Door.** A live entry scan (`exos_check_in_ticket`, both overloads) outside
the ticket's window answers `outside-entry-window` with `window` early / late;
nothing is written. Staff choose **Admit anyway** (`exos_admit_outside_window`),
then the next scan checks the ticket in. Offline replays are not re-judged: the
door decided. `exos_event_door_slots` lists every slotted ticket's window for
the door's registry.

Screens: `SlotPicker.tsx` (event page), `TimedEntryPanel.tsx` and
`SlotReport.tsx` (event report), the door prompt in `OrganizerCheckIn.tsx`.

## Partner API

Read only (`docs/api/series.json`): `GET /v1/series`, `/v1/series/:id`
(summary stats + schedule), `/v1/series/:id/dates`, `/v1/collections`,
`/v1/collections/:id`, `/v1/events/:id/timed-entry` (all `events:read`),
`/v1/events/:id/slots` (`tickets:read`). Writes are the dashboard RPCs above.

## Known limits

- One slot per order. Seat maps, timed-entry settings and secret locations are
  not copied to series dates.
- An offline door shows the window warning only once the scanner app reads
  `exos_event_door_slots` into its registry (the server already accepts the
  replay).
- Postgres resolves an ambiguous local time to the later instant on its own;
  `_exos_zoned_ts` corrects that to the earlier one to match the browser.
