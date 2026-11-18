import { useEffect, useRef, useState } from "react";
import type { Place } from "./types";

// Where the photos were taken: a point (lat, lon) with a label and where it came from. Three ways in, one compact
// control: the device's location, a pin on a map, or a country / first-level division (its representative point).
// Photo GPS, when a photo has it, always wins per photo (engine side); this is the fallback for the rest.

export interface Country { code: string; zh: string; en: string; lat: number; lon: number; regions: { zh: string; lat: number; lon: number }[] }
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

export default function LocationPicker({ value, onChange, catalogue, compact = false }: {
  value: Place | null; onChange: (p: Place | null) => void; catalogue: Country[]; compact?: boolean;
}) {
  const [msg, setMsg] = useState("");
  const [mapOpen, setMapOpen] = useState(false);
  const [country, setCountry] = useState("");
  const set = (p: Place | null) => { remember(p); onChange(p); };

  const useDevice = () => {
    if (!navigator.geolocation) { setMsg("这个浏览器不能定位。"); return; }
    setMsg("正在请求定位权限…");
    navigator.geolocation.getCurrentPosition(
      (pos) => { const { latitude: lat, longitude: lon } = pos.coords; setMsg(""); set({ lat, lon, label: nearestName(catalogue, lat, lon), source: "device" }); },
      (err) => setMsg(err.code === err.PERMISSION_DENIED ? "没有得到定位权限，可以在地图上选，或选国家 / 地区。" : `定位失败：${err.message}`),
      { enableHighAccuracy: false, timeout: 15000, maximumAge: 600000 });
  };
  const c = catalogue.find((x) => x.code === country);
  const pickRegion = (code: string, sub: string) => {
    const cc = catalogue.find((x) => x.code === code);
    if (!cc) return;
    const r = cc.regions.find((x) => x.zh === sub);
    set(r ? { lat: r.lat, lon: r.lon, label: `${cc.zh} · ${r.zh}`, source: "region" } : { lat: cc.lat, lon: cc.lon, label: cc.zh, source: "region" });
  };

  return (
    <div className="loc">
      <div className={`folder${value ? " set" : ""}`}>{placeText(value)}</div>
      <div className="row" style={{ marginTop: 8 }}>
        <button type="button" className="btn" onClick={useDevice}>用我的位置</button>
        <button type="button" className="btn" onClick={() => setMapOpen(true)}>在地图上选</button>
        <select aria-label="国家" value={country} onChange={(e) => { setCountry(e.target.value); pickRegion(e.target.value, ""); }}>
          <option value="">选国家 / 地区…</option>
          {catalogue.map((x) => <option key={x.code} value={x.code}>{x.zh} {x.en}</option>)}
        </select>
        {c && c.regions.length > 0 && (
          <select aria-label="州 / 省" defaultValue="" onChange={(e) => pickRegion(c.code, e.target.value)}>
            <option value="">整个{c.zh}</option>
            {c.regions.map((r) => <option key={r.zh}>{r.zh}</option>)}
          </select>
        )}
        {value && <button type="button" className="btn link" onClick={() => { setCountry(""); set(null); }}>清除</button>}
      </div>
      {msg && <p className="hint" role="status">{msg}</p>}
      {!compact && value?.source === "region" && <p className="hint">地区中心点只是粗略位置（大的州省可能偏几百公里）；在地图上点一下拍摄地点会更准。</p>}
      {mapOpen && <MapDialog start={value} catalogue={catalogue} onClose={() => setMapOpen(false)} onPick={(p) => { setMapOpen(false); set(p); }} />}
    </div>
  );
}

