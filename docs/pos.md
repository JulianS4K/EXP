# Venue POS (Phase 3 scaffold)

Phase 3 of `docs/strategy.md` ("the Toast half"): box office walk-up sales, bar and merch, and an
end-of-night settlement for each event. This document covers the **scaffolding** that exists today:
the data model, the pure money logic with tests, a placeholder edge function, and the decisions the
operator still has to make.

**Card payments are off by default.** Walk-up ticket sales can take a card on a Stripe Terminal reader
(mig 20261107130000, "Card at the door" below) only when `exos-pos` runs with `EXOS_POS_CARD=on`; off, the
edge function answers `501` for every card action as before. Bar / merch cards and tabs aren't built. **No card
data is ever stored.** The reader handles the card, and Exos only ever keeps an opaque processor
reference (the Stripe PaymentIntent id) in `exos_pos_payments.terminal_ref`. No column may hold a
PAN, expiry, CVC, cardholder name or track data, and `test_pos_scaffold.sql` P1 and `test_pos_terminal.sql` T1
check for that.

## Scope

| In scope (Phase 3) | Out of scope |
|---|---|
| Box office walk-up tickets, sold through the same quota-aware mint path (`exos_mint_tickets`) | Restaurant features: table maps, coursing, kitchen display |
| Bar and merch: a catalog, 86'ing items, stock counts, tabs tied to a ticket or a wristband, tips | Payroll and tip-out payouts (tips are only tracked) |
| Several tenders per order: cash, card, comp | Stored cards, card-on-file, and any storage of card data |
| Cash drawers: opening float, denomination counts, expected vs counted | Accounting exports (QuickBooks and similar) |
| Settlement per event: tickets + bar + merch, cash vs card, the Exos fee, promoter and artist splits | Payouts over Stripe Connect (these come after the terminal is wired) |

## Staff shifts (clock in / out)

Mig `20261105120000` (`exos_staff_shifts`). Staff clock in on the phone they're signed in on (the door app's
device), not on a shared kiosk: `exos_staff_clock_in(org, event?, device?, note?)` and `exos_staff_clock_out(org,
note?)`. Any active member may clock in; one open shift per member per organization; the event and device, when
given, must be the organization's (a device that is pending or active). The role at clock-in is kept on the shift.
Owners and managers close a shift somebody forgot (`exos_staff_shift_close(shift, clock_out_at, reason)`: between
the clock-in and now, with a reason kept on the row) and read the hours report (`exos_staff_shift_report(org, from?,
to?)`, shifts that started in the window, at most 92 days, default the last 7, with each member's minutes; an open
shift counts up to now). RLS: members read their own shifts, owners and managers all. Tips and pay stay out of
scope. API (`docs/api/box-office.json`): `POST /v1/staff-shifts/clock-in` and `/clock-out` with the member's own
personal or OAuth token (`checkin:write`; an org API key is not a person), `GET /v1/staff-shifts` (`events:read`,
an owner or manager). Opendate's kiosk endpoints (a shared tablet with its own token) map here.

## What's built vs later

