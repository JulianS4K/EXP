import { describe, it, expect } from 'vitest';
import { stubHubStatus, type StubHubDistributionRow } from './stubhubStatus';

const EV = { stubhubTicked: true, published: true, primaryMarketOnly: false };
const row = (p: Partial<StubHubDistributionRow>): StubHubDistributionRow => ({
  status: 'pending', error: null, external_event_id: null, planned_request: null, last_synced_at: null, ...p,
});

describe('stubHubStatus', () => {
  it('says nothing when StubHub is not ticked', () => {
    expect(stubHubStatus(null, { ...EV, stubhubTicked: false })).toBeNull();
  });

  it('explains what happens before a row exists', () => {
    expect(stubHubStatus(null, { ...EV, published: false })?.text).toMatch(/when you publish/);
    expect(stubHubStatus(null, EV)?.text).toMatch(/Save to queue/);
    expect(stubHubStatus(null, { ...EV, primaryMarketOnly: true })?.text).toMatch(/Primary market only/);
  });

  it('describes the queue states', () => {
    expect(stubHubStatus(row({}), EV)).toEqual({ tone: 'info', text: 'Queued: Exos is preparing the StubHub event request.' });
    const planned = stubHubStatus(row({
      status: 'planned',
      planned_request: { body: { event: { name: 'Late Night Jazz' }, venue: { name: 'Blue Room', city: 'Brooklyn' } } },
    }), EV);
    expect(planned?.text).toBe(
      "StubHub event request ready for Late Night Jazz at Blue Room, Brooklyn. Not sent yet: StubHub selling isn't switched on.",
    );
    expect(stubHubStatus(row({ status: 'planned' }), EV)?.text).toMatch(/^StubHub event request ready\. Not sent/);
    const failed = stubHubStatus(row({ status: 'failed', error: 'venue city is required: add the venue address to the event' }), EV);
    expect(failed?.tone).toBe('warn');
    expect(failed?.text).toMatch(/venue city is required/);
  });

  it('shows the StubHub event once it exists, even if StubHub was unticked since', () => {
    const s = stubHubStatus(row({ status: 'listed', external_event_id: '104857' }), { ...EV, stubhubTicked: false });
    expect(s).toEqual({ tone: 'ok', text: 'On StubHub (event 104857).' });
  });
});
