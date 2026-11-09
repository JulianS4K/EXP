// Public collection page (/c/:orgSlug/:slug): a published collection's
// upcoming published events, soonest first, with schema.org EventSeries
// JSON-LD (each event a subEvent) for search engines. Reads only
// exos_public_collection (mig 20261030150000), which returns nothing for an
// unpublished collection or a draft event.

import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { getPublicCollection, type PublicCollection } from '../lib/seriesTimedApi';
import { formatInTz } from '../lib/datetime';
import { formatCurrency } from '../lib/utils';
import { collectionJsonLd } from '../lib/collectionLd';

export default function CollectionPage() {
  const { orgSlug, slug } = useParams<{ orgSlug: string; slug: string }>();
  const [c, setC] = useState<PublicCollection | null | undefined>(undefined);

  useEffect(() => {
    if (!orgSlug || !slug) return undefined;
    let live = true;
    getPublicCollection(orgSlug, slug).then((r) => { if (live) setC(r); })
      .catch((err) => { console.error('collection load failed:', err); if (live) setC(null); });
    return () => { live = false; };
  }, [orgSlug, slug]);

  useEffect(() => {
    if (!c) return undefined;
    document.title = `${c.name} · ${c.org.name}`;
    const el = document.createElement('script');
    el.type = 'application/ld+json';
    el.text = JSON.stringify(collectionJsonLd(c, window.location.origin));
    document.head.appendChild(el);
    return () => { el.remove(); };
  }, [c]);

  if (c === undefined) return <div className="min-h-screen bg-black text-white/40 p-24 text-center">Loading…</div>;
  if (c === null) return <div className="min-h-screen bg-black text-white/60 p-24 text-center">This page isn't available.</div>;

  return (
    <div className="min-h-screen bg-black text-white">
      <div className="max-w-5xl mx-auto px-4 py-12">
        <p className="type text-[11px] uppercase tracking-widest text-white/50 mb-2">{c.org.name}</p>
        <h1 className="disp text-4xl mb-3">{c.name}</h1>
        {c.description && <p className="text-white/70 mb-8 max-w-2xl whitespace-pre-line">{c.description}</p>}
        {c.events.length === 0 && <p className="text-white/50">No upcoming dates right now.</p>}
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          {c.events.map((e) => (
            <Link key={e.id} to={`/event/${e.id}`} className="border border-white/10 hover:border-white/40 block">
              {e.image_url && <img src={e.image_url} alt="" className="w-full aspect-video object-cover" loading="lazy" />}
              <div className="p-4">
                <p className="type text-[11px] uppercase tracking-widest text-white/60">
                  {formatInTz(new Date(e.starts_at), e.timezone ?? undefined, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })}
                </p>
                <p className="disp text-xl mt-1">{e.name}</p>
                <p className="text-xs text-white/50 mt-1">{e.venue_name}{e.venue_location ? ` · ${e.venue_location}` : ''}</p>
                <p className="text-xs mt-2">
                  {e.sold_out ? 'Sold out' : e.from_price != null ? `From ${formatCurrency(Number(e.from_price), (e.currency || 'USD').toUpperCase())}` : ''}
                </p>
              </div>
            </Link>
          ))}
        </div>
      </div>
    </div>
  );
}
