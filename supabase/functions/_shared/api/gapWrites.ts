// Organization routes the Opendate gap list still pointed at the dashboard
// (claude/exos-fan-api, mig 20261105110000): event series writes, an event's
// fee rules (Opendate organizer_fee_components), API keys, releasing orphaned
// seats, imported attendees in bulk, membership scans and gifts, gift card
// issue and quotes, offline donations. exos-api/gapWrites.ts runs them; each
// write is one exos_api_gap_write call (the key's org, its scope again, run
// as the member who created the key, Idempotency-Key, logged), so it does
// what the same action in the dashboard does.
//
// This file maps a route to its action and target and shapes the body; it
// holds no business rule. Pure TypeScript, imported by vitest
// (src/lib/apiGapWrites.test.ts).

export class GapBodyError extends Error {}

export interface GapAction {
  action: string;
  /** The path param that is the action's target. */
  target?: string;
}

/** Route id -> exos_api_gap_write action. */
export const GAP_ACTIONS: Readonly<Record<string, GapAction>> = {
  'create-api-key': { action: 'api_key.create' },
  'revoke-api-key': { action: 'api_key.revoke', target: 'id' },
  'create-series': { action: 'series.create' },
  'update-series': { action: 'series.update', target: 'id' },
  'cancel-series': { action: 'series.cancel', target: 'id' },
  'delete-series': { action: 'series.delete', target: 'id' },
  'attach-series-event': { action: 'series.attach', target: 'id' },
  'detach-series-event': { action: 'series.detach', target: 'id' },
  'generate-series-dates': { action: 'series.generate', target: 'id' },
  'cancel-series-date': { action: 'series.cancel_date', target: 'id' },
  'create-event-fee-rule': { action: 'fee_rule.create', target: 'id' },
  'update-event-fee-rule': { action: 'fee_rule.update', target: 'id' },
  'delete-event-fee-rule': { action: 'fee_rule.delete', target: 'id' },
  'release-orphan-seats': { action: 'seats.release_orphans', target: 'id' },
  'import-migrated-attendees': { action: 'migrated_attendees.bulk' },
  'create-membership-scan': { action: 'membership.scan' },
  'gift-membership': { action: 'membership.gift', target: 'id' },
  'cancel-membership-gift': { action: 'membership.cancel_gift', target: 'id' },
  'issue-gift-card': { action: 'gift_card.issue', target: 'id' },
  'create-offline-donation': { action: 'donation.offline', target: 'id' },
  'create-donation': { action: 'donation.offline' },
};

/** Routes answered 201 Created. */
export const GAP_CREATED: ReadonlySet<string> = new Set([
  'create-api-key', 'create-series', 'create-event-fee-rule', 'gift-membership', 'issue-gift-card',
  'create-offline-donation', 'create-donation', 'import-migrated-attendees',
]);

/** The scope each action needs: must equal _exos_api_gap_action_scope (apiGapWrites.test.ts). */
export const GAP_ACTION_SCOPE: Readonly<Record<string, string>> = {
  'series.create': 'events:write', 'series.update': 'events:write', 'series.cancel': 'events:write',
  'series.delete': 'events:write', 'series.attach': 'events:write', 'series.detach': 'events:write',
  'series.generate': 'events:write', 'series.cancel_date': 'events:write',
  'fee_rule.create': 'events:write', 'fee_rule.update': 'events:write', 'fee_rule.delete': 'events:write',
  'membership.gift': 'commerce:write', 'membership.cancel_gift': 'commerce:write',
  'gift_card.issue': 'commerce:write', 'donation.offline': 'commerce:write',
  'membership.scan': 'checkin:write',
  'seats.release_orphans': 'tickets:write', 'migrated_attendees.bulk': 'tickets:write',
  'api_key.create': 'org:admin', 'api_key.revoke': 'org:admin',
};

/**
 * The dashboard roles the key's creator must hold NOW for each action (the
 * sibling routes' actor(c, [...]); must equal _exos_api_gap_action_roles in
 * the migration, apiGapWrites.test.ts). The dashboard RPC checks again.
 */
