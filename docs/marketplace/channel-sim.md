# Channel allocation: how much to share, how much to hold, how often to rebalance

`scripts/channel-sim/` simulates one ticket type sold on Exos and on the five
resale marketplaces at once, with demand taken from Terminal-2's CRM, and
compares ways of splitting the inventory. Re-run:

    python3 scripts/channel-sim/sim.py 150 > scripts/channel-sim/report.txt
    python3 scripts/channel-sim/analyze.py

It is a model, not the live code: the live pools are
`exos_refill_channel_pools` (mig `20260928010000`); the DB-level dry run of
those is `scarcity-sim.md`.

## Demand, from the CRM (2026-10-13 pull)

Aggregates only (`scripts/channel-sim/data.json`), from `s4kcs_orders`
(2025-10-15 .. 2026-10-13, 73k orders, 204k tickets) plus exact order times
from `vivid_orders` and `gotickets_sales` for the last 72 hours:

| | StubHub | Gametime | Vivid Seats | TickPick | GoTickets |
|---|---|---|---|---|---|
| Share of tickets | 42% | 20% | 14% | 13% | 11% |
| Median days before the event | 11 | 6 | 21 | 11 | 22 |
| Sold on the event day | 16% | 20% | 6% | 12% | 9% |

- The last day is the busiest: about 1 in 7 tickets (14%) sells on the event day, with peaks
  0–3 h before and again 17–20 h before (the evening before).
- Orders: 2 tickets is the norm (52%); 98% are 8 or fewer, so **a pack = 8** (the max per order).
- One event is lopsided: across 881 events with 50+ tickets, the top marketplace takes 46% on
  average (10th–90th percentile 32–63%). The model draws each event's split from that spread, so
  an even split is wrong for most events, as in real life.
- Exos's own checkout has no history: assumed 15% of buyers, buying earlier than resale.

Buyers stay where they shop: a marketplace buyer who finds too few tickets there is lost, even if
another channel holds some.

## Strategies

- **even**: Exos keeps a reserve (at least one pack); the rest is split evenly across the five
  marketplaces. Each rebalance tops the reserve back up from what's unsold, then re-splits the rest
  evenly.
