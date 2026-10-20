// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { Timestamp } from '../lib/timestamp';

const h = vi.hoisted(() => ({
  toast: vi.fn(),
  getEventForEdit: vi.fn(),
  updateEvent: vi.fn(),
  cancelEvent: vi.fn(),
}));
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: h.toast }) }));
vi.mock('../context/AuthContext', () => ({ useAuth: () => ({ user: { uid: 'u1' }, isAdmin: false }) }));
vi.mock('../lib/supabase', () => ({ supabase: {} }));
vi.mock('../lib/events', () => ({
  getEventForEdit: h.getEventForEdit,
  updateEvent: h.updateEvent,
  cancelEvent: h.cancelEvent,
  notifyEventHolders: vi.fn(),
  addTier: vi.fn(),
  updateTier: vi.fn().mockResolvedValue(undefined),
  deleteTier: vi.fn(),
}));
vi.mock('../lib/geo', () => ({ geocodeEvent: vi.fn() }));
vi.mock('../lib/storage', () => ({ uploadEventImage: vi.fn() }));
vi.mock('../lib/tablesApi', () => ({ getTierTableRows: vi.fn().mockResolvedValue({}), saveTierTableConfig: vi.fn() }));
vi.mock('../lib/marketplace/stubhubStatusApi', () => ({ getMarketplaceRows: vi.fn().mockResolvedValue([]) }));
vi.mock('../lib/onlineEventsApi', () => ({ getEventJoinLinkForStaff: vi.fn().mockResolvedValue(null), setEventJoinLink: vi.fn() }));
vi.mock('../lib/reschedule', () => ({ rescheduleEvent: vi.fn() }));
vi.mock('../hooks/useOrgPaymentsReady', () => ({ useOrgPaymentsReady: () => null }));
vi.mock('../components/TicketBackendPanel', () => ({ default: () => null }));
vi.mock('../components/ChannelsPanel', () => ({ default: () => null }));
vi.mock('../components/AddonsEditor', () => ({ default: () => null }));
vi.mock('../components/VouchersEditor', () => ({ default: () => null }));
vi.mock('../components/QuotasEditor', () => ({ default: () => null }));
vi.mock('../components/TaxRulesEditor', () => ({ default: () => null }));
vi.mock('../components/CheckinListsEditor', () => ({ default: () => null }));
vi.mock('../components/ChannelSplitPanel', () => ({ default: () => null }));
vi.mock('../components/S4kRoutePanel', () => ({ default: () => null }));
vi.mock('../components/ChannelLinks', () => ({
  LABEL: {}, ChannelLinks: () => null, MarketplaceGrid: () => null, MarketplaceOrders: () => null,
}));

import EditEvent from './EditEvent';

const DAY = 24 * 3600_000;
const ts = (ms: number) => Timestamp.fromDate(new Date(ms));
const event = (over: Record<string, unknown> = {}) => {
  const start = Date.now() + 10 * DAY;
  return {
    id: 'e1', orgId: 'o1', title: 'Warehouse', description: '', location: 'Brooklyn', category: 'Music',
    status: 'published', timezone: 'UTC', currency: 'USD', price: 20, totalTickets: 100, ticketsSold: 0,
    date: ts(start),
    timing: { startTime: ts(start), doorsOpen: ts(start - 3600_000), endTime: ts(start + 4 * 3600_000) },
    // Created with a blank "What's included".
    ticketTiers: [{ id: 't1', name: 'GA', price: 20, capacity: 100, sold: 0, description: null }],
    ...over,
  };
};

const renderPage = () =>
  render(
    <MemoryRouter initialEntries={['/edit/e1']}>
      <Routes>
        <Route path="/edit/:eventId" element={<EditEvent />} />
        <Route path="/dashboard" element={<p>dashboard page</p>} />
      </Routes>
    </MemoryRouter>,
  );
const submitForm = () => fireEvent.submit(document.querySelector('form') as HTMLFormElement);
const showInput = (label: string) =>
  screen.getByText(label, { selector: 'label' }).parentElement!.querySelector('input') as HTMLInputElement;

beforeEach(() => {
  h.toast.mockReset();
  h.updateEvent.mockReset().mockResolvedValue(undefined);
  h.cancelEvent.mockReset();
  h.getEventForEdit.mockReset().mockResolvedValue(event());
});
afterEach(cleanup);

describe('EditEvent', () => {
  it('has no dead "Event Date" field; Show Start is the date', async () => {
    renderPage();
    await screen.findByText('Show Start', { selector: 'label' });
    expect(screen.queryByText('Event Date', { selector: 'label' })).toBeNull();
  });

  it('saves an event whose ticket type has a blank "What\'s included"', async () => {
    renderPage();
    await screen.findByText('Show Start', { selector: 'label' });
    const desc = screen.getByPlaceholderText('Describe the exclusivity of this tier...') as HTMLTextAreaElement;
    expect(desc.required).toBe(false);
    submitForm();
    await waitFor(() => expect(h.updateEvent).toHaveBeenCalled());
    expect(h.toast).toHaveBeenCalledWith({ kind: 'success', message: 'Changes saved.' });
  });

  it("refuses doors after the start, and an end before it (Create Event's rules)", async () => {
    renderPage();
    await screen.findByText('Show Start', { selector: 'label' });
    fireEvent.change(showInput('Doors Open'), { target: { value: '2099-01-01T00:00' } });
    submitForm();
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith({
      kind: 'error', title: 'Check your details', message: 'Doors must open before the show starts.',
    }));
    fireEvent.change(showInput('Doors Open'), { target: { value: '' } });
    fireEvent.change(showInput('Show End'), { target: { value: showInput('Show Start').value } });
    submitForm();
    await waitFor(() => expect(h.toast).toHaveBeenLastCalledWith({
      kind: 'error', title: 'Check your details', message: 'Show end must be after the show start.',
    }));
    expect(h.updateEvent).not.toHaveBeenCalled();
  });

  it('a cancelled event offers no way back to published or draft', async () => {
    h.getEventForEdit.mockResolvedValue(event({ status: 'cancelled' }));
    renderPage();
    await screen.findByText('CANCELLED');
    expect(screen.queryByRole('button', { name: /mark as published/i })).toBeNull();
    expect(screen.queryByRole('button', { name: /move to draft/i })).toBeNull();
  });

  it('a draft can still be published', async () => {
    h.getEventForEdit.mockResolvedValue(event({ status: 'draft' }));
    renderPage();
    expect(await screen.findByRole('button', { name: /mark as published/i })).toBeTruthy();
  });
});
