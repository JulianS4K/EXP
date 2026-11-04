// Matched seats (Timeleft / 222 style): group ticket holders into tables or
// crews. Pure and deterministic: the same input and seed always give the same
// groups. No Math.random, no Date, no I/O.
//
// This file is copied byte for byte to supabase/functions/_shared/matching.ts
// (the exos-match edge function runs it); matchingParity.test.ts fails if the
// two drift. The database re-checks every hard rule when the result is stored
// (exos_match_apply, mig 20261031210000), so a bug here can't split a party,
// overfill a spot or seat a blocked pair.
//
// Hard rules:
//   * a party (one order, or one party code, joined transitively) is never split
//   * no group above `max`; the people at one spot never exceed its capacity
//   * a blocked pair is never in the same group
// Soft goals (a simple score): fill groups toward `target`, same language,
// near age band, shared interest tags, and avoid two friend groups at one table.

export type AgeBand = '18-24' | '25-34' | '35-44' | '45-54' | '55+';
export const AGE_BANDS: readonly AgeBand[] = ['18-24', '25-34', '35-44', '45-54', '55+'];

export interface MatchMember {
  ticketId: string;
  /** Who holds the ticket (user id, or 'email:...' for a guest). Blocks use it. */
  userKey: string;
  /** Tickets bought together (order ref). Same key = same party. */
  orderKey: string;
  /** Party code from the quiz; the same code also joins a party. */
  partyCode?: string | null;
  ageBand?: string | null;
  language?: string | null;
  tags?: readonly string[] | null;
}

export interface MatchSpot {
  id: string;
  /** People this spot can seat across all of its groups. */
  capacity: number;
}

export interface MatchSettings {
  min: number;
  target: number;
  max: number;
  /** Fixed number of groups; omitted or null = derive it. */
  groupCount?: number | null;
  seed: number;
}

export type UndersubscribedPolicy = 'merge' | 'refund';

export interface MatchGroup {
  spotId: string;
  ticketIds: string[];
  score: number;
}

export type LeftoverReason = 'party_too_big' | 'no_room' | 'blocked' | 'undersubscribed';

export interface MatchResult {
  groups: MatchGroup[];
  leftovers: { ticketId: string; reason: LeftoverReason }[];
  warnings: string[];
}

export interface Party {
  key: string;
  members: MatchMember[];
}

