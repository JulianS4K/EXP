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
| `/llms.txt`, `/bridge/llms.txt` | Only with `EXOS_AI_DISCOVERY=on` (see below); a 404 until then |
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

## AI discovery (off until launch)

`EXOS_AI_DISCOVERY=on` on `exos-web` makes Exos readable by AI assistants and answer engines. **Leave it unset
until Exos is live** (operator decision 2026-10-08); with it unset, nothing below happens and AI fetchers keep
getting the plain app shell. Map of every AI source: the "Exos AI Reach Map" artifact.

With it on:
- **AI crawlers and fetchers count as link crawlers** (`supabase/functions/_shared/aiSources.ts`
  `AI_AGENT_UA_TOKENS`: ChatGPT-User, OAI-SearchBot, GPTBot, Claude-User, Claude-SearchBot, ClaudeBot,
  PerplexityBot, Perplexity-User, MistralAI-User, DuckAssistBot, Amazonbot, CCBot…), so they get the event tags
  and JSON-LD that Google and Meta get today.
- **Every crawler gets the event page as plain HTML** inside `#root` (`seo.ts` `eventBody`): summary, date, venue
  or "Online", organizer, ages, description, lineup, ticket types with all-in prices and sold-out / sales-ended
  state, the event link, FAQ, what to bring, refund policy and notes. React replaces it on mount for anyone
  running JavaScript. Hidden (`noindex`) events never get it.
- **FAQPage JSON-LD** from the organizer's FAQ (not on hidden events or promoter pages).
- **`/llms.txt`**: what Exos is, that prices are all-in and purchases happen on the event page, the sitemap, the
  MCP endpoint (from `VITE_SUPABASE_URL`), and up to 200 upcoming public events. Cached 10 minutes.

Through the Render link this needs `EXOS_ORIGIN` set (Terminal-2's own `static/bridge/` fallback has none of it).
Check after turning it on:
`curl -A 'ChatGPT-User/1.0' https://<host>/bridge/event/<id> | grep ssr-content` and `curl https://<host>/llms.txt`.

Not behind the switch: the Sources report's "AI assistant" grouping (organizers only). The SPA records which
assistant referred a visit (`ai_ref`, the name only) and checkout keeps it once `exos-checkout` is redeployed with
the shared attribution file.

## Error reporting (optional)

Nothing is sent anywhere unless a DSN is set. Without one, errors are only
logged, scrubbed, to the browser console / the function logs.

**Browser** (`src/lib/errorReporting.ts`, used by `ErrorBoundary` and the
`window` `error` / `unhandledrejection` handlers installed in `main.tsx`).
Build-time env on `exos-web` (Vite inlines them, so set them before the build):

| Var | What |
|---|---|
| `VITE_SENTRY_DSN` | The Sentry project's DSN (`https://<public key>@<org>.ingest.sentry.io/<project>`). Its key is public by design; it goes in the `X-Sentry-Auth` header, not the URL |
| `VITE_SENTRY_ENVIRONMENT` | Optional, default `production` |
| `VITE_SENTRY_RELEASE` | Optional, e.g. the commit sha |

The page CSP allows `https://*.sentry.io` (`src/lib/hosting/headers.ts`); a
self-hosted Sentry needs its host added to `connect-src` there.

**Edge functions** (`supabase/functions/_shared/log.ts`: `reportError(fn, err)`
and `redactError(err)`). Supabase function secrets:

| Secret | What |
|---|---|
| `SENTRY_DSN` | Optional. When set, `reportError` also POSTs the event (3 s timeout, failures dropped) |
| `SENTRY_ENVIRONMENT` | Optional, default `production` |

What gets scrubbed, in both (`supabase/functions/_shared/scrub.ts`): email
addresses, `Bearer` / `Basic` credentials, JWTs, prefixed keys (`sk_…`,
`whsec_…`, …), long token-looking strings, secret-named `key=value` pairs, and
every URL's query string and fragment (claim keys, the Gametime `?source=` key,
Vivid's `apiToken`). The browser sends the page as origin + path only. The
edge side also redacts the value of every secret-looking env var (`*_KEY`,
`*_TOKEN`, `*_SECRET`, `*AUTHORIZATION`, `*_DSN`, `*PASSWORD`, `*_ACCESS_ID`).