| Piece | Status | Where |
|---|---|---|
| Data model, RLS, grants | ✅ authored, not applied | `supabase/migrations/20260929074000_exos_pos_scaffold.sql` |
| 86 an item, open / close a tab, close a drawer | ✅ SQL functions | `exos_pos_set_86`, `exos_pos_open_tab`, `exos_pos_close_tab`, `exos_pos_close_drawer` |
| Recount a closed drawer (owner / manager, a reason, 7 days, 3 times; the replaced count kept in `exos_pos_drawer_recounts`) and the drawer report on the event report | ✅ SQL function + UI | `exos_pos_recount_drawer` (mig 20261104200000), `components/PosDrawersPanel` |
| Settlement summary and records | ✅ SQL functions | `exos_pos_settlement_summary`, `exos_pos_record_settlement` |
| Line and cart totals with tax, tips, tabs, split tenders, drawer math, settlement report, promoter and artist hooks | ✅ pure TS | `supabase/functions/_shared/pos/`, re-exported from `src/lib/pos` |
| `PaymentTerminal` interface, `FakeTerminal`, `NotWiredTerminal` | ✅ | `_shared/pos/terminal.ts` |
| `exos-pos` edge function: catalog and settlement preview, walk-up sales, voids, refunds, paid-outs, print codes, email; `501` for card actions | ✅ authored, not deployed | `supabase/functions/exos-pos/index.ts` |
| Tests | ✅ | `src/lib/pos/*.test.ts` (vitest), `tests/exos/test_pos_scaffold.sql` (in `run_p0.sh`) |
| Stripe Terminal adapter (connection tokens, locations, reader registration, `card_present` PaymentIntents, capture, refunds, webhook fallback) | ✅ authored, off until `EXOS_POS_CARD=on` | mig 20261107130000, `_shared/pos/stripeTerminal.ts` (`StripeTerminal implements PaymentTerminal`), `exos-pos`, `stripe-webhook` |
| Walk-up ticket sales (cash, comp): reserve, price at the door channel, mint, fill `order_lines.ticket_ids` | ✅ SQL functions + UI | mig 20261107100000, `exos_pos_walkup_sell`, the door app's Sell tab |
| Voids and refunds of POS orders (cash, comp, and walk-up cards: refunded to the card) | ✅ SQL functions + UI | `exos_pos_void_order`, `exos_pos_refund_order`, `_exos_pos_card_reverse`, `exos_pos_reversals` |
| Paying a tab with one tender that covers all its orders | ⬜ later | `allocateTabPayment` is the math |
| Cash paid-outs from a drawer | ✅ SQL function + UI | `exos_pos_paid_out`, `exos_pos_paid_outs` (also the cash of voids and refunds) |
| Promoter commission accrual for POS tickets (the per-ticket ledger) | ⬜ later | `exos_promoter_commissions` |
| Offline ringing (queued orders replayed with `client_ref`) | ⬜ later | `exos_pos_orders.client_ref` is reserved for this |
| Register UI: walk-up tickets on a phone | ✅ | `/checkin/:event` → Sell (`components/DoorSellPanel`) |
| Register UI: bar and merch | ⬜ later | SPA route |
| Card at the door on smart readers (S700, WisePOS E), from the web door app | ✅ authored, off until `EXOS_POS_CARD=on` | "Card at the door" below; the Sell tab |
| Kiosk mode: a self-serve screen, one event, card only on its reader, PIN exit, auto-reset | ✅ authored, sells only with `EXOS_POS_CARD=on` | mig 20261113100000, "Kiosk mode" below, `/kiosk` |
| Tap to Pay on iPhone, Bluetooth readers | ⬜ later (server side ready: `connection_token`, `card_payment` mode `sdk`) | needs the native wrapper app |

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
| Set up the card location, register a card reader | owner, manager of the org (`_exos_pos_terminal_manage_check`) |
| Get a Terminal connection token (SDK) | door staff of the event (`_exos_pos_terminal_token_check`) |
| Start a card walk-up, charge it on a reader, cancel it | door staff for the event start it; the seller, an owner or a manager charge or cancel it |
| Poll a card sale (`card_status`) | door staff of the event |
| Sell a walk-up ticket for cash | door staff for the event (`exos_pos_walkup_sell`) |
| Comp a walk-up ticket | owner, manager (the box-office comp rule; counts against the comp budget) |
| Void a sale (within 12 hours, before any of its tickets is scanned) | the member who sold it, owner, manager |
| Refund a sale (after a scan: with an override, recorded) | owner, manager |
| Pay cash out of a drawer; take cash into it (a sale, a bar tender, a cash gift card); hand a void's cash back from it; close it | the member who opened the drawer; an owner or manager naming it. Nothing picks another member's drawer by itself |
| Show / print a sale's tickets (print codes), email them | the member who sold it, owner, manager; only tickets the seller still holds (active, never checked in, owned by the seller), never a claimed or scanned one; an owner / manager may also resend one in the seller's unclaimed claim link. A buyer's ticket is printed only through `exos_ticket_print` |
| Recount a closed drawer (within 7 days of the close, at most 3 times, not after a final settlement) | owner, manager |
| Read the settlement | owner, manager, finance |
| Record a settlement (draft or final) | owner, manager |
| Mark a device as a kiosk, start kiosk mode on a screen, end a kiosk session, turn it off | owner, manager (`exos_pos_kiosk_*`; a platform admin is not enough) |
| Sell at a kiosk | the kiosk's credential only: its event's public types, card on its own reader; no cash, comps, skip, voids or refunds |
| Leave kiosk mode | whoever has the admin PIN (10 tries a minute, 5 wrong lock it 5 minutes) |
| Anyone outside the org | nothing (`test_pos_scaffold.sql` P3 and P9b check this) |

