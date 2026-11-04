// exos-oauth — Exos as an OAuth 2 authorization server for apps and AI agents
// (docs/developer-platform.md, mig 20261031130500).
//
//   GET  /authorize    sends the browser to the consent page in the app
//                      (<EXOS_APP_BASE_URL>/oauth/authorize?<same query>); the
//                      signed-in user approves there and the app's RPC mints
//                      the code (exos_oauth_authorize_approve).
//   POST /token        grant_type=authorization_code (PKCE S256) or refresh_token
//   POST /revoke       RFC 7009
//   POST /introspect   RFC 7662, the app's own tokens
//   POST /register     RFC 7591 dynamic registration, only with
//                      EXOS_OAUTH_DCR=on (off by default: 404)
//   GET  /.well-known/oauth-authorization-server   RFC 8414 metadata
//
// Client authentication: HTTP Basic or client_secret_post for confidential
// apps; public apps send client_id only and must use PKCE. Bodies are
// form-encoded or JSON, read with a byte cap. Errors are RFC 6749
// { error, error_description }, every answer is Cache-Control: no-store, and
// the endpoints share 30 requests a minute per network (exos_rate_hit).
// Everything that decides is SQL (service role): this function parses,
// hashes and maps answers.
//
// Deploy with --no-verify-jwt (apps don't send a Supabase JWT).
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, EXOS_APP_BASE_URL (the
// consent page). Optional: EXOS_OAUTH_ISSUER (default <SUPABASE_URL>/functions/v1/exos-oauth),
// EXOS_OAUTH_DCR=on, EXOS_GUEST_IP_SALT.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { MAX_BODY_BYTES, readCapped } from "../_shared/api/body.ts";
import {
  basicCredentials, CLIENT_ID_RE, redirectUriProblem, s256, scopeList, sha256Hex, TOKEN_RE, validVerifier,
} from "../_shared/api/credentials.ts";
import { SCOPES } from "../_shared/api/scopes.ts";
import { clientIp, hashIp } from "../_shared/guest.ts";

const PER_MINUTE = 30;
const NO_STORE = { "cache-control": "no-store", pragma: "no-cache" };
const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "authorization, content-type",
};

const env = (k: string) => Deno.env.get(k) ?? "";
const issuer = () => (env("EXOS_OAUTH_ISSUER") || `${env("SUPABASE_URL").replace(/\/+$/, "")}/functions/v1/exos-oauth`);

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*?\/exos-oauth(?=\/|$)/, "").replace(/\/+$/, "") || "/";

  if (req.method === "GET" && path === "/.well-known/oauth-authorization-server") return json(metadata(), 200);
  if (req.method === "GET" && path === "/authorize") return authorize(url);

  if (req.method !== "POST" || !["/token", "/revoke", "/introspect", "/register"].includes(path)) {
    return oauthError("invalid_request", "Unknown endpoint.", 404);
  }
  if (path === "/register" && env("EXOS_OAUTH_DCR") !== "on") {
    return oauthError("invalid_request", "Dynamic client registration is switched off.", 404);
  }

  const sb = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
  const salt = env("EXOS_GUEST_IP_SALT") || env("SUPABASE_SERVICE_ROLE_KEY");
  const net = (await hashIp(clientIp((h) => req.headers.get(h)), salt)) ?? "unknown";
  const { data: allowed, error: rlErr } = await sb.rpc("exos_rate_hit", { p_bucket: `oauth:${net}`, p_limit: PER_MINUTE });
  if (rlErr) return oauthError("temporarily_unavailable", "Try again shortly.", 503, { "retry-after": "30" });
  if (allowed === false) {
    return oauthError("slow_down", "Too many requests.", 429, { "retry-after": String(Math.max(1, 60 - new Date().getUTCSeconds())) });
  }

  let body: Record<string, string>;
  try {
    body = await readForm(req);
  } catch (e) {
    return oauthError("invalid_request", (e as Error).message, 400);
  }

  try {
    if (path === "/register") return await register(sb, body);
    // Client authentication: Basic, or client_secret_post / client_id only.
    const basic = basicCredentials(req.headers.get("authorization"));
    const clientId = basic?.id ?? body.client_id ?? "";
    const secret = basic?.secret ?? body.client_secret ?? null;
    if (!CLIENT_ID_RE.test(clientId)) return oauthError("invalid_client", "Unknown client.", 401);
    if (secret !== null && !TOKEN_RE.secret.test(secret)) return oauthError("invalid_client", "Client authentication failed.", 401);
    const secretHash = secret ? await sha256Hex(secret) : null;

    if (path === "/token") return await token(sb, body, clientId, secretHash);
    if (path === "/revoke" || path === "/introspect") {
      const t = body.token ?? "";
      const known = TOKEN_RE.access.test(t) || TOKEN_RE.refresh.test(t);
      const hash = known ? await sha256Hex(t) : "0".repeat(64);
      const fn = path === "/revoke" ? "exos_oauth_revoke_token" : "exos_oauth_introspect";
      const { data, error } = await sb.rpc(fn, { p_hash: hash, p_client_id: clientId, p_secret_hash: secretHash });
      if (error) throw error;
      return answer(data as Record<string, unknown>);
    }
  } catch (e) {
    console.error("exos-oauth error:", e);
    return oauthError("server_error", "Something went wrong.", 500);
  }
  return oauthError("invalid_request", "Unknown endpoint.", 404);
});

