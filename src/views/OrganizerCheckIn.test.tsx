// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

const h = vi.hoisted(() => ({
  auth: { user: null as { uid: string } | null, loading: false, isAdmin: false, openAuthModal: vi.fn() },
  rpc: vi.fn(),
  from: vi.fn(),
}));
vi.mock('../context/AuthContext', () => ({ useAuth: () => h.auth }));
vi.mock('../context/OrganizationContext', () => ({ useOrganization: () => ({ orgs: [] }) }));
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: vi.fn() }) }));
vi.mock('../lib/supabase', () => ({ supabase: { rpc: h.rpc, from: h.from, channel: vi.fn(), removeChannel: vi.fn() } }));

import OrganizerCheckIn from './OrganizerCheckIn';

const renderDoor = () =>
  render(
    <MemoryRouter initialEntries={['/checkin/11111111-2222-3333-4444-555555555555']}>
      <Routes><Route path="/checkin/:eventId" element={<OrganizerCheckIn />} /></Routes>
    </MemoryRouter>,
  );

beforeEach(() => {
  h.auth.user = null;
  h.auth.loading = false;
  h.auth.openAuthModal.mockReset();
  h.rpc.mockReset();
  h.from.mockReset();
});
afterEach(cleanup);

describe('OrganizerCheckIn: signed out', () => {
  it('shows a sign-in gate, not the scanner, and loads nothing', () => {
    renderDoor();
    expect(screen.getByText(/sign in to check people in/i)).toBeTruthy();
    expect(screen.queryByText(/door check-in/i)).toBeNull();
    expect(screen.queryByPlaceholderText(/./)).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Sign in' }));
    expect(h.auth.openAuthModal).toHaveBeenCalled();
    expect(h.rpc).not.toHaveBeenCalled();
    expect(h.from).not.toHaveBeenCalled();
  });

  it('waits for the session instead of flashing the gate', () => {
    h.auth.loading = true;
    renderDoor();
    expect(screen.queryByText(/sign in to check people in/i)).toBeNull();
    expect(screen.getByLabelText('Loading')).toBeTruthy();
  });
});
