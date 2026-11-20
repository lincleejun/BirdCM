import { useState } from "react";
import type { Name, Species } from "./types";
import { type Key, t } from "./i18n";

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
  if (sp.level === "genus" && l) return { title: t("look.genus", { g: genusOf(l.sci) }), sub: t("names.genus_only"), sci: genusOf(l.sci), uncertain: true };
  const c = sp.override?.local ?? sp.top5[0];          // the first name was ruled out here: offer the local congener
  return { title: t("look.uncertain"), sub: c ? t("names.top", { name: `${c.zh ? c.zh + " " : ""}${c.en ?? ""}` }) : "", sci: c ? c.sci : "", uncertain: true };
}

export type NameSize = "hero" | "row" | "card";

/** The one name block (docs/design/polish/polish.md): line 1 the name in the UI language (Chinese; English when there
 * is none), line 2 in secondary gray "the other common name · *Latin*". Hero and row keep line 2 on one line (the
 * common name gives way first, then the Latin); a card may wrap it to two lines (owner, 2026-11-18). Spans only: it
 * sits inside buttons and headings. The full names stay in the text (and the title) when the eye sees an ellipsis. */
export function SpeciesName({ title, sub, sci, size, uncertain = false }: { title: string; sub?: string | null; sci?: string | null; size: NameSize; uncertain?: boolean }) {
  return (
    <span className={`spn spn-${size}${uncertain ? " uncertain" : ""}`} title={[title, sub, sci].filter(Boolean).join(" · ")}>
      <span className="spn-1">{title}</span>
      {(sub || sci) && <span className="spn-2">{sub && <span className="spn-alt">{sub}</span>}{sub && sci && <span className="spn-dot"> · </span>}
        {sci && <i className="spn-sci">{sci}</i>}</span>}
    </span>
  );
}

/** A plain {zh, en, sci} (records, search hits) as the name block. */
export function PlainName({ zh, en, sci, size }: { zh: string | null; en: string | null; sci: string; size: NameSize }) {
  return <SpeciesName title={zh || en || sci} sub={zh ? en : null} sci={sci} size={size} />;
}

/** A naming result (species, genus or 不确定) as the name block. */
export function SpName({ sp, size = "row" }: { sp: Species | null | undefined; size?: NameSize }) {
  const n = named(sp);
  return <SpeciesName title={n.title} sub={n.sub} sci={n.sci} size={size} uncertain={n.uncertain} />;
}

export const candidateText = (c: Name) => `${c.zh ? c.zh + " " : ""}${c.en ?? ""}`.trim();

// Collapsed unless the answer is 不确定: once a species/genus is settled the others are mostly 0 % (owner, 2026-11-18).
export function Candidates({ sp, skipFirst = false }: { sp: Species; skipFirst?: boolean }) {
  const list = sp.top5.slice(skipFirst ? 1 : 0);
  const best = Math.max(0, ...list.slice(sp.level === "uncertain" ? 0 : 1).map((c) => c.p));
  return (
    <details className="candidates-fold" open={sp.level === "uncertain"}>
      <summary>{t("names.candidates", { n: list.length, p: Math.round(best * 100) })}</summary>
      <ol className="candidates" start={skipFirst ? 2 : 1}>
        {list.map((c) => (
          <li key={c.sci}>{candidateText(c) || c.sci} <span>· <i>{c.sci}</i> · {Math.round(c.p * 100)}%</span></li>
        ))}
      </ol>
    </details>
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

const KINDS: [keyof MarkSet, Key, string][] = [["box", "names.box", "l-box"], ["eye", "names.eye", "l-eye"], ["beak", "names.beak", "l-beak"], ["focus", "names.focus", "l-af"]];

/** The legend is the switch: one checkbox per kind of mark, plus 全部. */
export function MarkControls({ m, set, missing = {} }: { m: MarkSet; set: (m: MarkSet) => void; missing?: Partial<Record<keyof MarkSet, string>> }) {
  const all = KINDS.every(([k]) => m[k]);
  return (
    <div className="mark-bar" role="group" aria-label={t("names.marks")}>
      <label><input type="checkbox" checked={all} onChange={() => set(all ? { box: false, eye: false, beak: false, focus: false } : ALL)} /> {t("names.all_marks")}</label>
      {KINDS.map(([k, label, cls]) => (
        <label key={k} title={missing[k]}><input type="checkbox" checked={m[k]} onChange={() => set({ ...m, [k]: !m[k] })} />
          <i className={cls}></i>{t(label)}{missing[k] ? <span className="mark-missing">{t("names.paren", { x: missing[k]! })}</span> : null}</label>
      ))}
    </div>
  );
}

/** Why the naming reads as it does, the same on the batch page and for one photo (Codex I5): a possible rare record,
 * a name ruled out by the place and season, a look-alike flip in a burst, or simply an unclear picture. */
export function Verdict({ sp }: { sp: Species }) {
  const pct = (p: number) => `${Math.round(p * 100)}%`;
  const as = (n: Name) => named({ ...sp, label: n, level: "species" });
  return (
    <>
      {sp.check === "rare" && <p className="rare-note"><span className="tbd">{t("names.rare_tag")}</span>{t("names.rare_1")}
        {sp.prior?.median != null && t("names.rare_median", { p: (sp.prior.median * 100).toFixed(1) })}{t("names.rare_2")}</p>}
      {sp.override && (
        <p className="fixed-note">{t("names.looks_most")}{as(sp.override.visual).title} <i>{sp.override.visual.sci}</i> {pct(sp.override.visual.p)}
          {sp.level === "genus" ? t("names.only_genus") : t("names.only_uncertain")}
          {sp.override.local && <>{t("names.local_congener")}{as(sp.override.local).title} <i>{sp.override.local.sci}</i></>}</p>
      )}
      {sp.lookalike && <p className="rare-note"><span className="tbd">{t("names.flip_tag")}</span>{t("names.flip_1", { a: named(sp).title })}<i>{sp.lookalike}</i>{t("names.flip_2", { a: named(sp).title })}</p>}
      {sp.closer && <p className="rare-note"><span className="tbd">{t("names.closer_tag")}</span>{t("names.closer_1", { a: named(sp).title })}
        {" "}{as(sp.closer).title} <i>{sp.closer.sci}</i>{t("names.closer_2", { p: pct(sp.closer.p) })}</p>}
      {sp.level === "uncertain" && !sp.override && <p className="hint">{t("names.unclear")}</p>}
      {sp.prior?.unknown && <p className="hint">{t("names.not_in_model")}</p>}
    </>
  );
}
