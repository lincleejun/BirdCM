import { StrictMode, useCallback, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { get, post, useEngine } from "./api";
import Results, { STATE_LABEL } from "./Results";
import Singles from "./Singles";
import KeepControl, { DEFAULT_KEEP, type KeepSetting } from "./Keep";
import LocationPicker, { type Country, rememberedPlace } from "./Location";
import { Records, Stats } from "./Library";
import type { ModelStatus, Place, Scan } from "./types";
import "./styles.css";

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
        <p className="kicker">批量选片</p>
        <h2 id="h-start">选一批鸟片</h2>
        <p className="intro">从一批原片里找鸟、认种，挑出值得细看的照片。</p>
        {models && !models.ready && (
          <div className="missing" role="alert">缺模型文件：{models.missing.join("、")}。<br />{models.fetch_hint ?? `在终端运行 ${models.fetch}`}，下载后刷新。</div>
        )}
        {models && models.ready && (models.optional_missing?.length ?? 0) > 0 && (
          <div className="missing soft" role="status">
            {models.optional_missing!.filter((o) => !o.released).length > 0 && <>这 {models.optional_missing!.filter((o) => !o.released).length} 个文件还没有发布，先不用它们：<br /></>}
            {models.optional_missing!.map((o) => <span key={o.name}>· {o.effect}<br /></span>)}
          </div>
        )}
        {models && !models.exiftool && (
          <div className="missing" role="alert">找不到 exiftool，拍摄信息和对焦点会是空的。运行 <code>brew install exiftool</code> 安装。</div>
        )}
        <div className="field">
          <label className="label" htmlFor="folder">照片文件夹</label>
          <div className="row">
            <input id="folder" className="folder-input" placeholder="/Volumes/… · ARW、DNG、JPG" value={folder} onChange={(e) => setFolder(e.target.value)} />
            <button className="btn" onClick={pick}>选择文件夹</button>
          </div>
          <label className="row hint" style={{ marginTop: 10 }}><input type="checkbox" checked={sub} onChange={(e) => setSub(e.target.checked)} /> 包含子文件夹</label>
        </div>
        <div className="field">
          <span className="label">拍摄地点</span>
          <LocationPicker value={place} onChange={setPlace} catalogue={catalogue} />
          <p className="hint">照片自带 GPS 时以照片为准；没有 GPS 的照片用这里的位置和拍摄日期修正鸟种。不选也能扫，只凭图像。</p>
        </div>
        <div className="field">
          <span className="label" id="lb-ratio">留片比例（有星的照片占比）</span>
          <KeepControl value={keep} onChange={setKeep} />
          <p className="hint">大约 {keep.keep}% 的照片会有星（一、二、三星合计），其余 0 星。几星看照片本身好不好，不按名额分；
            同一种鸟、同一组连拍拍得越多，越不容易全拿星。照片整体一般时会少于这个比例。扫完后还能改，不用重扫。</p>
        </div>
        <div className="go">
          <button className="btn primary big" disabled={!folder.trim() || busy} onClick={go}>开始</button>
          {err && <p className="error-text" role="alert">{err}</p>}
          <p className="note">全部在这台电脑上处理，不上传，也不改动原片。</p>
        </div>
        {scans.length > 0 && (
          <div className="recent"><span className="label">最近的扫描</span>
            {scans.slice(0, 6).map((s) => (
              <div key={s.id} className="recent-row">
                <button onClick={() => onOpen(s.id)}>
                  {s.folder} · {s.counts.total} 张 · {STATE_LABEL[s.state]}
                  {["running", "queued", "stopping", "finalizing"].includes(s.state) && `（已完成 ${s.counts.done + s.counts.failed} / ${s.counts.total}）`}
                  {s.previous?.length ? ` · 之前扫过 ${s.previous.length} 次` : ""}
                </button>
                {s.last_completed && <button className="btn link" onClick={() => onOpen(s.last_completed!)}>上次完成的结果</button>}
              </div>
            ))}
          </div>
        )}
      </section>
      <aside className="hero" aria-label="示例照片">
        {heroOk ? (
          <figure>
            <div className="hero-frame"><div className="ph"><img src="/hero.jpg" alt="掠过水面的角鸬鹚" onError={() => setHeroOk(false)} /></div></div>
            <figcaption><h3>角鸬鹚</h3><small>索尼 α7 IV · 湿地公园</small></figcaption>
            <div className="settings"><span>600 mm</span> <span>f/6.3</span> <span>1/1000 s</span> <span>ISO 250</span> <span>0 EV</span></div>
          </figure>
        ) : (
          // a public clone has no sample photo (it is the author's own): an original mark instead of a broken image
          <div className="hero-mark">
            <svg viewBox="0 0 200 200" aria-hidden="true">
              <circle cx="100" cy="100" r="92" fill="none" stroke="currentColor" strokeOpacity=".35" />
              <circle cx="100" cy="100" r="58" fill="none" stroke="currentColor" strokeOpacity=".55" />
              <path d="M40 112 C70 70 105 64 128 80 C140 66 158 62 172 66 C160 72 152 80 148 92 C136 120 96 132 40 112 Z" fill="currentColor" fillOpacity=".85" />
              <circle cx="141" cy="76" r="2.6" fill="var(--mat)" />
            </svg>
            <p className="hero-name">观羽</p>
            <p className="hero-tag">找鸟 · 认种 · 挑出值得细看的那一张</p>
          </div>
        )}
      </aside>
    </div>
  );
}