Orders, lines and tenders can't be updated or deleted from the client. Voids and refunds go through
functions (below).

## Walk-up sales

Mig `20261107100000`. Door staff sell tickets at the door in the door app (`/checkin/:event`, the **Sell**
tab), on a phone: pick a ticket type (its door price and what's left), the quantity, cash or comp, an
optional name and email and the event's checkout questions (the required ones too, unless the seller taps
**Skip questions**, which is logged: `docs/checkout-questions.md` "Walk-up sales"), then confirm. The
ticket goes over as a **one-time QR on the staff screen** for the buyer to photograph, on **paper**
(any ticket printer, the 4 × 8 in PDF of "Printed tickets" in `docs/wallet.md`), or by **email**. Both
the QR and the paper are print codes (`P-…`, `printed_via = 'pos'`), so a walk-up ticket scans like any
printed ticket, online and offline; an email gives the buyer the ticket in the app (an Exos account
gets it directly; anyone else gets a claim link, the box-office path of `exos_issue_ticket_to_email`).

**How a sale works.** Two steps, so a card tender can be added later without rework:

1. **Begin** (`_exos_pos_walkup_begin`): the role, then the same inventory rules as online sales, in
   the same lock order as holds: the type's shared limits by `quota_id` (`exos_assert_quota`), the
   type, its price steps; the type's room (`exos_effective_available`: live online checkouts count),
   the house cap, and the step's places. The price is the **door channel**'s:
   `exos_tier_current_price(tier, now(), 'door')` = `door_price_cents` when set, else the current
   step; tax is the type's rule, per unit, as at checkout. The order is created (status `open`, shown
   as `pending`) with its ticket line, and the places are **reserved** with `exos_cart_holds` rows tied
   to the order (`pos_order_id`; paid places on their step, comps on none). Nothing is minted.
2. **Complete** (`_exos_pos_walkup_complete`): the tenders (cash into the drawer, comps as a comp
   tender), then the holds become tickets in one transaction (channel `pos` for paid ones, `boxoffice`
   at 0 for comps, `order_ref` `pos:<order>`), `order_lines.ticket_ids` is filled, and the email goes
   if one was given.
3. **Cancel** (`_exos_pos_walkup_cancel`) gives a pending sale's places back; an expired reservation
   gives them back by itself and can't be completed.

Cash and comps do 1 and 2 in one transaction (`exos_pos_walkup_sell`). It is idempotent on the
client's **order key** (a UUID per sale, `exos_pos_orders.client_ref`): a double tap returns the first
sale; the key used for another sale (or by another member, event or org) is refused without saying
anything about that sale. Rate limit: 30 sales a minute per device (or per member without one).

