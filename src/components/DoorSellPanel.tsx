// The door app's Sell tab (mig 20261107100000, docs/pos.md "Walk-up sales").
// Door staff sell a ticket at the door for cash or as a comp, then hand it
// over: a one-time QR on this screen for the buyer to photograph, paper from
// any ticket printer, or email. Recent sales can be voided the same night;
// owners and managers refund (with an override after a scan). The cash
// drawer opens, pays out and closes here too.
//
// Phone first: one column, big tap targets (at least 48px), the total and the
// change in large type. Card at the door (mig 20261107130000): the Card button
// works when the server's switch (EXOS_POS_CARD) is on and the org has a
// reader; pick the reader, "Charge $X on reader", and the screen polls until
// the reader captured, declined or was cancelled. The card is handled by the
// reader: no card field, no script, nothing that could touch card data here
// (docs/pci.md). Owners and managers add a reader by the code it shows.
// TODO(native app, docs/pos.md "Card at the door"): Tap to Pay on iPhone stays
// hidden until the native wrapper (Terminal iOS SDK + Apple's entitlement)
// exists; it will use connection_token and card_payment mode "sdk".
//
// Checkout questions (mig 20261108110000): the event's required questions are
// required at the door too. While one is unanswered the sale button waits and
// "Skip questions" sells anyway: the seller's explicit choice, logged on the
// server (exos_pos_question_skips), so a queue never stalls on a form.
//
// Every rule is enforced in SQL (exos-pos → exos_pos_*); this screen only
// mirrors them (lib/pos walkup.ts) to show the right buttons.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Banknote, CreditCard, Gift, Loader2, Mail, Minus, Plus, Printer, QrCode, RotateCcw, Ticket, Wallet } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { useLanguage } from '../context/LanguageContext';
import { formatCents } from '../lib/refunds';
import { parseCash } from '../lib/drawerRecount';
import {
  CARD_POLL_GIVE_UP_MS, CARD_POLL_MS, cardStateDone, cardStateText, changeDue, doorQuestions, missingAnswersText, quickCash, reverseOption,
  walkupMissingRequired, walkupQuote, WALKUP_CARD_MESSAGE, type CardSaleState,
} from '../lib/pos';
import {
  beginCardSale, cancelCardSale, cardStatus, chargeOnReader, closeDrawer, emailSale, getRecentSales, getWalkupCatalog,
  newOrderKey, openDrawer, paidOut, posErrorText, refundSale, registerReader, saleCodes, sellWalkup, setupCardLocation,
  ticketsPdf, voidSale, type CardProgress, type WalkupCatalog, type WalkupOrder,
} from '../lib/posWalkup';
import { answersBody, EMPTY_DRAFT, hasQuestions, ticketTiersFor, type AnswerDraft } from '../lib/checkoutQuestions';
import { qrSvg } from '../../supabase/functions/_shared/print/qr.ts';
import type { PrintTicket } from '../../supabase/functions/_shared/print/tickets.ts';
import CheckoutQuestionsForm from './CheckoutQuestionsForm';
import KioskSetupPanel from './KioskSetupPanel'; // claude/exos-kiosk

const BIG = 'min-h-[52px] px-4 rounded-xl text-sm font-black uppercase tracking-widest';
const INPUT = 'w-full min-h-[48px] border border-slate-300 rounded-xl px-3 text-base bg-white';

