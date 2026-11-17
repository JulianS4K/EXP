// The Spanish dictionary is complete for the buyer, door and POS surfaces
// (docs/i18n-review.md): every English key has a Spanish string, the same
// {placeholders}, and nothing blank. Also the event-text fallback and the
// editor payload the database validates (mig 20261114130000).
import { describe, expect, it } from 'vitest';
import {
  DICTS, EVENT_I18N_LIMITS, NAMESPACES, REVIEW_KEYS, en, es, eventI18nPayload, eventText, interpolate, placeholders, translate,
  type DictKey,
} from './dict';

const keys = Object.keys(en) as DictKey[];
const inNamespace = (ns: readonly string[]) => keys.filter((k) => ns.some((p) => k.startsWith(p)));

describe('dictionary completeness', () => {
  it('puts every key in one of the buyer, door or POS namespaces', () => {
    const all = [...NAMESPACES.buyer, ...NAMESPACES.door, ...NAMESPACES.pos];
    expect(keys.filter((k) => !all.some((p) => k.startsWith(p)))).toEqual([]);
  });

  for (const [name, prefixes] of Object.entries(NAMESPACES)) {
    describe(name, () => {
      const ns = inNamespace(prefixes);
      it('has keys', () => expect(ns.length).toBeGreaterThan(10));
      it('has every English key in Spanish', () => {
        expect(ns.filter((k) => typeof es[k] !== 'string')).toEqual([]);
      });
      it('has no blank strings in either language', () => {
        expect(ns.filter((k) => !en[k].trim() || !es[k].trim())).toEqual([]);
      });
      it('keeps the same placeholders in both languages', () => {
        const off = ns.filter((k) => placeholders(en[k]).join() !== placeholders(es[k]).join())
          .map((k) => `${k}: ${placeholders(en[k])} vs ${placeholders(es[k])}`);
        expect(off).toEqual([]);
      });
    });
  }

  it('has no Spanish key that English lacks', () => {
    expect(Object.keys(es).filter((k) => !(k in en))).toEqual([]);
  });

  it('actually translates the door and POS (not English copied over)', () => {
    const same = [...inNamespace(NAMESPACES.door), ...inNamespace(NAMESPACES.pos)]
      .filter((k) => en[k] === es[k] && en[k].length > 12);
    expect(same).toEqual([]);
  });

  it('lists only real keys for human review, money and legal ones included', () => {
    expect(REVIEW_KEYS.filter((k) => !(k in en))).toEqual([]);
    for (const k of ['page.refund.none', 'checkout.allIn', 'checkout.feesIncluded', 'checkout.giftApplied', 'pos.inclTax'] as DictKey[]) {
      expect(REVIEW_KEYS).toContain(k);
    }
  });
});

describe('translate / interpolate', () => {
  it('fills placeholders and leaves unknown ones', () => {
    expect(interpolate('{n} left of {m}', { n: 3 })).toBe('3 left of {m}');
    expect(translate('es', 'event.left', { n: 2 })).toBe('Quedan 2');
    expect(translate('en', 'door.refuse.doors-not-open-at', { time: '9:00 PM' })).toContain('9:00 PM');
  });
  it('has a table per language', () => {
    expect(Object.keys(DICTS)).toEqual(['en', 'es']);
  });
});

describe('eventText', () => {
  const ev = { title: 'Salsa Night', description: 'Dance', i18n: { es: { title: 'Noche de Salsa', description: 'Baile' } } };
  it('shows the Spanish fields to a Spanish visitor', () => {
    expect(eventText(ev, 'es')).toEqual({ title: 'Noche de Salsa', description: 'Baile', translated: true });
  });
  it('shows the default to an English visitor', () => {
    expect(eventText(ev, 'en')).toEqual({ title: 'Salsa Night', description: null, translated: false });
  });
  it('falls back field by field', () => {
    expect(eventText({ title: 'A', i18n: { es: { description: 'solo' } } }, 'es')).toEqual({ title: 'A', description: 'solo', translated: true });
    expect(eventText({ title: 'A', i18n: { es: { title: '  ' } } }, 'es').title).toBe('A');
    expect(eventText({ title: 'A', i18n: null }, 'es').title).toBe('A');
    expect(eventText({ title: 'A' }, 'es').description).toBeNull();
  });
});

describe('eventI18nPayload', () => {
  it('drops blank fields and an empty language', () => {
    expect(eventI18nPayload({ title: ' ', description: '' })).toEqual({});
    expect(eventI18nPayload({ title: ' Noche ' })).toEqual({ es: { title: 'Noche' } });
  });
  it('keeps to the database caps and strips control characters from the title', () => {
    const p = eventI18nPayload({ title: `a\nb${'x'.repeat(300)}`, description: 'y'.repeat(EVENT_I18N_LIMITS.description + 5) });
    expect(p.es?.title?.length).toBe(EVENT_I18N_LIMITS.title);
    expect(p.es?.title).not.toMatch(/\n/);
    expect(p.es?.description?.length).toBe(EVENT_I18N_LIMITS.description);
  });
});
