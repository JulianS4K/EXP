// Edit event → Where tickets are sold (mig 20261016100000). Exos, or the
// organizer's own Eventbrite / pretix / hi.events / Luma shop: the buy button
// links there, and pretix / hi.events / Luma attendees sync to the door (read-only).

import { useCallback, useEffect, useState } from 'react';
import { Store } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useToast } from '../context/ToastContext';
import {
  BACKEND_LABEL, fetchBackendStatus, linkBackend, refFromLink, setTicketBackend, SYNC_PROVIDERS, syncBackend, unlinkBackend,
  type BackendStatus, type SyncProvider, type TicketBackend,
} from '../lib/integrations';

const REF_HELP: Record<SyncProvider, { label: string; placeholder: string; missing: string }> = {
  pretix: { label: 'pretix event link or short name', placeholder: 'https://pretix.eu/myclub/spring/', missing: 'Paste the pretix event link or its short name.' },
  hievents: { label: 'hi.events check-in list link', placeholder: 'https://…/check-in/cil_…', missing: 'Paste the hi.events check-in list link.' },
  luma: { label: 'Luma event manage link or event id', placeholder: 'https://luma.com/event/manage/evt-…', missing: 'Paste the Luma manage link (it has the evt-… id).' },
};

const BTN = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-1.5 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';
const FLD = 'w-full bg-black border border-white/20 px-3 py-2 text-xs text-white';

