// 看大图: one photo or two side by side, fit or zoomed to 100 % and dragged; both panes follow one viewport.
// The full-size photo (/full) is fetched only once a pane is zoomed; until then, and while it loads, the 2048 preview
// stands in at the same place.
import type { Dispatch, KeyboardEvent, PointerEvent as RPointerEvent, SetStateAction, SyntheticEvent } from "react";
import { forwardRef, useEffect, useLayoutEffect, useRef, useState } from "react";
import { actual, FIT, headOf, layout, panBy, scaleOf, type Size, starOf, toggle, type View, zoomAt } from "./look";
import type { MarkSet } from "./names";
import type { PhotoResult, PhotoRow } from "./types";
import { t } from "./i18n";

export function Marks({ r, m }: { r: PhotoResult; m: MarkSet }) {
  const at = (p: [number, number]) => ({ left: `${p[0] * 100}%`, top: `${p[1] * 100}%` });
  return (
    <>
      {m.box && r.boxes.map((d, i) => (
        <span key={i} className={`mk box${i === r.subject ? "" : " other"}`} style={{ left: `${d.box[0] * 100}%`, top: `${d.box[1] * 100}%`,
          width: `${(d.box[2] - d.box[0]) * 100}%`, height: `${(d.box[3] - d.box[1]) * 100}%` }} />
      ))}
      {m.eye && r.eye && r.eye_visible && <span className="mk eye" style={at(r.eye)} />}
      {m.beak && r.beak && (r.beak_p ?? 0) >= 0.5 && <span className="mk beak" style={at(r.beak)} />}
      {m.focus && r.focus && <span className="mk af" style={at(r.focus)} />}
    </>
  );
}

/** 淘汰 / 0-3 / 撤回 for these photos (one request however many); `on` marks the person's own stars. */
export function StarSet({ on, undo, onStars, label = t("viewer.set_stars") }: { on: number | null; undo: boolean; onStars: (s: number | null) => void; label?: string }) {
  return (
    <div className="star-set" role="group" aria-label={label}>
      {[-1, 0, 1, 2, 3].map((v) => (
        <button key={v} type="button" className="btn slim" aria-pressed={on === v} onClick={() => onStars(v)}>{v === -1 ? t("viewer.reject") : v === 0 ? t("viewer.zero") : "★".repeat(v)}</button>
      ))}
      {undo && <button type="button" className="btn slim link" onClick={() => onStars(null)}>{t("viewer.undo")}</button>}
    </div>
  );
}

const fullUrl = (scanId: number, p: PhotoRow) => `/api/scans/${scanId}/photos/${p.id}/full?v=${p.size}-${p.mtime_ns}`;

