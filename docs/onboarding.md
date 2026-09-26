# Developer onboarding

A guide for your first day on Exos. Read it top to bottom once. After that, `CLAUDE.md` holds
the rules and `KANBAN.md` holds what's being worked on.

## What Exos is

A ticketing platform for live events. Organizers run orgs with members and roles. They create
events with tiers, shared quotas, vouchers, add-ons, tax and a waitlist, then sell through Stripe
Checkout. Buyers get tickets in a wallet with a **rotating signed QR code**, and can transfer them to
someone else by email. Door staff scan tickets online, or offline with a downloaded registry.

**Stack:**

- **Frontend:** React 19 + Vite SPA (`src/`), served under `/bridge/`.
- **Database:** Supabase Postgres, where row-level security does the authorization. The money,
  inventory and check-in logic lives in SQL functions (`supabase/migrations/`).
- **Server code:** Deno edge functions (`supabase/functions/`) for Stripe, email, organizer
  webhooks and the public API.

## The one thing to understand first: two repos, one database

Exos moved out of `JulianS4K/Terminal-2` (a broker-analytics app) on 2026-09-24, but **the database
did not move**. Both apps share the Supabase project `hzrizjeaxlqcxfrtczpq`.

| You're changing… | Edit it in | Then |
|---|---|---|
| The SPA (`src/`, `server.ts`, `public/`) | **this repo** | Build, then copy `dist/` into `Terminal-2/static/bridge/` to ship it |
| A migration, an edge function or an SQL test | **Terminal-2** (authoritative) | Copy the same file here in the same change |
| Docs about Exos | this repo (`docs/`, `KANBAN.md`) | — |

`supabase/README.md` has the details and caveats. For example, 18 Terminal-2 migrations without
"exos" in the name also change Exos tables. When the database gets its own project (step 4 of
Terminal-2's `docs/archive/2026-07-02-bridge-extraction-plan.md`), this flips and this repo becomes
the source for everything.

## Setup

```bash
npm ci
cp .env.example .env.local   # set VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY (the anon key is public)
npm run dev                  # http://localhost:5173/bridge/ — talks to the Supabase project in .env.local
```

The `VITE_FIREBASE_*` lines in `.env.example` are left over from before the move to Supabase. Ignore them.

**Be careful with `npm run dev` against production.** Anything you do in the UI is real. For
schema work, use a Supabase branch (copy-on-write, safe to create) or the local SQL harness below.

## Checks (CI runs all of these)

```bash
npm run lint    # tsc --noEmit
npm test        # vitest: pure lib logic in src/lib/*.test.ts
npm run build   # vite → dist/
```

### SQL suites (Postgres 16, no Supabase needed)

The SQL suites apply the **real** migrations to a throwaway database with a small shim for
Supabase's `auth` schema (`tests/exos/prereq*.sql`), then run assertion scripts.

```bash
# one-time local Postgres, e.g. Debian/Ubuntu:
sudo apt-get install -y postgresql-16
sudo -u postgres /usr/lib/postgresql/16/bin/initdb -D /var/lib/postgresql/exos -U postgres -A trust
sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/exos -o '-p 5433' start

export PGHOST=localhost PGPORT=5433 PGUSER=postgres
bash tests/exos/run.sh             exos_test          # platform: waitlist, add-ons, vouchers, tax, invoices, stage 3
bash tests/exos/run_lifecycle.sh   exos_lc_test       # mint → roster → HMAC scan → transfer → void
bash tests/exos/run_money_path.sh  exos_money_test    # refund ledger + void contracts
bash tests/exos/run_audit_hardening.sh exos_ah_test   # quota scope, transfer race, waitlist, grants
bash tests/exos/run_p0.sh          exos_p0_test       # full checkout chain + vouchers / holds / quota mints
```

Every suite ends with a `*** … PASSED ***` line. A failed `ASSERT` stops the run with its message.

**When you fix a bug, add a case that fails without your fix.** Re-run the chain without your
migration to prove it (every P0 fix was checked this way).

## How the important flows work

| Flow | Where to look |
|---|---|
| Checkout | `exos-checkout` validates the tier, voucher, purchase limits and **scheduled price**, creates a cart hold, then a Stripe session. `stripe-webhook` on payment → `exos_fulfill_checkout` mints the tickets, idempotent on the session id |
| Availability | `exos_effective_available(tier)` = tier capacity − sold − live cart holds − blocking waitlist offers, then capped by every shared quota. **Every** mint path must go through it (`exos_seats_available`) |
| Vouchers | One use = one ticket. `bypass_capacity` lets a voucher sell past sold-out. `block_quota` (waitlist offers) reserves seats |
| Refunds | `charge.refunded` → each Stripe refund is recorded by its id (`exos_record_refund`). On a full refund, `exos_refund_checkout` voids the tickets and frees inventory |
| Check-in | `exos_check_in_ticket` checks the HMAC of the rotating code on the server. Offline mode caches a registry (see the KANBAN note on the cached secrets) |
| Transfers | `exos_create_transfer` / `exos_claim_transfer` bind the claim to the recipient's email, lock the ticket, and rotate its barcode secret |

## Rules you must not break

- **Production is shared with Terminal-2.** Reading prod with `SELECT` is fine. Applying migrations,
  running DML/DDL, changing crons or deploying edge functions needs the operator's explicit
  go-ahead each time.
- **Ticket marketplaces (Automatiq, TEvo, SeatGeek, …) are read-only.** No code may create orders,
  holds or listings on them without operator authorization. Keep `exos-distribute` undeployed.
- **Money RPCs are service-role only.** Every `SECURITY DEFINER` function sets `search_path`, and
  one a user can call checks the caller (org role, or owner).
- **`exos_tickets` uses column-level grants.** A new column is invisible to clients until you
  `GRANT SELECT (col) … TO authenticated`. `barcode_secret` stays ungranted.
- **Don't copy code from hi.events or pretix** (both AGPL). Use them for design; the reference map
  is in `CLAUDE.md`.

## Where things are tracked

- `KANBAN.md`: prod state, open audit findings and the roadmap.
- `docs/payments-go-live.md`: turning Stripe on.
- `docs/strategy.md` and `docs/gtm-nyc.md`: the phased plan and who we sell to first.
- `docs/organizer-guide.md`: what organizers do, to help with support and testing.
- `docs/d4_bridge_charter.md`: the original architecture charter (historical, but still useful).
