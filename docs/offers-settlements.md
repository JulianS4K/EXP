# Offers, settlements, finance and ticket counts

The money side of booking: what you offer an act, how the night settles from what actually sold, the profit and
loss per show and across shows, and the ticket-count emails agents expect. Ported from the Firebase build (Exos-Bridge
`server/offers.ts`, `server/finance.ts`, `server/ticketCounts.ts`, `src/lib/settlement.ts`) onto Opendate's v3
model, with offer pools added (the Firebase build had none).

| Piece | Where |
|---|---|
| Deal math, settlement, budget projection, sales pace (pure) | `supabase/functions/_shared/finance/dealMath.ts` |
| Inputs → settlement, per-show and org P&L, CSV | `supabase/functions/_shared/finance/settlementModel.ts` |
| PDF writer and the offer / settlement documents | `supabase/functions/_shared/finance/{pdf,documents}.ts` |
| Dashboard re-export | `src/lib/dealMath.ts`; data layer `src/lib/offersApi.ts`; CSV import `src/lib/offerImport.ts` |
| Schema, functions, RLS | `supabase/migrations/20261031100000_exos_offers.sql`, `20261031100500_exos_settlements.sql` |
| Partner API | `supabase/functions/exos-api/finance.ts`, bodies `_shared/api/finance.ts`, reference `docs/api/{offers,budgets,deals,finance,settlements}.json` |
| Mail | `offer-sent`, `settlement-finalized`, `ticket-counts` in `_shared/mail-templates.ts` |
| Screens | `/orgs/:orgId/offers` (`OrgOffers`), `/orgs/:orgId/offers/:offerId` (`OfferEditor`), `/orgs/:orgId/finance` (`OrgFinance`), event report → Settlement & P&L (`components/finance/ShowFinancePanel`), hold drawer → Make offer; public `/offer/:id?t=`, `/settlement/:eventId?t=`, `/ticket-counts/opt-out?t=` |
| Tests | `src/lib/dealMath.test.ts` (the Firebase sims, case by case, plus pools, P&L, PDFs), `apiFinance.test.ts`, `offerImport.test.ts`, `mailTemplates.test.ts`, `tests/exos/test_offers_settlements.sql` |

Every amount is integer cents. Percentages are 0 to 100 with up to three decimals. Each computed line rounds half up
once.

## Who sees what

Offers, budgets, settlements, items, P&L and ticket counts hold money figures: **owners, managers and finance** read
them; scanners, content staff and other organizations see nothing (RLS on `org_id`, and the functions check the role
from the row, never from the caller). Owners and managers write offers, templates, budgets, pools, imports and deals,
reopen settlements and manage ticket-count emails. Finance also writes finance categories, ledger codes and items,
adjusts and finalizes settlements. Platform admins act as owners. API keys need `booking:*` for offers, budgets, pools,
templates, imports and deals, `finance:*` for the rest.

## Offers

An offer is one act's deal for a show. It sits on a **budget** (capacity, average price, sell-through, income and
expense lines in your finance categories). Offers that share a budget are a lineup.

- **Create** blank, from a template (its terms, conditions, budget lines and expiry), and/or from a hold (its active
  nights, venue and room, first artist, the room's capacity; for a hold with rental terms, a Venue rental line with
  the fee). Hold drawer → *Make offer* does the last.
- **Edit** drafts and sent offers. Changing what the agent agreed to (terms, dates, act, venue, conditions, pool
  share) on a sent offer takes it back to **draft** and its link stops working. Accepted, declined, expired and
  cancelled offers only take notes and the show link.
- **Send** mails the agent (or another address) a summary and a link `/offer/<id>?t=<token>`: 32 random bytes,
  only their SHA-256 stored, rotated on every send. Webhook `offer.sent`.
- **Answer**: the agent's page needs no account; a name is required; IP and user agent are recorded; one answer per
  send. The venue can record an answer it got another way (dashboard or `POST /v1/offers/:id/accept|decline`).
  Webhooks `offer.accepted` / `offer.declined`.
- **Expiry**: a sent offer past `expires_at` reads as expired (and is written back as expired on the next write).
- **Cancel** drafts, sent and accepted offers; **delete** drafts only (with their budget when nothing else uses it).
- **Import** a spreadsheet saved as CSV: the browser maps the columns (`offerImport.ts`), the database creates the
  drafts row by row (a bad row is reported, the rest kept). Rows with the same `group` share a budget.
- **Converting a hold night** links the hold's open offers and budgets to the new event.
- **PDF**: the dashboard, the agent's page and `GET /v1/offers/:id/pdf` render the same document.

## Deal math

Per act, from the net box office:

| Deal | Pays | Split point |
|---|---|---|
| `flat` | the guarantee | none |
| `versus` | the greater of the guarantee and % × (net − expenses applied) | expenses applied + guarantee ÷ % |
| `plus` | the guarantee + % × what net leaves above the split point | guarantee + expenses applied + promoter profit % × (guarantee + expenses applied) |
| `door` | the greater of the guarantee and % × net (no expenses) | guarantee ÷ % |

