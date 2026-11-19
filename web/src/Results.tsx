import type { ReactNode } from "react";
import { forwardRef, memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { get, post, put, useEngine } from "./api";
const CHIPS = 3;                                   // species chips shown before "+n", so the bar stays one row at 1440 px
import CorrectPanel, { type Pick, type Scope } from "./Correct";
import ExportDialog from "./Export";
import KeepControl, { KeepButton, keepOf, type KeepSetting } from "./Keep";
import LocationPicker, { type Country, placeText } from "./Location";
import { Candidates, MarkControls, type MarkSet, named, SpName, useMarks, Verdict } from "./names";
import type { Exif, PhotoResult, PhotoRow, Place, Scan, Snapshot } from "./types";

export const STATE_LABEL: Record<string, string> = { queued: "排队中", running: "扫描中", stopping: "正在停止", paused: "已停止",
  finalizing: "正在汇总", completed: "已完成", failed: "出错已停" };
const ROW_LABEL: Record<string, string> = { queued: "排队中", working: "识别中", unscanned: "未扫描", failed: "处理失败" };
const PREVIEW_LABEL: Record<string, string> = { queued: "还在排队", working: "正在识别", unscanned: "未扫描", failed: "处理失败" };
type Phase = "scanning" | "paused" | "complete";
type RowState = "ready" | "queued" | "working" | "unscanned" | "failed";

// ---------- formatting ----------
const starTxt = (s: number) => (s === -1 ? "淘汰" : s === 0 ? "0 星" : "★".repeat(s) + "☆".repeat(3 - s));
const starLabel = (s: number | null) => (s === null ? "待定" : s === -1 ? "淘汰" : `${s} 星`);
const pct = (p: number) => `${Math.round(p * 100)}%`;
const evText = (ev: number | null) => (ev === null ? "— EV" : `${ev > 0 ? "+" : ""}${+ev.toFixed(1)} EV`);
const sharpTxt = (v: number | null | undefined) => (v == null ? "—" : v.toFixed(2));
const REGION: Record<string, string> = { eye: "眼睛周围", head: "头部", box: "整个鸟框" };
const RARITY_NOTE = "按 GBIF 观察记录在当地当月所占比例分级：常见 ≥0.2%，不常见 ≥0.02%，少见 ≥0.002%，更低为罕见。记录多少反映的是有多少人报告，不是鸟有多少。";
const IUCN_ZH: Record<string, string> = { LC: "无危", NT: "近危", VU: "易危", EN: "濒危", CR: "极危", DD: "数据缺乏", EX: "灭绝", EW: "野外灭绝", NE: "未评估" };
// rarer first: 罕见 1, 少见 2, 不常见 3, 常见 4; 无记录 (0) counts as rarest, unknown last
const rank = (p: PhotoRow) => { const t = p.result?.rarity?.tier; return t == null ? 9 : t === 0 ? 0.5 : t; };
const Q_LABEL: Record<string, string> = { sharp_burst: "组内清晰度", sharp_species: "同种清晰度", eye: "眼睛", size: "鸟的大小",
  focus: "对焦", aesthetic: "美学", detection: "检测把握", burst_length: "连拍长度", fly: "飞版加分", rare: "稀有加分" };
function qParts(parts: Record<string, number | null> | null | undefined): string {
  if (!parts) return "";
  return Object.entries(parts).filter(([k, v]) => !(["fly", "rare"].includes(k) && !v))
    .map(([k, v]) => `${Q_LABEL[k] ?? k} ${v == null ? "未知" : ["fly", "rare"].includes(k) ? `+${v}` : v.toFixed(2)}`).join(" · ");
}
const PRIOR_SRC: Record<string, string> = { photo: "照片 GPS", map: "地图选点", device: "本机定位", region: "地区中心点" };
const fmtTime = (t: string | null | undefined) => (t ? t.slice(0, 19).replace("T", " ") : "时间未知");

export function nameOf(r: PhotoResult): string {
  if (r.rejected) return r.reject_reason || "没有找到鸟";
  const s = r.species;
  if (!s || s.level === "uncertain" || !s.label) return "不确定";
  if (s.level === "genus") return `${s.label.sci.replace(/ sp\.$/, "")} 属`;
  return s.label.zh || s.label.en || s.label.sci;
}
const confirmed = (r: PhotoResult | null) => !!r && !r.rejected && r.species?.level === "species" && !!r.species.label;
// the species a photo is about, rejected or not (a rejected photo still names its bird)
const named_ = (r: PhotoResult | null) => !!r && r.species?.level === "species" && !!r.species.label;
const speciesKey = (r: PhotoResult | null) => (named_(r) ? r!.species!.label!.sci : "");

function Settings({ e }: { e: Partial<Exif> | null | undefined }) {
  if (!e) return <div className="settings"><span>读取拍摄信息…</span></div>;
  return (
    <div className="settings">
      <span>{e.focal_mm != null ? `${+e.focal_mm.toFixed(0)} mm` : "— mm"}</span> <span>{e.aperture != null ? `f/${e.aperture}` : "f/—"}</span>{" "}
      <span>{e.shutter ? `${e.shutter} s` : "— s"}</span> <span>ISO {e.iso ?? "—"}</span> <span>{evText(e.ev ?? null)}</span>
    </div>
  );
}

function Marks({ r, m }: { r: PhotoResult; m: MarkSet }) {
  const at = (p: [number, number]) => ({ left: `${p[0] * 100}%`, top: `${p[1] * 100}%` });
  return (
    <>
      {m.box && r.boxes.map((d, i) => (
        <span key={i} className={`mk box${i === r.subject ? "" : " other"}`} style={{ left: `${d.box[0] * 100}%`, top: `${d.box[1] * 100}%`,
          width: `${(d.box[2] - d.box[0]) * 100}%`, height: `${(d.box[3] - d.box[1]) * 100}%` }} />
      ))}
      {m.eye && r.eye && r.eye_visible && <span className="mk eye" style={at(r.eye)} />}
      {m.beak && r.beak && (r.beak_p ?? 0) >= 0.5 && <span className="mk beak" style={at(r.beak)} />}
      {m.focus && r.focus && <span className="mk af" style={at(r.focus)} />}
    </>
  );
}

interface TileAct { pick: (id: number) => void; open: (id: number) => void; group: (p: PhotoRow) => void; ref: (id: number, el: HTMLButtonElement | null) => void }

const Tile = memo(function Tile({ p, st, active, complete, more, marks, exif: e, act }: {
  p: PhotoRow; st: RowState; active: boolean; complete: boolean; more: boolean; marks: MarkSet | null;
  exif: Partial<Exif> | null | undefined; act: { current: TileAct };
}) {
  const r = p.result;
  const name = r ? (r.rejected ? nameOf(r) : named(r.species).title) : ROW_LABEL[st];
  return (
    <button type="button" className="tile" data-state={st} aria-pressed={active} tabIndex={active ? 0 : -1}
      aria-describedby="photo-keys" aria-label={`${name}，${complete ? starLabel(p.stars) : "待定星级"}，${p.file}`}
      ref={(el) => act.current.ref(p.id, el)}
      onClick={() => act.current.pick(p.id)} onDoubleClick={() => act.current.open(p.id)}>
      <Photo row={p} marks={marks} show={!!r || active} />
      <span className="row-result">{r && r.rejected && r.species?.label ? <span className="name dim" style={{ display: "block" }}>{name} · {named(r.species).title}</span>
        : r && !r.rejected ? <><SpName sp={r.species} />{r.species_own && <span className="pill">{r.species?.manual ? "主人改正" : "按连拍组修正"}</span>}
        {r.rarity && r.rarity.tier != null && <span className={`pill${r.rarity.tier <= 2 ? " rare" : ""}`}>{r.rarity.label}</span>}</> : <span className={r ? "name" : "scan-name"} style={{ display: "block" }}>{name}</span>}
        {complete && p.stars !== null ? <span className="stars">{starTxt(p.stars)}</span> : <span className="pending-stars">待定星级</span>}
        {more && (p.burst_size ?? 1) > 1 && (
          <span className="pill more" role="link" title="只看这一组" onClick={(ev) => { ev.stopPropagation(); act.current.group(p); }}>+{(p.burst_size ?? 1) - 1}</span>
        )}
        {r && !r.rejected && r.flying !== null && <span className="pill">{r.flying ? "在飞" : "不在飞"}</span>}
        {r && <span className="small reason-line" style={{ display: "block" }}>
          {complete && p.star_reason ? p.star_reason : r.rejected ? "不参与标星" : r.eye_visible ? `眼睛可见 · 头部清晰度 ${sharpTxt(r.sharpness)}` : "眼睛未找到"}</span>}
        {st === "failed" && <span className="small reason-line" style={{ display: "block" }}>{p.error}</span>}
      </span>
      <span className="row-settings"><span className="file">{p.file}</span><br />
        {e && <span className="small">{e.focal_mm != null ? `${+e.focal_mm.toFixed(0)} mm` : "—"} · f/{e.aperture ?? "—"} · {e.shutter ?? "—"} s<br />ISO {e.iso ?? "—"} · {evText(e.ev ?? null)}</span>}</span>
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
      <span className={`frame ${r.width >= r.height ? "land" : "port"}`} style={{ aspectRatio: `${r.width} / ${r.height}` }}>
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
    文件: p.file, 路径: p.path, 状态: p.state === "failed" ? "失败" : p.state === "done" ? "已识别" : "未扫描", 错误: p.error ?? "",
    星级: starLabel(p.stars), 理由: p.star_reason ?? "",
    中文名: l?.zh ?? "", 英文名: l?.en ?? "", 学名: l?.sci ?? (s ? named(s).sci : ""),
    按连拍组修正: r?.species_own && !r.species?.manual ? "是" : "", 鸟种来源: !r?.species ? "" : r.species.manual ? "手动改正" : r.species_own ? "连拍组修正" : "应用", 原识别: r?.species_own ? `${named(r.species_own).title} · ${named(r.species_own).sci} · ${pct(r.species_own.top5[0]?.p ?? 0)}` : "",
    识别结果: r ? nameOf(r) : "", 识别层级: s?.level ?? "", 把握: s?.label?.p ?? s?.top5[0]?.p ?? "",
    候选: s ? s.top5.map((c) => [c.zh, c.en, c.sci, pct(c.p)].filter(Boolean).join(" · ")).join(" / ") : "",
    在飞: r?.flying == null ? "" : r.flying ? "是" : "否", 在飞概率: r?.p_fly ?? "",
    鸟框: r && r.subject != null ? r.boxes[r.subject].box.join(" ") : "", 眼睛位置: r?.eye?.join(" ") ?? "", 对焦点: r?.focus?.join(" ") ?? "",
    眼睛: r?.eye_visible == null ? "" : r.eye_visible ? "看得见" : "看不见", 头部清晰度: r?.sharpness ?? "", 清晰度测量处: r?.sharpness_region ?? "",
    美学分: r?.aesthetic ?? "", 清楚的鸟: r?.clear == null ? "" : r.clear ? "是" : "否",
    可能的稀有记录: s?.check === "rare" ? "是" : "", 衍生文件: (p.variants ?? []).map((v) => v.split("/").pop()).join(" / "),
    稀有度: r?.rarity?.label ?? "", 稀有度地区: r?.rarity?.region ?? "", IUCN: r?.rarity?.iucn ?? "", 连拍组: p.burst_group ?? "", 组内排名: p.burst_rank ?? "", 连拍组张数: p.burst_size ?? "",
    相机: e?.camera ?? "", 镜头: e?.lens ?? "", 焦距毫米: e?.focal_mm ?? "", 光圈: e?.aperture ?? "", 快门秒: e?.shutter ?? "", ISO: e?.iso ?? "",
    曝光补偿EV: e?.ev ?? "", 对焦模式: e?.focus_mode ?? "", 拍摄时间: e?.taken_at ?? "", 拍摄时间显示: e?.taken_at ? fmtTime(e.taken_at) : "",
    地区: r?.region.source === "photo" ? `GPS ${r.region.gps!.map((v) => v.toFixed(5)).join(", ")}` : r?.region.name ?? "",
    地区来源: r?.region.source === "photo" ? "照片自带" : r?.region.source === "scan" ? "批次设定" : "",
    修正用的位置: r?.region.prior ? `${r.region.prior.lat}, ${r.region.prior.lon}` : "",
    位置来源: r?.region.prior ? PRIOR_SRC[r.region.prior.source] : "没有位置（只凭图像）", 拍摄周: r?.region.prior?.week ?? "",
  };
}
function save(name: string, text: string, type: string) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([text], { type }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}
function csv(rows: ReturnType<typeof exportRow>[]): string {
  if (!rows.length) return "﻿";
  const keys = Object.keys(rows[0]) as (keyof (typeof rows)[0])[];
  const q = (v: unknown) => {
    // text that a spreadsheet would run as a formula gets a leading apostrophe (numbers stay numbers); JSON keeps the original
    let t = String(v ?? "");
    if (typeof v === "string" && /^[=+\-@\t\r]/.test(t)) t = "'" + t;
    return /[",\r\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
  };
  return "﻿" + [keys.join(","), ...rows.map((o) => keys.map((k) => q(o[k])).join(","))].join("\n");
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
      es = new EventSource(`/api/scans/${scanId}/events?after=${s.cursor}`);
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
    pick: (id) => { setSelected(id); if (matchMedia("(max-width: 720px)").matches) panelRef.current?.scrollIntoView({ block: "start" }); },
    open: (id) => { setSelected(id); viewerRef.current?.showModal(); },
    group: (p) => { setSelected(p.id); setGroupOnly(p.burst_group); },
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

  // "只看这一组": the list shows one burst, whatever the other filters say (they are kept, and come back on clearing)
  const [groupOnly, setGroupOnly] = useState<number | null>(null);
  const [fold, setFold] = useState(false);              // 连拍折叠: one row per burst, its best frame
  const view = useMemo(() => {
    const usesResults = fsp || ffly !== "all" || frar !== "0";
    // filters first, then (folded) one row per burst: its best-ranked frame AMONG the matches (Codex I8)
    const matches = (p: PhotoRow) => {
      if (onlyIds) return onlyIds.ids.has(p.id);
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
    if (fold && groupOnly === null && !onlyIds) {
      const best = new Map<number, PhotoRow>();
      for (const p of v) {
        const g = p.burst_group ?? -p.id;
        const cur = best.get(g);
        if (!cur || (p.burst_rank ?? 99) < (cur.burst_rank ?? 99)) best.set(g, p);
      }
      const keep = new Set([...best.values()].map((p) => p.id));
      v = v.filter((p) => keep.has(p.id));
    }
    const ready = (p: PhotoRow) => (p.result ? 1 : 0);
    const cmp: Record<string, (a: PhotoRow, b: PhotoRow) => number> = {
      queue: (a, b) => a.seq - b.seq,
      time: (a, b) => (a.result?.exif.taken_at ?? "~").localeCompare(b.result?.exif.taken_at ?? "~") || a.seq - b.seq,
      star: (a, b) => (b.stars ?? -2) - (a.stars ?? -2) || (b.quality?.q ?? -1) - (a.quality?.q ?? -1) || a.seq - b.seq,
      species: (a, b) => nameOf(a.result!).localeCompare(nameOf(b.result!), "zh-CN") || a.seq - b.seq,
      fly: (a, b) => (b.result?.p_fly ?? 0) - (a.result?.p_fly ?? 0),
      eye: (a, b) => (b.result?.sharpness ?? -1) - (a.result?.sharpness ?? -1),
      rar: (a, b) => rank(a) - rank(b) || (b.stars ?? -2) - (a.stars ?? -2) || a.seq - b.seq,
    };
    // finished photos first in the chosen order; the ones still waiting stay behind them in queue order
    v.sort((a, b) => ready(b) - ready(a) || (ready(a) && ready(b) ? cmp[sort](a, b) : a.seq - b.seq));
    return v;
  }, [photos, fs, fsp, ffly, frar, sort, starsReady, groupOnly, onlyIds, fold]);

  // a photo picked from the burst strip may be outside the filtered list: it is still the one shown
  const current = view.find((p) => p.id === selected) ?? (selected !== null ? photos.find((p) => p.id === selected) : undefined) ?? view[0] ?? null;
  const tiles = useRef(new Map<number, HTMLButtonElement>());
  const burst = useMemo(() => {
    if (!current?.burst_group || (current.burst_size ?? 1) < 2) return null;
    const members = photos.filter((p) => p.burst_group === current.burst_group);
    const byTime = [...members].sort((a, b) => (a.result?.exif.taken_at ?? "").localeCompare(b.result?.exif.taken_at ?? "") || a.seq - b.seq);
    return { members: [...members].sort((a, b) => (a.burst_rank ?? 99) - (b.burst_rank ?? 99)), order: new Map(byTime.map((p, i) => [p.id, i + 1])) };
  }, [photos, current?.burst_group, current?.burst_size]);
  const pick = (id: number) => {
    setSelected(id);
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
    const p = view[i + d];
    if (!p) return;
    setSelected(p.id);
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
  if (!scan) return <p className="hint">读取中…</p>;
  // counts come from the rows on screen: scan events only arrive on state changes, photo events on every result
  const c = { total: photos.length, done: photos.filter((p) => p.state === "done").length, failed: photos.filter((p) => p.state === "failed").length };
  const finished = c.done + c.failed;
  const rejected = photos.filter((p) => p.result?.rejected).length;
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
    const t = r.rarity?.tier, iucn = r.rarity?.iucn;
    const tags = [t === 1 || t === 0 ? "罕见" : t === 2 ? "少见" : "", iucn && ["NT", "VU", "EN", "CR"].includes(iucn) ? (IUCN_ZH[iucn] ?? iucn) : ""].filter(Boolean);
    if (tags.length) notableMap.set(l.sci, { sci: l.sci, name: l.zh || l.en || l.sci, tag: tags.join("·"), why: `${l.sci}：${tags.join("，")}` });
  }
  const notable = [...notableMap.values()];
  const rare = new Map<string, string>();
  for (const p of photos) {
    const t = p.result?.rarity?.tier, l = p.result?.species?.label;
    if (t != null && t > 0 && t <= 2 && l && !p.result!.rejected) rare.set(l.sci, `${l.zh || l.en || l.sci}（${p.result!.rarity!.label}）`);
  }
  const rareNames = [...rare.values()].join("、");
  const stepText = complete ? "" : scan.state === "failed" ? ` · ${scan.error ?? ""}` : phase === "paused" ? " · 等待继续"
    : scan.state === "stopping" ? " · 这一批做完就停" : scan.state === "queued" ? (engine === "loading" ? " · 模型加载完自动开始" : engine === "error" ? " · 模型出错，在顶栏重试后开始" : " · 等前一个扫描完成") : scan.state === "finalizing" ? " · 分连拍组" : " · 找鸟、认种、看眼睛和姿态";
  const days = photos.map((p) => p.result?.exif.taken_at?.slice(0, 10)).filter(Boolean).sort() as string[];
  const dateRange = days.length ? (days[0] === days[days.length - 1] ? days[0] : `${days[0]} – ${days[days.length - 1].slice(5)}`) : "";
  const folderName = scan.folder.split("/").filter(Boolean).pop() ?? scan.folder;
  const state = complete ? `${c.total} 张${c.failed ? `（${c.failed} 张失败）` : ""}`
    : `${phase === "paused" ? (scan.state === "failed" ? "出错已停" : "已停止") : scan.state === "stopping" ? "正在停止" : scan.state === "finalizing" ? "正在汇总" : scan.state === "queued" ? (engine === "loading" ? "等模型加载完" : engine === "error" ? "模型出错，等重试" : "排队中") : "扫描中"} ${finished} / ${c.total}`;

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
          <p className="scan-id" title={`${scan.folder}${scan.recursive ? "（包含子文件夹）" : ""}${stepText}`}>
            <button type="button" className="scan-folder" title={`${scan.folder} · 点一下复制路径`} onClick={() => navigator.clipboard?.writeText(scan.folder).catch(() => {})}>{folderName}</button>
            <span className="scan-meta"> · {placeText(scan.region)}{dateRange ? ` · ${dateRange}` : ""} · </span>
            <span id="scan-copy" role="status">{state}</span>
          </p>
          {!complete && scan.state !== "finalizing" && scan.state !== "queued" && (
            <button type="button" className="btn slim" onClick={act} disabled={scan.state === "stopping"}>{phase === "paused" ? "继续" : "停止"}</button>
          )}
          {changes && !changesOff && (
            <span className="keep-pop">
              <span className="changes-chip"><button type="button" aria-expanded={changesOpen} onClick={() => setChangesOpen(!changesOpen)}>较上次：{changes.changed.length} 张鸟种变了 ▾</button>
                <button type="button" aria-label="不再显示和上次的比较" onClick={() => { setChangesOff(true); try { localStorage.setItem(`birdcm.changesOff.${scanId}`, "1"); } catch { /* not remembered */ } }}>×</button></span>
              {changesOpen && (
                <div className="keep-menu changes-menu" role="dialog" aria-label="和上一次扫描比">
                  <button type="button" onClick={() => { setChangesOpen(false); setOnlyIds({ ids: new Set(changes.changed), label: "鸟种有变化的" }); }}>{changes.changed.length} 张鸟种变了</button>
                  <button type="button" onClick={() => { setChangesOpen(false); setOnlyIds({ ids: new Set(changes.vague), label: "变成不确定 / 只到属的" }); }}>其中 {changes.vague.length} 张变成不确定或只到属</button>
                  <button type="button" onClick={() => { setChangesOpen(false); setOnlyIds({ ids: new Set(changes.fixed), label: "按连拍组修正的" }); }}>{changes.fixed.length} 张按连拍组修正</button>
                  <button type="button" onClick={() => { keepOld(rel.previous!, true); onOpen(rel.previous!); }}>打开之前的结果</button>
                </div>
              )}
            </span>
          )}
          <div className="res-actions">
            <button className="btn slim" onClick={() => setRescanOpen(true)}>重新扫描</button>
            <button className="btn slim primary" disabled={!complete} onClick={() => { setExportOpen(true); exportRef.current?.showModal(); }}>导出</button>
            <button className="btn slim link" onClick={onBack}>换一批</button>
            {nav}
          </div>
        </div>
        {!complete && <progress className="bar-progress" value={finished} max={c.total || 1} aria-label="扫描进度" />}
      </header>
      {scan.state === "failed" && <p className="warn-strip stale" role="alert">扫描出错停下了：{scan.error ?? "原因未知"}</p>}
      {rel.newer ? (
        <p className="warn-strip" role="status">
          {rel.newer.state === "completed" ? "这个文件夹已经重新扫描完了"
            : rel.newer.state === "failed" ? "这个文件夹的重新扫描出错停下了，这里仍是上次完成的结果"
            : rel.newer.state === "paused" ? `这个文件夹的重新扫描已暂停（已完成 ${rel.newer.counts.done + rel.newer.counts.failed} / ${rel.newer.counts.total}）`
            : `这个文件夹正在重新扫描（已完成 ${rel.newer.counts.done + rel.newer.counts.failed} / ${rel.newer.counts.total}）`}
          {" · "}<button className="btn link" onClick={() => onOpen(rel.newer!.id)}>{rel.newer.state === "completed" ? "查看新结果" : "去看重新扫描"}</button>
          {rel.newer.state === "completed" && !keepOld(scanId) && <span className="hint">（几秒钟没有操作就会自动切过去）</span>}
        </p>
      ) : rel.stale && (
        <p className="warn-strip stale">这些结果是旧版本算的（模型、地点修正或规则变过） · <button className="btn link" onClick={() => setRescanOpen(true)}>重新扫描</button></p>
      )}
      <h2 id="h-res" tabIndex={-1} className="sr-only">审片结果</h2>
      {rescanOpen && <Rescan scan={scan} catalogue={catalogue} onClose={() => setRescanOpen(false)} onStarted={(id) => { setRescanOpen(false); onOpen(id); }} />}
      {complete && (scan.ratio as { strategy?: string })?.strategy !== "quota" ? (
        <div className="cull" aria-label="这批的结果">
          <div className="cull-keep">
            <b className="cull-big">留 {keptN} 张 · {starredPct}%</b>
            <KeepButton value={keepSet} onChange={(v) => put(`/api/scans/${scanId}/ratio`, { ...v }).then(() => load()).catch((e) => setError(String(e.message)))} />
            {floorN > 0 && <small title="每个确认的鸟种至少留最好的一张（质量太差的不留）；这些可能让总数超过目标比例">含 {floorN} 张每种保底</small>}
          </div>
          <div className="cull-stars">
            {[3, 2, 1].map((n) => (
              <button key={n} type="button" className={`cull-chip${fs === String(n) ? " on" : ""}`} onClick={() => setFs(fs === String(n) ? "all" : String(n))}>
                <span className="stars">{"★".repeat(n)}</span> {photos.filter((p) => p.stars === n).length}</button>
            ))}
          </div>
          <div className="cull-drop" title={`0 星 ${photos.filter((p) => p.stars === 0).length} 张（可评星但没选上）· 淘汰 ${rejected} 张（没有清楚的鸟）`}>
            <button type="button" className={`cull-chip${fs === "drop" ? " on" : ""}`} onClick={() => setFs(fs === "drop" ? "all" : "drop")}>不留 {c.total - keptN} 张</button>
            <small>0 星 {photos.filter((p) => p.stars === 0).length} · 淘汰 {rejected}</small>
          </div>
          <div className="cull-species">
            <b>{species.list.length} 种鸟</b>
            {rareIds.size > 0 && (
              <button type="button" className="cull-chip rare" title="确认到种，但这里这个季节大部分地方很少有它：可能是稀有记录，请核对"
                onClick={() => setOnlyIds({ ids: rareIds, label: "可能的稀有记录" })}>可能稀有 {rareIds.size}</button>
            )}
            {manualIds.size > 0 && (
              <button type="button" className="cull-chip" onClick={() => setOnlyIds({ ids: manualIds, label: "手动改正" })}>手动改正 {manualIds.size}</button>
            )}
            {lookIds.size > 0 && (
              <button type="button" className="cull-chip rare" title="同一只鸟在两个很像的种之间来回认，已按多数统一；请核对"
                onClick={() => setOnlyIds({ ids: lookIds, label: "近似种来回跳" })}>近似种请核对 {lookIds.size}</button>
            )}
            {(allChips ? notable : notable.slice(0, chipsN)).map((n) => (
              <button key={n.sci} type="button" className={`cull-chip rare${fsp === n.sci ? " on" : ""}`} title={n.why} onClick={() => setFsp(fsp === n.sci ? "" : n.sci)}>{n.name}<small>{n.tag}</small></button>
            ))}
            {notable.length > chipsN && (
              <button type="button" className="cull-chip" aria-expanded={allChips} onClick={() => setAllChips(!allChips)}>{allChips ? "收起" : `+${notable.length - chipsN}`}</button>
            )}
          </div>
        </div>
      ) : (
      <div className="summary" data-complete={complete}>
        {complete ? (
          <>
            <div><b>{c.total}</b><small>张照片</small></div>
            {[3, 2, 1, 0].map((s) => (
              <div key={s}><b>{starsReady ? photos.filter((p) => p.stars === s).length : "—"}</b>
                <small className="stars" aria-label={`${s} 星`}>{s ? "★".repeat(s) : "0 星"}{!starsReady && " 待定"}</small></div>
            ))}
            <div><b>{rejected}</b><small>淘汰</small></div>
          </>
        ) : <div><b>{finished} / {c.total}</b><small>已扫描照片</small></div>}
        <div><b>{species.list.length}</b><small>已认出的鸟种</small></div>
        <div><b className="rare-name">{rareNames || (complete ? "没有" : "尚未发现")}</b>
          <small title={RARITY_NOTE}>少见和罕见（当地当月的观察记录比例）</small></div>
      </div>
      )}

      <div className="filters" role="group" aria-label="筛选和排序">
        <div className="seg" role="radiogroup" aria-label="星级" aria-disabled={!starsReady}>
          {[["all", "全部"], ["3", "三星"], ["2", "两星"], ["1", "一星"], ["0", "0 星"], ["-1", "淘汰"]].map(([v, t]) => (
            <label key={v}><input type="radio" name="fs" value={v} checked={fs === v} disabled={!starsReady} onChange={() => setFs(v)} /><span>{t}</span></label>
          ))}
        </div>
        <select aria-label="鸟种" value={fsp} onChange={(e) => setFsp(e.target.value)}>
          <option value="">所有鸟种</option>
          {species.list.map(([k, n]) => <option key={k} value={k}>{n}</option>)}
          {species.unsure && <option value="unsure">不确定或只到属</option>}
        </select>
        <select aria-label="稀有度" value={frar} onChange={(e) => setFrar(e.target.value)} title={RARITY_NOTE}>
          <option value="0">所有稀有度</option><option value="3">不常见及以上</option><option value="2">少见及以上</option><option value="1">罕见</option>
        </select>
        <select aria-label="是否在飞" value={ffly} onChange={(e) => setFfly(e.target.value)}>
          <option value="all">所有姿态</option><option value="fly">在飞</option><option value="still">不在飞</option>
        </select>
        <label className="inline"><input type="checkbox" checked={fold} onChange={(e) => setFold(e.target.checked)} disabled={!complete} /> 连拍折叠</label>
        <label className="inline">排序
          <select value={sort} onChange={(e) => { sortTouched.current = true; setSort(e.target.value); }}>
            <option value="queue">队列顺序</option>
            <option value="star" disabled={!starsReady}>星级高的在前</option>
            <option value="time">拍摄时间</option>
            <option value="species">按鸟种排序</option>
            <option value="fly">在飞的在前</option>
            <option value="rar">稀有的在前</option>
            <option value="eye">头部清晰的在前</option>
          </select>
        </label>
        {onlyIds && (
          <span className="chip">只看{onlyIds.label}（{onlyIds.ids.size}）<button type="button" aria-label="清除这个筛选" onClick={() => setOnlyIds(null)}>×</button></span>
        )}
        {groupOnly !== null && (
          <span className="chip">只看第 {groupOnly} 组连拍<button type="button" aria-label="清除：不再只看这一组" onClick={() => {
            setGroupOnly(null);
            if (current) requestAnimationFrame(() => tiles.current.get(current.id)?.scrollIntoView({ block: "center" }));
          }}>×</button></span>
        )}
        {!starsReady && <p className="hint">星级要等全部照片扫完后互相比较才能定。</p>}
      </div>

      <div className="inspection">
        <section className="list" aria-labelledby="list-title">
          <div className="list-head"><h3 id="list-title">照片列表</h3><span aria-live="polite">显示 {view.length} / {c.total} 张</span></div>
          <p className="sr-only" id="photo-keys">上、下方向键选择照片，回车看大图。右侧显示这张照片的全部信息。</p>
          <div id="grid" onKeyDown={(e) => {
            if (e.key === "Enter") { e.preventDefault(); openViewer(); return; }
            if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
            e.preventDefault();
            step(e.key === "ArrowDown" ? 1 : -1);
          }}>
            {view.length ? view.map((p) => (
              <Tile key={p.id} p={p} st={rowState(p)} active={p.id === current?.id} complete={complete} more={fold && groupOnly === null}
                marks={marks} exif={p.result?.exif ?? exifs[p.id]} act={tileAct} />
            )) : <p className="empty">{c.total ? "没有符合条件的照片。" : "这个文件夹里没有 ARW、DNG 或 JPG 照片。"}</p>}
          </div>
        </section>
        {current && <Inspector ref={panelRef} p={current} st={rowState(current)} marks={marks} setMarks={setMarks} complete={complete}
          inScan={inScan} onCorrect={correct}
          exif={current.result?.exif ?? exifs[current.id]} onOpen={openViewer} burst={burst} onPick={pick}
          groupOnly={groupOnly !== null} onGroupOnly={(on) => setGroupOnly(on ? current.burst_group : null)} />}
      </div>

      <dialog ref={viewerRef} className="viewer" aria-label="大图" onClick={(e) => { if (e.target === e.currentTarget) viewerRef.current?.close(); }}
        onKeyDown={(e) => { if (e.key === "ArrowLeft" || e.key === "ArrowUp") { e.preventDefault(); step(-1); } if (e.key === "ArrowRight" || e.key === "ArrowDown") { e.preventDefault(); step(1); } }}>
        <div className="dlg-head"><h3>{current?.file}</h3><span className="hint">← → 换一张 · Esc 关闭</span>
          <button className="btn" onClick={() => viewerRef.current?.close()}>关闭</button></div>
        {current && <Photo row={current} marks={current.result ? marks : null} big show alt={current.file} />}
      </dialog>

      <dialog ref={exportRef} aria-labelledby="e-title" style={{ maxWidth: 760 }} onClose={() => setExportOpen(false)}>
        <div className="dlg-head"><h3 id="e-title">导出</h3><button className="btn" onClick={() => exportRef.current?.close()}>关闭</button></div>
        {exportOpen && <ExportDialog scanId={scanId} photos={photos} view={view} onClose={() => exportRef.current?.close()}
          saveTable={(rows, kind) => kind === "csv" ? save("选片结果.csv", csv(rows.map(exportRow)), "text/csv")
            : save("选片结果.json", JSON.stringify(rows.map(exportRow), null, 2), "application/json")} />}
        <p className="hint" style={{ margin: "0 16px 14px" }}>导出的文件存到你选的位置，原片文件夹里不写任何东西。写给 Lightroom 的 XMP 和网页报告以后再做。</p>
      </dialog>
    </section>
  );
}

interface Burst { members: PhotoRow[]; order: Map<number, number> }

const Inspector = forwardRef<HTMLElement, { p: PhotoRow; st: RowState; marks: MarkSet; setMarks: (m: MarkSet) => void; complete: boolean;
  exif?: Exif; onOpen: () => void; burst: Burst | null; onPick: (id: number) => void; groupOnly: boolean; onGroupOnly: (on: boolean) => void;
  inScan: Pick[]; onCorrect: (id: number, sci: string | null | undefined, scope: Scope) => Promise<void> }>(
  function Inspector({ p, st, marks, setMarks, complete, exif, onOpen, burst, onPick, groupOnly, onGroupOnly, inScan, onCorrect }, ref) {
  const [correcting, setCorrecting] = useState(false);
  useEffect(() => setCorrecting(false), [p.id]);
  const r = p.result, ready = st === "ready" && !!r;
  const sp = r?.species, sure = confirmed(r), e = exif;
  const missing: Partial<Record<keyof MarkSet, string>> = r ? {
    eye: r.eye && r.eye_visible ? undefined : "这张没有", beak: r.beak && (r.beak_p ?? 0) >= 0.5 ? undefined : "这张没有",
    focus: r.focus ? undefined : "不可用", box: r.boxes.length ? undefined : "这张没有" } : {};
  return (
    <aside className="inspector" aria-label="所选照片的全部信息" ref={ref}>
      {ready && <MarkControls m={marks} set={setMarks} missing={missing} />}
      <button className="preview-photo" type="button" aria-label="看大图" onClick={onOpen}>
        <Photo row={p} marks={ready ? marks : null} big show alt={p.file} />
      </button>
      <div className="preview-info">
        {!ready ? (
          <>
            <h3>{PREVIEW_LABEL[st]}</h3>
            <p className="preview-note">{st === "failed" ? p.error : st === "unscanned" ? "继续扫描后会在这里显示识别结果。" : "识别完成后会在这里显示鸟种和标记。"}</p>
          </>
        ) : (
          <>
            <div className="verdict stars">{complete && p.stars !== null ? starTxt(p.stars) : "待定星级"}</div>
            {complete && p.star_reason && <p className="reason">{p.star_reason}</p>}
            {r!.rejected ? (
              <>
                <div className="sp-cn">{r!.reject_reason ?? "没有找到鸟"}</div>
                <p className="preview-note">{r!.boxes.length ? `检测到 ${r!.boxes.length} 个框，但都没有通过"清楚的鸟"判断，标为淘汰（不参与标星）。` : "检测模型在这张照片里没有找到鸟，标为淘汰。"}</p>
                {sp && <><p className="conf-line">照片淘汰，但鸟本身认得出：</p><SpName sp={sp} /><Verdict sp={sp} />
                  <h4 className="panel-h">前 5 个候选</h4><Candidates sp={sp} /></>}
              </>
            ) : sp ? (
              <>
                <SpName sp={sp} big />
                <Verdict sp={sp} />
                {sp.manual && r!.species_own && (
                  <p className="fixed-note"><span className="tbd">主人改正</span> 应用自己认的是 {named(r!.species_own).title}
                    {r!.species_own.label && <> <i>{r!.species_own.label.sci}</i></>}</p>
                )}
                {!sp.manual && r!.species_own && (
                  <p className="fixed-note"><span className="tbd">按连拍组修正</span> 这一组 {sp.consensus?.frames} 张里 {sp.consensus?.support} 张支持它；
                    这张自己最像 {named({ ...r!.species_own, label: r!.species_own.top5[0], level: "species" }).title} <i>{r!.species_own.top5[0]?.sci}</i>（{pct(r!.species_own.top5[0]?.p ?? 0)}），按连拍组改成它</p>
                )}
                <p className="conf-line">{r!.species_own ? (sp.label?.p != null ? `这张自己给它 ${pct(sp.label.p)}` : "这张自己的前五里没有它")
                  : `${sure ? "把握" : "最高候选"} ${pct((sure || sp.level === "genus" ? sp.label!.p : sp.top5[0].p) ?? 0)}`} <span className="ref">· {!sp.geo ? "没有位置，只凭图像" : sp.prior?.unknown ? "地区模型里没有这个鸟种，没按地点修正" : "已按拍摄地点和季节修正"}</span></p>
                {correcting ? <CorrectPanel own={sp.top5} inScan={inScan} current={sp.level !== "uncertain" ? sp.label?.sci ?? null : null}
                    burst={(p.burst_size ?? 1) > 1} manual={!!sp.manual} onClose={() => setCorrecting(false)}
                    onApply={(sci, scope) => onCorrect(p.id, sci, scope)} onUndo={(scope) => onCorrect(p.id, undefined, scope)} />
                  : complete && <button type="button" className="btn slim" onClick={() => setCorrecting(true)}>改正鸟种</button>}
                <h4 className="panel-h">{r!.species_own ? "这张自己的前 5 个候选" : "前 5 个候选"}</h4>
                <Candidates sp={sp} />
              </>
            ) : null}
            <dl className="facts">
              <dt>在飞</dt><dd>{r!.flying == null ? "—" : r!.flying ? "是" : "否"}{r!.p_fly != null && <span className="ref"> · P = {r!.p_fly.toFixed(2)}</span>}</dd>
              <dt>眼睛</dt><dd>{r!.eye_visible == null ? "—" : r!.eye_visible ? "看得见" : "看不见"}</dd>
              <dt>头部清晰度</dt><dd>{sharpTxt(r!.sharpness)}{r!.sharpness_region && <span className="ref"> · 量在{REGION[r!.sharpness_region]}，只在本批内比较（阈值未标定）</span>}</dd>
              <dt>美学分</dt><dd>{r!.aesthetic != null ? r!.aesthetic.toFixed(2) : "—"} <span className="ref">仅供参考</span></dd>
              <dt>本地稀有度</dt><dd title={RARITY_NOTE}>{r!.rarity ? <><b>{r!.rarity.label}</b>{r!.rarity.region && <span className="ref"> · {r!.rarity.region}</span>}{r!.rarity.note && <span className="ref">（{r!.rarity.note}）</span>}</> : "—"}
                <span className="ref" style={{ display: "block" }}>此地此月，按 GBIF 观察记录所占比例；是有多少人报告，不是鸟有多少</span></dd>
              <dt>受威胁等级</dt><dd>{r!.rarity?.iucn ? <b>IUCN {IUCN_ZH[r!.rarity.iucn] ?? r!.rarity.iucn}（{r!.rarity.iucn}）</b> : "—"}
                <span className="ref" style={{ display: "block" }}>全球受威胁等级（IUCN 红色名录），全球统一，不随地点变化</span></dd>
              {p.quality && <><dt>综合分</dt><dd><b>{p.quality.q.toFixed(2)}</b>
                <span className="ref" style={{ display: "block" }}>{qParts(p.quality.parts)}</span></dd></>}
              {(p.variants?.length ?? 0) > 0 && <><dt>同一张的其他文件</dt><dd>{p.variants!.map((v) => <div key={v}>{v.split("/").pop()}</div>)}
                <span className="ref" style={{ display: "block" }}>另有降噪版 DNG（Lightroom 生成），和这张算同一张，不单独评星</span></dd></>}
              <dt>连拍组</dt><dd>{!p.burst_group ? "扫完后分组" : p.burst_size === 1 ? `第 ${p.burst_group} 组 · 只有这一张`
                : `第 ${p.burst_group} 组 · 组内排名第 ${p.burst_rank}，共 ${p.burst_size} 张${burst ? ` · 按拍摄顺序第 ${burst.order.get(p.id)} 张` : ""}`}</dd>
              <dt>鸟框</dt><dd>{r!.boxes.length} 个{r!.boxes.length > 1 && r!.subject != null ? `，主体按${r!.focus ? "对焦点" : "把握"}选取` : ""}</dd>
            </dl>
            {burst && (
              <section className="burst" aria-label={`第 ${p.burst_group} 组连拍`}>
                <div className="burst-head"><h4 className="panel-h" style={{ border: 0, margin: 0, padding: 0 }}>这一组连拍（按组内排名）</h4>
                  <label className="inline"><input type="checkbox" checked={groupOnly} onChange={(e) => onGroupOnly(e.target.checked)} /> 只看这一组</label></div>
                <ol className="burst-strip">
                  {burst.members.map((m) => (
                    <li key={m.id}>
                      <button type="button" aria-pressed={m.id === p.id} onClick={() => onPick(m.id)}
                        aria-label={`组内排名第 ${m.burst_rank}，${m.stars !== null ? starLabel(m.stars) : "待定星级"}，${m.file}`}>
                        <img src={`/api/photos/${m.id}/thumb?v=${m.size}-${m.mtime_ns}`} alt="" loading="lazy" decoding="async" />
                        <span className="burst-meta"><b>#{m.burst_rank}</b> <span className="stars">{m.stars !== null ? starTxt(m.stars) : "待定"}</span></span>
                        <span className="burst-meta">拍摄第 {burst.order.get(m.id)} 张</span>
                      </button>
                    </li>
                  ))}
                </ol>
              </section>
            )}
          </>
        )}
        <h4 className="panel-h">拍摄信息</h4>
        <Settings e={e} />
        <dl className="facts">
          <dt>相机</dt><dd>{e?.camera ?? "—"}</dd><dt>镜头</dt><dd>{e?.lens ?? "—"}</dd>
          <dt>对焦模式</dt><dd>{e?.focus_mode ?? "—"}</dd><dt>拍摄时间</dt><dd>{fmtTime(e?.taken_at)}</dd>
          {r && <><dt>地点</dt><dd>{r.region.source === "photo" ? `GPS ${r.region.gps!.map((v) => v.toFixed(4)).join(", ")}` : r.region.name ?? "—"}{" "}
            <span className="ref">· {r.region.prior ? `${PRIOR_SRC[r.region.prior.source]}${r.region.prior.week ? `，第 ${r.region.prior.week} 周` : "，全年"}` : "没有位置，只凭图像"}</span></dd></>}
          <dt>文件</dt><dd>{p.file}<span className="ref path"> {p.path}</span></dd>
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
      <div className="dlg-head"><h3 id="rs-title">重新扫描这个文件夹</h3><button className="btn" onClick={() => ref.current?.close()}>取消</button></div>
      <div className="dlg-body">
        <p className="hint">{scan.folder}{scan.recursive ? " · 包含子文件夹" : ""}。新结果会替代这一次的；没变的照片会直接复用。</p>
        <div className="field"><span className="label">拍摄地点</span><LocationPicker value={place} onChange={setPlace} catalogue={catalogue} /></div>
        <div className="field"><span className="label">留片比例</span>
          <KeepControl name="rs-keep" value={keep} onChange={setKeep} /></div>
        {err && <p className="error-text">{err}</p>}
        <button className="btn primary big" onClick={go}>开始重新扫描</button>
      </div>
    </dialog>
  );
}
