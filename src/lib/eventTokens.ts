// Event tokens: drink tickets, ride credits, tasting tickets (mig
// 20261114110000, docs/pos.md "Event tokens"). PURE: no Supabase import (the
// reads and writes are in ./eventTokensApi.ts), so the door's state machine
// and the offline ledger unit-test without a client.
//
// Every rule is enforced in SQL; this file only mirrors the parts the door
// needs to act on its own while the network is down:
//   * which code was scanned (a ticket's rotating T- code, or a token code
//     "K-XXXXXXXXXXXXXXXX" / typed with dashes; the gift card alphabet and
//     check character);
//   * the offline cap: what the device may give away for one code before it
//     syncs = the code's balance in the last roster minus what this device
//     already queued for it. The server takes what is left at sync and records
//     the rest as an 'overspent' exception, never a negative balance;
//   * the queue of spends to replay (a client ref each, so a replay is one
//     spend) and which answers settle a queued spend.

import { giftCardCheckOk, normalizeGiftCardCode } from '../../supabase/functions/_shared/commerce.ts';
import type { CsvCell } from './csv';

/** Credits one scan may take (the SQL's 1..50). */
export const MAX_CREDITS_PER_SCAN = 50;
/** A roster older than this doesn't allow offline spends (the cap would be stale). */
export const ROSTER_TTL_MS = 12 * 60 * 60 * 1000;
/** The same code read again within this is the camera seeing it twice. */
export const REPEAT_READ_MS = 2500;
/** The label every token offer, receipt and ticket page carries. */
export const NO_CASH_VALUE = 'Event tokens, no cash value';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type TokenCode =
  | { kind: 'ticket'; ticketId: string; payload: string }
  | { kind: 'code'; code: string; payload: string };

/** A scanned or typed code: a ticket's T- code, or a token code. null: neither. */
export function parseTokenCode(raw: string | null | undefined): TokenCode | null {
  const s = (raw ?? '').trim();
  if (!s || s.length > 300) return null;
  if (/^T-/i.test(s)) {
    const parts = s.slice(2).split(':');
    if (parts.length !== 4 || !UUID_RE.test(parts[0])) return null;
    return { kind: 'ticket', ticketId: parts[0].toLowerCase(), payload: s };
  }
  const body = /^K-/i.test(s) ? s.slice(2) : s;
  const code = normalizeGiftCardCode(body);
  if (!code || !giftCardCheckOk(code)) return null;
  return { kind: 'code', code, payload: `K-${code}` };
}

/** XXXX-XXXX-XXXX-XXXX for a person to read or write on a wristband. */
export function formatTokenCode(code: string): string {
  const c = normalizeGiftCardCode(code.replace(/^K-/i, ''));
  return c ? c.match(/.{4}/g)!.join('-') : code;
}

