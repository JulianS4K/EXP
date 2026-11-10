// Kiosk mode (mig 20261113100000, docs/pos.md "Kiosk mode"): the self-serve
// screen at a fair gate. One event's public ticket types, by card on the
// kiosk's own Stripe Terminal reader, and nothing else: no navigation, no
// sign-in, no dashboard. The browser holds only the kiosk's credential (the
// staff member who started it was signed out); App keeps every other path on
// /kiosk while it's set.
//
// Pick a type and quantity → the event's questions (required ones can't be
// skipped) → pay on the reader → the ticket QR on screen, "Email it to me",
// and paper when the kiosk has a printer. The screen starts over after each
// sale (Done, or 30 s untouched) and after 60 s idle mid-sale, clearing what
// the buyer entered from memory and local storage; a card sale left on the
// reader is cancelled there. Staff leave with the admin PIN (the Staff button).
//
// No card field, ever (SAQ A, docs/pci.md): the reader takes the card and this
// page only sends ids. Touch targets are at least 64 px, focus is always
// visible, and the a11y gate scans this screen (tests/smoke/a11y.mjs).

import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { CreditCard, Loader2, Lock, Mail, Minus, Plus, Printer } from 'lucide-react';
import { formatCents } from '../lib/refunds';
import { cardStateText, doorQuestions, missingAnswersText, walkupMissingRequired } from '../lib/pos';
import { answersBody, EMPTY_DRAFT, hasQuestions, ticketTiersFor, type AnswerDraft } from '../lib/checkoutQuestions';
import {
  clearKioskCredential, kioskExitText, kioskMaxQuantity, kioskReducer, kioskSecondsLeft, kioskStart, kioskStorage, kioskTimer,
  readKioskCredential, wipeBuyerStorage, type KioskCredential,
} from '../lib/kiosk';
import {
  kioskBegin, kioskCancel, kioskCharge, kioskCodes, kioskEmail, kioskErrorText, kioskExit, kioskScreen, kioskStatus,
  type KioskScreen,
} from '../lib/kioskApi';
import { PosError, ticketsPdf } from '../lib/posWalkup';
import { qrSvg } from '../../supabase/functions/_shared/print/qr.ts';
import type { PrintTicket } from '../../supabase/functions/_shared/print/tickets.ts';
import CheckoutQuestionsForm from '../components/CheckoutQuestionsForm';

const FOCUS = 'focus:outline-none focus-visible:ring-4 focus-visible:ring-offset-2 focus-visible:ring-sky-500';
const BIG = `min-h-[64px] px-6 rounded-2xl text-lg font-black ${FOCUS}`;
const POLL_MS = 2000;

const newKey = () => crypto.randomUUID();

/** Print the codes through the browser's print dialog (a kiosk browser prints it straight away). */
function printTickets(tickets: PrintTicket[]) {
  const url = URL.createObjectURL(new Blob([ticketsPdf(tickets) as BlobPart], { type: 'application/pdf' }));
  const frame = document.createElement('iframe');
  frame.style.position = 'fixed';
  frame.style.width = '0';
  frame.style.height = '0';
  frame.style.border = '0';
  frame.setAttribute('aria-hidden', 'true');
  frame.src = url;
  frame.onload = () => {
    try {
      frame.contentWindow?.print();
    } catch {
      /* the browser refused: nothing more to do here */
    }
  };
  document.body.appendChild(frame);
  setTimeout(() => { frame.remove(); URL.revokeObjectURL(url); }, 60_000);
}

