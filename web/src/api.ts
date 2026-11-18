let token: Promise<string> | null = null;

function session(fresh = false): Promise<string> {
  if (fresh) token = null;
  // a failed fetch must not stick: the next call asks again
  token ??= fetch("/api/session").then((r) => r.json()).then((j) => j.token as string).catch((e) => { token = null; throw e; });
  return token;
}

// A write carries the session token. The engine makes a new one each start, so a 403 (page opened before a restart)
// fetches the token again and retries once.
async function withToken(make: (tok: string) => Promise<Response>): Promise<Response> {
  let r = await make(await session());
  if (r.status === 403) r = await make(await session(true));
  return r;
}

async function fail(r: Response): Promise<never> {
  const t = await r.text().catch(() => r.statusText);
  let msg = t;
  try { msg = JSON.parse(t)?.detail ?? t; } catch { /* plain text */ }
  throw new Error(msg || r.statusText);
}

async function send<T>(method: string, url: string, body?: unknown): Promise<T> {
  const r = await withToken((tok) => {
    const headers: Record<string, string> = { "X-BirdCM-Token": tok };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    return fetch(url, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  });
  if (!r.ok) return fail(r);
  return r.json();
}

export async function get<T>(url: string): Promise<T> {
  const r = await fetch(url);
  if (!r.ok) return fail(r);
  return r.json();
}
export const post = <T,>(url: string, body?: unknown) => send<T>("POST", url, body);
export const put = <T,>(url: string, body?: unknown) => send<T>("PUT", url, body);
export const del = <T,>(url: string) => send<T>("DELETE", url);

export async function upload<T>(url: string, form: FormData): Promise<T> {
  const r = await withToken((tok) => fetch(url, { method: "POST", headers: { "X-BirdCM-Token": tok }, body: form }));
  if (!r.ok) return fail(r);
  return r.json();
}

/** A POST whose answer is text (a file to save), with the same token handling. */
export async function postText(url: string, body: unknown): Promise<string> {
  const r = await withToken((tok) => fetch(url, { method: "POST", headers: { "X-BirdCM-Token": tok, "Content-Type": "application/json" }, body: JSON.stringify(body) }));
  if (!r.ok) return fail(r);
  return r.text();
}