/** The SQL's _exos_event_token_hash: SHA-256 of "exos-event-token:" + code, hex. */
export async function tokenCodeHash(code: string, subtle: SubtleCrypto = globalThis.crypto.subtle): Promise<string> {
  const digest = await subtle.digest('SHA-256', new TextEncoder().encode(`exos-event-token:${code}`));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** How a code is keyed in the roster and the queue. */
export async function cardKeyOf(code: TokenCode, subtle?: SubtleCrypto): Promise<string> {
  return code.kind === 'ticket' ? `ticket:${code.ticketId}` : `code:${await tokenCodeHash(code.code, subtle)}`;
}

/** Credits a door may ask for in one scan. */
export function clampCredits(n: unknown, max = MAX_CREDITS_PER_SCAN): number {
  const v = Math.floor(Number(n));
  return Number.isFinite(v) ? Math.min(Math.max(v, 1), Math.min(max, MAX_CREDITS_PER_SCAN)) : 1;
}

/** The camera keeps decoding: the same code within REPEAT_READ_MS is one read. */
export function isRepeatRead(last: { payload: string; at: number } | null, payload: string, now: number): boolean {
  return !!last && last.payload === payload && now - last.at < REPEAT_READ_MS;
}

// ── The offline roster and the queue ──────────────────────────────────────

export interface TokenRosterCard {
  cardId: string;
  ticketId: string | null;
  codeHash: string | null;
  /** product id -> credits */
  balances: Record<string, number>;
}

export interface TokenRoster {
  syncedAt: number;
  cards: TokenRosterCard[];
}

const int = (v: unknown): number => {
  const n = Math.trunc(Number(v));
  return Number.isFinite(n) ? n : 0;
};

/** exos_event_token_roster's answer (or what the device stored) -> a roster; null if unusable. */
export function parseRoster(raw: unknown): TokenRoster | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as { synced_at?: unknown; syncedAt?: unknown; cards?: unknown };
  const at = typeof r.syncedAt === 'number' ? r.syncedAt : Date.parse(String(r.synced_at ?? ''));
  if (!Number.isFinite(at) || !Array.isArray(r.cards)) return null;
  const cards: TokenRosterCard[] = [];
  for (const c of r.cards as Record<string, unknown>[]) {
    if (!c || typeof c !== 'object') continue;
    const balances: Record<string, number> = {};
    const b = (c.balances ?? {}) as Record<string, unknown>;
    for (const [k, v] of Object.entries(b)) if (int(v) > 0) balances[k] = int(v);
    cards.push({
      cardId: String(c.card_id ?? c.cardId ?? ''),
      ticketId: (c.ticket_id ?? c.ticketId ?? null) as string | null,
      codeHash: (c.code_hash ?? c.codeHash ?? null) as string | null,
      balances,
    });
  }
  return { syncedAt: at, cards };
}

export function rosterCard(roster: TokenRoster | null, key: string): TokenRosterCard | null {
  if (!roster) return null;
  if (key.startsWith('ticket:')) return roster.cards.find((c) => c.ticketId === key.slice(7)) ?? null;
  if (key.startsWith('code:')) return roster.cards.find((c) => c.codeHash === key.slice(5)) ?? null;
  return null;
}

export interface QueuedSpend {
  /** Client ref (a UUID): the server's idempotency key. */
  ref: string;
  /** What was scanned (T- code / K- code), replayed as is. */
  payload: string;
  cardKey: string;
  productId: string;
  credits: number;
  /** When the device gave the tokens (ms). */
  at: number;
  device?: string | null;
}

/** What this device may still give from one code, offline: roster balance - queued. */
export function offlineCap(roster: TokenRoster | null, queue: readonly QueuedSpend[], key: string, productId: string): number {
  const base = rosterCard(roster, key)?.balances[productId] ?? 0;
  const queued = queue.filter((q) => q.cardKey === key && q.productId === productId).reduce((n, q) => n + q.credits, 0);
  return Math.max(0, base - queued);
}

export type OfflineDecision =
  | { ok: true; remaining: number }
  | { ok: false; reason: 'no-roster' | 'stale-roster' | 'insufficient'; available: number };

/** May the device give `credits` of a product for this code while offline? */
export function decideOffline(
  roster: TokenRoster | null, queue: readonly QueuedSpend[], key: string, productId: string, credits: number, now: number,
): OfflineDecision {
  if (!roster) return { ok: false, reason: 'no-roster', available: 0 };
  if (now - roster.syncedAt > ROSTER_TTL_MS) return { ok: false, reason: 'stale-roster', available: 0 };
  const cap = offlineCap(roster, queue, key, productId);
  if (credits > cap) return { ok: false, reason: 'insufficient', available: cap };
  return { ok: true, remaining: cap - credits };
}

/** Add a spend (a ref already queued is not added twice). */
export function enqueueSpend(queue: readonly QueuedSpend[], s: QueuedSpend): QueuedSpend[] {
  return queue.some((q) => q.ref === s.ref) ? [...queue] : [...queue, s];
}

