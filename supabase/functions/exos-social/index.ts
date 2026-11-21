// exos-social — "Post / list this event" (mig 20261121203000; docs/social.md
// "Posting and listing APIs"): plan an event's posts and listings on
// Instagram, TikTok, Meetup, LinkedIn and Google Business Profile for an
// org, on the channel core, from one post kit.
//
// DRY RUN ONLY (operator 2026-11-21: "For the APIs build and keep read only
// till build is complete"). Every write goes through GatedHttp on its
// adapter's explicit allowlist with the org's switch pinned off
// (_shared/social/run.ts SOCIAL_WRITES_PINNED_OFF), so nothing is sent
// whatever the flags say, and GatedHttp is handed a fetch that refuses every
// call: no request reaches a platform from this function, not even a read.
// What would be sent is recorded in exos_channel_audit (the organizer's
// "What we'd send", Org settings) and returned here.
//
// Route (POST JSON, under /functions/v1/exos-social), owner / manager (the
// context RPC checks the caller's role first):
//   /plan  {org, event, platforms?: [instagram, tiktok, meetup, linkedin, google_business]}
// Deploy with --no-verify-jwt (CORS preflight; the JWT is checked here).
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY,
//      EXOS_REDIRECT_ORIGINS, EXOS_APP_BASE_URL (the ticket links),
//      EXOS_TIKTOK_APP_AUDITED (on only after TikTok's audit; default off:
//      every TikTok post private).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { redactError } from "../_shared/log.ts";
import { corsHeaders, json } from "../_shared/spaHttp.ts";
import { planSocial, SOCIAL_PLATFORMS, type RunDeps } from "../_shared/social/run.ts";
import type { SocialEventInput, SocialPlatform } from "../_shared/social/postKit.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// A fetch that refuses everything: the dry run must never reach a platform.
const noNetwork = (async () => {
  throw new Error("exos-social: no network in the dry run");
}) as unknown as typeof fetch;

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const route = url.pathname.replace(/\/+$/, "").split("/").pop() ?? "";
  const cors = corsHeaders(req.headers.get("origin"), "POST, OPTIONS");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405, cors);
  if (route !== "plan") return json({ error: "not found" }, 404, cors);

  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(auth)) return json({ error: "sign in first" }, 401, cors);
  const sbUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data: who } = await sbUser.auth.getUser();
  if (!who.user) return json({ error: "sign in first" }, 401, cors);
  const body = await req.json().catch(() => ({}));
  const org = String(body?.org ?? "");
  const event = String(body?.event ?? "");
  if (!UUID.test(org)) return json({ error: "missing or bad org" }, 400, cors);
  if (!UUID.test(event)) return json({ error: "pick an event" }, 400, cors);
  const asked = Array.isArray(body?.platforms) ? body.platforms.map(String) : SOCIAL_PLATFORMS;
  const platforms = SOCIAL_PLATFORMS.filter((p) => asked.includes(p)) as SocialPlatform[];
  if (!platforms.length) return json({ error: `one of ${SOCIAL_PLATFORMS.join(", ")}` }, 400, cors);

  // The caller's role (owner / manager) and the event's facts, as the caller.
  const ctxRes = await sbUser.rpc("exos_social_post_context", { p_org_id: org, p_event_id: event });
  if (ctxRes.error) return rpcError(ctxRes.error, cors);
  const context = ctxRes.data as {
    org: { venue_org?: boolean }; event: (SocialEventInput & { id: string; capacity?: number | null }) | null;
    connected: Record<string, unknown>;
  };
  if (!context.event) return json({ error: "pick an event" }, 400, cors);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const deps: RunDeps = {
    orgId: org,
    rpc: (fn, args) => sb.rpc(fn, args),
    env: (k) => Deno.env.get(k),
    fetch: noNetwork,
    appBase: (Deno.env.get("EXOS_APP_BASE_URL") ?? "").replace(/\/+$/, ""),
  };
  try {
    const out = await planSocial(deps, { event: context.event, venueOrg: context.org?.venue_org === true, platforms });
    return json({ dry_run: true, connected: context.connected, ...out }, 200, cors);
  } catch (err) {
    console.error("exos-social: plan failed", redactError(err));
    return json({ error: "something went wrong" }, 500, cors);
  }
});

function rpcError(error: { code?: string; message?: string }, cors: Record<string, string>): Response {
  const msg = (error.message ?? "").replace(/^exos_\w+: /, "");
  if (error.code === "42501") return json({ error: msg || "Not allowed.", reason: "forbidden" }, 403, cors);
  if (error.code === "22023") return json({ error: msg, reason: "invalid" }, 400, cors);
  console.error("exos-social: rpc failed", redactError(error));
  return json({ error: "something went wrong" }, 500, cors);
}
