// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

const h = vi.hoisted(() => ({
  toast: vi.fn(),
  smsOverview: vi.fn(),
  cancelCampaign: vi.fn(),
}));
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: h.toast }) }));
vi.mock('../lib/supabase', () => ({ supabase: {} }));
vi.mock('../lib/sms', async (orig) => ({
  ...(await orig<typeof import('../lib/sms')>()),
  smsOverview: h.smsOverview,
  audienceSize: vi.fn().mockResolvedValue({ total: 3, capped: 0, reachable: 3 }),
  cancelCampaign: h.cancelCampaign,
}));

import SmsPanel from './SmsPanel';

const overview = {
  subscribers: 3, optedOut: 0, provider: 'twilio',
  campaigns: [{
    id: 'c1', audience: 'event_buyers', eventId: 'e1', body: 'Doors at 10', status: 'queued',
    sendAfter: new Date(Date.UTC(2026, 9, 20, 20)), createdAt: new Date(), queued: 3, skippedCap: 0, sent: 0, dryRun: 0, failed: 0,
  }],
};

const renderPanel = () =>
  render(<MemoryRouter><SmsPanel orgId="o1" orgName="Club" eventId="e1" canSend canView /></MemoryRouter>);

beforeEach(() => {
  h.toast.mockReset();
  h.smsOverview.mockReset().mockResolvedValue(overview);
  h.cancelCampaign.mockReset();
});
afterEach(cleanup);

describe('SmsPanel: cancel a campaign', () => {
  it('a failed cancel shows an error and keeps the campaign queued', async () => {
    h.cancelCampaign.mockRejectedValue(new Error('not allowed'));
    renderPanel();
    fireEvent.click(await screen.findByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith(expect.objectContaining({ kind: 'error' })));
    expect(h.toast).not.toHaveBeenCalledWith(expect.objectContaining({ kind: 'success' }));
    expect(h.smsOverview).toHaveBeenCalledTimes(1);
    expect(screen.getByText(/queued/)).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeTruthy();
  });

  it('a cancel that worked says how many were stopped and reloads', async () => {
    h.cancelCampaign.mockResolvedValue(3);
    renderPanel();
    fireEvent.click(await screen.findByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith({ kind: 'success', message: 'Cancelled 3 not yet sent.' }));
    await waitFor(() => expect(h.smsOverview).toHaveBeenCalledTimes(2));
  });
});
