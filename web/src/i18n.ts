// The page's text in Simplified Chinese and English, side by side (R8). t("key", {n: 3}) fills {n}; an entry that needs
// more than a fill-in (English plurals) is a function of the parameters. The language: the one chosen on the page
// (remembered in this browser), else the browser's (zh* -> Chinese, anything else -> English). Switching reloads the
// page, so text already fetched from the engine (star reasons, errors) comes again in the new language.
// Bird names are not here: Chinese, English and Latin are always shown together (names.tsx).
// Adding a text: one entry below; typecheck refuses a missing key, i18n.test.ts a fill-in that differs between the two.
import { M } from "./i18n.text";

export type Lang = "zh" | "en";
export type Key = keyof typeof M;
type P = Record<string, string | number>;
export type Msg = string | ((p: P) => string);

const STORE = "birdcm.lang";

function initial(): Lang {
  let saved: string | null = null;
  try { saved = localStorage.getItem(STORE); } catch { /* private window: not remembered */ }
  if (saved === "zh" || saved === "en") return saved;
  const nav = typeof navigator !== "undefined" ? navigator.language || "" : "";
  return nav.toLowerCase().startsWith("zh") ? "zh" : "en";
}

let lang: Lang = initial();

function apply() {
  if (typeof document === "undefined") return;
  document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
  document.title = t("brand.title");                     // index.html carries the Chinese one until this runs
}

export const getLang = (): Lang => lang;

/** The engine's Accept-Language for this page's language (api.ts sends it with every request). */
export const acceptLanguage = (): string => (lang === "zh" ? "zh-CN" : "en");

/** Choose a language: remembered, then the page reloads. reload=false only for tests. */
export function setLang(l: Lang, reload = true) {
  lang = l;
  try { localStorage.setItem(STORE, l); } catch { /* private window: this page only */ }
  apply();
  if (reload) location.reload();
}

export function t(key: Key, p: P = {}): string {
  const m = (M[key] as readonly [Msg, Msg])[lang === "zh" ? 0 : 1];
  return typeof m === "function" ? m(p) : m.replace(/\{(\w+)\}/g, (all, k: string) => (k in p ? String(p[k]) : all));
}

/** A number in the page's language (thousands separators). */
export const num = (n: number) => n.toLocaleString(lang === "zh" ? "zh-CN" : "en-US");

apply();
