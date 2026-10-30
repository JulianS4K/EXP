# Artists, lineups and the listing feed

Organizers keep a list of their artists, put them on each event's lineup, and
publish their events with those lineups to listing sites (Bandsintown, JamBase,
Songkick) or their own website. The listing feed has the same shape as
Opendate's public listing, so a partner that already reads Opendate only needs
a new URL and key. Ported from the Firebase build's round 12 (Exos-Bridge
`server/artists.ts`, `server/listingFeed.ts`).

| | |
|---|---|
| Migration | `supabase/migrations/20261030110000_exos_artists_feed.sql` |
| SQL harness | `tests/exos/test_artists_feed.sql` (in `run_p0.sh`) |
| Shared logic | `supabase/functions/_shared/artists.ts`, `_shared/listingFeed/feed.ts` (vitest: `src/lib/artists.test.ts`, `src/lib/listingFeed.test.ts`) |
| API | `exos-api`: `/v1/artists…`, `/v1/events/:id/lineup`, `/v1/listing-keys…`, `/v1/public/events…` (`docs/api/artists.json`, `docs/api/listing-feed.json`, rendered at `/developers`) |
| UI | Org settings → Artists (`src/views/OrgArtists.tsx`), Listing feed (`src/components/ListingFeedPanel.tsx`); Edit Event → Lineup (`src/components/LineupEditor.tsx`); event page (`src/components/EventArtistLineup.tsx`); widget (`src/views/EmbedOrg.tsx`) |

## Artists

`exos_artists`: one row per act per organization. Name (1-120), a permalink
unique in the org (made from the name, `lumen`, `lumen-2`, …, unless one is
given; an explicit taken one is refused), bio, up to 10 genres, links (website,
Instagram, Facebook, X, TikTok, YouTube, SoundCloud, Bandcamp, Apple Music),
photo and thumbnail (https; the dashboard uploads to the `exos-media` bucket
under the uploader's `event-images/` folder, so no new storage policy), and one
canonical Spotify id.

**Spotify.** The organizer pastes an artist link, a `spotify:artist:` URI or the
22-character id; all three become the id (`_exos_spotify_artist_id` in SQL,
`parseSpotifyArtist` in TypeScript, same rules). Album, track and playlist
links are refused. Only the id is stored; the URI and URL are derived on every
read, so the three can never disagree and are all null together. Exos never
calls Spotify.

**Merging** (owner / manager): when the same act was entered twice, merge it
into the one to keep. The merged artist stays as an alias with
`canonical_artist_id` set (hidden from lists unless asked for); its lineup
slots move to the kept artist, a slot on an event that already has it is
removed and the lineup renumbered, and a later lineup save that names the
alias gets the kept artist. Merging an alias, or into one, is refused.
Offers (booking) can reference `exos_artists.id`.

Owner, manager and content staff create and edit artists; finance can read
them. Writes go through `exos_artist_save` / `exos_artist_merge` only.

## Lineups

`exos_event_lineup`: ordered slots on an event (at most 20): artist, act type
(`headline`, `support`, `opener`, `dj`, `host`, `other`), position 1..n and an
optional set time. A child table rather than an array on the event: a join is
free here, and a rename shows everywhere without a snapshot refresh.
`exos_lineup_save` replaces the whole lineup: positions come from the order,
the first act defaults to headline and the rest to support, duplicates and
other orgs' artists are refused, and a slot that didn't change keeps its id
(the feed's `performer_id`) and `updated_at`.

Every save, merge and rename rewrites the event's `performer_names` (the first
10 names), so emails, the catalog / Google / calendar feeds, the partner API
and server-rendered previews follow the lineup. While an event has a lineup,
Edit Event hides the free-text performers and doesn't send them. The store
page's free-text `lineup` (names, roles, bios; mig 20260929120000) is separate
and unchanged.

The **event page** shows the lineup with photos, act types, set times and a
Spotify link per act, and its JSON-LD lists them as `performer` with the
Spotify URL as `sameAs` (`src/lib/meta.ts`); the server-rendered preview for
crawlers lists the names (`src/lib/hosting/seo.ts`, from `performer_names`).
Public pages read lineups with `exos_public_lineups` (published events only).
The lineup editor is on Edit Event (an event needs to exist first, so not on
Create Event) and saves right after the event; if only the lineup fails, the
event is saved and the page says so.

## The listing feed

### Keys

An org owner opens Org settings → Listing feed, picks the partner
(Bandsintown, JamBase, Songkick, Our website, Other), optionally a label, and
creates a shared key. The key (`sh_live_` + 48 hex) and a ready feed URL show
once; only the SHA-256 hash and a 16-character prefix are stored
(`exos_listing_keys`; `key_hash` has no client grant). One key per partner, so
each can be revoked alone and its ticket links carry the partner. At most 20
active keys. Revoking takes effect at once. With an API key (`org:admin`):
`GET/POST /v1/listing-keys`, `DELETE /v1/listing-keys/:id`.

A shared key reads one organization's feed and nothing else. It isn't an API
key, and an API key isn't a shared key.

### The URL

```
GET https://<project-ref>.supabase.co/functions/v1/exos-api/v1/public/events?shared_key=sh_live_…
GET …/v1/public/events/:id?shared_key=…
```

`/v1/public/confirms` and `/v1/public/confirms/:id` are the same feed under
Opendate's name. The key can also go in an `X-Shared-Key` header; from a
browser use the query parameter (the response allows any origin, and a custom
header would need a preflight, which is answered but costs a round trip).

### What is in it

Events of the key's organization that are published, listed (not "link
only", `exclusivity.customUrlOnly`) and start at or after the cutoff (default
now; `q[start_time_gteq]` for earlier). Drafts and cancelled events never
appear. `exos_listing_feed_source` (SQL) decides this and reads at most 2000
events per request; filters, sort and paging happen after (`feed.ts`), so
`total_entries` is exact.

