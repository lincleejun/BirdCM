// @vitest-environment happy-dom
// R8: the two languages are one table with the same fill-ins, and the English result page shows no Chinese except
// the birds' Chinese names (and 中文, the switch back).
import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import ExportDialog from "./Export";
import { row } from "./fixture";
import { getLang, setLang, t } from "./i18n";
import { M } from "./i18n.text";
import Results from "./Results";
import type { Snapshot } from "./types";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const CJK = /[　-〿一-鿿＀-￯]/;
const fills = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
const BIRDS = ["麻雀", "喜鹊", "鹊属"];                      // the fixture's Chinese bird names: shown in both languages

describe("the table", () => {
  it("every entry has both languages, the same fill-ins, and English without Chinese", () => {
    for (const [k, pair] of Object.entries(M) as [string, readonly unknown[]][]) {
      expect(pair, k).toHaveLength(2);
      const [zh, en] = pair;
      expect(typeof zh === "string" || typeof zh === "function", k).toBe(true);
      expect(typeof en === "string" || typeof en === "function", k).toBe(true);
      if (typeof zh === "string" && typeof en === "string") expect(fills(en), k).toEqual(fills(zh));
      if (k !== "lang.switch") {
        const text = typeof en === "string" ? en : (en as (p: Record<string, number>) => string)({ n: 2, a: 1, b: 1, p: 1, lists: 1, species: 1, photos: 1 });
        expect(CJK.test(text), `${k}: ${text}`).toBe(false);
      }
    }
  });
  it("t() follows the chosen language and fills in", () => {
    expect(getLang()).toBe("zh");
    expect(t("export.write_n", { n: 3 })).toBe("写入 3 个 .xmp");
    setLang("en", false);
    expect(t("export.write_n", { n: 3 })).toBe("Write 3 .xmp");
    expect(t("export.only_view", { n: 1 })).toBe("Only the 1 photo in the current filter");
    expect(document.documentElement.lang).toBe("en");
    setLang("zh", false);
    expect(document.documentElement.lang).toBe("zh-CN");
  });
});

/** Every text node and every attribute a person can see or hear, with the birds' Chinese names taken out. */
function chinese(root: Element): string[] {
  const out: string[] = [];
  const strip = (s: string) => BIRDS.reduce((a, b) => a.split(b).join(""), s);
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let n = walker.nextNode(); n; n = walker.nextNode()) if (CJK.test(strip(n.textContent ?? ""))) out.push(n.textContent!);
  for (const el of root.querySelectorAll("*")) {
    for (const a of ["title", "aria-label", "placeholder", "alt"]) {
      const v = el.getAttribute(a);
      if (v && CJK.test(strip(v))) out.push(`${a}=${v}`);
    }
  }
  return out;
}

