import { describe, expect, it } from 'vitest';
import {
  ALLOWED_HTTP_METHODS, EB_API, assertReadonlyMethod, changedSince, ebErrorMessage, ebGet, isTokenShaped,
  listUpcomingEvents, syncLink, toApplyRow, type ApplyRow, type ApplyState, type Fetch,
} from '../../supabase/functions/_shared/eventbrite/client.ts';

type Call = { url: string; init?: RequestInit };

function fakeFetch(routes: Array<(url: URL) => { status: number; body: unknown } | null>): { fetch: Fetch; calls: Call[] } {
  const calls: Call[] = [];
  const fetch: Fetch = async (input, init) => {
    calls.push({ url: input, init });
    const u = new URL(input);
    for (const r of routes) {
      const hit = r(u);
      if (hit) return new Response(JSON.stringify(hit.body), { status: hit.status });
    }
    return new Response(JSON.stringify({ error: 'NOT_FOUND' }), { status: 404 });
  };
  return { fetch, calls };
}

describe('read only', () => {
  it('allows GET and nothing else', () => {
    expect([...ALLOWED_HTTP_METHODS]).toEqual(['GET']);
    expect(() => assertReadonlyMethod('GET')).not.toThrow();
    for (const m of ['POST', 'PUT', 'PATCH', 'DELETE', 'post']) expect(() => assertReadonlyMethod(m)).toThrow(/read-only/);
  });
  it('sends GET to the Eventbrite API with the token in the header only', async () => {
    const { fetch, calls } = fakeFetch([() => ({ status: 200, body: { name: 'x' } })]);
    const r = await ebGet(fetch, 'TOKEN1234', '/users/me/', { a: '1', b: undefined });
    expect(r.ok).toBe(true);
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe(`${EB_API}/users/me/?a=1`);
    expect(calls[0].url).not.toContain('TOKEN');
    expect(calls[0].init?.method).toBe('GET');
    expect((calls[0].init?.headers as Record<string, string>).Authorization).toBe('Bearer TOKEN1234');
  });
  it('refuses odd paths and maps errors without bodies', async () => {
    const { fetch, calls } = fakeFetch([() => ({ status: 401, body: { error: 'INVALID_AUTH', error_description: 'secret stuff' } })]);
    expect((await ebGet(fetch, 'T', '//evil.example/x')).error).toBe('bad path');
    expect((await ebGet(fetch, 'T', '/a/../b')).error).toBe('bad path');
    expect(calls).toHaveLength(0);
    const r = await ebGet(fetch, 'T', '/users/me/');
    expect(r).toEqual({ ok: false, status: 401, body: null, error: 'INVALID_AUTH' });
    expect(ebErrorMessage(r)).toMatch(/rejected the token/);
    expect(ebErrorMessage({ status: 429 })).toMatch(/rate limit/);
    expect(ebErrorMessage({ status: 0, error: 'TIMEOUT' })).toMatch(/didn't answer/);
  });
  it('network failure is a result, not a throw', async () => {
    const r = await ebGet(async () => { throw new TypeError('boom'); }, 'T', '/users/me/');
    expect(r).toMatchObject({ ok: false, status: 0, error: 'NETWORK' });
  });
  it('token shape', () => {
    expect(isTokenShaped('ABCDEFGH12')).toBe(true);
    expect(isTokenShaped('short')).toBe(false);
    expect(isTokenShaped('has space 1234')).toBe(false);
    expect(isTokenShaped(42)).toBe(false);
  });
});

describe('toApplyRow', () => {
  it('a live attendee', () => {
    expect(toApplyRow({
      id: '9001', status: 'Attending', ticket_class_name: 'GA ',
      profile: { name: 'Ada Lovelace', email: 'ada@x.com' },
      barcodes: [{ barcode: '7001 0001', status: 'unused' }],
    })).toEqual({ ref: '9001', code: '7001 0001', name: 'Ada Lovelace', email: 'ada@x.com', ticket: 'GA', void: false });
  });
  it('voids refunded, cancelled, not attending, deleted, all-barcodes-refunded', () => {
    expect(toApplyRow({ id: '1', refunded: true })?.reason).toBe('refunded');
    expect(toApplyRow({ id: '2', cancelled: true })?.reason).toBe('cancelled');
    expect(toApplyRow({ id: '3', status: 'Not Attending' })?.reason).toBe('not attending');
    expect(toApplyRow({ id: '4', status: 'Deleted' })?.void).toBe(true);
    expect(toApplyRow({ id: '5', barcodes: [{ barcode: 'A', status: 'refunded' }] })?.reason).toBe('refunded');
    expect(toApplyRow({ id: '6', status: 'Checked In', barcodes: [{ barcode: 'A', status: 'used' }] })?.void).toBe(false);
  });
  it('picks a barcode that is not refunded; falls back to first + last name', () => {
    const r = toApplyRow({
      id: '7', profile: { first_name: 'Bo', last_name: 'Diddley' },
      barcodes: [{ barcode: 'OLD', status: 'refunded' }, { barcode: 'NEW', status: 'unused' }, { barcode: null }],
    });
    expect(r).toMatchObject({ code: 'NEW', name: 'Bo Diddley', void: false });
  });
  it('no usable id: dropped', () => {
    expect(toApplyRow({ id: 'abc' })).toBeNull();
    expect(toApplyRow({})).toBeNull();
  });
});

describe('changedSince', () => {
  it('goes back 2 minutes, no milliseconds', () => {
    expect(changedSince('2026-10-13T20:00:30.123Z')).toBe('2026-10-13T19:58:30Z');
    expect(changedSince(null)).toBeUndefined();
    expect(changedSince('nope')).toBeUndefined();
  });
});

describe('syncLink', () => {
  const link = { event_id: 'e1', eb_event_id: '111', token: 'TOKEN1234', sync_cursor: '2026-10-13T20:00:00Z', continuation: null };
  const page = (n: number, more: boolean) => ({
    attendees: [{ id: String(100 + n), profile: { name: `P${n}` }, barcodes: [{ barcode: `C${n}`, status: 'unused' }] }],
    pagination: { has_more_items: more, continuation: more ? `K${n + 1}` : null },
  });

  function attendeeServer(pages: number) {
    return fakeFetch([(u) => {
      if (u.pathname !== '/v3/events/111/attendees/') return null;
      const k = u.searchParams.get('continuation');
      const n = k ? Number(k.slice(1)) : 1;
      return { status: 200, body: page(n, n < pages) };
    }]);
  }

  function recorder() {
    const applied: Array<{ rows: ApplyRow[]; state: ApplyState; cont: string | null; err: string | null }> = [];
    const apply = async (rows: ApplyRow[], state: ApplyState, cont: string | null, err: string | null) => {
      applied.push({ rows, state, cont, err });
      return { ok: true, added: rows.length };
    };
    return { applied, apply };
  }

  it('pages to the end: more, more, done; changed_since from the cursor', async () => {
    const { fetch, calls } = attendeeServer(3);
    const { applied, apply } = recorder();
    const out = await syncLink(fetch, link, apply, { maxPages: 10, deadline: Date.now() + 60_000 });
    expect(out).toMatchObject({ state: 'done', pages: 3, rows: 3, added: 3 });
    expect(applied.map((a) => [a.state, a.cont])).toEqual([['more', 'K2'], ['more', 'K3'], ['done', null]]);
    expect(new URL(calls[0].url).searchParams.get('changed_since')).toBe('2026-10-13T19:58:00Z');
    expect(calls.every((c) => c.init?.method === 'GET')).toBe(true);
  });

  it('stops at the page budget with pause, and resumes from the continuation', async () => {
    const { fetch, calls } = attendeeServer(5);
    const { applied, apply } = recorder();
    const out = await syncLink(fetch, link, apply, { maxPages: 2, deadline: Date.now() + 60_000 });
    expect(out.state).toBe('more');
    expect(applied.map((a) => [a.state, a.cont])).toEqual([['more', 'K2'], ['pause', 'K3']]);
    const again = await syncLink(fetch, { ...link, continuation: 'K3' }, apply, { maxPages: 10, deadline: Date.now() + 60_000 });
    expect(again).toMatchObject({ state: 'done', pages: 3 });
    expect(new URL(calls[2].url).searchParams.get('continuation')).toBe('K3');
  });

  it('stops at the deadline', async () => {
    const { fetch } = attendeeServer(5);
    const { applied, apply } = recorder();
    let t = 0;
    const out = await syncLink(fetch, link, apply, { maxPages: 10, deadline: 1, now: () => t++ });
    expect(out.state).toBe('more');
    expect(applied.at(-1)?.state).toBe('pause');
  });

  it('an expired continuation restarts the pass; other errors keep it', async () => {
    const bad = fakeFetch([() => ({ status: 400, body: { error: 'BAD_CONTINUATION_TOKEN' } })]);
    const r1 = recorder();
    const o1 = await syncLink(bad.fetch, { ...link, continuation: 'K9' }, r1.apply, { maxPages: 5, deadline: Date.now() + 9e4 });
    expect(o1.state).toBe('error');
    expect(r1.applied).toEqual([{ rows: [], state: 'error', cont: null, err: expect.stringMatching(/Restarting/) }]);

    const down = fakeFetch([() => ({ status: 503, body: {} })]);
    const r2 = recorder();
    await syncLink(down.fetch, { ...link, continuation: 'K9' }, r2.apply, { maxPages: 5, deadline: Date.now() + 9e4 });
    expect(r2.applied[0]).toMatchObject({ state: 'error', cont: 'K9' });
  });

  it('a failed save stops the run', async () => {
    const { fetch } = attendeeServer(3);
    const out = await syncLink(fetch, link, async () => null, { maxPages: 5, deadline: Date.now() + 9e4 });
    expect(out).toMatchObject({ state: 'error', pages: 1 });
  });
});

describe('listUpcomingEvents', () => {
  it('walks organizations and pages, sorted by start', async () => {
    const { fetch, calls } = fakeFetch([
      (u) => (u.pathname === '/v3/users/me/organizations/' ? { status: 200, body: { organizations: [{ id: '1' }, { id: 'x' }, { id: '2' }] } } : null),
      (u) => {
        if (u.pathname === '/v3/organizations/1/events/') {
          return u.searchParams.get('continuation')
            ? { status: 200, body: { events: [{ id: '12', name: { text: 'Late' }, start: { utc: '2026-12-01T00:00:00Z' } }], pagination: {} } }
            : { status: 200, body: { events: [{ id: '11', name: { text: 'Soon' }, start: { utc: '2026-10-20T00:00:00Z' } }], pagination: { has_more_items: true, continuation: 'P2' } } };
        }
        if (u.pathname === '/v3/organizations/2/events/') {
          return { status: 200, body: { events: [{ id: '21', name: { text: '' }, start: { utc: '2026-11-01T00:00:00Z' } }, { id: 'bad' }] } };
        }
        return null;
      },
    ]);
    const r = await listUpcomingEvents(fetch, 'TOKEN1234');
    expect(r.body?.map((e) => [e.id, e.name])).toEqual([['11', 'Soon'], ['21', 'Event 21'], ['12', 'Late']]);
    expect(new URL(calls[1].url).searchParams.get('time_filter')).toBe('current_future');
    expect(calls).toHaveLength(4);
  });
});
