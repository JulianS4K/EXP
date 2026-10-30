// Discovery listings for one event (Promote page): every channel with its
// status. Feeds (Google, calendars, ad catalogs) are computed from the feeds'
// own rules; manual calendars (DoNYC, Time Out, CitySpark, RA, …) are queued
// here and worked by a person (the operator's queue at /admin/listings, or
// the organizer for channels that only take their own account).
// Mig 20261029130000; docs/organizer-guide.md "Discovery listings".

import { useCallback, useEffect, useState } from 'react';
import { ExternalLink, Globe } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { discoveryRows, type DiscoveryRow } from '../lib/discovery/channels';
import { eventChannels, queueListing, setListingStatus, withdrawListing } from '../lib/discovery/api';
import { STATUS_LABEL, canQueue, hasManualSlot, takesSlot, type ChannelStatus } from '../../supabase/functions/_shared/discovery/channels.ts';

const TONE: Record<ChannelStatus, string> = {
  live: 'bg-emerald-50 text-emerald-700 border-emerald-200',
  submitted: 'bg-sky-50 text-sky-700 border-sky-200',
  queued: 'bg-amber-50 text-amber-700 border-amber-200',
  rejected: 'bg-red-50 text-red-700 border-red-200',
  removed: 'bg-slate-100 text-slate-500 border-slate-200',
  not_submitted: 'bg-slate-50 text-slate-500 border-slate-200',
  not_eligible: 'bg-slate-50 text-slate-500 border-slate-200',
};

export function StatusPill({ status }: { status: ChannelStatus }) {
  return <span className={`inline-block px-2 py-0.5 rounded border text-[10px] font-black uppercase tracking-widest ${TONE[status]}`}>{STATUS_LABEL[status]}</span>;
}