Example (`GET /v1/public/events?shared_key=…&per_page=1`):

```json
{
  "current_page": 1, "per_page": 1, "total_entries": 2, "total_pages": 2,
  "collection": [{
    "id": "3f6b2c1e-8a4d-4e2f-9b1a-7c5d0e9f2a14",
    "title": "Warehouse Night",
    "start_time": "2026-12-04T22:00:00-05:00", "end_time": null, "doors_time": "2026-12-04T21:30:00-05:00",
    "timezone": "America/New_York",
    "venue_id": null, "venue_permalink": "the-loft", "venue_name": "The Loft",
    "city": "Brooklyn", "region": "NY", "country": "US", "online": false,
    "ticket_url": "https://tickets.example.com/bridge/e/warehouse-night?utm_source=bandsintown&utm_medium=listing&utm_campaign=listing_feed",
    "image_url": "https://…/poster.jpg",
    "genres": ["House"], "price_min": 16.5, "price_max": 27.5, "currency": "USD",
    "on_sale": true, "sold_out": false,
    "published_at": "2026-10-01T15:12:09.120Z", "updated_at": "2026-10-22T18:05:00.000Z",
    "performers": [{
      "performer_id": "c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f",
      "artist_id": "7a1c9e2b-4d6f-4a8b-9c0d-2e3f4a5b6c7d",
      "act_type": "headline", "position": 1, "set_time": "2026-12-05T04:30:00.000Z",
      "updated_at": "2026-10-22T18:05:00.000Z",
      "artist": {
        "id": "7a1c9e2b-4d6f-4a8b-9c0d-2e3f4a5b6c7d", "name": "Lumen", "permalink": "lumen",
        "updated_at": "2026-10-22T18:02:11.904Z", "image_url": "https://…", "image_thumb_url": "https://…",
        "spotify_id": "4Z8W4fKeB5YxbusRsdQVPb",
        "spotify_uri": "spotify:artist:4Z8W4fKeB5YxbusRsdQVPb",
        "spotify_url": "https://open.spotify.com/artist/4Z8W4fKeB5YxbusRsdQVPb",
        "canonical_artist_id": null
      },
      "id": "c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f", "name": "Lumen", "permalink": "lumen",
      "image_url": "https://…", "image_thumb_url_for_json": "https://…"
    }]
  }]
}
```

