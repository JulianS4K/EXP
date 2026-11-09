// docs/opendate-coverage.json (scripts/check-opendate-coverage.mjs): every
// Opendate endpoint accounted for, every Exos route it names real and
// documented, and docs/opendate-coverage.md generated from it.

import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { ROUTES, matchRoute } from '../../supabase/functions/_shared/api/routes.ts';
import {
  EXPECTED_ENDPOINTS, ROOT, STATUSES, check, namedRoutes, normPath, readRoutes, renderMarkdown,
} from '../../scripts/check-opendate-coverage.mjs';

const res = check();
const entries = res.coverage.endpoints as { category: string; method: string; path: string; status: string; exos: string; reason: string }[];

describe('Opendate coverage', () => {
  it('checks with no errors', () => {
    expect(res.errors).toEqual([]);
  });

  it('has one entry per Opendate endpoint, each with a known status', () => {
    expect(entries).toHaveLength(EXPECTED_ENDPOINTS);
    for (const e of entries) expect(STATUSES).toContain(e.status);
  });

  it('reads the same route table the edge function dispatches on', () => {
    expect(readRoutes().map((r: { id: string }) => r.id)).toEqual(ROUTES.map((r) => r.id));
  });

  it('names, for each route entry, a route the matcher resolves', () => {
    for (const e of entries.filter((x) => x.status === 'route')) {
      const [{ method, path: p }] = namedRoutes(e.exos);
      const concrete = p.replace(/^\/v1/, '').replace(/:[A-Za-z_]\w*/g, 'x');
      expect(matchRoute(method, concrete), `${e.method} ${e.path} -> ${e.exos}`).not.toBeNull();
    }
  });

  it('keeps admin endpoints off `route`', () => {
    expect(entries.filter((e) => e.category.startsWith('admin') && e.status === 'route')).toEqual([]);
  });

  it('flags a route the table does not have', () => {
    expect(namedRoutes('GET /v1/no-such-thing/:id')).toEqual([{ method: 'GET', path: '/v1/no-such-thing/:id' }]);
    expect(normPath('/v1/events/{id}/fee-rules?x=1')).toBe(normPath('/events/:event_id/fee-rules'));
  });

  it('has a current docs/opendate-coverage.md', () => {
    expect(fs.readFileSync(path.join(ROOT, 'docs', 'opendate-coverage.md'), 'utf8')).toBe(renderMarkdown(res));
  });
});
