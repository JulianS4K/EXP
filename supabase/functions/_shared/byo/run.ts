// The own-account marketplace pass (mig 20261121214500), behind exos-byo:
// replay, for one event, the listings exos-distribute planned for each
// marketplace the organizer sells with their OWN seller account, on the
// channel core, with the org's credential. Pure apart from the injected
// rpc / fetch, so the Deno tests drive a whole pass with stubs.
//
// DRY RUN, PINNED. Operator 2026-11-21: "For the APIs build and keep read
// only till build is complete". BYO_WRITES_PINNED_OFF hands GatedHttp an org
// switch of false whatever the org's row says (as ADS_WRITES_PINNED_OFF and
// SOCIAL_WRITES_PINNED_OFF), so every write is a dry run even if an operator
// flag were on: nothing is sent, the exact request (secrets redacted) is
// recorded in exos_channel_audit ("What we'd send") and returned. Going live
// needs this pin removed in a reviewed change AND the CLAUDE.md write
// exception for each marketplace in Julian's words.

import type { ChannelCtx, OrgCredential } from "../channels/adapter.ts";
import { createGatedHttp } from "../channels/gatedHttp.ts";
import { memoryAuditSink, rpcAuditSink, teeSink, type AuditStep } from "../channels/audit.ts";
import { rpcUsageCounter, type UsageCounter } from "../channels/usage.ts";
import { loadCredential } from "../channels/credentials.ts";
import type { AdsResult } from "../channels/adapters/adsCommon.ts";
import { BYO_ADAPTERS, BYO_CHANNELS, BYO_DEFS, byoHttp, isByoChannel, type ByoChannel, type ByoRow } from "../channels/adapters/byoMarketplace.ts";

/** The build gate: every own-account marketplace write stays a dry run (see the header). */
export const BYO_WRITES_PINNED_OFF = true;

export { BYO_CHANNELS };

type Rpc = (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;

export interface ByoRunDeps {
  orgId: string;
  /** Service-role rpc. */
  rpc: Rpc;
  env: (k: string) => string | undefined | null;
  fetch: typeof fetch;
  now?: () => Date;
  counter?: UsageCounter;
  persistAudit?: boolean;
}

/** One marketplace of exos_byo_allocations_view. */
export interface ByoViewChannel {
  channel: string;
  provider: string;
  own: boolean;
  pct: number;
  min_pct: number;
  connected: boolean;
  network_ticked: boolean;
  tiers: Array<ByoRow & { capacity: number | null; allocated: number; held: number; sold: number; min_pct: number; account: string | null }>;
}

export interface ByoStepView { op: string; method: string; path: string; live: boolean; body: unknown; error?: string; warnings?: string[] }
const view = (s: AuditStep): ByoStepView => ({
  op: s.op, method: s.method, path: s.path, live: s.live, body: s.request?.body ?? null,
  ...(s.error ? { error: s.error } : {}), ...(s.warnings?.length ? { warnings: s.warnings.map((w) => w.reason) } : {}),
});

export interface ByoChannelPlan {
  channel: ByoChannel;
  label: string;
  pct: number;
  connected: boolean;
  /** Always true while the build pin is in. */
  dryRun: boolean;
  result: AdsResult;
  steps: ByoStepView[];
}

const NONE = (provider: string): OrgCredential =>
  ({ provider, status: "unverified", config: {}, secret: null, writesEnabled: false, accountName: null, source: "none" });

/** Plan every own-account marketplace of the event with a share above 0. */
export async function planByo(d: ByoRunDeps, req: { eventId: string; channels: ByoViewChannel[] }): Promise<{ channels: ByoChannelPlan[] }> {
  const out: ByoChannelPlan[] = [];
  for (const ch of req.channels) {
    if (!isByoChannel(ch.channel) || !ch.own || !(ch.pct > 0)) continue;
    const channel = ch.channel;
    const def = BYO_DEFS[channel];
    const cred = (await loadCredential(d.rpc, d.orgId, def.provider).catch(() => null)) ?? NONE(def.provider);
    const usable = !!cred.secret && cred.status !== "disabled";
    const memory = memoryAuditSink();
    const audit = d.persistAudit === false ? memory : teeSink(memory, rpcAuditSink(d.rpc, d.orgId));
    const o = byoHttp(channel, usable ? cred : null);
    const http = createGatedHttp({
      channel: o.channel, base: o.base, writes: o.writes, headers: o.headers, secrets: o.secrets, standIn: o.standIn,
      fetch: d.fetch, env: d.env,
      orgWritesEnabled: BYO_WRITES_PINNED_OFF ? false : cred.writesEnabled,
      audit,
      limits: { ...o.limits, counter: d.counter ?? rpcUsageCounter(d.rpc, d.orgId) },
      eventId: req.eventId,
      now: d.now,
    });
    const ctx: ChannelCtx = { orgId: d.orgId, creds: usable ? cred : NONE(def.provider), http, audit };
    const adapter = BYO_ADAPTERS.find((a) => a.id === `byo_${channel}`)!;
    try {
      const result = await adapter.planListings!(ctx, { channel, rows: ch.tiers }, null) as AdsResult;
      out.push({
        channel, label: def.label, pct: ch.pct, connected: usable, dryRun: !http.writesLive,
        result, steps: memory.steps.map(view),
      });
    } finally {
      await audit.flush?.();
    }
  }
  return { channels: out };
}