/** Top bar: the models load in the background after a start; work sent meanwhile waits for them, nothing else does. */
function EngineBadge() {
  const s = useEngine();
  const [asked, setAsked] = useState(false);
  useEffect(() => setAsked(false), [s]);             // every poll answers the click (a failed reload is quick)
  if (!s) return null;
  if (s.engine === "ready") return <span className="engine ok" role="status" title="模型已加载，识别会立刻开始">模型就绪</span>;
  if (s.engine === "loading" || asked) return <span className="engine busy" role="status" title="页面可以照常使用；这时开始的识别会排队，加载完自动开始">模型准备中…</span>;
  return (
    <span className="engine bad" role="alert" title={s.load_error ?? ""}>模型出错
      <button type="button" onClick={() => { setAsked(true); post("/api/models/retry").catch(() => setAsked(false)); }}>重试</button>
    </span>
  );
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
    <nav className="views" aria-label="视图">
      <button aria-current={view === "batch"} onClick={() => switchTo("batch")}>批量选片</button>
      <button aria-current={view === "single"} onClick={() => switchTo("single")}>认一张</button>
      <button aria-current={view === "library"} onClick={() => switchTo("library")}>记录</button>
      <button aria-current={view === "stats"} onClick={() => switchTo("stats")}>统计</button>
      <EngineBadge />
    </nav>
  );
  const results = view === "batch" && scanId;
  return (
    <>
      {!results && (
        <header className="masthead">
          <div className="masthead-inner">
            <div className="brand"><span className="emblem" aria-hidden="true"></span><h1>观羽</h1><small>桌面审片</small></div>
            {nav}
          </div>
        </header>
      )}
      <main className={results ? "res-main" : undefined}>{view === "single" ? <Singles catalogue={catalogue} />
        : view === "library" ? <Records catalogue={catalogue} sci={sci} onSpecies={species} />
        : view === "stats" ? <Stats catalogue={catalogue} onSpecies={species} />
        : scanId ? <Results key={scanId} scanId={scanId} onBack={() => open(null)} onOpen={open} catalogue={catalogue} nav={nav}
          brand={<div className="brand"><span className="emblem" aria-hidden="true"></span><h1>观羽</h1></div>} /> : <Setup onOpen={open} catalogue={catalogue} />}</main>
    </>
  );
}

createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
