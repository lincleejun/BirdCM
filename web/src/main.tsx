import { StrictMode, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { get, post } from "./api";
import Results, { STATE_LABEL } from "./Results";
import type { ModelStatus, Ratio, Scan } from "./types";
import "./styles.css";

const RATIOS: Record<string, [number, number] | null> = { loose: [40, 30], std: [30, 30], strict: [20, 30], stricter: [10, 20], custom: null };
const RATIO_LABEL: [string, string][] = [["loose", "宽松"], ["std", "标准"], ["strict", "严格"], ["stricter", "更严"], ["custom", "自定义"]];

function ratioOf(preset: string, c3: number, c2: number): Ratio {
  const fixed = RATIOS[preset];
  if (fixed) return { preset, p3: fixed[0], p2: fixed[1] };
  const p3 = Math.max(0, Math.min(100, c3 || 0));
  return { preset, p3, p2: Math.max(0, Math.min(100 - p3, c2 || 0)) };
}

function Setup({ onOpen }: { onOpen: (id: number) => void }) {
  const [regions, setRegions] = useState<Record<string, string[]>>({});
  const [country, setCountry] = useState("美国");
  const [state, setState] = useState("");
  const [folder, setFolder] = useState("");
  const [sub, setSub] = useState(false);
  const [preset, setPreset] = useState("std");
  const [c3, setC3] = useState(25);
  const [c2, setC2] = useState(30);
  const [models, setModels] = useState<ModelStatus | null>(null);
  const [scans, setScans] = useState<Scan[]>([]);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    get<Record<string, string[]>>("/api/regions").then((r) => { setRegions(r); setState(r["美国"]?.[0] ?? ""); });
    get<ModelStatus>("/api/models").then(setModels).catch(() => {});
    get<Scan[]>("/api/scans").then(setScans).catch(() => {});
  }, []);

  const ratio = ratioOf(preset, c3, c2);
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
      const r = await post<{ id: number }>("/api/scans", { folder: folder.trim(), recursive: sub, region: `${country} · ${state}`, ratio });
      onOpen(r.id);
    } catch (e) { setErr(String((e as Error).message)); setBusy(false); }
  };

  return (
    <div id="setup" className="workbench">
      <section className="setup" aria-labelledby="h-start">
        <p className="kicker">批量选片</p>
        <h2 id="h-start">选一批鸟片</h2>
        <p className="intro">从一批原片里找鸟、认种，挑出值得细看的照片。</p>
        {models && !models.ready && (
          <div className="missing" role="alert">缺模型文件：{models.missing.join("、")}。<br />在终端运行 <code>{models.fetch}</code> 下载后刷新。</div>
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
          <span className="label">拍摄地区</span>
          <div className="row">
            <select aria-label="国家" value={country} onChange={(e) => { setCountry(e.target.value); setState(regions[e.target.value]?.[0] ?? ""); }}>
              {Object.keys(regions).map((c) => <option key={c}>{c}</option>)}
            </select>
            <select aria-label="州 / 省" value={state} onChange={(e) => setState(e.target.value)}>
              {(regions[country] ?? []).map((s) => <option key={s}>{s}</option>)}
            </select>
          </div>
          <p className="hint">照片自带位置时，以照片为准。地区修正 <span className="tbd">待定</span></p>
        </div>
        <div className="field">
          <span className="label" id="lb-ratio">留片比例</span>
          <div className="seg" role="radiogroup" aria-labelledby="lb-ratio">
            {RATIO_LABEL.map(([v, t]) => (
              <label key={v}><input type="radio" name="ratio" value={v} checked={preset === v} onChange={() => setPreset(v)} />
                <span>{t}{v === "stricter" && <> <span className="tbd">待定</span></>}</span></label>
            ))}
          </div>
          <p className="hint">目标 {ratio.p3}% 三星、接着 {ratio.p2}% 两星。受连拍上限和鸟种保底影响。{preset === "stricter" ? " 档位待定。" : ""}
            {preset === "custom" && c2 > ratio.p2 ? ` 两档合计最多 100%，本次两星按 ${ratio.p2}% 计算。` : ""}</p>
          {preset === "custom" && (
            <div className="row" style={{ marginTop: 8 }}>
              <label>三星 <input type="number" min={0} max={100} value={c3} onChange={(e) => setC3(+e.target.value)} /> %</label>
              <label>两星 <input type="number" min={0} max={100 - ratio.p3} value={c2} onChange={(e) => setC2(+e.target.value)} /> %</label>
            </div>
          )}
        </div>
        <button className="btn primary big" disabled={!folder.trim() || busy} onClick={go}>开始</button>
        {err && <p className="error-text" role="alert">{err}</p>}
        <p className="note">全部在这台电脑上处理，不上传，也不改动原片。</p>
        {scans.length > 0 && (
          <div className="recent"><span className="label">最近的扫描</span>
            {scans.slice(0, 6).map((s) => (
              <button key={s.id} onClick={() => onOpen(s.id)}>
                {s.folder} · {s.counts.total} 张 · {STATE_LABEL[s.state]}
              </button>
            ))}
          </div>
        )}
      </section>
      <aside className="hero" aria-label="示例照片">
        <figure>
          <div className="hero-frame"><div className="ph"><img src="/hero.jpg" alt="掠过水面的角鸬鹚" /></div></div>
          <figcaption><h3>角鸬鹚</h3><small>索尼 α7 IV · 湿地公园</small></figcaption>
          <div className="settings"><span>600 mm</span> <span>f/6.3</span> <span>1/1000 s</span> <span>ISO 250</span> <span>0 EV</span></div>
        </figure>
      </aside>
    </div>
  );
}

function App() {
  const [scanId, setScanId] = useState<number | null>(() => Number(new URLSearchParams(location.search).get("scan")) || null);
  const open = (id: number | null) => {
    history.replaceState(null, "", id ? `?scan=${id}` : location.pathname);
    setScanId(id);
    window.scrollTo(0, 0);
  };
  return (
    <>
      <header className="masthead">
        <div className="masthead-inner">
          <div className="brand"><span className="emblem" aria-hidden="true"></span><h1>观羽</h1><small>桌面审片</small></div>
          <span className="tag-proto">本机处理 · BirdCM</span>
        </div>
      </header>
      <main>{scanId ? <Results key={scanId} scanId={scanId} onBack={() => open(null)} /> : <Setup onOpen={open} />}</main>
    </>
  );
}

createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
