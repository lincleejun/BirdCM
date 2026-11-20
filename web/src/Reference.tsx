// 物种参考 on the species page (docs/design-species-search.md §4.4, §4.5, §4.8, §8; owner decisions 2026-11-18): the
// Wikipedia summary and one Commons reference image, fetched by the engine on demand and shown under the person's own
// photos, each card on its own with its attribution, its cache date and its own retry. Online is on by default; the
// first use shows the disclosure. Only the species' ids and titles leave the machine (the engine sends them).
import { useEffect, useState } from "react";
import { del, get, post } from "./api";

interface Card {
  state: "ok" | "stale" | "none" | "unmapped" | "off" | "unavailable" | "busy" | "missing"; why?: string; problem?: string;
  cached_at?: string; due?: boolean; lang?: string; title?: string; text?: string; source_url?: string; history_url?: string;
  revision?: string; licence?: string; licence_url?: string; credit?: string; changes?: string; author?: string | null; nc?: boolean;
  attribution?: string; width?: number; height?: number;
}
interface Reference { summary: Card; image: Card; links: { name: string; url: string }[] }
interface Settings { enabled: boolean; disclosed: boolean; places: boolean; updates: boolean; disclosure: string }
type Kind = "summary" | "image";

const ext = { target: "_blank", rel: "noopener noreferrer" } as const;

function problem(c: Card, retry: () => void, what: string) {
  const text = c.state === "unmapped" ? c.why ?? "资料未对应"
    : c.state === "none" ? c.why ?? `暂无${what}`
    : c.state === "off" ? "在线资料已关闭；打开后才会联网取" : c.state === "missing" ? "正在取在线资料…"
    : c.state === "busy" || c.problem === "busy" ? "来源请求较多，稍后可重试" : "在线资料暂不可用（可能离线）";
  const again = c.state === "unavailable" || c.state === "busy" || c.problem || c.state === "none";
  return <p className="hint" role="status">{text}{c.cached_at && c.state !== "none" ? `（显示 ${c.cached_at} 的缓存）` : ""}
    {again && <> <button className="btn link" onClick={retry}>重试</button></>}</p>;
}