export default function DiscoveryListingsPanel({ eventId }: { eventId: string }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<DiscoveryRow[] | null>(null);
  const [canEdit, setCanEdit] = useState(false);
  const [cap, setCap] = useState<{ cap: number | null; used: number; minutes: number }>({ cap: null, used: 0, minutes: 0 });
  const [busy, setBusy] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);

  const load = useCallback(() => {
    eventChannels(eventId)
      .then((r) => {
        setRows(discoveryRows(r));
        setCanEdit(!!r.can_edit);
        setCap({ cap: r.manual_cap ?? null, used: r.manual_used ?? 0, minutes: r.minutes_spent ?? 0 });
        setFailed(false);
      })
      .catch(() => { setRows([]); setFailed(true); });
  }, [eventId]);
  useEffect(load, [load]);

  const act = async (id: string, fn: () => Promise<unknown>) => {
    setBusy(id);
    try {
      await fn();
      load();
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not save that.' });
    } finally {
      setBusy(null);
    }
  };

  const markLive = (r: DiscoveryRow) => {
    const url = window.prompt(`Link to the ${r.name} listing (https://…)`, r.liveUrl ?? '');
    if (!url || !r.publication) return;
    void act(r.id, () => setListingStatus(r.publication!.id, 'live', { liveUrl: url }));
  };
  const markSubmitted = (r: DiscoveryRow) => {
    if (!r.publication) return;
    void act(r.id, () => setListingStatus(r.publication!.id, 'submitted'));
  };

  const feeds = (rows ?? []).filter((r) => r.kind === 'feed');
  const manual = (rows ?? []).filter((r) => r.kind !== 'feed');

  return (
    <section className="bg-[#111] p-6 border border-white/10 mb-6 text-white">
      <div className="flex items-center gap-2 mb-1">
        <Globe size={16} className="text-brand-primary" />
        <h2 className="text-sm font-black uppercase tracking-widest">Discovery listings</h2>
      </div>
      <p className="text-sm text-white/60 mb-5 max-w-prose">
        Where fans can find this event. Feeds update on their own; local calendars take a submission, which you can
        queue here. Each listing links back with its own tracking tag, so its sales show in Sources.
      </p>
      {rows === null ? (
        <p className="text-white/40 text-sm">Loading…</p>
      ) : failed ? (
        <p className="text-white/50 text-sm">Listings aren't available yet.</p>
      ) : (
        <>
          <h3 className="text-[10px] font-black text-white/40 uppercase tracking-widest mb-2">Automatic</h3>
          <ul className="divide-y divide-white/10 mb-6">
            {feeds.map((r) => (
              <li key={r.id} className="py-3 flex flex-wrap items-start justify-between gap-3 text-sm">
                <div className="min-w-0">
                  <p className="font-bold">{r.name}</p>
                  <p className="text-white/50 text-xs">
                    {r.status === 'live' ? `Live: ${r.info?.liveMeans ?? 'in the feed'}.` : `Not listed: ${r.reason}.`}
                  </p>
                  {r.info?.notes && <p className="text-white/40 text-xs mt-0.5">{r.info.notes}</p>}
                </div>
                <StatusPill status={r.status} />
              </li>
            ))}
          </ul>

          <h3 className="text-[10px] font-black text-white/40 uppercase tracking-widest mb-2">Calendars and listings sites</h3>
          {cap.cap != null && (
            <p className="text-xs text-white/50 mb-2">
              Free tier: up to {cap.cap} listing sites per event ({cap.used} used). Withdraw a queued one to pick another.
            </p>
          )}
          {cap.minutes > 0 && <p className="text-xs text-white/40 mb-2">{cap.minutes} min of manual submission work logged.</p>}
          <ul className="divide-y divide-white/10">
            {manual.map((r) => (
              <li key={r.id} className="py-3 text-sm">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="font-bold">
                      {r.name} <span className="text-white/40 font-normal text-xs">{r.region}</span>
                    </p>
                    {r.info?.notes && <p className="text-white/50 text-xs mt-0.5 max-w-prose">{r.info.notes}</p>}
                    {r.submissionUrl && (
                      <a href={r.submissionUrl} target="_blank" rel="noopener noreferrer"
                        className="inline-flex items-center gap-1 text-xs text-brand-primary font-bold mt-1">
                        How to submit <ExternalLink size={11} />{!r.verified && <span className="text-white/40 font-normal">(not verified)</span>}
                      </a>
                    )}
                    {r.status === 'live' && r.liveUrl && (
                      <p className="text-xs mt-1"><a href={r.liveUrl} target="_blank" rel="noopener noreferrer" className="text-emerald-400 font-bold">View listing</a></p>
                    )}
                    {r.status === 'rejected' && r.reason && <p className="text-xs text-red-400 mt-1">Rejected: {r.reason}</p>}
                    {r.nextAction && r.status !== 'live' && <p className="text-xs text-white/50 mt-1">Next: {r.nextAction}</p>}
                    {r.info?.submitter === 'organizer' && <p className="text-xs text-white/40 mt-1">Submitted from your own account on {r.name}.</p>}
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    <StatusPill status={r.status} />
                    {canEdit && canQueue(r.publication?.status)
                      && (!takesSlot(r.publication?.status) || hasManualSlot(cap.cap, cap.used)) && (
                      <button type="button" disabled={busy === r.id} onClick={() => act(r.id, () => queueListing(eventId, r.id))}
                        className="px-3 py-1.5 rounded bg-brand-primary text-black text-xs font-bold disabled:opacity-50">
                        {r.status === 'not_submitted' ? 'Queue for submission' : 'Queue again'}
                      </button>
                    )}
                    {canEdit && r.status === 'queued' && (
                      <button type="button" disabled={busy === r.id} onClick={() => act(r.id, () => withdrawListing(eventId, r.id))}
                        className="px-3 py-1.5 rounded border border-white/20 text-xs font-bold disabled:opacity-50">
                        Withdraw
                      </button>
                    )}
                    {canEdit && r.info?.submitter === 'organizer' && r.status === 'queued' && (
                      <button type="button" disabled={busy === r.id} onClick={() => markSubmitted(r)}
                        className="px-3 py-1.5 rounded border border-white/20 text-xs font-bold disabled:opacity-50">
                        I submitted it
                      </button>
                    )}
                    {canEdit && (r.status === 'queued' || r.status === 'submitted') && (
                      <button type="button" disabled={busy === r.id} onClick={() => markLive(r)}
                        className="px-3 py-1.5 rounded border border-emerald-400/50 text-emerald-400 text-xs font-bold disabled:opacity-50">
                        It's live
                      </button>
                    )}
                  </div>
                </div>
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  );
}
