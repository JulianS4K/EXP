// Shared HTTP transport for the StubHub reader (client.ts) and writer
// (writer.ts). Knows nothing about read/write policy; each caller decides
// what it's allowed to send before it gets here.

import { buildPath, type Endpoint } from './endpoints';
import type { ApiErrorBody } from './types';

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;
export type TokenSource = () => string | Promise<string>;
export type QueryValue = string | number | boolean | Date | null | undefined;

export interface RequestParts {
  path?: Record<string, string | number>;
  query?: Record<string, QueryValue>;
  body?: unknown;
}

export interface TransportConfig {
  baseUrl: string;
  accessToken: TokenSource;
  fetch: FetchLike;
  maxRetries: number;
  sleep: (ms: number) => Promise<void>;
}

export class StubHubError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly body: ApiErrorBody | string | null,
  ) {
    super(message);
    this.name = 'StubHubError';
  }
}

/** Safe to retry for any request: StubHub didn't process it. */
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

/** Retry-After is seconds or an HTTP date; fall back to exponential backoff. */
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
  baseUrl: string;
  accessToken: TokenSource;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}): TransportConfig {
  if (!opts.baseUrl) throw new Error('stubhub: baseUrl is required');
  return {
    baseUrl: opts.baseUrl.replace(/\/+$/, ''),
    accessToken: opts.accessToken,
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
  const hasBody = parts.body !== undefined;

  for (let attempt = 0; ; attempt++) {
    const token = await cfg.accessToken();
    const res = await cfg.fetch(url, {
      method: ep.method,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/hal+json, application/json',
        ...(hasBody ? { 'Content-Type': 'application/json' } : {}),
      },
      body: hasBody ? JSON.stringify(parts.body) : undefined,
    });
    if (res.ok) return res;
    if (retryOn.has(res.status) && attempt < cfg.maxRetries) {
      await cfg.sleep(retryDelayMs(res, attempt));
      continue;
    }
    const text = await res.text();
    let body: ApiErrorBody | string | null = text || null;
    try {
      body = text ? (JSON.parse(text) as ApiErrorBody) : null;
    } catch {
      // non-JSON error body; keep the raw text
    }
    const detail = typeof body === 'object' && body?.message ? `: ${body.message}` : '';
    throw new StubHubError(`stubhub ${ep.method} ${ep.path} -> ${res.status}${detail}`, res.status, body);
  }
}
