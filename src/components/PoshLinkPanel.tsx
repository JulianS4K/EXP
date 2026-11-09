// Posh (third-party link) extras on the Promote page's Discovery listings
// row (mig 20261104150000; docs/organizer-guide.md "Discovery listings").
// The organizer makes the Posh page by hand on posh.vip: the steps, a copy
// kit for Posh's form with the tracked Exos ticket link, and once the page is
// live, Posh's own views / clicks (entered here) next to the Exos orders that
// came through that link. Nothing is sent to Posh.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Copy, Trash2 } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { publicUrl } from '../lib/utils';
import type { DiscoveryEvent, DiscoveryRow } from '../lib/discovery/channels';
import { deletePoshStats, poshLinkFunnel, recordPoshStats, type PoshFunnelResponse } from '../lib/discovery/api';
import { formatRate, parseCount, poshFunnel, poshKit, type PoshLinkEligibility } from '../lib/discovery/poshLink';

function today(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function money(cents: number, currency: string): string {
  try {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: currency.toUpperCase() }).format(cents / 100);
  } catch {
    return `${(cents / 100).toFixed(2)} ${currency.toUpperCase()}`;
  }
}

export default function PoshLinkPanel({ eventId, event, row, eligibility, canEdit }: {
  eventId: string;
  event: DiscoveryEvent | null;
  row: DiscoveryRow;
  eligibility: PoshLinkEligibility;
  canEdit: boolean;
}) {
  const { toast } = useToast();
  const appBase = useMemo(() => publicUrl('/').replace(/\/+$/, ''), []);
  const kit = useMemo(() => (event ? poshKit(event, appBase) : null), [event, appBase]);
  const live = row.status === 'live' || row.status === 'removed';

  const [data, setData] = useState<PoshFunnelResponse | null>(null);
  const [asOf, setAsOf] = useState(today);
  const [views, setViews] = useState('');
  const [clicks, setClicks] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    if (!live) return;
    poshLinkFunnel(eventId).then(setData).catch(() => setData(null));
  }, [eventId, live]);
  useEffect(load, [load]);

  const copy = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      toast({ kind: 'success', message: 'Copied.' });
    } catch {
      toast({ kind: 'error', message: 'Copy failed; select the text instead.' });
    }
  };

  const save = async () => {
    const v = parseCount(views), c = parseCount(clicks);
    if (v === null || c === null || v === 'invalid' || c === 'invalid') {
      toast({ kind: 'error', message: 'Views and clicks: whole numbers from 0.' });
      return;
    }
    if (!row.publication) return;
    setBusy(true);
    try {
      await recordPoshStats(row.publication.id, asOf, v, c);
      setViews(''); setClicks('');
      load();
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not save that.' });
    } finally {
      setBusy(false);
    }
  };

  const remove = async (id: string) => {
    setBusy(true);
    try {
      await deletePoshStats(id);
      load();
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not delete that.' });
    } finally {
      setBusy(false);
    }
  };

  const f = data ? poshFunnel(data.readings, data.exos) : null;

  return (
    <div className="mt-3 space-y-3">
      {row.info?.steps && (
        <ol className="list-decimal list-inside text-xs text-white/60 space-y-0.5 max-w-prose">
          {row.info.steps.map((s) => <li key={s}>{s}</li>)}
        </ol>
      )}
      {eligibility.blocked && <p className="text-xs text-red-400 max-w-prose">{eligibility.blocked}</p>}
      {eligibility.warning && <p className="text-xs text-amber-300 max-w-prose">{eligibility.warning}</p>}

      {!eligibility.blocked && kit && (
        <details className="border border-white/10 rounded p-3">
          <summary className="text-xs font-bold cursor-pointer">Posh kit (copy into Create Event → External tickets)</summary>
          <dl className="grid grid-cols-1 sm:grid-cols-[9rem_1fr] gap-x-4 gap-y-1 text-xs mt-3">
            {kit.fields.map((x) => (
              <div key={x.key} className="contents">
                <dt className="text-white/40 font-bold uppercase tracking-wider pt-0.5">{x.label}</dt>
                <dd className="flex items-start gap-2 min-w-0">
                  <span className={`break-all ${x.key === 'description' ? 'whitespace-pre-line' : ''}`}>{x.value}</span>
                  <button type="button" onClick={() => copy(x.value)} aria-label={`Copy ${x.label}`} className="text-white/40 hover:text-white shrink-0">
                    <Copy size={12} />
                  </button>
                </dd>
              </div>
            ))}
          </dl>
          {kit.when && <p className="text-xs text-white/40 mt-2">{kit.when}</p>}
        </details>
      )}

      {live && (
        <div className="border border-white/10 rounded p-3 text-xs">
          <p className="font-bold mb-2">Posh numbers</p>
          {f && (
            <>
              <div className="grid grid-cols-3 gap-2 mb-2">
                <div><p className="text-white/40 uppercase tracking-wider">Posh views</p><p className="text-lg font-bold">{f.views}</p></div>
                <div><p className="text-white/40 uppercase tracking-wider">Ticket clicks</p><p className="text-lg font-bold">{f.clicks}</p><p className="text-white/50">{formatRate(f.clickRate)} of views</p></div>
                <div><p className="text-white/40 uppercase tracking-wider">Exos orders</p><p className="text-lg font-bold">{f.orders}</p><p className="text-white/50">{formatRate(f.orderRate)} of clicks</p></div>
              </div>
              <p className="text-white/50 mb-1">
                {f.tickets} tickets, {money(f.grossCents, data?.exos.currency ?? 'usd')} (net of refunds) · {formatRate(f.viewToOrder)} of Posh views ordered
                {f.latest ? ` · Posh numbers as of ${f.latest.as_of}` : ''}
              </p>
              {f.notes.map((n) => <p key={n} className="text-amber-300">{n}</p>)}
              {data && data.readings.length > 0 && (
                <ul className="mt-2 divide-y divide-white/10">
                  {[...data.readings].reverse().map((r) => (
                    <li key={r.id} className="py-1 flex items-center justify-between gap-2">
                      <span>{r.as_of}: {r.page_views} views, {r.link_clicks} clicks</span>
                      {canEdit && (
                        <button type="button" disabled={busy} onClick={() => remove(r.id)} aria-label={`Delete the ${r.as_of} reading`}
                          className="text-white/40 hover:text-red-400 disabled:opacity-50"><Trash2 size={12} /></button>
                      )}
                    </li>
                  ))}
                </ul>
              )}
            </>
          )}
          {canEdit && (
            <div className="flex flex-wrap items-end gap-2 mt-3">
              <label className="flex flex-col gap-1">
                <span className="text-white/40">As of</span>
                <input type="date" value={asOf} max={today()} onChange={(e) => setAsOf(e.target.value)}
                  className="bg-black border border-white/20 rounded px-2 py-1" />
              </label>
              <label className="flex flex-col gap-1">
                <span className="text-white/40">Page views</span>
                <input inputMode="numeric" value={views} onChange={(e) => setViews(e.target.value)}
                  className="bg-black border border-white/20 rounded px-2 py-1 w-28" />
              </label>
              <label className="flex flex-col gap-1">
                <span className="text-white/40">Ticket-link clicks</span>
                <input inputMode="numeric" value={clicks} onChange={(e) => setClicks(e.target.value)}
                  className="bg-black border border-white/20 rounded px-2 py-1 w-28" />
              </label>
              <button type="button" disabled={busy} onClick={save}
                className="px-3 py-1.5 rounded bg-brand-primary text-black font-bold disabled:opacity-50">Save reading</button>
            </div>
          )}
          <p className="text-white/40 mt-2">Copy these from your event's stats on Posh. Orders are Exos checkouts that came through the Posh link.</p>
        </div>
      )}
    </div>
  );
}
