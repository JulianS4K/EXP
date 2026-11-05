// "Connect Eventbrite" (OAuth 2.0 authorization code): the pure half of
// exos-eventbrite-oauth (mig 20261029140000; docs/eventbrite-app.md). No Deno
// or Node APIs beyond WebCrypto and fetch (injected), so vitest imports it
// too (src/lib/eventbriteOAuth.test.ts).
//
// Eventbrite's OAuth (docs/eventbrite-app.md has the sources):
//   authorize  https://www.eventbrite.com/oauth/authorize
//              ?response_type=code&client_id=<API key>&redirect_uri=…&state=…
//   token      POST https://www.eventbrite.com/oauth/token (form body)
//              grant_type=authorization_code, client_id, client_secret, code,
//              redirect_uri  ->  { access_token, token_type: "bearer" }
// No scopes are requested (Eventbrite's v3 API has none to ask for); the
// token acts as the organizer's account, like a private token, and Exos uses
// it only through the GET-only client (client.ts) and the capacity-only
// writer (writer.ts), which are unchanged.
//
// The token exchange is the ONE request this module sends, to exactly
// EB_TOKEN_URL. It is an OAuth grant, not a write to the organizer's
// Eventbrite data. The code, the client secret and the token are never
// logged, never put in a URL, and never returned to the browser.

import { isAllowedRedirect, parseRedirectOrigins } from "../redirects.ts";
import { normalizeAppUrl } from "../mail-render.ts";

export const EB_AUTHORIZE_URL = "https://www.eventbrite.com/oauth/authorize";
export const EB_TOKEN_URL = "https://www.eventbrite.com/oauth/token";
/** How long a started sign-in may take (the SQL caps it at 10 too). */
export const STATE_TTL_MINUTES = 10;
const CALLBACK_PATH = /\/exos-eventbrite-oauth\/callback$/;

export interface EventbriteOAuthConfig {
  /** Eventbrite calls it the API key. */
  clientId: string;
  clientSecret: string;
  /** https://<project>.supabase.co/functions/v1/exos-eventbrite-oauth/callback */
  redirectUri: string;
}

type EnvGet = (name: string) => string | undefined;

/**
 * The OAuth client from env, or null when it isn't configured (the SPA then
 * hides "Connect Eventbrite" and shows the private-token form).
 * EXOS_EVENTBRITE_REDIRECT_URI is optional: by default it is this function's
 * callback under SUPABASE_URL. Either way it must be an https (http only for
 * localhost) …/exos-eventbrite-oauth/callback URL with no query or fragment,
 * and it must match what is registered on the Eventbrite app exactly.
 */
export function eventbriteOAuthConfig(env: EnvGet): EventbriteOAuthConfig | null {
  const clientId = (env("EXOS_EVENTBRITE_CLIENT_ID") ?? "").trim();
  const clientSecret = (env("EXOS_EVENTBRITE_CLIENT_SECRET") ?? "").trim();
  if (!clientId || !clientSecret) return null;
  if (!/^[A-Za-z0-9_-]{4,128}$/.test(clientId)) return null;
  const explicit = (env("EXOS_EVENTBRITE_REDIRECT_URI") ?? "").trim();
  const base = (env("SUPABASE_URL") ?? "").trim().replace(/\/+$/, "");
  const redirectUri = explicit || (base ? `${base}/functions/v1/exos-eventbrite-oauth/callback` : "");
  if (!isCallbackUrl(redirectUri)) return null;
  return { clientId, clientSecret, redirectUri };
}

export function isCallbackUrl(u: string): boolean {
  let url: URL;
  try { url = new URL(u); } catch { return false; }
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
  if (url.protocol !== "https:" && !(url.protocol === "http:" && local)) return false;
  if (url.username || url.password || url.search || url.hash) return false;
  return CALLBACK_PATH.test(url.pathname);
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
export async function stateHash(state: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(state));
  return Array.from(new Uint8Array(d), (x) => x.toString(16).padStart(2, "0")).join("");
}

// ---- URLs -----------------------------------------------------------------

/** Eventbrite's authorize page for this state. */
export function buildAuthorizeUrl(cfg: EventbriteOAuthConfig, state: string): string {
  const q = new URLSearchParams({
    response_type: "code",
    client_id: cfg.clientId,
    redirect_uri: cfg.redirectUri,
    state,
  });
  return `${EB_AUTHORIZE_URL}?${q.toString()}`;
}

