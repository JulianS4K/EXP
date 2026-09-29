// Every URL Supabase Auth mails out or redirects to (confirm signup, magic
// link / code, reset password, change email, OAuth) is built here, so they all
// land on the host the person is using: exos-web.onrender.com, the
// vibepass-storefront-test /bridge proxy, or localhost. Each of those needs a
// matching entry in the Supabase redirect allow-list (docs/auth.md), or
// Supabase silently falls back to the Site URL.
//
// Also: the return-path sanitizer used by /auth/callback and /reset-password.
// Only same-origin, app-relative paths are ever followed (no open redirect).

type Env = { VITE_APP_URL?: string; BASE_URL?: string };

function viteEnv(): Env {
  return ((import.meta as { env?: Env }).env ?? {}) as Env;
}

/** '/bridge/' → '/bridge', '/' → ''. */
export function normalizeBase(base: string | undefined): string {
  const b = (base ?? '/').trim() || '/';
  const withLead = b.startsWith('/') ? b : `/${b}`;
  return withLead.replace(/\/+$/, '');
}

/**
 * The app's public base URL, no trailing slash (e.g. https://host/bridge).
 * The current origin wins in a browser so a link comes back to the same host
 * (and the same localStorage session); VITE_APP_URL is the fallback when there
 * is no usable origin. VITE_APP_URL may be given with or without the base.
 */
export function appBaseUrl(
  opts: { origin?: string | null; env?: Env } = {},
): string {
  const env = opts.env ?? viteEnv();
  const base = normalizeBase(env.BASE_URL);
  const origin =
    opts.origin !== undefined ? opts.origin : typeof window !== 'undefined' ? window.location.origin : null;
  if (origin && /^https?:\/\//i.test(origin)) return `${origin.replace(/\/+$/, '')}${base}`;
  const configured = (env.VITE_APP_URL ?? '').trim().replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(configured)) return base;
  return base && configured.endsWith(base) ? configured : `${configured}${base}`;
}

/** Absolute URL of an app route: authUrl('/reset-password') → https://host/bridge/reset-password. */
export function authUrl(route: string, opts?: { origin?: string | null; env?: Env }): string {
  const path = route.startsWith('/') ? route : `/${route}`;
  return `${appBaseUrl(opts)}${path}`;
}

// Routes a return path must never point at: following them after sign-in
// would loop or re-run a one-shot token exchange.
const AUTH_ROUTES = ['/auth/callback', '/reset-password'];

/**
 * Accepts a candidate return path (from ?next= or storage) and returns a
 * router path (without the /bridge base) or null. Only same-origin relative
 * paths pass: no scheme, no protocol-relative //host, no backslashes or
 * control characters, nothing that resolves to another origin.
 */
export function sanitizeReturnPath(raw: unknown, base: string = viteEnv().BASE_URL ?? '/'): string | null {
  if (typeof raw !== 'string') return null;
  const s = raw.trim();
  if (!s || s.length > 512) return null;
  if (!s.startsWith('/') || s.startsWith('//')) return null;
  // Browsers treat "\" as "/" in URLs ("/\evil.com" → //evil.com).
  if (/[\\\u0000-\u001f\u007f]/.test(s)) return null;
  let url: URL;
  try {
    url = new URL(s, 'https://exos.invalid');
  } catch {
    return null;
  }
  if (url.origin !== 'https://exos.invalid') return null;
  let path = url.pathname;
  const b = normalizeBase(base);
  if (b && (path === b || path.startsWith(`${b}/`))) path = path.slice(b.length) || '/';
  if (AUTH_ROUTES.some((r) => path === r || path.startsWith(`${r}/`))) return null;
  return `${path}${url.search}`;
}

/** Where the person is now, as a router path (base stripped, hash dropped). */
export function currentReturnPath(): string {
  if (typeof window === 'undefined') return '/';
  const { pathname, search } = window.location;
  return sanitizeReturnPath(`${pathname}${search}`) ?? '/';
}

/** /auth/callback URL that sends the person back to `next` once the session is set. */
export function callbackUrl(next: string | null = currentReturnPath(), opts?: { origin?: string | null; env?: Env }): string {
  const clean = sanitizeReturnPath(next ?? '');
  const q = clean && clean !== '/' ? `?next=${encodeURIComponent(clean)}` : '';
  return authUrl(`/auth/callback${q}`, opts);
}

// Return path kept across the email round trip. localStorage (not session
// storage): the confirmation link usually opens in a new tab. Expires so a
// stale path from last week doesn't hijack today's sign-in.
const RETURN_KEY = 'exos.authReturn';
const RETURN_TTL_MS = 24 * 60 * 60 * 1000;

export function rememberReturnPath(path: string = currentReturnPath()): void {
  const clean = sanitizeReturnPath(path);
  if (!clean) return;
  try {
    localStorage.setItem(RETURN_KEY, JSON.stringify({ path: clean, at: Date.now() }));
  } catch {
    /* storage unavailable */
  }
}

/** Reads and clears the remembered path. `next` (from the URL) wins when valid. */
export function takeReturnPath(next?: string | null, now: number = Date.now()): string {
  let stored: string | null = null;
  try {
    const raw = localStorage.getItem(RETURN_KEY);
    localStorage.removeItem(RETURN_KEY);
    if (raw) {
      const v = JSON.parse(raw) as { path?: unknown; at?: unknown };
      if (typeof v.at === 'number' && now - v.at < RETURN_TTL_MS) stored = sanitizeReturnPath(v.path);
    }
  } catch {
    /* storage unavailable or junk */
  }
  return sanitizeReturnPath(next ?? '') ?? stored ?? '/';
}

/**
 * Supabase reports link problems in the URL, in the hash (implicit flow) or
 * the query (PKCE): #error=access_denied&error_code=otp_expired&error_description=…
 * Returns the parsed params from both, hash winning.
 */
export function authUrlParams(href: string): Record<string, string> {
  const out: Record<string, string> = {};
  try {
    const url = new URL(href);
    url.searchParams.forEach((v, k) => (out[k] = v));
    const hash = url.hash.startsWith('#') ? url.hash.slice(1) : url.hash;
    // Only a query-string-shaped hash; a router hash like #account isn't ours.
    if (hash.includes('=')) new URLSearchParams(hash).forEach((v, k) => (out[k] = v));
  } catch {
    /* not a URL */
  }
  return out;
}