function MapDialog({ start, catalogue, onClose, onPick }: { start: Place | null; catalogue: Country[]; onClose: () => void; onPick: (p: Place) => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const box = useRef<HTMLDivElement>(null);
  const [pt, setPt] = useState<{ lat: number; lon: number } | null>(start ? { lat: start.lat, lon: start.lon } : null);
  const [tilesOk, setTilesOk] = useState<boolean | null>(null);
  const [lat, setLat] = useState(start ? String(start.lat) : "");
  const [lon, setLon] = useState(start ? String(start.lon) : "");
  const marker = useRef<{ setLatLng: (x: [number, number]) => void } | null>(null);
  const mapRef = useRef<{ remove: () => void } | null>(null);

  useEffect(() => {
    ref.current?.showModal();
    let dead = false;
    // Leaflet and the tiles load only now, when the person opened the map (the app's only network use)
    Promise.all([import("leaflet"), import("leaflet/dist/leaflet.css")]).then(([mod]) => {
      if (dead || !box.current) return;
      const L = mod.default;
      const at: [number, number] = start ? [start.lat, start.lon] : [30, 0];
      const map = L.map(box.current, { worldCopyJump: true }).setView(at, start ? 9 : 2);
      const tiles = L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 18, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors' });
      tiles.on("tileload", () => setTilesOk(true));
      tiles.on("tileerror", () => setTilesOk((ok) => ok ?? false));
      tiles.addTo(map);
      const icon = L.divIcon({ className: "pin", iconSize: [18, 18] });
      const m = L.marker(at, { draggable: true, icon });
      if (start) m.addTo(map);
      const move = (la: number, lo: number) => { const p = { lat: Math.max(-90, Math.min(90, la)), lon: ((((lo + 180) % 360) + 360) % 360) - 180 };
        setPt(p); setLat(p.lat.toFixed(5)); setLon(p.lon.toFixed(5)); };
      map.on("click", (e: { latlng: { lat: number; lng: number } }) => { m.setLatLng(e.latlng); if (!map.hasLayer(m)) m.addTo(map); move(e.latlng.lat, e.latlng.lng); });
      m.on("dragend", () => { const ll = m.getLatLng(); move(ll.lat, ll.lng); });
      marker.current = m;
      mapRef.current = map;
    }).catch(() => setTilesOk(false));
    return () => { dead = true; mapRef.current?.remove(); };
  }, []);  // eslint-disable-line react-hooks/exhaustive-deps

  const typed = () => {
    const a = parseFloat(lat), b = parseFloat(lon);
    if (Number.isFinite(a) && Number.isFinite(b) && Math.abs(a) <= 90 && Math.abs(b) <= 180) { setPt({ lat: a, lon: b }); marker.current?.setLatLng([a, b]); }
  };
  return (
    <dialog ref={ref} className="map-dlg" onClose={onClose} aria-labelledby="map-title">
      <div className="dlg-head"><h3 id="map-title">在地图上选拍摄地点</h3><button className="btn" onClick={() => ref.current?.close()}>取消</button></div>
      <div className="dlg-body">
        <p className="hint">打开地图会从 openstreetmap.org 加载地图图块（只有这一处联网；照片不会离开这台电脑）。点一下或拖动图钉。</p>
        <div ref={box} className="map-box" />
        {tilesOk === false && <p className="hint">地图图块加载不了（可能离线）。可以直接输入经纬度，或关掉这个窗口选国家 / 地区。</p>}
        <div className="row" style={{ marginTop: 8 }}>
          <label>纬度 <input className="coord" value={lat} onChange={(e) => setLat(e.target.value)} onBlur={typed} inputMode="decimal" /></label>
          <label>经度 <input className="coord" value={lon} onChange={(e) => setLon(e.target.value)} onBlur={typed} inputMode="decimal" /></label>
          <span className="hint">{pt ? nearestName(catalogue, pt.lat, pt.lon) : "还没选点"}</span>
          <button className="btn primary" disabled={!pt} onClick={() => pt && onPick({ ...pt, label: nearestName(catalogue, pt.lat, pt.lon), source: "map" })}>用这个点</button>
        </div>
      </div>
    </dialog>
  );
}
