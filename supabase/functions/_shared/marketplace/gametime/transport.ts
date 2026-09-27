// Shared HTTP transport for the Gametime reader (client.ts) and writer
// (writer.ts). Knows nothing about read/write policy.
//
// Gametime authenticates with `?source={api_key}` on every request. The key
// therefore sits in the URL: it is added here, at the last moment, and never
// appears in an error, a log line or a planned request (those use
// relativeUrl, which has no key).

import { GAMETIME_API_HOSTS, buildPath, type Endpoint, type GametimeEnvironment } from './endpoints.ts';

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;
export type KeySource = () => string | Promise<string>;
export type QueryValue = string | number | boolean | null | undefined;
/** multipart/form-data fields, in order. A name may repeat (transfer_url[]). */
export type FormFields = ReadonlyArray<readonly [string, string]>;

export interface RequestParts {
  path?: Record<string, string | number>;
  query?: Record<string, QueryValue>;
  body?: unknown;
  form?: FormFields;
}

export interface TransportConfig {
  baseUrl: string;
  apiKey: KeySource;
  fetch: FetchLike;
  maxRetries: number;
  sleep: (ms: number) => Promise<void>;
}

export class GametimeError extends Error {
  constructor(message: string, readonly status: number, readonly body: unknown) {
    super(message);
    this.name = 'GametimeError';
  }
}

export const RETRY_THROTTLED = new Set([429]);
export const RETRY_TRANSIENT = new Set([429, 502, 503, 504]);

export function toQueryString(query: Record<string, QueryValue> = {}): string {
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries(query)) {
    if (v === undefined || v === null || v === '') continue;
    params.set(k, String(v));
  }
  const s = params.toString();
  return s ? `?${s}` : '';
}

/** Path + query, relative to the API base, WITHOUT the key. */
export function relativeUrl(ep: Endpoint, parts: RequestParts = {}): string {
  return buildPath(ep.path, parts.path) + toQueryString(parts.query);
}

export function transportConfig(opts: {
  apiKey: KeySource;
  environment?: GametimeEnvironment;
  baseUrl?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}): TransportConfig {
  return {
    baseUrl: (opts.baseUrl ?? GAMETIME_API_HOSTS[opts.environment ?? 'production']).replace(/\/+$/, ''),
    apiKey: opts.apiKey,
    fetch: opts.fetch ?? ((input, init) => fetch(input, init)),
    maxRetries: opts.maxRetries ?? 2,
    sleep: opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))),
  };
}

export async function execute(cfg: TransportConfig, ep: Endpoint, parts: RequestParts, retryOn: ReadonlySet<number>): Promise<Response> {
  const key = await cfg.apiKey();
  if (!key) throw new Error('gametime: no API key');
  const rel = relativeUrl(ep, parts);
  const url = cfg.baseUrl + rel + (rel.includes('?') ? '&' : '?') + 'source=' + encodeURIComponent(key);
  for (let attempt = 0; ; attempt++) {
    const headers: Record<string, string> = { Accept: 'application/json' };
    let body: BodyInit | undefined;
    if (parts.form) {
      const fd = new FormData();
      for (const [k, v] of parts.form) fd.append(k, v);
      body = fd;
    } else if (parts.body !== undefined) {
      headers['Content-Type'] = 'application/json';
      body = JSON.stringify(parts.body);
    }
    const res = await cfg.fetch(url, { method: ep.method, headers, body });
    if (res.ok) return res;
    if (retryOn.has(res.status) && attempt < cfg.maxRetries) {
      await cfg.sleep(500 * 2 ** attempt);
      continue;
    }
    const text = await res.text();
    let parsed: unknown = text || null;
    try {
      parsed = text ? JSON.parse(text) : null;
    } catch {
      // keep the raw text
    }
    // The key is in `url`: the message names the endpoint only.
    throw new GametimeError(`gametime ${ep.method} ${ep.path} -> ${res.status}`, res.status, parsed);
  }
}
