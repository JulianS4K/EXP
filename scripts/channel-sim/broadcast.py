"""Broadcast vs split: list every unsold GA ticket on every marketplace at once.

Same demand as sim.py (Terminal-2 CRM). Broadcasting means each marketplace
shows the whole unsold count (minus a buffer). When a ticket sells on one,
the others only learn after their sync lag (a sale webhook / poll, then a
listing update): until then they still show the old number. A buyer who buys
there against stock that's already gone is an OVERSELL: an order Exos can't
fill (marketplaces fine the seller and can suspend the account).

Lags (hours) by how each marketplace reports sales and takes updates
(docs/marketplace/README.md): StubHub / SeatGeek / GoTickets / TickPick
webhooks + a REST update ~3-5 min; Vivid Seats polling only ~10 min;
Gametime listings are a CSV upload every < 6 h, so ~6 h.

Policies:
  broadcast        everything everywhere, buffer B held back from listings
  bcast-gt-split   broadcast on the fast marketplaces; Gametime gets a fixed
                   share (its CSV can't be pulled in time)
Compared against the auto split (sim.py: 10% reserve -> 1 pack at 48 h,
adaptive rebalance).

Usage: python3 scripts/channel-sim/broadcast.py [runs]
"""
import bisect, os, random, sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim  # noqa: E402

LAG = {"StubHub": 3 / 60, "Gametime": 6.0, "Vivid Seats": 10 / 60, "TickPick": 5 / 60, "GoTickets": 3 / 60}


def run_broadcast(orders, capacity, pack, buffer, gt_share=None):
    """orders: (hours_before, channel, qty), far -> near."""
    stock = capacity                    # true unsold
    hist_t = []                         # real-time history of stock, as -hours_before (increasing)
    hist_s = []
    own = defaultdict(list)             # channel -> [(-h, qty)] its own sales
    gt_left = None
    start = stock
    if gt_share is not None:
        gt_left = int(capacity * gt_share)
        stock -= gt_left                # Gametime's fixed share comes out of the broadcast pool
    start = stock
    sold = lost = over = over_orders = 0

    def stock_at(t):                    # stock as of real time t (t = -hours_before)
        i = bisect.bisect_right(hist_t, t) - 1
        return start if i < 0 else hist_s[i]

    for h, ch, q in orders:
        t = -h
        if ch == sim.EXOS:
            # Exos checkout sees the true count (minus nothing: it is the source).
            if stock >= q:
                stock -= q; sold += q
                hist_t.append(t); hist_s.append(stock)
            else:
                lost += q
            continue
        if gt_left is not None and ch == "Gametime":
            if gt_left >= q:
                gt_left -= q; sold += q
            else:
                lost += q
            continue
        lag = LAG[ch]
        seen = stock_at(t - lag) - sum(x for (ts, x) in own[ch] if ts > t - lag)
        view = seen - buffer
        if view < q:
            lost += q
            continue
        if stock >= q:
            stock -= q; sold += q
            hist_t.append(t); hist_s.append(stock)
            own[ch].append((t, q))
        else:
            over += q; over_orders += 1          # accepted on the marketplace, can't be filled
    demand = sum(o[2] for o in orders)
    return {"sold": sold, "lost": lost, "over": over, "over_orders": over_orders,
            "demand": demand, "servable": min(demand, capacity)}


def main():
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 150
    pack = 8
    sizes = [50, 200, 800]
    pressures = [0.7, 1.0, 1.5]
    configs = [("broadcast, no buffer", 0, None), ("broadcast, buffer 1 pack", pack, None),
               ("broadcast, buffer 2 packs", 2 * pack, None),
               ("broadcast + Gametime 20% share, buffer 1 pack", pack, 0.20),
               ("broadcast + Gametime 20% share, buffer 2 packs", 2 * pack, 0.20)]
    print(f"runs per cell: {runs}; pack {pack}; lags (min): " + ", ".join(f"{k} {v * 60:.0f}" for k, v in LAG.items()))
    print("cell: served% (sold / min(demand, capacity)) · oversold orders per event · oversold tickets per 1,000 sold\n")
    header = "| Policy | " + " | ".join(f"{n} ×{p}" for n in sizes for p in pressures) + " |"
    print(header)
    print("|---|" + "---|" * (len(sizes) * len(pressures)))
    demands = {}
    for n in sizes:
        for p in pressures:
            demands[(n, p)] = [sim.make_demand(random.Random(hash((n, p, i)) & 0xffffffff), n, p, sim.DATA["alpha"], 0.15, pack)[0]
                               for i in range(runs)]
    for label, buf, gt in configs:
        cells = []
        for n in sizes:
            for p in pressures:
                acc = defaultdict(float)
                for orders in demands[(n, p)]:
                    for k, v in run_broadcast(orders, n, pack, buf, gt).items():
                        acc[k] += v
                served = 100 * acc["sold"] / acc["servable"]
                cells.append(f"{served:.0f}% · {acc['over_orders'] / runs:.2f} · {1000 * acc['over'] / max(acc['sold'], 1):.1f}")
        print(f"| {label} | " + " | ".join(cells) + " |")
    # The auto split, same demand.
    cells = []
    for n in sizes:
        for p in pressures:
            acc = defaultdict(float)
            for orders in demands[(n, p)]:
                r = sim.run_event(orders, n, pack, max(pack, round(n * .10)), "even", "adaptive", taper_h=48)
                for k, v in r.items():
                    acc[k] += v
            cells.append(f"{100 * acc['sold'] / acc['servable']:.0f}% · 0 · 0")
    print("| auto split (10% → 1 pack at 48 h) | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
