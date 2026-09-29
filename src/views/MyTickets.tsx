import { useEffect, useState } from 'react';
import { useLocation, useNavigate, Link } from 'react-router-dom';
import { Ticket, Event, Transfer } from '../types';
import { useAuth } from '../context/AuthContext';
import {
  listMyTickets,
  listInboundTransfers,
  listOutboundTransfers,
  cancelTransfer,
} from '../lib/tickets';
import { Ticket as TicketIcon, Calendar, ArrowRight, UserPlus, Mail, Heart } from 'lucide-react';
import { format } from 'date-fns';
import { formatInTz } from '../lib/datetime';
import { motion } from 'motion/react';
import { useToast } from '../context/ToastContext';
import { listSavedEvents } from '../lib/saves';
import SaveEventButton from '../components/SaveEventButton';
import { useT } from '../context/LanguageContext';
import Dialog from '../components/Dialog';
import MyCalendarFeed from '../components/MyCalendarFeed';
import { trackCheckoutReturn } from '../lib/purchasePixel';
import {
  listMyRescheduleOffers,
  requestRescheduleRefund,
  releaseForReschedule,
  reasonText,
  type RescheduleOffer,
} from '../lib/rescheduleRefunds';
import { formatCents } from '../lib/refunds';

export default function MyTickets() {
  const { user, openAuth } = useAuth();
  // Back from a guest checkout (mig 20260928050000): tickets went by email.
  const [guestDone, setGuestDone] = useState(false);
  const location = useLocation();
  const navigate = useNavigate();
  const { toast } = useToast();
  const t = useT();
  const [tickets, setTickets] = useState<(Ticket & { event?: Event })[]>([]);
  const [groupedTickets, setGroupedTickets] = useState<{ [eventId: string]: (Ticket & { event?: Event })[] }>({});
  const [showReceipts, setShowReceipts] = useState<string | null>(null); // eventId
  const [pendingTransfers, setPendingTransfers] = useState<Transfer[]>([]);
  const [outboundTransfers, setOutboundTransfers] = useState<Transfer[]>([]);
  const [savedEvents, setSavedEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(true);
  // Date changes with a refund offer (mig 20260929150000): tickets this
  // account holds or paid for. Refunds go back to the card that paid.
  const [offers, setOffers] = useState<RescheduleOffer[]>([]);
  const [offerBusy, setOfferBusy] = useState<string | null>(null);

  const reloadOffers = async () => setOffers(await listMyRescheduleOffers());

  const actOnOffers = async (key: string, list: RescheduleOffer[]) => {
    const refunds = list.filter((o) => o.ok && o.kind === 'refund');
    const releases = list.filter((o) => o.ok && o.kind === 'release');
    if (refunds.length + releases.length === 0) return;
    const total = refunds.reduce((n, o) => n + o.amountCents, 0);
    const question = refunds.length > 0
      ? `Refund ${refunds.length} ticket${refunds.length === 1 ? '' : 's'} (${formatCents(total, refunds[0].currency)})? ` +
        'The money goes back to the card that paid, and the ticket stops working, also if you gave it to someone.'
      : `Give back ${releases.length} free ticket${releases.length === 1 ? '' : 's'}? It stops working and can't be undone.`;
    if (!window.confirm(question)) return;
    setOfferBusy(key);
    try {
      const results = [
        ...(refunds.length ? await requestRescheduleRefund({ ticketIds: refunds.map((o) => o.ticketId) }) : []),
        ...(releases.length ? await releaseForReschedule({ ticketIds: releases.map((o) => o.ticketId) }) : []),
      ];
      const failed = results.filter((r) => !r.ok);
      if (failed.length === 0) {
        toast({
          kind: 'success',
          title: refunds.length ? 'Refund on its way' : 'Ticket released',
          message: refunds.length
            ? 'It goes back to your card and can take 5 to 10 days to show up. We emailed you a receipt.'
            : 'Thanks for letting someone else have the spot.',
        });
      } else {
        toast({ kind: 'error', message: failed[0].error || reasonText(failed[0].reason) });
      }
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'That didn’t work. Try again.' });
    } finally {
      setOfferBusy(null);
      await reloadOffers();
    }
  };

  const handleCancelTransfer = async (transferId: string) => {
    // Confirmation lives outside the loading state so a user that backs out
    // doesn't see a brief loading flash.
    if (!window.confirm('Cancel this transfer? You will keep the ticket.')) return;
    try {
      // The RPC flips the transfer to 'cancelled' AND clears the ticket's
      // pendingTransferId lock atomically (server-side), so the wallet UI
      // and door-scan flow start honoring the ticket again immediately.
      await cancelTransfer(transferId);
      setOutboundTransfers((prev) => prev.filter((t) => t.id !== transferId));
      toast({ kind: 'success', message: t('tickets.transferCancelled') });
    } catch (err) {
      console.error('Cancel transfer failed:', err);
      toast({ kind: 'error', message: t('tickets.transferCancelFailed') });
    }
  };

  useEffect(() => {
    // Confirmation after a purchase, shown here rather than on the event page:
    // leaving an org's page can reload the app to drop its pixels
    // (lib/pixels.ts), which would swallow a toast raised before navigating.
    //   ?checkout=success — back from Stripe; stripe-webhook mints the tickets
    //   ?claimed=N        — a free claim that already minted N tickets
    const params = new URLSearchParams(location.search);
    const claimed = Number(params.get('claimed'));
    if (params.get('checkout') === 'success') {
      // Paid Purchase pixel, once per Stripe session. Async: it loads the
      // org's pixels after the replace below has stripped the session id
      // from the URL, so the vendors' PageView never sees it.
      void trackCheckoutReturn(params.get('session_id'));
    }
    if (params.get('checkout') === 'success' && params.get('guest') === '1') {
      setGuestDone(true);
    } else if (params.get('checkout') === 'success') {
      toast({ kind: 'success', title: 'Payment received', message: 'Your tickets will appear here in a moment.' });
    } else if (Number.isInteger(claimed) && claimed > 0) {
      toast({ kind: 'success', title: "You're in!", message: `${claimed} ticket${claimed === 1 ? '' : 's'} reserved.` });
    } else {
      return;
    }
    navigate('/my-tickets', { replace: true });
  }, [location.search, navigate, toast]);

  useEffect(() => {
    if (!user) return undefined;
    let cancelled = false;

    const load = async () => {
      try {
        // Tickets (with event joined) + both pending-transfer directions.
        // The transfer rows carry denormalised event title/image, so no
        // ticket/event dereference is needed (the old Firestore N+1 is gone).
        const [ticketsWithEvents, inbound, outbound, saved, dateOffers] = await Promise.all([
          listMyTickets(),
          listInboundTransfers(),
          listOutboundTransfers(),
          listSavedEvents(),
          listMyRescheduleOffers(),
        ]);
        if (cancelled) return;
        setOffers(dateOffers);

        setTickets(ticketsWithEvents);
        setSavedEvents(saved);

        const grouped = ticketsWithEvents.reduce((acc, t) => {
          if (!acc[t.eventId]) acc[t.eventId] = [];
          acc[t.eventId].push(t);
          return acc;
        }, {} as { [eventId: string]: (Ticket & { event?: Event })[] });

        // Sort each event's tickets so the scannable ones surface first.
        // Order: active+unlocked → in-transfer → used → voided, so the
        // cluster's "main" ticket (eventTickets[0]) is always usable at the
        // door even in a 4-pack with one claimed/used ticket mixed in.
        const sortRank = (t: Ticket & { event?: Event }) => {
          if (t.status === 'voided') return 3;
          if (t.status === 'used') return 2;
          if (t.pendingTransferId) return 1;
          return 0;
        };
        Object.values(grouped).forEach((arr) => arr.sort((a, b) => sortRank(a) - sortRank(b)));
        setGroupedTickets(grouped);

        setPendingTransfers(inbound);
        setOutboundTransfers(outbound);
      } catch (err) {
        if (!cancelled) {
          console.error('Failed to load tickets:', err);
          toast({ kind: 'error', message: t('tickets.loadFailed') });
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    };

    void load();
    return () => {
      cancelled = true;
    };
  }, [user, toast]);

  if (!user && guestDone) return (
    <div className="wall min-h-screen flex items-center justify-center p-8 text-center">
      <div className="max-w-md" role="status">
        <p className="type text-brand-primary uppercase tracking-widest text-[12px] mb-3">Payment received</p>
        <h1 className="disp text-4xl tracking-tight leading-none mb-4">Check your email</h1>
        <p className="text-white/70 mb-6">
          Your tickets are on their way{guestEmailHint() ? <> to <strong className="text-white">{guestEmailHint()}</strong></> : null}.
          Sign in with that email (we'll send a one-time code, no password) to see your QR codes here.
          Tickets can be forwarded to friends from the email.
        </p>
        <button onClick={() => openAuth('code', guestEmailHint() ?? '')} className="bg-brand-primary text-black font-black uppercase tracking-wider px-8 py-3">
          Sign in to see tickets
        </button>
      </div>
    </div>
  );
  if (!user) return (
    <div className="wall min-h-screen flex items-center justify-center p-20 text-center">
      <p className="type text-white/50 uppercase tracking-widest text-[12px]">{t('tickets.vaultHint')}</p>
    </div>
  );
  if (loading) return (
    <div className="wall min-h-screen flex items-center justify-center p-24 text-center">
      <p className="type text-brand-primary uppercase tracking-[0.3em] text-[12px] animate-pulse">{t('tickets.syncing')}</p>
    </div>
  );

  return (
    <div className="wall min-h-screen text-white">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-12 relative z-10">
        {/* HEADER */}
        <div className="flex flex-col md:flex-row justify-between items-start md:items-end mb-14 gap-6">
          <div className="relative">
            <p className="type text-brand-primary text-[12px] uppercase tracking-widest mb-2">{t('tickets.kicker')}</p>
            <h1 className="disp text-6xl md:text-7xl tracking-tight leading-none" style={{ transform: 'skewX(-4deg)' }}>MY <span className="neon">TICKETS</span></h1>
            {Object.keys(groupedTickets).length > 0 && (
              <span className="marker absolute -right-6 -top-3 text-brand-secondary text-lg rotate-[6deg] hidden md:block">{Object.keys(groupedTickets).length} live ✦</span>
            )}
          </div>
          <div className="flex border border-white/10 bg-white/5">
            <button className="disp px-8 py-2.5 text-lg tracking-wide bg-brand-primary text-black">{t('tickets.active')}</button>
            <button className="disp px-8 py-2.5 text-lg tracking-wide text-white/60 hover:text-white transition-colors">{t('tickets.archive')}</button>
          </div>
        </div>

        {/* Personal calendar feed: tickets + followed organizers (docs/calendar.md) */}
        <MyCalendarFeed className="mb-14" />

        {/* Transfer Notifications */}
        {(pendingTransfers.length > 0 || outboundTransfers.length > 0) && (
          <div className="mb-16 space-y-12">
            {pendingTransfers.length > 0 && (
              <div>
                <h2 className="type text-[12px] text-brand-primary uppercase tracking-widest mb-6 flex items-center gap-3">
                  <span className="w-2 h-2 bg-brand-primary rounded-full animate-ping"></span>
                  incoming tickets ({pendingTransfers.length})
                </h2>
                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                  {pendingTransfers.map((trans) => (
                    <div key={trans.id} className="bg-brand-primary p-7 relative overflow-hidden">
                       <div className="flex items-center gap-5 mb-7">
                          <div className="w-14 h-14 bg-black flex items-center justify-center shrink-0">
                             <Mail className="text-brand-primary w-6 h-6" />
                          </div>
                          <div className="min-w-0">
                             <p className="type text-[11px] text-black/70 uppercase tracking-widest leading-none mb-1">ref id: {trans.id.slice(0,6)}</p>
                             <h3 className="disp text-2xl text-black leading-none tracking-tight truncate">{trans.eventTitle}</h3>
                          </div>
                       </div>
                       <Link
                         to={`/claim/${trans.id}`}
                         className="disp block w-full bg-black text-white text-center py-3 text-lg tracking-wide hover:bg-white hover:text-black transition-colors"
                       >
                         CLAIM TICKET
                       </Link>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {outboundTransfers.length > 0 && (
              <div>
                <h2 className="type text-[12px] text-white/60 uppercase tracking-widest mb-6 flex items-center gap-3">
                  <span className="w-2 h-2 bg-white/30 rounded-full animate-pulse"></span>
                  pending outbound transfers ({outboundTransfers.length})
                </h2>
                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                  {outboundTransfers.map((trans) => (
                    <div key={trans.id} className="bg-[#111] border border-white/10 p-7 group">
                       <div className="flex items-center gap-5 mb-7">
                          <div className="w-14 h-14 bg-white/5 border border-white/10 flex items-center justify-center shrink-0">
                             <Mail className="text-white/60 w-6 h-6 group-hover:text-brand-primary transition-colors" />
                          </div>
                          <div className="min-w-0">
                             <p className="type text-[11px] text-white/60 uppercase tracking-widest leading-none mb-1">transfer id: {trans.id.slice(0,6)}</p>
                             <h3 className="disp text-2xl text-white leading-none tracking-tight truncate">{trans.eventTitle}</h3>
                             <p className="type text-[11px] text-brand-primary uppercase tracking-widest mt-1">to: {trans.receiverEmail.split('@')[0]}...</p>
                          </div>
                       </div>
                       <button
                         onClick={() => handleCancelTransfer(trans.id)}
                         className="disp w-full bg-white/5 border border-white/10 text-white/50 py-3 text-lg tracking-wide hover:bg-white hover:text-black transition-colors"
                       >
                         CANCEL TRANSFER
                       </button>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}

        {/* Date changed: refund or give back, until the organizer's deadline. */}
        {offers.length > 0 && (
          <section className="mb-16" aria-labelledby="date-changes-title">
            <h2 id="date-changes-title" className="type text-[12px] text-brand-primary uppercase tracking-widest mb-6">
              date changed · refunds available
            </h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              {offersByEvent(offers).map(([eventId, list]) => {
                const first = list[0];
                const when = (d: Date | null) => (d ? formatInTz(d, first.timezone ?? undefined, { dateStyle: 'medium', timeStyle: 'short' }) : 'TBA');
                const actionable = list.filter((o) => o.ok && (o.kind === 'refund' || o.kind === 'release'));
                const refundTotal = actionable.filter((o) => o.kind === 'refund').reduce((n, o) => n + o.amountCents, 0);
                return (
                  <div key={eventId} className="bg-[#111] border border-white/10 p-7">
                    <h3 className="disp text-2xl tracking-tight text-white leading-none mb-2">{first.eventName}</h3>
                    <p className="text-sm text-white/60 mb-1">
                      <span className="line-through">{when(first.oldStartsAt)}</span> → <strong className="text-white">{when(first.newStartsAt)}</strong>
                    </p>
                    <p className="type text-[11px] text-white/60 uppercase tracking-widest mb-5">
                      refunds until {when(first.refundDeadline)}
                    </p>
                    <ul className="space-y-2 mb-5">
                      {list.map((o) => (
                        <li key={o.ticketId} className="text-sm text-white/80 flex flex-wrap justify-between gap-2">
                          <span>
                            {o.tierName || 'Ticket'}
                            {!o.mine && <span className="text-white/50"> (you gave this one away)</span>}
                          </span>
                          <span className={o.ok ? 'text-brand-primary' : 'text-white/50 text-xs basis-full'}>
                            {o.ok
                              ? o.kind === 'refund' ? formatCents(o.amountCents, o.currency) : 'free: give back'
                              : reasonText(o.requestStatus === 'claimed' || o.requestStatus === 'pending' ? 'in-progress' : o.reason)}
                          </span>
                        </li>
                      ))}
                    </ul>
                    {actionable.length > 0 && (
                      <button
                        type="button"
                        disabled={offerBusy !== null}
                        onClick={() => void actOnOffers(eventId, actionable)}
                        className="disp w-full bg-brand-primary text-black py-3 text-lg tracking-wide hover:bg-white transition-colors disabled:opacity-50"
                      >
                        {offerBusy === eventId
                          ? 'WORKING…'
                          : refundTotal > 0
                            ? `GET A REFUND (${formatCents(refundTotal, actionable[0].currency)})`
                            : 'RELEASE MY TICKET'}
                      </button>
                    )}
                  </div>
                );
              })}
            </div>
          </section>
        )}

        {tickets.length === 0 ? (
          <div className="text-center py-40 border border-dashed border-white/20">
            <TicketIcon className="w-24 h-24 text-white/5 mx-auto mb-10" />
            <p className="type text-white/60 mb-12 uppercase tracking-widest text-[12px]">{t('tickets.empty')}</p>
            <Link to="/" className="disp inline-flex items-center bg-brand-primary text-black px-8 py-3 text-lg tracking-wide hover:bg-white transition-colors">
              FIND EVENTS
            </Link>
          </div>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-px bg-white/10 border border-white/10">
            {Object.entries(groupedTickets).map(([eventId, tickets]) => {
              const eventTickets = tickets as (Ticket & { event?: Event })[];
              const mainTicket = eventTickets[0];
              const event = mainTicket.event;
              return (
                <motion.div
                  key={eventId}
                  className="bg-[#111] group relative"
                >
                  <Link to={`/ticket/${mainTicket.id}`} className="block h-56 relative overflow-hidden">
                    <img
                      src={event?.image || 'https://images.unsplash.com/photo-1492684223066-81342ee5ff30?q=80&w=600'}
                      alt=""
                      className="xerox w-full h-full object-cover duration-700"
                    />
                    <div className="absolute inset-0 bg-gradient-to-t from-[#111] via-transparent to-transparent"></div>
                    <span className="disp absolute top-4 right-4 bg-brand-primary text-black px-2.5 py-0.5 text-base tracking-wide">
                      {eventTickets.length} {eventTickets.length === 1 ? 'PASS' : 'PASSES'}
                    </span>
                    <h3 className="disp absolute bottom-5 left-6 right-6 text-3xl text-white uppercase tracking-tight leading-[0.9] group-hover:neon transition-all">{event?.title}</h3>
                  </Link>

                  <div className="p-6">
                    <div className="flex justify-between items-end mb-7">
                      <div>
                        <p className="type text-[11px] text-white/60 uppercase tracking-widest mb-1">{t('tickets.date')}</p>
                        <p className="disp text-lg text-white tracking-wide">{event?.date ? formatInTz(event.date.toDate(), event.timezone, { month: 'short', day: 'numeric', year: 'numeric' }) : 'N/A'}</p>
                      </div>
                      <div className="text-right">
                        <p className="type text-[11px] text-white/60 uppercase tracking-widest mb-1">{t('tickets.passes')}</p>
                        <span className="stamp neon text-base">{eventTickets.length} ACTIVE</span>
                      </div>
                    </div>

                    <div className="flex gap-3">
                      <Link
                        to={`/ticket/${mainTicket.id}`}
                        className="disp flex-1 text-center bg-white text-black py-3 text-base tracking-wide hover:bg-brand-primary transition-colors"
                      >
                        OPEN PASSES
                      </Link>
                      <button
                        onClick={() => setShowReceipts(eventId)}
                        className="disp flex-1 border border-white/20 text-white/60 py-3 text-base tracking-wide hover:border-white hover:text-white transition-colors"
                      >
                        RECEIPTS
                      </button>
                    </div>
                  </div>

                </motion.div>
              );
            })}
          </div>
        )}

        {/* Saved Events — the buyer wishlist. Events the user hearted from the
            event page. Un-hearting here drops the card immediately. */}
        {savedEvents.length > 0 && (
          <div className="mt-20">
            <h2 className="type text-[12px] text-brand-primary uppercase tracking-widest mb-6 flex items-center gap-3">
              <Heart className="w-3.5 h-3.5" fill="currentColor" aria-hidden="true" />
              saved events ({savedEvents.length})
            </h2>
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-px bg-white/10 border border-white/10">
              {savedEvents.map((ev) => (
                <div key={ev.id} className="bg-[#111] group relative">
                  <Link to={`/event/${ev.id}`} className="block h-44 relative overflow-hidden">
                    <img
                      src={ev.image || 'https://images.unsplash.com/photo-1492684223066-81342ee5ff30?q=80&w=600'}
                      alt=""
                      className="xerox w-full h-full object-cover duration-700"
                    />
                    <div className="absolute inset-0 bg-gradient-to-t from-[#111] via-transparent to-transparent"></div>
                    <h3 className="disp absolute bottom-5 left-6 right-6 text-2xl text-white uppercase tracking-tight leading-[0.9] group-hover:neon transition-all">{ev.title}</h3>
                  </Link>
                  <div className="p-6 flex items-center justify-between gap-4">
                    <div>
                      <p className="type text-[11px] text-white/60 uppercase tracking-widest mb-1">{t('tickets.date')}</p>
                      <p className="disp text-lg text-white tracking-wide">
                        {ev.date ? formatInTz(ev.date.toDate(), ev.timezone, { month: 'short', day: 'numeric', year: 'numeric' }) : 'TBA'}
                      </p>
                    </div>
                    <SaveEventButton
                      eventId={ev.id}
                      variant="chip"
                      initialSaved
                      onChange={(saved) => {
                        if (!saved) setSavedEvents((prev) => prev.filter((e) => e.id !== ev.id));
                      }}
                    />
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>

      {/* Receipts Modal */}
      <Dialog
        open={!!showReceipts}
        onClose={() => setShowReceipts(null)}
        labelledBy="receipts-title"
        backdropClassName="bg-black/90"
        className="bg-[#111] border border-white/10 w-full max-w-2xl max-h-[80vh] overflow-y-auto"
      >
              <div className="p-8 border-b border-white/5 flex justify-between items-center bg-black">
                 <h2 id="receipts-title" className="disp text-2xl tracking-tight">{t('tickets.history')}</h2>
                 <button onClick={() => setShowReceipts(null)} className="type text-white/60 hover:text-white text-[11px] uppercase tracking-widest focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary">{t('tickets.close')}</button>
              </div>
              <div className="p-8 space-y-6">
                 {showReceipts && (() => {
                   const eventTickets = groupedTickets[showReceipts];
                   const receiptsMap = new Map<string, { tickets: typeof eventTickets, firstTicket: typeof eventTickets[0] }>();
                   eventTickets.forEach(t => {
                     const key = t.orderId || t.id;
                     if (!receiptsMap.has(key)) {
                        receiptsMap.set(key, { tickets: [], firstTicket: t });
                     }
                     receiptsMap.get(key)!.tickets.push(t);
                   });
                   return Array.from(receiptsMap.values()).map(({ tickets, firstTicket }) => (
                    <div key={firstTicket.id} className="bg-white/5 p-6 border border-white/10 flex flex-col md:flex-row justify-between items-start md:items-center gap-6 group hover:border-brand-primary transition-all">
                       <div>
                          <p className="type text-[11px] text-brand-primary uppercase tracking-widest mb-1">receipt id: {firstTicket.orderId?.slice(0, 8) || 'LEGACY_SYNC'}</p>
                          <h4 className="disp text-2xl tracking-tight text-white">
                             {firstTicket.tierName || 'GENERAL'} <span className="type text-white/60 text-xs ml-2 normal-case tracking-normal">× {tickets.length}</span>
                          </h4>
                          <p className="type text-[11px] text-white/60 uppercase tracking-widest mt-1">{firstTicket.purchaseDate ? format(firstTicket.purchaseDate.toDate(), 'PPP p') : 'N/A'}</p>
                       </div>
                       <div className="flex items-center space-x-4 w-full md:w-auto">
                          <Link
                            to={`/ticket/${firstTicket.id}`}
                            className="disp flex-1 md:flex-none px-6 py-3 bg-white text-black text-base tracking-wide hover:bg-brand-primary transition-colors text-center"
                          >
                            OPEN PASSES
                          </Link>
                       </div>
                    </div>
                   ));
                 })()}
              </div>
      </Dialog>
   </div>
  );
}

function offersByEvent(offers: RescheduleOffer[]): [string, RescheduleOffer[]][] {
  const m = new Map<string, RescheduleOffer[]>();
  for (const o of offers) m.set(o.eventId, [...(m.get(o.eventId) ?? []), o]);
  return [...m.entries()];
}

function guestEmailHint(): string | null {
  try { return localStorage.getItem('exos.guestEmail'); } catch { return null; }
}