/** Answers that settle a queued spend: the server decided (taken, short, refused for good). */
const FINAL = new Set(['spent', 'overspent', 'rejected', 'bad-client-ref', 'unknown-product', 'bad-credits', 'bad-scan-time',
  'not-found', 'insufficient', 'expired', 'event-cancelled', 'barcode-rejected', 'barcode-expired', 'ticket-voided']);

export interface SyncAnswer {
  ref: string;
  reason: string;
  spent?: number;
  short?: number;
}

/** The queue after a sync, and what the sync found. Rate-limited or failed calls stay queued. */
export function settleQueue(queue: readonly QueuedSpend[], answers: readonly SyncAnswer[]): {
  queue: QueuedSpend[]; settled: number; spent: number; short: number; refused: number;
} {
  const byRef = new Map(answers.map((a) => [a.ref, a]));
  const left: QueuedSpend[] = [];
  let settled = 0; let spent = 0; let short = 0; let refused = 0;
  for (const q of queue) {
    const a = byRef.get(q.ref);
    if (!a || !FINAL.has(a.reason)) {
      left.push(q);
      continue;
    }
    settled += 1;
    spent += Math.max(0, int(a.spent));
    if (a.reason === 'overspent' || a.reason === 'rejected') short += Math.max(0, int(a.short ?? q.credits));
    else if (a.reason !== 'spent') refused += 1;
  }
  return { queue: left, settled, spent, short, refused };
}

/** A stored queue, dropping anything malformed. */
export function parseQueue(raw: unknown): QueuedSpend[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter((q): q is QueuedSpend => !!q && typeof q === 'object'
    && UUID_RE.test(String((q as QueuedSpend).ref)) && typeof (q as QueuedSpend).payload === 'string'
    && typeof (q as QueuedSpend).cardKey === 'string' && UUID_RE.test(String((q as QueuedSpend).productId))
    && int((q as QueuedSpend).credits) >= 1 && int((q as QueuedSpend).credits) <= MAX_CREDITS_PER_SCAN
    && Number.isFinite((q as QueuedSpend).at));
}

// ── The door's spend state machine ────────────────────────────────────────

export interface SpendAnswer {
  ok: boolean;
  reason: string;
  spent?: number;
  short?: number;
  balance?: number;
  ledger_id?: number | null;
  duplicate?: boolean;
  why?: string;
}

export type DoorTokenState =
  | { phase: 'idle' }
  | { phase: 'busy'; ref: string; payload: string; credits: number }
  | { phase: 'spent'; ref: string; spent: number; balance: number | null; offline: boolean; ledgerId: number | null }
  | { phase: 'refused'; ref: string | null; reason: string; balance: number | null; offline: boolean };

export type DoorTokenEvent =
  | { type: 'scan'; ref: string; payload: string; credits: number }
  | { type: 'answer'; ref: string; answer: SpendAnswer }
  | { type: 'queued'; ref: string; credits: number; remaining: number }
  | { type: 'offline-refused'; ref: string; reason: string; available: number }
  | { type: 'failed'; ref: string; reason?: string }
  | { type: 'reset' };

export const DOOR_TOKEN_IDLE: DoorTokenState = { phase: 'idle' };

/**
 * One scan at a time: a scan while one is in flight is ignored (a double read
 * never takes twice), and an answer for another scan than the one in flight is
 * ignored (a late reply can't overwrite the screen).
 */
