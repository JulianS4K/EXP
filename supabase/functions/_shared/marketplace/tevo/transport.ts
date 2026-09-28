// Shared HTTP transport for the TEvo reader (client.ts) and writer (writer.ts).
//
// Every call carries X-Token (the API token) and X-Signature: base64 of
// HMAC-SHA256(secret, string-to-sign), where the string to sign is
//   "<METHOD> <host><path>?<query>"   for GET / DELETE (query sorted by key)
//   "<METHOD> <host><path>?<body>"    for POST / PUT / PATCH (the exact JSON sent)
// VERIFY IN SANDBOX: this is TEvo v9's documented scheme as we know it; the
// pages the operator supplied (docs/marketplace/tevo/README.md) show the
// headers but not how the signature is made. signatureBase() is the one
// place to change if TEvo's check disagrees.
//
// Neither the token nor the secret ever appears in a planned request, an
// error or a log line: errors name the endpoint's path, and any echo of
// either is redacted.

import { guardedFetch } from '../netError.ts';
import { TEVO_HOSTS, buildPath, type Endpoint, type TevoEnvironment } from './endpoints.ts';

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;
export type QueryValue = string | number | boolean | null | undefined;

export interface TevoCredentials {
  token: string;
  secret: string;
}

export interface RequestParts {
  path?: Record<string, string | number>;
  query?: Record<string, QueryValue>;
  json?: unknown;
}

export interface TransportConfig {
  baseUrl: string;
  credentials: () => TevoCredentials | Promise<TevoCredentials>;
  fetch: FetchLike;
  maxRetries: number;
  sleep: (ms: number) => Promise<void>;
}

export class TevoError extends Error {
  constructor(message: string, readonly status: number, readonly body: unknown) {
    super(message);
    this.name = 'TevoError';
  }
}

export const RETRY_THROTTLED = new Set([429]);
export const RETRY_TRANSIENT = new Set([429, 502, 503, 504]);

/** Query string with keys sorted (the signature covers it in this order); empty values dropped. */
export function toQueryString(query: Record<string, QueryValue> = {}): string {
  const params = new URLSearchParams();
  for (const k of Object.keys(query).sort()) {
    const v = query[k];
    if (v === undefined || v === null || v === '') continue;
    params.set(k, String(v));
  }
  return params.toString();
}

/** The path and query, without credentials: what a plan or an error may show. */
export function relativeUrl(ep: Endpoint, parts: RequestParts = {}): string {
  const q = toQueryString(parts.query);
  return buildPath(ep.path, parts.path) + (q ? `?${q}` : '');
}

/** The string TEvo signs: "<METHOD> <host><path>?<query or body>". */
export function signatureBase(method: string, baseUrl: string, path: string, queryOrBody: string): string {
  const host = baseUrl.replace(/^https?:\/\//, '').replace(/\/+$/, '');
  return `${method.toUpperCase()} ${host}${path}?${queryOrBody}`;
}

export async function hmacSha256Base64(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(message)));
  let bin = '';
  for (const b of sig) bin += String.fromCharCode(b);
  return btoa(bin);
}

export function transportConfig(opts: {
  credentials: TransportConfig['credentials'];
  environment?: TevoEnvironment;
  baseUrl?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}): TransportConfig {
  return {
    baseUrl: (opts.baseUrl ?? TEVO_HOSTS[opts.environment ?? 'sandbox']).replace(/\/+$/, ''),
    credentials: opts.credentials,
    fetch: opts.fetch ?? ((input, init) => fetch(input, init)),
    maxRetries: opts.maxRetries ?? 2,
    sleep: opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))),
  };
}

/** Every trace of the credentials out of a string. */
export function redact(s: string, c: TevoCredentials): string {
  let out = s;
  for (const secret of [c.token, c.secret]) {
    if (secret && secret.length >= 4) out = out.split(secret).join('[redacted]');
  }
  return out;
}

export async function execute(cfg: TransportConfig, ep: Endpoint, parts: RequestParts, retryOn: ReadonlySet<number>): Promise<{ res: Response; creds: TevoCredentials }> {
  const c = await cfg.credentials();
  if (!c.token || !c.secret) throw new Error('tevo: no API token or secret');
  const path = buildPath(ep.path, parts.path);
  const query = toQueryString(parts.query);
  const hasBody = ep.method === 'POST' || ep.method === 'PUT' || ep.method === 'PATCH';
  const body = hasBody ? JSON.stringify(parts.json ?? {}) : undefined;
  const url = cfg.baseUrl + path + (query ? `?${query}` : '');
  const signature = await hmacSha256Base64(c.secret, signatureBase(ep.method, cfg.baseUrl, path, hasBody ? body! : query));
  for (let attempt = 0; ; attempt++) {
    const headers: Record<string, string> = { Accept: 'application/json', 'X-Token': c.token, 'X-Signature': signature };
    if (hasBody) headers['Content-Type'] = 'application/json';
    const res = await guardedFetch(cfg.fetch, url, { method: ep.method, headers, body }, `tevo ${ep.method} ${ep.path}`, [c.token, c.secret, signature]);
    if (res.ok) return { res, creds: c };
    if (retryOn.has(res.status) && attempt < cfg.maxRetries) {
      await cfg.sleep(1000 * 2 ** attempt);
      continue;
    }
    const text = redact(await res.text(), c);
    let msg: string | null = null;
    try {
      const v = JSON.parse(text) as { error?: unknown; message?: unknown };
      const m = v.error ?? v.message;
      msg = typeof m === 'string' ? m.slice(0, 300) : null;
    } catch {
      // not JSON
    }
    throw new TevoError(`tevo ${ep.method} ${ep.path} -> ${res.status}${msg ? `: ${msg}` : ''}`, res.status, text.slice(0, 2000) || null);
  }
}

/** A successful JSON body (null when empty). */
export async function readTevoJson(res: Response, ep: Endpoint, creds: TevoCredentials): Promise<unknown> {
  const text = redact(await res.text(), creds).trim();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    throw new TevoError(`tevo ${ep.method} ${ep.path}: unreadable response`, res.status, text.slice(0, 2000));
  }
}
