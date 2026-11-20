// The export dialog: choose which birds (species checklist), then a table (CSV / JSON) or an eBird import file.
import { useEffect, useMemo, useState } from "react";
import { get, post, postText } from "./api";
import type { PhotoRow } from "./types";

interface PlanSpecies {
  sci: string; level: "species" | "genus"; zh: string | null; en: string | null; photos: number; stars: number; files: string[];
  max_in_frame: number; rare: boolean; lookalike: boolean; ebird_en: string; ebird_code: string; name_check: "" | "differs" | "not_in_ebird" | "genus";
}
interface Plan { species: PlanSpecies[]; checklists: { key: string; date: string; photos: number }[] }

interface XmpPlan { create: number; modify: number; skipped: Record<string, number>; last: { id: number; created_at: number; files: number } | null }
interface XmpDone { created: number; modified: number; unchanged: number; skipped: Record<string, number> }
interface XmpUndo { batch: number | null; deleted: number; restored: number; kept: { file: string; reason: string }[] }

const NONE = "__none__";
const skips = (m: Record<string, number>) => Object.entries(m).map(([why, n]) => `${n} 张${why}`).join("；");                                    // photos without a species (不确定 / 没有鸟)

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
      const e = m.get(k) ?? { n: 0, stars: 0, name: k === NONE ? "没认出鸟种（不确定 / 没有鸟）" : l?.zh ? `${l.zh} ${l.en ?? ""}` : (l?.en ?? k),
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
      else setXmpMsg(Object.keys(plan.skipped).length ? `没有可写的：${skips(plan.skipped)}。` : "没有可写的照片。");
    } catch (e) { setErr(String((e as Error).message)); }
    setBusy(false);
  };
  const writeXmp = async () => {
    if (!asking) return;
    setErr(""); setBusy(true);
    try {
      const r = await post<XmpDone>(`/api/scans/${scanId}/xmp`, { ids: asking.ids });
      setXmpMsg(`新增 ${r.created} 个、修改 ${r.modified} 个 .xmp${r.unchanged ? `，${r.unchanged} 个已是这些内容` : ""}。`
        + (Object.keys(r.skipped).length ? ` 跳过：${skips(r.skipped)}。` : "") + " 在 Lightroom 里选中这些照片，元数据 › 从文件读取元数据。");
    } catch (e) { setErr(String((e as Error).message)); }
    setAsking(null); setBusy(false); loadLast();
  };
  const undoXmp = async () => {
    setErr(""); setBusy(true);
    try {
      const r = await post<XmpUndo>(`/api/scans/${scanId}/xmp/undo`);
      setXmpMsg(`已撤回：删掉 ${r.deleted} 个、恢复 ${r.restored} 个。`
        + (r.kept.length ? ` ${r.kept.length} 个没动（${r.kept.map((k) => `${k.file}：${k.reason}`).join("；")}）。` : ""));
    } catch (e) { setErr(String((e as Error).message)); }
    setBusy(false); loadLast();
  };
  const xmpN = asking ? asking.plan.create + asking.plan.modify : 0;

  return (
    <div className="dlg-body export">
      <label className="row" style={{ marginBottom: 8 }}><input type="checkbox" checked={onlyView} onChange={(e) => setOnlyView(e.target.checked)} /> 只导出当前筛选出的 {view.length} 张</label>
      <fieldset className="exp-species">
        <legend>导出哪些鸟</legend>
        <div className="row">
          <button type="button" className="btn slim" onClick={() => setSel(new Set(counts.map(([k]) => k)))}>全选</button>
          <button type="button" className="btn slim" onClick={() => setSel(new Set())}>全不选</button>
          <button type="button" className="btn slim" onClick={() => setSel(new Set(counts.map(([k]) => k).filter((k) => inView.has(k))))}>只选当前筛选里的</button>
          {counts.length > 12 && <input className="map-search" placeholder="搜鸟种" value={q} onChange={(e) => setQ(e.target.value)} />}
        </div>
        <ul className="exp-sp-list">
          {shown.map(([k, e]) => (
            <li key={k}><label><input type="checkbox" checked={sel.has(k)} onChange={(ev) => { const s = new Set(sel); if (ev.target.checked) s.add(k); else s.delete(k); setSel(s); }} />
              {e.name}{e.genus && <small>（只到属）</small>} <small>{e.n} 张 · 有星 {e.stars}</small></label></li>
          ))}
        </ul>
      </fieldset>
      <p className="exp-summary"><b>{days.size} 个清单 · {new Set(chosen.map(speciesOf).filter((k) => k !== NONE)).size} 种 · {chosen.length} 张照片</b></p>
      <div className="exp-list">
        <div className="exp-item"><div className="what">表格（CSV）<small>每张照片一行，可用 Excel / Numbers 打开</small></div>
          <button className="btn primary" disabled={!chosen.length} onClick={() => saveTable(chosen, "csv")}>导出</button></div>
        <div className="exp-item"><div className="what">数据（JSON）<small>字段同上，给程序用</small></div>
          <button className="btn" disabled={!chosen.length} onClick={() => saveTable(chosen, "json")}>导出</button></div>
      </div>
      <section className="ebird">
        <h4 className="panel-h">写给 Lightroom（XMP 边车）</h4>
        <p className="hint">在每张 RAW 旁边写一个同名 .xmp（IMG_0001.ARW → IMG_0001.xmp）：星级（淘汰 = 拒绝）和鸟种关键字（中文名、英文名、学名，你改过的优先）。
          原片本身不改；已有的 .xmp 只加改这几项，你自己的关键字和调整都留着。JPEG / DNG 跳过：Lightroom 把它们的元数据写在文件里面，观羽不改原片。</p>
        {!asking && (
          <div className="row">
            <button className="btn" disabled={busy || !chosen.length} onClick={askXmp}>写 XMP 边车…</button>
            <button className="btn" disabled={busy || !last} onClick={undoXmp}>撤回上次写入{last ? `（${last.files} 个文件）` : ""}</button>
            {busy && <small>正在处理…</small>}
          </div>
        )}
        {asking && (
          <div className="warn" role="alertdialog" aria-label="确认写入 XMP">
            <p>会在照片文件夹里新增 {asking.plan.create} 个、修改 {asking.plan.modify} 个 .xmp 文件，共 {xmpN} 个。原片不动，可以用「撤回上次写入」撤回。
              {Object.keys(asking.plan.skipped).length > 0 && ` 跳过：${skips(asking.plan.skipped)}。`}</p>
            <div className="row">
              <button className="btn primary" disabled={busy} onClick={writeXmp}>{busy ? "正在写…" : `写入 ${xmpN} 个 .xmp`}</button>
              <button className="btn link" disabled={busy} onClick={() => setAsking(null)}>取消</button>
            </div>
          </div>
        )}
        {xmpMsg && <p className="hint" role="status">{xmpMsg}</p>}
      </section>
      <section className="ebird">
        <h4 className="panel-h">eBird 导入文件（Record Format）</h4>
        <p className="hint">每个鸟种在每个清单里一行；清单 = 一天 × 一个地点。默认按"顺带记录"（Incidental）提交、不是完整清单：照片只说明拍到了什么，不是完整计数。
          导入步骤见 README 的"导入 eBird"。{genusLeft > 0 && ` 只到属的 ${genusLeft} 项没选，不会导出。`}</p>
        <div className="row">
          <label>类型 <select value={protocol} onChange={(e) => setProtocol(e.target.value as "Incidental" | "Stationary")}>
            <option value="Incidental">顺带记录 Incidental（默认）</option><option value="Stationary">定点 Stationary（时长按第一张到最后一张照片）</option></select></label>
          <label>数量 <select value={countMode} onChange={(e) => { setCountMode(e.target.value as "x" | "max"); setNumbers({}); }}>
            <option value="x">X（有，没数）</option><option value="max">一张照片里最多同框几只</option></select></label>
          <label className="row"><input type="checkbox" checked={withFiles} onChange={(e) => setWithFiles(e.target.checked)} /> 备注里附照片文件名</label>
        </div>
        {plan && eSpecies.length > 0 && (
          <table className="eb-table"><thead><tr><th>鸟种（eBird 用的英文名）</th><th>数量</th><th>备注</th></tr></thead><tbody>
            {eSpecies.map((s) => (
              <tr key={s.sci}>
                <td>{s.zh ?? s.en} <small>{s.ebird_en || s.en} · <i>{s.sci}</i></small>
                  {(s.rare || s.lookalike) && <div className="warn">本地少见或近似种，eBird 可能要求说明</div>}
                  {s.name_check === "differs" && <div className="warn">eBird 的英文名和 AviList 不同，导入时可能要在"Fix Species"里核对</div>}
                  {s.name_check === "not_in_ebird" && <div className="warn">eBird 名录里没有这个名字，导入时要手动选种</div>}
                  {s.name_check === "genus" && <div className="warn">只到属：导入时要在 eBird 里选对应的"sp."</div>}</td>
                <td><input className="eb-n" value={countOf(s)} onChange={(e) => setNumbers({ ...numbers, [s.sci]: e.target.value.trim() })} /></td>
                <td><input className="eb-note" autoFocus={s.rare || s.lookalike} value={notes[s.sci] ?? ""} onChange={(e) => setNotes({ ...notes, [s.sci]: e.target.value })} /></td>
              </tr>
            ))}
          </tbody></table>
        )}
        <div className="row" style={{ marginTop: 8 }}>
          <button className="btn primary" disabled={!eSpecies.length} onClick={exportEbird}>导出 eBird 文件</button>
          <button className="btn link" onClick={onClose}>关闭</button>
        </div>
        {err && <p className="error-text" role="alert">{err}</p>}
      </section>
    </div>
  );
}
