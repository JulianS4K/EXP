// /admin/listings — the operator's discovery submission queue, across orgs
// (mig 20261029130000 exos_discovery_queue_list; exos_is_admin only). Each
// item has the copy-ready details for the channel's form (title, date,
// venue, address, all-in prices, the per-channel tracking link, image,
// description); after submitting by hand, record submitted / live (URL) /
// rejected (reason). Nothing is sent to the channel from here.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Copy, ExternalLink, ListChecks } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { discoveryMinutes, listingQueue, setListingStatus, type MinutesByOrg, type QueueItem } from '../lib/discovery/api';
import { publicUrl } from '../lib/utils';
import { MANUAL_CHANNELS, discoveryChannel, parseMinutes, type PublicationStatus } from '../../supabase/functions/_shared/discovery/channels.ts';
import { submissionCopy } from '../../supabase/functions/_shared/discovery/copy.ts';
import { StatusPill } from '../components/DiscoveryListingsPanel';

const TABS: PublicationStatus[] = ['queued', 'submitted', 'live', 'rejected'];

function when(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString(undefined, { dateStyle: 'medium' });
}

export default function ListingQueue() {
  const { user, isAdmin } = useAuth();
  const { toast } = useToast();
  const [status, setStatus] = useState<PublicationStatus>('queued');
  const [channel, setChannel] = useState('');
  const [items, setItems] = useState<QueueItem[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  // The public SPA base (publicUrl carries /bridge in this deployment).
  const appBase = useMemo(() => publicUrl('/').replace(/\/+$/, ''), []);

  const [minutes, setMinutes] = useState<MinutesByOrg[] | null>(null);

  const load = useCallback(() => {
    discoveryMinutes().then(setMinutes).catch(() => setMinutes(null));
    setItems(null);
    listingQueue(status, channel || undefined).then(setItems).catch((err) => {
      setItems([]);
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not load the queue.' });
    });
  }, [status, channel, toast]);
  useEffect(() => { if (isAdmin) load(); }, [isAdmin, load]);

  const copy = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      toast({ kind: 'success', message: 'Copied.' });
    } catch {
      toast({ kind: 'error', message: 'Copy failed; select the text instead.' });
    }
  };

  const record = async (it: QueueItem, next: PublicationStatus) => {
    let opts: { liveUrl?: string; reason?: string; minutes?: number | null } = {};
    if (next === 'live') {
      const url = window.prompt(`Link to the ${it.channel_name} listing (https://…)`, it.live_url ?? '');
      if (!url) return;
      opts = { liveUrl: url };
    } else if (next === 'rejected') {
      const reason = window.prompt(`Why did ${it.channel_name} reject it?`, '');
      if (!reason) return;
      opts = { reason };
    }
    // Discovery pilot: minutes of manual work on this step (blank = none).
    if (next === 'submitted' || next === 'live' || next === 'rejected') {
      const m = parseMinutes(window.prompt('Minutes you spent on this step (0-600, blank to skip)', ''));
      if (m === 'invalid') {
        toast({ kind: 'error', message: 'Minutes: a whole number from 0 to 600.' });
        return;
      }
      opts.minutes = m;
    }
    setBusy(it.id);
    try {
      await setListingStatus(it.id, next, opts);
      load();
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not save that.' });
    } finally {
      setBusy(null);
    }
  };

  if (!user || !isAdmin) {
    return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 font-bold uppercase tracking-widest">Operators only.</div>;
  }

  return (
    <div className="min-h-screen bg-tm-gray text-slate-900">
      <div className="max-w-5xl mx-auto px-4 py-10">
        <div className="mb-8">
          <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Operator</p>
          <h1 className="text-3xl md:text-4xl font-bold tracking-tight">Listing submissions</h1>
          <p className="text-sm text-slate-600 mt-2 max-w-prose">
            Events organizers queued for calendars that only take a form. Submit each one on the channel's site with
            the details below, then record what happened.
          </p>
        </div>

        {minutes && minutes.length > 0 && (
          <details className="bg-white rounded-2xl border border-slate-200 p-4 mb-6 text-sm">
            <summary className="font-bold cursor-pointer">
              Manual minutes: {minutes.reduce((a, o) => a + o.minutes, 0)} min over {minutes.reduce((a, o) => a + o.events, 0)} events
            </summary>
            <table className="w-full mt-3 text-left">
              <thead>
                <tr className="text-[10px] uppercase tracking-widest text-slate-400">
                  <th className="py-1">Organizer</th><th>Events</th><th>Submissions</th><th>Minutes</th><th>Per event</th>
                </tr>
              </thead>
              <tbody>
                {minutes.map((o) => (
                  <tr key={o.org_id} className="border-t border-slate-100">
                    <td className="py-1">{o.org_name}</td><td>{o.events}</td><td>{o.submissions}</td><td>{o.minutes}</td><td>{o.minutes_per_event}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </details>
        )}

        <div className="flex flex-wrap items-center gap-4 border-b border-slate-200 mb-6">
          {TABS.map((t) => (
            <button key={t} onClick={() => setStatus(t)}
              className={`pb-3 text-sm font-bold capitalize ${status === t ? 'text-slate-900 border-b-2 border-tm-blue -mb-px' : 'text-slate-400 hover:text-slate-600'}`}>
              {t}
            </button>
          ))}
          <select value={channel} onChange={(e) => setChannel(e.target.value)} className="ml-auto mb-2 text-sm border border-slate-300 rounded px-2 py-1">
            <option value="">All channels</option>
            {MANUAL_CHANNELS.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </div>

        {items === null ? (
          <p className="text-slate-400 text-sm">Loading…</p>
        ) : items.length === 0 ? (
          <div className="bg-white rounded-2xl border border-slate-200 p-8 text-center text-slate-500 text-sm">
            <ListChecks className="w-5 h-5 mx-auto mb-2 text-slate-300" /> Nothing {status}.
          </div>
        ) : (
          <ul className="space-y-4">
            {items.map((it) => {
              const c = submissionCopy(it.event, it.event.tiers ?? [], it.channel_id ?? '', appBase);
              const info = discoveryChannel(it.channel_id ?? '');
              return (
                <li key={it.id} className="bg-white rounded-2xl border border-slate-200 p-5">
                  <div className="flex flex-wrap items-start justify-between gap-3 mb-3">
                    <div>
                      <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest">{it.channel_name} · {it.event.org_name}</p>
                      <p className="font-bold text-lg">{c.title}</p>
                      <p className="text-xs text-slate-500">
                        Queued {when(it.queued_at)}{it.note ? ` · “${it.note}”` : ''}{it.minutes_spent ? ` · ${it.minutes_spent} min logged` : ''}
                      </p>
                    </div>
                    <div className="flex items-center gap-2">
                      <StatusPill status={it.status} />
                      {it.submission_url && (
                        <a href={it.submission_url} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-xs font-bold text-tm-blue">
                          Submit on {it.channel_name} <ExternalLink size={11} />
                        </a>
                      )}
                    </div>
                  </div>
                  {info?.notes && <p className="text-xs text-slate-500 mb-3">{info.notes}</p>}
                  <dl className="grid grid-cols-1 sm:grid-cols-[8rem_1fr] gap-x-4 gap-y-1 text-sm mb-3">
                    {([['Title', c.title], ['When', c.when], ['Date / time', c.date && `${c.date} ${c.time}`], ['Venue', c.venue],
                      ['Address', c.address], ['Price (all-in)', c.price], ['Ticket link', c.ticketLink], ['Image', c.image ?? '']] as const)
                      .filter(([, v]) => v)
                      .map(([k, v]) => (
                        <div key={k} className="contents">
                          <dt className="text-slate-400 text-xs font-bold uppercase tracking-wider pt-0.5">{k}</dt>
                          <dd className="flex items-start gap-2 min-w-0">
                            <span className="break-all">{v}</span>
                            <button type="button" onClick={() => copy(v)} aria-label={`Copy ${k}`} className="text-slate-400 hover:text-slate-700 shrink-0"><Copy size={12} /></button>
                          </dd>
                        </div>
                      ))}
                  </dl>
                  {c.description && <p className="text-sm text-slate-700 bg-slate-50 rounded p-3 mb-3 whitespace-pre-line">{c.description}</p>}
                  <div className="flex flex-wrap gap-2">
                    <button type="button" onClick={() => copy(c.text)} className="px-3 py-1.5 rounded border border-slate-300 text-xs font-bold">Copy all</button>
                    {it.status === 'queued' && (
                      <button type="button" disabled={busy === it.id} onClick={() => record(it, 'submitted')} className="px-3 py-1.5 rounded bg-slate-900 text-white text-xs font-bold disabled:opacity-50">Submitted</button>
                    )}
                    {(it.status === 'queued' || it.status === 'submitted' || it.status === 'live') && (
                      <button type="button" disabled={busy === it.id} onClick={() => record(it, 'live')} className="px-3 py-1.5 rounded border border-emerald-300 text-emerald-700 text-xs font-bold disabled:opacity-50">
                        {it.status === 'live' ? 'Change URL' : 'Live (URL)'}
                      </button>
                    )}
                    {(it.status === 'queued' || it.status === 'submitted') && (
                      <button type="button" disabled={busy === it.id} onClick={() => record(it, 'rejected')} className="px-3 py-1.5 rounded border border-red-300 text-red-700 text-xs font-bold disabled:opacity-50">Rejected (reason)</button>
                    )}
                    {it.status === 'live' && (
                      <button type="button" disabled={busy === it.id} onClick={() => record(it, 'removed')} className="px-3 py-1.5 rounded border border-slate-300 text-xs font-bold disabled:opacity-50">Removed</button>
                    )}
                    {it.live_url && <a href={it.live_url} target="_blank" rel="noopener noreferrer" className="text-xs font-bold text-emerald-700 self-center">View listing</a>}
                    {it.rejection_reason && <span className="text-xs text-red-700 self-center">Rejected: {it.rejection_reason}</span>}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </div>
  );
}
