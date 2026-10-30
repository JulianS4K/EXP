import { describe, it, expect } from 'vitest';
import {
  buildParties, deriveGroupCount, matchGroups, normalizePartyCode, planSpots, prng, validateResult,
  type MatchMember, type MatchSettings, type MatchSpot,
} from './matching';

const S: MatchSettings = { min: 4, target: 6, max: 8, seed: 42 };

function solo(i: number, extra: Partial<MatchMember> = {}): MatchMember {
  const id = `t${String(i).padStart(3, '0')}`;
  return { ticketId: id, userKey: `u${i}`, orderKey: `o${i}`, ...extra };
}

function people(n: number, from = 0, extra: (i: number) => Partial<MatchMember> = () => ({})): MatchMember[] {
  return Array.from({ length: n }, (_, k) => solo(from + k, extra(from + k)));
}

const spots = (...caps: number[]): MatchSpot[] => caps.map((c, i) => ({ id: `s${i}`, capacity: c }));

describe('prng / parties', () => {
  it('is deterministic per seed', () => {
    const a = prng(7), b = prng(7), c = prng(8);
    const xs = [a(), a(), a()];
    expect([b(), b(), b()]).toEqual(xs);
    expect(c()).not.toEqual(xs[0]);
  });

  it('joins an order and a party code transitively', () => {
    const ms = [
      solo(1, { orderKey: 'A' }), solo(2, { orderKey: 'A', partyCode: 'fun-42' }),
      solo(3, { partyCode: 'FUN42' }), solo(4), solo(5, { partyCode: 'x' }),
    ];
    const ps = buildParties(ms);
    expect(ps.map((p) => p.members.map((m) => m.ticketId))).toEqual([['t001', 't002', 't003'], ['t004'], ['t005']]);
  });

  it('refuses a party code that would join a blocked pair', () => {
    const ms = [solo(1, { partyCode: 'TEAM1' }), solo(2, { partyCode: 'TEAM1' })];
    expect(buildParties(ms, new Set(['u1|u2', 'u2|u1']))).toHaveLength(2);
    expect(buildParties(ms)).toHaveLength(1);
  });

  it('normalizes party codes and rejects short ones', () => {
    expect(normalizePartyCode(' ab-12 ')).toBe('AB12');
    expect(normalizePartyCode('abc')).toBeNull();
    expect(normalizePartyCode(null)).toBeNull();
  });
});

describe('group count and spots', () => {
  it('derives a count that respects min and max', () => {
    expect(deriveGroupCount(0, S)).toBe(0);
    expect(deriveGroupCount(12, S)).toBe(2);
    expect(deriveGroupCount(5, S)).toBe(1);
    expect(deriveGroupCount(17, { ...S, target: 8, max: 8 })).toBe(3);
    expect(deriveGroupCount(9, { ...S, groupCount: 4 })).toBe(4);
  });

  it('spreads groups across spots by seats left and skips spots below min', () => {
    expect(planSpots(3, spots(12, 6, 3), S)).toEqual(['s0', 's0', 's1']);
    expect(planSpots(2, spots(3), S)).toEqual([]);
  });
});

