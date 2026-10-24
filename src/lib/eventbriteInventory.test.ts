import { describe, expect, it } from 'vitest';
import { EB_API, listTicketClasses, unshareableReason, type EbTicketClass, type Fetch } from '../../supabase/functions/_shared/eventbrite/client.ts';
import {
  assertCapacityOnly, planCapacity, planRecord, sendCapacity, writesLive, type CapacityPlan,
} from '../../supabase/functions/_shared/eventbrite/writer.ts';

type Call = { url: string; init?: RequestInit };
function fake(status: number, body: unknown): { fetch: Fetch; calls: Call[] } {
  const calls: Call[] = [];
  return {
    calls,
    fetch: async (url, init) => {
      calls.push({ url, init });
      return new Response(JSON.stringify(body), { status });
    },
  };
}

describe('ticket classes (read)', () => {
  it('reads every page with GET and keeps only the fields the sync uses', async () => {
    const pages = [
      { ticket_classes: [{ id: '101', name: 'GA', capacity: 50, quantity_sold: 10, free: false, cost: { value: 2500 } }],
        pagination: { has_more_items: true, continuation: 'c2' } },
      { ticket_classes: [{ id: '102', name: 'Tiered', capacity: null, quantity_total: 30, quantity_sold: 2, inventory_tier_id: '9', hidden: true },
                         { id: 'nope' }],
        pagination: { has_more_items: false } },
    ];
    const calls: Call[] = [];
    const fetch: Fetch = async (url, init) => {
      calls.push({ url, init });
      return new Response(JSON.stringify(pages[calls.length - 1]), { status: 200 });
    };
    const r = await listTicketClasses(fetch, 'TOKEN123', '555');
    expect(r.ok).toBe(true);
    expect(r.body).toEqual([
      { id: '101', name: 'GA', capacity: 50, quantity_sold: 10, inventory_tier_id: null, free: false, hidden: false, donation: false, category: 'admission' },
      { id: '102', name: 'Tiered', capacity: 30, quantity_sold: 2, inventory_tier_id: '9', free: false, hidden: true, donation: false, category: 'admission' },
    ]);
    expect(calls.map((c) => c.init?.method)).toEqual(['GET', 'GET']);
    expect(calls[0].url).toBe(`${EB_API}/events/555/ticket_classes/`);
    expect(new URL(calls[1].url).searchParams.get('continuation')).toBe('c2');
  });
  it('says which classes can\'t share a count', () => {
    const c: EbTicketClass = { id: '1', name: 'x', capacity: 5, quantity_sold: 0, inventory_tier_id: null, free: false, hidden: false, donation: false, category: 'admission' };
    expect(unshareableReason(c)).toBeNull();
    expect(unshareableReason({ ...c, inventory_tier_id: '9' })).toMatch(/inventory tier/);
    expect(unshareableReason({ ...c, donation: true })).toMatch(/Donation/);
    expect(unshareableReason({ ...c, category: 'add_on' })).toMatch(/Add-ons/);
  });
  it('refuses a bad event id without calling', async () => {
    const { fetch, calls } = fake(200, {});
    expect((await listTicketClasses(fetch, 't', '5x')).ok).toBe(false);
    expect(calls).toHaveLength(0);
  });
});

describe('the one write: a ticket class capacity', () => {
  it('plans only a change', () => {
    expect(planCapacity('555', '101', 50, 50)).toBeNull();
    expect(planCapacity('555', '101', 50, -1)).toBeNull();
    // Eventbrite refuses 0 on a normal class (and reads it as unlimited on a donation): never sent.
    expect(planCapacity('555', '101', 50, 0)).toBeNull();
    expect(planCapacity('555', '101', 50, null)).toBeNull();
    // ...except on a class Exos created: hidden instead (mig 20261020110000).
    expect(planCapacity('555', '101', 50, 0, { exosCreated: true })?.body).toEqual({ ticket_class: { hidden: true } });
    expect(planCapacity('55x', '101', 50, 60)).toBeNull();
    expect(planCapacity('555', '101', 50, 96)).toEqual({
      method: 'POST', path: '/events/555/ticket_classes/101/', body: { ticket_class: { capacity: 96 } },
      ticket_class_id: '101', from: 50, to: 96,
    });
  });
  it('is live only with the org switch and the operator flag', () => {
    expect(writesLive(true, 'on')).toBe(true);
    expect(writesLive(true, undefined)).toBe(false);
    expect(writesLive(true, 'ON')).toBe(false);
    expect(writesLive(false, 'on')).toBe(false);
  });
  it('refuses anything but the capacity update', () => {
    const ok = planCapacity('555', '101', 50, 96)!;
    expect(() => assertCapacityOnly(ok)).not.toThrow();
    const bad: CapacityPlan[] = [
      { ...ok, path: '/organizations/1/events/' },
      { ...ok, path: '/events/555/ticket_classes/' },
      { ...ok, body: { ticket_class: { capacity: 96, cost: 'USD,100' } } as unknown as CapacityPlan['body'] },
      { ...ok, body: { ticket_class: { capacity: 96 }, event: {} } as unknown as CapacityPlan['body'] },
      { ...ok, method: 'DELETE' as 'POST' },
    ];
    for (const b of bad) expect(() => assertCapacityOnly(b)).toThrow(/only a ticket class capacity/);
  });
  it('sends POST with the token in the header and the capacity as the only field', async () => {
    const { fetch, calls } = fake(200, { id: '101' });
    const r = await sendCapacity(fetch, 'TOKEN123', planCapacity('555', '101', 50, 96)!);
    expect(r.ok).toBe(true);
    expect(calls[0].url).toBe(`${EB_API}/events/555/ticket_classes/101/`);
    expect(calls[0].init?.method).toBe('POST');
    expect((calls[0].init?.headers as Record<string, string>).Authorization).toBe('Bearer TOKEN123');
    expect(JSON.parse(String(calls[0].init?.body))).toEqual({ ticket_class: { capacity: 96 } });
    expect(calls[0].url).not.toContain('TOKEN123');
  });
  it('returns Eventbrite\'s error code', async () => {
    const { fetch } = fake(400, { error: 'CAPACITY_TOTAL_TOO_SMALL', error_description: 'x' });
    expect(await sendCapacity(fetch, 't', planCapacity('555', '101', 50, 5)!)).toEqual({ ok: false, status: 400, body: null, error: 'CAPACITY_TOTAL_TOO_SMALL' });
  });
  it('records the plan without the token', () => {
    const rec = planRecord(planCapacity('555', '101', 50, 96)!, false);
    expect(rec).toEqual({ dry_run: true, method: 'POST', path: '/events/555/ticket_classes/101/', body: { ticket_class: { capacity: 96 } }, from: 50, to: 96 });
  });
});
