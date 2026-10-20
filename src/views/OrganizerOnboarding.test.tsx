// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

const h = vi.hoisted(() => ({
  toast: vi.fn(),
  updateOrganization: vi.fn(),
  uploadOrgLogo: vi.fn(),
  startStripeOnboarding: vi.fn(),
  ready: false as boolean | null,
}));
const ORG = { id: 'o1', name: 'Night Owls', slug: 'night-owls', theme: { customDomain: 'tix.owls.test' } };
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: h.toast }) }));
vi.mock('../context/AuthContext', () => ({ useAuth: () => ({ user: { uid: 'u1' }, openAuthModal: vi.fn() }) }));
vi.mock('../context/OrganizationContext', () => ({
  useOrganization: () => ({ activeOrg: ORG, orgs: [{ org: ORG }], refresh: vi.fn(), setActiveOrg: vi.fn() }),
}));
vi.mock('../lib/supabase', () => ({ supabase: {} }));
vi.mock('../lib/orgLogo', () => ({ uploadOrgLogo: h.uploadOrgLogo }));
vi.mock('../lib/checkout', () => ({ startStripeOnboarding: h.startStripeOnboarding }));
vi.mock('../lib/payments', async (orig) => ({ ...(await orig<typeof import('../lib/payments')>()), paymentsEnabled: () => true }));
vi.mock('../hooks/useOrgPaymentsReady', () => ({ useOrgPaymentsReady: () => h.ready }));
vi.mock('../hooks/useHandleAvailability', () => ({ useHandleAvailability: () => 'idle' }));
vi.mock('../lib/orgs', async (orig) => ({
  ...(await orig<typeof import('../lib/orgs')>()),
  updateOrganization: h.updateOrganization,
  createOrganization: vi.fn(),
}));

import OrganizerOnboarding from './OrganizerOnboarding';

const renderAt = (step: number) => {
  window.location.hash = `step=${step}`;
  return render(
    <MemoryRouter basename="/bridge" initialEntries={['/bridge/onboarding']}>
      <OrganizerOnboarding />
    </MemoryRouter>,
  );
};

beforeEach(() => {
  h.toast.mockReset();
  h.updateOrganization.mockReset().mockResolvedValue(undefined);
  h.uploadOrgLogo.mockReset().mockResolvedValue('https://cdn.test/logo.png');
  h.startStripeOnboarding.mockReset();
  h.ready = false;
});
afterEach(cleanup);

describe('OrganizerOnboarding', () => {
  it('Save & Continue keeps the logo uploaded on the brand step (and other theme keys)', async () => {
    const { container } = renderAt(3);
    const file = new File(['x'], 'logo.png', { type: 'image/png' });
    fireEvent.change(container.querySelector('#ob-logo') as HTMLInputElement, { target: { files: [file] } });
    await waitFor(() => expect(h.updateOrganization).toHaveBeenCalledTimes(1));
    expect(h.updateOrganization.mock.calls[0][1].theme).toMatchObject({ logoUrl: 'https://cdn.test/logo.png', customDomain: 'tix.owls.test' });

    fireEvent.click(screen.getByRole('button', { name: /save & continue/i }));
    await waitFor(() => expect(h.updateOrganization).toHaveBeenCalledTimes(2));
    expect(h.updateOrganization.mock.calls[1][1].theme).toEqual({
      logoUrl: 'https://cdn.test/logo.png', customDomain: 'tix.owls.test', primaryColor: '#FFE714', accentColor: '#0A0A0A',
    });
  });

  it('refuses a colour that is not a hex value', () => {
    renderAt(3);
    fireEvent.change(screen.getByLabelText('Primary'), { target: { value: 'yellow' } });
    expect(screen.getByText('Use a hex color like #FFE714.')).toBeTruthy();
    expect((screen.getByRole('button', { name: /save & continue/i }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('has a payments step that opens Stripe Connect', async () => {
    h.startStripeOnboarding.mockRejectedValue({ message: 'redirect URL not allowed' });
    renderAt(4);
    expect(screen.getByText('Payments', { selector: 'h1' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /connect stripe/i }));
    await waitFor(() => expect(h.startStripeOnboarding).toHaveBeenCalledWith(expect.objectContaining({ orgId: 'o1' })));
    // The edge function's reason, not a generic line.
    await waitFor(() => expect(h.toast).toHaveBeenCalledWith({ kind: 'error', message: 'Redirect URL not allowed' }));
  });

  it('a connected org just continues', () => {
    h.ready = true;
    renderAt(4);
    expect(screen.queryByRole('button', { name: /connect stripe/i })).toBeNull();
    expect(screen.getByRole('button', { name: 'Continue' })).toBeTruthy();
  });

  it('the last step links keep the /bridge base path', () => {
    renderAt(6);
    expect(screen.getByRole('link', { name: /dashboard/i }).getAttribute('href')).toBe('/bridge/dashboard');
    expect(screen.getByRole('link', { name: /your storefront/i }).getAttribute('href')).toBe('/bridge/o/night-owls');
  });
});
