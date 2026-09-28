# Venue POS (Phase 3 scaffold)

Phase 3 of `docs/strategy.md` ("the Toast half"): box office walk-up sales, bar and merch, and an
end-of-night settlement for each event. This document covers the **scaffolding** that exists today:
the data model, the pure money logic with tests, a placeholder edge function, and the decisions the
operator still has to make.

**No live payments.** Stripe Terminal is not wired. Card payments are defined as an interface with a
fake implementation for tests. The edge function answers `501` for every payment action. **No card
data is ever stored.** The reader handles the card, and Exos only ever keeps an opaque processor
reference (a Stripe PaymentIntent id, later) in `exos_pos_payments.terminal_ref`. No column may hold a
PAN, expiry, CVC, cardholder name or track data, and `test_pos_scaffold.sql` P1 checks for that.

## Scope

| In scope (Phase 3) | Out of scope |
|---|---|
| Box office walk-up tickets, sold through the same quota-aware mint path (`exos_mint_tickets`) | Restaurant features: table maps, coursing, kitchen display |
| Bar and merch: a catalog, 86'ing items, stock counts, tabs tied to a ticket or a wristband, tips | Payroll and tip-out payouts (tips are only tracked) |
| Several tenders per order: cash, card, comp | Stored cards, card-on-file, and any storage of card data |
| Cash drawers: opening float, denomination counts, expected vs counted | Accounting exports (QuickBooks and similar) |
| Settlement per event: tickets + bar + merch, cash vs card, the Exos fee, promoter and artist splits | Payouts over Stripe Connect (these come after the terminal is wired) |

## What's built vs later

| Piece | Status | Where |
|---|---|---|
| Data model, RLS, grants | ✅ authored, not applied | `supabase/migrations/20260929074000_exos_pos_scaffold.sql` |
| 86 an item, open / close a tab, close a drawer | ✅ SQL functions | `exos_pos_set_86`, `exos_pos_open_tab`, `exos_pos_close_tab`, `exos_pos_close_drawer` |
| Settlement summary and records | ✅ SQL functions | `exos_pos_settlement_summary`, `exos_pos_record_settlement` |
| Line and cart totals with tax, tips, tabs, split tenders, drawer math, settlement report, promoter and artist hooks | ✅ pure TS | `supabase/functions/_shared/pos/`, re-exported from `src/lib/pos` |
| `PaymentTerminal` interface, `FakeTerminal`, `NotWiredTerminal` | ✅ | `_shared/pos/terminal.ts` |
| `exos-pos` edge function: catalog and settlement preview (read-only), `501` for payments | ✅ authored, not deployed | `supabase/functions/exos-pos/index.ts` |
| Tests | ✅ | `src/lib/pos/*.test.ts` (vitest), `tests/exos/test_pos_scaffold.sql` (in `run_p0.sh`) |
| Stripe Terminal adapter (connection tokens, reader registration, PaymentIntents with `card_present`) | ⬜ later | a `PaymentTerminal` implementation |
| Walk-up ticket mint: a ticket line mints through `exos_mint_tickets` and fills `order_lines.ticket_ids` | ⬜ later | server side in `exos-pos` |
| Voids and refunds of POS orders | ⬜ later | an SQL function, plus a terminal refund for card |
| Paying a tab with one tender that covers all its orders | ⬜ later | `allocateTabPayment` is the math |
| Cash paid-outs from a drawer | ⬜ later | `reconcileDrawer` already takes `paidOutCents` |
| Promoter commission accrual for POS tickets (the per-ticket ledger) | ⬜ later | `exos_promoter_commissions` |
| Offline ringing (queued orders replayed with `client_ref`) | ⬜ later | `exos_pos_orders.client_ref` is reserved for this |
| Register UI (iPad) | ⬜ later | SPA route |

## Data model

All money is integer cents. Every table has RLS enabled and explicit grants. `anon` has no grants
on any of them, and the service role has full access.

