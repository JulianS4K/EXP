// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

const h = vi.hoisted(() => ({
  toast: vi.fn(),
  queueEmail: vi.fn(),
  createOrgInvite: vi.fn(),
  listOrgInvites: vi.fn(),
}));
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: h.toast }) }));
vi.mock('../context/AuthContext', () => ({ useAuth: () => ({ user: { uid: 'u-owner' }, isAdmin: false }) }));
vi.mock('../context/OrganizationContext', () => ({ useOrganization: () => ({
  activeRole: 'owner',
  orgs: [{ org: { id: 'o1' }, membership: { role: 'owner' } }],
  refresh: vi.fn().mockResolvedValue(undefined),
}) }));
vi.mock('../lib/supabase', () => ({ supabase: {} }));
vi.mock('../lib/mail', () => ({ queueEmail: h.queueEmail }));
vi.mock('../lib/events', () => ({ listOrgEvents: vi.fn().mockResolvedValue([]) }));
vi.mock('../lib/orgs', async (orig) => ({
  ...(await orig<typeof import('../lib/orgs')>()),
  listOrgMembers: vi.fn().mockResolvedValue([{ id: 'm1', orgId: 'o1', uid: 'u-owner', role: 'owner' }]),
  listOrgInvites: h.listOrgInvites,
  listScannerEvents: vi.fn().mockResolvedValue({}),
  createOrgInvite: h.createOrgInvite,
  cancelOrgInvite: vi.fn(),
}));

import OrgMembers from './OrgMembers';

const renderPage = () =>
  render(
    <MemoryRouter initialEntries={['/orgs/o1/members']}>
      <Routes><Route path="/orgs/:orgId/members" element={<OrgMembers />} /></Routes>
    </MemoryRouter>,
  );

beforeEach(() => {
  h.toast.mockReset();
  h.queueEmail.mockReset();
  h.createOrgInvite.mockReset().mockResolvedValue({ token: 'tok-new', inviteUrl: 'https://exos.test/invite/tok-new' });
  h.listOrgInvites.mockReset().mockResolvedValue([{ token: 'tok-1', email: 'dj@club.test', role: 'manager', status: 'pending' }]);
});
afterEach(cleanup);

describe('OrgMembers: invites', () => {
  it('each pending invite has copy-link and resend', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.assign(navigator, { clipboard: { writeText } });
    h.queueEmail.mockResolvedValue(true);
    renderPage();
    fireEvent.click(await screen.findByRole('button', { name: /copy link/i }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(expect.stringMatching(/\/invite\/tok-1$/)));
    fireEvent.click(screen.getByRole('button', { name: /resend/i }));
    await waitFor(() => expect(h.queueEmail).toHaveBeenCalledWith({ template: 'org-invite', refId: 'tok-1' }));
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith({ kind: 'success', message: 'Invite email sent to dj@club.test.' }));
  });

  it('"Invite sent" only when the email queued; otherwise the link is shown', async () => {
    h.queueEmail.mockResolvedValue(false);
    renderPage();
    fireEvent.change(await screen.findByPlaceholderText('email@venue.com'), { target: { value: 'new@club.test' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send invite' }));
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith(expect.objectContaining({ kind: 'warn' })));
    expect(h.toast).not.toHaveBeenCalledWith(expect.objectContaining({ kind: 'success' }));
    expect((await screen.findByLabelText('Invite link') as HTMLInputElement).value).toBe('https://exos.test/invite/tok-new');

    h.queueEmail.mockResolvedValue(true);
    fireEvent.change(screen.getByPlaceholderText('email@venue.com'), { target: { value: 'two@club.test' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send invite' }));
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith({ kind: 'success', message: 'Invite sent to two@club.test.' }));
  });

  it('a refused invite shows the server reason (plain Supabase error object)', async () => {
    h.createOrgInvite.mockRejectedValue({ message: 'new row violates row-level security policy for table "exos_org_invites"', code: '42501' });
    renderPage();
    fireEvent.change(await screen.findByPlaceholderText('email@venue.com'), { target: { value: 'x@club.test' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send invite' }));
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith({ kind: 'error', message: "You don't have permission to do that." }));
  });
});
