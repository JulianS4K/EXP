# Money journal, sales tax by jurisdiction, $0 orders

Migration `20261108100000_exos_money_journal.sql`. Tests: `tests/exos/test_money_journal.sql` (run by `run_p0.sh`),
`tests/exos/race_money_journal.sh` (by hand), `src/lib/journal.test.ts`. Code: `src/lib/journal.ts` (pure),
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
| 1100 | Marketplace receivable | asset |
| 2000 | Organizer payable (owed to Exos) | liability |
| 2100 | Sales tax payable | liability |
| 2200 | Promoter commissions payable | liability |
| 2300 | Gift cards outstanding | liability |
| 2400 | Tips payable (POS) | liability |
| 4000 | Ticket revenue (face; add-ons included) | revenue |
| 4010 | Buyer fees (passed-on fee rules) | revenue |
| 4020 | Bar and merch sales (POS) | revenue |
| 4030 | Donations | revenue |
| 4900 | Refunds | contra revenue |
| 5000 | Exos fee | expense |
| 5010 | Card processing fees | expense |
| 5020 | Disputes | expense |
| 5030 | Promoter commissions | expense |
| 5040 | Cash paid-outs (POS) | expense |

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

Not in the journal yet: POS card tenders (Stripe Terminal), gift card sales and gift-card balance restored on a refund,
PayPal remittances to the org, Stripe payouts to the organizer's bank, the drawer float and count variance, absorbed
fees (an allocation, not money), the Exos fee on walk-up cash sales (an open operator decision, docs/pos.md).

## Reads

- Payouts page: a period, the trial balance per currency, **Journal CSV** (date, entry id and number, source, account,
  debit, credit, currency, memo) and sales tax by jurisdiction (CSV too).
- `exos_journal_rows` (security-invoker view, one row per line) and the two tables: owner / manager / finance of the
  org through RLS. `exos_journal_trial_balance(org, from, to, event)`: the same people (or the service role).
- `GET /v1/journal` (`finance:read`, paged; `from`, `to`, `event_id`, `account`, `source`).

## Sales tax by jurisdiction

`exos_sales_tax_report(org, from, to, event)`: grouped by the venue's location (`exos_events.venue_address`: country,
region, city, postal code), the tax rule (name and rate of the tier / add-on's `exos_tax_rules` row) and the source.
Online: collected = the price-disclosure lines' tax (tax a line doesn't explain is "Rate not recorded"); refunded = the
credit notes' tax, spread over the order's rates. Door (POS): the order lines' tax on the part paid in money (a comp
tender collects none), refunded when the sale is voided or refunded. On the Payouts page (the org, a period) and in
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
