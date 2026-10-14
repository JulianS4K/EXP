"""Dual broadcast: one ticket type sold on Exos and on Eventbrite at once.

Models exactly what mig 20261014110000 (Eventbrite inventory) does:
  - Exos checkout sees the Exos count (its own sales + Eventbrite sales it
    has counted) instantly.
  - Eventbrite sells against the capacity Exos last pushed.
  - Every sync tick (the cron: every 2 minutes) Exos reads Eventbrite's
    quantity_sold, counts the new sales against the ticket type (a sale with
    no seat left is counted as oversold), then pushes
        capacity = eb_sold + max(0, free on Exos - buffer)
    A target of 0 can't be sent (Eventbrite refuses 0 on a normal class): the
    old capacity stays ("keep", what's built) unless the zero policy is
    "hide" (a hypothetical second write that hides the class).
  - "writes off" is today's dry run: Eventbrite keeps the capacity the
    organizer typed (the full ticket type) and Exos only counts its sales.

An OVERSELL is a seat sold twice: a sale that takes Exos + Eventbrite past
the ticket type's capacity (counted on the sale that crosses it, whichever
platform). Lost = a buyer who found nothing on their platform (Eventbrite
buyers don't go to Exos, or back).

Demand: sim.py's CRM order sizes; timing either "steady" (the Exos curve from
sim.py, spread through each hour) or "rush" (an on-sale 30 days out: 40% of
demand in its first 20 minutes, front-loaded; the rest on the steady curve).

Usage: python3 scripts/channel-sim/eventbrite_dual.py [runs]
Deterministic (seeded), common random numbers across policies.
"""
import os, random, sys, zlib
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim  # noqa: E402

EB, EX = "Eventbrite", "Exos"
PACK = 8


def seed(*parts):
    """A stable seed (hash() of a str changes per process)."""
    return zlib.crc32(repr(parts).encode())


def make_orders(rng, capacity, pressure, eb_share, shape):
    """(hours_before, channel, qty), far -> near."""
    want = capacity * pressure
    out, got = [], 0
    while got < want:
        q = sim.sample_qty(rng, PACK)
        ch = EB if rng.random() < eb_share else EX
        if shape == "rush" and rng.random() < 0.40:
            # On-sale at T-30 days: first 20 minutes, front-loaded.
            h = 30 * 24 - (rng.random() ** 2) * (20 / 60)
        else:
            h = sim.SAMPLERS[sim.EXOS](rng)
        out.append((h, ch, q))
        got += q
    out.sort(key=lambda o: -o[0])
    return out


