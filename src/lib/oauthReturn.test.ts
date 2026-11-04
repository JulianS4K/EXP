import { describe, expect, it } from 'vitest';
import {
  confirmPrompt, finishBody, finishReducer, initialStep, readOAuthReturn, refusalMessage, stripOAuthHash, stripOAuthReturn,
  type FinishStep,
} from './oauthReturn';
import { finishRefusal, withFinishFragment } from '../../supabase/functions/_shared/oauthFinish.ts';

const S = 'S'.repeat(43);
const T = 'T'.repeat(42) + '_';

describe('OAuth return: the finish token comes from the fragment', () => {
  it('reads a finish with the state in the query and the token in the hash', () => {
    expect(readOAuthReturn(`?eventbrite=finish&eventbrite_state=${S}`, `#eventbrite_finish=${T}`))
      .toEqual({ provider: 'eventbrite', kind: 'finish', state: S, finish: T });
    expect(readOAuthReturn(`?tab=x&google_ads=finish&google_ads_state=${S}`, `#google_ads_finish=${T}`))
      .toEqual({ provider: 'google_ads', kind: 'finish', state: S, finish: T });
  });

  it('refuses a finish without a token in the fragment', () => {
    expect(readOAuthReturn(`?eventbrite=finish&eventbrite_state=${S}`, '')).toEqual({ provider: 'eventbrite', kind: 'error', reason: 'token' });
    // A token in the query (where servers would see it) doesn't count.
    expect(readOAuthReturn(`?eventbrite=finish&eventbrite_state=${S}&eventbrite_finish=${T}`, ''))
      .toEqual({ provider: 'eventbrite', kind: 'error', reason: 'token' });
    // Another provider's token doesn't count either.
    expect(readOAuthReturn(`?eventbrite=finish&eventbrite_state=${S}`, `#google_ads_finish=${T}`))
      .toEqual({ provider: 'eventbrite', kind: 'error', reason: 'token' });
    expect(readOAuthReturn(`?eventbrite=finish&eventbrite_state=${S}`, '#eventbrite_finish=short'))
      .toEqual({ provider: 'eventbrite', kind: 'error', reason: 'token' });
    expect(readOAuthReturn(`?google_ads=finish&google_ads_state=bad`, `#google_ads_finish=${T}`))
      .toEqual({ provider: 'google_ads', kind: 'error', reason: 'state' });
  });

  it('reads errors and ignores other URLs', () => {
    expect(readOAuthReturn('?google_ads=error&reason=denied', '')).toEqual({ provider: 'google_ads', kind: 'error', reason: 'denied' });
    expect(readOAuthReturn('?eventbrite=error&reason=<b>', '')).toEqual({ provider: 'eventbrite', kind: 'error', reason: 'b' });
    expect(readOAuthReturn('?eventbrite=pick', '')).toBeNull();
    expect(readOAuthReturn('?tab=x', '#eventbrite_finish=' + T)).toBeNull();
    expect(readOAuthReturn('', '')).toBeNull();
  });

  it('strips its params from the query and the token from the hash', () => {
    expect(stripOAuthReturn(`?tab=x&eventbrite=finish&eventbrite_state=${S}`)).toBe('?tab=x');
    expect(stripOAuthReturn('?google_ads=error&reason=denied')).toBe('');
    expect(stripOAuthReturn('?reason=keep')).toBe('?reason=keep');
    expect(stripOAuthHash(`#eventbrite_finish=${T}`)).toBe('');
    expect(stripOAuthHash(`#google_ads_finish=${T}&section=ads`)).toBe('#section=ads');
    expect(stripOAuthHash('')).toBe('');
  });
});

