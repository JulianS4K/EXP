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

## How Exos checkout money reaches organizers

Exos checkouts are **destination charges**: the buyer pays the platform account, Stripe keeps the
application fee (the Exos fee plus the card-fee estimate) on the platform and transfers the rest to the
organizer's connected account in the same moment (`exos_order_payments.transfer_id`). From there Stripe
pays the connected account's bank on the account's own payout schedule (in the US, daily on a two-day
rolling basis by default; Standard accounts set their schedule in their Stripe dashboard). Exos never
holds that money. The pieces below are built on top of that model and don't change it.

## Instant payouts (organizers)

Migration `20261102150000_exos_promoter_wedge.sql`, function `exos-instant-payouts`, pure rules
`supabase/functions/_shared/payouts/instant.ts`. Tests: `tests/exos/test_promoter_wedge.sql` (PW10),
`src/lib/promoterWedge.test.ts`. UI: **Get paid now** on `/orgs/:orgId/payouts` (`InstantPayoutPanel`).

- **Who:** the org **owner** only (the function checks the JWT and membership; the SQL re-checks).
- **What:** a Stripe Instant Payout (`POST /v1/payouts`, `method: instant`, `Stripe-Account: <org's
  connected account>`) from the account's `instant_available` balance. Stripe decides eligibility (an
  instant-capable debit card or bank, settled funds); the quote says so when there's nothing to send.
- **Fee:** shown before confirming. Estimate = max(`EXOS_INSTANT_PAYOUT_FEE_MIN_CENTS` (50),
  ceil(amount x `EXOS_INSTANT_PAYOUT_FEE_BPS` (150) / 10000)); Stripe's actual fee on the payout is the
  real one and comes out of the account balance, so the amount offered is capped so amount + fee fits.
- **Ledger:** `exos_org_instant_payouts`, one row per request, recorded before Stripe is called
  (`exos_instant_payout_begin`, idempotent per `(org, key)`, at most 5 a day), then `sent` with the
  payout id or `failed` with Stripe's message. The Stripe call carries the same idempotency key. Owner and
  finance read their org's rows (RLS).
- **Switch:** off unless `EXOS_INSTANT_PAYOUTS=on`; the panel hides when off.
- **Account type:** this works for connected accounts whose payouts the platform may manage (Express /
  Custom, `EXOS_CONNECT_ACCOUNT_TYPE=express`). A Standard account manages its own payouts, and Stripe may
  refuse the call; the panel shows Stripe's message. Operator decision: whether to move new orgs to Express.

## Promoter payouts

Same migration; function `exos-promoter-payouts`; pure rules
`supabase/functions/_shared/payouts/promoterTransfers.ts`. Tests: PW1-PW9, `src/lib/promoterWedge.test.ts`.
The commission ledger itself is `20260926020000` (accrual per paid ticket, reversal on refund,
clawback netting).

- **Terms:** percent and/or flat per ticket, an optional **step** after N tickets at an event
  (`exos_set_promoter_step`), per-event overrides that replace the whole default. A ticket's place is
  counted when it accrues, under a lock per promoter and event.
- **Settle** (`exos_settle_promoter`, owner / manager): the selected accrued sales of one currency, less
  outstanding clawbacks; the amount must match. Idempotent per `(promoter, key)`. `via = 'manual'` records
  money paid outside Exos (as `exos_record_promoter_payout` did); `via = 'stripe'` creates a payout in
  `transfer_status = 'pending'`.
- **Stripe mode needs** the org owner's switch (`exos_org_promoter_payouts.stripe_transfers`, set with
  `exos_set_promoter_stripe_transfers`) and a promoter payout account with the `transfers` capability
  active (`exos_promoter_stripe_accounts`). The promoter creates it from their portal: `POST
  /exos-promoter-payouts/onboard` (kit token) makes a Stripe **Express** account (idempotency key per
  promoter) and returns the onboarding link; `/status` refreshes the state on return.
- **Funding (the cap):** the settle plans `exos_promoter_payout_funding` lines, one per order the
  commission is taken from. Every selected sale must come from a Stripe order with a succeeded payment and
  a transfer id (door, PayPal and staff-issued sales are paid manually). Per order, the line is at most the
  selected commission from that order **and** at most what the organizer still holds from it: amount -
  application fee - succeeded refunds - funding already planned or taken by other payouts. The lines add up
  to the payout amount, or the settle is refused. So Exos never transfers more than the commission the
  organizer received.
