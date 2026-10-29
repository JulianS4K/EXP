// Edit event → for a link-out event (mig 20261029170000): where it's sold,
// what the last check of the source found, and "Check now". Renders nothing
// for an event Exos sells. Reads exos_event_imports (owner / manager /
// finance by RLS).

import { useEffect, useState } from 'react';
import { ExternalLink } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useToast } from '../context/ToastContext';
import { checkLinkOutNow, linkOutPriceLabel, platformLabel } from '../lib/linkOut';

interface ImportRow {
  platform: string;
  source_url: string;
  source_status: string;
  price_min: number | string | null;
  price_max: number | string | null;
  currency: string | null;
  is_free: boolean;
  checks_enabled: boolean;
  last_checked_at: string | null;
  last_ok_at: string | null;
  last_error: string | null;
  rescheduled_at: string | null;
}

const STATUS_LABEL: Record<string, string> = {
  on_sale: 'on sale', sold_out: 'sold out', cancelled: 'cancelled', ended: 'over', unknown: 'not checked',
};

export default function LinkOutStatusPanel({ eventId }: { eventId: string }) {
  const { toast } = useToast();
  const [row, setRow] = useState<ImportRow | null>(null);
  const [busy, setBusy] = useState(false);

  const load = () => supabase.from('exos_event_imports').select('*').eq('event_id', eventId).maybeSingle()
    .then(({ data }) => setRow((data as ImportRow | null) ?? null), () => setRow(null));
  useEffect(() => { void load(); }, [eventId]);

  if (!row) return null;
  const name = platformLabel(row.platform);
  const n = (v: number | string | null) => (v === null || v === '' ? null : Number(v));
  const price = linkOutPriceLabel({ priceMin: n(row.price_min), priceMax: n(row.price_max), isFree: row.is_free, currency: row.currency });

  const checkNow = async () => {
    setBusy(true);
    try {
      await checkLinkOutNow(eventId);
      await load();
      toast({ kind: 'success', message: `Checked ${name}.` });
    } catch (e) {
      toast({ kind: 'error', message: e instanceof Error ? e.message : 'Not checked.' });
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="mb-8 border border-white/10 bg-[#111] p-5" aria-labelledby="link-out-h">
      <h3 id="link-out-h" className="disp text-xl mb-2">Sold on {name}</h3>
      <p className="type text-[11px] text-white/60 leading-relaxed mb-3">
        Exos lists this event and sends buyers to your {name} checkout. Exos sells nothing for it: no Exos ticket types,
        holds, comps or resale. Edit the page here; prices and availability come from {name}.
      </p>
      <dl className="type text-[11px] uppercase tracking-widest grid grid-cols-2 gap-y-1 mb-3">
        <dt className="text-white/50">checkout</dt>
        <dd><a href={row.source_url} target="_blank" rel="noopener noreferrer" className="text-brand-primary inline-flex items-center gap-1 normal-case break-all">{row.source_url}<ExternalLink className="w-3 h-3" /></a></dd>
        <dt className="text-white/50">status</dt><dd>{STATUS_LABEL[row.source_status] ?? row.source_status}</dd>
        <dt className="text-white/50">price</dt><dd>{price ?? '—'}</dd>
        <dt className="text-white/50">last checked</dt><dd>{row.last_ok_at ? new Date(row.last_ok_at).toLocaleString() : '—'}</dd>
        {row.rescheduled_at && (<><dt className="text-white/50">moved on {name}</dt><dd>{new Date(row.rescheduled_at).toLocaleString()}</dd></>)}
      </dl>
      {row.last_error && <p className="type text-[11px] text-brand-accent mb-3">{row.last_error}</p>}
      {row.checks_enabled ? (
        <button type="button" disabled={busy} onClick={checkNow}
          className="type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40">
          Check {name} now
        </button>
      ) : (
        <p className="type text-[11px] text-white/50">Exos can't check {name} for changes yet: update this page if the event sells out, moves or is cancelled.</p>
      )}
    </section>
  );
}