export default function TicketBackendPanel({ eventId, orgId }: { eventId: string; orgId?: string }) {
  const { toast } = useToast();
  const [st, setSt] = useState<BackendStatus | null>(null);
  const [backend, setBackend] = useState<TicketBackend>('exos');
  const [url, setUrl] = useState('');
  const [ref, setRef] = useState('');
  const [busy, setBusy] = useState(false);
  const [hidden, setHidden] = useState(false);

  const load = useCallback(() => {
    fetchBackendStatus(eventId)
      .then((s) => { setSt(s); setBackend(s.ticketBackend); setUrl(s.externalTicketUrl ?? ''); })
      .catch(() => setHidden(true));
  }, [eventId]);
  useEffect(load, [load]);

  if (hidden || !st) return null;
  const changed = backend !== st.ticketBackend || (backend !== 'exos' && url.trim() !== (st.externalTicketUrl ?? ''));
  const syncProvider = (SYNC_PROVIDERS as string[]).includes(backend) ? backend as SyncProvider : null;
  const connected = syncProvider ? st.connected.includes(syncProvider) : false;

  const save = async () => {
    setBusy(true);
    try {
      await setTicketBackend(eventId, backend, backend === 'exos' ? null : url);
      toast({ kind: 'success', message: backend === 'exos' ? 'Tickets sell on Exos.' : `The buy button now goes to ${BACKEND_LABEL[backend]}.` });
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const link = async () => {
    if (!syncProvider) return;
    const id = refFromLink(syncProvider, ref);
    if (!id) {
      toast({ kind: 'error', message: REF_HELP[syncProvider].missing });
      return;
    }
    setBusy(true);
    try {
      const r = await linkBackend(eventId, syncProvider, id);
      toast({ kind: r.sync?.ok === false ? 'error' : 'success',
        message: r.sync?.ok === false ? `Linked, but the first sync failed: ${r.sync.error}` : `Linked. ${r.sync?.added ?? 0} guests on the door list.` });
      setRef('');
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const syncNow = async () => {
    setBusy(true);
    try {
      const r = await syncBackend(eventId);
      toast({ kind: r.sync.ok ? 'success' : 'error', message: r.sync.ok ? (r.sync.skipped ? 'Synced moments ago.' : `Synced. ${r.sync.added ?? 0} new.`) : r.sync.error ?? 'Sync failed.' });
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const unlink = async () => {
    if (!window.confirm('Stop syncing? Guests already on the door list stay.')) return;
    setBusy(true);
    try {
      await unlinkBackend(eventId);
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-4">
      <div className="flex items-center space-x-3">
        <Store className="text-brand-primary w-5 h-5" aria-hidden="true" />
        <h2 className="disp text-lg uppercase tracking-wide text-white leading-none">Where tickets are sold</h2>
      </div>
      <p className="type text-xs text-white/50">
        Exos, or your own shop on another platform. With another platform, the buy button sends fans there and Exos doesn't
        take payment; the event page, marketing and the door stay on Exos.
      </p>
      <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Ticket backend">
        {(['exos', 'eventbrite', 'pretix', 'hievents', 'luma'] as TicketBackend[]).map((b) => (
          <button key={b} type="button" role="radio" aria-checked={backend === b} disabled={!st.canManage || busy}
            onClick={() => setBackend(b)}
            className={`${BTN} ${backend === b ? 'border-brand-primary text-brand-primary' : ''}`}>
            {BACKEND_LABEL[b]}
          </button>
        ))}
      </div>
      {backend !== 'exos' && (
        <label className="block">
          <span className="type block text-[10px] uppercase tracking-widest text-white/50 mb-1">Link to the {BACKEND_LABEL[backend]} ticket page</span>
          <input className={FLD} value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://…" disabled={!st.canManage} />
        </label>
      )}
      {st.canManage && changed && (
        <button type="button" onClick={() => void save()} disabled={busy} className={BTN}>Save</button>
      )}

      {backend === 'eventbrite' && st.ticketBackend === 'eventbrite' && (
        <p className="type text-[11px] text-white/50">
          Link the Eventbrite event for the door in <Link to="/door" className="underline">the door app</Link> (or the event report → Attendees).
        </p>
      )}

      {syncProvider && st.ticketBackend === syncProvider && (
        <div className="border-t border-white/10 pt-4 space-y-3">
          <p className="type text-[11px] uppercase tracking-widest text-white/60">Door sync from {BACKEND_LABEL[syncProvider]}</p>
          {!connected && (
            <p className="type text-xs text-white/50">
              Connect {BACKEND_LABEL[syncProvider]} first in {orgId ? <Link to={`/orgs/${orgId}/settings`} className="underline">Org settings → Integrations</Link> : 'Org settings → Integrations'}.
            </p>
          )}
          {st.link ? (
            <div className="space-y-2">
              <p className="type text-xs text-white/70">
                {st.link.externalName ?? 'Linked'} · {st.link.syncedCount} guests
                {st.link.lastOkAt ? ` · synced ${st.link.lastOkAt.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}` : ''}
                {st.link.rowErrors ? ` · ${st.link.rowErrors} couldn't be read` : ''}
              </p>
              {st.link.lastError && <p className="type text-[11px] text-rose-400">{st.link.lastError}</p>}
              <div className="flex gap-2">
                <button type="button" onClick={() => void syncNow()} disabled={busy} className={BTN}>Sync now</button>
                {st.canManage && <button type="button" onClick={() => void unlink()} disabled={busy} className={BTN}>Unlink</button>}
              </div>
            </div>
          ) : st.canManage && connected ? (
            <div className="space-y-2">
              <label className="block">
                <span className="type block text-[10px] uppercase tracking-widest text-white/50 mb-1">
                  {REF_HELP[syncProvider].label}
                </span>
                <input className={FLD} value={ref} onChange={(e) => setRef(e.target.value)}
                  placeholder={REF_HELP[syncProvider].placeholder} />
              </label>
              {syncProvider === 'hievents' && (
                <p className="type text-[11px] text-white/40">
                  In hi.events: Check-in lists → make one for this event → share. Rotating QR codes can't be checked by
                  Exos; those guests are found by name.
                </p>
              )}
              {syncProvider === 'luma' && (
                <p className="type text-[11px] text-white/40">
                  Open the event in Luma's Manage view and paste that link (it has the evt-… id). Luma ticket QR codes
                  scan at the Exos door; pending and waitlisted guests show as not admitted.
                </p>
              )}
              <button type="button" onClick={() => void link()} disabled={busy || !ref.trim()} className={BTN}>Link and sync</button>
            </div>
          ) : null}
        </div>
      )}
    </section>
  );
}
