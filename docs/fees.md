# Fee rules (passed on or absorbed)

Organizers and venues can add their own fees: "$2 facility fee per ticket", "3% service charge", "$1.50 per order".
Each fee is either **passed on** (the buyer pays it, inside the all-in price) or **absorbed** (the organizer pays it out
of revenue). This is not the Exos platform fee (3%, paid by the organizer, `_shared/platformFee.ts`), which is unchanged.

- **Code:** `supabase/functions/_shared/fees.ts` (the maths; `src/lib/fees.ts` is an identical copy),
  `_shared/pricing.ts` / `src/lib/pricing.ts` (`allInCents` / `allInPrice` fold the fees in),
  `_shared/feeRulesRead.ts` (the feeds' read), `src/lib/feeRules.ts` (storefront read + organizer CRUD),
  `src/components/FeeRulesEditor.tsx` (Org settings and the event editor), `supabase/functions/exos-checkout/index.ts`.
- **Migration:** `20261027100000_exos_fee_rules.sql`.
- **Tests:** `src/lib/fees.test.ts` (parity, rounding, breakdown), `src/lib/feeRules.test.ts`, the feed and SEO tests,
  `tests/exos/test_fee_rules.sql` (run by `run_p0.sh`).

## All-in, always

Every price a buyer sees is the full amount they pay (operator decision 2026-09-24; NY Arts & Cultural Affairs Law
§ 25.07, FTC fee rule). A passed-on fee is therefore **folded into the price**, never shown as a separate line at
checkout: the event page, the "from $X" cards, the embed, link previews, the Google events feed, the ad catalog feeds
and the Stripe charge all use the same functions (`tierPassedOnFees` → `allInPrice` / `allInCents`), so the displayed
price and the charge match to the cent (`fees.test.ts` checks the two copies over thousands of generated cases). The
price-disclosure record keeps the passed-on fees per line (`fee_cents`, the export's `buyer_fees` column), and its
shown total is still exactly what Stripe charges.

Where the fee may be named:

- the event page under the price ("Each ticket includes $2.00 facility fee"),
- the Stripe line description ("Includes 2.00 USD facility fee and 0.36 USD tax per item"),
- the receipt mail ("the prices above include 6.00 facility fee; nothing was added at checkout"),
- the invoice / receipt document (`fees` in `exos_invoice_document`, the note under the totals),
- the organizer's reports (`exos_order_fees`).

## Rules

| Field | Meaning |
|---|---|
| `name` | Shown to buyers ("Facility fee") and in reports. |
| `recipient` | Who the money is for, a label for reports and settlements: `org`, `venue`, `promoter`, … |
| `kind` | `passed_on` (buyer pays, inside the price) or `absorbed` (organizer pays). |
| `calc` | `fixed` (`amount_cents`) or `percent` (0–100, 3 decimals, optional `cap_cents` per unit or order). |
| `per` | `ticket` (every paid ticket) or `order` (once per order). **Per-order fees can only be absorbed**: an all-in unit price can't carry a per-order amount (CHECK constraint). |
| `applies_to_addons` | Per ticket: also on every paid add-on unit. Per order: add-ons count in the base. |
| `taxable` | Passed-on fees only: tax is charged on the fee too (default true). |
| `tier_ids` | Event rules only: just these ticket types (null = all). |
| `active`, `sort_order` | Inactive rules never apply; the order is the order buyers see them in. |

Which rules apply to an event (`exos_effective_fee_rules`): the org's active rules (org level, `event_id` null), unless
the event opted out of all of them (`exos_event_fee_settings.inherit_org_rules = false`) or skips some
(`skipped_org_rule_ids`); then the event's own active rules. At most 10 take effect; at most 25 per org or event.

## The maths

All amounts are minor units (cents), per unit, with integer arithmetic so the storefront, exos-checkout and Postgres
(`exos_fee_unit_cents`, `exos_all_in_unit_cents`) agree:

1. **Codes first.** A voucher's price (pinned, % or amount off) is the unit price; fees are computed on it.
2. **Fees never apply to a $0 unit.** A free ticket (or a 100% code) stays free.
3. **Percent fees** round half-up to a whole cent per unit (3% of $19.99 = $0.60), then the cap applies.
4. **All-in unit** = price + passed-on fees + exclusive tax on (price + taxable fees), the tax rounded once per unit,
   as the existing all-in rule (`exclusive_tax_percent`) always has. With an inclusive tax rule (VAT style) the price
   and the fees already contain the tax; the recorded tax is extracted from price + taxable fees.
5. The order total is Σ all-in unit × quantity, so quantity × the shown price is exactly the charge.

**Tax decision.** A passed-on fee takes the ticket's (or add-on's) own tax rule (`exos_tax_rules` via `tax_rate_id`).
`taxable` defaults to true because fees that are part of the price of admission are generally taxable where the ticket
is (e.g. New York sales tax on admission charges); an organizer whose fee isn't taxable in their jurisdiction unticks
it. Absorbed fees are never taxed (the buyer doesn't pay them). Exos doesn't give tax advice: the organizer sets the
rates, as for tickets.

**Add-ons.** A per-ticket rule reaches add-ons only when `applies_to_addons` is on (a facility fee per ticket usually
shouldn't hit a parking pass or a T-shirt).

## Records

exos-checkout stores every fee line of the order in **`exos_checkout_fee_snapshots`** (one row per session, from
`orderFeeLines`; service role only, because buyers can read their own session row and absorbed fees are the
organizer's business), passed on and absorbed: org, event, session, rule id, name, kind, recipient, calc, percent, per,
item (ticket / add-on / order), unit and quantity, amount and whether it was taxed. When the session turns
`fulfilled`, a trigger copies the lines into **`exos_order_fees`**, the table settlements and the P&L read
(`exos_record_order_fees`, idempotent; a failure warns and never unwinds a paid fulfillment). A session from before the
deploy (no snapshot) gets its absorbed fees computed from the current rules and the price-disclosure lines
(`source = 'rules'`); nothing passed on can have been charged without a snapshot.

## Who can do what

- Owners and managers (and platform admins) write org rules, event rules and event settings; finance reads them and
  `exos_order_fees`; scanners, other roles and other orgs see nothing (RLS on `org_id`; an event rule's `org_id` must
  be its event's org, and rules can't move between orgs or events).
- Buyers (anon) read `exos_public_fee_rules`: passed-on per-ticket rules of published events only (name, amount,
  taxable, the tiers it covers). Absorbed rules and recipients are never public. A rule for a hidden (voucher-only)
  tier names that tier's id; the id alone unlocks nothing.
- `exos_effective_fee_rules`, `exos_record_order_fees`, `exos_tier_passed_on_fees` / `exos_addon_passed_on_fees`:
  service role only.

## Not covered yet

- **Partner API, box office (POS).** `exos-api` returns a tier's base `price` (not an all-in price), and the door
  POS (`_shared/pos/totals.ts`) still prices with `allInCents(unit, tax)` and no fees: whether passed-on fees apply
  at the door is an open call. The MCP tools price all-in with the fees (`withPublicTierFees` in exos-mcp).
- **Refunds.** A refund returns what the buyer paid (fees included); `exos_order_fees` isn't reversed on refund yet.
  Settlements should net refunded sessions out until it is.
- **Saved events / series cards** price from `event.price` without tiers (as before, also without tax).

## Gift cards and donations

A gift card is a way to pay, applied after the all-in price (fees and tax) is known (`docs/gift-cards.md`); the Exos
application fee is on the card charge only. An add-a-donation line comes after the tax and no fee rule applies to it
(`docs/giving.md`).
