# Exos

Primary ticketing platform for live events: organizers create events and tiered inventory, attendees buy and transfer tickets with rotating HMAC QR barcodes, organizers scan attendees at the door (online + offline with local registry fallback).

> **Status:** Core flows live on Supabase (auth, tickets, transfers, scanner). Stripe checkout and Automatiq distribution are wired but dormant pending credential setup. See `KANBAN.md` for open items.

## Stack

- **Frontend:** React 19 + Vite 6, Tailwind, Framer Motion, lucide-react
- **Auth + DB:** Supabase Auth + Supabase Postgres (migrated from Firebase)
- **Payments:** Stripe Checkout (dormant — set `STRIPE_SECRET_KEY` + `STRIPE_WEBHOOK_SECRET` to activate)
- **QR Barcodes:** HMAC-SHA256 rotating codes (60s buckets), verified server-side via `exos_check_in_ticket` RPC
- **Hosted at:** `vibepass-storefront-test.onrender.com/bridge/` (same-origin with FastAPI shell)

## Build

```bash
# Requires .env.local with VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY
npm install
npm run build          # outputs to dist/
# Until Exos has its own Render service, the bundle is still served by
# Terminal-2: copy dist/ → Terminal-2/static/bridge/ and open a PR there.
```

## Dev

```bash
npm run dev            # Vite HMR at localhost:5173 (hits prod Supabase)
```

## Prerequisites

- Node.js 20+
- Supabase project (URL + anon key in `.env.local`)
- Stripe account (only required for checkout activation)

## Key routes

| Path | Surface |
|---|---|
| `/` | Wallet / ticket list |
| `/events` | Event discovery |
| `/create-event` | Organizer event creation |
| `/ticket/:id` | Ticket detail + QR |
| `/transfer/:id` | Transfer flow |
| `/claim/:token` | Claim transferred ticket |
| `/organizer/check-in/:eventId` | Door scanner (camera + offline) |
| `/admin/org` | Org management |

## Architecture notes

- RLS on all `exos_*` tables — org-scoped by `exos_has_org_role()`; consumer wallet scoped to `owner_id = auth.uid()`
- Offline scanner: downloads registry to localStorage, HMAC-verifies barcodes client-side, queues pending check-ins for replay on reconnect
- Mail: `exos_queue_mail` RPC enqueues transactional mail → `exos-mail-drain` edge function delivers via Resend (dormant — set `RESEND_API_KEY` + `EXOS_MAIL_FROM`)
- See `src/lib/` for auth, barcode, tickets, datetime, mail utilities

## Docs

- [`docs/onboarding.md`](docs/onboarding.md): start here as a developer
- [`docs/payments-go-live.md`](docs/payments-go-live.md): switching Stripe on (operator runbook)
- [`docs/organizer-guide.md`](docs/organizer-guide.md): what organizers do, for support and testing
- [`docs/strategy.md`](docs/strategy.md): where Exos is going and the phased build plan
- [`docs/gtm-nyc.md`](docs/gtm-nyc.md): go-to-market, NYC first
- [`KANBAN.md`](KANBAN.md): prod state, open findings, roadmap

## Repository layout

| Path | What |
|---|---|
| `src/`, `public/`, `index.html`, `server.ts` | The SPA + Express dev/serve layer |
| `supabase/migrations/` | Copy of every `*exos*` migration. The DB is still shared, so Terminal-2 is authoritative (see `supabase/README.md`) |
| `supabase/functions/` | Copy of the Exos edge functions (`exos-*` + `stripe-webhook`) (+ vendored `_shared/cron-auth.ts`); Terminal-2 deploys them |
| `tests/exos/` | SQL lifecycle / RLS / money-path harnesses (run against a scratch Postgres) |
| `docs/` | Charter, RLS review, FE test plan, event preflight |
| `design/exos-screens/` | Static screen mockups |

## History

Extracted from `JulianS4K/Terminal-2` (formerly `d4_bridge/`, lane D4) on
2026-09-24 with `git filter-repo`, so `git log` carries the original commits.
