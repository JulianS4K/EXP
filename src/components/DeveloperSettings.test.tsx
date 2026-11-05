// @vitest-environment jsdom
// API key scopes in org settings: the picker, the 3-arg create RPC, editing a
// live key's scopes, and the 10-key cap.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

const h = vi.hoisted(() => ({
  rpc: vi.fn(),
  toast: vi.fn(),
  keys: [] as Record<string, unknown>[],
}));
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: h.toast }) }));
vi.mock('../lib/supabase', () => {
  const chain = { select: () => chain, eq: () => chain, order: async () => ({ data: [], error: null }) };
  return { supabase: { rpc: h.rpc, from: () => chain }, initialAuthUrl: '' };
});

import DeveloperSettings from './DeveloperSettings';
import { READ_SCOPES } from '../../supabase/functions/_shared/api/scopes.ts';

const key = (id: string, scopes: string[], revoked = false) => ({
  id, name: `Key ${id}`, key_prefix: 'sk_live_0123abcd', scopes,
  last_used_at: null, revoked_at: revoked ? '2026-10-01T00:00:00Z' : null, created_at: '2026-09-01T00:00:00Z',
});

beforeEach(() => {
  h.toast.mockReset();
  h.keys = [key('legacy', ['read'])];
  h.rpc.mockReset().mockImplementation(async (fn: string) => {
    if (fn === 'exos_list_api_keys') return { data: h.keys, error: null };
    if (fn === 'exos_create_api_key') return { data: 'sk_live_' + 'a'.repeat(48), error: null };
    if (fn === 'exos_set_api_key_scopes') return { data: ['orders:read'], error: null };
    return { data: null, error: null };
  });
});
afterEach(cleanup);

const renderIt = () => render(<MemoryRouter><DeveloperSettings orgId="org-1" canEdit /></MemoryRouter>);
const newKeyBox = () => screen.getByText(/^New key ·/).parentElement as HTMLElement;

describe('DeveloperSettings: API key scopes', () => {
  it('shows a legacy key as all read access and links the reference', async () => {
    renderIt();
    expect(await screen.findByText('All read access')).toBeTruthy();
    expect(screen.getByRole('link', { name: /API reference/ }).getAttribute('href')).toBe('/developers');
  });

  it('creates a key with the read scopes by default, through the 3-arg RPC', async () => {
    renderIt();
    await screen.findByText('All read access');
    const box = newKeyBox();
    const checked = within(box).getAllByRole('checkbox').filter((c) => (c as HTMLInputElement).checked);
    expect(checked.map((c) => c.id.replace('new-key-', ''))).toEqual([...READ_SCOPES]);
    fireEvent.click(within(box).getByLabelText(/Manage webhooks/));
    fireEvent.click(within(box).getByRole('button', { name: /New key/ }));
    await waitFor(() => expect(h.rpc).toHaveBeenCalledWith('exos_create_api_key', {
      p_org_id: 'org-1', p_name: null, p_scopes: [...READ_SCOPES, 'webhooks:write'],
    }));
    expect(await screen.findByText(/sk_live_a{48}/)).toBeTruthy();
  });

  it('edits a live key\'s scopes, spelling out legacy read', async () => {
    renderIt();
    await screen.findByText('All read access');
    fireEvent.click(screen.getByRole('button', { name: 'Scopes' }));
    expect(screen.getByText(/Saving replaces it/)).toBeTruthy();
    for (const s of READ_SCOPES) {
      if (s !== 'orders:read') fireEvent.click(document.getElementById(`key-legacy-${s}`)!);
    }
    fireEvent.click(screen.getByRole('button', { name: 'Save scopes' }));
    await waitFor(() => expect(h.rpc).toHaveBeenCalledWith('exos_set_api_key_scopes', { p_key_id: 'legacy', p_scopes: ['orders:read'] }));
  });

  it('shows the 10-key cap instead of the form, and the RPC\'s cap error inline', async () => {
    h.keys = Array.from({ length: 10 }, (_, i) => key(`k${i}`, ['events:read']));
    renderIt();
    expect((await screen.findByRole('alert')).textContent).toMatch(/10 active API keys/);
    expect(screen.queryByRole('button', { name: /New key/ })).toBeNull();

    cleanup();
    h.keys = [key('legacy', ['read'])];
    h.rpc.mockImplementation(async (fn: string) => {
      if (fn === 'exos_list_api_keys') return { data: h.keys, error: null };
      return { data: null, error: { code: '54000', message: 'exos_create_api_key: at most 10 active keys per organization; revoke one first' } };
    });
    renderIt();
    await screen.findByText('All read access');
    fireEvent.click(within(newKeyBox()).getByRole('button', { name: /New key/ }));
    expect((await screen.findByRole('alert')).textContent).toMatch(/already has 10 active API keys/);
  });
});