| Field | |
|---|---|
| `start_time`, `end_time`, `doors_time` | ISO 8601 with the offset of the event's time zone; null when unset. |
| `venue_*`, `city`, `region`, `country` | From the event's venue name and address. `venue_permalink` is made from the venue name. `venue_id` is null until venues are records (booking); the column is read when it exists. |
| Secret venues | An event whose row has `secret_location = true` shows only `location_area` as `venue_name`; `venue_id`, `venue_permalink`, city, region, country are null, and the address never leaves the database. **Seam:** those columns don't exist yet (venue privacy belongs to booking). The feed reads the row through `to_jsonb`, so redaction starts working the day they land; the SQL harness adds them in its transaction and checks it. |
| `online` | `true` for an online-only event, which has no venue fields. |
| `ticket_url` | The event page with `utm_source` = the key's partner (`listing` for Other), `utm_medium=listing`, `utm_campaign=listing_feed`, so sales show up attributed. Needs `EXOS_APP_BASE_URL` on the function; null without it. |
| `price_min`, `price_max` | All-in (passed-on fees and tax included, like every Exos feed) over the public ticket types, in major units; null when there are none. |
| `on_sale` / `sold_out` | `sold_out`: every ticket (or every public ticket type) is sold. `on_sale`: not sold out and a public ticket type with tickets left is inside its sale window. |
| `published_at` | The event's creation time (events don't record a publish time). |
| `performers` | The lineup in running order. `performer_id` is the slot; `artist_id` and everything under `artist` belong to the artist. Spotify fields are all set or all null. `canonical_artist_id` is set when the artist was merged; lineups already point at the kept artist. `id`, `name`, `permalink`, `image_url`, `image_thumb_url_for_json` are Opendate's deprecated flat copies, for older readers (`image_thumb_url_for_json` is null without a photo; there is no placeholder). An event with only free-text performer names lists them with `artist_id: null`. |

### Filters, sort, paging

| Parameter | |
|---|---|
| `page`, `per_page` | Opendate's rules: page from 1, `per_page` default 30, values above 250 treated as 250, anything but a positive integer is a 400. A page past the end has an empty `collection`. |
| `genre`, `exclude_genre` | Comma-separated or repeated (`genre[]` too), case-insensitive; subgenres count. |
| `venue_id` | Only events at this venue (see the seam above). |
| `artist_id` | Only events with this artist (an alias merged into it counts). |
| `q[start_time_gteq]`, `q[start_time_lteq]` | Date or date-time bounds (the plain names work too). |
| `q[s]` | `start_time asc` (default), `start_time desc`, `published_at asc`, `published_at desc`. |
| `tag_id` | Refused (400): Exos events have no tags, and ignoring it would return everything. |

### Caching and limits

`Cache-Control: public, max-age=60` and a strong `ETag`; send it back as
`If-None-Match` for a `304`. 120 requests a minute per key (`exos_rate_hit`;
requests without a well-formed key share a bucket per network); over it `429`
with `Retry-After`. Errors are `{ "error": "…" }` and `no-store`: `401` missing,
unknown or revoked key, `404` an event not in the feed, `400` a bad parameter.

## The events-list widget

Org settings → Website gives the snippet for `/embed/org/<slug>` (list or
calendar layout). Each row now shows the lineup (or the free-text performers)
under the date and venue. It needs no key; use the feed when a site wants to
render the events itself.

## Not here (yet)

- **Artist follows.** In the Firebase build, fans follow artists by name and
  Spotify id across organizers for the "For you" discovery feed; that belongs
  to discovery, not to the org artist record, and isn't ported here.
- **Tags** (Opendate `tags`, `tagged_items`, `canonical_tags`): events have
  genres, not tags, so the feed refuses `tag_id`. A tagging model would be its
  own feature.
- **Opendate's events database** (`GET /api/v2/events`, a cross-team archive of
  shows from SetlistFM, Pollstar and Bandsintown): Exos has no such shared
  dataset. `GET /v1/artists/:id/events` and the feed's `artist_id` filter cover
  "shows with this artist" for the organization's own events.
