// exos-byo — "Sell with your own marketplace accounts" (mig 20261121214500;
// docs/marketplace/README.md "Your own marketplace accounts"): for one event,
// replay the listings exos-distribute planned for each marketplace the
// organizer sells with their OWN seller account (StubHub, SeatGeek, Vivid
// Seats, Ticket Evolution), on the channel core, with the org's credential.
//
// DRY RUN ONLY (operator 2026-11-21: "For the APIs build and keep read only
// till build is complete"). Every write goes through GatedHttp on the
// adapter's explicit allowlist with the org's switch pinned off
// (_shared/byo/run.ts BYO_WRITES_PINNED_OFF), and GatedHttp is handed a fetch
// that refuses every call: no request reaches a marketplace from this
// function, not even a read. What would be sent is recorded in
// exos_channel_audit ("What we'd send", Org settings) and returned here.
//
// Route (POST JSON, under /functions/v1/exos-byo), owner / manager (the view
// RPC checks the caller's role first):
//   /plan  {org, event}
// The allocations themselves are set with the exos_byo_set_allocation RPC.
// Deploy with --no-verify-jwt (CORS preflight; the JWT is checked here).
//
// Env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, EXOS_REDIRECT_ORIGINS.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { redactError } from "../_shared/log.ts";
import { corsHeaders, json } from "../_shared/spaHttp.ts";
import { planByo, type ByoRunDeps, type ByoViewChannel } from "../_shared/byo/run.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// A fetch that refuses everything: the dry run must never reach a marketplace.
const noNetwork = (async () => {
  throw new Error("exos-byo: no network in the dry run");
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

  // The caller's role (owner / manager) and the event's allocations, as the caller.
  const v = await sbUser.rpc("exos_byo_allocations_view", { p_event_id: event });
  if (v.error) return rpcError(v.error, cors);
  const data = v.data as { event: { org_id: string }; channels: ByoViewChannel[] } | null;
  if (!data?.event || data.event.org_id !== org) return json({ error: "pick an event of this organization" }, 400, cors);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const deps: ByoRunDeps = {
    orgId: org,
    rpc: (fn, args) => sb.rpc(fn, args),
    env: (k) => Deno.env.get(k),
    fetch: noNetwork,
  };
  try {
    const out = await planByo(deps, { eventId: event, channels: data.channels });
    return json({ dry_run: true, ...out }, 200, cors);
  } catch (err) {
    console.error("exos-byo: plan failed", redactError(err));
    return json({ error: "something went wrong" }, 500, cors);
  }
});

function rpcError(error: { code?: string; message?: string }, cors: Record<string, string>): Response {
  const msg = (error.message ?? "").replace(/^exos_\w+: /, "");
  if (error.code === "42501") return json({ error: msg || "Not allowed.", reason: "forbidden" }, 403, cors);
  if (error.code === "P0002") return json({ error: "pick an event", reason: "not_found" }, 404, cors);
  if (error.code === "22023") return json({ error: msg, reason: "invalid" }, 400, cors);
  console.error("exos-byo: rpc failed", redactError(error));
  return json({ error: "something went wrong" }, 500, cors);
}
