// The organizer's OWN marketplace seller accounts on the channel core (BYO,
// mig 20261121214500; docs/marketplace/README.md "Your own marketplace
// accounts"). DRY RUN ONLY. Operator 2026-11-21: "For the APIs build and keep
// read only till build is complete". Going live needs this pin removed in a
// reviewed change AND a CLAUDE.md write exception per marketplace in
// Julian's words.
//
// There is ONE listing plan, the one exos-distribute already makes for every
// allocation (_shared/marketplace/exosListing.ts + each marketplace's
// listingPlan.ts, diffed by sync.ts), stored on the allocation row as
// planned_listing. An own-account allocation is the same row with account
// 'own'. This adapter only REPLAYS that plan through ctx.http (GatedHttp: the
// allowlist below, the dry-run decision, the audit, the limits) with the
// org's own credential from the store (providers stubhub / seatgeek / vivid
// / tevo, mig 20261016090000) instead of the Exos network's account. No
// second transport and no second planner.
//
//   creates   each planned listing's own request (endpoint, method, path, body)
//   updates   StubHub PATCH /externalsellerlistings/{ex…}, SeatGeek PATCH
//             /listings/single/{ex…} with the changed fields; Vivid Seats and
//             Ticket Evolution updates are not built yet (warned)
//   deletes   sync.ts planDelist (the same requests the network uses)
// A $0 listing is never planned (limits.ts: every resale marketplace blocks
// zero_price). A plan that carries a placeholder is refused live (liveSafe).

import { caps, type ChannelAdapter, type ChannelCtx, type OrgCredential } from "../adapter.ts";
import type { WriteMethod, WriteRule } from "../gatedHttp.ts";
import { evaluateLimits } from "../limits.ts";
import { newResult, write, type AdsResult } from "./adsCommon.ts";
import { planDelist, type DelistPlan } from "../../marketplace/sync.ts";
import { plannedEntries } from "../../marketplace/exosListing.ts";
import { isExosListingId } from "../../marketplace/listingIds.ts";

export const BYO_CHANNELS = ["stubhub", "seatgeek", "vivid", "evo"] as const;
export type ByoChannel = typeof BYO_CHANNELS[number];

/** An Exos listing id in a path (listingIds.ts EXOS_ID). */
const EX = "ex[a-z2-7]{26}[1-9][0-9]{0,3}";
const re = (s: string) => new RegExp(`^${s}$`);

interface ByoDef {
  label: string;
  /** exos_org_integrations provider (the org's credential). */
  provider: string;
  base: string;
  writes: WriteRule[];
  headers: (secret: string | null) => Record<string, string>;
  /** The update request for one listing's changed fields, when built. */
  update?: (listingId: string, patch: Record<string, unknown>) => { method: WriteMethod; path: string; body: unknown };
}

export const BYO_DEFS: Readonly<Record<ByoChannel, ByoDef>> = {
  stubhub: {
    label: "StubHub", provider: "stubhub", base: "https://api.stubhub.net",
    writes: [
      { method: "POST", path: /^\/events\/[0-9]{1,15}\/sellerlistings$/ },
      { method: "POST", path: /^\/sellerlistings$/ },
      { method: "PATCH", path: re(`/externalsellerlistings/${EX}`) },
      { method: "DELETE", path: re(`/externalsellerlistings/${EX}`), idempotent: true },
    ],
    headers: (s) => (s ? { Authorization: `Bearer ${s}` } : {}),
    update: (id, patch) => ({ method: "PATCH", path: `/externalsellerlistings/${encodeURIComponent(id)}`, body: patch }),
  },
  seatgeek: {
    label: "SeatGeek", provider: "seatgeek", base: "https://sellerdirect-api.seatgeek.com",
    writes: [
      { method: "PUT", path: re(`/listings/single/${EX}`), idempotent: true },
      { method: "PATCH", path: re(`/listings/single/${EX}`) },
      { method: "POST", path: /^\/listings\/bulk-delete$/ },
    ],
    headers: (s) => (s ? { Authorization: `Bearer ${s}` } : {}),
    update: (id, patch) => ({ method: "PATCH", path: `/listings/single/${encodeURIComponent(id)}`, body: patch }),
  },
  vivid: {
    label: "Vivid Seats", provider: "vivid", base: "https://brokers.vividseats.com/webservices",
    writes: [
      { method: "POST", path: /^\/listings\/v2\/create$/ },
      { method: "DELETE", path: /^\/listings\/v2\/delete$/, idempotent: true },
    ],
    headers: (s) => (s ? { "Api-token": s } : {}),
  },
  evo: {
    label: "Ticket Evolution", provider: "tevo", base: "https://api.ticketevolution.com",
    writes: [
      { method: "POST", path: /^\/v9\/inventory$/ },
      { method: "DELETE", path: /^\/v9\/inventory\/[1-9][0-9]{0,15}$/, idempotent: true },
    ],
    // X-Signature is an HMAC of the request, computed only when a request is sent (never in a dry run).
    headers: (s) => (s ? { "X-Token": s } : {}),
  },
};

