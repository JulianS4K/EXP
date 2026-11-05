# Shared limits and price steps

Two inventory tools on top of ticket types, from DICE's data model (KANBAN "DICE gaps" #3 and #4).

- **Shared limits** (DICE `TicketPool`): one allocation across several ticket types.
- **Price steps** (DICE `PriceTier`): one ticket type moves through prices on its own, plus a door price.

Code and tests:

- **Migrations:** `20261106120000_exos_shared_capacity.sql`, `20261106130000_exos_price_steps.sql`.
- **SQL:** `exos_quotas` / `exos_quota_tiers` (the limits, since `20260702123030`), `exos_effective_available`;
  `exos_price_steps`, `exos_tier_current_price` (the one price computation), `exos_hold_lock_price`.
- **TypeScript:** `supabase/functions/_shared/priceSteps.ts` (the mirror of `exos_tier_current_price`),
  `src/lib/priceSteps.ts`, `src/lib/quotas.ts` (`sharedAvailability`), `src/components/QuotasEditor.tsx`,
  `src/components/PriceStepsEditor.tsx`, `supabase/functions/exos-checkout/index.ts`,
  `supabase/functions/exos-api/capacity.ts`.
- **API:** `docs/api/capacity.json`.
- **Tests:** `tests/exos/test_shared_capacity.sql`, `tests/exos/test_price_steps.sql` (run by `run_p0.sh`),
  `src/lib/sharedCapacity.test.ts`, `src/lib/priceSteps.test.ts`. TS and SQL run the same cases from
  `tests/exos/fixtures/`. Races, by hand: `tests/exos/race_shared_capacity.sh`, `tests/exos/race_price_steps.sh`.

## Shared limits

A shared limit is a row of `exos_quotas` (its allocation is `size`) and the ticket types in it are rows of
`exos_quota_tiers`. There is one pool system: these tables have existed since mig `20260702123030`, and every
place that sells counts against them the way it counts against a type's own capacity: cart holds (both hold
functions), the webhook's fulfilment, staff mints and comps, partner reservations, marketplace and channel
allocations, vouchers that block inventory, the waitlist. Refunds and returns free a place the same way (a
voided or refunded ticket stops counting).

- **A type sells only while every limit it is in has room** (pretix's rule). Its availability everywhere
  is the smallest of its own remaining and each limit's remaining (`exos_effective_available`): the event
  page and the feeds (`exos_public_tiers.available`), the public API (`_exos_api_public_tiers_json`:
  `available`, `sold_out`), partner sales, the dashboard. It shows sold out as soon as one limit is full.
- **No unlimited.** The allocation is required; 0 closes the limit (stop sales); NULL or negative is
  refused. A dashboard write can't set it below what the limit has already sold, and can't add a type
  whose sales would push it over (same rule as a type's capacity, mig `20261104110000`).
- **Race-safe.** A hold or a mint locks the type's limits by id (one order everywhere, so two buyers of
  two types sharing two limits can't deadlock), then re-checks under the lock.
- **Publish blockers:** a limit with no ticket types; a limit without a size (a row from before sizes were
  required); a type on sale inside a closed limit (close the type, capacity 0, or open the limit).

## Price steps

Example: Early bird $20 for the first 100 or until Dec 1, then GA $25 for 200, then $30, and $35 at the door.

- **When a step ends.** At its count (tickets sold at it plus live checkouts holding it) or at its time,
  whichever comes first. The last step is the final price and has no end; every other step needs one.
- **Once sold, ended.** When a step's count has *sold* (not just held), it is latched (`sold_out_at`): a
  refund after that frees the ticket at the current price, it doesn't bring the lower price back. Before
  that, a refund or an expired checkout frees the step's place again.
- **Boundary rule: cap.** An order is priced at one step. If it asks for more than the step has left,
  checkout answers 409 `price_step_remaining` with how many are left at this price; the buyer takes those
  and buys the rest at the next price. (pretix and DICE cap too. It keeps one unit price per order, which
  fulfilment, refunds, invoices and the price disclosure rely on.)
- **The price seen is the price paid.** `exos-checkout` reads the current step, prices the order with it,
  creates the cart hold, then `exos_hold_lock_price` re-checks the step under a lock on the type's steps
  and stamps it on the hold, so the hold counts against the step and two buyers can't both get the last
  early birds. If the step moved in between, the hold is released and the buyer gets 409 `price_changed`
  (the event page reloads its prices). The Stripe amount is fixed at that point and the webhook mints at
  it, even if the step advanced while the buyer was on Stripe; the ticket keeps its step
  (`exos_tickets.price_step_id`, from the session).
- **Door price.** The door channel (`door`, `pos`, `box_office`) sells at `door_price_cents` when set,
  else at the current step. Door sales at the door price and comps (price 0 from the box office) don't
  use a step's places. (POS walk-up ticket sales aren't wired yet: `exos-pos` answers 501.)
- **Free steps.** A free first step ("first 10 free") counts its free claims and then advances.

### One pricing path

`exos_tier_current_price(tier, at, channel)` is the only place the current price is computed. Every buyer
price comes from it: `exos_public_tiers.price` (the event page, the Google and catalog feeds, MCP, hosted
pages), the public API's tiers JSON, the partner API's event JSON and `current_price` on a ticket type,
public discovery, the listing feed, voucher-unlocked types, partner sales and referral rewards (through
`exos_rr_tier_price`), and the checkout charge. The all-in price is unchanged: the organizer's passed-on
fees and the exclusive tax are added to that face price by `allInCents` (`_shared/pricing.ts`, mirrored by
`src/lib/pricing.ts` and in SQL by `exos_all_in_unit_cents`), so buyers never see a fee line. There was no
single place for the *face* price before: every reader ran `effectiveTierPrice(price, price_schedule)` on
its own copy of the tier row. Those calls still run and are now no-ops (`price` already is the current
price, and `price_schedule` is its time-only form).

**The old `price_schedule`** (`[{startsAt, price}]`, mig `20260703122000`) was migrated into steps (option
(b)): every type with a schedule got time-only steps. The column stays readable and writable so existing
API clients and templates don't break: a write of `price` / `price_schedule` rebuilds the type's time-only
steps in place, and steps saved by the editor or the API write `price` (the first step's) and
`price_schedule` (the time-only form) back. A type whose steps end on a count has `price_schedule: []` and
refuses a schedule write. Readers of the raw `exos_ticket_tiers` row that compute the price themselves
(marketplace listing plans in `exos-distribute`) see the first step for such a type; the public view and
the APIs are right.

### TypeScript mirror

`currentPriceStep` in `_shared/priceSteps.ts` follows the same rules, for the editor's preview and the
buyer's "Price goes up to $25 on Dec 1 or after 37 more are sold" line (the next price shown all-in). The
parity cases in `tests/exos/fixtures/price_steps_cases.json` run against both.
