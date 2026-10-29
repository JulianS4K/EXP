// Org settings → Posh (mig 20261029150000): the webhook URL to paste into
// Posh, when it last heard from Posh, the Posh events linked to Exos events,
// and the orders that matched no event (assign them here). The URL holds a
// secret: it is shown once, right after it is made; "New URL" replaces it.

import { useCallback, useEffect, useState } from 'react';
import { Webhook } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import {
  assignPoshOrder, connectPosh, disconnectPosh, fetchOrgEvents, fetchPoshStatus, linkPoshEvent, unlinkPoshEvent,
  unmatchedLabel, type PoshStatus,
} from '../lib/posh';

const LBL = 'block text-[10px] font-black text-slate-500 uppercase tracking-widest mb-1';
const FLD = 'w-full bg-slate-50 border border-slate-200 rounded-lg px-3 py-2 text-xs text-slate-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';
const BTN = 'px-3 py-1.5 rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-50 border border-slate-300 text-slate-700 hover:border-brand-primary';

export default function PoshIntegrationPanel({ orgId, canEdit }: { orgId: string; canEdit: boolean }) {
  const { toast } = useToast();
  const [st, setSt] = useState<PoshStatus | null>(null);
  const [hidden, setHidden] = useState(false);
  const [busy, setBusy] = useState(false);
  const [url, setUrl] = useState('');
  const [events, setEvents] = useState<{ id: string; name: string }[]>([]);
  const [ref, setRef] = useState('');
  const [linkTo, setLinkTo] = useState('');
  const [assign, setAssign] = useState<Record<string, string>>({});

  const load = useCallback(() => {
    fetchPoshStatus(orgId).then(setSt).catch(() => setHidden(true));
  }, [orgId]);
  useEffect(load, [load]);
  useEffect(() => {
    if (canEdit) fetchOrgEvents(orgId).then(setEvents).catch(() => setEvents([]));
  }, [orgId, canEdit]);
  if (hidden || !st) return null;
  const manage = canEdit && st.canManage;

  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setBusy(true);
    try {
      await fn();
      toast({ kind: 'success', message: ok });
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const makeUrl = () => run(async () => {
    const r = await connectPosh(orgId);
    if (!r.url) throw new Error('Supabase URL is not configured for this app.');
    setUrl(r.url);
  }, st.connected ? 'New URL made. Paste it into Posh: the old one has stopped working.' : 'Webhook URL made. Paste it into Posh.');

  return (
    <section className="bg-white border border-slate-200 rounded-xl p-6 space-y-4">
      <div className="flex items-center gap-2">
        <Webhook className="w-4 h-4 text-brand-primary" aria-hidden="true" />
        <h3 className="text-sm font-black text-slate-800 uppercase tracking-widest">Posh</h3>
      </div>
      <p className="text-xs text-slate-500">
        Posh has no API for organizers, so Exos listens to Posh's webhooks. In Posh, open Organization Settings → API
        Webhooks and add this URL for <strong>Order Created</strong> and <strong>Pending Order Created</strong>. Posh
        sales then count against the Posh cap you set on each event, and Posh buyers show up on the door list. Exos
        never changes anything on Posh.
      </p>

      <div className="space-y-2">
        {url ? (
          <div>
            <span className={LBL}>Webhook URL (shown once: copy it now)</span>
            <div className="flex gap-2">
              <input className={FLD} readOnly value={url} onFocus={(e) => e.currentTarget.select()} aria-label="Posh webhook URL" />
              <button type="button" className={BTN} onClick={() => { void navigator.clipboard?.writeText(url); toast({ kind: 'success', message: 'Copied.' }); }}>Copy</button>
            </div>
          </div>
        ) : st.connected ? (
          <p className="text-xs text-slate-700">Connected: the URL ends in …{st.hint}. Lost it? Make a new one (the old one stops working).</p>
        ) : (
          <p className="text-xs text-slate-700">{st.disabled ? 'Switched off: Posh webhooks are refused.' : 'Not connected yet.'}</p>
        )}
        <p className="text-[11px] text-slate-500">
          {st.lastReceivedAt ? `Last heard from Posh ${st.lastReceivedAt.toLocaleString()} (${st.lastOutcome ?? 'ok'}). ` : 'Nothing received yet. '}
          {st.counts.tickets} ticket{st.counts.tickets === 1 ? '' : 's'} in {st.counts.confirmed} confirmed order{st.counts.confirmed === 1 ? '' : 's'},
          {' '}{st.counts.pending} pending, {st.counts.unmatched} unmatched{st.counts.oversold > 0 ? `, ${st.counts.oversold} past a Posh cap` : ''}.
        </p>
        {manage && (
          <div className="flex flex-wrap gap-2">
            <button type="button" className={BTN} disabled={busy} onClick={() => void makeUrl()}>{st.connected ? 'New URL' : 'Make the webhook URL'}</button>
            {st.connected && (
              <button type="button" className={BTN} disabled={busy}
                onClick={() => void run(() => disconnectPosh(orgId), 'Posh webhooks switched off.')}>Switch off</button>
            )}
          </div>
        )}
      </div>

      <div className="border-t border-slate-200 pt-4 space-y-2">
        <span className={LBL}>Posh events linked to Exos events</span>
        {st.links.length === 0 && <p className="text-xs text-slate-500">None yet.</p>}
        <ul className="space-y-1">
          {st.links.map((l) => (
            <li key={l.id} className="flex flex-wrap items-center justify-between gap-2 text-xs text-slate-700">
              <span><code>{l.poshRef}</code> → {l.eventName ?? l.eventId}</span>
              {manage && (
                <button type="button" className={BTN} disabled={busy}
                  onClick={() => void run(() => unlinkPoshEvent(l.id), 'Unlinked. Orders already matched stay with their event.')}>Unlink</button>
              )}
            </li>
          ))}
        </ul>
        {manage && (
          <div className="grid gap-2 md:grid-cols-[1fr_1fr_auto]">
            <input className={FLD} value={ref} onChange={(e) => setRef(e.target.value)}
              placeholder="Posh event link, id or name (as in the webhook)" aria-label="Posh event" />
            <select className={FLD} value={linkTo} onChange={(e) => setLinkTo(e.target.value)} aria-label="Exos event">
              <option value="">Exos event…</option>
              {events.map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}
            </select>
            <button type="button" className={BTN} disabled={busy || !ref.trim() || !linkTo}
              onClick={() => void run(async () => {
                const r = await linkPoshEvent(orgId, ref, linkTo);
                setRef('');
                if (r.ordersMatched) toast({ kind: 'info', message: `${r.ordersMatched} waiting order${r.ordersMatched === 1 ? '' : 's'} matched.` });
              }, 'Linked.')}>Link</button>
          </div>
        )}
      </div>

      {st.unmatched.length > 0 && (
        <div className="border-t border-slate-200 pt-4 space-y-2">
          <span className={LBL}>Unmatched Posh orders ({st.counts.unmatched})</span>
          <p className="text-[11px] text-slate-500">These name a Posh event Exos doesn't know. Assign one to its event: that Posh event is linked, so its other orders follow.</p>
          <ul className="space-y-2">
            {st.unmatched.map((u) => (
              <li key={u.id} className="flex flex-wrap items-center gap-2 text-xs text-slate-700">
                <span className="flex-1 min-w-[12rem]">
                  {unmatchedLabel(u)} · {u.quantity} ticket{u.quantity === 1 ? '' : 's'}{u.ticketLabel ? ` (${u.ticketLabel})` : ''}
                  {u.state === 'pending' ? ' · pending approval' : ''}{u.receivedAt ? ` · ${u.receivedAt.toLocaleString()}` : ''}
                </span>
                {manage && (
                  <>
                    <select className={`${FLD} w-auto`} value={assign[u.id] ?? ''} onChange={(e) => setAssign({ ...assign, [u.id]: e.target.value })}
                      aria-label="Assign to event">
                      <option value="">Assign to…</option>
                      {events.map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}
                    </select>
                    <button type="button" className={BTN} disabled={busy || !assign[u.id]}
                      onClick={() => void run(() => assignPoshOrder(u.id, assign[u.id]), 'Assigned.')}>Assign</button>
                  </>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}