- *Expenses applied* = every expense line except Talent, plus the other acts' guarantees (support costs), capped by
  the act's expenses cap.
- Bonuses are cumulative: every threshold of paid tickets reached pays. Merch: the act's share of the Merch income
  lines. Adjustments (signed, each with a reason) add after; a payout never goes below zero. Balance due = payout −
  the deposit, once marked paid.
- **Offer pools** (one per budget): in `pool` mode the pool's terms make one payout for the lineup (same rules; its
  support costs are the guarantees of acts outside the pool), clamped to its floor and cap. Each member with a
  `pool_share_percent` gets that share; members without one split what is left equally (odd cents to the first);
  shares over 100 % are scaled down. Bonuses, merch, deposits and adjustments stay per act. `independent` mode
  changes nothing.

Worked example: $1,000 versus 85 %, net box office $5,000, expenses $2,000 → 85 % × $3,000 = $2,550 (split point
$3,176.48); with a $1,500 expenses cap, $2,975.

### Tiered deals (brackets)

An offer can carry up to 20 brackets (`exos_deal_brackets`, mig 20261102120000; Offer page → Terms → Tiered
percentage; `/v1/deal-brackets`, also `/v3_deal_brackets`). Each changes the percentage from a threshold upward; below
the lowest threshold the offer's own percentage applies (a bracket at 0 replaces it). One basis per offer:

- `amount`: thresholds are cents of the base the percentage applies to (net after expenses for versus, net box office
  for door, the overage above the split point for plus). 85 % with a bracket at $20,000 → 90 % pays 85 % of the first
  $20,000 and 90 % of the rest.
- `tickets`: thresholds are paid tickets sold; each tier gets the share of the base its tickets are of all paid
  tickets (so a uniform price gives the same answer as tiering the money).

Thresholds are unique per offer, so in order they are strictly increasing and tiers never overlap or leave gaps. Each
tier is rounded half-up once with exact integer arithmetic, then summed. Brackets apply to versus, plus and door (flat
has no percentage); a versus or door split point is where the tiered amount first reaches the guarantee. Pools pay
from the pool's terms, so a member's brackets don't apply. Brackets change only while the offer is a draft (they are
deal terms); they reach the settlement inputs (`deal_brackets`) and are frozen in a finalized snapshot. The maths is
`_shared/finance/dealBrackets.ts`; `_exos_bracket_amount` is its SQL twin, checked against the same fixtures
(`src/lib/dealBrackets.test.ts`, `tests/exos/test_finance_extras.sql`).

## Settlement

`_exos_settlement_inputs` gathers everything one show's settlement reads; the deal math runs on it in the browser and
in exos-api (the same file), so both show the same numbers.

- **Box office** from Exos sales: tickets still active or used; $0 tickets are comps (attendance, not revenue).
  Gross is what buyers paid for those tickets (all-in) less refunds that voided tickets don't already account for.
  Deductions are each order's tax, passed-on fees, absorbed fees and the Exos and card fee, in proportion to the share
  of the order still held as valid tickets. Add-on revenue is not box office.