def run(orders, cap, buffer, tick_min, writes=True, zero="keep", velocity=0.0):
    tick = tick_min / 60.0
    exos_sold = 0          # Exos's own sales
    eb_sold = 0            # Eventbrite's real quantity_sold
    eb_counted = 0         # Eventbrite sales Exos has counted
    counted_oversold = 0   # what the panel shows in red
    taken = 0              # Eventbrite sales that got an Exos seat when counted
    eb_cap = cap if not writes else max(0, cap - buffer) or cap
    zero_stuck = 0         # syncs that wanted 0 but couldn't send it
    last_tick = None
    sold = lost = over = over_orders = 0
    exos_at_sync = 0       # Exos's sold count at the last sync (for the velocity buffer)

    def sync():
        nonlocal eb_counted, counted_oversold, taken, eb_cap, zero_stuck, exos_at_sync
        # Velocity buffer: hold back what Exos sold in the last window, x velocity.
        buf = max(buffer, round(velocity * (exos_sold - exos_at_sync))) if velocity else buffer
        exos_at_sync = exos_sold
        new = eb_sold - eb_counted
        if new:
            free = cap - exos_sold - taken
            take = min(new, max(free, 0))
            taken += take
            counted_oversold += new - take
            eb_counted = eb_sold
        if not writes:
            return
        free = max(0, cap - exos_sold - taken)
        target = eb_sold + max(0, free - buf)
        if target == 0:
            if zero == "hide":
                eb_cap = 0
            else:
                zero_stuck += 1
            return
        eb_cap = target

    for h, ch, q in orders:
        t = -h
        k = int(t // tick)
        if last_tick is None or k > last_tick:
            # Nothing changes between orders, so one sync at the latest tick
            # before this order stands for all the ticks since the last one.
            if last_tick is not None:
                sync()
            last_tick = k
        if ch == EX:
            view = cap - exos_sold - taken          # Exos's count (uncounted EB sales unseen)
            if view < q:
                lost += q
                continue
            exos_sold += q
        else:
            if eb_cap - eb_sold < q:
                lost += q
                continue
            eb_sold += q
        sold += q
        real = exos_sold + eb_sold
        if real > cap:
            x = min(q, real - cap)
            over += x
            over_orders += 1
    return {"sold": sold, "lost": lost, "over": over, "over_orders": over_orders,
            "servable": min(sum(o[2] for o in orders), cap), "zero_stuck": zero_stuck}


def table(title, rows, demands, sizes, pressures, runs):
    print(f"\n### {title}\n")
    print("| Policy | " + " | ".join(f"{n} ×{p}" for n in sizes for p in pressures) + " |")
    print("|---|" + "---|" * (len(sizes) * len(pressures)))
    for label, kw in rows:
        cells = []
        for n in sizes:
            for p in pressures:
                acc = defaultdict(float)
                for orders in demands[(n, p)]:
                    for k, v in run(orders, n, **kw).items():
                        acc[k] += v
                served = 100 * (acc["sold"] - acc["over"]) / acc["servable"]
                cells.append(f"{served:.0f}% · {acc['over_orders'] / runs:.2f} · {1000 * acc['over'] / max(acc['sold'], 1):.1f}")
        print(f"| {label} | " + " | ".join(cells) + " |")


def main():
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    sizes, pressures = [50, 200, 800], [1.0, 1.5]
    print(f"runs per cell: {runs}; pack {PACK}; Eventbrite share 50% unless stated")
    print("cell: served% (good sales / min(demand, capacity)) · oversold orders per event · oversold tickets per 1,000 sold")
    built = dict(buffer=PACK, tick_min=2)
    policies = [
        ("writes off (today: count only)", dict(buffer=PACK, tick_min=2, writes=False)),
        ("2-min sync, no buffer", dict(buffer=0, tick_min=2)),
        ("2-min sync, buffer 1 pack (built)", built),
        ("2-min sync, buffer 2 packs", dict(buffer=2 * PACK, tick_min=2)),
        ("10-min sync (cron late), buffer 1 pack", dict(buffer=PACK, tick_min=10)),
        ("30-min sync, buffer 1 pack", dict(buffer=PACK, tick_min=30)),
        ("2-min sync, 1 pack, hide at 0 (not built)", dict(buffer=PACK, tick_min=2, zero="hide")),
        ("2-min sync, velocity buffer (≥1 pack, 2× last window's Exos sales)", dict(buffer=PACK, tick_min=2, velocity=2.0)),
        ("10-min sync, velocity buffer", dict(buffer=PACK, tick_min=10, velocity=2.0)),
    ]
    for shape in ("steady", "rush"):
        for share in (0.5,):
            demands = {(n, p): [make_orders(random.Random(seed(n, p, i, shape, share)), n, p, share, shape)
                                for i in range(runs)] for n in sizes for p in pressures}
            table(f"{shape} demand, Eventbrite {int(share * 100)}%", policies, demands, sizes, pressures, runs)
    for shape in ("steady", "rush"):
        for share in (0.2, 0.8):
            demands = {(n, p): [make_orders(random.Random(seed(n, p, i, shape, share)), n, p, share, shape)
                                for i in range(runs)] for n in sizes for p in pressures}
            table(f"{shape} demand, Eventbrite {int(share * 100)}%", [
                ("2-min sync, buffer 1 pack (built)", built),
                ("2-min sync, 1 pack, hide at 0 (not built)", dict(buffer=PACK, tick_min=2, zero="hide")),
            ], demands, sizes, pressures, runs)
    # How often the 0 target gets stuck (built policy).
    print("\n### Syncs that wanted capacity 0 and couldn't send it (built policy, per event)\n")
    for shape in ("steady", "rush"):
        cells = []
        for n in sizes:
            demands = [make_orders(random.Random(seed(n, 1.5, i, shape, 0.5)), n, 1.5, 0.5, shape) for i in range(runs)]
            z = sum(run(o, n, **built)["zero_stuck"] > 0 for o in demands)
            cells.append(f"{n}: {100 * z / runs:.0f}% of events")
        print(f"- {shape}, ×1.5: " + ", ".join(cells))


if __name__ == "__main__":
    main()
