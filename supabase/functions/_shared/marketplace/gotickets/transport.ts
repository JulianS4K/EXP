// Shared HTTP transport for the GoTickets reader (client.ts) and writer
// (writer.ts). Auth is two headers, X-Api-Access-Id and X-Api-Access-Secret;
// neither is ever put in a URL, an error or a plan.

import { guardedFetch } from '../netError.ts';
import { GOTICKETS_API_HOST, buildPath, type Endpoint } from './endpoints.ts';

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;
export type QueryValue = string | number | boolean | null | undefined;

export interface GoTicketsCredentials {
  accessId: string;
  accessSecret: string;
}

export interface RequestParts {
  path?: Record<string, string | number>;
  query?: Record<string, QueryValue>;
  body?: unknown;
}

export interface TransportConfig {
  baseUrl: string;
  credentials: () => GoTicketsCredentials | Promise<GoTicketsCredentials>;
  fetch: FetchLike;
  maxRetries: number;
  sleep: (ms: number) => Promise<void>;
}

export class GoTicketsError extends Error {
  constructor(message: string, readonly status: number, readonly body: unknown) {
    super(message);
    this.name = 'GoTicketsError';
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

export function relativeUrl(ep: Endpoint, parts: RequestParts = {}): string {
  return buildPath(ep.path, parts.path) + toQueryString(parts.query);
}

export function transportConfig(opts: {
  credentials: TransportConfig['credentials'];
  baseUrl?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}): TransportConfig {
  return {
    baseUrl: (opts.baseUrl ?? GOTICKETS_API_HOST).replace(/\/+$/, ''),
    credentials: opts.credentials,
    fetch: opts.fetch ?? ((input, init) => fetch(input, init)),
    maxRetries: opts.maxRetries ?? 2,
    sleep: opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))),
  };
}

export async function execute(cfg: TransportConfig, ep: Endpoint, parts: RequestParts, retryOn: ReadonlySet<number>): Promise<Response> {
  const c = await cfg.credentials();
  if (!c.accessId || !c.accessSecret) throw new Error('gotickets: no API access id / secret');
  const url = cfg.baseUrl + relativeUrl(ep, parts);
  for (let attempt = 0; ; attempt++) {
    const headers: Record<string, string> = {
      Accept: 'application/json',
      'X-Api-Access-Id': c.accessId,
      'X-Api-Access-Secret': c.accessSecret,
    };
    let body: string | undefined;
    if (parts.body !== undefined) {
      headers['Content-Type'] = 'application/json';
      body = JSON.stringify(parts.body);
    }
    const res = await guardedFetch(cfg.fetch, url, { method: ep.method, headers, body }, `gotickets ${ep.method} ${ep.path}`, [c.accessId, c.accessSecret]);
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
    const msg = (parsed as { message?: unknown } | null)?.message;
    throw new GoTicketsError(`gotickets ${ep.method} ${ep.path} -> ${res.status}${typeof msg === 'string' ? `: ${msg}` : ''}`, res.status, parsed);
  }
}
