import { useEffect, useRef, useState } from "react";
import { get } from "./api";
import type { Place } from "./types";
import { getLang, type Key, t as tr } from "./i18n";

// Where the photos were taken: a point (lat, lon) with a label and where it came from. Three ways in, one compact
// control: the device's location, a pin on a map, or a country / first-level division (its representative point).
// Photo GPS, when a photo has it, always wins per photo (engine side); this is the fallback for the rest.

export interface Country { code: string; zh: string; en: string; lat: number; lon: number; regions: { zh: string; en?: string; code?: string; lat: number; lon: number }[] }
const KEY = "birdcm.place";
const SOURCE: Record<Place["source"], Key> = { map: "loc.src_map", device: "loc.src_device", region: "loc.src_region" };

export function rememberedPlace(): Place | null {
  try { const p = JSON.parse(localStorage.getItem(KEY) || "null"); return p && typeof p.lat === "number" ? p : null; } catch { return null; }
}
function remember(p: Place | null) {
  try { if (p) localStorage.setItem(KEY, JSON.stringify(p)); else localStorage.removeItem(KEY); } catch { /* not remembered */ }
}

/** A place for people (owner, 2026-11-18): its English name from the engine (a point: the cached OpenStreetMap name,
 * else its region; a region: by code or our label), the point itself as a small caption. `name` given = no request
 * (lists carry it); while an online lookup is queued it asks again a few times. */
export function PlaceName({ lat, lon, code, label, name }: { lat?: number | null; lon?: number | null; code?: string | null; label?: string | null; name?: string | null }) {
  const point = lat != null && lon != null;
  const [n, setN] = useState<string | null | undefined>(name);
  useEffect(() => {
    if (name !== undefined) { setN(name); return; }
    let dead = false, tries = 0, t = 0;
    const qs = point ? `lat=${lat}&lon=${lon}` : `code=${encodeURIComponent(code ?? "")}&label=${encodeURIComponent(label ?? "")}`;
    const ask = () => get<{ label: string | null; pending: boolean }>(`/api/places/name?${qs}`).then((r) => {
      if (dead) return;
      setN(r.label);
      if (r.pending && ++tries < 5) t = window.setTimeout(ask, 1500);
    }).catch(() => { if (!dead) setN(label ?? null); });
    ask();
    return () => { dead = true; clearTimeout(t); };
  }, [lat, lon, code, label, name, point]);
  const shown = n ?? (point ? null : label);
  const xy = point ? fmt(lat!, lon!) : null;
  return <span className="place-name">{shown ?? xy ?? "—"}{shown && xy && <small className="place-coords">{xy}</small>}</span>;
}

/** A chosen location (a scan's, a single photo's): its name, how it was chosen, the point as a caption. */
export function PlaceOf({ loc }: { loc: string | Place | null | undefined }) {
  if (!loc) return <>{tr("loc.none")}</>;
  if (typeof loc === "string") return <><PlaceName label={loc} /> · {tr("loc.src_region")}</>;
  return loc.source === "region" ? <><PlaceName code={loc.code} label={loc.label} /> · {tr("loc.src_region")}</>
    : <><PlaceName lat={loc.lat} lon={loc.lon} /> · {tr(SOURCE[loc.source] ?? "loc.src_map")}</>;
}
const fmt = (lat: number, lon: number) => `${lat.toFixed(4)}, ${lon.toFixed(4)}`;
const wrap = (lon: number) => ((((lon + 180) % 360) + 360) % 360) - 180;

/** The nearest representative point in our own table: a cheap offline "reverse geocode" for a label. */
export function nearestName(cat: Country[], lat: number, lon: number): string {
  let best = "", d = Infinity;
  const dist = (a: number, b: number) => { const dl = Math.abs(wrap(b - lon)); return (a - lat) ** 2 + (dl * Math.cos((lat * Math.PI) / 180)) ** 2; };
  for (const c of cat) {
    for (const r of c.regions) { const x = dist(r.lat, r.lon); if (x < d) { d = x; best = `${c.zh} · ${r.zh} 附近`; } }
    const x = dist(c.lat, c.lon) * 1.5;                       // a division's point beats its country's when close
    if (x < d) { d = x; best = `${c.zh} 附近`; }
  }
  return best;
}

