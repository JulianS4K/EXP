# Scarcity mode: scenario dry run

`scripts/scarcity-sim/` runs one event's whole on-sale through the real
database functions that decide who holds which seat:
- `exos_set_channel_allocation` (the grid);
- `exos_refill_channel_pools` (every `exos-distribute` run);
- `exos_confirm_channel_listing` (the live sender);
- `exos_record_marketplace_order` and `exos_fulfil_marketplace_order` (marketplace sales);
- `exos_seats_available` (Exos checkout).

A virtual clock runs from 14 days before doors to the event start: 1-hour
steps, then 15-minute steps in the last 26 hours. Buyers arrive on Exos and
on each marketplace at the scenario's rates, wanting 1 to max-per-order seats.

Marketplaces are modelled as live listings behind a sender. A marketplace
shows what it was last sent. The sender brings it up to the planned
quantity after `lag` steps and confirms any shrink. Marketplace buyers buy
against what the marketplace shows, not what Exos planned. Each scenario
runs in a transaction that is rolled back, so nothing is kept.

    bash tests/exos/run_p0.sh exos_p0_test                     # build a database once
    bash scripts/scarcity-sim/run.sh exos_p0_test report.txt   # run every scenario

Scenarios are in `scripts/scarcity-sim/scenarios.json`. The last full output
is in `scripts/scarcity-sim/last-run.txt`, which shows each scenario's
timeline (T-168h … doors) and per-channel numbers. The rest of this page is
from that run (2026-09-28, migration `20260928040000`).

## Results

Columns:
- **Exos / mkts**: seats sold on Exos / on the marketplaces.
- **Lost**: seats buyers wanted but couldn't get where they were shopping.
- **Held at doors**: seats still in a marketplace pool when doors open.
- **Exos-out h**: hours when Exos had no free seat while some pool held seats.
- **To a human**: marketplace sales beyond what the pool held.

| Scenario | Sold | Exos / mkts | Unsold | Lost | Held at doors | Exos-out h | To a human | Integrity |
|---|---|---|---|---|---|---|---|---|
| 01 baseline | 200/200 | 123 / 77 | 0 | 54 | 0 | 0.0 | none | ok |
| 02 hot show | 200/200 | 103 / 97 | 0 | 838 | 0 | 46.0 | none | ok |
| 03 cold show | 84/200 | 58 / 26 | 116 | 0 | 0 | 0.0 | none | ok |
| 04 marketplace-heavy | 149/200 | 38 / 111 | 51 | 224 | 0 | 0.0 | none | ok |
| 05 Exos-heavy | 200/200 | 192 / 8 | 0 | 134 | 0 | 0.0 | none | ok |
| 06 day-of surge | 167/200 | 93 / 74 | 33 | 7 | 0 | 0.0 | none | ok |
| 07 tiny tier | 10/10 | 6 / 4 | 0 | 166 | 0 | 0.0 | none | ok |
| 08 slow sender | 200/200 | 124 / 76 | 0 | 106 | 0 | 7.0 | none | ok |
| 09 sender down on the last day | 194/200 | 114 / 80 | 6 | 90 | 6 | 6.3 | none | ok |
| 10 refunds near sellout | 200/200 | 110 / 90 | 0 | 715 | 0 | 38.0 | none | ok |
| 11 no max per order | 200/200 | 159 / 41 | 0 | 170 | 0 | 28.0 | none | ok |
| 12 max per order 1 | 200/200 | 104 / 96 | 0 | 48 | 0 | 5.0 | none | ok |
| 13 no doors time | 200/200 | 123 / 77 | 0 | 49 | 0 | 0.0 | none | ok |
| 14 doors 3h before start | 200/200 | 123 / 77 | 0 | 54 | 0 | 0.0 | none | ok |
| 15 grid filled before publish | 89/200 | 58 / 31 | 111 | 0 | 0 | 0.0 | none | ok |
| 16 organizer changes mid-sale | 200/200 | 129 / 71 | 0 | 54 | 0 | 0.0 | none | ok |
| 17 dead marketplaces | 190/200 | 190 / 0 | 10 | 0 | 0 | 0.0 | none | ok |
| 18 one marketplace, big cap | 200/200 | 62 / 138 | 0 | 127 | 0 | 5.0 | none | ok |
| 19 not live yet | 190/200 | 190 / 0 | 10 | 0 | 0 | 0.0 | none | ok |

## What held
- **Integrity held in all 19 runs.** Nothing sold over capacity, no seat was
  held or sold twice, and no marketplace sold more than its pool held. That
  includes a sender 4 steps behind (08), organizer changes on live listings
  (16), refunds after the scarcity line (10), and odd limits: no max per
  order (11), max per order 1 (12), no doors time (13), doors 3 h before
  the start (14).
- **The cutoff works.** Every pool reached 0 by doors in every scenario
  except the one where the sender was down (09). In the day-of surge (06)
  and the cold show (03), the cutoff handed 12–17 seats back to Exos 3 hours
  out.
- **Selling vs stagnant works.** Pools flip between selling and stagnant as
  sales come and go. Stagnant pools end up at one order's worth, then 0
  near sellout. Dead or not-yet-live marketplaces (17, 19) cost Exos
  nothing at the end: their seats all came back.
- **Publishing late (15).** Pools filled 11 days before publish stayed
  "normal" until publish, as intended, and only then started their clock.

## What it found
1. **A stopped sender strands seats at the door (09).** The sender stopped
   30 h out, and 6 seats were still held for Gametime at doors while Exos
   turned buyers away. Refills kept growing the pool, but the marketplace
   never showed the new seats, and the cutoff never reached it.
   **Fix:**
   - don't grow a pool while a change to its live listing is still unconfirmed;
   - alert when a live listing has had an unconfirmed change for more than N minutes;
   - at doors, show staff any seats still held so someone can release them by hand.

   Releasing automatically without the marketplace's confirmation would
   risk selling the same seat twice.
2. **Caps choke a hot marketplace (04).** StubHub had the buyers but hit its
   grid cap of 40. It turned away 224 seats of demand while 51 seats went
   unsold at the door. Scarcity mode moves seats between pools but never
   raises a cap. **Fix:** an "auto" cap: no ceiling, only the pool rules and
   Exos's floor.
3. **The grid refuses caps it doesn't need to (07).** On a 10-seat tier, once
   StubHub holds its pool, SeatGeek, Gametime and Vivid Seats are refused a
   cap of 10 ("only 4 more seats free"). The check still treats a cap as a
   promise of seats, though under pools it's only a ceiling. **Fix:**
   require only that the cap is at least what that marketplace has sold, and
   let the pool take what it can.
4. **A cap below what's already sold is accepted silently (16).** StubHub's
   cap was cut to 12 after it had sold 19. The pool correctly went to 0, but
   the grid should say so, or refuse it.
5. **In hot shows Exos's floor sells in minutes (02, 10, 11).** Pools
   hold a few seats while Exos shows sold out for 28–46 h. That's expected
   with small pools and demand everywhere, not a leak. If Exos should keep
   more, the floor could follow Exos's own sell-through rather than a fixed
   one order's worth.
6. **Stagnation fires often far from the event (01, 03).** With sparse
   early sales, pools flip between selling and stagnant within days. Once
   listings are live, every flip is a marketplace update. This supports
   scaling the stagnant window with time to the event (days early, hours on
   the last day).

## Not covered yet
- **Several ticket types sharing a quota.** The engine uses one ticket type.
- **Cancelled marketplace orders after delivery.** The e2e dry run covers
  them.
- **Price changes.** Scarcity mode only moves quantities.
