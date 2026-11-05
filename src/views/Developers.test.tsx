// @vitest-environment jsdom
// /developers renders the bundled spec (docs/api/*.json via scripts/api-spec.mjs).
//
// With ~350 endpoints, rendering the whole reference in jsdom takes most of a
// worker's time budget under a parallel run. So: the spec itself is checked
// for every route (pure), and the page is rendered from a slice of it (every
// category, with the endpoints the assertions below look at) and must render
// an article for every endpoint it is given.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { bundleSpec, loadSpec } from '../../scripts/api-spec.mjs';
import { ROUTES } from '../../supabase/functions/_shared/api/routes.ts';
import Developers from './Developers';

interface Endpoint { id: string; method: string; path: string; scope: string | null }
interface Category { file: string; endpoints: Endpoint[] }
interface Bundle { categories: Category[] }

const bundle = bundleSpec(loadSpec()) as Bundle;
const LOOKED_AT = new Set(['list-events', 'list-orders', 'public-list-events', 'create-artist']);

/** A path with its parameters blanked (the spec writes :id or {id}). */
const shape = (path: string) => path.replace(/:[A-Za-z_]\w*|\{[A-Za-z_]\w*\}/g, ':_');

/** Every category, with its first endpoint and any endpoint the test looks at. */
function slice(b: Bundle): Bundle {
  return {
    ...b,
    categories: b.categories.map((c) => ({ ...c, endpoints: c.endpoints.filter((e, i) => i === 0 || LOOKED_AT.has(e.id)) })),
  };
}

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe('Developers', () => {
  it('the bundled spec has every route once, with its method, path and scope', () => {
    const all = bundle.categories.flatMap((c) => c.endpoints);
    const byId = new Map(all.map((e) => [e.id, e]));
    expect(byId.size).toBe(all.length);
    for (const r of ROUTES) {
      const e = byId.get(r.id);
      expect(e, r.id).toBeDefined();
      expect([e!.method, shape(e!.path), e!.scope ?? null], r.id).toEqual([r.method, shape(`/v1${r.path}`), r.scope]);
    }
  });

  it('renders every endpoint it is given, its scope, a curl example and the scope table', async () => {
    const spec = slice(bundle);
    const given = spec.categories.flatMap((c) => c.endpoints);
    expect(given.length).toBeGreaterThanOrEqual(spec.categories.length);
    for (const id of LOOKED_AT) expect(given.some((e) => e.id === id), id).toBe(true);
    const fetchMock = vi.fn(async () => new Response(JSON.stringify(spec), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    window.requestAnimationFrame = ((cb: FrameRequestCallback) => { cb(0); return 0; }) as typeof window.requestAnimationFrame;

    const { container } = render(<MemoryRouter><Developers /></MemoryRouter>);
    await screen.findByRole('heading', { name: 'List events' });

    expect(String((fetchMock.mock.calls[0] as unknown[])[0])).toMatch(/api-spec\.json$/);
    for (const e of given) expect(container.querySelector(`article#${e.id}`), e.id).not.toBeNull();
    expect(container.querySelectorAll('article').length).toBe(given.length);
    for (const c of spec.categories) expect(container.querySelector(`section#cat-${c.file}`), c.file).not.toBeNull();
    const listOrders = container.querySelector('article#list-orders')!;
    expect(listOrders.textContent).toContain('orders:read');
    expect(listOrders.textContent).toContain('Authorization: Bearer $EXOS_API_KEY');
    expect(listOrders.textContent).toContain('/v1/orders');
    expect(screen.getByTestId('scopes-table').textContent).toContain('All read access');
    expect(screen.getByRole('link', { name: /openapi\.json/i }).getAttribute('href')).toMatch(/openapi\.json$/);
    // The listing feed authenticates with a shared key in the query string.
    const feed = container.querySelector('article#public-list-events')!;
    expect(feed.textContent).toContain('shared_key=$EXOS_SHARED_KEY');
    expect(feed.textContent).not.toContain('Authorization: Bearer');
    // Writes show their JSON body.
    expect(container.querySelector('article#create-artist')!.textContent).toContain('-X POST');
    // jsdom renders one article per category plus the ones looked at (about 50
    // and growing by one per API category); under a full parallel run that can
    // pass vitest's 5 s default, so this test gets its own budget.
  }, 20_000);

  it('says so when the spec cannot be loaded', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('nope', { status: 404 })));
    render(<MemoryRouter><Developers /></MemoryRouter>);
    expect((await screen.findByRole('alert')).textContent).toContain('could not be loaded');
  });
});
