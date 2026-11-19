// WCAG 2.x contrast of every text / background pair the stylesheet uses, light and dark, read from src/styles.css
// itself; and every role value there checked against docs/design/polish/tokens.json. Exit 1 on any failure.
// usage: node scripts/contrast.mjs   (npm run contrast)
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
const tokens = JSON.parse(readFileSync(new URL("../../docs/design/polish/tokens.json", import.meta.url), "utf8"));

// the two :root blocks: the light one, then the dark overrides inside @media (prefers-color-scheme: dark)
const block = (src) => Object.fromEntries([...src.matchAll(/--([\w-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]));
const light = block(css.slice(css.indexOf(":root {"), css.indexOf("@media (prefers-color-scheme: dark)")));
const darkSrc = css.slice(css.indexOf("@media (prefers-color-scheme: dark)"));
const dark = { ...light, ...block(darkSrc.slice(0, darkSrc.indexOf("\n}\n"))) };
const resolve = (vars, v) => { for (let i = 0; i < 5; i++) { const m = v.match(/^var\(--([\w-]+)\)$/); if (!m) break; v = vars[m[1]]; } return v.toUpperCase(); };

const lum = (hex) => {
  const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
};
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

let bad = 0;
// 1. the stylesheet carries the design's values (role -> tokens.json roles / tokens)
const roleOf = { canvas: "canvas", "surface-1": "surface-1", "surface-2": "surface-2", "surface-3": "surface-3", border: "border", "border-control": "border-control",
  "text-primary": "text-primary", "text-secondary": "text-secondary", "text-tertiary": "text-tertiary", accent: "accent", "accent-contrast": "accent-contrast",
  "new-species": "new-species-highlight", "success-fg": "success.fg", "success-bg": "success.bg", "warning-fg": "warning.fg", "warning-bg": "warning.bg",
  "error-fg": "error.fg", "error-bg": "error.bg" };
const tok = Object.fromEntries(tokens.tokens.map((t) => [t.name, t]));
const extra = { "accent-pressed": tok.actionPressed, mat: tok.mat, "on-mat": tok.onMat, "on-mat-muted": tok.onMatMuted };
for (const [mode, vars] of [["light", light], ["dark", dark]]) {
  for (let i = 0; i <= 9; i++) if (resolve(vars, vars[`gray-${i}`]) !== tokens.grayScale[mode][i]) { bad++; console.log(`✗ ${mode} gray-${i} ${vars[`gray-${i}`]} ≠ ${tokens.grayScale[mode][i]}`); }
  for (const [v, r] of Object.entries(roleOf)) if (resolve(vars, vars[v]) !== tokens.roles[r][mode]) { bad++; console.log(`✗ ${mode} --${v} ${resolve(vars, vars[v])} ≠ tokens ${r} ${tokens.roles[r][mode]}`); }
  for (const [v, t] of Object.entries(extra)) if (resolve(vars, vars[v]) !== t[mode]) { bad++; console.log(`✗ ${mode} --${v} ${resolve(vars, vars[v])} ≠ tokens ${t.name} ${t[mode]}`); }
}

// 2. the pairs used: text roles on every surface they sit on (incl. hover / pressed), filled controls, status pairs, the mat
const surfaces = ["canvas", "surface-1", "surface-2", "surface-3"];
const pairs = [
  ...["text-primary", "text-secondary", "text-tertiary", "accent", "new-species", "error-fg", "warning-fg"].flatMap((f) => surfaces.map((b) => [f, b, 4.5])),
  ["accent-contrast", "accent", 4.5], ["accent-contrast", "accent-pressed", 4.5],
  ["text-primary", "warning-bg", 4.5], ["warning-fg", "warning-bg", 4.5], ["error-fg", "error-bg", 4.5], ["success-fg", "success-bg", 4.5],
  ["success-fg", "surface-1", 3], // the 模型就绪 dot (a graphic, beside its text)
  ["on-mat", "mat", 4.5], ["on-mat-muted", "mat", 4.5],
  ...surfaces.map((b) => ["border-control", b, 3]), ...surfaces.map((b) => ["accent", b, 3]),   // control outlines, focus ring
];
for (const [mode, vars] of [["light", light], ["dark", dark]]) {
  for (const [f, b, min] of pairs) {
    const fg = resolve(vars, vars[f]), bg = resolve(vars, vars[b]), r = ratio(fg, bg);
    const ok = r >= min;
    if (!ok) bad++;
    console.log(`${ok ? "✓" : "✗"} ${mode.padEnd(5)} ${f.padEnd(15)} on ${b.padEnd(14)} ${fg} / ${bg}  ${r.toFixed(2)}:1 (≥ ${min})`);
  }
}
console.log(bad ? `${bad} failed` : `all ${pairs.length * 2} pairs pass; stylesheet matches tokens.json`);
process.exit(bad ? 1 : 0);
