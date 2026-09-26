// /checkout?products=<tierId>:<qty>,<addonId>:<qty>&coupon=…&promoter=…
//
// Resolves a checkout link (lib/checkoutLink.ts) to its event, stores the
// cart as a prefill for the visit, and hands off to the event page, which
// re-validates everything and runs the normal checkout. Attribution params
// ride along on the event URL so lib/attribution.ts captures them there.

import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { parseCheckoutLink, resolveCheckout, savePrefill, type ResolvedRow } from '../lib/checkoutLink';
import { applyMeta } from '../lib/meta';

export default function CheckoutLink() {
  const navigate = useNavigate();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    try { applyMeta({ title: 'Checkout', description: 'Opening your tickets…' }); } catch { /* non-fatal */ }
    let alive = true;
    (async () => {
      const parsed = parseCheckoutLink(window.location.search);
      const ids = parsed.items.map((i) => i.id);
      let tiers: ResolvedRow[] = [];
      let addons: ResolvedRow[] = [];
      if (ids.length > 0) {
        const [t, a] = await Promise.all([
          supabase.from('exos_public_tiers').select('id, event_id').in('id', ids),
          supabase.from('exos_public_addons').select('id, event_id').in('id', ids),
        ]);
        tiers = (t.data as ResolvedRow[] | null) ?? [];
        addons = (a.data as ResolvedRow[] | null) ?? [];
      }
      if (!alive) return;
      const r = resolveCheckout(parsed, tiers, addons);
      if ('reason' in r) {
        setError(r.reason);
        return;
      }
      savePrefill(r.eventId, r.prefill);
      const attr = new URLSearchParams();
      for (const [k, v] of Object.entries(parsed.attribution)) if (v) attr.set(k, v);
      const q = attr.toString();
      navigate(`/event/${r.eventId}${q ? `?${q}` : ''}`, { replace: true, state: { checkoutNotes: r.notes } });
    })().catch((e) => {
      console.error('Checkout link failed:', e);
      if (alive) setError('Something went wrong opening this link. Try again in a moment.');
    });
    return () => { alive = false; };
  }, [navigate]);

  return (
    <div className="wall min-h-[70vh] flex flex-col items-center justify-center px-6 text-center">
      {error ? (
        <>
          <p className="disp text-3xl md:text-4xl tracking-tight mb-4">{error}</p>
          <Link to="/" className="type text-[11px] uppercase tracking-widest text-brand-primary hover:underline">Browse events</Link>
        </>
      ) : (
        <p className="type text-[11px] uppercase tracking-widest text-white/50">Opening your tickets…</p>
      )}
    </div>
  );
}