**Tenders.** Cash needs an open drawer at the event that the member opened (theirs on this device,
else their latest). An owner or manager may name any open drawer at the event; nobody else's drawer is
ever picked by default. A comp covers whole tickets and needs an owner or manager, like the box-office comp,
and counts against the org's comp budget. A sale can mix them (two tickets, one comped). A **card**
tender goes through the card path ("Card at the door" below) when it's switched on, and is refused
otherwise ("Card at the door isn't connected yet"). No card data is accepted: `exos-pos` refuses a body with a
card-looking field before it looks at anything else.

**Void and refund.** A void (the seller, an owner or a manager; within 12 hours and before any ticket
of the sale is scanned) voids the tickets (their places go back on sale; a step's place too, unless
the step has already sold out), hands the cash back out of an open drawer as a **paid-out row** (kind
`void`), marks the tenders `refunded`, and writes an `exos_pos_reversals` row. A refund (owner or
manager) does the same later; after a scan it needs their **override**, which is recorded, and a
scanned ticket stays `used` and keeps its place (the guest came in), as an online refund does. A
pending sale is cancelled instead. Nothing can be reversed after the event's final settlement. The
cash comes back out of a drawer the member may use (the one it went into if it's theirs, else their
own; an owner or manager may name any open drawer at the event), and the drawer must hold it.

**Handing over.** Only the member who sold it, an owner or a manager can show, print or email a sale's
tickets (another scanner at the same door can't redirect them). Codes for the screen QR or paper are
made only for tickets the seller still holds, for everyone: a live paper code makes the holder's app
code read "printed", so printing a buyer's ticket would take it over (a buyer's ticket is printed only
through `exos_ticket_print`). Email only ever sends tickets the
seller still holds (active, never checked in, owned by the seller): a ticket a buyer has claimed is
theirs and changes only through the normal transfer and refund flows, and a scanned ticket is never
sent. The seller sends tickets not yet in a claim link; an owner or manager can also resend one sitting
in the seller's own unclaimed claim link (that link is cancelled and the new one is from the seller
too). Email gives an Exos account the tickets directly only when its email is confirmed; otherwise
it's a claim link.

**Paid-outs.** `exos_pos_paid_out(drawer, amount, reason, key)`: owner, manager or the member who
opened the drawer (the same holder rule now applies to bar cash tenders, cash gift cards sold into a
drawer and closing a drawer); a reason; never more than the drawer holds; once per key. A drawer's expected cash
at close is float + cash taken (refunded sales too: that cash came in) + cash gift cards - paid-outs
(voids and refunds included), which is `reconcileDrawer` with `paidOutCents`.

**Settlement.** `exos_pos_settlement_summary` counts paid orders as before, and adds
`cash_ticket_cents`, `fee_base`, `fee_base_cents`, `reversals` (voids, refunds, overrides, the cash
returned) and `paid_outs`. Voided and refunded sales drop out of the gross and the tenders.

**The fee on walk-up tickets (OPEN operator decision 1).** One platform setting,
`exos_platform_settings` key `pos_walkup_fee_base`:

| Value | Exos fee on walk-up tickets |
|---|---|
| `"card-tickets"` (**default**, what the scaffold settlement already did) | card ticket sales only: a cash or comp walk-up pays no Exos fee |
| `"all-tickets"` | cash ticket sales too (per order floor(ticket gross × cash / total)) |

The rate is the event's (`exos_event_fee_bps`: 0 in the org's free months and on the free tier).
`buildSettlement` takes the same values (`feeBase`).

**API** (`docs/api/pos-sales.json`): `GET /v1/events/:id/pos-orders` (`orders:read`, paged) and
`POST /v1/events/:id/pos-orders/:order/void` (`refunds:write`, an organization API key whose creator
is an owner or manager now; same night, before a scan). Selling and refunds after a scan stay in the
door app.

Tests: `tests/exos/test_pos_walkup.sql` (W1-W17), `tests/exos/race_pos_walkup.sh` (by hand: two
devices and the last ticket, a walk-up against an online checkout for a shared limit's last place,
a double tap from two sessions, a void against a paid-out), `src/lib/pos/walkup.test.ts`, the smoke
test "the Sell tab sells one cash ticket and shows the QR".

