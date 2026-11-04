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

## Commission methods: where a promoter's commission comes from

Migration `20261104190000_exos_commission_methods.sql`; pure rules
`supabase/functions/_shared/payouts/commissionMethods.ts`; transfers in `exos-promoter-payouts` (`/run`,
`/ct-cancel`). Tests: `tests/exos/test_commission_methods.sql` (CM1-CM14), `src/lib/commissionMethods.test.ts`.
Organizer-facing explanation: `docs/organizer-guide.md` "How promoter commissions are paid".

Four methods, chosen case by case. A per-org default (`exos_org_commission_settings`), a per-event override
(`exos_event_commission_settings.method`) and a per-promoter override (`exos_promoters.commission_method`).
**Most specific wins: promoter, then event, then org, then `manual`.** A method whose switch is off falls back
to `manual` at checkout (`method_source = 'fallback'`), so a sale is never charged a way Exos can't pay out.

| Method | How the money moves | Pros | Cons | Requirements |
|---|---|---|---|---|
| **A. `clawback`** (the wedge above) | Destination charge as before. At settle time Exos reverses the commission out of the organizer's order transfers and transfers it to the promoter. | Organizer paid at once; nothing changes at checkout; Exos never holds the commission. | Needs money still in the organizer's Stripe balance (reversal can fail if they paid out); only online Stripe sales; up to 10 orders per payout. | Owner switch `stripe_transfers` + `EXOS_PROMOTER_TRANSFERS=on`; promoter Express account. |
| **B. `split_at_sale`** | Separate charges and transfers: the charge stays on the platform (no `transfer_data`), `transfer_group = exos-order-<uuid>`. After the holdback Exos transfers the organizer's share and each promoter's commission with `source_transaction` = that charge. | Commission set aside at the sale; no reversals; promoter paid from the order itself. | Organizer is paid only after the event + holdback; **Exos handles disputes on these charges**; refunds after the transfer are netted from the organizer's next split order. | `EXOS_SPLIT_AT_SALE=on` **and** the owner's org switch (`split_at_sale_enabled`); organizer and promoter on **Express** accounts (`EXOS_CONNECT_ACCOUNT_TYPE=express`). |
| **C. `platform_fee`** | Destination charge; the commission is **added to `application_fee_amount`**. After the holdback Exos transfers it from the platform balance to the promoter. | Organizer still paid at once; no reversals; one transfer per promoter. | The organizer's Stripe dashboard shows a bigger application fee (it includes the commission; the dashboard says so); refunds return the fee in proportion, so a partial refund shrinks what's held. | `EXOS_PLATFORM_FEE_COMMISSIONS=on`; promoter Express account. |
| **D. `manual`** (default) | The ledger only. The organizer pays by Venmo / cash and records it (`exos_settle_promoter`, via `manual`). | Works for every sale (door, PayPal, staff); no setup. | Exos can't enforce payment; the organizer chases refunds after payout themselves (netting helps). | None. |

**When to use which.** `manual` while you pay your team yourself or sell mostly at the door. `platform_fee` when
promoters want to be paid by Exos and you want your money at once (the usual pick). `split_at_sale` when you'd
rather the commission never touches your balance, and can wait until after the event for your share. `clawback`
when you already pay out through Stripe and want promoters paid the moment you settle.

- **Buyers see the same all-in price** whichever method. Checkout asks `exos_commission_checkout_plan` only when
  one of the two platform switches is on; with both off (the default) nothing in `exos-checkout` changes.
  Existing destination-charge events are unchanged: a plan of `manual` / `clawback` charges exactly as before
  (`paymentIntentData` returns the old object, pinned by a test). The plan is stored in
  `exos_checkout_commission_plans` (not on the buyer-readable session row); an order charged a new way whose
  plan can't be recorded is expired.
