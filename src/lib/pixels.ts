// Per-org marketing pixels: Meta Pixel, GA4, TikTok, Reddit, Snap and X.
//
// Multi-tenant: pixel IDs come from each org's `marketing.pixels` config
// at runtime, so the loaders are injected from JS rather than hardcoded in
// index.html. The snippets below are the vendors' standard public loaders
// (connect.facebook.net/fbevents.js, googletagmanager.com/gtag/js,
// analytics.tiktok.com/i18n/pixel/events.js, redditstatic.com/ads/pixel.js,
// sc-static.net/scevent.min.js, static.ads-twitter.com/uwt.js).
//
// Consent (lib/consent.ts) is per category: GA4 loads only with ANALYTICS
// consent; Meta, TikTok, Reddit, Snap and X only with ADVERTISING consent.
// Calls made before a category is granted are queued and replayed to that
// category's vendors on opt-in; a visitor who declines loads nothing of that
// category. Withdrawing a category whose vendors already loaded reloads the
// page (vendor scripts can't be unloaded).
//
// Google Consent Mode v2: before gtag.js loads, the consent defaults (all four
// signals denied, wait_for_update) go on the dataLayer, then an update with
// the visitor's actual choice; every later change sends another update.
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
// Dedupe ids: an event id (the Stripe session id for a paid Purchase) goes to
// each vendor in its own field so a later server-side event for the same
// order counts once: Meta eventID, TikTok event_id, GA4 transaction_id,
// Reddit conversionId, Snap client_dedup_id (+ transaction_id on PURCHASE),
// X conversion_id. See docs/social.md "Pixels".
//
// GA4 caveat: enhanced measurement's "page changes based on browser history
// events" (on by default) reports SPA route changes itself, including the
// moment before the reload above. Organizers should turn that setting off in
// their GA4 property (docs/organizer-guide.md); it can't be disabled from here.
//
// CSP: src/lib/hosting/headers.ts allowlists every vendor origin above on the
// pixel routes only (PIXEL_SCRIPT / PIXEL_CONNECT); a vendor missing there
// silently no-ops.

import { getConsentState, onConsentChange, type ConsentCategory, type ConsentSnapshot } from './consent';
import { cleanPixelId, xEventMatchesPixel } from './pixelIds';

export interface PixelConfig {
  meta?: string;
  ga4?: string;
  tiktok?: string;
  /** Reddit pixel id (a2_…). */
  reddit?: string;
  /** Snap Pixel id (UUID). */
  snap?: string;
  /** X pixel id (twq config). */
  x?: string;
  /** X event ids (tw-<pixel>-<event>) per canonical event; an event without one isn't sent to X. */
  xViewContent?: string;
  xInitiateCheckout?: string;
  xPurchase?: string;
}

export type PixelVendor = 'meta' | 'ga4' | 'tiktok' | 'reddit' | 'snap' | 'x';

/** Which consent category each vendor needs. */
export const VENDOR_CATEGORY: Record<PixelVendor, ConsentCategory> = {
  ga4: 'analytics',
  meta: 'advertising',
  tiktok: 'advertising',
  reddit: 'advertising',
  snap: 'advertising',
  x: 'advertising',
};

/** The vendors this config would load (malformed Reddit / Snap / X ids are skipped). */
export function configuredVendors(p: PixelConfig | null | undefined): PixelVendor[] {
  if (!p) return [];
  const out: PixelVendor[] = [];
  if (p.meta) out.push('meta');
  if (p.ga4) out.push('ga4');
  if (p.tiktok) out.push('tiktok');
  if (cleanPixelId('reddit', p.reddit)) out.push('reddit');
  if (cleanPixelId('snap', p.snap)) out.push('snap');
  if (cleanPixelId('x', p.x)) out.push('x');
  return out;
}

/** The consent categories this config needs. */
export function configuredCategories(p: PixelConfig | null | undefined): ConsentCategory[] {
  const cats = new Set(configuredVendors(p).map((v) => VENDOR_CATEGORY[v]));
  return (['analytics', 'advertising'] as ConsentCategory[]).filter((c) => cats.has(c));
}

/** Google Consent Mode v2 signals for a consent state. */
export function googleConsent(s: Pick<ConsentSnapshot, 'analytics' | 'advertising'>): Record<string, 'granted' | 'denied'> {
  const ad = s.advertising === 'granted' ? 'granted' : 'denied';
  return {
    ad_storage: ad,
    ad_user_data: ad,
    ad_personalization: ad,
    analytics_storage: s.analytics === 'granted' ? 'granted' : 'denied',
  };
}

