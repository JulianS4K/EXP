// Sales by channel (mig 20261029120000): reading the document that
// exos_event_channel_report / exos_org_channel_report return and the weekly
// org-channel-report mail carries. One reader for the mail renderer
// (mail-templates.ts) and the SPA (ChannelsPanel, OrgChannelReport), so the
// email and the screen show the same numbers. No imports: Deno and vitest
// both load it.
//
// Each channel carries `week` and `to_date` as
// [tickets, gross_cents, fee_cents, exos_fee_cents, net_cents]; a NULL is a
// figure the channel didn't report (Eventbrite and Luma don't send prices or
// fees), never zero. `week` is NULL for a channel counted without dates.

export type ChannelKind = "sale" | "comp" | "attendee";
export type FeeStatus = "reported" | "not_reported" | "none";

export interface Figures {
  tickets: number;
  grossCents: number | null;
  feeCents: number | null;
  exosFeeCents: number | null;
  netCents: number | null;
}

export interface ChannelRow {
  channel: string;
  label: string;
  group: string;
  kind: ChannelKind;
  currency: string;
  fees: FeeStatus;
  dated: boolean;
  week: Figures | null;
  toDate: Figures;
}

export interface Totals {
  currency: string;
  tickets: number;
  grossCents: number;
  feeCents: number;
  exosFeeCents: number;
  netCents: number;
  /** Tickets in channels that reported no gross / no net (left out of those sums). */
  grossNotReported: number;
  netNotReported: number;
}

export interface EventChannels {
  id: string;
  name: string;
  startsAt: string | null;
  timezone: string | null;
  currency: string;
  capacity: number;
  sales: ChannelRow[];
  comps: ChannelRow[];
  attendees: ChannelRow[];
  totals: { week: Totals[]; toDate: Totals[] };
}

export interface ChannelReport {
  orgId: string | null;
  orgName: string;
  from: string | null;
  to: string | null;
  isoWeek: string | null;
  events: EventChannels[];
  moreEvents: number;
  totals: { week: Totals[]; toDate: Totals[] };
}

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const n = (v: unknown): number | null => {
  const x = typeof v === "string" && v.trim() !== "" ? Number(v) : v;
  return typeof x === "number" && Number.isFinite(x) ? x : null;
};
const s = (v: unknown, fallback = ""): string => (typeof v === "string" ? v : fallback);

/** [tickets, gross, fee, exos, net] → Figures; null when not an array. */
export function parseFigures(v: unknown): Figures | null {
  if (!Array.isArray(v)) return null;
  return {
    tickets: Math.max(0, Math.round(n(v[0]) ?? 0)),
    grossCents: n(v[1]),
    feeCents: n(v[2]),
    exosFeeCents: n(v[3]),
    netCents: n(v[4]),
  };
}

const KINDS = new Set(["sale", "comp", "attendee"]);
const FEES = new Set(["reported", "not_reported", "none"]);

export function parseChannel(v: unknown): ChannelRow | null {
  if (!isObj(v)) return null;
  const toDate = parseFigures(v.to_date);
  const channel = s(v.channel);
  if (!toDate || !channel) return null;
  const kind = KINDS.has(s(v.kind)) ? (s(v.kind) as ChannelKind) : "sale";
  return {
    channel,
    label: s(v.label, channel),
    group: s(v.group, "exos"),
    kind,
    currency: s(v.currency, "usd").toLowerCase(),
    fees: FEES.has(s(v.fees)) ? (s(v.fees) as FeeStatus) : "not_reported",
    dated: v.dated !== false,
    week: v.dated === false ? null : parseFigures(v.week),
    toDate,
  };
}

export function parseTotals(v: unknown): Totals[] {
  if (!Array.isArray(v)) return [];
  return v.filter(isObj).map((t) => ({
    currency: s(t.currency, "usd").toLowerCase(),
    tickets: n(t.tickets) ?? 0,
    grossCents: n(t.gross_cents) ?? 0,
    feeCents: n(t.fee_cents) ?? 0,
    exosFeeCents: n(t.exos_fee_cents) ?? 0,
    netCents: n(t.net_cents) ?? 0,
    grossNotReported: n(t.gross_not_reported) ?? 0,
    netNotReported: n(t.net_not_reported) ?? 0,
  }));
}

function parsePeriods(v: unknown): { week: Totals[]; toDate: Totals[] } {
  const o = isObj(v) ? v : {};
  return { week: parseTotals(o.week), toDate: parseTotals(o.to_date) };
}

