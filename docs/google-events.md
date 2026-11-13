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

Organizers see whether each event is in the feed, with the reason when it isn't, on the Promote page under
**Discovery listings** (`docs/organizer-guide.md`); that status is `feedBlocker` run on the same columns, not a
stored guess.

### Events sold on another checkout (mig `20261029170500`)

Where to buy comes from one SQL function, `exos_event_buy_link`, which the storefront reads too; the feed gets it
through `exos_feed_where_to_buy`.

- **Link-out events** (listed from Eventbrite, Luma or Posh; Exos sells nothing): no Exos ticket types, so the
  offers are the **imported ticket types** (else one "Tickets" offer at the lowest price), each linking to the
  organizer's checkout tagged `utm_source=google&utm_medium=events_feed`, with the platform as `seller`
  (`{"@type":"Organization","name":"Eventbrite"}`) and `category: primary` (it is the organizer's own primary
  sale, not a resale). `googleFields.sellerType` is `LINK_OUT` (provisional until the partner spec names its
  value). Availability follows the re-checked source: `SoldOut` when the source is sold out (or that type is),
  else `InStock`. Example:

  ```jsonc
  "googleFields": { "category": "CONCERT", "placeId": null, "sellerType": "LINK_OUT", "updatedFrom": "exos" },
  "event": { "@type": "MusicEvent", "name": "Rooftop Party", "eventStatus": "https://schema.org/EventScheduled",
    "offers": [
      { "@type": "Offer", "name": "Early", "price": "25.00", "priceCurrency": "USD", "availability": "https://schema.org/SoldOut",
        "url": "https://www.eventbrite.com/e/rooftop-party-tickets-1234567890?utm_source=google&utm_medium=events_feed",
        "category": "primary", "seller": { "@type": "Organization", "name": "Eventbrite" }, "sku": "<event id>:1" },
      { "@type": "Offer", "name": "GA", "price": "45.00", "availability": "https://schema.org/InStock", … } ] }
  ```
  - Moved at the source: `eventStatus` `EventRescheduled` with `previousStartDate`.
  - Cancelled at the source: the Exos event is cancelled, and the feed shows it as `EventCancelled` until its start
    (it was listed, even with no Exos sales). Ended at the source: left out. No price from the source: left out
    (`no price from the source`).
- **Events another backend sells** (Edit event → Where tickets are sold, or last call on another primary): their
  Exos ticket types stay the offers, but each offer links to that shop with the same tags, seller = the platform.
- Google's Event guidelines want the offer URL to be a page where the ticket can be bought and the price to match
  that page; the imported price is re-read with the status, but between checks it can lag the source. *Not
  verified against Google's live docs in this change (the session couldn't reach developers.google.com); confirm
  the third-party ticket URL rules and the partner spec's seller field at onboarding.*

## Spanish (`?lang=es`)

The same feed with `?lang=es` swaps in each organizer's Spanish title and description where they wrote one
(`exos_events.i18n`, mig 20261114130000) and marks every event `inLanguage: "es"`; events without them keep the
default text. `docs/i18n-review.md`.

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

## Neighborhood pages ("this week in Bushwick")

Phase 1 item 7c (`docs/gtm-nyc.md`, "Content and SEO"). Mig `20261111110000_exos_neighborhoods.sql`, harness
`tests/exos/test_neighborhoods.sql`.

- **Pages.** `/nyc` lists New York's neighborhoods with how many events each has this week; `/nyc/<neighborhood>`
  (`/nyc/bushwick`) is "This week in Bushwick": the next 7 days, by day, soonest first (`?days=14` for two weeks).
  Views `src/views/NeighborhoodsIndex.tsx`, `src/views/NeighborhoodPage.tsx`; logic `src/lib/neighborhoods.ts`.
- **What's listed.** Exactly what public discovery lists: published events that aren't hidden from search
  (`noindex`), that haven't ended, starting inside the window. Drafts, cancelled and hidden events never show.
- **Where an event is.** Its venue pin from `exos-geocode` (`docs/maps.md`), read through `exos_public_event_geo`, so
  only fresh pins (30 days) and never a secret or to-be-announced location. Each neighborhood is a center point and a
  radius in `exos_neighborhoods` (seeded for 20 NYC neighborhoods; the operator edits rows, `active = false` hides
  one). There is no PostGIS here, so the distance is a haversine in plain SQL (`exos_geo_distance_m`, mirrored by
  `distanceMeters` in TS). An event belongs to the nearest center whose circle holds it, so it is never on two pages.
- **No pin, not listed.** An event without coordinates can't be placed and is left out. Platform admins see, on the
  page, how many listed events in the city's time zone have no pin (online events and secret / TBA locations aren't
  counted); nobody else gets that number.
- **Search engines.** The page sets its title ("This week in Bushwick"), description, Open Graph tags and a canonical
  URL with `applyMeta` (`src/lib/meta.ts`), plus schema.org JSON-LD: a `CollectionPage` whose `ItemList` holds each
  event as an `Event`. Link-preview bots get the title and description server-side (`neighborhoodTags` in
  `src/lib/hosting/seo.ts`), and `/bridge/sitemap.xml` lists `/nyc` and every neighborhood.
- **RPCs (anon).** `exos_neighborhoods_list(city, days)` and `exos_neighborhood_page(slug, days)`: 120 calls a minute
  per network between them (the platform-set IP, as `exos_api_public`); 54000 over it.
- **Adding a city or a neighborhood.** Insert rows (service role) with `city`, center, `radius_m` and `timezone`; the
  SPA routes are NYC-only today (`/nyc`).
