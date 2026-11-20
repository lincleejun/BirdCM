// The pure parts of looking at photos (no React, no DOM): the zoom viewport and the grid's multi-select.
// Kept apart so they can be tested on their own (look.test.ts). Also the result list's filters and order.
import { type Key, t } from "./i18n";
import { M } from "./i18n.text";
import type { PhotoResult, PhotoRow } from "./types";

/** One viewport for every pane: fit, or s screen (CSS) px per image px around (cx, cy), normalised 0-1 in the
 *  upright photo. Two panes driven by the same View show the same part of their photos at the same size. */
export interface View { fit: boolean; s: number; cx: number; cy: number }
export interface Size { w: number; h: number }
export const FIT: View = { fit: true, s: 1, cx: 0.5, cy: 0.5 };

export const fitScale = (pane: Size, img: Size) => Math.min(pane.w / img.w, pane.h / img.h);
export const scaleOf = (v: View, pane: Size, img: Size) => (v.fit ? fitScale(pane, img) : v.s);
/** 100 %: one photo pixel on one screen (device) pixel, so a Retina screen shows the real detail. */
export const actual = (dpr = globalThis.devicePixelRatio || 1) => 1 / dpr;

/** Keep the photo over the pane: a centre that would show background beyond an edge is pulled back; an axis
 *  narrower than the pane stays centred. */
export function clamp(v: View, pane: Size, img: Size): View {
  if (v.fit) return FIT;
  const s = v.s, ax = (c: number, p: number, i: number) => { const half = p / 2 / (i * s); return half >= 0.5 ? 0.5 : Math.min(1 - half, Math.max(half, c)); };
  return { fit: false, s, cx: ax(v.cx, pane.w, img.w), cy: ax(v.cy, pane.h, img.h) };
}

/** Where the photo sits in its pane (CSS px): what the <img> and the marks are laid out by. */
export function layout(v: View, pane: Size, img: Size) {
  const c = clamp(v, pane, img), s = scaleOf(c, pane, img), w = img.w * s, h = img.h * s;
  return { left: pane.w / 2 - c.cx * w, top: pane.h / 2 - c.cy * h, width: w, height: h, s };
}

/** The photo point (normalised) under pane point (px, py). */
export function pointAt(v: View, pane: Size, img: Size, px: number, py: number): [number, number] {
  const l = layout(v, pane, img);
  return [(px - l.left) / l.width, (py - l.top) / l.height];
}

/** Zoom to scale s keeping the photo point under (px, py) where it is; at or below fit it is fit. */
export function zoomAt(v: View, pane: Size, img: Size, px: number, py: number, s: number): View {
  const fit = fitScale(pane, img), top = 4 * actual();               // up to 400 %
  if (s <= fit * 1.001) return FIT;
  s = Math.min(s, Math.max(top, fit));
  const [u, w] = pointAt(v, pane, img, px, py);
  return clamp({ fit: false, s, cx: u - (px - pane.w / 2) / (img.w * s), cy: w - (py - pane.h / 2) / (img.h * s) }, pane, img);
}

/** Drag by (dx, dy) screen px. */
export function panBy(v: View, pane: Size, img: Size, dx: number, dy: number): View {
  if (v.fit) return v;
  return clamp({ ...v, cx: v.cx - dx / (img.w * v.s), cy: v.cy - dy / (img.h * v.s) }, pane, img);
}

/** fit <-> 100 %, the 100 % centred on the photo point under (px, py) (a click) or on `at` (a key). */
export function toggle(v: View, pane: Size, img: Size, at: [number, number] | null, px?: number, py?: number): View {
  if (!v.fit) return FIT;
  const [cx, cy] = px != null && py != null ? pointAt(v, pane, img, px, py) : at ?? [0.5, 0.5];
  return clamp({ fit: false, s: Math.max(actual(), fitScale(pane, img) * 1.01), cx, cy }, pane, img);
}

/** The bird's head: its eye when one is seen, else the centre of the subject's box; null without a bird. */
export function headOf(r: { eye: number[] | null; eye_visible: boolean | null; boxes: { box: number[] }[]; subject: number | null } | null): [number, number] | null {
  if (!r) return null;
  if (r.eye && r.eye_visible) return [r.eye[0], r.eye[1]];
  const b = r.subject != null ? r.boxes[r.subject]?.box : undefined;
  return b ? [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2] : null;
}

// ---------- the result list: filters and order ----------
export function nameOf(r: PhotoResult): string {
  if (r.rejected) return r.reject_reason || t("look.no_bird");
  const s = r.species;
  if (!s || s.level === "uncertain" || !s.label) return t("look.uncertain");
  if (s.level === "genus") return t("look.genus", { g: s.label.sci.replace(/ sp\.$/, "") });
  return s.label.zh || s.label.en || s.label.sci;
}
export const confirmed = (r: PhotoResult | null) => !!r && !r.rejected && r.species?.level === "species" && !!r.species.label;
// the species a photo is about, rejected or not (a rejected photo still names its bird)
const named_ = (r: PhotoResult | null) => !!r && r.species?.level === "species" && !!r.species.label;
export const speciesKey = (r: PhotoResult | null) => (named_(r) ? r!.species!.label!.sci : "");
// rarer first: 罕见 1, 少见 2, 不常见 3, 常见 4; 无记录 (0) counts as rarest, unknown last
const rank = (p: PhotoRow) => { const t = p.result?.rarity?.tier; return t == null ? 9 : t === 0 ? 0.5 : t; };

/** What the grid's controls say: fs stars ("all", "3".."-1", "drop" = 0 星 and 淘汰), fsp species (sci, "unsure" or ""),
 *  ffly "all" | "fly" | "still", frar the rarest tier kept ("0" = all), sort a key of SORTS. */