export default function Kiosk() {
  const navigate = useNavigate();
  const [cred] = useState<KioskCredential | null>(() => readKioskCredential(kioskStorage()));
  const [screen, setScreen] = useState<KioskScreen | null>(null);
  const [ended, setEnded] = useState(false);
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [s, dispatch] = useReducer(kioskReducer, undefined, () => kioskStart(newKey(), Date.now()));
  const [draft, setDraft] = useState<AnswerDraft>(EMPTY_DRAFT);
  const [showErrors, setShowErrors] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [codes, setCodes] = useState<PrintTicket[] | null>(null);
  const [codeAt, setCodeAt] = useState(0);
  const [email, setEmail] = useState('');
  const [sent, setSent] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());
  // The staff PIN pad.
  const [pinOpen, setPinOpen] = useState(false);
  const [pin, setPin] = useState('');
  const [pinMsg, setPinMsg] = useState<string | null>(null);
  const pinRef = useRef<HTMLInputElement | null>(null);
  const [polls, setPolls] = useState(0);
  const token = cred?.token ?? '';
  const orderRef = useRef<string | null>(null);
  orderRef.current = s.orderId;

  const leave = useCallback(() => {
    clearKioskCredential(kioskStorage());
    wipeBuyerStorage(kioskStorage(), ['exos.consent.v2']);
    try { sessionStorage.clear(); } catch { /* blocked */ }
    navigate('/door', { replace: true });
  }, [navigate]);

  const load = useCallback(async () => {
    if (!token) { setEnded(true); return; }
    try {
      setScreen(await kioskScreen(token));
      setLoadErr(null);
    } catch (e) {
      if (e instanceof PosError && e.code === 'kiosk-ended') setEnded(true);
      else setLoadErr(kioskErrorText(e));
    }
  }, [token]);
  useEffect(() => { void load(); }, [load]);

  // Start over: forget the buyer (memory and storage), a new order key, fresh availability.
  const reset = useCallback(() => {
    dispatch({ type: 'reset', orderKey: newKey(), at: Date.now() });
    setDraft(EMPTY_DRAFT); setShowErrors(false); setError(null); setCodes(null); setCodeAt(0); setEmail(''); setSent(null);
    wipeBuyerStorage(kioskStorage());
    try { sessionStorage.clear(); } catch { /* blocked */ }
    void load();
  }, [load]);

  const cancelOnReader = useCallback(async (orderId: string | null) => {
    if (!orderId) return;
    try { await kioskCancel(token, orderId); } catch { /* the hold lapses by itself */ }
  }, [token]);

  // The clock: idle, after a sale, and a sale abandoned at the reader.
  useEffect(() => {
    const t = setInterval(() => {
      const at = Date.now();
      setNow(at);
      const act = kioskTimer(s, at);
      if (act === 'cancel-and-reset') { void cancelOnReader(s.orderId); reset(); }
      else if (act === 'reset') reset();
    }, 1000);
    return () => clearInterval(t);
  }, [s, reset, cancelOnReader]);

  // Any touch or key keeps the sale alive.
  const touch = useCallback(() => dispatch({ type: 'touch', at: Date.now() }), []);
  useEffect(() => {
    window.addEventListener('pointerdown', touch, true);
    window.addEventListener('keydown', touch, true);
    return () => { window.removeEventListener('pointerdown', touch, true); window.removeEventListener('keydown', touch, true); };
  }, [touch]);
  useEffect(() => { if (pinOpen) pinRef.current?.focus(); }, [pinOpen]);

  const tier = screen?.tiers.find((t) => t.tier_id === s.tierId) ?? null;
  const currency = screen?.event.currency ?? 'USD';
  const money = (c: number) => formatCents(c, currency);
  const max = tier && screen ? kioskMaxQuantity(screen.max_per_order, tier.remaining) : 1;
  const ticketTiers = useMemo(() => (s.tierId ? ticketTiersFor(s.tierId, s.quantity) : []), [s.tierId, s.quantity]);
  const questions = useMemo(() => (screen ? doorQuestions(screen.questions) : []), [screen]);
  const asks = screen && s.tierId ? hasQuestions(questions, ticketTiers) : false;
  const missing = useMemo(() => (asks && screen
    ? walkupMissingRequired(screen.questions, ticketTiers, answersBody(questions, ticketTiers, draft) ?? {}) : []),
  [asks, screen, questions, ticketTiers, draft]);
  const total = tier ? tier.unit_total_cents * s.quantity : 0;

  // Begin the sale and send it to the reader.
  const pay = async () => {
    if (!screen || !tier) return;
    if (missing.length > 0) { setShowErrors(true); setError(missingAnswersText(missing)); return; }
    dispatch({ type: 'next', asksQuestions: false, at: Date.now() });
    setError(null); setBusy(true);
    let orderId: string | null = null;
    try {
      const o = await kioskBegin(token, {
        tierId: tier.tier_id, quantity: s.quantity, orderKey: s.orderKey,
        answers: asks ? answersBody(questions, ticketTiers, draft) : undefined,
      });
      orderId = o.id;
      const r = await kioskCharge(token, o.id);
      dispatch({ type: 'charging', orderId: o.id, at: Date.now() });
      if (r.state === 'succeeded') dispatch({ type: 'card', state: 'succeeded', at: Date.now() });
    } catch (e) {
      if (e instanceof PosError && e.code === 'kiosk-ended') { setEnded(true); return; }
      setError(kioskErrorText(e));
      void cancelOnReader(orderId);
      dispatch({ type: 'card', state: 'canceled', at: Date.now() });
    } finally {
      setBusy(false);
    }
  };

  // While the buyer is at the reader: ask every 2 s (the server captures once authorized).
  useEffect(() => {
    if (s.step !== 'paying' || s.card !== 'waiting' || !s.orderId) return undefined;
    let stop = false;
    const t = setTimeout(async () => {
      try {
        const r = await kioskStatus(token, s.orderId!);
        if (stop || orderRef.current !== r.order_id) return;
        if (r.state !== 'waiting') { dispatch({ type: 'card', state: r.state, declineCode: r.decline_code ?? null, at: Date.now() }); return; }
      } catch (e) {
        if (stop) return;
        if (e instanceof PosError && e.code === 'kiosk-ended') { setEnded(true); return; }
        // A dropped request: ask again.
      }
      setPolls((n) => n + 1);
    }, POLL_MS);
    return () => { stop = true; clearTimeout(t); };
  }, [s.step, s.card, s.orderId, token, polls]);

  // Paid: fetch the QR codes once.
  useEffect(() => {
    if (s.step !== 'done' || !s.orderId || codes) return;
    kioskCodes(token, s.orderId).then((c) => { setCodes(c); setCodeAt(0); }).catch((e) => setError(kioskErrorText(e)));
  }, [s.step, s.orderId, codes, token]);

  const cancelPay = async () => {
    touch();
    await cancelOnReader(s.orderId);
    dispatch({ type: 'card', state: 'canceled', at: Date.now() });
  };

  const sendEmail = async () => {
    if (!s.orderId || !email.trim()) return;
    setBusy(true); setError(null);
    try {
      await kioskEmail(token, s.orderId, email.trim());
      setSent(email.trim()); setEmail('');
    } catch (e) {
      setError(kioskErrorText(e));
    } finally {
      setBusy(false);
    }
  };

  const tryExit = async () => {
    if (!pin) return;
    setBusy(true);
    try {
      // A sale still on the reader is cancelled first (the server does it too).
      if (s.step === 'paying') await cancelOnReader(s.orderId);
      const r = await kioskExit(token, pin);
      setPin('');
      if (r.ok) { leave(); return; }
      setPinMsg(kioskExitText(r));
    } catch (e) {
      setPinMsg(kioskErrorText(e));
    } finally {
      setBusy(false);
    }
  };

  const staffButton = (
    <button type="button" onClick={() => { setPinOpen(true); setPinMsg(null); setPin(''); }}
      className={`min-h-[48px] min-w-[48px] px-3 rounded-xl text-sm font-bold text-slate-600 bg-white border border-slate-300 flex items-center gap-2 ${FOCUS}`}>
      <Lock className="w-4 h-4" aria-hidden="true" /> Staff
    </button>
  );

  if (ended) {
    return (
      <main className="min-h-screen bg-slate-50 text-slate-900 flex flex-col items-center justify-center gap-6 p-8 text-center">
        <h1 className="text-3xl font-black">This kiosk has been switched off</h1>
        <p className="text-lg text-slate-600">Please buy your tickets at the box office.</p>
        <button type="button" onClick={leave} className={`${BIG} bg-slate-900 text-white`}>Staff sign-in</button>
      </main>
    );
  }

  const code = codes?.[codeAt] ?? null;
  const unavailable = screen && !screen.card.available;
  const left = kioskSecondsLeft(s, now);

  return (
    <main className="min-h-screen bg-slate-50 text-slate-900 p-6">
      <div className="max-w-2xl mx-auto space-y-6">
        <div className="flex justify-end">{staffButton}</div>
        <header className="text-center space-y-1">
          <p className="text-sm font-bold uppercase tracking-widest text-slate-600">Buy tickets here</p>
          <h1 className="text-3xl sm:text-4xl font-black">{screen?.event.name ?? 'Tickets'}</h1>
          {screen?.event.venue_name && <p className="text-base text-slate-600">{screen.event.venue_name}</p>}
        </header>

        {!screen && !loadErr && (
          <p role="status" className="text-center text-lg flex items-center justify-center gap-2">
            <Loader2 className="w-6 h-6 animate-spin" aria-hidden="true" /> Loading…
          </p>
        )}
        {loadErr && <p role="alert" className="text-center text-lg text-rose-700">{loadErr}</p>}

        {screen && unavailable && (
          <section aria-labelledby="unavail-h" className="rounded-2xl border-2 border-amber-500 bg-amber-50 p-6 text-center space-y-2">
            <h2 id="unavail-h" className="text-2xl font-black">Kiosk unavailable</h2>
            <p className="text-lg">{screen.card.message}</p>
          </section>
        )}

        {screen && !unavailable && s.step === 'pick' && (
          <section aria-labelledby="pick-h" className="space-y-5">
            <h2 id="pick-h" className="text-xl font-black">1. Choose your tickets</h2>
            {screen.tiers.length === 0 && <p className="text-lg">No tickets on sale here right now.</p>}
            <div role="radiogroup" aria-labelledby="pick-h" className="grid gap-3">
              {screen.tiers.map((t) => {
                const out = t.remaining !== null && t.remaining <= 0;
                const on = t.tier_id === s.tierId;
                return (
                  <button key={t.tier_id} type="button" role="radio" aria-checked={on} disabled={out}
                    onClick={() => dispatch({ type: 'pick', tierId: t.tier_id, at: Date.now() })}
                    className={`min-h-[80px] rounded-2xl border-2 px-5 py-3 text-left flex items-center justify-between gap-4 ${FOCUS} ${
                      on ? 'border-slate-900 bg-slate-900 text-white' : 'border-slate-300 bg-white'} disabled:opacity-50`}>
                    <span>
                      <span className="block text-xl font-black">{t.name}</span>
                      {t.description && <span className={`block text-sm ${on ? 'text-white/80' : 'text-slate-600'}`}>{t.description}</span>}
                    </span>
                    <span className="text-right">
                      <span className="block text-2xl font-black">{money(t.unit_total_cents)}</span>
                      {out && <span className="block text-sm">Sold out</span>}
                    </span>
                  </button>
                );
              })}
            </div>
            {tier && (
              <>
                <div className="flex items-center justify-between gap-4 rounded-2xl bg-white border border-slate-300 p-4">
                  <span className="text-lg font-bold" id="qty-l">How many?</span>
                  <div className="flex items-center gap-3" role="group" aria-labelledby="qty-l">
                    <button type="button" aria-label="One fewer" disabled={s.quantity <= 1}
                      onClick={() => dispatch({ type: 'quantity', quantity: s.quantity - 1, max, at: Date.now() })}
                      className={`w-16 h-16 rounded-2xl border-2 border-slate-300 bg-white flex items-center justify-center disabled:opacity-40 ${FOCUS}`}>
                      <Minus className="w-7 h-7" aria-hidden="true" />
                    </button>
                    <output aria-live="polite" className="w-12 text-center text-3xl font-black">{s.quantity}</output>
                    <button type="button" aria-label="One more" disabled={s.quantity >= max}
                      onClick={() => dispatch({ type: 'quantity', quantity: s.quantity + 1, max, at: Date.now() })}
                      className={`w-16 h-16 rounded-2xl border-2 border-slate-300 bg-white flex items-center justify-center disabled:opacity-40 ${FOCUS}`}>
                      <Plus className="w-7 h-7" aria-hidden="true" />
                    </button>
                  </div>
                </div>
                <p className="text-sm text-slate-600 text-center">Up to {max} per order.</p>
                <button type="button" disabled={max < 1}
                  onClick={() => (asks ? dispatch({ type: 'next', asksQuestions: true, at: Date.now() }) : void pay())}
                  className={`${BIG} w-full min-h-[72px] text-xl bg-emerald-700 text-white disabled:opacity-50`}>
                  {asks ? 'Continue' : `Pay ${money(total)} by card`}
                </button>
              </>
            )}
          </section>
        )}

        {screen && !unavailable && s.step === 'questions' && (
          <section aria-labelledby="q-h" className="space-y-5">
            <h2 id="q-h" className="text-xl font-black">2. A few questions</h2>
            <div className="rounded-2xl bg-white border border-slate-300 p-4">
              <CheckoutQuestionsForm questions={questions} ticketTiers={ticketTiers} value={draft} onChange={setDraft}
                problems={{}} showErrors={showErrors} tone="light" />
            </div>
            {error && <p role="alert" className="text-lg text-rose-700">{error}</p>}
            <div className="grid grid-cols-3 gap-3">
              <button type="button" onClick={() => dispatch({ type: 'back', at: Date.now() })}
                className={`${BIG} border-2 border-slate-300 bg-white`}>Back</button>
              <button type="button" onClick={() => void pay()}
                className={`${BIG} col-span-2 bg-emerald-700 text-white`}>Pay {money(total)} by card</button>
            </div>
          </section>
        )}

        {s.step === 'paying' && (
          <section aria-labelledby="pay-h" className="rounded-2xl border-2 border-sky-600 bg-white p-6 text-center space-y-4">
            <h2 id="pay-h" className="text-2xl font-black flex items-center justify-center gap-3">
              <CreditCard className="w-8 h-8" aria-hidden="true" /> {money(total)}
            </h2>
            <p role="status" aria-live="polite" className="text-xl font-bold flex items-center justify-center gap-2">
              {(busy || s.card === 'waiting') && <Loader2 className="w-6 h-6 animate-spin" aria-hidden="true" />}
              {s.card === 'waiting' ? `Tap, insert or swipe your card on the reader${screen?.reader.label ? ` (${screen.reader.label})` : ''}.`
                : cardStateText(s.card ?? 'starting')}
            </p>
            <button type="button" onClick={() => void cancelPay()} className={`${BIG} w-full border-2 border-slate-300 bg-white`}>
              Cancel
            </button>
          </section>
        )}

        {s.step === 'failed' && (
          <section aria-labelledby="fail-h" className="rounded-2xl border-2 border-rose-600 bg-white p-6 text-center space-y-4">
            <h2 id="fail-h" role="alert" className="text-2xl font-black">{error ?? cardStateText(s.card ?? 'canceled', s.declineCode)}</h2>
            <button type="button" onClick={reset} className={`${BIG} w-full bg-slate-900 text-white`}>Start again</button>
            {left !== null && <p className="text-sm text-slate-600">Starting over in {left} s.</p>}
          </section>
        )}

        {s.step === 'done' && (
          <section aria-labelledby="done-h" className="rounded-2xl border-2 border-emerald-600 bg-white p-6 space-y-4">
            <h2 id="done-h" className="text-2xl font-black text-center">Paid. Here are your tickets.</h2>
            {code ? (
              <div className="flex flex-col items-center gap-2">
                {/* Our own SVG from the print code, as a data URL (no remote image service sees it). */}
                <img alt={`Ticket QR code ${codeAt + 1} of ${codes!.length}`} width={300} height={300} className="w-full max-w-[300px] h-auto"
                  src={`data:image/svg+xml;charset=utf-8,${encodeURIComponent(qrSvg(code.print_code, 300))}`} />
                <p className="text-base text-slate-700 text-center">
                  Ticket {codeAt + 1} of {codes!.length}. Take a photo: it gets you in once.
                </p>
                {codes!.length > 1 && (
                  <button type="button" onClick={() => setCodeAt((codeAt + 1) % codes!.length)} className={`${BIG} w-full border-2 border-slate-300 bg-white`}>
                    Next ticket
                  </button>
                )}
              </div>
            ) : !error && (
              <p role="status" className="text-center flex items-center justify-center gap-2">
                <Loader2 className="w-5 h-5 animate-spin" aria-hidden="true" /> Getting your tickets…
              </p>
            )}
            {screen?.kiosk.printer && codes && codes.length > 0 && (
              <button type="button" onClick={() => printTickets(codes)} className={`${BIG} w-full border-2 border-slate-300 bg-white flex items-center justify-center gap-2`}>
                <Printer className="w-6 h-6" aria-hidden="true" /> Print my tickets
              </button>
            )}
            <div className="space-y-2">
              <label htmlFor="kiosk-email" className="block text-lg font-bold">Email it to me (optional)</label>
              <div className="flex flex-col sm:flex-row gap-2">
                <input id="kiosk-email" type="email" inputMode="email" autoComplete="off" value={email} maxLength={254}
                  onChange={(e) => setEmail(e.target.value)}
                  className={`flex-1 min-w-0 min-h-[64px] border-2 border-slate-300 rounded-2xl px-4 text-lg bg-white ${FOCUS}`} />
                <button type="button" disabled={busy || !email.trim()} onClick={() => void sendEmail()}
                  className={`${BIG} bg-slate-900 text-white flex items-center justify-center gap-2 disabled:opacity-50`}>
                  <Mail className="w-5 h-5" aria-hidden="true" /> Send
                </button>
              </div>
              {sent && <p role="status" className="text-base text-emerald-800">Sent to {sent}.</p>}
            </div>
            {error && <p role="alert" className="text-lg text-rose-700">{error}</p>}
            <button type="button" onClick={reset} className={`${BIG} w-full min-h-[72px] bg-emerald-700 text-white`}>Done</button>
            {left !== null && <p className="text-sm text-slate-600 text-center">Starting over in {left} s.</p>}
          </section>
        )}
      </div>

      {pinOpen && (
        <div role="dialog" aria-modal="true" aria-labelledby="pin-h" className="fixed inset-0 bg-slate-900/70 flex items-center justify-center p-4">
          <div className="bg-white rounded-2xl p-6 w-full max-w-sm space-y-4">
            <h2 id="pin-h" className="text-xl font-black">Staff: leave kiosk mode</h2>
            <label htmlFor="kiosk-pin" className="block text-base font-bold">Admin PIN</label>
            <input id="kiosk-pin" type="password" inputMode="numeric" autoComplete="off" maxLength={12} value={pin} ref={pinRef}
              onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))}
              onKeyDown={(e) => { if (e.key === 'Enter') void tryExit(); }}
              className={`w-full min-h-[64px] border-2 border-slate-300 rounded-2xl px-4 text-2xl tracking-widest bg-white ${FOCUS}`} />
            {pinMsg && <p role="alert" className="text-base text-rose-700">{pinMsg}</p>}
            <div className="grid grid-cols-2 gap-3">
              <button type="button" onClick={() => { setPinOpen(false); setPin(''); }} className={`${BIG} border-2 border-slate-300 bg-white`}>Cancel</button>
              <button type="button" disabled={busy || pin.length < 6} onClick={() => void tryExit()}
                className={`${BIG} bg-slate-900 text-white disabled:opacity-50`}>Exit</button>
            </div>
          </div>
        </div>
      )}
    </main>
  );
}