## Card at the door (Tap to Pay / Terminal)

Operator ask 2026-11-05: card payments for on-site sales. Mig `20261107130000`, `_shared/pos/stripeTerminal.ts`,
`exos-pos`, `stripe-webhook`. **Off until `EXOS_POS_CARD=on`** on `exos-pos` (a live Stripe key also needs
`EXOS_POS_CARD_LIVE=on`); off, every card action answers `501` as before. `terminal_ref` stays the only card
reference: no card data, ever.

**The charge model is the online one.** `exos-checkout` makes a **destination charge** on the platform account
(`transfer_data.destination` = the org's connected account) with `application_fee_amount` = the Exos fee + Stripe's
card fee (the platform pays Stripe under destination charges; `checkoutFeeSplit`). A card walk-up is the same, with
the card fee estimated at Terminal's in-person rate (2.7% + 5c, `EXOS_STRIPE_TERMINAL_FEE_BPS` /
`_FIXED_CENTS`). The Exos rate is the event's (`exos_event_fee_bps`: 0 in the org's free months and on the free
tier). Under either `pos_walkup_fee_base` value a card walk-up pays the Exos fee, which is what the settlement
counts. `on_behalf_of` is off, as online (`EXOS_POS_CARD_ON_BEHALF_OF=on` makes the connected account the
settlement merchant). Because the charges are the platform's, the **Terminal Location and the readers live on the
platform account** (not the connected account), one Location per org and mode
(`exos_pos_terminal_locations`).

**How a card sale works** (the walk-up's two steps with a PaymentIntent in the middle):

1. **Begin** (`mint_walkup` with `payment: "card"` → `_exos_pos_walkup_begin_card`): the walk-up begin (role, rate
   limit, order key, inventory, door price), places held **5 minutes**, an `exos_pos_card_payments` row
   `awaiting`. No comps in a card sale; a $0 sale is cash; the org must have finished Stripe setup.
2. **Charge** (`card_payment` → `_exos_pos_card_begin`): the seller, an owner or a manager; the reader must be
   one Exos registered for this org (active, org-wide or set to this event, this Stripe mode); the places still
   held (extended 5 minutes). Then a `card_present` PaymentIntent with **manual capture**: the order's amount
   (never the client's), the destination charge and fee above, `metadata.exos_pos_order`, idempotency key
   `exos_pos_pi_<order>`. It's recorded (`_exos_pos_card_attach`) **before** the reader sees it, then sent to a
   smart reader (`process_payment_intent`, server-driven) or, in mode `sdk`, its client secret goes back to a
   Terminal SDK.
3. **Capture** (`card_status` / `capture`, polled every 2 s by the Sell tab): when the reader authorized
   (`requires_capture`), `_exos_pos_card_capture_prepare` checks under the order lock that the sale is still
   pending and its places held (extended 2 minutes), Exos captures (key `exos_pos_capture_<pi>`), and
   `_exos_pos_card_complete` runs the walk-up complete with the PaymentIntent as the card tender's `terminal_ref`:
   tickets minted, QR / paper / email as for cash. A capture that can't become tickets (the sale was cancelled,
   the places lapsed, a wrong amount) cancels the sale and is **refunded in full** (`refund_pending` → `refunded`);
   an authorization Exos never captures is cancelled and takes no money.
4. **Decline / cancel**: a decline (the PaymentIntent's error, or the reader's failed action) or "Cancel the card
   payment" cancels the PaymentIntent, then the sale (`_exos_pos_card_fail`): places back. Never after money was
   taken.
5. **Webhook fallback** (`stripe-webhook`): `payment_intent.amount_capturable_updated`, `.succeeded`,
   `.payment_failed` and `.canceled` with `metadata.exos_pos_order` run the same steps, so a door app that died
   mid-payment still completes or releases the sale. Every step is gated on the order's state in SQL (the order
   lock; the card tender keyed on the PaymentIntent), so the door and the webhook racing, a replayed event, or one
   arriving after the door finished, make one set of tickets (`race_pos_terminal.sh`). Stripe has no event-id
   dedupe table in Exos; this state gate is the dedupe, as for checkout sessions. The metadata only names a
   candidate order: every webhook step is bound to the PaymentIntent recorded for that order (and a refund
   answer to the refund id already stored), and a connected account's event is ignored (door PaymentIntents are
   the platform's). An unmatched event is logged and answered 200.
