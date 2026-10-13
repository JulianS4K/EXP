"""Exos channel allocation simulator: reserve + marketplace split + rebalancing.

Question: an organizer sells one ticket type on Exos and on the resale
marketplaces at once. Exos keeps a reserve (at least one full pack) for its
own checkout; the rest is split across the marketplaces and rebalanced on a
schedule. How big should the reserve be, how should the shared part be split,
and how often should it be rebalanced?

Demand is modelled from Terminal-2's CRM (s4kcs_orders, 2025-10 .. 2026-10,
~204k tickets on StubHub, Gametime, Vivid Seats, TickPick, GoTickets):
  - each marketplace's share of tickets,
  - when buyers buy relative to the event start (days, per marketplace),
  - the last 72 h hour by hour (Vivid + GoTickets exact timestamps),
  - order sizes (1..12),
  - how lopsided a single event is across marketplaces (881 events with
    50+ tickets: the top marketplace takes 46% on average, HHI 0.33).
The numbers are in data.json (aggregates only; no order rows).

A buyer arrives on one channel wanting q tickets. They buy if that channel
holds q unsold tickets; otherwise the sale is lost (marketplace buyers don't
come looking on Exos). The headline metric is MISALLOCATED LOSS: tickets lost
while at least q tickets sat unsold somewhere else. That is the cost of the
split; demand above capacity is lost under every policy and is reported
separately.

Policies:
  even      reserve R, the rest split evenly; each rebalance re-splits the
            unsold marketplace tickets evenly (the reserve is topped back to R
            first from what's unsold, then any surplus is shared out).
  weighted  same, but the re-split follows observed demand per marketplace
            (orders seen, sold or lost, plus a prior of the CRM shares).
  pools     Exos's current model (mig 20260928010000): each marketplace holds a
            small pool (2 packs); everything else stays in the Exos reserve and
            pools are topped up at each rebalance.
Frequencies: never, 24h, 6h, 1h, 15m, and "adaptive" (24h until T-7d, 6h
until T-48h, 1h until T-24h, 15m in the last day).

Usage: python3 scripts/channel-sim/sim.py [runs] > report.txt
Pure standard library; deterministic (seeded); common random numbers across
policies so differences are not noise.
"""
import json, math, os, random, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = json.load(open(os.path.join(HERE, "data.json")))
MKTS = DATA["marketplaces"]                     # names
EXOS = "Exos"
CHANNELS = MKTS + [EXOS]
H = 1.0                                         # hours

# ---- demand model ------------------------------------------------------------

def _hours_sampler(day_buckets, hourly72):
    """Hours before start, from day buckets (lo day -> tickets) and the
    72-hour shape (which replaces days 0..2 inside each channel's own mass)."""
    los = sorted(int(k) for k in day_buckets)
    spans = []
    for i, lo in enumerate(los):
        hi = los[i + 1] if i + 1 < len(los) else 180
        spans.append((lo, hi, day_buckets[str(lo)]))
    early = sum(w for lo, hi, w in spans if lo >= 3)
    first3 = sum(w for lo, hi, w in spans if lo < 3)
    total = early + first3
    h72 = sum(hourly72)
    cum = []
    acc = 0.0
    for h, w in enumerate(hourly72):
        acc += first3 * w / h72
        cum.append((acc / total, ("h", h)))
    for lo, hi, w in spans:
        if lo < 3:
            continue
        acc += w
        cum.append((acc / total, ("d", lo, hi)))

    def sample(rng):
        u = rng.random()
        for c, b in cum:
            if u <= c:
                if b[0] == "h":
                    return b[1] + rng.random()
                return (b[1] + rng.random() * (b[2] - b[1])) * 24
        return 72.0
    return sample

SAMPLERS = {m: _hours_sampler(DATA["day_buckets"][m], DATA["hourly72"]) for m in MKTS}
# Exos direct: no history. Assume an organizer's own link sells earlier than
# resale (fans + presale): the pooled marketplace curve stretched x1.5.
_pooled = {k: sum(DATA["day_buckets"][m][k] for m in MKTS) for k in DATA["day_buckets"][MKTS[0]]}
_exos_base = _hours_sampler(_pooled, DATA["hourly72"])
SAMPLERS[EXOS] = lambda rng: min(_exos_base(rng) * 1.5, 180 * 24)

