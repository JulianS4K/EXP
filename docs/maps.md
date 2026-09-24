# Maps

Venue pins for event pages and an events map. Phase 1, the web, is built. Phase 2 (native
Android and iOS maps) and Phase 3 (Places UI Kit for venue intake) are scoped separately.

## How it works

```
organizer saves event ──► exos-geocode (edge fn, server key) ──► Geocoding API
                                   │
                                   ▼
                          exos_event_geo  (lat/lng ≤ 30 days, place_id kept)
                                   │
buyer opens /event/:id or /map ◄── exos_public_event_geo (published, fresh only)
        │
        └─► Maps JavaScript API (@vis.gl/react-google-maps) renders AdvancedMarkers
```

- **The browser never calls a Google REST endpoint.**
  - Geocoding runs only in `supabase/functions/exos-geocode`, which adds
    `GOOGLE_MAPS_SERVER_KEY` and returns `{ lat, lng, placeId }`.
  - The browser only loads the Maps JavaScript API, through `@vis.gl/react-google-maps`.
- **Only organizers trigger lookups,** because each one is billed.
  - Saving an event calls it with `{ event_id }` (`src/lib/geo.ts`, from Create and Edit).
  - It's skipped when the address is unchanged and the pin is under 25 days old.
  - Staff can also preview an address with `{ address }`; nothing is stored.
  - Buyers only read the stored result.
- **The proxy is a Supabase edge function, not a Node/Express route on Cloud Run.** Exos has no
  Node server in production: `server.ts` is dev-only, and the SPA is served by Terminal-2. Edge
  functions are where every Exos server call lives.

## Caching rules (enforced in the schema)

Migration `20260924230000_exos_event_geo`, tested in `tests/exos/test_event_geo.sql`.

| Data | Kept | How |
|---|---|---|
| lat/lng | at most 30 days | `exos_public_event_geo` hides pins 30+ days old; `exos_expire_event_geo()` nulls them |
| Place ID | indefinitely | survives expiry; the refresh re-geocodes by `place_id` |
| Tiles and images | never | nothing stores them |

**The refresh job.** `exos-geocode-refresh`, run daily by cron, re-geocodes published events
whose pin is 25 or more days old, then runs the expiry. A failed lookup drops the pin rather than
keeping a stale one.

## Web (built)

| Where | What |
|---|---|
| Event page | Interactive map with one AdvancedMarker (`InteractiveVenueMap`), when there's a browser key and a fresh pin. Otherwise the Embed iframe if `VITE_GOOGLE_MAPS_EMBED_KEY` is set. "Directions" always, using the Place ID when known. |
| `/map` | Every published event with a pin (`EventsMapCanvas`), NYC by default, with a card and a Tickets link per pin. Without a key, a list with directions. |

**Gotchas handled:**
- `<Map>` always gets a `mapId` (`VITE_GOOGLE_MAPS_MAP_ID`, falling back to `DEMO_MAP_ID`).
  AdvancedMarkers don't render without one.
- Map containers have explicit heights (256 px on the event page, `70vh` on `/map`).
- The Maps loader is lazy, so pages without a map don't download it.

## Turning it on (operator)

1. **Create two keys in Google Cloud:**
   - A **browser key**, restricted to the Maps JavaScript API and to our HTTP referrers.
   - A **server key**, restricted to the Geocoding API.

   Create a **Map ID** (JavaScript, vector) with a dark style.
2. **SPA build env:** `VITE_GOOGLE_MAPS_API_KEY` and `VITE_GOOGLE_MAPS_MAP_ID`. Keep
   `VITE_GOOGLE_MAPS_EMBED_KEY` optional.
3. **Supabase secret:** `GOOGLE_MAPS_SERVER_KEY`.
4. **Apply migration** `20260924230000_exos_event_geo`.
5. **Deploy both functions:**
   - `exos-geocode`: verify_jwt **true**; bundle `../_shared/geocode.ts`.
   - `exos-geocode-refresh`: verify_jwt **false**; bundle `../_shared/geocode.ts` and
     `../_shared/cron-auth.ts`.
6. **Schedule `exos-geocode-refresh` daily** through `_cron_invoke_edge_fn`, like
   `exos-reconcile-checkouts`. Cron changes are operator-gated.
7. **Deploy the Terminal-2 `server.py` CSP.** Event pages and `/bridge/map` allow Google's Maps
   hosts, following its allowlist CSP guidance, plus `blob:` workers.
   - Check the map in a browser after deploy.
   - If Google changes what its loader needs, the fix is in `_BRIDGE_MAPS_*` there.

## Next phases

- **Phase 2 — native.**
  - The Maps SDK for Android (Kotlin) and iOS (Swift) render pins in the app.
  - They read the same `exos_public_event_geo` view, so there's no geocoding on the device.
  - The app shell is the one in `docs/native-sharing.md`.
- **Phase 3 — Places UI Kit intake.**
  - Organizers pick the venue from Google Places autocomplete when creating an event.
  - That stores the Place ID up front, so the first geocode is exact.
  - It needs a Places key and a CSP review.
