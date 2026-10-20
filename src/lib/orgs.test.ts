import { beforeEach, describe, expect, it, vi } from 'vitest';

// A chainable stand-in for supabase.from(...).update(...).eq(...).select(...).
const result: { data: unknown; error: unknown } = { data: [], error: null };
const rpc = vi.fn();
vi.mock('./supabase', () => {
  const chain: any = {};
  for (const k of ['update', 'eq', 'upsert']) chain[k] = () => chain;
  chain.select = () => Promise.resolve(result);
  return { supabase: { from: () => chain, rpc: (...a: unknown[]) => rpc(...a) } };
});

import {
  assertChanged, disableOrgMember, listOrgMembers, memberActions, memberLabel, NOT_SAVED,
  transferOrgOwnership, updateOrganization, updateOrgMemberRole,
} from './orgs';

beforeEach(() => {
  result.data = [];
  result.error = null;
  rpc.mockReset();
});

describe('0-row writes are not "Saved"', () => {
  it('assertChanged throws on no rows', () => {
    expect(() => assertChanged([])).toThrow(NOT_SAVED);
    expect(() => assertChanged(null)).toThrow(NOT_SAVED);
    expect(() => assertChanged([{ id: 'x' }])).not.toThrow();
  });
  it('membership and org updates that RLS filtered out reject', async () => {
    await expect(updateOrgMemberRole('o', 'u', 'finance')).rejects.toThrow(NOT_SAVED);
    await expect(disableOrgMember('o', 'u')).rejects.toThrow(NOT_SAVED);
    await expect(updateOrganization('o', { name: 'New' })).rejects.toThrow(NOT_SAVED);
    result.data = [{ id: 'm1' }];
    await expect(updateOrgMemberRole('o', 'u', 'finance')).resolves.toBeUndefined();
    await expect(updateOrganization('o', { name: 'New' })).resolves.toBeUndefined();
  });
  it('never sets the owner role directly', async () => {
    result.data = [{ id: 'm1' }];
    await expect(updateOrgMemberRole('o', 'u', 'owner')).rejects.toThrow(/Make owner/);
  });
});

describe('members', () => {
  it('maps the members RPC with email and name', async () => {
    rpc.mockResolvedValue({ data: [{ id: 'm1', user_id: 'u1', role: 'manager', disabled: false, added_at: '2026-10-01T00:00:00Z', email: 'a@x.com', display_name: 'Ann' }], error: null });
    const [m] = await listOrgMembers('o');
    expect(rpc).toHaveBeenCalledWith('exos_org_members', { p_org_id: 'o' });
    expect(m).toMatchObject({ uid: 'u1', role: 'manager', email: 'a@x.com', displayName: 'Ann' });
  });
  it('labels a member by name, then email, never a bare uuid', () => {
    expect(memberLabel({ uid: 'abcdef12-3456', displayName: ' Ann ', email: 'a@x.com' })).toBe('Ann');
    expect(memberLabel({ uid: 'abcdef12-3456', email: 'a@x.com' })).toBe('a@x.com');
    expect(memberLabel({ uid: 'abcdef12-3456' })).toBe('Member abcdef12');
  });
  it('transfer errors read without the function prefix', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'exos_transfer_org_ownership: the new owner must be an active member of the team' } });
    await expect(transferOrgOwnership('o', 'u')).rejects.toThrow(/^the new owner must be an active member/);
  });

  const owner = { uid: 'me', role: 'owner' as const, isAdmin: false };
  it('the owner edits, removes and hands over to others; never on the owner row', () => {
    expect(memberActions(owner, { uid: 'x', role: 'manager' })).toEqual({ editRole: true, remove: true, makeOwner: true, leave: false });
    expect(memberActions(owner, { uid: 'x', role: 'scanner', disabled: true }).makeOwner).toBe(false);
    expect(memberActions(owner, { uid: 'me', role: 'owner' })).toEqual({ editRole: false, remove: false, makeOwner: false, leave: false });
  });
  it('anyone but the owner can leave; a non-owner admin can only hand over', () => {
    expect(memberActions({ uid: 'me', role: 'finance', isAdmin: false }, { uid: 'me', role: 'finance' }))
      .toEqual({ editRole: false, remove: false, makeOwner: false, leave: true });
    expect(memberActions({ uid: 'adm', role: null, isAdmin: true }, { uid: 'x', role: 'manager' }))
      .toEqual({ editRole: false, remove: false, makeOwner: true, leave: false });
    expect(memberActions({ uid: 'me', role: 'manager', isAdmin: false }, { uid: 'x', role: 'scanner' }))
      .toEqual({ editRole: false, remove: false, makeOwner: false, leave: false });
  });
});
