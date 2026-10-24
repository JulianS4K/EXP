// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

const h = vi.hoisted(() => ({
  toast: vi.fn(),
  createEvent: vi.fn(),
  org: { orgs: [] as unknown[], activeOrg: null as unknown, loading: false },
}));
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: h.toast }) }));
vi.mock('../context/AuthContext', () => ({ useAuth: () => ({ user: { uid: 'u1', emailVerified: true } }) }));
vi.mock('../context/OrganizationContext', () => ({ useOrganization: () => h.org }));
vi.mock('../lib/supabase', () => ({ supabase: {} }));
vi.mock('../lib/events', () => ({ createEvent: h.createEvent, getEventForEdit: vi.fn() }));
vi.mock('../lib/tablesApi', () => ({ applyTableConfigsBySortOrder: vi.fn().mockResolvedValue(undefined) }));
vi.mock('../lib/geo', () => ({ geocodeEvent: vi.fn() }));
vi.mock('../lib/storage', () => ({ uploadEventImage: vi.fn(), deleteStorageObject: vi.fn() }));
vi.mock('../lib/onlineEventsApi', () => ({ setEventJoinLink: vi.fn() }));
vi.mock('../hooks/useAccessColumns', () => ({ useAccessColumns: () => false }));
vi.mock('../hooks/useStoreColumns', () => ({ useStoreColumns: () => false }));
vi.mock('../hooks/useOnlineColumns', () => ({ useOnlineColumns: () => false }));
vi.mock('../hooks/useOrgPaymentsReady', () => ({ useOrgPaymentsReady: () => null }));
vi.mock('../components/ChannelChoicePicker', () => ({ default: () => null }));

import CreateEvent from './CreateEvent';

const renderPage = () =>
  render(
    <MemoryRouter initialEntries={['/create-event']}>
      <Routes>
        <Route path="/create-event" element={<CreateEvent />} />
        <Route path="/orgs/new" element={<p>create org page</p>} />
        <Route path="/dashboard" element={<p>dashboard page</p>} />
      </Routes>
    </MemoryRouter>,
  );

beforeEach(() => {
  h.toast.mockReset();
  h.createEvent.mockReset().mockResolvedValue({ eventId: 'e1' });
  try { localStorage.clear(); } catch { /* */ }
});
afterEach(cleanup);

describe('CreateEvent', () => {
  it('no organization: straight to /orgs/new, before the form', async () => {
    h.org = { orgs: [], activeOrg: null, loading: false };
    renderPage();
    expect(await screen.findByText('create org page')).toBeTruthy();
    expect(h.toast).toHaveBeenCalledWith(expect.objectContaining({ kind: 'info' }));
  });

  it('"Save Draft" needs only a title (and the org)', async () => {
    const org = { id: 'o1', name: 'Owls', slug: 'owls' };
    h.org = { orgs: [{ org, role: 'owner' }], activeOrg: org, loading: false };
    renderPage();
    expect(screen.queryByText(/legacy path/i)).toBeNull();
    fireEvent.click(await screen.findByRole('button', { name: 'Save Draft' }));
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith(expect.objectContaining({ message: 'Please enter an event title.' })));
    expect(h.createEvent).not.toHaveBeenCalled();

    fireEvent.change(screen.getByLabelText('Event name'), { target: { value: 'Half-planned party' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save Draft' }));
    await waitFor(() => expect(h.createEvent).toHaveBeenCalled());
    const input = h.createEvent.mock.calls[0][0];
    expect(input).toMatchObject({ orgId: 'o1', name: 'Half-planned party', status: 'draft', startsAt: null });
    // Blank numbers go in as 0, never NaN (which the insert would refuse).
    for (const t of input.tiers) expect(Number.isFinite(t.price) && Number.isFinite(t.capacity)).toBe(true);
    expect(Number.isFinite(input.totalTickets)).toBe(true);
    expect(await screen.findByText('dashboard page')).toBeTruthy();
  });

  it('"Publish" still checks everything', async () => {
    const org = { id: 'o1', name: 'Owls', slug: 'owls' };
    h.org = { orgs: [{ org, role: 'owner' }], activeOrg: org, loading: false };
    renderPage();
    fireEvent.change(await screen.findByLabelText('Event name'), { target: { value: 'Half-planned party' } });
    fireEvent.submit(document.querySelector('form') as HTMLFormElement);
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith(expect.objectContaining({ kind: 'error', title: 'Check your details' })));
    expect(h.createEvent).not.toHaveBeenCalled();
  });
});