// ---------------------------------------------------------------------------
// Seeded PRNG (mulberry32) and a stable shuffle.
// ---------------------------------------------------------------------------
export function prng(seed: number): () => number {
  let a = (Math.trunc(seed) >>> 0) || 0x9e3779b9;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function shuffle<T>(xs: T[], rand: () => number): T[] {
  const a = xs.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

const byStr = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

// ---------------------------------------------------------------------------
// Parties: union of "same order" and "same party code".
// ---------------------------------------------------------------------------
/**
 * Parties. One order always stays together. A party code joins parties only
 * when that wouldn't put a blocked pair together (a code is self-chosen, so it
 * must not be a way around a block).
 */
export function buildParties(members: readonly MatchMember[], blocked: Set<string> = new Set()): Party[] {
  const sorted = members.slice().sort((a, b) => byStr(a.ticketId, b.ticketId));
  const parent = new Map<string, string>();
  const find = (x: string): string => {
    let r = x;
    while (parent.get(r) !== r) r = parent.get(r)!;
    let c = x;
    while (parent.get(c) !== r) { const n = parent.get(c)!; parent.set(c, r); c = n; }
    return r;
  };
  const union = (a: string, b: string) => {
    const ra = find(a), rb = find(b);
    if (ra === rb) return;
    if (ra < rb) parent.set(rb, ra); else parent.set(ra, rb);
  };
  for (const m of sorted) parent.set(m.ticketId, m.ticketId);
  const users = new Map<string, Set<string>>();   // root -> user keys in it
  for (const m of sorted) users.set(m.ticketId, new Set([m.userKey]));
  const join = (a: string, b: string, checkBlocks: boolean) => {
    const ra = find(a), rb = find(b);
    if (ra === rb) return;
    const ua = users.get(ra)!, ub = users.get(rb)!;
    if (checkBlocks && blocked.size > 0) {
      for (const x of ua) for (const y of ub) if (blocked.has(x + '|' + y)) return;
    }
    union(ra, rb);
    users.set(find(ra), new Set([...ua, ...ub]));
  };
  for (const pass of ['o', 'c'] as const) {
    const firstBy = new Map<string, string>();
    for (const m of sorted) {
      const k = pass === 'o' ? m.orderKey : normalizePartyCode(m.partyCode);
      if (!k) continue;
      const f = firstBy.get(k);
      if (f === undefined) firstBy.set(k, m.ticketId); else join(f, m.ticketId, pass === 'c');
    }
  }
  const groups = new Map<string, MatchMember[]>();
  for (const m of sorted) {
    const r = find(m.ticketId);
    const g = groups.get(r);
    if (g) g.push(m); else groups.set(r, [m]);
  }
  return [...groups.entries()].sort((a, b) => byStr(a[0], b[0]))
    .map(([key, ms]) => ({ key, members: ms }));
}

export function normalizePartyCode(code: string | null | undefined): string | null {
  const c = String(code ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  return c.length >= 4 && c.length <= 12 ? c : null;
}

// ---------------------------------------------------------------------------
// How many groups, and which spot each one sits at.
// ---------------------------------------------------------------------------
export function deriveGroupCount(total: number, s: MatchSettings): number {
  if (total <= 0) return 0;
  if (s.groupCount != null && s.groupCount > 0) return Math.floor(s.groupCount);
  let n = Math.max(1, Math.round(total / s.target));
  if (n * s.max < total) n = Math.ceil(total / s.max);
  while (n > 1 && n * s.min > total) n--;
  return n;
}

/** Spot for each group: the spot with the most seats left after `target` per group. */
export function planSpots(n: number, spots: readonly MatchSpot[], s: MatchSettings): string[] {
  const left = spots.map((sp) => ({ id: sp.id, left: Math.max(0, Math.floor(sp.capacity)) }));
  const out: string[] = [];
  for (let g = 0; g < n; g++) {
    let best = -1;
    for (let i = 0; i < left.length; i++) {
      if (left[i].left < s.min) continue;
      if (best < 0 || left[i].left > left[best].left) best = i;
    }
    if (best < 0) break;
    out.push(left[best].id);
    left[best].left -= Math.min(s.target, left[best].left);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Score of adding a party to a group (higher is better).
// ---------------------------------------------------------------------------
interface Slot {
  spotId: string;
  members: MatchMember[];
  partySizes: number[];
}

function ageIndex(b: string | null | undefined): number {
  return AGE_BANDS.indexOf(String(b ?? '') as AgeBand);
}

export function affinity(a: MatchMember, b: MatchMember): number {
  let s = 0;
  const la = a.language ?? null, lb = b.language ?? null;
  if (la && lb) s += la === lb ? 3 : -3;
  const ia = ageIndex(a.ageBand), ib = ageIndex(b.ageBand);
  if (ia >= 0 && ib >= 0) s += Math.max(-2, 2 - Math.abs(ia - ib) * 1.5);
  const ta = new Set(a.tags ?? []), tb = new Set(b.tags ?? []);
  if (ta.size > 0 && tb.size > 0) {
    let shared = 0;
    for (const t of ta) if (tb.has(t)) shared++;
    s += 1.5 * (shared / (ta.size + tb.size - shared));
  }
  return s;
}

function addScore(slot: Slot, party: Party, s: MatchSettings): number {
  const size = slot.members.length, p = party.members.length;
  let score = 4 * (s.target - size) / s.target;      // fill the emptiest first
  if (size + p > s.target) score -= 3 * (size + p - s.target);
  if (size > 0) {
    let sum = 0;
    for (const a of party.members) for (const b of slot.members) sum += affinity(a, b);
    score += sum / (p * size);
  }
  if (p >= 2 && slot.partySizes.some((x) => x >= 2)) score -= 1;
  return score;
}

function groupScore(ms: readonly MatchMember[]): number {
  if (ms.length < 2) return 0;
  let sum = 0, n = 0;
  for (let i = 0; i < ms.length; i++) for (let j = i + 1; j < ms.length; j++) { sum += affinity(ms[i], ms[j]); n++; }
  return Math.round((sum / n) * 1000) / 1000;
}

export function blockSet(blocks: readonly (readonly [string, string])[]): Set<string> {
  const out = new Set<string>();
  for (const [a, b] of blocks) { if (a && b && a !== b) { out.add(a + '|' + b); out.add(b + '|' + a); } }
  return out;
}

function conflicts(party: Party, members: readonly MatchMember[], blocked: Set<string>): boolean {
  if (blocked.size === 0) return false;
  for (const a of party.members) for (const b of members) if (blocked.has(a.userKey + '|' + b.userKey)) return true;
  return false;
}

// ---------------------------------------------------------------------------
// Main entry point.
// ---------------------------------------------------------------------------
export function matchGroups(input: {
  members: readonly MatchMember[];
  spots: readonly MatchSpot[];
  settings: MatchSettings;
  blocks?: readonly (readonly [string, string])[];
  policy?: UndersubscribedPolicy;
}): MatchResult {
  const s = input.settings;
  const warnings: string[] = [];
  if (!(s.min >= 1 && s.min <= s.target && s.target <= s.max)) {
    throw new Error('matching: group sizes must satisfy 1 <= min <= target <= max');
  }
  const blocked = blockSet(input.blocks ?? []);
  const rand = prng(s.seed);
  const leftovers: { ticketId: string; reason: LeftoverReason }[] = [];
  const spotCap = new Map(input.spots.map((sp) => [sp.id, Math.max(0, Math.floor(sp.capacity))]));
  const spotLoad = new Map(input.spots.map((sp) => [sp.id, 0]));

  // Parties: too big for any group -> leftovers; the rest shuffled by seed,
  // then biggest first (stable), so packing is good and ties are seeded.
  const all = buildParties(input.members, blocked);
  const fits: Party[] = [];
  for (const party of all) {
    if (conflicts(party, party.members, blocked)) {
      // One order holding a blocked pair (a ticket was passed on): staff decide.
      for (const m of party.members) leftovers.push({ ticketId: m.ticketId, reason: 'blocked' });
      warnings.push('one order holds a blocked pair; left for staff');
    } else if (party.members.length > s.max) {
      for (const m of party.members) leftovers.push({ ticketId: m.ticketId, reason: 'party_too_big' });
      warnings.push(`party of ${party.members.length} is bigger than a group (max ${s.max})`);
    } else fits.push(party);
  }
  const order = shuffle(fits, rand).map((p, i) => ({ p, i }))
    .sort((a, b) => b.p.members.length - a.p.members.length || a.i - b.i)
    .map((x) => x.p);

  const total = order.reduce((n, p) => n + p.members.length, 0);
  const plan = planSpots(deriveGroupCount(total, s), input.spots, s);
  if (total > 0 && plan.length === 0) warnings.push('no spot can seat a group of the minimum size');
  const slots: Slot[] = plan.map((spotId) => ({ spotId, members: [], partySizes: [] }));

  const place = (party: Party, candidates: Slot[]): Slot | null => {
    const p = party.members.length;
    let best: Slot | null = null, bestScore = -Infinity;
    for (const slot of candidates) {
      if (slot.members.length + p > s.max) continue;
      if ((spotLoad.get(slot.spotId) ?? 0) + p > (spotCap.get(slot.spotId) ?? 0)) continue;
      if (conflicts(party, slot.members, blocked)) continue;
      const sc = addScore(slot, party, s);
      if (sc > bestScore + 1e-9) { best = slot; bestScore = sc; }
    }
    if (best) {
      best.members.push(...party.members);
      best.partySizes.push(p);
      spotLoad.set(best.spotId, (spotLoad.get(best.spotId) ?? 0) + p);
    }
    return best;
  };

  const partyOf = new Map<string, Party>();
  for (const party of order) for (const m of party.members) partyOf.set(m.ticketId, party);

  for (const party of order) {
    if (place(party, slots)) continue;
    const roomless = slots.every((sl) => sl.members.length + party.members.length > s.max
      || (spotLoad.get(sl.spotId) ?? 0) + party.members.length > (spotCap.get(sl.spotId) ?? 0));
    const reason: LeftoverReason = roomless || slots.length === 0 ? 'no_room' : 'blocked';
    for (const m of party.members) leftovers.push({ ticketId: m.ticketId, reason });
  }

  // Undersubscribed groups (below min): re-home their parties into the other
  // groups where they fit. What's left: merge -> combine the small groups
  // (kept even if still small); refund -> leftovers.
  const policy = input.policy ?? 'merge';
  const take = (slot: Slot): Party[] => {
    const seen = new Set<string>(), ps: Party[] = [];
    for (const m of slot.members) {
      const p = partyOf.get(m.ticketId)!;
      if (!seen.has(p.key)) { seen.add(p.key); ps.push(p); }
    }
    spotLoad.set(slot.spotId, (spotLoad.get(slot.spotId) ?? 0) - slot.members.length);
    slot.members = [];
    slot.partySizes = [];
    return ps;
  };
  const kept = new Set<Slot>();
  for (;;) {
    const small = slots.filter((sl) => !kept.has(sl) && sl.members.length > 0 && sl.members.length < s.min)
      .sort((a, b) => a.members.length - b.members.length || slots.indexOf(a) - slots.indexOf(b));
    if (small.length === 0) break;
    const victim = small[0];
    const parties = take(victim);
    const others = slots.filter((sl) => sl !== victim && sl.members.length > 0);
    const homeless = parties.filter((p) => !place(p, others));
    if (homeless.length === 0) continue;               // dissolved into the others
    if (policy === 'refund') {
      for (const p of homeless) for (const m of p.members) leftovers.push({ ticketId: m.ticketId, reason: 'undersubscribed' });
      continue;
    }
    // merge: whoever couldn't move stays together (they fit before), kept small.
    for (const p of homeless) place(p, [victim]);
    kept.add(victim);
    warnings.push(`a group at spot ${victim.spotId} has ${victim.members.length} (min ${s.min})`);
  }

  const groups = slots.filter((sl) => sl.members.length > 0).map((sl) => ({
    spotId: sl.spotId,
    ticketIds: sl.members.map((m) => m.ticketId).sort(byStr),
    score: groupScore(sl.members),
  }));
  leftovers.sort((a, b) => byStr(a.ticketId, b.ticketId));
  return { groups, leftovers, warnings };
}

/** Hard-rule check (the SQL side re-runs the same checks). Empty = valid. */
export function validateResult(
  result: MatchResult,
  input: { members: readonly MatchMember[]; spots: readonly MatchSpot[]; settings: MatchSettings;
    blocks?: readonly (readonly [string, string])[] },
): string[] {
  const errs: string[] = [];
  const where = new Map<string, number>();
  result.groups.forEach((g, i) => g.ticketIds.forEach((t) => {
    if (where.has(t)) errs.push(`ticket ${t} placed twice`);
    where.set(t, i);
  }));
  for (const l of result.leftovers) {
    if (where.has(l.ticketId)) errs.push(`ticket ${l.ticketId} is both placed and left over`);
    where.set(l.ticketId, -1);
  }
  for (const m of input.members) if (!where.has(m.ticketId)) errs.push(`ticket ${m.ticketId} missing`);
  for (const p of buildParties(input.members, blockSet(input.blocks ?? []))) {
    const gs = new Set(p.members.map((m) => where.get(m.ticketId)));
    if (gs.size > 1) errs.push(`party ${p.key} split`);
  }
  const load = new Map<string, number>();
  result.groups.forEach((g) => {
    if (g.ticketIds.length > input.settings.max) errs.push(`group at ${g.spotId} above max`);
    load.set(g.spotId, (load.get(g.spotId) ?? 0) + g.ticketIds.length);
  });
  for (const sp of input.spots) if ((load.get(sp.id) ?? 0) > sp.capacity) errs.push(`spot ${sp.id} over capacity`);
  const blocked = blockSet(input.blocks ?? []);
  const byTicket = new Map(input.members.map((m) => [m.ticketId, m]));
  for (const g of result.groups) {
    const ms = g.ticketIds.map((t) => byTicket.get(t)!).filter(Boolean);
    for (let i = 0; i < ms.length; i++) for (let j = i + 1; j < ms.length; j++) {
      if (blocked.has(ms[i].userKey + '|' + ms[j].userKey)) errs.push(`blocked pair grouped at ${g.spotId}`);
    }
  }
  return errs;
}