export function doorTokenReducer(state: DoorTokenState, ev: DoorTokenEvent): DoorTokenState {
  switch (ev.type) {
    case 'scan':
      if (state.phase === 'busy') return state;
      return { phase: 'busy', ref: ev.ref, payload: ev.payload, credits: clampCredits(ev.credits) };
    case 'reset':
      return state.phase === 'busy' ? state : DOOR_TOKEN_IDLE;
    default:
      if (state.phase !== 'busy' || state.ref !== ev.ref) return state;
  }
  switch (ev.type) {
    case 'answer': {
      const a = ev.answer;
      if (a.ok && a.reason === 'spent') {
        return { phase: 'spent', ref: ev.ref, spent: int(a.spent) || state.credits, balance: a.balance ?? null, offline: false,
                 ledgerId: a.ledger_id ?? null };
      }
      return { phase: 'refused', ref: ev.ref, reason: a.reason || 'failed', balance: a.balance ?? null, offline: false };
    }
    case 'queued':
      return { phase: 'spent', ref: ev.ref, spent: ev.credits, balance: ev.remaining, offline: true, ledgerId: null };
    case 'offline-refused':
      return { phase: 'refused', ref: ev.ref, reason: ev.reason, balance: ev.available, offline: true };
    case 'failed':
      return { phase: 'refused', ref: ev.ref, reason: ev.reason || 'failed', balance: null, offline: false };
    default:
      return state;
  }
}

/** What the door says for each refusal. */
export const TOKEN_REASON_TEXT: Record<string, string> = {
  insufficient: 'Not enough tokens on this code.',
  'not-found': 'Unknown code for this event.',
  'barcode-rejected': "That code isn't valid. Ask the guest to open their ticket again.",
  'barcode-expired': 'That code is old. Ask the guest to refresh their ticket.',
  'ticket-voided': 'That ticket was refunded or voided.',
  expired: 'These tokens have expired.',
  'event-cancelled': 'The event is cancelled.',
  'unknown-product': 'Pick a token type first.',
  'bad-credits': 'Pick 1 to 50.',
  'bad-client-ref': 'That spend was already recorded differently. Scan again.',
  'bad-scan-time': "This device's clock is off.",
  'rate-limited': 'Too many scans a minute. Wait a moment.',
  overspent: 'Synced: this code was short; recorded on the report.',
  rejected: 'Synced: the server refused this code; recorded on the report.',
  'no-roster': 'Offline with no token list on this device: download it while online.',
  'stale-roster': 'The token list on this device is old: download it again while online.',
  failed: "The server didn't answer. Try again.",
};

export function tokenReasonText(reason: string): string {
  return TOKEN_REASON_TEXT[reason] ?? reason;
}

// ── The report ────────────────────────────────────────────────────────────

export interface TokenReportProduct {
  product_id: string;
  name: string;
  unit_label: string;
  refundable: boolean;
  expires_at: string | null;
  sold_credits: number; sold_cents: number;
  redeemed_credits: number; redeemed_cents: number;
  expired_credits: number; expired_cents: number;
  refunded_credits: number; refunded_cents: number;
  outstanding_credits: number; outstanding_cents: number;
  overspent_count: number; overspent_credits: number;
  rejected_count: number; rejected_credits: number;
}

export interface TokenReportException {
  id: string; kind: 'overspent' | 'rejected'; product: string; credits_asked: number; credits_short: number;
  reason: string | null; device: string | null; offline_at: string; synced_at: string; card_last4: string | null; on_ticket: boolean;
}

export interface TokenReportLot {
  lot_id: string; product: string; source: 'online' | 'pos' | 'comp'; credits_left: number; value_left: number;
  bought_at: string; card_id: string; card_last4: string | null; on_ticket: boolean;
}

export interface TokenReport {
  event_id: string;
  currency: string;
  generated_at: string;
  products: TokenReportProduct[];
  exceptions: TokenReportException[];
  refundable: TokenReportLot[];
}

const dec = (cents: number) => (int(cents) / 100).toFixed(2);

export const TOKEN_REPORT_HEADER = [
  'product', 'unit', 'sold', 'sold_amount', 'redeemed', 'redeemed_amount', 'expired', 'expired_amount', 'refunded',
  'refunded_amount', 'outstanding', 'outstanding_amount', 'overspent_scans', 'overspent_tokens', 'rejected_scans', 'rejected_tokens',
];

