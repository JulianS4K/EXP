// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

const h = vi.hoisted(() => ({
  toast: vi.fn(),
  createOrganization: vi.fn(),
  isOrgHandleAvailable: vi.fn(),
}));
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: h.toast }) }));
vi.mock('../context/AuthContext', () => ({ useAuth: () => ({ user: { uid: 'u1' }, openAuthModal: vi.fn() }) }));
vi.mock('../context/OrganizationContext', () => ({
  useOrganization: () => ({ refresh: vi.fn().mockResolvedValue(undefined), setActiveOrg: vi.fn() }),
}));
vi.mock('../lib/supabase', () => ({ supabase: {} }));
vi.mock('../lib/orgs', async (orig) => ({
  ...(await orig<typeof import('../lib/orgs')>()),
  createOrganization: h.createOrganization,
  isOrgHandleAvailable: h.isOrgHandleAvailable,
}));

import CreateOrg from './CreateOrg';

const renderPage = (path = '/orgs/new') =>
  render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/orgs/new" element={<CreateOrg />} />
        <Route path="/create-event" element={<p>create event page</p>} />
        <Route path="/dashboard" element={<p>dashboard page</p>} />
      </Routes>
    </MemoryRouter>,
  );

beforeEach(() => {
  h.toast.mockReset();
  h.createOrganization.mockReset();
  h.isOrgHandleAvailable.mockReset().mockResolvedValue(true);
});
afterEach(cleanup);

describe('CreateOrg', () => {
  it('checks the handle as the user types', async () => {
    h.isOrgHandleAvailable.mockImplementation(async (s: string) => s !== 'night-owls');
    renderPage();
    fireEvent.change(screen.getByLabelText(/organization name/i), { target: { value: 'Night Owls' } });
    expect(await screen.findByText('That handle is taken. Try a different one.')).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Create organization' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(screen.getByLabelText(/public handle/i), { target: { value: 'night-owls-nyc' } });
    expect(await screen.findByText('Available')).toBeTruthy();
    expect(h.isOrgHandleAvailable).toHaveBeenLastCalledWith('night-owls-nyc');
  });

  it('a 23505 on the handle (lost a race) says the handle is taken', async () => {
    h.createOrganization.mockRejectedValue({
      message: 'duplicate key value violates unique constraint "exos_orgs_slug_key"', code: '23505',
      details: 'Key (slug)=(owls)=(owls) already exists.',
    });
    renderPage();
    fireEvent.change(screen.getByLabelText(/organization name/i), { target: { value: 'Owls' } });
    await screen.findByText('Available');
    fireEvent.click(screen.getByRole('button', { name: 'Create organization' }));
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith({ kind: 'error', message: 'The handle "owls" is taken. Try a different one.' }));
  });

  it('shows the server reason for other failures (org limit)', async () => {
    h.createOrganization.mockRejectedValue({ message: 'exos_create_org: organization limit reached (3 a day). Try again tomorrow, or contact support.', code: 'P0001' });
    renderPage();
    fireEvent.change(screen.getByLabelText(/organization name/i), { target: { value: 'Owls' } });
    await screen.findByText('Available');
    fireEvent.click(screen.getByRole('button', { name: 'Create organization' }));
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith({
      kind: 'error', message: 'Organization limit reached (3 a day). Try again tomorrow, or contact support.',
    }));
  });

  it('?next=/create-event goes back to Create Event after creating', async () => {
    h.createOrganization.mockResolvedValue({ orgId: 'o1' });
    renderPage('/orgs/new?next=/create-event');
    fireEvent.change(screen.getByLabelText(/organization name/i), { target: { value: 'Owls' } });
    await screen.findByText('Available');
    fireEvent.click(screen.getByRole('button', { name: 'Create organization' }));
    expect(await screen.findByText('create event page')).toBeTruthy();
  });
});
