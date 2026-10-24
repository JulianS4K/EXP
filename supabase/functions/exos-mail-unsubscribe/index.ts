// exos-mail-unsubscribe — the one-click unsubscribe endpoint marketing mail
// points at (RFC 8058 List-Unsubscribe-Post; see handler.ts). Public: mail
// clients call it with no session, the token is the credential.
// Deploy with --no-verify-jwt.
//
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, EXOS_APP_URL (for the GET redirect).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { normalizeAppUrl } from "../_shared/mail-render.ts";
import { handleUnsubscribe } from "./handler.ts";

Deno.serve((req: Request): Promise<Response> => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  return handleUnsubscribe(req, {
    appUrl: normalizeAppUrl(Deno.env.get("EXOS_APP_URL")),
    unsubscribe: async (token) => {
      const { error } = await sb.rpc("exos_mail_unsubscribe", { p_token: token });
      if (error) {
        console.error("exos-mail-unsubscribe: rpc failed", error.code);
        throw new Error("unsubscribe failed");
      }
    },
  });
});
