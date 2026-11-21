// Shared cron-secret auth for Supabase edge functions.
//
// Hardened 2026-05-11 (security chat). Use this everywhere instead of the
// old `if (expected && header !== expected)` pattern, which fails open when
// CRON_SECRET env is unset.
//
// Usage:
//   import { requireCronSecret } from "../_shared/cron-auth.ts";
//   Deno.serve(async (req) => {
//     const authErr = requireCronSecret(req);
//     if (authErr) return authErr;
//     // ... rest of handler
//   });

import { constantTimeEqual } from "./constantTime.ts";

export function requireCronSecret(req: Request): Response | null {
  const expected = Deno.env.get("CRON_SECRET");
  if (!expected) {
    return new Response(
      "server misconfigured: CRON_SECRET unset",
      { status: 500 },
    );
  }
  const provided = req.headers.get("x-cron-secret") ?? "";
  if (!constantTimeEqual(provided, expected)) {
    return new Response("unauthorized", { status: 401 });
  }
  return null;
}