function downloadPdf(bytes: Uint8Array, name: string) {
  const url = URL.createObjectURL(new Blob([bytes as BlobPart], { type: 'application/pdf' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 30_000);
}

export default function DoorSellPanel({ eventId }: { eventId: string }) {
  const { toast } = useToast();
  // The Sell tab in the device's language (lib/i18n/pos.ts); English keeps the shared texts.
  const { t, lang } = useLanguage();
  const cardText = (state: CardSaleState, decline?: string | null) =>
    lang === 'en' ? cardStateText(state, decline) : t(`pos.card.${state}`);
  const missingText = (m: typeof missing) => lang === 'en'
    ? `${missingAnswersText(m)}. Ask them, or skip the questions.`
    : t('pos.missing', { n: m.length, names: m.slice(0, 3).map((x) => (x.ticket ? `${x.label} (${t('questions.ticket', { n: x.ticket })})` : x.label)).join(', ') });
  const [cat, setCat] = useState<WalkupCatalog | null>(null);
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [sales, setSales] = useState<WalkupOrder[]>([]);
  const [tierId, setTierId] = useState<string | null>(null);
  const [qty, setQty] = useState(1);
  const [payment, setPayment] = useState<'cash' | 'comp' | 'card'>('cash');
  const [readerId, setReaderId] = useState<string | null>(null);
  // A card sale under way: the pending order and where the reader is.
  const [cardSale, setCardSale] = useState<{ order: WalkupOrder; state: CardSaleState; startedAt: number; polls: number } | null>(null);
  // Adding a reader (owner / manager).
  const [rdCode, setRdCode] = useState('');
  const [rdLabel, setRdLabel] = useState('Door reader');
  const [addr, setAddr] = useState({ line1: '', city: '', state: '', postal_code: '', country: 'US' });
  const [received, setReceived] = useState<number | null>(null);
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [draft, setDraft] = useState<AnswerDraft>(EMPTY_DRAFT);
  const [showQs, setShowQs] = useState(false);
  const [drawerId, setDrawerId] = useState<string | null>(null);
  const [orderKey, setOrderKey] = useState(newOrderKey);
  const [busy, setBusy] = useState(false);
  // After a sale: the order and its codes (the QR on screen).
  const [done, setDone] = useState<WalkupOrder | null>(null);
  const [codes, setCodes] = useState<PrintTicket[] | null>(null);
  const [codeAt, setCodeAt] = useState(0);
  const [sendTo, setSendTo] = useState('');
  // Drawer forms.
  const [floatText, setFloatText] = useState('100');
  const [poAmount, setPoAmount] = useState('');
  const [poReason, setPoReason] = useState('');
  const [countText, setCountText] = useState('');

  const load = useCallback(async () => {
    try {
      const c = await getWalkupCatalog(eventId);
      setCat(c);
      setLoadErr(null);
      // Only ever this member's own drawer by default; an owner / manager picks another one by hand.
      setDrawerId((cur) => (cur && c.drawers.some((d) => d.id === cur) ? cur : c.drawers.find((d) => d.mine)?.id ?? null));
      setTierId((cur) => cur ?? c.tiers.find((t) => t.remaining === null || t.remaining > 0)?.tier_id ?? null);
      const readers = c.card.connected ? c.card.readers ?? [] : [];
      setReaderId((cur) => (cur && readers.some((r) => r.device_id === cur) ? cur : readers[0]?.device_id ?? null));
      if (!c.card.connected) setPayment((cur) => (cur === 'card' ? 'cash' : cur));
      setSales(await getRecentSales(eventId, 15));
    } catch (e) {
      setLoadErr(posErrorText(e));
    }
  }, [eventId]);
  useEffect(() => { void load(); }, [load]);

  const tier = cat?.tiers.find((t) => t.tier_id === tierId) ?? null;
  const currency = cat?.event.currency ?? 'USD';
  const money = (c: number) => formatCents(c, currency);
  const quote = useMemo(() => tier ? walkupQuote({
    unitCents: tier.price_cents, quantity: qty, compQuantity: payment === 'comp' ? qty : 0,
    tax: tier.tax ? { ratePercent: tier.tax.rate_percent, priceIncludesTax: tier.tax.price_includes_tax } : null,
  }) : null, [tier, qty, payment]);
  const ticketTiers = useMemo(() => (tierId ? ticketTiersFor(tierId, qty) : []), [tierId, qty]);
  const asks = cat && tierId ? hasQuestions(cat.questions, ticketTiers) : false;
  // Required answers still missing (shown questions only; hidden-from-checkout ones never required).
  const missing = useMemo(
    () => (cat && asks ? walkupMissingRequired(cat.questions, ticketTiers, answersBody(cat.questions, ticketTiers, draft) ?? {}) : []),
    [cat, asks, ticketTiers, draft]);
  const maxQty = Math.max(1, Math.min(10, tier?.remaining ?? 10));
  const drawer = cat?.drawers.find((d) => d.id === drawerId) ?? null;
  const needsDrawer = payment === 'cash' && (quote?.cashDueCents ?? 0) > 0;
  const readers = cat?.card.connected ? cat.card.readers ?? [] : [];
  const reader = readers.find((r) => r.device_id === readerId) ?? null;
  const change = received !== null && quote ? changeDue(quote.cashDueCents, received) : null;

  const resetSale = () => {
    setQty(1); setReceived(null); setName(''); setEmail(''); setDraft(EMPTY_DRAFT); setShowQs(false);
    setOrderKey(newOrderKey());
  };

  const sell = async (skipQuestions = false) => {
    if (!cat || !tier || !quote) return;
    if (needsDrawer && !drawer) { toast({ kind: 'error', message: t('pos.toastNeedDrawer') }); return; }
    setBusy(true);
    try {
      const o = await sellWalkup({
        eventId, tierId: tier.tier_id, quantity: qty, orderKey, payment,
        compQuantity: payment === 'comp' ? qty : 0, drawerId: needsDrawer ? drawer?.id : null,
        buyerName: name, buyerEmail: email, answers: asks ? answersBody(cat.questions, ticketTiers, draft) : undefined,
        skipQuestions: skipQuestions && missing.length > 0,
      });
      setDone(o);
      setCodes(null);
      setCodeAt(0);
      setSendTo(o.buyer_email ?? '');
      resetSale();
      toast({ kind: 'success', message: `${t('pos.toastSold', { qty: o.quantity, tier: o.tier_name })}${o.questions_skipped ? ' (questions skipped)' : ''}` });
      void load();
    } catch (e) {
      // The same key retries the same sale; a refusal keeps it for a fix and retry.
      toast({ kind: 'error', message: posErrorText(e) });
    } finally {
      setBusy(false);
    }
  };

  // A finished card sale: hand the tickets over like a cash sale, or say why not.
  const finishCard = useCallback((r: CardProgress) => {
    setCardSale(null);
    if (r.state === 'succeeded' && r.order) {
      setDone(r.order);
      setCodes(null);
      setCodeAt(0);
      setSendTo(r.order.buyer_email ?? '');
      toast({ kind: 'success', message: t('pos.toastPaidCard', { qty: r.order.quantity, tier: r.order.tier_name }) });
    } else {
      toast({ kind: 'error', message: cardText(r.state, r.decline_code) });
    }
    setQty(1); setReceived(null); setName(''); setEmail(''); setDraft(EMPTY_DRAFT); setShowQs(false);
    setOrderKey(newOrderKey());
    void load();
  }, [toast, load]);

  const cancelCard = useCallback(async (orderId: string, reason: string) => {
    try {
      finishCard(await cancelCardSale(orderId, reason));
    } catch (e) {
      toast({ kind: 'error', message: posErrorText(e) });
    }
  }, [finishCard, toast]);

  // While the guest is at the reader: ask every 2 s; the server captures once
  // the reader authorized (or cancels a decline). Give up after the reservation.
  useEffect(() => {
    if (!cardSale || cardSale.state !== 'waiting') return undefined;
    let stop = false;
    const t = setTimeout(async () => {
      try {
        const r = await cardStatus(cardSale.order.id);
        if (stop) return;
        if (cardStateDone(r.state)) { finishCard(r); return; }
        if (Date.now() - cardSale.startedAt > CARD_POLL_GIVE_UP_MS) { void cancelCard(cardSale.order.id, 'timed out at the reader'); return; }
      } catch {
        if (stop) return;   // a dropped request: ask again
      }
      setCardSale((c) => (c && c.order.id === cardSale.order.id ? { ...c, polls: c.polls + 1 } : c));
    }, CARD_POLL_MS);
    return () => { stop = true; clearTimeout(t); };
  }, [cardSale, finishCard, cancelCard]);

  const chargeCard = async (skipQuestions = false) => {
    if (!cat || !tier || !quote || !reader) return;
    setBusy(true);
    let pending: WalkupOrder | null = null;
    try {
      pending = await beginCardSale({
        eventId, tierId: tier.tier_id, quantity: qty, orderKey, buyerName: name, buyerEmail: email,
        answers: asks ? answersBody(cat.questions, ticketTiers, draft) : undefined,
        skipQuestions: skipQuestions && missing.length > 0,
      });
      setCardSale({ order: pending, state: 'starting', startedAt: Date.now(), polls: 0 });
      await chargeOnReader(pending.id, reader.device_id);
      setCardSale((c) => (c && c.order.id === pending!.id ? { ...c, state: 'waiting' } : c));
    } catch (e) {
      toast({ kind: 'error', message: posErrorText(e) });
      // The reader never got it: give the places back.
      if (pending) void cancelCard(pending.id, 'the reader could not start');
    } finally {
      setBusy(false);
    }
  };

  const addReader = async () => {
    if (!cat) return;
    if (rdCode.trim().length < 3) { toast({ kind: 'error', message: 'Type the code the reader shows.' }); return; }
    setBusy(true);
    try {
      if (!cat.card.has_location) await setupCardLocation(eventId, addr);
      await registerReader(eventId, rdCode.trim(), rdLabel.trim() || 'Door reader');
      setRdCode('');
      toast({ kind: 'success', message: 'Reader added.' });
      void load();
    } catch (e) {
      toast({ kind: 'error', message: posErrorText(e) });
    } finally {
      setBusy(false);
    }
  };

  const showQr = async (o: WalkupOrder) => {
    setBusy(true);
    try {
      const r = await saleCodes(o.id);
      if (r.tickets.length === 0) {
        toast({ kind: 'error', message: r.skipped.length ? `Can't show these tickets (${r.skipped[0].reason}).` : 'No tickets to show.' });
        return;
      }
      setDone(o); setCodes(r.tickets); setCodeAt(0);
    } catch (e) {
      toast({ kind: 'error', message: posErrorText(e) });
    } finally {
      setBusy(false);
    }
  };

  const print = async (o: WalkupOrder) => {
    setBusy(true);
    try {
      const r = codes && done?.id === o.id ? { tickets: codes } : await saleCodes(o.id);
      if (!r.tickets.length) { toast({ kind: 'error', message: 'Nothing to print.' }); return; }
      if (!(codes && done?.id === o.id)) { setDone(o); setCodes(r.tickets); }
      downloadPdf(ticketsPdf(r.tickets), `door-tickets-${o.id.slice(0, 8)}.pdf`);
    } catch (e) {
      toast({ kind: 'error', message: posErrorText(e) });
    } finally {
      setBusy(false);
    }
  };

  const sendEmail = async () => {
    if (!done || !sendTo.trim()) return;
    setBusy(true);
    try {
      await emailSale(done.id, sendTo.trim());
      setCodes(null);
      toast({ kind: 'success', message: t('pos.toastSentTo', { email: sendTo.trim() }) });
      void load();
    } catch (e) {
      toast({ kind: 'error', message: posErrorText(e) });
    } finally {
      setBusy(false);
    }
  };

  const reverse = async (o: WalkupOrder) => {
    if (!cat) return;
    const opt = reverseOption({
      status: o.status, createdAt: o.created_at, scanned: o.tickets_scanned, rungByMe: o.rung_by_me, role: cat.role,
    });
    if (opt.kind === 'none') return;
    const label = opt.kind === 'refund' ? 'refund' : opt.kind === 'cancel' ? 'cancel' : 'void';
    const reason = window.prompt(`Why ${label} this sale? (${money(o.total_cents)})`);
    if (!reason || reason.trim().length < 3) return;
    if (opt.kind === 'refund' && opt.override
        && !window.confirm('A ticket of this sale was scanned. Refund anyway (override, recorded with your name)?')) return;
    setBusy(true);
    try {
      const r = opt.kind === 'refund'
        ? await refundSale(o.id, reason.trim(), opt.override, drawerId)
        : await voidSale(o.id, reason.trim(), drawerId);
      toast({ kind: 'success', message: r.cash_returned_cents ? t('pos.toastHandBack', { amount: money(r.cash_returned_cents) }) : t('pos.toastDone') });
      if (done?.id === o.id) { setDone(null); setCodes(null); }
      void load();
    } catch (e) {
      toast({ kind: 'error', message: posErrorText(e) });
    } finally {
      setBusy(false);
    }
  };

  const doOpenDrawer = async () => {
    const cents = parseCash(floatText);
    if (cents === null) { toast({ kind: 'error', message: 'Enter the float, e.g. 100' }); return; }
    setBusy(true);
    try {
      setDrawerId(await openDrawer(eventId, cents));
      void load();
    } catch (e) {
      toast({ kind: 'error', message: posErrorText(e) });
    } finally {
      setBusy(false);
    }
  };

  const doPaidOut = async () => {
    const cents = parseCash(poAmount);
    if (!drawer || cents === null || cents < 1) { toast({ kind: 'error', message: 'Enter the amount, e.g. 20' }); return; }
    if (poReason.trim().length < 3) { toast({ kind: 'error', message: 'Say what the cash is for.' }); return; }
    setBusy(true);
    try {
      const r = await paidOut(drawer.id, cents, poReason.trim(), newOrderKey());
      toast({ kind: 'success', message: `Paid out ${money(r.amount_cents)}. Drawer: ${money(r.drawer_cash_cents)}` });
      setPoAmount(''); setPoReason('');
      void load();
    } catch (e) {
      toast({ kind: 'error', message: posErrorText(e) });
    } finally {
      setBusy(false);
    }
  };

  const doClose = async () => {
    const cents = parseCash(countText);
    if (!drawer || cents === null) { toast({ kind: 'error', message: 'Enter the counted cash, e.g. 412.50' }); return; }
    if (!window.confirm(`Close the drawer with ${money(cents)} counted?`)) return;
    setBusy(true);
    try {
      const r = await closeDrawer(drawer.id, cents);
      toast({ kind: r.variance_cents === 0 ? 'success' : 'error',
        message: r.variance_cents === 0 ? t('pos.toastBalanced') : t(r.variance_cents < 0 ? 'pos.toastShort' : 'pos.toastOver', { amount: money(Math.abs(r.variance_cents)) }) });
      setCountText('');
      void load();
    } catch (e) {
      toast({ kind: 'error', message: posErrorText(e) });
    } finally {
      setBusy(false);
    }
  };

  if (loadErr) return <p role="alert" className="text-sm text-rose-600">{loadErr}</p>;
  if (!cat) return <p className="text-sm text-slate-400 flex items-center gap-2"><Loader2 className="w-4 h-4 animate-spin" /> {t('pos.loading')}</p>;

  const code = codes?.[codeAt] ?? null;

  return (
    <div className="space-y-6 text-slate-900">
      {/* After a sale: hand the ticket over. */}
      {done && (
        <section aria-label={t('pos.handOver')} className="rounded-2xl border-2 border-emerald-500 bg-emerald-50 p-4 space-y-3">
          <p className="text-lg font-black">
            {t('pos.soldLine', { qty: done.quantity, tier: done.tier_name, amount: done.payment_method === 'comp' ? t('pos.comp') : money(done.total_cents) })}
          </p>
          {code ? (
            <div className="bg-white rounded-xl p-3 flex flex-col items-center gap-2">
              {/* Our own SVG from the print code, as a data URL (no remote image service sees it). */}
              <img alt={t('pos.qrAlt')} width={280} height={280} className="w-full max-w-[280px] h-auto"
                src={`data:image/svg+xml;charset=utf-8,${encodeURIComponent(qrSvg(code.print_code, 280))}`} />
              <p className="text-xs text-slate-500 text-center">
                {t('pos.qrHint', { n: codeAt + 1, total: codes!.length })}
              </p>
              {codes!.length > 1 && (
                <button type="button" onClick={() => setCodeAt((codeAt + 1) % codes!.length)} className={`${BIG} border border-slate-300 w-full`}>
                  {t('pos.nextTicket')}
                </button>
              )}
            </div>
          ) : null}
          <div className="grid grid-cols-2 gap-2">
            <button type="button" disabled={busy} onClick={() => void showQr(done)} className={`${BIG} bg-slate-900 text-white flex items-center justify-center gap-2`}>
              <QrCode className="w-5 h-5" /> {t('pos.showQr')}
            </button>
            <button type="button" disabled={busy} onClick={() => void print(done)} className={`${BIG} border border-slate-300 bg-white flex items-center justify-center gap-2`}>
              <Printer className="w-5 h-5" /> {t('pos.print')}
            </button>
          </div>
          <div className="flex gap-2">
            <label className="flex-1">
              <span className="sr-only">{t('pos.emailTo')}</span>
              <input type="email" inputMode="email" value={sendTo} onChange={(e) => setSendTo(e.target.value)} placeholder={t('pos.emailPlaceholder')}
                className={INPUT} />
            </label>
            <button type="button" disabled={busy || !sendTo.trim()} onClick={() => void sendEmail()}
              className={`${BIG} border border-slate-300 bg-white flex items-center gap-2`}>
              <Mail className="w-5 h-5" /> {t('pos.send')}
            </button>
          </div>
          <button type="button" onClick={() => { setDone(null); setCodes(null); }} className={`${BIG} w-full bg-emerald-700 text-white`}>
            {t('pos.newSale')}
          </button>
        </section>
      )}

      {/* The sale. */}
      <section aria-labelledby="sell-h" className="space-y-4">
        <h2 id="sell-h" className="text-sm font-black uppercase tracking-widest text-slate-500 flex items-center gap-2">
          <Ticket className="w-4 h-4" /> {t('pos.sellAtDoor')}
        </h2>
        {cat.tiers.length === 0 && <p className="text-sm text-slate-500">{t('pos.noTiers')}</p>}
        <div role="radiogroup" aria-label={t('pos.ticketType')} className="grid gap-2">
          {cat.tiers.map((tr) => {
            const out = tr.remaining !== null && tr.remaining <= 0;
            const on = tr.tier_id === tierId;
            return (
              <button key={tr.tier_id} type="button" role="radio" aria-checked={on} disabled={out}
                onClick={() => { setTierId(tr.tier_id); setQty(1); }}
                className={`min-h-[60px] rounded-xl border-2 px-4 py-2 text-left flex items-center justify-between gap-3 ${
                  on ? 'border-slate-900 bg-slate-900 text-white' : 'border-slate-200 bg-white'} disabled:opacity-40`}>
                <span>
                  <span className="block font-black">{tr.name}</span>
                  <span className={`block text-xs ${on ? 'text-white/70' : 'text-slate-500'}`}>
                    {tr.price_source === 'door' ? t('pos.doorPrice') : tr.step_name ? tr.step_name : t('pos.price')}
                    {tr.step_remaining !== null ? t('pos.atThisPrice', { n: tr.step_remaining }) : ''}
                  </span>
                </span>
                <span className="text-right">
                  <span className="block text-lg font-black">{money(tr.unit_total_cents)}</span>
                  <span className={`block text-xs ${on ? 'text-white/70' : 'text-slate-500'}`}>
                    {out ? t('pos.soldOut') : tr.remaining === null ? t('pos.noLimit') : t('pos.left', { n: tr.remaining })}
                  </span>
                </span>
              </button>
            );
          })}
        </div>

        {tier && quote && (
          <>
            <div className="flex items-center justify-between gap-3">
              <span className="text-sm font-bold">{t('pos.quantity')}</span>
              <div className="flex items-center gap-2">
                <button type="button" aria-label={t('pos.fewer')} disabled={qty <= 1} onClick={() => setQty(qty - 1)}
                  className="w-14 h-14 rounded-xl border border-slate-300 bg-white flex items-center justify-center disabled:opacity-40">
                  <Minus className="w-5 h-5" />
                </button>
                <output aria-live="polite" className="w-10 text-center text-2xl font-black">{qty}</output>
                <button type="button" aria-label={t('pos.more')} disabled={qty >= maxQty} onClick={() => setQty(qty + 1)}
                  className="w-14 h-14 rounded-xl border border-slate-300 bg-white flex items-center justify-center disabled:opacity-40">
                  <Plus className="w-5 h-5" />
                </button>
              </div>
            </div>

            <div role="radiogroup" aria-label={t('pos.payment')} className="grid grid-cols-3 gap-2">
              <button type="button" role="radio" aria-checked={payment === 'cash'} onClick={() => setPayment('cash')}
                className={`${BIG} flex flex-col items-center justify-center gap-1 ${payment === 'cash' ? 'bg-slate-900 text-white' : 'border border-slate-300 bg-white'}`}>
                <Banknote className="w-5 h-5" /> {t('pos.cash')}
              </button>
              <button type="button" role="radio" aria-checked={payment === 'comp'} disabled={!cat.can_comp}
                title={cat.can_comp ? undefined : t('pos.compsNeedManager')} onClick={() => setPayment('comp')}
                className={`${BIG} flex flex-col items-center justify-center gap-1 ${payment === 'comp' ? 'bg-slate-900 text-white' : 'border border-slate-300 bg-white'} disabled:opacity-40`}>
                <Gift className="w-5 h-5" /> {t('pos.compButton')}
              </button>
              <button type="button" role="radio" aria-checked={payment === 'card'} disabled={!cat.card.connected || !!cardSale}
                title={cat.card.connected ? undefined : cat.card.message || (lang === 'en' ? WALKUP_CARD_MESSAGE : t('pos.cardOff'))} onClick={() => setPayment('card')}
                className={`${BIG} flex flex-col items-center justify-center gap-1 ${payment === 'card' ? 'bg-slate-900 text-white' : 'border border-slate-300 bg-white'} disabled:opacity-40`}>
                <CreditCard className="w-5 h-5" /> {t('pos.card')}
              </button>
            </div>
            {!cat.card.connected && <p className="text-xs text-slate-500">{cat.card.message || (lang === 'en' ? WALKUP_CARD_MESSAGE : t('pos.cardOff'))}</p>}
            {payment === 'card' && readers.length > 1 && (
              <label className="block text-sm">
                <span className="block font-bold mb-1">{t('pos.reader')}</span>
                <select value={readerId ?? ''} onChange={(e) => setReaderId(e.target.value || null)} className={INPUT}>
                  {readers.map((r) => <option key={r.device_id} value={r.device_id}>{r.label}</option>)}
                </select>
              </label>
            )}

            <div className="rounded-2xl bg-slate-900 text-white p-4">
              <p className="text-xs uppercase tracking-widest text-white/60">
                {payment === 'comp' ? t('pos.compButton') : payment === 'card' ? t('pos.dueOn', { reader: reader?.label ?? t('pos.theReader') }) : t('pos.due')}
              </p>
              <p className="text-4xl font-black">{money(payment === 'comp' ? 0 : quote.cashDueCents)}</p>
              {quote.taxCents > 0 && <p className="text-xs text-white/60">{t('pos.inclTax', { amount: money(quote.taxCents) })}</p>}
              {payment === 'cash' && quote.cashDueCents > 0 && (
                <>
                  <div className="grid grid-cols-2 gap-2 mt-3" aria-label={t('pos.cashReceived')}>
                    {quickCash(quote.cashDueCents).map((c) => (
                      <button key={c} type="button" onClick={() => setReceived(c)}
                        className={`min-h-[48px] rounded-xl font-black ${received === c ? 'bg-white text-slate-900' : 'bg-white/10'}`}>
                        {money(c)}
                      </button>
                    ))}
                  </div>
                  {change && (
                    <p aria-live="polite" className="mt-3 text-2xl font-black">
                      {change.shortCents > 0 ? t('pos.short', { amount: money(change.shortCents) }) : t('pos.change', { amount: money(change.changeCents) })}
                    </p>
                  )}
                </>
              )}
            </div>

            <div className="grid gap-2">
              <label className="block text-sm">
                <span className="block font-bold mb-1">{t('pos.nameOptional')}</span>
                <input value={name} maxLength={80} onChange={(e) => setName(e.target.value)} autoComplete="off" className={INPUT} />
              </label>
              <label className="block text-sm">
                <span className="block font-bold mb-1">{t('pos.emailOptional')}</span>
                <input type="email" inputMode="email" value={email} maxLength={254} onChange={(e) => setEmail(e.target.value)} autoComplete="off" className={INPUT} />
              </label>
              {asks && (
                <div>
                  <button type="button" aria-expanded={showQs} onClick={() => setShowQs(!showQs)} className="text-sm font-bold underline min-h-[44px]"
                    data-testid="walkup-questions-toggle">
                    {t(showQs ? 'pos.hideQuestions' : 'pos.askQuestions')}{missing.length > 0 ? t('pos.requiredCount', { n: missing.length }) : ''}
                  </button>
                  {showQs && (
                    <CheckoutQuestionsForm questions={doorQuestions(cat.questions)} ticketTiers={ticketTiers} value={draft} onChange={setDraft}
                      problems={{}} showErrors={false} tone="light" />
                  )}
                </div>
              )}
            </div>

            {needsDrawer && !drawer && <p role="alert" className="text-sm text-amber-700">{t('pos.openDrawerFirst')}</p>}
            {missing.length > 0 && !cardSale && (
              <p className="text-sm text-amber-700" data-testid="walkup-missing">{missingText(missing)}</p>
            )}
            {cardSale ? (
              <div role="status" aria-live="polite" className="rounded-2xl border-2 border-sky-500 bg-sky-50 p-4 space-y-3">
                <p className="text-lg font-black flex items-center gap-2">
                  {!cardStateDone(cardSale.state) && <Loader2 className="w-5 h-5 animate-spin" />}
                  {money(cardSale.order.total_cents)} · {cardText(cardSale.state)}
                </p>
                <button type="button" onClick={() => void cancelCard(cardSale.order.id, 'cancelled at the door')}
                  className={`${BIG} w-full border border-slate-300 bg-white`}>
                  {t('pos.cancelCard')}
                </button>
              </div>
            ) : payment === 'card' ? (
              <>
                <button type="button" disabled={busy || !reader || (tier.remaining !== null && tier.remaining < qty) || quote.totalCents <= 0 || missing.length > 0}
                  onClick={() => void chargeCard()}
                  className={`${BIG} w-full min-h-[60px] text-base bg-emerald-700 text-white disabled:opacity-50 flex items-center justify-center gap-2`}>
                  {busy && <Loader2 className="w-5 h-5 animate-spin" />}
                  <CreditCard className="w-5 h-5" /> {t('pos.chargeOnReader', { amount: money(quote.totalCents) })}
                </button>
                {missing.length > 0 && (
                  <button type="button" disabled={busy || !reader || (tier.remaining !== null && tier.remaining < qty) || quote.totalCents <= 0}
                    onClick={() => void chargeCard(true)} data-testid="walkup-skip-questions"
                    className={`${BIG} w-full border-2 border-amber-500 text-amber-800 bg-white disabled:opacity-50`}>
                    {t('pos.skipCharge', { amount: money(quote.totalCents) })}
                  </button>
                )}
              </>
            ) : (
              <>
                <button type="button" disabled={busy || (needsDrawer && !drawer) || (tier.remaining !== null && tier.remaining < qty) || missing.length > 0}
                  onClick={() => void sell()}
                  className={`${BIG} w-full min-h-[60px] text-base bg-emerald-700 text-white disabled:opacity-50 flex items-center justify-center gap-2`}>
                  {busy && <Loader2 className="w-5 h-5 animate-spin" />}
                  {payment === 'comp' ? t(qty === 1 ? 'pos.compOne' : 'pos.compN', { n: qty }) : t('pos.takeSell', { amount: money(quote.cashDueCents), n: qty })}
                </button>
                {missing.length > 0 && (
                  <button type="button" disabled={busy || (needsDrawer && !drawer) || (tier.remaining !== null && tier.remaining < qty)}
                    onClick={() => void sell(true)} data-testid="walkup-skip-questions"
                    className={`${BIG} w-full border-2 border-amber-500 text-amber-800 bg-white disabled:opacity-50`}>
                    {payment === 'comp' ? t('pos.skipComp', { n: qty }) : t('pos.skipSell', { n: qty })}
                  </button>
                )}
              </>
            )}
          </>
        )}
      </section>

      {/* Recent sales. */}
      <section aria-labelledby="recent-h" className="space-y-2">
        <h2 id="recent-h" className="text-sm font-black uppercase tracking-widest text-slate-500">{t('pos.recent')}</h2>
        {sales.length === 0 && <p className="text-sm text-slate-500">{t('pos.noSales')}</p>}
        <ul className="space-y-2">
          {sales.map((o) => {
            const opt = reverseOption({ status: o.status, createdAt: o.created_at, scanned: o.tickets_scanned, rungByMe: o.rung_by_me, role: cat.role });
            return (
              <li key={o.id} className="rounded-xl border border-slate-200 bg-white p-3 flex items-center gap-3">
                <span className="flex-1 min-w-0">
                  <span className="block font-bold truncate">{o.quantity ?? ''} × {o.tier_name ?? 'POS order'}{o.buyer_name ? ` · ${o.buyer_name}` : ''}</span>
                  <span className="block text-xs text-slate-500">
                    {new Date(o.created_at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })} ·{' '}
                    {o.payment_method === 'comp' ? 'comp' : money(o.total_cents)} · {o.status}
                    {o.tickets_scanned > 0 ? ` · ${o.tickets_scanned} in` : ''}
                    {o.channel === 'kiosk' ? ' · kiosk' : ''}
                  </span>
                </span>
                {o.status === 'paid' && o.can_hand_over && o.ticket_ids.length > 0 && (
                  <button type="button" aria-label="Show the QR" disabled={busy} onClick={() => void showQr(o)}
                    className="w-12 h-12 rounded-xl border border-slate-300 flex items-center justify-center">
                    <QrCode className="w-5 h-5" />
                  </button>
                )}
                {opt.kind !== 'none' && (
                  <button type="button" disabled={busy} onClick={() => void reverse(o)}
                    className="min-h-[48px] px-3 rounded-xl border border-rose-300 text-rose-700 text-xs font-black uppercase tracking-widest flex items-center gap-1">
                    <RotateCcw className="w-4 h-4" /> {opt.kind === 'refund' ? (opt.override ? t('pos.refundOverride') : t('pos.refund')) : opt.kind === 'cancel' ? t('pos.cancel') : t('pos.void')}
                  </button>
                )}
              </li>
            );
          })}
        </ul>
      </section>

      {/* The cash drawer. */}
      <section aria-labelledby="drawer-h" className="rounded-2xl border border-slate-200 bg-white p-4 space-y-3">
        <h2 id="drawer-h" className="text-sm font-black uppercase tracking-widest text-slate-500 flex items-center gap-2">
          <Wallet className="w-4 h-4" /> {t('pos.drawerTitle')}
        </h2>
        {cat.drawers.some((d) => !d.mine || cat.drawers.length > 1) && (
          <label className="block text-sm">
            <span className="block font-bold mb-1">Drawer</span>
            <select value={drawerId ?? ''} onChange={(e) => setDrawerId(e.target.value || null)} className={INPUT}>
              <option value="">{cat.drawers.some((d) => d.mine) ? 'Pick a drawer' : 'Open your own below, or pick one'}</option>
              {cat.drawers.map((d) => (
                <option key={d.id} value={d.id}>{d.mine ? 'Mine' : 'Drawer'} · opened {new Date(d.opened_at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}</option>
              ))}
            </select>
          </label>
        )}
        {drawer ? (
          <>
            <p className="text-lg font-black">{t('pos.inDrawer', { amount: money(drawer.cash_cents) })}</p>
            <p className="text-xs text-slate-500">{t('pos.float', { amount: money(drawer.open_float_cents) })}</p>
            <div className="grid grid-cols-2 gap-2">
              <label className="text-sm"><span className="block font-bold mb-1">{t('pos.payOutAmount')}</span>
                <input inputMode="decimal" value={poAmount} onChange={(e) => setPoAmount(e.target.value)} placeholder="20.00" className={INPUT} /></label>
              <label className="text-sm"><span className="block font-bold mb-1">{t('pos.payOutFor')}</span>
                <input value={poReason} maxLength={300} onChange={(e) => setPoReason(e.target.value)} placeholder="Ice for the bar" className={INPUT} /></label>
            </div>
            <button type="button" disabled={busy} onClick={() => void doPaidOut()} className={`${BIG} w-full border border-slate-300`}>{t('pos.payOut')}</button>
            <label className="block text-sm"><span className="block font-bold mb-1">{t('pos.countedAtClose')}</span>
              <input inputMode="decimal" value={countText} onChange={(e) => setCountText(e.target.value)} placeholder="412.50" className={INPUT} /></label>
            <button type="button" disabled={busy} onClick={() => void doClose()} className={`${BIG} w-full bg-slate-900 text-white`}>{t('pos.countClose')}</button>
          </>
        ) : (
          <>
            <label className="block text-sm"><span className="block font-bold mb-1">{t('pos.openingFloat')}</span>
              <input inputMode="decimal" value={floatText} onChange={(e) => setFloatText(e.target.value)} className={INPUT} /></label>
            <button type="button" disabled={busy} onClick={() => void doOpenDrawer()} className={`${BIG} w-full bg-slate-900 text-white`}>{t('pos.openDrawer')}</button>
          </>
        )}
      </section>

      {/* Card readers: owners and managers add a smart reader (Stripe Reader S700, WisePOS E) by its code. */}
      {cat.card.switched_on && cat.card.can_manage && (
        <section aria-labelledby="reader-h" className="rounded-2xl border border-slate-200 bg-white p-4 space-y-3">
          <h2 id="reader-h" className="text-sm font-black uppercase tracking-widest text-slate-500 flex items-center gap-2">
            <CreditCard className="w-4 h-4" /> Card readers
          </h2>
          {readers.length > 0 && <p className="text-sm">{readers.map((r) => r.label).join(' · ')}</p>}
          {!cat.card.has_location && (
            <div className="grid gap-2">
              <p className="text-xs text-slate-500">The venue's address (Stripe needs it once for this organization's readers).</p>
              <input aria-label="Street" value={addr.line1} onChange={(e) => setAddr({ ...addr, line1: e.target.value })} placeholder="Street" className={INPUT} />
              <div className="grid grid-cols-2 gap-2">
                <input aria-label="City" value={addr.city} onChange={(e) => setAddr({ ...addr, city: e.target.value })} placeholder="City" className={INPUT} />
                <input aria-label="State" value={addr.state} onChange={(e) => setAddr({ ...addr, state: e.target.value })} placeholder="State" className={INPUT} />
                <input aria-label="Postal code" value={addr.postal_code} onChange={(e) => setAddr({ ...addr, postal_code: e.target.value })} placeholder="Postal code" className={INPUT} />
                <input aria-label="Country" value={addr.country} maxLength={2} onChange={(e) => setAddr({ ...addr, country: e.target.value.toUpperCase() })} placeholder="US" className={INPUT} />
              </div>
            </div>
          )}
          <div className="grid grid-cols-2 gap-2">
            <label className="text-sm"><span className="block font-bold mb-1">Code on the reader</span>
              <input value={rdCode} onChange={(e) => setRdCode(e.target.value)} autoComplete="off" placeholder="sepia-cerulean-aqua" className={INPUT} /></label>
            <label className="text-sm"><span className="block font-bold mb-1">Name</span>
              <input value={rdLabel} maxLength={80} onChange={(e) => setRdLabel(e.target.value)} className={INPUT} /></label>
          </div>
          <button type="button" disabled={busy} onClick={() => void addReader()} className={`${BIG} w-full border border-slate-300`}>Add reader</button>
        </section>
      )}

      {/* Kiosk mode (mig 20261113100000): owners and managers set up a self-serve card-only screen. */}
      {(cat.role === 'owner' || cat.role === 'manager') && (
        <KioskSetupPanel eventId={eventId} readers={cat.card.readers ?? []} cardOn={cat.card.switched_on === true} />
      )}
    </div>
  );
}
