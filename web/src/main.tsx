import { StrictMode, useCallback, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { get, post, useEngine } from "./api";
import Results, { stateLabel } from "./Results";
import Singles from "./Singles";
import KeepControl, { DEFAULT_KEEP, type KeepSetting } from "./Keep";
import LocationPicker, { type Country, rememberedPlace } from "./Location";
import { Records, Stats } from "./Library";
import type { ModelStatus, Place, Scan } from "./types";
import "./styles.css";
import { getLang, setLang, t } from "./i18n";

function Setup({ onOpen, catalogue }: { onOpen: (id: number) => void; catalogue: Country[] }) {
  const [place, setPlace] = useState<Place | null>(rememberedPlace);
  const [folder, setFolder] = useState("");
  const [sub, setSub] = useState(false);
  const [keep, setKeep] = useState<KeepSetting>(DEFAULT_KEEP);
  const [models, setModels] = useState<ModelStatus | null>(null);
  const [scans, setScans] = useState<Scan[]>([]);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    get<ModelStatus>("/api/models").then(setModels).catch(() => {});
    const poll = () => get<Scan[]>("/api/scans").then(setScans).catch(() => {});
    poll();
    const t = window.setInterval(poll, 2000);           // scans in progress show live progress here
    return () => clearInterval(t);
  }, []);

  const ratio = keep;
  const pick = async () => {
    setErr("");
    try {
      const r = await post<{ folder: string | null }>("/api/pick-folder");
      if (r.folder) setFolder(r.folder);
    } catch (e) { setErr(String((e as Error).message)); }
  };
  const go = async () => {
    setBusy(true); setErr("");
    try {
      const r = await post<{ id: number }>("/api/scans", { folder: folder.trim(), recursive: sub, region: place, ratio });
      onOpen(r.id);
    } catch (e) { setErr(String((e as Error).message)); setBusy(false); }
  };

  const [heroOk, setHeroOk] = useState(true);
  return (
    <div id="setup" className="workbench">
      <section className="setup" aria-labelledby="h-start">
        <p className="kicker">{t("nav.batch")}</p>
        <h2 id="h-start">{t("setup.title")}</h2>
        <p className="intro">{t("setup.intro")}</p>
        {models && !models.ready && (
          <div className="missing" role="alert">{t("setup.models_missing", { names: models.missing.join(t("setup.list_sep")) })}<br />{models.fetch_hint ?? t("setup.run_in_terminal", { cmd: models.fetch })}{t("setup.refresh_after")}</div>
        )}
        {models && models.ready && (models.optional_missing?.length ?? 0) > 0 && (
          <div className="missing soft" role="status">
            {models.optional_missing!.filter((o) => !o.released).length > 0 && <>{t("setup.unreleased", { n: models.optional_missing!.filter((o) => !o.released).length })}<br /></>}
            {models.optional_missing!.map((o) => <span key={o.name}>· {o.effect}<br /></span>)}
          </div>
        )}
        {models && !models.exiftool && (
          <div className="missing" role="alert">{t("setup.no_exiftool")}<code>brew install exiftool</code>{t("setup.no_exiftool_after")}</div>
        )}
        <div className="field">
          <label className="label" htmlFor="folder">{t("setup.folder")}</label>
          <div className="row">
            <input id="folder" className="folder-input" placeholder={t("setup.folder_ph")} value={folder} onChange={(e) => setFolder(e.target.value)} />
            <button className="btn" onClick={pick}>{t("setup.pick")}</button>
          </div>
          <label className="row hint" style={{ marginTop: 10 }}><input type="checkbox" checked={sub} onChange={(e) => setSub(e.target.checked)} /> {t("setup.subfolders")}</label>
        </div>
        <div className="field">
          <span className="label">{t("setup.place")}</span>
          <LocationPicker value={place} onChange={setPlace} catalogue={catalogue} />
          <p className="hint">{t("setup.place_hint")}</p>
        </div>
        <div className="field">
          <span className="label" id="lb-ratio">{t("setup.ratio")}</span>
          <KeepControl value={keep} onChange={setKeep} />
          <p className="hint">{t("setup.ratio_hint", { keep: keep.keep })}</p>
        </div>
        <div className="go">
          <button className="btn primary big" disabled={!folder.trim() || busy} onClick={go}>{t("setup.start")}</button>
          {err && <p className="error-text" role="alert">{err}</p>}
          <p className="note">{t("setup.note")}</p>
        </div>
        {scans.length > 0 && (
          <div className="recent"><span className="label">{t("setup.recent")}</span>
            {scans.slice(0, 6).map((s) => (
              <div key={s.id} className="recent-row">
                <button onClick={() => onOpen(s.id)}>
                  {t("setup.recent_row", { folder: s.folder, n: s.counts.total, state: stateLabel(s.state) })}
                  {["running", "queued", "stopping", "finalizing"].includes(s.state) && t("setup.recent_done", { done: s.counts.done + s.counts.failed, n: s.counts.total })}
                  {s.previous?.length ? t("setup.recent_before", { n: s.previous.length }) : ""}
                </button>
                {s.last_completed && <button className="btn link" onClick={() => onOpen(s.last_completed!)}>{t("setup.last_completed")}</button>}
              </div>
            ))}
          </div>
        )}
      </section>
      <aside className="hero" aria-label={t("setup.hero_label")}>
        {heroOk ? (
          <figure>
            <div className="hero-frame"><div className="ph"><img src="/hero.jpg" alt={t("setup.hero_alt")} onError={() => setHeroOk(false)} /></div></div>
            <figcaption><h3>{t("setup.hero_bird")}</h3><small>{t("setup.hero_where")}</small></figcaption>
            <div className="settings"><span>600 mm</span> <span>f/6.3</span> <span>1/1000 s</span> <span>ISO 250</span> <span>0 EV</span></div>
          </figure>
        ) : (
          // a public clone has no sample photo (it is the author's own): an original mark instead of a broken image
          <div className="hero-mark">
            <BrandMark size={160} />
            <p className="hero-name">{t("brand")}</p>
            <p className="hero-tag">{t("setup.tagline")}</p>
          </div>
        )}
      </aside>
    </div>
  );
}

