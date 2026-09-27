// Shared HTTP transport for the SeatGeek reader (client.ts) and writer
// (writer.ts). Knows nothing about read/write policy; each caller decides
// what it may send before it gets here.
//
// Auth: the seller API token in the Authorization header. The API spec
// recommends `Bearer {token}`; the listing guide's examples use
// `token {token}`. Both are documented, so the scheme is an option
// (default Bearer). The ?token= query form is never used: it puts the token
// in logs.
//
// A listing create/update can return 409 Conflict during the 5-minute
// post-order inventory lock (listing guide). 409 is never retried here: the
// caller decides (recreate after a rejected order, retry after it settles).
// PATCH /order takes multipart/form-data; everything else is JSON or none.

import { SEATGEEK_API_HOST, buildPath, type Endpoint } from './endpoints.ts';

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;
export type TokenSource = () => string | Promise<string>;
export type QueryValue = string | number | boolean | Date | null | undefined;
/** multipart/form-data fields, in order. A name may repeat. */
export type FormFields = ReadonlyArray<readonly [string, string]>;

export interface RequestParts {
  path?: Record<string, string | number>;
  query?: Record<string, QueryValue>;
  body?: unknown;
  form?: FormFields;
}

export const DEFAULT_USER_AGENT = 'Exos-SeatGeek/1.0';

export type AuthScheme = 'Bearer' | 'token';

export interface TransportConfig {
  authScheme: AuthScheme;
  baseUrl: string;
  userAgent: string;
  token: TokenSource;
  fetch: FetchLike;
  maxRetries: number;
  sleep: (ms: number) => Promise<void>;
}

export class SeatGeekError extends Error {
  constructor(message: string, readonly status: number, readonly body: unknown) {
    super(message);
    this.name = 'SeatGeekError';
  }
}

/** Safe to retry for any request: SeatGeek didn't process it. */
export const RETRY_THROTTLED = new Set([429]);
/** Also safe for side-effect-free requests. */
export const RETRY_TRANSIENT = new Set([429, 502, 503, 504]);

export function toQueryString(query: Record<string, QueryValue> = {}): string {
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries(query)) {
    if (v === undefined || v === null || v === '') continue;
    params.set(k, v instanceof Date ? v.toISOString() : String(v));
  }
  const s = params.toString();
  return s ? `?${s}` : '';
}

/** Path + query, relative to the API host. */
export function relativeUrl(ep: Endpoint, parts: RequestParts = {}): string {
  return buildPath(ep.path, parts.path) + toQueryString(parts.query);
}

function retryDelayMs(res: Response, attempt: number): number {
  const header = res.headers.get('retry-after');
  if (header) {
    const secs = Number(header);
    if (Number.isFinite(secs)) return Math.min(secs * 1000, 60_000);
    const at = Date.parse(header);
    if (Number.isFinite(at)) return Math.max(0, Math.min(at - Date.now(), 60_000));
  }
  return 500 * 2 ** attempt;
}

export function transportConfig(opts: {
  token: TokenSource;
  authScheme?: AuthScheme;
  baseUrl?: string;
  userAgent?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}): TransportConfig {
  return {
    authScheme: opts.authScheme ?? 'Bearer',
    baseUrl: (opts.baseUrl ?? SEATGEEK_API_HOST).replace(/\/+$/, ''),
    userAgent: opts.userAgent ?? DEFAULT_USER_AGENT,
    token: opts.token,
    fetch: opts.fetch ?? ((input, init) => fetch(input, init)),
    maxRetries: opts.maxRetries ?? 2,
    sleep: opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))),
  };
}

export async function execute(
  cfg: TransportConfig,
  ep: Endpoint,
  parts: RequestParts,
  retryOn: ReadonlySet<number>,
): Promise<Response> {
  const url = cfg.baseUrl + relativeUrl(ep, parts);
  for (let attempt = 0; ; attempt++) {
    const headers: Record<string, string> = {
      Authorization: `${cfg.authScheme} ${await cfg.token()}`,
      Accept: 'application/json',
      'User-Agent': cfg.userAgent,
    };
    let body: BodyInit | undefined;
    if (parts.form) {
      const fd = new FormData();
      for (const [k, v] of parts.form) fd.append(k, v);
      body = fd; // fetch sets the multipart boundary
    } else if (parts.body !== undefined) {
      headers['Content-Type'] = 'application/json';
      body = JSON.stringify(parts.body);
    }
    const res = await cfg.fetch(url, { method: ep.method, headers, body });
    if (res.ok) return res;
    if (retryOn.has(res.status) && attempt < cfg.maxRetries) {
      await cfg.sleep(retryDelayMs(res, attempt));
      continue;
    }
    const text = await res.text();
    let parsed: unknown = text || null;
    try {
      parsed = text ? JSON.parse(text) : null;
    } catch {
      // keep the raw text
    }
    const msg = (parsed as { error?: unknown; message?: unknown } | null);
    const detail = typeof msg === 'object' && msg && (msg.error || msg.message) ? `: ${String(msg.error ?? msg.message)}` : '';
    throw new SeatGeekError(`seatgeek ${ep.method} ${ep.path} -> ${res.status}${detail}`, res.status, parsed);
  }
}