/** The consent page lives in the app; this hands the browser over, query and all. */
function authorize(url: URL): Response {
  const base = env("EXOS_APP_BASE_URL").replace(/\/+$/, "");
  if (!/^https:\/\//.test(base)) return oauthError("temporarily_unavailable", "The consent page is not configured.", 503);
  return new Response(null, { status: 302, headers: { location: `${base}/oauth/authorize${url.search}`, ...NO_STORE } });
}

async function token(
  sb: SupabaseClient, body: Record<string, string>, clientId: string, secretHash: string | null,
): Promise<Response> {
  const grant = body.grant_type;
  if (grant === "authorization_code") {
    const code = body.code ?? "";
    if (!TOKEN_RE.code.test(code)) return oauthError("invalid_grant", "Unknown authorization code.", 400);
    const verifier = body.code_verifier;
    if (verifier !== undefined && verifier !== "" && !validVerifier(verifier)) {
      return oauthError("invalid_request", "code_verifier must be 43-128 unreserved characters.", 400);
    }
    const { data, error } = await sb.rpc("exos_oauth_exchange_code", {
      p_code_hash: await sha256Hex(code), p_client_id: clientId, p_secret_hash: secretHash,
      p_redirect_uri: body.redirect_uri ?? null, p_verifier_s256: verifier ? await s256(verifier) : null,
    });
    if (error) throw error;
    return answer(data as Record<string, unknown>);
  }
  if (grant === "refresh_token") {
    const rt = body.refresh_token ?? "";
    if (!TOKEN_RE.refresh.test(rt)) return oauthError("invalid_grant", "Unknown refresh token.", 400);
    const scopes = scopeList(body.scope);
    const { data, error } = await sb.rpc("exos_oauth_refresh", {
      p_refresh_hash: await sha256Hex(rt), p_client_id: clientId, p_secret_hash: secretHash, p_scopes: scopes,
    });
    if (error) throw error;
    return answer(data as Record<string, unknown>);
  }
  return oauthError("unsupported_grant_type", "Use authorization_code or refresh_token.", 400);
}

async function register(sb: SupabaseClient, body: Record<string, unknown>): Promise<Response> {
  const uris = body.redirect_uris;
  if (!Array.isArray(uris) || uris.length === 0 || uris.length > 10 || uris.some((u) => redirectUriProblem(u))) {
    return oauthError("invalid_redirect_uri", "redirect_uris must be 1-10 https (or localhost http) URLs.", 400);
  }
  const auth = body.token_endpoint_auth_method ?? "none";
  if (!["none", "client_secret_basic", "client_secret_post"].includes(String(auth))) {
    return oauthError("invalid_client_metadata", "token_endpoint_auth_method must be none, client_secret_basic or client_secret_post.", 400);
  }
  const scopes = scopeList(body.scope);
  if (scopes && scopes.some((s) => !(SCOPES as readonly string[]).includes(s))) {
    return oauthError("invalid_client_metadata", "Unknown scope.", 400);
  }
  const name = typeof body.client_name === "string" && body.client_name.trim() ? body.client_name.trim().slice(0, 80) : "Unnamed app";
  const { data, error } = await sb.rpc("exos_oauth_register", {
    p_name: name, p_redirect_uris: uris, p_scopes: scopes, p_client_type: auth === "none" ? "public" : "confidential",
    p_logo_url: typeof body.logo_uri === "string" ? body.logo_uri : null,
    p_homepage_url: typeof body.client_uri === "string" ? body.client_uri : null,
  });
  if (error) {
    if (error.code === "22023") return oauthError("invalid_client_metadata", String(error.message).slice(0, 200), 400);
    throw error;
  }
  const a = data as Record<string, unknown>;
  return json({
    client_id: a.client_id, ...(a.client_secret ? { client_secret: a.client_secret, client_secret_expires_at: 0 } : {}),
    client_id_issued_at: Math.floor(Date.now() / 1000), client_name: a.name, redirect_uris: a.redirect_uris,
    grant_types: ["authorization_code", "refresh_token"], response_types: ["code"],
    token_endpoint_auth_method: auth, scope: (a.scopes as string[]).join(" "),
  }, 201);
}

function metadata() {
  const iss = issuer();
  return {
    issuer: iss,
    authorization_endpoint: `${iss}/authorize`,
    token_endpoint: `${iss}/token`,
    revocation_endpoint: `${iss}/revoke`,
    introspection_endpoint: `${iss}/introspect`,
    ...(env("EXOS_OAUTH_DCR") === "on" ? { registration_endpoint: `${iss}/register` } : {}),
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: ["client_secret_basic", "client_secret_post", "none"],
    scopes_supported: SCOPES,
  };
}

/** A SQL answer: tokens, or { error, error_description } (invalid_client is 401). */
function answer(d: Record<string, unknown>): Response {
  if (d && typeof d.error === "string") {
    return oauthError(d.error, String(d.error_description ?? ""), d.error === "invalid_client" ? 401 : 400);
  }
  return json(d ?? {}, 200);
}

/** Form-encoded or JSON, capped. Repeated keys: the first wins. */
async function readForm(req: Request): Promise<Record<string, string>> {
  const text = await readCapped(req, Math.min(MAX_BODY_BYTES, 16 * 1024));
  if (text === null) throw new Error("request body is too large");
  const type = (req.headers.get("content-type") ?? "").toLowerCase();
  if (type.includes("application/json")) {
    let v: unknown;
    try {
      v = JSON.parse(text || "{}");
    } catch {
      throw new Error("the body must be JSON or form-encoded");
    }
    if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error("the body must be an object");
    return v as Record<string, string>;
  }
  const out: Record<string, string> = {};
  for (const [k, val] of new URLSearchParams(text)) if (!(k in out) && k.length <= 64) out[k] = val;
  return out;
}

function oauthError(code: string, description: string, status: number, extra: Record<string, string> = {}): Response {
  const headers: Record<string, string> = { ...extra };
  if (status === 401) headers["www-authenticate"] = 'Basic realm="exos-oauth"';
  return json({ error: code, error_description: description }, status, headers);
}

function json(body: unknown, status: number, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json", ...NO_STORE, ...CORS, ...extra },
  });
}
