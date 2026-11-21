// /nyc/:neighborhood — "This week in Bushwick" (Phase 1 item 7c, mig
// 20261111110000, docs/google-events.md "Neighborhood pages"). Published,
// listed (not noindex) events in the next 7 days (?days=14 for two weeks)
// whose geocoded venue falls in the neighborhood, by day. Title, description,
// Open Graph and an ItemList JSON-LD through applyMeta (lib/meta.ts). Events
// without a map pin can't be placed; platform admins see how many.

import { useEffect, useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import {
  clampDays, getNeighborhoodPage, groupByDay, neighborhoodJsonLd, normalizeSlug, pageDescription, pageTitle,
  type NeighborhoodPage as Page,
} from '../lib/neighborhoods';
import { applyMeta } from '../lib/meta';
import { formatInTz } from '../lib/datetime';
import { formatCurrency, publicUrl } from '../lib/utils';

export default function NeighborhoodPage() {
  const { neighborhood } = useParams<{ neighborhood: string }>();
  const [params] = useSearchParams();
  const days = clampDays(params.get('days') ?? 7) > 7 ? 14 : 7;
  const slug = normalizeSlug(neighborhood);
  // undefined: loading; null: no such neighborhood; 'error': the call failed.
  const [page, setPage] = useState<Page | null | undefined | 'error'>(undefined);

  useEffect(() => {
    if (!slug) { setPage(null); return undefined; }
    let live = true;
    setPage(undefined);
    getNeighborhoodPage(slug, days)
      .then((p) => { if (live) setPage(p); })
      .catch((err) => { console.error('neighborhood page failed:', err); if (live) setPage('error'); });
    return () => { live = false; };
  }, [slug, days]);

  useEffect(() => {
    if (!page || page === 'error') return;
    const name = page.neighborhood.name;
    const url = publicUrl(`/nyc/${page.neighborhood.slug}${days > 7 ? '?days=14' : ''}`);
    try {
      applyMeta({
        title: pageTitle(name, days),
        description: pageDescription(name, page.events.length, days),
        canonicalUrl: url,
        jsonLd: neighborhoodJsonLd(page, url, (id) => publicUrl(`/event/${id}`)),
      });
    } catch { /* non-fatal */ }
  }, [page, days]);

  if (page === undefined) {
    return <div className="min-h-screen bg-black text-white/60 p-24 text-center" role="status">Loading…</div>;
  }
  if (page === null || page === 'error') {
    return (
      <div className="min-h-screen bg-black text-white px-4 py-24 text-center">
        <h1 className="disp text-3xl mb-4">{page === 'error' ? "This page didn't load." : "We don't have that neighborhood."}</h1>
        <Link to="/nyc" className="type text-xs uppercase tracking-widest text-brand-primary hover:underline">All New York neighborhoods</Link>
      </div>
    );
  }

  const { neighborhood: nb } = page;
  const byDay = groupByDay(page.events, nb.timezone);
  return (
    <div className="min-h-screen bg-black text-white">
      <div className="max-w-5xl mx-auto px-4 py-12">
        <nav aria-label="Breadcrumb" className="type text-[11px] uppercase tracking-widest text-white/60 mb-3">
          <Link to="/nyc" className="hover:text-white underline-offset-2 hover:underline">New York</Link>
          {nb.borough ? <span aria-hidden="true"> / </span> : null}
          {nb.borough ? <span>{nb.borough}</span> : null}
        </nav>
        <h1 className="disp text-4xl md:text-5xl mb-3">{pageTitle(nb.name, page.days)}</h1>
        <p className="text-white/70 mb-2">
          {page.events.length === 0
            ? `Nothing listed in ${nb.name} ${page.days > 7 ? 'in the next two weeks' : 'this week'} yet.`
            : `${page.events.length} live event${page.events.length === 1 ? '' : 's'}. Prices are all-in: what you see is what you pay.`}
        </p>
        <p className="mb-8">
          {page.days > 7
            ? <Link to={`/nyc/${nb.slug}`} className="type text-[11px] uppercase tracking-widest text-brand-primary hover:underline">This week only</Link>
            : <Link to={`/nyc/${nb.slug}?days=14`} className="type text-[11px] uppercase tracking-widest text-brand-primary hover:underline">Next two weeks</Link>}
        </p>
        {page.missingCoordinates != null && (
          <p className="mb-8 border border-amber-400/40 bg-amber-400/10 text-amber-200 text-sm px-4 py-3" data-testid="missing-coordinates">
            Admin: {page.missingCoordinates} listed event{page.missingCoordinates === 1 ? '' : 's'} in this time zone
            {page.missingCoordinates === 1 ? ' has' : ' have'} no map pin, so {page.missingCoordinates === 1 ? "it isn't" : "they aren't"} on any neighborhood page.
          </p>
        )}
        {byDay.map((d) => (
          <section key={d.day} className="mb-10" aria-labelledby={`day-${d.day.replace(/\W+/g, '-')}`}>
            <h2 id={`day-${d.day.replace(/\W+/g, '-')}`} className="type text-xs uppercase tracking-widest text-white/60 border-b border-white/10 pb-2 mb-4">{d.day}</h2>
            <ul className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
              {d.events.map((e) => (
                <li key={e.id}>
                  <Link to={`/event/${e.id}`} className="border border-white/10 hover:border-white/40 block h-full">
                    {e.imageUrl && <img src={e.imageUrl} alt="" className="w-full aspect-video object-cover" loading="lazy" />}
                    <div className="p-4">
                      <p className="type text-[11px] uppercase tracking-widest text-white/60">
                        {formatInTz(new Date(e.startsAt), e.timezone ?? nb.timezone, { hour: 'numeric', minute: '2-digit' })}
                      </p>
                      <p className="disp text-xl mt-1">{e.name}</p>
                      <p className="text-xs text-white/60 mt-1">{[e.venueName, e.org.name].filter(Boolean).join(' · ')}</p>
                      <p className="text-xs mt-2">
                        {e.soldOut ? 'Sold out' : e.fromPrice != null ? `From ${formatCurrency(e.fromPrice, e.currency)}` : ''}
                      </p>
                    </div>
                  </Link>
                </li>
              ))}
            </ul>
          </section>
        ))}
        <p className="mt-12 text-sm text-white/60">
          Organizers: list your event on Exos with its venue address and it shows up here.{' '}
          <Link to="/nyc" className="text-brand-primary underline underline-offset-2">More neighborhoods</Link>
        </p>
      </div>
    </div>
  );
}