```
exos_orgs ─┬─ exos_pos_devices        registered iPad / reader / printer; event optional;
           │                          status pending | active | disabled | retired
           │
           ├─ exos_pos_items          catalog: category ticket | bar | merch, price_cents,
           │     │                    tax_rule_id → exos_tax_rules (same event),
           │     │                    tier_id → exos_ticket_tiers (ticket items), sku,
           │     │                    active, is_86d (+ who / when), inventory_count (NULL = untracked)
           │     │
exos_events ─┬─ exos_pos_tabs          open | closed | void; ticket_id → exos_tickets OR wristband_code;
             │     │                  one open tab per ticket / wristband per event
             │     │
             ├─ exos_pos_orders ◄─────┘ tab_id (optional), device_id; source 'pos';
             │     │                  status open | paid | void | refunded;
             │     │                  payment_method cash | card | comp | split;
             │     │                  subtotal / tax / total / tip cents (kept by triggers)
             │     │
             │     ├─ exos_pos_order_lines   item snapshot: category, name, unit price, tax rate,
             │     │                         inclusive flag, tax_cents, line_total_cents,
             │     │                         promoter_id → exos_promoters, ticket_ids (later)
             │     │
             │     └─ exos_pos_payments      one row per tender: method cash | card | comp,
             │                               amount_cents (tip excluded), tip_cents,
             │                               drawer_session_id (cash), terminal_ref (card, opaque)
             │
             ├─ exos_pos_drawer_sessions   open float, counts {denomination cents: count},
             │                             expected, counted, variance; one open per device
             │
             └─ exos_pos_settlements       draft | final (one final per event): the totals as
                                           columns plus the full summary JSON
```

The database, not the register, is the source of truth for anything to do with money:

- **Line trigger.** It snapshots the item's name, price and tax rule, so the client can't set a price.
  It refuses items that are inactive, 86'd, out of stock or belong to another event, and it
  decrements the stock count. It computes tax the same way checkout does: exclusive tax per unit,
  rounded, times the quantity (`allInCents`); inclusive tax extracted from the line total
  (`exos_tax_cents`).
- **Payment trigger.** It refuses a tender larger than what's left on the order, and a cash tender
  into a drawer that isn't open. It marks the order `paid` when the tenders cover the total.
- **Org and event.** Both always come from the event or the order, never from the client.

### Who can do what

| Action | Who |
|---|---|
| Manage devices and the catalog | owner, manager |
| Read the catalog | owner, manager, finance; door staff for the events they work (org-wide items: any scanner) |
| Ring orders, bar and merch lines, cash and comp tenders; open drawers; open and close tabs | door staff for the event: `exos_pos_can_ring` = `exos_can_door_event` (owner, manager, or a scanner who is org-wide or assigned to the event in `exos_event_staff`) |
| 86 an item | owner, manager; door staff for an event-scoped item |
| Ticket lines and card tenders | **service role only** (the walk-up mint path and the terminal integration) |
| Read the settlement | owner, manager, finance |
| Record a settlement (draft or final) | owner, manager |
| Anyone outside the org | nothing (`test_pos_scaffold.sql` P3 and P9b check this) |

Orders, lines and tenders can't be updated or deleted from the client. Voids and refunds will come
through functions.

## Settlement math

`exos_pos_settlement_summary(event)` (SQL) and `buildSettlement` (TS) compute the same thing. The two
test suites pin the same night: gross 120.20, cash 36.40, card 75.00, comp 8.80, Exos fee 1.62,
drawer 0.10 short.

