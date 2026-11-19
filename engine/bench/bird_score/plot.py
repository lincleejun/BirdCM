import json, math, sys
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager as fm
fm.fontManager.addfont("/System/Library/Fonts/Hiragino Sans GB.ttc")
plt.rcParams["font.family"] = fm.FontProperties(fname="/System/Library/Fonts/Hiragino Sans GB.ttc").get_name()
C, W = 2.0, 1.4
d = json.load(open(sys.argv[1])); out = sys.argv[2]
fig, (a, b) = plt.subplots(1, 2, figsize=(13, 5), dpi=150)
# left: the curve
xs = [i / 50 for i in range(0, 351)]
a.plot(xs, [4.5 + 4.5 * math.tanh((x - C) / W) for x in xs], color="#1f6f78", lw=2.5)
pts = [(n, L) for n, L in d['points'] if n not in ('喜鹊', '黄胸鹀 CR', '丹顶鹤 VU', '圣岛丛鸦 (岛屿特有)')]
top = 0
for name, L in sorted(pts, key=lambda p: p[1]):
    y = 4.5 + 4.5 * math.tanh((L - C) / W); a.plot(L, y, "o", color="#c8553d")
    if y > 8.5:   # crowded near the ceiling: labels stacked below, with leader lines
        a.annotate(f"{name} {y:.2f}", (L, y), (4.6 + top * 0.0, 7.4 - 0.45 * top), fontsize=9, arrowprops=dict(arrowstyle="-", color="#bbb", lw=.8)); top += 1
    else: a.annotate(f"{name} {y:.1f}", (L, y), (6, -12), textcoords="offset points", fontsize=9)
for y, t in [(6, "6：不错"), (8, "8"), (9, "9：鸟分的上限")]: a.axhline(y, ls=":", color="#999", lw=1); a.text(0.05, y + .1, t, fontsize=9, color="#666")
a.set_xticks(range(0, 8)); a.set_xticklabels(["1", "10", "100", "1千", "1万", "10万", "100万", "1千万"])
a.set_xlabel("稀有度：约多少条记录里有 1 条（地区 0.6 + 全球 0.4，再加保护等级）"); a.set_ylabel("鸟分（0–9，照片另加 0–1）")
a.set_title(f"鸟分 = 4.5 + 4.5·tanh((L - {C}) / {W})（加州 11 月的点）"); a.set_ylim(0, 10); a.set_xlim(0, 7)
# right: total distribution
names = {"US-CA": "加州", "US-NY": "纽约州", "GB": "英国", "CN-BJ": "北京"}
w = 0.2
for i, (k, n) in enumerate(names.items()):
    v = d[k]["combined"]; b.bar([j + 0.5 + (i - 1.5) * w for j in range(10)], v, w, label=f"{n}  ≥6 {sum(v[6:]):.1f}%  ≥8 {sum(v[8:]):.2f}%  ≥9 {v[9]:.2f}%")
b.axvline(6, ls=":", color="#999"); b.axvline(9, ls=":", color="#999")
b.set_xticks(range(0, 11)); b.set_xlabel("总分"); b.set_ylabel("占观察次数 %"); b.legend(fontsize=9)
b.set_title("总分分布（11 月；照片加分先按 0–1 均匀假设）")
fig.tight_layout(); fig.savefig(out)