- **Accrual records the method.** `exos_promoter_commissions.method` / `method_source` are set when the sale
  accrues (from the order's plan, else resolved then) and never rewritten. A `platform_fee` sale's commission
  is the checkout quote (what the fee collected); re-pricing leaves it.
- **Locking.** An event's method is pinned (`locked_method`) by its first paid ticket, and before any org default
  change, so a new default never moves an event that has sold. Changing a sold event needs
  `p_future_sales_only = true` and reaches only later sales. Every change is logged
  (`exos_commission_method_changes`).
- **Holdback, frozen at the sale.** Each order's plan and each accrual store `payable_at` when the ticket sells:
  the event's later of `starts_at` / `ends_at` at that moment plus the holdback (org setting 0-30, default 3).
  For the Exos-funded methods the holdback is never below the platform minimum
  (`exos_platform_settings.commission_min_holdback_days`, default 3; org staff can't lower it) and also counts
  from the sale itself, so dating an event in the past doesn't make a fresh sale payable. The time actually used
  is the later of the frozen one and the event as it is now (`_exos_commission_payable_at`): moving an event
  earlier never makes anything payable sooner, a reschedule later pushes it out, and a plan's `payable_at` can't
  be before the event's original start (CHECK). The frozen value is set once (the gate trigger keeps it).
  Enforced on the row (`exos_promoter_commissions_gate`): always for Exos-moved payouts; for `manual` /
  `clawback` once the org has saved commission settings (orgs that never did keep today's behaviour). Every Exos
  send claim re-checks it (`_exos_ct_hold`).
- **Self-dealing cap.** An Exos-funded commission is at most `exos_funded_commission_max_bps` (platform setting,
  default 3000 = 30%) of the ticket's net to the organizer (its base less its share of the Exos fee). Checkout
  falls back to `manual` (`fallback_reason: commission_cap`) when any ticket is over; the accrual clamps to the
  cap if terms changed since. Higher needs a platform-admin row in `exos_commission_cap_approvals` (service role
  only; per org or per promoter, optional expiry).
- **The reserve.** Nothing Exos-funded is planned or sent for an order with an open dispute or a refund in flight
  (a pending refund, a claimed / pending refund request); the send claim re-checks it, so a refund started after
  planning holds the transfer (`refund_in_flight`).
- **Netting.** A sale refunded after it was paid is a negative line in `exos_commission_netting`, owed back by
  the promoter and **taken off their next payout by whoever funded it** (`funder`): organizer-funded lines
  (`manual`, `clawback`) by `exos_settle_promoter` / `exos_record_promoter_payout`; Exos-funded lines (`split`,
  `platform_fee`) by the Exos transfers. Never reversed from the promoter's account. Whole lines, oldest first,
  never more than the payout. A line still open after `netting_alert_days` (default 30) is flagged overdue on
  the dashboard (`exos_commission_balances`).
- **Split orders and refunds.** Before the transfer, the shares are computed from the order as it is
  (`_exos_split_entitlement`: net = charge - refunds; fee = Exos fee less its refunded share; organizer =
  net - fee - commission still standing). After the organizer's share is planned, any later refund, void or lost
  dispute is a **true-up** line (`_exos_split_true_up`, idempotent, from triggers on `exos_order_refunds`,
  `exos_checkout_sessions.dispute_status` and the commission rows), taken off (or, for a credit, added to, up to
  that order's fee) the organizer's next split transfer; what doesn't fit carries forward. Orders with an open
  dispute or a refund in flight wait.
- **Organizer refunds of split orders** (`exos_refund_charge_prepare`, decided once per refund request in
  `exos_refund_charge_plans`, so retries send the same parameters). Before the organizer's share went out, the
  unsent transfer is cancelled and planned again from the smaller order. Once it was sent, the organizer's part
  of the refund (their share before minus their share after) is **taken back from that transfer first**: a
  Stripe transfer reversal (`exos_split_reversals`, lease, reconcile by `metadata.exos_split_reversal_id`, key
  `exos-ctr:<id>`), then the refund (no Connect flags). If the transfer can't cover it (already reversed, or the
  share was fully netted) the refund is **refused** with how much Exos can take back; Exos never funds it. If
  the reversal is refused by Stripe, so is the refund; if the refund then fails after a reversal, the money taken
  is credited back (`exos_split_reversal_unused`). A refund while the share is being sent waits (`busy`).
  A commission Exos already paid and then refunded stays counted against the organizer until the promoter's
  clawback is netted, then the organizer is credited, so Exos never fronts it.
- **The fallback and the debt cap.** Refunds made outside Exos, disputes, or a reversal that couldn't happen are
  true-up lines with an alert on the transfer. Over `split_org_debt_cap_cents` (platform setting, default
  50000) of open debt, the org gets no new split-at-sale checkouts (`fallback_reason: split_debt_cap`) and no
  split money: shares bigger than the debt aren't planned and planned ones are held (`debt_cap`) until the debt
  is netted or settled.
- **Fee orders and refunds.** While the commission is still held, the refund returns the application fee in
  proportion (`refund_application_fee` on, whatever `EXOS_REFUND_KEEP_PLATFORM_FEE` says), so the payout for
  each order is capped at what the fee still holds; any difference is a `shortfall` line. Once the commission
  went out (planned or sent), the refund **keeps the fee** (`refund_application_fee` off; the organizer bears the
  refund, as with a clawback) and the promoter's clawback is owed to the organizer
  (`exos_commission_refund_marks`, netting `funder = organizer`). So a refund never costs Exos more than the fee
  it collected.
- **Exos transfers** (`exos_commission_transfers`, one row = one Stripe transfer, key `exos-ct:<id>`):
  `exos_commission_plan_due` plans what is past the holdback (amounts fixed when planned); `/run` (cron
  `exos-commission-transfers-15min`, created inactive, or an owner / manager for their org) sends what is
  due. Same rules and numbers as the clawback sends: `exos_ct_claim` leases for 6 minutes (never extended),
  `exos_ct_lease_ok` is checked right before the Stripe call, every claim mints a new token, a retry after an
  unreconciled send reconciles first (transfer group + `metadata.exos_ct_id`), a reconcile or cancel waits 10
  minutes after a send began, `'sent'` always wins (a late one restores the sales a cancel freed and sets an
  alert). A dry run (switch off) records `dry_run` and is retried when the switch is on; `failed` is retried up
  to 5 times, then by hand (Retry on the dashboard). `/ct-cancel` cancels one that never went out: the sales are
  unpaid again, netting re-opened, nothing to return (the money never left the platform).
- **Webhook and refunds.** `stripe-webhook` fulfils both charge models the same way; the auto-refund drops the
  two Connect flags for split orders (`chargeModelFromMetadata`, which the reconcile sweep reads the same way;
  nothing was transferred yet for an unfulfilled order). Organizer refunds go through `refundRun` as above.
- **Fee actuals.** For a fee order, `exos_order_payments.application_fee_cents` is Stripe's (Exos fee +
  commission); `net_cents` leaves the commission out.

Operator setup (all operator-gated): apply `20261104190000`; redeploy `exos-checkout`, `stripe-webhook`,
`exos-refund`, `exos-api`, `exos-reconcile-checkouts`, `exos-promoter-payouts`; set `CRON_SECRET` for
`exos-promoter-payouts`; turn on the cron `exos-commission-transfers-15min`; then, when ready,
`EXOS_PLATFORM_FEE_COMMISSIONS=on` and / or `EXOS_SPLIT_AT_SALE=on` (both off by default, test mode first).

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
