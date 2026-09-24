# CLAUDE.md

Exos is a ticketing platform for live events: organizers, tiered inventory,
Stripe checkout, transfers, rotating-HMAC barcodes, and online/offline door
check-in. It's a React 19 + Vite SPA on Supabase (Postgres + RLS + edge
functions). It was extracted from `JulianS4K/Terminal-2` (`d4_bridge/`) on
2026-09-24.

## Commands

```bash
npm ci
npm run lint     # tsc --noEmit
npm test         # vitest (pure lib logic)
npm run build    # vite → dist/
npm run dev      # tsx server.ts (hits the Supabase URL in .env.local)
bash tests/exos/run.sh <db>   # SQL harnesses against a scratch Postgres
```

Run lint, test, and build before pushing. CI (`.github/workflows/ci.yml`) runs the same three.

## Rules carried over from Terminal-2

- **The database is shared with Terminal-2's broker data.** Read `supabase/README.md`
  before writing a migration. Prod `apply_migration`, DML/DDL, cron changes,
  and edge-function deploys need explicit operator permission. Reads are free.
- **Upstream ticketing APIs (Automatiq, TEvo, SeatGeek, etc.) are read-only.**
  Never add order/hold/price/inventory writes to a third party.
- Edge functions are Deno; they're excluded from the Node `tsconfig`/eslint.

## Open-source references (hi.events, pretix)

Two mature open-source ticketing platforms are available as **read-only
references**. When building a feature they already have, look at how they
model it first, and borrow the parts that fit (edge cases, state machines,
data shapes). Don't copy code wholesale: hi.events is AGPL-3.0 and pretix is
AGPL-3.0 with additional terms, so treat them as design references and write our
own implementation. Where they disagree, pretix is usually the more battle-tested
one (about 10 years old) and hi.events the closer fit to our stack and UX.

Local clones in a Claude Code session: `/home/user/Hi.Events` and
`/home/user/julians4k/pretixtest` (add them with `add_repo` if missing).

| Area | hi.events (`backend/app/…`) | pretix (`src/pretix/base/…`) |
|---|---|---|
| Order lifecycle, reservation expiry | `Services/Domain/Order/` | `services/orders.py`, `models/orders.py` |
| Cart + quota / capacity | `Services/Domain/CapacityAssignment/` | `services/cart.py`, `services/quotas.py` |
| Check-in lists, offline sync | `Services/Domain/CheckInList/` | `services/checkin.py`, `models/checkin.py` |
| Vouchers / promo codes | `Services/Domain/PromoCode/` | `services/vouchers.py`, `models/vouchers.py` |
| Tax rules | `Services/Domain/Tax/` | `services/tax.py`, `models/tax.py` |
| Invoices + numbering | `Services/Domain/Invoice/` | `services/invoices.py`, `models/invoices.py` |
| Waitlist | `Services/Domain/Waitlist/` | `services/waitinglist.py` |
| Payments / refunds | `Services/Domain/Payment/` | `services/payment.py`, `base/payment.py` |
| Transactional mail | `Services/Domain/Mail/`, `Services/Domain/Email/` | `services/mail.py`, `services/notifications.py` |
| Wallet passes | `Services/Domain/Wallet/` | plugin ecosystem (passbook) |
| Webhooks / public API | `CreateWebhookService.php`, `Http/Actions/` | `src/pretix/api/` (webhooks, REST) |
| Event cancellation | — | `services/cancelevent.py` |
| Data retention / GDPR | — | `services/shredder.py` |
| Plugin architecture | — | `src/pretix/plugins/`, `base/signals.py` |

`KANBAN.md` → "borrowed from hi.events + pretix research" is the running
list of features picked out of them.