describe("the English page", () => {
  const SID = 7;
  const photos = Array.from({ length: 8 }, (_, i) => row(i + 1, {
    stars: i < 2 ? 3 : i < 4 ? 2 : i < 6 ? 1 : i === 6 ? -1 : 0, q: 1 - i / 10, sci: i % 2 ? "Pica serica" : "Passer montanus",
    zh: i % 2 ? "喜鹊" : "麻雀", star_auto: i === 0, flying: i === 1, tier: i === 2 ? 1 : i === 3 ? 4 : undefined,
    rejected: i === 6, burst_group: i < 3 ? 1 : null, burst_rank: i < 3 ? i + 1 : null,
  }));
  // what the engine answers an English request with: its own messages in English
  for (const p of photos) {
    p.star_reason = p.stars === -1 ? "No clear bird" : "Good in every way (overall 0.81)";
    if (p.result?.rejected) p.result.reject_reason = "No clear bird";
    if (p.result?.rarity) p.result.rarity = { ...p.result.rarity, label: p.result.rarity.tier === 1 ? "罕见" : "常见" };   // wire words
  }
  photos[7].result!.species = { level: "genus", label: { sci: "Pica sp.", en: null, zh: "鹊属", p: 0.5 }, top5: [], geo: false };
  const snapshot = (): Snapshot => ({
    scan: { id: SID, folder: "/f", recursive: 0, region: null, ratio: { strategy: "select" }, state: "completed", error: null, created_at: 0,
      counts: { queued: 0, working: 0, done: 8, failed: 0, total: 8 } },
    photos, cursor: 1,
  });
  const json = (v: unknown) => new Response(JSON.stringify(v), { status: 200, headers: { "Content-Type": "application/json" } });
  let sent: string[] = [];
  afterEach(() => { vi.unstubAllGlobals(); setLang("zh", false); });

  async function render(el: React.ReactElement) {
    sent = [];
    vi.stubGlobal("fetch", vi.fn(async (url: string, init?: RequestInit) => {
      sent.push((init?.headers as Record<string, string> | undefined)?.["Accept-Language"] ?? "");
      if (url === "/api/session") return json({ token: "t" });
      if (url === "/api/models") return json({ engine: "ready", load_error: null });
      if (url === `/api/scans/${SID}`) return json(snapshot());
      if (url === `/api/scans/${SID}/related`) return json({ newer: null, previous: null, stale: false });
      if (url.includes("/ebird/plan")) return json({ species: [], checklists: [] });
      if (url.includes("/xmp")) return json({ create: 0, modify: 0, skipped: {}, last: null });
      if (url.startsWith("/api/species")) return json([]);
      return json({ ok: true });
    }));
    vi.stubGlobal("EventSource", class { close() {} addEventListener() {} onerror = null; onmessage = null; });
    setLang("en", false);
    const box = document.createElement("div");
    document.body.append(box);
    const root = createRoot(box);
    await act(async () => root.render(el));
    for (let i = 0; i < 6; i++) await act(() => new Promise((r) => setTimeout(r, 0)));
    return { box, done: () => { act(() => root.unmount()); box.remove(); } };
  }
  const clickEach = async (els: Element[]) => {
    for (const el of els) {
      await act(async () => { el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true })); });
      for (let i = 0; i < 3; i++) await act(() => new Promise((r) => setTimeout(r, 0)));
    }
  };

  it("the result page: grid, filters, the panel of each kind of photo", async () => {
    const { box, done } = await render(<Results scanId={SID} onBack={() => {}} onOpen={() => {}} catalogue={[]} brand={null} nav={null} />);
    expect(box.querySelectorAll("#grid .tile")).toHaveLength(8);
    expect(box.textContent).toContain("Showing 8 / 8");                    // really the English page
    expect(chinese(box)).toEqual([]);
    for (const tile of [...box.querySelectorAll("#grid .tile")]) {          // rejected, genus, rare, by hand, flying, burst
      await clickEach([tile]);
      expect(chinese(box), tile.getAttribute("aria-label")!).toEqual([]);
    }
    expect(sent.filter(Boolean).every((h) => h === "en")).toBe(true);        // every request names the language
    done();
  });

  it("the export dialog", async () => {
    const { box, done } = await render(<ExportDialog scanId={SID} photos={photos} view={photos.slice(0, 3)} onClose={() => {}} saveTable={() => {}} />);
    expect(box.textContent).toContain("Which birds");
    expect(chinese(box)).toEqual([]);
    done();
  });
});

// The page's own text lives in the dictionary; what Chinese is left in the code is data, each kind said why.
describe("no Chinese left in the code", () => {
  const ALLOW: [file: string, line: RegExp, why: string][] = [
    ["Location.tsx", / 附近/, "the engine's place label (\"国家 · 州 附近\"): data sent and parsed; shown through PlaceName in English"],
    ["Location.tsx", /\[,，\\s\]/, "typed coordinates may use a Chinese comma"],
    ["look.ts", /"rarity\./, "the engine's rarity words (rarity.py): wire values mapped to display text by rarityText"],
    ["Library.tsx", /rarityText\(.*"罕见" : "少见"/, "rarity wire words passed to rarityText"],
    ["types.ts", /"数据不足"/, "the engine's coverage value (rarity.py), a type"],
    ["Results.tsx", /^\s*([\u4e00-\u9fff\w]+: .+?,\s*)+$/, "exportRow: the JSON export's keys, unchanged (a file format)"],
    ["Results.tsx", /^\s*"[^"]+": "results\.col_\d+",$/, "the same JSON keys mapped to the CSV headers in the page's language"],
  ];
  it("outside comments, only the allowed data", async () => {
    const fs = await import("node:fs");
    const path = await import("node:path");
    const dir = path.resolve(__dirname);
    const files = fs.readdirSync(dir).filter((f) => /\.tsx?$/.test(f) && !/^i18n\.text|\.test\.|^fixture\.ts$|^test-setup\.ts$/.test(f));
    const left: string[] = [];
    for (const f of files) {
      const code = fs.readFileSync(path.join(dir, f), "utf8").replace(/\/\*[\s\S]*?\*\//g, (c) => c.replace(/[^\n]/g, ""))
        .replace(/(^|[^:"'`])\/\/.*$/gm, "$1");
      code.split("\n").forEach((line, i) => {
        if (CJK.test(line) && !ALLOW.some(([af, re]) => af === f && re.test(line))) left.push(`${f}:${i + 1}: ${line.trim()}`);
      });
    }
    expect(left).toEqual([]);
  });
});
