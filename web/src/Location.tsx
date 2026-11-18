import { useEffect, useRef, useState } from "react";
import { get } from "./api";
import type { Place } from "./types";

// Where the photos were taken: a point (lat, lon) with a label and where it came from. Three ways in, one compact
// control: the device's location, a pin on a map, or a country / first-level division (its representative point).
// Photo GPS, when a photo has it, always wins per photo (engine side); this is the fallback for the rest.

export interface Country { code: string; zh: string; en: string; lat: number; lon: number; regions: { zh: string; en?: string; code?: string; lat: number; lon: number }[] }
const KEY = "birdcm.place";
const SOURCE: Record<Place["source"], string> = { map: "地图选点", device: "本机定位", region: "地区中心点" };

export function rememberedPlace(): Place | null {
  try { const p = JSON.parse(localStorage.getItem(KEY) || "null"); return p && typeof p.lat === "number" ? p : null; } catch { return null; }
}
function remember(p: Place | null) {
  try { if (p) localStorage.setItem(KEY, JSON.stringify(p)); else localStorage.removeItem(KEY); } catch { /* not remembered */ }
}

export function placeText(loc: string | Place | null | undefined): string {
  if (!loc) return "未选位置";
  if (typeof loc === "string") return `${loc} · 地区中心点`;
  return `${loc.label || fmt(loc.lat, loc.lon)} · ${SOURCE[loc.source] ?? "地图选点"}${loc.source !== "region" ? `（${fmt(loc.lat, loc.lon)}）` : ""}`;
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
  const t = text.trim().toLowerCase();
  if (!t) return [];
  const out: { label: string; lat: number; lon: number; zoom: number; region: boolean }[] = [];
  for (const c of cat) {
    if (c.zh.includes(t) || c.en.toLowerCase().includes(t)) out.push({ label: `${c.zh} ${c.en}`, lat: c.lat, lon: c.lon, zoom: 5, region: true });
    for (const r of c.regions) {
      const en = (r as { en?: string }).en ?? "";
      if (r.zh.includes(t) || en.toLowerCase().includes(t)) out.push({ label: `${c.zh} · ${r.zh} ${en}`, lat: r.lat, lon: r.lon, zoom: 7, region: true });
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
    if (!navigator.geolocation) { setMsg("这个浏览器不能定位。"); return; }
    setMsg("正在请求定位权限…");
    navigator.geolocation.getCurrentPosition(
      (pos) => { const { latitude: lat, longitude: lon } = pos.coords; set({ lat, lon, label: nearestName(catalogue, lat, lon), source: "device" }); },
      (err) => setMsg(err.code === err.PERMISSION_DENIED ? "没有得到定位权限，可以在地图上选，或选国家 / 地区。" : `定位失败：${err.message}`),
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
          <div className="folder set" style={{ flex: 1 }}>{placeText(value)}</div>
          <button type="button" className="btn" onClick={() => setEditing(true)}>更改</button>
          <button type="button" className="btn link" onClick={() => set(null)}>清除</button>
        </div>
      ) : null}
      {choosing && (
        <div className="row" style={{ marginTop: value ? 8 : 0 }}>
          <button type="button" className="btn" onClick={useDevice}>用我的位置</button>
          <button type="button" className="btn" onClick={() => setMapOpen(true)}>在地图上选</button>
          <select aria-label="国家" value={country} onChange={(e) => { setCountry(e.target.value); pickRegion(e.target.value, ""); }}>
            <option value="">选国家 / 地区…</option>
            {catalogue.map((x) => <option key={x.code} value={x.code}>{x.zh} {x.en}</option>)}
          </select>
          {c && c.regions.length > 0 && (
            <select aria-label="州 / 省" value={cur[0] === c.zh ? cur[1] ?? "" : ""} onChange={(e) => pickRegion(c.code, e.target.value)}>
              <option value="">整个{c.zh}</option>
              {c.regions.map((r) => <option key={r.zh}>{r.zh}</option>)}
            </select>
          )}
          {value && <button type="button" className="btn link" onClick={() => setEditing(false)}>取消</button>}
        </div>
      )}
      {msg && <p className="hint" role="status">{msg}</p>}
      {!compact && value?.source === "region" && !editing && <p className="hint">地区中心点只是粗略位置（大的州省可能偏几百公里）；在地图上点一下拍摄地点会更准。</p>}
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
    setOnlineMsg("正在搜索…");
    try { const r = await nominatim(q); setOnline(r); setOnlineMsg(r.length ? "" : "没有找到"); }
    catch { setOnline(null); setOnlineMsg("在线搜索用不了（可能离线），上面列出的本地地名仍可用。"); }
  };
  return (
    <dialog ref={ref} className="map-dlg" onClose={onClose} aria-labelledby="map-title">
      <div className="dlg-head"><h3 id="map-title">在地图上选拍摄地点</h3><button className="btn" onClick={() => ref.current?.close()}>取消</button></div>
      <div className="dlg-body">
        <div className="row">
          <input className="map-search" placeholder="搜地名（Alaska、阿拉斯加、Bolsa Chica…）或输入坐标 61.2, -149.9" value={q} autoFocus
            onChange={(e) => { setQ(e.target.value); setOnline(null); setOnlineMsg(""); }}
            onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); searchOnline(); } }} />
          <button className="btn" onClick={searchOnline}>{coords ? "跳到坐标" : "搜索"}</button>
        </div>
        {(local.length > 0 || online || onlineMsg) && (
          <ul className="map-hits">
            {local.map((h) => <li key={h.label}><button type="button" onClick={() => go(h.lat, h.lon, h.zoom)}>{h.label}<small>本地</small></button></li>)}
            {online?.map((h) => <li key={`${h.lat},${h.lon}`}><button type="button" onClick={() => go(h.lat, h.lon, 12)}>{h.label}<small>OpenStreetMap</small></button></li>)}
            {onlineMsg && <li className="hint">{onlineMsg}</li>}
          </ul>
        )}
        <p className="hint">地图图块和按回车的地名搜索会访问 openstreetmap.org（搜索由本机程序转发，只发送你输入的地名；照片不会离开这台电脑）。搜到地方后点一下或拖动图钉细调。</p>
        <div ref={box} className="map-box" />
        {tilesOk === false && <p className="hint">地图图块加载不了（可能离线）。可以用上面的本地地名或输入坐标。</p>}
        <div className="row" style={{ marginTop: 8 }}>
          <span className="hint">{pt ? `${nearestName(catalogue, pt.lat, pt.lon)}（${pt.lat.toFixed(4)}, ${pt.lon.toFixed(4)}）` : "还没选点"}</span>
          <button className="btn primary" disabled={!pt} onClick={() => pt && onPick({ ...pt, label: nearestName(catalogue, pt.lat, pt.lon), source: "map" })}>用这个点</button>
        </div>
      </div>
    </dialog>
  );
}