- **Sold elsewhere** comes from `exos_sales_count_totals` (PR #65) when that view exists (`to_regclass`); otherwise
  `sold_elsewhere.available` is false. Lines in the show's currency count, others are listed only.
- **Items** count at `actual_cents`, else `amount_cents`.
- **Acts** are the accepted offers on the show, or on its hold and not yet linked. Offers in another currency are
  listed, not settled.
- **Promoter mode** (the venue is rented or partner, or the hold has rental terms): the venue is owed its rental (the
  Venue rental items, which are also expenses) + its share of net box office − the rental deposit paid (default: the
  hold's). The rental item is created once on first read; deleting it sticks.
- **Promoter net** = net box office + other income + merch income − expenses − artist payouts − venue share + house
  adjustments.

`PATCH` takes adjustments (the full list), deposits paid and venue terms, with an optional `revision` that refuses a
save over someone else's. **Finalize** freezes the inputs (`snapshot`; later sales and edits no longer move it), mints
a link for the show's *settlement* contacts (the page and its PDF leave out the promoter net), mails them and emits
`settlement.finalized`. **Reopen** (owner / manager) returns to live numbers and kills the link.

## Profit and loss

Per show, one row per line in three columns:

- **Forecast**: the budget (capacity × sell-through × average price, its lines; an item with an explicit
  `forecast_cents` replaces the budget lines of its category) and the deal math on that (the accepted offers, else
  the budget's open ones).
- **Estimate**: paid sales so far plus the current daily pace until the show, capped at capacity; deductions scaled
  with it; items at estimate, else actual, else amount; budget lines for categories with no items.
- **Actual**: the settlement (the snapshot once finalized).

Across shows: `/orgs/:orgId/finance` or `GET /v1/profit-and-loss?from&to` (at most 366 days, 100 shows), totals per
currency, CSV with formula-looking cells defused.

## Finance categories and ledger codes

Seeded per org on first use: Talent, Production, Marketing, Hospitality, Venue rental, Staff, Bar/F&B income, Merch
income, Other. Talent, Venue rental, Merch income and Other are built in (the maths reads their keys): they can be
renamed and coded, not deleted or re-kinded. Each category carries one code from the org's chart of accounts
(`exos_gl_codes`, discarded rather than deleted; discarding unlinks it).

### Ledger codes and reporting (mig 20261102120000)

- **Revenue types** (`exos_gl_revenue_codes`): tickets, buyer fees, tax, donations, refunds, platform fees, POS,
  payouts and the imported sources (box office, bar, merchandise, memberships, delivery, ticket insurance, gift
  cards, other) each post to one of the org's codes. Finance → Ledger → Revenue codes; `/v1/gl-revenue-codes`.
- **Per-event overrides** (`exos_gl_code_assignments`): one per revenue type and show; deleting one falls back to the
  org's code. Event report → Settlement → Ledger codes; `/v1/events/:id/gl-code-assignments`.
- **Reporting rows** (`exos_reporting_rows`): one row per money line with its code: per order the ticket value (order
  value less tax, buyer fees and donations), tax, buyer fees, donations and the platform fee (negative); each refund
  (negative); each Stripe transfer (payout rows are money moved, not revenue); each paid POS sale and its tax; and
  each imported entry (`imported: true`). Finance → Ledger (CSV); `/v1/reporting-rows`.
- **Backfill** (`_exos_gl_backfill`): rebuilds one show's Exos rows from its orders, refunds, payouts and POS sales,
  removes rows whose source is gone, and re-tags every row (imported ones without their own code included) with the
  code in force. It never changes money. Idempotent (a second run reports 0 / 0 / 0) and serialized per show (an
  advisory lock). `POST /v1/events/:id/gl-backfill`.
- **Imported ledger entries** (`exos_imported_ledger_entries`): accounting lines from another system, at most 500 per
  import, identified by (`source_system`, `source_line_id`): the same line again is `exists` and writes nothing; the
  same id with other values is an error naming the stored entry. Amounts are signed integer cents. Entries are never
  edited (delete and import again). An entry on a show counts in its settlement and P&L as income (positive; merchandise
  as merch income) or expense (negative), under "Imported · <source>" lines flagged in the P&L and its CSV; its tax
  doesn't. Finance → Ledger → Imported entries (CSV); `/v1/imported-ledger-entries`.
- **Cash summary** (`_exos_cash_summary`): a show's gross (online order value plus POS payments), fees, tax, refunds and
  net (gross − tax − refunds − platform fees), split by payment method (card, Cash App, PayPal, Venmo, gift card,
  cash and card at the POS, comps), comps, and payouts (Stripe transferred / pending, PayPal owed / held). Optional
  window. Event report → Settlement; `/v1/events/:id/cash-summary`.

## Ticket-count emails

Per show (event report → Settlement & P&L, or `/v1/events/:id/ticket-counts`): daily at a local time or weekly on a
weekday, in the show's time zone. Recipients default to the show's agent contacts; re-saving the list keeps an
address's opt-out. Each email: sold by ticket type, comps, gross, the last 24 hours, attendance against capacity,
sold elsewhere, and the recipient's own opt-out link. *Send now* at most once per 10 minutes.

`exos_ticket_counts_run(25)` claims due schedules with `SKIP LOCKED`, moves each to its next run before queueing, and
queues one `exos_mail` row per recipient with a dedupe key per run, so a retry never doubles. Schedules switch off a
day after the show or when it is cancelled. The cron job `exos-ticket-counts-15min` is **created inactive**; turn it
on once the mail drain is live:

```sql
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'exos-ticket-counts-15min'), active := true);
```

## CRM deals

`exos_crm_deals` is the org-level counterpart of Opendate's admin deals: a sales or fundraising opportunity with a
stage (status follows: open, won, lost), amount, probability, close date, owner (a member), contact, and optional links
to an offer or a show. Offers page → Deals; `/v1/deals`.

## Not built

- Tax withholding, charity and facility-fee deductions, door-deal revenue bases: a deal is one of the four types
  above (with optional brackets). Opendate's bracket widths (`quantity` / `gross_amount`), `dollar_amount`,
  `dollar_or_percentage_operator` and `cap_overflow_target` are not modelled: brackets are thresholds with a
  percentage, and flat amounts are bonuses.
- Organizer fee components and ledger overrides of a single tax or fee rule (overrides are per revenue type).
- Live stamping of reporting rows at sale time: a show's Exos rows are built by its backfill.
- Offer imports from PDFs or multi-sheet workbooks (CSV only, mapped in the browser); Opendate's offer blueprints.
- Attachments on emails (links instead), currency conversion between offers and the show.
