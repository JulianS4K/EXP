// /group-pay/:groupId — the host's group buy (mig 20261108120000).
//
// One link per seat (text it from your own phone, or copy it), each seat's
// state live (waiting / paying / paid / released), the 30-minute countdown,
// "Pay my seat" through a seat link, "Cover the rest" (one checkout for every
// unpaid seat; you can then split or transfer them, /split/:sessionId) and
// "End the group" (unpaid seats back on sale now).

import { useEffect, useState, type ReactNode } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Clock, Copy, MessageSquare } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { getPublicEvent } from '../lib/events';
import { startCheckout } from '../lib/checkout';
import { buyerTierPrice } from '../lib/pricing';
import { formatCurrency, publicUrl } from '../lib/utils';
import {
  cancelGroup, coverableSeats, formatCountdown, friendsPayingNow, getGroup, seatLabel, seatMessage, seatSmsUrl, secondsLeft,
  type GroupBuy, type SeatState,
} from '../lib/groupPay';

const chip: Record<SeatState, string> = {
  waiting: 'bg-amber-100 text-amber-800',
  paying: 'bg-sky-100 text-sky-800',
  covering: 'bg-sky-100 text-sky-800',
  paid: 'bg-emerald-100 text-emerald-800',
  covered: 'bg-emerald-100 text-emerald-800',
  released: 'bg-slate-100 text-slate-500',
};