export interface ListFilter {
  fs: string; fsp: string; ffly: string; frar: string; sort: string; starsReady: boolean; fold: boolean;
  groupOnly: number | null; onlyIds: ReadonlySet<number> | null;
}
const SORTS: Record<string, (a: PhotoRow, b: PhotoRow) => number> = {
  queue: (a, b) => a.seq - b.seq,
  time: (a, b) => (a.result?.exif.taken_at ?? "~").localeCompare(b.result?.exif.taken_at ?? "~") || a.seq - b.seq,
  star: (a, b) => (b.stars ?? -2) - (a.stars ?? -2) || (b.quality?.q ?? -1) - (a.quality?.q ?? -1) || a.seq - b.seq,
  species: (a, b) => nameOf(a.result!).localeCompare(nameOf(b.result!), "zh-CN") || a.seq - b.seq,
  fly: (a, b) => (b.result?.p_fly ?? 0) - (a.result?.p_fly ?? 0),
  eye: (a, b) => (b.result?.sharpness ?? -1) - (a.result?.sharpness ?? -1),
  rar: (a, b) => rank(a) - rank(b) || (b.stars ?? -2) - (a.stars ?? -2) || a.seq - b.seq,
};

/** The photos the grid lists, in its order. */
export function listView(photos: readonly PhotoRow[], f: ListFilter): PhotoRow[] {
  const { fs, fsp, ffly, frar, starsReady, groupOnly, onlyIds } = f;
  const usesResults = fsp || ffly !== "all" || frar !== "0";
  // filters first, then (folded) one row per burst: its best-ranked frame AMONG the matches (Codex I8)
  const matches = (p: PhotoRow) => {
    if (onlyIds) return onlyIds.has(p.id);
    if (groupOnly !== null) return p.burst_group === groupOnly;
    const r = p.result;
    if (starsReady && fs !== "all") {
      if (fs === "drop" ? !(p.stars != null && p.stars <= 0) : p.stars !== +fs) return false;
    } else if (usesResults && r?.rejected) return false;     // rejected photos show only with 淘汰 / 不留
    if (!usesResults) return true;
    if (!r) return false;
    const t = r.rarity?.tier;
    return (!fsp || (fsp === "unsure" ? !confirmed(r) && !r.rejected : speciesKey(r) === fsp)) && (ffly === "all" || (ffly === "fly") === !!r.flying)
      && (frar === "0" || (t != null && t <= +frar));
  };
  let v = photos.filter(matches);
  if (f.fold && groupOnly === null && !onlyIds) {
    const best = new Map<number, PhotoRow>();
    for (const p of v) {
      const g = p.burst_group ?? -p.id;
      const cur = best.get(g);
      if (!cur || (p.burst_rank ?? 99) < (cur.burst_rank ?? 99)) best.set(g, p);
    }
    const keep = new Set([...best.values()].map((p) => p.id));
    v = v.filter((p) => keep.has(p.id));
  }
  const ready = (p: PhotoRow) => (p.result ? 1 : 0), cmp = SORTS[f.sort];
  // finished photos first in the chosen order; the ones still waiting stay behind them in queue order
  return v.sort((a, b) => ready(b) - ready(a) || (ready(a) && ready(b) ? cmp(a, b) : a.seq - b.seq));
}

// ---------- multi-select ----------
export type Mode = "plain" | "toggle" | "range";

/** A click on `id` in the grid (order = the ids as listed): plain picks it alone (the set empties), toggle
 *  (Cmd / Ctrl) adds or removes it, the photo picked before joining a new set; range (Shift) is every photo between
 *  the anchor and it. The anchor is the last plain or toggle click; range leaves it. */
export function select(set: ReadonlySet<number>, anchor: number | null, id: number, order: readonly number[], mode: Mode): { set: Set<number>; anchor: number } {
  if (mode === "plain") return { set: new Set(), anchor: id };
  if (mode === "toggle") {
    const s = new Set(set);
    if (!s.size && anchor !== null && anchor !== id) s.add(anchor);
    if (s.has(id)) s.delete(id); else s.add(id);
    return { set: s, anchor: id };
  }
  const a = anchor === null ? -1 : order.indexOf(anchor), b = order.indexOf(id);
  if (a < 0 || b < 0) return { set: new Set([id]), anchor: id };
  return { set: new Set(order.slice(Math.min(a, b), Math.max(a, b) + 1)), anchor: anchor! };
}

/** The keys that set stars (Lightroom's): 0-3, X 淘汰, U back to the computed ones (null); undefined: not a star key. */
export function starOf(e: { key: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean }): number | null | undefined {
  if (e.metaKey || e.ctrlKey || e.altKey) return undefined;
  const k = e.key.toLowerCase();
  return k === "x" ? -1 : k === "u" ? null : /^[0-3]$/.test(k) ? +k : undefined;
}

// ---------- the engine's rarity and IUCN words: wire values (the engine stores and compares them), shown translated ----------
const RARITY: Record<string, Key> = {
  "无记录": "rarity.none", "罕见": "rarity.rare", "少见": "rarity.scarce", "不常见": "rarity.uncommon", "常见": "rarity.common",
  "数据不足": "rarity.no_data", "未知": "rarity.unknown", "时间未知": "rarity.no_time", "不可用": "rarity.unavailable",
  "按全国数据估计": "rarity.country_note",
};
/** A rarity label or note from the engine in the page's language (an unknown word as it came). */
export const rarityText = (label: string | null | undefined) => (label && RARITY[label] ? t(RARITY[label]) : label ?? "");
/** IUCN category code -> its name in the page's language. */
export const iucnText = (code: string) => (`iucn.${code}` in M ? t(`iucn.${code}` as Key) : code);
