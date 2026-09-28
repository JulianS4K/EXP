// Browser error reporting, without an SDK.
//
// When VITE_SENTRY_DSN is set, uncaught errors (ErrorBoundary, window
// 'error', 'unhandledrejection') are POSTed to that project's Sentry store
// endpoint as a minimal event; the DSN's public key goes in the
// X-Sentry-Auth header, not the URL. Without a DSN nothing leaves the
// browser: errors are only logged to the console, as before.
//
// Everything sent is scrubbed first (supabase/functions/_shared/scrub.ts,
// shared with the edge functions): emails, bearer/basic credentials, JWTs,
// long tokens and every URL's query string and fragment (claim keys, promo
// codes, checkout session ids) are removed; the page URL is sent as origin +
// path only. At most MAX_PER_PAGE reports per page load, one per distinct
// message.
//
// Env: VITE_SENTRY_DSN, VITE_SENTRY_ENVIRONMENT (optional, default
// "production"), VITE_SENTRY_RELEASE (optional). The page CSP allows
// https://*.sentry.io (src/lib/hosting/headers.ts); a self-hosted Sentry
// needs its host added there.

import { parseSentryDsn, scrub, scrubError, scrubStack, sentryAuthHeader, sentryEvent, sentryStoreUrl, stripQuery, type SentryDsn } from '../../supabase/functions/_shared/scrub.ts';

export { scrub, scrubError, stripQuery } from '../../supabase/functions/_shared/scrub.ts';

const MAX_PER_PAGE = 10;

type Env = Record<string, string | undefined>;
type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

interface ReporterState {
  dsn: SentryDsn | null;
  environment: string;
  release?: string;
  sent: number;
  seen: Set<string>;
  fetch: FetchLike;
}

let state: ReporterState | null = null;
let installed = false;

function env(): Env {
  return ((import.meta as unknown as { env?: Env }).env ?? {}) as Env;
}

/** Set up (or reset, in tests) the reporter. Returns whether reports will be sent. */
export function configureErrorReporting(opts: { dsn?: string | null; environment?: string; release?: string; fetch?: FetchLike } = {}): boolean {
  const e = env();
  state = {
    dsn: parseSentryDsn(opts.dsn !== undefined ? opts.dsn : e.VITE_SENTRY_DSN),
    environment: opts.environment ?? e.VITE_SENTRY_ENVIRONMENT ?? 'production',
    release: opts.release ?? e.VITE_SENTRY_RELEASE,
    sent: 0,
    seen: new Set(),
    fetch: opts.fetch ?? ((input, init) => fetch(input, init)),
  };
  return !!state.dsn;
}

/** The current page as origin + path: never its query string or fragment. */
export function pageUrl(): string | undefined {
  if (typeof location === 'undefined') return undefined;
  return scrub(stripQuery(`${location.origin}${location.pathname}`));
}

/**
 * Report one error. Always logs (scrubbed) to the console; POSTs to Sentry
 * only when a DSN is configured. Never throws.
 */
export function reportError(err: unknown, context: { source: string; extra?: Record<string, string> } = { source: 'manual' }): void {
  try {
    if (!state) configureErrorReporting();
    const s = state!;
    const message = scrubError(err, [], 1000);
    console.error(`[${context.source}]`, message);
    if (!s.dsn || s.sent >= MAX_PER_PAGE || s.seen.has(message)) return;
    s.seen.add(message);
    s.sent++;
    const tags: Record<string, string> = { source: context.source };
    for (const [k, v] of Object.entries(context.extra ?? {})) tags[k] = scrub(String(v)).slice(0, 200);
    const body = sentryEvent({
      message,
      exceptionType: err instanceof Error ? err.name : undefined,
      stack: scrubStack(err),
      platform: 'javascript',
      logger: 'exos-web',
      environment: s.environment,
      release: s.release,
      url: pageUrl(),
      tags,
    });
    void s.fetch(sentryStoreUrl(s.dsn), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Sentry-Auth': sentryAuthHeader(s.dsn, 'exos-web/1.0') },
      body: JSON.stringify(body),
      keepalive: true,
    }).catch(() => {
      // Best-effort: a blocked or failed report is dropped.
    });
  } catch {
    // Reporting must never break the page.
  }
}

/** window 'error' + 'unhandledrejection' -> reportError. Idempotent. */
export function installGlobalErrorHandlers(target: Pick<Window, 'addEventListener'> | undefined = typeof window === 'undefined' ? undefined : window): void {
  if (installed || !target) return;
  installed = true;
  target.addEventListener('error', (ev: Event) => {
    const e = ev as ErrorEvent;
    // Resource load errors (img/script) carry no error object: skip them.
    if (!e.error && !e.message) return;
    reportError(e.error ?? e.message, { source: 'window.onerror' });
  });
  target.addEventListener('unhandledrejection', (ev: Event) => {
    reportError((ev as PromiseRejectionEvent).reason, { source: 'unhandledrejection' });
  });
}

/** Tests only: forget handlers and state. */
export function _resetErrorReportingForTests(): void {
  state = null;
  installed = false;
}
