import type { KeyboardEvent, ReactNode } from "react";
import { forwardRef, memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { get, post, put, useEngine } from "./api";
const CHIPS = 3;                                   // species chips shown before "+n", so the bar stays one row at 1440 px
import CorrectPanel, { type Pick, type Scope } from "./Correct";
import ExportDialog from "./Export";
import KeepControl, { KeepButton, keepOf, type KeepSetting } from "./Keep";
import LocationPicker, { type Country, PlaceName, PlaceOf } from "./Location";
import { getLang, type Key, t } from "./i18n";
import { confirmed, iucnText, listView, nameOf, rarityText, select, speciesKey, starOf } from "./look";
import { Candidates, MarkControls, type MarkSet, named, SpName, useMarks, Verdict } from "./names";
import type { Exif, PhotoRow, Place, Scan, Snapshot } from "./types";
import { Marks, StarSet, Viewer } from "./Viewer";

const lookup = (keys: Record<string, Key>) => (k: string) => (keys[k] ? t(keys[k]) : k);
export const stateLabel = lookup({ queued: "results.st_queued", running: "results.st_running", stopping: "results.st_stopping", paused: "results.st_paused",
  finalizing: "results.st_finalizing", completed: "results.st_completed", failed: "results.st_failed" });
const rowLabel = lookup({ queued: "results.st_queued", working: "results.row_working", unscanned: "results.row_unscanned", failed: "results.row_failed" });
const previewLabel = lookup({ queued: "results.pv_queued", working: "results.pv_working", unscanned: "results.row_unscanned", failed: "results.row_failed" });
type Phase = "scanning" | "paused" | "complete";
type RowState = "ready" | "queued" | "working" | "unscanned" | "failed";

// ---------- formatting ----------
const starTxt = (s: number) => (s === -1 ? t("viewer.reject") : s === 0 ? t("viewer.zero") : "★".repeat(s) + "☆".repeat(3 - s));
const starLabel = (s: number | null) => (s === null ? t("viewer.pending") : s === -1 ? t("viewer.reject") : t("results.n_stars", { n: s }));
const pct = (p: number) => `${Math.round(p * 100)}%`;
const evText = (ev: number | null) => (ev === null ? "— EV" : `${ev > 0 ? "+" : ""}${+ev.toFixed(1)} EV`);
const sharpTxt = (v: number | null | undefined) => (v == null ? "—" : v.toFixed(2));
const region = lookup({ eye: "results.rg_eye", head: "results.rg_head", box: "results.rg_box" });
const rarityNote = () => t("results.rarity_note");
const qLabel = lookup({ sharp_burst: "results.q_sharp_burst", sharp_species: "results.q_sharp_species", eye: "results.q_eye", size: "results.q_size",
  focus: "results.q_focus", aesthetic: "results.q_aesthetic", detection: "results.q_detection", burst_length: "results.q_burst_length",
  fly: "results.q_fly", rare: "results.q_rare", exposure: "results.q_exposure" });
const ADDED = ["fly", "rare", "exposure"];      // added to Q as is (signed), shown only when not 0
function qParts(parts: Record<string, number | null> | null | undefined): string {
  if (!parts) return "";
  return Object.entries(parts).filter(([k, v]) => !(ADDED.includes(k) && !v))
    .map(([k, v]) => `${qLabel(k)} ${v == null ? t("results.unknown") : ADDED.includes(k) ? `${v > 0 ? "+" : ""}${v}` : v.toFixed(2)}`).join(" · ");
}
const priorSrc = lookup({ photo: "results.ps_photo", map: "results.ps_map", device: "results.ps_device", region: "results.ps_region" });
const fmtTime = (v: string | null | undefined) => (v ? v.slice(0, 19).replace("T", " ") : t("results.no_time"));

function Settings({ e }: { e: Partial<Exif> | null | undefined }) {
  if (!e) return <div className="settings"><span>{t("results.reading_exif")}</span></div>;
  return (
    <div className="settings">
      <span>{e.focal_mm != null ? `${+e.focal_mm.toFixed(0)} mm` : "— mm"}</span> <span>{e.aperture != null ? `f/${e.aperture}` : "f/—"}</span>{" "}
      <span>{e.shutter ? `${e.shutter} s` : "— s"}</span> <span>ISO {e.iso ?? "—"}</span> <span>{evText(e.ev ?? null)}</span>
    </div>
  );
}

interface TileAct { pick: (id: number, mode: "plain" | "toggle" | "range") => void; open: (id: number) => void; group: (p: PhotoRow) => void; ref: (id: number, el: HTMLButtonElement | null) => void }

const Tile = memo(function Tile({ p, st, active, picked, complete, more, marks, exif: e, act }: {
  p: PhotoRow; st: RowState; active: boolean; picked: boolean; complete: boolean; more: boolean; marks: MarkSet | null;
  exif: Partial<Exif> | null | undefined; act: { current: TileAct };
}) {
  const r = p.result;
  const name = r ? (r.rejected ? nameOf(r) : named(r.species).title) : rowLabel(st);
  return (
    <button type="button" className="tile" data-state={st} data-picked={picked || undefined} aria-pressed={active} tabIndex={active ? 0 : -1}
      aria-describedby="photo-keys" aria-label={t("results.tile_label", { name, stars: complete ? starLabel(p.stars) : t("viewer.pending_stars"), file: p.file })}
      ref={(el) => act.current.ref(p.id, el)}
      onClick={(ev) => act.current.pick(p.id, ev.shiftKey ? "range" : ev.metaKey || ev.ctrlKey ? "toggle" : "plain")} onDoubleClick={() => act.current.open(p.id)}>
      <Photo row={p} marks={marks} show={!!r || active} />
      <span className="row-result">{r && r.rejected && r.species?.label ? <span className="name dim">{name} · {named(r.species).title}</span>
        : r && !r.rejected ? <SpName sp={r.species} size="card" /> : <span className={r ? "name" : "scan-name"}>{name}</span>}
        <span className="tile-meta">
          {complete && p.stars !== null ? <span className="stars">{starTxt(p.stars)}</span> : <span className="pending-stars">{t("viewer.pending_stars")}</span>}
          {complete && p.star_auto && <span className="pill" title={t("results.computed_as", { stars: starLabel(p.star_auto.stars) })}>{t("viewer.manual_stars")}</span>}
          {r && !r.rejected && r.rarity && r.rarity.tier != null && <span className={`pill${r.rarity.tier <= 2 ? " rare" : ""}`}>{rarityText(r.rarity.label)}</span>}
          {r && !r.rejected && r.species_own && <span className="pill">{r.species?.manual ? t("results.by_owner") : t("results.by_burst")}</span>}
          {more && (p.burst_size ?? 1) > 1 && (
            <span className="pill more" role="link" title={t("results.only_group")} onClick={(ev) => { ev.stopPropagation(); act.current.group(p); }}>+{(p.burst_size ?? 1) - 1}</span>
          )}
          {r && !r.rejected && r.flying !== null && <span className="pill">{r.flying ? t("results.flying") : t("results.not_flying")}</span>}
        </span>
        {r && <span className="small reason-line">
          {complete && p.star_reason ? p.star_reason : r.rejected ? t("results.not_rated") : r.eye_visible ? t("results.eye_sharp", { s: sharpTxt(r.sharpness) }) : t("results.no_eye")}</span>}
        {st === "failed" && <span className="small reason-line">{p.error}</span>}
      </span>
      <span className="row-settings"><span className="file">{p.file}</span>
        {e && <span className="small"> · {e.focal_mm != null ? `${+e.focal_mm.toFixed(0)} mm` : "—"} · f/{e.aperture ?? "—"} · {e.shutter ?? "—"} s · ISO {e.iso ?? "—"} · {evText(e.ev ?? null)}</span>}</span>
    </button>
  );
});

function Photo({ row, marks, big, show, alt = "" }: { row: PhotoRow; marks: MarkSet | null; big?: boolean; show: boolean; alt?: string }) {
  // the URL names the file version too: ids restart with a new database, and a browser may still hold an image cached
  // for a day under the same id by an older build
  const src = `/api/photos/${row.id}/${big ? "preview" : "thumb"}?v=${row.size}-${row.mtime_ns}`;
  const r = row.result;
  if (!show) return <span className="ph"><span className="placeholder">{row.file}</span></span>;
  if (!r) return <span className="ph"><img src={src} alt={alt} loading="lazy" /></span>;
  return (
    <span className="ph">
      <span className="frame" style={{ aspectRatio: `${r.width} / ${r.height}`, ["--ar" as string]: r.width / r.height }}>
        <img src={src} alt={alt} loading="lazy" decoding="async" />
        {marks && <Marks r={r} m={marks} />}
      </span>
    </span>
  );
}

const fixedRows = new WeakMap<PhotoRow, PhotoRow>();          // same input row -> same object, so memoised rows hold
function withFix(p: PhotoRow): PhotoRow {
  if (!p.species_fix || !p.result) return p;
  let f = fixedRows.get(p);
  if (!f) {
    f = { ...p, result: { ...p.result, species: p.species_fix, species_own: p.result.species, rarity: p.species_fix.rarity ?? null } };
    fixedRows.set(p, f);
  }
  return f;
}

// ---------- export ----------
function exportRow(p: PhotoRow) {
  const r = p.result, e = r?.exif, s = r?.species, l = s?.level === "species" ? s.label : null;
  return {
    文件: p.file, 路径: p.path, 状态: p.state === "failed" ? t("results.v_failed") : p.state === "done" ? t("results.v_done") : t("results.row_unscanned"), 错误: p.error ?? "",
    星级: starLabel(p.stars), 理由: p.star_reason ?? "", 星级来源: p.star_auto ? t("results.v_manual") : p.stars === null ? "" : t("results.v_app"),
    算出的星级: p.star_auto ? starLabel(p.star_auto.stars) : "",
    中文名: l?.zh ?? "", 英文名: l?.en ?? "", 学名: l?.sci ?? (s ? named(s).sci : ""),
    按连拍组修正: r?.species_own && !r.species?.manual ? t("results.yes") : "", 鸟种来源: !r?.species ? "" : r.species.manual ? t("results.v_corrected") : r.species_own ? t("results.v_burst_fixed") : t("results.v_app"), 原识别: r?.species_own ? `${named(r.species_own).title} · ${named(r.species_own).sci} · ${pct(r.species_own.top5[0]?.p ?? 0)}` : "",
    识别结果: r ? nameOf(r) : "", 识别层级: s?.level ?? "", 把握: s?.label?.p ?? s?.top5[0]?.p ?? "",
    候选: s ? s.top5.map((c) => [c.zh, c.en, c.sci, pct(c.p)].filter(Boolean).join(" · ")).join(" / ") : "",
    在飞: r?.flying == null ? "" : r.flying ? t("results.yes") : t("results.no"), 在飞概率: r?.p_fly ?? "",
    鸟框: r && r.subject != null ? r.boxes[r.subject].box.join(" ") : "", 眼睛位置: r?.eye?.join(" ") ?? "", 对焦点: r?.focus?.join(" ") ?? "",
    眼睛: r?.eye_visible == null ? "" : r.eye_visible ? t("results.v_visible") : t("results.v_hidden"), 头部清晰度: r?.sharpness ?? "", 清晰度测量处: r?.sharpness_region ?? "",
    美学分: r?.aesthetic ?? "", 清楚的鸟: r?.clear == null ? "" : r.clear ? t("results.yes") : t("results.no"),
    可能的稀有记录: s?.check === "rare" ? t("results.yes") : "", 衍生文件: (p.variants ?? []).map((v) => v.split("/").pop()).join(" / "),
    稀有度: rarityText(r?.rarity?.label), 稀有度地区: r?.rarity?.region ?? "", IUCN: r?.rarity?.iucn ?? "", 连拍组: p.burst_group ?? "", 组内排名: p.burst_rank ?? "", 连拍组张数: p.burst_size ?? "",
    相机: e?.camera ?? "", 镜头: e?.lens ?? "", 焦距毫米: e?.focal_mm ?? "", 光圈: e?.aperture ?? "", 快门秒: e?.shutter ?? "", ISO: e?.iso ?? "",
    曝光补偿EV: e?.ev ?? "", 对焦模式: e?.focus_mode ?? "", 拍摄时间: e?.taken_at ?? "", 拍摄时间显示: e?.taken_at ? fmtTime(e.taken_at) : "",
    地区: r?.region.source === "photo" ? `GPS ${r.region.gps!.map((v) => v.toFixed(5)).join(", ")}` : r?.region.name ?? "",
    地区来源: r?.region.source === "photo" ? t("results.v_from_photo") : r?.region.source === "scan" ? t("results.v_from_scan") : "",
    修正用的位置: r?.region.prior ? `${r.region.prior.lat}, ${r.region.prior.lon}` : "",
    位置来源: r?.region.prior ? priorSrc(r.region.prior.source) : t("results.v_no_place"), 拍摄周: r?.region.prior?.week ?? "",
  };
}
function save(name: string, text: string, type: string) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([text], { type }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}
// the CSV's header row in the page's language; the JSON export keeps these keys as they are
const COL: Record<string, Key> = {
  "文件": "results.col_0",
  "路径": "results.col_1",
  "状态": "results.col_2",
  "错误": "results.col_3",
  "星级": "results.col_4",
  "理由": "results.col_5",
  "星级来源": "results.col_6",
  "算出的星级": "results.col_7",
  "中文名": "results.col_8",
  "英文名": "results.col_9",
  "学名": "results.col_10",
  "按连拍组修正": "results.col_11",
  "鸟种来源": "results.col_12",
  "原识别": "results.col_13",
  "识别结果": "results.col_14",
  "识别层级": "results.col_15",
  "把握": "results.col_16",
  "候选": "results.col_17",
  "在飞": "results.col_18",
  "在飞概率": "results.col_19",
  "鸟框": "results.col_20",
  "眼睛位置": "results.col_21",
  "对焦点": "results.col_22",
  "眼睛": "results.col_23",
  "头部清晰度": "results.col_24",
  "清晰度测量处": "results.col_25",
  "美学分": "results.col_26",
  "清楚的鸟": "results.col_27",
  "可能的稀有记录": "results.col_28",
  "衍生文件": "results.col_29",
  "稀有度": "results.col_30",
  "稀有度地区": "results.col_31",
  "连拍组": "results.col_32",
  "组内排名": "results.col_33",
  "连拍组张数": "results.col_34",
  "相机": "results.col_35",
  "镜头": "results.col_36",
  "焦距毫米": "results.col_37",
  "光圈": "results.col_38",
  "快门秒": "results.col_39",
  "曝光补偿EV": "results.col_40",
  "对焦模式": "results.col_41",
  "拍摄时间": "results.col_42",
  "拍摄时间显示": "results.col_43",
  "地区": "results.col_44",
  "地区来源": "results.col_45",
  "修正用的位置": "results.col_46",
  "位置来源": "results.col_47",
  "拍摄周": "results.col_48",
};
function csv(rows: ReturnType<typeof exportRow>[]): string {
  if (!rows.length) return "﻿";
  const keys = Object.keys(rows[0]) as (keyof (typeof rows)[0])[];
  const q = (v: unknown) => {
    // text that a spreadsheet would run as a formula gets a leading apostrophe (numbers stay numbers); JSON keeps the original
    let t = String(v ?? "");
    if (typeof v === "string" && /^[=+\-@\t\r]/.test(t)) t = "'" + t;
    return /[",\r\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
  };
  return "﻿" + [keys.map((k) => (COL[k] ? t(COL[k]) : k)).join(","), ...rows.map((o) => keys.map((k) => q(o[k])).join(","))].join("\n");
}

// ---------- the view ----------
/** A previous result the person opened on purpose is not switched away from automatically (this browser tab only). */
function keepOld(id: number, set = false): boolean {
  try {
    if (set) sessionStorage.setItem(`birdcm.keep.${id}`, "1");
    return sessionStorage.getItem(`birdcm.keep.${id}`) === "1";
  } catch { return set; }
}

interface Related { newer: { id: number; state: Scan["state"]; counts: Scan["counts"] } | null; previous: number | null; stale: boolean; cursor?: number }

export default function Results({ scanId, onBack, onOpen, catalogue, brand, nav }: {
  scanId: number; onBack: () => void; onOpen: (id: number) => void; catalogue: Country[]; brand: ReactNode; nav: ReactNode }) {
  const [changesOff, setChangesOff] = useState(() => { try { return localStorage.getItem(`birdcm.changesOff.${scanId}`) === "1"; } catch { return false; } });
  const [changesOpen, setChangesOpen] = useState(false);
  const engine = useEngine()?.engine;
  const [scan, setScan] = useState<Scan | null>(null);
  const [raw, setPhotos] = useState<PhotoRow[]>([]);
  // what the page shows: a burst's majority species replaces a frame's own (kept as species_own) when stars.py says so
  const photos = useMemo(() => raw.map(withFix), [raw]);
  const [error, setError] = useState("");
  const index = useRef(new Map<number, number>());
  const lastN = useRef(0);          // newest event seen (dedupe)
  const completeRef = useRef(false);
  const snapN = useRef(-1);         // cursor of the snapshot on screen: events at or below it are already in it
  const pending = useRef<{ rows: Map<number, { n: number; row: PhotoRow }>; scan: { n: number; data: Partial<Scan> } | null }>({ rows: new Map(), scan: null });
  const flushTimer = useRef<number | null>(null);

  const load = useCallback(async () => {
    const s = await get<Snapshot>(`/api/scans/${scanId}`);
    if (s.cursor < snapN.current) return s;                   // an older snapshot answered late: keep the newer one
    snapN.current = s.cursor;
    pending.current.rows.forEach((v, id) => { if (v.n <= s.cursor) pending.current.rows.delete(id); });
    if (pending.current.scan && pending.current.scan.n <= s.cursor) pending.current.scan = null;
    index.current = new Map(s.photos.map((p, i) => [p.id, i]));
    lastN.current = Math.max(lastN.current, s.cursor);
    setScan(s.scan);
    setPhotos(s.photos);
    return s;
  }, [scanId]);

  // snapshot, then the event stream from its cursor; events within 150 ms are applied together
  useEffect(() => {
    let es: EventSource | null = null, dead = false;
    const flush = () => {
      flushTimer.current = null;
      const { rows, scan: sc } = pending.current;
      pending.current = { rows: new Map(), scan: null };
      const live = [...rows.values()].filter((v) => v.n > snapN.current).sort((a, b) => a.n - b.n);
      if (live.length) setPhotos((old) => { const next = old.slice(); live.forEach(({ row }) => { const i = index.current.get(row.id); if (i !== undefined) next[i] = { ...next[i], ...row }; }); return next; });
      if (sc && sc.n > snapN.current) setScan((old) => (old ? { ...old, ...sc.data } : old));
    };
    const later = () => { flushTimer.current ??= window.setTimeout(flush, 150); };
    // "stars" and "completed" arrive together at the end of a scan: one snapshot for both (Codex P2)
    let reloadTimer: number | null = null;
    const reload = () => { reloadTimer ??= window.setTimeout(() => { reloadTimer = null; load(); }, 120); };
    const fresh = (ev: MessageEvent) => { const n = Number(ev.lastEventId); if (n <= lastN.current) return false; lastN.current = n; return true; };
    load().then((s) => {
      if (dead || s.scan.state === "completed") return;
      es = new EventSource(`/api/scans/${scanId}/events?after=${s.cursor}&lang=${getLang()}`);
      es.addEventListener("photo", (ev) => { if (!fresh(ev)) return; const r = JSON.parse(ev.data) as PhotoRow; pending.current.rows.set(r.id, { n: Number(ev.lastEventId), row: r }); later(); });
      es.addEventListener("scan", (ev) => {
        if (!fresh(ev)) return;
        const d = JSON.parse(ev.data);
        pending.current.scan = { n: Number(ev.lastEventId), data: { state: d.state, error: d.error, counts: d.counts } };
        later();
        if (d.state === "completed") { es?.close(); reload(); }
      });
      es.addEventListener("stars", (ev) => { if (fresh(ev)) reload(); });
    }).catch((e) => setError(String(e.message)));
    return () => { dead = true; es?.close(); if (flushTimer.current) clearTimeout(flushTimer.current); };
  }, [scanId, load]);

  // a newer scan of this folder (re-scan): poll lightly, banner at once, switch when the person is not busy here
  const [rel, setRel] = useState<Related>({ newer: null, previous: null, stale: false });
  const lastTouch = useRef(Date.now());
  useEffect(() => {
    const touch = () => { lastTouch.current = Date.now(); };
    window.addEventListener("pointerdown", touch);
    window.addEventListener("keydown", touch);
    let dead = false;
    const poll = () => get<Related>(`/api/scans/${scanId}/related`).then((r) => {
      if (dead) return;
      setRel(r);
      // settings or stars changed elsewhere (another tab) after this page finished listening: reload (Codex I1)
      if (r.cursor != null && snapN.current >= 0 && r.cursor > lastN.current && completeRef.current) load();
      // switch to a re-scan only once it has finished: a failed or paused one is no place to land (Codex I9)
      if (r.newer?.state === "completed" && Date.now() - lastTouch.current > 6000 && !document.querySelector("dialog[open]") && !keepOld(scanId)) onOpen(r.newer.id);
    }).catch(() => {});
    poll();
    const t = window.setInterval(poll, 3000);
    return () => { dead = true; clearInterval(t); window.removeEventListener("pointerdown", touch); window.removeEventListener("keydown", touch); };
  }, [scanId, onOpen]);

  // what changed against the previous scan of this folder (shown once this one is complete)
  const [prevRows, setPrevRows] = useState<Map<string, PhotoRow> | null>(null);
  useEffect(() => {
    if (!rel.previous || scan?.state !== "completed") return;
    get<Snapshot>(`/api/scans/${rel.previous}`).then((s) => setPrevRows(new Map(s.photos.map((p) => [p.path, withFix(p)])))).catch(() => {});
  }, [rel.previous, scan?.state]);
  const [onlyIds, setOnlyIds] = useState<{ ids: Set<number>; label: string } | null>(null);
  const [rescanOpen, setRescanOpen] = useState(false);

  const phase: Phase = scan?.state === "completed" ? "complete" : scan && ["paused", "failed"].includes(scan.state) ? "paused" : "scanning";
  const complete = phase === "complete";
  completeRef.current = complete;
  const starsReady = complete && photos.some((p) => p.stars !== null);   // also true for a batch that is all 淘汰
  // one stable handler for every row (Codex P3: rows are memoised and only re-render when their own data changes)
  const tileAct = useRef<TileAct>(null as unknown as TileAct);
  tileAct.current = {
    pick: (id, mode) => {
      // Cmd / Ctrl toggles, Shift adds the run from the anchor (look.ts select); a plain click picks one
      const r = select(picked, anchor.current ?? current?.id ?? null, id, view.map((p) => p.id), mode);
      setPicked(r.set); anchor.current = r.anchor; setSelected(id);
      if (mode !== "plain") return;
      if (matchMedia("(max-width: 720px)").matches) panelRef.current?.scrollIntoView({ block: "start" }); },
    open: (id) => { setSelected(id); setPicked(new Set()); viewerRef.current?.showModal(); },
    group: (p) => { setSelected(p.id); anchor.current = null; setGroupOnly(p.burst_group); },
    ref: (id, el) => { if (el) tiles.current.set(id, el); else tiles.current.delete(id); },
  };
  const rowState = (p: PhotoRow): RowState => (p.state === "done" ? "ready" : p.state === "failed" ? "failed"
    : p.state === "queued" && phase === "paused" ? "unscanned" : p.state);

  // filters
  const [fs, setFs] = useState("all");
  const [fsp, setFsp] = useState("");
  const [allChips, setAllChips] = useState(false);
  // look-alike flips: the corrected frames and the burst-mates they were corrected to (the whole group is the question)
  const lookIds = useMemo(() => {
    const groups = new Set(photos.filter((p) => p.result?.species?.lookalike || p.result?.species?.closer).map((p) => p.burst_group));
    return new Set(photos.filter((p) => groups.has(p.burst_group) && p.result && !p.result.rejected).map((p) => p.id));
  }, [photos]);
  const rareIds = useMemo(() => new Set(photos.filter((p) => p.result?.species?.check === "rare" && !p.result.rejected).map((p) => p.id)), [photos]);
  const [ffly, setFfly] = useState("all");
  const [frar, setFrar] = useState("0");
  const [sort, setSort] = useState("queue");
  const [marks, setMarks] = useMarks();
  const [selected, setSelected] = useState<number | null>(null);
  // multi-select: the grid's picked set (empty = just the current photo); `selected` stays the current / anchor one
  const [picked, setPicked] = useState<Set<number>>(() => new Set());
  const anchor = useRef<number | null>(null);
  const [cmp, setCmp] = useState<number | null>(null);         // compare the current photo with this one
  const sortTouched = useRef(false);
  useEffect(() => { if (starsReady && !sortTouched.current) setSort("star"); }, [starsReady]);

  const species = useMemo(() => {
    const m = new Map<string, string>();
    let unsure = false;
    for (const p of photos) {
      const l = p.result?.species?.label;
      if (confirmed(p.result) && l) m.set(speciesKey(p.result), l.zh ? `${l.zh} ${l.en ?? ""}` : l.en ?? l.sci);
      else if (p.result && !p.result.rejected) unsure = true;
    }
    return { list: [...m].sort((a, b) => a[1].localeCompare(b[1], "zh-CN")), unsure };
  }, [photos]);
  const manualIds = useMemo(() => new Set(photos.filter((p) => p.result?.species?.manual).map((p) => p.id)), [photos]);
  const inScan = useMemo(() => species.list.map(([sci, name]) => ({ sci, zh: name.split(" ")[0], en: name.split(" ").slice(1).join(" ") || null })), [species]);
  // the person's word: sci = species, null = 不确定, undefined = undo; stars are re-rated on the server
  const correct = useCallback(async (id: number, sci: string | null | undefined, scope: Scope) => {
    await post(`/api/scans/${scanId}/corrections`, sci === undefined ? { photo_id: id, scope, undo: true } : { photo_id: id, scope, sci });
    await load();
  }, [scanId, load]);
  // the same for exactly these photos (the grid's selection), one request
  const correctMany = async (ids: number[], sci: string | null | undefined) => {
    await post(`/api/scans/${scanId}/corrections`, sci === undefined ? { photo_ids: ids, undo: true } : { photo_ids: ids, sci });
    await load();
  };
  const [batchFix, setBatchFix] = useState(false);

  // the person's stars for these photos (null: back to the computed ones); one request however many
  const setStars = useCallback(async (ids: number[], s: number | null) => {
    try { await post(`/api/scans/${scanId}/stars`, { photo_ids: ids, stars: s }); await load(); }
    catch (e) { setError(String((e as Error).message)); }
  }, [scanId, load]);
  // stars from the grid, the panel or the viewer: the current photo stays picked; when the star filter or sort
  // takes it out of the list, the photo now at its place is (the next one), so the arrow keys keep working
  const follow = useRef<{ id: number; at: number } | null>(null);
  const [followN, setFollowN] = useState(0);
  const starsFollow = (ids: number[], s: number | null) => {
    if (current) follow.current = { id: current.id, at: view.findIndex((p) => p.id === current.id) };
    setStars(ids, s).then(() => setFollowN((n) => n + 1));
  };
  useEffect(() => {
    const f = follow.current;
    if (!f) return;
    follow.current = null;
    const next = view.some((p) => p.id === f.id) ? f.id : f.at >= 0 ? view[Math.min(f.at, view.length - 1)]?.id : undefined;
    if (next === undefined) return;
    setSelected(next);
    anchor.current = null;
    if (!viewerRef.current?.open) requestAnimationFrame(() => tiles.current.get(next)?.focus({ preventScroll: true }));
  }, [followN]);                     // once per answered request, on the view it produced
  // keys on the selected photo (or every picked one): 0-3 stars, X 淘汰, U back to the computed stars (Lightroom's)
  const starKey = (e: KeyboardEvent): boolean => {
    const s = starOf(e);
    if (!complete || !current?.result || s === undefined) return false;
    e.preventDefault();
    starsFollow(many ? pickedIds : [current.id], s);
    return true;
  };

  // "只看这一组": the list shows one burst, whatever the other filters say (they are kept, and come back on clearing)
  const [groupOnly, setGroupOnly] = useState<number | null>(null);
  const [fold, setFold] = useState(false);              // 连拍折叠: one row per burst, its best frame
  const view = useMemo(() => listView(photos, { fs, fsp, ffly, frar, sort, starsReady, fold, groupOnly, onlyIds: onlyIds?.ids ?? null }),
    [photos, fs, fsp, ffly, frar, sort, starsReady, groupOnly, onlyIds, fold]);

  // a photo picked from the burst strip may be outside the filtered list: it is still the one shown
  const current = view.find((p) => p.id === selected) ?? (selected !== null ? photos.find((p) => p.id === selected) : undefined) ?? view[0] ?? null;
  const tiles = useRef(new Map<number, HTMLButtonElement>());
  // the picked photos still in the list (a filter change does not let a batch reach photos out of sight) that have a
  // result (like the single-photo keys: no stars or species for a failed or unscanned photo)
  const pickedIds = view.filter((p) => picked.has(p.id) && p.result).map((p) => p.id);
  const many = pickedIds.length > 1;
  const burst = useMemo(() => {
    if (!current?.burst_group || (current.burst_size ?? 1) < 2) return null;
    const members = photos.filter((p) => p.burst_group === current.burst_group);
    const byTime = [...members].sort((a, b) => (a.result?.exif.taken_at ?? "").localeCompare(b.result?.exif.taken_at ?? "") || a.seq - b.seq);
    return { members: [...members].sort((a, b) => (a.burst_rank ?? 99) - (b.burst_rank ?? 99)), order: new Map(byTime.map((p, i) => [p.id, i + 1])) };
  }, [photos, current?.burst_group, current?.burst_size]);
  // compare: the other photo, ← → walking it through the burst (in shooting order) or else the list
  const cmpRow = cmp !== null && cmp !== current?.id ? photos.find((p) => p.id === cmp) ?? null : null;
  const pool = burst && cmpRow && cmpRow.burst_group === current?.burst_group ? [...burst.members].sort((x, y) => burst.order.get(x.id)! - burst.order.get(y.id)!) : view;
  const neighbour = burst && current ? (() => {           // the frame shot just after this one, else just before
    const n = burst.order.get(current.id)!, m = burst.members;
    return (m.find((x) => burst.order.get(x.id) === n + 1) ?? m.find((x) => burst.order.get(x.id) === n - 1))?.id ?? null;
  })() : null;
  const pick = (id: number) => {
    setSelected(id);
    anchor.current = null;
    requestAnimationFrame(() => tiles.current.get(id)?.scrollIntoView({ block: "nearest" }));
  };

  // on-demand shooting info for a selected photo that has not been processed yet
  const [exifs, setExifs] = useState<Record<number, Exif>>({});
  useEffect(() => {
    if (!current || current.result || exifs[current.id]) return;
    get<Exif>(`/api/photos/${current.id}/exif`).then((e) => setExifs((x) => ({ ...x, [current.id]: e }))).catch(() => {});
  }, [current, exifs]);

  // dialogs: export, and a plain large-photo viewer (Enter / double-click / click on the panel photo)
  const viewerRef = useRef<HTMLDialogElement>(null);
  const exportRef = useRef<HTMLDialogElement>(null);
  const panelRef = useRef<HTMLElement>(null);
  const [exportOpen, setExportOpen] = useState(false);       // the dialog's choices are fresh each time it opens
  const openViewer = () => { if (current && !viewerRef.current?.open) viewerRef.current?.showModal(); };
  const step = (d: number) => {
    const i = view.findIndex((p) => p.id === current?.id);
    const p = view[Math.max(0, Math.min(view.length - 1, i + d))];        // down onto a short last row: its last card
    if (!p || p.id === current?.id) return;
    setSelected(p.id);
    setPicked(new Set());
    anchor.current = null;
    tiles.current.get(p.id)?.focus({ preventScroll: viewerRef.current?.open });
  };

  const act = async () => {
    if (!scan) return;
    try {
      const r = await post<{ state: Scan["state"] }>(`/api/scans/${scanId}/${phase === "paused" ? "resume" : "stop"}`);
      setScan((s) => (s ? { ...s, state: r.state } : s));
    } catch (e) { setError(String((e as Error).message)); }
  };

  const chipsN = Math.max(0, CHIPS - (rareIds.size > 0 ? 1 : 0) - (lookIds.size > 0 ? 1 : 0) - (manualIds.size > 0 ? 1 : 0));   // one row at 1440 px
  if (error && !scan) return <p className="error-text">{error}</p>;
  if (!scan) return <p className="hint">{t("results.loading")}</p>;
  // counts come from the rows on screen: scan events only arrive on state changes, photo events on every result
  const c = { total: photos.length, done: photos.filter((p) => p.state === "done").length, failed: photos.filter((p) => p.state === "failed").length };
  const finished = c.done + c.failed;
  const rejected = photos.filter((p) => (starsReady ? p.stars === -1 : p.result?.rejected)).length;   // hand 淘汰 counts
  const eligibleN = photos.filter((p) => p.result && !p.result.rejected).length;
  const starredPct = eligibleN ? Math.round((100 * photos.filter((p) => (p.stars ?? 0) > 0).length) / eligibleN) : 0;
  const keepSet = keepOf(scan.ratio as { preset?: string; keep?: number });
  const keptN = photos.filter((p) => (p.stars ?? 0) > 0).length;
  const floorN = photos.filter((p) => (p.stars ?? 0) > 0 && p.quality?.parts?.floor).length;
  // notable species: locally 少见 / 罕见 this month, or threatened worldwide (IUCN NT and worse)
  const notableMap = new Map<string, { sci: string; name: string; tag: string; why: string }>();
  for (const p of photos) {
    const r = p.result, l = r?.species?.label;
    if (!r || r.rejected || r.species?.level !== "species" || !l) continue;
    const tier = r.rarity?.tier, iucn = r.rarity?.iucn;
    const tags = [tier === 1 || tier === 0 ? t("rarity.rare") : tier === 2 ? t("rarity.scarce") : "", iucn && ["NT", "VU", "EN", "CR"].includes(iucn) ? iucnText(iucn) : ""].filter(Boolean);
    if (tags.length) notableMap.set(l.sci, { sci: l.sci, name: l.zh || l.en || l.sci, tag: tags.join("·"), why: t("results.notable_why", { sci: l.sci, tags: tags.join(t("results.comma")) }) });
  }
  const notable = [...notableMap.values()];
  const rare = new Map<string, string>();
  for (const p of photos) {
    const tier = p.result?.rarity?.tier, l = p.result?.species?.label;
    if (tier != null && tier > 0 && tier <= 2 && l && !p.result!.rejected) rare.set(l.sci, t("results.rare_name", { name: l.zh || l.en || l.sci, label: rarityText(p.result!.rarity!.label) }));
  }
  const rareNames = [...rare.values()].join(t("results.list_sep"));
  const stepText = complete ? "" : scan.state === "failed" ? ` · ${scan.error ?? ""}` : " · " + t(phase === "paused" ? "results.step_paused"
    : scan.state === "stopping" ? "results.step_stopping" : scan.state === "queued" ? (engine === "loading" ? "results.step_wait_models" : engine === "error" ? "results.step_model_error" : "results.step_wait_scan") : scan.state === "finalizing" ? "results.step_bursts" : "results.step_running");
  const days = photos.map((p) => p.result?.exif.taken_at?.slice(0, 10)).filter(Boolean).sort() as string[];
  const dateRange = days.length ? (days[0] === days[days.length - 1] ? days[0] : `${days[0]} – ${days[days.length - 1].slice(5)}`) : "";
  const folderName = scan.folder.split("/").filter(Boolean).pop() ?? scan.folder;
  const state = complete ? t("results.n_photos", { n: c.total }) + (c.failed ? t("results.n_failed", { n: c.failed }) : "")
    : `${t(phase === "paused" ? (scan.state === "failed" ? "results.st_failed" : "results.st_paused") : scan.state === "stopping" ? "results.st_stopping" : scan.state === "finalizing" ? "results.st_finalizing" : scan.state === "queued" ? (engine === "loading" ? "results.wait_models" : engine === "error" ? "results.model_error_wait" : "results.st_queued") : "results.st_running")} ${finished} / ${c.total}`;

  const key = (p: PhotoRow) => { const r = p.result, sp = r?.species; return !r || r.rejected || !sp ? "x" : `${sp.level}:${sp.label?.sci ?? ""}`; };
  const changes = complete && prevRows ? (() => {
    const changed: number[] = [], vague: number[] = [], fixed: number[] = [];
    for (const p of photos) {
      const old = prevRows.get(p.path);
      if (old && key(old) !== key(p)) {
        changed.push(p.id);
        if (p.result?.species && p.result.species.level !== "species" && !p.result.rejected) vague.push(p.id);
      }
      if (p.species_fix) fixed.push(p.id);
    }
    return { changed, vague, fixed };
  })() : null;

  return (
    <section id="s-res" data-phase={phase} aria-labelledby="h-res">
      <header className="masthead resbar">
        <div className="masthead-inner">
          {brand}
          <p className="scan-id" title={`${scan.folder}${scan.recursive ? t("results.with_sub") : ""}${stepText}`}>
            <button type="button" className="scan-folder" title={t("results.copy_path", { folder: scan.folder })} onClick={() => navigator.clipboard?.writeText(scan.folder).catch(() => {})}>{folderName}</button>
            <span className="scan-meta"> · <PlaceOf loc={scan.region} />{dateRange ? ` · ${dateRange}` : ""} · </span>
            <span id="scan-copy" role="status">{state}</span>
          </p>
          {!complete && scan.state !== "finalizing" && scan.state !== "queued" && (
            <button type="button" className="btn slim" onClick={act} disabled={scan.state === "stopping"}>{phase === "paused" ? t("results.resume") : t("results.stop")}</button>
          )}
          {changes && !changesOff && (
            <span className="keep-pop">
              <span className="changes-chip"><button type="button" aria-expanded={changesOpen} onClick={() => setChangesOpen(!changesOpen)}>{t("results.changes_chip", { n: changes.changed.length })}</button>
                <button type="button" aria-label={t("results.changes_off")} onClick={() => { setChangesOff(true); try { localStorage.setItem(`birdcm.changesOff.${scanId}`, "1"); } catch { /* not remembered */ } }}>×</button></span>
              {changesOpen && (
                <div className="keep-menu changes-menu" role="dialog" aria-label={t("results.changes_menu")}>
                  <button type="button" onClick={() => { setChangesOpen(false); setOnlyIds({ ids: new Set(changes.changed), label: t("results.only_changed") }); }}>{t("results.changed_n", { n: changes.changed.length })}</button>
                  <button type="button" onClick={() => { setChangesOpen(false); setOnlyIds({ ids: new Set(changes.vague), label: t("results.only_vague") }); }}>{t("results.vague_n", { n: changes.vague.length })}</button>
                  <button type="button" onClick={() => { setChangesOpen(false); setOnlyIds({ ids: new Set(changes.fixed), label: t("results.only_fixed") }); }}>{t("results.fixed_n", { n: changes.fixed.length })}</button>
                  <button type="button" onClick={() => { keepOld(rel.previous!, true); onOpen(rel.previous!); }}>{t("results.open_previous")}</button>
                </div>
              )}
            </span>
          )}
          <div className="res-actions">
            <button className="btn slim" onClick={() => setRescanOpen(true)}>{t("results.rescan")}</button>
            <button className="btn slim primary" disabled={!complete} onClick={() => { setExportOpen(true); exportRef.current?.showModal(); }}>{t("results.export")}</button>
            <button className="btn slim link" onClick={onBack}>{t("results.new_batch")}</button>
            {nav}
          </div>
        </div>
        {!complete && <progress className="bar-progress" value={finished} max={c.total || 1} aria-label={t("results.progress")} />}
      </header>
      {scan.state === "failed" && <p className="warn-strip stale" role="alert">{t("results.scan_failed")}{scan.error ?? t("results.no_reason")}</p>}
      {rel.newer ? (
        <p className="warn-strip" role="status">
          {rel.newer.state === "completed" ? t("results.newer_done")
            : rel.newer.state === "failed" ? t("results.newer_failed")
            : t(rel.newer.state === "paused" ? "results.newer_paused" : "results.newer_running", { done: rel.newer.counts.done + rel.newer.counts.failed, total: rel.newer.counts.total })}
          {" · "}<button className="btn link" onClick={() => onOpen(rel.newer!.id)}>{rel.newer.state === "completed" ? t("results.see_new") : t("results.see_rescan")}</button>
          {rel.newer.state === "completed" && !keepOld(scanId) && <span className="hint">{t("results.auto_switch")}</span>}
        </p>
      ) : rel.stale && (
        <p className="warn-strip stale">{t("results.stale")}<button className="btn link" onClick={() => setRescanOpen(true)}>{t("results.rescan")}</button></p>
      )}
      <h2 id="h-res" tabIndex={-1} className="sr-only">{t("results.heading")}</h2>
      {rescanOpen && <Rescan scan={scan} catalogue={catalogue} onClose={() => setRescanOpen(false)} onStarted={(id) => { setRescanOpen(false); onOpen(id); }} />}
      {complete && (scan.ratio as { strategy?: string })?.strategy !== "quota" ? (
        <div className="cull" aria-label={t("results.batch_result")}>
          <div className="cull-keep">
            <b className="cull-big">{t("results.kept", { n: keptN, pct: starredPct })}</b>
            <KeepButton value={keepSet} onChange={(v) => put(`/api/scans/${scanId}/ratio`, { ...v }).then(() => load()).catch((e) => setError(String(e.message)))} />
            {floorN > 0 && <small title={t("results.floor_title")}>{t("results.floor_n", { n: floorN })}</small>}
          </div>
          <div className="cull-stars">
            {[3, 2, 1].map((n) => (
              <button key={n} type="button" className={`cull-chip${fs === String(n) ? " on" : ""}`} onClick={() => setFs(fs === String(n) ? "all" : String(n))}>
                <span className="stars">{"★".repeat(n)}</span> {photos.filter((p) => p.stars === n).length}</button>
            ))}
          </div>
          <div className="cull-drop" title={t("results.drop_title", { zero: photos.filter((p) => p.stars === 0).length, rejected })}>
            <button type="button" className={`cull-chip${fs === "drop" ? " on" : ""}`} onClick={() => setFs(fs === "drop" ? "all" : "drop")}>{t("results.drop_n", { n: c.total - keptN })}</button>
            <small>{t("results.drop_small", { zero: photos.filter((p) => p.stars === 0).length, rejected })}</small>
          </div>
          <div className="cull-species">
            <b>{t("results.n_species", { n: species.list.length })}</b>
            {rareIds.size > 0 && (
              <button type="button" className="cull-chip rare" title={t("results.rare_title")}
                onClick={() => setOnlyIds({ ids: rareIds, label: t("results.only_rare") })}>{t("results.rare_chip", { n: rareIds.size })}</button>
            )}
            {manualIds.size > 0 && (
              <button type="button" className="cull-chip" onClick={() => setOnlyIds({ ids: manualIds, label: t("results.only_manual") })}>{t("results.manual_chip", { n: manualIds.size })}</button>
            )}
            {lookIds.size > 0 && (
              <button type="button" className="cull-chip rare" title={t("results.look_title")}
                onClick={() => setOnlyIds({ ids: lookIds, label: t("results.only_look") })}>{t("results.look_chip", { n: lookIds.size })}</button>
            )}
            {(allChips ? notable : notable.slice(0, chipsN)).map((n) => (
              <button key={n.sci} type="button" className={`cull-chip rare${fsp === n.sci ? " on" : ""}`} title={n.why} onClick={() => setFsp(fsp === n.sci ? "" : n.sci)}>{n.name}<small>{n.tag}</small></button>
            ))}
            {notable.length > chipsN && (
              <button type="button" className="cull-chip" aria-expanded={allChips} onClick={() => setAllChips(!allChips)}>{allChips ? t("results.collapse") : `+${notable.length - chipsN}`}</button>
            )}
          </div>
        </div>
      ) : (
      <div className="summary" data-complete={complete}>
        {complete ? (
          <>
            <div><b>{c.total}</b><small>{t("results.sum_photos")}</small></div>
            {[3, 2, 1, 0].map((s) => (
              <div key={s}><b>{starsReady ? photos.filter((p) => p.stars === s).length : "—"}</b>
                <small className="stars" aria-label={t("results.n_stars", { n: s })}>{s ? "★".repeat(s) : t("viewer.zero")}{!starsReady && t("results.sum_pending")}</small></div>
            ))}
            <div><b>{rejected}</b><small>{t("viewer.reject")}</small></div>
          </>
        ) : <div><b>{finished} / {c.total}</b><small>{t("results.sum_scanned")}</small></div>}
        <div><b>{species.list.length}</b><small>{t("results.sum_species")}</small></div>
        <div><b className="rare-name">{rareNames || (complete ? t("results.none") : t("results.none_yet"))}</b>
          <small title={rarityNote()}>{t("results.sum_rare")}</small></div>
      </div>
      )}

      <div className="filters" role="group" aria-label={t("results.filters")}>
        <div className="seg" role="radiogroup" aria-label={t("results.f_stars")} aria-disabled={!starsReady}>
          {([["all", "results.f_all"], ["3", "results.f_3"], ["2", "results.f_2"], ["1", "results.f_1"], ["0", "viewer.zero"], ["-1", "viewer.reject"]] as [string, Key][]).map(([v, l]) => (
            <label key={v}><input type="radio" name="fs" value={v} checked={fs === v} disabled={!starsReady} onChange={() => setFs(v)} /><span>{t(l)}</span></label>
          ))}
        </div>
        <select aria-label={t("results.f_species")} value={fsp} onChange={(e) => setFsp(e.target.value)}>
          <option value="">{t("results.f_all_species")}</option>
          {species.list.map(([k, n]) => <option key={k} value={k}>{n}</option>)}
          {species.unsure && <option value="unsure">{t("results.f_unsure")}</option>}
        </select>
        <select aria-label={t("results.f_rarity")} value={frar} onChange={(e) => setFrar(e.target.value)} title={rarityNote()}>
          <option value="0">{t("results.f_all_rarity")}</option><option value="3">{t("results.f_uncommon_up")}</option><option value="2">{t("results.f_scarce_up")}</option><option value="1">{t("rarity.rare")}</option>
        </select>
        <select aria-label={t("results.f_fly")} value={ffly} onChange={(e) => setFfly(e.target.value)}>
          <option value="all">{t("results.f_all_poses")}</option><option value="fly">{t("results.flying")}</option><option value="still">{t("results.not_flying")}</option>
        </select>
        <label className="inline"><input type="checkbox" checked={fold} onChange={(e) => setFold(e.target.checked)} disabled={!complete} /> {t("results.fold")}</label>
        <label className="inline">{t("results.sort")}
          <select value={sort} onChange={(e) => { sortTouched.current = true; setSort(e.target.value); }}>
            <option value="queue">{t("results.sort_queue")}</option>
            <option value="star" disabled={!starsReady}>{t("results.sort_star")}</option>
            <option value="time">{t("results.sort_time")}</option>
            <option value="species">{t("results.sort_species")}</option>
            <option value="fly">{t("results.sort_fly")}</option>
            <option value="rar">{t("results.sort_rar")}</option>
            <option value="eye">{t("results.sort_eye")}</option>
          </select>
        </label>
        {onlyIds && (
          <span className="chip">{t("results.only_chip", { label: onlyIds.label, n: onlyIds.ids.size })}<button type="button" aria-label={t("results.clear_filter")} onClick={() => setOnlyIds(null)}>×</button></span>
        )}
        {groupOnly !== null && (
          <span className="chip">{t("results.only_burst", { n: groupOnly })}<button type="button" aria-label={t("results.clear_burst")} onClick={() => {
            setGroupOnly(null);
            if (current) requestAnimationFrame(() => tiles.current.get(current.id)?.scrollIntoView({ block: "center" }));
          }}>×</button></span>
        )}
        {!starsReady && <p className="hint">{t("results.stars_wait")}</p>}
      </div>

      <div className="inspection">
        <section className="list" aria-labelledby="list-title" onKeyDown={(e) => { if (e.key === "Escape" && picked.size) { e.preventDefault(); setPicked(new Set()); setBatchFix(false); } }}>
          <div className="list-head"><h3 id="list-title">{t("results.list")}</h3><span aria-live="polite">{t("results.showing", { n: view.length, total: c.total })}</span></div>
          <p className="sr-only" id="photo-keys">{t("results.keys")}</p>
          {many && (
            <div className="batch" role="toolbar" aria-label={t("results.batch_ops")}>
              <b>{t("results.picked", { n: pickedIds.length })}</b>
              {complete && <StarSet on={null} undo onStars={(v) => starsFollow(pickedIds, v)} label={t("results.set_picked_stars")} />}
              {complete && <button type="button" className="btn slim" aria-expanded={batchFix} onClick={() => setBatchFix(!batchFix)}>{t("results.fix_species")}</button>}
              {pickedIds.length === 2 && <button type="button" className="btn slim" onClick={() => { setSelected(pickedIds[0]); setCmp(pickedIds[1]); viewerRef.current?.showModal(); }}>{t("results.compare")}</button>}
              <button type="button" className="btn slim link" onClick={() => { setPicked(new Set()); setBatchFix(false); }}>{t("results.clear_selection")}</button>
              {batchFix && <CorrectPanel own={[]} inScan={inScan} current={null} burst={false} count={pickedIds.length}
                manual={pickedIds.some((id) => manualIds.has(id))} onClose={() => setBatchFix(false)}
                onApply={(sci) => correctMany(pickedIds, sci)} onUndo={() => correctMany(pickedIds, undefined)} />}
            </div>
          )}
          <div id="grid" onKeyDown={(e) => {
            if (e.key === "Enter") { e.preventDefault(); openViewer(); return; }
            if (starKey(e)) return;
            // a grid of cards: left / right one photo, up / down one row (however many columns fit)
            const d = ({ ArrowLeft: -1, ArrowRight: 1, ArrowUp: -1, ArrowDown: 1 } as Record<string, number>)[e.key];
            if (!d) return;
            e.preventDefault();
            const row = e.key === "ArrowUp" || e.key === "ArrowDown";
            step(row ? d * getComputedStyle(e.currentTarget).gridTemplateColumns.split(" ").length : d);
          }}>
            {view.length ? view.map((p) => (
              <Tile key={p.id} p={p} st={rowState(p)} active={p.id === current?.id} picked={picked.has(p.id)} complete={complete} more={fold && groupOnly === null}
                marks={marks} exif={p.result?.exif ?? exifs[p.id]} act={tileAct} />
            )) : <p className="empty">{c.total ? t("results.empty") : t("results.empty_folder")}</p>}
          </div>
        </section>
        {current && <Inspector ref={panelRef} p={current} st={rowState(current)} marks={marks} setMarks={setMarks} complete={complete}
          inScan={inScan} onCorrect={correct} onStars={starsFollow}
          exif={current.result?.exif ?? exifs[current.id]} onOpen={openViewer} burst={burst} onPick={pick}
          groupOnly={groupOnly !== null} onGroupOnly={(on) => setGroupOnly(on ? current.burst_group : null)} />}
      </div>

      <Viewer ref={viewerRef} scanId={scanId} a={current} b={cmpRow} pool={pool} marks={marks} complete={complete}
        onStep={step} onStars={starsFollow} setStars={setStars} onCompare={setCmp} neighbour={neighbour} />

      <dialog ref={exportRef} aria-labelledby="e-title" style={{ maxWidth: 760 }} onClose={() => setExportOpen(false)}>
        <div className="dlg-head"><h3 id="e-title">{t("results.export")}</h3><button className="btn" onClick={() => exportRef.current?.close()}>{t("viewer.close")}</button></div>
        {exportOpen && <ExportDialog scanId={scanId} photos={photos} view={view} onClose={() => exportRef.current?.close()}
          saveTable={(rows, kind) => kind === "csv" ? save(t("results.export_name") + ".csv", csv(rows.map(exportRow)), "text/csv")
            : save(t("results.export_name") + ".json", JSON.stringify(rows.map(exportRow), null, 2), "application/json")} />}
        <p className="hint" style={{ margin: "0 16px 14px" }}>{t("results.export_hint")}</p>
      </dialog>
    </section>
  );
}

interface Burst { members: PhotoRow[]; order: Map<number, number> }

const Inspector = forwardRef<HTMLElement, { p: PhotoRow; st: RowState; marks: MarkSet; setMarks: (m: MarkSet) => void; complete: boolean;
  exif?: Exif; onOpen: () => void; burst: Burst | null; onPick: (id: number) => void; groupOnly: boolean; onGroupOnly: (on: boolean) => void;
  inScan: Pick[]; onCorrect: (id: number, sci: string | null | undefined, scope: Scope) => Promise<void>;
  onStars: (ids: number[], s: number | null) => void }>(
  function Inspector({ p, st, marks, setMarks, complete, exif, onOpen, burst, onPick, groupOnly, onGroupOnly, inScan, onCorrect, onStars }, ref) {
  const [correcting, setCorrecting] = useState(false);
  useEffect(() => setCorrecting(false), [p.id]);
  const r = p.result, ready = st === "ready" && !!r;
  const sp = r?.species, sure = confirmed(r), e = exif;
  const missing: Partial<Record<keyof MarkSet, string>> = r ? {
    eye: r.eye && r.eye_visible ? undefined : t("results.mk_none"), beak: r.beak && (r.beak_p ?? 0) >= 0.5 ? undefined : t("results.mk_none"),
    focus: r.focus ? undefined : t("rarity.unavailable"), box: r.boxes.length ? undefined : t("results.mk_none") } : {};
  const stars = <div className="panel-stars"><div className="verdict stars">{complete && p.stars !== null ? starTxt(p.stars) : t("viewer.pending_stars")}</div>
    {complete && p.star_reason && <p className="reason">{p.star_reason}</p>}
    {complete && p.star_auto && <p className="reason">{t("results.computed_as", { stars: starLabel(p.star_auto.stars) })}{p.star_auto.reason ? t("results.colon_reason", { r: p.star_auto.reason }) : ""}</p>}
    {complete && r && <StarSet on={p.star_auto ? p.stars : null} undo={!!p.star_auto} onStars={(v) => onStars([p.id], v)} />}</div>;
  return (
    <aside className="inspector" aria-label={t("results.inspector")} ref={ref}>
      {ready && <MarkControls m={marks} set={setMarks} missing={missing} />}
      <button className="preview-photo" type="button" aria-label={t("results.open_large")} onClick={onOpen}>
        <Photo row={p} marks={ready ? marks : null} big show alt={p.file} />
      </button>
      <div className="preview-info">
        {!ready ? (
          <>
            <h3>{previewLabel(st)}</h3>
            <p className="preview-note">{st === "failed" ? p.error : st === "unscanned" ? t("results.pv_unscanned") : t("results.pv_pending")}</p>
          </>
        ) : (
          <>
            {r!.rejected ? (
              <>
                {stars}
                <div className="sp-cn">{r!.reject_reason ?? t("look.no_bird")}</div>
                <p className="preview-note">{r!.boxes.length ? t("results.rej_boxes", { n: r!.boxes.length }) : t("results.rej_none")}</p>
                {sp && <><p className="conf-line">{t("results.rej_named")}</p><SpName sp={sp} /><Verdict sp={sp} />
                  <h4 className="panel-h">{t("results.top5")}</h4><Candidates sp={sp} /></>}
              </>
            ) : sp ? (
              <>
                {/* polish.md order: the name, local / IUCN status, the naming notes and match, the stars, then correcting */}
                <SpName sp={sp} size="hero" />
                {r!.rarity && <p className="facts-inline"><span title={rarityNote()}>{t("results.local")}<strong>{rarityText(r!.rarity.label)}</strong></span>
                  {r!.rarity.iucn && <span>{t("results.iucn_colon")}<strong>{iucnText(r!.rarity.iucn)} {r!.rarity.iucn}</strong></span>}</p>}
                <Verdict sp={sp} />
                {sp.manual && r!.species_own && (
                  <p className="fixed-note"><span className="tbd">{t("results.by_owner")}</span>{t("results.app_said")}{named(r!.species_own).title}
                    {r!.species_own.label && <> <i>{r!.species_own.label.sci}</i></>}</p>
                )}
                {!sp.manual && r!.species_own && (
                  <p className="fixed-note"><span className="tbd">{t("results.by_burst")}</span>{t("results.burst_support", { frames: sp.consensus?.frames ?? "", support: sp.consensus?.support ?? "" })}
                    {t("results.own_best")}{named({ ...r!.species_own, label: r!.species_own.top5[0], level: "species" }).title} <i>{r!.species_own.top5[0]?.sci}</i>{t("results.own_best_after", { p: pct(r!.species_own.top5[0]?.p ?? 0) })}</p>
                )}
                <p className="conf-line">{r!.species_own ? (sp.label?.p != null ? t("results.own_gives", { p: pct(sp.label.p) }) : t("results.own_not_top5"))
                  : t(sure ? "results.confidence" : "results.top_candidate", { p: pct((sure || sp.level === "genus" ? sp.label!.p : sp.top5[0].p) ?? 0) })} <span className="ref">· {!sp.geo ? t("results.no_place") : sp.prior?.unknown ? t("results.prior_unknown") : t("results.prior_used")}</span></p>
                {stars}
                {correcting ? <CorrectPanel own={sp.top5} inScan={inScan} current={sp.level !== "uncertain" ? sp.label?.sci ?? null : null}
                    burst={(p.burst_size ?? 1) > 1} manual={!!sp.manual} onClose={() => setCorrecting(false)}
                    onApply={(sci, scope) => onCorrect(p.id, sci, scope)} onUndo={(scope) => onCorrect(p.id, undefined, scope)} />
                  : complete && <button type="button" className="btn slim" onClick={() => setCorrecting(true)}>{t("correct.label")}</button>}
                <h4 className="panel-h">{r!.species_own ? t("results.own_top5") : t("results.top5")}</h4>
                <Candidates sp={sp} />
              </>
            ) : stars}
            <dl className="facts">
              <dt>{t("results.flying")}</dt><dd>{r!.flying == null ? "—" : r!.flying ? t("results.yes") : t("results.no")}{r!.p_fly != null && <span className="ref"> · P = {r!.p_fly.toFixed(2)}</span>}</dd>
              <dt>{t("results.q_eye")}</dt><dd>{r!.eye_visible == null ? "—" : r!.eye_visible ? t("results.v_visible") : t("results.v_hidden")}</dd>
              <dt>{t("results.head_sharp")}</dt><dd>{sharpTxt(r!.sharpness)}{r!.sharpness_region && <span className="ref">{t("results.sharp_where", { where: region(r!.sharpness_region) })}</span>}</dd>
              <dt>{t("results.aes")}</dt><dd>{r!.aesthetic != null ? r!.aesthetic.toFixed(2) : "—"} <span className="ref">{t("results.for_reference")}</span></dd>
              <dt>{t("results.local_rarity")}</dt><dd title={rarityNote()}>{r!.rarity ? <><b>{rarityText(r!.rarity.label)}</b>{r!.rarity.region && <span className="ref"> · {r!.rarity.region}</span>}{r!.rarity.note && <span className="ref">{t("results.paren", { x: rarityText(r!.rarity.note) })}</span>}</> : "—"}
                <span className="ref" style={{ display: "block" }}>{t("results.local_rarity_note")}</span></dd>
              <dt>{t("results.threat")}</dt><dd>{r!.rarity?.iucn ? <b>{t("results.iucn_line", { name: iucnText(r!.rarity.iucn), code: r!.rarity.iucn })}</b> : "—"}
                <span className="ref" style={{ display: "block" }}>{t("results.threat_note")}</span></dd>
              {p.quality && <><dt>{t("results.overall")}</dt><dd><b>{p.quality.q.toFixed(2)}</b>
                <span className="ref" style={{ display: "block" }}>{qParts(p.quality.parts)}</span></dd></>}
              {(p.variants?.length ?? 0) > 0 && <><dt>{t("results.variants")}</dt><dd>{p.variants!.map((v) => <div key={v}>{v.split("/").pop()}</div>)}
                <span className="ref" style={{ display: "block" }}>{t("results.variants_note")}</span></dd></>}
              <dt>{t("results.burst")}</dt><dd>{!p.burst_group ? t("results.burst_later") : p.burst_size === 1 ? t("results.burst_alone", { g: p.burst_group })
                : t("results.burst_rank", { g: p.burst_group, rank: p.burst_rank ?? "", size: p.burst_size ?? "" }) + (burst ? t("results.burst_order", { n: burst.order.get(p.id) ?? "" }) : "")}</dd>
              <dt>{t("results.boxes")}</dt><dd>{t("results.n_boxes", { n: r!.boxes.length })}{r!.boxes.length > 1 && r!.subject != null ? t(r!.focus ? "results.subject_focus" : "results.subject_conf") : ""}</dd>
            </dl>
            {burst && (
              <section className="burst" aria-label={t("results.burst_label", { g: p.burst_group ?? "" })}>
                <div className="burst-head"><h4 className="panel-h" style={{ border: 0, margin: 0, padding: 0 }}>{t("results.burst_head")}</h4>
                  <label className="inline"><input type="checkbox" checked={groupOnly} onChange={(e) => onGroupOnly(e.target.checked)} /> {t("results.only_group")}</label></div>
                <ol className="burst-strip">
                  {burst.members.map((m) => (
                    <li key={m.id}>
                      <button type="button" aria-pressed={m.id === p.id} onClick={() => onPick(m.id)}
                        aria-label={t("results.member_label", { rank: m.burst_rank ?? "", stars: m.stars !== null ? starLabel(m.stars) : t("viewer.pending_stars"), file: m.file })}>
                        <img src={`/api/photos/${m.id}/thumb?v=${m.size}-${m.mtime_ns}`} alt="" loading="lazy" decoding="async" />
                        <span className="burst-meta"><b>#{m.burst_rank}</b> <span className="stars">{m.stars !== null ? starTxt(m.stars) : t("viewer.pending")}</span></span>
                        <span className="burst-meta">{t("results.shot_n", { n: burst.order.get(m.id) ?? "" })}</span>
                      </button>
                    </li>
                  ))}
                </ol>
              </section>
            )}
          </>
        )}
        <h4 className="panel-h">{t("results.shooting")}</h4>
        <Settings e={e} />
        <dl className="facts">
          <dt>{t("results.camera")}</dt><dd>{e?.camera ?? "—"}</dd><dt>{t("results.lens")}</dt><dd>{e?.lens ?? "—"}</dd>
          <dt>{t("results.focus_mode")}</dt><dd>{e?.focus_mode ?? "—"}</dd><dt>{t("results.taken")}</dt><dd>{fmtTime(e?.taken_at)}</dd>
          {r && <><dt>{t("results.place")}</dt><dd>{r.region.source === "photo" ? <PlaceName lat={r.region.gps![0]} lon={r.region.gps![1]} />
            : r.region.prior && r.region.prior.source !== "region" ? <PlaceName lat={r.region.prior.lat} lon={r.region.prior.lon} />
            : r.region.name ? <PlaceName code={r.region.code} label={r.region.name} /> : "—"}{" "}
            <span className="ref">· {r.region.prior ? priorSrc(r.region.prior.source) + (r.region.prior.week ? t("results.week", { n: r.region.prior.week }) : t("results.all_year")) : t("results.no_place")}</span></dd></>}
          <dt>{t("results.file")}</dt><dd>{p.file}<span className="ref path"> {p.path}</span></dd>
        </dl>
      </div>
    </aside>
  );
});


/** 重新扫描: the same folder, with the location and ratio prefilled and changeable. */
function Rescan({ scan, catalogue, onClose, onStarted }: { scan: Scan; catalogue: Country[]; onClose: () => void; onStarted: (id: number) => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const start = typeof scan.region === "object" && scan.region ? scan.region
    : (() => { const label = scan.region as string | null; if (!label) return null;
      const [cz, sub] = label.split(" · "); const c = catalogue.find((x) => x.zh === cz); const r = c?.regions.find((x) => x.zh === sub);
      return c ? { lat: (r ?? c).lat, lon: (r ?? c).lon, label, source: "region" as const } : null; })();
  const [place, setPlace] = useState<Place | null>(start);
  const [keep, setKeep] = useState<KeepSetting>(keepOf(scan.ratio as { preset?: string; keep?: number }));
  const [err, setErr] = useState("");
  useEffect(() => { ref.current?.showModal(); }, []);
  const go = async () => {
    const ratio = keep;
    try {
      const r = await post<{ id: number }>("/api/scans", { folder: scan.folder, recursive: !!scan.recursive, region: place, ratio });
      onStarted(r.id);
    } catch (e) { setErr(String((e as Error).message)); }
  };
  return (
    <dialog ref={ref} onClose={onClose} aria-labelledby="rs-title" style={{ maxWidth: 640 }}>
      <div className="dlg-head"><h3 id="rs-title">{t("results.rescan_title")}</h3><button className="btn" onClick={() => ref.current?.close()}>{t("correct.cancel")}</button></div>
      <div className="dlg-body">
        <p className="hint">{scan.folder}{scan.recursive ? t("results.rs_sub") : ""}{t("results.rs_note")}</p>
        <div className="field"><span className="label">{t("results.rs_place")}</span><LocationPicker value={place} onChange={setPlace} catalogue={catalogue} /></div>
        <div className="field"><span className="label">{t("keep.ratio")}</span>
          <KeepControl name="rs-keep" value={keep} onChange={setKeep} /></div>
        {err && <p className="error-text">{err}</p>}
        <button className="btn primary big" onClick={go}>{t("results.rs_go")}</button>
      </div>
    </dialog>
  );
}
