"""Summarize results.json (from sim.py) into the tables in docs/marketplace/channel-sim.md."""
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
R = json.load(open(os.path.join(HERE, "results.json")))
for r in R:
    r["served"] = 100 * r["sold"] / r["servable"]
    r["exo"] = 100 * r["exos_out"] / r["demand"]
CELLS = sorted(set((r["size"], r["pressure"]) for r in R))
def pick(rows, pol, res, f):
    return [x for x in rows if x["policy"] == pol and x["reserve"] == res and x["freq"] == f][0]
COLS = [("even 1 pack, daily", "even", "1 pack", "24h"), ("even 5%, never", "even", "5%", "never"),
        ("even 5%, daily", "even", "5%", "24h"), ("even 5%, adaptive", "even", "5%", "adaptive"),
        ("even 5%, 15 min", "even", "5%", "15m"), ("even 10%, adaptive", "even", "10%", "adaptive"),
        ("even 20%, adaptive", "even", "20%", "adaptive"), ("weighted 5%, adaptive", "weighted", "5%", "adaptive"),
        ("taper 10%→1 pack, adaptive", "taper", "10%>1pk", "adaptive"),
        ("pools 1 pack", "pools1", "rest", "adaptive"), ("pools 2 packs", "pools2", "rest", "adaptive"),
        ("pools 4 packs", "pools4", "rest", "adaptive")]
print("| Strategy | " + " | ".join(f"{n} tix ×{p}" for n, p in CELLS) + " |")
print("|---|" + "---|" * len(CELLS))
for lab, pol, res, f in COLS:
    cells = []
    for c in CELLS:
        rows = [r for r in R if (r["size"], r["pressure"]) == c]
        x = pick(rows, pol, res, f)
        cells.append(f"{x['served']:.0f}% · {x['exo']:.1f} · {x['writes']:.0f}")
    print(f"| {lab} | " + " | ".join(cells) + " |")
print()
print("Frequency (even, 5% reserve): served %")
print("| Size × demand | never | 24h | 6h | 1h | 15m | adaptive |")
print("|---|---|---|---|---|---|---|")
for c in CELLS:
    rows = [r for r in R if (r["size"], r["pressure"]) == c]
    print(f"| {c[0]} ×{c[1]} | " + " | ".join(f"{pick(rows,'even','5%',f)['served']:.1f}" for f in ["never","24h","6h","1h","15m","adaptive"]) + " |")
