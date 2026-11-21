// The Exos MCP write tools (served by supabase/functions/exos-mcp; docs/mcp.md):
//
//   create_event_draft   a DRAFT event in the credential's organization
//   add_ticket_type      a ticket type on one of the organization's drafts
//   publish_event        makes a draft public (destructive: it goes on sale)
//
// Each runs the partner API's own SQL (exos_api_write's event.create /
// ticket_type.create / event.publish, mig 20261031110000), so the rules are the
// dashboard's and the REST API's: no business rule lives here. This file turns
// a tool's arguments into that one call and words the answers.
//
// Every write is two calls (mig 20261119130000). The first call (no
// confirm_token) changes nothing: it answers a preview of exactly what will be
// written and a confirm_token the server issued, bound by hash to the
// credential, the tool and the exact write, single use, 10 minutes. The second
// call repeats the same arguments plus that confirm_token. A bare flag would
// not do: text an assistant reads (an event description, a web page) could
// tell it to set one. Changed arguments burn the token. The org's MCP writes
// are capped per hour in SQL.
//
// Needs: an organizer credential (org API key, personal access token or OAuth
// token) holding events:write, narrowed to the user's live role. Pure
// TypeScript: the database is behind McpWriteData, so vitest imports it.

import { EXOS_FEE_BPS, FEE_FREE_MONTHS, FREE_TIER_MAX_CAPACITY } from '../platformFee.ts';
import { ToolError, str, type ToolContext, type ToolDefinition } from './protocol.ts';

/** The one exos_api_write call a tool makes: its action, target and args. */
export interface WriteExec {
  action: 'event.create' | 'ticket_type.create' | 'event.publish';
  target: string | null;
  args: Record<string, unknown>;
}

export type WriteOutcome =
  | { ok: true; write_id?: string; result: Record<string, unknown> }
  | { ok: false; error: string; message: string; code?: string; retry_after_seconds?: number };

export interface EventState {
  event: {
    id: string; name: string; status: string; starts_at: string | null; ends_at: string | null; timezone: string | null;
    currency: string; venue_name: string | null; total_tickets: number | null;
  };
  ticket_types: Array<{ id: string; name: string; price: number | string; capacity: number; sales_start: string | null; sales_end: string | null }>;
  blockers: Array<{ code: string; field: string | null; message: string }>;
}

export interface FeeOutcome {
  free_tier: boolean;
  max_capacity: number | null;
  bounded?: boolean | null;
  free_tier_max_capacity: number;
}

export interface OrgVenue {
  id: string;
  name: string;
  address: Record<string, unknown> | null;
  timezone: string | null;
}

/** What the write tools need from the database. exos-mcp implements it; every method is held to ctx's org. */
export interface McpWriteData {
  /** Stores a confirmation for exactly `exec` (exos_mcp_confirm_issue) and returns the token. */
  issueConfirm(ctx: ToolContext, tool: WriteToolName, exec: WriteExec): Promise<{ token: string; expires_at: string }>;
  /** Spends the confirmation and writes (exos_mcp_write). */
  runWrite(ctx: ToolContext, tool: WriteToolName, confirmToken: string, exec: WriteExec): Promise<WriteOutcome>;
  orgVenue(orgId: string, venueId: string): Promise<OrgVenue | null>;
  eventState(orgId: string, eventId: string): Promise<EventState | null>;
  feeOutcome(orgId: string, eventId: string): Promise<FeeOutcome | null>;
}

export interface WriteToolOptions {
  /** Public SPA base, e.g. https://exos.example.com/bridge (no trailing slash). */
  appBase: string;
}

export const WRITE_TOOLS = {
  create_event_draft: { action: 'event.create', route: 'create-event' },
  add_ticket_type: { action: 'ticket_type.create', route: 'create-ticket-type' },
  publish_event: { action: 'event.publish', route: 'publish-event' },
} as const;
export type WriteToolName = keyof typeof WRITE_TOOLS;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** What exos-mcp hands out: exos_mcc_ + 43 base64url characters (32 random bytes). */
export const CONFIRM_TOKEN_RE = /^exos_mcc_[A-Za-z0-9_-]{43}$/;
const MAX_CAPACITY = 100_000;
const MAX_PRICE = 100_000;

