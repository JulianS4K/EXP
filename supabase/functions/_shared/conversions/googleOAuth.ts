// Google OAuth for the Google Ads (Data Manager API) conversions sender: the
// pure half of exos-oauth-google (consent URL, state, code exchange) and of
// exos-conversions-drain (refresh token -> short-lived access token, cached
// per org for one run). No Deno or Node APIs beyond WebCrypto and fetch
// (injected), so vitest imports it too (src/lib/googleOAuth.test.ts).
//
// Scope: the Data Manager API's own scope, https://www.googleapis.com/auth/datamanager
// (not the Google Ads API's .../auth/adwords): googleAds.ts builds a Data
// Manager events:ingest request. The Data Manager API takes no Google Ads
// developer token and no login-customer-id header (the destination carries
// the accounts), so none is sent. docs/marketing-conversions.md → Google Ads
// has the setup and the references.
//
// Tokens: the refresh token only ever goes to oauth2.googleapis.com, in a
// form body; the access token only to datamanager.googleapis.com, in the
// Authorization header. Neither is logged; error text is Google's error code
// and description with both scrubbed.

import { ALLOWED_HOSTS, type PlannedRequest, sha256Hex } from "./common.ts";
import { normalizeAppUrl } from "../mail-render.ts";
import { isAllowedRedirect, parseRedirectOrigins } from "../redirects.ts";

export const GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
export const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
export const DATA_MANAGER_SCOPE = "https://www.googleapis.com/auth/datamanager";
/** How long a started sign-in may take (the SQL caps it at 10 too). */
export const STATE_TTL_MINUTES = 10;
/** Refresh an access token this long before Google says it expires. */
const EXPIRY_SLACK_MS = 60_000;

export interface GoogleOAuthConfig {
  clientId: string;
  clientSecret: string;
  /** https://<project>.supabase.co/functions/v1/exos-oauth-google/callback */
  redirectUri: string;
}

type EnvGet = (name: string) => string | undefined;

/**
 * The OAuth client from env, or null when any part is missing or the
 * redirect URI isn't an https …/exos-oauth-google/callback URL.
 * GOOGLE_OAUTH_REDIRECT_URI is optional for the drain (refreshing needs no
 * redirect URI), so `needRedirect` is false there.
 */
export function googleOAuthConfig(env: EnvGet, needRedirect = true): GoogleOAuthConfig | null {
  const clientId = (env("GOOGLE_OAUTH_CLIENT_ID") ?? "").trim();
  const clientSecret = (env("GOOGLE_OAUTH_CLIENT_SECRET") ?? "").trim();
  const redirectUri = (env("GOOGLE_OAUTH_REDIRECT_URI") ?? "").trim();
  if (!clientId || !clientSecret) return null;
  if (needRedirect && !isCallbackUrl(redirectUri)) return null;
  return { clientId, clientSecret, redirectUri };
}

export function isCallbackUrl(u: string): boolean {
  let url: URL;
  try { url = new URL(u); } catch { return false; }
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
  if (url.protocol !== "https:" && !(url.protocol === "http:" && local)) return false;
  if (url.username || url.password || url.search || url.hash) return false;
  return /\/exos-oauth-google\/callback$/.test(url.pathname);
}

// ---- state ----------------------------------------------------------------

/** A new state: 32 random bytes, base64url (43 chars, 256 bits). */
export function newState(): string {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Shape check before any lookup (the SQL stores only the hash). */
export const isStateShaped = (s: unknown): s is string =>
  typeof s === "string" && /^[A-Za-z0-9_-]{43}$/.test(s);

/** What exos_oauth_states stores: SHA-256 hex of the state. */
export const stateHash = (state: string): Promise<string> => sha256Hex(state);

// ---- URLs -----------------------------------------------------------------

/** Google's consent page: offline access (a refresh token), consent every time. */
export function buildConsentUrl(cfg: GoogleOAuthConfig, state: string): string {
  const q = new URLSearchParams({
    client_id: cfg.clientId,
    redirect_uri: cfg.redirectUri,
    response_type: "code",
    scope: DATA_MANAGER_SCOPE,
    access_type: "offline",
    prompt: "consent",
    state,
  });
  return `${GOOGLE_AUTH_URL}?${q.toString()}`;
}

/**
 * The app base the browser is sent back to: EXOS_APP_URL (https, no query),
 * and its origin must be in EXOS_REDIRECT_ORIGINS, the same allow-list
 * exos-checkout and exos-connect-onboard use. Null when either fails.
 */
export function returnAppUrl(appUrlRaw: string | undefined, originsRaw: string | undefined): string | null {
  const app = normalizeAppUrl(appUrlRaw);
  if (!app) return null;
  return isAllowedRedirect(`${app}/`, parseRedirectOrigins(originsRaw)) ? app : null;
}

/**
 * Where the browser goes back to: <app>/orgs/<org>/settings with the given
 * query. appUrl is EXOS_APP_URL (already checked); an org id that isn't a
 * uuid goes to /orgs.
 */
export function settingsReturnUrl(appUrl: string, orgId: string | null, params: Record<string, string>): string {
  const base = appUrl.replace(/\/+$/, "");
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const path = orgId && uuid.test(orgId) ? `/orgs/${orgId}/settings` : "/orgs";
  const q = new URLSearchParams(params).toString();
  return `${base}${path}${q ? `?${q}` : ""}`;
}

// ---- token endpoint ---------------------------------------------------------

export interface TokenRequest {
  url: string;
  method: "POST";
  headers: Record<string, string>;
  /** application/x-www-form-urlencoded */
  body: string;
}

export function buildCodeExchangeRequest(cfg: GoogleOAuthConfig, code: string): TokenRequest {
  return {
    url: GOOGLE_TOKEN_URL,
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code,
      client_id: cfg.clientId,
      client_secret: cfg.clientSecret,
      redirect_uri: cfg.redirectUri,
    }).toString(),
  };
}

