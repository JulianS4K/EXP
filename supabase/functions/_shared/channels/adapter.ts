// ChannelAdapter: one shape for every platform Exos mirrors to, lists on,
// reads from or promotes through (channel core, mig 20261121162400; the
// proposal from EXOS Growth, 2026-11-21). An adapter declares what it can do
// (ChannelCaps) and implements only the methods its capabilities need; every
// call reaches the platform through ctx.http (GatedHttp: the live / dry-run
// decision, the allowlist, the audit, the limits) with the org's credential
// from the one store (credentials.ts). Pure: no Deno or Node APIs.
//
// The registry lists every channel Exos knows. `core` adapters run on this
// interface; `legacy` entries describe a channel whose code still lives in
// its own module (Eventbrite / Luma in exos-channel-sync, DICE in
// exos-dice-import, the marketplaces in exos-distribute), so the caps table
// is complete while each one moves over on its own branch.

import type { AuditSink } from "./audit.ts";
import type { GatedHttp } from "./gatedHttp.ts";
import type { LimitFacts } from "./limits.ts";
import type { HashedIdentifiers } from "../hashedIds.ts";

export type DeliveryKind = "claim_url" | "pdf" | "mobile_transfer" | "barcode" | "manual";

export interface ChannelCaps {
  /** primary: sells Exos inventory as its own; secondary: resale / listing only. */
  role: "primary" | "secondary";
  createEvent: boolean;
  ticketTypes: boolean;
  setCapacity: boolean;
  requestEvent: boolean;
  matchEvent: boolean;
  list: boolean;
  delist: boolean;
  deliver: readonly DeliveryKind[];
  readAttendees: boolean;
  checkin: boolean;
  saleWebhook: boolean;
  // Promotion and measurement (new with the core).
  publishPost: boolean;
  syncAudience: boolean;
  createCampaign: boolean;
  readInsights: boolean;
  sendConversion: boolean;
}

/** The org's credential for this channel (exos_integration_secret). */
export interface OrgCredential {
  provider: string;
  status: string;
  config: Record<string, unknown>;
  /** Never logged; GatedHttp redacts it from every step. */
  secret: string | null;
  writesEnabled: boolean;
  accountName: string | null;
  /** 'store', or 'legacy:<table>' while a managed provider's copy is missing. */
  source: string;
}

export interface ChannelCtx {
  orgId: string;
  creds: OrgCredential;
  http: GatedHttp;
  audit: AuditSink;
  facts?: LimitFacts;
}

/** A sale as every channel reports it: an order, or a count delta. Unique by (channel, external_order_id). */
export type CanonicalSale =
  | { kind: "order"; channel: string; external_order_id: string; external_event_id: string; at: string;
      items: Array<{ external_ticket_type_id: string; quantity: number; unit_cents: number | null }> }
  | { kind: "count"; channel: string; external_event_id: string; external_ticket_type_id: string; sold: number; at: string };

export interface TestResult { ok: boolean | null; name?: string; error?: string }
export interface Page<T> { rows: T[]; next: string | null }
export interface AttendeeRow { ref: string; code: string | null; name: string | null; email: string | null; ticket: string | null; void: boolean }

/** Exos's view of an event, as the planners take it (model.ts MirrorEvent and friends). */
export type ExosEvent = Record<string, unknown> & { id: string };

