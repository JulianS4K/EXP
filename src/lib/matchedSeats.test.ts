import { describe, it, expect } from 'vitest';
import {
  answersBody, answersFromRow, configBody, draftFromConfig, EMPTY_ANSWERS, hoursLabel, newPartyCode, refundBatches,
} from './matchedSeats';
import { prng } from './matching';

describe('settings form', () => {
  it('round-trips the defaults', () => {
    const body = configBody(draftFromConfig(null));
    expect(body).toMatchObject({ group_min: 4, group_target: 6, group_max: 8, group_count: null,
      match_hours_before: 24, reveal_hours_before: 3, undersub_policy: 'merge', quiz_languages: ['en'] });
  });

  it('normalizes tags and languages', () => {
    const d = { ...draftFromConfig(null), quizTags: 'Wine, food ,wine,, Hiking', quizLanguages: 'EN, es' };
    expect(configBody(d)).toMatchObject({ quiz_tags: ['food', 'hiking', 'wine'], quiz_languages: ['en', 'es'] });
  });

  it('refuses bad sizes, times and codes', () => {
    const d = draftFromConfig(null);
    expect(() => configBody({ ...d, groupMin: '7' })).toThrow(/smallest/);
    expect(() => configBody({ ...d, groupMax: '2.5' })).toThrow(/whole number/);
    expect(() => configBody({ ...d, revealHoursBefore: '48' })).toThrow(/Reveal/);
    expect(() => configBody({ ...d, quizLanguages: 'english' })).toThrow(/Languages/);
    expect(() => configBody({ ...d, groupCount: '0' })).toThrow(/Number of groups/);
  });
});

describe('quiz', () => {
  const opts = { tags: ['food', 'wine', 'art'], languages: ['en', 'es'] };

  it('keeps only what was answered, first name only', () => {
    expect(answersBody(EMPTY_ANSWERS, opts)).toEqual({ tags: [] });
    expect(answersBody({ ageBand: '25-34', language: 'es', tags: ['food', 'golf', 'food'], mode: 'friends',
      partyCode: 'ab-12x', displayName: '  Ana <b>Lopez ' }, opts)).toEqual({
      age_band: '25-34', language: 'es', tags: ['food'], mode: 'friends', party_code: 'AB12X', display_name: 'Ana',
    });
  });

  it('refuses a birthdate, an unlisted language, a short code, too many tags', () => {
    expect(() => answersBody({ ...EMPTY_ANSWERS, ageBand: '1990-01-01' }, opts)).toThrow();
    expect(() => answersBody({ ...EMPTY_ANSWERS, language: 'fr' }, opts)).toThrow();
    expect(() => answersBody({ ...EMPTY_ANSWERS, partyCode: 'ab' }, opts)).toThrow();
    const many = { tags: ['a', 'b', 'c', 'd', 'e', 'f'], languages: ['en'] };
    expect(() => answersBody({ ...EMPTY_ANSWERS, tags: many.tags }, many)).toThrow(/5/);
  });

  it('reads a stored row', () => {
    expect(answersFromRow({ age_band: '55+', tags: ['art'], mode: 'solo', party_code: 'ABCD' }))
      .toEqual({ ageBand: '55+', language: '', tags: ['art'], mode: 'solo', partyCode: 'ABCD', displayName: '' });
    expect(answersFromRow(null)).toEqual(EMPTY_ANSWERS);
  });

  it('makes readable party codes', () => {
    const c = newPartyCode(prng(1));
    expect(c).toMatch(/^[A-HJ-NP-Z2-9]{6}$/);
    expect(newPartyCode(prng(1))).toBe(c);
  });
});

describe('labels and refunds', () => {
  it('labels hours', () => {
    expect(hoursLabel(0)).toBe('at the start');
    expect(hoursLabel(1)).toBe('1 hour before');
    expect(hoursLabel(24)).toBe('1 day before');
    expect(hoursLabel(72)).toBe('3 days before');
  });

  it('groups paid, active leftovers by order', () => {
    expect(refundBatches([
      { ticketId: 't2', sessionId: 's1', status: 'active', pricePaid: 40 },
      { ticketId: 't1', sessionId: 's1', status: 'active', pricePaid: 40 },
      { ticketId: 't3', sessionId: null, status: 'active', pricePaid: 40 },
      { ticketId: 't4', sessionId: 's2', status: 'voided', pricePaid: 40 },
      { ticketId: 't5', sessionId: 's3', status: 'active', pricePaid: 0 },
    ])).toEqual([{ sessionId: 's1', ticketIds: ['t1', 't2'] }]);
  });
});
