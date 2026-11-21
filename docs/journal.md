# Money journal, sales tax by jurisdiction, $0 orders

Migrations `20261108100000_exos_money_journal.sql`, `20261110100000_exos_journal_complete.sql` (card at the door,
gift cards, payouts, the drawer) and `20261111130000_exos_journal_payouts_tax.sql` (Stripe's scheduled payouts, the tax
report read from the journal, the owed gift card fee handed back). Tests: `tests/exos/test_money_journal.sql`,
`tests/exos/test_journal_complete.sql` and `tests/exos/test_journal_payouts_tax.sql` (run by `run_p0.sh`),
`tests/exos/race_money_journal.sh` and `tests/exos/race_journal_payouts.sh` (CI, after `run_p0.sh`), the simulation's
invariant I10 (`tests/exos/e2e_helpers.sql`), `src/lib/journal.test.ts`, `src/lib/payouts/orgPayouts.test.ts`. Code: `src/lib/journal.ts` (pure),
`src/lib/journalApi.ts` (reads), `src/components/finance/JournalPanel.tsx` (Payouts page),
`src/components/finance/EventSalesTax.tsx` (the event's Money section), `supabase/functions/exos-api/journal.ts`
(`GET /v1/journal`, `docs/api/journal.json`).

## What it is

A minimal double-entry journal per organization: the organizer's books as Exos sees them. Every entry balances
(debits = credits, integer cents), is idempotent on `(source_table, source_id, kind)`, and is never edited or deleted.
A change after the fact is a further entry: a reversal (`reverses` names the entry it undoes) or the difference to the
new state. Triggers on the money tables post the entries; a posting failure is a WARNING and never undoes a sale.
`_exos_journal_backfill(org)` (service role) posts anything missing and is safe to run again; the migration runs it
once for every org.

It follows the existing money model, never a second one: the settlement (`src/lib/settlement.ts`),
`exos_order_money`, the reporting-row split (`_exos_gl_backfill`), POS settlement (`exos_pos_settlement_summary`).
`exos_journal_trial_balance` per org and period always nets to zero per currency.

## The chart

| # | Account | Type |
|---|---|---|
| 1000 | Cash at Stripe / clearing (`stripe_clearing`) | asset |
| 1010 | PayPal balance due from Exos (`paypal_receivable`) | asset |
| 1020 | POS cash drawer | asset |
| 1030 | Bank (payouts received) | asset |
| 1040 | Cash on hand (outside Exos): the drawer float's source, counted cash after close, cash / checks / cards taken outside Exos | asset |
| 1100 | Marketplace receivable | asset |
| 2000 | Organizer payable (owed to Exos) | liability |
| 2100 | Sales tax payable | liability |
| 2200 | Promoter commissions payable | liability |
| 2300 | Gift cards outstanding | liability |
| 2400 | Tips payable (POS) | liability |
| 3000 | Opening balances (imported gift cards) | equity |
| 4000 | Ticket revenue (face; add-ons included) | revenue |
| 4010 | Buyer fees (passed-on fee rules) | revenue |
| 4020 | Bar and merch sales (POS) | revenue |
| 4030 | Donations | revenue |
| 4040 | Gift card breakage (voided balances) | revenue |
| 4900 | Refunds | contra revenue |
| 5000 | Exos fee | expense |
| 5010 | Card processing fees | expense |
| 5020 | Disputes | expense |
| 5030 | Promoter commissions | expense |
| 5040 | Cash paid-outs (POS) | expense |
| 5050 | Cash over / short (POS) | expense |
| 5060 | Gift cards given away | expense |

## What posts what

| Source | Entry |
|---|---|
| Paid order (`exos_checkout_sessions`, fulfilled / refunded) | `sale`: Dr clearing (charge), Dr gift cards (gift-card part); Cr face, buyer fees, tax, donation (the `_exos_gl_backfill` split). Dr Exos fee + card fees, Cr clearing: the application fee withheld. An Exos fee not withheld (`exos_fee_owed_cents`, gift cards): Dr Exos fee, Cr organizer payable. Clearing is the PayPal receivable for a PayPal order. A $0 order posts nothing. |
| Refund (`exos_order_refunds`, succeeded) | `refund`: Dr refunds + tax (the credit note's tax, else pro rata), Cr clearing (the organizer's share), Cr Exos fee + card fees (the application fee comes back in proportion). Cumulative per order, so partial refunds add up to the settlement's net after refunds exactly. A refund that fails later: `refund_reversal`. |
| Fee-change log (`exos_fee_adjustments`) | `fee_adjustment`, no cash: the buyer-fee part of a refund moves from Refunds to Buyer fees; any other change moves between Ticket revenue and Buyer fees. |
| Dispute (`exos_disputes`) | A Stripe charge is a destination charge, so a dispute hits Exos's balance: the organizer's books change only when it is lost and the org's recovery policy is on (`dispute_lost`: Dr disputes, Cr organizer payable, amount + fee). Waiving the recovery reverses it. A lost PayPal dispute writes off what Exos owed for the order. |
| Marketplace order | `mkt_sale`: Dr marketplace receivable (net) + Exos fee, Cr face (proceeds). Re-priced: `mkt_adjust` (the difference); cancelled: `mkt_cancel`. |
| Marketplace payout line, once the payout is `sent` | `mkt_payout`: Dr clearing, Cr receivable (a clawback the other way). |
| Promoter commission | `commission_accrued`: Dr commissions, Cr payable; `commission_paid`: Dr payable, Cr clearing; reversed: `commission_reversed`. Commissions paid inside the Exos fee (`platform_fee`) are Exos's cost and post nothing. |
| POS cash tender (`exos_pos_payments`, cash) | `pos_cash_sale`: Dr drawer (amount + tip), Cr tips, tax (pro rata to the order), face / bar and merch (by the order's lines). |
| POS cash out (`exos_pos_paid_outs`) | `pos_void` / `pos_refund`: Dr refunds + tax, Cr drawer. `pos_paid_out`: Dr cash paid-outs, Cr drawer. |
| POS card tender (`exos_pos_payments`, card; Stripe Terminal) | `pos_card_sale`, like an online order: Dr clearing (charge), Cr tax, face / bar and merch (the order's lines, as cash); Dr Exos fee + card fees, Cr clearing: the application fee withheld (`exos_pos_card_payments`). A capture that never became a sale (`refund_pending`) posts nothing: in and out at Stripe. |
| POS card refund (`exos_pos_reversals`, `card_refund_status` succeeded) | `pos_card_refund`: Dr refunds + tax, Cr clearing (net), Cr Exos fee + card fees (the application fee comes back in proportion, as online). Nothing while the refund is pending. |
| Gift card sale (`exos_gift_card_ledger`, issue) | `gc_issue`: Cr gift cards outstanding (a liability, never revenue). Dr: online, Stripe clearing less the application fee (Dr Exos fee; the commerce order's `application_fee_cents`); cash sold from a drawer, the drawer; cash, check or a card taken outside Exos, cash on hand; a comp, gift cards given away; an import, opening balances. |
| Gift card redemption | On a checkout order: the order's own `sale` entry (Dr gift cards, above): nothing posts from the ledger's hold / release rows. On a partner reservation (`exos_gift_card_redemptions`, captured when the reservation completes): `gc_redeem`: Dr gift cards, Cr ticket revenue. |
| Refund back to a gift card (`exos_gift_card_ledger`, refund) | `gc_refund`: Dr refunds + the tax share (the order's tax × the amount ÷ the order's value, never more than the order's tax not yet handed back), Cr gift cards outstanding: the liability is restored. When the order owes an Exos fee on its gift card part (`exos_fee_owed_cents`), `gc_refund_fee` (same ledger row): Dr organizer payable, Cr Exos fee, the owed fee × the part handed back ÷ the order's gift card part, cumulative over the order's refund rows in id order (like a card refund's application fee), so the parts hand back exactly the whole owed fee. |
| Gift card void (`exos_gift_card_ledger`, void) | `gc_void`: Dr gift cards, Cr breakage. When the purchase itself was refunded (`exos_commerce_refund` voids the card): `gc_purchase_refund`: Dr gift cards, Cr clearing (net), Cr Exos fee (returned in proportion). |
| Instant payout (`exos_org_instant_payouts`, sent) | `stripe_payout`: Dr bank, Cr Stripe clearing; one that fails later: `stripe_payout_reversal`. |
| Stripe payout from the connected account (`exos_stripe_org_payouts`, paid) | `stripe_payout`: Dr bank, Cr Stripe clearing (a negative payout, Stripe debiting the bank, the other way), dated by its arrival; paid then failed: `stripe_payout_reversal`. Synced on the payout id. An instant payout Exos sent posts from `exos_org_instant_payouts` instead, never twice. |
| PayPal remittance (`exos_paypal_org_remittances`) | `paypal_remittance`: Dr bank (Stripe clearing for a `stripe_transfer`), Cr PayPal receivable. |
| Drawer (`exos_pos_drawer_sessions`) | `drawer_float`: Dr drawer, Cr cash on hand. At close: `drawer_variance` (source id `<drawer>:variance`): Dr / Cr drawer against cash over / short (counted − expected); `drawer_close` (`<drawer>:close`): Dr cash on hand, Cr drawer (the counted cash leaves). A recount posts the difference (`…_adjust`). The drawer's postings are the close's expected terms, so a closed drawer nets to zero. |

Gift cards are posted at commit (a deferred trigger on the ledger): a box-office card is tied to its drawer, and a
refunded purchase's commerce order marked refunded, right after the ledger row is written.

Not in the journal: Stripe's fee on an instant payout (only an estimate is known), absorbed fees (an allocation, not
money).

## Payouts to the bank

Which payouts Exos can see. A Stripe checkout is a destination charge: the charge is the platform's, Stripe moves the
organizer's share to their connected account, and the connected account pays out to the organizer's bank on its own
schedule. The platform's balance transactions (`exos-reconcile-stripe` stores them in `exos_stripe_balance_txns`)
therefore carry the charge, the application fee and the transfer to the account, but never the account's payouts: a
`payout` there is the platform's own payout of its fees to Exos's bank, not the organizer's. So nothing Exos stored
before recorded a scheduled payout. Stripe does let a Connect platform read a connected account's objects with the
`Stripe-Account` header, and Exos already reads the account's balance that way (`exos-instant-payouts`), so:

- `exos-reconcile-stripe` (cron secret, the same run as the reconciliation, not scheduled yet) lists each connected
  account's payouts (`GET /v1/payouts`, `Stripe-Account: acct_…`; a read, never a write) created from 14 days before
  its window, since Stripe marks a payout paid or failed days after creating it, and hands them per org to
  `exos_stripe_org_payouts_record` (service role). `EXOS_RECONCILE_PAYOUTS=off` skips the step; a failure there is
  reported and never fails the reconciliation.
- The record checks the account is the org's own (`exos_org_secrets.payments.connectedAccountId`), upserts one row per
  payout id (`exos_stripe_org_payouts`: amount, currency, status, method, arrival), never moves a payout another org
  recorded, and only moves a status forward (pending, in transit, paid, then failed / canceled). Paid, failed and
  canceled are in the org's audit log (`payout.stripe_status`).
- A paid payout posts Dr bank, Cr Stripe clearing; a failure after paid reverses it. Stripe clearing is the
  organizer's Stripe balance as the journal sees it (charges less the application fee, less refunds), so after the
  payouts it holds what is still at Stripe.
- Instant payouts show up in the same list. One Exos sent (`exos_org_instant_payouts.stripe_payout_id`) is posted from
  there; its Stripe row posts nothing, and if the Stripe row is recorded first, its posting is taken back when the
  instant payout learns its id. An instant payout taken outside Exos (Stripe's dashboard) posts from the Stripe row.

**TODO (operator decision): the Exos fee on walk-up cash sales is NOT posted.** Whether Exos charges a fee on cash taken
at the door, and how it would be collected (there is no charge to withhold it from), is open (docs/pos.md). Until it is
decided, `pos_cash_sale` carries no Exos fee line and nothing records one as owed; when it is decided, post it as an
`organizer_payable` line (Dr Exos fee, Cr organizer payable, like the gift card part of an online order).

## Reads

- Payouts page: a period, the trial balance per currency, **Journal CSV** (date, entry id and number, source, account,
  debit, credit, currency, memo) and sales tax by jurisdiction (CSV too).
- `exos_journal_rows` (security-invoker view, one row per line) and the two tables: owner / manager / finance of the
  org through RLS. `exos_journal_trial_balance(org, from, to, event)`: the same people (or the service role).
- `GET /v1/journal` (`finance:read`, paged; `from`, `to`, `event_id`, `account`, `source`).

## Sales tax by jurisdiction

`exos_sales_tax_report(org, from, to, event)`: grouped by the venue's location (`exos_events.venue_address`: country,
region, city, postal code), the tax rule (name and rate of the tier / add-on's `exos_tax_rules` row) and the source.
Every tax amount is a journal line on sales tax payable (mig `20261111130000`), so the report and the journal always
agree: its net per org, currency, event and period is exactly what sales tax payable moved (`check_invariants()` I10
in the simulation, `test_journal_payouts_tax.sql` JP3). Collected = the sale entries (an order, a door tender);
refunded = every other entry on the account: a card refund (the credit note's tax, else pro rata), a refund back to a
gift card (its tax share), a door void / refund / card refund, and a refund that failed later counts back. Each
entry's amount is spread over its order's rates by the order's own split: online, the price-disclosure lines' tax (tax
a line doesn't explain is "Rate not recorded"); at the door, the order lines' tax; the remainder goes to the largest
rate. Dated by the journal entry (the sale: fulfilment; a refund: when it was made). Taxable and order counts still
come from the orders in the period (online: fulfilment; door: the part paid in money, a comp tender collects none).
Before this, refunded counted only the credit notes, so a refund back to a gift card, a refund with no credit note
and a door refund of part of a sale read differently from the journal. On the Payouts page (the org, a period) and in
the event's Money section. Exos doesn't file or remit tax.

## $0 orders for free claims and comps

Tickets minted with no order (free claims, comps from the box office, a batch or a staff mint, RSVPs, referral
rewards, comps at the door) now get a `$0` `exos_checkout_sessions` row (`free_kind`: `free_claim`, `comp`, `rsvp`,
`referral`, `pos_comp`), one per mint call and holder, so order lists, exports, the API and fans see them. A trigger on
`exos_tickets` does it, so no mint function is patched; the tickets keep their `order_ref` (refund, reschedule and door
paths match by it, and see exactly what they saw before). No invoice (the invoice trigger only runs on an update to
`fulfilled` above $0, mig `20261001100000`), no journal entry, no money. A comp parked on a staff member (no account
yet) is the recipient's (a guest order by email); a phone-only RSVP with no email gets none. The reports that already
count those tickets from `exos_tickets` (channel lines, buyer geo, the cash summary, the reporting rows, the in-app
report) leave the `$0` rows out (marker `/* exos: zero orders */`), and so do the settlement and the sources report in
the browser; `tests/exos/test_money_journal.sql` MJ9 checks they read the same with and without them.