6. **Void / refund**: the walk-up rules (`_exos_pos_reverse`: the seller same night before a scan, an owner or
   manager after, the override after a scan, nothing after the final settlement), then the card part on the
   `exos_pos_reversals` row (`card_cents`, `card_payment_intent`, `card_refund_status` pending) and a Stripe
   refund of the PaymentIntent with the online refund's Connect flags (`reverse_transfer`, the application fee
   back unless `EXOS_REFUND_KEEP_PLATFORM_FEE=true`), key `exos_pos_refund_<order>`. Stripe's answer, and the
   webhook's later one, land on the same row; a pending refund is retried by repeating the void / refund. The
   cash RPCs and the partner API refuse a card sale (`0A000`): it's refunded to the card from the door app.

**Tips are not built** (decision 3): the card amount is the order total. **Who pays card processing**
(decision 2): the organizer, as online (the fee carries Stripe's estimated fee).

**Readers.** Smart readers (Stripe Reader S700, BBPOS WisePOS E) are driven from the server, so they work from
the web door app with no native code. Owners and managers add one in the Sell tab ("Card readers": the venue's
address once, then the code the reader shows), which creates the org's Location on demand and registers the
reader (`exos_pos_devices` kind `reader`, `hardware_ref` = the reader id, plus `exos_pos_terminal_readers`, the
proof the reader is the org's: a device row edited by hand can't point a charge at another reader).

**Tap to Pay on iPhone** needs a native iOS app: the Stripe Terminal iOS SDK (or React Native SDK) and Apple's
ProximityReader entitlement; a web page can't use the iPhone's NFC for payments. Bluetooth readers (BBPOS
WisePad 3, Stripe M2) need a native SDK too. The server side is ready for it: `connection_token` (door staff of
the event, scoped to the org's Location) and `card_payment` with `mode: "sdk"` (returns the PaymentIntent's client
secret; the app collects it, then calls `card_status` like the web). The Tap to Pay button stays hidden
(`card.tap_to_pay: false`) until the app exists. Still to do for it: the wrapper app (the same SPA in a web view
plus the SDK bridge), the entitlement, `onBehalfOf` / the merchant display name in the SDK's connection config if
`EXOS_POS_CARD_ON_BEHALF_OF` is used, and App Store review.

**Operator setup:** Stripe Terminal enabled on the platform account (test mode first: Stripe's simulated reader,
registration code `simulated-wpe`); a smart reader per door to buy (S700 or WisePOS E, ordered from the Stripe
Dashboard to the venue's address); each org's Location is created from the Sell tab; set `EXOS_POS_CARD=on` (and
later `EXOS_POS_CARD_LIVE=on` with the live key); add the four `payment_intent.*` events to the platform webhook
endpoint; re-check the PCI SAQ type before the first live card (`docs/pci.md`). For Tap to Pay: an Apple
Developer account (organization), the Tap to Pay on iPhone entitlement (Apple reviews it), Tap to Pay enabled in
Stripe, iPhone XS or newer on a current iOS, the wrapper app on the App Store.

**Still open:** offline card capture (below), tips on the reader (decision 3), Interac in Canada (`card_present`
only today), and whether card walk-ups count toward promoter commissions (decision 8).

## Kiosk mode

Mig `20261113100000`, `src/views/Kiosk.tsx`, `exos-pos` (`kiosk_*`). A **self-serve screen** at a fair gate: the
public buys tickets for one event by card on the kiosk's own reader, with no staff at the screen. An RFP pass / fail
line (county and state fairs). Sales need `EXOS_POS_CARD=on` like every card at the door; with it off, the kiosk
screen says it's unavailable.

**Setting one up** (the Sell tab, owners and managers: "Kiosk mode"). A kiosk is a POS device (`exos_pos_devices`,
kind `register`, active) marked for **one event** in `exos_pos_kiosks`: its card reader (one of the org's registered
readers, org-wide or set to that event), whether a ticket printer is attached, and an **admin PIN** (6 to 12 digits,
not one digit repeated or a run like 123456; kept as a bcrypt hash, never the PIN; re-saving without a PIN keeps
it). `exos_pos_kiosk_configure(device, event, reader, pin, printer)`; `event` null turns the kiosk off. Then, on the
screen itself, "Start kiosk mode on this screen" (`exos_pos_kiosk_enter`): Exos mints the **kiosk credential**
(`exk_` + 256 random bits, shown once, kept as its SHA-256 in `exos_pos_kiosk_sessions`, valid 24 hours), the
browser keeps it and **signs the staff member out** there. One live session per device; starting it again elsewhere
ends the old one. Owners and managers end a session from the dashboard (`exos_pos_kiosk_end`) or turn the kiosk off;
moving the kiosk to another event ends its session too.

**What the screen does.** `/kiosk` only: the app sends every other path back there while the credential is stored
(no navbar, no dashboard, no other event, no settings, no sign-in). The flow:

1. Pick a ticket type and a quantity: the event's **public** types (never hidden ones, never tables) at the **door
   price** (`exos_tier_current_price(..., 'door')`: `door_price_cents`, else the current price step), what's left
   (shared limits, the house cap), at most the event's `purchase_limits.maxPerOrder` (and 10).
2. The event's checkout questions. **Required ones must be answered: a kiosk has no "Skip questions"** (the kiosk
   begin always passes `skip = false`).
3. Pay on the reader: the card walk-up begin (`_exos_pos_walkup_begin_card`, places held 5 minutes) and the charge
   on **the kiosk's own reader** (`_exos_pos_card_begin`), polled every 2 s; capture and completion as in "Card at
   the door", with the same webhook fallback.
4. The tickets: the **QR on screen** (one-time print codes, as the Sell tab's), **"Email it to me"** (queued mail:
   the account if the address is confirmed, else a claim link; `_exos_pos_deliver_email`), and **"Print my tickets"**
   when the kiosk has a printer (the same 4 × 8 in PDF, to the browser's print dialog; a kiosk browser prints it
   straight away). Only for the session's own sale, within 10 minutes of paying.

**Auto-reset** (`src/lib/kiosk.ts`, tested in `kiosk.test.ts`): after a sale, "Done" or 30 s untouched; mid-sale,
60 s idle; a declined card, 10 s. A reset clears every buyer field from memory, wipes local storage except the kiosk
credential and the cookie choice, clears session storage, and takes a new order key. A card sale left at the reader
(90 s untouched, or past the 5-minute hold) is **cancelled on the reader** (`kiosk_cancel` → the card cancel path:
places back, nothing charged).

**Card only, and nothing else.** No cash, comps, "skip questions", voids or refunds at a kiosk: those stay with
staff in the door app. In SQL: the kiosk cores only reach the card begin; the order trigger
(`exos_pos_orders_zkiosk`) stamps `channel = 'kiosk'` and the session, refuses an order for another event or device
and any comp, and refuses any door sale (cash, comp or card) on a kiosk device outside kiosk mode;
`_exos_pos_walkup_complete` refuses to complete a kiosk order with anything but the card (`0A000`, `kiosk-card-only`).

**Leaving** (staff, the corner "Staff" button): the admin PIN (`_exos_pos_kiosk_exit`). 10 tries a minute per
device; 5 wrong in a row lock the PIN for 5 minutes (`pos.kiosk_lockout` in the audit log). A wrong PIN answers
rather than raises, so the count sticks. The right PIN ends the session (`pos.kiosk_exit`), cancels a card sale
still on the reader, clears the credential and returns to the door app's sign-in.

**Who the sale is by.** The member who started the kiosk is the seller of record (`rung_by`): the tickets are theirs
until handed over (as at the door), their door app lists the sale ("· kiosk") and can void or refund it. Every
kiosk call re-checks that this member is still an owner or manager of the org, that the device is active and the
event not cancelled; otherwise the kiosk reads "switched off".

**Money and reports.** A kiosk sale is a walk-up card sale (`exos_pos_orders.channel = 'kiosk'`): the same card
tender, the same journal entry (`pos_card_sale`), the same Exos fee and settlement; `exos_pos_settlement_summary`
adds a `kiosk` block (orders, tickets, gross) and the order JSON carries `channel`.

**Audit:** `pos.kiosk_set`, `pos.kiosk_off`, `pos.kiosk_enter`, `pos.kiosk_exit` (`via` pin or staff),
`pos.kiosk_lockout`; never the PIN, its hash or the credential.

**PCI:** still SAQ A for the web (`docs/pci.md`): the kiosk page has no card field and loads no payment script;
the reader takes the card.

**API** (`exos-pos`, POST JSON with `kiosk_token`, no staff JWT): `kiosk_state`, `kiosk_begin`, `kiosk_charge`,
`kiosk_status`, `kiosk_cancel`, `kiosk_codes`, `kiosk_email`, `kiosk_exit`. Only `kiosk_state` and `kiosk_exit`
answer with `EXOS_POS_CARD` off. Each goes through a service-role core that resolves the credential first
(`_exos_pos_kiosk_resolve`) and rate-limits per session before any Stripe call.

Tests: `tests/exos/test_pos_kiosk.sql` (K1-K13), `tests/exos/race_pos_kiosk.sh` (by hand: two kiosks and the last
ticket, a kiosk against a door sale, a double tap, ten wrong PINs at once), `src/lib/kiosk.test.ts`, the smoke tests
"kiosk: …" and the blocking a11y scan "kiosk screen" (`tests/smoke/a11y.mjs`: axe, plus visible focus and 48 px
targets).

**Operator steps:** `EXOS_POS_CARD=on` (the card at the door setup), one smart reader per kiosk, a tablet in the
OS's single-app mode (iPad Guided Access, Android screen pinning, or Chrome `--kiosk` with `--kiosk-printing` for
silent printing). Kiosk calls carry no staff JWT: `exos-pos` keeps JWT verification on, which passes the project's
anon key (a JWT); if the project moves to the new publishable keys, `exos-pos` needs `--no-verify-jwt` (it checks
every caller itself).

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
| Card reader | A Stripe Terminal smart reader (Stripe Reader S700 or BBPOS WisePOS E, Wi-Fi / Ethernet), driven from the server; Bluetooth readers (WisePad 3, M2) later with the native app | Registered from the Sell tab: `exos_pos_devices` kind `reader`, `hardware_ref` = the Stripe reader id, and `exos_pos_terminal_readers` |
| Tap to Pay | Tap to Pay on iPhone through Stripe Terminal | No extra hardware, but a native iOS app (the Terminal SDK + Apple's entitlement): see "Card at the door" |
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
   decided. For walk-up tickets the choice is one setting, `pos_walkup_fee_base` (`card-tickets` by
   default, or `all-tickets` to charge cash walk-ups): see "Walk-up sales".
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
8. **Walk-up ticket pricing.** Built: the same ticket type at its door price (`door_price_cents`, else
   the current step). Still open: whether walk-up sales count toward promoter commissions (they carry
   no promoter today).
9. **Hardware.** Smart readers (S700 / WisePOS E) work today from the web; Tap to Pay and Bluetooth readers need
   the native shell. Which to buy first is still the operator's call.