export function parseEventChannels(v: unknown): EventChannels | null {
  if (!isObj(v) || typeof v.id !== "string") return null;
  const rows = (Array.isArray(v.channels) ? v.channels : []).map(parseChannel).filter((r): r is ChannelRow => r !== null);
  return {
    id: v.id,
    name: s(v.name, "Event"),
    startsAt: typeof v.starts_at === "string" ? v.starts_at : null,
    timezone: typeof v.timezone === "string" ? v.timezone : null,
    currency: s(v.currency, "usd").toLowerCase(),
    capacity: n(v.capacity) ?? 0,
    sales: rows.filter((r) => r.kind === "sale"),
    comps: rows.filter((r) => r.kind === "comp"),
    attendees: rows.filter((r) => r.kind === "attendee"),
    totals: parsePeriods(v.totals),
  };
}

export function parseChannelReport(v: unknown): ChannelReport | null {
  if (!isObj(v)) return null;
  const org = isObj(v.org) ? v.org : {};
  return {
    orgId: typeof org.id === "string" ? org.id : null,
    orgName: s(org.name, "your organization"),
    from: typeof v.from === "string" ? v.from : null,
    to: typeof v.to === "string" ? v.to : null,
    isoWeek: typeof v.iso_week === "string" ? v.iso_week : null,
    events: (Array.isArray(v.events) ? v.events : []).map(parseEventChannels).filter((e): e is EventChannels => e !== null),
    moreEvents: n(v.more_events) ?? 0,
    totals: parsePeriods(v.totals),
  };
}

/** Money for display; "not reported" for a figure the channel didn't send. */
export function money(cents: number | null | undefined, currency: string): string {
  if (cents === null || cents === undefined || !Number.isFinite(cents)) return "not reported";
  const cur = (currency || "usd").toUpperCase();
  try {
    return new Intl.NumberFormat("en-US", { style: "currency", currency: cur }).format(Math.round(cents) / 100);
  } catch {
    return `${(Math.round(cents) / 100).toFixed(2)} ${cur}`;
  }
}

/** The channel-fee cell: "none" when the channel charges none, else the amount or "not reported". */
export function feeText(f: Figures | null, status: FeeStatus, currency: string): string {
  if (!f) return "";
  if (status === "none" && (f.feeCents === 0 || f.feeCents === null)) return "none";
  return money(f.feeCents, currency);
}

export const plural = (k: number, one: string, many = `${one}s`): string => `${k} ${k === 1 ? one : many}`;

/** "12 tickets, $340.00 gross, $310.20 net" per currency, noting what wasn't reported. */
export function totalsText(totals: Totals[]): string {
  if (totals.length === 0) return "no tickets";
  return totals.map((t) => {
    const parts = [plural(t.tickets, "ticket")];
    if (t.tickets > t.grossNotReported) parts.push(`${money(t.grossCents, t.currency)} gross`);
    if (t.tickets > t.netNotReported) parts.push(`${money(t.netCents, t.currency)} net`);
    return parts.join(", ");
  }).join(" + ");
}

/** The caveat under a total, or "" when every figure was reported. */
export function notReportedNote(totals: Totals[]): string {
  const g = totals.reduce((k, t) => k + t.grossNotReported, 0);
  const net = totals.reduce((k, t) => k + t.netNotReported, 0);
  if (g === 0 && net === 0) return "";
  const most = Math.max(g, net);
  return `${plural(most, "ticket")} came through channels that don't report ${g > 0 ? "prices or fees" : "fees"} to Exos, so ${most === 1 ? "it isn't" : "they aren't"} in the money totals.`;
}

export const sumTickets = (totals: Totals[]): number => totals.reduce((k, t) => k + t.tickets, 0);

/** Comps / imported attendees for a period, one line ("4 comps, 2 imported"). */
export function sideCounts(e: EventChannels, period: "week" | "toDate"): { comps: number; attendees: number } {
  const count = (rows: ChannelRow[]) => rows.reduce((k, r) => k + ((period === "week" ? r.week : r.toDate)?.tickets ?? 0), 0);
  return { comps: count(e.comps), attendees: count(e.attendees) };
}

/** "Oct 26 – Nov 1" for [from, to) in UTC (the report week). */
export function weekLabel(from: string | null, to: string | null): string {
  if (!from || !to) return "";
  const a = new Date(from);
  const b = new Date(new Date(to).getTime() - 86_400_000);
  if (Number.isNaN(a.getTime()) || Number.isNaN(b.getTime())) return "";
  const f = (d: Date) => new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", timeZone: "UTC" }).format(d);
  return `${f(a)} – ${f(b)}`;
}
