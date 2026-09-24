// /promoter/:eventId/:code — the promoter's own kit for one event.
//
// The organizer sends each promoter this link from the Promote page. It needs
// no account: it only shows public event data and builds links tagged with
// the promoter's code. Sales still only count if the code is the one the
// organizer handed out, since the Sales report groups by that code.

import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Megaphone } from 'lucide-react';
import type { Event } from '../types';
import { getPublicEvent } from '../lib/events';
import { applyMeta } from '../lib/meta';
import { sanitizePromoter } from '../../supabase/functions/_shared/attribution.ts';
import PromoterKitPanel from '../components/PromoterKitPanel';

export default function PromoterKit() {
  const { eventId, code } = useParams();
  const promoter = sanitizePromoter(code);
  const [event, setEvent] = useState<Event | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // A kit page is for one person; keep it out of search results.
    try { applyMeta({ title: 'Promoter kit', description: 'Your links for this event.', noindex: true }); } catch { /* non-fatal */ }
    if (!eventId) { setLoading(false); return; }
    getPublicEvent(eventId)
      .then(setEvent)
      .catch((e) => console.error('Promoter kit load failed:', e))
      .finally(() => setLoading(false));
  }, [eventId]);

  if (loading) {
    return <div className="max-w-3xl mx-auto p-20 text-center type text-white/40 uppercase tracking-widest text-xs">Loading…</div>;
  }
  if (!event || !promoter) {
    return (
      <div className="max-w-3xl mx-auto p-20 text-center">
        <p className="type text-white/40 uppercase tracking-widest text-[10px] mb-4">
          {!promoter ? 'This promoter link is not valid.' : 'This event is not on sale.'}
        </p>
        <Link to="/" className="text-brand-primary font-bold text-sm">Browse events</Link>
      </div>
    );
  }

  return (
    <div className="max-w-3xl mx-auto px-4 py-12">
      <p className="type text-[10px] text-white/40 uppercase tracking-widest mb-2">Promoter kit · {promoter}</p>
      <div className="flex items-center gap-3 mb-2">
        <Megaphone className="w-6 h-6 text-brand-primary" />
        <h1 className="disp text-4xl uppercase tracking-wide text-white">{event.title}</h1>
      </div>
      <p className="text-sm text-white/60 mb-8">
        Every ticket sold through these links is credited to <strong className="text-white">{promoter}</strong>.
      </p>
      <section className="bg-[#111] p-6 border border-white/10">
        <PromoterKitPanel event={event} promoter={promoter} />
      </section>
    </div>
  );
}
