// Mirror of engine/birdcm/result.py (PhotoResult contract) and the store's rows. Keep the two in step.
export type Point = [number, number];          // normalised 0-1 in the upright original
export type Box = [number, number, number, number];

export interface Exif {
  camera: string | null; lens: string | null; focal_mm: number | null; aperture: number | null;
  shutter: string | null; iso: number | null; ev: number | null; focus_mode: string | null;
  taken_at: string | null; gps: [number, number] | null;
}
export interface Name { sci: string; en: string | null; zh: string | null; p: number }
export interface Species {
  level: "species" | "genus" | "uncertain"; label: Name | null; top5: Name[]; geo: boolean;
  genus?: Name | null; max_cos?: number | null;
  consensus?: { support: number; frames: number };    // set on a burst correction (PhotoRow.species_fix)
  rarity?: Rarity | null;                             // the corrected species' rarity
  visual?: Name & { margin: number };                  // the picture alone, before the location prior
  check?: "rare";                                      // confirmed, but not expected over most of the place (请核对)
  override?: { why: "range"; visual: Name; local: Name | null };   // not confirmed: first name not expected here
  prior?: { max?: number; median?: number; unknown?: boolean };
  lookalike?: string;
  closer?: Name;                                       // a look-alike congener this place expects at least twice as much                                  // burst fix: the look-alike name this frame flipped to
}
export interface Detection {
  box: Box; score: number; clear: boolean | null; species: Species;
  eye: Point | null; eye_p: number | null; beak: Point | null; beak_p: number | null; p_fly: number | null;
}
export interface Region {
  name: string | null; source: "photo" | "scan" | null; gps: [number, number] | null;
  prior?: { lat: number; lon: number; source: "photo" | "map" | "device" | "region"; week: number | null } | null;
}
export interface Place { lat: number; lon: number; label: string; source: "map" | "device" | "region" }
export interface Rarity { tier: number | null; label: string; iucn: string | null; region: string | null }

export interface PhotoResult {
  file: string; width: number; height: number; orientation: number; source: string;
  exif: Exif; region: Region; focus: Point | null; boxes: Detection[]; subject: number | null;
  species: Species | null; eye: Point | null; eye_p: number | null; eye_visible: boolean | null;
  beak: Point | null; beak_p: number | null; flying: boolean | null; p_fly: number | null;
  clear: boolean | null;          // subject passed the clear-bird gate
  sharpness: number | null;       // head sharpness (grad ratio), uncalibrated scale: compare within a batch
  sharpness_region: "eye" | "head" | "box" | null; sharpness_window: Box | null;
  aesthetic: number | null;       // 0-1, whole photo
  rarity: Rarity | null;          // pending
  rejected: boolean; reject_reason: string | null; pending: string[];
  species_own?: Species | null;   // client side: the frame's own naming when its burst corrected it
}

export type PhotoState = "queued" | "working" | "done" | "failed";
export interface PhotoRow {
  id: number; seq: number; path: string; file: string; size: number; mtime_ns: number; state: PhotoState;
  result: PhotoResult | null; error: string | null; reused: number;
  // per scan (stars.py); null = 待定
  stars: number | null; star_reason: string | null; burst_group: number | null; burst_rank: number | null; burst_size: number | null;
  species_fix: Species | null;    // the burst's majority species, when it differs from this frame's own
  quality?: { q: number; parts: Record<string, number | null> | null } | null;   // stars.py "select": Q and its parts
  variants?: string[];            // Lightroom derivatives of this shot (e.g. -Enhanced-NR.dng): listed, never rated
}

export type ScanState = "queued" | "running" | "stopping" | "paused" | "finalizing" | "completed" | "failed";
export interface Counts { queued: number; working: number; done: number; failed: number; total: number }
export interface Ratio { preset?: string; keep?: number; p3?: number; p2?: number; strategy?: string }
export interface Scan {
  id: number; folder: string; recursive: number; region: string | Place | null; ratio: Ratio; state: ScanState;
  error: string | null; created_at: number; counts: Counts; previous?: number[]; fp?: string; last_completed?: number;
}
export interface Snapshot { scan: Scan; photos: PhotoRow[]; cursor: number }
export interface ModelStatus { ready: boolean; missing: string[]; fetch: string; fetch_hint?: string; exiftool: boolean; engine_error: string | null;
  optional_missing?: { name: string; role: string; released: boolean; effect: string }[] }