export interface ChannelAdapter {
  id: string;
  label: string;
  caps: ChannelCaps;
  /** core: runs on this interface. legacy: caps only; the code is elsewhere (see `home`). */
  status: "core" | "legacy";
  /** Where a legacy channel's code lives today. */
  home?: string;
  /** Write allowlist GatedHttp enforces for this channel (empty: read only). */
  writes?: import("./gatedHttp.ts").WriteRule[];
  testCredential?(ctx: ChannelCtx): Promise<TestResult>;
  upsertEvent?(ctx: ChannelCtx, ev: ExosEvent, link: unknown): Promise<unknown>;
  syncTicketTypes?(ctx: ChannelCtx, ev: ExosEvent, maps: unknown): Promise<unknown>;
  setCapacity?(ctx: ChannelCtx, extEventId: string, targets: unknown): Promise<unknown>;
  requestEvent?(ctx: ChannelCtx, ev: ExosEvent): Promise<unknown>;
  findEvents?(ctx: ChannelCtx, ev: ExosEvent): Promise<unknown[]>;
  planListings?(ctx: ChannelCtx, alloc: unknown, prev: unknown): Promise<unknown>;
  planDelist?(ctx: ChannelCtx, snapshot: unknown): Promise<unknown>;
  readSales?(ctx: ChannelCtx, since: string | null): AsyncIterable<CanonicalSale>;
  parseWebhook?(req: Request, ctx: ChannelCtx): Promise<CanonicalSale[]>;
  deliver?(ctx: ChannelCtx, sale: CanonicalSale, kind: DeliveryKind, tickets: unknown[]): Promise<unknown>;
  readAttendees?(ctx: ChannelCtx, extEventId: string, cursor: string | null): Promise<Page<AttendeeRow>>;
  checkin?(ctx: ChannelCtx, extAttendeeId: string): Promise<unknown>;
  publishPost?(ctx: ChannelCtx, ev: ExosEvent, post: { text: string; url?: string }): Promise<unknown>;
  syncAudience?(ctx: ChannelCtx, audience: { id: string; members: HashedIdentifiers[] }): Promise<unknown>;
  createCampaign?(ctx: ChannelCtx, ev: ExosEvent, campaign: Record<string, unknown>): Promise<unknown>;
  readInsights?(ctx: ChannelCtx, ref: string): Promise<Record<string, number>>;
  sendConversion?(ctx: ChannelCtx, conversion: Record<string, unknown>): Promise<unknown>;
}

/** The method each capability needs (deliver: a non-empty list needs deliver()). */
export const CAP_METHOD: Readonly<Record<Exclude<keyof ChannelCaps, "role">, keyof ChannelAdapter>> = {
  createEvent: "upsertEvent",
  ticketTypes: "syncTicketTypes",
  setCapacity: "setCapacity",
  requestEvent: "requestEvent",
  matchEvent: "findEvents",
  list: "planListings",
  delist: "planDelist",
  deliver: "deliver",
  readAttendees: "readAttendees",
  checkin: "checkin",
  saleWebhook: "parseWebhook",
  publishPost: "publishPost",
  syncAudience: "syncAudience",
  createCampaign: "createCampaign",
  readInsights: "readInsights",
  sendConversion: "sendConversion",
};

const NONE: ChannelCaps = {
  role: "secondary", createEvent: false, ticketTypes: false, setCapacity: false, requestEvent: false, matchEvent: false,
  list: false, delist: false, deliver: [], readAttendees: false, checkin: false, saleWebhook: false,
  publishPost: false, syncAudience: false, createCampaign: false, readInsights: false, sendConversion: false,
};
export const caps = (c: Partial<ChannelCaps>): ChannelCaps => ({ ...NONE, ...c });

/** Problems with an adapter's shape: a core adapter must implement every capability it claims, and nothing it doesn't. */
export function adapterProblems(a: ChannelAdapter): string[] {
  const out: string[] = [];
  if (!/^[a-z0-9_]{2,40}$/.test(a.id)) out.push(`${a.id}: bad id`);
  if (a.status !== "core") return out;
  for (const [cap, method] of Object.entries(CAP_METHOD) as Array<[keyof typeof CAP_METHOD, keyof ChannelAdapter]>) {
    const on = cap === "deliver" ? a.caps.deliver.length > 0 : a.caps[cap] === true;
    const has = typeof a[method] === "function";
    if (on && !has) out.push(`${a.id}: claims ${cap} but has no ${String(method)}()`);
    if (!on && has) out.push(`${a.id}: has ${String(method)}() but doesn't claim ${cap}`);
  }
  return out;
}

const REGISTRY = new Map<string, ChannelAdapter>();

export function registerAdapter(a: ChannelAdapter): void {
  const problems = adapterProblems(a);
  if (problems.length) throw new Error(`channel adapter: ${problems.join("; ")}`);
  REGISTRY.set(a.id, a);
}
export function getAdapter(id: string): ChannelAdapter | undefined {
  return REGISTRY.get(id);
}
export function listAdapters(): ChannelAdapter[] {
  return [...REGISTRY.values()].sort((x, y) => x.id.localeCompare(y.id));
}
/** The channels with a capability (the recommendation and allocation views). */
export function adaptersWith(cap: Exclude<keyof ChannelCaps, "role">): ChannelAdapter[] {
  return listAdapters().filter((a) => (cap === "deliver" ? a.caps.deliver.length > 0 : a.caps[cap] === true));
}
