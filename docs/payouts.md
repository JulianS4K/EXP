# Marketplace payouts

Exos checkouts pay the organizer directly (Stripe destination charges). Marketplace sales don't: the marketplace
pays Exos, usually about a week after the event, and Exos pays each organizer their share. This is the ledger and
the job that does it.

- **Migration:** `20260929070000_exos_payout_ledger.sql`. Tests: `tests/exos/test_payout_ledger.sql` (P1–P5),
  `src/lib/payouts/payouts.test.ts`.
- **Code:** `supabase/functions/_shared/payouts/payouts.ts` (pure), `supabase/functions/exos-payouts/index.ts` (the job).

## The money for one marketplace order

| Field (`exos_marketplace_orders`) | Meaning |
|---|---|
| `proceeds` | what the marketplace pays for the order (after its own seller fee) |
| `exos_fee` | 3% of proceeds, or 0 during the org's first 6 months (`exos_org_billing`) |
| `organizer_net` | proceeds − exos_fee: what the organizer is paid |

`exos_marketplace_order_money` (a view organizers can read for their own orders) says where each order stands:

| State | Meaning |
|---|---|
| `awaiting_delivery` | tickets not delivered yet |
| `awaiting_marketplace` | delivered; the marketplace hasn't reported paying |
| `reported_unconfirmed` | the marketplace says it paid; nobody has confirmed the cash arrived |
| `payable` | delivered, and confirmed money covers the proceeds |
| `in_payout` / `paid` | in a planned or sending payout / sent |
| `cancelled` | cancelled before any payout |
| `clawback_due` / `clawed_back` | cancelled after the organizer was paid; taken back / taken off a later payout |
| `needs_price` | no proceeds recorded (the marketplace didn't report a payout amount) |

## Remittances: what a marketplace paid

`exos_record_remittance(p)` (service role) records one payment from a marketplace, and the orders it covers:

```json
{ "channel": "evo", "external_id": "evo-order-19196777", "amount": 31.51, "source": "marketplace_api",
  "reference": "payment 18582737", "allocations": [{ "external_order_id": "19196777", "amount": 31.51 }] }
```

It's idempotent on `(channel, external_id)` and returns orders it couldn't match. A remittance counts toward
payouts **only once confirmed** (`exos_confirm_remittance(id, by)`): TEvo marks an EvoPay payment "completed" when
it's applied to the order, seconds after the sale, long before cash moves (order 8089940-19196777). A confirmed
remittance is never changed.

Sources today:

- **TEvo:** `exos-payouts` reads each delivered order's payments (`GET /v9/payments?order_id=`, read-only) and
  records the proceeds once TEvo shows them settled, with no refund or unknown state.
- **Others (StubHub, SeatGeek, Gametime, GoTickets, Vivid):** record them from their payout statements with
  `source: "statement"` or `"manual"`. Their payout-report APIs aren't wired yet.

**Confirming:** after the money shows up in the bank or on the marketplace's payout statement, confirm the matching
remittances. This is the one manual step, and it's what stops Exos paying organizers money it hasn't received.

## Payouts

`exos_plan_org_payouts()` makes at most one open payout per org and currency: the `organizer_net` of every
payable order, less clawbacks. A total of zero or less isn't paid, and the balance carries forward. Each order is
paid once (`UNIQUE (order_id, kind)`).

Payout states: `planned` → `sending` → `sent` (with the Stripe transfer id) or `failed` → `planned` (retry).
`exos_cancel_org_payout` cancels a planned or failed payout and frees its orders.

`exos-payouts` (cron, `x-cron-secret`) does, each run:

1. TEvo remittances (above).
2. Plan payouts.
3. Send each planned payout as a **Stripe Connect transfer** from the platform balance to the org's connected
   account (`exos_org_secrets.payments.connectedAccountId`), with the payout's idempotency key. A payout is held
   when the org has no connected account or can't receive payouts yet, and cancelled (re-planned next run) when one
   of its orders was cancelled after planning.

**Dry-run by default.** Money only moves when `EXOS_PAYOUTS_LIVE=true`; until then a run reports what it would send.
A payout left in `sending` by a crash is safe to resend: Stripe dedupes on the idempotency key.

## Operator setup

- Apply `20260929070000` (after `20260929062000`).
- Deploy: `supabase functions deploy exos-payouts --no-verify-jwt` (cron-secret auth).
- Secrets: `CRON_SECRET`, `STRIPE_SECRET_KEY`, optional `TEVO_API_TOKEN` / `TEVO_API_SECRET` / `TEVO_ENV`.
- Schedule (a cron change: operator permission), for example daily:
  `select net.http_post(url := '<functions-url>/exos-payouts', headers := jsonb_build_object('x-cron-secret', '<secret>'));`
- The platform balance must hold the marketplace money before a transfer can go out: marketplace payouts land in
  the bank account, so top up the Stripe balance (or pay marketplace remittances into it) before going live.
- Go live: set `EXOS_PAYOUTS_LIVE=true` after one dry-run looks right.
