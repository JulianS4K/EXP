// What the edge functions the SPA calls with the user's Supabase JWT share:
// CORS for the allow-listed SPA origins, a no-store JSON response, and the
// signed-in user. Each function still checks the user's role in its RPCs.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { parseRedirectOrigins } from "./redirects.ts";

/**
 * CORS for the SPA's fetch calls: an origin in EXOS_REDIRECT_ORIGINS is
 * echoed back; any other origin gets no CORS headers (only `vary`).
 */
export function corsHeaders(origin: string | null, methods = "GET, POST, OPTIONS"): Record<string, string> {
  const allowed = parseRedirectOrigins(Deno.env.get("EXOS_REDIRECT_ORIGINS"));
  if (!origin || !allowed.includes(origin)) return { vary: "Origin" };
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": methods,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Max-Age": "600",
    vary: "Origin",
  };
}

/** A JSON response that is never cached; `extra` is usually the CORS headers. */
export function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json", "cache-control": "no-store", ...extra },
  });
}

/** A Supabase client acting as the caller (their Bearer JWT), or null without one. */
export function userClient(req: Request): SupabaseClient | null {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/.test(auth)) return null;
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
}

/** The caller's user id, checked with Supabase Auth, or null. */
export async function signedInUser(req: Request): Promise<string | null> {
  const c = userClient(req);
  if (!c) return null;
  const { data } = await c.auth.getUser();
  return data.user?.id ?? null;
}
