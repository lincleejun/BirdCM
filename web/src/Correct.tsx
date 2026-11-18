// 改正鸟种: the person says what the bird is. A search over all species (Chinese / English / Latin), with this photo's
// own candidates and the species already in the scan first.
import { useEffect, useState } from "react";
import { get } from "./api";
import type { Name } from "./types";

export interface Pick { sci: string; zh: string | null; en: string | null }
export type Scope = "one" | "burst" | "same";

export default function CorrectPanel({ own, inScan, current, burst, onApply, onUndo, onClose, manual }: {
  own: Name[]; inScan: Pick[]; current: string | null; burst: boolean; manual: boolean;
  onApply: (sci: string | null, scope: Scope) => Promise<void>; onUndo?: (scope: Scope) => Promise<void>; onClose: () => void;
}) {
  const [q, setQ] = useState("");
  const [hits, setHits] = useState<Pick[]>([]);
  const [chosen, setChosen] = useState<Pick | null>(null);
  const [scope, setScope] = useState<Scope>("one");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  useEffect(() => {
    if (!q.trim()) { setHits([]); return; }
    const t = window.setTimeout(() => get<Pick[]>(`/api/species?q=${encodeURIComponent(q)}`).then(setHits).catch(() => setHits([])), 150);
    return () => clearTimeout(t);
  }, [q]);
  const first = [...own.map((n) => ({ sci: n.sci, zh: n.zh, en: n.en })), ...inScan].filter((x, i, a) => a.findIndex((y) => y.sci === x.sci) === i);
  const list = q.trim() ? hits : first;
  const run = async (f: () => Promise<void>) => { setBusy(true); setErr(""); try { await f(); onClose(); } catch (e) { setErr(String((e as Error).message)); } finally { setBusy(false); } };
  return (
    <div className="correct" role="group" aria-label="改正鸟种">
      <input className="map-search" placeholder="搜鸟种：中文、英文或学名" value={q} onChange={(e) => setQ(e.target.value)} autoFocus />
      <ul className="correct-list">
        {list.map((x) => (
          <li key={x.sci}><button type="button" aria-pressed={chosen?.sci === x.sci} onClick={() => setChosen(x)}>
            {x.zh ?? x.en} <small>{x.en} · <i>{x.sci}</i></small></button></li>
        ))}
        {!list.length && <li className="hint">{q.trim() ? "没有找到" : "输入名字搜索"}</li>}
      </ul>
      <div className="row" role="radiogroup" aria-label="改哪些照片">
        <label><input type="radio" checked={scope === "one"} onChange={() => setScope("one")} /> 这一张</label>
        {burst && <label><input type="radio" checked={scope === "burst"} onChange={() => setScope("burst")} /> 这一连拍组</label>}
        {current && <label><input type="radio" checked={scope === "same"} onChange={() => setScope("same")} /> 这批里所有被认成 <i>{current}</i> 的照片</label>}
      </div>
      <div className="row">
        <button type="button" className="btn primary slim" disabled={!chosen || busy} onClick={() => run(() => onApply(chosen!.sci, scope))}>
          {chosen ? `改成 ${chosen.zh ?? chosen.en}` : "先选一个鸟种"}</button>
        <button type="button" className="btn slim" disabled={busy} onClick={() => run(() => onApply(null, scope))}>标为不确定</button>
        {manual && onUndo && <button type="button" className="btn slim" disabled={busy} onClick={() => run(() => onUndo(scope))}>撤销改正</button>}
        <button type="button" className="btn link" onClick={onClose}>取消</button>
      </div>
      {err && <p className="error-text" role="alert">{err}</p>}
    </div>
  );
}
