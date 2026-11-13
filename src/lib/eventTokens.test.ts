import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { webcrypto } from 'node:crypto';
import { makeGiftCardCode } from '../../supabase/functions/_shared/commerce.ts';
import {
  cardKeyOf, clampCredits, decideOffline, DOOR_TOKEN_IDLE, doorTokenReducer, enqueueSpend, formatTokenCode, isRepeatRead,
  offlineCap, parseQueue, parseRoster, parseTokenCode, reportAddsUp, ROSTER_TTL_MS, settleQueue, tokenCodeHash,
  tokenDraftProblem, tokenReasonText, tokenReportRows, tokenRuleText, TOKEN_REPORT_HEADER, type DoorTokenState,
  type QueuedSpend, type TokenProductDraft, type TokenReportProduct,
} from './eventTokens';

const MIG = readFileSync(path.resolve(__dirname, '../../supabase/migrations/20261114110000_exos_event_tokens.sql'), 'utf8');
const subtle = webcrypto.subtle as unknown as SubtleCrypto;
const CODE = makeGiftCardCode(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]));
const TICKET = '0b6f0000-0000-4000-8000-0000000000aa';
const DRINK = '1b6f0000-0000-4000-8000-0000000000d1';
const RIDE = '1b6f0000-0000-4000-8000-0000000000d2';
const ref = (n: number) => `2b6f0000-0000-4000-8000-${String(n).padStart(12, '0')}`;

describe('parseTokenCode', () => {
  it('reads a ticket code by its ticket id', () => {
    expect(parseTokenCode(`T-${TICKET.toUpperCase()}:owner:123:mac`)).toEqual({ kind: 'ticket', ticketId: TICKET, payload: `T-${TICKET.toUpperCase()}:owner:123:mac` });
    expect(parseTokenCode('T-nope:a:b:c')).toBeNull();
    expect(parseTokenCode(`T-${TICKET}:a:b`)).toBeNull();
  });

  it('reads a token code from the QR, typed with dashes or in lower case', () => {
    const want = { kind: 'code', code: CODE, payload: `K-${CODE}` };
    expect(parseTokenCode(`K-${CODE}`)).toEqual(want);
    expect(parseTokenCode(formatTokenCode(CODE).toLowerCase())).toEqual(want);
    expect(parseTokenCode(` ${CODE} `)).toEqual(want);
  });

  it('refuses a mistyped code before any lookup', () => {
    const typo = CODE.slice(0, 5) + (CODE[5] === 'A' ? 'B' : 'A') + CODE.slice(6);
    expect(parseTokenCode(typo)).toBeNull();
    expect(parseTokenCode('')).toBeNull();
    expect(parseTokenCode(null)).toBeNull();
  });
});

describe('tokenCodeHash', () => {
  it('is the SQL hash: sha256 of "exos-event-token:" + code', async () => {
    expect(MIG).toContain("encode(sha256(convert_to('exos-event-token:' || p_code, 'UTF8')), 'hex')");
    const h = await tokenCodeHash('ABCD', subtle);
    // The same vector as SELECT public._exos_event_token_hash('ABCD').
    expect(h).toBe('1fa152efeaa188afca860ede5eb482aa627220ced0b5cd8df484fefa8f92c6d6');
    const again = await tokenCodeHash('ABCD', subtle);
    expect(again).toBe(h);
    expect(await tokenCodeHash('ABCE', subtle)).not.toBe(h);
  });

  it('keys a ticket by its id and a code by its hash', async () => {
    expect(await cardKeyOf(parseTokenCode(`T-${TICKET}:o:1:m`)!, subtle)).toBe(`ticket:${TICKET}`);
    expect(await cardKeyOf(parseTokenCode(CODE)!, subtle)).toBe(`code:${await tokenCodeHash(CODE, subtle)}`);
  });
});

