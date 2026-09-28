// Scrubbing for error reports and logs, shared by the app
// (src/lib/errorReporting.ts) and the edge functions (_shared/log.ts).
// Pure: no Deno, no DOM.
//
// What goes: email addresses, bearer/basic credentials, JWTs, long
// token-looking strings, every query string and fragment on a URL, secret-ish
// key=value pairs, and any caller-supplied secret value (raw or URL-encoded).

const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const JWT = /\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\b/g;
const AUTH_HEADER = /\b(Bearer|Basic|Token)\s+[A-Za-z0-9._~+/=-]{8,}/gi;
// Stripe-style and other prefixed keys (sk_live_…, whsec_…, pk_test_…, rk_…).
const PREFIXED_KEY = /\b(?:sk|pk|rk|whsec|re|sbp|sb_secret|sb_publishable)_[A-Za-z0-9_]{8,}\b/g;
// key=value / "key": "value" where the key names a secret.
const SECRET_PAIR = /\b((?:api[_-]?key|api[_-]?token|apitoken|access[_-]?token|refresh[_-]?token|token|secret|password|passwd|source|signature|sig|client[_-]?secret|key|code|auth|authorization)["']?\s*[:=]\s*["']?)([^\s"'&,;}]+)/gi;
// A long run of hex / base64url characters with at least one digit: a token.
// UUIDs (row ids) are kept: they identify, they don't authorize.
const LONG_TOKEN = /\b(?![0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b)(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]{32,}\b/g;
const URL_RE = /\b([a-z][a-z0-9+.-]*:\/\/[^\s?#"'<>)]+)([?#][^\s"'<>)]*)?/gi;

/** A URL with its query string and fragment removed. */
export function stripQuery(url: string): string {
  return url.replace(URL_RE, (_m, base: string) => base);
}

/** `s` with emails, credentials, tokens, query strings and `secrets` removed. */
export function scrub(s: string, secrets: ReadonlyArray<string | null | undefined> = []): string {
  let out = String(s ?? '');
  for (const secret of secrets) {
    if (!secret || secret.length < 6) continue;
    for (const form of new Set([secret, encodeURIComponent(secret)])) out = out.split(form).join('[redacted]');
  }
  return out
    .replace(URL_RE, (_m, base: string, q?: string) => base + (q ? '?[redacted]' : ''))
    .replace(JWT, '[jwt]')
    .replace(AUTH_HEADER, (_m, scheme: string) => `${scheme} [redacted]`)
    .replace(PREFIXED_KEY, '[key]')
    .replace(SECRET_PAIR, (_m, k: string) => `${k}[redacted]`)
    .replace(EMAIL, '[email]')
    .replace(LONG_TOKEN, '[token]');
}

/** A thrown value as scrubbed text: "Name: message", bounded. */
export function scrubError(err: unknown, secrets: ReadonlyArray<string | null | undefined> = [], max = 1000): string {
  const raw = err instanceof Error ? `${err.name}: ${err.message}` : typeof err === 'string' ? err : safeJson(err);
  return scrub(raw, secrets).slice(0, max);
}

/** A stack trace, scrubbed (file URLs lose their query strings too). */
export function scrubStack(err: unknown, secrets: ReadonlyArray<string | null | undefined> = [], max = 4000): string | undefined {
  const st = err instanceof Error ? err.stack : undefined;
  return st ? scrub(st, secrets).slice(0, max) : undefined;
}

function safeJson(v: unknown): string {
  try {
    return JSON.stringify(v) ?? String(v);
  } catch {
    return String(v);
  }
}

/** Parsed Sentry DSN: https://<key>@<host>/<projectId>. Null when malformed. */
export interface SentryDsn {
  key: string;
  origin: string;
  projectId: string;
}

export function parseSentryDsn(dsn: string | null | undefined): SentryDsn | null {
  if (!dsn) return null;
  try {
    const u = new URL(dsn.trim());
    const projectId = u.pathname.replace(/^\/+|\/+$/g, '').split('/').pop() ?? '';
    const pathPrefix = u.pathname.replace(/\/?[^/]*\/?$/, '');
    if (!u.username || !/^\d+$/.test(projectId) || (u.protocol !== 'https:' && u.protocol !== 'http:')) return null;
    return { key: u.username, origin: `${u.protocol}//${u.host}${pathPrefix}`, projectId };
  } catch {
    return null;
  }
}

/** The store endpoint for a DSN; the key goes in the X-Sentry-Auth header, not the URL. */
export function sentryStoreUrl(d: SentryDsn): string {
  return `${d.origin}/api/${d.projectId}/store/`;
}

export function sentryAuthHeader(d: SentryDsn, client: string): string {
  return `Sentry sentry_version=7, sentry_client=${client}, sentry_key=${d.key}`;
}

export interface SentryEventInput {
  message: string;
  exceptionType?: string;
  stack?: string;
  level?: 'error' | 'warning' | 'info';
  platform: 'javascript' | 'node';
  logger: string;
  environment?: string;
  release?: string;
  url?: string;
  tags?: Record<string, string>;
}

/** A minimal Sentry store-API event (already scrubbed input). */
export function sentryEvent(e: SentryEventInput, now = new Date(), id = randomHex32()): Record<string, unknown> {
  return {
    event_id: id,
    timestamp: now.toISOString(),
    level: e.level ?? 'error',
    platform: e.platform,
    logger: e.logger,
    environment: e.environment,
    release: e.release,
    message: e.message,
    exception: e.exceptionType ? { values: [{ type: e.exceptionType, value: e.message }] } : undefined,
    extra: e.stack ? { stack: e.stack } : undefined,
    request: e.url ? { url: e.url } : undefined,
    tags: e.tags,
  };
}

function randomHex32(): string {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
}