export const GAP_ACTION_ROLES: Readonly<Record<string, readonly string[]>> = Object.fromEntries(
  Object.keys(GAP_ACTION_SCOPE).map((a) => [a,
    a.startsWith('api_key.') ? ['owner']
      : a === 'membership.scan' ? ['owner', 'manager', 'scanner']
        : a === 'donation.offline' ? ['owner', 'manager', 'finance']
          : ['owner', 'manager']]),
);

/** POST /memberships/:id/cancel (exos_api_commerce_write's membership.update) acts as an owner or manager. */
export const CANCEL_MEMBERSHIP_ROLES: readonly string[] = ['owner', 'manager'];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function unwrap(body: Record<string, unknown>, ...wrappers: string[]): Record<string, unknown> {
  for (const w of wrappers) {
    const v = body[w];
    if (v && typeof v === 'object' && !Array.isArray(v)) return v as Record<string, unknown>;
  }
  return body;
}

function intOf(v: unknown, name: string, min: number, max: number): number {
  const n = typeof v === 'string' && /^-?\d{1,10}$/.test(v.trim()) ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isInteger(n) || n < min || n > max) {
    throw new GapBodyError(`${name} must be a whole number from ${min} to ${max}`);
  }
  return n;
}

function uuidOf(v: unknown, name: string): string {
  if (typeof v !== 'string' || !UUID_RE.test(v)) throw new GapBodyError(`${name} must be a UUID`);
  return v;
}

function pick(b: Record<string, unknown>, keys: readonly string[]): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k of keys) if (b[k] !== undefined) out[k] = b[k];
  return out;
}

const FEE_RULE_FIELDS = ['name', 'recipient', 'kind', 'calc', 'percent', 'amount_cents', 'cap_cents', 'per', 'taxable',
  'applies_to_addons', 'tier_ids', 'active', 'sort_order'] as const;

/**
 * An Opendate organizer fee component as an Exos fee rule. Opendate sends
 * name, amount (dollars or a percent), calculation (`percent` / `flat`) and
 * whether it is passed to the buyer; Exos stores calc percent / fixed, cents,
 * kind passed_on / absorbed.
 */
export function feeRuleFields(raw: Record<string, unknown>, mode: 'create' | 'update'): Record<string, unknown> {
  const b = unwrap(raw, 'organizer_fee_component', 'fee_rule');
  const out = pick(b, FEE_RULE_FIELDS);
  const calc = b.calculation ?? b.fee_type;
  if (out.calc === undefined && calc !== undefined) out.calc = calc === 'flat' || calc === 'fixed' ? 'fixed' : 'percent';
  if (b.passed_to_buyer !== undefined && out.kind === undefined) out.kind = b.passed_to_buyer === true || b.passed_to_buyer === 'true' ? 'passed_on' : 'absorbed';
  if (b.amount !== undefined) {
    if (out.calc === 'fixed') {
      if (out.amount_cents === undefined) out.amount_cents = Math.round(Number(b.amount) * 100);
    } else if (out.percent === undefined) out.percent = Number(b.amount);
  }
  if (out.amount_cents !== undefined && out.amount_cents !== null) out.amount_cents = intOf(out.amount_cents, 'amount_cents', 0, 10_000_000);
  if (out.cap_cents !== undefined && out.cap_cents !== null) out.cap_cents = intOf(out.cap_cents, 'cap_cents', 0, 10_000_000);
  if (out.percent !== undefined && out.percent !== null) {
    const p = Number(out.percent);
    if (!Number.isFinite(p) || p < 0 || p > 100) throw new GapBodyError('percent must be from 0 to 100');
    out.percent = p;
  }
  if (out.calc === 'fixed') out.percent = null;
  if (out.calc === 'percent') out.amount_cents = null;
  if (out.tier_ids !== undefined && out.tier_ids !== null) {
    if (!Array.isArray(out.tier_ids) || out.tier_ids.length < 1 || out.tier_ids.length > 100) {
      throw new GapBodyError('tier_ids must be a list of 1 to 100 ticket type ids (or null for every type)');
    }
    for (const t of out.tier_ids) uuidOf(t, 'tier_ids');
  }
  const unknown = Object.keys(b).filter((k) => !(FEE_RULE_FIELDS as readonly string[]).includes(k)
    && !['calculation', 'fee_type', 'passed_to_buyer', 'amount'].includes(k));
  if (unknown.length) throw new GapBodyError(`unknown or read-only field: ${unknown[0].slice(0, 40)}`);
  if (mode === 'create' && (typeof out.name !== 'string' || !out.name.trim())) throw new GapBodyError('name is required');
  if (mode === 'update' && Object.keys(out).length === 0) throw new GapBodyError('send at least one field to change');
  return out;
}