const confirmTokenSchema = {
  type: 'string',
  description:
    'Leave this out on the first call: the answer is a preview and a confirm_token. Send it back only after the ' +
    'person has seen that preview and explicitly agreed, with the same arguments.',
  maxLength: 60,
} as const;

// ── Fee wording ────────────────────────────────────────────────────────────

const pct = (bps: number) => `${(bps / 100).toFixed(bps % 100 === 0 ? 0 : 1)}%`;
const STANDARD_FEE =
  `the standard Exos fee: ${pct(EXOS_FEE_BPS)} of each order, paid by the organizer (buyers pay no Exos fee; ` +
  `a new organization's first ${FEE_FREE_MONTHS} months are free)`;

/**
 * The fee outcome in plain words, from the SQL rule (exos_event_is_free_tier:
 * an event whose size, its capacity capped by what its ticket types add up
 * to, is at most the free tier's cutoff pays no Exos fee).
 */
export function feeStatement(f: FeeOutcome, capacity: number | null): string {
  const cutoff = Number(f.free_tier_max_capacity);
  if (!Number.isFinite(cutoff) || cutoff < 0) return `There is no free tier right now, so ${STANDARD_FEE} applies.`;
  const max = f.max_capacity === null || f.max_capacity === undefined ? null : Number(f.max_capacity);
  if (!f.free_tier) {
    return `This event can sell ${max ?? 'an unlimited number of'} tickets, over the free tier (${cutoff} or less), so ${STANDARD_FEE} applies.`;
  }
  if (capacity !== null && capacity > cutoff) {
    return `No Exos fee for now: its ticket types add up to ${max ?? 0} tickets, within the free tier (${cutoff} or less). ` +
      `Its capacity is ${capacity}, so once its ticket types add up to more than ${cutoff}, ${STANDARD_FEE} applies.`;
  }
  return `This event is on the free tier: no Exos fee (${cutoff} tickets or less).`;
}

/** Before the event exists: what the capacity means for the fee (FREE_TIER_MAX_CAPACITY, the SQL default). */
export function expectedFeeStatement(capacity: number | null, cutoff: number = FREE_TIER_MAX_CAPACITY): string {
  if (capacity === null) {
    return `The fee depends on the ticket types: ${cutoff} tickets or less is the free tier (no Exos fee); more pays ${STANDARD_FEE}.`;
  }
  if (capacity <= cutoff) return `This event will be on the free tier: no Exos fee (capacity ${capacity}; the free tier is ${cutoff} or less).`;
  return `With a capacity of ${capacity} (over the free tier's ${cutoff}), ${STANDARD_FEE} applies once its ticket types add up to more than ${cutoff}.`;
}

// ── Time ───────────────────────────────────────────────────────────────────

const LOCAL_RE = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?$/;
const OFFSET_RE = /(?:Z|[+-]\d{2}:?\d{2})$/i;