describe('the door spend state machine', () => {
  const scan = (s: DoorTokenState, r = ref(1), credits = 2) => doorTokenReducer(s, { type: 'scan', ref: r, payload: 'K-X', credits });

  it('takes one scan at a time: a second read while one is in flight is ignored', () => {
    const busy = scan(DOOR_TOKEN_IDLE);
    expect(busy).toEqual({ phase: 'busy', ref: ref(1), payload: 'K-X', credits: 2 });
    expect(scan(busy, ref(2))).toBe(busy);
    expect(doorTokenReducer(busy, { type: 'reset' })).toBe(busy);
  });

  it('shows what was spent and what is left', () => {
    const s = doorTokenReducer(scan(DOOR_TOKEN_IDLE), { type: 'answer', ref: ref(1),
      answer: { ok: true, reason: 'spent', spent: 2, balance: 7, ledger_id: 41 } });
    expect(s).toEqual({ phase: 'spent', ref: ref(1), spent: 2, balance: 7, offline: false, ledgerId: 41 });
    expect(doorTokenReducer(s, { type: 'reset' })).toEqual(DOOR_TOKEN_IDLE);
  });

  it('refuses with the balance when there is not enough', () => {
    const s = doorTokenReducer(scan(DOOR_TOKEN_IDLE), { type: 'answer', ref: ref(1), answer: { ok: false, reason: 'insufficient', balance: 1 } });
    expect(s).toEqual({ phase: 'refused', ref: ref(1), reason: 'insufficient', balance: 1, offline: false });
    expect(tokenReasonText('insufficient')).toBe('Not enough tokens on this code.');
  });

  it('ignores a late answer for another scan', () => {
    const busy = scan(DOOR_TOKEN_IDLE, ref(3));
    expect(doorTokenReducer(busy, { type: 'answer', ref: ref(1), answer: { ok: true, reason: 'spent', spent: 2, balance: 0 } })).toBe(busy);
  });

  it('queues offline within the cap, refuses beyond it', () => {
    const q = doorTokenReducer(scan(DOOR_TOKEN_IDLE), { type: 'queued', ref: ref(1), credits: 2, remaining: 3 });
    expect(q).toMatchObject({ phase: 'spent', offline: true, balance: 3, ledgerId: null });
    const r = doorTokenReducer(scan(q, ref(2)), { type: 'offline-refused', ref: ref(2), reason: 'insufficient', available: 1 });
    expect(r).toMatchObject({ phase: 'refused', offline: true, reason: 'insufficient', balance: 1 });
  });

  it('a failed call is a refusal the staff can retry', () => {
    expect(doorTokenReducer(scan(DOOR_TOKEN_IDLE), { type: 'failed', ref: ref(1) })).toMatchObject({ phase: 'refused', reason: 'failed' });
  });

  it('clamps the amount and sees a repeated camera read', () => {
    expect(clampCredits(0)).toBe(1);
    expect(clampCredits(99)).toBe(50);
    expect(clampCredits('3')).toBe(3);
    expect(clampCredits(8, 5)).toBe(5);
    expect(isRepeatRead({ payload: 'K-X', at: 1000 }, 'K-X', 2000)).toBe(true);
    expect(isRepeatRead({ payload: 'K-X', at: 1000 }, 'K-X', 9000)).toBe(false);
    expect(isRepeatRead({ payload: 'K-X', at: 1000 }, 'K-Y', 1100)).toBe(false);
  });
});

describe('the offline ledger', () => {
  const roster = parseRoster({
    synced_at: '2026-11-14T18:00:00Z',
    cards: [
      { card_id: 'c1', ticket_id: TICKET, code_hash: null, balances: { [DRINK]: 9, [RIDE]: 0 } },
      { card_id: 'c2', ticket_id: null, code_hash: 'ab'.repeat(32), balances: { [DRINK]: 4 } },
      null,
    ],
  })!;
  const now = Date.parse('2026-11-14T19:00:00Z');
  const tkey = `ticket:${TICKET}`;
  const spend = (n: number, credits: number, key = tkey, product = DRINK): QueuedSpend =>
    ({ ref: ref(n), payload: 'T-x', cardKey: key, productId: product, credits, at: now });

  it('reads the roster (zero balances dropped)', () => {
    expect(roster.cards).toHaveLength(2);
    expect(roster.cards[0].balances).toEqual({ [DRINK]: 9 });
    expect(parseRoster({ cards: [] })).toBeNull();
    expect(parseRoster(null)).toBeNull();
  });

  it('caps a code at its balance at the last sync minus what this device queued', () => {
    let queue: QueuedSpend[] = [];
    expect(offlineCap(roster, queue, tkey, DRINK)).toBe(9);
    queue = enqueueSpend(queue, spend(1, 6));
    expect(decideOffline(roster, queue, tkey, DRINK, 3, now)).toEqual({ ok: true, remaining: 0 });
    queue = enqueueSpend(queue, spend(2, 3));
    expect(decideOffline(roster, queue, tkey, DRINK, 1, now)).toEqual({ ok: false, reason: 'insufficient', available: 0 });
    // The same ref twice is one spend.
    expect(enqueueSpend(queue, spend(2, 3))).toHaveLength(2);
    // Another product, another code: their own caps.
    expect(decideOffline(roster, queue, tkey, RIDE, 1, now)).toEqual({ ok: false, reason: 'insufficient', available: 0 });
    expect(decideOffline(roster, queue, `code:${'ab'.repeat(32)}`, DRINK, 4, now)).toEqual({ ok: true, remaining: 0 });
    // A code bought after the sync isn't on this device: nothing offline.
    expect(decideOffline(roster, queue, `code:${'cd'.repeat(32)}`, DRINK, 1, now)).toMatchObject({ ok: false, reason: 'insufficient' });
  });

  it('refuses offline spends without a roster or with an old one', () => {
    expect(decideOffline(null, [], tkey, DRINK, 1, now)).toMatchObject({ ok: false, reason: 'no-roster' });
    expect(decideOffline(roster, [], tkey, DRINK, 1, roster.syncedAt + ROSTER_TTL_MS + 1)).toMatchObject({ ok: false, reason: 'stale-roster' });
  });

  it('settles what the server decided and keeps what it did not', () => {
    const queue = [spend(1, 6), spend(2, 6), spend(3, 1), spend(4, 2), spend(5, 1)];
    const out = settleQueue(queue, [
      { ref: ref(1), reason: 'spent', spent: 6 },
      { ref: ref(2), reason: 'overspent', spent: 3, short: 3 },
      { ref: ref(3), reason: 'rejected', short: 1 },
      { ref: ref(4), reason: 'rate-limited' },
    ]);
    expect(out.queue.map((q) => q.ref)).toEqual([ref(4), ref(5)]);
    expect(out).toMatchObject({ settled: 3, spent: 9, short: 4, refused: 0 });
  });

  it('drops malformed stored entries', () => {
    expect(parseQueue([spend(1, 2), { ref: 'x' }, { ...spend(2, 0) }, { ...spend(3, 2), productId: 'nope' }, null])).toEqual([spend(1, 2)]);
    expect(parseQueue('nope')).toEqual([]);
  });
});

