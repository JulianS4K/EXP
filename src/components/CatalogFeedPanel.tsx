// Catalog feed URLs for dynamic / catalog ads (docs/marketing-catalog.md).
// The feed itself is public (exos-catalog-feed reads only what the event pages
// show), so any org member may see and copy the links.

import { Copy } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { catalogFeedLinks } from '../lib/audienceCsv';

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

function functionsBase(): string {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  return url ? `${url}/functions/v1` : '';
}

export default function CatalogFeedPanel({ orgSlug }: { orgSlug: string }) {
  const { toast } = useToast();
  const links = catalogFeedLinks(functionsBase(), orgSlug);
  if (!links.length) return null;

  const copy = (url: string) => {
    navigator.clipboard
      .writeText(url)
      .then(() => toast({ kind: 'success', message: 'Feed URL copied.' }))
      .catch(() => toast({ kind: 'error', message: 'Copy failed — select and copy manually.' }));
  };

  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8">
      <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest mb-2">Catalog feed</h2>
      <p className="text-xs text-slate-400 mb-4">
        Your published upcoming events as a product catalog for catalog ads. Add the URL as a
        scheduled data feed (Meta Commerce Manager, TikTok Catalog Manager or Google Merchant
        Center); it refreshes itself. Item ids are event ids, the same ids your pixels send.
        Prices are all-in; links carry <code className="font-mono">utm_campaign=catalog</code>.
      </p>
      <ul className="space-y-3">
        {links.map((l) => (
          <li key={l.platform}>
            <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1">{l.label}</span>
            <div className="flex gap-2">
              <input
                readOnly
                value={l.url}
                aria-label={`${l.label} feed URL`}
                onClick={(e) => (e.target as HTMLInputElement).select()}
                className="flex-1 min-w-0 bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-[11px] text-slate-700 font-mono focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60"
              />
              <button
                type="button"
                onClick={() => copy(l.url)}
                className="px-3 py-2 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest text-slate-600 hover:border-tm-blue hover:text-tm-blue transition-colors inline-flex items-center gap-1"
              >
                <Copy className="w-3 h-3" aria-hidden="true" /> Copy
              </button>
            </div>
          </li>
        ))}
      </ul>
      <p className="text-[11px] text-slate-400 mt-4">
        Google Shopping doesn't accept event tickets, so Merchant Center may disapprove these items
        for Shopping ads; see docs/marketing-catalog.md.
      </p>
    </div>
  );
}
