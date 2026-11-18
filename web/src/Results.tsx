import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { get, post } from "./api";
import type { Exif, PhotoResult, PhotoRow, Scan, Snapshot } from "./types";

export const STATE_LABEL: Record<string, string> = { queued: "排队中", running: "扫描中", stopping: "正在停止", paused: "已停止",
  finalizing: "正在汇总", completed: "已完成", failed: "出错已停" };
const ROW_LABEL: Record<string, string> = { queued: "排队中", working: "识别中", unscanned: "未扫描", failed: "处理失败" };
const PREVIEW_LABEL: Record<string, string> = { queued: "还在排队", working: "正在识别", unscanned: "未扫描", failed: "处理失败" };
type Phase = "scanning" | "paused" | "complete";
type RowState = "ready" | "queued" | "working" | "unscanned" | "failed";

// ---------- formatting ----------
const starTxt = (s: number) => (s === -1 ? "淘汰" : s === 0 ? "0 星" : "★".repeat(s) + "☆".repeat(3 - s));
const starLabel = (s: number | null) => (s === null ? "待定" : s === -1 ? "淘汰" : `${s} 星`);
const pct = (p: number) => `${Math.round(p * 100)}%`;
const evText = (ev: number | null) => (ev === null ? "— EV" : `${ev > 0 ? "+" : ""}${+ev.toFixed(1)} EV`);
const sharpTxt = (v: number | null | undefined) => (v == null ? "—" : v.toFixed(2));
const REGION: Record<string, string> = { eye: "眼睛周围", head: "头部", box: "整个鸟框" };
const fmtTime = (t: string | null | undefined) => (t ? t.slice(0, 19).replace("T", " ") : "时间未知");

export function nameOf(r: PhotoResult): string {
  if (r.rejected) return r.reject_reason || "没有找到鸟";
  const s = r.species;
  if (!s || s.level === "uncertain" || !s.label) return "不确定";
  if (s.level === "genus") return `${s.label.sci.replace(/ sp\.$/, "")} 属`;
  return s.label.zh || s.label.en || s.label.sci;
}
const confirmed = (r: PhotoResult | null) => !!r && !r.rejected && r.species?.level === "species" && !!r.species.label;
const speciesKey = (r: PhotoResult | null) => (confirmed(r) ? r!.species!.label!.sci : "");

function Settings({ e }: { e: Partial<Exif> | null | undefined }) {
  if (!e) return <div className="settings"><span>读取拍摄信息…</span></div>;
  return (
    <div className="settings">
      <span>{e.focal_mm != null ? `${+e.focal_mm.toFixed(0)} mm` : "— mm"}</span> <span>{e.aperture != null ? `f/${e.aperture}` : "f/—"}</span>{" "}
      <span>{e.shutter ? `${e.shutter} s` : "— s"}</span> <span>ISO {e.iso ?? "—"}</span> <span>{evText(e.ev ?? null)}</span>
    </div>
  );
}

function Marks({ r }: { r: PhotoResult }) {
  const at = (p: [number, number]) => ({ left: `${p[0] * 100}%`, top: `${p[1] * 100}%` });
  return (
    <>
      {r.boxes.map((d, i) => (
        <span key={i} className={`mk box${i === r.subject ? "" : " other"}`} style={{ left: `${d.box[0] * 100}%`, top: `${d.box[1] * 100}%`,
          width: `${(d.box[2] - d.box[0]) * 100}%`, height: `${(d.box[3] - d.box[1]) * 100}%` }} />
      ))}
      {r.eye && r.eye_visible && <span className="mk eye" style={at(r.eye)} />}
      {r.focus && <span className="mk af" style={at(r.focus)} />}
    </>
  );
}

function Photo({ row, marks, big, show, alt = "" }: { row: PhotoRow; marks: boolean; big?: boolean; show: boolean; alt?: string }) {
  const src = `/api/photos/${row.id}/${big ? "preview" : "thumb"}`;
  const r = row.result;
  if (!show) return <span className="ph"><span className="placeholder">{row.file}</span></span>;
  if (!r) return <span className="ph"><img src={src} alt={alt} loading="lazy" /></span>;
  return (
    <span className="ph">
      <span className={`frame ${r.width >= r.height ? "land" : "port"}`} style={{ aspectRatio: `${r.width} / ${r.height}` }}>
        <img src={src} alt={alt} loading="lazy" decoding="async" />
        {marks && <Marks r={r} />}
      </span>
    </span>
  );
}

