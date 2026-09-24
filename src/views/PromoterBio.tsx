// /l/:orgSlug/:code — a promoter's link-in-bio page.
//
// One public link a promoter keeps in their Instagram or TikTok bio instead of
// swapping it per event: the organizer's upcoming events, every ticket link
// carrying the promoter's code (utm_medium=bio), so each sale is credited to
// them. Shows only the promoter's display name (exos_public_promoter), and
// only while the organizer has them active.

import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import type { Event } from '../types';
import { getPublicPromoter, linkInBioPath, type PublicPromoterCard } from '../lib/promoters';
import { listPublicEventsForOrg } from '../lib/events';
import { shareAttribution } from '../lib/shareLinks';
import { fromPrice } from '../lib/pricing';
import { formatCurrency, publicUrl } from '../lib/utils';
import { formatInTz } from '../lib/datetime';
import { applyMeta } from '../lib/meta';
import { initOrgPixels } from '../lib/pixels';
import { getPublicOrg } from '../lib/orgs';
import InAppBrowserBanner from '../components/InAppBrowserBanner';

export default function PromoterBio() {
  const { orgSlug, code } = useParams();
  const [card, setCard] = useState<PublicPromoterCard | null>(null);
  const [events, setEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!orgSlug || !code) { setLoading(false); return undefined; }
    let alive = true;
    (async () => {
      const c = await getPublicPromoter(orgSlug, code);
      if (!alive || !c) return;
      setCard(c);
      try {
        applyMeta({
          title: `${c.promoter.name} × ${c.org.name}`,
          description: `Tickets to ${c.org.name}'s upcoming events.`,
          canonicalUrl: publicUrl(linkInBioPath(c.org.slug, c.promoter.code)),
        });
      } catch { /* non-fatal */ }
      const now = Date.now();
      const evs = (await listPublicEventsForOrg(c.org.id))
        .filter((e) => !e.date || e.date.toDate().getTime() > now - 6 * 3600 * 1000);
      if (!alive) return;
      setEvents(evs);
      // The org's own pixels, consent-gated (lib/pixels.ts).
      getPublicOrg(c.org.id).then((o) => initOrgPixels(c.org.id, o?.marketing?.pixels)).catch(() => {});
    })()
      .catch((e) => console.error('Link-in-bio load failed:', e))
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [orgSlug, code]);

  if (loading) return <div className="max-w-md mx-auto p-20 text-center type text-white/40 uppercase tracking-widest text-xs">Loading…</div>;
  if (!card) {
    return (
      <div className="max-w-md mx-auto p-20 text-center">
        <p className="type text-white/40 uppercase tracking-widest text-[10px] mb-4">This link isn't active.</p>
        <Link to="/" className="text-brand-primary font-bold text-sm">Browse events</Link>
      </div>
    );
  }

  return (
    <div className="min-h-screen">
      <InAppBrowserBanner />
      <div className="max-w-md mx-auto px-4 py-10">
        <p className="type text-[10px] uppercase tracking-widest text-white/40 text-center mb-1">{card.org.name}</p>
        <h1 className="disp text-4xl uppercase tracking-wide text-white text-center mb-8">{card.promoter.name}</h1>
        {events.length === 0 ? (
          <p className="text-center text-sm text-white/50">No upcoming events right now. Check back soon.</p>
        ) : (
          <ul className="space-y-3">
            {events.map((e) => {
              const tags = shareAttribution({ role: 'promoter', channel: 'instagram_bio', promoter: card.promoter.code });
              const path = `/event/${e.id}?${new URLSearchParams(tags as Record<string, string>).toString()}`;
              const when = e.date
                ? formatInTz(e.date.toDate(), e.timezone, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
                : null;
              return (
                <li key={e.id}>
                  <Link to={path} className="flex gap-3 items-center bg-[#111] border border-white/10 hover:border-brand-primary p-3 transition-colors">
                    {e.image && <img src={e.image} alt="" className="w-16 h-16 object-cover shrink-0" loading="lazy" />}
                    <div className="min-w-0 flex-1">
                      <p className="font-black text-white truncate">{e.title}</p>
                      <p className="type text-[10px] uppercase tracking-widest text-white/50 truncate">{[when, e.location].filter(Boolean).join(' · ')}</p>
                    </div>
                    <span className="type text-[11px] font-black uppercase text-brand-primary shrink-0">
                      {formatCurrency(fromPrice(e.ticketTiers, e.price), e.currency)}+
                    </span>
                  </Link>
                </li>
              );
            })}
          </ul>
        )}
        <p className="type text-[9px] uppercase tracking-widest text-white/30 text-center mt-10">Tickets by Exos</p>
      </div>
    </div>
  );
}