QTY = [(int(k), v) for k, v in sorted(DATA["order_qty"].items(), key=lambda kv: int(kv[0]))]
_QTOT = sum(v for _, v in QTY)

def sample_qty(rng, cap):
    u = rng.random() * _QTOT
    for q, v in QTY:
        u -= v
        if u <= 0:
            return min(q, cap)
    return min(QTY[-1][0], cap)

BASE = DATA["shares"]                           # marketplace -> share of marketplace demand

def gamma(rng, a):
    return rng.gammavariate(a, 1.0) if a > 0 else 0.0

def event_shares(rng, alpha, exos_share):
    g = {m: gamma(rng, alpha * BASE[m]) for m in MKTS}
    s = sum(g.values()) or 1.0
    out = {m: (1 - exos_share) * g[m] / s for m in MKTS}
    out[EXOS] = exos_share
    return out

def make_demand(rng, capacity, pressure, alpha, exos_share, pack):
    """List of (hours_before, channel, qty), sorted far -> near."""
    shares = event_shares(rng, alpha, exos_share)
    want = capacity * pressure
    orders = []
    got = 0
    while got < want:
        u = rng.random()
        ch = EXOS
        for c in CHANNELS:
            u -= shares[c]
            if u <= 0:
                ch = c
                break
        q = sample_qty(rng, pack)
        orders.append((SAMPLERS[ch](rng), ch, q))
        got += q
    orders.sort(key=lambda o: -o[0])
    return orders, shares

# ---- schedules ---------------------------------------------------------------

def next_tick(freq, h):
    """Next rebalance time (hours before start) strictly closer than h."""
    if freq == "never":
        return -1.0
    if freq == "adaptive":
        step = 24 if h > 168 else 6 if h > 48 else 1 if h > 24 else 0.25
    else:
        step = {"24h": 24, "6h": 6, "1h": 1, "15m": 0.25}[freq]
    t = math.floor(h / step - 1e-9) * step
    return t if t >= 0 else -1.0

# ---- one event ---------------------------------------------------------------

def run_event(orders, capacity, pack, reserve, policy, freq, pool_packs=2, taper_h=None):
    stock = {c: 0 for c in CHANNELS}
    seen = defaultdict(float)
    pool = pool_packs * pack
    cur_h = [1e9]

    def target_weights():
        if policy == "weighted":
            prior = 4.0
            return {m: seen[m] + prior * BASE[m] for m in MKTS}
        return {m: 1.0 for m in MKTS}

    def split(n, w):
        tot = sum(w.values())
        raw = {m: n * w[m] / tot for m in MKTS}
        out = {m: int(raw[m]) for m in MKTS}
        left = n - sum(out.values())
        for m in sorted(MKTS, key=lambda m: -(raw[m] - out[m]))[:left]:
            out[m] += 1
        return out

    writes = 0

    def rebalance(initial=False):
        nonlocal writes
        unsold = sum(stock.values())
        if policy == "pools":
            # Pools: each marketplace up to `pool`; the rest stays on Exos.
            free = unsold - sum(min(stock[m], pool) for m in MKTS)
            new = {}
            for m in MKTS:
                keep = min(stock[m], pool)
                add = min(pool - keep, max(0, free - reserve_floor()))
                free -= add
                new[m] = keep + add
            new[EXOS] = unsold - sum(new.values())
        else:
            # Taper: the reserve drops to one pack inside taper_h of the start.
            res = reserve if taper_h is None or cur_h[0] > taper_h else min(reserve, pack)
            r = min(unsold, res)
            new = split(unsold - r, target_weights())
            new[EXOS] = r
        for c in CHANNELS:
            if c != EXOS and new[c] != stock[c] and not initial:
                writes += 1
        stock.update(new)

    def reserve_floor():
        return min(pack, capacity)

    stock[EXOS] = capacity
    rebalance(initial=True)

    sold = defaultdict(int)
    lost = 0
    misallocated = 0
    exos_out = 0
    tick = next_tick(freq, orders[0][0] + 1) if orders else -1
    for h, ch, q in orders:
        # Apply any due rebalance (state only changes on sales, so one
        # rebalance per gap is the same as every tick in it).
        if tick >= 0 and tick >= h:
            cur_h[0] = tick
            rebalance()
            tick = next_tick(freq, h)
        seen[ch] += q
        if stock[ch] >= q:
            stock[ch] -= q
            sold[ch] += q
            if policy == "pools" and ch != EXOS:
                # Pools top up in the same transaction as the sale (mig 20260928010000).
                free = stock[EXOS] - reserve_floor()
                add = max(0, min(pool - stock[ch], free))
                if add:
                    writes += 1
                stock[ch] += add
                stock[EXOS] -= add
        else:
            lost += q
            if ch == EXOS:
                exos_out += q
            if sum(stock.values()) >= q:
                misallocated += q
    total_sold = sum(sold.values())
    demand = sum(o[2] for o in orders)
    return {
        "demand": demand, "servable": min(demand, capacity),
        "sold": total_sold, "lost": lost, "mis": misallocated, "exos_out": exos_out,
        "unsold": capacity - total_sold, "writes": writes,
        "exos_sold": sold[EXOS],
    }

