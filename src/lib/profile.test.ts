import { describe, expect, it, vi } from 'vitest';

const { from } = vi.hoisted(() => {
  const rows: Record<string, unknown[]> = {
    exos_org_follows: [{ org_id: 'o2', created_at: '2026-10-02' }, { org_id: 'o1', created_at: '2026-10-01' }, { org_id: 'gone' }],
    exos_public_orgs: [
      { id: 'o1', name: 'Night Owls', slug: 'night-owls', followers_count: 12 },
      { id: 'o2', name: 'Basement', slug: 'basement', followers_count: '1' },
    ],
  };
  // A chainable stand-in for the query builder: every call returns it; awaiting it gives the table's rows.
  const from = vi.fn((table: string) => {
    const q: any = {
      select: () => q, order: () => q, in: () => q,
      then: (ok: (v: unknown) => unknown) => Promise.resolve({ data: rows[table], error: null }).then(ok),
    };
    return q;
  });
  return { from };
});
vi.mock('./supabase', () => ({ supabase: { from } }));

import { cleanDisplayName, listFollowedOrgs } from './profile';

describe('profile', () => {
  it('lists followed organizers in follow order, skipping ones no longer public', async () => {
    expect(await listFollowedOrgs()).toEqual([
      { id: 'o2', name: 'Basement', slug: 'basement', followers: 1 },
      { id: 'o1', name: 'Night Owls', slug: 'night-owls', followers: 12 },
    ]);
  });

  it('cleans a display name', () => {
    expect(cleanDisplayName('  Ada   Lovelace \n')).toBe('Ada Lovelace');
    expect(() => cleanDisplayName('   ')).toThrow('Enter a name.');
    expect(() => cleanDisplayName('x'.repeat(61))).toThrow(/under 60/);
  });
});
