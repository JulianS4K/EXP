// Scoring an Exos event against a marketplace's catalog events. Conservative
// on purpose: a wrong link routes a buyer to someone else's show, a missed
// one only means a human links it. So an automatic link needs the same local
// day, a close start time, and a strong name match, and a clear lead over the
// runner-up; anything weaker is a "review" for a human.

import { localDate, type EventCandidate, type ExosEventRef } from './channel.ts';

export interface ScoredCandidate {
  candidate: EventCandidate;
  score: number;
  reasons: string[];
}

export type MatchDecision =
  | { decision: 'link'; best: ScoredCandidate; candidates: ScoredCandidate[] }
  | { decision: 'review'; best: ScoredCandidate; candidates: ScoredCandidate[] }
  | { decision: 'none'; best: null; candidates: ScoredCandidate[] };

export const AUTO_LINK_SCORE = 0.8;
export const REVIEW_SCORE = 0.5;
/** An automatic link must beat the runner-up by at least this much. */
export const AUTO_LINK_MARGIN = 0.15;

const STOP = new Set(['the', 'a', 'an', 'and', 'of', 'at', 'in', 'on', 'with', 'tickets', 'live', 'presents', 'vs', 'v']);

export function tokens(s: string | null | undefined): Set<string> {
  const out = new Set<string>();
  for (const t of (s ?? '')
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/&/g, ' and ')
    .split(/[^a-z0-9]+/)) {
    if (t && !STOP.has(t)) out.add(t);
  }
  return out;
}

/** Overlap of two token sets, relative to the smaller one (0..1). */
export function overlap(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 || b.size === 0) return 0;
  let n = 0;
  for (const t of a) if (b.has(t)) n++;
  return n / Math.min(a.size, b.size);
}

function candidateLocalDate(c: EventCandidate): string | null {
  const m = /^(\d{4}-\d{2}-\d{2})/.exec(c.startsLocal ?? '');
  return m ? m[1] : null;
}

/** 0..1. Date gates everything: a different local day scores 0. */
export function scoreMatch(ev: ExosEventRef, c: EventCandidate): ScoredCandidate {
  const reasons: string[] = [];
  const evDay = localDate(ev);
  const cDay = candidateLocalDate(c) ?? (c.startsAt ? new Date(c.startsAt).toISOString().slice(0, 10) : null);
  if (!cDay || cDay !== evDay) {
    return { candidate: c, score: 0, reasons: [`different day (${cDay ?? 'unknown'} vs ${evDay})`] };
  }
  let score = 0.3;
  reasons.push('same day');

  if (c.startsAt) {
    const hours = Math.abs(Date.parse(c.startsAt) - Date.parse(ev.startsAt)) / 3_600_000;
    if (hours <= 0.5) { score += 0.15; reasons.push('same start time'); }
    else if (hours <= 3) { score += 0.05; reasons.push(`start ${hours.toFixed(1)}h apart`); }
    else { score -= 0.1; reasons.push(`start ${hours.toFixed(1)}h apart`); }
  }

  const name = overlap(tokens(ev.name), tokens(c.name));
  score += 0.4 * name;
  reasons.push(`name ${Math.round(name * 100)}%`);

  const venue = overlap(tokens(ev.venueName), tokens(c.venueName));
  score += 0.1 * venue;
  if (venue > 0) reasons.push(`venue ${Math.round(venue * 100)}%`);

  if (ev.venueCity && c.venueCity) {
    if (ev.venueCity.trim().toLowerCase() === c.venueCity.trim().toLowerCase()) {
      score += 0.05;
      reasons.push('same city');
    } else {
      score -= 0.2;
      reasons.push('different city');
    }
  }
  return { candidate: c, score: Math.max(0, Math.min(1, Math.round(score * 1000) / 1000)), reasons };
}

export function decideMatch(ev: ExosEventRef, candidates: EventCandidate[]): MatchDecision {
  const scored = candidates.map((c) => scoreMatch(ev, c)).sort((a, b) => b.score - a.score);
  const [best, second] = scored;
  if (!best || best.score < REVIEW_SCORE) return { decision: 'none', best: null, candidates: scored };
  const clear = !second || best.score - second.score >= AUTO_LINK_MARGIN;
  if (best.score >= AUTO_LINK_SCORE && clear) return { decision: 'link', best, candidates: scored };
  return { decision: 'review', best, candidates: scored };
}