- **Send** (`POST /exos-promoter-payouts/send`, owner / manager JWT): `exos_promoter_transfer_claim` leases
  the payout (re-checks the role and the switch, refuses if the lines don't add up), then for each
  planned line a **transfer reversal** of the organizer's order transfer (key `exos-pcf:<payout>:<order>`),
  then one **transfer** to the promoter's account (key `exos-pct:<payout>`, `transfer_group
  exos-promoter-payout-<id>`). Marked `sent` only with the transfer id and every line taken; any Stripe
  error marks `failed` with the message. Retrying is safe: the keys make each call happen once.
- **Dry run by default:** unless `EXOS_PROMOTER_TRANSFERS=on` a send records `dry_run` and moves nothing.
- **The ledger never forgets money that moved.** After a reversal or the transfer succeeds at Stripe, its
  mark is retried; if it still can't be written the call answers an error and the payout stays
  `sending` (never `failed`). Every send claim stamps `send_started_at`, and such a payout can't be
  cancelled until it's **reconciled** (`exos_promoter_transfer_reconcile`): `/cancel` first lists the
  transfers in `exos-promoter-payout-<id>` and the reversals on each order transfer, keeping only those
  whose metadata names this payout (and, for the transfer, the promoter's account; the organizer-return
  transfer doesn't count). A transfer found marks the payout `sent` and the cancel is refused; found
  reversals become `taken` lines that the cancel returns to the organizer; nothing found allows the cancel.
- **Bounded timing** (constants in `_shared/payouts/promoterTransfers.ts`, pinned to the SQL literals and
  checked by `src/lib/promoterWedge.test.ts`): each Stripe call has a 15 s client timeout and no network
  retries; each database call a 3 s timeout; a Stripe payout covers at most 10 orders. So one send (the
  claim's answer, up to 10 reversals and the transfer, each preceded by a lease check, and durable marks
  with up to 3 tries) takes at most 11 x 15 s + 45 x 3 s + 11 x 0.75 s = **308.25 s**, which is less than
  the **6-minute** send lease (never extended), which is less than the **10 minutes** a cancel or
  reconcile waits after a send began. The send also stops on its own clock before a call that couldn't
  finish inside the lease.
- **Leases fence sends.** Every claim (`send`, `reconcile`, `cancel`) mints a new `lease_token`;
  `send` calls `exos_promoter_lease_ok` before each reversal and the transfer. `dry_run` / `failed`
  marks need the current token. A `sent` mark always wins: if it lands after a cancel started (or
  finished) it is recorded, restores the sales the cancel freed that are still unpaid, and sets the
  payout's `alert` (shown in red on the payout in the dashboard), never dropped. A reversal recorded
  after its line was released or returned also sets `alert`.
- **Cancel is a fenced state machine.** The cancel claim moves the payout to `cancel_pending` under its
  lease before any Stripe call (send refuses it from then on, also once a return key exists). After a
  reconcile, `exos_promoter_return_begin` records the return transfer's key (`exos-pcr:<payout>`) and
  amount and moves it to `return_pending`; the function then reuses a return already in the payout's
  `transfer_group` or makes it with that key, records it (`exos_promoter_return_done`, which marks every
  taken line returned in one statement, checked through `durably`), and finishes
  (`exos_promoter_payout_cancel`). Any failure stops with an error, releases the lease and leaves the
  payout fenced; running Cancel again resumes from the recorded state and never makes a second return.
- **Retries reconcile first.** A send claim on a payout whose earlier attempt was never reconciled
  answers `needs_reconcile`; the function takes a `reconcile` lease, lists Stripe and, if the transfer
  exists, marks the payout sent and creates nothing.
- **Idempotency keys are per payout, not per attempt** (`exos-pct:<payout>`, `exos-pcf:<payout>:<order>`,
  `exos-pcr:<payout>`). Within Stripe's 24-hour window a repeated call returns the first result. After
  it Stripe forgets the key and would create a new object, which is why the reconcile before every retry
  (and every cancel) is what actually prevents a second transfer.
- **Cancel** (`/cancel`): a Stripe payout not yet `sent` can be cancelled. Money already taken from the
  organizer goes back to their connected account first (one transfer, key `exos-pcr:<payout>`); then
  `exos_promoter_payout_cancel` releases the lines, returns the sales to unpaid and re-opens the
  clawbacks it had netted.
- **What the promoter sees** (`exos_promoter_earnings`, refreshed every 30 seconds on `/p/:token`): owed,
  paid, on its way (a Stripe payout not yet sent), their sales and per-event terms, and payouts with status.
- **Refunds after a payout** are clawbacks, netted from the next payout as before; a Stripe payout's
  amount is already net of them.

Operator setup (all operator-gated): apply `20261102150000`; deploy `exos-promoter-payouts`,
`exos-instant-payouts` and `exos-rsvp` with `--no-verify-jwt` (they check JWTs / tokens themselves and
answer CORS only for `EXOS_REDIRECT_ORIGINS`, except `exos-rsvp`, which is public like `exos-signup`);
secrets `STRIPE_SECRET_KEY`, `EXOS_REDIRECT_ORIGINS`, `EXOS_APP_URL`, `EXOS_GUEST_IP_SALT`; switches
`EXOS_PROMOTER_TRANSFERS`, `EXOS_INSTANT_PAYOUTS` (both off by default). Stripe Connect must allow Express
accounts for promoters on the platform.

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
