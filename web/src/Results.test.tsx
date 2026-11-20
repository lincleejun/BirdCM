// @vitest-environment happy-dom
// The result page rendered for real against a mocked engine: what the clicks and keys send.
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { row } from "./fixture";
import Results from "./Results";
import type { PhotoRow, Snapshot } from "./types";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const SID = 7;
// 24 photos, two species, distinct qualities so the default order (stars, then quality) is known: ids 1..24 in that order
const PHOTOS: PhotoRow[] = Array.from({ length: 24 }, (_, i) => row(i + 1, {
  stars: i < 8 ? 3 : i < 16 ? 2 : 1, q: 1 - i / 100, sci: i % 2 ? "Pica serica" : "Passer montanus", zh: i % 2 ? "喜鹊" : "麻雀",
  star_auto: i === 0,                                    // photo 1 carries the person's own stars: it has 撤回
}));
const snapshot = (): Snapshot => ({
  scan: { id: SID, folder: "/f", recursive: 0, region: null, ratio: { strategy: "select" }, state: "completed", error: null, created_at: 0,
    counts: { queued: 0, working: 0, done: 24, failed: 0, total: 24 } },
  photos: PHOTOS, cursor: 1,
});

let calls: { method: string; url: string; body: unknown }[] = [];
const writes = (path: string) => calls.filter((c) => c.method !== "GET" && c.url === `/api/scans/${SID}/${path}`);
const json = (v: unknown) => new Response(JSON.stringify(v), { status: 200, headers: { "Content-Type": "application/json" } });

let root: Root, box: HTMLDivElement;
beforeEach(async () => {
  calls = [];
  vi.stubGlobal("fetch", vi.fn(async (url: string, init?: RequestInit) => {
    const method = init?.method ?? "GET";
    calls.push({ method, url, body: init?.body ? JSON.parse(init.body as string) : undefined });
    if (url === "/api/session") return json({ token: "t" });
    if (url === "/api/models") return json({ engine: "ready", load_error: null });
    if (url === `/api/scans/${SID}`) return json(snapshot());
    if (url === `/api/scans/${SID}/related`) return json({ newer: null, previous: null, stale: false });
    if (url.startsWith("/api/species")) return json([]);
    if (method === "POST") return json({ ok: true });
    return new Response("not mocked", { status: 404 });
  }));
  box = document.createElement("div");
  document.body.append(box);
  root = createRoot(box);
  await act(async () => root.render(<Results scanId={SID} onBack={() => {}} onOpen={() => {}} catalogue={[]} brand={null} nav={null} />));
  await settle();
  expect(tiles()).toHaveLength(24);
});
afterEach(() => { act(() => root.unmount()); box.remove(); vi.unstubAllGlobals(); });

/** Let fetches answer and React render (a few macrotask turns). */
async function settle() { for (let i = 0; i < 5; i++) await act(() => new Promise((r) => setTimeout(r, 0))); }
const tiles = () => [...box.querySelectorAll<HTMLButtonElement>("#grid .tile")];
const tile = (id: number) => tiles().find((t) => t.getAttribute("aria-label")!.endsWith(`p${id}.ARW`))!;
const picked = () => tiles().filter((t) => t.dataset.picked !== undefined).map((t) => +t.getAttribute("aria-label")!.match(/p(\d+)\.ARW$/)![1]);
const current = () => tiles().filter((t) => t.getAttribute("aria-pressed") === "true").map((t) => +t.getAttribute("aria-label")!.match(/p(\d+)\.ARW$/)![1]);
async function click(el: Element, mod: MouseEventInit = {}) {
  await act(async () => { el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, ...mod })); });
  await settle();
}
async function key(k: string, el: Element = box.querySelector("#grid .tile[aria-pressed=true]")!) {
  await act(async () => { el.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true })); });
  await settle();
}
const button = (text: string, within: ParentNode = box) => [...within.querySelectorAll("button")].find((b) => b.textContent === text)!;

describe("stars", () => {
  it("number keys, X and U on the current photo: one POST each with its id", async () => {
    await click(tile(5));
    await key("2");
    await key("x");
    await key("u");
    expect(writes("stars").map((c) => c.body)).toEqual([
      { photo_ids: [5], stars: 2 }, { photo_ids: [5], stars: -1 }, { photo_ids: [5], stars: null }]);
  });
  it("the panel's buttons, and 撤回 sends stars: null", async () => {
    await click(tile(1));
    const panel = box.querySelector(".inspector")!;
    await click(button("★★★", panel));
    await click(button("撤回", panel));
    expect(writes("stars").map((c) => c.body)).toEqual([{ photo_ids: [1], stars: 3 }, { photo_ids: [1], stars: null }]);
  });
});