/** Places in our own table matching typed text (Chinese or English, any case); offline. */
export function localMatches(cat: Country[], text: string): { label: string; lat: number; lon: number; zoom: number; region: boolean }[] {
  const t = text.trim().toLowerCase(), zh = getLang() === "zh";
  if (!t) return [];
  const out: { label: string; lat: number; lon: number; zoom: number; region: boolean }[] = [];
  for (const c of cat) {
    if (c.zh.includes(t) || c.en.toLowerCase().includes(t)) out.push({ label: zh ? `${c.zh} ${c.en}` : c.en, lat: c.lat, lon: c.lon, zoom: 5, region: true });
    for (const r of c.regions) {
      const en = (r as { en?: string }).en ?? "";
      if (r.zh.includes(t) || en.toLowerCase().includes(t)) out.push({ label: zh ? `${c.zh} · ${r.zh} ${en}` : `${en || r.zh} · ${c.en}`, lat: r.lat, lon: r.lon, zoom: 7, region: true });
    }
  }
  return out.slice(0, 8);
}

/** "61.2, -149.9" (or with a space) -> a point; null when the text is not coordinates. */
export function parseCoords(text: string): { lat: number; lon: number } | null {
  const m = text.trim().match(/^(-?\d+(?:\.\d+)?)\s*[,，\s]\s*(-?\d+(?:\.\d+)?)$/);
  if (!m) return null;
  const lat = +m[1], lon = +m[2];
  return Math.abs(lat) <= 90 && Math.abs(lon) <= 180 ? { lat, lon } : null;
}

// Online place search goes through the local engine (/api/places), which talks to OpenStreetMap Nominatim politely.
async function nominatim(q: string): Promise<{ label: string; lat: number; lon: number }[]> {
  return get<{ label: string; lat: number; lon: number }[]>(`/api/places?q=${encodeURIComponent(q)}`);
}

