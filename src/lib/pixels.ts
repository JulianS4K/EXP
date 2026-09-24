// Per-org marketing pixels (Meta Pixel, GA4, TikTok).
//
// Multi-tenant: pixel IDs come from each org's `marketing.pixels` config
// at runtime, so the loaders are injected from JS rather than hardcoded in
// index.html. The snippets below are the vendors' standard public loaders
// (connect.facebook.net/fbevents.js, googletagmanager.com/gtag/js,
// analytics.tiktok.com/i18n/pixel/events.js).
//
// Consent: nothing loads until lib/consent.ts reports 'granted'. Calls made
// before consent are queued and flushed on opt-in; a visitor who declines
// loads nothing.
//
// Idempotency: keyed by `${provider}:${id}` so re-renders don't re-inject.
//
// One org per page: vendor pixels can't be unloaded, and a loaded pixel keeps
// receiving every later event (fbq('track') goes to every init'd pixel, GA4
// enhanced measurement reports history changes). So once an org's pixels are
// live, moving to another org's page, or to a page that must not be tracked
// (door check-in), reloads the page to drop them. Queued pre-consent events
// are discarded when the org changes, so they can't reach the next org.
//
// CSP: these inject <script src> from the three vendor origins and run the
// inline bootstraps. If a strict Content-Security-Policy is added later, it
// must allowlist those origins (and 'unsafe-inline' or a nonce for the
// bootstraps) or the pixels silently no-op.

import { getConsent, onConsentChange } from './consent';

export interface PixelConfig {
  meta?: string;
  ga4?: string;
  tiktok?: string;
}

declare global {
  interface Window {
    fbq?: (...args: unknown[]) => void;
    _fbq?: unknown;
    gtag?: (...args: unknown[]) => void;
    dataLayer?: unknown[];
    ttq?: { page: () => void; track: (e: string, p?: unknown) => void; load: (id: string) => void } & Record<string, unknown>;
    TiktokAnalyticsObject?: string;
  }
}

const loaded = new Set<string>();
let pending: PixelConfig | null = null;
let scopeOrg: string | null = null;   // org whose pixels are pending or loaded
let subscribed = false;
let ready = false;

// Events fired before consent/load are queued here and replayed once the
// providers are live, so a first-visit ViewContent isn't lost to the consent
// gate. Capped so a denied visitor can't grow it unbounded.
const deferred: { name: string; params?: Record<string, unknown> }[] = [];
const MAX_DEFERRED = 20;

export type PixelScopeAction = 'reload' | 'switch' | 'keep';

// What to do when a page for `nextOrg` (null = an untracked page) mounts.
export function pixelScopeAction(
  currentOrg: string | null,
  nextOrg: string | null,
  anyLoaded: boolean,
): PixelScopeAction {
  if (currentOrg === nextOrg) return 'keep';
  return anyLoaded ? 'reload' : 'switch';
}

function enterScope(orgId: string | null): boolean {
  const action = pixelScopeAction(scopeOrg, orgId, loaded.size > 0);
  if (action === 'reload') {
    window.location.reload();
    return false;
  }
  if (action === 'switch') {
    scopeOrg = orgId;
    pending = null;
    ready = false;
    deferred.length = 0;
  }
  return true;
}

// Public listing pages an org's pixels may see. Everything else (tickets,
// wallet, transfers, account, dashboards, door check-in) is untracked.
const PIXEL_ROUTE_PREFIXES = ['/event/', '/e/', '/o/', '/organizer/', '/embed/event/', '/l/'];
// Exact public pages that aren't one org's (no org pixels fire there anyway).
const PIXEL_ROUTES_EXACT = new Set(['/', '/map']);
export function isPixelRoute(pathname: string): boolean {
  return PIXEL_ROUTES_EXACT.has(pathname) || PIXEL_ROUTE_PREFIXES.some((p) => pathname.startsWith(p));
}

// Call on pages that must never send data to a pixel (door check-in, account
// pages). Reloads only if some org's pixels are already live.
export function leavePixelScope(): void {
  if (typeof window === 'undefined') return;
  enterScope(null);
}

// Register an org's pixels. Loads immediately if consent is granted, else
// queues until the visitor opts in.
export function initOrgPixels(orgId: string, pixels?: PixelConfig): void {
  if (typeof document === 'undefined') return;
  if (!enterScope(orgId)) return;
  if (!pixels || (!pixels.meta && !pixels.ga4 && !pixels.tiktok)) return;
  pending = pixels;

  if (getConsent() === 'granted') {
    flush();
  } else if (!subscribed) {
    subscribed = true;
    onConsentChange((s) => {
      if (s === 'granted') flush();
    });
  }
}

