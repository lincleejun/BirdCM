import { describe, expect, it } from "vitest";
import { row } from "./fixture";
import { clamp, FIT, headOf, layout, type ListFilter, listView, panBy, pointAt, select, starOf, zoomAt } from "./look";

const ALL: ListFilter = { fs: "all", fsp: "", ffly: "all", frar: "0", sort: "queue", starsReady: true, fold: false, groupOnly: null, onlyIds: null };
const ids = (f: Partial<ListFilter>, rows = ROWS) => listView(rows, { ...ALL, ...f }).map((p) => p.id);

const ROWS = [
  row(1, { stars: 3, sci: "Pica serica", zh: "喜鹊", flying: true, tier: 4, q: 0.5, taken_at: "2026-05-01T08:00:03", sharpness: 0.2, p_fly: 0.9 }),
  row(2, { stars: 2, sci: "Passer montanus", zh: "麻雀", tier: 2, q: 0.9, taken_at: "2026-05-01T08:00:01", sharpness: 0.9, p_fly: 0.1 }),
  row(3, { stars: 3, sci: "Passer montanus", zh: "麻雀", tier: 1, q: 0.8, taken_at: "2026-05-01T08:00:02", sharpness: 0.5, p_fly: 0.5 }),
  row(4, { stars: 0, level: "genus", sci: "Parus sp.", tier: null }),
  row(5, { stars: -1, rejected: true, sci: "Pica serica", zh: "喜鹊" }),
  row(6, { stars: 1, sci: null, flying: true, tier: 0 }),
  row(7, { done: false, stars: null }),
];

describe("listView: filters", () => {
  it("star filter keeps exactly that star; 不留 is 0 星 plus 淘汰", () => {
    expect(ids({ fs: "3" })).toEqual([1, 3]);
    expect(ids({ fs: "-1" })).toEqual([5]);
    expect(ids({ fs: "drop" })).toEqual([4, 5]);
  });
  it("star filter does nothing before the stars are ready", () => {
    expect(ids({ fs: "3", starsReady: false })).toEqual([1, 2, 3, 4, 5, 6, 7]);
  });
  it("species filter by scientific name, and 不确定或只到属; rejected photos and unscanned ones drop out", () => {
    expect(ids({ fsp: "Passer montanus" })).toEqual([2, 3]);
    expect(ids({ fsp: "Pica serica" })).toEqual([1]);        // 5 is the same bird but 淘汰
    expect(ids({ fsp: "unsure" })).toEqual([4, 6]);
  });
  it("species and star filters combine", () => {
    expect(ids({ fsp: "Passer montanus", fs: "3" })).toEqual([3]);
  });
  it("flying and rarity filters (无记录 counts as rarest, unknown never matches)", () => {
    expect(ids({ ffly: "fly" })).toEqual([1, 6]);
    expect(ids({ ffly: "still" })).toEqual([2, 3, 4]);
    expect(ids({ frar: "2" })).toEqual([2, 3, 6]);
    expect(ids({ frar: "1" })).toEqual([3, 6]);
  });
  it("只看 a set or one burst wins over the other filters", () => {
    expect(ids({ fs: "3", onlyIds: new Set([2, 5]) })).toEqual([2, 5]);
    const burst = [row(1, { burst_group: 9 }), row(2, { burst_group: 8 }), row(3, { burst_group: 9, stars: 3 })];
    expect(ids({ fs: "3", groupOnly: 9 }, burst)).toEqual([1, 3]);
  });
  it("连拍折叠 keeps one row per burst: its best-ranked frame among the matches", () => {
    const burst = [row(1, { burst_group: 9, burst_rank: 1, stars: 3 }), row(2, { burst_group: 9, burst_rank: 2, stars: 2 }),
      row(3, { burst_group: 9, burst_rank: 3, stars: 2 }), row(4, { burst_group: 8, burst_rank: 1 })];
    expect(ids({ fold: true }, burst)).toEqual([1, 4]);
    expect(ids({ fold: true, fs: "2" }, burst)).toEqual([2]);
  });
});

describe("listView: order", () => {
  it("stars high first (the two 3-star ones by quality, 0.8 before 0.5), 淘汰 last of the scanned, unscanned after", () => {
    expect(ids({ sort: "star" })).toEqual([3, 1, 2, 6, 4, 5, 7]);
  });
  it("the queue order; an unscanned photo stays behind the scanned ones whatever the order", () => {
    expect(ids({})).toEqual([1, 2, 3, 4, 5, 6, 7]);
    expect(ids({ sort: "time" }, [row(1, { done: false }), row(2, { taken_at: "2026-01-01" })])).toEqual([2, 1]);
  });
  it("time, species, rarity, sharpness and flying orders", () => {
    const r = ROWS.slice(0, 3);
    expect(ids({ sort: "time" }, r)).toEqual([2, 3, 1]);
    expect(ids({ sort: "species" }, r)).toEqual([2, 3, 1]);           // 麻雀 (má) before 喜鹊 (xǐ)
    expect(ids({ sort: "rar" }, r)).toEqual([3, 2, 1]);
    expect(ids({ sort: "eye" }, r)).toEqual([2, 3, 1]);
    expect(ids({ sort: "fly" }, r)).toEqual([1, 3, 2]);
  });
});