# ---- grid ----------------------------------------------------------------------

def main():
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 150
    alpha = DATA["alpha"]
    exos_share = 0.15
    pack = 8          # a full pack = the event's max per order (98% of CRM orders are <= 8)
    sizes = [50, 200, 800]
    pressures = [0.7, 1.0, 1.5]
    reserves = [("1 pack", lambda n: pack), ("5%", lambda n: max(pack, round(n * .05))),
                ("10%", lambda n: max(pack, round(n * .10))), ("20%", lambda n: max(pack, round(n * .20))),
                ("35%", lambda n: max(pack, round(n * .35)))]
    freqs = ["never", "24h", "6h", "1h", "15m", "adaptive"]
    policies = ["even", "weighted"]

    rows = []
    for n in sizes:
        for p in pressures:
            demands = []
            for i in range(runs):
                rng = random.Random(hash((n, p, i)) & 0xffffffff)
                demands.append(make_demand(rng, n, p, alpha, exos_share, pack)[0])
            def agg(policy, rname, rfun, f):
                acc = defaultdict(float)
                for orders in demands:
                    r = run_event(orders, n, pack, rfun(n), policy, f)
                    for k, v in r.items():
                        acc[k] += v
                return {k: v / runs for k, v in acc.items()}
            def agg_x(policy, rfun, f, **kw):
                acc = defaultdict(float)
                for orders in demands:
                    r = run_event(orders, n, pack, rfun(n), policy, f, **kw)
                    for k, v in r.items():
                        acc[k] += v
                return {k: v / runs for k, v in acc.items()}
            for policy in policies:
                for rname, rfun in reserves:
                    for f in freqs:
                        rows.append((n, p, policy, rname, f, agg(policy, rname, rfun, f)))
            for pp in (1, 2, 4):
                for f in ("never", "adaptive"):
                    rows.append((n, p, f"pools{pp}", "rest", f, agg_x("pools", lambda n: 0, f, pool_packs=pp)))
            for f in freqs:
                rows.append((n, p, "taper", "10%>1pk", f, agg_x("even", lambda n: max(pack, round(n * .10)), f, taper_h=48)))
    json.dump([{"size": r[0], "pressure": r[1], "policy": r[2], "reserve": r[3], "freq": r[4], **r[5]} for r in rows],
              open(os.path.join(HERE, "results.json"), "w"), indent=0)

    print(f"runs per cell: {runs}; Exos direct share {exos_share:.0%}; pack {pack}; alpha {alpha}")
    for n in sizes:
        for p in pressures:
            print(f"\n== {n} tickets, demand {p:.1f}x capacity ==")
            print(f"{'policy':9} {'reserve':7} {'freq':9} {'served%':>7} {'misalloc%':>9} {'exosOut%':>8} {'unsold':>6} {'writes':>6}")
            cell = [r for r in rows if r[0] == n and r[1] == p]
            for r in cell:
                a = r[5]
                print(f"{r[2]:9} {r[3]:7} {r[4]:9} {100*a['sold']/a['servable']:7.1f} {100*a['mis']/a['demand']:9.1f} {100*a['exos_out']/a['demand']:8.1f} {a['unsold']:6.1f} {a['writes']:6.1f}")

if __name__ == "__main__":
    main()
