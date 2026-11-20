import { useEffect, useRef, useState } from "react";
import { del, get, post, upload } from "./api";
import LocationPicker, { type Country, PlaceName, PlaceOf } from "./Location";
import CorrectPanel from "./Correct";
import { Verdict, Candidates, named, SpName } from "./names";
import { nameOf, rarityText } from "./look";
import { t } from "./i18n";
import type { Box, Detection, PhotoResult, Place, Species } from "./types";

// Single photo + history, laid out like prototype/mobile.html's result page: photo on top, then reading order.
interface Single {
  stale?: boolean;
  correction?: { sci: string | null; en?: string | null; zh?: string | null } | null;
  id: number; name: string; created_at: number; region: string | Place | null; subject: number | null;
  boxes: Box[] | null; result: PhotoResult | null; error: string | null;
}
interface Slim {
  id: number; name: string; created_at: number; region: string | Place | null; error: string | null;
  result: { species: Species | null; rejected: boolean; reject_reason: string | null; taken_at: string | null; gps: number[] | null; place?: string | null } | null;
}

const pct = (p: number) => `${Math.round(p * 100)}%`;
const fmtTime = (v: string | null | undefined) => (v ? v.slice(0, 19).replace("T", " ") : t("singles.no_time"));
const clamp = (v: number) => Math.max(0, Math.min(1, v));

const queued = (r: { result: unknown; error: string | null }) => !r.result && !r.error;

function spName(sp: Species | null | undefined): string {
  return named(sp).title;
}