/** The args of a gap write from its route and (already capped) body. */
export function gapArgs(routeId: string, raw: Record<string, unknown>, params: Record<string, string>): Record<string, unknown> {
  switch (routeId) {
    case 'create-api-key': {
      const b = unwrap(raw, 'api_key');
      const scopes = typeof b.scopes === 'string' ? b.scopes.split(/[\s,]+/).filter(Boolean) : b.scopes;
      if (!Array.isArray(scopes) || scopes.length < 1 || scopes.length > 40 || scopes.some((s) => typeof s !== 'string')) {
        throw new GapBodyError('scopes must be a list of scope names');
      }
      const name = typeof b.name === 'string' ? b.name.trim().slice(0, 80) : null;
      return { name, scopes };
    }
    case 'create-series': {
      const b = unwrap(raw, 'event_series', 'series');
      return { template_event_id: uuidOf(b.template_event_id ?? b.event_id, 'template_event_id'), name: b.name, rule: b.rule, description: b.description ?? null };
    }
    case 'update-series':
      return pick(unwrap(raw, 'event_series', 'series'), ['name', 'description', 'image_url', 'rule', 'status']);
    case 'cancel-series': {
      const b = unwrap(raw, 'event_series', 'series');
      const scope = b.scope ?? 'series_only';
      if (!['series_only', 'all_shows', 'selected'].includes(String(scope))) {
        throw new GapBodyError('scope must be series_only, all_shows or selected');
      }
      const out: Record<string, unknown> = { scope, reason: typeof b.reason === 'string' ? b.reason.slice(0, 500) : null };
      if (b.event_ids !== undefined) {
        if (!Array.isArray(b.event_ids)) throw new GapBodyError('event_ids must be a list of event ids');
        out.event_ids = b.event_ids.map((x) => uuidOf(x, 'event_ids'));
      }
      return out;
    }
    case 'attach-series-event': {
      const b = unwrap(raw, 'event_series_event');
      return { event_id: uuidOf(b.event_id ?? b.confirm_id ?? b.calendar_event_id, 'event_id') };
    }
    case 'detach-series-event':
      return { event_id: uuidOf(params.eid, 'event_id') };
    case 'generate-series-dates': {
      const dates = raw.dates;
      if (!Array.isArray(dates) || dates.length < 1 || dates.length > 366) throw new GapBodyError('dates must be a list of 1 to 366 { date, time }');
      return { dates };
    }
    case 'cancel-series-date': {
      if (typeof raw.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(raw.date)) throw new GapBodyError('date must be YYYY-MM-DD');
      return { date: raw.date, reason: typeof raw.reason === 'string' ? raw.reason.slice(0, 500) : null };
    }
    case 'create-event-fee-rule':
      return feeRuleFields(raw, 'create');
    case 'update-event-fee-rule':
      return { ...feeRuleFields(raw, 'update'), rule_id: uuidOf(params.rid, 'rule id') };
    case 'delete-event-fee-rule':
      return { rule_id: uuidOf(params.rid, 'rule id') };
    case 'release-orphan-seats': {
      const ids = raw.seat_ids;
      if (!Array.isArray(ids) || ids.length < 1 || ids.length > 500 || ids.some((s) => typeof s !== 'string' || !s || s.length > 100)) {
        throw new GapBodyError('seat_ids must be a list of 1 to 500 seat ids');
      }
      return { seat_ids: ids };
    }
    case 'import-migrated-attendees': {
      const rows = raw.rows ?? raw.migrated_attendees ?? raw.attendees;
      if (!Array.isArray(rows) || rows.length < 1 || rows.length > 5000) throw new GapBodyError('rows must be a list of 1 to 5000 attendees');
      return { list_id: uuidOf(raw.list_id ?? raw.guest_list_id, 'list_id'), rows };
    }
    case 'create-membership-scan': {
      const b = unwrap(raw, 'membership_scan');
      return { membership_id: uuidOf(b.membership_id ?? b.membership_token, 'membership_id') };
    }
    case 'gift-membership': {
      const b = unwrap(raw, 'gift', 'membership');
      const to = b.to_email ?? b.recipient_email ?? b.email;
      if (typeof to !== 'string' || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to.trim())) throw new GapBodyError('to_email must be an email address');
      return { to_email: to.trim(), from_name: b.from_name ?? null, message: b.message ?? null };
    }
    case 'issue-gift-card': {
      const b = unwrap(raw, 'gift_card_order', 'gift_card');
      const out: Record<string, unknown> = pick(b, ['recipient_email', 'recipient_name', 'message', 'purchaser_email',
        'external_id', 'currency']);
      out.payment_method = b.payment_method ?? 'comp';
      if (!['cash', 'check', 'comp', 'card'].includes(String(out.payment_method))) {
        throw new GapBodyError('payment_method must be cash, check, comp or card');
      }
      out.amount_cents = intOf(b.amount_cents ?? (b.amount !== undefined ? Math.round(Number(b.amount) * 100) : undefined),
        'amount_cents', 100, 100_000_000);
      return out;
    }
    case 'create-offline-donation':
    case 'create-donation': {
      const b = unwrap(raw, 'donation', 'offline_donation');
      const out: Record<string, unknown> = pick(b, ['donor_name', 'donor_email', 'note', 'external_id']);
      out.amount_cents = intOf(b.amount_cents ?? (b.amount !== undefined ? Math.round(Number(b.amount) * 100) : undefined),
        'amount_cents', 1, 100_000_000);
      out.method = b.method ?? b.payment_method ?? 'other';
      if (!['cash', 'check', 'other'].includes(String(out.method))) throw new GapBodyError('method must be cash, check or other');
      out.anonymous = b.anonymous === true || b.anonymous === 'true';
      if (routeId === 'create-donation') out.campaign_id = uuidOf(b.campaign_id ?? b.giving_campaign_id, 'campaign_id');
      return out;
    }
  }
  return {};
}