describe("select", () => {
  const order = [10, 11, 12, 13, 14, 15];
  it("a plain click picks one: the set empties, the anchor moves", () => {
    expect(select(new Set([11, 12]), 11, 13, order, "plain")).toEqual({ set: new Set(), anchor: 13 });
  });
  it("Cmd / Ctrl toggles; the photo picked before joins a new set", () => {
    let r = select(new Set(), 10, 12, order, "toggle");
    expect(r).toEqual({ set: new Set([10, 12]), anchor: 12 });
    r = select(r.set, r.anchor, 14, order, "toggle");
    expect([...r.set].sort()).toEqual([10, 12, 14]);
    r = select(r.set, r.anchor, 12, order, "toggle");
    expect([...r.set].sort()).toEqual([10, 14]);
    expect(r.anchor).toBe(12);
  });
  it("Shift picks the run from the anchor, either way, and keeps the anchor", () => {
    let r = select(new Set(), 11, 14, order, "range");
    expect([...r.set]).toEqual([11, 12, 13, 14]);
    expect(r.anchor).toBe(11);
    r = select(r.set, r.anchor, 10, order, "range");         // re-ranged from the same anchor, not added to
    expect([...r.set]).toEqual([10, 11]);
  });
  it("Shift without an anchor (or one filtered out) picks just that photo", () => {
    expect(select(new Set(), null, 12, order, "range")).toEqual({ set: new Set([12]), anchor: 12 });
    expect(select(new Set(), 99, 12, order, "range")).toEqual({ set: new Set([12]), anchor: 12 });
  });
});

describe("starOf", () => {
  const k = (key: string, mod: Partial<{ metaKey: boolean; ctrlKey: boolean; altKey: boolean }> = {}) =>
    starOf({ key, metaKey: false, ctrlKey: false, altKey: false, ...mod });
  it("0-3, X 淘汰, U back; others and modified keys are not star keys", () => {
    expect([k("0"), k("3"), k("x"), k("X"), k("u")]).toEqual([0, 3, -1, -1, null]);
    expect([k("4"), k("a"), k("3", { metaKey: true }), k("x", { ctrlKey: true })]).toEqual([undefined, undefined, undefined, undefined]);
  });
});

describe("viewport", () => {
  const pane = { w: 1000, h: 800 }, img = { w: 6000, h: 4000 };
  it("zoomAt keeps the photo point under the pointer where it is", () => {
    const v1 = zoomAt(FIT, pane, img, 700, 300, 0.5);
    expect(v1.fit).toBe(false);
    expect(pointAt(v1, pane, img, 700, 300)[0]).toBeCloseTo(pointAt(FIT, pane, img, 700, 300)[0], 9);
    expect(pointAt(v1, pane, img, 700, 300)[1]).toBeCloseTo(pointAt(FIT, pane, img, 700, 300)[1], 9);
    const v2 = zoomAt(v1, pane, img, 200, 600, 0.9);
    expect(pointAt(v2, pane, img, 200, 600)).toEqual(pointAt(v1, pane, img, 200, 600).map((x) => expect.closeTo(x, 9)));
  });
  it("zoomAt: at or below fit is fit; at most 400 %", () => {
    expect(zoomAt(FIT, pane, img, 500, 400, 0.1)).toBe(FIT);
    expect(zoomAt(FIT, pane, img, 500, 400, 50).s).toBe(4);
  });
  it("panBy never shows background beyond an edge", () => {
    const v = zoomAt(FIT, pane, img, 500, 400, 1);
    for (const [dx, dy] of [[1e6, 1e6], [-1e6, -1e6], [1e6, -1e6]]) {
      const l = layout(panBy(v, pane, img, dx, dy), pane, img);
      expect(l.left).toBeLessThanOrEqual(0);
      expect(l.top).toBeLessThanOrEqual(0);
      expect(l.left + l.width).toBeGreaterThanOrEqual(pane.w);
      expect(l.top + l.height).toBeGreaterThanOrEqual(pane.h);
    }
    expect(panBy(FIT, pane, img, 50, 50)).toBe(FIT);
  });
  it("one View on two panes shows the same photo point at the centre, at the same scale", () => {
    const other = { w: 4000, h: 6000 };                         // a portrait frame next to a landscape one
    const v = clamp({ fit: false, s: 1, cx: 0.4, cy: 0.45 }, pane, img);
    const a = layout(v, pane, img), b = layout(v, pane, other);
    expect(a.s).toBe(b.s);
    expect(pointAt(v, pane, img, 500, 400)).toEqual([expect.closeTo(0.4, 9), expect.closeTo(0.45, 9)]);
    expect(pointAt(v, pane, other, 500, 400)).toEqual([expect.closeTo(0.4, 9), expect.closeTo(0.45, 9)]);
  });
  it("headOf: the eye when seen, else the subject box's centre, else null", () => {
    const r = { eye: [0.3, 0.4], eye_visible: true, boxes: [{ box: [0, 0, 0.2, 0.2] }, { box: [0.5, 0.25, 0.75, 0.75] }], subject: 1 };
    expect(headOf(r)).toEqual([0.3, 0.4]);
    expect(headOf({ ...r, eye_visible: false })).toEqual([0.625, 0.5]);
    expect(headOf({ ...r, eye: null })).toEqual([0.625, 0.5]);
    expect(headOf({ ...r, eye: null, subject: null })).toBeNull();
    expect(headOf(null)).toBeNull();
  });
});
