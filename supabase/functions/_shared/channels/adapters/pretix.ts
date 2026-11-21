// pretix on the channel core: the first adapter moved onto it (mig
// 20261121162400), a READ path only (exos-integrations /test). The org's
// pretix (pretix.eu or self-hosted) is a ticket backend Exos reads; it is
// never written to, so the allowlist is empty and every request is a GET
// through GatedHttp (audited, retried, the token in the Authorization header
// and redacted). The attendee sync itself still runs in exos-integrations on
// _shared/backends/pretix.ts (readAttendees moves next).

import { caps, type ChannelAdapter } from "../adapter.ts";
import { pretixWhoAmI } from "../../backends/pretix.ts";
import { baseUrl } from "../../backends/rows.ts";

export const PRETIX_DEFAULT_BASE = "https://pretix.eu";

/** The https origin the org's pretix lives on (config.base_url), or null. */
export function pretixBase(config: Record<string, unknown>): string | null {
  return baseUrl(config.base_url ?? PRETIX_DEFAULT_BASE);
}

export const pretixAdapter: ChannelAdapter = {
  id: "pretix",
  label: "pretix",
  status: "core",
  caps: caps({ role: "primary" }),
  writes: [],
  async testCredential(ctx) {
    if (!ctx.creds.secret) return { ok: false, error: "Paste a pretix API token." };
    const base = pretixBase(ctx.creds.config);
    if (!base) return { ok: false, error: "The pretix address must be an https URL." };
    // pretix.ts builds full URLs: GatedHttp's fetch view keeps them on the channel's base.
    return pretixWhoAmI(ctx.http.asFetch(), { base, organizer: String(ctx.creds.config.organizer ?? ""), token: ctx.creds.secret });
  },
};
