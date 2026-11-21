import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { placementNameError, placementSheet, placementSlug, placementUrl, type PrintPlacement } from './printPlacements';

const MIG = readFileSync(new URL('../../supabase/migrations/20261121153700_exos_promotion.sql', import.meta.url), 'utf8');
const p = (over: Partial<PrintPlacement>): PrintPlacement => ({
  id: 'p1', event_id: 'e1', name: 'Poster', slug: 'poster', created_at: '2026-11-21T10:00:00Z', ...over,
});

describe('print placements', () => {
  it('slugs a name the way the RPC does', () => {
    expect(placementSlug('Poster – Bedford Ave')).toBe('poster-bedford-ave');
    expect(placementSlug('  Flyer @ Bar X!! ')).toBe('flyer-bar-x');
    expect(placementSlug('Café Ñ')).toBe('caf');
    expect(placementSlug('---')).toBe('');
    expect(placementSlug('a'.repeat(70))).toHaveLength(60);
    expect(placementSlug(`${'a'.repeat(59)} b`)).toBe('a'.repeat(59));
    // The SQL twin uses the same rule.
    expect(MIG).toContain("regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '-', 'g')");
  });

  it('checks a name before it is sent', () => {
    expect(placementNameError('')).toMatch(/Name the spot/);
    expect(placementNameError('!!!')).toMatch(/letter or a number/);
    expect(placementNameError('x'.repeat(81))).toMatch(/80/);
    expect(placementNameError('Flyer - Bar X')).toBeNull();
  });

  it('tags the short link with qr / print / the placement', () => {
    const u = new URL(placementUrl('https://exos.example/bridge/e/late-jazz', 'poster-bedford-ave'));
    expect(u.pathname).toBe('/bridge/e/late-jazz');
    expect(Object.fromEntries(u.searchParams)).toEqual({ utm_source: 'qr', utm_medium: 'print', utm_content: 'poster-bedford-ave' });
  });

  it('lays out the sheet in the order placements were added, one URL each', () => {
    const sheet = placementSheet('https://exos.example/e/x', [
      p({ id: 'b', name: 'Flyer - Bar X', slug: 'flyer-bar-x', created_at: '2026-11-21T11:00:00Z' }),
      p({ id: 'a', name: 'Poster - Bedford Ave', slug: 'poster-bedford-ave' }),
    ]);
    expect(sheet.map((s) => [s.name, s.url])).toEqual([
      ['Poster - Bedford Ave', 'https://exos.example/e/x?utm_source=qr&utm_medium=print&utm_content=poster-bedford-ave'],
      ['Flyer - Bar X', 'https://exos.example/e/x?utm_source=qr&utm_medium=print&utm_content=flyer-bar-x'],
    ]);
  });
});
