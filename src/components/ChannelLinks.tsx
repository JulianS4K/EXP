// Which event this is on each marketplace (exos_channel_event_links), and the
// staff decision when the automatic match wasn't sure. Lives in the event
// editor's Distribution section.
import { useEffect, useState } from 'react';
import {
  getChannelLinks,
  getMarketplaceOrders,
  linkChannelEvent,
  markMarketplaceOrderHandled,
  marketplaceOrderActions,
  resendMarketplaceClaimLinks,
  type ChannelLink,
  type MarketplaceOrder,
} from '../lib/marketplace/linksApi';
import { useToast } from '../context/ToastContext';
import { setChannelAllocation, setChannelPrice, setMarketSplit, type AllocationChannel } from '../lib/marketplace/stubhubStatusApi';
import { allocationCellStatus, parseMarketplacePrice, poolLine, type MarketplaceRow } from '../lib/marketplace/stubhubStatus';
import { MARKET_SPLITS, MARKET_SPLIT_LABEL, formatSeatRanges, parseSeatRanges, type MarketSplit } from '../lib/marketplace';

const LABEL: Record<string, string> = {
  stubhub: 'StubHub', seatgeek: 'SeatGeek', gametime: 'Gametime', gotickets: 'GoTickets', vivid: 'Vivid Seats', tickpick: 'TickPick', evo: 'Ticket Evolution', automatiq: 'Automatiq',
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
  const { toast } = useToast();
  const [orders, setOrders] = useState<MarketplaceOrder[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const load = () => getMarketplaceOrders(eventId).then(setOrders).catch(() => setOrders([]));
  useEffect(() => {
    void getMarketplaceOrders(eventId).then(setOrders).catch(() => setOrders([]));
  }, [eventId]);

  const run = async (id: string, what: () => Promise<string | null>) => {
    setBusy(id);
    try {
      const done = await what();
      if (done) toast({ kind: 'success', message: done });
      await load();
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Could not do that.';
      toast({ kind: 'error', message: msg.replace(/^exos_[a-z_]+: /, '') });
    } finally {
      setBusy(null);
    }
  };
  const resend = (o: MarketplaceOrder) => run(o.id, async () => {
    const n = await resendMarketplaceClaimLinks(o.id);
    return `Sent ${n} claim link${n === 1 ? '' : 's'} to the buyer again.`;
  });
  const handled = (o: MarketplaceOrder) => run(o.id, async () => {
    const note = window.prompt('Mark handled: what did you do? (optional, for your team)');
    if (note === null) return null; // cancelled
    await markMarketplaceOrderHandled(o.id, note);
    return "Marked handled. Exos won't retry this order on its own.";
  });

  if (!orders?.length) return null;
  return (
    <div className="space-y-3">
      <h3 className="type text-[11px] text-white/60 uppercase tracking-widest">Marketplace sales</h3>
      <ul className="space-y-2">
        {orders.map((o) => {
          const act = marketplaceOrderActions(o);
          const open = o.status === 'needs_attention' && !o.handled_at;
          return (
            <li key={o.id} className={`border p-3 type text-xs ${open ? 'border-amber-400/60 text-amber-200' : 'border-white/10 text-white/70'}`}>
              <p>
                <span className="text-white">{LABEL[o.channel] ?? o.channel} #{o.external_order_id}</span>
                {' '}· {o.quantity} ticket{o.quantity === 1 ? '' : 's'} · {o.handled_at && o.status === 'needs_attention' ? 'handled' : ORDER_STATUS[o.status]}
                {o.sold_at ? ` · ${when(o.sold_at)}` : ''}
              </p>
              {o.attention_reason && <p className="mt-1">{o.attention_reason}</p>}
              {o.delivery_plan?.kind === 'manual' && o.delivery_plan.reason && <p className="mt-1">{o.delivery_plan.reason}</p>}
              {o.handled_at && (
                <p className="mt-1 text-white/50">Marked handled {when(o.handled_at)}{o.handled_note ? `: ${o.handled_note}` : ''}</p>
              )}
              {o.links_resent_at && <p className="mt-1 text-white/50">Claim links resent {when(o.links_resent_at)}</p>}
              {(act.resend || act.markHandled) && (
                <div className="mt-2 flex flex-wrap gap-2">
                  {act.resend && (
                    <button type="button" disabled={busy === o.id} onClick={() => resend(o)}
                      className="px-3 py-1.5 border border-white/20 text-white/80 text-[10px] uppercase tracking-widest disabled:opacity-50">
                      Resend claim links to buyer email
                    </button>
                  )}
                  {act.markHandled && (
                    <button type="button" disabled={busy === o.id} onClick={() => handled(o)}
                      className="px-3 py-1.5 bg-brand-primary text-black text-[10px] font-black uppercase tracking-widest disabled:opacity-50">
                      Mark handled
                    </button>
                  )}
                </div>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}

/**
 * The Marketplaces grid: a row per ticket type, a column per ticked
 * marketplace, each cell the seats set aside for it. Exos can't sell those
 * seats, so a marketplace buyer and an Exos buyer never get the same one, and
 * the marketplace listings carry exactly that many. Setting 0 takes the
 * listing down, then gives the seats back. The seat numbers shown are
 * internal (general admission has none; SeatGeek needs them): buyers never
 * see them. Each cell also takes an optional price (blank = the ticket
 * type's price); it can't be below what Exos charges (checked here and
 * enforced by exos_set_channel_price). Each ticket type has one split
 * policy (any / don't leave one / pairs / all together) that every
 * marketplace listing follows (listingStandard.ts).
 */
export function MarketplaceGrid({
  eventId, channels, tiers, rows, maxPerOrder, onSaved,
}: {
  eventId: string;
  channels: AllocationChannel[];
  /** price: what Exos charges for it now (scheduled step included): the marketplace floor. */
  tiers: Array<{ id: string; name: string; capacity: number; price: number; split?: MarketSplit }>;
  rows: MarketplaceRow[];
  /** The event's max per order: what one marketplace order can take. */
  maxPerOrder: number | null;
  onSaved: () => void;
}) {
  const { toast } = useToast();
  const rowFor = (ch: string, tierId: string) => rows.find((r) => r.channel === ch && r.tier_id === tierId) ?? null;
  const current = (ch: string, tierId: string) => {
    const r = rowFor(ch, tierId);
    return r && r.status !== 'delisted' && r.status !== 'failed' ? r.sell_cap ?? r.requested_qty ?? 0 : 0;
  };
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [priceDraft, setPriceDraft] = useState<Record<string, string>>({});
  // Split policy per ticket type: edits, and what was saved since the tiers were loaded.
  const [splitDraft, setSplitDraft] = useState<Record<string, MarketSplit>>({});
  const [splitSaved, setSplitSaved] = useState<Record<string, MarketSplit>>({});
  const splitNow = (t: { id: string; split?: MarketSplit }): MarketSplit => splitSaved[t.id] ?? t.split ?? 'any';
  const [busy, setBusy] = useState(false);
  const currentPrice = (ch: string, tierId: string): string => {
    const p = rowFor(ch, tierId)?.unit_price;
    return p === null || p === undefined || p === '' ? '' : String(Number(p));
  };
  const priceValue = (ch: AllocationChannel, tierId: string) => priceDraft[`${ch}:${tierId}`] ?? currentPrice(ch, tierId);
  if (!tiers.length || !channels.length) return null;
  const key = (ch: string, tierId: string) => `${ch}:${tierId}`;
  const value = (ch: AllocationChannel, tierId: string) => draft[key(ch, tierId)] ?? String(current(ch, tierId));

  const save = async () => {
    const changes: Array<{ ch: AllocationChannel; tierId: string; n: number }> = [];
    for (const ch of channels) {
      for (const t of tiers) {
        const raw = draft[key(ch, t.id)];
        if (raw === undefined) continue;
        const n = Number.parseInt(raw, 10);
        if (!Number.isInteger(n) || n < 0 || String(n) !== raw.trim()) {
          toast({ kind: 'error', message: `${t.name} on ${LABEL[ch]}: enter a whole number of seats (0 to stop).` });
          return;
        }
        if (n !== current(ch, t.id)) changes.push({ ch, tierId: t.id, n });
      }
    }
    const priceChanges: Array<{ ch: AllocationChannel; tierId: string; price: number | null }> = [];
    for (const ch of channels) {
      for (const t of tiers) {
        const raw = priceDraft[key(ch, t.id)];
        if (raw === undefined || raw.trim() === currentPrice(ch, t.id)) continue;
        const p = parseMarketplacePrice(raw, t.price);
        if ('error' in p) {
          toast({ kind: 'error', message: `${t.name} price on ${LABEL[ch]}: ${p.error}.` });
          return;
        }
        priceChanges.push({ ch, tierId: t.id, price: p.price });
      }
    }
    const splitChanges = tiers.filter((t) => splitDraft[t.id] && splitDraft[t.id] !== splitNow(t))
      .map((t) => ({ tierId: t.id, split: splitDraft[t.id] }));
    if (!changes.length && !priceChanges.length && !splitChanges.length) {
      toast({ kind: 'info', message: 'Nothing changed.' });
      return;
    }
    setBusy(true);
    const failed: string[] = [];
    for (const c of changes) {
      try {
        await setChannelAllocation(eventId, c.ch, c.tierId, c.n);
      } catch (err) {
        const tier = tiers.find((t) => t.id === c.tierId)?.name ?? 'ticket type';
        failed.push(`${tier} on ${LABEL[c.ch]}: ${err instanceof Error ? err.message.replace(/^exos_set_channel_allocation: /, '') : 'not saved'}`);
      }
    }
    // Prices after seats: a price needs the ticket type's row on that marketplace.
    for (const c of priceChanges) {
      try {
        await setChannelPrice(eventId, c.ch, c.tierId, c.price);
      } catch (err) {
        const tier = tiers.find((t) => t.id === c.tierId)?.name ?? 'ticket type';
        failed.push(`${tier} price on ${LABEL[c.ch]}: ${err instanceof Error ? err.message.replace(/^exos_set_channel_price: /, '') : 'not saved'}`);
      }
    }
    const saved: Record<string, MarketSplit> = {};
    for (const c of splitChanges) {
      try {
        await setMarketSplit(c.tierId, c.split);
        saved[c.tierId] = c.split;
      } catch (err) {
        const tier = tiers.find((t) => t.id === c.tierId)?.name ?? 'ticket type';
        failed.push(`${tier} split: ${err instanceof Error ? err.message : 'not saved'}`);
      }
    }
    const total = changes.length + priceChanges.length + splitChanges.length;
    setBusy(false);
    setDraft({});
    setPriceDraft({});
    setSplitDraft({});
    setSplitSaved({ ...splitSaved, ...saved });
    onSaved();
    if (failed.length) toast({ kind: 'error', message: failed.join(' · ') });
    else toast({ kind: 'success', message: `Marketplace seats, prices and splits saved (${total} change${total === 1 ? '' : 's'}).` });
  };

  const tone = { muted: 'text-white/40', info: 'text-white/60', ok: 'text-brand-primary', warn: 'text-amber-400' } as const;
  return (
    <div className="space-y-3">
      <h3 className="type text-[11px] text-white/60 uppercase tracking-widest">Marketplaces</h3>
      <p className="type text-xs text-white/50">
        The most each marketplace sells, per ticket type: GA on one, VIP on all, or 0 to keep a ticket type off a
        marketplace. "Same on all" copies the first column across. Each one holds only a few seats at a time (twice your max per order)
        and is topped up from the free seats as it sells, so the event is live everywhere while Exos sells the rest, and a
        seat is never on sale in two places. 0 takes the listing down and gives its seats back. The price under each
        number is what that marketplace lists it at: leave it blank for the ticket price. It can be higher, never lower
        than what Exos charges. "Split" says what a marketplace buyer can take from a listing: any number, any number
        that doesn't leave one seat behind, pairs only, or the whole listing, on every marketplace.
        {maxPerOrder
          ? ` One marketplace order can take at most ${maxPerOrder} (your max per order).`
          : ' Set a max per order to stop one marketplace order taking them all.'}
      </p>
      <div className="overflow-x-auto">
        <table className="w-full type text-xs text-white/80">
          <thead>
            <tr className="text-left text-white/50">
              <th className="py-2 pr-3 font-normal">Ticket type</th>
              {channels.map((ch) => <th key={ch} className="py-2 pr-3 font-normal">{LABEL[ch]}</th>)}
            </tr>
          </thead>
          <tbody>
            {tiers.map((t) => (
              <tr key={t.id} className="border-t border-white/10 align-top">
                <td className="py-2 pr-3">
                  <span className="text-white">{t.name}</span>
                  <span className="block text-white/40">{t.capacity} total · {t.price.toFixed(2)} on Exos</span>
                  <label className="mt-1 block text-white/50">
                    Split{' '}
                    <select
                      value={splitDraft[t.id] ?? splitNow(t)} disabled={busy}
                      onChange={(e) => setSplitDraft({ ...splitDraft, [t.id]: e.target.value as MarketSplit })}
                      aria-label={`How marketplace buyers can split ${t.name}`}
                      className="bg-black border border-white/20 px-1 py-0.5 text-white disabled:opacity-50"
                    >
                      {MARKET_SPLITS.map((s) => <option key={s} value={s}>{MARKET_SPLIT_LABEL[s]}</option>)}
                    </select>
                  </label>
                  {channels.length > 1 && (
                    <button
                      type="button" disabled={busy}
                      onClick={() => setDraft(sameOnAll(draft, channels, t.id, value(channels[0], t.id)))}
                      className="mt-1 text-[10px] uppercase tracking-widest text-white/50 hover:text-brand-primary disabled:opacity-40"
                      aria-label={`Use ${LABEL[channels[0]]}'s number for ${t.name} on every marketplace`}
                    >
                      Same on all
                    </button>
                  )}
                </td>
                {channels.map((ch) => {
                  const r = rowFor(ch, t.id);
                  const st = allocationCellStatus(r, ch);
                  const seats = r && (r.requested_qty ?? 0) > 0 ? formatSeatRanges(parseSeatRanges(r.internal_seats ?? null)) : '';
                  const pool = poolLine(r);
                  return (
                    <td key={ch} className="py-2 pr-3">
                      <input
                        type="number" min={0} inputMode="numeric" aria-label={`${t.name} seats on ${LABEL[ch]}`}
                        value={value(ch, t.id)} disabled={busy || r?.status === 'delisting'}
                        onChange={(e) => setDraft({ ...draft, [key(ch, t.id)]: e.target.value })}
                        className="w-20 bg-black border border-white/20 px-2 py-1 text-white disabled:opacity-50"
                      />
                      <input
                        type="text" inputMode="decimal" aria-label={`${t.name} price on ${LABEL[ch]}`}
                        placeholder={t.price.toFixed(2)} title="Price on this marketplace; blank = the ticket price"
                        value={priceValue(ch, t.id)} disabled={busy || r?.status === 'delisting'}
                        onChange={(e) => setPriceDraft({ ...priceDraft, [key(ch, t.id)]: e.target.value })}
                        className="mt-1 block w-20 bg-black border border-white/10 px-2 py-1 text-white placeholder:text-white/30 disabled:opacity-50"
                      />
                      {st && <span role="status" className={`block mt-1 ${tone[st.tone]}`}>{st.text}</span>}
                      {pool && <span className="block mt-1 text-white/50">{pool}</span>}
                      {seats && <span className="block mt-1 text-white/30">Internal seats {seats}</span>}
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <button type="button" onClick={save} disabled={busy}
        className="px-4 py-2 bg-brand-primary text-black text-[10px] font-black uppercase tracking-widest disabled:opacity-50">
        {busy ? 'Saving…' : 'Save marketplace seats, prices and splits'}
      </button>
    </div>
  );
}

/** The draft with this ticket type set to `value` on every marketplace ("Same on all"). */
export function sameOnAll(
  draft: Record<string, string>, channels: readonly string[], tierId: string, value: string,
): Record<string, string> {
  const next = { ...draft };
  for (const ch of channels) next[`${ch}:${tierId}`] = value;
  return next;
}