describe('OAuth return: the confirm step', () => {
  const ret = { provider: 'eventbrite' as const, kind: 'finish' as const, state: S, finish: T };

  it('waits for Confirm: nothing is sendable on load', () => {
    const s = initialStep(ret, true);
    expect(s.step).toBe('confirm');
    expect(finishBody(s)).toBeNull();
  });

  it('sends state + token only after Confirm, once', () => {
    const sending = finishReducer(initialStep(ret, true), { type: 'confirm' });
    expect(sending.step).toBe('sending');
    expect(finishBody(sending)).toEqual({ state: S, finish: T });
    // A second Confirm (double click) doesn't make a second request.
    expect(finishReducer(sending, { type: 'confirm' })).toBe(sending);
    expect(finishReducer(sending, { type: 'ok' })).toEqual({ step: 'done', provider: 'eventbrite' });
  });

  it('Cancel drops the token; a refusal keeps no token either', () => {
    const cancelled = finishReducer(initialStep(ret, true), { type: 'cancel' });
    expect(cancelled).toEqual({ step: 'cancelled', provider: 'eventbrite' });
    expect(JSON.stringify(cancelled)).not.toContain(T);
    const refused = finishReducer(finishReducer(initialStep(ret, true), { type: 'confirm' }), { type: 'refused', reason: 'other_user' });
    expect(refused).toEqual({ step: 'refused', provider: 'eventbrite', reason: 'other_user' });
    expect(JSON.stringify(refused)).not.toContain(T);
  });

  it('an org this user cannot see is refused without sending anything', () => {
    const s = initialStep(ret, false);
    expect(s).toEqual({ step: 'refused', provider: 'eventbrite', reason: 'other_user' });
    expect(finishBody(finishReducer(s, { type: 'confirm' }))).toBeNull();
  });

  it('an error return goes straight to a message', () => {
    expect(initialStep({ provider: 'google_ads', kind: 'error', reason: 'denied' }, true))
      .toEqual({ step: 'refused', provider: 'google_ads', reason: 'denied' });
  });

  it('names the org, and says nothing was connected on refusal', () => {
    expect(confirmPrompt('eventbrite', 'Blue Room')).toBe('Connect the Eventbrite account you just signed in with to Blue Room?');
    expect(confirmPrompt('google_ads', 'Blue Room')).toMatch(/Google Ads account .* to Blue Room\?/);
    const m = refusalMessage('eventbrite', 'other_user');
    expect(m).toMatch(/started by another Exos account/);
    expect(m).toMatch(/nothing was connected/);
    expect(refusalMessage('google_ads', 'token')).toMatch(/nothing was connected/);
    expect(refusalMessage('google_ads', 'whatever')).toMatch(/nothing was connected/);
  });

  it('stays put on actions that do not apply', () => {
    const done: FinishStep = { step: 'done', provider: 'google_ads' };
    expect(finishReducer(done, { type: 'confirm' })).toBe(done);
    expect(finishReducer(done, { type: 'refused', reason: 'x' })).toBe(done);
  });
});

describe('OAuth finish token (server helpers)', () => {
  it('puts the token in the fragment only', () => {
    const u = withFinishFragment(`https://exos.example/orgs/o/settings?eventbrite=finish&eventbrite_state=${S}`, 'eventbrite_finish', T);
    const url = new URL(u);
    expect(url.hash).toBe(`#eventbrite_finish=${T}`);
    expect(url.search).not.toContain(T);
    expect(withFinishFragment('https://exos.example/x#old', 'google_ads_finish', T)).toBe(`https://exos.example/x#google_ads_finish=${T}`);
    expect(() => withFinishFragment('https://exos.example/x', 'eventbrite_finish', 'short')).toThrow();
  });

  it('maps refusals without echoing anything', () => {
    expect(finishRefusal('other_user')).toMatchObject({ status: 403, reason: 'other_user' });
    expect(finishRefusal('token')).toMatchObject({ status: 400, reason: 'token' });
    expect(finishRefusal('forbidden')).toMatchObject({ status: 403, reason: 'forbidden' });
    expect(finishRefusal('expired')).toMatchObject({ status: 400, reason: 'expired' });
    expect(finishRefusal(null)).toMatchObject({ reason: 'expired' });
    expect(finishRefusal('other_user').error).toMatch(/nothing was connected/);
  });
});
