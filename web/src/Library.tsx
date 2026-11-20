// 记录 and 统计 (docs/design-lifelist.md §7.1): the life list derived by the engine from scans, single photos and
// imports. Every number here comes from /api/library/*; names and rarity are read-time labels from the engine.
import { useEffect, useRef, useState } from "react";
import { get, post, postText, upload } from "./api";
import LocationPicker, { type Country, PlaceName } from "./Location";
import SpeciesReference from "./Reference";
import { PlainName } from "./names";
import { getLang, t } from "./i18n";
import { iucnText, rarityText } from "./look";
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
  key: string; sci: string; zh: string | null; en: string | null; day: string; place_key: string; place: { label: string | null; source: string; region_code: string | null; points: [number, number][] };
  estimate: number; estimate_source: "max" | "edit"; max_in_photo: number; photo_count: number; rare: boolean; first_seen: boolean;
  fallback_date: boolean; contexts: { region: string | null; tier: number | null; label: string; note: string | null }[]; source_refs: Ref[];
}
interface PhotoItem extends Ref { day: string; level: string; species_key: string | null; zh?: string | null; en?: string | null; reason?: string; subjects?: number; date_source?: string; place_label?: string | null; lat?: number | null; lon?: number | null }

const ESTIMATE_NOTE = () => t("library.estimate_note");
const NO_PLACE_NOTE = () => t("library.no_place_note");
/** A region label from our Chinese catalogue: as it is in Chinese, the engine's English name (by code) in English. */
const regionLabel = (label: string | null, code: string) => getLang() === "en" ? <PlaceName code={code} label={label} /> : (label ?? code);
const pad = (n: number) => String(n).padStart(2, "0");
const label = (x: { zh: string | null; en: string | null; key: string }) => x.zh || x.en || x.key;
export const preview = (r: Ref) => r.thumb.replace("/thumb", "/preview").replace("size=thumb", "size=preview");
const q = (o: Record<string, string | number | null | undefined>) =>
  Object.entries(o).filter(([, v]) => v !== null && v !== undefined && v !== "").map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`).join("&");

// ---- periods: Gregorian month / year of the browser's today, or everything -------------------------------------------
export interface Period { kind: "month" | "year" | "all"; y: number; m: number }
export function today(): Period { const d = new Date(); return { kind: "month", y: d.getFullYear(), m: d.getMonth() + 1 }; }
export function range(p: Period): { from: string | null; to: string | null; text: string } {
  if (p.kind === "all") return { from: null, to: null, text: t("library.all_records") };
  if (p.kind === "year") return { from: `${p.y}-01-01`, to: `${p.y}-12-31`, text: t("library.range_year", { y: p.y }) };
  const last = new Date(p.y, p.m, 0).getDate();
  return { from: `${p.y}-${pad(p.m)}-01`, to: `${p.y}-${pad(p.m)}-${pad(last)}`, text: t("library.range_month", { y: p.y, m: p.m, from: `${p.y}-${pad(p.m)}-01`, to: `${p.y}-${pad(p.m)}-${pad(last)}` }) };
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
  if (err) return <p className="error-text" role="alert">{t("library.read_error", { e: err })}</p>;
  if (!s) return <p className="hint" role="status">{t("library.reading")}</p>;
  if (s.error) return <p className="error-text" role="alert">{t("library.update_error", { e: s.error })}</p>;
  const h = s.hashing;
  // a first rebuild reads every original once (one fingerprint per photo); the counts below are usable meanwhile
  if (h && h.of > 0) return <p className="hint" role="status">{t("library.hashing", { files: h.files, of: h.of,
    gb: (h.bytes / 1e9).toFixed(1), of_gb: (h.of_bytes / 1e9).toFixed(1) })}</p>;
  return s.updating ? <p className="hint" role="status">{t("library.updating", { g: s.generation })}</p> : null;
}

function Thumb({ r, alt }: { r: Ref | null; alt: string }) {
  const [ok, setOk] = useState(true);
  return r && ok ? <img className="ll-thumb" src={r.thumb} alt={alt} loading="lazy" onError={() => setOk(false)} />
    : <span className="ll-thumb ll-none" aria-hidden="true">{r ? t("library.original_unavailable") : "—"}</span>;
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
      <div className="topbar"><div><h2 id="h-rec">{t("library.records")}</h2>
        <span className="sub">{m ? t("library.records_sub", { species: m.species, obs: m.observations, photos: m.photos }) : " "}</span></div></div>
      <Updating s={s} err={err} />
      <div className="filters">
        <div className="seg" role="radiogroup" aria-label={t("library.records_view")}>
          {([["species", t("library.tab_species")], ["photos", t("library.tab_photos")], ["pending", `${t("library.tab_pending")}${m ? ` ${m.pending_subjects}` : ""}`]] as const).map(([k, name]) => (
            <label key={k}><input type="radio" name="ll-tab" checked={tab === k} onChange={() => setTab(k)} /><span>{name}</span></label>))}
        </div>
        {tab === "species" && <>
          <input className="map-search ll-search" type="search" placeholder={t("library.search")} aria-label={t("library.search_label")} value={text} onChange={(e) => setText(e.target.value)} />
          <label className="inline"><input type="checkbox" checked={explore} onChange={(e) => setExplore(e.target.checked)} /> {t("library.explore")}</label>
          <label className="inline">{t("library.sort")} <select value={sort} onChange={(e) => setSort(e.target.value as typeof sort)}>
            <option value="recent">{t("library.sort_recent")}</option><option value="first">{t("library.sort_first")}</option><option value="name">{t("library.sort_name")}</option></select></label>
        </>}
      </div>
      {tab === "species" && <SpeciesGrid gen={s?.generation} text={text} explore={explore} sort={sort} onSpecies={onSpecies} />}
      {tab !== "species" && <PhotoList gen={s?.generation} status={tab === "pending" ? "pending" : "all"} onOpen={setOpen}
        empty={tab === "pending" ? t("library.pending_empty") : t("library.records_empty")} />}
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
  if (!items.length) return <p className="empty">{text ? t("library.not_found", { q: text }) : explore ? t("library.no_catalogue") : t("library.start_empty")}</p>;
  return (
    <>
      <ul className="ll-grid" aria-label={t("library.species_list")}>
        {items.map((x) => (
          <li key={x.key}><button className="ll-card" onClick={() => onSpecies(x.key)} aria-label={t("library.card_label", { name: label(x), what: x.seen ? t("library.card_obs", { n: x.observations }) : t("library.unseen") })}>
            <Thumb r={x.cover_ref} alt={label(x)} />
            <span className="ll-card-text"><PlainName zh={x.zh} en={x.en} sci={x.key} size="card" />
              <small className="ll-card-meta">{x.seen ? (x.observations ? t("library.card_meta", { obs: x.observations, photos: x.photos }) : t("library.none_in_range")) : t("library.unseen")}
                {!x.zh && x.en && t("library.no_zh")}</small>
              {x.seen && <small>{t("library.first_seen", { d: x.first_day ?? "" })}</small>}</span>
          </button></li>))}
      </ul>
      {total > items.length && <button className="btn" onClick={() => setN(n + 60)}>{t("library.more_species", { total })}</button>}
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
                : <span className="history-name">{x.reason ?? (x.level === "photo" ? t("library.no_bird_found") : t("library.pending"))}</span>}
                <span className="history-meta">{x.day}{x.date_source?.startsWith("identified") ? t("library.fallback_date") : ""}
                  {x.lat != null && x.lon != null ? <> · <PlaceName lat={x.lat} lon={x.lon} name={x.place_label ?? null} /></> : x.place_label ? ` · ${x.place_label}` : ""}{x.subjects && x.subjects > 1 ? t("library.subjects", { n: x.subjects }) : ""} · {x.kind === "photo" ? t("library.kind_photo") : x.kind === "single" ? t("library.kind_single") : t("library.kind_import")}</span></span>
            </button></li>))}
      </ul>
      {total > items.length && n < 100 && <button className="btn" onClick={() => setN(100)}>{t("library.more", { total })}</button>}
    </>
  );
}

function SpeciesPage({ sci, gen, onBack, onOpen, dialog }: { sci: string; gen?: number; onBack: () => void; onOpen: (r: Ref) => void; dialog: React.ReactNode }) {
  interface Detail {
    key: string; zh: string | null; en: string | null; family: string | null; genus: string; iucn: string | null; seen: boolean;
    first_day: string | null; last_day: string | null; scope: { observations: number; estimated_count: number; photos: number };
    months: number[]; places: { place_key: string; label: string | null; source: string; region_code: string | null; lat: number | null; lon: number | null; observations: number }[];
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
      <button className="btn link" onClick={onBack}>{t("library.back")}</button>
      {err && <p className="error-text" role="alert">{err}</p>}
      <h2 id="h-sp" tabIndex={-1} ref={head} className="ll-sp-title">{d ? <PlainName zh={d.zh} en={d.en} sci={d.key} size="hero" /> : sci}</h2>
      {d && <>
        {(d.family || !d.zh) && <p className="hint">{[!d.zh && t("library.no_zh_name"), d.family].filter(Boolean).join(" · ")}</p>}
        <p className="facts-inline">
          <span>{d.seen ? <>{t("library.first")} <strong>{d.first_day}</strong> · {t("library.latest")} <strong>{d.last_day}</strong></> : <strong>{t("library.unseen")}</strong>}</span>
          {d.iucn && <span>IUCN <strong>{iucnText(d.iucn)}</strong>{t("library.paren", { x: d.iucn })}</span>}
          <span>{t("library.observations")} <strong>{d.scope.observations}</strong></span><span title={ESTIMATE_NOTE()}>{t("library.estimated")} <strong>{d.scope.estimated_count}</strong></span>
          <span>{t("library.photos")} <strong>{d.scope.photos}</strong></span>
        </p>
        <div className="result-section"><h3>{t("library.by_month")}</h3>
          <ol className="ll-months" aria-label={t("library.by_month_label")}>
            {d.months.map((v, i) => <li key={i} title={t("library.month_count", { m: i + 1, n: v })}><span style={{ height: `${(v / max) * 100}%` }} /><small>{i + 1}</small><b className="sr-only">{t("library.month_count_sr", { m: i + 1, n: v })}</b></li>)}
          </ol></div>
        <div className="result-section"><h3>{t("library.places")}</h3>
          {d.places.length ? <ul className="ll-places">{d.places.map((p) => <li key={p.place_key}>
            {p.place_key === "none" ? t("library.place_unknown_note", { note: NO_PLACE_NOTE() }) : p.region_code ? <>{regionLabel(p.label, p.region_code)}{t("library.region_only", { code: p.region_code })}</>
              : p.lat != null && p.lon != null ? <PlaceName lat={p.lat} lon={p.lon} name={p.label} /> : (p.label || p.place_key)}
            <small>{t("library.place_count", { n: p.observations })}</small></li>)}</ul> : <p className="hint">{t("library.no_obs")}</p>}</div>
        <div className="result-section"><h3>{t("library.photos_head", { n: d.total_photos, more: d.total_photos > 50 ? t("library.photos_recent") : "" })}</h3>
          {d.photo_refs.length ? <ul className="ll-gallery">{d.photo_refs.map((r) => <li key={r.asset_hash}>
            <button onClick={() => onOpen(r)} aria-label={t("library.open_day", { d: r.day ?? "" })}><Thumb r={r} alt="" /><small>{r.day}</small></button></li>)}</ul>
            : <p className="hint">{t("library.no_own_photos")}</p>}</div>
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
      setMsg(t("library.saved")); onChanged();
    } catch (e) {
      const m = String((e as Error).message);
      setMsg((e as Error & { status?: number }).status === 409 ? `${m}${t("library.keep_input")}` : m);
    } finally { setBusy(false); }
  };
  const bird = r.subject_id !== "photo";
  const openScan = async () => {
    const p = await get<{ scan_id: number }>(`/api/photos/${r.id}`);
    location.href = `?scan=${p.scan_id}`;
  };
  return (
    <dialog ref={ref} className="map-dlg" onClose={onClose} aria-labelledby="ev-title">
      <div className="dlg-head"><h3 id="ev-title">{r.day ?? t("library.photo")}{r.sci ? ` · ${r.sci}` : ""}</h3>
        {r.kind === "photo" && <button className="btn" onClick={openScan}>{t("library.open_in_batch")}</button>}
        <button className="btn" onClick={() => ref.current?.close()}>{t("library.close")}</button></div>
      <div className="dlg-body ll-ev">
        <img className="ll-ev-img" src={preview(r)} alt={t("library.preview_alt")} />
        <div>
          <p className="hint">{r.kind === "import" ? t("library.import_note") : t("library.edit_note")}</p>
          {bird && <div className="result-section"><h3>{t("library.fix_species")}</h3>
            <input className="map-search" placeholder={t("library.search")} value={find} onChange={(e) => setFind(e.target.value)} />
            <ul className="correct-list">{hits.map((h) => <li key={h.sci}><button type="button" disabled={busy}
              onClick={() => send({ op: "species", state: "species", key: h.sci })}><PlainName zh={h.zh} en={h.en} sci={h.sci} size="row" /></button></li>)}</ul>
            <div className="row"><button className="btn" disabled={busy} onClick={() => send({ op: "species", state: "uncertain", key: null })}>{t("library.mark_uncertain")}</button>
              <button className="btn" disabled={busy} onClick={() => send({ op: "species", state: "none", key: null })}>{t("library.auto_species")}</button></div></div>}
          {bird && <div className="result-section"><h3>{t("library.count")}</h3>
            <div className="row"><input type="number" min={1} max={999998} value={count} onChange={(e) => setCount(e.target.value)} aria-label={t("library.count_label")} />
              <button className="btn" disabled={busy || !(+count >= 1 && +count <= 999998)} onClick={() => send({ op: "count", value: Math.round(+count) })}>{t("library.save_count")}</button>
              <button className="btn link" disabled={busy} onClick={() => send({ op: "count", value: null })}>{t("library.auto_count")}</button></div>
            <div className="row" style={{ marginTop: 8 }}><button className="btn" disabled={busy} onClick={() => send({ op: "exclude", value: true })}>{t("library.exclude")}</button>
              <button className="btn link" disabled={busy} onClick={() => send({ op: "exclude", value: false })}>{t("library.unexclude")}</button></div></div>}
          <div className="result-section"><h3>{t("library.date_head")}</h3>
            <div className="row"><input type="date" value={day} onChange={(e) => setDay(e.target.value)} aria-label={t("library.date_label")} />
              <button className="btn" disabled={busy || !day} onClick={() => send({ op: "date", value: { wall: day, offset_min: null } })}>{t("library.save_date")}</button>
              <button className="btn link" disabled={busy} onClick={() => send({ op: "date", value: null })}>{t("library.photo_date")}</button></div></div>
          <div className="result-section"><h3>{t("library.place_head")}</h3>
            <LocationPicker value={place} onChange={setPlace} catalogue={catalogue} compact />
            <div className="row" style={{ marginTop: 8 }}>
              <button className="btn" disabled={busy || !place} onClick={() => place && send({ op: "place", value: place.source === "region"
                ? { source: "region", lat: null, lon: null, label: place.label, region_code: place.code ?? null }
                : { source: place.source, lat: place.lat, lon: place.lon, label: place.label, region_code: null } })}>{t("library.save_place")}</button>
              <button className="btn link" disabled={busy} onClick={() => send({ op: "place", value: { source: "none", lat: null, lon: null, label: "", region_code: null } })}>{t("library.no_place")}</button>
              <button className="btn link" disabled={busy} onClick={() => send({ op: "place", value: null })}>{t("library.orig_place")}</button></div></div>
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
  const tile = (n: number | undefined, name: string, onClick?: () => void, title?: string, cls = "") => (
    <button className={`ll-metric ${cls}`} onClick={onClick} disabled={!onClick} title={title}><b>{n ?? "–"}</b><small>{name}</small></button>);
  return (
    <section className="ll" aria-labelledby="h-stats">
      <div className="topbar"><div><h2 id="h-stats">{t("stats.title")}</h2><span className="sub">{rg.text}</span></div>
        <div className="row">
          <div className="seg" role="radiogroup" aria-label={t("stats.range")}>
            {([["month", t("stats.month")], ["year", t("stats.year")], ["all", t("stats.all")]] as const).map(([k, name]) => (
              <label key={k}><input type="radio" name="ll-period" checked={p.kind === k} onChange={() => { setP({ ...today(), kind: k }); setList(null); }} /><span>{name}</span></label>))}
          </div>
          {p.kind !== "all" && <><button className="btn" onClick={() => setP(shift(p, -1))} aria-label={t("stats.prev")}>‹</button>
            <button className="btn" onClick={() => setP(shift(p, 1))} aria-label={t("stats.next")}>›</button></>}
        </div></div>
      <Updating s={s} err={err} />
      <div className="ll-metrics">
        {tile(m?.species, t("stats.species"), () => setList({ kind: "species" }))}
        {tile(m?.observations, t("stats.obs"), () => setList({ kind: "obs" }), t("stats.obs_title"))}
        {tile(m?.estimated_count, t("stats.estimated"), () => setList({ kind: "obs" }), ESTIMATE_NOTE())}
        {tile(m?.new_species, t("stats.new"), undefined, t("stats.new_title"), "new")}
      </div>
      {m && <p className="hint">{t("stats.line", { photos: m.photos, pending: m.pending_subjects, pending_photos: m.pending_photos, no_bird: m.no_bird_photos, days: m.active_days })}
        {s!.coverage.fallback_date_photos > 0 && t("stats.fallback", { n: s!.coverage.fallback_date_photos })}
        {s!.coverage.no_place_photos > 0 && t("stats.no_place", { n: s!.coverage.no_place_photos, note: NO_PLACE_NOTE() })}
        {s!.coverage.region_only_photos > 0 && t("stats.region_only", { n: s!.coverage.region_only_photos })}{t("stats.estimate_tail", { note: ESTIMATE_NOTE() })}</p>}
      {m && m.species === 0 && <p className="empty">{t("stats.none")}{m.pending_subjects ? t("stats.none_pending", { n: m.pending_subjects }) : ""}</p>}
      {m && <div className="ll-rarity">
        <button className="btn link" onClick={() => setList({ kind: "obs", rare: true })}>{t("stats.rare_obs")}<b>{m.rare_observations}</b></button>
        <span>{t("stats.threatened")}<b>{m.threatened_species}</b></span>
        <span className="hint">{t("stats.buckets")}{Object.entries(s!.rarity_buckets).map(([k, v]) => `${rarityText(k)} ${v}`).join(" · ")}</span>
      </div>}
      {list && <div className="result-section">
        <div className="row"><h3>{list.kind === "species" ? t("stats.list_species") : list.rare ? t("stats.list_rare") : list.day ? t("stats.list_day", { d: list.day }) : t("stats.list_obs")}</h3>
          <button className="btn link" onClick={() => setList(null)}>{t("stats.fold")}</button></div>
        {list.kind === "species" ? <SpeciesGrid gen={s?.generation} text="" explore={false} sort="recent" onSpecies={onSpecies} from={rg.from} to={rg.to} />
          : <ObsList gen={s?.generation} from={list.day ?? rg.from} to={list.day ?? rg.to} rare={list.rare} onSpecies={onSpecies} onOpen={setOpen} onChanged={reload} />}
      </div>}
      <div className="ll-lower">{/* calendar beside the map and the data tools on a wide window */}
        <Calendar p={p} gen={s?.generation} onDay={(d) => setList({ kind: "obs", day: d })} onMonth={(y, m) => { setP({ kind: "month", y, m }); setList(null); }} />
        <div><MapView from={rg.from} to={rg.to} gen={s?.generation} onOpen={setOpen} />
          <DataTools from={rg.from} to={rg.to} gen={s?.generation} onChanged={reload} /></div>
      </div>
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
  if (!items.length) return <p className="empty">{t("library.no_obs")}</p>;
  return (
    <>
      {msg && <p className="error-text" role="alert">{msg}</p>}
      <ul className="ll-obs">
        {items.map((o) => (
          <li key={o.key}>
            <div className="ll-obs-refs">{o.source_refs.slice(0, 3).map((r) => <button key={r.asset_hash + r.subject_id} onClick={() => onOpen({ ...r, day: o.day, sci: o.sci })} aria-label={t("obs.open_photo")}><Thumb r={r} alt="" /></button>)}</div>
            <div>
              <button className="ll-obs-name" onClick={() => onSpecies(o.sci)}><PlainName zh={o.zh} en={o.en} sci={o.sci} size="row" /></button>
              {o.first_seen && <span className="pill">{t("obs.new")}</span>}{o.rare && <span className="pill rare">{t("obs.local", { r: rarityText(o.contexts.find((c) => c.tier === 1) ? "罕见" : "少见") })}</span>}
              <span className="history-meta">{o.day} · {o.place_key === "none" ? t("obs.place_unknown") : o.place.region_code ? <>{regionLabel(o.place.label, o.place.region_code)}{t("obs.region")}</>
                : o.place.points.length ? <PlaceName lat={o.place.points[0][0]} lon={o.place.points[0][1]} name={o.place.label} /> : o.place.label ?? o.place_key}
                {" · "}{t("obs.photos_est", { n: o.photo_count, e: o.estimate })}{o.estimate_source === "edit" ? t("obs.edited", { max: o.max_in_photo }) : ""}
                {o.fallback_date ? t("obs.no_date") : ""}{t("obs.rarity")}{o.contexts.map((c) => rarityText(c.label) + (c.note ? t("library.paren", { x: rarityText(c.note) }) : "")).join(" / ")}</span>
              <span className="row ll-count"><input type="number" min={1} max={999998} aria-label={t("obs.count_label")} placeholder={String(o.estimate)}
                value={edit[o.key] ?? ""} onChange={(e) => setEdit({ ...edit, [o.key]: e.target.value })} />
                <button className="btn slim" disabled={!(+edit[o.key] >= 1 && +edit[o.key] <= 999998)} onClick={() => save(o, Math.round(+edit[o.key]))}>{t("obs.set_count")}</button>
                {o.estimate_source === "edit" && <button className="btn link" onClick={() => save(o, null)}>{t("obs.max_count")}</button>}
                {+edit[o.key] > 0 && +edit[o.key] < o.max_in_photo && <small className="hint">{t("obs.below_max", { max: o.max_in_photo })}</small>}</span>
            </div>
          </li>))}
      </ul>
      {total > items.length && <p className="hint">{t("obs.shown", { n: items.length, total })}</p>}
    </>
  );
}

// Photo-first calendar (owner, 2026-11-18): the day's bird, not a colour level. Cover = the latest eligible bird of
// the day by wall time, then photo hash, then subject id (engine: library.cover_of); its square crop is cached.
interface CalCell { observations: number; species: number; cover: (Ref & { crop: string; sci: string; zh: string | null; en: string | null }) | null }
function CoverCell({ c, text, big }: { c: CalCell; text: string; big?: boolean }) {
  const [ok, setOk] = useState(true);
  const name = c.cover ? (c.cover.zh || c.cover.en || c.cover.sci) : "";
  return ok && c.cover ? <><img src={c.cover.crop} alt={`${name}${c.species > 1 ? t("cal.more_species", { n: c.species }) : ""}`} loading="lazy" onError={() => setOk(false)} />
    {!big && c.species > 1 && <span className="ll-badge" aria-hidden="true">{c.species}</span>}<span className="ll-cal-n">{text}</span></>
    : <><span className="ll-cal-count">{t("cal.species", { n: c.species })}</span><span className="ll-cal-n">{text}</span></>;   // no picture (volume not mounted)
}

function Calendar({ p, gen, onDay, onMonth }: { p: Period; gen?: number; onDay: (d: string) => void; onMonth: (y: number, m: number) => void }) {
  const [year, setYear] = useState(p.y);
  const [cal, setCal] = useState<{ days: Record<string, CalCell>; months: (CalCell & { month: number })[]; active_days: number; years: string[] } | null>(null);
  useEffect(() => { setYear(p.kind === "all" ? new Date().getFullYear() : p.y); }, [p.kind, p.y]);
  useEffect(() => { if (gen !== undefined) get<typeof cal>(`/api/library/calendar?year=${p.kind === "month" ? p.y : year}`).then(setCal).catch(() => setCal(null)); }, [year, gen, p.kind, p.y]);
  if (!cal) return null;
  const label = (c: CalCell) => c.cover ? t("cal.label", { name: c.cover.zh || c.cover.en || c.cover.sci, more: c.species > 1 ? t("cal.more_species", { n: c.species }) : "", obs: c.observations }) : "";
  if (p.kind === "month") {
    const first = new Date(p.y, p.m - 1, 1), lead = (first.getDay() + 6) % 7, n = new Date(p.y, p.m, 0).getDate();
    return (<div className="result-section"><h3>{t("cal.title")}</h3>
      <div className="ll-month" aria-label={t("cal.month_label", { y: p.y, m: p.m })}>
        {t("cal.weekdays").split(",").map((w) => <span key={w} className="ll-wd">{w}</span>)}
        {Array.from({ length: lead }, (_, i) => <span key={`x${i}`} />)}
        {Array.from({ length: n }, (_, i) => {
          const k = `${p.y}-${pad(p.m)}-${pad(i + 1)}`, c = cal.days[k];
          return c ? <button key={k} className="ll-cal has" onClick={() => onDay(k)} aria-label={t("cal.day", { k, label: label(c) })} title={t("cal.day", { k, label: label(c) })}>
            <CoverCell c={c} text={String(i + 1)} /></button>
            : <span key={k} className="ll-cal"><span className="ll-cal-n">{i + 1}</span></span>;
        })}
      </div></div>);
  }
  return (<div className="result-section"><div className="row"><h3>{t("cal.year", { y: year })}</h3>
    {p.kind === "all" && <select value={year} onChange={(e) => setYear(+e.target.value)} aria-label={t("cal.year_label")}>
      {[...new Set([...cal.years, String(new Date().getFullYear())])].sort().map((y) => <option key={y}>{y}</option>)}</select>}
    <small className="hint">{t("cal.active_days", { n: cal.active_days })}</small></div>
    <ol className="ll-year-tiles">{cal.months.map((c) => (
      <li key={c.month}>{c.observations ? <button className="ll-cal has big" onClick={() => onMonth(year, c.month)} aria-label={t("cal.month_tile", { y: year, m: c.month, species: c.species, obs: c.observations, label: label(c) })}>
        <CoverCell c={c} text={t("cal.month", { m: c.month })} big /></button> : <span className="ll-cal big"><span className="ll-cal-n">{t("cal.month", { m: c.month })}</span></span>}
        <small>{c.observations ? t("cal.month_meta", { species: c.species, obs: c.observations }) : t("cal.no_records")}</small></li>))}</ol></div>);
}

function MapView({ from, to, gen, onOpen }: { from: string | null; to: string | null; gen?: number; onOpen: (r: Ref) => void }) {
  const box = useRef<HTMLDivElement>(null);
  const [shown, setShown] = useState(false);
  const [info, setInfo] = useState<{ regions: { code: string; observations: number }[]; no_place_observations: number; truncated: boolean } | null>(null);
  const [tiles, setTiles] = useState<boolean | null>(null);
  const [pick, setPick] = useState<(Ref & { lat: number; lon: number; zh: string | null; en: string | null })[]>([]);
  useEffect(() => {
    if (!shown || gen === undefined) return;
    let dead = false, map: { remove: () => void } | null = null;
    Promise.all([import("leaflet"), import("leaflet/dist/leaflet.css")]).then(([mod]) => {
      if (dead || !box.current) return;
      const L = mod.default;
      const m = L.map(box.current, { worldCopyJump: true }).setView([20, 0], 2);
      const tl = L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 18,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors' });
      tl.on("tileload", () => setTiles(true)); tl.on("tileerror", () => setTiles((ok) => ok ?? false)); tl.addTo(m);
      const layer = L.layerGroup().addTo(m);
      let first = true;
      const load = () => {
        const b = m.getBounds(), w = ((b.getWest() + 540) % 360) - 180, e = ((b.getEast() + 540) % 360) - 180;
        const span = b.getEast() - b.getWest() >= 360;
        const bounds = [Math.max(-90, b.getSouth()), span ? -180 : w, Math.min(90, b.getNorth()), span ? 180 : e].map((x) => x.toFixed(5)).join(",");
        get<{ clusters: { lat: number; lon: number; observations: number; refs: (Ref & { lat: number; lon: number; zh: string | null; en: string | null })[] }[]; regions: { code: string; observations: number }[]; no_place_observations: number; truncated: boolean }>(
          `/api/library/map?${q({ bounds, from, to })}`).then((r) => {
          if (dead) return;
          layer.clearLayers(); setInfo(r);
          for (const c of r.clusters) {
            L.marker([c.lat, c.lon], { icon: L.divIcon({ className: "ll-pin", html: `<span>${c.observations}</span>`, iconSize: [30, 30] }),
              title: t("map.pin", { n: c.observations }) }).on("click", () => setPick(c.refs)).addTo(layer);
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
    <div className="result-section"><div className="row"><h3>{t("map.title")}</h3>
      {!shown && <button className="btn" onClick={() => setShown(true)}>{t("map.open")}</button>}</div>
      {!shown && <p className="hint">{t("map.note")}</p>}
      {shown && <>
        <div ref={box} className="map-box ll-map" aria-label={t("map.label")} />
        {tiles === false && <p className="hint">{t("map.offline")}</p>}
        {pick.length > 0 && <div className="ll-gallery">{pick.map((r) => <button key={r.asset_hash + r.subject_id} onClick={() => onOpen(r)}>
          <Thumb r={r} alt="" /><PlainName zh={r.zh} en={r.en} sci={r.sci ?? ""} size="card" /><small>{r.day}</small>
          {/* each photo's own place: a cluster's centre at a low zoom is no place at all */}
          <small className="ll-pick-place"><PlaceName lat={r.lat} lon={r.lon} /></small></button>)}</div>}
        {info && <p className="hint">{info.truncated ? t("map.truncated") : ""}
          {info.regions.length > 0 && t("map.regions", { list: info.regions.map((x) => `${x.code} ${x.observations}`).join(" · ") })}
          {info.no_place_observations > 0 && t("map.no_place", { n: info.no_place_observations, note: NO_PLACE_NOTE() })}</p>}
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
    setMsg(t("data.checking")); setPv(null);
    try { const fd = new FormData(); fd.append("file", f); setPv(await upload("/api/library/import/preview", fd)); setMsg(""); }
    catch (e) { setMsg(String((e as Error).message)); }
  };
  const apply = async () => {
    try {
      const r = await post<{ added_photos: number; merged_photos: number; pending_conflicts: number }>("/api/library/import/apply",
        { token: pv!.token, mode: "merge", choices, expected_generation: gen });
      setMsg(t("data.imported", { added: r.added_photos, merged: r.merged_photos, conflicts: r.pending_conflicts ? t("data.conflicts", { n: r.pending_conflicts }) : "" }));
      setPv(null); onChanged();
    } catch (e) { setMsg(String((e as Error).message)); }
  };
  return (
    <div className="result-section"><h3>{t("data.title")}</h3>
      <div className="row">
        <a className="btn" href={`/api/library/export?${q({ from, to })}`} download>{from ? t("data.export_range") : t("data.backup")}</a>
        <label className="btn">{t("data.import")}<input type="file" accept=".birdcm" hidden onChange={(e) => choose(e.target.files?.[0])} /></label>
      </div>
      <p className="hint">{t("data.note")}</p>
      {pv && <div className="missing soft" role="status">
        {t("data.preview", { records: String(pv.summary.records), new: String(pv.summary.new_photos), same: String(pv.summary.identical_photos),
          missing: String(pv.summary.missing_originals), mb: Math.ceil(+pv.summary.required_bytes / 1e6) })}
        {pv.conflicts.map((c) => <label key={c.id} className="row">{t("data.conflict", { field: c.field, local: JSON.stringify(c.local), file: JSON.stringify(c.file) })}
          <select value={choices[c.id] ?? "local"} onChange={(e) => setChoices({ ...choices, [c.id]: e.target.value as "local" | "file" })}>
            <option value="local">{t("data.keep_local")}</option><option value="file">{t("data.use_file")}</option></select></label>)}
        <div className="row"><button className="btn primary" onClick={apply}>{t("data.merge")}</button><button className="btn link" onClick={() => setPv(null)}>{t("data.cancel")}</button></div>
      </div>}
      <div className="row" style={{ marginTop: 10 }}>
        <button className="btn" onClick={ebird}>{t("data.ebird")}</button>
        <label className="inline"><input type="checkbox" checked={est} onChange={(e) => setEst(e.target.checked)} /> {t("data.estimates")}</label>
        <label className="inline">{t("data.no_date")} <select value={fallback} onChange={(e) => setFallback(e.target.value as typeof fallback)}>
          <option value="refuse">{t("data.refuse")}</option><option value="include">{t("data.include")}</option><option value="exclude">{t("data.exclude")}</option></select></label>
      </div>
      <p className="hint">{t("data.ebird_note")}</p>
      {msg && <p className="hint" role="status">{msg}</p>}
    </div>
  );
}
