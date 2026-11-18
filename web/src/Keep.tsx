// 留片比例: one number, the share of eligible photos that get any star (1 + 2 + 3). Which star is decided by quality,
// not by quotas. Changing it after a scan only re-rates (no re-scan).
export interface KeepSetting { preset: string; keep: number }
export const KEEP_PRESETS: [string, string, number][] = [["loose", "宽松", 30], ["std", "标准", 25], ["strict", "严格", 20], ["stricter", "更严", 10]];
export const DEFAULT_KEEP: KeepSetting = { preset: "std", keep: 25 };

export function keepOf(ratio: { preset?: string; keep?: number } | null | undefined): KeepSetting {
  const k = ratio?.keep;
  if (typeof k === "number") return { preset: ratio?.preset ?? "custom", keep: k };
  const p = KEEP_PRESETS.find((x) => x[0] === ratio?.preset);      // an older scan's {preset, p3, p2}: same preset, new ratio
  return p ? { preset: p[0], keep: p[2] } : DEFAULT_KEEP;
}

export default function KeepControl({ value, onChange, name = "keep" }: { value: KeepSetting; onChange: (v: KeepSetting) => void; name?: string }) {
  return (
    <>
      <div className="seg" role="radiogroup" aria-label="留片比例（有星的照片占比）">
        {KEEP_PRESETS.map(([v, t, k]) => (
          <label key={v}><input type="radio" name={name} checked={value.preset === v} onChange={() => onChange({ preset: v, keep: k })} />
            <span>{t} {k}%</span></label>
        ))}
        <label><input type="radio" name={name} checked={value.preset === "custom"} onChange={() => onChange({ preset: "custom", keep: value.keep })} />
          <span>自定义</span></label>
      </div>
      {value.preset === "custom" && (
        <label className="row" style={{ marginTop: 8 }}>有星的照片占 <input type="number" min={1} max={100} value={value.keep}
          onChange={(e) => onChange({ preset: "custom", keep: Math.max(1, Math.min(100, +e.target.value || 1)) })} /> %</label>
      )}
    </>
  );
}