export function validTimeZone(tz: string): boolean {
  if (!/^[A-Za-z_]+(?:\/[A-Za-z0-9_+-]+){0,2}$/.test(tz) && tz !== 'UTC') return false;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/** The zone's offset from UTC (minutes) at instant `ms`. */
function offsetMinutes(ms: number, tz: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(new Date(ms));
  const n = (t: string) => Number(parts.find((p) => p.type === t)?.value);
  const asUtc = Date.UTC(n('year'), n('month') - 1, n('day'), n('hour'), n('minute'), n('second'));
  return Math.round((asUtc - Math.floor(ms / 1000) * 1000) / 60000);
}

/**
 * A wall-clock time in `tz` as a UTC ISO string. A time with an offset (or Z)
 * is taken as given. A local time that doesn't exist (skipped by a DST change)
 * is refused; one that happens twice takes the first.
 */
export function zonedToUtc(value: string, tz: string, field: string): string {
  const v = value.trim();
  if (OFFSET_RE.test(v)) {
    const t = Date.parse(v);
    if (Number.isNaN(t)) throw new ToolError(`${field} must be a date and time, e.g. 2027-01-15T20:00`);
    return new Date(t).toISOString();
  }
  const m = LOCAL_RE.exec(v);
  if (!m) throw new ToolError(`${field} must be a local date and time like 2027-01-15T20:00 (in timezone), or ISO 8601 with an offset`);
  const [y, mo, d, h, mi, s] = [m[1], m[2], m[3], m[4], m[5], m[6] ?? '0'].map(Number);
  const wall = Date.UTC(y, mo - 1, d, h, mi, s);
  const check = new Date(wall);
  if (check.getUTCMonth() !== mo - 1 || check.getUTCDate() !== d || h > 23 || mi > 59 || s > 59) {
    throw new ToolError(`${field} is not a real date and time`);
  }
  // Try the offsets around the wall time; keep the earliest that maps back to it.
  const candidates = [offsetMinutes(wall - 86_400_000, tz), offsetMinutes(wall, tz), offsetMinutes(wall + 86_400_000, tz)];
  const hits = [...new Set(candidates)].map((off) => wall - off * 60_000).filter((ms) => ms + offsetMinutes(ms, tz) * 60_000 === wall);
  if (hits.length === 0) throw new ToolError(`${field} doesn't exist in ${tz} (the clocks skip that hour)`);
  return new Date(Math.min(...hits)).toISOString();
}

// ── Argument readers ─────────────────────────────────────────────────────────

function wholeNumber(args: Record<string, unknown>, key: string, min: number, max: number, required = false): number | null {
  const v = args[key];
  if (v === undefined || v === null || v === '') {
    if (required) throw new ToolError(`${key} is required`);
    return null;
  }
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isInteger(n) || n < min || n > max) throw new ToolError(`${key} must be a whole number from ${min} to ${max}`);
  return n;
}

function money(args: Record<string, unknown>, key: string): number {
  const v = args[key];
  const n = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  if (!Number.isFinite(n) || n < 0 || n > MAX_PRICE || Math.round(n * 100) / 100 !== n) {
    throw new ToolError(`${key} must be an amount from 0 to ${MAX_PRICE} with at most 2 decimals (0 is free)`);
  }
  return n;
}

/** An https image URL: no credentials, a real host, at most 1000 characters (the tables' image rule). */
export function imageUrl(raw: string | undefined): string | null {
  if (raw === undefined) return null;
  if (raw.length > 1000) throw new ToolError('image_url is too long (max 1000)');
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    throw new ToolError('image_url must be a full https:// URL');
  }
  if (u.protocol !== 'https:' || u.username || u.password || !/\.[a-z]{2,}$/i.test(u.hostname)) {
    throw new ToolError('image_url must be an https:// URL on a public host, without a username or password');
  }
  return u.toString();
}

function eventId(args: Record<string, unknown>): string {
  const id = str(args, 'event_id', { required: true, max: 36 })!;
  if (!UUID_RE.test(id)) throw new ToolError('event_id must be an Exos event id (from create_event_draft or my_events)');
  return id;
}

function confirmToken(args: Record<string, unknown>): string | undefined {
  const t = str(args, 'confirm_token', { max: 60 });
  if (t !== undefined && !CONFIRM_TOKEN_RE.test(t)) {
    throw new ToolError('confirm_token is not one this server issued; call the tool again without it for a new preview');
  }
  return t;
}

function needCredential(ctx: ToolContext): string {
  if (!ctx.orgId || !ctx.credKind || !ctx.credId) throw new ToolError('this tool needs an Exos organizer credential with events:write');
  return ctx.orgId;
}

function editUrl(base: string, id: string): string {
  return `${base}/edit-event/${id}`;
}

function payoutsUrl(base: string, orgId: string): string {
  return `${base}/orgs/${orgId}/payouts`;
}