export default function LocationPicker({ value, onChange, catalogue, compact = false }: {
  value: Place | null; onChange: (p: Place | null) => void; catalogue: Country[]; compact?: boolean;
}) {
  const [msg, setMsg] = useState("");
  const [mapOpen, setMapOpen] = useState(false);
  const [editing, setEditing] = useState(false);
  const set = (p: Place | null) => { remember(p); setEditing(false); setMsg(""); onChange(p); };
  // the dropdowns reflect the current place when it is a region (never a placeholder beside a set location)
  // a point's label is "国家 · 州 附近": its country (and division) preselected too
  const cur = value ? value.label.replace(/ 附近$/, "").split(" · ") : [];
  const [country, setCountry] = useState(() => catalogue.find((x) => x.zh === cur[0])?.code ?? "");
  useEffect(() => { if (value) setCountry(catalogue.find((x) => x.zh === value.label.replace(/ 附近$/, "").split(" · ")[0])?.code ?? ""); }, [value, catalogue]);

  const useDevice = () => {
    if (!navigator.geolocation) { setMsg(tr("loc.no_geo")); return; }
    setMsg(tr("loc.asking"));
    navigator.geolocation.getCurrentPosition(
      (pos) => { const { latitude: lat, longitude: lon } = pos.coords; set({ lat, lon, label: nearestName(catalogue, lat, lon), source: "device" }); },
      (err) => setMsg(err.code === err.PERMISSION_DENIED ? tr("loc.denied") : tr("loc.failed", { e: err.message })),
      { enableHighAccuracy: false, timeout: 15000, maximumAge: 600000 });
  };
  const c = catalogue.find((x) => x.code === country);
  const pickRegion = (code: string, sub: string) => {
    const cc = catalogue.find((x) => x.code === code);
    if (!cc) return;
    const r = cc.regions.find((x) => x.zh === sub);
    // the ISO 3166 code is what the rarity table and the life list key a chosen region by; the point is only the prior's
    set(r ? { lat: r.lat, lon: r.lon, label: `${cc.zh} · ${r.zh}`, source: "region", code: r.code || undefined }
      : { lat: cc.lat, lon: cc.lon, label: cc.zh, source: "region", code: cc.code });
  };
  const choosing = !value || editing;

  return (
    <div className="loc">
      {value && !editing ? (
        <div className="row">
          <div className="folder set" style={{ flex: 1 }}><PlaceOf loc={value} /></div>
          <button type="button" className="btn" onClick={() => setEditing(true)}>{tr("loc.change")}</button>
          <button type="button" className="btn link" onClick={() => set(null)}>{tr("loc.clear")}</button>
        </div>
      ) : null}
      {choosing && (
        <div className="row" style={{ marginTop: value ? 8 : 0 }}>
          <button type="button" className="btn" onClick={useDevice}>{tr("loc.device")}</button>
          <button type="button" className="btn" onClick={() => setMapOpen(true)}>{tr("loc.on_map")}</button>
          <select aria-label={tr("loc.country")} value={country} onChange={(e) => { setCountry(e.target.value); pickRegion(e.target.value, ""); }}>
            <option value="">{tr("loc.pick_country")}</option>
            {catalogue.map((x) => <option key={x.code} value={x.code}>{getLang() === "zh" ? `${x.zh} ${x.en}` : x.en}</option>)}
          </select>
          {c && c.regions.length > 0 && (
            <select aria-label={tr("loc.division")} value={cur[0] === c.zh ? cur[1] ?? "" : ""} onChange={(e) => pickRegion(c.code, e.target.value)}>
              <option value="">{tr("loc.whole", { c: getLang() === "zh" ? c.zh : c.en })}</option>
              {c.regions.map((r) => <option key={r.zh} value={r.zh}>{getLang() === "zh" ? r.zh : r.en || r.zh}</option>)}
            </select>
          )}
          {value && <button type="button" className="btn link" onClick={() => setEditing(false)}>{tr("loc.cancel")}</button>}
        </div>
      )}
      {msg && <p className="hint" role="status">{msg}</p>}
      {!compact && value?.source === "region" && !editing && <p className="hint">{tr("loc.region_hint")}</p>}
      {mapOpen && <MapDialog start={value ?? rememberedPlace()} catalogue={catalogue} onClose={() => setMapOpen(false)} onPick={(p) => { setMapOpen(false); set(p); }} />}
    </div>
  );
}