export default function GroupPayHost() {
  const { groupId = '' } = useParams();
  const { user } = useAuth();
  const { toast } = useToast();
  const [g, setG] = useState<GroupBuy | null>(null);
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [title, setTitle] = useState('your event');
  const [price, setPrice] = useState<number | null>(null);
  const [currency, setCurrency] = useState('USD');
  const [now, setNow] = useState(Date.now());
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!user) return undefined;
    let alive = true;
    const load = () => getGroup(groupId).then((x) => { if (alive) setG(x); }).catch((e) => { if (alive) setLoadErr((e as Error).message); });
    void load();
    const poll = window.setInterval(load, 5000);
    const tick = window.setInterval(() => setNow(Date.now()), 1000);
    return () => { alive = false; window.clearInterval(poll); window.clearInterval(tick); };
  }, [groupId, user]);

  const eventId = g?.eventId;
  const tierId = g?.tierId;
  useEffect(() => {
    if (!eventId) return undefined;
    let alive = true;
    getPublicEvent(eventId).then((ev) => {
      if (!alive || !ev) return;
      setTitle(ev.title);
      setCurrency(ev.currency || 'USD');
      const tier = ev.ticketTiers?.find((t) => t.id === tierId);
      if (tier) setPrice(buyerTierPrice(tier));
    }).catch(() => undefined);
    return () => { alive = false; };
  }, [eventId, tierId]);

  if (!user) return <Shell><p className="text-slate-500">Sign in with the account that started the group.</p></Shell>;
  if (loadErr) return <Shell><p className="text-red-600 font-bold">{loadErr}</p></Shell>;
  if (!g) return <Shell><p className="text-slate-500">Loading…</p></Shell>;

  const left = secondsLeft(g.deadline, g.serverNow, g.fetchedAt, now);
  const open = g.status === 'open' && left > 0;
  const money = (n: number) => formatCurrency(n, currency);
  const rest = coverableSeats(g);
  const payingNow = friendsPayingNow(g);
  const message = (seatNo: number, path: string) => seatMessage({
    eventTitle: title, seatNo, url: publicUrl(path), minutesLeft: left / 60, priceLabel: price !== null ? money(price) : null,
  });

  const cover = async () => {
    if (payingNow > 0 && !window.confirm(`${payingNow} friend${payingNow === 1 ? ' is' : 's are'} paying right now. Covering takes their seat${payingNow === 1 ? '' : 's'} too; whoever pays first gets it and the other payment is refunded. Cover anyway?`)) return;
    setBusy(true);
    try {
      const url = await startCheckout({
        eventId: g.eventId, tierId: g.tierId, quantity: rest.length, groupCover: g.id,
        successUrl: publicUrl('my-tickets?checkout=success&session_id={CHECKOUT_SESSION_ID}'),
        cancelUrl: publicUrl(`group-pay/${g.id}`),
      });
      window.location.href = url;
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
      setBusy(false);
      getGroup(groupId).then(setG).catch(() => undefined);
    }
  };

  const end = async () => {
    if (!window.confirm('End the group now? Every unpaid seat goes back on sale.')) return;
    try { setG(await cancelGroup(g.id)); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  };

  return (
    <Shell>
      <p className="text-slate-500 text-sm mb-4">
        {title}: {g.quantity} seats{price !== null ? ` at ${money(price)} each` : ''}. Each friend pays for their own seat with their link.
      </p>
      <div className="border-2 border-slate-900 rounded-2xl p-4 mb-6 flex items-center justify-between gap-3">
        <div>
          <p className="font-black text-slate-900">{g.counts.paid} of {g.quantity} paid</p>
          <p className="text-xs text-slate-500">{g.counts.paying > 0 ? `${g.counts.paying} paying now · ` : ''}{g.counts.waiting} waiting{g.counts.released ? ` · ${g.counts.released} released` : ''}</p>
        </div>
        {open ? (
          <p className="font-black text-amber-700 flex items-center gap-2" data-testid="group-countdown"><Clock className="w-4 h-4" />{formatCountdown(left)}</p>
        ) : (
          <p className="text-xs font-black uppercase tracking-widest text-slate-400">{g.status === 'cancelled' ? 'Ended' : 'Closed'}</p>
        )}
      </div>

      <ul className="space-y-3 mb-6">
        {g.seats.map((s) => (
          <li key={s.id} className="border border-slate-200 rounded-2xl p-4">
            <div className="flex items-center justify-between gap-3">
              <p className="font-bold text-slate-900">Seat {s.seatNo}</p>
              <span className={`text-[10px] font-black uppercase tracking-widest rounded-full px-2 py-1 ${chip[s.state]}`}>
                {s.orderStatus === 'refunded' ? 'Refunded' : seatLabel(s.state)}
              </span>
            </div>
            {open && (s.state === 'waiting' || s.state === 'paying') && (
              <div className="flex flex-wrap gap-2 mt-3">
                <a href={seatSmsUrl(message(s.seatNo, s.path))}
                  className="flex items-center gap-1 text-xs font-black uppercase tracking-widest border border-slate-200 rounded-lg px-3 py-2">
                  <MessageSquare className="w-4 h-4" /> Text
                </a>
                <button type="button"
                  onClick={() => { void navigator.clipboard?.writeText(publicUrl(s.path)); toast({ kind: 'info', message: 'Link copied.' }); }}
                  className="flex items-center gap-1 text-xs font-black uppercase tracking-widest border border-slate-200 rounded-lg px-3 py-2">
                  <Copy className="w-4 h-4" /> Copy link
                </button>
                {s.state === 'waiting' && (
                  <Link to={s.path} className="flex items-center gap-1 text-xs font-black uppercase tracking-widest border border-slate-200 rounded-lg px-3 py-2">
                    Pay my seat
                  </Link>
                )}
              </div>
            )}
          </li>
        ))}
      </ul>

      {open && g.canCover && rest.length > 0 && (
        <button type="button" disabled={busy} onClick={() => void cover()}
          className="w-full bg-slate-900 text-white rounded-xl py-4 font-black uppercase tracking-widest text-xs disabled:opacity-40 mb-3">
          {busy ? 'Opening checkout…' : `Cover the rest: ${rest.length} seat${rest.length === 1 ? '' : 's'}${price !== null ? `, ${money(price * rest.length)}` : ''}`}
        </button>
      )}
      {open && (
        <button type="button" onClick={() => void end()} className="w-full text-xs font-black uppercase tracking-widest text-slate-500 py-3">
          End the group now
        </button>
      )}
      <p className="text-xs text-slate-400 mt-4">
        Unpaid seats go back on sale when the time runs out. Covered seats are yours: send them on from My Tickets, or split
        the cost with friends afterwards.
      </p>
    </Shell>
  );
}

function Shell({ children }: { children: ReactNode }) {
  return (
    <div className="max-w-xl mx-auto px-4 py-10">
      <Link to="/my-tickets" className="inline-flex items-center gap-2 text-slate-500 text-sm font-bold mb-6">
        <ArrowLeft className="w-4 h-4" /> My Tickets
      </Link>
      <h1 className="text-2xl font-black text-slate-900 mb-2">Pay separately</h1>
      {children}
    </div>
  );
}
