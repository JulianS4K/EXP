// Per-genre playbook (Promote page): for the event's category, which ad
// platforms to use, creative tips, poster / QR guidance and the ad-policy
// traps. Static (lib/promoPlaybook.ts, sources in its header).

import { BookOpen } from 'lucide-react';
import { MARKET_CATEGORY_LABEL, type MarketCategory } from '../../supabase/functions/_shared/marketplace/eventStandard.ts';
import type { CityConfig } from '../../supabase/functions/_shared/discovery/cities.ts';
import { playbookFor } from '../lib/promoPlaybook';

export default function PromoPlaybookPanel({ category, city = null }: { category: MarketCategory; city?: CityConfig | null }) {
  const pb = playbookFor(category, city);
  const label = MARKET_CATEGORY_LABEL[category];
  return (
    <section data-promotion className="bg-[#111] p-6 border border-white/10 mb-6" aria-labelledby="playbook-title">
      <h2 id="playbook-title" className="disp text-lg uppercase tracking-wide text-white mb-1 flex items-center gap-2">
        <BookOpen className="w-4 h-4 text-brand-primary" aria-hidden="true" /> Playbook: {label}
      </h2>
      <p className="text-sm text-white/60 mb-4">What tends to work for {label.toLowerCase()} events{city ? ` in ${city.name}` : ''}. Your category comes from the event's category and genres.</p>
      <div className="grid md:grid-cols-2 gap-5 text-sm">
        <div>
          <h3 className="text-[10px] font-black text-white/50 uppercase tracking-widest mb-2">Where to advertise</h3>
          <ol className="space-y-2 list-decimal list-inside">
            {pb.platforms.map((p) => (
              <li key={p.name} className="text-white/80"><strong className="text-white">{p.name}</strong>: {p.why}</li>
            ))}
          </ol>
          {pb.geo && <p className="text-white/60 text-xs mt-2">{pb.geo}</p>}
        </div>
        <div>
          <h3 className="text-[10px] font-black text-white/50 uppercase tracking-widest mb-2">Creative</h3>
          <ul className="space-y-1.5 list-disc list-inside text-white/80">{pb.creative.map((t) => <li key={t}>{t}</li>)}</ul>
        </div>
        <div>
          <h3 className="text-[10px] font-black text-white/50 uppercase tracking-widest mb-2">Posters and QR codes</h3>
          <ul className="space-y-1.5 list-disc list-inside text-white/80">{pb.print.map((t) => <li key={t}>{t}</li>)}</ul>
        </div>
        <div>
          <h3 className="text-[10px] font-black text-white/50 uppercase tracking-widest mb-2">Ad rules to know</h3>
          <ul className="space-y-1.5 list-disc list-inside text-white/80">{pb.policy.map((t) => <li key={t}>{t}</li>)}</ul>
        </div>
      </div>
    </section>
  );
}
