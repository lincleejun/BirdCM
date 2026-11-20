"""The owner's acceptance cases (docs/bird-value.md) at real points; --fit searches K, C, W_C, TO_FREQ for them.

  uv run python bench/bird_score/cases.py TABLE [--fit]
"""
import itertools
import sys

from birdcm import rarity, value

# (scientific, lat, lon, month, photo, label, low, high)
CASES = [
    ("Pyrocephalus rubinus", 37.32, -122.03, 3, False, "朱红霸鹟 Cupertino", 8.5, 9.5),
    ("Pyrocephalus rubinus", 33.2, -117.1, 5, False, "朱红霸鹟 南加州繁殖地", 3.0, 5.0),
    ("Haliaeetus albicilla", 39.1, 121.7, 12, False, "白尾海雕 大连金州湾冬季", 6.0, 7.5),
    ("Haliaeetus albicilla", 37.32, -122.03, 11, True, "白尾海雕 Cupertino 拍到", 9.0, 10.0),
    ("Passer domesticus", 37.32, -122.03, 11, False, "家麻雀 Cupertino", 1.0, 2.0),
    ("Calypte anna", 37.32, -122.03, 11, False, "安氏蜂鸟 Cupertino", 1.0, 2.0),
    ("Calcarius pictus", 37.32, -122.03, 11, True, "斯氏铁爪鹀 Cupertino 拍到", 8.0, 9.8),
    ("Passer montanus", 39.95, 116.4, 11, False, "麻雀 北京", 1.0, 2.0),
]


def run(t, rows):
    out = []
    for sci, lat, lon, m, photo, label, lo, hi in rows:
        div, country = t.region_at(lat, lon)
        out.append((value.value(t, sci, div or country, m, photo, lat, lon), label, lo, hi))
    return out


def loss(results):
    return sum(max(0, lo - r["regional"], r["regional"] - hi) ** 2 if r and r["regional"] is not None else 25
               for r, _, lo, hi in results)


def show(results):
    for r, label, lo, hi in results:
        reg = "—" if r is None or r["regional"] is None else f"{r['regional']:.2f}"
        ok = r and r["regional"] is not None and lo <= r["regional"] <= hi
        feats = {k: round(v, 2) for k, v in (r or {}).get("features", {}).items()}
        print(f"{label:24s} {reg:>5s} (期望 {lo}–{hi}) {'✓' if ok else '✗'} {r and r['status']} {feats}")


if __name__ == "__main__":
    t = rarity.Rarity(sys.argv[1])
    if "--fit" in sys.argv:
        best = None
        for tf in (10, 30, 100):
            value.TO_FREQ = tf
            feats = [value.features(t, sci, *(lambda d, c: (d or c,))(*t.region_at(lat, lon)), m, p, lat, lon)
                     for sci, lat, lon, m, p, *_ in CASES]
            for k, c, w in itertools.product([x / 4 for x in range(6, 21)], [x / 20 for x in range(6, 17)],
                                             [x / 20 for x in range(6, 15)]):
                value.K, value.C, value.W_C = k, c, w
                res = [(value.score(f), *case[5:]) for f, case in zip(feats, CASES)]
                score = loss(res) + 0.01 * (w - 0.3) ** 2      # tie-break toward the design's weight
                if best is None or score < best[0]:
                    best = (score, tf, k, c, w)
        print("best loss %.3f  TO_FREQ %s  K %s  C %s  W_C %s" % best)
        value.TO_FREQ, value.K, value.C, value.W_C = best[1:]
    show(run(t, CASES))
