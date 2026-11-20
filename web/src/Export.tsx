// The export dialog: choose which birds (species checklist), then a table (CSV / JSON) or an eBird import file.
import { useEffect, useMemo, useState } from "react";
import { get, post, postText } from "./api";
import type { PhotoRow } from "./types";
import { t } from "./i18n";

interface PlanSpecies {
  sci: string; level: "species" | "genus"; zh: string | null; en: string | null; photos: number; stars: number; files: string[];
  max_in_frame: number; rare: boolean; lookalike: boolean; ebird_en: string; ebird_code: string; name_check: "" | "differs" | "not_in_ebird" | "genus";
}
interface Plan { species: PlanSpecies[]; checklists: { key: string; date: string; photos: number }[] }

interface XmpPlan { create: number; modify: number; skipped: Record<string, number>; last: { id: number; created_at: number; files: number } | null }
interface XmpDone { created: number; modified: number; unchanged: number; skipped: Record<string, number> }
interface XmpUndo { batch: number | null; deleted: number; restored: number; kept: { file: string; reason: string }[] }

const NONE = "__none__";
const skips = (m: Record<string, number>) => Object.entries(m).map(([why, n]) => t("export.skip_item", { n, why })).join(t("export.skip_sep"));                                    // photos without a species (不确定 / 没有鸟)

/** The species a row stands for in the checklist: the burst-corrected one (withFix already applied), genus "X sp.". */
export function speciesOf(p: PhotoRow): string {
  const sp = p.result?.species;
  return sp && (sp.level === "species" || sp.level === "genus") && sp.label ? sp.label.sci : NONE;
}

