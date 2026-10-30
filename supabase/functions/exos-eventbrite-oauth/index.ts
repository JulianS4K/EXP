// exos-eventbrite-oauth — "Connect Eventbrite": the Eventbrite OAuth sign-in
// that gives an org the same Eventbrite token the pasted private token gives
// today (Vault exos_eventbrite:<org>), without the organizer handling a
// token. mig 20261029140000; docs/eventbrite-app.md; the read-only sync that
// uses the token is exos-eventbrite-sync.
//
// Routes (under /functions/v1/exos-eventbrite-oauth):
//   GET  /config               No auth. { oauth: boolean }: whether the OAuth
//        client is configured. The SPA shows "Connect Eventbrite" only when
//        it is; otherwise the private-token form (exos-eventbrite-sync
//        /connect) stays the way to connect.
//   GET  /start?org=<org id>[&event=<event id>]   Authorization: Bearer <user
//        JWT>. Owner / manager of the org. Makes a single-use state (256
//        bits; only its SHA-256 is stored, 10-minute expiry, at most 10 starts
//        a user in 10 minutes), optionally with the org's Exos event to go
//        back to, and answers { url: <Eventbrite authorize URL> }. JSON
//        rather than a 302 because the SPA calls it with fetch (the JWT is a
//        header) and then navigates.
//   GET  /callback?code&state  Eventbrite sends the browser here (no JWT). The
//        code is parked on the state row with the SHA-256 of a fresh 256-bit
//        finish token, and the browser goes back to
//        <EXOS_APP_URL>/orgs/<org>/settings?eventbrite=finish&eventbrite_state=<state>#eventbrite_finish=<token>
//        (the token in the fragment: _shared/oauthFinish.ts says why).
//        A refusal (?error=access_denied) or an unknown / used / expired
//        state goes back with ?eventbrite=error&reason=….
//   POST /finish {state, finish} Authorization: Bearer <user JWT>. The
//        settings page calls this when the user clicks Confirm. It needs the
//        state, the finish token AND the JWT of the user who started it
//        (exos_eventbrite_oauth_consume): the starter never sees the token,
//        and the browser that has it doesn't have the starter's JWT, so a
//        link finished in someone else's browser can't attach their
//        Eventbrite account to this org (refused: other_user / token). The
//        code is exchanged at https://www.eventbrite.com/oauth/token, the
//        token is checked with GET /users/me/ and stored in Vault
//        (exos_eventbrite_connect_oauth). Answers { connected: true,
//        account_name, event_id } (event_id: where to pick the Eventbrite
//        event, or null) or { error, reason }.
//
// Eventbrite stays read-only (CLAUDE.md): the only non-GET request here is
// the OAuth code exchange (_shared/eventbrite/oauth.ts, to exactly
// EB_TOKEN_URL), which writes nothing to the organizer's Eventbrite data.
// Writes stay off: a new account has writes_enabled false, and
// EXOS_EVENTBRITE_WRITES is unchanged.
//
// The code, the client secret and the token are never logged or returned,
// and the redirect back only ever goes to EXOS_APP_URL, whose origin must be
// in EXOS_REDIRECT_ORIGINS (_shared/redirects.ts): no open redirect. Deploy
// with --no-verify-jwt: Eventbrite's redirect carries no Supabase JWT;
// /start and /finish verify the JWT themselves.
//
// Env: EXOS_EVENTBRITE_CLIENT_ID (the Eventbrite app's API key),
//      EXOS_EVENTBRITE_CLIENT_SECRET, EXOS_EVENTBRITE_REDIRECT_URI (optional;
//      default <SUPABASE_URL>/functions/v1/exos-eventbrite-oauth/callback,
//      must match the app's registered redirect URI), EXOS_APP_URL (the SPA
//      base, e.g. https://host/bridge), EXOS_REDIRECT_ORIGINS, SUPABASE_URL,
//      SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY. Client id / secret / app
//      URL missing → /config says oauth: false and the rest answer 503.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { redactError } from "../_shared/log.ts";
import { parseRedirectOrigins } from "../_shared/redirects.ts";
import { finishRefusal, withFinishFragment } from "../_shared/oauthFinish.ts";
import { whoAmI } from "../_shared/eventbrite/client.ts";
import {
  buildAuthorizeUrl, buildCodeExchangeRequest, callbackErrorReason, eventbriteOAuthConfig, integrationsReturnUrl,
  isStateShaped, newState, postTokenRequest, returnAppUrl, stateHash,
} from "../_shared/eventbrite/oauth.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const route = url.pathname.replace(/\/+$/, "").split("/").pop() ?? "";
  const cors = corsHeaders(req.headers.get("origin"));

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });

  const cfg = eventbriteOAuthConfig((k) => Deno.env.get(k));
  const app = returnAppUrl(Deno.env.get("EXOS_APP_URL"), Deno.env.get("EXOS_REDIRECT_ORIGINS"));

  if (route === "config" && req.method === "GET") {
    return json({ oauth: cfg !== null && app !== null }, 200, cors);
  }
  if (!cfg || !app) return json({ error: "Eventbrite connection not configured", reason: "not_configured" }, 503, cors);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  if (route === "start" && req.method === "GET") {
    const user = await signedInUser(req);
    if (!user) return json({ error: "sign in first", reason: "auth" }, 401, cors);
    const org = url.searchParams.get("org") ?? "";
    const event = url.searchParams.get("event") || null;
    if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);
    if (event !== null && !UUID.test(event)) return json({ error: "bad event" }, 400, cors);

    const state = newState();
    const { error } = await sb.rpc("exos_eventbrite_oauth_begin", {
      p_org_id: org, p_user_id: user, p_state_hash: await stateHash(state), p_event_id: event,
    });
    if (error) {
      if (error.code === "42501") return json({ error: "owner or manager only", reason: "forbidden" }, 403, cors);
      if (error.code === "54000") return json({ error: "too many attempts, try again in a few minutes", reason: "rate" }, 429, cors);
      if (error.code === "22023") return json({ error: "that event isn't this organization's", reason: "invalid" }, 400, cors);
      console.error("exos-eventbrite-oauth: begin failed", redactError(error));
      return json({ error: "could not start the Eventbrite sign-in", reason: "server" }, 500, cors);
    }
    return json({ url: buildAuthorizeUrl(cfg, state) }, 200, cors);
  }

  if (route === "callback" && req.method === "GET") {
    const state = url.searchParams.get("state");
    const code = url.searchParams.get("code");
    const ebErr = url.searchParams.get("error");
    if (!isStateShaped(state)) return redirect(integrationsReturnUrl(app, null, { eventbrite: "error", reason: "state" }));
    // A fresh finish token for the browser that came back from Eventbrite:
    // only its hash is stored, next to the parked code.
    const finish = newState();
    const { data: orgId, error } = await sb.rpc("exos_oauth_state_return", {
      p_state_hash: await stateHash(state), p_code: ebErr ? null : code, p_finish_hash: await stateHash(finish),
    });
    if (error) {
      console.error("exos-eventbrite-oauth: callback failed", redactError(error));
      return redirect(integrationsReturnUrl(app, null, { eventbrite: "error", reason: "server" }));
    }
    const org = typeof orgId === "string" ? orgId : null;
    if (!org) return redirect(integrationsReturnUrl(app, null, { eventbrite: "error", reason: "expired" }));
    if (ebErr || !code) {
      return redirect(integrationsReturnUrl(app, org, { eventbrite: "error", reason: callbackErrorReason(ebErr) }));
    }
    // The state in the query, the finish token in the fragment (not sent to
    // any server, not logged, not in a Referer).
    return redirect(withFinishFragment(
      integrationsReturnUrl(app, org, { eventbrite: "finish", eventbrite_state: state }), "eventbrite_finish", finish));
  }

  if (route === "finish" && req.method === "POST") {
    const user = await signedInUser(req);
    if (!user) return json({ error: "sign in first", reason: "auth" }, 401, cors);
    let body: { state?: unknown; finish?: unknown };
    try { body = await req.json(); } catch { return json({ error: "invalid JSON", reason: "state" }, 400, cors); }
    if (!isStateShaped(body.state)) return json({ error: "bad state", reason: "state" }, 400, cors);
    // A missing or malformed finish token still goes to the SQL (as no hash),
    // so the starting user's state is burned rather than left to retry.
    const finishHash = isStateShaped(body.finish) ? await stateHash(body.finish) : null;

    const { data, error } = await sb.rpc("exos_eventbrite_oauth_consume", {
      p_state_hash: await stateHash(body.state), p_user_id: user, p_finish_hash: finishHash,
    });
    if (error) {
      console.error("exos-eventbrite-oauth: consume failed", redactError(error));
      return json({ error: "could not finish the Eventbrite sign-in", reason: "server" }, 500, cors);
    }
    const row = (Array.isArray(data) ? data[0] : null) as
      { org_id: string | null; code: string | null; return_event_id: string | null; refused: string | null } | null;
    if (!row?.org_id || !row.code) {
      const refusal = finishRefusal(row?.refused);
      return json({ error: refusal.error, reason: refusal.reason }, refusal.status, cors);
    }

    const tok = await postTokenRequest(buildCodeExchangeRequest(cfg, row.code), (u, i) => fetch(u, i));
    if ("error" in tok) {
      // The kind and Eventbrite's error code only: no code, secret or token.
      console.error("exos-eventbrite-oauth: code exchange failed", tok.kind, tok.error);
      return json({ error: "Eventbrite refused the sign-in; try again", reason: tok.kind === "config" ? "config" : "exchange" }, 502, cors);
    }
    const me = await whoAmI(fetch, tok.accessToken);
    if (!me.ok || !me.body) {
      console.error("exos-eventbrite-oauth: token check failed", me.status, me.error);
      return json({ error: "Eventbrite didn't accept the new connection; try again", reason: "eventbrite" }, 502, cors);
    }

    const { data: saved, error: saveErr } = await sb.rpc("exos_eventbrite_connect_oauth", {
      p_org_id: row.org_id, p_user_id: user, p_token: tok.accessToken, p_account_name: me.body.name,
    });
    if (saveErr) {
      if (saveErr.code === "42501") return json({ error: "owner or manager only", reason: "forbidden" }, 403, cors);
      console.error("exos-eventbrite-oauth: save failed", redactError(saveErr));
      return json({ error: "could not save the Eventbrite connection", reason: "server" }, 500, cors);
    }
    const acct = (saved as { account_name?: string | null } | null)?.account_name ?? null;
    return json({ connected: true, org_id: row.org_id, account_name: acct, event_id: row.return_event_id ?? null }, 200, cors);
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