/** The target of a gap write: a path param, or (POST /donations, /membership-scans) a body id. */
export function gapTarget(routeId: string, params: Record<string, string>, args: Record<string, unknown>): string | null {
  if (routeId === 'create-donation') return String(args.campaign_id);
  if (routeId === 'create-membership-scan') return String(args.membership_id);
  const spec = GAP_ACTIONS[routeId];
  return spec?.target ? params[spec.target] ?? null : null;
}

/**
 * Opendate's gift card quote: what a gift card of this product costs. Exos
 * products are a fixed list of amounts or an open range, and the price is the
 * amount (no fee is added on top): the quote validates the amount.
 */
export function giftCardQuote(
  p: { id: string; currency: string; amount_type: string; amounts_cents: number[] | null; min_cents: number | null; max_cents: number | null; active: boolean },
  amountRaw: string | null,
): { product_id: string; currency: string; amount_cents: number; total_cents: number; fees_cents: 0 } | { error: string } {
  if (!p.active) return { error: 'this gift card product is not on sale' };
  let amount: number;
  if (amountRaw === null) {
    if (p.amount_type === 'fixed' && p.amounts_cents?.length) amount = p.amounts_cents[0];
    else if (p.min_cents !== null) amount = p.min_cents;
    else return { error: 'amount_cents is required' };
  } else {
    if (!/^\d{1,9}$/.test(amountRaw)) return { error: 'amount_cents must be a whole number of cents' };
    amount = Number(amountRaw);
  }
  if (p.amount_type === 'fixed') {
    if (!(p.amounts_cents ?? []).includes(amount)) return { error: `amount_cents must be one of ${(p.amounts_cents ?? []).join(', ')}` };
  } else if ((p.min_cents !== null && amount < p.min_cents) || (p.max_cents !== null && amount > p.max_cents)) {
    return { error: `amount_cents must be from ${p.min_cents} to ${p.max_cents}` };
  }
  return { product_id: p.id, currency: p.currency, amount_cents: amount, total_cents: amount, fees_cents: 0 };
}