/** The Consent Mode default, sent before any Google tag loads. */
export const GOOGLE_CONSENT_DEFAULT = {
  ad_storage: 'denied',
  ad_user_data: 'denied',
  ad_personalization: 'denied',
  analytics_storage: 'denied',
  wait_for_update: 500,
} as const;

declare global {
  interface Window {
    fbq?: (...args: unknown[]) => void;
    _fbq?: unknown;
    gtag?: (...args: unknown[]) => void;
    dataLayer?: unknown[];
    ttq?: { page: () => void; track: (e: string, p?: unknown) => void; load: (id: string) => void } & Record<string, unknown>;
    TiktokAnalyticsObject?: string;
    rdt?: (...args: unknown[]) => void;
    snaptr?: (...args: unknown[]) => void;
    twq?: (...args: unknown[]) => void;
  }
}

const loaded = new Set<string>();
let pending: PixelConfig | null = null;
let scopeOrg: string | null = null;   // org whose pixels are pending or loaded
// Set once a reload has been decided: from then on nothing fires, so events
// meant for the next org can't reach the pixels that are about to be dropped
// (window.location.reload() doesn't stop the current script).
let reloading = false;
// Short grace before that reload so a just-fired Purchase beacon can flush.
const RELOAD_DELAY_MS = 800;
let subscribed = false;
// Categories whose vendors have loaded for `pending`.
const live = new Set<ConsentCategory>();

// Events fired before a category is granted / loaded are queued here with the
// categories still owed, and replayed once they're live, so a first-visit
// ViewContent isn't lost to the consent gate. Capped so a denied visitor
// can't grow it unbounded.
const deferred: { name: string; params?: Record<string, unknown>; eventId?: string; cats: ConsentCategory[] }[] = [];
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

function scheduleReload(): void {
  if (reloading) return;
  reloading = true;
  scopeOrg = null;
  pending = null;
  live.clear();
  deferred.length = 0;
  setTimeout(() => window.location.reload(), RELOAD_DELAY_MS);
}

function enterScope(orgId: string | null): boolean {
  const action = pixelScopeAction(scopeOrg, orgId, loaded.size > 0);
  if (action === 'reload') {
    scheduleReload();
    return false;
  }
  if (action === 'switch') {
    scopeOrg = orgId;
    pending = null;
    live.clear();
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
  if (typeof window === 'undefined' || reloading) return;
  enterScope(null);
}

// The router path of the current page (the /bridge basename stripped).
function currentRoutePath(): string {
  const base = ((import.meta as any).env?.BASE_URL ?? '/').replace(/\/$/, '');
  const path = window.location.pathname;
  return base && path.startsWith(base) ? path.slice(base.length) || '/' : path;
}

// Register an org's pixels. Loads immediately if consent is granted, else
// queues until the visitor opts in.
export function initOrgPixels(orgId: string, pixels?: PixelConfig): void {
  if (typeof document === 'undefined' || reloading) return;
  // A late org lookup can resolve after the buyer has moved on to an
  // untracked page (My Tickets, the door scanner): never load pixels there.
  if (!isPixelRoute(currentRoutePath())) return;
  register(orgId, pixels);
}

// The one exception to the route rule: the page a buyer lands on after paying
// on Stripe (My Tickets ?checkout=success) reports that org's Purchase. Only
// lib/purchasePixel.ts calls this, after the checkout params are stripped
// from the URL. Leaving My Tickets for a ticket page reloads (see
// leavePixelScope), so the pixels don't follow the buyer into their wallet.
export function initOrgPixelsForPurchase(orgId: string, pixels?: PixelConfig): void {
  if (typeof document === 'undefined' || reloading) return;
  register(orgId, pixels);
}

function register(orgId: string, pixels?: PixelConfig): void {
  if (!enterScope(orgId)) return;
  if (configuredVendors(pixels).length === 0) return;
  pending = pixels!;
  if (!subscribed) {
    subscribed = true;
    onConsentChange((s) => {
      if (!reloading) applyConsent(s);
    });
  }
  applyConsent(getConsentState());
}

// Load each newly granted category's vendors and replay what was queued for
// it; a withdrawn category that already loaded reloads the page.
function applyConsent(s: ConsentSnapshot): void {
  if (window.gtag && [...loaded].some((k) => k.startsWith('ga4:'))) {
    window.gtag('consent', 'update', googleConsent(s));
  }
  for (const cat of live) {
    if (s[cat] !== 'granted') {
      scheduleReload();
      return;
    }
  }
  if (!pending) return;
  const p = pending;
  for (const cat of configuredCategories(p)) {
    if (s[cat] !== 'granted' || live.has(cat)) continue;
    // Each loader fires the vendor's own PageView on init, so callers don't
    // (and must not) also fire one — that would double-count.
    for (const v of configuredVendors(p)) {
      if (VENDOR_CATEGORY[v] === cat) loadVendor(v, p, s);
    }
    live.add(cat);
    for (let i = 0; i < deferred.length; ) {
      const e = deferred[i];
      if (e.cats.includes(cat)) {
        fire(e.name, e.params, e.eventId, [cat]);
        e.cats = e.cats.filter((c) => c !== cat);
      }
      if (e.cats.length === 0) deferred.splice(i, 1);
      else i += 1;
    }
  }
}

function loadVendor(v: PixelVendor, p: PixelConfig, s: ConsentSnapshot): void {
  switch (v) {
    case 'meta': return loadMeta(p.meta!);
    case 'ga4': return loadGa4(p.ga4!, s);
    case 'tiktok': return loadTikTok(p.tiktok!);
    case 'reddit': return loadReddit(cleanPixelId('reddit', p.reddit)!);
    case 'snap': return loadSnap(cleanPixelId('snap', p.snap)!);
    case 'x': return loadX(cleanPixelId('x', p.x)!);
  }
}

/** True once any of the current org's pixels are live (worth a flush delay before leaving). */
export function pixelsLive(): boolean {
  return live.size > 0 && !reloading;
}

type Params = Record<string, unknown>;

const num = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined);
const ids = (p: Params | undefined): string[] =>
  Array.isArray(p?.content_ids) ? (p!.content_ids as unknown[]).filter((x): x is string => typeof x === 'string') : [];