/** One row per product (amounts as 12.34). */
export function tokenReportRows(r: TokenReport | null): CsvCell[][] {
  return (r?.products ?? []).map((p) => [
    p.name, p.unit_label, int(p.sold_credits), dec(p.sold_cents), int(p.redeemed_credits), dec(p.redeemed_cents),
    int(p.expired_credits), dec(p.expired_cents), int(p.refunded_credits), dec(p.refunded_cents),
    int(p.outstanding_credits), dec(p.outstanding_cents), int(p.overspent_count), int(p.overspent_credits),
    int(p.rejected_count), int(p.rejected_credits),
  ]);
}

export const TOKEN_EXCEPTION_HEADER = ['kind', 'product', 'asked', 'short', 'reason', 'device', 'given_at', 'synced_at', 'code_last4', 'on_ticket'];

export function tokenExceptionRows(r: TokenReport | null): CsvCell[][] {
  return (r?.exceptions ?? []).map((x) => [
    x.kind, x.product, int(x.credits_asked), int(x.credits_short), x.reason ?? '', x.device ?? '', x.offline_at, x.synced_at,
    x.card_last4 ?? '', x.on_ticket ? 'yes' : 'no',
  ]);
}

/** Sold always equals redeemed + expired + refunded + outstanding (the SQL computes them from one ledger). */
export function reportAddsUp(p: TokenReportProduct): boolean {
  return int(p.sold_credits) === int(p.redeemed_credits) + int(p.expired_credits) + int(p.refunded_credits) + int(p.outstanding_credits)
    && int(p.sold_cents) === int(p.redeemed_cents) + int(p.expired_cents) + int(p.refunded_cents) + int(p.outstanding_cents);
}

// ── The product editor ────────────────────────────────────────────────────

export interface TokenBundle { credits: number; price_cents: number }

export interface TokenProductDraft {
  id?: string;
  name: string;
  unit_label: string;
  price_cents: number;
  bundles: TokenBundle[];
  max_per_order: number;
  refundable: boolean;
  grace_hours: number;
  active: boolean;
}

/** What's wrong with a draft (the SQL refuses the same), or null. */
export function tokenDraftProblem(d: TokenProductDraft): string | null {
  if (!d.name.trim() || d.name.trim().length > 60) return 'Give it a name (up to 60 characters).';
  if (!d.unit_label.trim() || d.unit_label.trim().length > 20) return 'Name one token (up to 20 characters), e.g. drink or ride.';
  if (!Number.isInteger(d.price_cents) || d.price_cents < 1 || d.price_cents > 100000) return 'Price per token: 0.01 to 1,000.00.';
  if (d.bundles.length > 5) return 'At most 5 bundles.';
  const seen = new Set<number>();
  for (const b of d.bundles) {
    if (!Number.isInteger(b.credits) || b.credits < 2 || b.credits > 500) return 'A bundle is 2 to 500 tokens.';
    if (!Number.isInteger(b.price_cents) || b.price_cents < 1 || b.price_cents > 1000000) return 'A bundle costs 0.01 to 10,000.00.';
    if (seen.has(b.credits)) return `Two bundles of ${b.credits}.`;
    seen.add(b.credits);
  }
  if (!Number.isInteger(d.max_per_order) || d.max_per_order < 1 || d.max_per_order > 500) return 'Max per order: 1 to 500 tokens.';
  if (!Number.isInteger(d.grace_hours) || d.grace_hours < 0 || d.grace_hours > 720) return 'Grace: 0 to 720 hours.';
  return null;
}

/** The rule shown before purchase and on the ticket (the SQL's _exos_event_token_rule). */
export function tokenRuleText(eventName: string, p: { grace_hours: number; refundable: boolean }): string {
  return `${NO_CASH_VALUE}, valid for ${eventName.slice(0, 120)} only. They expire `
    + (p.grace_hours === 0 ? 'when the event ends' : `${p.grace_hours} hours after the event ends`)
    + (p.refundable ? '; unused tokens are refunded on request to how you paid.' : '; unused tokens are not refundable.');
}

/** Price per token of a bundle, for the "saves" hint. */
export function bundleUnitCents(b: TokenBundle): number {
  return Math.round(b.price_cents / Math.max(1, b.credits));
}
