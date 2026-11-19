// 记录 and 统计 (docs/design-lifelist.md §7.1): the life list derived by the engine from scans, single photos and
// imports. Every number here comes from /api/library/*; names and rarity are read-time labels from the engine.
import { useEffect, useRef, useState } from "react";
import { get, post, postText, upload } from "./api";
import LocationPicker, { type Country } from "./Location";
import SpeciesReference from "./Reference";
import { PlainName } from "./names";
import type { Place } from "./types";

export interface Ref { kind: "photo" | "single" | "import"; id: string; subject_id: string; asset_hash: string; thumb: string; day?: string; sci?: string }
interface Status { generation: number; updating: boolean; error?: string | null;
  hashing?: { files: number; of: number; bytes: number; of_bytes: number } | null }
interface Metrics {
  species: number; observations: number; estimated_count: number; photos: number; pending_subjects: number; pending_photos: number;
  no_bird_photos: number; active_days: number; new_species: number; rare_observations: number; threatened_species: number;
}
interface Summary extends Status {
  metrics: Metrics; coverage: { fallback_date_photos: number; no_place_photos: number; region_only_photos: number };
  rarity_buckets: Record<string, number>; species_keys: string[];
}
interface SpeciesItem {
  key: string; zh: string | null; en: string | null; family: string | null; iucn: string | null; seen: boolean;
  first_day: string | null; last_day: string | null; observations: number; estimated_count: number; photos: number; cover_ref: Ref | null;
}
interface Obs {
  key: string; sci: string; zh: string | null; en: string | null; day: string; place_key: string; place: { label: string | null; source: string; region_code: string | null };
  estimate: number; estimate_source: "max" | "edit"; max_in_photo: number; photo_count: number; rare: boolean; first_seen: boolean;
  fallback_date: boolean; contexts: { region: string | null; tier: number | null; label: string; note: string | null }[]; source_refs: Ref[];
}
interface PhotoItem extends Ref { day: string; level: string; species_key: string | null; zh?: string | null; en?: string | null; reason?: string; subjects?: number; date_source?: string; place_label?: string | null }

