// Cookie consent store: two categories.
//
//   * analytics:   GA4.
//   * advertising: Meta, TikTok, Reddit, Snap and X pixels, plus the Google
//                  Consent Mode ad signals (ad_storage, ad_user_data,
//                  ad_personalization) that Google Ads remarketing reads.
//
// Third-party pixels set cookies and phone home, so none of them loads until
// the visitor opts in to its category (lib/pixels.ts). A choice is sticky: a
// visitor who declines isn't re-asked, and can change their mind from
// "Cookie settings" in the footer (openConsentSettings reopens the banner).
//
// Global Privacy Control: a browser that sends navigator.globalPrivacyControl
// === true is treated as "advertising: denied" until the visitor explicitly
// switches advertising on in the banner. Analytics isn't affected by GPC.
//
// Persisted in localStorage so the choice survives reloads. No cookie is set
// for the consent flag itself (it's first-party functional state, not
// tracking), which keeps the gate outside the thing it gates.
//
// Backward compatible: the earlier single flag ('exos.consent.marketing.v1' =
// 'granted' | 'denied') still reads as both categories granted / denied.

const LEGACY_KEY = 'exos.consent.marketing.v1';
const KEY = 'exos.consent.v2';

export type ConsentCategory = 'analytics' | 'advertising';
export type ConsentState = 'granted' | 'denied' | 'unset';

export interface ConsentSnapshot {
  /** Effective analytics consent. */
  analytics: ConsentState;
  /** Effective advertising consent ('denied' under GPC until opted in). */
  advertising: ConsentState;
  /** The browser sends Global Privacy Control. */
  gpc: boolean;
  /** The visitor made a choice for both categories (the banner stays hidden). */
  decided: boolean;
}

interface Stored {
  analytics?: 'granted' | 'denied';
  advertising?: 'granted' | 'denied';
}

// The last choice made on this page, so a choice holds even when storage is blocked.
let memory: Stored | null = null;

const listeners = new Set<(s: ConsentSnapshot) => void>();
const settingsListeners = new Set<() => void>();

function readRaw(key: string): string | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage.getItem(key);
  } catch {
    return null;
  }
}

const isChoice = (v: unknown): v is 'granted' | 'denied' => v === 'granted' || v === 'denied';

/** Parse what's stored (v2 JSON, else the legacy single flag). Pure. */
export function parseStoredConsent(v2: string | null, legacy: string | null): Stored {
  if (v2) {
    try {
      const o = JSON.parse(v2) as Record<string, unknown>;
      const out: Stored = {};
      if (isChoice(o?.analytics)) out.analytics = o.analytics;
      if (isChoice(o?.advertising)) out.advertising = o.advertising;
      if (out.analytics || out.advertising) return out;
    } catch { /* fall through to the legacy flag */ }
  }
  if (isChoice(legacy)) return { analytics: legacy, advertising: legacy };
  return {};
}

/** The effective state from what's stored and the GPC signal. Pure. */
export function resolveConsent(stored: Stored, gpc: boolean): ConsentSnapshot {
  const analytics: ConsentState = stored.analytics ?? 'unset';
  // GPC is an opt-out signal: advertising stays off unless explicitly granted.
  const advertising: ConsentState = stored.advertising ?? (gpc ? 'denied' : 'unset');
  return { analytics, advertising, gpc, decided: !!stored.analytics && !!stored.advertising };
}

/** navigator.globalPrivacyControl === true. */
export function hasGpc(): boolean {
  try {
    return typeof navigator !== 'undefined' && (navigator as { globalPrivacyControl?: unknown }).globalPrivacyControl === true;
  } catch {
    return false;
  }
}

/** Both categories and the GPC flag, as the pixels and checkout should see them. */
export function getConsentState(): ConsentSnapshot {
  return resolveConsent(memory ?? parseStoredConsent(readRaw(KEY), readRaw(LEGACY_KEY)), hasGpc());
}

export function hasConsent(category: ConsentCategory): boolean {
  return getConsentState()[category] === 'granted';
}

/**
 * Legacy single-flag read, kept for older callers: the ADVERTISING state
 * (what "marketing consent" meant for checkout records and ad pixels).
 */
export function getConsent(): ConsentState {
  return getConsentState().advertising;
}

/** Record a choice for both categories and notify subscribers. */
export function setConsentChoice(choice: { analytics: boolean; advertising: boolean }): void {
  const stored: Stored = {
    analytics: choice.analytics ? 'granted' : 'denied',
    advertising: choice.advertising ? 'granted' : 'denied',
  };
  memory = stored;
  try {
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(KEY, JSON.stringify({ ...stored, at: new Date().toISOString() }));
      localStorage.removeItem(LEGACY_KEY);
    }
  } catch { /* storage blocked: the choice holds for this page only */ }
  const snap = resolveConsent(stored, hasGpc());
  for (const fn of listeners) fn(snap);
}

/** Legacy: grant or deny both categories. */
export function setConsent(granted: boolean): void {
  setConsentChoice({ analytics: granted, advertising: granted });
}

// Subscribe to consent changes. Returns an unsubscribe fn.
export function onConsentChange(fn: (s: ConsentSnapshot) => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

/** Reopen the banner ("Cookie settings" link). */
export function openConsentSettings(): void {
  for (const fn of settingsListeners) fn();
}

export function onOpenConsentSettings(fn: () => void): () => void {
  settingsListeners.add(fn);
  return () => settingsListeners.delete(fn);
}