| Figure | Rule |
|---|---|
| Gross per category | Line totals of **paid** orders, tax included, comps included |
| Tenders | Cash, card and comp. Tips are kept apart because they are the staff's money |
| Card ticket sales | For each order: floor(ticket gross × card / order total). A split order's card share is pro-rata |
| Exos fee | `exosFeeCents(card ticket sales, bps)`: 3%, rounded half up, and 0 during the org's first 6 months (`exos_org_fee_bps`, `exosFeeBpsAt`) |
| Organizer net | cash + card − Exos fee. Card processing comes off the Stripe payout. The TS report estimates it at Stripe Terminal's standard US rate (2.7% + 5c, `STRIPE_TERMINAL_FEE`) |
| Promoters | Per promoter: ticket lines net of tax, times the paid share (cash + card) / total. The commission is a hook (`commissionHook` uses the promoter's terms) |
| Artist deal | `artistDealCents`: the larger of the guarantee and the door split after expenses. The deal terms are an input |
| Drawers | Float, expected (float + cash taken, cash tips included), counted, and variance (counted − expected) |

A final settlement needs every drawer closed and no open orders.

## Hardware (placeholder)

A supported-device list, to confirm before any venue goes live:

| Role | Candidate | Notes |
|---|---|---|
| Register | iPad (10th gen or newer) running the SPA, or a native shell later | Safari PWA first; a native shell only if the reader SDK needs one |
| Card reader | A Stripe Terminal reader (e.g. BBPOS WisePad 3 over Bluetooth, or Stripe Reader S700 over Wi-Fi / smart reader) | Registered as `exos_pos_devices` kind `reader`; `hardware_ref` = the Stripe reader id |
| Tap to Pay | Tap to Pay on iPhone through Stripe Terminal | No extra hardware; check the per-device limits |
| Receipt printer | An ESC/POS network printer (optional) | kind `printer` |
| Cash drawer | Printer-kicked drawer (optional) | |
| Wristbands | Printed / RFID wristbands with a code | `wristband_code` is 3–64 of `[A-Za-z0-9_-]` |

## Open questions: offline card capture

Stripe Terminal has an offline mode on some readers that stores payments on the device and forwards
them later. Before relying on it:

- **Limits.** What are the per-transaction and total offline amount caps, and how long can a reader
  stay offline? Stripe sets these per reader and per account, so they need confirming on our account.
- **Risk.** An offline payment can be declined when it's forwarded. Who eats that loss: the venue,
  or Exos under destination charges?
- **Tabs.** Can a tab be pre-authorized offline, or does it need a cash deposit or an ID hold?
- **Replay.** Offline POS orders need `client_ref` idempotency (reserved), the same way offline
  check-in replay works (`exos_check_in_offline`).
- **Reporting.** Settlement has to separate `offline_queued` card tenders until they're confirmed.

## Operator decisions

1. **Exos fee on POS sales.** The scaffold charges the 3% fee on **card ticket sales only**. Bar,
   merch and cash aren't charged (`feeBase: 'card-tickets'`). The alternatives, `'card-all'` and
   `'all-sales'`, are implemented and tested. The SQL summary uses card tickets only until this is
   decided.
2. **Who pays card processing** at the venue (Stripe Terminal is 2.7% + 5c): the organizer, as at
   checkout, or passed through? Also, is card processing on tips taken from the tips?
3. **Tip base.** The presets tip on the pre-tax subtotal by default (18 / 20 / 22%). The alternative
   is the all-in total. Also decide the tip-pool rule (`poolTips` splits by hours) and the manager
   override above 100%.
4. **A POS staff role.** Bartenders currently use the `scanner` role and its per-event assignment.
   Should there be a separate `pos` role?
5. **Tabs.** Card pre-authorization (once the terminal is wired), a cash deposit, or ID-only? Also
   set the default tab limit (`overTabLimit`).
6. **Drawer tolerance.** How far off counts as balanced (`reconcileDrawer(…, toleranceCents)`)?
   The default is 0.
7. **Org-wide taxed items.** Tax rules are per event today, so an org-wide item can't carry a tax
   rule. Options: add org-level tax rules, or require every taxed item to be scoped to an event.
8. **Walk-up ticket pricing.** Door price vs online price (a separate door tier or the same tier),
   and whether walk-up sales count toward promoter commissions.
9. **Hardware.** Which readers to support first, and whether a native shell is needed.
