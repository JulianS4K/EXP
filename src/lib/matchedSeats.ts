// Matched seats (mig 20261031210000): pure helpers for the staff settings
// form, the checkout quiz and the ticket panel. The grouping itself is
// ./matching.ts; every rule here is checked again in SQL.

import { AGE_BANDS, normalizePartyCode } from './matching';

export { AGE_BANDS };

export type UndersubPolicy = 'merge' | 'refund';

export interface MatchConfig {
  tierId: string;
  groupMin: number;
  groupTarget: number;
  groupMax: number;
  groupCount: number | null;
  matchHoursBefore: number;
  revealHoursBefore: number;
  undersubPolicy: UndersubPolicy;
  quizEnabled: boolean;
  quizTags: string[];
  quizLanguages: string[];
  retentionDays: number;
  status: 'open' | 'matched' | 'revealed';
}

export const DEFAULT_CONFIG: Omit<MatchConfig, 'tierId' | 'status'> = {
  groupMin: 4, groupTarget: 6, groupMax: 8, groupCount: null,
  matchHoursBefore: 24, revealHoursBefore: 3, undersubPolicy: 'merge',
  quizEnabled: true, quizTags: [], quizLanguages: ['en'], retentionDays: 14,
};

/** Strings from the settings form. */
export interface ConfigDraft {
  groupMin: string; groupTarget: string; groupMax: string; groupCount: string;
  matchHoursBefore: string; revealHoursBefore: string; undersubPolicy: UndersubPolicy;
  quizEnabled: boolean; quizTags: string; quizLanguages: string; retentionDays: string;
}

export function draftFromConfig(c?: Partial<MatchConfig> | null): ConfigDraft {
  const d = { ...DEFAULT_CONFIG, ...(c ?? {}) };
  return {
    groupMin: String(d.groupMin), groupTarget: String(d.groupTarget), groupMax: String(d.groupMax),
    groupCount: d.groupCount == null ? '' : String(d.groupCount),
    matchHoursBefore: String(d.matchHoursBefore), revealHoursBefore: String(d.revealHoursBefore),
    undersubPolicy: d.undersubPolicy, quizEnabled: d.quizEnabled,
    quizTags: d.quizTags.join(', '), quizLanguages: d.quizLanguages.join(', '),
    retentionDays: String(d.retentionDays),
  };
}

function int(s: string, name: string, lo: number, hi: number): number {
  const n = Number(String(s).trim());
  if (!Number.isInteger(n) || n < lo || n > hi) throw new Error(`${name}: a whole number from ${lo} to ${hi}.`);
  return n;
}

function list(s: string): string[] {
  return [...new Set(String(s).split(',').map((x) => x.trim().toLowerCase()).filter(Boolean))].sort();
}

/** Form strings -> the RPC body (exos_match_set_config). Throws a readable error. */
export function configBody(d: ConfigDraft): Record<string, unknown> {
  const groupMin = int(d.groupMin, 'Smallest group', 1, 50);
  const groupTarget = int(d.groupTarget, 'Ideal group', 1, 50);
  const groupMax = int(d.groupMax, 'Largest group', 1, 50);
  if (!(groupMin <= groupTarget && groupTarget <= groupMax)) {
    throw new Error('Group sizes: smallest ≤ ideal ≤ largest.');
  }
  const groupCount = d.groupCount.trim() === '' ? null : int(d.groupCount, 'Number of groups', 1, 500);
  const matchHoursBefore = int(d.matchHoursBefore, 'Match cutoff', 1, 720);
  const revealHoursBefore = int(d.revealHoursBefore, 'Reveal', 0, 720);
  if (revealHoursBefore > matchHoursBefore) throw new Error('Reveal comes after matching: use fewer hours for the reveal.');
  const tags = list(d.quizTags);
  if (tags.length > 20) throw new Error('Up to 20 interests.');
  if (tags.some((t) => !/^[a-z0-9][a-z0-9 &/-]{0,29}$/.test(t))) throw new Error('Interests: up to 30 letters, digits or spaces each.');
  const langs = list(d.quizLanguages);
  if (langs.length < 1 || langs.length > 10 || langs.some((l) => !/^[a-z]{2,3}$/.test(l))) {
    throw new Error('Languages: 1 to 10 two-letter codes, like en, es.');
  }
  return {
    group_min: groupMin, group_target: groupTarget, group_max: groupMax, group_count: groupCount,
    match_hours_before: matchHoursBefore, reveal_hours_before: revealHoursBefore,
    undersub_policy: d.undersubPolicy, quiz_enabled: d.quizEnabled,
    quiz_tags: tags, quiz_languages: langs,
    retention_days: int(d.retentionDays, 'Keep answers', 1, 90),
  };
}

