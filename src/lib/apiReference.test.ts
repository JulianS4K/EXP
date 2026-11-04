// The partner API reference (docs/api/*.json, scripts/api-spec.mjs) against
// the route table the exos-api edge function dispatches on
// (supabase/functions/_shared/api/routes.ts). docs/api-reference.md.
//
// A route can't ship undocumented, a documented endpoint can't be missing from
// the API, and the scope the docs promise is the scope the function enforces.

import { describe, expect, it } from 'vitest';
import { ROUTES, apiPath, matchRoute } from '../../supabase/functions/_shared/api/routes.ts';
import { SCOPES } from '../../supabase/functions/_shared/api/scopes.ts';
import { bundleSpec, loadSpec, normalizePath, readScopes, toOpenApi } from '../../scripts/api-spec.mjs';

const spec = loadSpec();
const endpoints = spec.categories.flatMap((c: any) => c.endpoints as any[]);
const key = (method: string, path: string) => `${method} ${normalizePath(path)}`;

describe('API reference spec', () => {
  it('validates with no errors or warnings', () => {
    expect(spec.errors).toEqual([]);
    expect(spec.warnings).toEqual([]);
  });

  it('reads the same SCOPES the edge function imports', () => {
    expect(readScopes()).toEqual([...SCOPES]);
  });

  it('bundles into api-spec.json and openapi.json shapes', () => {
    const bundle = bundleSpec(spec);
    const openapi = toOpenApi(bundle) as any;
    expect(bundle.categories.reduce((n: number, c: any) => n + c.endpoints.length, 0)).toBe(ROUTES.length);
    expect(openapi.openapi).toBe('3.1.0');
    expect(openapi.paths['/v1/events/{id}'].get['x-required-scope']).toBe('events:read');
    expect(openapi.paths['/v1/me'].get['x-required-scope']).toBeNull();
  });
});

describe('API reference covers the route table', () => {
  it('documents every route exactly once, under /v1, with its scope', () => {
    for (const r of ROUTES) {
      const docs = endpoints.filter((e) => key(e.method, e.path) === key(r.method, `/v1${r.path === '/' ? '' : r.path}`));
      expect(docs.map((e) => e.id), `${r.method} ${r.path}`).toEqual([r.id]);
      expect(docs[0].scope, `${r.id} scope`).toBe(r.scope);
      expect(docs[0].auth, `${r.id} auth`).toBe(r.auth);
    }
  });

  it('has a route for every documented endpoint', () => {
    for (const e of endpoints) {
      const m = matchRoute(e.method, apiPath(`/functions/v1/exos-api${e.path}`));
      expect(m?.route.id, `${e.method} ${e.path}`).toBe(e.id);
    }
    expect(endpoints).toHaveLength(ROUTES.length);
  });

  it('documents page and per_page on exactly the paged routes', () => {
    for (const r of ROUTES) {
      const e = endpoints.find((x) => x.id === r.id);
      const names = (e.parameters as any[]).filter((p) => p.location === 'query').map((p) => p.name);
      const pagedDoc = names.includes('page') && names.includes('per_page');
      expect(pagedDoc, `${r.id} paged`).toBe(r.paged !== false);
      const ok = e.responses.find((x: any) => x.status === 200);
      if (r.paged === true) {
        expect(Object.keys(ok.example.meta), `${r.id} meta`).toEqual(['page', 'per_page', 'total', 'total_pages']);
      } else if (r.paged === 'opendate') {
        expect(Object.keys(ok.example), `${r.id} envelope`)
          .toEqual(['current_page', 'per_page', 'total_entries', 'total_pages', 'collection']);
      }
    }
  });

  it('documents 403 insufficient_scope on every scoped route', () => {
    for (const r of ROUTES) {
      const e = endpoints.find((x) => x.id === r.id);
      // A route may document other 403s too (owner only, the partner's comps scope).
      const scoped = e.responses.filter((x: any) => x.status === 403 && x.example?.required_scope !== undefined);
      if (r.scope) expect(scoped.map((x: any) => x.example.required_scope), r.id).toEqual([r.scope]);
      else expect(scoped, r.id).toEqual([]);
    }
  });
});