describe("multi-select", () => {
  it("Cmd and Ctrl toggle; the photo picked before joins; Esc empties the set", async () => {
    await click(tile(2));
    await click(tile(4), { metaKey: true });
    await click(tile(6), { ctrlKey: true });
    expect(picked()).toEqual([2, 4, 6]);
    await click(tile(4), { metaKey: true });
    expect(picked()).toEqual([2, 6]);
    expect(box.querySelector(".batch b")!.textContent).toBe("已选 2 张");
    await key("Escape");
    expect(picked()).toEqual([]);
    expect(box.querySelector(".batch")).toBeNull();
  });
  it("Shift picks the run from the last click; after the arrows it runs from the photo they reached", async () => {
    await click(tile(3));
    await click(tile(6), { shiftKey: true });
    expect(picked()).toEqual([3, 4, 5, 6]);
    await click(tile(10));                                // plain click: one photo, the anchor moves
    expect(picked()).toEqual([]);
    await key("ArrowRight");
    await key("ArrowRight");
    expect(current()).toEqual([12]);
    await click(tile(14), { shiftKey: true });
    expect(picked()).toEqual([12, 13, 14]);
  });
  it("20 picked, a star key: exactly one request carrying the 20 ids", async () => {
    await click(tile(1));
    await click(tile(20), { shiftKey: true });
    expect(picked()).toHaveLength(20);
    await key("3", tile(20));
    expect(writes("stars")).toHaveLength(1);
    const body = writes("stars")[0].body as { photo_ids: number[]; stars: number };
    expect(body.stars).toBe(3);
    expect([...body.photo_ids].sort((a, b) => a - b)).toEqual(Array.from({ length: 20 }, (_, i) => i + 1));
  });
  it("20 picked, the batch bar's star button: one request", async () => {
    await click(tile(5));
    await click(tile(24), { shiftKey: true });
    await click(button("0 星", box.querySelector(".batch")!));
    expect(writes("stars")).toHaveLength(1);
    expect((writes("stars")[0].body as { photo_ids: number[] }).photo_ids).toHaveLength(20);
    expect((writes("stars")[0].body as { stars: number }).stars).toBe(0);
  });
  it("20 picked, 改鸟种: one /corrections request with photo_ids", async () => {
    await click(tile(1));
    await click(tile(20), { shiftKey: true });
    const bar = box.querySelector(".batch")!;
    await click(button("改鸟种", bar));
    await click([...bar.querySelectorAll(".correct-list button")].find((b) => b.textContent!.includes("喜鹊"))!);
    await click(button("改成 喜鹊", bar));
    expect(writes("corrections")).toHaveLength(1);
    const body = writes("corrections")[0].body as { photo_ids: number[]; sci: string };
    expect(body.sci).toBe("Pica serica");
    expect([...body.photo_ids].sort((a, b) => a - b)).toEqual(Array.from({ length: 20 }, (_, i) => i + 1));
    expect(writes("stars")).toHaveLength(0);
  });
});

describe("filters on the page", () => {
  it("the star radio and the species select narrow the grid", async () => {
    await click(box.querySelector<HTMLInputElement>('input[name=fs][value="3"]')!);
    expect(tiles().map((t) => t.getAttribute("aria-label")!.match(/p(\d+)\.ARW$/)![1]).map(Number)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
    const sp = box.querySelector<HTMLSelectElement>('select[aria-label="鸟种"]')!;
    await act(async () => { sp.value = "Pica serica"; sp.dispatchEvent(new Event("change", { bubbles: true })); });
    await settle();
    expect(tiles().map((t) => +t.getAttribute("aria-label")!.match(/p(\d+)\.ARW$/)![1])).toEqual([2, 4, 6, 8]);
  });
});

describe("compare", () => {
  it("both panes follow one viewport: Z zooms the two together", async () => {
    await click(tile(1));
    await click(tile(2), { metaKey: true });
    await click(button("并排对比"));
    const dlg = box.querySelector("dialog.viewer.compare")!;
    expect(dlg.querySelectorAll(".zoom")).toHaveLength(2);
    expect(dlg.querySelectorAll(".zoom.zoomed")).toHaveLength(0);
    await key("z", dlg);
    expect(dlg.querySelectorAll(".zoom.zoomed")).toHaveLength(2);
    await key("z", dlg);
    expect(dlg.querySelectorAll(".zoom.zoomed")).toHaveLength(0);
  });
});
