// Which event this is on each marketplace (exos_channel_event_links), and the
// staff decision when the automatic match wasn't sure. Lives in the event
// editor's Distribution section.
import { useEffect, useState } from 'react';
import {
  getChannelLinks,
  getMarketplaceOrders,
  linkChannelEvent,
  type ChannelLink,
  type MarketplaceOrder,
} from '../lib/marketplace/linksApi';
import { useToast } from '../context/ToastContext';
import { setStubHubAllocation } from '../lib/marketplace/stubhubStatusApi';
import type { StubHubDistributionRow } from '../lib/marketplace/stubhubStatus';

const LABEL: Record<string, string> = {
  stubhub: 'StubHub', seatgeek: 'SeatGeek', vivid: 'Vivid Seats', tickpick: 'TickPick', evo: 'Ticket Evolution', automatiq: 'Automatiq',
};

function when(iso: string | null): string {
  if (!iso) return '';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

export function ChannelLinks({ eventId }: { eventId: string }) {
  const { toast } = useToast();
  const [links, setLinks] = useState<ChannelLink[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const load = () => getChannelLinks(eventId).then(setLinks).catch((err) => {
    console.warn('marketplace links unavailable:', err);
    setLinks([]);
  });
  useEffect(() => {
    void getChannelLinks(eventId).then(setLinks).catch(() => setLinks([]));
  }, [eventId]);

  const decide = async (channel: string, id: string | null) => {
    setBusy(channel);
    try {
      await linkChannelEvent(eventId, channel, id);
      toast({ kind: 'success', message: id ? `Linked to ${LABEL[channel] ?? channel} event ${id}.` : `Marked as not on ${LABEL[channel] ?? channel} yet.` });
      await load();
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not save that.' });
    } finally {
      setBusy(null);
    }
  };

  if (!links?.length) return null;
  return (
    <div className="space-y-4">
      <h3 className="type text-[11px] text-white/60 uppercase tracking-widest">On each marketplace</h3>
      <ul className="space-y-3">
        {links.map((l) => (
          <li key={l.channel} className="border border-white/10 bg-black/40 p-4 space-y-3">
            <p className="type text-xs text-white/80">
              <span className="text-white">{LABEL[l.channel] ?? l.channel}: </span>
              {l.status === 'linked' || l.status === 'created'
                ? `event ${l.external_event_id}${l.method === 'manual' ? ' (set by staff)' : l.method === 'auto_match' ? ' (matched automatically)' : ''}`
                : l.status === 'review' ? 'possible matches, pick one or reject them'
                : l.status === 'rejected' ? 'not on this marketplace yet (staff decision)'
                : 'no matching event found'}
            </p>
            {l.status === 'review' && (
              <div className="space-y-2">
                {(l.candidates ?? []).map((c) => (
                  <div key={c.external_event_id} className="flex flex-wrap items-center justify-between gap-2 border border-white/10 p-3">
                    <div className="type text-xs text-white/70">
                      <p className="text-white">{c.url ? <a href={c.url} target="_blank" rel="noreferrer" className="underline">{c.name}</a> : c.name}</p>
                      <p>{[when(c.starts_at), c.venue].filter(Boolean).join(' · ')} · match {Math.round(c.score * 100)}%</p>
                    </div>
                    <button type="button" disabled={busy === l.channel} onClick={() => decide(l.channel, c.external_event_id)}
                      className="px-3 py-2 bg-brand-primary text-black text-[10px] font-black uppercase tracking-widest disabled:opacity-50">
                      This is it
                    </button>
                  </div>
                ))}
                <button type="button" disabled={busy === l.channel} onClick={() => decide(l.channel, null)}
                  className="px-3 py-2 border border-white/20 text-white/70 text-[10px] uppercase tracking-widest disabled:opacity-50">
                  None of these
                </button>
              </div>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}

const ORDER_STATUS: Record<MarketplaceOrder['status'], string> = {
  received: 'received',
  needs_attention: 'needs you',
  fulfilled: 'tickets issued, links not sent yet',
  delivered: 'delivered',
  cancelled: 'cancelled',
};

/** Sales made on the marketplaces, and the ones that need a human. */
export function MarketplaceOrders({ eventId }: { eventId: string }) {
  const [orders, setOrders] = useState<MarketplaceOrder[] | null>(null);
  useEffect(() => {
    void getMarketplaceOrders(eventId).then(setOrders).catch(() => setOrders([]));
  }, [eventId]);
  if (!orders?.length) return null;
  return (
    <div className="space-y-3">
      <h3 className="type text-[11px] text-white/60 uppercase tracking-widest">Marketplace sales</h3>
      <ul className="space-y-2">
        {orders.map((o) => (
          <li key={o.id} className={`border p-3 type text-xs ${o.status === 'needs_attention' ? 'border-amber-400/60 text-amber-200' : 'border-white/10 text-white/70'}`}>
            <p>
              <span className="text-white">{LABEL[o.channel] ?? o.channel} #{o.external_order_id}</span>
              {' '}· {o.quantity} ticket{o.quantity === 1 ? '' : 's'} · {ORDER_STATUS[o.status]}
              {o.sold_at ? ` · ${when(o.sold_at)}` : ''}
            </p>
            {o.attention_reason && <p className="mt-1">{o.attention_reason}</p>}
            {o.delivery_plan?.kind === 'manual' && o.delivery_plan.reason && <p className="mt-1">{o.delivery_plan.reason}</p>}
          </li>
        ))}
      </ul>
    </div>
  );
}

/**
 * Seats set aside for StubHub. Exos can't sell them, so a StubHub buyer and
 * an Exos buyer can never get the same seat; the StubHub listing should carry
 * exactly this many.
 */
export function StubHubAllocation({
  eventId, tiers, row, maxPerOrder, onSaved,
}: {
  eventId: string;
  tiers: Array<{ id: string; name: string; capacity: number }>;
  row: StubHubDistributionRow | null;
  /** The event's max per order: StubHub buyers see at most this many at a time. */
  maxPerOrder: number | null;
  onSaved: () => void;
}) {
  const { toast } = useToast();
  const [tierId, setTierId] = useState(row?.tier_id ?? tiers[0]?.id ?? '');
  const [qty, setQty] = useState(String(row?.requested_qty ?? 0));
  const [busy, setBusy] = useState(false);
  if (!tiers.length) return null;
  const save = async () => {
    const n = Number.parseInt(qty, 10);
    if (!Number.isInteger(n) || n < 0) {
      toast({ kind: 'error', message: 'Enter a whole number of seats (0 to stop).' });
      return;
    }
    setBusy(true);
    try {
      await setStubHubAllocation(eventId, tierId, n);
      toast({ kind: 'success', message: n ? `${n} seat${n === 1 ? '' : 's'} set aside for StubHub.` : 'StubHub seats given back to Exos.' });
      onSaved();
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message.replace(/^exos_set_channel_allocation: /, '') : 'Could not save that.' });
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="space-y-2">
      <h3 className="type text-[11px] text-white/60 uppercase tracking-widest">Seats for StubHub</h3>
      <p className="type text-xs text-white/50">
        Exos stops selling these seats, so nobody can buy the same seat on both. Set 0 to give them back.
        {maxPerOrder
          ? ` StubHub buyers see at most ${maxPerOrder} at a time (your max per order), so one order can't take them all.`
          : ' Set a max per order to stop one StubHub order taking them all.'}
      </p>
      <div className="flex flex-wrap items-end gap-2">
        <label className="type text-xs text-white/70">
          <span className="block mb-1">Ticket type</span>
          <select value={tierId} onChange={(e) => setTierId(e.target.value)} className="bg-black border border-white/20 px-3 py-2 text-white">
            {tiers.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
        </label>
        <label className="type text-xs text-white/70">
          <span className="block mb-1">Seats</span>
          <input type="number" min={0} inputMode="numeric" value={qty} onChange={(e) => setQty(e.target.value)}
            className="w-24 bg-black border border-white/20 px-3 py-2 text-white" />
        </label>
        <button type="button" onClick={save} disabled={busy || !tierId}
          className="px-4 py-2 bg-brand-primary text-black text-[10px] font-black uppercase tracking-widest disabled:opacity-50">
          {busy ? 'Saving…' : 'Save'}
        </button>
      </div>
    </div>
  );
}