const IUCN_ZH: Record<string, string> = { LC: "无危", NT: "近危", VU: "易危", EN: "濒危", CR: "极危", DD: "数据缺乏", NE: "未评估", EX: "灭绝", EW: "野外灭绝" };
const ESTIMATE_NOTE = "同日同地点取单张最大值；可能重复见到同一只鸟";
const NO_PLACE_NOTE = "地点未知的同日记录合并，可能低估次数";
const pad = (n: number) => String(n).padStart(2, "0");
const label = (x: { zh: string | null; en: string | null; key: string }) => x.zh || x.en || x.key;
export const preview = (r: Ref) => r.thumb.replace("/thumb", "/preview").replace("size=thumb", "size=preview");
const q = (o: Record<string, string | number | null | undefined>) =>
  Object.entries(o).filter(([, v]) => v !== null && v !== undefined && v !== "").map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`).join("&");

// ---- periods: Gregorian month / year of the browser's today, or everything -------------------------------------------
export interface Period { kind: "month" | "year" | "all"; y: number; m: number }
export function today(): Period { const d = new Date(); return { kind: "month", y: d.getFullYear(), m: d.getMonth() + 1 }; }
export function range(p: Period): { from: string | null; to: string | null; text: string } {
  if (p.kind === "all") return { from: null, to: null, text: "全部记录" };
  if (p.kind === "year") return { from: `${p.y}-01-01`, to: `${p.y}-12-31`, text: `${p.y} 年（${p.y}-01-01 至 ${p.y}-12-31）` };
  const last = new Date(p.y, p.m, 0).getDate();
  return { from: `${p.y}-${pad(p.m)}-01`, to: `${p.y}-${pad(p.m)}-${pad(last)}`, text: `${p.y} 年 ${p.m} 月（${p.y}-${pad(p.m)}-01 至 ${p.y}-${pad(p.m)}-${pad(last)}）` };
}
const shift = (p: Period, d: number): Period => p.kind === "year" ? { ...p, y: p.y + d }
  : { ...p, y: p.y + Math.floor((p.m - 1 + d) / 12), m: ((((p.m - 1 + d) % 12) + 12) % 12) + 1 };

/** The summary of a range, polled while the engine is still rebuilding; `gen` changes when the numbers do. */
function useSummary(from: string | null, to: string | null) {
  const [s, setS] = useState<Summary | null>(null);
  const [err, setErr] = useState("");
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let dead = false, t = 0;
    const load = () => get<Summary>(`/api/library/summary?${q({ from, to })}`).then((x) => {
      if (dead) return;
      setS(x); setErr("");
      if (x.updating) t = window.setTimeout(load, 1500);
    }).catch((e) => !dead && setErr(String((e as Error).message)));
    load();
    return () => { dead = true; clearTimeout(t); };
  }, [from, to, tick]);
  return { s, err, reload: () => setTick((x) => x + 1) };
}

function Updating({ s, err }: { s: Status | null; err: string }) {
  if (err) return <p className="error-text" role="alert">统计读不出来：{err}</p>;
  if (!s) return <p className="hint" role="status">正在读取…</p>;
  if (s.error) return <p className="error-text" role="alert">更新统计出错：{s.error}（显示的是上一次完整的结果）</p>;
  const h = s.hashing;
  // a first rebuild reads every original once (one fingerprint per photo); the counts below are usable meanwhile
  if (h && h.of > 0) return <p className="hint" role="status">正在给照片做指纹 {h.files} / {h.of} 张（{(h.bytes / 1e9).toFixed(1)} / {(h.of_bytes / 1e9).toFixed(1)} GB）·
    数字先按文件算，同一张照片在两处出现时可能暂时多算；做完自动刷新，改动要等做完</p>;
  return s.updating ? <p className="hint" role="status">更新统计中…（第 {s.generation} 版，完成后自动刷新）</p> : null;
}

function Thumb({ r, alt }: { r: Ref | null; alt: string }) {
  const [ok, setOk] = useState(true);
  return r && ok ? <img className="ll-thumb" src={r.thumb} alt={alt} loading="lazy" onError={() => setOk(false)} />
    : <span className="ll-thumb ll-none" aria-hidden="true">{r ? "原图不可用" : "—"}</span>;
}

// ---- 记录 ---------------------------------------------------------------------------------------------------------
export function Records({ catalogue, sci, onSpecies }: { catalogue: Country[]; sci: string | null; onSpecies: (sci: string | null) => void }) {
  const [tab, setTab] = useState<"species" | "photos" | "pending">("species");
  const [explore, setExplore] = useState(false);
  const [text, setText] = useState("");
  const [sort, setSort] = useState<"recent" | "first" | "name">("recent");
  const { s, err, reload } = useSummary(null, null);
  const [open, setOpen] = useState<Ref | null>(null);
  if (sci) return <SpeciesPage sci={sci} gen={s?.generation} onBack={() => onSpecies(null)} onOpen={setOpen} dialog={open &&
    <Evidence r={open} catalogue={catalogue} onClose={() => setOpen(null)} onChanged={reload} />} />;
  const m = s?.metrics;
  return (
    <section className="ll" aria-labelledby="h-rec">
      <div className="topbar"><div><h2 id="h-rec">记录</h2>
        <span className="sub">{m ? `已见 ${m.species} 种 · ${m.observations} 条观察记录 · ${m.photos} 张照片` : " "}</span></div></div>
      <Updating s={s} err={err} />
      <div className="filters">
        <div className="seg" role="radiogroup" aria-label="记录视图">
          {([["species", "鸟种"], ["photos", "照片"], ["pending", `待确认${m ? ` ${m.pending_subjects}` : ""}`]] as const).map(([k, t]) => (
            <label key={k}><input type="radio" name="ll-tab" checked={tab === k} onChange={() => setTab(k)} /><span>{t}</span></label>))}
        </div>
        {tab === "species" && <>
          <input className="map-search ll-search" type="search" placeholder="搜鸟种：中文、英文或学名" aria-label="搜鸟种" value={text} onChange={(e) => setText(e.target.value)} />
          <label className="inline"><input type="checkbox" checked={explore} onChange={(e) => setExplore(e.target.checked)} /> 全部物种（探索，含未见）</label>
          <label className="inline">排序 <select value={sort} onChange={(e) => setSort(e.target.value as typeof sort)}>
            <option value="recent">最近见到</option><option value="first">首次见到</option><option value="name">名称</option></select></label>
        </>}
      </div>
      {tab === "species" && <SpeciesGrid gen={s?.generation} text={text} explore={explore} sort={sort} onSpecies={onSpecies} />}
      {tab !== "species" && <PhotoList gen={s?.generation} status={tab === "pending" ? "pending" : "all"} onOpen={setOpen}
        empty={tab === "pending" ? "所有已识别主体都已确定到种" : "还没有记录：在批量选片里扫一个文件夹，或认一张照片"} />}
      {open && <Evidence r={open} catalogue={catalogue} onClose={() => setOpen(null)} onChanged={reload} />}
    </section>
  );
}

function SpeciesGrid({ gen, text, explore, sort, onSpecies, from = null, to = null }: {
  gen?: number; text: string; explore: boolean; sort: string; onSpecies: (s: string) => void; from?: string | null; to?: string | null;
}) {
  const [items, setItems] = useState<SpeciesItem[]>([]);
  const [total, setTotal] = useState(0);
  const [n, setN] = useState(60);
  const [err, setErr] = useState("");
  useEffect(() => { setN(60); }, [text, explore, sort, from, to]);
  useEffect(() => {
    if (gen === undefined) return;
    const t = window.setTimeout(() => {
      const pages = Array.from({ length: Math.ceil(n / 60) }, (_, i) => i);
      Promise.all(pages.map((i) => get<{ total: number; items: SpeciesItem[] }>(`/api/library/species?${q({
        q: text, seen: explore ? "all" : "yes", sort: explore && sort === "recent" && text ? "name" : sort, offset: i * 60, limit: 60, from, to })}`)))
        .then((rs) => { setItems(rs.flatMap((r) => r.items).slice(0, n)); setTotal(rs[0]?.total ?? 0); setErr(""); })
        .catch((e) => setErr(String((e as Error).message)));
    }, 150);
    return () => clearTimeout(t);
  }, [gen, text, explore, sort, n, from, to]);
  if (err) return <p className="error-text" role="alert">{err}</p>;
  if (!items.length) return <p className="empty">{text ? <>没有找到 “{text}”</> : explore ? "名录还没装好（需要模型文件里的名称表）" : "还没有记录，从批量选片或认一张开始"}</p>;
  return (
    <>
      <ul className="ll-grid" aria-label="鸟种">
        {items.map((x) => (
          <li key={x.key}><button className="ll-card" onClick={() => onSpecies(x.key)} aria-label={`${label(x)}，${x.seen ? `${x.observations} 条观察记录` : "未见"}`}>
            <Thumb r={x.cover_ref} alt={label(x)} />
            <span className="ll-card-text"><PlainName zh={x.zh} en={x.en} sci={x.key} size="card" />
              <small className="ll-card-meta">{x.seen ? (x.observations ? `${x.observations} 条观察 · ${x.photos} 张照片` : "这段时间没有") : "未见"}
                {!x.zh && x.en && " · 暂无中文名"}</small>
              {x.seen && <small>首见 {x.first_day}</small>}</span>
          </button></li>))}
      </ul>
      {total > items.length && <button className="btn" onClick={() => setN(n + 60)}>再显示 60 种（共 {total}）</button>}
    </>
  );
}

function PhotoList({ gen, status, onOpen, empty, sci, day }: { gen?: number; status: "all" | "pending" | "no-bird"; onOpen: (r: Ref) => void; empty: string; sci?: string; day?: string }) {
  const [items, setItems] = useState<PhotoItem[]>([]);
  const [total, setTotal] = useState(0);
  const [n, setN] = useState(50);
  useEffect(() => {
    if (gen === undefined) return;
    get<{ total: number; items: PhotoItem[] }>(`/api/library/photos?${q({ status, sci, day, limit: Math.min(n, 100), offset: 0 })}`)
      .then((r) => { setItems(r.items); setTotal(r.total); }).catch(() => {});
  }, [gen, status, n, sci, day]);
  if (!items.length) return <p className="empty">{empty}</p>;
  return (
    <>
      <ul className="history-list">
        {items.map((x) => (
          <li key={`${x.asset_hash}/${x.subject_id}`} className="history-entry">
            <button className="history-open" onClick={() => onOpen(x)}>
              <Thumb r={x} alt="" />
              <span>{!x.reason && x.species_key ? <PlainName zh={x.zh ?? null} en={x.en ?? null} sci={x.species_key} size="row" />
                : <span className="history-name">{x.reason ?? (x.level === "photo" ? "未找到鸟" : "待确认")}</span>}
                <span className="history-meta">{x.day}{x.date_source?.startsWith("identified") ? "（拍摄日期缺失，按首次识别日期统计）" : ""}
                  {x.place_label ? ` · ${x.place_label}` : ""}{x.subjects && x.subjects > 1 ? ` · ${x.subjects} 个主体` : ""} · {x.kind === "photo" ? "批量选片" : x.kind === "single" ? "认一张" : "导入"}</span></span>
            </button></li>))}
      </ul>
      {total > items.length && n < 100 && <button className="btn" onClick={() => setN(100)}>再显示更多（共 {total}）</button>}
    </>
  );
}

function SpeciesPage({ sci, gen, onBack, onOpen, dialog }: { sci: string; gen?: number; onBack: () => void; onOpen: (r: Ref) => void; dialog: React.ReactNode }) {
  interface Detail {
    key: string; zh: string | null; en: string | null; family: string | null; genus: string; iucn: string | null; seen: boolean;
    first_day: string | null; last_day: string | null; scope: { observations: number; estimated_count: number; photos: number };
    months: number[]; places: { place_key: string; label: string | null; source: string; region_code: string | null; observations: number }[];
    photo_refs: Ref[]; total_photos: number;
  }
  const [d, setD] = useState<Detail | null>(null);
  const [err, setErr] = useState("");
  const head = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    if (gen === undefined) return;
    get<Detail>(`/api/library/species/detail?${q({ sci })}`).then((x) => { setD(x); setErr(""); }).catch((e) => setErr(String((e as Error).message)));
  }, [sci, gen]);
  useEffect(() => { head.current?.focus(); }, [sci]);
  const max = Math.max(1, ...(d?.months ?? [0]));
  return (
    <section className="ll" aria-labelledby="h-sp">
      <button className="btn link" onClick={onBack}>← 返回记录</button>
      {err && <p className="error-text" role="alert">{err}</p>}
      <h2 id="h-sp" tabIndex={-1} ref={head} className="ll-sp-title">{d ? <PlainName zh={d.zh} en={d.en} sci={d.key} size="hero" /> : sci}</h2>
      {d && <>
        {(d.family || !d.zh) && <p className="hint">{[!d.zh && "暂无中文名", d.family].filter(Boolean).join(" · ")}</p>}
        <p className="facts-inline">
          <span>{d.seen ? <>首次 <strong>{d.first_day}</strong> · 最近 <strong>{d.last_day}</strong></> : <strong>未见</strong>}</span>
          {d.iucn && <span>IUCN <strong>{IUCN_ZH[d.iucn] ?? d.iucn}</strong>（{d.iucn}）</span>}
          <span>观察记录 <strong>{d.scope.observations}</strong></span><span title={ESTIMATE_NOTE}>估计数量 <strong>{d.scope.estimated_count}</strong></span>
          <span>照片 <strong>{d.scope.photos}</strong></span>
        </p>
        <div className="result-section"><h3>每月观察记录（全部年份按月份合计）</h3>
          <ol className="ll-months" aria-label="每月观察记录">
            {d.months.map((v, i) => <li key={i} title={`${i + 1} 月：${v} 条`}><span style={{ height: `${(v / max) * 100}%` }} /><small>{i + 1}</small><b className="sr-only">{i + 1} 月 {v} 条</b></li>)}
          </ol></div>
        <div className="result-section"><h3>地点</h3>
          {d.places.length ? <ul className="ll-places">{d.places.map((p) => <li key={p.place_key}>
            {p.place_key === "none" ? `地点未知（${NO_PLACE_NOTE}）` : p.region_code ? `${p.label ?? p.region_code}（只选了地区 ${p.region_code}）` : (p.label || p.place_key)}
            <small> · {p.observations} 条</small></li>)}</ul> : <p className="hint">没有观察记录</p>}</div>
        <div className="result-section"><h3>照片（{d.total_photos} 张{d.total_photos > 50 ? "，显示最近 50 张" : ""}）</h3>
          {d.photo_refs.length ? <ul className="ll-gallery">{d.photo_refs.map((r) => <li key={r.asset_hash}>
            <button onClick={() => onOpen(r)} aria-label={`打开 ${r.day} 的照片`}><Thumb r={r} alt="" /><small>{r.day}</small></button></li>)}</ul>
            : <p className="hint">还没有自己的照片</p>}</div>
        <SpeciesReference sci={sci} own={d.total_photos} />
      </>}
      {dialog}
    </section>
  );
}

// ---- one photo / subject: facts and edits ----------------------------------------------------------------------------
function Evidence({ r, catalogue, onClose, onChanged }: { r: Ref; catalogue: Country[]; onClose: () => void; onChanged: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const [msg, setMsg] = useState("");
  const [busy, setBusy] = useState(false);
  const [find, setFind] = useState("");
  const [hits, setHits] = useState<{ sci: string; zh: string | null; en: string | null }[]>([]);
  const [count, setCount] = useState("");
  const [day, setDay] = useState("");
  const [place, setPlace] = useState<Place | null>(null);
  useEffect(() => { ref.current?.showModal(); }, []);
  useEffect(() => {
    if (!find.trim()) { setHits([]); return; }
    const t = window.setTimeout(() => get<typeof hits>(`/api/species?q=${encodeURIComponent(find)}`).then(setHits).catch(() => setHits([])), 150);
    return () => clearTimeout(t);
  }, [find]);
  const send = async (edit: unknown) => {
    setBusy(true); setMsg("");
    try {
      const st = await get<Status>("/api/library/summary");
      await post("/api/library/subject-edit", { source_ref: r, edit, expected_generation: st.generation });
      setMsg("已保存，统计更新中"); onChanged();
    } catch (e) {
      const t = String((e as Error).message);
      setMsg(t.includes("重新载入") ? `${t}（你的输入还在，稍后再保存）` : t);
    } finally { setBusy(false); }
  };
  const bird = r.subject_id !== "photo";
  const openScan = async () => {
    const p = await get<{ scan_id: number }>(`/api/photos/${r.id}`);
    location.href = `?scan=${p.scan_id}`;
  };
  return (
    <dialog ref={ref} className="map-dlg" onClose={onClose} aria-labelledby="ev-title">
      <div className="dlg-head"><h3 id="ev-title">{r.day ?? "照片"}{r.sci ? ` · ${r.sci}` : ""}</h3>
        {r.kind === "photo" && <button className="btn" onClick={openScan}>在批量选片中打开</button>}
        <button className="btn" onClick={() => ref.current?.close()}>关闭</button></div>
      <div className="dlg-body ll-ev">
        <img className="ll-ev-img" src={preview(r)} alt="照片预览" />
        <div>
          <p className="hint">{r.kind === "import" ? "导入的记录（原图在观羽自己的文件夹里）" : "原片不会被改动；这里的更正只改记录本"}</p>
          {bird && <div className="result-section"><h3>更正鸟种</h3>
            <input className="map-search" placeholder="搜鸟种：中文、英文或学名" value={find} onChange={(e) => setFind(e.target.value)} />
            <ul className="correct-list">{hits.map((h) => <li key={h.sci}><button type="button" disabled={busy}
              onClick={() => send({ op: "species", state: "species", key: h.sci })}><PlainName zh={h.zh} en={h.en} sci={h.sci} size="row" /></button></li>)}</ul>
            <div className="row"><button className="btn" disabled={busy} onClick={() => send({ op: "species", state: "uncertain", key: null })}>标为不确定</button>
              <button className="btn" disabled={busy} onClick={() => send({ op: "species", state: "none", key: null })}>恢复自动识别</button></div></div>}
          {bird && <div className="result-section"><h3>数量</h3>
            <div className="row"><input type="number" min={1} max={999998} value={count} onChange={(e) => setCount(e.target.value)} aria-label="这个框里的鸟数" />
              <button className="btn" disabled={busy || !(+count >= 1 && +count <= 999998)} onClick={() => send({ op: "count", value: Math.round(+count) })}>保存数量</button>
              <button className="btn link" disabled={busy} onClick={() => send({ op: "count", value: null })}>恢复自动（1）</button></div>
            <div className="row" style={{ marginTop: 8 }}><button className="btn" disabled={busy} onClick={() => send({ op: "exclude", value: true })}>排除这个框（不是鸟 / 认错）</button>
              <button className="btn link" disabled={busy} onClick={() => send({ op: "exclude", value: false })}>取消排除</button></div></div>}
          <div className="result-section"><h3>拍摄日期（整张照片）</h3>
            <div className="row"><input type="date" value={day} onChange={(e) => setDay(e.target.value)} aria-label="拍摄日期" />
              <button className="btn" disabled={busy || !day} onClick={() => send({ op: "date", value: { wall: day, offset_min: null } })}>保存日期</button>
              <button className="btn link" disabled={busy} onClick={() => send({ op: "date", value: null })}>恢复照片里的日期</button></div></div>
          <div className="result-section"><h3>地点（整张照片）</h3>
            <LocationPicker value={place} onChange={setPlace} catalogue={catalogue} compact />
            <div className="row" style={{ marginTop: 8 }}>
              <button className="btn" disabled={busy || !place} onClick={() => place && send({ op: "place", value: place.source === "region"
                ? { source: "region", lat: null, lon: null, label: place.label, region_code: place.code ?? null }
                : { source: place.source, lat: place.lat, lon: place.lon, label: place.label, region_code: null } })}>保存地点</button>
              <button className="btn link" disabled={busy} onClick={() => send({ op: "place", value: { source: "none", lat: null, lon: null, label: "", region_code: null } })}>设为地点未知</button>
              <button className="btn link" disabled={busy} onClick={() => send({ op: "place", value: null })}>恢复原来的地点</button></div></div>
          {msg && <p className="hint" role="status">{msg}</p>}
        </div>
      </div>
    </dialog>
  );
}

// ---- 统计 ---------------------------------------------------------------------------------------------------------
export function Stats({ catalogue, onSpecies }: { catalogue: Country[]; onSpecies: (sci: string) => void }) {
  // ?period=year | all | YYYY-MM opens that period (a link to a month / year)
  const [p, setP] = useState<Period>(() => {
    const v = new URLSearchParams(location.search).get("period") ?? "", t = today(), m = v.match(/^(\d{4})-(\d{2})$/);
    return v === "year" || v === "all" ? { ...t, kind: v } : m ? { kind: "month", y: +m[1], m: +m[2] } : t;
  });
  const rg = range(p);
  const { s, err, reload } = useSummary(rg.from, rg.to);
  const [list, setList] = useState<{ kind: "species" | "obs"; day?: string; rare?: boolean } | null>(null);
  const [open, setOpen] = useState<Ref | null>(null);
  const m = s?.metrics;
  const tile = (n: number | undefined, t: string, onClick?: () => void, title?: string, cls = "") => (
    <button className={`ll-metric ${cls}`} onClick={onClick} disabled={!onClick} title={title}><b>{n ?? "–"}</b><small>{t}</small></button>);
  return (
    <section className="ll" aria-labelledby="h-stats">
      <div className="topbar"><div><h2 id="h-stats">统计</h2><span className="sub">{rg.text}</span></div>
        <div className="row">
          <div className="seg" role="radiogroup" aria-label="统计范围">
            {([["month", "本月"], ["year", "本年"], ["all", "全部"]] as const).map(([k, t]) => (
              <label key={k}><input type="radio" name="ll-period" checked={p.kind === k} onChange={() => { setP({ ...today(), kind: k }); setList(null); }} /><span>{t}</span></label>))}
          </div>
          {p.kind !== "all" && <><button className="btn" onClick={() => setP(shift(p, -1))} aria-label="上一个">‹</button>
            <button className="btn" onClick={() => setP(shift(p, 1))} aria-label="下一个">›</button></>}
        </div></div>
      <Updating s={s} err={err} />
      <div className="ll-metrics">
        {tile(m?.species, "鸟种", () => setList({ kind: "species" }))}
        {tile(m?.observations, "观察记录", () => setList({ kind: "obs" }), "同一种鸟、同一天、同一地点算一条")}
        {tile(m?.estimated_count, "估计数量", () => setList({ kind: "obs" }), ESTIMATE_NOTE)}
        {tile(m?.new_species, "新种", undefined, "这段时间里第一次见到的鸟种（按全部记录算）", "new")}
      </div>
      {m && <p className="hint">照片 {m.photos} 张 · 待确认 {m.pending_subjects} 个主体（{m.pending_photos} 张）· 未找到鸟 {m.no_bird_photos} 张 · 有记录的天数 {m.active_days}
        {s!.coverage.fallback_date_photos > 0 && ` · ${s!.coverage.fallback_date_photos} 张拍摄日期缺失，按首次识别日期统计`}
        {s!.coverage.no_place_photos > 0 && ` · ${s!.coverage.no_place_photos} 张地点未知（${NO_PLACE_NOTE}）`}
        {s!.coverage.region_only_photos > 0 && ` · ${s!.coverage.region_only_photos} 张只选了地区`}。估计数量：{ESTIMATE_NOTE}。</p>}
      {m && m.species === 0 && <p className="empty">这段时间没有确定到种的观察记录{m.pending_subjects ? `；有 ${m.pending_subjects} 个主体待确认，在“记录 → 待确认”里改正` : ""}</p>}
      {m && <div className="ll-rarity">
        <button className="btn link" onClick={() => setList({ kind: "obs", rare: true })}>本地罕见 / 少见的观察记录：<b>{m.rare_observations}</b></button>
        <span>受威胁鸟种（IUCN 易危、濒危、极危）：<b>{m.threatened_species}</b></span>
        <span className="hint">按每条记录自己的地点和月份：{Object.entries(s!.rarity_buckets).map(([k, v]) => `${k} ${v}`).join(" · ")}</span>
      </div>}
      {list && <div className="result-section">
        <div className="row"><h3>{list.kind === "species" ? "这段时间的鸟种" : list.rare ? "本地罕见 / 少见" : list.day ? `${list.day} 的观察记录` : "观察记录"}</h3>
          <button className="btn link" onClick={() => setList(null)}>收起</button></div>
        {list.kind === "species" ? <SpeciesGrid gen={s?.generation} text="" explore={false} sort="recent" onSpecies={onSpecies} from={rg.from} to={rg.to} />
          : <ObsList gen={s?.generation} from={list.day ?? rg.from} to={list.day ?? rg.to} rare={list.rare} onSpecies={onSpecies} onOpen={setOpen} onChanged={reload} />}
      </div>}
      <Calendar p={p} gen={s?.generation} onDay={(d) => setList({ kind: "obs", day: d })} onMonth={(y, m) => { setP({ kind: "month", y, m }); setList(null); }} />
      <MapView from={rg.from} to={rg.to} gen={s?.generation} onOpen={setOpen} />
      <DataTools from={rg.from} to={rg.to} gen={s?.generation} onChanged={reload} />
      {open && <Evidence r={open} catalogue={catalogue} onClose={() => setOpen(null)} onChanged={reload} />}
    </section>
  );
}

function ObsList({ gen, from, to, rare, onSpecies, onOpen, onChanged }: {
  gen?: number; from: string | null; to: string | null; rare?: boolean; onSpecies: (s: string) => void; onOpen: (r: Ref) => void; onChanged: () => void;
}) {
  const [items, setItems] = useState<Obs[]>([]);
  const [total, setTotal] = useState(0);
  const [edit, setEdit] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState("");
  useEffect(() => {
    if (gen === undefined) return;
    get<{ total: number; items: Obs[] }>(`/api/library/observations?${q({ from, to, rare: rare ? "true" : undefined, limit: 100 })}`)
      .then((r) => { setItems(r.items); setTotal(r.total); }).catch((e) => setMsg(String((e as Error).message)));
  }, [gen, from, to, rare]);
  const save = async (o: Obs, count: number | null) => {
    setMsg("");
    try { await post("/api/library/observation-count", { group_key: o.key, count, expected_generation: gen }); onChanged(); }
    catch (e) { setMsg(String((e as Error).message)); }
  };
  if (!items.length) return <p className="empty">没有观察记录</p>;
  return (
    <>
      {msg && <p className="error-text" role="alert">{msg}</p>}
      <ul className="ll-obs">
        {items.map((o) => (
          <li key={o.key}>
            <div className="ll-obs-refs">{o.source_refs.slice(0, 3).map((r) => <button key={r.asset_hash + r.subject_id} onClick={() => onOpen({ ...r, day: o.day, sci: o.sci })} aria-label="打开照片"><Thumb r={r} alt="" /></button>)}</div>
            <div>
              <button className="ll-obs-name" onClick={() => onSpecies(o.sci)}><PlainName zh={o.zh} en={o.en} sci={o.sci} size="row" /></button>
              {o.first_seen && <span className="pill">新种</span>}{o.rare && <span className="pill rare">本地{o.contexts.find((c) => c.tier === 1) ? "罕见" : "少见"}</span>}
              <span className="history-meta">{o.day} · {o.place_key === "none" ? "地点未知" : o.place.region_code ? `${o.place.label ?? o.place.region_code}（地区）` : o.place.label ?? o.place_key}
                {" · "}{o.photo_count} 张 · 估计 {o.estimate} 只{o.estimate_source === "edit" ? `（你改的；单张最多 ${o.max_in_photo}）` : ""}
                {o.fallback_date ? " · 拍摄日期缺失" : ""} · 稀有度 {o.contexts.map((c) => c.label + (c.note ? `（${c.note}）` : "")).join(" / ")}</span>
              <span className="row ll-count"><input type="number" min={1} max={999998} aria-label="本次观察数量" placeholder={String(o.estimate)}
                value={edit[o.key] ?? ""} onChange={(e) => setEdit({ ...edit, [o.key]: e.target.value })} />
                <button className="btn slim" disabled={!(+edit[o.key] >= 1 && +edit[o.key] <= 999998)} onClick={() => save(o, Math.round(+edit[o.key]))}>改本次观察数量</button>
                {o.estimate_source === "edit" && <button className="btn link" onClick={() => save(o, null)}>恢复单张最大值</button>}
                {+edit[o.key] > 0 && +edit[o.key] < o.max_in_photo && <small className="hint">比单张照片里最多的 {o.max_in_photo} 只还少：这是你的估计</small>}</span>
            </div>
          </li>))}
      </ul>
      {total > items.length && <p className="hint">显示前 {items.length} 条，共 {total} 条</p>}
    </>
  );
}

// Photo-first calendar (owner, 2026-11-18): the day's bird, not a colour level. Cover = the latest eligible bird of
// the day by wall time, then photo hash, then subject id (engine: library.cover_of); its square crop is cached.
interface CalCell { observations: number; species: number; cover: (Ref & { crop: string; sci: string; zh: string | null; en: string | null }) | null }
function CoverCell({ c, text, big }: { c: CalCell; text: string; big?: boolean }) {
  const [ok, setOk] = useState(true);
  const name = c.cover ? (c.cover.zh || c.cover.en || c.cover.sci) : "";
  return ok && c.cover ? <><img src={c.cover.crop} alt={`${name}${c.species > 1 ? ` 等 ${c.species} 种` : ""}`} loading="lazy" onError={() => setOk(false)} />
    {!big && c.species > 1 && <span className="ll-badge" aria-hidden="true">{c.species}</span>}<span className="ll-cal-n">{text}</span></>
    : <><span className="ll-cal-count">{c.species} 种</span><span className="ll-cal-n">{text}</span></>;   // no picture (volume not mounted)
}

function Calendar({ p, gen, onDay, onMonth }: { p: Period; gen?: number; onDay: (d: string) => void; onMonth: (y: number, m: number) => void }) {
  const [year, setYear] = useState(p.y);
  const [cal, setCal] = useState<{ days: Record<string, CalCell>; months: (CalCell & { month: number })[]; active_days: number; years: string[] } | null>(null);
  useEffect(() => { setYear(p.kind === "all" ? new Date().getFullYear() : p.y); }, [p.kind, p.y]);
  useEffect(() => { if (gen !== undefined) get<typeof cal>(`/api/library/calendar?year=${p.kind === "month" ? p.y : year}`).then(setCal).catch(() => setCal(null)); }, [year, gen, p.kind, p.y]);
  if (!cal) return null;
  const label = (c: CalCell) => c.cover ? `${c.cover.zh || c.cover.en || c.cover.sci}${c.species > 1 ? ` 等 ${c.species} 种` : ""}，${c.observations} 条观察记录` : "";
  if (p.kind === "month") {
    const first = new Date(p.y, p.m - 1, 1), lead = (first.getDay() + 6) % 7, n = new Date(p.y, p.m, 0).getDate();
    return (<div className="result-section"><h3>日历</h3>
      <div className="ll-month" aria-label={`${p.y} 年 ${p.m} 月`}>
        {["一", "二", "三", "四", "五", "六", "日"].map((w) => <span key={w} className="ll-wd">{w}</span>)}
        {Array.from({ length: lead }, (_, i) => <span key={`x${i}`} />)}
        {Array.from({ length: n }, (_, i) => {
          const k = `${p.y}-${pad(p.m)}-${pad(i + 1)}`, c = cal.days[k];
          return c ? <button key={k} className="ll-cal has" onClick={() => onDay(k)} aria-label={`${k}：${label(c)}`} title={`${k}：${label(c)}`}>
            <CoverCell c={c} text={String(i + 1)} /></button>
            : <span key={k} className="ll-cal"><span className="ll-cal-n">{i + 1}</span></span>;
        })}
      </div></div>);
  }
  return (<div className="result-section"><div className="row"><h3>{year} 年</h3>
    {p.kind === "all" && <select value={year} onChange={(e) => setYear(+e.target.value)} aria-label="年份">
      {[...new Set([...cal.years, String(new Date().getFullYear())])].sort().map((y) => <option key={y}>{y}</option>)}</select>}
    <small className="hint">{cal.active_days} 天有记录</small></div>
    <ol className="ll-year-tiles">{cal.months.map((c) => (
      <li key={c.month}>{c.observations ? <button className="ll-cal has big" onClick={() => onMonth(year, c.month)} aria-label={`${year} 年 ${c.month} 月：${c.species} 种，${c.observations} 条观察；代表照片 ${label(c)}`}>
        <CoverCell c={c} text={`${c.month} 月`} big /></button> : <span className="ll-cal big"><span className="ll-cal-n">{c.month} 月</span></span>}
        <small>{c.observations ? `${c.species} 种 · ${c.observations} 条观察` : "没有记录"}</small></li>))}</ol></div>);
}

function MapView({ from, to, gen, onOpen }: { from: string | null; to: string | null; gen?: number; onOpen: (r: Ref) => void }) {
  const box = useRef<HTMLDivElement>(null);
  const [shown, setShown] = useState(false);
  const [info, setInfo] = useState<{ regions: { code: string; observations: number }[]; no_place_observations: number; truncated: boolean } | null>(null);
  const [tiles, setTiles] = useState<boolean | null>(null);
  const [pick, setPick] = useState<Ref[]>([]);
  useEffect(() => {
    if (!shown || gen === undefined) return;
    let dead = false, map: { remove: () => void } | null = null;
    Promise.all([import("leaflet"), import("leaflet/dist/leaflet.css")]).then(([mod]) => {
      if (dead || !box.current) return;
      const L = mod.default;
      const m = L.map(box.current, { worldCopyJump: true }).setView([20, 0], 2);
      const t = L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 18,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors' });
      t.on("tileload", () => setTiles(true)); t.on("tileerror", () => setTiles((ok) => ok ?? false)); t.addTo(m);
      const layer = L.layerGroup().addTo(m);
      let first = true;
      const load = () => {
        const b = m.getBounds(), w = ((b.getWest() + 540) % 360) - 180, e = ((b.getEast() + 540) % 360) - 180;
        const span = b.getEast() - b.getWest() >= 360;
        const bounds = [Math.max(-90, b.getSouth()), span ? -180 : w, Math.min(90, b.getNorth()), span ? 180 : e].map((x) => x.toFixed(5)).join(",");
        get<{ clusters: { lat: number; lon: number; observations: number; refs: Ref[] }[]; regions: { code: string; observations: number }[]; no_place_observations: number; truncated: boolean }>(
          `/api/library/map?${q({ bounds, from, to })}`).then((r) => {
          if (dead) return;
          layer.clearLayers(); setInfo(r);
          for (const c of r.clusters) {
            L.marker([c.lat, c.lon], { icon: L.divIcon({ className: "ll-pin", html: `<span>${c.observations}</span>`, iconSize: [30, 30] }),
              title: `${c.observations} 条观察记录（照片位置）` }).on("click", () => setPick(c.refs)).addTo(layer);
          }
          if (first && r.clusters.length) { first = false; m.fitBounds(L.latLngBounds(r.clusters.map((c) => [c.lat, c.lon] as [number, number])).pad(0.3), { maxZoom: 11 }); }
        }).catch(() => {});
      };
      m.on("moveend", load); load();
      map = m;
    }).catch(() => setTiles(false));
    return () => { dead = true; map?.remove(); };
  }, [shown, from, to, gen]);
  return (
    <div className="result-section"><div className="row"><h3>地图</h3>
      {!shown && <button className="btn" onClick={() => setShown(true)}>打开地图</button>}</div>
      {!shown && <p className="hint">地图图块来自 openstreetmap.org，打开时才加载；照片和记录不会离开这台电脑。</p>}
      {shown && <>
        <div ref={box} className="map-box ll-map" aria-label="观察记录地图（数字是该处的观察记录数）" />
        {tiles === false && <p className="hint">地图图块加载不了（可能离线）。下面的地区和列表仍然可用。</p>}
        {pick.length > 0 && <div className="ll-gallery">{pick.map((r) => <button key={r.asset_hash + r.subject_id} onClick={() => onOpen(r)}>
          <Thumb r={r} alt="" /><small>{r.day} · <i>{r.sci}</i></small></button>)}</div>}
        {info && <p className="hint">{info.truncated ? "点太多，只显示观察记录最多的 500 处；放大看更多。" : ""}
          {info.regions.length > 0 && <>只选了地区的观察记录（不在地图上标点）：{info.regions.map((x) => `${x.code} ${x.observations}`).join(" · ")}。</>}
          {info.no_place_observations > 0 && <>地点未知：{info.no_place_observations} 条（{NO_PLACE_NOTE}）。</>}</p>}
      </>}
    </div>
  );
}

// ---- 数据: portable file, import, eBird ----------------------------------------------------------------------------------
function DataTools({ from, to, gen, onChanged }: { from: string | null; to: string | null; gen?: number; onChanged: () => void }) {
  const [msg, setMsg] = useState("");
  const [pv, setPv] = useState<{ token: string; summary: Record<string, number | string>; conflicts: { id: string; field: string; local: unknown; file: unknown }[] } | null>(null);
  const [choices, setChoices] = useState<Record<string, "local" | "file">>({});
  const [fallback, setFallback] = useState<"refuse" | "include" | "exclude">("refuse");
  const [est, setEst] = useState(false);
  const save = (text: string, name: string) => {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([text], { type: "text/csv" })); a.download = name; a.click(); URL.revokeObjectURL(a.href);
  };
  const ebird = async () => {
    setMsg("");
    try {
      save(await postText("/api/library/ebird", { start: from, end: to, fallback, use_estimates: est }), "birdcm-lifelist-ebird.csv");
    } catch (e) { setMsg(String((e as Error).message)); }
  };
  const choose = async (f: File | undefined) => {
    if (!f) return;
    setMsg("正在检查文件…"); setPv(null);
    try { const fd = new FormData(); fd.append("file", f); setPv(await upload("/api/library/import/preview", fd)); setMsg(""); }
    catch (e) { setMsg(String((e as Error).message)); }
  };
  const apply = async () => {
    try {
      const r = await post<{ added_photos: number; merged_photos: number; pending_conflicts: number }>("/api/library/import/apply",
        { token: pv!.token, mode: "merge", choices, expected_generation: gen });
      setMsg(`已导入：新增 ${r.added_photos} 张，已有 ${r.merged_photos} 张${r.pending_conflicts ? `，${r.pending_conflicts} 处冲突保留了本机的` : ""}`);
      setPv(null); onChanged();
    } catch (e) { setMsg(String((e as Error).message)); }
  };
  return (
    <div className="result-section"><h3>数据</h3>
      <div className="row">
        <a className="btn" href={`/api/library/export?${q({ from, to })}`} download>{from ? "导出这段时间（.birdcm）" : "完整备份（.birdcm）"}</a>
        <label className="btn">导入 .birdcm<input type="file" accept=".birdcm" hidden onChange={(e) => choose(e.target.files?.[0])} /></label>
      </div>
      <p className="hint">备份文件里有原图，没有加密，放在你选的位置；只在你自己分享时才离开这台电脑。导入先预览，不会改动扫描结果和原片。</p>
      {pv && <div className="missing soft" role="status">
        文件里 {String(pv.summary.records)} 条记录：新照片 {String(pv.summary.new_photos)} 张，已有 {String(pv.summary.identical_photos)} 张，
        原图缺失 {String(pv.summary.missing_originals)} 张，需要 {Math.ceil(+pv.summary.required_bytes / 1e6)} MB。
        {pv.conflicts.map((c) => <label key={c.id} className="row">{c.field}：本机 {JSON.stringify(c.local)} / 文件 {JSON.stringify(c.file)}
          <select value={choices[c.id] ?? "local"} onChange={(e) => setChoices({ ...choices, [c.id]: e.target.value as "local" | "file" })}>
            <option value="local">保留本机</option><option value="file">用文件的</option></select></label>)}
        <div className="row"><button className="btn primary" onClick={apply}>合并导入</button><button className="btn link" onClick={() => setPv(null)}>取消</button></div>
      </div>}
      <div className="row" style={{ marginTop: 10 }}>
        <button className="btn" onClick={ebird}>导出 eBird 文件（这段时间）</button>
        <label className="inline"><input type="checkbox" checked={est} onChange={(e) => setEst(e.target.checked)} /> 用估计数量（默认 X）</label>
        <label className="inline">拍摄日期缺失的记录 <select value={fallback} onChange={(e) => setFallback(e.target.value as typeof fallback)}>
          <option value="refuse">先让我核对</option><option value="include">包含（按首次识别日期）</option><option value="exclude">排除</option></select></label>
      </div>
      <p className="hint">eBird Record Format，Incidental，不是完整清单；只含确定到种的记录，待确认的不导出。上传在 eBird 网站上手动做。</p>
      {msg && <p className="hint" role="status">{msg}</p>}
    </div>
  );
}
