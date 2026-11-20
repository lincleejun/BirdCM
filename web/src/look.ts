// The pure parts of looking at photos (no React, no DOM): the zoom viewport and the grid's multi-select.
// Kept apart so they can be tested on their own.

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
