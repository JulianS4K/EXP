// SSRF-guarded fetch for remote ActivityPub documents and inboxes
// (docs/federation.md). Every URL, including each redirect hop, must pass
// urlIsBlocked() from ../ssrf.ts: https only, no credentials, no internal
// names, and every A / AAAA address public (no private, loopback, link-local,
// CGNAT, metadata or IPv6 transition forms).
//
//   * redirects are followed by hand (redirect: "manual"), at most
//     maxRedirects, each hop re-checked; POSTs never follow redirects
//   * a time cap (AbortController) and a body cap (streamed; the read stops
//     at maxBytes and the request fails)
//
// Residual risk, same as ../ssrf.ts: fetch() resolves DNS again after the
// check, so a rebinding host could still flip between the two lookups.
//
// Pure: fetch and the DNS resolver are injected, so vitest drives it.

import { urlIsBlocked } from "../ssrf.ts";

export type Resolver = (host: string) => Promise<string[]>;
export type Fetcher = (url: string, init: RequestInit) => Promise<Response>;

export interface GuardOptions {
  method?: "GET" | "POST";
  headers?: Record<string, string>;
  body?: string;
  maxBytes?: number;
  timeoutMs?: number;
  maxRedirects?: number;
  resolve?: Resolver;
  fetchImpl?: Fetcher;
}

export interface GuardResult {
  ok: boolean;
  status: number;
  url: string;
  body: string;
  contentType: string;
  error?: string;
  /** The URL was refused before any request (SSRF), so retrying is pointless. */
  blocked?: boolean;
}

/** Read a Request or Response body, failing past maxBytes (declared or streamed). */
export async function readCapped(res: { headers: Headers; body: ReadableStream<Uint8Array> | null }, maxBytes: number): Promise<string> {
  const declared = Number(res.headers.get("content-length") ?? "");
  if (Number.isFinite(declared) && declared > maxBytes) throw new Error(`body over ${maxBytes} bytes`);
  if (!res.body) return "";
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => {});
      throw new Error(`body over ${maxBytes} bytes`);
    }
    chunks.push(value);
  }
  const all = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    all.set(c, off);
    off += c.byteLength;
  }
  return new TextDecoder().decode(all);
}

export async function guardedFetch(rawUrl: string, o: GuardOptions = {}): Promise<GuardResult> {
  const method = o.method ?? "GET";
  const maxBytes = o.maxBytes ?? 256 * 1024;
  const timeoutMs = o.timeoutMs ?? 8000;
  const maxRedirects = method === "POST" ? 0 : (o.maxRedirects ?? 3);
  const fetchImpl: Fetcher = o.fetchImpl ?? ((u, i) => fetch(u, i));
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  let url = rawUrl;
  try {
    for (let hop = 0; ; hop++) {
      const why = await urlIsBlocked(url, o.resolve);
      if (why) return { ok: false, status: 0, url, body: "", contentType: "", error: `blocked: ${why}`, blocked: true };
      const res = await fetchImpl(url, {
        method,
        headers: o.headers,
        body: method === "POST" ? o.body : undefined,
        redirect: "manual",
        signal: ctrl.signal,
      });
      if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
        await res.body?.cancel().catch(() => {});
        if (hop >= maxRedirects) {
          return { ok: false, status: res.status, url, body: "", contentType: "", error: "too many redirects" };
        }
        url = new URL(res.headers.get("location")!, url).toString();
        continue;
      }
      const body = await readCapped(res, maxBytes);
      return {
        ok: res.status >= 200 && res.status < 300,
        status: res.status,
        url,
        body,
        contentType: res.headers.get("content-type") ?? "",
      };
    }
  } catch (e) {
    const msg = (e as Error)?.name === "AbortError" ? `timed out after ${timeoutMs} ms` : String((e as Error)?.message ?? e);
    return { ok: false, status: 0, url, body: "", contentType: "", error: msg.slice(0, 200) };
  } finally {
    clearTimeout(timer);
  }
}

export const AP_ACCEPT =
  'application/activity+json, application/ld+json; profile="https://www.w3.org/ns/activitystreams"';

/** GET an ActivityPub JSON document (actor, object) through the guard. */
export async function fetchApJson(
  url: string,
  o: Omit<GuardOptions, "method" | "body"> = {},
): Promise<{ ok: true; json: Record<string, unknown>; url: string } | { ok: false; error: string }> {
  const r = await guardedFetch(url, { ...o, method: "GET", headers: { accept: AP_ACCEPT, ...(o.headers ?? {}) } });
  if (!r.ok) return { ok: false, error: r.error ?? `HTTP ${r.status}` };
  if (!/json/i.test(r.contentType)) return { ok: false, error: "not JSON" };
  try {
    const j = JSON.parse(r.body);
    if (typeof j !== "object" || j === null || Array.isArray(j)) return { ok: false, error: "not an object" };
    return { ok: true, json: j as Record<string, unknown>, url: r.url };
  } catch {
    return { ok: false, error: "bad JSON" };
  }
}
