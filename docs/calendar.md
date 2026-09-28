# Calendar feeds (subscribe to an organizer, a venue, or "my events")

Fans can put Exos events in the calendar app they already use (Google Calendar, Apple Calendar, Outlook) and keep
them there: a subscribed calendar picks up new dates, time changes and cancellations on its own.

- **Endpoint:** `GET https://<project>.supabase.co/functions/v1/exos-calendar/<feed>.ics` (GET / HEAD only)
- **Code:** `supabase/functions/_shared/calendar/ics.ts` (RFC 5545 writer), `supabase/functions/_shared/calendar/feed.ts`
  (Exos event → VEVENT, venue key, links, path parsing), `supabase/functions/exos-calendar/index.ts` (reads and serves).
  SPA: `src/lib/calendar.ts`, `src/components/AddToCalendar.tsx`, `SubscribeCalendar.tsx`, `MyCalendarFeed.tsx`.
- **Migration:** `20260929073000_exos_calendar_feeds.sql` (feed tokens, venue key, the feed reads).
- **Tests:** `src/lib/calendarFeed.test.ts` (vitest), `tests/exos/test_calendar_feeds.sql` (run by `run_p0.sh`).

## The feeds

| URL (after `/functions/v1/exos-calendar`) | What's in it | Who can read it |
|---|---|---|
| `/org/<org slug>.ics` | An organizer's (promoter's, or a venue org's) events | Anyone (public event data) |
| `/venue/<venue key>.ics` | Every organizer's events at one venue | Anyone (public event data) |
| `/event/<event id>.ics` | One event, as a download ("add to calendar") | Anyone (public event data) |
| `/me/<token>.ics` | Events from the organizers I follow + events I hold tickets for | Whoever has the link |

- **Which events:** published events from 30 days ago onward (up to 500 per feed). A cancelled event stays in the feed
  if it was on sale (tickets sold) or if the subscriber held tickets for it, as `STATUS:CANCELLED` with
  "Cancelled:" in front of the title, so calendars show the cancellation instead of silently dropping the entry.
  Drafts never appear. The single-event feed has no date window.
