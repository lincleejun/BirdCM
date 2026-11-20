// 物种参考 on the species page (docs/design-species-search.md §4.4, §4.5, §4.8, §8; owner decisions 2026-11-18): the
// Wikipedia summary and one Commons reference image, fetched by the engine on demand and shown under the person's own
// photos, each card on its own with its attribution, its cache date and its own retry. Online is on by default; the
// first use shows the disclosure. Only the species' ids and titles leave the machine (the engine sends them).
import { useEffect, useState } from "react";
import { del, get, post } from "./api";
import { getLang, t } from "./i18n";

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
  const text = c.state === "unmapped" ? c.why ?? t("ref.unmapped")
    : c.state === "none" ? c.why ?? t("ref.none", { what })
    : c.state === "off" ? t("ref.off") : c.state === "missing" ? t("ref.fetching")
    : c.state === "busy" || c.problem === "busy" ? t("ref.busy") : t("ref.unavailable");
  const again = c.state === "unavailable" || c.state === "busy" || c.problem || c.state === "none";
  return <p className="hint" role="status">{text}{c.cached_at && c.state !== "none" ? t("ref.showing_cache", { d: c.cached_at }) : ""}
    {again && <> <button className="btn link" onClick={retry}>{t("ref.retry")}</button></>}</p>;
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
      <div className="row"><h3 id="h-ref">{t("ref.title")}</h3>
        {s && <label className="inline"><input type="checkbox" checked={s.enabled} onChange={(e) => setting({ enabled: e.target.checked, disclosed: true })} /> {t("ref.online")}</label>}
        {s && <label className="inline" title={t("ref.places_title")}>
          <input type="checkbox" checked={s.places} onChange={(e) => setting({ places: e.target.checked })} /> {t("ref.places")}</label>}
        {s && <label className="inline" title={t("ref.updates_title")}>
          <input type="checkbox" checked={s.updates} onChange={(e) => setting({ updates: e.target.checked })} /> {t("ref.updates")}</label>}
        <button className="btn link" onClick={clearCache}>{t("ref.clear_cache")}</button></div>
      {s && !s.enabled && <p className="hint" role="status">{t("ref.off_note")}</p>}
      {s && !s.disclosed && <div className="ref-disclosure" role="note">
        <p>{s.disclosure}</p>
        <div className="row"><button className="btn" onClick={() => setting({ disclosed: true })}>{t("ref.got_it")}</button>
          <button className="btn link" onClick={() => setting({ enabled: false, disclosed: true })}>{t("ref.turn_off")}</button></div></div>}
      <div className="ref-grid">
        <figure className="ref-figure">
          {img && shown(img) && imgOk ? <>
            <img src={`/api/species/reference/image?sci=${encodeURIComponent(sci)}&v=${img.cached_at}`} alt={own ? t("ref.web_image") : t("ref.web_image_not_yours")}
              width={img.width} height={img.height} onError={() => setImgOk(false)} />
            <figcaption><b className="ref-label">{own ? t("ref.image") : t("ref.web_image_not_yours")}</b>
              {t("ref.photo_by")}<a href={img.source_url} {...ext}>{img.author ?? t("ref.author_on_commons")}</a> · <a href={img.licence_url} {...ext}>{img.licence}</a>
              {img.nc && <span className="pill">{t("ref.nc")}</span>}
              {img.credit && img.credit !== img.author && !/^own work$/i.test(img.credit) && <> · {t("ref.credit")} {img.credit}</>}
              {" "}· {t("ref.source")} <a href={img.source_url} {...ext}>{t("ref.commons_page")}</a>
              {img.changes && <> · {img.changes}</>} · {t("ref.cached_on")} {img.cached_at}{img.state === "stale" && t("ref.stale")}</figcaption>
          </> : <div className="ref-empty">{img ? problem(img, () => refresh(["image"], true), t("ref.what_image")) : <p className="hint">{t("ref.loading")}</p>}</div>}
        </figure>
        <div className="ref-summary">
          <h4>{t("ref.summary")}{sum?.lang && sum.lang !== getLang() && <span className="pill">{t("ref.other_lang")}</span>}</h4>
          {sum && shown(sum) ? <>
            <p className={open ? "ref-text" : "ref-text clamp"} lang={sum.lang === "zh" ? "zh-Hans" : "en"}>{sum.text}</p>
            {(sum.text?.length ?? 0) > 160 && <button className="btn link" onClick={() => setOpen(!open)}>{open ? t("ref.less") : t("ref.more")}</button>}
            <p className="hint ref-credit">{sum.credit} · {sum.changes} · <a href={sum.licence_url} {...ext}>{sum.licence}</a> ·{" "}
              <a href={sum.source_url} {...ext}>{t("ref.original", { title: sum.title ?? "" })}</a>{sum.history_url && <> / <a href={sum.history_url} {...ext}>{t("ref.history")}</a></>}
              {sum.revision && t("ref.revision", { r: sum.revision })} · {t("ref.cached_on")} {sum.cached_at}{sum.state === "stale" && t("ref.stale")}</p>
          </> : sum ? problem(sum, () => refresh(["summary"], true), t("ref.summary")) : <p className="hint">{t("ref.loading")}</p>}
        </div>
      </div>
      <p className="hint ll-links">{t("ref.look_up")}
        {(r?.links ?? []).map((l) => <a key={l.name} href={l.url} {...ext}>{l.name}</a>)}
        {r && !r.links.some((l) => l.name === "eBird") && <a href={`https://ebird.org/explore?q=${encodeURIComponent(sci)}`} {...ext}>{t("ref.ebird_search")}</a>}
        {r && !r.links.some((l) => l.url.startsWith("https://en.wikipedia.org/")) && <a href={`https://en.wikipedia.org/w/index.php?search=${encodeURIComponent(sci)}`} {...ext}>{t("ref.wiki_search")}</a>}
        <button className="btn link" onClick={() => navigator.clipboard?.writeText(sci)}>{t("ref.copy_sci")}</button></p>
    </div>
  );
}
