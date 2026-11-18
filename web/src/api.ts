let token: Promise<string> | null = null;

function session(): Promise<string> {
  token ??= fetch("/api/session").then((r) => r.json()).then((j) => j.token as string);
  return token;
}

async function send<T>(method: string, url: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = { "X-BirdCM-Token": await session() };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const r = await fetch(url, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  if (!r.ok) throw new Error((await r.json().catch(() => null))?.detail ?? (await r.text().catch(() => r.statusText)));
  return r.json();
}

export async function get<T>(url: string): Promise<T> {
  const r = await fetch(url);
  if (!r.ok) throw new Error((await r.json().catch(() => null))?.detail ?? r.statusText);
  return r.json();
}
export const post = <T,>(url: string, body?: unknown) => send<T>("POST", url, body);
export const put = <T,>(url: string, body?: unknown) => send<T>("PUT", url, body);
export const del = <T,>(url: string) => send<T>("DELETE", url);

export async function upload<T>(url: string, form: FormData): Promise<T> {
  const r = await fetch(url, { method: "POST", headers: { "X-BirdCM-Token": await session() }, body: form });
  if (!r.ok) throw new Error((await r.json().catch(() => null))?.detail ?? r.statusText);
  return r.json();
}
