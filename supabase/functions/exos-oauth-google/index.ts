// exos-oauth-google — "Connect Google Ads": the Google sign-in that gives an
// org's Google Ads conversions row its refresh token (Data Manager API scope),
// so exos-conversions-drain can send Google Ads conversions.
// docs/marketing-conversions.md → Google Ads; mig 20260930102000.
//
// Routes (under /functions/v1/exos-oauth-google):
//   GET  /start?org=<org id>   Authorization: Bearer <user JWT>. Owner /
//        manager of the org. Makes a single-use state (256 bits; only its
//        SHA-256 is stored, 10-minute expiry) and answers
//        { url: <Google consent URL> } (access_type=offline, prompt=consent,
//        scope https://www.googleapis.com/auth/datamanager). JSON rather than
//        a 302 because the SPA calls it with fetch (the JWT is a header, not
//        a cookie) and then navigates.
//   GET  /callback?code&state  Google sends the browser here (no JWT). The
//        code is parked on the state row with the SHA-256 of a fresh 256-bit
//        finish token (mig 20261029140000), and the browser goes back to
//        <EXOS_APP_URL>/orgs/<org>/settings?google_ads=finish&google_ads_state=<state>#google_ads_finish=<token>
//        (the token in the fragment: _shared/oauthFinish.ts says why).
//        A refusal (?error=access_denied) or an unknown / used / expired
//        state goes back with ?google_ads=error&reason=….
//   POST /finish {state, finish} Authorization: Bearer <user JWT>. The
//        settings page calls this when the user clicks Confirm. It needs the
//        state, the finish token AND the JWT of the user who started it
//        (exos_oauth_state_consume): the starter never sees the token and the
//        browser that has it doesn't have the starter's JWT, so a consent
//        link completed in someone else's browser can't attach their Google
//        account to this org (refused: other_user / token). The code is
//        exchanged at oauth2.googleapis.com/token, and the refresh token is
//        stored in Vault as the org's google_ads secret
//        (exos_set_google_ads_token). Answers { connected: true } or
//        { error, reason }.
//
// Tokens and codes are never logged or returned. Deploy with
// --no-verify-jwt: Google's redirect carries no Supabase JWT; /start and
// /finish verify the JWT themselves.
//
// Env: GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET,
//      GOOGLE_OAUTH_REDIRECT_URI (this function's /callback URL, exactly as
//      registered on the OAuth client), EXOS_APP_URL (the SPA base, e.g.
//      https://host/bridge; its origin must be in EXOS_REDIRECT_ORIGINS),
//      EXOS_REDIRECT_ORIGINS, SUPABASE_URL, SUPABASE_ANON_KEY,
//      SUPABASE_SERVICE_ROLE_KEY. Any Google / app variable missing → 503
//      "Google Ads connection not configured".

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { redactError } from "../_shared/log.ts";
import { parseRedirectOrigins } from "../_shared/redirects.ts";
import { finishRefusal, withFinishFragment } from "../_shared/oauthFinish.ts";
import {
  buildCodeExchangeRequest, buildConsentUrl, googleOAuthConfig, hasDataManagerScope, isStateShaped,
  newState, postTokenRequest, returnAppUrl, settingsReturnUrl, stateHash, STATE_TTL_MINUTES,
} from "../_shared/conversions/googleOAuth.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const route = url.pathname.replace(/\/+$/, "").split("/").pop() ?? "";
  const cors = corsHeaders(req.headers.get("origin"));

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });

  const cfg = googleOAuthConfig((k) => Deno.env.get(k));
  const app = returnAppUrl(Deno.env.get("EXOS_APP_URL"), Deno.env.get("EXOS_REDIRECT_ORIGINS"));
  if (!cfg || !app) return json({ error: "Google Ads connection not configured" }, 503, cors);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  if (route === "start" && req.method === "GET") {
    const user = await signedInUser(req);
    if (!user) return json({ error: "sign in first" }, 401, cors);
    const org = url.searchParams.get("org") ?? "";
    if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);

    const state = newState();
    const { error } = await sb.rpc("exos_oauth_state_begin", {
      p_provider: "google_ads", p_org_id: org, p_user_id: user,
      p_state_hash: await stateHash(state), p_ttl_minutes: STATE_TTL_MINUTES,
    });
    if (error) {
      if (error.code === "42501") return json({ error: "owner or manager only" }, 403, cors);
      if (error.code === "54000") return json({ error: "too many attempts, try again in a few minutes" }, 429, cors);
      console.error("exos-oauth-google: begin failed", redactError(error));
      return json({ error: "could not start the Google sign-in" }, 500, cors);
    }
    return json({ url: buildConsentUrl(cfg, state) }, 200, cors);
  }

  if (route === "callback" && req.method === "GET") {
    const state = url.searchParams.get("state");
    const code = url.searchParams.get("code");
    const gErr = url.searchParams.get("error");
    if (!isStateShaped(state)) return redirect(settingsReturnUrl(app, null, { google_ads: "error", reason: "state" }));
    // A fresh finish token for the browser that came back from Google: only
    // its hash is stored, next to the parked code (mig 20261029140000).
    const finish = newState();
    const { data: orgId, error } = await sb.rpc("exos_oauth_state_return", {
      p_state_hash: await stateHash(state), p_code: gErr ? null : code, p_finish_hash: await stateHash(finish),
    });
    if (error) {
      console.error("exos-oauth-google: callback failed", redactError(error));
      return redirect(settingsReturnUrl(app, null, { google_ads: "error", reason: "server" }));
    }
    const org = typeof orgId === "string" ? orgId : null;
    if (!org) return redirect(settingsReturnUrl(app, null, { google_ads: "error", reason: "expired" }));
    if (gErr || !code) {
      return redirect(settingsReturnUrl(app, org, {
        google_ads: "error", reason: gErr === "access_denied" ? "denied" : "google",
      }));
    }
    // The state in the query, the finish token in the fragment.
    return redirect(withFinishFragment(
      settingsReturnUrl(app, org, { google_ads: "finish", google_ads_state: state }), "google_ads_finish", finish));
  }

  if (route === "finish" && req.method === "POST") {
    const user = await signedInUser(req);
    if (!user) return json({ error: "sign in first", reason: "auth" }, 401, cors);
    let body: { state?: unknown; finish?: unknown };
    try { body = await req.json(); } catch { return json({ error: "invalid JSON", reason: "state" }, 400, cors); }
    if (!isStateShaped(body.state)) return json({ error: "bad state", reason: "state" }, 400, cors);
    // A missing or malformed finish token goes to the SQL as no hash, which
    // burns the starting user's state.
    const finishHash = isStateShaped(body.finish) ? await stateHash(body.finish) : null;

    const { data, error } = await sb.rpc("exos_oauth_state_consume", {
      p_state_hash: await stateHash(body.state), p_user_id: user, p_finish_hash: finishHash,
    });
    if (error) {
      console.error("exos-oauth-google: consume failed", redactError(error));
      return json({ error: "could not finish the Google sign-in", reason: "server" }, 500, cors);
    }
    const row = (Array.isArray(data) ? data[0] : null) as
      { org_id: string | null; code: string | null; refused: string | null } | null;
    if (!row?.org_id || !row.code) {
      const refusal = finishRefusal(row?.refused);
      return json({ error: refusal.error, reason: refusal.reason }, refusal.status, cors);
    }

    const tok = await postTokenRequest(buildCodeExchangeRequest(cfg, row.code), (u, i) => fetch(u, i));
    if ("error" in tok) {
      // Google's error code only (no code or token in it); the client secret is scrubbed by parse.
      console.error("exos-oauth-google: code exchange failed", tok.kind);
      return json({ error: "Google refused the sign-in; try again", reason: "exchange" }, 502, cors);
    }
    if (!hasDataManagerScope(tok.scope)) {
      return json({ error: "Google didn't grant access to conversion uploads; tick the permission and try again", reason: "scope" }, 400, cors);
    }
    if (!tok.refreshToken) {
      return json({ error: "Google didn't return a long-lived token; remove Exos from your Google account's third-party access and connect again", reason: "no_refresh" }, 502, cors);
    }

    const { error: saveErr } = await sb.rpc("exos_set_google_ads_token", {
      p_org_id: row.org_id, p_user_id: user, p_refresh_token: tok.refreshToken,
    });
    if (saveErr) {
      if (saveErr.code === "42501") return json({ error: "owner or manager only", reason: "forbidden" }, 403, cors);
      console.error("exos-oauth-google: save failed", redactError(saveErr));
      return json({ error: "could not save the Google connection", reason: "server" }, 500, cors);
    }
    return json({ connected: true, org_id: row.org_id }, 200, cors);
  }

  return json({ error: "not found" }, 404, cors);
});

/** The verified user id from the request's Supabase JWT, or null. */
async function signedInUser(req: Request): Promise<string | null> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(auth)) return null;
  const sbUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data } = await sbUser.auth.getUser();
  return data.user?.id ?? null;
}

/** CORS for the SPA's fetch calls: only allow-listed origins are echoed. */
function corsHeaders(origin: string | null): Record<string, string> {
  const allowed = parseRedirectOrigins(Deno.env.get("EXOS_REDIRECT_ORIGINS"));
  if (!origin || !allowed.includes(origin)) return { vary: "Origin" };
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Max-Age": "600",
    vary: "Origin",
  };
}

function redirect(to: string): Response {
  return new Response(null, {
    status: 302,
    headers: { location: to, "cache-control": "no-store", "referrer-policy": "no-referrer" },
  });
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json", "cache-control": "no-store", ...extra },
  });
}