/**
 * The app base the browser is sent back to: EXOS_APP_URL (https, no query),
 * and its origin must be in EXOS_REDIRECT_ORIGINS (_shared/redirects.ts, the
 * allow-list exos-checkout and exos-oauth-google use). Null when either fails.
 */
export function returnAppUrl(appUrlRaw: string | undefined, originsRaw: string | undefined): string | null {
  const app = normalizeAppUrl(appUrlRaw);
  if (!app) return null;
  return isAllowedRedirect(`${app}/`, parseRedirectOrigins(originsRaw)) ? app : null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Where the browser goes back to: the org's settings page (Integrations),
 * <app>/orgs/<org>/settings?<params>. Only the checked app base and a uuid
 * org id go into it, so it can't point anywhere else; a bad org id goes to
 * /orgs.
 */
export function integrationsReturnUrl(appUrl: string, orgId: string | null, params: Record<string, string>): string {
  const base = appUrl.replace(/\/+$/, "");
  const path = orgId && UUID.test(orgId) ? `/orgs/${orgId}/settings` : "/orgs";
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

export function buildCodeExchangeRequest(cfg: EventbriteOAuthConfig, code: string): TokenRequest {
  return {
    url: EB_TOKEN_URL,
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: cfg.clientId,
      client_secret: cfg.clientSecret,
      code,
      redirect_uri: cfg.redirectUri,
    }).toString(),
  };
}

export type TokenResult =
  | { ok: true; accessToken: string }
  /**
   * denied: invalid_grant / access_denied (the code is dead or was refused:
   * connect again); config: invalid_client / unauthorized_client /
   * redirect mismatch (fix the app registration); retry: 429 / 5xx /
   * network; bad: anything else.
   */
  | { ok: false; kind: "denied" | "config" | "retry" | "bad"; error: string };

/** A token Exos can store (the SQL checks the same shape). */
export const isTokenShaped = (t: unknown): t is string =>
  typeof t === "string" && /^[A-Za-z0-9_-]{8,255}$/.test(t);

/** Sort the token endpoint's answer. Never puts a token or the body in `error`. */
export function parseTokenResponse(status: number, body: unknown): TokenResult {
  const b = (body && typeof body === "object" ? body : {}) as Record<string, unknown>;
  if (status >= 200 && status < 300 && typeof b.error !== "string") {
    const at = typeof b.access_token === "string" ? b.access_token : "";
    if (!isTokenShaped(at)) return { ok: false, kind: "bad", error: "token response without a usable access_token" };
    return { ok: true, accessToken: at };
  }
  const code = typeof b.error === "string" ? b.error.toLowerCase().replace(/[^a-z_]/g, "").slice(0, 40) : "";
  const error = `token http ${status}${code ? ` ${code}` : ""}`;
  if (status === 429 || status >= 500) return { ok: false, kind: "retry", error };
  if (code === "invalid_grant" || code === "access_denied") return { ok: false, kind: "denied", error };
  if (code === "invalid_client" || code === "unauthorized_client" || code === "redirect_uri_mismatch" ||
      code === "invalid_redirect_uri") {
    return { ok: false, kind: "config", error };
  }
  return { ok: false, kind: "bad", error };
}

type FetchFn = (url: string, init: RequestInit) => Promise<Response>;

/** POST the code exchange with a timeout. Refuses any URL but EB_TOKEN_URL. */
export async function postTokenRequest(req: TokenRequest, fetchFn: FetchFn, timeoutMs = 8000): Promise<TokenResult> {
  if (req.url !== EB_TOKEN_URL || req.method !== "POST") {
    return { ok: false, kind: "config", error: "refused token url" };
  }
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetchFn(req.url, {
      method: "POST", headers: req.headers, body: req.body, redirect: "manual", signal: ctrl.signal,
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

// ---- callback ---------------------------------------------------------------

/** Why a callback came back without a usable code (?error=… from Eventbrite). */
export function callbackErrorReason(err: string | null): "denied" | "eventbrite" {
  return err === "access_denied" ? "denied" : "eventbrite";
}
