// /group-pay/seat/:token — one friend's seat in a group buy (mig 20261108120000).
//
// Anyone with the link sees the event, the price, the group's deadline and how
// many seats are paid, and pays for exactly this seat through the normal
// checkout (signed in, or as a guest with an email). The ticket is theirs, its
// own order. Nothing about the other friends is shown or sent (nor the
// host's names for the seats). A price-step type shows the price the group
// locked; a timed type, the group's slot (mig 20261110110000).

import { useEffect, useState, type ReactNode } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Clock, Ticket, Users } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { getPublicEvent } from '../lib/events';
import { startCheckout } from '../lib/checkout';
import { buyerTierPrice } from '../lib/pricing';
import { formatCurrency, publicUrl } from '../lib/utils';
import { maskEmail } from '../lib/doorSearch';
import { slotIdLabel } from '../lib/slots';
import { formatCountdown, groupSeatPrice, seatPayable, secondsLeft, viewSeat, type SeatView } from '../lib/groupPay';

export default function GroupPaySeat() {
  const { token = '' } = useParams();
  const { user } = useAuth();
  const [view, setView] = useState<SeatView | null | undefined>(undefined);
  const [price, setPrice] = useState<number | null>(null);
  const [tierName, setTierName] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // The seat, refreshed every 15 s (a friend may pay meanwhile), and the clock.
  useEffect(() => {
    let alive = true;
    const load = () => viewSeat(token).then((v) => { if (alive) setView(v); }).catch(() => { if (alive) setView((cur) => cur ?? null); });
    void load();
    const poll = window.setInterval(load, 15_000);
    const tick = window.setInterval(() => setNow(Date.now()), 1000);
    return () => { alive = false; window.clearInterval(poll); window.clearInterval(tick); };
  }, [token]);

  // The price the event page shows for this ticket type (all-in), or the one
  // the group locked for a price-step type.
  const eventId = view?.eventId;
  const tierId = view?.tierId;
  const locked = view?.unitPriceCents ?? null;
  useEffect(() => {
    if (!eventId || !tierId) return undefined;
    let alive = true;
    getPublicEvent(eventId).then((ev) => {
      const tier = ev?.ticketTiers?.find((t) => t.id === tierId);
      if (!alive || !tier) return;
      setPrice(groupSeatPrice(tier, locked, buyerTierPrice(tier)));
      setTierName(tier.name);
    }).catch(() => undefined);
    return () => { alive = false; };
  }, [eventId, tierId, locked]);

  if (view === undefined) return <Shell><p className="text-slate-500">Loading…</p></Shell>;
  if (view === null) return <Shell><p className="text-slate-700 font-bold">This seat link isn't valid. Ask whoever sent it for a new one.</p></Shell>;

  const left = secondsLeft(view.deadline, view.serverNow, view.fetchedAt, now);
  const payable = seatPayable(view, left);
  const cur = view.event?.currency ?? 'USD';
  const when = view.event?.startsAt ? new Date(view.event.startsAt).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : null;

  const pay = async () => {
    const guest = !user;
    if (guest && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.trim())) { setErr('Enter the email your ticket should go to.'); return; }
    setBusy(true);
    setErr(null);
    try {
      const url = await startCheckout({
        eventId: view.eventId,
        tierId: view.tierId,
        quantity: 1,
        groupSeat: token,
        guestEmail: guest ? email.trim() : undefined,
        successUrl: publicUrl(`my-tickets?checkout=success${guest ? `&guest=1&to=${encodeURIComponent(maskEmail(email.trim()) ?? '')}` : ''}&session_id={CHECKOUT_SESSION_ID}`),
        cancelUrl: publicUrl(`group-pay/seat/${token}`),
      });
      window.location.href = url;
    } catch (e) {
      setErr((e as Error).message);
      setBusy(false);
      viewSeat(token).then((v) => setView(v)).catch(() => undefined);
    }
  };

  return (
    <Shell>
      {view.event ? (
        <div className="mb-6">
          <h2 className="text-xl font-black text-slate-900">{view.event.name}</h2>
          <p className="text-slate-500 text-sm">{[when, view.event.venueName].filter(Boolean).join(' · ')}</p>
        </div>
      ) : null}

      <div className="border-2 border-slate-900 rounded-2xl p-5 mb-4">
        <div className="flex items-center justify-between gap-3">
          <p className="font-black text-slate-900 flex items-center gap-2"><Ticket className="w-5 h-5" /> Seat {view.seatNo} of {view.seats}</p>
          {price !== null && <p className="font-black text-slate-900">{formatCurrency(price, cur)}</p>}
        </div>
        {tierName && <p className="text-xs text-slate-500 mt-1">{tierName}. The price includes every fee.</p>}
        {view.slotId && <p className="text-xs text-slate-500 mt-1" data-testid="seat-slot">Entry slot: {slotIdLabel(view.slotId)}</p>}
        <p className="text-xs text-slate-500 mt-3 flex items-center gap-2"><Users className="w-4 h-4" /> {view.paid} of {view.seats} paid</p>
        {view.groupStatus === 'open' && left > 0 && (
          <p className="text-sm font-black mt-2 flex items-center gap-2 text-amber-700" data-testid="seat-countdown">
            <Clock className="w-4 h-4" /> {formatCountdown(left)} left to pay
          </p>
        )}
      </div>

      {view.state === 'paid' && <Note>This seat is paid for. Its ticket is in the payer's My Tickets.</Note>}
      {view.state === 'covered' && <Note>The host covered this seat. Ask them for your ticket.</Note>}
      {view.state === 'covering' && <Note>The host is paying for the rest of the group right now.</Note>}
      {view.state === 'paying' && !view.mine && <Note>A friend is paying for this seat right now. If that's not you, ask the host for another link.</Note>}
      {(view.state === 'released' || view.groupStatus !== 'open' || left === 0) && view.state !== 'paid' && view.state !== 'covered' && (
        <Note>
          This group's time ran out, so the seat went back on sale.{' '}
          <Link className="underline font-bold" to={`/event/${view.eventId}`}>Buy on the event page</Link>
        </Note>
      )}
      {payable && (
        <div className="space-y-3">
          {!user && (
            <label className="block">
              <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Email for your ticket</span>
              <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com"
                className="w-full border-2 border-slate-200 rounded-xl px-3 py-3 font-bold text-sm focus:outline-none focus:border-brand-primary" />
            </label>
          )}
          <button type="button" disabled={busy} onClick={() => void pay()}
            className="w-full bg-slate-900 text-white rounded-xl py-4 font-black uppercase tracking-widest text-sm disabled:opacity-40">
            {busy ? 'Opening checkout…' : `Pay for my seat${price !== null ? ` · ${formatCurrency(price, cur)}` : ''}`}
          </button>
          <p className="text-xs text-slate-500">The ticket is yours: it goes to your account (or this email), on its own order.</p>
        </div>
      )}
      {!payable && view.state === 'waiting' && view.groupStatus === 'open' && left > 0 && left <= 60 && (
        <Note>Less than a minute left: there isn't time to pay for this seat now.</Note>
      )}
      {err && <p className="text-red-600 text-sm font-bold mt-3" role="alert">{err}</p>}
      {view.isHost && view.groupId && (
        <Link to={`/group-pay/${view.groupId}`} className="block mt-6 text-sm font-black text-brand-primary">Back to your group</Link>
      )}
    </Shell>
  );
}

function Note({ children }: { children: ReactNode }) {
  return <p className="bg-slate-100 rounded-xl p-4 text-sm text-slate-700 mb-3">{children}</p>;
}

function Shell({ children }: { children: ReactNode }) {
  return (
    <div className="max-w-xl mx-auto px-4 py-10">
      <h1 className="text-2xl font-black text-slate-900 mb-4">Your seat</h1>
      {children}
    </div>
  );
}