describe('matchGroups', () => {
  it('fills groups toward the target and satisfies every hard rule', () => {
    const members = people(24);
    const input = { members, spots: spots(16, 16), settings: S };
    const r = matchGroups(input);
    expect(r.groups).toHaveLength(4);
    expect(r.groups.map((g) => g.ticketIds.length)).toEqual([6, 6, 6, 6]);
    expect(r.leftovers).toEqual([]);
    expect(validateResult(r, input)).toEqual([]);
  });

  it('is deterministic for a seed and changes with another seed', () => {
    const members = people(18, 0, (i) => ({ language: i % 3 === 0 ? 'es' : 'en' }));
    const input = { members, spots: spots(30), settings: S };
    expect(matchGroups(input)).toEqual(matchGroups(input));
    const other = matchGroups({ ...input, settings: { ...S, seed: 43 } });
    expect(validateResult(other, input)).toEqual([]);
  });

  it('never splits a party', () => {
    const members = [
      ...people(3, 0, () => ({ orderKey: 'big' })),
      ...people(2, 10, () => ({ partyCode: 'DUO22' })),
      ...people(9, 20),
    ];
    const input = { members, spots: spots(20), settings: S };
    const r = matchGroups(input);
    expect(validateResult(r, input)).toEqual([]);
    const home = (t: string) => r.groups.findIndex((g) => g.ticketIds.includes(t));
    expect(new Set(['t000', 't001', 't002'].map(home)).size).toBe(1);
    expect(home('t010')).toBe(home('t011'));
  });

  it('leaves a party bigger than a group out, with a reason', () => {
    const members = [...people(9, 0, () => ({ orderKey: 'huge' })), ...people(6, 50)];
    const r = matchGroups({ members, spots: spots(20), settings: S });
    expect(r.leftovers.filter((l) => l.reason === 'party_too_big')).toHaveLength(9);
    expect(r.groups.flatMap((g) => g.ticketIds)).toHaveLength(6);
    expect(r.warnings.join(' ')).toMatch(/bigger than a group/);
  });

  it('respects spot capacity and reports leftovers when there is no room', () => {
    const members = people(14);
    const input = { members, spots: spots(6, 4), settings: { ...S, min: 2 } };
    const r = matchGroups(input);
    expect(validateResult(r, input)).toEqual([]);
    expect(r.groups.flatMap((g) => g.ticketIds)).toHaveLength(10);
    expect(r.leftovers).toHaveLength(4);
    expect(r.leftovers.every((l) => l.reason === 'no_room')).toBe(true);
  });

  it('never groups a blocked pair', () => {
    const members = people(8);
    const blocks: [string, string][] = [['u0', 'u1'], ['u2', 'u3']];
    const input = { members, spots: spots(8, 8), settings: { ...S, min: 2, target: 4, max: 4 }, blocks };
    const r = matchGroups(input);
    expect(validateResult(r, input)).toEqual([]);
    expect(r.leftovers).toEqual([]);
  });

  it('leaves someone out (reason blocked) rather than seat a blocked pair', () => {
    const members = people(2);
    const r = matchGroups({ members, spots: spots(10), settings: { ...S, min: 1, target: 2, max: 2 }, blocks: [['u0', 'u1']] });
    expect(r.groups).toHaveLength(1);
    expect(r.leftovers).toEqual([{ ticketId: 't001', reason: 'blocked' }]);
  });

  it('balances on language and age', () => {
    const members = people(12, 0, (i) => ({
      language: i % 2 === 0 ? 'en' : 'fr',
      ageBand: i % 2 === 0 ? '25-34' : '45-54',
    }));
    const r = matchGroups({ members, spots: spots(12), settings: S });
    expect(r.groups).toHaveLength(2);
    for (const g of r.groups) {
      const langs = new Set(g.ticketIds.map((t) => (Number(t.slice(1)) % 2 === 0 ? 'en' : 'fr')));
      expect(langs.size).toBe(1);
      expect(g.score).toBeGreaterThan(0);
    }
  });

  it('merge policy folds a small group into the others', () => {
    // 14 people, target 6 -> 2 groups, max 8: everybody fits in two groups.
    // 14 people in 4 groups -> the groups of 3 (min 4) get folded in.
    const members = people(14);
    const r = matchGroups({ members, spots: spots(40), settings: { ...S, groupCount: 4 }, policy: 'merge' });
    expect(r.groups.length).toBeLessThan(4);
    expect(r.groups.every((g) => g.ticketIds.length >= 4 && g.ticketIds.length <= 8)).toBe(true);
    expect(r.groups.flatMap((g) => g.ticketIds)).toHaveLength(14);
    expect(r.leftovers).toEqual([]);
  });

  it('merge policy keeps a lone small group when there is nowhere to go', () => {
    const r = matchGroups({ members: people(3), spots: spots(10), settings: S, policy: 'merge' });
    expect(r.groups).toHaveLength(1);
    expect(r.groups[0].ticketIds).toHaveLength(3);
    expect(r.warnings.join(' ')).toMatch(/min 4/);
  });

  it('refund policy turns the residue into leftovers', () => {
    const r = matchGroups({ members: people(3), spots: spots(10), settings: S, policy: 'refund' });
    expect(r.groups).toEqual([]);
    expect(r.leftovers.map((l) => l.reason)).toEqual(['undersubscribed', 'undersubscribed', 'undersubscribed']);
  });

  it('refund policy re-homes into groups with room before refunding', () => {
    // 8 + 3 people, max 8: the 3 can't join a full group -> refunded.
    const members = [...people(8), ...people(3, 100)];
    const r = matchGroups({ members, spots: spots(20), settings: { ...S, target: 8, groupCount: 2 }, policy: 'refund' });
    const placed = r.groups.flatMap((g) => g.ticketIds).length;
    expect(placed + r.leftovers.length).toBe(11);
    expect(r.groups.every((g) => g.ticketIds.length >= 4 && g.ticketIds.length <= 8)).toBe(true);
  });

  it('handles nobody, no spots and bad settings', () => {
    expect(matchGroups({ members: [], spots: spots(10), settings: S })).toEqual({ groups: [], leftovers: [], warnings: [] });
    const r = matchGroups({ members: people(5), spots: [], settings: S });
    expect(r.leftovers).toHaveLength(5);
    expect(r.warnings.join(' ')).toMatch(/no spot/);
    expect(() => matchGroups({ members: [], spots: [], settings: { ...S, min: 9 } })).toThrow();
  });

  it('holds the hard rules over many random inputs', () => {
    const rand = prng(20261031);
    for (let k = 0; k < 300; k++) {
      const n = Math.floor(rand() * 40);
      const members: MatchMember[] = Array.from({ length: n }, (_, i) => ({
        ticketId: `k${k}-${String(i).padStart(2, '0')}`,
        userKey: `u${Math.floor(rand() * 30)}`,
        orderKey: `o${Math.floor(rand() * (n * 0.7 + 1))}`,
        partyCode: rand() < 0.1 ? `CODE${Math.floor(rand() * 3)}` : null,
        language: rand() < 0.5 ? 'en' : 'es',
        ageBand: ['18-24', '25-34', '35-44', null][Math.floor(rand() * 4)],
        tags: rand() < 0.5 ? ['food'] : ['music', 'art'],
      }));
      const min = 1 + Math.floor(rand() * 4), target = min + Math.floor(rand() * 3), max = target + Math.floor(rand() * 3);
      const settings = { min, target, max, seed: k, groupCount: rand() < 0.3 ? 1 + Math.floor(rand() * 6) : null };
      const sp = Array.from({ length: 1 + Math.floor(rand() * 4) }, (_, i) => ({ id: `s${i}`, capacity: Math.floor(rand() * 20) }));
      const blocks: [string, string][] = Array.from({ length: Math.floor(rand() * 5) },
        () => [`u${Math.floor(rand() * 30)}`, `u${Math.floor(rand() * 30)}`]);
      const policy = rand() < 0.5 ? 'merge' : 'refund';
      const input = { members, spots: sp, settings, blocks, policy } as const;
      const r = matchGroups(input);
      expect(validateResult(r, input), `case ${k}`).toEqual([]);
      if (policy === 'refund') expect(r.groups.every((g) => g.ticketIds.length >= min), `case ${k} min`).toBe(true);
    }
  });
});
