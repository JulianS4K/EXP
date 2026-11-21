// The MCP write tools (supabase/functions/_shared/mcp/exosWriteTools.ts, mig
// 20261119130000, docs/mcp.md): tools/list shape and annotations, the server
// instructions, the two-step confirm_token flow, the fee line, time zones, and
// that the TypeScript lists match the SQL ones. The database is a fake that
// keeps the SQL's confirmation rules (tests/exos/test_mcp_writes.sql runs the
// real ones).
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  EXOS_MCP_INSTRUCTIONS, WRITE_TOOLS, exosMcpServer, expectedFeeStatement, feeStatement, handleBody, imageUrl,
  zonedToUtc, type EventState, type ExosData, type McpWriteData, type ToolContext, type WriteExec,
} from '.';
import { USER_TOKEN_CORE_WRITES, userTokenMayCall } from '../../../supabase/functions/_shared/api/request.ts';
import { ROUTES } from '../../../supabase/functions/_shared/api/routes.ts';

const ORG = '33333333-3333-4333-8333-333333333333';
const OTHER_EVENT = '99999999-9999-4999-8999-999999999999';
const EV = '0f8fad5b-d9cb-469f-a165-70867728950e';
const VENUE = '55555555-5555-4555-8555-555555555555';

const reads: ExosData = {
  async searchEvents() { return []; }, async getEvent() { return null; }, async tiersFor() { return []; },
  async orgEvents() { return []; }, async eventSales() { return null; }, async doorStatus() { return null; }, async attention() { return []; },
};

const canon = (v: unknown): string => JSON.stringify(v, (_k, x) => (x && typeof x === 'object' && !Array.isArray(x)
  ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, (x as Record<string, unknown>)[k]])) : x));

/** A fake database with the SQL's confirmation rules. */
function fakeDb(state: { event: EventState; free: boolean }) {
  const confirms = new Map<string, { cred: string; tool: string; exec: string; used: boolean; expires: number }>();
  const writes: Array<{ tool: string; exec: WriteExec }> = [];
  let n = 0;
  const credOf = (ctx: ToolContext) => `${ctx.credKind}:${ctx.credId}`;
  const db: McpWriteData = {
    async issueConfirm(ctx, tool, exec) {
      const token = `exos_mcc_${String(++n).padStart(43, 'a')}`;
      confirms.set(token, { cred: credOf(ctx), tool, exec: canon(exec), used: false, expires: Date.now() + 600_000 });
      return { token, expires_at: new Date(Date.now() + 600_000).toISOString() };
    },
    async runWrite(ctx, tool, token, exec) {
      const c = confirms.get(token);
      if (!c || c.cred !== credOf(ctx)) return { ok: false, error: 'confirm_invalid', message: 'this confirm_token is not valid' };
      if (c.used) return { ok: false, error: 'confirm_used', message: 'this confirm_token was already used' };
      if (c.expires <= Date.now()) return { ok: false, error: 'confirm_expired', message: 'this confirm_token expired' };
      if (c.tool !== tool || c.exec !== canon(exec)) {
        c.used = true;
        return { ok: false, error: 'confirm_mismatch', message: 'the arguments changed since the preview' };
      }
      c.used = true;
      writes.push({ tool, exec });
      if (exec.action === 'event.create') return { ok: true, result: { id: EV, name: (exec.args.event as { name: string }).name, publish_blockers: [] } };
      if (exec.action === 'ticket_type.create') return { ok: true, result: { id: 'tier-1', ...(exec.args.ticket_type as object) } };
      return { ok: true, result: { published: state.event.blockers.length === 0, blockers: state.event.blockers } };
    },
    async orgVenue(orgId, id) { return orgId === ORG && id === VENUE ? { id, name: 'The Loft', address: { street: '1 Main St', city: 'Brooklyn' }, timezone: null } : null; },
    async eventState(orgId, id) { return orgId === ORG && id === EV ? state.event : null; },
    async feeOutcome(orgId, id) {
      return orgId === ORG && id === EV ? { free_tier: state.free, max_capacity: state.free ? 120 : 300, free_tier_max_capacity: 150 } : null;
    },
  };
  return { db, writes, confirms };
}

