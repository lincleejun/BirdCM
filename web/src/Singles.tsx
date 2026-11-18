import { useEffect, useRef, useState } from "react";
import { del, get, post, upload } from "./api";
import { nameOf } from "./Results";
import type { Box, Detection, PhotoResult, Species } from "./types";

// Single photo + history, laid out like prototype/mobile.html's result page: photo on top, then reading order.
interface Single {
  id: number; name: string; created_at: number; region: string | null; subject: number | null;
  boxes: Box[] | null; result: PhotoResult | null; error: string | null;
}
interface Slim {
  id: number; name: string; created_at: number; region: string | null; error: string | null;
  result: { species: Species | null; rejected: boolean; reject_reason: string | null; taken_at: string | null; gps: number[] | null } | null;
}

const pct = (p: number) => `${Math.round(p * 100)}%`;
const fmtTime = (t: string | null | undefined) => (t ? t.slice(0, 19).replace("T", " ") : "时间未知");
const clamp = (v: number) => Math.max(0, Math.min(1, v));

function spName(sp: Species | null | undefined): string {
  if (!sp || sp.level === "uncertain" || !sp.label) return "不确定";
  if (sp.level === "genus") return `${sp.label.sci.replace(/ sp\.$/, "")} 属`;
  return sp.label.zh || sp.label.en || sp.label.sci;
}

export default function Singles({ regions }: { regions: Record<string, string[]> }) {
  const [list, setList] = useState<Slim[]>([]);
  const [rec, setRec] = useState<Single | null>(null);
  const [busy, setBusy] = useState("");
  const [err, setErr] = useState("");
  const refresh = () => get<Slim[]>("/api/singles").then(setList).catch((e) => setErr(String(e.message)));
  useEffect(() => { refresh(); }, []);

  const send = async (file: File) => {
    setBusy("正在识别…"); setErr("");
    try {
      const fd = new FormData();
      fd.append("file", file);
      setRec(await upload<Single>("/api/singles", fd));
      refresh();
    } catch (e) { setErr(String((e as Error).message)); } finally { setBusy(""); }
  };
  const act = async (body: object, label = "正在识别…") => {
    if (!rec) return;
    setBusy(label); setErr("");
    try { setRec(await post<Single>(`/api/singles/${rec.id}/identify`, body)); refresh(); }
    catch (e) { setErr(String((e as Error).message)); } finally { setBusy(""); }
  };
  const open = async (id: number) => { setErr(""); setRec(await get<Single>(`/api/singles/${id}`)); window.scrollTo(0, 0); };
  const remove = async (id: number) => {
    await del(`/api/singles/${id}`);
    if (rec?.id === id) setRec(null);
    refresh();
  };
  const clearAll = async () => {
    if (!confirm(`清空全部 ${list.length} 条识别记录？上传的照片也会一起删除，不能恢复。`)) return;
    await del("/api/singles");
    setRec(null);
    refresh();
  };

  if (rec) return <Result rec={rec} busy={busy} err={err} regions={regions} onBack={() => { setRec(null); refresh(); }}
    onAct={act} onDelete={() => remove(rec.id)} onPick={send} />;
  return (
    <section className="single" aria-labelledby="h-single">
      <p className="kicker">认一张</p>
      <h2 id="h-single" tabIndex={-1}>这是什么鸟</h2>
      <p className="intro">选一张照片或拖进来，在这台电脑上识别，结果自动记进历史。</p>
      <Drop onFile={send} busy={busy} />
      {err && <p className="error-text" role="alert">{err}</p>}
      <div className="single-bar" style={{ marginTop: 22 }}>
        <h3>识别历史</h3>
        {list.length > 0 && <button className="btn link" onClick={clearAll}>清空历史</button>}
      </div>
      {list.length === 0 ? <p className="history-empty">识别过的照片会自动出现在这里。</p> : (
        <ol className="history-list" aria-label="识别记录">
          {list.map((h) => {
            const name = h.error && !h.result ? "识别失败" : h.result?.rejected ? (h.result.reject_reason ?? "没有找到鸟") : spName(h.result?.species);
            return (
              <li key={h.id} className="history-entry">
                <button type="button" className="history-open" onClick={() => open(h.id)}>
                  <img className="history-thumb" src={`/api/singles/${h.id}/image?size=thumb`} alt="" loading="lazy" />
                  <span><span className={`history-name${name === "不确定" || h.result?.rejected ? " uncertain" : ""}`}>{name}</span>
                    <span className="history-meta">{fmtTime(h.result?.taken_at)} · {h.name}</span>
                    <span className="history-meta">{h.result?.gps ? "照片自带位置" : h.region ?? "地区未记录"}</span></span>
                </button>
                <button type="button" className="history-delete" onClick={() => remove(h.id)} aria-label={`删除这条记录（${name}）`}>删除</button>
              </li>
            );
          })}
        </ol>
      )}
    </section>
  );
}

