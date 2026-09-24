// Buyer-facing product add-on (merch) selector.
//
// Rendered on EventDetails above the buy button. Lists the event's public
// add-ons with quantity steppers and reports the current selection (+ its
// dollar total) up to the parent, which folds it into checkout / free claim.

import { useEffect, useState } from 'react';
import { Plus, Minus } from 'lucide-react';
import { listPublicAddons, type PublicAddon } from '../lib/addons';
import { formatCurrency } from '../lib/utils';
import { allInPrice } from '../lib/pricing';
import { useT } from '../context/LanguageContext';

export interface AddonSelection {
  items: { addon_id: string; quantity: number }[];
  totalCents: number;
}

interface Props {
  eventId: string;
  currency?: string;
  onChange: (sel: AddonSelection) => void;
  /** Quantities from a checkout link, applied once the add-ons load. */
  initialQty?: Record<string, number>;
}

export default function AddonSelector({ eventId, currency = 'USD', onChange, initialQty }: Props) {
  const t = useT();
  const [addons, setAddons] = useState<PublicAddon[]>([]);
  const [qty, setQty] = useState<Record<string, number>>({});

  useEffect(() => {
    let alive = true;
    listPublicAddons(eventId)
      .then((a) => {
        if (!alive) return;
        setAddons(a);
        if (initialQty) applyInitial(a, initialQty);
      })
      .catch((e) => console.error('listPublicAddons failed:', e));
    return () => { alive = false; };
  }, [eventId]);

  const clampFor = (a: PublicAddon, next: number) => {
    const remaining = a.capacity > 0 ? Math.max(0, a.capacity - a.sold) : Infinity;
    const ceiling = Math.min(a.maxPerOrder ?? Infinity, remaining);
    return Math.max(0, Math.min(next, ceiling));
  };

  const report = (updated: Record<string, number>, list: PublicAddon[]) => {
    const items = Object.entries(updated).map(([addon_id, quantity]) => ({ addon_id, quantity }));
    const totalCents = items.reduce((sum, it) => {
      const found = list.find((x) => x.id === it.addon_id);
      // All-in (incl. exclusive tax), matching what exos-checkout charges.
      return sum + Math.round(allInPrice(found?.price ?? 0, found?.exclusiveTaxPercent) * 100) * it.quantity;
    }, 0);
    onChange({ items, totalCents });
  };

  // Ids that aren't this event's public add-ons are ignored.
  const applyInitial = (list: PublicAddon[], wanted: Record<string, number>) => {
    const updated: Record<string, number> = {};
    for (const a of list) {
      const n = clampFor(a, wanted[a.id] ?? 0);
      if (n > 0) updated[a.id] = n;
    }
    if (Object.keys(updated).length === 0) return;
    setQty(updated);
    report(updated, list);
  };

  const setQuantity = (a: PublicAddon, next: number) => {
    const clamped = clampFor(a, next);
    const updated: Record<string, number> = { ...qty, [a.id]: clamped };
    if (clamped === 0) delete updated[a.id];
    setQty(updated);
    report(updated, addons);
  };

  if (addons.length === 0) return null;

  return (
    <div className="mb-6 space-y-3">
      <p className="text-[10px] font-black uppercase tracking-[0.2em] text-white/40">{t('addon.title')}</p>
      {addons.map((a) => {
        const remaining = a.capacity > 0 ? Math.max(0, a.capacity - a.sold) : Infinity;
        const soldOut = remaining <= 0;
        const current = qty[a.id] ?? 0;
        return (
          <div key={a.id} className="flex items-center justify-between border-2 border-white/10 p-3">
            <div className="min-w-0 pr-3">
              <p className="font-black uppercase italic tracking-tighter text-sm truncate">{a.name}</p>
              {a.description && <p className="text-white/40 text-xs font-bold truncate">{a.description}</p>}
              <p className="text-brand-primary text-xs font-black mt-0.5">
                {a.price > 0 ? formatCurrency(allInPrice(a.price, a.exclusiveTaxPercent), currency) : t('event.free')}
                {soldOut && <span className="text-brand-accent ml-2">{t('event.soldOut')}</span>}
              </p>
            </div>
            <div className="flex items-center space-x-3 shrink-0">
              <button
                type="button"
                disabled={current <= 0}
                onClick={() => setQuantity(a, current - 1)}
                className="w-8 h-8 flex items-center justify-center border-2 border-white/15 hover:border-brand-primary disabled:opacity-30"
                aria-label={`Remove one ${a.name}`}
              >
                <Minus className="w-4 h-4" />
              </button>
              <span className="w-6 text-center font-black tabular-nums">{current}</span>
              <button
                type="button"
                disabled={soldOut || current >= (a.maxPerOrder ?? Infinity) || current >= remaining}
                onClick={() => setQuantity(a, current + 1)}
                className="w-8 h-8 flex items-center justify-center border-2 border-white/15 hover:border-brand-primary disabled:opacity-30"
                aria-label={`Add one ${a.name}`}
              >
                <Plus className="w-4 h-4" />
              </button>
            </div>
          </div>
        );
      })}
    </div>
  );
}