function Pane({ scanId, row, view, setView, marks, active, onActive }: {
  scanId: number; row: PhotoRow; view: View; setView: Dispatch<SetStateAction<View>>;
  marks: MarkSet | null; active?: boolean; onActive?: () => void;
}) {
  const r = row.result!;
  const img: Size = { w: r.width, h: r.height };
  const el = useRef<HTMLDivElement>(null);
  const [pane, setPane] = useState<Size>({ w: 0, h: 0 });
  useLayoutEffect(() => {
    const b = el.current!.getBoundingClientRect();
    setPane({ w: b.width, h: b.height });
    const ro = new ResizeObserver(([e]) => setPane({ w: e.contentRect.width, h: e.contentRect.height }));
    ro.observe(el.current!);
    return () => ro.disconnect();
  }, []);
  // the wheel zooms about the pointer (a trackpad pinch arrives as a wheel with ctrlKey); React's onWheel is passive
  const live = useRef({ pane, img });
  live.current = { pane, img };
  useEffect(() => {
    const node = el.current!;
    const wheel = (e: WheelEvent) => {
      e.preventDefault();
      const { pane: p, img: i } = live.current, b = node.getBoundingClientRect();
      const k = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.002));
      setView((v) => zoomAt(v, p, i, e.clientX - b.left, e.clientY - b.top, scaleOf(v, p, i) * k));
    };
    node.addEventListener("wheel", wheel, { passive: false });
    return () => node.removeEventListener("wheel", wheel);
  }, [setView]);
  // drag pans; a press that does not move is a click: fit <-> 100 % at that point
  const drag = useRef<{ x: number; y: number; moved: number } | null>(null);
  const down = (e: RPointerEvent<HTMLDivElement>) => { if (e.button) return; e.currentTarget.setPointerCapture(e.pointerId); drag.current = { x: e.clientX, y: e.clientY, moved: 0 }; };
  const move = (e: RPointerEvent<HTMLDivElement>) => {
    const d = drag.current;
    if (!d) return;
    const dx = e.clientX - d.x, dy = e.clientY - d.y;
    d.x = e.clientX; d.y = e.clientY; d.moved += Math.abs(dx) + Math.abs(dy);
    if (d.moved > 3) setView((v) => panBy(v, pane, img, dx, dy));
  };
  const up = (e: RPointerEvent<HTMLDivElement>) => {
    const d = drag.current;
    drag.current = null;
    if (!d || d.moved > 3) return;
    const b = e.currentTarget.getBoundingClientRect();
    setView((v) => toggle(v, pane, img, null, e.clientX - b.left, e.clientY - b.top));
  };
  // the full-size photo: asked for the first time this pane is zoomed (a pane is one photo: keyed by its id)
  const [want, setWant] = useState(false);
  const [shown, setShown] = useState<number | null>(null);         // ms from asking to on screen
  const t0 = useRef(0);
  useEffect(() => { if (!view.fit && !want) { t0.current = performance.now(); setWant(true); } }, [view.fit, want]);
  const loaded = (e: SyntheticEvent<HTMLImageElement>) => {
    const im = e.currentTarget;
    im.decode().catch(() => {}).then(() => {
      const ms = Math.round(performance.now() - t0.current);
      console.info(`[birdcm] full size ${row.file}: visible after ${ms} ms`);
      setShown(ms);
    });
  };
  const l = pane.w ? layout(view, pane, img) : null;
  const full = shown !== null;
  return (
    <div ref={el} className={`zoom${view.fit ? "" : " zoomed"}${active ? " active" : ""}`} onPointerDown={down} onPointerMove={move} onPointerUp={up}
      onPointerCancel={() => { drag.current = null; }} onPointerEnter={onActive}>
      {l && (
        <div className="zf" style={{ left: l.left, top: l.top, width: l.width, height: l.height }}>
          <img src={`/api/photos/${row.id}/preview?v=${row.size}-${row.mtime_ns}`} alt={row.file} draggable={false} />
          {want && <img src={fullUrl(scanId, row)} alt="" draggable={false} onLoad={loaded} style={{ opacity: full ? 1 : 0 }} />}
          {marks && <Marks r={r} m={marks} />}
        </div>
      )}
      <span className="zoom-tag">{l ? `${Math.round((l.s / actual()) * 100)}%` : ""}{want && !full ? t("viewer.loading_full") : full ? t("viewer.full", { s: (shown! / 1000).toFixed(1) }) : ""}</span>
    </div>
  );
}

const starTxt = (s: number | null) => (s === null ? t("viewer.pending") : s === -1 ? t("viewer.reject") : s === 0 ? t("viewer.zero") : "★".repeat(s) + "☆".repeat(3 - s));

