import sys
from birdcm import rarity, value
t = rarity.Rarity(sys.argv[1])
for reg, m in [("US-CA", 11), ("US-NY", 5), ("GB", 5), ("CN-BJ", 11)]:
    rows = t.db.execute("SELECT s.scientific, c.n FROM counts c JOIN species s ON s.id=c.species_id JOIN regions r ON r.id=c.region_id WHERE r.code=? AND c.month=? AND c.n>0", (reg, m)).fetchall()
    tot = sum(n for _, n in rows); vals = [(value.value(t, s, reg, m)["regional"] or 0, n) for s, n in rows]
    sp = lambda k: sum(1 for v, _ in vals if v >= k); w = lambda k: 100 * sum(n for v, n in vals if v >= k) / tot
    print(f"{reg} {m}: species {len(vals)} | ≥6 {sp(6)} ≥8 {sp(8)} ≥9 {sp(9)} | sightings ≥6 {w(6):.2f}% ≥8 {w(8):.3f}% ≥9 {w(9):.4f}%")