export interface QuizAnswers {
  ageBand: string;
  language: string;
  tags: string[];
  mode: '' | 'solo' | 'friends';
  partyCode: string;
  displayName: string;
}

export const EMPTY_ANSWERS: QuizAnswers = { ageBand: '', language: '', tags: [], mode: '', partyCode: '', displayName: '' };

/** Quiz -> the RPC body. Blank fields stay out (nothing is required). */
export function answersBody(a: QuizAnswers, options: { tags: string[]; languages: string[] }): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (a.ageBand) {
    if (!(AGE_BANDS as readonly string[]).includes(a.ageBand)) throw new Error('Pick an age band.');
    out.age_band = a.ageBand;
  }
  if (a.language) {
    if (!options.languages.includes(a.language)) throw new Error('Pick one of the listed languages.');
    out.language = a.language;
  }
  const tags = [...new Set(a.tags)].filter((t) => options.tags.includes(t));
  if (tags.length > 5) throw new Error('Pick up to 5 interests.');
  out.tags = tags;
  if (a.mode) out.mode = a.mode;
  if (a.partyCode.trim()) {
    const code = normalizePartyCode(a.partyCode);
    if (!code) throw new Error('A party code is 4 to 12 letters or digits.');
    out.party_code = code;
  }
  const first = a.displayName.trim().split(/\s+/)[0]?.replace(/[<>"&]/g, '').slice(0, 40) ?? '';
  if (first) out.display_name = first;
  return out;
}

export function answersFromRow(r: any): QuizAnswers {
  if (!r || typeof r !== 'object') return { ...EMPTY_ANSWERS };
  return {
    ageBand: r.age_band ?? '', language: r.language ?? '',
    tags: Array.isArray(r.tags) ? r.tags.map(String) : [],
    mode: r.mode === 'solo' || r.mode === 'friends' ? r.mode : '',
    partyCode: r.party_code ?? '', displayName: r.display_name ?? '',
  };
}

/** A short random party code to share with friends (no 0/O/1/I). */
export function newPartyCode(rand: () => number = Math.random): string {
  const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let s = '';
  for (let i = 0; i < 6; i++) s += abc[Math.floor(rand() * abc.length)];
  return s;
}

export function hoursLabel(h: number): string {
  if (h === 0) return 'at the start';
  if (h % 24 === 0) return `${h / 24} day${h === 24 ? '' : 's'} before`;
  return `${h} hour${h === 1 ? '' : 's'} before`;
}

export const LEFTOVER_REASON: Record<string, string> = {
  party_too_big: 'Party bigger than a group',
  no_room: 'No room left',
  blocked: 'Blocked pair',
  undersubscribed: 'Group too small',
  late: 'Bought after matching',
  removed: 'Removed',
};

/** Leftovers the staff panel can refund through exos-refund, one call per order. */
export function refundBatches(
  leftovers: { ticketId: string; sessionId: string | null; status: string; pricePaid: number }[],
): { sessionId: string; ticketIds: string[] }[] {
  const by = new Map<string, string[]>();
  for (const l of leftovers) {
    if (!l.sessionId || l.status !== 'active' || !(l.pricePaid > 0)) continue;
    const xs = by.get(l.sessionId);
    if (xs) xs.push(l.ticketId); else by.set(l.sessionId, [l.ticketId]);
  }
  return [...by.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))
    .map(([sessionId, ticketIds]) => ({ sessionId, ticketIds: ticketIds.sort() }));
}