function MapDialog({ start, catalogue, onClose, onPick }: { start: Place | null; catalogue: Country[]; onClose: () => void; onPick: (p: Place) => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const box = useRef<HTMLDivElement>(null);
  const [pt, setPt] = useState<{ lat: number; lon: number } | null>(start ? { lat: start.lat, lon: start.lon } : null);
  const [tilesOk, setTilesOk] = useState<boolean | null>(null);
  const [q, setQ] = useState("");
  const [online, setOnline] = useState<{ label: string; lat: number; lon: number }[] | null>(null);
  const [onlineMsg, setOnlineMsg] = useState("");
  const api = useRef<{ go: (lat: number, lon: number, zoom: number) => void } | null>(null);

  useEffect(() => {
    ref.current?.showModal();
    let dead = false;
    let map: { remove: () => void } | null = null;
    // Leaflet and the tiles load only now, when the person opened the map
    Promise.all([import("leaflet"), import("leaflet/dist/leaflet.css")]).then(([mod]) => {
      if (dead || !box.current) return;
      const L = mod.default;
      const at: [number, number] = start ? [start.lat, start.lon] : [30, 0];
      const m = L.map(box.current, { worldCopyJump: true }).setView(at, start ? 9 : 2);
      const tiles = L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 18, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors' });
      tiles.on("tileload", () => setTilesOk(true));
      tiles.on("tileerror", () => setTilesOk((ok) => ok ?? false));
      tiles.addTo(m);
      const pin = L.marker(at, { draggable: true, icon: L.divIcon({ className: "pin", iconSize: [18, 18] }) });
      if (start) pin.addTo(m);
      const move = (la: number, lo: number) => setPt({ lat: Math.max(-90, Math.min(90, la)), lon: ((((lo + 180) % 360) + 360) % 360) - 180 });
      m.on("click", (e: { latlng: { lat: number; lng: number } }) => { pin.setLatLng(e.latlng); if (!m.hasLayer(pin)) pin.addTo(m); move(e.latlng.lat, e.latlng.lng); });
      pin.on("dragend", () => { const ll = pin.getLatLng(); move(ll.lat, ll.lng); });
      api.current = { go: (la, lo, zoom) => { m.setView([la, lo], zoom); pin.setLatLng([la, lo]); if (!m.hasLayer(pin)) pin.addTo(m); move(la, lo); } };
      map = m;
    }).catch(() => setTilesOk(false));
    return () => { dead = true; map?.remove(); };
  }, []);  // eslint-disable-line react-hooks/exhaustive-deps

  const go = (lat: number, lon: number, zoom: number) => {
    if (api.current) api.current.go(lat, lon, zoom);
    else setPt({ lat, lon });                                  // offline: no map, the point is still set
  };
  const local = localMatches(catalogue, q);
  const coords = parseCoords(q);
  const searchOnline = async () => {
    if (coords) { go(coords.lat, coords.lon, 11); return; }
    if (!q.trim()) return;
    setOnlineMsg(tr("loc.searching"));
    try { const r = await nominatim(q); setOnline(r); setOnlineMsg(r.length ? "" : tr("loc.not_found")); }
    catch { setOnline(null); setOnlineMsg(tr("loc.search_offline")); }
  };
  return (
    <dialog ref={ref} className="map-dlg" onClose={onClose} aria-labelledby="map-title">
      <div className="dlg-head"><h3 id="map-title">{tr("loc.map_title")}</h3><button className="btn" onClick={() => ref.current?.close()}>{tr("loc.cancel")}</button></div>
      <div className="dlg-body">
        <div className="row">
          <input className="map-search" placeholder={tr("loc.search_ph")} value={q} autoFocus
            onChange={(e) => { setQ(e.target.value); setOnline(null); setOnlineMsg(""); }}
            onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); searchOnline(); } }} />
          <button className="btn" onClick={searchOnline}>{coords ? tr("loc.go_coords") : tr("loc.search")}</button>
        </div>
        {(local.length > 0 || online || onlineMsg) && (
          <ul className="map-hits">
            {local.map((h) => <li key={h.label}><button type="button" onClick={() => go(h.lat, h.lon, h.zoom)}>{h.label}<small>{tr("loc.local")}</small></button></li>)}
            {online?.map((h) => <li key={`${h.lat},${h.lon}`}><button type="button" onClick={() => go(h.lat, h.lon, 12)}>{h.label}<small>OpenStreetMap</small></button></li>)}
            {onlineMsg && <li className="hint">{onlineMsg}</li>}
          </ul>
        )}
        <p className="hint">{tr("loc.map_hint")}</p>
        <div ref={box} className="map-box" />
        {tilesOk === false && <p className="hint">{tr("loc.tiles_failed")}</p>}
        <div className="row" style={{ marginTop: 8 }}>
          <span className="hint">{pt ? <PlaceName lat={pt.lat} lon={pt.lon} /> : tr("loc.no_point")}</span>
          <button className="btn primary" disabled={!pt} onClick={() => pt && onPick({ ...pt, label: nearestName(catalogue, pt.lat, pt.lon), source: "map" })}>{tr("loc.use_point")}</button>
        </div>
      </div>
    </dialog>
  );
}