export const isByoChannel = (c: unknown): c is ByoChannel => typeof c === "string" && (BYO_CHANNELS as readonly string[]).includes(c);

/** The GatedHttp options for one own-account marketplace (the adapter id picks EXOS_BYO_<CHANNEL>_WRITES). */
export function byoHttp(channel: ByoChannel, creds: OrgCredential | null) {
  const d = BYO_DEFS[channel];
  return {
    channel: `byo_${channel}`,
    base: d.base,
    writes: d.writes,
    headers: d.headers(creds?.secret ?? null),
    secrets: [creds?.secret],
    standIn: () => ({ dry_run: true }),
    limits: { platform: channel, scopeKey: (creds?.accountName ?? "").slice(0, 64) },
  };
}

/** One own-account allocation, as exos_byo_allocations_view returns it. */
export interface ByoRow {
  tier_id: string;
  name: string;
  price: number | null;
  status: string | null;
  planned_listing: unknown;
  listed: boolean;
  /** listed_snapshot, when the caller has it (delist / deletes need the ids). */
  listed_snapshot?: unknown;
  skip?: string | null;
}

interface PlanShape {
  listings?: Array<{ listing_id: string; quantity?: number; unit_price?: number; request?: { method?: string; path?: string; body?: unknown } }>;
  ops?: { create?: string[]; update?: Array<{ listing_id: string; patch: Record<string, unknown> }>; delete?: string[] };
  unresolved?: string[];
  notices?: string[];
}

const WRITE_METHODS = new Set(["POST", "PUT", "PATCH", "DELETE"]);

// exos-distribute plans Ticket Evolution listings for Exos's own office
// (TEVO_OFFICE_ID in the request body) and TEvo numbers inventory per office,
// so replaying that plan with the organizer's token would list in, or delete
// from, the wrong office (review of #143). Until the organizer's office id is
// read from their credential and planned for, nothing is planned for it.
const TEVO_OWN_OFFICE = "Ticket Evolution with your own account needs your own office id in the plan, which isn't built yet: nothing is planned for it.";
const cents = (p: unknown): number | null => (typeof p === "number" && Number.isFinite(p) ? Math.round(p * 100) : null);

async function sendDelist(ctx: ChannelCtx, res: AdsResult, plan: DelistPlan | null, op: string) {
  for (const r of plan?.requests ?? []) {
    if (r.path.includes("{")) { res.warnings.push(`A listing can't be addressed safely: ${r.path}`); continue; }
    await write(ctx, res, r.method, r.path, r.body ?? null, { op });
  }
}

