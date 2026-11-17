// exos-wroom-join — a new waiting-room place behind Cloudflare Turnstile
// (mig 20261118120000; docs/self-hosting.md "Waiting room CAPTCHA").
//   POST /exos-wroom-join { event_id, token?, turnstile_token }
// The logic and its order live in _shared/wroomJoin.ts (Deno-tested with the
// siteverify call mocked). Public (no JWT): deploy with --no-verify-jwt.
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, TURNSTILE_SECRET_KEY
// (unset: 503, the room can't take new places with its Turnstile on);
// optional EXOS_GUEST_IP_SALT.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleWroomJoin } from "../_shared/wroomJoin.ts";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve((req: Request) =>
  handleWroomJoin(req, {
    env: (n) => Deno.env.get(n),
    fetch: (url, init) => fetch(url, init),
    rpc: async (fn, args) => {
      const { data, error } = await sb.rpc(fn, args);
      return { data, error: error ? { code: error.code, message: error.message } : null };
    },
  })
);
