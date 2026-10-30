// exos-api write bodies (supabase/functions/_shared/api/body.ts): capped
// reads that stop a chunked body past the limit, and form decoding.
import { describe, expect, it } from 'vitest';
import { formBody, MAX_BODY_BYTES, readCapped } from '../../supabase/functions/_shared/api/body.ts';

/** A chunked (no Content-Length) body of `n` chunks of `size` bytes; counts how many were pulled. */
function chunked(n: number, size: number) {
  let pulled = 0;
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({
    pull(ctrl) {
      if (pulled >= n) { ctrl.close(); return; }
      pulled += 1;
      ctrl.enqueue(new Uint8Array(size).fill(97));
    },
    cancel() { cancelled = true; },
  });
  const req = new Request('https://x/exos-api/v1/artists', { method: 'POST', body: stream, duplex: 'half' } as RequestInit);
  return { req, pulled: () => pulled, cancelled: () => cancelled };
}

describe('readCapped', () => {
  it('reads a small body', async () => {
    expect(await readCapped(new Request('https://x', { method: 'POST', body: '{"name":"Lumen"}' }), MAX_BODY_BYTES)).toBe('{"name":"Lumen"}');
    expect(await readCapped(new Request('https://x', { method: 'POST' }), 10)).toBe('');
  });

  it('stops a chunked body as soon as it passes the limit and cancels the stream', async () => {
    const b = chunked(1000, 1024); // ~1 MB offered
    expect(await readCapped(b.req, 4 * 1024)).toBeNull();
    expect(b.pulled()).toBeLessThanOrEqual(6);
    expect(b.cancelled()).toBe(true);
  });

  it('refuses a declared Content-Length over the limit without reading', async () => {
    const req = new Request('https://x', { method: 'POST', body: 'abc', headers: { 'content-length': String(MAX_BODY_BYTES + 1) } });
    expect(await readCapped(req, MAX_BODY_BYTES)).toBeNull();
  });

  it('counts bytes, not characters', async () => {
    expect(await readCapped(new Request('https://x', { method: 'POST', body: 'é'.repeat(6) }), 11)).toBeNull();
    expect(await readCapped(new Request('https://x', { method: 'POST', body: 'é'.repeat(5) }), 11)).toBe('ééééé');
  });
});

describe('formBody', () => {
  it('unwraps Opendate-style keys and collects arrays', () => {
    expect(formBody('artist[name]=Lumen&artist[genres][]=House&artist[genres][]=Disco&bad[a][b]=x'))
      .toEqual({ name: 'Lumen', genres: ['House', 'Disco'] });
    expect(formBody('partner_type=jambase&label=JB')).toEqual({ partner_type: 'jambase', label: 'JB' });
  });
});
