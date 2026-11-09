// @vitest-environment jsdom
// The app landing pages may only say what the facts registry allows
// (src/lib/hosting/productFacts.ts): every bullet is a live or at-launch claim,
// at-launch ones say "coming at launch", and nothing on the page (bullets, the
// page's own words, or its meta tags) describes an off or not-shipped feature.
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { PRODUCT_FACTS } from '../lib/hosting/productFacts';
import { APP_LANDINGS, AT_LAUNCH_LABEL, PRICING_FACT_IDS, type AppId } from '../lib/apps/landing';
import {
  EXOS_FEE_BPS, FEE_FREE_MONTHS, FREE_TIER_MAX_CAPACITY,
} from '../../supabase/functions/_shared/platformFee.ts';
import AppLanding from './AppLanding';

const byId = new Map(PRODUCT_FACTS.map((f) => [f.id, f]));

// Words that would describe each off / not-shipped feature, so a page can't
// claim one in its own copy either. A new off fact must add its words here.
const OFF_WORDS: Record<string, string[]> = {
  'google-events': ['Google Search', 'Google Maps', 'Maps ticket'],
  'wallet-passes': ['Apple Wallet', 'Google Wallet', 'wallet pass'],
  'addon-wallet-passes': ['Apple Wallet', 'Google Wallet', 'wallet pass'],
  sms: ['SMS', 'text message', 'text your', 'Twilio', 'Telnyx'],
  'marketplace-distribution': ['resale', 'marketplace'],
  'eventbrite-mirror': ['mirror', 'sync to Eventbrite', 'publish to Eventbrite'],
  'alt-payments': ['PayPal', 'Venmo', 'Cash App'],
  'card-at-door': ['card reader', 'tap to pay', 'tap-to-pay', 'card at the door', 'card payments at the door'],
  'dice-import': ['DICE events', 'import from DICE', 'opted-in fans'],
  'promoter-payouts': ['commission straight', 'paid their commission', 'pay promoters', 'promoter payouts'],
  'follower-new-event-email': ['email your followers', 'emails your followers', 'followers get an email', 'new event email'],
  'group-pay': ['pay separately', 'paying separately', 'each friend pays', 'friends pay for their own', 'group pay', 'cover the rest'],
};

/** Every text node on its own line, so words from neighbouring elements don't run together. */
function textOf(root: Element): string {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const out: string[] = [];
  for (let n = walker.nextNode(); n; n = walker.nextNode()) out.push(n.textContent ?? '');
  return out.join('\n');
}

const escapeRe = (w: string) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function renderPage(id: AppId) {
  const { container } = render(
    <MemoryRouter initialEntries={[`/apps/${id}`]}>
      <AppLanding app={id} />
    </MemoryRouter>,
  );
  return container;
}

afterEach(cleanup);

describe('app landing pages only claim what the registry allows', () => {
  it('lists words for every off or not-shipped fact', () => {
    const blocked = PRODUCT_FACTS.filter((f) => f.status === 'off' || f.status === 'not_shipped').map((f) => f.id);
    expect(blocked.filter((id) => !OFF_WORDS[id])).toEqual([]);
  });

  for (const app of APP_LANDINGS) {
    describe(app.path, () => {
      it('renders each bullet from a live or at-launch fact, labelled when at launch', () => {
        const page = renderPage(app.id);
        const items = [...page.querySelectorAll('[data-claims] li')];
        expect(items.length).toBe(app.factIds.length + PRICING_FACT_IDS.length);
        for (const li of items) {
          const id = li.getAttribute('data-fact');
          expect(id, `a bullet with no registry fact: ${li.textContent}`).toBeTruthy();
          const f = byId.get(id!);
          expect(f, `${id} is not in the registry`).toBeDefined();
          expect(['live', 'at_launch']).toContain(f!.status);
          const text = li.textContent ?? '';
          expect(text).toContain(f!.claim);
          // Nothing else in the bullet but the claim and, at launch, the label.
          const rest = text.replace(f!.claim, '').replace(AT_LAUNCH_LABEL, '').trim();
          expect(rest).toBe('');
          if (f!.status === 'at_launch') expect(text).toContain(AT_LAUNCH_LABEL);
          else expect(text).not.toContain(AT_LAUNCH_LABEL);
        }
      });

      it('never states an off or not-shipped feature, in the page or its meta tags', () => {
        const page = renderPage(app.id);
        const text = [textOf(page), document.title,
          document.querySelector('meta[name="description"]')?.getAttribute('content') ?? ''].join('\n');
        for (const f of PRODUCT_FACTS) {
          if (f.status === 'live' || f.status === 'at_launch') continue;
          expect(text, f.id).not.toContain(f.claim);
          for (const w of OFF_WORDS[f.id] ?? []) {
            expect(text, `${f.id}: "${w}"`).not.toMatch(new RegExp(`\\b${escapeRe(w)}\\b`, 'i'));
          }
        }
      });

      it('prices from the fee module and sends the call to action to the right place', () => {
        const page = renderPage(app.id);
        const pricing = page.querySelector('[data-claims="pricing"]')?.textContent ?? '';
        expect(pricing).toContain(`${EXOS_FEE_BPS / 100}%`);
        expect(pricing).toContain(`${FEE_FREE_MONTHS} months`);
        expect(pricing).toContain(`${FREE_TIER_MAX_CAPACITY} or less`);
        expect(pricing).toContain('passed through at cost');
        const ctas = [...page.querySelectorAll('a')].filter((a) => a.textContent?.includes(app.cta.label));
        expect(ctas.length).toBeGreaterThan(0);
        for (const a of ctas) expect(a.getAttribute('href')).toBe(app.id === 'door' ? '/door' : '/onboarding');
      });

      it('sets its title, description and canonical link', () => {
        renderPage(app.id);
        expect(document.title).toBe(`${app.title} | Exos`);
        expect(document.querySelector('meta[name="description"]')?.getAttribute('content')).toBe(app.description);
        expect(document.querySelector('meta[property="og:title"]')?.getAttribute('content')).toBe(app.title);
        expect(document.querySelector('link[rel="canonical"]')?.getAttribute('href')).toMatch(new RegExp(`${app.path}$`));
      });
    });
  }
});