function flush(): void {
  if (!pending) return;
  const p = pending;
  // Each loader fires the vendor's own PageView on init, so callers don't
  // (and must not) also fire one — that would double-count.
  if (p.meta) loadMeta(p.meta);
  if (p.ga4) loadGa4(p.ga4);
  if (p.tiktok) loadTikTok(p.tiktok);
  ready = true;
  const queued = deferred.splice(0, deferred.length);
  for (const e of queued) fire(e.name, e.params);
}

function fire(name: string, params?: Record<string, unknown>): void {
  if (window.fbq) window.fbq('track', name, params);
  if (window.ttq) window.ttq.track(name, params);
  // GA4 has no fixed event taxonomy; lowercase the canonical name.
  if (window.gtag) window.gtag('event', name.toLowerCase(), params);
}

// Fire a conversion/interaction event across whichever providers are loaded.
// `name` is the canonical event (e.g. 'ViewContent', 'Purchase'); it's
// translated to each vendor's nearest equivalent. Calls made before consent
// or before the providers finish loading are queued and replayed on flush.
// Do NOT pass 'PageView' here — the loaders emit that themselves.
export function trackPixelEvent(name: string, params?: Record<string, unknown>): void {
  if (typeof window === 'undefined' || scopeOrg === null) return;
  if (getConsent() !== 'granted' || !ready) {
    if (deferred.length < MAX_DEFERRED) deferred.push({ name, params });
    return;
  }
  fire(name, params);
}

function inject(src: string): void {
  const s = document.createElement('script');
  s.async = true;
  s.src = src;
  document.head.appendChild(s);
}

function loadMeta(id: string): void {
  const key = `meta:${id}`;
  if (loaded.has(key)) return;
  loaded.add(key);
  if (!window.fbq) {
    const n: any = (window.fbq = function (...args: unknown[]) {
      n.callMethod ? n.callMethod.apply(n, args) : n.queue.push(args);
    });
    if (!window._fbq) window._fbq = n;
    n.push = n;
    n.loaded = true;
    n.version = '2.0';
    n.queue = [];
    // Our loaders fire PageView themselves; stop fbevents auto-tracking SPA
    // route changes, which would send account/ticket URLs to the pixel.
    n.disablePushState = true;
    inject('https://connect.facebook.net/en_US/fbevents.js');
  }
  window.fbq!('init', id);
  window.fbq!('track', 'PageView');
}

function loadGa4(id: string): void {
  const key = `ga4:${id}`;
  if (loaded.has(key)) return;
  loaded.add(key);
  window.dataLayer = window.dataLayer || [];
  window.gtag =
    window.gtag ||
    function (...args: unknown[]) {
      window.dataLayer!.push(args);
    };
  inject(`https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(id)}`);
  window.gtag('js', new Date());
  window.gtag('config', id);
}

function loadTikTok(id: string): void {
  const key = `tiktok:${id}`;
  if (loaded.has(key)) return;
  loaded.add(key);
  const w = window as any;
  w.TiktokAnalyticsObject = 'ttq';
  const ttq = (w.ttq = w.ttq || []);
  ttq.methods = [
    'page', 'track', 'identify', 'instances', 'debug', 'on', 'off',
    'once', 'ready', 'alias', 'group', 'enableCookie', 'disableCookie',
  ];
  ttq.setAndDefer = function (t: any, e: string) {
    t[e] = function (...args: unknown[]) {
      t.push([e].concat(Array.prototype.slice.call(args, 0)));
    };
  };
  for (const m of ttq.methods) ttq.setAndDefer(ttq, m);
  ttq.load = function (e: string) {
    const url = 'https://analytics.tiktok.com/i18n/pixel/events.js';
    ttq._i = ttq._i || {};
    ttq._i[e] = [];
    ttq._i[e]._u = url;
    ttq._t = ttq._t || {};
    ttq._t[e] = +new Date();
    ttq._o = ttq._o || {};
    ttq._o[e] = {};
    inject(`${url}?sdkid=${encodeURIComponent(e)}&lib=ttq`);
  };
  ttq.load(id);
  ttq.page();
}
