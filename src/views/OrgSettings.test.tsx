// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';

const h = vi.hoisted(() => ({
  toast: vi.fn(),
  updateOrganization: vi.fn(),
  getOrganization: vi.fn(),
}));
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: h.toast }) }));
vi.mock('../context/AuthContext', () => ({ useAuth: () => ({ user: { uid: 'u1' }, isAdmin: false }) }));
vi.mock('../context/OrganizationContext', () => ({ useOrganization: () => ({ activeRole: 'owner', roleIn: () => 'owner' }) }));
vi.mock('../lib/supabase', () => ({ supabase: {} }));
vi.mock('../lib/comps', () => ({ getOrgCompUsage: vi.fn().mockResolvedValue(0), setOrgCompBudget: vi.fn() }));
vi.mock('../lib/marketplace/s4kNetwork', () => ({ setS4kNetwork: vi.fn() }));
vi.mock('../lib/checkout', () => ({ startStripeOnboarding: vi.fn() }));
vi.mock('../lib/orgLogo', () => ({ uploadOrgLogo: vi.fn() }));
vi.mock('../lib/payments', async (orig) => ({ ...(await orig<typeof import('../lib/payments')>()), paymentsEnabled: () => true }));
vi.mock('../lib/orgs', async (orig) => ({
  ...(await orig<typeof import('../lib/orgs')>()),
  getOrganization: h.getOrganization,
  updateOrganization: h.updateOrganization,
}));
vi.mock('../components/WebsitePanel', () => ({ default: () => null }));
vi.mock('../components/IntegrationsPanel', () => ({ default: () => null }));
vi.mock('../components/DeveloperSettings', () => ({ default: () => null }));
vi.mock('../components/CatalogFeedPanel', () => ({ default: () => null }));
vi.mock('../components/AudienceExportPanel', () => ({ default: () => null }));
vi.mock('../components/AdConversionsSettings', () => ({ default: () => null }));
vi.mock('../components/OrgLegalSettings', () => ({ default: () => null }));

import OrgSettings from './OrgSettings';

const ORG = {
  id: 'o1', name: 'Night Owls', slug: 'night-owls', ownerUid: 'u1', country: 'US', currency: 'USD',
  theme: { primaryColor: '#FFE714', customDomain: 'tix.owls.test' }, marketing: {}, payments: {},
};

const renderPage = () =>
  render(
    <MemoryRouter initialEntries={['/orgs/o1/settings']}>
      <Routes>
        <Route path="/orgs/:orgId/settings" element={<OrgSettings />} />
        <Route path="/orgs/:orgId/members" element={<p>members page</p>} />
      </Routes>
    </MemoryRouter>,
  );

beforeEach(() => {
  h.toast.mockReset();
  h.updateOrganization.mockReset().mockResolvedValue(undefined);
  h.getOrganization.mockReset().mockResolvedValue(ORG);
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('OrgSettings', () => {
  it('on a phone, Payments leads the page (before Profile)', async () => {
    const { container } = renderPage();
    await screen.findByLabelText('Org Name');
    const headings = [...container.querySelectorAll('h2')].map((el) => el.textContent);
    expect(headings.indexOf('Payments')).toBeLessThan(headings.indexOf('Profile'));
    expect(container.querySelector('.lg\\:hidden h2')?.textContent).toBe('Payments');
  });

  it('edits show a sticky save bar, and leaving by a tab asks first', async () => {
    renderPage();
    const name = await screen.findByLabelText('Org Name');
    expect(screen.queryByText(/unsaved changes/i)).toBeNull();
    fireEvent.change(name, { target: { value: 'Night Owls NYC' } });
    expect(screen.getByText(/unsaved changes/i)).toBeTruthy();

    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
    fireEvent.click(screen.getByRole('button', { name: 'Members' }));
    expect(confirm).toHaveBeenCalled();
    expect(screen.queryByText('members page')).toBeNull();

    confirm.mockReturnValue(true);
    fireEvent.click(screen.getByRole('button', { name: 'Members' }));
    expect(await screen.findByText('members page')).toBeTruthy();
  });

  it('saving clears the bar and keeps theme keys the form does not edit', async () => {
    renderPage();
    fireEvent.change(await screen.findByLabelText('Org Name'), { target: { value: 'Night Owls NYC' } });
    const bar = screen.getByRole('status');
    fireEvent.click(bar.querySelector('button') as HTMLButtonElement);
    await waitFor(() => expect(h.updateOrganization).toHaveBeenCalled());
    expect(h.updateOrganization.mock.calls[0][1]).toMatchObject({
      name: 'Night Owls NYC', theme: { primaryColor: '#FFE714', customDomain: 'tix.owls.test' },
    });
    await waitFor(() => expect(screen.queryByText(/unsaved changes/i)).toBeNull());
    // Nothing unsaved: tabs don't ask.
    const confirm = vi.spyOn(window, 'confirm');
    fireEvent.click(screen.getByRole('button', { name: 'Members' }));
    expect(confirm).not.toHaveBeenCalled();
  });

  it('a failed save shows the server reason', async () => {
    h.updateOrganization.mockRejectedValue({ message: 'value too long for type character varying(100)', code: '22001' });
    renderPage();
    fireEvent.change(await screen.findByLabelText('Org Name'), { target: { value: 'Night Owls NYC' } });
    fireEvent.click(screen.getByRole('status').querySelector('button') as HTMLButtonElement);
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith({ kind: 'error', message: 'Value too long for type character varying(100)' }));
  });
});