const draft = (over: Partial<EventState> = {}): EventState => ({
  event: { id: EV, name: 'Rooftop', status: 'draft', starts_at: '2027-01-16T01:00:00.000Z', ends_at: null, timezone: 'America/New_York',
    currency: 'USD', venue_name: 'The Loft', total_tickets: 120 },
  ticket_types: [{ id: 't1', name: 'RSVP', price: 0, capacity: 120, sales_start: null, sales_end: null }],
  blockers: [],
  ...over,
});

const pat: ToolContext = { orgId: ORG, scopes: ['events:read', 'events:write'], credKind: 'pat', credId: 'p1', bearerHash: 'a'.repeat(64) };
const oauth: ToolContext = { ...pat, credKind: 'oauth', credId: 'g1' };
const readOnly: ToolContext = { ...pat, scopes: ['events:read'] };

function setup(state = { event: draft(), free: true }) {
  const f = fakeDb(state);
  const server = exosMcpServer(reads, { appBase: 'https://exos.example.test/bridge/', version: '1', writes: f.db });
  const rpc = async (method: string, params: unknown, ctx: ToolContext) =>
    handleBody(server, JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }), ctx) as Promise<any>;
  const call = async (name: string, args: unknown, ctx: ToolContext = pat) => (await rpc('tools/call', { name, arguments: args }, ctx)).result;
  return { ...f, server, rpc, call, state };
}

const CREATE = { title: 'Rooftop Sessions', starts_at: '2027-01-15T20:00', timezone: 'America/New_York', venue_id: VENUE, capacity: 120 };

