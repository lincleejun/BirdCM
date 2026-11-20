// Test rows (look.test.ts, Results.test.tsx); not imported by the app, so not in the build.
import type { PhotoResult, PhotoRow } from "./types";

export interface RowOpts {
  stars?: number | null; sci?: string | null; zh?: string; level?: "species" | "genus" | "uncertain"; rejected?: boolean;
  flying?: boolean; tier?: number | null; taken_at?: string; sharpness?: number; p_fly?: number; q?: number;
  burst_group?: number | null; burst_rank?: number | null; done?: boolean; star_auto?: boolean; seq?: number;
}

export function row(id: number, o: RowOpts = {}): PhotoRow {
  const sci = o.sci === undefined ? "Passer montanus" : o.sci;
  const label = sci ? { sci, en: null, zh: o.zh ?? sci, p: 0.9 } : null;
  const result: PhotoResult = {
    file: `p${id}.ARW`, width: 6000, height: 4000, orientation: 1, source: "raw",
    exif: { camera: null, lens: null, focal_mm: null, aperture: null, shutter: null, iso: null, ev: null, focus_mode: null,
      taken_at: o.taken_at ?? null, gps: null },
    region: { name: null, source: null, gps: null }, focus: null,
    boxes: [{ box: [0.2, 0.2, 0.6, 0.6], score: 0.9, clear: true, species: null as never, eye: null, eye_p: null, beak: null, beak_p: null, p_fly: null }],
    subject: 0, species: { level: o.level ?? (label ? "species" : "uncertain"), label, top5: label ? [label] : [], geo: false },
    eye: null, eye_p: null, eye_visible: false, beak: null, beak_p: null, flying: o.flying ?? false, p_fly: o.p_fly ?? 0,
    clear: true, sharpness: o.sharpness ?? 0.5, sharpness_region: null, sharpness_window: null, aesthetic: null,
    rarity: o.tier === undefined ? null : { tier: o.tier, label: `t${o.tier}`, iucn: null, region: null },
    rejected: !!o.rejected, reject_reason: o.rejected ? "没有清楚的鸟" : null, pending: [],
  };
  return {
    id, seq: o.seq ?? id, path: `/f/p${id}.ARW`, file: `p${id}.ARW`, size: 1, mtime_ns: 1, state: o.done === false ? "queued" : "done",
    result: o.done === false ? null : result, error: null, reused: 0,
    stars: o.stars === undefined ? 1 : o.stars, star_reason: null, burst_group: o.burst_group ?? null, burst_rank: o.burst_rank ?? null,
    burst_size: o.burst_group ? 3 : 1, star_auto: o.star_auto ? { stars: 1, reason: null } : null, species_fix: null,
    quality: o.q === undefined ? null : { q: o.q, parts: null },
  };
}