export default function ExportDialog({ scanId, photos, view, onClose, saveTable }: {
  scanId: number; photos: PhotoRow[]; view: PhotoRow[]; onClose: () => void;
  saveTable: (rows: PhotoRow[], kind: "csv" | "json") => void;
}) {
  const [onlyView, setOnlyView] = useState(false);
  const scope = onlyView ? view : photos;
  const counts = useMemo(() => {
    const m = new Map<string, { n: number; stars: number; name: string; genus: boolean }>();
    for (const p of scope) {
      const k = speciesOf(p), l = p.result?.species?.label;
      const e = m.get(k) ?? { n: 0, stars: 0, name: k === NONE ? t("export.no_species") : l?.zh ? `${l.zh} ${l.en ?? ""}` : (l?.en ?? k),
        genus: p.result?.species?.level === "genus" };
      e.n += 1; e.stars += (p.stars ?? 0) > 0 ? 1 : 0;
      m.set(k, e);
    }
    return [...m.entries()].sort((a, b) => Number(a[0] === NONE) - Number(b[0] === NONE) || b[1].n - a[1].n);
  }, [scope]);
  // every species ticked by default, except genus-only and "no species" for eBird (they are opt-in below)
  const [sel, setSel] = useState<Set<string>>(() => new Set(counts.map(([k]) => k)));
  useEffect(() => { setSel(new Set(counts.map(([k]) => k))); }, [onlyView]); // eslint-disable-line react-hooks/exhaustive-deps
  const [q, setQ] = useState("");
  const shown = counts.filter(([k, e]) => !q || (k + " " + e.name).toLowerCase().includes(q.toLowerCase()));
  const chosen = scope.filter((p) => sel.has(speciesOf(p)));
  const inView = new Set(view.map(speciesOf));

  // eBird
  const [plan, setPlan] = useState<Plan | null>(null);
  const [err, setErr] = useState("");
  useEffect(() => { get<Plan>(`/api/scans/${scanId}/ebird/plan`).then(setPlan).catch((e) => setErr(String(e.message))); }, [scanId]);
  const [protocol, setProtocol] = useState<"Incidental" | "Stationary">("Incidental");
  const [countMode, setCountMode] = useState<"x" | "max">("x");
  const [withFiles, setWithFiles] = useState(false);
  const [numbers, setNumbers] = useState<Record<string, string>>({});
  const [notes, setNotes] = useState<Record<string, string>>({});
  const eSpecies = (plan?.species ?? []).filter((s) => sel.has(s.sci) && chosen.some((p) => speciesOf(p) === s.sci));
  const genusLeft = (plan?.species ?? []).filter((s) => s.level === "genus" && !sel.has(s.sci)).length;
  const days = new Set(chosen.filter((p) => speciesOf(p) !== NONE).map((p) => `${p.result?.exif.taken_at?.slice(0, 10)}|${p.result?.exif.gps?.map((v) => v.toFixed(2)).join(",") ?? ""}`));
  const countOf = (s: PlanSpecies) => numbers[s.sci] ?? (countMode === "max" && s.max_in_frame > 0 ? String(s.max_in_frame) : "X");

  const exportEbird = async () => {
    setErr("");
    try {
      const counts: Record<string, string> = {}, comments: Record<string, string> = {};
      for (const s of eSpecies) { counts[s.sci] = countOf(s); if (notes[s.sci]) comments[s.sci] = notes[s.sci]; }
      const text = await postText(`/api/scans/${scanId}/ebird`, { species: eSpecies.map((s) => s.sci), counts, comments, protocol,
        with_files: withFiles, ids: onlyView ? view.map((p) => p.id) : null });
      const a = document.createElement("a");
      a.href = URL.createObjectURL(new Blob([text], { type: "text/csv" }));
      a.download = "ebird-record-format.csv";
      a.click();
      URL.revokeObjectURL(a.href);
    } catch (e) { setErr(String((e as Error).message)); }
  };

  // Lightroom: XMP sidecars beside the RAWs, only after the person confirms the counts
  // the counts are taken when 写 XMP 边车… is clicked and the write uses those same ids; on open only the last batch (ids: [])
  const [last, setLast] = useState<XmpPlan["last"]>(null);
  const [asking, setAsking] = useState<{ plan: XmpPlan; ids: number[] } | null>(null);
  const [busy, setBusy] = useState(false);
  const [xmpMsg, setXmpMsg] = useState("");
  const loadLast = () => post<XmpPlan>(`/api/scans/${scanId}/xmp`, { ids: [], dry: true }).then((x) => setLast(x.last)).catch(() => {});
  useEffect(() => { loadLast(); }, [scanId]); // eslint-disable-line react-hooks/exhaustive-deps
  const chosenKey = chosen.map((p) => p.id).join(",");
  useEffect(() => { setAsking(null); }, [chosenKey]);
  const askXmp = async () => {
    setErr(""); setXmpMsg(""); setBusy(true);
    const ids = chosen.map((p) => p.id);
    try {
      const plan = await post<XmpPlan>(`/api/scans/${scanId}/xmp`, { ids, dry: true });
      if (plan.create + plan.modify) setAsking({ plan, ids });
      else setXmpMsg(Object.keys(plan.skipped).length ? t("export.xmp_nothing_because", { why: skips(plan.skipped) }) : t("export.xmp_nothing"));
    } catch (e) { setErr(String((e as Error).message)); }
    setBusy(false);
  };
  const writeXmp = async () => {
    if (!asking) return;
    setErr(""); setBusy(true);
    try {
      const r = await post<XmpDone>(`/api/scans/${scanId}/xmp`, { ids: asking.ids });
      setXmpMsg(t("export.xmp_done", { created: r.created, modified: r.modified }) + (r.unchanged ? t("export.xmp_unchanged", { n: r.unchanged }) : "") + t("export.period")
        + (Object.keys(r.skipped).length ? t("export.skipped", { why: skips(r.skipped) }) : "") + t("export.xmp_read_in_lr"));
    } catch (e) { setErr(String((e as Error).message)); }
    setAsking(null); setBusy(false); loadLast();
  };
  const undoXmp = async () => {
    setErr(""); setBusy(true);
    try {
      const r = await post<XmpUndo>(`/api/scans/${scanId}/xmp/undo`);
      setXmpMsg(t("export.undone", { deleted: r.deleted, restored: r.restored })
        + (r.kept.length ? t("export.undo_kept", { n: r.kept.length, list: r.kept.map((k) => t("export.undo_kept_item", { file: k.file, why: k.reason })).join(t("export.skip_sep")) }) : ""));
    } catch (e) { setErr(String((e as Error).message)); }
    setBusy(false); loadLast();
  };
  const xmpN = asking ? asking.plan.create + asking.plan.modify : 0;

  return (
    <div className="dlg-body export">
      <label className="row" style={{ marginBottom: 8 }}><input type="checkbox" checked={onlyView} onChange={(e) => setOnlyView(e.target.checked)} /> {t("export.only_view", { n: view.length })}</label>
      <fieldset className="exp-species">
        <legend>{t("export.which_birds")}</legend>
        <div className="row">
          <button type="button" className="btn slim" onClick={() => setSel(new Set(counts.map(([k]) => k)))}>{t("export.all")}</button>
          <button type="button" className="btn slim" onClick={() => setSel(new Set())}>{t("export.none")}</button>
          <button type="button" className="btn slim" onClick={() => setSel(new Set(counts.map(([k]) => k).filter((k) => inView.has(k))))}>{t("export.in_view")}</button>
          {counts.length > 12 && <input className="map-search" placeholder={t("export.search")} value={q} onChange={(e) => setQ(e.target.value)} />}
        </div>
        <ul className="exp-sp-list">
          {shown.map(([k, e]) => (
            <li key={k}><label><input type="checkbox" checked={sel.has(k)} onChange={(ev) => { const s = new Set(sel); if (ev.target.checked) s.add(k); else s.delete(k); setSel(s); }} />
              {e.name}{e.genus && <small>{t("export.genus_only")}</small>} <small>{t("export.sp_counts", { n: e.n, stars: e.stars })}</small></label></li>
          ))}
        </ul>
      </fieldset>
      <p className="exp-summary"><b>{t("export.summary", { lists: days.size, species: new Set(chosen.map(speciesOf).filter((k) => k !== NONE)).size, photos: chosen.length })}</b></p>
      <div className="exp-list">
        <div className="exp-item"><div className="what">{t("export.csv")}<small>{t("export.csv_hint")}</small></div>
          <button className="btn primary" disabled={!chosen.length} onClick={() => saveTable(chosen, "csv")}>{t("export.export")}</button></div>
        <div className="exp-item"><div className="what">{t("export.json")}<small>{t("export.json_hint")}</small></div>
          <button className="btn" disabled={!chosen.length} onClick={() => saveTable(chosen, "json")}>{t("export.export")}</button></div>
      </div>
      <section className="ebird">
        <h4 className="panel-h">{t("export.lr_title")}</h4>
        <p className="hint">{t("export.lr_hint")}</p>
        {!asking && (
          <div className="row">
            <button className="btn" disabled={busy || !chosen.length} onClick={askXmp}>{t("export.xmp_write")}</button>
            <button className="btn" disabled={busy || !last} onClick={undoXmp}>{t("export.undo_last")}{last ? t("export.undo_files", { n: last.files }) : ""}</button>
            {busy && <small>{t("export.busy")}</small>}
          </div>
        )}
        {asking && (
          <div className="warn" role="alertdialog" aria-label={t("export.confirm_label")}>
            <p>{t("export.confirm", { create: asking.plan.create, modify: asking.plan.modify, n: xmpN })}
              {Object.keys(asking.plan.skipped).length > 0 && t("export.skipped", { why: skips(asking.plan.skipped) })}</p>
            <div className="row">
              <button className="btn primary" disabled={busy} onClick={writeXmp}>{busy ? t("export.writing") : t("export.write_n", { n: xmpN })}</button>
              <button className="btn link" disabled={busy} onClick={() => setAsking(null)}>{t("export.cancel")}</button>
            </div>
          </div>
        )}
        {xmpMsg && <p className="hint" role="status">{xmpMsg}</p>}
      </section>
      <section className="ebird">
        <h4 className="panel-h">{t("export.ebird_title")}</h4>
        <p className="hint">{t("export.ebird_hint")}{genusLeft > 0 && t("export.genus_left", { n: genusLeft })}</p>
        <div className="row">
          <label>{t("export.protocol")} <select value={protocol} onChange={(e) => setProtocol(e.target.value as "Incidental" | "Stationary")}>
            <option value="Incidental">{t("export.incidental")}</option><option value="Stationary">{t("export.stationary")}</option></select></label>
          <label>{t("export.count")} <select value={countMode} onChange={(e) => { setCountMode(e.target.value as "x" | "max"); setNumbers({}); }}>
            <option value="x">{t("export.count_x")}</option><option value="max">{t("export.count_max")}</option></select></label>
          <label className="row"><input type="checkbox" checked={withFiles} onChange={(e) => setWithFiles(e.target.checked)} /> {t("export.with_files")}</label>
        </div>
        {plan && eSpecies.length > 0 && (
          <table className="eb-table"><thead><tr><th>{t("export.th_species")}</th><th>{t("export.count")}</th><th>{t("export.th_note")}</th></tr></thead><tbody>
            {eSpecies.map((s) => (
              <tr key={s.sci}>
                <td>{s.zh ?? s.en} <small>{s.ebird_en || s.en} · <i>{s.sci}</i></small>
                  {(s.rare || s.lookalike) && <div className="warn">{t("export.warn_rare")}</div>}
                  {s.name_check === "differs" && <div className="warn">{t("export.warn_differs")}</div>}
                  {s.name_check === "not_in_ebird" && <div className="warn">{t("export.warn_not_in_ebird")}</div>}
                  {s.name_check === "genus" && <div className="warn">{t("export.warn_genus")}</div>}</td>
                <td><input className="eb-n" value={countOf(s)} onChange={(e) => setNumbers({ ...numbers, [s.sci]: e.target.value.trim() })} /></td>
                <td><input className="eb-note" autoFocus={s.rare || s.lookalike} value={notes[s.sci] ?? ""} onChange={(e) => setNotes({ ...notes, [s.sci]: e.target.value })} /></td>
              </tr>
            ))}
          </tbody></table>
        )}
        <div className="row" style={{ marginTop: 8 }}>
          <button className="btn primary" disabled={!eSpecies.length} onClick={exportEbird}>{t("export.ebird_export")}</button>
          <button className="btn link" onClick={onClose}>{t("export.close")}</button>
        </div>
        {err && <p className="error-text" role="alert">{err}</p>}
      </section>
    </div>
  );
}