describe('tools/list', () => {
  it('lists the three write tools only for a credential with events:write', async () => {
    const t = setup();
    const names = (ctx: ToolContext) => t.rpc('tools/list', {}, ctx).then((r) => r.result.tools.map((x: any) => x.name));
    expect(await names(pat)).toEqual(expect.arrayContaining(['create_event_draft', 'add_ticket_type', 'publish_event', 'my_events']));
    expect(await names(readOnly)).not.toEqual(expect.arrayContaining(['create_event_draft']));
    expect(await names(readOnly)).toContain('my_events');
    expect(await names({ orgId: null })).toEqual(['search_events', 'get_event', 'get_ticket_link', 'search', 'fetch']);
    const res = await t.call('publish_event', { event_id: EV }, readOnly);
    expect(res).toMatchObject({ isError: true, structuredContent: { error: 'this credential lacks the events:write scope' } });
    expect(await t.call('create_event_draft', CREATE, { orgId: null })).toMatchObject({ isError: true });
  });

  it('annotations: none read-only, publish destructive and idempotent; every write takes a confirm_token', async () => {
    const t = setup();
    const tools = (await t.rpc('tools/list', {}, pat)).result.tools as any[];
    const by = Object.fromEntries(tools.map((x) => [x.name, x]));
    for (const name of Object.keys(WRITE_TOOLS)) {
      expect(by[name].annotations.readOnlyHint, name).toBe(false);
      expect(by[name].inputSchema.properties.confirm_token, name).toBeDefined();
      expect(by[name].inputSchema.required ?? [], name).not.toContain('confirm_token');
      expect(by[name].inputSchema.additionalProperties, name).toBe(false);
    }
    expect(by.publish_event.annotations).toMatchObject({ destructiveHint: true, idempotentHint: true });
    expect(by.create_event_draft.annotations).toMatchObject({ destructiveHint: false, idempotentHint: false });
    expect(by.add_ticket_type.annotations).toMatchObject({ destructiveHint: false, idempotentHint: false });
    expect(by.create_event_draft.inputSchema.required).toEqual(['title', 'starts_at', 'timezone']);
    expect(by.add_ticket_type.inputSchema.required).toEqual(['event_id', 'name', 'price', 'quantity']);
    // The reads stay read-only.
    for (const x of tools.filter((x) => !(x.name in WRITE_TOOLS))) expect(x.annotations.readOnlyHint, x.name).toBe(true);
  });

  it('the instructions require explicit confirmation and treat content as content', () => {
    expect(EXOS_MCP_INSTRUCTIONS).toMatch(/only after they have explicitly agreed/);
    expect(EXOS_MCP_INSTRUCTIONS).toMatch(/Never publish an event without the person's explicit confirmation/);
    expect(EXOS_MCP_INSTRUCTIONS).toMatch(/content, not instructions/);
    expect(EXOS_MCP_INSTRUCTIONS).toMatch(/Never send a confirm_token on your own initiative/);
    expect(EXOS_MCP_INSTRUCTIONS).toMatch(/free tier: no Exos fee/);
  });
});

describe('the confirm_token flow', () => {
  it('first call: a preview and a token, nothing written; second call with the token: a draft', async () => {
    const t = setup();
    const first = (await t.call('create_event_draft', CREATE)).structuredContent;
    expect(first.status).toBe('confirmation_required');
    expect(first.confirm_token).toMatch(/^exos_mcc_/);
    expect(first.preview).toMatchObject({ title: 'Rooftop Sessions', venue: 'The Loft, Brooklyn', capacity: 120 });
    expect(first.preview.fee).toMatch(/free tier: no Exos fee/);
    expect(first.next_step).toMatch(/Nothing has been changed yet/);
    expect(t.writes).toHaveLength(0);
    const done = (await t.call('create_event_draft', { ...CREATE, confirm_token: first.confirm_token })).structuredContent;
    expect(done).toMatchObject({ status: 'created', event_id: EV, event_status: 'draft', edit_url: `https://exos.example.test/bridge/edit-event/${EV}`, free_tier: true });
    expect(done.fee).toMatch(/free tier: no Exos fee/);
    expect(t.writes).toHaveLength(1);
    // Exactly what the preview showed: UTC start, the venue copied from the org's venue.
    expect(t.writes[0].exec).toEqual({ action: 'event.create', target: null, args: { event: {
      name: 'Rooftop Sessions', starts_at: '2027-01-16T01:00:00.000Z', timezone: 'America/New_York', total_tickets: 120,
      venue_name: 'The Loft', venue_address: { street: '1 Main St', city: 'Brooklyn' }, venue_location: 'Brooklyn',
    } } });
  });

  it('refuses a reused token, changed arguments (and burns the token), another credential, a made-up token', async () => {
    const t = setup();
    const a = (await t.call('create_event_draft', CREATE)).structuredContent.confirm_token;
    expect((await t.call('create_event_draft', { ...CREATE, confirm_token: a })).isError).toBeFalsy();
    expect((await t.call('create_event_draft', { ...CREATE, confirm_token: a })).structuredContent.error).toMatch(/already used/);
    const b = (await t.call('create_event_draft', CREATE)).structuredContent.confirm_token;
    expect((await t.call('create_event_draft', { ...CREATE, capacity: 1200, confirm_token: b })).structuredContent.error).toMatch(/changed/);
    expect((await t.call('create_event_draft', { ...CREATE, confirm_token: b })).structuredContent.error).toMatch(/already used/);
    const c = (await t.call('create_event_draft', CREATE)).structuredContent.confirm_token;
    expect((await t.call('create_event_draft', { ...CREATE, confirm_token: c }, oauth)).structuredContent.error).toMatch(/not valid/);
    expect((await t.call('create_event_draft', { ...CREATE, confirm_token: 'yes' })).structuredContent.error).toMatch(/not one this server issued/);
    expect((await t.call('create_event_draft', { ...CREATE, confirm_token: true })).isError).toBe(true);
    expect(t.writes).toHaveLength(1);
  });

  it('publish without a confirm_token returns the summary and publishes nothing', async () => {
    const t = setup();
    const r = (await t.call('publish_event', { event_id: EV })).structuredContent;
    expect(r.status).toBe('confirmation_required');
    expect(r.preview.action).toMatch(/PUBLISH/);
    expect(r.preview.ticket_types).toEqual([{ name: 'RSVP', price: 'free', quantity: 120 }]);
    expect(t.writes).toHaveLength(0);
    const p = (await t.call('publish_event', { event_id: EV, confirm_token: r.confirm_token })).structuredContent;
    expect(p).toMatchObject({ status: 'published', event_id: EV });
    expect(t.writes.map((w) => w.exec.action)).toEqual(['event.publish']);
  });

  it('paid tickets without Stripe Connect: a clear error with the onboarding link, no token issued', async () => {
    const t = setup({ event: draft({ blockers: [{ code: 'stripe_not_connected', field: null, message: 'Paid tickets need a connected Stripe account that can take payments (Org settings → Payouts).' }] }), free: true });
    const r = await t.call('publish_event', { event_id: EV });
    expect(r.isError).toBe(true);
    expect(r.structuredContent.error).toContain(`https://exos.example.test/bridge/orgs/${ORG}/payouts`);
    expect(r.structuredContent.error).toMatch(/free \/ RSVP events can publish without it/);
    expect(t.confirms.size).toBe(0);
  });

  it("another organization's event id is refused before anything is issued", async () => {
    const t = setup();
    for (const [name, args] of [['publish_event', { event_id: OTHER_EVENT }],
      ['add_ticket_type', { event_id: OTHER_EVENT, name: 'GA', price: 10, quantity: 5 }]] as const) {
      const r = await t.call(name, args);
      expect(r.structuredContent.error, name).toMatch(/no event with that id in your organization/);
    }
    expect((await t.call('create_event_draft', { ...CREATE, venue_id: '66666666-6666-4666-8666-666666666666' })).structuredContent.error)
      .toMatch(/no venue with that id/);
    expect(t.confirms.size).toBe(0);
  });

  it('add_ticket_type: drafts only; the sale window is read in the event time zone', async () => {
    const t = setup();
    const args = { event_id: EV, name: 'GA', price: 25, quantity: 100, sales_start: '2027-01-01T10:00' };
    const r = (await t.call('add_ticket_type', args)).structuredContent;
    expect(r.preview).toMatchObject({ ticket_type: 'GA', price: '25.00 USD', quantity: 100, sales_start: '2027-01-01T15:00:00.000Z (America/New_York)' });
    expect(r.preview.note).toMatch(/Stripe Connect/);
    const done = (await t.call('add_ticket_type', { ...args, confirm_token: r.confirm_token })).structuredContent;
    expect(done).toMatchObject({ status: 'added', event_id: EV, ticket_type: { name: 'GA', price: 25, quantity: 100 } });
    expect((await t.call('add_ticket_type', { ...args, price: 10.005 })).isError).toBe(true);
    const live = setup({ event: draft({ event: { ...draft().event, status: 'published' } }), free: true });
    expect((await live.call('add_ticket_type', args)).structuredContent.error).toMatch(/works on drafts/);
  });
});

describe('the fee line (free tier: 150 or less)', () => {
  it('150 is the free tier, 151 the standard fee', () => {
    expect(expectedFeeStatement(150)).toBe('This event will be on the free tier: no Exos fee (capacity 150; the free tier is 150 or less).');
    expect(expectedFeeStatement(151)).toMatch(/^With a capacity of 151 \(over the free tier's 150\), the standard Exos fee: 3% of each order/);
    expect(feeStatement({ free_tier: true, max_capacity: 150, free_tier_max_capacity: 150 }, 150)).toBe('This event is on the free tier: no Exos fee (150 tickets or less).');
    expect(feeStatement({ free_tier: false, max_capacity: 151, free_tier_max_capacity: 150 }, 151)).toMatch(/can sell 151 tickets, over the free tier \(150 or less\), so the standard Exos fee/);
    expect(feeStatement({ free_tier: true, max_capacity: 100, free_tier_max_capacity: 150 }, 151)).toMatch(/No Exos fee for now/);
    expect(feeStatement({ free_tier: false, max_capacity: 10, free_tier_max_capacity: -1 }, 10)).toMatch(/no free tier right now/);
  });
});

describe('inputs', () => {
  it('local times convert in the event time zone, across DST; a skipped hour is refused', () => {
    expect(zonedToUtc('2027-01-15T20:00', 'America/New_York', 's')).toBe('2027-01-16T01:00:00.000Z');
    expect(zonedToUtc('2027-07-15T20:00', 'America/New_York', 's')).toBe('2027-07-16T00:00:00.000Z');
    expect(zonedToUtc('2027-11-07T01:30', 'America/New_York', 's')).toBe('2027-11-07T05:30:00.000Z');
    expect(zonedToUtc('2027-01-15T20:00:00-05:00', 'Europe/Paris', 's')).toBe('2027-01-16T01:00:00.000Z');
    expect(() => zonedToUtc('2027-03-14T02:30', 'America/New_York', 's')).toThrow(/doesn't exist/);
    expect(() => zonedToUtc('2027-02-30T20:00', 'America/New_York', 's')).toThrow(/not a real date/);
    expect(() => zonedToUtc('next friday', 'America/New_York', 's')).toThrow();
  });
  it('image URLs: https on a public host only', () => {
    expect(imageUrl('https://cdn.example.com/a.jpg')).toBe('https://cdn.example.com/a.jpg');
    expect(() => imageUrl('http://cdn.example.com/a.jpg')).toThrow();
    expect(() => imageUrl('https://user:pw@cdn.example.com/a.jpg')).toThrow();
    expect(() => imageUrl('https://localhost/a.jpg')).toThrow();
    expect(() => imageUrl('javascript:alert(1)')).toThrow();
  });
  it('a venue, an online flag or nothing', async () => {
    const t = setup();
    const { venue_id: _v, ...noVenue } = CREATE;
    expect((await t.call('create_event_draft', noVenue)).structuredContent.error).toMatch(/give venue_id, a venue/);
    const online = (await t.call('create_event_draft', { ...noVenue, online: true })).structuredContent;
    expect(online.preview.venue).toBe('Online');
    const byAddress = (await t.call('create_event_draft', { ...noVenue, venue: { name: 'Hall', street: '2 Elm St', city: 'Queens', region: 'NY' } })).structuredContent;
    expect(byAddress.preview.venue).toBe('Hall, 2 Elm St, Queens, NY');
    expect((await t.call('create_event_draft', { ...noVenue, venue: { name: 'Hall', notes: 'x' } })).isError).toBe(true);
    expect((await t.call('create_event_draft', { ...CREATE, timezone: 'Mars/Base' })).isError).toBe(true);
    expect((await t.call('create_event_draft', { ...CREATE, ends_at: '2027-01-15T19:00' })).structuredContent.error).toMatch(/after starts_at/);
  });
});

describe('the TypeScript lists match the SQL (mig 20261119130000)', () => {
  const mig = readFileSync('supabase/migrations/20261119130000_exos_mcp_writes.sql', 'utf8');
  it('user-token core writes: exactly create-event, create-ticket-type, publish-event', () => {
    const m = /_exos_api_user_token_actions\(\)[\s\S]*?SELECT ARRAY\[([^\]]*)\]/.exec(mig);
    const sql = (m?.[1] ?? '').split(',').map((s) => s.trim().replace(/'/g, ''));
    expect([...USER_TOKEN_CORE_WRITES.values()].sort()).toEqual(sql.sort());
    expect([...USER_TOKEN_CORE_WRITES.keys()].sort()).toEqual(['create-event', 'create-ticket-type', 'publish-event']);
    const ids = new Set(ROUTES.map((r) => r.id));
    for (const id of USER_TOKEN_CORE_WRITES.keys()) expect(ids.has(id), id).toBe(true);
  });
  it('the tool -> action -> route map', () => {
    for (const [tool, { action, route }] of Object.entries(WRITE_TOOLS)) {
      expect(mig).toContain(`WHEN '${tool}' THEN ARRAY['${action}', '${route}']`);
      expect(USER_TOKEN_CORE_WRITES.get(route)).toBe(action);
    }
  });
  it('every other write route still refuses a user token', () => {
    const writes = ROUTES.filter((r) => r.auth === 'api_key' && r.method !== 'GET');
    for (const r of writes) {
      if (USER_TOKEN_CORE_WRITES.has(r.id)) {
        expect(userTokenMayCall('oauth', r.method, r.id), r.id).toBe(true);
        expect(userTokenMayCall('pat', r.method, r.id), r.id).toBe(true);
      }
    }
    for (const id of ['update-event', 'unpublish-event', 'delete-ticket-type', 'update-ticket-type', 'create-refund', 'issue-comps']) {
      const r = ROUTES.find((x) => x.id === id)!;
      expect(r, id).toBeDefined();
      expect(userTokenMayCall('oauth', r.method, r.id), id).toBe(false);
      expect(userTokenMayCall('pat', r.method, r.id), id).toBe(false);
    }
  });
});