/** GA4 event name for a canonical pixel event. */
export function ga4EventName(name: string): string {
  return name === 'InitiateCheckout' ? 'begin_checkout' : name.toLowerCase();
}

/**
 * Reddit: rdt('track', event, params). Reddit has no checkout-start event, so
 * InitiateCheckout is its AddToCart. Dedupe key: conversionId.
 */
export function redditEvent(name: string, params?: Params, eventId?: string): [string, Params] | null {
  const event = name === 'ViewContent' ? 'ViewContent'
    : name === 'InitiateCheckout' ? 'AddToCart'
    : name === 'Purchase' ? 'Purchase'
    : null;
  if (!event) return null;
  const out: Params = {};
  const products = ids(params).map((id) => {
    const prod: Params = { id, category: 'Tickets' };
    if (typeof params?.content_name === 'string') prod.name = params.content_name;
    return prod;
  });
  if (products.length) out.products = products;
  const value = num(params?.value);
  if (value !== undefined) out.value = value;
  if (typeof params?.currency === 'string') out.currency = params.currency;
  const n = num(params?.num_items);
  if (n !== undefined) out.itemCount = n;
  if (eventId) out.conversionId = eventId;
  return [event, out];
}

/**
 * Snap: snaptr('track', EVENT, params). Dedupe key: client_dedup_id (matches
 * the Conversions API event_id); PURCHASE also carries transaction_id.
 */
export function snapEvent(name: string, params?: Params, eventId?: string): [string, Params] | null {
  const event = name === 'ViewContent' ? 'VIEW_CONTENT'
    : name === 'InitiateCheckout' ? 'START_CHECKOUT'
    : name === 'Purchase' ? 'PURCHASE'
    : null;
  if (!event) return null;
  const out: Params = { item_category: 'tickets' };
  const itemIds = ids(params);
  if (itemIds.length) out.item_ids = itemIds;
  const value = num(params?.value);
  if (value !== undefined) out.price = value;
  if (typeof params?.currency === 'string') out.currency = params.currency;
  const n = num(params?.num_items);
  if (n !== undefined) out.number_items = n;
  if (eventId) {
    out.client_dedup_id = eventId;
    if (event === 'PURCHASE') out.transaction_id = eventId;
  }
  return [event, out];
}

/**
 * X: twq('event', '<event id>', params), where the event id comes from the
 * org's X Events Manager (pixels.xPurchase etc.); no id, no event. Dedupe
 * key: conversion_id.
 */
export function xEvent(name: string, cfg: PixelConfig, params?: Params, eventId?: string): [string, Params] | null {
  const raw = name === 'ViewContent' ? cfg.xViewContent
    : name === 'InitiateCheckout' ? cfg.xInitiateCheckout
    : name === 'Purchase' ? cfg.xPurchase
    : undefined;
  const key = name === 'ViewContent' ? 'xViewContent' : name === 'InitiateCheckout' ? 'xInitiateCheckout' : 'xPurchase';
  const tag = cleanPixelId(key, raw);
  if (!tag || !xEventMatchesPixel(cleanPixelId('x', cfg.x), tag)) return null;
  const out: Params = {};
  const value = num(params?.value);
  if (value !== undefined) out.value = value;
  if (typeof params?.currency === 'string') out.currency = params.currency;
  const n = num(params?.num_items);
  const contents = ids(params).map((id) => {
    const c: Params = { content_id: id, content_type: 'tickets' };
    if (typeof params?.content_name === 'string') c.content_name = params.content_name;
    if (n !== undefined) c.num_items = n;
    return c;
  });
  if (contents.length) out.contents = contents;
  if (eventId) out.conversion_id = eventId;
  return [tag, out];
}

