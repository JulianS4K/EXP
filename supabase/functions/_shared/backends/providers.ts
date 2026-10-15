// Credential tests for Integrations (mig 20261016090000): one READ per
// provider, never a send or a write. Returns the account's display name.
import { baseUrl } from "./rows.ts";
import { pretixWhoAmI } from "./pretix.ts";
import { lumaWhoAmI } from "./luma.ts";

type Fetch = typeof fetch;
export interface TestResult { ok: boolean | null; name?: string; error?: string }

export async function testProvider(
  f: Fetch, provider: string, config: Record<string, unknown>, secret: string | null,
  blocked: (url: string) => Promise<string | null>,
): Promise<TestResult> {
  switch (provider) {
    case "pretix": {
      const base = baseUrl(config.base_url ?? "https://pretix.eu");
      if (!base) return { ok: false, error: "The pretix address must be an https URL." };
      if (await blocked(base)) return { ok: false, error: "That pretix address isn't reachable from Exos." };
      if (!secret) return { ok: false, error: "Paste a pretix API token." };
      return pretixWhoAmI(f, { base, organizer: String(config.organizer ?? ""), token: secret });
    }
    case "hievents": {
      const base = baseUrl(config.base_url);
      if (!base) return { ok: false, error: "The hi.events address must be an https URL." };
      if (await blocked(base)) return { ok: false, error: "That hi.events address isn't reachable from Exos." };
      const r = await f(`${base}/api/public/events/0`, { method: "GET", headers: { Accept: "application/json" }, redirect: "manual" });
      // Any API answer (even 404 for event 0) means the address is a hi.events backend.
      const isApi = (r.headers.get("content-type") ?? "").includes("json");
      return isApi ? { ok: true, name: new URL(base).host } : { ok: false, error: "That address didn't answer like a hi.events API." };
    }
    case "luma": {
      if (!secret) return { ok: false, error: "Paste a Luma API key." };
      return lumaWhoAmI(f, secret);
    }
    case "twilio": {
      const sid = String(config.account_sid ?? "");
      if (!/^AC[0-9a-fA-F]{32}$/.test(sid)) return { ok: false, error: "The Account SID starts with AC and has 34 characters." };
      if (!secret) return { ok: false, error: "Paste the Twilio auth token." };
      const r = await f(`https://api.twilio.com/2010-04-01/Accounts/${sid}.json`, {
        method: "GET", headers: { Authorization: `Basic ${btoa(`${sid}:${secret}`)}` }, redirect: "manual",
      });
      if (r.status === 401) return { ok: false, error: "Twilio refused the SID / token." };
      if (!r.ok) return { ok: false, error: `Twilio answered ${r.status}.` };
      const b = await r.json().catch(() => ({}));
      return { ok: true, name: typeof b?.friendly_name === "string" ? b.friendly_name : sid };
    }
    case "telnyx": {
      if (!secret) return { ok: false, error: "Paste a Telnyx API key." };
      const r = await f("https://api.telnyx.com/v2/balance", { method: "GET", headers: { Authorization: `Bearer ${secret}` }, redirect: "manual" });
      if (r.status === 401) return { ok: false, error: "Telnyx refused the API key." };
      if (!r.ok) return { ok: false, error: `Telnyx answered ${r.status}.` };
      return { ok: true, name: "Telnyx account" };
    }
    default:
      // Resale marketplaces: stored for the marketplace readers; Exos doesn't
      // call them from here (and never writes to them).
      return { ok: null };
  }
}
