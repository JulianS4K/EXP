import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';

// addonUndo imports the Supabase client; the window constant is all we need.
vi.mock('../supabase', () => ({ supabase: {} }));
import { EXOS_FEE_BPS, FEE_FREE_MONTHS } from '../../../supabase/functions/_shared/platformFee.ts';
import { PRODUCT_FACTS, assistantFacts, factsTableRows, pricingExample } from './productFacts';
import { buildLlmsTxt, type PublicReader } from './seo';
import { ADDON_UNDO_WINDOW_MINUTES } from '../addonUndo';

const root = resolve(__dirname, '../../..');

describe('the AI facts registry', () => {
  it('has unique ids', () => {
    const ids = PRODUCT_FACTS.map((f) => f.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it('names only files that exist', () => {
    const missing = PRODUCT_FACTS.flatMap((f) => f.code.filter((p) => !existsSync(resolve(root, p))).map((p) => `${f.id}: ${p}`));
    expect(missing).toEqual([]);
  });

  it('backs every fact an assistant may repeat with code', () => {
    expect(assistantFacts().filter((f) => f.code.length === 0).map((f) => f.id)).toEqual([]);
  });

  it('explains every fact that is off or not shipped', () => {
    expect(PRODUCT_FACTS.filter((f) => (f.status === 'off' || f.status === 'not_shipped') && !f.note).map((f) => f.id)).toEqual([]);
  });

  it('computes the pricing claim from the fee module', () => {
    const ex = pricingExample();
    expect(ex.payoutCents).toBe(ex.priceCents - ex.exosCents - ex.cardCents);
    expect(ex.payoutCents).toBe(3734);
    const claim = PRODUCT_FACTS.find((f) => f.id === 'organizer-pricing')!.claim;
    expect(claim).toContain(`${EXOS_FEE_BPS / 100}%`);
    expect(claim).toContain('$37.34');
    expect(claim).toContain(`${FEE_FREE_MONTHS} months`);
  });

  it('states the add-on undo window the door enforces', () => {
    const claim = PRODUCT_FACTS.find((f) => f.id === 'addon-scan-undo')!.claim;
    expect(claim).toContain(`within ${ADDON_UNDO_WINDOW_MINUTES} minutes`);
  });

  it('matches docs/ai-facts.md', () => {
    const doc = readFileSync(resolve(root, 'docs/ai-facts.md'), 'utf8');
    expect(doc).toContain(factsTableRows());
  });
});

describe('llms.txt and the facts', () => {
  const none: PublicReader = async () => [];

  it('tells assistants every live and at-launch fact, and nothing else', async () => {
    const txt = await buildLlmsTxt(none, 'https://exos.example');
    for (const f of PRODUCT_FACTS) {
      if (f.status === 'live' || f.status === 'at_launch') expect(txt).toContain(f.claim);
      else expect(txt).not.toContain(f.claim);
    }
    expect(txt).toContain('## For ticket buyers');
    expect(txt).toContain('## For organizers');
  });
});