/** Replay one channel's planned listings (exos-distribute's plan) as writes through ctx.http. */
async function planListings(ctx: ChannelCtx, alloc: unknown, _prev: unknown): Promise<AdsResult> {
  const { channel, rows } = (alloc ?? {}) as { channel?: unknown; rows?: ByoRow[] };
  if (!isByoChannel(channel)) throw new Error("byo: unknown marketplace");
  const def = BYO_DEFS[channel];
  const res = newResult(`byo_${channel}`, ctx);
  if (channel === "evo") { res.warnings.push(TEVO_OWN_OFFICE); return res; }
  if (!res.connected) res.warnings.push(`Your ${def.label} seller account isn't connected (Org settings → Integrations): the requests below are what Exos would send once it is.`);
  for (const row of rows ?? []) {
    if (row.skip) { res.warnings.push(`${row.name}: ${row.skip}.`); continue; }
    // Every resale marketplace blocks a $0 listing (limits.ts zero_price).
    const verdict = evaluateLimits(channel, { priceCents: cents(row.price) });
    if (verdict.blocks.length) { res.warnings.push(`${row.name}: ${verdict.blocks[0].reason}`); continue; }
    if (row.status === "delisting") {
      await sendDelist(ctx, res, planDelist(channel, row.listed_snapshot ?? null), "listing.delist");
      continue;
    }
    const plan = (row.planned_listing ?? null) as PlanShape | null;
    if (!plan || !Array.isArray(plan.listings)) {
      res.warnings.push(`${row.name}: not planned yet (the next distribution run plans its listings).`);
      continue;
    }
    for (const u of plan.unresolved ?? []) res.warnings.push(`${row.name}: ${u}`);
    for (const n of plan.notices ?? []) res.warnings.push(`${row.name}: ${n}`);
    const creates = new Set(plan.ops?.create ?? plan.listings.map((l) => l.listing_id));
    for (const l of plan.listings) {
      if (!creates.has(l.listing_id)) continue;
      const rq = l.request ?? {};
      const method = String(rq.method ?? "").toUpperCase();
      if (!WRITE_METHODS.has(method) || typeof rq.path !== "string") {
        res.warnings.push(`${row.name}: listing ${l.listing_id} has no request planned.`);
        continue;
      }
      if (l.unit_price !== undefined && (cents(l.unit_price) ?? 0) <= 0) { res.warnings.push(`${row.name}: a $0 listing is never offered.`); continue; }
      await write(ctx, res, method as WriteMethod, rq.path, rq.body ?? null, { op: "listing.create" });
    }
    for (const u of plan.ops?.update ?? []) {
      if (!isExosListingId(u.listing_id)) continue;
      if (!def.update) { res.warnings.push(`${row.name}: changing a live listing on your own ${def.label} account isn't built yet (${u.listing_id}).`); continue; }
      const r = def.update(u.listing_id, u.patch);
      await write(ctx, res, r.method, r.path, r.body, { op: "listing.update" });
    }
    const gone = (plan.ops?.delete ?? []).filter(isExosListingId);
    if (gone.length) {
      const snap = { listings: plannedEntries(row.listed_snapshot ?? null).filter((e) => gone.includes(e.listing_id)) };
      await sendDelist(ctx, res, planDelist(channel, snap), "listing.delete");
    }
  }
  return res;
}

async function delist(ctx: ChannelCtx, snapshot: unknown): Promise<AdsResult> {
  const { channel, snapshot: snap } = (snapshot ?? {}) as { channel?: unknown; snapshot?: unknown };
  if (!isByoChannel(channel)) throw new Error("byo: unknown marketplace");
  const res = newResult(`byo_${channel}`, ctx);
  if (channel === "evo") { res.warnings.push(TEVO_OWN_OFFICE); return res; }
  await sendDelist(ctx, res, planDelist(channel, snap ?? null), "listing.delist");
  return res;
}

const byoAdapter = (channel: ByoChannel): ChannelAdapter => ({
  id: `byo_${channel}`,
  label: `${BYO_DEFS[channel].label} (your own account)`,
  status: "core",
  caps: caps({ role: "secondary", list: true, delist: true }),
  writes: BYO_DEFS[channel].writes,
  planListings,
  planDelist: delist,
});

export const BYO_ADAPTERS: readonly ChannelAdapter[] = BYO_CHANNELS.map(byoAdapter);
