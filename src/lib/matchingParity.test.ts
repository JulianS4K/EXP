import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

// exos-match (Deno) runs supabase/functions/_shared/matching.ts; the SPA and
// these tests use src/lib/matching.ts. They must be the same file.
describe('matching parity (SPA vs exos-match)', () => {
  it('the two copies are byte for byte identical', () => {
    const a = readFileSync(resolve(__dirname, 'matching.ts'), 'utf8');
    const b = readFileSync(resolve(__dirname, '../../supabase/functions/_shared/matching.ts'), 'utf8');
    expect(b).toBe(a);
  });
});
