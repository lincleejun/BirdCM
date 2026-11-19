"""Regional vs global bird score. Global L = the species' rarity where it is easiest to see this month
(min over countries and divisions with >= 2000 records and n >= 5). Combined L = w*L_region + (1-w)*L_global."""
import sqlite3, math, sys, json
from collections import defaultdict
D = {"NT": 0.3, "VU": 0.6, "EN": 1.0, "CR": 1.5}
db = sqlite3.connect(sys.argv[1]); month = 11
C, W, WR = float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
def bird(L): return 4.5 + 4.5 * math.tanh((L - C) / W)
iucn = dict(db.execute("SELECT id, iucn FROM species")); sci = dict(db.execute("SELECT id, scientific FROM species"))
tots = dict(db.execute("SELECT region_id, SUM(n) FROM counts WHERE month=? GROUP BY 1", (month,)))
ok = {r for (r,) in db.execute("SELECT region_id FROM months WHERE month=? AND records>=2000", (month,))}
Lg = defaultdict(lambda: 99.0)
for rid, s, n in db.execute("SELECT region_id, species_id, n FROM counts WHERE month=? AND n>=5", (month,)):
    if rid in ok: Lg[s] = min(Lg[s], math.log10(tots[rid] / n))
SHOW = {"Zonotrichia leucophrys": "白冠带鹀", "Passer domesticus": "家麻雀", "Haliaeetus leucocephalus": "白头海雕",
        "Calcarius lapponicus": "铁爪鹀", "Calcarius ornatus": "栗领铁爪鹀 VU", "Gymnogyps californianus": "加州神鹫 CR",
        "Calcarius pictus": "斯氏铁爪鹀", "Aphelocoma insularis": "圣岛丛鸦 (岛屿特有)", "Fringilla montifringilla": "燕雀 (亚欧常见)",
        "Emberiza aureola": "黄胸鹀 CR", "Grus japonensis": "丹顶鹤 VU", "Pica serica": "喜鹊"}
result = {}
for code in sys.argv[5:]:
    rid = db.execute("SELECT id FROM regions WHERE code=?", (code,)).fetchone()[0]
    rows = db.execute("SELECT species_id, n FROM counts WHERE region_id=? AND month=? AND n>0", (rid, month)).fetchall()
    tot = sum(n for _, n in rows); out = []
    for s, n in rows:
        Lr = math.log10(tot / n); g = min(Lg[s], Lr); p = D.get(iucn[s] or "", 0)
        out.append((sci[s], n, bird(Lr + p), bird(g + p), bird(WR * Lr + (1 - WR) * g + p)))
        if code == 'US-CA' and sci[s] in SHOW: result.setdefault('points', []).append((SHOW[sci[s]], WR * Lr + (1 - WR) * g + p))
    # total = bird + photo bonus; photo bonus assumed uniform 0..1 (unknown until measured)
    def bins(k):
        h = [0.0] * 10
        for r in out:
            for j in range(20): h[min(9, int(r[k] + (j + .5) / 20))] += r[1] / tot / 20
        return [round(100 * x, 2) for x in h]
    result[code] = {"region": bins(2), "combined": bins(4)}
    print(f"== {code} 11月  C={C} W={W} 地区权重={WR}")
    for r in out:
        if r[0] in SHOW: print(f"   {SHOW[r[0]]:14s} 地区 {r[2]:.2f}  全球 {r[3]:.2f}  合成 {r[4]:.2f}")
    for k in ("region", "combined"):
        b = result[code][k]; print(f"   总分分布({k}) 1-10:", b, "| ≥6 %.1f%% ≥8 %.2f%% ≥9 %.3f%%" % (sum(b[6:]), sum(b[8:]), b[9]))
json.dump(result, open(sys.argv[0].replace(".py", f"-{C}-{W}-{WR}.json"), "w"))