- **What's in an entry:** title, start and end (2 hours when the event has no end time), the venue and address
  (`LOCATION`), coordinates (`GEO`, only while the geocode is under 30 days old, per Google's caching terms), the event
  page (`URL`), and a description: the ticket link, doors time in the venue's zone, the organizer, and the event
  description as plain text. In the `/me` feed, events with tickets also link to My Tickets. No ticket, order or buyer
  data is ever in a feed.
- **Unknown feeds** (no such org / venue / event, a draft, a revoked or unknown token) all return the same `404`.

### Venue key

Most events carry their venue as text on the event (`venue_name`, `venue_address`), not a venue record (the only
`venue_id` is a TEvo cross-reference, mostly empty), so a venue calendar groups events by a key made from the venue
name and city:

```
slug(venue_name, else venue_location) [ "--" slug(city) ]      "Brooklyn Steel", Brooklyn  →  brooklyn-steel--brooklyn
slug = Unicode NFKD, drop accents, lowercase, every run of other characters → "-", trimmed, at most 60 characters
```

- The same function exists in TypeScript (`venueKey`, used by the event page's "<venue> calendar" link) and SQL
  (`public.exos_venue_key`, used by the feed); both test suites check the same vectors.
- A slug never contains `--`, so the separator is unambiguous; with no city the key is just the name slug.
- **Spelling variants merge through Google Place IDs:** a name key's feed also includes any event geocoded
  (`exos_event_geo`) to the same place as one of its events ("Brooklyn Steel (Main Room)" lands in
  `brooklyn-steel--brooklyn` when both geocode to the same Place ID).
- `place-<Google Place ID>` is a second key form: every event geocoded to that place.
- A venue name with no Latin letters or digits has no name key (use its `place-` key once geocoded).
- The key is stable as long as the organizer spells the venue and city the same way; it doesn't depend on geocoding.

### Times

Every `DTSTART` / `DTEND` is in UTC (`20261107T020000Z`). All calendar apps understand UTC and show it in the viewer's
zone. The alternative, local times with `TZID` and a `VTIMEZONE` block, needs each zone's DST rules written out, which
the runtime can't produce reliably, and a wrong `VTIMEZONE` is worse than none (Outlook trusts it). The venue's zone
is still on the calendar as `X-WR-TIMEZONE`, a display hint, and the doors time in the description is in venue time.

### Updates

- `UID` is `<event id>@exos` in every feed and in the SPA's download, so an app updates the entry instead of adding
  a copy.
- `SEQUENCE` is the event's `updated_at` in seconds since 2024-01-01 (only grows, fits the 32-bit limit until 2092);
  `LAST-MODIFIED` and `DTSTAMP` are `updated_at`.
- Lines are folded at 75 bytes of UTF-8 without splitting a character, with CRLF line endings; text is escaped per
  RFC 5545 §3.3.11.

## How fans subscribe

- **Organizer page** (`/o/<slug>` and `/organizer/<id>`): "Subscribe to calendar" opens
  - **Apple Calendar / Outlook**: a `webcal://` link; the OS opens its subscribe dialog (macOS / iOS Calendar, Outlook
    for Windows / Mac).
  - **Google Calendar**: `https://calendar.google.com/calendar/render?cid=webcal://…`, Google's own
    "add this calendar" dialog. By hand: Google Calendar → Other calendars → **+** → **From URL** → paste the link.
    (Google Calendar on phones can't add URL calendars; do it once on the web and it syncs to the phone.)
  - **Copy calendar link**: for anything else. Outlook on the web: Add calendar → **Subscribe from web** → paste.
  - The **Follow** button next to it (existing, `exos_org_follows`) also puts that organizer in the fan's `/me` feed.
- **Event page:** "Add to Calendar" offers Google Calendar (template link), Outlook.com (compose deeplink) and an `.ics`
  download (Apple Calendar, Outlook desktop), plus "<venue> calendar" to subscribe to the venue.
- **My Tickets:** "My calendar feed" makes the personal link. It's shown once, right after it's made (only a hash is
  stored); "make a new link" replaces it (the old one stops working everywhere), and "turn off" revokes it.

## Refresh behaviour

Feeds ask for a 6-hour refresh (`REFRESH-INTERVAL;VALUE=DURATION:PT6H` and `X-PUBLISHED-TTL:PT6H`); the single-event
download has none. Each app decides for itself:

| App | Refresh |
|---|---|
| Apple Calendar | The subscription's own setting (default often weekly on macOS; set it to "Every hour" / "Every day" in the calendar's info) |
| Google Calendar | Google's schedule, typically every 8 to 24 hours; it can't be forced |
| Outlook (web / new Outlook) | Roughly every 3 to 24 hours |
| Outlook desktop (classic) | Honours `X-PUBLISHED-TTL` |

So a cancellation or time change reaches subscribers within hours, not instantly. The email that Exos sends on a
change stays the prompt path; the calendar catches up.

Responses carry `Cache-Control: public, max-age=900` (`private` for `/me`) and an `ETag`, and answer
`If-None-Match` with `304`.

## Personal feed tokens

- Calendar apps can't send an `Authorization` header, so `/me` feeds are keyed by an unguessable token in the URL:
  `exc_` + 48 hex characters (192 random bits), made by `exos_calendar_feed_token_create()`.
- Only its SHA-256 is stored (`exos_calendar_feed_tokens.token_hash`); the table has no client grants at all, and
  `exos_calendar_feed_token_status()` returns only whether a link is on, when it was made and last fetched.
- One live token per user. Creating a new one revokes the old one (at most 10 new links an hour);
  `exos_calendar_feed_token_revoke()` turns it off.
- A deleted account (tombstoned by `exos_delete_my_account`) resolves to nothing.
- The edge function never logs the path or token. `/me` responses send `Referrer-Policy: no-referrer`.

## Limits

120 requests a minute per network (hashed IP) and 30 a minute per `/me` token, via `public.exos_rate_hit`
(migration `20260929060000`). If the limiter errors, requests are refused (`503`). Note that Google Calendar fetches
all its users' subscriptions from Google's servers; if Exos feeds become popular, watch for `429`s to Google and
raise the per-network limit.

## Deploy (operator-gated)

Nothing here is applied or deployed. With the operator's go-ahead:

1. Apply `supabase/migrations/20260929073000_exos_calendar_feeds.sql` to the shared project (it needs
   `20260929060000_exos_mcp` for `exos_rate_hit`, and `exos_org_follows`, both already in prod or pending with MCP).
2. Deploy the function without JWT verification (calendar apps send none):

   ```bash
   supabase functions deploy exos-calendar --no-verify-jwt --project-ref hzrizjeaxlqcxfrtczpq
   ```

   Secrets: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` (platform), `EXOS_APP_BASE_URL` (public app base, e.g.
   `https://…/bridge`, already set for other functions), optional `EXOS_GUEST_IP_SALT`.
3. Ship the SPA build (the subscribe links build on `VITE_SUPABASE_URL`, already set).
4. Smoke test: `curl -i https://<project>.supabase.co/functions/v1/exos-calendar/org/<slug>.ics`, then subscribe from
   Google Calendar and Apple Calendar with a test org.