describe('the report and the editor', () => {
  const p: TokenReportProduct = {
    product_id: DRINK, name: 'Drink token', unit_label: 'drink', refundable: false, expires_at: null,
    sold_credits: 26, sold_cents: 10000, redeemed_credits: 14, redeemed_cents: 5600, expired_credits: 8, expired_cents: 3400,
    refunded_credits: 2, refunded_cents: 1000, outstanding_credits: 2, outstanding_cents: 0,
    overspent_count: 2, overspent_credits: 5, rejected_count: 1, rejected_credits: 1,
  };

  it('adds up and exports one row per product', () => {
    expect(reportAddsUp(p)).toBe(true);
    expect(reportAddsUp({ ...p, outstanding_credits: 3 })).toBe(false);
    const rows = tokenReportRows({ event_id: 'e', currency: 'usd', generated_at: '', products: [p], exceptions: [], refundable: [] });
    expect(rows).toEqual([['Drink token', 'drink', 26, '100.00', 14, '56.00', 8, '34.00', 2, '10.00', 2, '0.00', 2, 5, 1, 1]]);
    expect(rows[0]).toHaveLength(TOKEN_REPORT_HEADER.length);
    expect(tokenReportRows(null)).toEqual([]);
  });

  it('checks a product like the SQL does', () => {
    const d: TokenProductDraft = { name: 'Drink token', unit_label: 'drink', price_cents: 500, bundles: [{ credits: 10, price_cents: 4500 }],
      max_per_order: 20, refundable: false, grace_hours: 2, active: true };
    expect(tokenDraftProblem(d)).toBeNull();
    expect(tokenDraftProblem({ ...d, price_cents: 0 })).toMatch(/Price per token/);
    expect(tokenDraftProblem({ ...d, bundles: [{ credits: 1, price_cents: 100 }] })).toMatch(/2 to 500/);
    expect(tokenDraftProblem({ ...d, bundles: [{ credits: 10, price_cents: 4500 }, { credits: 10, price_cents: 4000 }] })).toMatch(/Two bundles/);
    expect(tokenDraftProblem({ ...d, max_per_order: 501 })).toMatch(/Max per order/);
    expect(tokenDraftProblem({ ...d, grace_hours: -1 })).toMatch(/Grace/);
  });

  it('words the rule like the SQL', () => {
    expect(tokenRuleText('Cherry Festival', { grace_hours: 0, refundable: false }))
      .toBe('Event tokens, no cash value, valid for Cherry Festival only. They expire when the event ends; unused tokens are not refundable.');
    expect(tokenRuleText('Fair', { grace_hours: 2, refundable: true })).toContain('2 hours after the event ends; unused tokens are refunded');
    expect(MIG).toContain("'Event tokens, no cash value, valid for '");
    expect(MIG).toContain("'; unused tokens are refunded on request to how you paid.'");
  });
});
