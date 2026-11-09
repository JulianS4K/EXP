// /nyc — New York neighborhoods with how many live events each has this week
// (mig 20261111110000). Each links to its "This week in …" page.

import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { listNeighborhoods, type NeighborhoodSummary } from '../lib/neighborhoods';
import { applyMeta } from '../lib/meta';
import { publicUrl } from '../lib/utils';

export default function NeighborhoodsIndex() {
  const [rows, setRows] = useState<NeighborhoodSummary[] | null | 'error'>(null);

  useEffect(() => {
    let live = true;
    listNeighborhoods('nyc', 7)
      .then((r) => { if (live) setRows(r); })
      .catch((err) => { console.error('neighborhoods failed:', err); if (live) setRows('error'); });
    return () => { live = false; };
  }, []);

  useEffect(() => {
    const url = publicUrl('/nyc');
    try {
      applyMeta({
        title: 'New York events by neighborhood',
        description: 'Live events this week in Bushwick, Williamsburg, the Lower East Side, Ridgewood and more. All-in prices on Exos.',
        canonicalUrl: url,
        jsonLd: {
          '@context': 'https://schema.org', '@type': 'CollectionPage', name: 'New York events by neighborhood', url,
          ...(Array.isArray(rows) ? {
            hasPart: rows.map((r) => ({ '@type': 'WebPage', name: `This week in ${r.name}`, url: publicUrl(`/nyc/${r.slug}`) })),
          } : {}),
        },
      });
    } catch { /* non-fatal */ }
  }, [rows]);

  const byBorough = useMemo(() => {
    const out = new Map<string, NeighborhoodSummary[]>();
    for (const r of Array.isArray(rows) ? rows : []) {
      const k = r.borough ?? 'New York';
      out.set(k, [...(out.get(k) ?? []), r]);
    }
    return [...out.entries()];
  }, [rows]);

  return (
    <div className="min-h-screen bg-black text-white">
      <div className="max-w-5xl mx-auto px-4 py-12">
        <h1 className="disp text-4xl md:text-5xl mb-3">New York, by neighborhood</h1>
        <p className="text-white/70 mb-10">What's on this week, close to you. Prices are all-in.</p>
        {rows === null && <p className="text-white/60" role="status">Loading…</p>}
        {rows === 'error' && <p className="text-white/70">The neighborhoods didn't load. Try again in a minute.</p>}
        {byBorough.map(([borough, list]) => (
          <section key={borough} className="mb-10" aria-labelledby={`b-${borough.replace(/\W+/g, '-')}`}>
            <h2 id={`b-${borough.replace(/\W+/g, '-')}`} className="type text-xs uppercase tracking-widest text-white/60 border-b border-white/10 pb-2 mb-4">{borough}</h2>
            <ul className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
              {list.map((r) => (
                <li key={r.slug}>
                  <Link to={`/nyc/${r.slug}`} className="flex items-baseline justify-between border border-white/10 hover:border-white/40 px-4 py-3">
                    <span className="disp text-lg">{r.name}</span>
                    <span className="text-xs text-white/60">{r.events === 0 ? 'nothing yet' : `${r.events} this week`}</span>
                  </Link>
                </li>
              ))}
            </ul>
          </section>
        ))}
      </div>
    </div>
  );
}