function Drop({ onFile, busy }: { onFile: (f: File) => void; busy: string }) {
  const [over, setOver] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  return (
    <div className={`drop${over ? " over" : ""}`} onDragOver={(e) => { e.preventDefault(); setOver(true); }} onDragLeave={() => setOver(false)}
      onDrop={(e) => { e.preventDefault(); setOver(false); const f = e.dataTransfer.files[0]; if (f) onFile(f); }}>
      {busy ? <p role="status">{busy}</p> : <p>把一张 ARW、DNG、JPG 或 PNG 拖到这里</p>}
      <input ref={input} type="file" accept=".arw,.dng,.jpg,.jpeg,.png" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f); e.target.value = ""; }} />
      <button className="btn primary" disabled={!!busy} onClick={() => input.current?.click()}>选择照片</button>
    </div>
  );
}

function Result({ rec, busy, err, regions, onBack, onAct, onDelete, onPick }: {
  rec: Single; busy: string; err: string; regions: Record<string, string[]>; onBack: () => void;
  onAct: (body: object, label?: string) => void; onDelete: () => void; onPick: (f: File) => void;
}) {
  const r = rec.result;
  const [drawing, setDrawing] = useState(false);
  const [box, setBox] = useState<Box | null>(null);
  const [askRegion, setAskRegion] = useState(false);
  const shot = useRef<HTMLDivElement>(null);
  const drag = useRef<{ x: number; y: number } | null>(null);
  const noBird = !r || r.rejected;
  const framing = (noBird && !rec.error) || drawing;
  const i = rec.subject ?? r?.subject ?? null;
  const b: Detection | null = r && i !== null ? r.boxes[i] ?? null : null;
  const sp = b?.species ?? null;
  const sure = sp?.level === "species" && !!sp.label;
  const multi = !!r && !r.rejected && r.boxes.filter((x) => x.clear !== false || rec.boxes).length > 1;
  const shown = r ? r.boxes.map((x, k) => ({ x, k })).filter(({ x }) => x.clear !== false || rec.boxes) : [];
  useEffect(() => { setDrawing(false); setBox(null); setAskRegion(false); }, [rec]);       // every new answer leaves the drawing mode

  const at = (e: React.PointerEvent) => {
    const q = shot.current!.getBoundingClientRect();
    return { x: clamp((e.clientX - q.left) / q.width), y: clamp((e.clientY - q.top) / q.height) };
  };
  const move = (e: React.PointerEvent) => {
    if (!drag.current) return;
    const p = at(e), s = drag.current;
    setBox([Math.min(s.x, p.x), Math.min(s.y, p.y), Math.max(s.x, p.x), Math.max(s.y, p.y)]);
  };
  const posStyle = (q: number[]) => ({ left: `${q[0] * 100}%`, top: `${q[1] * 100}%`, width: `${(q[2] - q[0]) * 100}%`, height: `${(q[3] - q[1]) * 100}%` });
  const e = r?.exif;

  return (
    <section className="single" aria-labelledby="h-result">
      <div className="single-bar">
        <button className="btn link" onClick={onBack}>‹ 历史</button>
        <div className="row">
          <label className="btn">再选一张<input type="file" accept=".arw,.dng,.jpg,.jpeg,.png" hidden onChange={(ev) => { const f = ev.target.files?.[0]; if (f) onPick(f); ev.target.value = ""; }} /></label>
          <button className="btn" onClick={onDelete}>删除记录</button>
        </div>
      </div>
      <div className="shot-view">
        <div ref={shot} className={`shot${framing ? " drawing" : ""}`}
          onPointerDown={framing ? (ev) => { (ev.target as Element).setPointerCapture?.(ev.pointerId); drag.current = at(ev); setBox(null); } : undefined}
          onPointerMove={framing ? move : undefined}
          onPointerUp={framing ? () => { drag.current = null; setBox((q) => (q && q[2] - q[0] > 0.01 && q[3] - q[1] > 0.01 ? q : null)); } : undefined}>
          <img src={`/api/singles/${rec.id}/image`} alt={framing ? "在照片上拖出一个框，框住鸟" : r ? nameOf(r) : rec.name} draggable={false} />
          {!framing && r && shown.map(({ x, k }) => <span key={k} className={`mk box${k === i ? "" : " off"}`} style={posStyle(x.box)} />)}
          {!framing && b?.eye && (b.eye_p ?? 0) >= 0.5 && <span className="mk eye" style={{ left: `${b.eye[0] * 100}%`, top: `${b.eye[1] * 100}%` }} />}
          {!framing && multi && shown.map(({ x, k }) => (
            <button key={k} type="button" className="bird-hit" aria-label={`照片中的第 ${k + 1} 只鸟`} aria-pressed={k === i}
              style={{ left: `${(x.box[0] + x.box[2]) * 50}%`, top: `${(x.box[1] + x.box[3]) * 50}%`, width: `${(x.box[2] - x.box[0]) * 100}%`, height: `${(x.box[3] - x.box[1]) * 100}%` }}
              onClick={() => onAct({ subject: k }, "")} />
          ))}
          {framing && box && <span className="mk drag" style={posStyle(box)} />}
        </div>
      </div>
      {busy && <p className="hint" role="status">{busy}</p>}
      {err && <p className="error-text" role="alert">{err}</p>}
      {rec.error && !busy && <p className="error-text" role="alert">识别失败：{rec.error}</p>}

      {framing ? (
        <div className="result-content">
          <h1 className="sp-cn" style={{ font: "700 30px/1.2 var(--serif)" }} tabIndex={-1}>{drawing ? "手动画框" : r?.reject_reason ?? "没有找到鸟"}</h1>
          <p className="lead hint">在照片上拖出一个框，也可以用整张照片重试。</p>
          <div className="row" style={{ marginTop: 10 }}>
            <button className="btn primary" disabled={!box || !!busy} onClick={() => box && onAct({ box })}>识别框里的鸟</button>
            <button className="btn" disabled={!!busy} onClick={() => onAct({ box: [0, 0, 1, 1] })}>框住整张照片</button>
            {drawing && <button className="btn link" onClick={() => { setDrawing(false); setBox(null); }}>取消</button>}
          </div>
        </div>
      ) : r && b && (
        <div className="result-content">
          <div className="identity-result">
            <h1 tabIndex={-1} id="h-result" className={`sp-cn${sure ? "" : " uncertain"}`}>{spName(sp)}</h1>
            <span className="conf">{sure ? "初步把握" : "最高候选"} {pct(sure || sp?.level === "genus" ? sp!.label!.p : sp!.top5[0].p)}</span>
          </div>
          {sure ? <p className="sp-en">{sp!.label!.en} <span className="sp-sci">· {sp!.label!.sci}</span></p>
            : <p className="hint">{sp?.level === "genus" ? `只认到属 · ${sp.label!.sci}` : "照片里的特征不够清楚。"}</p>}
          <p className="facts-inline">
            <strong>{b.p_fly == null ? "姿态未知" : b.p_fly >= 0.5 ? "在飞" : "不在飞"}</strong>
            <span>稀有度 <span className="tbd">待定</span></span><span>IUCN <span className="tbd">待定</span></span>
            {b.clear === false && <span>框里的鸟不够清楚</span>}
          </p>
          {multi && (
            <div className="bird-switch" role="group" aria-label="切换照片中的鸟">
              {shown.map(({ k }, n) => <button key={k} type="button" aria-pressed={k === i} onClick={() => onAct({ subject: k }, "")}>第 {n + 1} 只</button>)}
              <span className="hint">也可以点照片里的鸟框</span>
            </div>
          )}
          <div className="legend"><span><i className="l-box"></i>{rec.boxes ? "手动画的框" : "当前鸟框"}</span>
            {b.eye && (b.eye_p ?? 0) >= 0.5 && <span><i className="l-eye"></i>眼睛</span>}
            {multi && <span><i className="l-off"></i>其他鸟框</span>}
            <button className="btn link" style={{ minHeight: 0, padding: 0 }} onClick={() => { setDrawing(true); setBox(null); }}>手动画框重试</button></div>
          <section className="result-section" aria-labelledby="cand-h">
            <h3 id="cand-h">{sure ? "其他候选" : "前 5 个候选"}</h3>
            <ol className="candidates" start={sure ? 2 : 1}>
              {sp!.top5.slice(sure ? 1 : 0).map((c) => <li key={c.sci}>{c.zh ?? c.en ?? c.sci} <span>{c.zh ? c.en : ""} · <i>{c.sci}</i> · {pct(c.p)}</span></li>)}
            </ol>
            <p className="hint">只凭图像判断，地区修正 <span className="tbd">待定</span></p>
          </section>
          <section className="result-section" aria-labelledby="exif-h">
            <h3 id="exif-h">拍摄信息</h3>
            <div className="settings"><span>{e?.focal_mm != null ? `${+e.focal_mm.toFixed(0)} mm` : "— mm"}</span> <span>f/{e?.aperture ?? "—"}</span>{" "}
              <span>{e?.shutter ?? "—"} s</span> <span>ISO {e?.iso ?? "—"}</span> <span>{e?.ev != null ? `${e.ev > 0 ? "+" : ""}${e.ev} EV` : "— EV"}</span></div>
            <dl className="facts"><dt>相机</dt><dd>{e?.camera ?? "—"}</dd><dt>镜头</dt><dd>{e?.lens ?? "—"}</dd><dt>拍摄时间</dt><dd>{fmtTime(e?.taken_at)}</dd><dt>文件</dt><dd>{rec.name}</dd></dl>
          </section>
          <section className="result-section" aria-labelledby="region-h">
            <h3 id="region-h">拍摄地区</h3>
            {e?.gps ? <div className="location"><span>GPS {e.gps.map((v) => v.toFixed(4)).join(", ")}</span><span className="hint">照片自带位置</span></div>
              : askRegion ? <RegionPicker regions={regions} initial={rec.region} onPick={(region) => { setAskRegion(false); onAct({ region }); }} onCancel={() => setAskRegion(false)} />
              : <div className="location">
                  <span className={rec.region ? "" : "hint"}>{rec.region ?? "未记录地区，暂无法判断当地稀有度。"}</span>
                  <button className="btn" onClick={() => setAskRegion(true)}>{rec.region ? "改地区" : "补充地区"}</button>
                </div>}
            {!e?.gps && <p className="hint">地区修正还在调研，选了地区现在不改变识别结果。</p>}
          </section>
        </div>
      )}
    </section>
  );
}

function RegionPicker({ regions, initial, onPick, onCancel }: { regions: Record<string, string[]>; initial: string | null;
  onPick: (r: string) => void; onCancel: () => void }) {
  const [c0, s0] = (initial ?? "").split(" · ");
  const [country, setCountry] = useState(c0 && regions[c0] ? c0 : Object.keys(regions)[0] ?? "");
  const [state, setState] = useState(s0 ?? regions[country]?.[0] ?? "");
  return (
    <div className="row" style={{ marginTop: 6 }}>
      <select aria-label="国家" value={country} onChange={(e) => { setCountry(e.target.value); setState(regions[e.target.value]?.[0] ?? ""); }}>
        {Object.keys(regions).map((c) => <option key={c}>{c}</option>)}
      </select>
      <select aria-label="州 / 省" value={state} onChange={(e) => setState(e.target.value)}>
        {(regions[country] ?? []).map((s) => <option key={s}>{s}</option>)}
      </select>
      <button className="btn primary" onClick={() => onPick(`${country} · ${state}`)}>确定</button>
      <button className="btn link" onClick={onCancel}>取消</button>
    </div>
  );
}