/** The write refused or failed: what the assistant should tell the person. */
function outcomeError(out: WriteOutcome): never {
  const o = out as Extract<WriteOutcome, { ok: false }>;
  if (o.error === 'rate_limited') {
    throw new ToolError(`${o.message} (retry in about ${Math.ceil((o.retry_after_seconds ?? 60) / 60)} minutes)`);
  }
  if (o.error === 'write_failed') {
    const why = o.code === '42501' ? 'not allowed: ' : o.code === 'P0002' ? 'not found: ' : '';
    throw new ToolError(`nothing was changed; Exos refused the write (${why}${o.message})`);
  }
  throw new ToolError(o.message);
}

function confirmationAnswer(tool: WriteToolName, preview: Record<string, unknown>, issued: { token: string; expires_at: string }) {
  return {
    status: 'confirmation_required',
    preview,
    confirm_token: issued.token,
    expires_at: issued.expires_at,
    next_step:
      `Nothing has been changed yet. Show this preview to the person. Only if they explicitly agree, call ${tool} ` +
      'again with exactly the same arguments plus this confirm_token. If they want changes, call it again without ' +
      'a confirm_token for a new preview.',
  };
}

const WRITE_ANNOTATIONS = { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false } as const;

export function exosWriteTools(data: McpWriteData, opts: WriteToolOptions): ToolDefinition[] {
  const base = opts.appBase.replace(/\/+$/, '');

  // ── create_event_draft ───────────────────────────────────────────────────
  const create_event_draft: ToolDefinition = {
    name: 'create_event_draft',
    title: 'Create a draft event',
    requiresOrg: true,
    scope: 'events:write',
    description:
      "Create a DRAFT event in the organizer's Exos organization (never published by this tool). Two steps: the first " +
      'call returns a preview and a confirm_token; call again with the same arguments plus confirm_token once the ' +
      'person has agreed. Returns the dashboard edit link and whether the event is on the free tier (no Exos fee).',
    inputSchema: {
      type: 'object',
      properties: {
        title: { type: 'string', description: 'Event name', maxLength: 200 },
        starts_at: { type: 'string', description: 'Start: local time like 2027-01-15T20:00 (in timezone), or ISO 8601 with an offset' },
        ends_at: { type: 'string', description: 'End (optional), same format as starts_at' },
        timezone: { type: 'string', description: 'IANA time zone of the event, e.g. America/New_York', maxLength: 64 },
        venue_id: { type: 'string', description: "An existing venue of the organization (from Exos's venues); or give venue instead" },
        venue: {
          type: 'object',
          description: 'A venue by name and address (when there is no venue_id). Saved on the event; the map pin is placed from the address.',
          properties: {
            name: { type: 'string', maxLength: 100 },
            street: { type: 'string', maxLength: 200 },
            city: { type: 'string', maxLength: 100 },
            region: { type: 'string', description: 'State or region', maxLength: 100 },
            postal: { type: 'string', description: 'Postal / ZIP code', maxLength: 20 },
            country: { type: 'string', description: 'Country, e.g. US', maxLength: 60 },
          },
          required: ['name'],
          additionalProperties: false,
        },
        online: { type: 'boolean', description: 'An online event (no venue needed)', default: false },
        description: { type: 'string', description: 'What the event is (plain text)', maxLength: 5000 },
        capacity: { type: 'integer', minimum: 1, maximum: MAX_CAPACITY, description: 'Most tickets the event can sell overall. 150 or less is the free tier: no Exos fee.' },
        image_url: { type: 'string', description: 'Cover image, an https:// URL', maxLength: 1000 },
        confirm_token: confirmTokenSchema,
      },
      required: ['title', 'starts_at', 'timezone'],
      additionalProperties: false,
    },
    annotations: { title: 'Create a draft event', ...WRITE_ANNOTATIONS },
    handler: async (args, ctx) => {
      const orgId = needCredential(ctx);
      const token = confirmToken(args);
      const name = str(args, 'title', { required: true, max: 200 })!;
      const tz = str(args, 'timezone', { required: true, max: 64 })!;
      if (!validTimeZone(tz)) throw new ToolError('timezone must be an IANA time zone, e.g. America/New_York');
      const startsAt = zonedToUtc(str(args, 'starts_at', { required: true, max: 40 })!, tz, 'starts_at');
      const endsRaw = str(args, 'ends_at', { max: 40 });
      const endsAt = endsRaw === undefined ? null : zonedToUtc(endsRaw, tz, 'ends_at');
      if (endsAt && Date.parse(endsAt) <= Date.parse(startsAt)) throw new ToolError('ends_at must be after starts_at');
      const online = args.online === true;
      const capacity = wholeNumber(args, 'capacity', 1, MAX_CAPACITY);
      const description = str(args, 'description', { max: 5000 });
      const image = imageUrl(str(args, 'image_url', { max: 1000 }));

      const event: Record<string, unknown> = { name, starts_at: startsAt, timezone: tz };
      if (endsAt) event.ends_at = endsAt;
      if (description) event.description = description;
      if (capacity !== null) event.total_tickets = capacity;
      if (image) event.image_url = image;
      if (online) event.format = 'online';

      const venueId = str(args, 'venue_id', { max: 36 });
      const venueArg = args.venue;
      let venueLine: string | null = null;
      if (venueId !== undefined && venueArg !== undefined) throw new ToolError('give venue_id or venue, not both');
      if (venueId !== undefined) {
        if (!UUID_RE.test(venueId)) throw new ToolError('venue_id must be an Exos venue id');
        const v = await data.orgVenue(orgId, venueId);
        if (!v) throw new ToolError('no venue with that id in your organization');
        event.venue_name = v.name;
        if (v.address) event.venue_address = v.address;
        const city = typeof v.address?.city === 'string' ? v.address.city : null;
        if (city) event.venue_location = city;
        venueLine = [v.name, city].filter(Boolean).join(', ');
      } else if (venueArg !== undefined) {
        if (!venueArg || typeof venueArg !== 'object' || Array.isArray(venueArg)) throw new ToolError('venue must be an object');
        const va = venueArg as Record<string, unknown>;
        const vname = str(va, 'name', { required: true, max: 100 })!;
        const address: Record<string, string> = {};
        for (const [k, max] of [['street', 200], ['city', 100], ['region', 100], ['postal', 20], ['country', 60]] as const) {
          const val = str(va, k, { max });
          if (val) address[k] = val;
        }
        for (const k of Object.keys(va)) if (!['name', 'street', 'city', 'region', 'postal', 'country'].includes(k)) {
          throw new ToolError(`venue.${k} is not a venue field`);
        }
        event.venue_name = vname;
        if (Object.keys(address).length) event.venue_address = address;
        if (address.city) event.venue_location = [address.city, address.region].filter(Boolean).join(', ');
        venueLine = [vname, address.street, address.city, address.region, address.postal, address.country].filter(Boolean).join(', ');
      } else if (!online) {
        throw new ToolError('give venue_id, a venue (name and address) or online: true');
      }

      const exec: WriteExec = { action: 'event.create', target: null, args: { event } };
      if (!token) {
        const issued = await data.issueConfirm(ctx, 'create_event_draft', exec);
        return confirmationAnswer('create_event_draft', {
          action: 'Create a DRAFT event (not published, nothing goes on sale)',
          title: name,
          starts: `${startsAt} (${tz})`,
          ends: endsAt ? `${endsAt} (${tz})` : null,
          venue: online ? 'Online' : venueLine,
          capacity,
          description: description ?? null,
          image_url: image,
          fee: expectedFeeStatement(capacity),
        }, issued);
      }
      const out = await data.runWrite(ctx, 'create_event_draft', token, exec);
      if (!out.ok) outcomeError(out);
      const id = String(out.result.id ?? '');
      const fee = UUID_RE.test(id) ? await data.feeOutcome(orgId, id) : null;
      return {
        status: 'created',
        event_id: id,
        event_status: 'draft',
        title: out.result.name ?? name,
        edit_url: editUrl(base, id),
        fee: fee ? feeStatement(fee, capacity) : expectedFeeStatement(capacity),
        free_tier: fee?.free_tier ?? null,
        publish_blockers: out.result.publish_blockers ?? [],
        next_steps: 'Add ticket types with add_ticket_type, then publish with publish_event (or finish in the dashboard: edit_url).',
      };
    },
  };

  // ── add_ticket_type ──────────────────────────────────────────────────────
  const add_ticket_type: ToolDefinition = {
    name: 'add_ticket_type',
    title: 'Add a ticket type',
    requiresOrg: true,
    scope: 'events:write',
    description:
      "Add a ticket type (name, price, quantity, optional sale window) to one of the organization's DRAFT events. " +
      'Two steps, like create_event_draft: preview first, then the same arguments plus confirm_token.',
    inputSchema: {
      type: 'object',
      properties: {
        event_id: { type: 'string', description: 'A draft event id (from create_event_draft or my_events)' },
        name: { type: 'string', description: 'e.g. General admission', maxLength: 100 },
        price: { type: 'number', minimum: 0, maximum: MAX_PRICE, description: 'Ticket price in the event currency (0 = free / RSVP)' },
        quantity: { type: 'integer', minimum: 1, maximum: MAX_CAPACITY, description: 'How many of this ticket type can be sold' },
        sales_start: { type: 'string', description: 'When sales open (optional; local time in the event time zone, or ISO 8601 with an offset)' },
        sales_end: { type: 'string', description: 'When sales close (optional)' },
        confirm_token: confirmTokenSchema,
      },
      required: ['event_id', 'name', 'price', 'quantity'],
      additionalProperties: false,
    },
    annotations: { title: 'Add a ticket type', ...WRITE_ANNOTATIONS },
    handler: async (args, ctx) => {
      const orgId = needCredential(ctx);
      const token = confirmToken(args);
      const id = eventId(args);
      const name = str(args, 'name', { required: true, max: 100 })!;
      const price = money(args, 'price');
      const quantity = wholeNumber(args, 'quantity', 1, MAX_CAPACITY, true)!;
      const st = await data.eventState(orgId, id);
      if (!st) throw new ToolError('no event with that id in your organization');
      if (st.event.status !== 'draft') {
        throw new ToolError(`add_ticket_type works on drafts; this event is ${st.event.status}. Change its ticket types in the dashboard: ${editUrl(base, id)}`);
      }
      const tz = st.event.timezone || 'UTC';
      const ss = str(args, 'sales_start', { max: 40 });
      const se = str(args, 'sales_end', { max: 40 });
      const salesStart = ss === undefined ? null : zonedToUtc(ss, tz, 'sales_start');
      const salesEnd = se === undefined ? null : zonedToUtc(se, tz, 'sales_end');
      if (salesStart && salesEnd && Date.parse(salesEnd) <= Date.parse(salesStart)) throw new ToolError('sales_end must be after sales_start');
      const tier: Record<string, unknown> = { name, price, capacity: quantity };
      if (salesStart) tier.sales_start = salesStart;
      if (salesEnd) tier.sales_end = salesEnd;
      const exec: WriteExec = { action: 'ticket_type.create', target: id, args: { ticket_type: tier } };
      if (!token) {
        const issued = await data.issueConfirm(ctx, 'add_ticket_type', exec);
        return confirmationAnswer('add_ticket_type', {
          action: 'Add a ticket type to a draft event',
          event: st.event.name,
          ticket_type: name,
          price: price === 0 ? 'free' : `${price.toFixed(2)} ${st.event.currency}`,
          quantity,
          sales_start: salesStart ? `${salesStart} (${tz})` : 'when the event is published',
          sales_end: salesEnd ? `${salesEnd} (${tz})` : 'when the event starts',
          existing_ticket_types: st.ticket_types.map((t) => `${t.name} (${t.capacity})`),
          ...(price > 0 ? { note: 'Paid tickets need Stripe Connect finished before the event can be published.' } : {}),
        }, issued);
      }
      const out = await data.runWrite(ctx, 'add_ticket_type', token, exec);
      if (!out.ok) outcomeError(out);
      const fee = await data.feeOutcome(orgId, id);
      return {
        status: 'added',
        event_id: id,
        ticket_type: {
          id: out.result.id ?? null, name: out.result.name ?? name, price: out.result.price ?? price,
          quantity: out.result.capacity ?? quantity, sales_start: out.result.sales_start ?? salesStart, sales_end: out.result.sales_end ?? salesEnd,
        },
        fee: fee ? feeStatement(fee, st.event.total_tickets) : null,
        edit_url: editUrl(base, id),
      };
    },
  };

  // ── publish_event ────────────────────────────────────────────────────────
  const publish_event: ToolDefinition = {
    name: 'publish_event',
    title: 'Publish an event',
    requiresOrg: true,
    scope: 'events:write',
    description:
      'Publish one of the organization\'s draft events: it becomes public (search, its event page, listing feeds) and ' +
      'tickets go on sale per their sale windows. Two steps: the first call returns a summary and a confirm_token; ' +
      'publish only after the person explicitly confirms that summary. Paid tickets need Stripe Connect finished; ' +
      'free / RSVP events don\'t.',
    inputSchema: {
      type: 'object',
      properties: {
        event_id: { type: 'string', description: 'A draft event id (from create_event_draft or my_events)' },
        confirm_token: confirmTokenSchema,
      },
      required: ['event_id'],
      additionalProperties: false,
    },
    annotations: { title: 'Publish an event', readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
    handler: async (args, ctx) => {
      const orgId = needCredential(ctx);
      const token = confirmToken(args);
      const id = eventId(args);
      const st = await data.eventState(orgId, id);
      if (!st) throw new ToolError('no event with that id in your organization');
      if (st.event.status === 'published') return { status: 'already_published', event_id: id, edit_url: editUrl(base, id) };
      if (st.event.status !== 'draft') throw new ToolError(`this event is ${st.event.status} and can't be published`);
      if (st.blockers.length) refuseBlockers(st.blockers, base, orgId, id);
      const exec: WriteExec = { action: 'event.publish', target: id, args: {} };
      if (!token) {
        const fee = await data.feeOutcome(orgId, id);
        const issued = await data.issueConfirm(ctx, 'publish_event', exec);
        return confirmationAnswer('publish_event', {
          action: 'PUBLISH this event: it becomes public and tickets go on sale',
          title: st.event.name,
          starts: st.event.starts_at ? `${st.event.starts_at} (${st.event.timezone ?? 'UTC'})` : null,
          venue: st.event.venue_name,
          ticket_types: st.ticket_types.map((t) => ({
            name: t.name, price: Number(t.price) === 0 ? 'free' : `${Number(t.price).toFixed(2)} ${st.event.currency}`, quantity: t.capacity,
          })),
          fee: fee ? feeStatement(fee, st.event.total_tickets) : null,
          warning: 'Once published, people can find the event and buy tickets. Unpublishing later is done in the dashboard.',
        }, issued);
      }
      const out = await data.runWrite(ctx, 'publish_event', token, exec);
      if (!out.ok) outcomeError(out);
      if (out.result.published !== true) {
        const b = Array.isArray(out.result.blockers) ? out.result.blockers as EventState['blockers'] : [];
        refuseBlockers(b, base, orgId, id);
      }
      return { status: 'published', event_id: id, event_url: `${base}/event/${id}`, edit_url: editUrl(base, id) };
    },
  };

  return [create_event_draft, add_ticket_type, publish_event];
}

/** What stops publishing, with the Stripe onboarding link when that's one of them. */
function refuseBlockers(blockers: EventState['blockers'], base: string, orgId: string, id: string): never {
  const stripe = blockers.some((b) => b.code === 'stripe_not_connected');
  const list = blockers.map((b) => b.message).join(' ');
  throw new ToolError(
    `The event can't be published yet: ${list}` +
      (stripe
        ? ` Paid tickets need Stripe Connect: finish onboarding at ${payoutsUrl(base, orgId)} (free / RSVP events can publish without it).`
        : '') +
      ` Fix it in the dashboard (${editUrl(base, id)}) or with add_ticket_type, then try again.`,
  );
}