export default function Singles({ catalogue }: { catalogue: Country[] }) {
  const [list, setList] = useState<Slim[]>([]);
  const [rec, setRec] = useState<Single | null>(null);
  const [busy, setBusy] = useState("");
  const [err, setErr] = useState("");
  const refresh = () => get<Slim[]>("/api/singles").then(setList).catch((e) => setErr(String(e.message)));
  useEffect(() => { refresh(); }, []);
  // sent while the models were still loading: queued on the engine (neither answer nor error yet); look again shortly
  const waiting = !!rec && queued(rec);
  const listWaiting = list.some(queued);
  useEffect(() => {
    if (!waiting && !listWaiting) return;
    const tm = window.setTimeout(() => {
      if (rec && waiting) get<Single>(`/api/singles/${rec.id}`).then((x) => setRec((cur) => (cur?.id === x.id ? x : cur))).catch(() => {});
      refresh();
    }, 700);
    return () => clearTimeout(tm);
  }, [rec, list, waiting, listWaiting]);

  const send = async (file: File) => {
    setBusy(t("singles.identifying")); setErr("");
    try {
      const fd = new FormData();
      fd.append("file", file);
      setRec(await upload<Single>("/api/singles", fd));
      refresh();
    } catch (e) { setErr(String((e as Error).message)); } finally { setBusy(""); }
  };
  const act = async (body: object, label = t("singles.identifying")) => {
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
    if (!confirm(t("singles.clear_confirm", { n: list.length }))) return;
    await del("/api/singles");
    setRec(null);
    refresh();
  };

  if (rec) return <Result rec={rec} busy={busy} err={err} catalogue={catalogue} onBack={() => { setRec(null); refresh(); }}
    onAct={act} onDelete={() => remove(rec.id)} onPick={send}
    onCorrect={async (body) => { setRec(await post<Single>(`/api/singles/${rec.id}/correct`, body)); refresh(); }} />;
  return (
    <section className="single" aria-labelledby="h-single">
      <p className="kicker">{t("singles.kicker")}</p>
      <h2 id="h-single" tabIndex={-1}>{t("singles.title")}</h2>
      <p className="intro">{t("singles.intro")}</p>
      <Drop onFile={send} busy={busy} />
      {err && <p className="error-text" role="alert">{err}</p>}
      <div className="single-bar" style={{ marginTop: 22 }}>
        <h3>{t("singles.history")}</h3>
        {list.length > 0 && <button className="btn link" onClick={clearAll}>{t("singles.clear")}</button>}
      </div>
      {list.length === 0 ? <p className="history-empty">{t("singles.history_empty")}</p> : (
        <ol className="history-list" aria-label={t("singles.history_label")}>
          {list.map((h) => {
            const name = queued(h) ? t("singles.queued") : h.error && !h.result ? t("singles.failed") : h.result?.rejected ? (h.result.reject_reason ?? t("singles.no_bird")) : spName(h.result?.species);
            return (
              <li key={h.id} className="history-entry">
                <button type="button" className="history-open" onClick={() => open(h.id)}>
                  <img className="history-thumb" src={`/api/singles/${h.id}/image?size=thumb&v=${h.created_at}`} alt="" loading="lazy" />
                  <span>{h.result && !h.result.rejected && h.result.species ? <SpName sp={h.result.species} size="row" />
                    : <span className={`history-name${h.result?.rejected ? " uncertain" : ""}`}>{name}</span>}
                    <span className="history-meta">{fmtTime(h.result?.taken_at)} · {h.name}</span>
                    <span className="history-meta">{h.result?.gps ? <><PlaceName lat={h.result.gps[0]} lon={h.result.gps[1]} name={h.result.place ?? null} />{t("singles.own_gps")}</>
                      : h.region ? <PlaceOf loc={h.region} /> : t("singles.no_place")}</span></span>
                </button>
                <button type="button" className="history-delete" onClick={() => remove(h.id)} aria-label={t("singles.delete_label", { name })}>{t("singles.delete")}</button>
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
      {busy ? <p role="status">{busy}</p> : <p>{t("singles.drop")}</p>}
      <input ref={input} type="file" accept=".arw,.dng,.jpg,.jpeg,.png" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) onFile(f); e.target.value = ""; }} />
      <button className="btn primary" disabled={!!busy} onClick={() => input.current?.click()}>{t("singles.choose")}</button>
    </div>
  );
}

function Result({ rec, busy, err, catalogue, onBack, onAct, onDelete, onPick, onCorrect }: {
  rec: Single; busy: string; err: string; catalogue: Country[]; onBack: () => void;
  onAct: (body: object, label?: string) => void; onDelete: () => void; onPick: (f: File) => void;
  onCorrect: (body: object) => Promise<void>;
}) {
  const [correcting, setCorrecting] = useState(false);
  const r = rec.result;
  const [drawing, setDrawing] = useState(false);
  const [box, setBox] = useState<Box | null>(null);
  const [askRegion, setAskRegion] = useState(false);
  const shot = useRef<HTMLDivElement>(null);
  const drag = useRef<{ x: number; y: number } | null>(null);
  const noBird = !r || r.rejected;
  const waiting = queued(rec);
  const framing = (noBird && !rec.error && !waiting) || drawing;
  const i = rec.subject ?? r?.subject ?? null;
  const b: Detection | null = r && i !== null ? r.boxes[i] ?? null : null;
  const own = b?.species ?? null;
  const cor = rec.correction;
  // the person's correction wins; the app's own answer stays visible underneath
  const sp = cor && own ? (cor.sci ? { ...own, level: "species" as const, manual: true, label: { sci: cor.sci, en: cor.en ?? null, zh: cor.zh ?? null, p: own.top5.find((c) => c.sci === cor.sci)?.p ?? 0 } }
    : { ...own, level: "uncertain" as const, manual: true, label: null }) : own;
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
        <button className="btn link" onClick={onBack}>{t("singles.back")}</button>
        <div className="row">
          <label className="btn">{t("singles.another")}<input type="file" accept=".arw,.dng,.jpg,.jpeg,.png" hidden onChange={(ev) => { const f = ev.target.files?.[0]; if (f) onPick(f); ev.target.value = ""; }} /></label>
          <button className="btn" onClick={onDelete}>{t("singles.delete_record")}</button>
        </div>
      </div>
      <div className="shot-view">
        <div ref={shot} className={`shot${framing ? " drawing" : ""}`}
          onPointerDown={framing ? (ev) => { (ev.target as Element).setPointerCapture?.(ev.pointerId); drag.current = at(ev); setBox(null); } : undefined}
          onPointerMove={framing ? move : undefined}
          onPointerUp={framing ? () => { drag.current = null; setBox((q) => (q && q[2] - q[0] > 0.01 && q[3] - q[1] > 0.01 ? q : null)); } : undefined}>
          <img src={`/api/singles/${rec.id}/image?v=${rec.created_at}`} alt={framing ? t("singles.draw_alt") : r ? nameOf(r) : rec.name} draggable={false} />
          {!framing && r && shown.map(({ x, k }) => <span key={k} className={`mk box${k === i ? "" : " off"}`} style={posStyle(x.box)} />)}
          {!framing && b?.eye && (b.eye_p ?? 0) >= 0.5 && <span className="mk eye" style={{ left: `${b.eye[0] * 100}%`, top: `${b.eye[1] * 100}%` }} />}
          {!framing && multi && shown.map(({ x, k }) => (
            <button key={k} type="button" className="bird-hit" aria-label={t("singles.bird_n", { n: k + 1 })} aria-pressed={k === i}
              style={{ left: `${(x.box[0] + x.box[2]) * 50}%`, top: `${(x.box[1] + x.box[3]) * 50}%`, width: `${(x.box[2] - x.box[0]) * 100}%`, height: `${(x.box[3] - x.box[1]) * 100}%` }}
              onClick={() => onAct({ subject: k }, "")} />
          ))}
          {framing && box && <span className="mk drag" style={posStyle(box)} />}
        </div>
      </div>
      {busy && <p className="hint" role="status">{busy}</p>}
      {waiting && !busy && <p className="hint" role="status">{t("singles.waiting")}</p>}
      {err && <p className="error-text" role="alert">{err}</p>}
      {rec.error && !busy && <p className="error-text" role="alert">{t("singles.error", { e: rec.error })}</p>}

      {framing ? (
        <div className="result-content">
          <h1 className="sp-cn" tabIndex={-1}>{drawing ? t("singles.draw_head") : r?.reject_reason ?? t("singles.no_bird")}</h1>
          <p className="lead hint">{t("singles.draw_hint")}</p>
          <div className="row" style={{ marginTop: 10 }}>
            <button className="btn primary" disabled={!box || !!busy} onClick={() => box && onAct({ box })}>{t("singles.identify_box")}</button>
            <button className="btn" disabled={!!busy} onClick={() => onAct({ box: [0, 0, 1, 1] })}>{t("singles.whole")}</button>
            {drawing && <button className="btn link" onClick={() => { setDrawing(false); setBox(null); }}>{t("singles.cancel")}</button>}
          </div>
        </div>
      ) : r && b && (
        <div className="result-content">
          <div className="identity-result">
            <h1 tabIndex={-1} id="h-result" style={{ margin: 0 }}><SpName sp={sp} size="hero" /></h1>
            <span className="conf">{sure ? t("singles.likely") : t("singles.top")} {pct(sure || sp?.level === "genus" ? sp!.label!.p : sp!.top5[0].p)}</span>
          </div>
          {cor && own && <p className="fixed-note"><span className="tbd">{t("singles.fixed")}</span>{t("singles.app_said", { name: named(own).title })}{own.label && <> <i>{own.label.sci}</i></>}</p>}
          {sp && !cor && <Verdict sp={sp} />}
          {own && (correcting
            ? <CorrectPanel own={own.top5} inScan={[]} current={null} burst={false} manual={!!cor} onClose={() => setCorrecting(false)}
                onApply={(sci) => onCorrect({ sci })} onUndo={() => onCorrect({ undo: true })} />
            : <button type="button" className="btn slim" onClick={() => setCorrecting(true)}>{t("singles.correct")}</button>)}
          {rec.stale && <p className="hint">{t("singles.stale")}
            <button className="btn link" disabled={!!busy} onClick={() => onAct({})}>{t("singles.again")}</button></p>}
          <p className="facts-inline">
            <strong>{b.p_fly == null ? t("singles.pose_unknown") : b.p_fly >= 0.5 ? t("singles.flying") : t("singles.perched")}</strong>
            {i === r.subject && r.rarity ? <><span>{t("singles.local_month")}<strong>{rarityText(r.rarity.label)}</strong></span>{r.rarity.iucn && <span>IUCN {r.rarity.iucn}</span>}</>
              : <span>{t("singles.rarity_none")}</span>}
            {b.clear === false && <span>{t("singles.unclear")}</span>}
          </p>
          {multi && (
            <div className="bird-switch" role="group" aria-label={t("singles.switch")}>
              {shown.map(({ k }, n) => <button key={k} type="button" aria-pressed={k === i} onClick={() => onAct({ subject: k }, "")}>{t("singles.nth", { n: n + 1 })}</button>)}
              <span className="hint">{t("singles.click_hint")}</span>
            </div>
          )}
          <div className="legend"><span><i className="l-box"></i>{rec.boxes ? t("singles.drawn_box") : t("singles.box")}</span>
            {b.eye && (b.eye_p ?? 0) >= 0.5 && <span><i className="l-eye"></i>{t("singles.eye")}</span>}
            {multi && <span><i className="l-off"></i>{t("singles.other_boxes")}</span>}
            <button className="btn link" style={{ minHeight: 0, padding: 0 }} onClick={() => { setDrawing(true); setBox(null); }}>{t("singles.redraw")}</button></div>
          <section className="result-section" aria-labelledby="cand-h">
            <h3 id="cand-h">{sure ? t("singles.others") : t("singles.top5")}</h3>
            <Candidates sp={sp!} skipFirst={sure} />
            <p className="hint">{sp?.geo ? t("singles.geo") : t("singles.no_geo")}</p>
          </section>
          <section className="result-section" aria-labelledby="exif-h">
            <h3 id="exif-h">{t("singles.exif")}</h3>
            <div className="settings"><span>{e?.focal_mm != null ? `${+e.focal_mm.toFixed(0)} mm` : "— mm"}</span> <span>f/{e?.aperture ?? "—"}</span>{" "}
              <span>{e?.shutter ?? "—"} s</span> <span>ISO {e?.iso ?? "—"}</span> <span>{e?.ev != null ? `${e.ev > 0 ? "+" : ""}${e.ev} EV` : "— EV"}</span></div>
            <dl className="facts"><dt>{t("singles.camera")}</dt><dd>{e?.camera ?? "—"}</dd><dt>{t("singles.lens")}</dt><dd>{e?.lens ?? "—"}</dd><dt>{t("singles.time")}</dt><dd>{fmtTime(e?.taken_at)}</dd><dt>{t("singles.file")}</dt><dd>{rec.name}</dd></dl>
          </section>
          <section className="result-section" aria-labelledby="region-h">
            <h3 id="region-h">{t("singles.region")}</h3>
            {e?.gps ? <div className="location"><span><PlaceName lat={e.gps[0]} lon={e.gps[1]} /></span><span className="hint">{t("singles.photo_gps")}</span></div>
              : askRegion ? <LocationPicker compact value={typeof rec.region === "object" ? rec.region : null} catalogue={catalogue}
                  onChange={(p) => { setAskRegion(false); onAct({ region: p ?? "" }); }} />
              : <div className="location">
                  <span className={rec.region ? "" : "hint"}>{rec.region ? <PlaceOf loc={rec.region} /> :t("singles.no_region")}</span>
                  <button className="btn" onClick={() => setAskRegion(true)}>{rec.region ? t("singles.change_place") : t("singles.add_place")}</button>
                </div>}
            {!e?.gps && <p className="hint">{t("singles.place_hint")}</p>}
          </section>
        </div>
      )}
    </section>
  );
}
