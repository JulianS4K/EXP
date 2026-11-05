// Tixel's fan-data webhook (mig 20261105120000): the secrets env var and the
// secret -> org lookup.
import { describe, expect, it } from 'vitest';
import { orgForSecret, parseTixelBody, parseTixelSecrets } from '../../supabase/functions/_shared/tixel/webhook';

const A = '11111111-2222-3333-4444-555555555555';
const B = '66666666-7777-8888-9999-000000000000';

describe('tixel webhook', () => {
  it('reads the env var, dropping malformed entries', () => {
    expect(parseTixelSecrets(undefined)).toEqual({ pairs: [], dropped: 0 });
    expect(parseTixelSecrets('nope')).toEqual({ pairs: [], dropped: 1 });
    expect(parseTixelSecrets('[1]')).toEqual({ pairs: [], dropped: 1 });
    const r = parseTixelSecrets(JSON.stringify({
      [A.toUpperCase()]: 'secret-of-org-a-123', [B]: 'short', 'not-a-uuid': 'secret-of-nobody-12', [B + 'x']: 7,
    }));
    expect(r).toEqual({ pairs: [{ orgId: A, secret: 'secret-of-org-a-123' }], dropped: 3 });
    // Two orgs with one secret: the second is dropped (a secret picks one org).
    expect(parseTixelSecrets(JSON.stringify({ [A]: 'same-secret-123456', [B]: 'same-secret-123456' })).dropped).toBe(1);
  });
  it('the secret picks the org; anything else is no org', () => {
    const { pairs } = parseTixelSecrets(JSON.stringify({ [A]: 'secret-of-org-a-123', [B]: 'secret-of-org-b-456' }));
    expect(orgForSecret(pairs, 'secret-of-org-b-456')).toBe(B);
    expect(orgForSecret(pairs, 'secret-of-org-b-45')).toBeNull();
    expect(orgForSecret(pairs, 'secret-of-org-b-4567')).toBeNull();
    expect(orgForSecret(pairs, '')).toBeNull();
    expect(orgForSecret(pairs, null)).toBeNull();
  });
  it('takes a JSON object only', () => {
    expect(parseTixelBody('{"action":"WAITLIST"}')).toEqual({ action: 'WAITLIST' });
    expect(parseTixelBody('[]')).toBeNull();
    expect(parseTixelBody('x')).toBeNull();
  });
});
