// The org's credential for a provider, from the one store (mig
// 20261121162400): exos_integration_secret, service role only, which reads
// exos_org_integrations + Vault and falls back to a managed provider's old
// table while its copy is missing. The secret never leaves the server: pass
// it to GatedHttp in `headers` and `secrets`, never into a URL or a log.

import type { OrgCredential } from "./adapter.ts";

type Rpc = (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;

export function parseCredential(data: unknown): OrgCredential | null {
  const d = data as Record<string, unknown> | null;
  if (!d || typeof d !== "object" || typeof d.provider !== "string") return null;
  return {
    provider: d.provider,
    status: typeof d.status === "string" ? d.status : "unverified",
    config: d.config && typeof d.config === "object" && !Array.isArray(d.config) ? d.config as Record<string, unknown> : {},
    secret: typeof d.secret === "string" && d.secret ? d.secret : null,
    writesEnabled: d.writes_enabled === true,
    accountName: typeof d.account_name === "string" ? d.account_name : null,
    source: typeof d.source === "string" ? d.source : "store",
  };
}

/** Null when nothing is connected (or the row is disabled). Throws on an RPC failure. */
export async function loadCredential(rpc: Rpc, orgId: string, provider: string): Promise<OrgCredential | null> {
  const { data, error } = await rpc("exos_integration_secret", { p_org_id: orgId, p_provider: provider });
  if (error) throw new Error("credential read failed");
  return parseCredential(data);
}
