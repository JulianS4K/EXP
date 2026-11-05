// @vitest-environment jsdom
// The proof token's way back from Stripe / PayPal when storage is blocked
// (in-app browsers): the #pt= fragment, read once and stripped from the URL.
import { afterEach, describe, expect, it, vi } from 'vitest';
vi.mock('./supabase', () => ({ supabase: {} }));
import {
  hashWithoutProofToken, newProofToken, proofTokenFromHash, withProofFragment,
} from '../../supabase/functions/_shared/orderProof.ts';
import { _resetProofTokensForTest, recallProofToken, rememberProofToken, takeProofTokenFromUrl } from './orderProof';

const T = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcd';
const SID = 'cs_test_0123456789';

describe('withProofFragment / proofTokenFromHash', () => {
  it('puts the token in the fragment, never the query', () => {
    const url = 'https://exos.test/my-tickets?checkout=success&guest=1&to=j***%40gmail.com&session_id={CHECKOUT_SESSION_ID}';
    const out = withProofFragment(url, T);
    expect(out).toBe(`${url}#pt=${T}`);
    expect(new URL(out.replace('{CHECKOUT_SESSION_ID}', 'x')).search).not.toContain(T);
    expect(withProofFragment('https://exos.test/a#cart=xyz', T)).toBe(`https://exos.test/a#cart=xyz&pt=${T}`);
    expect(withProofFragment('https://exos.test/a#', T)).toBe(`https://exos.test/a#pt=${T}`);
  });

  it('leaves the URL alone without a usable token', () => {
    expect(withProofFragment('https://exos.test/a', null)).toBe('https://exos.test/a');
    expect(withProofFragment('https://exos.test/a', 'short')).toBe('https://exos.test/a');
    expect(withProofFragment('https://exos.test/a', 'x#y&z=' + T)).toBe('https://exos.test/a');
  });

  it('round-trips a real token', () => {
    const t = newProofToken();
    expect(proofTokenFromHash(new URL(withProofFragment('https://exos.test/a', t)).hash)).toBe(t);
  });

  it('reads pt= next to other fragment parts, and before a query PayPal appended', () => {
    expect(proofTokenFromHash(`#pt=${T}`)).toBe(T);
    expect(proofTokenFromHash(`#cart=abc&pt=${T}`)).toBe(T);
    expect(proofTokenFromHash(`#pt=${T}?token=ABCDEFGH12&PayerID=X`)).toBe(T);
    expect(proofTokenFromHash(`#xpt=${T}`)).toBeNull();
    expect(proofTokenFromHash('#pt=short')).toBeNull();
    expect(proofTokenFromHash('')).toBeNull();
  });

  it('strips only pt=', () => {
    expect(hashWithoutProofToken(`#pt=${T}`)).toBe('');
    expect(hashWithoutProofToken(`#cart=abc&pt=${T}`)).toBe('#cart=abc');
    expect(hashWithoutProofToken(`#pt=${T}&cart=abc`)).toBe('#cart=abc');
    expect(hashWithoutProofToken('#cart=abc')).toBe('#cart=abc');
  });
});

describe('takeProofTokenFromUrl / recallProofToken (storage blocked)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    _resetProofTokensForTest();
    window.history.replaceState(null, '', '/');
  });
  const blockStorage = () => vi.stubGlobal('localStorage', {
    getItem: () => { throw new DOMException('denied', 'SecurityError'); },
    setItem: () => { throw new DOMException('denied', 'SecurityError'); },
    removeItem: () => { throw new DOMException('denied', 'SecurityError'); },
  });

  it('reads the fragment once, strips it, and keeps the rest of the URL', () => {
    blockStorage();
    window.history.replaceState({ idx: 0 }, '', `/my-tickets?checkout=success&guest=1&session_id=${SID}#pt=${T}`);
    expect(takeProofTokenFromUrl()).toBe(T);
    expect(window.location.hash).toBe('');
    expect(window.location.search).toBe(`?checkout=success&guest=1&session_id=${SID}`);
    expect(window.history.state).toEqual({ idx: 0 });
    // Gone from the URL, still known to this page load.
    expect(recallProofToken(SID)).toBe(T);
  });

  it('keeps an order\'s token in memory when storage refuses it', () => {
    blockStorage();
    rememberProofToken(SID, T);
    expect(recallProofToken(SID)).toBe(T);
    expect(recallProofToken('cs_other')).toBeNull();
  });

  it('prefers the stored token when storage works', () => {
    const store = new Map<string, string>([[`exos:proof:${SID}`, 'stored-token-0123456789']]);
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => store.set(k, v), removeItem: (k: string) => store.delete(k),
    });
    window.history.replaceState(null, '', `/my-tickets#pt=${T}`);
    expect(recallProofToken(SID)).toBe('stored-token-0123456789');
  });
});