/** The app icon's kingfisher (ios/design/icon/K1.svg) in its own deep-teal tile: the brand, not a UI colour. */
function BrandMark({ size = 30 }: { size?: number }) {
  return (
    <svg className="mark" width={size} height={size} viewBox="0 0 1024 1024" aria-hidden="true">
      <rect width="1024" height="1024" rx="224" fill="#123D46" />
      <path d="M 231 788 L 319 626 Q 290 521 350 407 L 335 326 Q 423 250 535 280 Q 618 297 648 371 L 872 422 L 648 452 Q 647 618 479 770 L 412 709 Z" fill="#3BA5AC" />
      <path d="M 357 479 Q 483 531 624 468 Q 625 630 479 770 L 412 709 Q 368 624 357 479 Z" fill="#DE8547" />
      <path d="M 374 423 Q 483 380 637 414 L 625 458 Q 489 492 374 458 Z" fill="#F4F1E8" />
      <path d="M 350 586 Q 340 501 432 477 Q 501 521 459 647 L 412 709 Z" fill="#102E2B" />
      <path d="M 650 388 L 872 422 L 650 428 Z" fill="#F4F1E8" />
      <circle cx="556" cy="366" r="47" fill="#102E2B" /><circle cx="542" cy="350" r="15" fill="#F4F1E8" />
    </svg>
  );
}

/** Top bar: the models load in the background after a start; work sent meanwhile waits for them, nothing else does. */
function EngineBadge() {
  const s = useEngine();
  const [asked, setAsked] = useState(false);
  useEffect(() => setAsked(false), [s]);             // every poll answers the click (a failed reload is quick)
  // 模型就绪 shows for a few seconds, then goes (owner 2026-11-19: 不要一直展示)
  const ready = s?.engine === "ready";
  const [readyShown, setReadyShown] = useState(true);
  useEffect(() => {
    setReadyShown(true);
    if (!ready) return;
    const t = setTimeout(() => setReadyShown(false), 3000);
    return () => clearTimeout(t);
  }, [ready]);
  if (!s || (ready && !readyShown)) return null;
  if (ready) return <span className="engine ok" role="status" title={t("engine.ready_title")}>{t("engine.ready")}</span>;
  if (s.engine === "loading" || asked) return <span className="engine busy" role="status" title={t("engine.loading_title")}>{t("engine.loading")}</span>;
  return (
    <span className="engine bad" role="alert" title={s.load_error ?? ""}>{t("engine.error")}
      <button type="button" onClick={() => { setAsked(true); post("/api/models/retry").catch(() => setAsked(false)); }}>{t("engine.retry")}</button>
    </span>
  );
}

