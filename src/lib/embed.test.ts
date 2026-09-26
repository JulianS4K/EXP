import { describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import {
  EMBED_COMPLETE, EMBED_RESIZE, LEGACY_RESIZE,
  buildEmbedReturnUrl, buildEmbedSnippet, buyableTiers, maxQuantity,
  parseEmbedMessage, parseHostOrigin, postToHost, resolveHostOrigin,
} from './embed';
import { isAllowedEmbedReturn, parseRedirectOrigins } from '../../supabase/functions/_shared/redirects.ts';

const EXOS = 'https://exos.example';
const EVENT = '0f8b6c2e-1111-4222-8333-444455556666';

describe('parseHostOrigin', () => {
  it.each([
    ['https://venue.com', 'https://venue.com'],
    ['https://venue.com/', 'https://venue.com'],
    ['https://www.venue.co.uk:8443', 'https://www.venue.co.uk:8443'],
    ['http://localhost:5173', 'http://localhost:5173'],
  ])('accepts %s', (raw, want) => expect(parseHostOrigin(raw)).toBe(want));

  it.each([
    null, '', 'null', 'venue.com', 'http://venue.com', 'https://venue.com/page',
    'https://venue.com?x=1', 'https://u:p@venue.com', 'javascript:alert(1)', '*',
  ])('rejects %s', (raw) => expect(parseHostOrigin(raw as string | null)).toBeNull());
});

describe('resolveHostOrigin', () => {
  it('prefers ?host=, falls back to ancestorOrigins, else null', () => {
    expect(resolveHostOrigin('?host=https%3A%2F%2Fvenue.com', ['https://other.com'])).toBe('https://venue.com');
    expect(resolveHostOrigin('?host=bogus', ['https://other.com'])).toBe('https://other.com');
    expect(resolveHostOrigin('', [])).toBeNull();
    expect(resolveHostOrigin('', null)).toBeNull();
  });
});

describe('parseEmbedMessage', () => {
  it('accepts well-formed messages', () => {
    expect(parseEmbedMessage({ type: EMBED_RESIZE, height: 412.3 })).toEqual({ type: EMBED_RESIZE, height: 413 });
    expect(parseEmbedMessage({ type: EMBED_COMPLETE, eventId: EVENT, sessionId: 'cs_test_a1B2' }))
      .toEqual({ type: EMBED_COMPLETE, eventId: EVENT, sessionId: 'cs_test_a1B2' });
  });
  it('drops junk', () => {
    expect(parseEmbedMessage(null)).toBeNull();
    expect(parseEmbedMessage('exos:resize')).toBeNull();
    expect(parseEmbedMessage({ type: EMBED_RESIZE, height: '400' })).toBeNull();
    expect(parseEmbedMessage({ type: EMBED_RESIZE, height: Infinity })).toBeNull();
    expect(parseEmbedMessage({ type: EMBED_RESIZE, height: 1e9 })).toBeNull();
    expect(parseEmbedMessage({ type: EMBED_COMPLETE, eventId: '<script>' })).toBeNull();
    expect(parseEmbedMessage({ type: 'other' })).toBeNull();
    // A bad session id is dropped, not passed through.
    expect(parseEmbedMessage({ type: EMBED_COMPLETE, eventId: EVENT, sessionId: 'x"y' })).toEqual({ type: EMBED_COMPLETE, eventId: EVENT });
  });
});

describe('postToHost', () => {
  it('posts to the exact host origin', () => {
    const target = { postMessage: vi.fn() };
    postToHost({ type: EMBED_COMPLETE, eventId: EVENT }, 'https://venue.com', target);
    expect(target.postMessage).toHaveBeenCalledWith({ type: EMBED_COMPLETE, eventId: EVENT }, 'https://venue.com');
  });
  it("never posts completion to '*'; legacy resize only", () => {
    const target = { postMessage: vi.fn() };
    expect(postToHost({ type: EMBED_COMPLETE, eventId: EVENT }, null, target)).toBe(false);
    expect(target.postMessage).not.toHaveBeenCalled();
    postToHost({ type: EMBED_RESIZE, height: 300 }, null, target);
    expect(target.postMessage).toHaveBeenCalledWith({ type: LEGACY_RESIZE, height: 300 }, '*');
  });
});

describe('buildEmbedReturnUrl + isAllowedEmbedReturn', () => {
  const allowed = parseRedirectOrigins(`${EXOS},http://localhost:3000`);
  it('keeps the Stripe template literal and passes the server check', () => {
    const u = buildEmbedReturnUrl(`${EXOS}/bridge/embed/return`, EVENT, 'https://venue.com');
    expect(u).toBe(`${EXOS}/bridge/embed/return?session_id={CHECKOUT_SESSION_ID}&event=${EVENT}&host=https%3A%2F%2Fvenue.com`);
    expect(isAllowedEmbedReturn(u, allowed)).toBe(true);
    expect(isAllowedEmbedReturn(buildEmbedReturnUrl(`${EXOS}/embed/return`, EVENT, null), allowed)).toBe(true);
  });
  it.each([
    'https://evil.example/bridge/embed/return',          // origin not allowlisted
    `${EXOS}/bridge/my-tickets`,                         // not the return page
    `${EXOS}/bridge/embed/event/1`,
    `${EXOS}/a/b/embed/return`,                          // more than one base segment
    `${EXOS}/bridge/embed/return#x`,                     // fragment
    `${EXOS}/bridge/embed/returnx`,
    'http://exos.example/bridge/embed/return',           // http off localhost
    `https://u:p@exos.example/bridge/embed/return`,
    42,
  ])('rejects %s', (u) => expect(isAllowedEmbedReturn(u, allowed)).toBe(false));
});

describe('buildEmbedSnippet', () => {
  it('is a div + loader script', () => {
    const s = buildEmbedSnippet({ loaderUrl: `${EXOS}/bridge/embed.js`, eventId: EVENT, title: 'Night --> <b>Out</b>' });
    expect(s).toBe(`<!-- Exos tickets — Night — bOut/b -->
<div data-exos-event="${EVENT}"></div>
<script src="${EXOS}/bridge/embed.js" async></script>`);
    expect(s.indexOf('-->')).toBe(s.lastIndexOf('-->')); // the title can't close the comment early
  });
  it('replaces a bad id with the placeholder', () => {
    expect(buildEmbedSnippet({ loaderUrl: `${EXOS}/embed.js`, eventId: '"><script>' })).toContain('data-exos-event="EVENT_ID"');
  });
});

describe('buyableTiers / maxQuantity', () => {
  const ts = (ms: number) => ({ toMillis: () => ms });
  const now = 1_000_000;
  const tiers = [
    { id: 'a', price: 20, capacity: 100, sold: 10 },
    { id: 'hidden', price: 20, capacity: 0, sold: 0, visibility: 'hidden' as const },
    { id: 'soldout', price: 20, capacity: 5, sold: 5 },
    { id: 'later', price: 20, capacity: 0, sold: 0, salesStart: ts(now + 1) },
    { id: 'ended', price: 20, capacity: 0, sold: 0, salesEnd: ts(now - 1) },
    { id: 'unlimited', price: 20, capacity: 0, sold: 0, salesStart: ts(now - 1), salesEnd: ts(now + 1) },
  ];
  it('keeps public, on-sale, in-stock tiers', () => {
    expect(buyableTiers(tiers, now).map((t) => t.id)).toEqual(['a', 'unlimited']);
    expect(buyableTiers(undefined)).toEqual([]);
  });
  it('caps quantity by order limit, remaining stock and 10', () => {
    expect(maxQuantity({ id: 'x', price: 1, capacity: 0, sold: 0 })).toBe(8);
    expect(maxQuantity({ id: 'x', price: 1, capacity: 0, sold: 0 }, 25)).toBe(10);
    expect(maxQuantity({ id: 'x', price: 1, capacity: 0, sold: 0 }, 4)).toBe(4);
    expect(maxQuantity({ id: 'x', price: 1, capacity: 10, sold: 7 }, 8)).toBe(3);
    expect(maxQuantity({ id: 'x', price: 1, capacity: 10, sold: 12 })).toBe(0);
  });
});

// Runs the real public/embed.js against a tiny fake DOM.
describe('public/embed.js loader', () => {
  function load(pageUrl = 'https://venue.com/shows?utm_campaign=fall&evil=1') {
    const code = readFileSync(new URL('../../public/embed.js', import.meta.url), 'utf8');
    const listeners: Record<string, (e: unknown) => void> = {};
    const makeEl = (tag: string) => {
      const attrs: Record<string, string> = {};
      const el: Record<string, unknown> = {
        tagName: tag, style: {} as Record<string, string>, children: [] as unknown[], events: [] as unknown[],
        contentWindow: tag === 'iframe' ? { frame: true } : undefined,
        setAttribute: (k: string, v: string) => { attrs[k] = v; },
        getAttribute: (k: string) => (k in attrs ? attrs[k] : null),
        appendChild: (c: unknown) => (el.children as unknown[]).push(c),
        dispatchEvent: (e: unknown) => (el.events as unknown[]).push(e),
      };
      return el;
    };
    const div = makeEl('div');
    (div.setAttribute as (k: string, v: string) => void)('data-exos-event', EVENT);
    const bad = makeEl('div');
    (bad.setAttribute as (k: string, v: string) => void)('data-exos-event', '../../x');
    class FakeCustomEvent { type: string; detail: unknown; constructor(t: string, o: { detail: unknown }) { this.type = t; this.detail = o.detail; } }
    const win: Record<string, unknown> = {
      location: { href: pageUrl, origin: new URL(pageUrl).origin },
      addEventListener: (t: string, fn: (e: unknown) => void) => { listeners[t] = fn; },
      CustomEvent: FakeCustomEvent,
    };
    const doc = {
      currentScript: { src: `${EXOS}/bridge/embed.js` },
      readyState: 'complete',
      createElement: makeEl,
      querySelectorAll: () => [div, bad],
      getElementsByTagName: () => [],
    };
    runInNewContext(code, { window: win, document: doc, URL, encodeURIComponent, isFinite, Math });
    const iframe = (div.children as Record<string, unknown>[])[0];
    return { div, bad, iframe, send: (e: unknown) => listeners.message(e) };
  }

  it('mounts an iframe with ?host= and forwarded attribution only', () => {
    const { iframe, bad } = load();
    expect(iframe.src).toBe(`${EXOS}/bridge/embed/event/${EVENT}?host=https%3A%2F%2Fvenue.com&utm_campaign=fall`);
    expect((iframe.getAttribute as (k: string) => string)('allow')).toBe('payment');
    expect((bad.children as unknown[]).length).toBe(0);
  });

  it('resizes only for messages from the Exos origin and its own iframe', () => {
    const { iframe, send } = load();
    const style = iframe.style as Record<string, string>;
    send({ origin: 'https://evil.com', source: iframe.contentWindow, data: { type: EMBED_RESIZE, height: 900 } });
    expect(style.height).toBe('420px');
    send({ origin: EXOS, source: { other: true }, data: { type: EMBED_RESIZE, height: 900 } });
    expect(style.height).toBe('420px');
    send({ origin: EXOS, source: iframe.contentWindow, data: { type: EMBED_RESIZE, height: 'x' } });
    expect(style.height).toBe('420px');
    send({ origin: EXOS, source: iframe.contentWindow, data: { type: EMBED_RESIZE, height: 612.2 } });
    expect(style.height).toBe('613px');
  });

  it('fires exos:checkout-complete on the div for its own event only', () => {
    const { div, iframe, send } = load();
    send({ origin: EXOS, source: iframe.contentWindow, data: { type: EMBED_COMPLETE, eventId: 'other-event' } });
    expect((div.events as unknown[]).length).toBe(0);
    send({ origin: 'https://evil.com', source: iframe.contentWindow, data: { type: EMBED_COMPLETE, eventId: EVENT } });
    expect((div.events as unknown[]).length).toBe(0);
    send({ origin: EXOS, source: iframe.contentWindow, data: { type: EMBED_COMPLETE, eventId: EVENT, sessionId: 'cs_test_1' } });
    const evs = div.events as { type: string; detail: unknown }[];
    expect(evs).toHaveLength(1);
    expect(evs[0].type).toBe('exos:checkout-complete');
    expect(evs[0].detail).toEqual({ eventId: EVENT, sessionId: 'cs_test_1' });
  });
});