/** The large-photo dialog. `b` set: compare `a` with `b` (stars per pane, ← → walk `b` through `pool`). */
export const Viewer = forwardRef<HTMLDialogElement, {
  scanId: number; a: PhotoRow | null; b: PhotoRow | null; pool: PhotoRow[]; marks: MarkSet; complete: boolean;
  onStep: (d: number) => void; onStars: (ids: number[], s: number | null) => void; setStars: (ids: number[], s: number | null) => void;
  onCompare: (id: number | null) => void; neighbour: number | null;
}>(function Viewer({ scanId, a, b, pool, marks, complete, onStep, onStars, setStars, onCompare, neighbour }, ref) {
  const [view, setViewRaw] = useState<View>(FIT);
  const [side, setSide] = useState(0);                               // the compare pane the keys act on
  // keys and buttons act on one pane (the one under the pointer when comparing): its size from the page
  const paneSet = (row: PhotoRow) => (f: (v: View, pane: Size, img: Size) => View) => {
    const node = document.querySelector<HTMLElement>(`[data-pane="${row.id}"] .zoom`);
    const pane = { w: node?.clientWidth ?? 1, h: node?.clientHeight ?? 1 }, img = { w: row.result!.width, h: row.result!.height };
    setViewRaw((v) => f(v, pane, img));
  };
  const rows = [a, b].filter((p): p is PhotoRow => !!p);
  const zoomable = rows.every((p) => p.result);
  const target = b ? rows[side] ?? a : a;
  const head = () => target && headOf(target.result);
  const key = (e: KeyboardEvent) => {
    if (!a) return;
    const s = starOf(e);
    if (s !== undefined && complete && target?.result) {
      e.preventDefault();
      if (b) setStars([target.id], s); else onStars([a.id], s);
      return;
    }
    if (e.metaKey || e.ctrlKey || e.altKey) return;                 // Cmd+C copies, it does not compare
    const k = e.key.toLowerCase();
    if (zoomable && (k === "z" || k === "e")) {
      e.preventDefault();
      paneSet(target!)((v, p, i) => (k === "z" ? toggle(v, p, i, head()) : toggle(FIT, p, i, head())));
      return;
    }
    if (k === "c") { e.preventDefault(); onCompare(b ? null : neighbour); return; }
    const d = ({ ArrowLeft: -1, ArrowUp: -1, ArrowRight: 1, ArrowDown: 1 } as Record<string, number>)[e.key];
    if (!d) return;
    e.preventDefault();
    if (!b) { onStep(d); return; }
    const others = pool.filter((p) => p.id !== a.id), i = others.findIndex((p) => p.id === b.id);
    const next = others[Math.max(0, Math.min(others.length - 1, i + d))];
    if (next && next.id !== b.id) onCompare(next.id);
  };
  return (
    <dialog ref={ref} className={`viewer${b ? " compare" : ""}`} aria-label={b ? t("viewer.compare_label") : t("viewer.large")} onKeyDown={key}
      onClose={() => { setViewRaw(FIT); setSide(0); onCompare(null); }}
      onClick={(e) => { if (e.target === e.currentTarget) e.currentTarget.close(); }}>
      <div className="dlg-head"><h3>{b ? t("viewer.compare_title", { a: a?.file ?? "", b: b.file }) : a?.file}</h3>
        <span className="hint">{b ? t("viewer.keys_compare") : t("viewer.keys_one")}{t("viewer.keys_mid")}{b ? t("viewer.keys_close_compare") : t("viewer.keys_open_compare")}{t("viewer.keys_end")}</span>
        {!b && neighbour !== null && <button className="btn" onClick={() => onCompare(neighbour)}>{t("viewer.compare_neighbour")}</button>}
        {zoomable && a && <button className="btn" onClick={() => paneSet(target!)((_v, p, i) => toggle(FIT, p, i, head()))} disabled={!head()}>{t("viewer.to_eye")}</button>}
        <button className="btn" onClick={(e) => (e.currentTarget.closest("dialog") as HTMLDialogElement).close()}>{t("viewer.close")}</button></div>
      {a && (
        <div className="look">
          {rows.map((p, i) => (
            <figure key={p.id} className="look-pane" data-pane={p.id}>
              {b && <figcaption><b>{p.file}</b> <span className="stars">{complete ? starTxt(p.stars) : t("viewer.pending_stars")}</span>
                {p.star_auto && <span className="pill">{t("viewer.manual_stars")}</span>}
                {complete && p.result && <StarSet on={p.star_auto ? p.stars : null} undo={!!p.star_auto} onStars={(s) => setStars([p.id], s)} />}</figcaption>}
              {p.result ? <Pane scanId={scanId} row={p} view={view} setView={setViewRaw} marks={marks} active={!!b && side === i} onActive={() => setSide(i)} />
                : <img className="look-plain" src={`/api/photos/${p.id}/preview?v=${p.size}-${p.mtime_ns}`} alt={p.file} />}
            </figure>
          ))}
        </div>
      )}
    </dialog>
  );
});