function Legend({ r }: { r: PhotoResult }) {
  return (
    <div className="legend"><span><i className="l-box"></i>鸟框</span>{r.eye && r.eye_visible && <span><i className="l-eye"></i>眼睛</span>}
      {r.focus ? <span><i className="l-af"></i>相机对焦点</span> : <span>对焦点不可用</span>}</div>
  );
}

// ---------- export ----------
function exportRow(p: PhotoRow) {
  const r = p.result, e = r?.exif, s = r?.species, ok = confirmed(r);
  return {
    文件: p.file, 路径: p.path, 状态: p.state === "failed" ? "失败" : p.state === "done" ? "已识别" : "未扫描", 错误: p.error ?? "",
    星级: starLabel(p.stars), 理由: p.star_reason ?? "",
    中文名: ok ? s!.label!.zh ?? "" : "", 英文名: ok ? s!.label!.en ?? "" : "", 学名: s?.label?.sci ?? "",
    识别结果: r ? nameOf(r) : "", 识别层级: s?.level ?? "", 把握: s?.label?.p ?? s?.top5[0]?.p ?? "",
    候选: s ? s.top5.map((c) => `${c.zh ?? c.en} · ${c.sci} · ${pct(c.p)}`).join(" / ") : "",
    在飞: r?.flying == null ? "" : r.flying ? "是" : "否", 在飞概率: r?.p_fly ?? "",
    鸟框: r && r.subject != null ? r.boxes[r.subject].box.join(" ") : "", 眼睛位置: r?.eye?.join(" ") ?? "", 对焦点: r?.focus?.join(" ") ?? "",
    眼睛: r?.eye_visible == null ? "" : r.eye_visible ? "看得见" : "看不见", 头部清晰度: r?.sharpness ?? "", 清晰度测量处: r?.sharpness_region ?? "",
    美学分: r?.aesthetic ?? "", 清楚的鸟: r?.clear == null ? "" : r.clear ? "是" : "否",
    稀有度: r?.rarity ? r.rarity.tier : "待定", IUCN: r?.rarity?.iucn ?? "待定", 连拍组: p.burst_group ?? "", 组内排名: p.burst_rank ?? "", 连拍组张数: p.burst_size ?? "",
    相机: e?.camera ?? "", 镜头: e?.lens ?? "", 焦距毫米: e?.focal_mm ?? "", 光圈: e?.aperture ?? "", 快门秒: e?.shutter ?? "", ISO: e?.iso ?? "",
    曝光补偿EV: e?.ev ?? "", 对焦模式: e?.focus_mode ?? "", 拍摄时间: e?.taken_at ?? "", 拍摄时间显示: e?.taken_at ? fmtTime(e.taken_at) : "",
    地区: r?.region.source === "photo" ? `GPS ${r.region.gps!.map((v) => v.toFixed(5)).join(", ")}` : r?.region.name ?? "",
    地区来源: r?.region.source === "photo" ? "照片自带" : r?.region.source === "scan" ? "批次设定" : "",
  };
}
function save(name: string, text: string, type: string) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([text], { type }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}
function csv(rows: ReturnType<typeof exportRow>[]): string {
  if (!rows.length) return "﻿";
  const keys = Object.keys(rows[0]) as (keyof (typeof rows)[0])[];
  const q = (v: unknown) => {
    // text that a spreadsheet would run as a formula gets a leading apostrophe (numbers stay numbers); JSON keeps the original
    let t = String(v ?? "");
    if (typeof v === "string" && /^[=+\-@\t\r]/.test(t)) t = "'" + t;
    return /[",\r\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
  };
  return "﻿" + [keys.join(","), ...rows.map((o) => keys.map((k) => q(o[k])).join(","))].join("\n");
}

// ---------- the view ----------
export default function Results({ scanId, onBack }: { scanId: number; onBack: () => void }) {
  const [scan, setScan] = useState<Scan | null>(null);
  const [photos, setPhotos] = useState<PhotoRow[]>([]);
  const [error, setError] = useState("");
  const index = useRef(new Map<number, number>());
  const lastN = useRef(0);          // newest event seen (dedupe)
  const snapN = useRef(-1);         // cursor of the snapshot on screen: events at or below it are already in it
  const pending = useRef<{ rows: Map<number, { n: number; row: PhotoRow }>; scan: { n: number; data: Partial<Scan> } | null }>({ rows: new Map(), scan: null });
  const flushTimer = useRef<number | null>(null);

  const load = useCallback(async () => {
    const s = await get<Snapshot>(`/api/scans/${scanId}`);
    if (s.cursor < snapN.current) return s;                   // an older snapshot answered late: keep the newer one
    snapN.current = s.cursor;
    pending.current.rows.forEach((v, id) => { if (v.n <= s.cursor) pending.current.rows.delete(id); });
    if (pending.current.scan && pending.current.scan.n <= s.cursor) pending.current.scan = null;
    index.current = new Map(s.photos.map((p, i) => [p.id, i]));
    lastN.current = Math.max(lastN.current, s.cursor);
    setScan(s.scan);
    setPhotos(s.photos);
    return s;
  }, [scanId]);

  // snapshot, then the event stream from its cursor; events within 150 ms are applied together
  useEffect(() => {
    let es: EventSource | null = null, dead = false;
    const flush = () => {
      flushTimer.current = null;
      const { rows, scan: sc } = pending.current;
      pending.current = { rows: new Map(), scan: null };
      const live = [...rows.values()].filter((v) => v.n > snapN.current).sort((a, b) => a.n - b.n);
      if (live.length) setPhotos((old) => { const next = old.slice(); live.forEach(({ row }) => { const i = index.current.get(row.id); if (i !== undefined) next[i] = { ...next[i], ...row }; }); return next; });
      if (sc && sc.n > snapN.current) setScan((old) => (old ? { ...old, ...sc.data } : old));
    };
    const later = () => { flushTimer.current ??= window.setTimeout(flush, 150); };
    const fresh = (ev: MessageEvent) => { const n = Number(ev.lastEventId); if (n <= lastN.current) return false; lastN.current = n; return true; };
    load().then((s) => {
      if (dead || s.scan.state === "completed") return;
      es = new EventSource(`/api/scans/${scanId}/events?after=${s.cursor}`);
      es.addEventListener("photo", (ev) => { if (!fresh(ev)) return; const r = JSON.parse(ev.data) as PhotoRow; pending.current.rows.set(r.id, { n: Number(ev.lastEventId), row: r }); later(); });
      es.addEventListener("scan", (ev) => {
        if (!fresh(ev)) return;
        const d = JSON.parse(ev.data);
        pending.current.scan = { n: Number(ev.lastEventId), data: { state: d.state, error: d.error, counts: d.counts } };
        later();
        if (d.state === "completed") { es?.close(); load(); }
      });
      es.addEventListener("stars", (ev) => { if (fresh(ev)) load(); });
    }).catch((e) => setError(String(e.message)));
    return () => { dead = true; es?.close(); if (flushTimer.current) clearTimeout(flushTimer.current); };
  }, [scanId, load]);

  const phase: Phase = scan?.state === "completed" ? "complete" : scan && ["paused", "failed"].includes(scan.state) ? "paused" : "scanning";
  const complete = phase === "complete";
  const starsReady = complete && photos.some((p) => p.stars !== null);   // also true for a batch that is all 淘汰
  const rowState = (p: PhotoRow): RowState => (p.state === "done" ? "ready" : p.state === "failed" ? "failed"
    : p.state === "queued" && phase === "paused" ? "unscanned" : p.state);

  // filters
  const [fs, setFs] = useState("all");
  const [fsp, setFsp] = useState("");
  const [ffly, setFfly] = useState("all");
  const [sort, setSort] = useState("queue");
  const [showMarks, setShowMarks] = useState(true);
  const [selected, setSelected] = useState<number | null>(null);
  const sortTouched = useRef(false);
  useEffect(() => { if (starsReady && !sortTouched.current) setSort("star"); }, [starsReady]);

  const species = useMemo(() => {
    const m = new Map<string, string>();
    let unsure = false;
    for (const p of photos) {
      if (confirmed(p.result)) m.set(speciesKey(p.result), nameOf(p.result!));
      else if (p.result && !p.result.rejected) unsure = true;
    }
    return { list: [...m].sort((a, b) => a[1].localeCompare(b[1], "zh-CN")), unsure };
  }, [photos]);

  const view = useMemo(() => {
    const usesResults = fsp || ffly !== "all";
    const v = photos.filter((p) => {
      if (starsReady && fs !== "all" && p.stars !== +fs) return false;
      if (!usesResults) return true;
      const r = p.result;
      if (!r || r.rejected) return false;
      return (!fsp || (fsp === "unsure" ? !confirmed(r) : speciesKey(r) === fsp)) && (ffly === "all" || (ffly === "fly") === !!r.flying);
    });
    const ready = (p: PhotoRow) => (p.result ? 1 : 0);
    const cmp: Record<string, (a: PhotoRow, b: PhotoRow) => number> = {
      queue: (a, b) => a.seq - b.seq,
      time: (a, b) => (a.result?.exif.taken_at ?? "~").localeCompare(b.result?.exif.taken_at ?? "~") || a.seq - b.seq,
      star: (a, b) => (b.stars ?? -2) - (a.stars ?? -2) || a.seq - b.seq,
      species: (a, b) => nameOf(a.result!).localeCompare(nameOf(b.result!), "zh-CN") || a.seq - b.seq,
      fly: (a, b) => (b.result?.p_fly ?? 0) - (a.result?.p_fly ?? 0),
      eye: (a, b) => (b.result?.sharpness ?? -1) - (a.result?.sharpness ?? -1),
    };
    if (sort === "queue" || sort === "time" || sort === "star") v.sort(cmp[sort]);
    else v.sort((a, b) => ready(b) - ready(a) || (ready(a) && ready(b) ? cmp[sort](a, b) : a.seq - b.seq));
    return v;
  }, [photos, fs, fsp, ffly, sort, starsReady]);

  const current = view.find((p) => p.id === selected) ?? view[0] ?? null;
  const tiles = useRef(new Map<number, HTMLButtonElement>());

  // on-demand shooting info for a selected photo that has not been processed yet
  const [exifs, setExifs] = useState<Record<number, Exif>>({});
  useEffect(() => {
    if (!current || current.result || exifs[current.id]) return;
    get<Exif>(`/api/photos/${current.id}/exif`).then((e) => setExifs((x) => ({ ...x, [current.id]: e }))).catch(() => {});
  }, [current, exifs]);

  // dialogs
  const detailRef = useRef<HTMLDialogElement>(null);
  const exportRef = useRef<HTMLDialogElement>(null);
  const [detailId, setDetailId] = useState<number | null>(null);
  const [exportFiltered, setExportFiltered] = useState(false);
  const readyView = view.filter((p) => p.result);
  const openDetail = (p: PhotoRow | null | undefined) => {
    if (!p || !p.result) return;
    setDetailId(p.id);
    if (!detailRef.current?.open) detailRef.current?.showModal();
  };
  const turn = (d: number) => { const i = readyView.findIndex((p) => p.id === detailId); if (i >= 0) openDetail(readyView[i + d]); };

  const act = async () => {
    if (!scan) return;
    try {
      const r = await post<{ state: Scan["state"] }>(`/api/scans/${scanId}/${phase === "paused" ? "resume" : "stop"}`);
      setScan((s) => (s ? { ...s, state: r.state } : s));
    } catch (e) { setError(String((e as Error).message)); }
  };

  if (error && !scan) return <p className="error-text">{error}</p>;
  if (!scan) return <p className="hint">读取中…</p>;
  // counts come from the rows on screen: scan events only arrive on state changes, photo events on every result
  const c = { total: photos.length, done: photos.filter((p) => p.state === "done").length, failed: photos.filter((p) => p.state === "failed").length };
  const finished = c.done + c.failed;
  const rejected = photos.filter((p) => p.result?.rejected).length;
  const copy = complete ? `已完成 · ${c.total} 张${c.failed ? `（${c.failed} 张失败）` : ""}`
    : `${phase === "paused" ? (scan.state === "failed" ? "出错已停" : "已停止") : scan.state === "stopping" ? "正在停止" : scan.state === "finalizing" ? "正在汇总" : "扫描中"} · 已完成 ${finished} / ${c.total}`;
  const step = complete ? "" : scan.state === "failed" ? ` · ${scan.error ?? ""}` : phase === "paused" ? " · 等待继续"
    : scan.state === "stopping" ? " · 这一批做完就停" : scan.state === "queued" ? " · 等前一个扫描完成" : scan.state === "finalizing" ? " · 分连拍组" : " · 找鸟、认种、看眼睛和姿态";
  const date = photos.find((p) => p.result?.exif.taken_at)?.result?.exif.taken_at;
  const dp = detailId !== null ? photos[index.current.get(detailId) ?? -1] : undefined;
  const di = dp ? readyView.findIndex((p) => p.id === dp.id) : -1;

  return (
    <section id="s-res" data-phase={phase} aria-labelledby="h-res">
      <div className="topbar">
        <div><h2 id="h-res" tabIndex={-1}>审片结果</h2>
          <span className="sub">{scan.region ?? "未选地区"}{date ? ` · ${date.slice(0, 10)}` : ""}{scan.recursive ? " · 包含子文件夹" : ""} · {scan.folder}</span></div>
        <div className="row"><button className="btn link" onClick={onBack}>换一批</button>
          <button className="btn primary" disabled={!complete} onClick={() => exportRef.current?.showModal()}>导出</button></div>
      </div>

      <div className="scan-status">
        <p><span id="scan-copy" role="status">{copy}</span><span>{step}</span></p>
        {!complete && scan.state !== "finalizing" && (
          <button type="button" className="btn" onClick={act} disabled={scan.state === "stopping"}>{phase === "paused" ? "继续" : "停止"}</button>
        )}
        {!complete && <progress value={finished} max={c.total || 1} aria-label="扫描进度" />}
      </div>

      <div className="summary" data-complete={complete}>
        {complete ? (
          <>
            <div><b>{c.total}</b><small>张照片</small></div>
            {[3, 2, 1, 0].map((s) => (
              <div key={s}><b>{starsReady ? photos.filter((p) => p.stars === s).length : "—"}</b>
                <small className="stars" aria-label={`${s} 星`}>{s ? "★".repeat(s) : "0 星"}{!starsReady && " 待定"}</small></div>
            ))}
            <div><b>{rejected}</b><small>淘汰</small></div>
          </>
        ) : <div><b>{finished} / {c.total}</b><small>已扫描照片</small></div>}
        <div><b>{species.list.length}</b><small>已认出的鸟种</small></div>
        <div><b className="rare-name">待定</b><small>少见和罕见（稀有度表调研中）</small></div>
      </div>

      <div className="filters" role="group" aria-label="筛选和排序">
        <div className="seg" role="radiogroup" aria-label="星级" aria-disabled={!starsReady}>
          {[["all", "全部"], ["3", "三星"], ["2", "两星"], ["1", "一星"], ["0", "0 星"], ["-1", "淘汰"]].map(([v, t]) => (
            <label key={v}><input type="radio" name="fs" value={v} checked={fs === v} disabled={!starsReady} onChange={() => setFs(v)} /><span>{t}</span></label>
          ))}
        </div>
        <select aria-label="鸟种" value={fsp} onChange={(e) => setFsp(e.target.value)}>
          <option value="">所有鸟种</option>
          {species.list.map(([k, n]) => <option key={k} value={k}>{n}</option>)}
          {species.unsure && <option value="unsure">不确定或只到属</option>}
        </select>
        <select aria-label="稀有度" disabled title="稀有度待定"><option>稀有度 · 待定</option></select>
        <select aria-label="是否在飞" value={ffly} onChange={(e) => setFfly(e.target.value)}>
          <option value="all">所有姿态</option><option value="fly">在飞</option><option value="still">不在飞</option>
        </select>
        <label className="inline">排序
          <select value={sort} onChange={(e) => { sortTouched.current = true; setSort(e.target.value); }}>
            <option value="queue">队列顺序</option>
            <option value="star" disabled={!starsReady}>星级高的在前</option>
            <option value="time">拍摄时间</option>
            <option value="species">按鸟种排序</option>
            <option value="fly">在飞的在前</option>
            <option value="rar" disabled>稀有的在前（待定）</option>
            <option value="eye">头部清晰的在前</option>
          </select>
        </label>
        <label className="inline"><input type="checkbox" checked={showMarks} onChange={(e) => setShowMarks(e.target.checked)} /> 显示标记</label>
        {!starsReady && <p className="hint">星级要等全部照片扫完后互相比较才能定。</p>}
      </div>

      <div className="inspection">
        <section className="list" aria-labelledby="list-title">
          <div className="list-head"><h3 id="list-title">照片列表</h3><span aria-live="polite">显示 {view.length} / {c.total} 张</span></div>
          <p className="sr-only" id="photo-keys">上、下方向键选择照片，回车查看已扫描照片的详情。</p>
          <div id="grid" onKeyDown={(e) => {
            const i = view.findIndex((p) => p.id === current?.id);
            if (e.key === "Enter") { e.preventDefault(); openDetail(view[i]); return; }
            if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;
            e.preventDefault();
            const p = view[i + (e.key === "ArrowDown" ? 1 : -1)];
            if (!p) return;
            setSelected(p.id);
            tiles.current.get(p.id)?.focus();
          }}>
            {view.length ? view.map((p) => {
              const st = rowState(p), r = p.result, active = p.id === current?.id;
              const name = r ? nameOf(r) : ROW_LABEL[st];
              const e = r?.exif ?? exifs[p.id];
              return (
                <button key={p.id} type="button" className="tile" data-state={st} aria-pressed={active} tabIndex={active ? 0 : -1}
                  aria-describedby="photo-keys" aria-label={`${name}，${complete ? starLabel(p.stars) : "待定星级"}，${p.file}`}
                  ref={(el) => { if (el) tiles.current.set(p.id, el); else tiles.current.delete(p.id); }}
                  onClick={() => { setSelected(p.id); if (r && matchMedia("(max-width: 720px)").matches) openDetail(p); }}>
                  <Photo row={p} marks={showMarks} show={!!r || active} />
                  <span className="row-result"><span className={r ? "name" : "scan-name"}>{name}</span><br />
                    {complete && p.stars !== null ? <span className="stars">{starTxt(p.stars)}</span> : <span className="pending-stars">待定星级</span>}
                    {r && !r.rejected && r.flying !== null && <span className="pill">{r.flying ? "在飞" : "不在飞"}</span>}
                    {r && <span className="small reason-line" style={{ display: "block" }}>
                      {complete && p.star_reason ? p.star_reason : r.rejected ? "不参与标星" : r.eye_visible ? `眼睛可见 · 头部清晰度 ${sharpTxt(r.sharpness)}` : "眼睛未找到"}</span>}
                    {st === "failed" && <span className="small reason-line" style={{ display: "block" }}>{p.error}</span>}
                  </span>
                  <span className="row-settings"><span className="file">{p.file}</span><br />
                    {e && <span className="small">{e.focal_mm != null ? `${+e.focal_mm.toFixed(0)} mm` : "—"} · f/{e.aperture ?? "—"} · {e.shutter ?? "—"} s<br />ISO {e.iso ?? "—"} · {evText(e.ev)}</span>}</span>
                </button>
              );
            }) : <p className="empty">{c.total ? "没有符合条件的照片。" : "这个文件夹里没有 ARW、DNG 或 JPG 照片。"}</p>}
          </div>
        </section>
        {current && <Inspector p={current} st={rowState(current)} marks={showMarks} exif={current.result?.exif ?? exifs[current.id]} onOpen={() => openDetail(current)} />}
      </div>

      <dialog ref={detailRef} aria-labelledby="d-title" onClose={() => { if (detailId !== null) { setSelected(detailId); tiles.current.get(detailId)?.focus({ preventScroll: true }); } }}
        onKeyDown={(e) => { if (e.key === "ArrowLeft") { e.preventDefault(); turn(-1); } if (e.key === "ArrowRight") { e.preventDefault(); turn(1); } }}>
        <div className="dlg-head">
          <h3 id="d-title">{dp ? `${dp.file}（${di + 1} / ${readyView.length}）` : ""}</h3>
          <button className="btn" onClick={() => turn(-1)} disabled={di <= 0}>上一张</button>
          <button className="btn" onClick={() => turn(1)} disabled={di < 0 || di >= readyView.length - 1}>下一张</button>
          <button className="btn" onClick={() => detailRef.current?.close()}>关闭</button>
        </div>
        {dp?.result && <Detail p={dp} r={dp.result} complete={complete} />}
      </dialog>

      <dialog ref={exportRef} aria-labelledby="e-title" style={{ maxWidth: 560 }}>
        <div className="dlg-head"><h3 id="e-title">导出</h3><button className="btn" onClick={() => exportRef.current?.close()}>关闭</button></div>
        <div className="dlg-body">
          <label className="row" style={{ marginBottom: 14 }}><input type="checkbox" checked={exportFiltered} onChange={(e) => setExportFiltered(e.target.checked)} /> 只导出当前筛选出的 {view.length} 张</label>
          <div className="exp-list">
            <div className="exp-item"><div className="what">表格（CSV）<small>每张照片一行，可用 Excel / Numbers 打开</small></div>
              <button className="btn primary" onClick={() => save("选片结果.csv", csv((exportFiltered ? view : photos).map(exportRow)), "text/csv")}>导出</button></div>
            <div className="exp-item"><div className="what">数据（JSON）<small>字段同上，给程序用</small></div>
              <button className="btn" onClick={() => save("选片结果.json", JSON.stringify((exportFiltered ? view : photos).map(exportRow), null, 2), "application/json")}>导出</button></div>
            <div className="exp-item later"><div className="what">观鸟清单<small>每个鸟种一行，带数量、日期、地点</small></div><span className="tbd">以后 · 待定</span></div>
            <div className="exp-item later"><div className="what">写给 Lightroom<small>把星级和鸟种写进旁边的 XMP 文件</small></div><span className="tbd">以后 · 待定</span></div>
            <div className="exp-item later"><div className="what">网页报告<small>自己看的一页总结</small></div><span className="tbd">以后 · 待定</span></div>
          </div>
          <p className="hint" style={{ marginTop: 14 }}>导出的文件存到你选的位置，原片文件夹里不写任何东西。</p>
        </div>
      </dialog>
    </section>
  );
}

function Inspector({ p, st, marks, exif, onOpen }: { p: PhotoRow; st: RowState; marks: boolean; exif?: Exif; onOpen: () => void }) {
  const r = p.result, ready = st === "ready" && !!r;
  const name = r ? nameOf(r) : PREVIEW_LABEL[st];
  const image = <Photo row={p} marks={ready && marks} big show alt={ready ? name : p.file} />;
  return (
    <aside className="inspector" aria-label="所选照片预览">
      {ready ? <button className="preview-photo" type="button" aria-label="放大照片，查看详情" onClick={onOpen}>{image}</button>
        : <div className="preview-photo pending">{image}</div>}
      <div className="preview-info">
        <div className="preview-top"><h3>{name}</h3>{ready && <button type="button" className="btn" onClick={onOpen}>查看详情</button>}</div>
        <Settings e={exif} />
        <p className="preview-time">{fmtTime(exif?.taken_at)} · {p.file}</p>
        {ready ? (marks && <Legend r={r!} />)
          : <p className="preview-note">{st === "failed" ? p.error : st === "unscanned" ? "继续扫描后会在这里显示识别结果。" : "识别完成后会在这里显示鸟种和标记。"}</p>}
      </div>
    </aside>
  );
}

function Detail({ p, r, complete }: { p: PhotoRow; r: PhotoResult; complete: boolean }) {
  const s = r.species, e = r.exif, sure = confirmed(r);
  return (
    <div className="dlg-body detail">
      <div>
        <Photo row={p} marks big show alt={nameOf(r)} />
        <Legend r={r} />
        <section className="exif" aria-label="拍摄信息"><h3>拍摄信息</h3><Settings e={e} />
          <dl className="facts">
            <dt>相机</dt><dd>{e.camera ?? "—"}</dd><dt>镜头</dt><dd>{e.lens ?? "—"}</dd>
            <dt>对焦模式</dt><dd>{e.focus_mode ?? "—"}</dd><dt>拍摄时间</dt><dd>{fmtTime(e.taken_at)}</dd>
            <dt>地区</dt><dd>{r.region.source === "photo" ? `GPS ${r.region.gps!.map((v) => v.toFixed(4)).join(", ")}` : r.region.name ?? "—"}{" "}
              <span className="ref">· {r.region.source === "photo" ? "照片自带" : "批次设定"}</span></dd>
            <dt>文件</dt><dd className="ref">{p.path}</dd>
          </dl>
        </section>
      </div>
      <div>
        <div className="verdict stars">{complete && p.stars !== null ? starTxt(p.stars) : "待定星级"}</div>
        {complete && p.star_reason && <p className="reason">{p.star_reason}</p>}
        {r.rejected ? <><div className="sp-cn">{r.reject_reason ?? "没有找到鸟"}</div>
          <p className="hint">{r.boxes.length ? `检测到 ${r.boxes.length} 个框，但都没有通过"清楚的鸟"判断，标为淘汰。` : "检测模型在这张照片里没有找到鸟，标为淘汰。"}</p></>
          : s ? <>
            <div className="sp-cn">{nameOf(r)}</div>
            {sure && <div className="sp-en">{s.label!.en} · <span className="sp-sci">{s.label!.sci}</span></div>}
            {s.level === "genus" && <div className="sp-en">只认到属 · <span className="sp-sci">{s.label!.sci}</span></div>}
            <div>{sure ? "把握" : "最高候选"} {pct(sure || s.level === "genus" ? s.label!.p : s.top5[0].p)} <span className="ref">· 仅凭图像，地区修正待定</span></div>
            <details open={!sure}><summary>前 5 个候选</summary>
              <ol>{s.top5.map((c) => <li key={c.sci}>{c.zh ?? c.en} {c.zh ? c.en : ""} <i>{c.sci}</i> — {pct(c.p)}</li>)}</ol></details>
          </> : null}
        <dl className="facts">
          <dt>在飞</dt><dd>{r.flying == null ? "—" : r.flying ? "是" : "否"}{r.p_fly != null && <span className="ref"> · P = {r.p_fly.toFixed(2)}</span>}</dd>
          <dt>眼睛</dt><dd>{r.eye_visible == null ? "—" : r.eye_visible ? "看得见" : "看不见"}</dd>
          <dt>头部清晰度</dt><dd>{sharpTxt(r.sharpness)}{r.sharpness_region && <span className="ref"> · 量在{REGION[r.sharpness_region]}，只在本批内比较（阈值未标定）</span>}</dd>
          <dt>美学分</dt><dd>{r.aesthetic != null ? r.aesthetic.toFixed(2) : "—"} <span className="ref">仅供参考，不单独用来选片</span></dd>
          <dt>稀有度</dt><dd><span className="tbd">待定</span></dd>
          <dt>受威胁等级</dt><dd><span className="tbd">待定</span></dd>
          <dt>连拍组</dt><dd>{p.burst_group ? `第 ${p.burst_group} 组，组内第 ${p.burst_rank} / ${p.burst_size} 张` : "扫完后分组"}</dd>
          <dt>鸟框</dt><dd>{r.boxes.length} 个{r.boxes.length > 1 && r.subject != null ? `，主体按${r.focus ? "对焦点" : "把握"}选取` : ""}</dd>
        </dl>
      </div>
    </div>
  );
}
