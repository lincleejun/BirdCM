import { useState } from "react";
import type { Name, Species } from "./types";

// One way to name a bird everywhere: Chinese, English and the scientific (Latin) name together.
export interface Named { title: string; sub: string; sci: string; uncertain: boolean }

const genusOf = (sci: string) => sci.replace(/ sp\.$/, "").split(" ")[0];

export function named(sp: Species | null | undefined): Named {
  if (!sp) return { title: "—", sub: "", sci: "", uncertain: true };
  const l = sp.label;
  if (sp.level === "species" && l) {
    const title = l.zh || l.en || l.sci;
    // without a Chinese name the English becomes the title and the second line is the Latin alone
    return { title, sub: l.zh ? l.en ?? "" : "", sci: l.sci, uncertain: false };
  }
  if (sp.level === "genus" && l) return { title: `${genusOf(l.sci)} 属`, sub: "只认到属", sci: genusOf(l.sci), uncertain: true };
  const t = sp.top5[0];
  return { title: "不确定", sub: t ? `最高候选 ${t.zh ? t.zh + " " : ""}${t.en ?? ""}` : "", sci: t ? t.sci : "", uncertain: true };
}

/** "Chinese / English · Latin" as a title line and a small second line. */
export function SpName({ sp, big = false }: { sp: Species | null | undefined; big?: boolean }) {
  const n = named(sp);
  return (
    <>
      <span className={`${big ? "sp-cn" : "name"}${n.uncertain && big ? " uncertain" : ""}`}>{n.title}</span>
      <span className={big ? "sp-en" : "small sp-line"} style={{ display: "block" }}>
        {n.sub}{n.sub && n.sci ? " · " : ""}{n.sci && <i className="sp-sci">{n.sci}</i>}
      </span>
    </>
  );
}

export const candidateText = (c: Name) => `${c.zh ? c.zh + " " : ""}${c.en ?? ""}`.trim();

export function Candidates({ sp, skipFirst = false }: { sp: Species; skipFirst?: boolean }) {
  return (
    <ol className="candidates" start={skipFirst ? 2 : 1}>
      {sp.top5.slice(skipFirst ? 1 : 0).map((c) => (
        <li key={c.sci}>{candidateText(c) || c.sci} <span>· <i>{c.sci}</i> · {Math.round(c.p * 100)}%</span></li>
      ))}
    </ol>
  );
}

// ---------- which marks to draw (remembered per browser) ----------
export interface MarkSet { box: boolean; eye: boolean; beak: boolean; focus: boolean }
const KEY = "birdcm.marks";
const ALL: MarkSet = { box: true, eye: true, beak: true, focus: true };

export function useMarks(): [MarkSet, (m: MarkSet) => void] {
  const [m, setM] = useState<MarkSet>(() => {
    try { return { ...ALL, ...JSON.parse(localStorage.getItem(KEY) || "{}") }; } catch { return ALL; }
  });
  const set = (v: MarkSet) => {
    setM(v);
    try { localStorage.setItem(KEY, JSON.stringify(v)); } catch { /* private window: just not remembered */ }
  };
  return [m, set];
}

const KINDS: [keyof MarkSet, string, string][] = [["box", "鸟框", "l-box"], ["eye", "眼睛", "l-eye"], ["beak", "嘴", "l-beak"], ["focus", "对焦点", "l-af"]];

/** The legend is the switch: one checkbox per kind of mark, plus 全部. */
export function MarkControls({ m, set, missing = {} }: { m: MarkSet; set: (m: MarkSet) => void; missing?: Partial<Record<keyof MarkSet, string>> }) {
  const all = KINDS.every(([k]) => m[k]);
  return (
    <div className="mark-bar" role="group" aria-label="照片上的标记">
      <label><input type="checkbox" checked={all} onChange={() => set(all ? { box: false, eye: false, beak: false, focus: false } : ALL)} /> 全部标记</label>
      {KINDS.map(([k, label, cls]) => (
        <label key={k} title={missing[k]}><input type="checkbox" checked={m[k]} onChange={() => set({ ...m, [k]: !m[k] })} />
          <i className={cls}></i>{label}{missing[k] ? <span className="mark-missing">（{missing[k]}）</span> : null}</label>
      ))}
    </div>
  );
}