export default function SpeciesReference({ sci, own }: { sci: string; own: number }) {
  const [s, setS] = useState<Settings | null>(null);
  const [r, setR] = useState<Reference | null>(null);
  const [open, setOpen] = useState(false);
  const [imgOk, setImgOk] = useState(true);

  const refresh = (kinds: Kind[], force = false, dead = () => false) =>
    post<Reference>("/api/species/reference", { sci, kinds, force }).then((x) => !dead() && setR((old) => ({ ...(old ?? x), ...x })))
      .catch(() => !dead() && setR((old) => old && { ...old, ...Object.fromEntries(kinds.map((k) => [k, { state: "unavailable" }])) }));

  useEffect(() => {
    let dead = false;
    setR(null); setOpen(false); setImgOk(true);
    Promise.all([get<Settings>("/api/online/settings"), get<Reference>(`/api/species/reference?sci=${encodeURIComponent(sci)}`)]).then(([st, x]) => {
      if (dead) return;
      setS(st); setR(x);
      const due = (["summary", "image"] as Kind[]).filter((k) => x[k].due && x[k].state !== "unmapped");
      if (st.enabled && due.length) refresh(due, false, () => dead);
    }).catch(() => {});
    return () => { dead = true; };
  }, [sci]); // eslint-disable-line react-hooks/exhaustive-deps

  const setting = async (v: Partial<Settings>) => {
    const st = await post<Settings>("/api/online/settings", v);
    setS(st);
    if (v.enabled) refresh(["summary", "image"]);
  };
  const clearCache = async () => {
    await del("/api/online/cache");
    setR(await get<Reference>(`/api/species/reference?sci=${encodeURIComponent(sci)}`));
    if (s?.enabled) refresh(["summary", "image"]);
  };

  const off = (c?: Card): Card | undefined => c && c.state === "missing" && s && !s.enabled ? { ...c, state: "off" } : c;
  const img = off(r?.image), sum = off(r?.summary);
  const shown = (c?: Card) => c && (c.state === "ok" || c.state === "stale") && (c.text || c.licence);
  return (
    <div className="result-section ref-section" aria-labelledby="h-ref">
      <div className="row"><h3 id="h-ref">物种参考</h3>
        {s && <label className="inline"><input type="checkbox" checked={s.enabled} onChange={(e) => setting({ enabled: e.target.checked, disclosed: true })} /> 在线资料（Wikipedia / Wikimedia）</label>}
        {s && <label className="inline" title="只把经纬度（约 1 公里）发给 OpenStreetMap Nominatim；关闭后显示离线的地区名">
          <input type="checkbox" checked={s.places} onChange={(e) => setting({ places: e.target.checked })} /> 用网络显示地名（OpenStreetMap）</label>}
        {s && <label className="inline" title="默认关闭。打开后每天最多向 GitHub 请求一次最新版本号，什么都不发送；有新版时在顶部给出 Releases 页的链接，不自动下载">
          <input type="checkbox" checked={s.updates} onChange={(e) => setting({ updates: e.target.checked })} /> 检查更新（GitHub）</label>}
        <button className="btn link" onClick={clearCache}>删除网络缓存</button></div>
      {s && !s.enabled && <p className="hint" role="status">在线资料已关闭：不会联网，只显示已经缓存的资料。</p>}
      {s && !s.disclosed && <div className="ref-disclosure" role="note">
        <p>{s.disclosure}</p>
        <div className="row"><button className="btn" onClick={() => setting({ disclosed: true })}>知道了</button>
          <button className="btn link" onClick={() => setting({ enabled: false, disclosed: true })}>关闭在线资料</button></div></div>}
      <div className="ref-grid">
        <figure className="ref-figure">
          {img && shown(img) && imgOk ? <>
            <img src={`/api/species/reference/image?sci=${encodeURIComponent(sci)}&v=${img.cached_at}`} alt={own ? "网络参考图" : "网络参考图，不是你的观察"}
              width={img.width} height={img.height} onError={() => setImgOk(false)} />
            <figcaption><b className="ref-label">{own ? "参考图" : "网络参考图，不是你的观察"}</b>
              照片：<a href={img.source_url} {...ext}>{img.author ?? "作者见 Commons 文件页"}</a> · <a href={img.licence_url} {...ext}>{img.licence}</a>
              {img.nc && <span className="pill">非商业许可（NC）</span>}
              {img.credit && img.credit !== img.author && !/^own work$/i.test(img.credit) && <> · 出处 {img.credit}</>}
              {" "}· 来源 <a href={img.source_url} {...ext}>Wikimedia Commons 文件页</a>
              {img.changes && <> · {img.changes}</>} · 缓存于 {img.cached_at}{img.state === "stale" && "（离线显示缓存）"}</figcaption>
          </> : <div className="ref-empty">{img ? problem(img, () => refresh(["image"], true), "可用的授权参考图") : <p className="hint">正在读取…</p>}</div>}
        </figure>
        <div className="ref-summary">
          <h4>简介{sum?.lang === "en" && <span className="pill">英文资料</span>}</h4>
          {sum && shown(sum) ? <>
            <p className={open ? "ref-text" : "ref-text clamp"} lang={sum.lang === "zh" ? "zh-Hans" : "en"}>{sum.text}</p>
            {(sum.text?.length ?? 0) > 160 && <button className="btn link" onClick={() => setOpen(!open)}>{open ? "收起" : "展开"}</button>}
            <p className="hint ref-credit">{sum.credit} · {sum.changes} · <a href={sum.licence_url} {...ext}>{sum.licence}</a> ·{" "}
              <a href={sum.source_url} {...ext}>原文「{sum.title}」</a>{sum.history_url && <> / <a href={sum.history_url} {...ext}>历史</a></>}
              {sum.revision && ` · 修订 ${sum.revision}`} · 缓存于 {sum.cached_at}{sum.state === "stale" && "（离线显示缓存）"}</p>
          </> : sum ? problem(sum, () => refresh(["summary"], true), "简介") : <p className="hint">正在读取…</p>}
        </div>
      </div>
      <p className="hint ll-links">在浏览器里查：
        {(r?.links ?? []).map((l) => <a key={l.name} href={l.url} {...ext}>{l.name}</a>)}
        {r && !r.links.some((l) => l.name === "eBird") && <a href={`https://ebird.org/explore?q=${encodeURIComponent(sci)}`} {...ext}>eBird（搜索）</a>}
        {r && !r.links.some((l) => l.name.startsWith("Wikipedia")) && <a href={`https://en.wikipedia.org/w/index.php?search=${encodeURIComponent(sci)}`} {...ext}>Wikipedia（搜索）</a>}
        <button className="btn link" onClick={() => navigator.clipboard?.writeText(sci)}>复制学名</button></p>
    </div>
  );
}
