// The drain's X step (ads phase, mig 20261121190500): one claimed X row ->
// the outbox result. Pure apart from the injected fetch, so the Deno tests
// drive it with a stub.
//
// PINNED OFF IN CODE (review of #138, S3; operator 2026-11-21: "keep read
// only till build is complete"): X_CONVERSIONS_PINNED_OFF hands the x_ads
// GatedHttp an org switch of false whatever the ads_x row says (as
// ADS_WRITES_PINNED_OFF does for exos-ads), so with every flag below on the
// request is still only planned: X conversions are a dry run until a
// reviewed change removes the pin AND CLAUDE.md records Julian's write
// exception for X. Behind the pin, three gates:
//   1. EXOS_CONVERSIONS_LIVE=true (the drain's switch, like every platform);
//   2. Exos's X app keys (X_ADS_CONSUMER_KEY / _SECRET), else planned only;
//   3. the x_ads adapter's GatedHttp: the org's switch (the ads_x row's
//      writes_enabled) AND EXOS_X_ADS_WRITES=on, on the one allowlisted path.
// With the pin or any gate off nothing is sent: the request as built (no
// token in it) goes to payload_planned and the row is marked skipped with
// why.

import type { OrgCredential } from "../channels/adapter.ts";
import { createGatedHttp } from "../channels/gatedHttp.ts";
import { memoryAuditSink, type AuditSink } from "../channels/audit.ts";
import { xAdsAdapter, xAdsHttp, type XAppKeys } from "../channels/adapters/xAds.ts";
import { type BuildContext, type ConversionRow, type PlannedRequest, redactRequest } from "./common.ts";
import { buildConversionRequest, plannedOnly } from "./send.ts";

/** The build gate: X conversions never leave Exos while this is true. */
export const X_CONVERSIONS_PINNED_OFF = true;

export type XOutcome =
  | { result: "sent"; status: number; planned: PlannedRequest }
  | { result: "skipped"; error: string; planned?: PlannedRequest }
  | { result: "failed" | "retry"; error: string; status: number | null; planned: PlannedRequest };

export interface XDeps {
  live: boolean;
  app: XAppKeys | null;
  env: (k: string) => string | undefined | null;
  fetch: typeof fetch;
  audit?: AuditSink;
  ctx: BuildContext;
}

export async function drainXRow(row: ConversionRow & { org_id: string }, cred: OrgCredential | null, d: XDeps): Promise<XOutcome> {
  if (!cred || !cred.secret || !cred.writesEnabled || cred.status === "disabled") {
    return { result: "skipped", error: "x: not connected, or switched off for the organization" };
  }
  const config: Record<string, string> = {};
  for (const [k, v] of Object.entries(cred.config)) if (typeof v === "string") config[k] = v;
  const built = buildConversionRequest(row, { config, secret: cred.secret, test_event_code: null }, d.ctx);
  if ("skip" in built) return { result: "skipped", error: built.skip };
  const planned = redactRequest(built.request, cred.secret);
  if (!d.live) return { result: "skipped", error: "dry-run: EXOS_CONVERSIONS_LIVE is not true", planned };
  if (plannedOnly("x", { xConfigured: !!d.app })) return { result: "skipped", error: "planned only: x sender not enabled (X app keys not set)", planned };

  const audit = d.audit ?? memoryAuditSink();
  const opts = xAdsHttp(cred, d.app);
  const http = createGatedHttp({ ...opts, fetch: d.fetch, env: d.env, orgWritesEnabled: X_CONVERSIONS_PINNED_OFF ? false : cred.writesEnabled, audit });
  const r = await xAdsAdapter.sendConversion!({ orgId: row.org_id, creds: cred, http, audit },
    { pixelId: config.pixel_id, body: built.request.body, app: d.app! }) as { ok: boolean; status: number; error?: string; planned?: boolean; live?: boolean };
  await audit.flush?.();
  if (r.planned) {
    return { result: "skipped", planned, error: X_CONVERSIONS_PINNED_OFF
      ? "dry-run: X conversions are pinned off in code (build phase)"
      : "dry-run: the x_ads writes are off (the organization's switch or EXOS_X_ADS_WRITES)" };
  }
  if (r.ok) return { result: "sent", status: r.status, planned };
  const s = r.status || null;
  const retry = s === null || s === 408 || s === 425 || s === 429 || s >= 500;
  return { result: retry ? "retry" : "failed", status: s, error: `x: ${r.error ?? `http ${s}`}`, planned };
}
