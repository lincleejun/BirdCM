import { useEffect, useRef, useState } from "react";
import { type Key, t } from "./i18n";
// 留片比例: one number, the share of eligible photos that get any star (1 + 2 + 3). Which star is decided by quality,
// not by quotas. Changing it after a scan only re-rates (no re-scan).
export interface KeepSetting { preset: string; keep: number }
export const KEEP_PRESETS: [string, Key, number][] = [["loose", "keep.loose", 30], ["std", "keep.std", 25], ["strict", "keep.strict", 20], ["stricter", "keep.stricter", 10]];
export const DEFAULT_KEEP: KeepSetting = { preset: "std", keep: 25 };

export function keepOf(ratio: { preset?: string; keep?: number } | null | undefined): KeepSetting {
  const k = ratio?.keep;
  // the preset follows the value, never a stored label: {preset: "std", keep: 10} reads as 自定义 10 % (Codex I3)
  if (typeof k === "number") return { preset: KEEP_PRESETS.find((x) => x[2] === k)?.[0] ?? "custom", keep: k };
  const p = KEEP_PRESETS.find((x) => x[0] === ratio?.preset);      // an older scan's {preset, p3, p2}: same preset, new ratio
  return p ? { preset: p[0], keep: p[2] } : DEFAULT_KEEP;
}

export default function KeepControl({ value, onChange, name = "keep" }: { value: KeepSetting; onChange: (v: KeepSetting) => void; name?: string }) {
  return (
    <>
      <div className="seg" role="radiogroup" aria-label={t("keep.ratio_label")}>
        {KEEP_PRESETS.map(([v, l, k]) => (
          <label key={v}><input type="radio" name={name} checked={value.preset === v} onChange={() => onChange({ preset: v, keep: k })} />
            <span>{t(l)} {k}%</span></label>
        ))}
        <label><input type="radio" name={name} checked={value.preset === "custom"} onChange={() => onChange({ preset: "custom", keep: value.keep })} />
          <span>{t("keep.custom")}</span></label>
      </div>
      {value.preset === "custom" && (
        <label className="row" style={{ marginTop: 8 }}>{t("keep.share")}<input type="number" min={1} max={100} value={value.keep}
          onChange={(e) => onChange({ preset: "custom", keep: Math.max(1, Math.min(100, +e.target.value || 1)) })} /> %</label>
      )}
    </>
  );
}

/** The ratio as a compact button ("目标 20% ▾") that opens the five choices; choosing closes it and calls onChange. */
export function KeepButton({ value, onChange }: { value: KeepSetting; onChange: (v: KeepSetting) => void }) {
  const [open, setOpen] = useState(false);
  const [custom, setCustom] = useState(value.keep);
  const box = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open) return;
    const away = (e: MouseEvent) => { if (!box.current?.contains(e.target as Node)) setOpen(false); };
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", away); document.addEventListener("keydown", esc);
    return () => { document.removeEventListener("mousedown", away); document.removeEventListener("keydown", esc); };
  }, [open]);
  const pick = (v: KeepSetting) => { setOpen(false); if (v.keep !== value.keep || v.preset !== value.preset) onChange(v); };
  return (
    <span className="keep-pop" ref={box}>
      <button type="button" className="keep-btn" aria-expanded={open} onClick={() => { setCustom(value.keep); setOpen(!open); }}>{t("keep.target", { n: value.keep })}</button>
      {open && (
        <div className="keep-menu" role="dialog" aria-label={t("keep.ratio")}>
          {KEEP_PRESETS.map(([v, l, k]) => (
            <button key={v} type="button" className={value.preset === v ? "on" : ""} onClick={() => pick({ preset: v, keep: k })}>{t(l)} {k}%</button>
          ))}
          <label className={value.preset === "custom" ? "on" : ""}>{t("keep.custom")}
            <input type="number" min={1} max={100} value={custom} onChange={(e) => setCustom(+e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter") pick({ preset: "custom", keep: Math.max(1, Math.min(100, Math.round(custom) || 1)) }); }} /> %
            <button type="button" className="btn" onClick={() => pick({ preset: "custom", keep: Math.max(1, Math.min(100, Math.round(custom) || 1)) })}>{t("keep.ok")}</button>
          </label>
          <p className="hint">{t("keep.hint")}</p>
        </div>
      )}
    </span>
  );
}