// 检查更新 (engine/birdcm/update.py): off by default (物种参考's switches); when on, a quiet link to the Releases page if a
// newer release exists. Asked once per page load; any failure shows nothing.
interface Update { latest: string | null; newer: boolean; url: string }
let updateAsked: Promise<Update | null> | null = null;
function UpdateNote() {
  const [u, setU] = useState<Update | null>(null);
  useEffect(() => { (updateAsked ??= post<Update>("/api/update").catch(() => null)).then(setU); }, []);
  if (!u?.newer) return null;
  return <a className="pill update" href="https://github.com/lincleejun/BirdCM/releases" target="_blank" rel="noopener noreferrer"
    title={t("update.title")}>{t("update.new", { v: u.latest ?? "" })}</a>;
}

function App() {
  const q = new URLSearchParams(location.search);
  const [scanId, setScanId] = useState<number | null>(() => Number(q.get("scan")) || null);
  type View = "batch" | "single" | "library" | "stats";
  const [view, setView] = useState<View>(() => (["single", "library", "stats"].includes(q.get("view") ?? "") ? q.get("view") as View : "batch"));
  const [sci, setSci] = useState<string | null>(q.get("sci"));
  // one history entry per species page, so Back returns to the list (no router: the query string is the state)
  useEffect(() => {
    const pop = () => { const p = new URLSearchParams(location.search); setSci(p.get("sci")); if (p.get("view")) setView(p.get("view") as View); };
    window.addEventListener("popstate", pop);
    return () => window.removeEventListener("popstate", pop);
  }, []);
  const species = (s: string | null) => {
    if (s) history.pushState(null, "", `?view=library&sci=${encodeURIComponent(s)}`);
    else history.back();
    setView("library"); setSci(s); window.scrollTo(0, 0);
  };
  const [catalogue, setCatalogue] = useState<Country[]>([]);
  useEffect(() => { get<Country[]>("/api/regions").then(setCatalogue).catch(() => {}); }, []);
  const open = useCallback((id: number | null) => {
    history.replaceState(null, "", id ? `?scan=${id}` : location.pathname);
    setScanId(id);
    window.scrollTo(0, 0);
  }, []);
  const switchTo = (v: View) => {
    history.replaceState(null, "", v !== "batch" ? `?view=${v}` : scanId ? `?scan=${scanId}` : location.pathname);
    setView(v); setSci(null);
  };
  const nav = (
    <nav className="views" aria-label={t("nav.label")}>
      <button aria-current={view === "batch"} onClick={() => switchTo("batch")}>{t("nav.batch")}</button>
      <button aria-current={view === "single"} onClick={() => switchTo("single")}>{t("nav.single")}</button>
      <button aria-current={view === "library"} onClick={() => switchTo("library")}>{t("nav.library")}</button>
      <button aria-current={view === "stats"} onClick={() => switchTo("stats")}>{t("nav.stats")}</button>
      <EngineBadge />
      <UpdateNote />
      <button type="button" className="lang" lang={getLang() === "zh" ? "en" : "zh-CN"} title={t("lang.switch_title")}
        onClick={() => setLang(getLang() === "zh" ? "en" : "zh")}>{t("lang.switch")}</button>
    </nav>
  );
  const results = view === "batch" && scanId;
  return (
    <>
      {!results && (
        <header className="masthead">
          <div className="masthead-inner">
            <div className="brand"><BrandMark /><h1>{t("brand")}</h1><small>{t("brand.sub")}</small></div>
            {nav}
          </div>
        </header>
      )}
      <main className={results ? "res-main" : undefined}>{view === "single" ? <Singles catalogue={catalogue} />
        : view === "library" ? <Records catalogue={catalogue} sci={sci} onSpecies={species} />
        : view === "stats" ? <Stats catalogue={catalogue} onSpecies={species} />
        : scanId ? <Results key={scanId} scanId={scanId} onBack={() => open(null)} onOpen={open} catalogue={catalogue} nav={nav}
          brand={<div className="brand"><BrandMark /><h1>{t("brand")}</h1></div>} /> : <Setup onOpen={open} catalogue={catalogue} />}</main>
    </>
  );
}

createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
