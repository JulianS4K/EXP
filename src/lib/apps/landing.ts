// The public landing pages of the Exos apps suite (docs/strategy.md "Apps"):
// /apps/door, /apps/events, /apps/promote and /apps/money.
//
// Every feature bullet and every price on these pages is a claim from the facts
// registry (src/lib/hosting/productFacts.ts), so a page can only say what the
// registry says works: `live` facts as they are, `at_launch` facts labelled
// "coming at launch", and `off` / `not_shipped` facts never. The page's own
// words (headline, intro, SEO description) are job statements kept to what the
// bullets below them already back; landing.test.ts and AppLanding.test.tsx
// check both.
//
// Pure: no React, no Supabase. src/views/AppLanding.tsx renders it, and
// src/lib/hosting/seo.ts uses it for the crawler card, the sitemap and llms.txt.

import { PRODUCT_FACTS, type FactStatus, type ProductFact } from '../hosting/productFacts';

export type AppId = 'door' | 'events' | 'promote' | 'money';

/** The statuses a landing page may claim. */
export const CLAIMABLE_STATUSES: ReadonlySet<FactStatus> = new Set<FactStatus>(['live', 'at_launch']);

/** The label an `at_launch` claim carries on a page. */
export const AT_LAUNCH_LABEL = 'coming at launch';

/** The pricing claims every page shows, computed from the fee module (productFacts.ts). */
export const PRICING_FACT_IDS = ['organizer-pricing', 'free-tier'] as const;

/** Sign-up: /onboarding asks a signed-out visitor to sign in, then creates the organization. */
export const SIGNUP_PATH = '/onboarding';

export interface AppLanding {
  id: AppId;
  /** SPA path, under the router's basename (/bridge). */
  path: string;
  /** The app's name as the footer and other pages show it. */
  name: string;
  /** Page title (document title and og:title, before " | Exos"). */
  title: string;
  /** Meta and og:description. */
  description: string;
  /** The app's job, in one line. */
  headline: string;
  intro: string;
  /** Registry ids of the feature bullets, in page order. */
  factIds: string[];
  cta: { to: string; label: string };
}

export const APP_LANDINGS: readonly AppLanding[] = [
  {
    id: 'door',
    path: '/apps/door',
    name: 'Door',
    title: 'Exos Door: a free door app for any event',
    description:
      'Check in any event for free, including tickets sold on Eventbrite, Posh, DICE, Shotgun or RA. ' +
      'Import the attendee CSV, then scan or check guests in by name, offline too.',
    headline: 'The free door app for any event.',
    intro:
      'Sell on Eventbrite, Posh, DICE, Shotgun, RA or from a spreadsheet? Import the attendee list and run the door ' +
      'with Exos. Scan their barcodes or check guests in by name, with or without signal.',
    factIds: ['free-door-app', 'door-name-checkin', 'offline-door', 'walk-up-sales', 'walkup-questions', 'addon-scan-undo', 'rotating-barcodes'],
    cta: { to: '/door', label: 'Open the door app' },
  },
  {
    id: 'events',
    path: '/apps/events',
    name: 'Events',
    title: 'Exos Events: create an event page and sell tickets',
    description:
      'Create an event page and sell tickets with all-in prices, presales, tables and guest lists.',
    headline: 'Create an event page and sell tickets.',
    intro:
      'One page per event, with the ticket types you need, and buyers see the price they pay. ' +
      'Share it anywhere, including Instagram and TikTok.',
    factIds: [
      'paid-checkout', 'all-in-prices', 'instagram-checkout', 'tiers-and-presales', 'tables-guest-lists',
      'seating-timed-entry', 'series', 'waitlist', 'storefront-embed', 'refunds',
    ],
    cta: { to: SIGNUP_PATH, label: 'Create your organization' },
  },
  {
    id: 'promote',
    path: '/apps/promote',
    name: 'Promote',
    title: 'Exos Promote: promoter links, share links and ad catalogs',
    description:
      'Give promoters tracked links, a link-in-bio page and a leaderboard. Let fans share with their own link, ' +
      'and export your events as a Meta, TikTok or Google ad catalog.',
    headline: 'Get people to your event, and see who brought them.',
    intro:
      'Give promoters and fans their own links, and put your events in front of more people.',
    factIds: ['promoters', 'fan-referrals', 'ad-catalogs', 'instagram-checkout', 'storefront-embed', 'calendar-feeds', 'ai-assistants'],
    cta: { to: SIGNUP_PATH, label: 'Create your organization' },
  },
  {
    id: 'money',
    path: '/apps/money',
    name: 'Money',
    title: 'Exos Money: settlements, invoices and your books',
    description:
      'Receipts and invoices, sales tax by ticket type, show settlements with the artist, and a double-entry ' +
      'journal with a CSV export.',
    headline: 'Your sales, settlements and books in one place.',
    intro:
      'See what you sold, what you took at the door and what you owe the artist, per event and across your ' +
      'organization.',
    factIds: ['paid-checkout', 'money-journal', 'invoices-tax', 'booking-settlements', 'walk-up-sales', 'org-audit-log'],
    cta: { to: SIGNUP_PATH, label: 'Create your organization' },
  },
];

const BY_ID = new Map(APP_LANDINGS.map((a) => [a.id, a]));

export function appLanding(id: AppId): AppLanding {
  const app = BY_ID.get(id);
  if (!app) throw new Error(`unknown app ${id}`);
  return app;
}

/** The landing page at an SPA path ("apps/door", "/apps/door/"), or null. */
export function appLandingAt(path: string): AppLanding | null {
  const clean = '/' + path.replace(/[?#].*$/, '').replace(/^\/+|\/+$/g, '');
  return APP_LANDINGS.find((a) => a.path === clean) ?? null;
}

export interface LandingClaim {
  id: string;
  claim: string;
  atLaunch: boolean;
}

/**
 * The registry claims for `ids`, in order, keeping only the ones a page may
 * make (live or at launch). An unknown id or an off / not-shipped fact is
 * dropped, never shown.
 */
export function landingClaims(ids: readonly string[], facts: readonly ProductFact[] = PRODUCT_FACTS): LandingClaim[] {
  const byId = new Map(facts.map((f) => [f.id, f]));
  return ids.flatMap((id) => {
    const f = byId.get(id);
    if (!f || !CLAIMABLE_STATUSES.has(f.status)) return [];
    return [{ id: f.id, claim: f.claim, atLaunch: f.status === 'at_launch' }];
  });
}
