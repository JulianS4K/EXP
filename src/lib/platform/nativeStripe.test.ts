// @vitest-environment jsdom
// PCI (docs/pci.md): the native app never loads Stripe.js. src/lib/stripe.ts
// imports @stripe/stripe-js/pure, which injects nothing on import, and the
// native build refuses loadStripe; the venue embed (Stripe's card iframe) is
// left out of the native router (App.tsx) and bundle.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';

const stripeScripts = () => [...document.querySelectorAll('script')].filter((s) => /js\.stripe\.com/.test(s.src)).length;

afterEach(() => {
  vi.unstubAllEnvs();
  document.head.innerHTML = '';
});

describe('Stripe.js in the native build', () => {
  it('importing the module injects nothing, on the web either', async () => {
    vi.resetModules();
    await import('../stripe');
    expect(stripeScripts()).toBe(0);
  });

  it('MODE=native: getStripe refuses and no script is ever injected', async () => {
    vi.resetModules();
    vi.stubEnv('MODE', 'native');
    vi.stubEnv('VITE_STRIPE_PUBLISHABLE_KEY', 'pk_test_x');
    const { getStripe } = await import('../stripe');
    await expect(getStripe()).rejects.toThrow(/hosted Checkout/);
    await new Promise((r) => setTimeout(r, 20));
    expect(stripeScripts()).toBe(0);
  });

  it('uses the pure entry, and the native router has no /embed routes', () => {
    const src = readFileSync(resolve(__dirname, '../stripe.ts'), 'utf8');
    expect(src).toMatch(/from '@stripe\/stripe-js\/pure'/);
    // Types only from the main entry (erased at build): nothing that runs it.
    expect(src).not.toMatch(/^import (?!type )[^;]*from '@stripe\/stripe-js';/m);
    const app = readFileSync(resolve(__dirname, '../../App.tsx'), 'utf8');
    for (const line of app.split('\n').filter((l) => /path="\/embed\//.test(l))) expect(line).toMatch(/!NATIVE_BUILD &&/);
    for (const v of ['EmbedEvent', 'EmbedOrg', 'EmbedSignup', 'EmbedReturn']) {
      expect(app).toMatch(new RegExp(`const ${v} = NATIVE_BUILD \\? NotInApp : lazy`));
    }
  });
});
