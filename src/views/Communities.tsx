// /communities — the directory of public communities, by city
// (exos_public_communities, mig 20261031200000). ?city=<key>&q=<search>.

import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { applyMeta } from '../lib/meta';
import { formatInTz } from '../lib/datetime';
import { memberCountLabel, placeLine } from '../lib/communities';
import { listCommunities, type DirectoryResult } from '../lib/communitiesApi';

export default function Communities() {
  const [params, setParams] = useSearchParams();
  const city = params.get('city');
  const q = params.get('q') ?? '';
  const [query, setQuery] = useState(q);
  const [data, setData] = useState<DirectoryResult | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    try { applyMeta({ title: 'Communities', description: 'Run clubs, supper clubs, scenes and crews near you, with their events.' }); } catch { /* non-fatal */ }
  }, []);
  useEffect(() => {
    let cancelled = false;
    setFailed(false);
    listCommunities(city, q || null)
      .then((d) => { if (!cancelled) setData(d); })
      .catch(() => { if (!cancelled) setFailed(true); });
    return () => { cancelled = true; };
  }, [city, q]);

  const set = (k: string, v: string | null) => {
    const next = new URLSearchParams(params);
    if (v) next.set(k, v); else next.delete(k);
    setParams(next, { replace: true });
  };

  return (
    <div className="wall min-h-screen text-white">
      <div className="max-w-5xl mx-auto px-6 py-10">
        <h1 className="disp text-4xl md:text-5xl tracking-tight mb-2">Communities</h1>
        <p className="text-white/60 mb-6">Groups that meet up: join one to hear about every event it runs.</p>
        <form className="flex gap-2 mb-4" onSubmit={(e) => { e.preventDefault(); set('q', query.trim() || null); }}>
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search by name"
            className="flex-1 bg-white/5 border border-white/15 rounded-lg px-3 py-2 text-sm placeholder-white/40" />
          <button type="submit" className="px-4 py-2 rounded-full bg-white text-black text-xs font-black uppercase tracking-widest">Search</button>
        </form>
        {data && data.cities.length > 0 && (
          <div className="flex flex-wrap gap-2 mb-8">
            <button type="button" onClick={() => set('city', null)}
              className={`px-3 py-1 rounded-full text-xs border ${!city ? 'bg-white text-black border-white' : 'border-white/20 text-white/70'}`}>All cities</button>
            {data.cities.map((c) => (
              <button key={c.key} type="button" onClick={() => set('city', c.key)}
                className={`px-3 py-1 rounded-full text-xs border ${city === c.key ? 'bg-white text-black border-white' : 'border-white/20 text-white/70'}`}>
                {c.city} <span className="opacity-60">{c.count}</span>
              </button>
            ))}
          </div>
        )}
        {failed && <p className="text-sm text-white/60">Couldn't load communities. Try again.</p>}
        {data && data.items.length === 0 && <p className="text-sm text-white/60">No communities here yet.</p>}
        <ul className="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
          {data?.items.map((c) => (
            <li key={c.slug}>
              <Link to={`/c/${c.slug}`} className="block rounded-xl border border-white/10 hover:border-white/40 overflow-hidden h-full">
                <div className="h-28 bg-white/5">{c.banner_url && <img src={c.banner_url} alt="" className="w-full h-full object-cover" />}</div>
                <div className="p-4">
                  <p className="font-bold">{c.name}</p>
                  {c.tagline && <p className="text-sm text-white/70 line-clamp-2">{c.tagline}</p>}
                  <p className="text-[11px] text-white/50 mt-2">
                    {[placeLine(c), memberCountLabel(c.member_count), c.join_mode === 'open' ? null : c.join_mode === 'approval' ? 'Ask to join' : 'Invite only'].filter(Boolean).join(' · ')}
                  </p>
                  {c.next_event_at && <p className="text-[11px] text-white/50">Next: {formatInTz(new Date(c.next_event_at), undefined, { dateStyle: 'medium' })}</p>}
                </div>
              </Link>
            </li>
          ))}
        </ul>
        {data && data.total > data.items.length && <p className="text-xs text-white/40 mt-6">Showing {data.items.length} of {data.total}. Narrow it with a city or a search.</p>}
      </div>
    </div>
  );
}