function fire(name: string, params: Params | undefined, eventId: string | undefined, cats: ConsentCategory[]): void {
  const ads = cats.includes('advertising');
  if (ads) {
    // eventId (the Stripe session id for a Purchase) lets each vendor match
    // this browser event to a server-side one and count it once.
    if (window.fbq) {
      if (eventId) window.fbq('track', name, params, { eventID: eventId });
      else window.fbq('track', name, params);
    }
    if (window.ttq) window.ttq.track(name, eventId ? { ...params, event_id: eventId } : params);
    if (window.rdt) {
      const e = redditEvent(name, params, eventId);
      if (e) window.rdt('track', e[0], e[1]);
    }
    if (window.snaptr) {
      const e = snapEvent(name, params, eventId);
      if (e) window.snaptr('track', e[0], e[1]);
    }
    if (window.twq && pending) {
      const e = xEvent(name, pending, params, eventId);
      if (e) window.twq('event', e[0], e[1]);
    }
  }
  // GA4: its recommended name where there is one (begin_checkout), else the
  // lowercased canonical name.
  if (cats.includes('analytics') && window.gtag) {
    window.gtag('event', ga4EventName(name), eventId && name === 'Purchase' ? { ...params, transaction_id: eventId } : params);
  }
}

// Fire a conversion/interaction event across whichever providers are loaded.
// `name` is the canonical event (e.g. 'ViewContent', 'InitiateCheckout',
// 'Purchase'); it's translated to each vendor's nearest equivalent. Calls
// made before a category is granted or loaded are queued and replayed to it.
// Do NOT pass 'PageView' here — the loaders emit that themselves.
export function trackPixelEvent(name: string, params?: Record<string, unknown>, eventId?: string): void {
  if (typeof window === 'undefined' || scopeOrg === null || reloading || !pending) return;
  const nowLive = [...live];
  if (nowLive.length) fire(name, params, eventId, nowLive);
  const owed = configuredCategories(pending).filter((c) => !live.has(c));
  if (owed.length && deferred.length < MAX_DEFERRED) deferred.push({ name, params, eventId, cats: owed });
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

function loadGa4(id: string, s: ConsentSnapshot): void {
  const key = `ga4:${id}`;
  if (loaded.has(key)) return;
  loaded.add(key);
  window.dataLayer = window.dataLayer || [];
  if (!window.gtag) {
    // gtag.js reads `arguments` objects off the dataLayer, not arrays.
    window.gtag = function gtag() {
      // eslint-disable-next-line prefer-rest-params
      window.dataLayer!.push(arguments);
    };
    // Consent Mode v2: defaults first, before gtag.js is even requested,
    // then the visitor's actual choice.
    window.gtag('consent', 'default', { ...GOOGLE_CONSENT_DEFAULT });
    window.gtag('consent', 'update', googleConsent(s));
  }
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

function loadReddit(id: string): void {
  const key = `reddit:${id}`;
  if (loaded.has(key)) return;
  loaded.add(key);
  if (!window.rdt) {
    const p: any = (window.rdt = function (...args: unknown[]) {
      p.sendEvent ? p.sendEvent.apply(p, args) : p.callQueue.push(args);
    });
    p.callQueue = [];
    inject('https://www.redditstatic.com/ads/pixel.js');
  }
  window.rdt!('init', id);
  window.rdt!('track', 'PageVisit');
}

function loadSnap(id: string): void {
  const key = `snap:${id}`;
  if (loaded.has(key)) return;
  loaded.add(key);
  if (!window.snaptr) {
    const a: any = (window.snaptr = function (...args: unknown[]) {
      a.handleRequest ? a.handleRequest.apply(a, args) : a.queue.push(args);
    });
    a.queue = [];
    inject('https://sc-static.net/scevent.min.js');
  }
  window.snaptr!('init', id, {});
  window.snaptr!('track', 'PAGE_VIEW');
}

function loadX(id: string): void {
  const key = `x:${id}`;
  if (loaded.has(key)) return;
  loaded.add(key);
  if (!window.twq) {
    const t: any = (window.twq = function (...args: unknown[]) {
      t.exe ? t.exe.apply(t, args) : t.queue.push(args);
    });
    t.version = '1.1';
    t.queue = [];
    inject('https://static.ads-twitter.com/uwt.js');
  }
  // config sends X's PageView itself.
  window.twq!('config', id);
}
