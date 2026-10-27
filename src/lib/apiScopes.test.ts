// The partner API's scope vocabulary has two homes: SCOPES in
// supabase/functions/_shared/api/scopes.ts (the edge function, the key UI,
// /developers) and exos_api_scope_names() in mig 20261027090000 (what
// exos_create_api_key / exos_set_api_key_scopes accept). They must agree.

import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  LEGACY_READ, READ_SCOPES, SCOPES, SCOPE_INFO, effectiveScopes, hasScope,
} from '../../supabase/functions/_shared/api/scopes.ts';

const MIGRATION = path.resolve(__dirname, '../../supabase/migrations/20261027090000_exos_api_scopes.sql');

function sqlScopeNames(): string[] {
  const sql = readFileSync(MIGRATION, 'utf8');
  const fn = /FUNCTION public\.exos_api_scope_names\(\)[\s\S]*?SELECT ARRAY\[([\s\S]*?)\]::text\[\]/.exec(sql);
  if (!fn) throw new Error('exos_api_scope_names() not found in the migration');
  return [...fn[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
}

describe('API scopes', () => {
  it('SCOPES equals exos_api_scope_names() in the migration, in order', () => {
    expect(sqlScopeNames()).toEqual([...SCOPES]);
  });

  it('every scope has a label and description', () => {
    expect(Object.keys(SCOPE_INFO).sort()).toEqual([...SCOPES].sort());
    for (const s of SCOPES) {
      expect(SCOPE_INFO[s].label.length, s).toBeGreaterThan(0);
      expect(SCOPE_INFO[s].description.length, s).toBeGreaterThan(0);
    }
  });

  it('legacy read covers every :read scope and nothing else', () => {
    expect(effectiveScopes([LEGACY_READ])).toEqual([...READ_SCOPES]);
    expect(hasScope([LEGACY_READ], 'events:write')).toBe(false);
  });

  it('a :write scope covers its own :read only', () => {
    expect(effectiveScopes(['events:write'])).toEqual(['events:read', 'events:write']);
    expect(hasScope(['events:write'], 'orders:read')).toBe(false);
  });
});
