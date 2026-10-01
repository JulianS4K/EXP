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

## Disputes (chargebacks)

Exos checkouts are destination charges, so a chargeback is opened against the **Exos platform's** Stripe account:
Stripe takes the amount plus its dispute fee from the platform balance, not from the organizer. Migration
`20261001101000_exos_disputes_reconciliation.sql` (**not applied**) records and announces them. Tests:
`tests/exos/test_disputes_reconciliation.sql` (D1–D4), `src/lib/disputes.test.ts`, the dispute cases in
`src/lib/mailTemplates.test.ts`, and the smoke test for the Disputes block.

- **Record.** `stripe-webhook` sends every `charge.dispute.created` / `.updated` / `.closed` to
  `exos_record_dispute_event` (service role). It runs `exos_record_dispute` as before (the session's `dispute_*`
  columns and the payment row's meta, same return value, so a **lost** dispute still voids the order through
  `exos_refund_checkout`) and upserts one `exos_disputes` row per Stripe dispute: session, event, PaymentIntent,
  charge, amount, Stripe's dispute fee (the sum of the fees on the dispute's own balance transactions), currency,
  reason, status, evidence deadline (`evidence_details.due_by`), evidence submitted, opened / closed times, and
  `raw`, an allowlisted copy of the Stripe object without the `evidence` block (buyer name, email, IP, addresses,
  files) or metadata (`_shared/disputes.ts`, repeated in SQL by `_exos_dispute_raw`). A closed status (won / lost /
  warning_closed) is final: a replayed earlier event doesn't reopen it. Until the migration is applied the webhook
  falls back to `exos_record_dispute` alone.
- **Tell the organizer.** Mail to the org owner and active finance members, once per dispute and person:
  `dispute-opened` (amount, reason, evidence deadline, the event's Money section, the dispute in the Stripe
  dashboard), `dispute-won`, `dispute-lost` (`docs/email.md`). A mail problem is logged and never fails the webhook.
- **See it.** A Disputes block under the event's Money section and on the org's Payouts page (owner / manager /
  finance; RLS on `exos_disputes`): status, reason, amount and fee, evidence due date, the order, a link to Stripe.
- **Evidence** is submitted from the platform's Stripe dashboard (organizers can't see the platform account), so the
  mail and the block ask the organizer to send the Exos team what they have before the deadline. Evidence tooling
  in Exos isn't built.

## Recovery policy for lost disputes

`exos_org_billing.recover_lost_disputes` (per org, **default false**, server-written like the rest of the row):

- **false** (today): the platform absorbs a lost dispute. The row gets `recovery_status = 'not_recovered'`.
- **true**: the row gets `recovery_status = 'recovery_pending'` and `recovery_candidate_cents` = amount + dispute fee,
  and the lost-dispute mail says that amount can be taken from a later payout.

Nothing moves money either way. Recovering it would be a later payout job reversing the organizer's transfer
(`transfers.createReversal` on the charge's `transfer_id`, capped at what was transferred) or netting it off a
marketplace payout. That is a Stripe write and needs operator sign-off, so it isn't built. The payout ledger's
clawback line (`exos_org_payout_lines`, kind `clawback`) is keyed to a marketplace order (`order_id NOT NULL
REFERENCES exos_marketplace_orders`), so a checkout dispute can't be one; the candidate is reported on the dispute
row and in the Disputes block only. Operator decisions still open: whether to recover at all, and how (transfer
reversal vs. payout netting vs. invoicing the organizer).

## Daily Stripe reconciliation

`exos-reconcile-stripe` (cron secret, **read-only at Stripe**; not deployed, not scheduled) compares the platform
account's balance transactions with the Exos ledger. Pure diff: `supabase/functions/_shared/reconcile.ts`
(`src/lib/reconcile.test.ts`); SQL: the same migration (tests R1–R2).

Each run:

1. Lists the balance transactions created in the last N days (`{"days": N}` in the body, else
   `EXOS_RECONCILE_DAYS`, else 3; at most 90), paginated, source expanded. It stops at 20,000 transactions or 90
   seconds; a cut-off run stores what it read and records no findings (run it with fewer days).
2. Stores them in `exos_stripe_balance_txns` (service role only; upsert on the txn id).
3. Diffs them against `exos_order_payments`, `exos_order_refunds` and `exos_disputes`:

   | Kind | Meaning |
   |---|---|
   | `stripe_payment_missing` | Stripe booked a charge Exos has no payment row for (a missed webhook, or a charge made outside Exos) |
   | `exos_payment_missing` | a succeeded Exos payment has no Stripe charge in the window |
   | `payment_status_mismatch` | Stripe charged, the Exos payment row isn't `succeeded` |
   | `amount_mismatch` | the charge's amount or currency differs from the payment row |
   | `fee_mismatch` | Stripe's fee differs from `exos_order_payments.stripe_fee_cents` (a NULL fee isn't flagged; `exos-reconcile-checkouts` fills it) |
   | `stripe_refund_missing` / `exos_refund_missing` | a refund on one side only |
   | `refund_amount_mismatch` | refund amount or currency differs |
   | `stripe_dispute_missing` | Stripe moved money for a dispute Exos never recorded |

   Transfers, payouts and other balance movements are counted, not compared. Exos rows within an hour of either
   end of the window aren't checked for a missing Stripe movement, so a boundary doesn't flap.
4. Records the findings with `exos_reconcile_stripe_record`: one `exos_reconciliation_issues` row per (kind, key)
   with `first_seen`, `last_seen`, `seen_days`; an open issue inside the checked window that isn't found again is
   resolved, one found again is reopened; one `exos_reconciliation_runs` row per day. A second run the same day
   changes nothing but timestamps.

Who sees the issues: platform admins, all of them (`exos_reconciliation_issues_for(NULL)`); an org's owner and
finance members, the ones on their org's sessions (RLS and `exos_reconciliation_issues_for(org_id)`). Issues Exos
can't tie to an org (a Stripe charge with no Exos row) are admin only. There is no screen yet.

Without `STRIPE_SECRET_KEY` (payments are off in prod) the function answers **503 "payments are switched off"**
and touches nothing.

Operator setup (all operator-gated):

- Apply `20261001101000` (after `20261001100000`).
- Deploy `stripe-webhook` (for dispute records) and `exos-reconcile-stripe`
  (`supabase functions deploy exos-reconcile-stripe --no-verify-jwt`); secrets `CRON_SECRET`, `STRIPE_SECRET_KEY`,
  optional `EXOS_RECONCILE_DAYS`.
- Schedule it daily (a cron change needs operator permission; **not scheduled**), for example 06:07 UTC:
  `select cron.schedule('exos-reconcile-stripe-daily', '7 6 * * *', $$select net.http_post(url := '<functions-url>/exos-reconcile-stripe', headers := jsonb_build_object('x-cron-secret', '<secret>', 'content-type', 'application/json'), body := '{"days": 3}'::jsonb);$$);`