- **weighted**: the same, but the re-split follows the demand seen per marketplace so far.
- **taper**: even, with a 10% reserve that drops to one pack 48 hours before the start.
- **pools** (today's design): each marketplace holds a small pool, topped up from Exos after
  every sale; everything else stays on Exos.
- Frequencies: never, every 24 h, 6 h, 1 h, 15 min, and **adaptive** (24 h until a week out, 6 h
  until 48 h out, 1 h in the last 48 h, 15 min in the last 24 h).

## Results (150 simulated events per cell)

Each cell: **% of sellable tickets sold** (sold ÷ min(demand, capacity)) · **% of buyers turned away on
Exos while marketplaces still held tickets** · **marketplace listing updates per event**.

| Strategy | 50 tix ×0.7 | 50 tix ×1.0 | 50 tix ×1.5 | 200 tix ×0.7 | 200 tix ×1.0 | 200 tix ×1.5 | 800 tix ×0.7 | 800 tix ×1.0 | 800 tix ×1.5 |
|---|---|---|---|---|---|---|---|---|---|
| even 1 pack, daily | 85% · 0.2 · 31 | 73% · 0.1 · 37 | 83% · 0.1 · 44 | 99% · 0.3 · 110 | 91% · 0.6 · 148 | 99% · 1.3 · 181 | 99% · 1.4 · 313 | 94% · 1.9 · 392 | 100% · 4.2 · 467 |
| even 5%, never | 70% · 3.4 · 0 | 60% · 3.2 · 0 | 72% · 7.0 · 0 | 78% · 8.3 · 0 | 64% · 9.9 · 0 | 76% · 11.1 · 0 | 78% · 7.9 · 0 | 66% · 9.9 · 0 | 75% · 11.9 · 0 |
| even 5%, daily | 85% · 0.2 · 31 | 73% · 0.1 · 37 | 83% · 0.1 · 44 | 99% · 0.1 · 110 | 91% · 0.2 · 148 | 98% · 1.0 · 179 | 100% · 0.0 · 313 | 94% · 0.0 · 392 | 100% · 1.3 · 459 |
| even 5%, adaptive | 86% · 0.0 · 33 | 73% · 0.0 · 40 | 83% · 0.1 · 45 | 100% · 0.1 · 140 | 92% · 0.0 · 182 | 98% · 1.0 · 182 | 100% · 0.0 · 453 | 95% · 0.0 · 547 | 100% · 1.3 · 465 |
| even 5%, 15 min | 86% · 0.0 · 34 | 73% · 0.0 · 41 | 83% · 0.1 · 46 | 100% · 0.0 · 151 | 92% · 0.0 · 202 | 98% · 0.9 · 209 | 100% · 0.0 · 599 | 95% · 0.0 · 813 | 100% · 1.3 · 820 |
| even 10%, adaptive | 86% · 0.0 · 33 | 73% · 0.0 · 40 | 83% · 0.1 · 45 | 100% · 0.0 · 140 | 88% · 0.0 · 174 | 95% · 0.2 · 173 | 100% · 0.0 · 453 | 91% · 0.0 · 509 | 98% · 0.1 · 451 |
| even 20%, adaptive | 83% · 0.0 · 32 | 70% · 0.0 · 39 | 79% · 0.1 · 43 | 99% · 0.0 · 140 | 80% · 0.0 · 157 | 87% · 0.0 · 157 | 100% · 0.0 · 453 | 82% · 0.0 · 447 | 89% · 0.0 · 426 |
| weighted 5%, adaptive | 81% · 0.0 · 40 | 74% · 0.0 · 49 | 84% · 0.2 · 55 | 97% · 0.1 · 159 | 92% · 0.0 · 193 | 99% · 1.0 · 195 | 100% · 0.0 · 498 | 95% · 0.0 · 569 | 100% · 1.4 · 480 |
| taper 10%→1 pack, adaptive | 86% · 0.0 · 33 | 73% · 0.0 · 40 | 83% · 0.1 · 45 | 100% · 0.0 · 142 | 93% · 0.0 · 185 | 97% · 0.3 · 186 | 100% · 0.0 · 454 | 98% · 0.0 · 573 | 100% · 1.0 · 492 |
| pools 1 pack | 71% · 2.8 · 1 | 60% · 2.5 · 1 | 73% · 6.0 · 1 | 100% · 0.0 · 44 | 90% · 0.8 · 47 | 96% · 4.0 · 47 | 100% · 0.0 · 175 | 97% · 0.1 · 232 | 100% · 4.4 · 231 |
| pools 2 packs | 69% · 3.4 · 0 | 62% · 3.2 · 0 | 74% · 7.0 · 0 | 99% · 0.2 · 34 | 84% · 2.6 · 34 | 92% · 5.5 · 34 | 100% · 0.0 · 175 | 96% · 0.4 · 219 | 99% · 5.0 · 219 |
| pools 4 packs | 61% · 3.4 · 0 | 58% · 3.2 · 0 | 76% · 7.0 · 0 | 85% · 5.7 · 10 | 70% · 7.1 · 9 | 81% · 9.0 · 9 | 100% · 0.0 · 175 | 92% · 1.6 · 194 | 97% · 5.9 · 194 |

Frequency (even, 5% reserve): served %
| Size × demand | never | 24h | 6h | 1h | 15m | adaptive |
|---|---|---|---|---|---|---|
| 50 ×0.7 | 70.2 | 85.1 | 85.8 | 85.9 | 85.9 | 85.9 |
| 50 ×1.0 | 60.0 | 72.6 | 73.0 | 72.9 | 72.8 | 72.9 |
| 50 ×1.5 | 72.0 | 82.7 | 82.6 | 82.6 | 82.6 | 82.6 |
| 200 ×0.7 | 77.7 | 99.4 | 99.9 | 100.0 | 100.0 | 99.9 |
| 200 ×1.0 | 63.6 | 90.9 | 92.0 | 92.3 | 92.4 | 92.3 |
| 200 ×1.5 | 76.3 | 98.4 | 98.4 | 98.4 | 98.4 | 98.3 |
| 800 ×0.7 | 78.4 | 99.9 | 100.0 | 100.0 | 100.0 | 100.0 |
| 800 ×1.0 | 66.3 | 93.5 | 94.8 | 95.0 | 95.0 | 95.0 |
| 800 ×1.5 | 75.0 | 99.8 | 99.9 | 99.9 | 99.9 | 99.8 |

## What it says

1. **Rebalance daily at least; hourly in the last 48 hours; 15 minutes buys nothing more.**
   Never rebalancing loses 20–30 points (65–78% sold). Daily recovers almost all of it.
   Going to hourly near the end adds 1–1.5 points when demand ≈ capacity, the hardest case.
   15-minute steps sell the same as hourly but cost up to 1.5× the listing updates. Use the
   adaptive schedule.
2. **Reserve: about 5% of the inventory, never less than one pack.** One pack alone runs Exos's own
   checkout dry (up to 4% of buyers turned away at hot shows). Every 10 points of reserve above 5%
   costs 4–9 points of sell-through, because the reserve only serves Exos buyers.
3. **Share the rest, about 95%, across the marketplaces.** Split evenly at first; following
   demand (weighted) helps hot shows by ~1–2 points and hurts small, slow ones (it chases early
   noise). Even is the safe default.
4. **Taper the reserve when the event is big and demand ≈ capacity.** 10% held until 48 hours out,
   then released down to one pack: 98% sold at 800 tickets vs 95% for a fixed 5%. It is never
   worse than 1 point below the fixed 5% anywhere else.
5. **Pools are the write-efficient choice for big events, not small ones.** At 800 tickets, pools of
   one pack sell 97–100% with less than half the listing updates (175–232 vs 450–550). At 200
   tickets they are within 2 points of even + 5%, but turn away up to 4% of Exos's own buyers at hot
   shows. At 50 tickets they sell 60–73%: pools of 8 across five marketplaces leave Exos little to
   refill with. From 200 tickets up, one-pack pools beat two- and four-pack pools.
6. **Small events: fewer marketplaces.** 50 tickets over six channels is under a pack each; nothing
   tested gets past 73–86%. List a small event on two or three marketplaces, not five.

## Recommended defaults

| Event size | Split | Reserve | Rebalance |
|---|---|---|---|
| ≤ 100 tickets | even, 2–3 marketplaces | 1 pack | adaptive |
| 100–500 | even, all marketplaces | 5% (≥ 1 pack) | adaptive |
| 500+ | pools of 1 pack, or even + taper (10% → 1 pack at T-48h) | rest on Exos / taper | refill on each sale (pools) or adaptive |

## Broadcast: every unsold ticket on every marketplace at once (`broadcast.py`)

GA tickets are interchangeable, so the alternative to splitting is listing the whole unsold count
everywhere and taking it down everywhere as it sells, as broker point-of-sale tools do. The only risk is
the sync lag: a marketplace still shows tickets another one has just sold. Lags used: StubHub, SeatGeek,
GoTickets ~3 min, TickPick 5 min, Vivid Seats 10 min (polling only), **Gametime 6 h** (CSV upload).
An **oversell** = an order accepted on a marketplace that Exos can't fill.

Cell: served % · oversold orders per event · oversold tickets per 1,000 sold.

| Policy | 50 ×0.7 | 50 ×1.0 | 50 ×1.5 | 200 ×0.7 | 200 ×1.0 | 200 ×1.5 | 800 ×0.7 | 800 ×1.0 | 800 ×1.5 |
|---|---|---|---|---|---|---|---|---|---|
| broadcast, no buffer | 100% · 0.00 · 0.0 | 98% · 0.08 · 5.4 | 100% · 0.03 · 1.3 | 100% · 0.00 · 0.0 | 100% · 0.10 · 1.4 | 100% · 0.11 · 1.3 | 100% · 0.00 · 0.0 | 100% · 0.21 · 1.0 | 100% · 0.62 · 1.9 |
| broadcast, buffer 1 pack | 100% · 0.00 · 0.0 | 86% · 0.00 · 0.0 | 92% · 0.00 · 0.0 | 100% · 0.00 · 0.0 | 97% · 0.01 · 0.1 | 99% · 0.00 · 0.0 | 100% · 0.00 · 0.0 | 99% · 0.03 · 0.2 | 100% · 0.01 · 0.0 |
| broadcast, buffer 2 packs | 91% · 0.00 · 0.0 | 72% · 0.00 · 0.0 | 78% · 0.00 · 0.0 | 100% · 0.00 · 0.0 | 93% · 0.00 · 0.0 | 98% · 0.00 · 0.0 | 100% · 0.00 · 0.0 | 99% · 0.00 · 0.0 | 100% · 0.00 · 0.0 |
| broadcast + Gametime 20% share, buffer 1 pack | 92% · 0.00 · 0.0 | 77% · 0.00 · 0.0 | 87% · 0.00 · 0.0 | 99% · 0.00 · 0.0 | 89% · 0.00 · 0.0 | 96% · 0.00 · 0.0 | 99% · 0.00 · 0.0 | 91% · 0.00 · 0.0 | 96% · 0.00 · 0.0 |
| broadcast + Gametime 20% share, buffer 2 packs | 80% · 0.00 · 0.0 | 65% · 0.00 · 0.0 | 74% · 0.00 · 0.0 | 99% · 0.00 · 0.0 | 86% · 0.00 · 0.0 | 95% · 0.00 · 0.0 | 99% · 0.00 · 0.0 | 90% · 0.00 · 0.0 | 96% · 0.00 · 0.0 |
| auto split (10% → 1 pack at 48 h) | 86% · 0 · 0 | 73% · 0 · 0 | 83% · 0 · 0 | 100% · 0 · 0 | 93% · 0 · 0 | 97% · 0 · 0 | 100% · 0 · 0 | 98% · 0 · 0 | 100% · 0 · 0 |

- **Broadcast with a one-pack buffer** (the last 8 tickets never listed, so Exos sells them) sells as
  much as or more than the split everywhere: 86–92% at 50 tickets (split: 73–83%), 97–100% at
  200–800, with about one oversold order per 30 events in the worst cell (800 tickets, demand =
  capacity, mostly from Gametime's 6-hour lag).
- With no buffer it sells the most but oversells 1–5 tickets per 1,000.
- Giving Gametime a fixed share instead of broadcasting there loses more (fragmentation) than its
  lag costs.
- So the better default for GA is **broadcast with a one-pack buffer**, not a split. It changes the
  rule Exos is built on (a seat in one place at a time): marketplace sales would claim from one shared
  count, and an order arriving after the last ticket went needs the oversell path (cancel / replace /
  refund on that marketplace). Reserved seating keeps the split.

## What Exos does by default (mig `20261014090000`)

The operator picked the tapering reserve (2026-10-13). Every new event's ticket types are split
automatically (**Auto** in the event editor's Marketplaces section; existing events stay as they were):

- Exos keeps **10% (at least one pack)**, and **one pack from 48 hours before the show**.
  A pack = the max per order (8 when the event has none).
- The rest is shared **evenly** across the ticked marketplaces.
- Rebalanced **daily**, every **6 hours** in the last week, **hourly** in the last 48 hours
  (`exos_run_channel_splits`, hourly cron).
- **Free ticket types stay on Exos**: the resale marketplaces don't get them by default (Eventbrite may
  sell them once it is a channel). The organizer can still list one by hand.
- Editing the grid by hand switches the event to **Manual**.
- In Auto, the pools' scarcity and stagnant rules (mig `20260928040000`) are off: the split already
  protects the reserve. The **3-hour day-of cutoff still applies** (every pool to 0 three hours before
  doors). The CRM puts ~10% of event-day resale sales in those 3 hours, so that cutoff is worth a second
  look.

## Limits

- The CRM is resale (broker) data. Primary sales may run earlier; the shape of the last 72 hours is
  what matters most for rebalancing, and that is the most consistent part of the data.
- One price everywhere, no marketplace fees, no listing lag (the sender confirms within minutes;
  scarcity-sim models lag), no refunds, buyers never switch channels.
- Exos's own demand (15%) is an assumption; with more Exos demand the reserve should grow with it.
