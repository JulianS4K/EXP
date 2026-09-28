// Shared HTTP transport for the Vivid Seats reader (client.ts) and writer
// (writer.ts).
//
// Auth depends on the endpoint (endpoints.ts): v2 / events take the token in
// the `Api-token` header; v1 takes it as `apiToken`, a query parameter on a
// GET and a form field on a POST. It's added here, at the last moment, and
// never appears in a planned request, an error or a log line: errors name
// the endpoint's path, not the URL, and any echo of the token is redacted.
// `X-Integrator-Token` goes on every call when one is set.
//
// v1 answers in XML, and reports failures as HTTP 200 with
// <success>false</success> and a message; readVividBody() turns those into
// VividError too.

import { guardedFetch } from '../netError.ts';
import { VIVID_API_HOST, buildPath, type Endpoint } from './endpoints.ts';
import { XmlError, child, parseXml, type XmlElement } from './xml.ts';

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;
export type QueryValue = string | number | boolean | null | undefined;
export type FormValue = QueryValue | ReadonlyArray<string | number>;

export interface VividCredentials {
  apiToken: string;
  /** X-Integrator-Token, when Vivid issued one for the integration. */
  integratorToken?: string | null;
}

export interface RequestParts {
  path?: Record<string, string | number>;
  query?: Record<string, QueryValue>;
  /** application/json body (v2). */
  json?: unknown;
  /** application/x-www-form-urlencoded body (v1); arrays become repeated fields. */
  form?: Record<string, FormValue>;
}

export interface TransportConfig {
  baseUrl: string;
  credentials: () => VividCredentials | Promise<VividCredentials>;
  fetch: FetchLike;
  maxRetries: number;
  sleep: (ms: number) => Promise<void>;
}

export class VividError extends Error {
  constructor(message: string, readonly status: number, readonly body: unknown) {
    super(message);
    this.name = 'VividError';
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

export function formBody(form: Record<string, FormValue> = {}): string {
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries(form)) {
    if (v === undefined || v === null || v === '') continue;
    if (Array.isArray(v)) for (const x of v) params.append(k, String(x));
    else params.set(k, String(v));
  }
  return params.toString();
}

/** The path and query, without the token: what a plan or an error may show. */
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
    baseUrl: (opts.baseUrl ?? VIVID_API_HOST).replace(/\/+$/, ''),
    credentials: opts.credentials,
    fetch: opts.fetch ?? ((input, init) => fetch(input, init)),
    maxRetries: opts.maxRetries ?? 2,
    sleep: opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))),
  };
}

/** Every trace of the secrets out of a string. */
export function redact(s: string, c: VividCredentials): string {
  let out = s;
  for (const secret of [c.apiToken, c.integratorToken]) {
    if (secret && secret.length >= 4) {
      out = out.split(secret).join('[redacted]');
      const enc = encodeURIComponent(secret);
      if (enc !== secret) out = out.split(enc).join('[redacted]');
    }
  }
  return out;
}

export async function execute(cfg: TransportConfig, ep: Endpoint, parts: RequestParts, retryOn: ReadonlySet<number>): Promise<{ res: Response; creds: VividCredentials }> {
  const c = await cfg.credentials();
  if (!c.apiToken) throw new Error('vivid: no API token');
  const query = ep.auth === 'param' && ep.method === 'GET' ? { ...parts.query, apiToken: c.apiToken } : parts.query;
  const url = cfg.baseUrl + buildPath(ep.path, parts.path) + toQueryString(query);
  for (let attempt = 0; ; attempt++) {
    const headers: Record<string, string> = { Accept: 'application/json, application/xml;q=0.9' };
    if (ep.auth === 'header') headers['Api-token'] = c.apiToken;
    if (c.integratorToken) headers['X-Integrator-Token'] = c.integratorToken;
    let body: string | undefined;
    if (ep.body === 'json') {
      headers['Content-Type'] = 'application/json';
      body = JSON.stringify(parts.json ?? {});
    } else if (ep.body === 'form') {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
      body = formBody(ep.auth === 'param' ? { ...parts.form, apiToken: c.apiToken } : parts.form);
    }
    const res = await guardedFetch(cfg.fetch, url, { method: ep.method, headers, body }, `vivid ${ep.method} ${ep.path}`, [c.apiToken, c.integratorToken]);
    if (res.ok) return { res, creds: c };
    if (retryOn.has(res.status) && attempt < cfg.maxRetries) {
      await cfg.sleep(1000 * 2 ** attempt);
      continue;
    }
    const text = redact(await res.text(), c);
    const msg = messageOf(text);
    throw new VividError(`vivid ${ep.method} ${ep.path} -> ${res.status}${msg ? `: ${msg}` : ''}`, res.status, text.slice(0, 2000) || null);
  }
}

function messageOf(text: string): string | null {
  const t = text.trim();
  if (!t) return null;
  try {
    if (t.startsWith('{')) {
      const m = (JSON.parse(t) as { message?: unknown }).message;
      return typeof m === 'string' ? m.slice(0, 300) : null;
    }
    if (t.startsWith('<')) {
      const m = child(parseXml(t), 'message');
      return m ? m.text.trim().slice(0, 300) : null;
    }
  } catch {
    // not parseable: no message
  }
  return null;
}

export type VividBody = { kind: 'json'; value: unknown } | { kind: 'xml'; root: XmlElement } | { kind: 'empty' };

/**
 * A successful response's body, JSON or XML. A `success: false` answer (v1
 * says failures that way, with HTTP 200) throws VividError with its message.
 */
export async function readVividBody(res: Response, ep: Endpoint, creds: VividCredentials): Promise<VividBody> {
  const text = redact(await res.text(), creds).trim();
  if (!text) return { kind: 'empty' };
  let body: VividBody;
  if (text.startsWith('<')) {
    try {
      body = { kind: 'xml', root: parseXml(text) };
    } catch (e) {
      throw new VividError(`vivid ${ep.method} ${ep.path}: unreadable XML (${e instanceof XmlError ? e.message : String(e)})`, res.status, text.slice(0, 2000));
    }
    const ok = child(body.root, 'success');
    if (ok && ok.text.trim().toLowerCase() === 'false') {
      const m = child(body.root, 'message')?.text.trim();
      throw new VividError(`vivid ${ep.method} ${ep.path} failed${m ? `: ${m.slice(0, 300)}` : ''}`, res.status, text.slice(0, 2000));
    }
    return body;
  }
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new VividError(`vivid ${ep.method} ${ep.path}: unreadable response`, res.status, text.slice(0, 2000));
  }
  const v = value as { success?: unknown; message?: unknown } | null;
  if (v && typeof v === 'object' && !Array.isArray(v) && v.success === false) {
    throw new VividError(`vivid ${ep.method} ${ep.path} failed${typeof v.message === 'string' ? `: ${v.message.slice(0, 300)}` : ''}`, res.status, value);
  }
  return { kind: 'json', value };
}
