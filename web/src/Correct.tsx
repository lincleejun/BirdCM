// 改正鸟种: the person says what the bird is. A search over all species (Chinese / English / Latin), with this photo's
// own candidates and the species already in the scan first.
import { useEffect, useState } from "react";
import { get } from "./api";
import type { Name } from "./types";
import { PlainName } from "./names";
import { t } from "./i18n";

export interface Pick { sci: string; zh: string | null; en: string | null }
export type Scope = "one" | "burst" | "same";

export default function CorrectPanel({ own, inScan, current, burst, onApply, onUndo, onClose, manual, count }: {
  own: Name[]; inScan: Pick[]; current: string | null; burst: boolean; manual: boolean; count?: number;   // count: the grid's selection
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
    <div className="correct" role="group" aria-label={t("correct.label")}>
      <input className="map-search" placeholder={t("correct.search")} value={q} onChange={(e) => setQ(e.target.value)} autoFocus />
      <ul className="correct-list">
        {list.map((x) => (
          <li key={x.sci}><button type="button" aria-pressed={chosen?.sci === x.sci} onClick={() => setChosen(x)}>
            <PlainName zh={x.zh} en={x.en} sci={x.sci} size="row" /></button></li>
        ))}
        {!list.length && <li className="hint">{q.trim() ? t("correct.none") : t("correct.type")}</li>}
      </ul>
      <div className="row" role="radiogroup" aria-label={t("correct.which")}>
        <label><input type="radio" checked={scope === "one"} onChange={() => setScope("one")} /> {count ? t("correct.picked", { n: count }) : t("correct.this")}</label>
        {burst && <label><input type="radio" checked={scope === "burst"} onChange={() => setScope("burst")} /> {t("correct.burst")}</label>}
        {current && <label><input type="radio" checked={scope === "same"} onChange={() => setScope("same")} /> {t("correct.same")}<i>{current}</i>{t("correct.same_after")}</label>}
      </div>
      <div className="row">
        <button type="button" className="btn primary slim" disabled={!chosen || busy} onClick={() => run(() => onApply(chosen!.sci, scope))}>
          {chosen ? t("correct.to", { name: chosen.zh ?? chosen.en ?? "" }) : t("correct.choose")}</button>
        <button type="button" className="btn slim" disabled={busy} onClick={() => run(() => onApply(null, scope))}>{t("correct.uncertain")}</button>
        {manual && onUndo && <button type="button" className="btn slim" disabled={busy} onClick={() => run(() => onUndo(scope))}>{t("correct.undo")}</button>}
        <button type="button" className="btn link" onClick={onClose}>{t("correct.cancel")}</button>
      </div>
      {err && <p className="error-text" role="alert">{err}</p>}
    </div>
  );
}
