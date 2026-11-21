// Wave-9 leftovers (claude/exos-leftovers-9, mig 20261110120000): the pure
// parts. Reservation answers (sales.ts reservationAnswersParam, the 422
// questions_required body), the add-on wallet rule, the event report's audit
// footer and the Activity link it opens.
import { describe, expect, it } from 'vitest';
import { ParamError, reservationAnswersParam } from '../../supabase/functions/_shared/partners/sales.ts';
import { questionsRequiredBody, rpcAnswer, RPC_STATUS } from '../../supabase/functions/_shared/api/request.ts';
import { matchRoute } from '../../supabase/functions/_shared/api/routes.ts';
import { addonWalletEligible, walletErrorMessage } from './walletButtons';
import { activityLink, auditFooterText, eventFilterFromSearch, parseEventAuditSummary } from './orgAudit';

const Q = '5b0c8a2e-1f3d-4c6e-9a7b-2d4e6f8a0c1e';
const E = '3f6b2c1e-8a4d-4e2f-9b1a-7c5d0e9f2a14';
const O = '8c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f';

describe('reservation answers', () => {
  it('reads them from the wrapper or the top level', () => {
    const a = { order: { [Q]: 'Acme' }, tickets: [{ [Q]: 'L' }] };
    expect(reservationAnswersParam({ ticket_reservation: { answers: a } }, 'ticket_reservation')).toEqual(a);
    expect(reservationAnswersParam({ answers: a, ticket_reservation: {} }, 'ticket_reservation')).toEqual(a);
    expect(reservationAnswersParam({ comp: { answers: a } }, 'comp')).toEqual(a);
  });
  it('is undefined when none were sent', () => {
    expect(reservationAnswersParam({ ticket_reservation: { first_name: 'Ann' } }, 'ticket_reservation')).toBeUndefined();
    expect(reservationAnswersParam({ answers: null }, 'ticket_reservation')).toBeUndefined();
    expect(reservationAnswersParam(null, 'ticket_reservation')).toBeUndefined();
  });
  it('turns a Rails form tickets hash into a list, in index order', () => {
    const out = reservationAnswersParam({ ticket_reservation: { answers: { tickets: { 1: { [Q]: 'M' }, 0: { [Q]: 'S' } } } } }, 'ticket_reservation');
    expect(out?.tickets).toEqual([{ [Q]: 'S' }, { [Q]: 'M' }]);
  });
  it('refuses what is not an object, and a tickets hash with other keys', () => {
    expect(() => reservationAnswersParam({ answers: 'yes' }, 'ticket_reservation')).toThrow(ParamError);
    expect(() => reservationAnswersParam({ answers: [1] }, 'ticket_reservation')).toThrow(ParamError);
    expect(() => reservationAnswersParam({ answers: { tickets: { a: {} } } }, 'ticket_reservation')).toThrow(/a list/);
    expect(() => reservationAnswersParam({ answers: { order: { [Q]: 'x'.repeat(100_001) } } }, 'ticket_reservation')).toThrow(/too long/);
  });
});

describe('a partner reservation without the required answers', () => {
  it('answers 422 questions_required with each missing question', () => {
    const a = rpcAnswer({
      code: 'EXQRQ',
      message: 'answer the event\'s required checkout questions (2 unanswered, first: "Company")',
      details: JSON.stringify([{ question_id: Q, label: 'Company', ticket: null }, { question_id: Q, label: 'Size', ticket: 2 }]),
    });
    expect(RPC_STATUS.EXQRQ).toBe(422);
    expect(a?.status).toBe(422);
    expect(a?.body).toMatchObject({
      reason: 'questions_required',
      missing: [{ question_id: Q, label: 'Company', ticket: null }, { question_id: Q, label: 'Size', ticket: 2 }],
    });
  });
  it('keeps the reason with an empty list when the detail is not ours', () => {
    expect(questionsRequiredBody({ details: 'garbage' })).toEqual({ reason: 'questions_required', missing: [] });
    expect(questionsRequiredBody({ details: JSON.stringify([{ label: 'no id' }, { question_id: Q, ticket: -1, label: 3 }]) }))
      .toEqual({ reason: 'questions_required', missing: [{ question_id: Q, label: null, ticket: null }] });
    expect(questionsRequiredBody(null).missing).toEqual([]);
  });
  it('the questions route is a partner-key route', () => {
    const m = matchRoute('GET', `/public/confirms/${E}/questions`);
    expect(m?.route.id).toBe('public-list-questions');
    expect(m?.route.auth).toBe('partner_key');
    expect(m?.params.id).toBe(E);
  });
});

describe('add-on wallet buttons', () => {
  it('only for a usable unit whose code is drawn here', () => {
    expect(addonWalletEligible({ status: 'active', barcodeSecret: 's' })).toBe(true);
    expect(addonWalletEligible({ status: 'used', barcodeSecret: 's' })).toBe(false);
    expect(addonWalletEligible({ status: 'voided', barcodeSecret: null })).toBe(false);
    expect(addonWalletEligible({ status: 'active', barcodeSecret: null })).toBe(false);
  });
  it('says why the add-on route refused', () => {
    expect(walletErrorMessage('voided')).toMatch(/refunded/);
    expect(walletErrorMessage('not your add-on')).toMatch(/add-on holder/);
  });
});

describe('the event report audit footer', () => {
  const date = (iso: string) => iso.slice(0, 10);
  it('parses the summary', () => {
    expect(parseEventAuditSummary({ event_id: E, org_id: O, published_at: '2026-11-09T12:00:00Z', changes_since_publish: 3, changes_total: 7 }))
      .toEqual({ eventId: E, orgId: O, publishedAt: '2026-11-09T12:00:00Z', changesSincePublish: 3, changesTotal: 7 });
    expect(parseEventAuditSummary({ event_id: E, org_id: O, published_at: null, changes_since_publish: null, changes_total: '2' }))
      .toEqual({ eventId: E, orgId: O, publishedAt: null, changesSincePublish: null, changesTotal: 2 });
    expect(parseEventAuditSummary(null)).toBeNull();
    expect(parseEventAuditSummary({ event_id: 1 })).toBeNull();
  });
  it('words the count', () => {
    const s = parseEventAuditSummary({ event_id: E, org_id: O, published_at: '2026-11-09T12:00:00Z', changes_since_publish: 1, changes_total: 4 });
    expect(auditFooterText(s, date)).toBe('1 change since publish (2026-11-09)');
    expect(auditFooterText(s && { ...s, changesSincePublish: 5 }, date)).toBe('5 changes since publish (2026-11-09)');
    expect(auditFooterText(s && { ...s, changesSincePublish: 0 }, date)).toBe('No changes since publish (2026-11-09)');
    expect(auditFooterText(s && { ...s, publishedAt: null, changesSincePublish: null }, date)).toBe('4 changes logged');
    expect(auditFooterText(s && { ...s, publishedAt: null, changesSincePublish: null, changesTotal: 0 }, date)).toBeNull();
    expect(auditFooterText(null, date)).toBeNull();
  });
  it('links to Org → Activity for the event, and Activity reads it back', () => {
    const href = activityLink(O, E);
    expect(href).toBe(`/orgs/${O}/activity?event=${E}`);
    expect(eventFilterFromSearch(href.slice(href.indexOf('?')))).toBe(E);
    expect(eventFilterFromSearch(`?event=${E.toUpperCase()}`)).toBe(E);
    expect(eventFilterFromSearch('?event=nope')).toBeNull();
    expect(eventFilterFromSearch('')).toBeNull();
  });
});
