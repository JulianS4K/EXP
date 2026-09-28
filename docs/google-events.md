# Exos events on Google (Search and Maps "Tickets")

Google shows ticket links for events on Search and on a venue's Maps page (the "Tickets" tab, e.g. DICE as the
"official seller"). Ticketers get there through Google's **events ticketing** program: after a contract, Google sets
up an Actions Center account and reads the ticketer's events feed. Exos has the feed; joining the program is a
business step (see "Going live").

- **Endpoint:** `GET https://<project>.supabase.co/functions/v1/exos-google-feed`
- **Code:** `supabase/functions/_shared/googleEvents/feed.ts` (pure builder),
  `supabase/functions/exos-google-feed/index.ts` (reads and serves). Tests: `src/lib/googleEvents/feed.test.ts`.
- **No migration.** It reads existing tables with the service role and serves only fields that are already public
  on the event page.

## What's in the feed

```jsonc
{
  "feed_metadata": { "provider": "Exos", "version": 1, "generated_at": "…", "processing_instruction": "PROCESS_AS_SNAPSHOT", "total_events": 12 },
  "events": [
    {
      "id": "<exos event id>",
      "googleFields": { "category": "CONCERT", "placeId": "ChIJ…", "sellerType": "PRIMARY", "updatedFrom": "exos" },
      "event": { "@context": "https://schema.org", "@type": "MusicEvent", "name": "…", "startDate": "2026-11-06T21:00:00-05:00",
                 "location": { "@type": "Place", "name": "…", "address": { … }, "geo": { … } },
                 "offers": [ { "@type": "Offer", "price": "21.78", "priceCurrency": "USD", "availability": "https://schema.org/InStock",
                               "url": "https://…/checkout?event=…&products=<tier>:1&utm_source=google&utm_medium=events_feed", … } ], … }
    }
  ]
}
```

- **Each event is a schema.org `Event`,** the vocabulary Google documents for event data:
  - the name (the marketplace-clean title from `eventStandard.ts`) and a plain-text description;
  - `startDate`, `endDate` and `doorTime` in the venue's local time with its UTC offset;
  - `eventStatus`, and the venue as a `Place` with a postal address, coordinates and a Maps link by Place ID;
  - performers, the organizer (their Exos page), the image, and a `typicalAgeRange` for 18+/21+ events;
  - **one `Offer` per public ticket type.**
- **Prices are all-in:** the scheduled price in force plus any tax added at checkout. Exos adds no buyer fee, so this
  is what the buyer pays, as Google's policy and US all-in pricing rules expect.
- **Availability:**
  - `InStock` while on sale;
  - `PreOrder` before sales open;
  - `SoldOut` at capacity;
  - `Discontinued` once sales end or the event is cancelled.
- **Offer links** open the Exos checkout with that ticket type in the cart, tagged `utm_source=google`, so sales from
  Google show up in attribution.
- **`googleFields`** holds what isn't schema.org:
  - Google's category (concerts / sports / theatre / exhibits / workshops, else other);
  - the venue's Google Place ID from Exos geocoding;
  - Exos as the primary (official) seller.

  When Google shares the partner feed spec at onboarding, mapping to it is one function over these items.

**Included:**
- published events that haven't ended (no end time = assumed over six hours after the start) and have at least one
  public ticket type, a time zone, a venue name, and a city and country;
- cancelled events that were on sale and haven't started, as `EventCancelled`, so Google shows the cancellation.

Hidden ticket types (unlocked by codes) are never listed. The feed is a **snapshot**: an event that drops out is
removed from Google.

## Report (operator)

`GET …/exos-google-feed?report=1` with `Authorization: Bearer <service role key>` returns the counts and every event
left out, with why, for example "no time zone" or "venue address needs at least a city and a country". It can name
events that never went public, so it isn't public.

## Limits

- 30 calls a minute per network. If the limiter errors, calls are refused.
- The feed is cacheable for 15 minutes and covers up to 2,000 events.
- Unexpected errors return "something went wrong"; the details go to the function log, redacted.

## Going live (operator)

1. **Deploy (needs permission):** `supabase functions deploy exos-google-feed --no-verify-jwt`, with
   `EXOS_APP_BASE_URL` set (https, the public app base). It uses `exos_rate_hit` from `20260929060000_exos_mcp.sql`,
   so apply that first.
2. **Check:** `curl -s <url> | jq '.feed_metadata'`, then read the report for events that are missing something.
3. **Apply to Google's events ticketing program** (Google Ads Help, "Google events ticketing: starter guide"). Google
   onboards the ticketer, which is Exos, not each venue. Their review looks at live inventory, so it comes after
   payments are live.
4. **Map to Google's partner spec** once they share it, and give them the feed URL or set up the upload they ask for
   (the Actions Center usually uses SFTP; Exos has no uploader yet, and an upload means credentials and operator
   sign-off).

Separately from the program, event pages already carry schema.org `Event` JSON-LD for crawlers
(`src/lib/hosting/seo.ts`), which is what regular Google Search reads.
