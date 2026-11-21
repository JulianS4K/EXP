// Shared pieces of the ad-platform adapters (ads phase, mig 20261121190500):
// metaAds.ts, redditAds.ts, googleCustomerMatch.ts, xAds.ts. Pure.
//
// DRY RUN ONLY. Operator 2026-11-21: "For the APIs build and keep read only
// till build is complete". Every write goes through ctx.http (GatedHttp) on
// the adapter's explicit allowlist; with the org's switch or the operator's
// EXOS_<ID>_WRITES off (all off, and exos-ads pins the org switch off too),
// nothing is sent and GatedHttp hands back a stand-in. A chain of creates
// (campaign -> ad set -> ad) needs the earlier ids: a stand-in id is a
// "planned_<kind>" token, which the allowlists accept so the plan is
// complete, and which liveSafe() refuses to ever send live.

import type { ChannelCtx } from "../adapter.ts";
import { GatedHttpRefused, type GatedResponse, type HttpMethod, type RequestOptions, type WriteMethod } from "../gatedHttp.ts";

export const PLANNED_RE = /planned_[a-z_]{1,40}/;
export const plannedId = (kind: string): string => `planned_${kind.replace(/[^a-z_]/g, "_").slice(0, 40)}`;

/** Every placeholder a not-connected plan uses for an account id. */
export const NOT_CONNECTED = plannedId("account");

/** A stand-in factory: the kind of thing a path creates -> a planned id (in the platform's answer shape). */
export function standInBy(kinds: Array<[RegExp, string]>, wrap: (id: string) => unknown = (id) => ({ id })) {
  return (_method: WriteMethod, path: string, _body: unknown): unknown => {
    const hit = kinds.find(([re]) => re.test(path));
    return { ...(wrap(plannedId(hit ? hit[1] : "write")) as Record<string, unknown>), dry_run: true };
  };
}

/** Refuses a request that would carry a placeholder while writes are live. */
export function liveSafe(ctx: ChannelCtx, path: string, body: unknown): void {
  if (!ctx.http.writesLive) return;
  if (PLANNED_RE.test(path) || PLANNED_RE.test(JSON.stringify(body ?? null))) {
    throw new GatedHttpRefused(`${ctx.http.channel}: a planned placeholder would be sent live; connect the account and plan again`);
  }
}

export interface AdsStep {
  op: string;
  method: HttpMethod;
  path: string;
  planned: boolean;
  ok: boolean;
  error?: string;
}

export interface AdsResult {
  channel: string;
  /** The org has the credential this channel needs. */
  connected: boolean;
  /** Nothing was sent (every write a dry run). */
  planned: boolean;
  steps: AdsStep[];
  /** What was created (or would be): campaign / ad set / audience / ... -> id. */
  ids: Record<string, string>;
  warnings: string[];
  /** Rows (or requests) the limits pushed to a later window. */
  deferred?: number;
  /** The plan stopped here (a platform rule, a missing piece). */
  stopped?: string;
}

export function newResult(channel: string, ctx: ChannelCtx): AdsResult {
  return { channel, connected: !!ctx.creds.secret, planned: !ctx.http.writesLive, steps: [], ids: {}, warnings: [] };
}

/** One write through GatedHttp: placeholder-checked, recorded on the result. */
export async function write(
  ctx: ChannelCtx, res: AdsResult, method: WriteMethod, path: string, body: unknown, ro: Omit<RequestOptions, "body"> & { op: string },
): Promise<GatedResponse> {
  liveSafe(ctx, path, body);
  const r = await ctx.http.request(method, path, { ...ro, body });
  res.steps.push({ op: ro.op, method, path, planned: r.planned, ok: r.ok, ...(r.error ? { error: r.error } : {}) });
  if (r.live) res.planned = false;
  return r;
}

/** The id a create answered with (`pick` reads the platform's shape); null when the write failed. */
export function createdId(r: GatedResponse, pick: (body: any) => unknown): string | null {
  if (!r.ok) return null;
  const v = pick(r.body);
  return typeof v === "string" || typeof v === "number" ? String(v) : null;
}

/** Cents -> the platform's micro-units (Reddit budgets: 1 = 1/1,000,000 of the currency). */
export const microsFromCents = (c: number): number => Math.round(c) * 10_000;

/** The org's config value, or a placeholder when it isn't set (a not-connected plan). */
export function cfgOr(config: Record<string, unknown>, key: string, re: RegExp, kind: string): { value: string; set: boolean } {
  const v = config[key];
  return typeof v === "string" && re.test(v) ? { value: v, set: true } : { value: plannedId(kind), set: false };
}