export function buildRefreshRequest(cfg: GoogleOAuthConfig, refreshToken: string): TokenRequest {
  return {
    url: GOOGLE_TOKEN_URL,
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: cfg.clientId,
      client_secret: cfg.clientSecret,
    }).toString(),
  };
}

export type TokenResult =
  | { ok: true; accessToken: string; expiresInSec: number; refreshToken: string | null; scope: string }
  /**
   * revoked: invalid_grant (the refresh token or code is dead: reconnect);
   * config: invalid_client / unauthorized_client (fix the OAuth client);
   * retry: 429 / 5xx / network; bad: anything else.
   */
  | { ok: false; kind: "revoked" | "config" | "retry" | "bad"; error: string };

/** Sort the token endpoint's answer. Never puts a token in `error`. */
export function parseTokenResponse(status: number, body: unknown): TokenResult {
  const b = (body && typeof body === "object" ? body : {}) as Record<string, unknown>;
  if (status >= 200 && status < 300) {
    const at = typeof b.access_token === "string" ? b.access_token : "";
    if (!at) return { ok: false, kind: "bad", error: "token response without access_token" };
    const exp = Number(b.expires_in);
    return {
      ok: true,
      accessToken: at,
      expiresInSec: Number.isFinite(exp) && exp > 0 ? exp : 3600,
      refreshToken: typeof b.refresh_token === "string" && b.refresh_token ? b.refresh_token : null,
      scope: typeof b.scope === "string" ? b.scope : "",
    };
  }
  const code = typeof b.error === "string" ? b.error.replace(/[^a-z_]/g, "").slice(0, 40) : "";
  const desc = typeof b.error_description === "string" ? b.error_description.slice(0, 200) : "";
  const error = `token http ${status}${code ? ` ${code}` : ""}${desc ? `: ${desc}` : ""}`;
  if (status === 429 || status >= 500) return { ok: false, kind: "retry", error };
  if (code === "invalid_grant") return { ok: false, kind: "revoked", error };
  if (code === "invalid_client" || code === "unauthorized_client") return { ok: false, kind: "config", error };
  return { ok: false, kind: "bad", error };
}

/** Whether a space-separated scope list includes the Data Manager scope. */
export const hasDataManagerScope = (scope: string): boolean =>
  scope.split(/\s+/).includes(DATA_MANAGER_SCOPE);

type FetchFn = (url: string, init: RequestInit) => Promise<Response>;

/** POST a token request with a timeout; network trouble is a retry. */
export async function postTokenRequest(req: TokenRequest, fetchFn: FetchFn, timeoutMs = 8000): Promise<TokenResult> {
  let host = "";
  try { host = new URL(req.url).hostname; } catch { /* invalid */ }
  if (!ALLOWED_HOSTS.has(host) || !req.url.startsWith("https://")) {
    return { ok: false, kind: "config", error: `refused host ${host || "(invalid url)"}` };
  }
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetchFn(req.url, {
      method: req.method, headers: req.headers, body: req.body, redirect: "manual", signal: ctrl.signal,
    });
    let body: unknown = null;
    try { body = await res.json(); } catch { /* not json */ }
    return parseTokenResponse(res.status, body);
  } catch (e) {
    const msg = e instanceof Error && e.name === "AbortError" ? "token request timeout" : "token request failed";
    return { ok: false, kind: "retry", error: msg };
  } finally {
    clearTimeout(timer);
  }
}

// ---- the drain's per-run access token cache -------------------------------

export type AccessToken =
  | { ok: true; accessToken: string }
  | { ok: false; kind: "revoked" | "config" | "retry" | "bad"; error: string };

/**
 * One access token per org per drain run: the first Google Ads row of an org
 * refreshes, the rest reuse the answer (a failure too, so a revoked token
 * costs one request per run, not one per row). Keyed by org and the refresh
 * token, so a token replaced mid-run isn't mixed up.
 */
export function createAccessTokenCache(cfg: GoogleOAuthConfig, fetchFn: FetchFn, now: () => number = Date.now) {
  const cache = new Map<string, Promise<{ tok: AccessToken; until: number }>>();
  return async (orgId: string, refreshToken: string): Promise<AccessToken> => {
    const key = `${orgId}\u0000${refreshToken}`;
    const hit = cache.get(key);
    if (hit) {
      const v = await hit;
      if (!v.tok.ok || now() < v.until) return v.tok;
    }
    const p = (async () => {
      const r = await postTokenRequest(buildRefreshRequest(cfg, refreshToken), fetchFn);
      if ("error" in r) return { tok: { ok: false, kind: r.kind, error: scrub(r.error, [refreshToken, cfg.clientSecret]) } as AccessToken, until: 0 };
      return {
        tok: { ok: true, accessToken: r.accessToken } as AccessToken,
        until: now() + r.expiresInSec * 1000 - EXPIRY_SLACK_MS,
      };
    })();
    cache.set(key, p);
    return (await p).tok;
  };
}

/** The built request with the real access token in place of the placeholder. */
export function withBearer(req: PlannedRequest, accessToken: string): PlannedRequest {
  return { ...req, headers: { ...req.headers, Authorization: `Bearer ${accessToken}` } };
}

export function scrub(s: string, secrets: (string | null | undefined)[]): string {
  let out = s;
  for (const x of secrets) {
    if (x && x.length >= 4) out = out.split(x).join("[redacted]").split(encodeURIComponent(x)).join("[redacted]");
  }
  return out;
}
