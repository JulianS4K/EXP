// @vitest-environment jsdom
// /developers renders the bundled spec (docs/api/*.json via scripts/api-spec.mjs).
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { bundleSpec, loadSpec } from '../../scripts/api-spec.mjs';
import { ROUTES } from '../../supabase/functions/_shared/api/routes.ts';
import Developers from './Developers';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe('Developers', () => {
  it('renders every endpoint, its scope, a curl example and the scope table', async () => {
    const bundle = bundleSpec(loadSpec());
    const fetchMock = vi.fn(async () => new Response(JSON.stringify(bundle), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    window.requestAnimationFrame = ((cb: FrameRequestCallback) => { cb(0); return 0; }) as typeof window.requestAnimationFrame;

    const { container } = render(<MemoryRouter><Developers /></MemoryRouter>);
    await screen.findByRole('heading', { name: 'List events' });

    expect(String((fetchMock.mock.calls[0] as unknown[])[0])).toMatch(/api-spec\.json$/);
    for (const r of ROUTES) expect(container.querySelector(`article#${r.id}`), r.id).not.toBeNull();
    const listOrders = container.querySelector('article#list-orders')!;
    expect(listOrders.textContent).toContain('orders:read');
    expect(listOrders.textContent).toContain('Authorization: Bearer $EXOS_API_KEY');
    expect(listOrders.textContent).toContain('/v1/orders');
    expect(screen.getByTestId('scopes-table').textContent).toContain('All read access');
    expect(screen.getByRole('link', { name: /openapi\.json/i }).getAttribute('href')).toMatch(/openapi\.json$/);
  });

  it('says so when the spec cannot be loaded', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('nope', { status: 404 })));
    render(<MemoryRouter><Developers /></MemoryRouter>);
    expect((await screen.findByRole('alert')).textContent).toContain('could not be loaded');
  });
});
