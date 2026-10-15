# Self-hosting Exos

Exos is a React SPA (served by a small Node server) on Supabase: Postgres with RLS, Vault for secrets, pg_cron
for schedules, and Deno edge functions. Everything an organizer connects (Stripe, pretix, hi.events, Eventbrite,
Twilio / Telnyx, resale marketplaces) is their own account, entered in the app. Nothing in this guide needs an
Exos-the-company account.

```
browser ──► Node server (server.ts: SPA, link previews, sitemap, security headers)
   │
   └──► Supabase: Postgres (RLS, Vault, pg_cron) + edge functions (Stripe, mail, syncs, feeds)
                     ▲
     pg_cron ────────┘  (calls /functions/v1/<fn>/cron with CRON_SECRET)
```

## 1. Supabase project

1. Create a project (any region). Enable the **pg_cron**, **pg_net** and **Vault** extensions (Database → Extensions).
2. **Schema.** Apply `supabase/migrations/*exos*.sql` in timestamp order, then the rest of the list in
   `tests/exos/run_p0.sh` (it is the canonical order; CI replays it on every change).

   > ⚠ **Known gap: the baseline.** The first Exos tables (`exos_orgs`, `exos_events`, `exos_tickets`, …) were
   > created in Terminal-2's history before this repo existed, so a brand-new database needs a baseline schema
   > first. Until `supabase/migrations/00000000000000_exos_baseline.sql` is exported from a live install
   > (`supabase db dump --schema public --data-only=false`, filtered to `exos_*`), self-hosting starts from that
   > dump. `tests/exos/prereq.sql` is a *test stub* of it, not a production schema. (KANBAN: "Open source".)
3. **Cron helper.** The schedules call `public._cron_invoke_edge_fn(url, body)`, which posts with the cron
   secret from Vault. Point the jobs at your project:
   `ALTER DATABASE postgres SET app.exos_functions_url = 'https://<project>.supabase.co/functions/v1';`
   (jobs created before this setting existed hard-code the original project URL: edit them in `cron.job`).

## 2. Edge functions

Deploy every folder in `supabase/functions/` except `_shared`:

```bash
supabase functions deploy <name> --project-ref <ref>               # most functions
supabase functions deploy <name> --project-ref <ref> --no-verify-jwt   # see the table
```

`--no-verify-jwt` (they check auth themselves, or are called by Stripe / cron / public feeds):
`stripe-webhook`, `exos-api`, `exos-calendar`, `exos-catalog-feed`, `exos-conversions-drain`, `exos-distribute`,
`exos-eventbrite-sync`, `exos-geocode-refresh`, `exos-google-feed`, `exos-integrations`, `exos-mail-drain`,
`exos-marketplace-sales`, `exos-mcp`, `exos-payouts`, `exos-reconcile-checkouts`, `exos-reconcile-stripe`,
`exos-s4k-feed`, `exos-wallet`, `exos-webhook-drain`. The rest keep JWT verification.

## 3. Secrets (Project settings → Edge functions → Secrets)

| Secret | Needed for | Notes |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | everything | set by Supabase |
| `CRON_SECRET` | every `/cron` route | the same value in Vault for `_cron_invoke_edge_fn` |
| `EXOS_REDIRECT_ORIGINS` | checkout, CORS | comma list of your app origins, e.g. `https://tickets.example.com` |
| `EXOS_APP_URL`, `EXOS_APP_BASE_URL` | links in mail, feeds | your public app URL (with `/bridge` if you keep that base) |
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_CONNECT_WEBHOOK_SECRET` | payments | `docs/payments-go-live.md`; `docs/pci.md` |
| `EXOS_PLATFORM_FEE_BPS`, `EXOS_STRIPE_FEE_BPS`, `EXOS_STRIPE_FEE_FIXED_CENTS`, `EXOS_CONNECT_ACCOUNT_TYPE` | payments | defaults in `_shared/platformFee.ts` |
| `RESEND_API_KEY`, `EXOS_MAIL_FROM` | ticket / transfer / refund mail | without them the mail drain answers 500 and nothing sends |
| `GOOGLE_MAPS_SERVER_KEY` | geocoding | optional |
| `EXOS_GUEST_IP_SALT` | guest checkout | any long random string |
| `EXOS_EVENTBRITE_WRITES` | Eventbrite capacity sync | `on` to allow; each org also switches it on |
| `EXOS_CONVERSIONS_LIVE` | server-side ad conversions | optional |

Organizer-level accounts are **not** secrets here: owners and managers paste them in **Org settings →
Integrations** (pretix, hi.events, Twilio, Telnyx, marketplaces) or the door app (Eventbrite). They're stored in
Vault (`exos_integration:<org>:<provider>`), read only by edge functions, never shown again.

## 4. The web app

Any Node 20+ host (Render blueprint in `render.yaml`; Fly, Railway, a VM all work):

```bash
npm ci --include=dev && npm run build && npm start
```

| Env | Notes |
|---|---|
| `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` | build time (baked in) and read by the server for previews |
| `VITE_STRIPE_PUBLISHABLE_KEY` | build time |
| `VITE_APP_URL`, `EXOS_PUBLIC_BASE_URL` | your public origin |
| `VITE_GOOGLE_MAPS_API_KEY`, `VITE_GOOGLE_MAPS_MAP_ID`, `VITE_SENTRY_DSN` | optional |
| `TRUST_PROXY_HOPS` | number of proxies in front (Render: 1) |
| `EXOS_AI_DISCOVERY` | leave off until you want crawler / AI pages |

The app is built under `/bridge/` (vite `base`); serve it at `https://<host>/bridge/` or change `base` and
`EXOS_APP_URL` together.

## 5. Check it works

1. Sign up, create an org, create a free event, claim a ticket, scan it at `/door`.
2. Org settings → Integrations → connect pretix with a read-only token → **Save and test** says Connected.
3. Stripe test mode: one paid checkout end to end (`docs/payments-go-live.md` test cases).

## What runs on a schedule

| Job | Every | Function |
|---|---|---|
| `exos-eventbrite-sync-2min` | 2 min (odd) | `exos-eventbrite-sync/cron` |
| `exos-integrations-sync-2min` | 2 min (even) | `exos-integrations/cron` (pretix, hi.events door sync) |
| mail, webhooks, conversions drains; reconcile; geocode refresh; feeds | see each migration's cron section | |

## Upstream rules (kept in code, not configuration)

Ticketing platforms and marketplaces are **read**. pretix, hi.events and the marketplaces are only read;
Eventbrite's one write is the opt-in capacity sync. Don't add order, hold, price or inventory writes to a third
party (CLAUDE.md).
