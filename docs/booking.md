# Booking: venues, rooms, holds, show day

An organization keeps its venues and their rooms, pencils nights with
**holds** before a show is confirmed, and converts one held night into a
**draft event**. Each event carries a day-of **show schedule**, staff
**notes** and **contacts**. Ported from the Firebase build's round 12
(Exos-Bridge `docs/BOOKING.md`); Opendate's booking API was the yardstick.

| Piece | Where |
|---|---|
| Tables, rules, hold functions | `supabase/migrations/20261030100000_exos_booking.sql` |
| SQL tests | `tests/exos/test_booking.sql` (run by `tests/exos/run_p0.sh`) |
| Partner API | `exos-api` booking routes, `_shared/api/booking.ts`; reference in `docs/api/{venues,holds,show-schedule}.json` |
| Calendar page | `src/views/BookingCalendar.tsx` at `/orgs/:orgId/calendar` (linked from the dashboard) |
| Hold dialog, venue manager, event panels | `src/components/booking/` |
| Client logic / data | `src/lib/booking.ts` (pure, tested), `src/lib/bookingApi.ts` |

## Venues and rooms

`exos_venues` (one org each): name, address, IANA time zone, capacity,
website, permalink (unique in the org, made from the name when left out),
`relationship` = `owned` | `rented` | `partner` (promoters book rooms they
don't own) and an optional booking contact. `exos_venue_rooms`: name,
capacity, colour, notes. At most 200 venues per org and 50 rooms per venue.

Events keep their own `venue_name` / `venue_address`. `exos_events.exos_venue_id`
and `exos_room_id` link the org's venue (not `venue_id`, which is the TEvo
catalog id); a trigger refuses another org's venue. A venue or room that any
hold night points at can't be deleted (the history stays).

## Holds and levels

`exos_holds` (title, notes, announce time, ticket forecast, age label,
artist ids, rental terms) has one or more nights in `exos_hold_positions`:
a date (the venue's local date), a venue, a room or the whole venue
(`room_id` null), an optional show time, a target flag and a **level**.

- Levels count per line: org + venue + room + date. They are always 1..N.
- A new night goes to the end of the line unless a level is asked for; then
  it goes in there and the nights at or below move down one.
- Moving a night re-inserts it at the new level.
- Clearing or converting a night takes it out of the line and the nights
  behind move up: clearing H1 makes H2 the new H1.
- A hold holds a line once; a line holds at most 50; a hold at most 30 nights.
- Lines only count the org's own holds, also on a rented or partner venue.
- A night is **challenged** when its line has more than one hold, or a show
  that isn't cancelled is linked to the same room (or the whole venue) that
  local date.

Holds are written only through `exos_hold_create / _update / _clear /
_convert` (owner / manager) and their `_exos_hold_*` cores (service role:
exos-api). Each runs under a per-org lock, renumbers every line it touches
and enqueues webhooks: `hold.created`, `hold.updated`, `hold.converted`, and
`hold.updated` with `reason: level_changed` for every other hold that moved.
`hold.status` is derived: active while any night is held, else converted (a
night became a show) or cleared.

## Converting a night

One transaction: a **draft** event with the hold's title, the venue's address
and time zone, starting at the night's time (given, else its show time, else
20:00) in that zone; `exos_venue_id`, `exos_room_id`, `hold_id`,
`hold_position_id` set; one free General Admission ticket type sized to the
room, else the venue, else 100. An announce time still ahead becomes the
schedule's Announce row; the hold's notes become the first staff note. The
night is marked converted, the hold's other rooms that night are cleared,
and with `clear_holds_on_day` every other hold at the venue that date too.
The hold's other dates stay held. Converting the same night twice is a 409.
The rental terms stay on the hold for the settlement port to read.

## Show schedule, notes, contacts

`exos_show_activities`: kind (`announce`, `load_in`, `soundcheck`, `doors`,
`set`, `changeover`, `curfew`, `load_out`, `other`), name, start, optional
end, notes, `is_set` (false = time to be confirmed), `show_in_advance`. At
most 60 per event, and one `doors` row, which is the same fact as
`exos_events.doors_at`: saving it sets doors_at, deleting it clears it, and
changing doors_at anywhere moves (or, when cleared, deletes) the row. A
doors row written directly can't be after the start. With doors_at and no
row, the app shows an implied Doors row.

`exos_event_notes` (author fixed to the writer) and `exos_event_contacts`
(role, free-text title, name, email, phone, company, notes) are staff-only.

## Who can do what

| | Owner / manager | Content | Finance | Scanner |
|---|---|---|---|---|
| Venues, rooms | read, write | read | read | read |
| Holds | read; write via the functions | read | read | — |
| Show schedule | read, write | read, write | read | read (events they may work) |
| Notes, contacts | read, write | read, write (own notes) | read | — |
| Calendar page | full | read-only | read-only | no access |

The partner API acts for the key's org: `booking:read` for reads,
`booking:write` for writes. Opendate-style spellings answer the same routes
(`/holds/:id/convert_to_confirm`, `/venue_ownerships`,
`/confirms/:id/show_activities`, `/calendar_event_contacts`).

## Not yet

- Artists: `artist_ids` is stored, not resolved (the artists port).
- Offers and settlements read holds, nights and rental terms later.
- A hold on a venue another Exos org owns reserves nothing on that org's
  calendar (no cross-org rental requests yet).
