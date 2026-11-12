import { describe, expect, it } from 'vitest';
import { AttendanceError, handleAttendance, type AttendanceCtx } from '../../supabase/functions/exos-api/attendance.ts';
import { matchRoute } from '../../supabase/functions/_shared/api/routes.ts';

// exos-api/attendance.ts (mig 20261113120000): GET /v1/events/:id/attendance
// sends the credential to SQL (_exos_api_attendance), which checks the key's
// creator's (or the token user's) role; errors map to HTTP here.
const ORG = '0a000000-0000-4000-8000-000000000001';
const EV = '0a000000-0000-4000-8000-0000000000e1';
const PREV = '0a000000-0000-4000-8000-0000000000e0';
const KEY = '0a000000-0000-4000-8000-0000000000f1';

function ctx(path: string, query = '', error: { code: string; message: string } | null = null, cred?: AttendanceCtx['cred']) {
  const calls: Array<{ fn: string; args: Record<string, unknown> }> = [];
  const m = matchRoute('GET', path)!;
  const c: AttendanceCtx = {
    sb: { rpc: async (fn, args) => { calls.push({ fn, args }); return { data: error ? null : { event_id: EV }, error }; } },
    orgId: ORG,
    cred: cred ?? { kind: 'api_key', id: KEY, userId: 'u1' },
    params: m.params,
    q: new URLSearchParams(query),
  };
  return { route: m.route, c, calls };
}

describe('GET /v1/events/:id/attendance', () => {
  it('is an orders:read route', () => {
    const m = matchRoute('GET', `/events/${EV}/attendance`)!;
    expect(m.route).toMatchObject({ id: 'get-event-attendance', scope: 'orders:read', auth: 'api_key', paged: false });
  });

  it('sends the org, the event, the comparison and the credential to SQL', async () => {
    const { route, c, calls } = ctx(`/events/${EV}/attendance`, `compare=${PREV}`);
    expect(await handleAttendance(route, c)).toEqual({ data: { event_id: EV } });
    expect(calls).toEqual([{ fn: '_exos_api_attendance', args: {
      p_org: ORG, p_event: EV, p_compare: PREV, p_cred_kind: 'api_key', p_cred_id: KEY, p_user: 'u1',
    } }]);
  });

  it('passes a personal token as its user, and no comparison as null', async () => {
    const { route, c, calls } = ctx(`/events/${EV}/attendance`, '', null, { kind: 'pat', id: 'pat_1', userId: 'u9' });
    await handleAttendance(route, c);
    expect(calls[0].args).toMatchObject({ p_compare: null, p_cred_kind: 'pat', p_cred_id: 'pat_1', p_user: 'u9' });
  });

  it('refuses bad ids before any SQL', async () => {
    const bad = ctx('/events/not-a-uuid/attendance');
    await expect(handleAttendance(bad.route, bad.c)).rejects.toMatchObject({ status: 404 });
    const cmp = ctx(`/events/${EV}/attendance`, 'compare=x');
    await expect(handleAttendance(cmp.route, cmp.c)).rejects.toMatchObject({ status: 400 });
    expect(bad.calls.length + cmp.calls.length).toBe(0);
  });

  it('maps the SQL refusals', async () => {
    for (const [code, status] of [['42501', 403], ['P0002', 404], ['22023', 400], ['54000', 429]] as const) {
      const { route, c } = ctx(`/events/${EV}/attendance`, '', { code, message: 'nope' });
      const e = await handleAttendance(route, c).catch((x: unknown) => x) as AttendanceError;
      expect(e).toBeInstanceOf(AttendanceError);
      expect(e.status).toBe(status);
    }
    const other = ctx(`/events/${EV}/attendance`, '', { code: 'XX000', message: 'boom' });
    await expect(handleAttendance(other.route, other.c)).rejects.not.toBeInstanceOf(AttendanceError);
  });
});
