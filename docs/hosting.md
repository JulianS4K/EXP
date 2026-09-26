# Hosting: Exos on its own Render service, behind the existing link

**The link people use doesn't change:** `https://vibepass-storefront-test.onrender.com/bridge/`.

```
browser ──► vibepass-storefront-test (Terminal-2, Python)
              │  /bridge/*  ── reverse proxy (EXOS_ORIGIN set) ──► exos-web (this repo, server.ts)
              │                                                     └ dist/ built from main on every merge
              └  everything else (hub, terminal, store) as before
```

- **Same URL and origin.** The browser only ever talks to
  `vibepass-storefront-test`. The Supabase session in `localStorage` is still
  shared with the hub, so a user signed in on the home page is signed in to
  Exos.
- **Exos owns its pages.** `server.ts` sets the per-page security headers
  (`src/lib/hosting/headers.ts`), serves the link previews and sitemap
  (`src/lib/hosting/seo.ts`), and serves the SPA under `/bridge/`.
  Terminal-2 passes those headers through untouched.
- **No more copying `dist/`.** `exos-web` auto-deploys from `main`
  (`render.yaml`). Terminal-2's `static/bridge/` stays only as the fallback
  until the cutover is confirmed, then gets deleted.

## Routes on exos-web

| Path | What |
|---|---|
| `/` | 308 → `/bridge/` (keeps the query string) |
| `/bridge` | 308 → `/bridge/` |
| `/bridge/assets/*`, icons, `manifest.json`, `sw.js` | Static from `dist/`. Hashed assets are immutable; a missing asset is a 404, never the shell |
| `/bridge/*` (any client route) | The SPA shell, `no-cache`. Link-unfurl bots get per-event / per-org tags spliced between the `SSR_META` markers in `index.html` |
| `/bridge/sitemap.xml` | Upcoming published events + organizer pages (10 min cache); 404 without Supabase env |
| `/sitemap.xml` | 301 → `/bridge/sitemap.xml` |
| `/robots.txt` | For direct visits to this host. Through the Render link, Terminal-2 serves its own |
| `/healthz` | Liveness for Render |

## Cutover (operator steps)

Nothing below happens automatically. Creating a service, setting env vars
and deploying are Render writes.

1. **Merge the app work first.** The build Terminal-2 serves today comes from
   JulianS4K/EXP#4 (`claude/exos-p0`). `exos-web` builds from `main`, so #4
   must be on `main` before step 2, or visitors would get an older app.
2. **Create `exos-web`** from `render.yaml` (Dashboard → New → Blueprint).
   Fill in the `sync: false` values:
   - `EXOS_PUBLIC_BASE_URL` = `https://vibepass-storefront-test.onrender.com`
   - `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`: the anon key, same
     project as today.
   - `VITE_STRIPE_PUBLISHABLE_KEY`, `VITE_GOOGLE_MAPS_API_KEY`,
     `VITE_GOOGLE_MAPS_MAP_ID`, `VITE_GOOGLE_MAPS_EMBED_KEY`: the values the
     current bundle was built with.
3. **Check it directly** at `https://exos-web.onrender.com/bridge/`: browse an
   event and the door scanner, and load `/bridge/sitemap.xml`. Then check a
   crawler preview:
   `curl -A facebookexternalhit/1.1 https://exos-web.onrender.com/bridge/event/<id> | grep og:title`.
4. **Flip the proxy:** set `EXOS_ORIGIN=https://exos-web.onrender.com` on
   `vibepass-storefront-test`. Unset it to roll back instantly to
   `static/bridge/`.
5. **Confirm the Render link.** `https://vibepass-storefront-test.onrender.com/bridge/`
   should serve the new build, with the signed-in session intact.
6. **Retire the copy.** Once it's stable, delete Terminal-2's `static/bridge/`
   in a follow-up PR.
