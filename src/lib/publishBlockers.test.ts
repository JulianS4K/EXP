import { describe, expect, it, vi } from 'vitest';

const rpc = vi.fn();
vi.mock('./supabase', () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...a) } }));

import { blockersSentence, getPublishBlockers, parseBlockers, publishEvent } from './publishBlockers';

describe('publish blockers', () => {
  it('keeps well-formed blockers and fills a missing message from the code', () => {
    expect(parseBlockers([
      { code: 'missing_venue', field: 'venue_name', message: 'Add a venue (or make the event online).' },
      { code: 'no_ticket_types', field: 'ticket_types' },
      null, 'x', { field: 'name' },
    ])).toEqual([
      { code: 'missing_venue', field: 'venue_name', message: 'Add a venue (or make the event online).' },
      { code: 'no_ticket_types', field: 'ticket_types', message: 'no ticket types' },
    ]);
    expect(parseBlockers(null)).toEqual([]);
    expect(parseBlockers({ code: 'x' })).toEqual([]);
  });

  it('joins messages into one sentence each', () => {
    expect(blockersSentence([
      { code: 'missing_start', field: 'starts_at', message: 'Add a start date and time.' },
      { code: 'stripe_not_connected', field: null, message: 'Connect Stripe' },
    ])).toBe('Add a start date and time. Connect Stripe.');
    expect(blockersSentence([])).toBe('');
  });

  it('reads the blockers and publishes through the SQL functions', async () => {
    rpc.mockResolvedValueOnce({ data: [{ code: 'missing_name', field: 'name', message: 'Add a name.' }], error: null });
    expect(await getPublishBlockers('e1')).toHaveLength(1);
    expect(rpc).toHaveBeenLastCalledWith('exos_event_publish_blockers', { p_event_id: 'e1' });

    rpc.mockResolvedValueOnce({
      data: { event_id: 'e1', status: 'draft', published: false, blockers: [{ code: 'missing_name', field: 'name', message: 'Add a name.' }] },
      error: null,
    });
    expect(await publishEvent('e1')).toEqual({
      published: false, status: 'draft', blockers: [{ code: 'missing_name', field: 'name', message: 'Add a name.' }],
    });
    expect(rpc).toHaveBeenLastCalledWith('exos_publish_event', { p_event_id: 'e1' });

    rpc.mockResolvedValueOnce({ data: null, error: { message: 'exos_publish_event: only an owner or manager can publish' } });
    await expect(publishEvent('e1')).rejects.toMatchObject({ message: /owner or manager/ });
  });
});
