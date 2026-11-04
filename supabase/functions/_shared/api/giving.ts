// Giving and gift card writes of the partner API (mig 20261102110000): the
// pure body parsing, shared by exos-api (./exos-api/giving.ts) and vitest
// (src/lib/apiGiving.test.ts). No Deno or Supabase imports.

export class GivingBodyError extends Error {}

const CAMPAIGN_FIELDS = [
  'name', 'slug', 'description', 'image_url', 'currency', 'goal_cents', 'starts_at', 'ends_at', 'active',
  'suggested_cents', 'cover_fees', 'cover_fees_bps', 'checkout_add_on', 'round_up', 'tax_receipt_text',
] as const;

/** Opendate-style bodies wrap the fields ({ giving_campaign: {...} }); both forms work. */
export function unwrapBody(body: Record<string, unknown>, wrapper: string): Record<string, unknown> {
  const inner = body[wrapper];
  return inner && typeof inner === 'object' && !Array.isArray(inner) ? inner as Record<string, unknown> : body;
}

/**
 * A campaign body: only the known fields, so a typo is a 400 and not a
 * silent no-op. Opendate's `title` and `goal` (major units) are accepted too.
 */
export function campaignBody(raw: Record<string, unknown>): Record<string, unknown> {
  const b = unwrapBody(raw, 'giving_campaign');
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(b)) {
    if ((CAMPAIGN_FIELDS as readonly string[]).includes(k)) out[k] = v;
    else if (k === 'title') out.name = v;
    else if (k === 'goal') {
      const n = typeof v === 'string' ? Number(v) : v;
      if (typeof n !== 'number' || !Number.isFinite(n) || n < 0) throw new GivingBodyError('goal must be a positive amount.');
      out.goal_cents = Math.round(n * 100);
    } else throw new GivingBodyError(`unknown field: ${k}`);
  }
  // Form bodies send strings: "true" / "1500".
  for (const k of ['active', 'cover_fees', 'checkout_add_on', 'round_up']) {
    if (out[k] === 'true') out[k] = true;
    if (out[k] === 'false') out[k] = false;
  }
  return out;
}

export interface CardRow {
  code: string;
  balance_cents: number;
  initial_cents?: number;
  currency?: string;
  expires_at?: string;
  recipient_email?: string;
  recipient_name?: string;
}

export const IMPORT_MAX = 500;

/**
 * A bulk import body: { source?, cards: [...] } (or gift_cards / giftcards,
 * Gift Up!'s word). Each card's amounts may be given in cents (balance_cents)
 * or major units (balance / remaining_value, as Gift Up! exports them).
 */
export function importBody(raw: Record<string, unknown>): { source: string; cards: CardRow[] } {
  const b = raw;
  const list = (b.cards ?? b.gift_cards ?? b.giftcards ?? b.gift_up_giftcards) as unknown;
  if (!Array.isArray(list) || list.length === 0) throw new GivingBodyError('cards must be a non-empty list.');
  if (list.length > IMPORT_MAX) throw new GivingBodyError(`at most ${IMPORT_MAX} cards per request.`);
  const source = typeof b.source === 'string' && b.source.trim() ? b.source.trim().toLowerCase() : 'gift_up';
  const cards = list.map((x, i) => cardRow(x, i + 1));
  return { source, cards };
}

function cents(v: unknown, major: boolean): number | undefined {
  if (v === undefined || v === null || v === '') return undefined;
  const n = typeof v === 'string' ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isFinite(n)) return NaN;
  return major ? Math.round(n * 100) : n;
}

function cardRow(x: unknown, row: number): CardRow {
  if (!x || typeof x !== 'object' || Array.isArray(x)) throw new GivingBodyError(`card ${row} must be an object.`);
  const c = x as Record<string, unknown>;
  const code = c.code ?? c.gift_card_code;
  const balance = cents(c.balance_cents, false) ?? cents(c.remaining_value ?? c.balance, true);
  const initial = cents(c.initial_cents, false) ?? cents(c.initial_value ?? c.value, true);
  const out: CardRow = { code: typeof code === 'string' ? code : '', balance_cents: balance ?? NaN };
  if (initial !== undefined) out.initial_cents = initial;
  for (const k of ['currency', 'expires_at', 'recipient_email', 'recipient_name'] as const) {
    if (typeof c[k] === 'string' && (c[k] as string).trim()) out[k] = (c[k] as string).trim();
  }
  if (!out.expires_at && typeof c.expiry_date === 'string') out.expires_at = c.expiry_date;
  // NaN goes through as null: the SQL answers that row with its own error.
  return JSON.parse(JSON.stringify(out, (_k, v) => (typeof v === 'number' && !Number.isFinite(v) ? null : v)));
}

/** A gift card on a reservation: { code, amount_cents? } (gift_card_code, Opendate's wrapper). */
export function redemptionBody(raw: Record<string, unknown>): { code: string; amountCents: number | null } {
  const b = unwrapBody(raw, 'gift_card_redemption');
  const code = b.code ?? b.gift_card_code;
  if (typeof code !== 'string' || !code.trim()) throw new GivingBodyError('code is required.');
  let amount: number | null = null;
  const a = b.amount_cents ?? (b.amount !== undefined ? cents(b.amount, true) : undefined);
  if (a !== undefined && a !== null && a !== '') {
    const n = typeof a === 'string' ? Number(a) : a;
    if (typeof n !== 'number' || !Number.isInteger(n) || n <= 0) throw new GivingBodyError('amount_cents must be a positive whole number.');
    amount = n;
  }
  return { code: code.trim(), amountCents: amount };
}

/** An offline refund: { amount_cents?, reference?, method?, note? }. */
export function offlineRefundBody(raw: Record<string, unknown>, idempotencyKey: string | null): Record<string, unknown> {
  const b = unwrapBody(raw, 'offline_refund');
  const out: Record<string, unknown> = {};
  if (b.amount_cents !== undefined && b.amount_cents !== null && b.amount_cents !== '') {
    const n = typeof b.amount_cents === 'string' ? Number(b.amount_cents) : b.amount_cents;
    if (typeof n !== 'number' || !Number.isInteger(n) || n <= 0) throw new GivingBodyError('amount_cents must be a positive whole number.');
    out.amount_cents = n;
  }
  const ref = b.reference ?? idempotencyKey;
  if (ref !== undefined && ref !== null) {
    if (typeof ref !== 'string' || !/^[A-Za-z0-9_:.-]{1,200}$/.test(ref)) {
      throw new GivingBodyError('reference must be 1-200 letters, digits, _ . : or -.');
    }
    out.reference = ref;
  }
  if (b.method !== undefined) {
    if (!['cash', 'check', 'card', 'bank_transfer', 'other'].includes(String(b.method))) {
      throw new GivingBodyError('method must be cash, check, card, bank_transfer or other.');
    }
    out.method = b.method;
  }
  if (typeof b.note === 'string') out.note = b.note.slice(0, 1000);
  return out;
}

export const RECURRING_STATUSES = ['pending', 'active', 'past_due', 'cancelled', 'ended'] as const;
