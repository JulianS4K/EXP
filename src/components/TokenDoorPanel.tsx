// The door app's Tokens tab (mig 20261114110000; docs/pos.md "Event tokens"):
// take drink tickets, ride credits or tasting tickets off a guest's ticket or
// token code, and sell them at the door.
//
// Take: pick the token type and how many (1-50), scan the guest's ticket QR
// (or the wristband / paper code, or type it). The server checks the code,
// locks the balance and takes them, or refuses ("not enough"); the screen
// shows what is left. Offline, the device gives at most what the code had at
// its last sync minus what it already gave (lib/eventTokens offlineCap),
// queues the spend with a client ref and replays it once back online; the
// server takes what is left and records any shortfall as an exception on the
// report. Owners and managers undo a spend made here, with a reason.
// Sell: cash into the seller's open drawer (open one in the Sell tab) or a
// comp (owner / manager), onto a new token code (shown once, as a QR and in
// words, for a wristband or paper) or onto a guest's ticket or code.
//
// One column, big tap targets: this runs on a bartender's phone.

import { useCallback, useEffect, useReducer, useRef, useState } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import { Camera, Loader2, Minus, Plus, RefreshCw, RotateCcw } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { formatCents } from '../lib/refunds';
import { safeLocalStorage } from '../lib/door/kv';
import { deviceLabel, newClientRef } from '../lib/offlineCheckins';
import {
  cardKeyOf, clampCredits, decideOffline, DOOR_TOKEN_IDLE, doorTokenReducer, enqueueSpend, formatTokenCode, isRepeatRead,
  NO_CASH_VALUE, parseQueue, parseRoster, parseTokenCode, settleQueue, tokenReasonText, type QueuedSpend, type SyncAnswer,
  type TokenRoster,
} from '../lib/eventTokens';
import {
  listTokenProducts, sellTokens, spendTokens, tokenRoster, undoTokenSpend, type TokenProduct, type TokenSale,
} from '../lib/eventTokensApi';

const BIG = 'min-h-[52px] px-4 rounded-xl text-sm font-black uppercase tracking-widest focus:outline-none focus-visible:ring-2 focus-visible:ring-sky-500';
const INPUT = 'w-full min-h-[48px] border border-slate-300 rounded-xl px-3 text-base bg-white';
const LABEL = 'block text-xs font-bold text-slate-700 mb-1';

interface RecentSpend { ref: string; ledgerId: number | null; product: string; credits: number; at: number; offline: boolean; undone?: boolean }

const rosterKey = (eventId: string) => `exos:tok-roster:${eventId}`;
const queueKey = (eventId: string) => `exos:tok-queue:${eventId}`;

function readJson(key: string): unknown {
  try {
    const s = safeLocalStorage()?.getItem(key);
    return s ? JSON.parse(s) : null;
  } catch {
    return null;
  }
}
function writeJson(key: string, v: unknown): void {
  try {
    safeLocalStorage()?.setItem(key, JSON.stringify(v));
  } catch {
    /* storage full or blocked: the queue stays in memory */
  }
}

export default function TokenDoorPanel({ eventId, isOffline, canManage }: { eventId: string; isOffline: boolean; canManage: boolean }) {
  const { toast } = useToast();
  const [products, setProducts] = useState<TokenProduct[] | null>(null);
  const [tab, setTab] = useState<'take' | 'sell'>('take');
  const [productId, setProductId] = useState('');
  const [credits, setCredits] = useState(1);
  const [code, setCode] = useState('');
  const [state, dispatch] = useReducer(doorTokenReducer, DOOR_TOKEN_IDLE);
  const [roster, setRoster] = useState<TokenRoster | null>(() => parseRoster(readJson(rosterKey(eventId))));
  const [queue, setQueue] = useState<QueuedSpend[]>(() => parseQueue(readJson(queueKey(eventId))));
  const [syncing, setSyncing] = useState(false);
  const [recent, setRecent] = useState<RecentSpend[]>([]);
  const [undoing, setUndoing] = useState<string | null>(null);
  const [undoWhy, setUndoWhy] = useState('');
  const [cameraOn, setCameraOn] = useState(false);
  const lastRead = useRef<{ payload: string; at: number } | null>(null);
  const device = useRef(deviceLabel(safeLocalStorage()));
  // Sell
  const [offer, setOffer] = useState(1);
  const [qty, setQty] = useState(1);
  const [payment, setPayment] = useState<'cash' | 'comp'>('cash');
  const [topUp, setTopUp] = useState('');
  const [selling, setSelling] = useState(false);
  const [sale, setSale] = useState<TokenSale | null>(null);
  const orderKey = useRef<string>(newClientRef());

  useEffect(() => {
    let live = true;
    listTokenProducts(eventId).then((p) => {
      if (!live) return;
      setProducts(p);
      if (p.length > 0) setProductId((id) => id || p[0].id);
    }).catch(() => { if (live) setProducts([]); });
    return () => { live = false; };
  }, [eventId]);

  useEffect(() => { writeJson(queueKey(eventId), queue); }, [eventId, queue]);

  const product = products?.find((p) => p.id === productId) ?? null;

  const downloadRoster = useCallback(async () => {
    try {
      const r = parseRoster(await tokenRoster(eventId));
      if (r) {
        setRoster(r);
        writeJson(rosterKey(eventId), r);
      }
    } catch {
      /* rate limited or offline: keep the last copy */
    }
  }, [eventId]);

  const sync = useCallback(async () => {
    if (queue.length === 0 || isOffline) return;
    setSyncing(true);
    const answers: SyncAnswer[] = [];
    for (const q of queue) {
      try {
        const a = await spendTokens({ eventId, code: q.payload, productId: q.productId, credits: q.credits, ref: q.ref, offlineAt: q.at, device: q.device });
        answers.push({ ref: q.ref, reason: a.reason, spent: a.spent, short: a.short });
      } catch {
        break;   // the network went again: the rest stays queued
      }
    }
    const out = settleQueue(queue, answers);
    setQueue(out.queue);
    setSyncing(false);
    if (out.settled > 0) {
      toast({ kind: out.short ? 'error' : 'success', message: out.short
        ? `Synced ${out.settled}: ${out.short} token${out.short === 1 ? '' : 's'} were short and are on the report.`
        : `Synced ${out.settled} offline spend${out.settled === 1 ? '' : 's'}.` });
    }
    void downloadRoster();
  }, [queue, isOffline, eventId, toast, downloadRoster]);

  // Online: keep the offline copy fresh and replay what was queued.
  useEffect(() => {
    if (isOffline || !products || products.length === 0) return;
    if (queue.length > 0) void sync();
    else void downloadRoster();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOffline, products]);

  const take = useCallback(async (raw: string) => {
    if (!product) return;
    const now = Date.now();
    const parsed = parseTokenCode(raw);
    if (isRepeatRead(lastRead.current, raw.trim(), now)) return;
    lastRead.current = { payload: raw.trim(), at: now };
    const ref = newClientRef();
    const n = clampCredits(credits);
    dispatch({ type: 'scan', ref, payload: raw.trim(), credits: n });
    if (!parsed) {
      dispatch({ type: 'answer', ref, answer: { ok: false, reason: 'not-found' } });
      return;
    }
    if (isOffline) {
      const key = await cardKeyOf(parsed);
      const d = decideOffline(roster, queue, key, product.id, n, now);
      if ('reason' in d) {
        dispatch({ type: 'offline-refused', ref, reason: d.reason, available: d.available });
        return;
      }
      setQueue((q) => enqueueSpend(q, { ref, payload: parsed.payload, cardKey: key, productId: product.id, credits: n, at: now, device: device.current }));
      dispatch({ type: 'queued', ref, credits: n, remaining: d.remaining });
      setRecent((r) => [{ ref, ledgerId: null, product: product.unit_label, credits: n, at: now, offline: true }, ...r].slice(0, 10));
      return;
    }
    try {
      const a = await spendTokens({ eventId, code: parsed.payload, productId: product.id, credits: n, ref, device: device.current });
      dispatch({ type: 'answer', ref, answer: a });
      if (a.ok) {
        setRecent((r) => [{ ref, ledgerId: a.ledger_id ?? null, product: product.unit_label, credits: n, at: now, offline: false }, ...r].slice(0, 10));
      }
    } catch {
      dispatch({ type: 'failed', ref });
    }
    setCode('');
  }, [product, credits, isOffline, roster, queue, eventId]);

  const takeRef = useRef(take);
  takeRef.current = take;

  // The camera (same library and pattern as the guest-list door).
  useEffect(() => {
    if (!cameraOn) return undefined;
    let stopped = false;
    let inst: { start: (...a: unknown[]) => Promise<unknown>; stop: () => Promise<void>; clear: () => void; isScanning: boolean } | null = null;
    const shut = async () => {
      if (!inst) return;
      try {
        if (inst.isScanning) await inst.stop();
        inst.clear();
      } catch {
        /* already stopped */
      }
    };
    void (async () => {
      try {
        const { Html5Qrcode } = await import('html5-qrcode');
        if (stopped) return;
        inst = new Html5Qrcode('token-reader') as unknown as typeof inst;
        await inst!.start(
          { facingMode: 'environment' },
          { fps: 10, qrbox: (vw: number, vh: number) => { const m = Math.floor(Math.min(vw, vh) * 0.7); return { width: m, height: m }; } },
          (decoded: string) => { void takeRef.current(decoded); },
          () => {},
        );
        if (stopped) await shut();
      } catch {
        if (stopped) return;
        toast({ kind: 'error', message: 'Could not open the camera. Allow camera access, or type the code.' });
        setCameraOn(false);
      }
    })();
    return () => {
      stopped = true;
      void shut();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cameraOn]);

  const undo = async (r: RecentSpend) => {
    if (r.ledgerId == null || undoWhy.trim().length < 3) return;
    try {
      const out = await undoTokenSpend(eventId, r.ledgerId, undoWhy.trim());
      setRecent((list) => list.map((x) => (x.ref === r.ref ? { ...x, undone: true } : x)));
      toast({ kind: 'success', message: `Undone: ${out.balance} left on that code.` });
      setUndoing(null);
      setUndoWhy('');
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    }
  };

  const sell = async () => {
    if (!product) return;
    setSelling(true);
    try {
      const top = topUp.trim() ? parseTokenCode(topUp) : null;
      if (topUp.trim() && !top) throw new Error('That code isn\'t a ticket or token code.');
      const s = await sellTokens({ eventId, productId: product.id, offerCredits: offer, quantity: qty, payment, orderKey: orderKey.current,
        code: top?.payload ?? null, compReason: payment === 'comp' ? 'door comp' : null });
      setSale(s);
      orderKey.current = newClientRef();
      setTopUp('');
      void downloadRoster();
    } catch (e) {
      const hint = (e as { hint?: string }).hint;
      toast({ kind: 'error', message: hint === 'no-drawer' ? 'Open a cash drawer first (in the Sell tab).' : (e as Error).message });
    } finally {
      setSelling(false);
    }
  };

  if (products === null) {
    return <p className="text-sm text-slate-600 flex items-center gap-2"><Loader2 className="w-4 h-4 animate-spin" aria-hidden="true" /> Loading tokens…</p>;
  }
  if (products.length === 0) {
    return <p className="text-sm text-slate-600">No event tokens for this event. Owners and managers add them in Edit event → Event tokens.</p>;
  }

  const unit = product?.unit_label ?? 'token';
  const offerPrice = product?.offers?.find((o) => o.credits === offer)?.price_cents ?? 0;

  return (
    <div className="space-y-5" data-testid="token-door-panel">
      <div className="flex flex-wrap items-center gap-3">
        <div className="inline-flex p-1 bg-slate-100 rounded-xl" role="tablist" aria-label="Tokens">
          {(['take', 'sell'] as const).map((t) => (
            <button key={t} type="button" role="tab" aria-selected={tab === t} onClick={() => setTab(t)}
              className={`px-4 py-2 rounded-lg text-[11px] font-black uppercase tracking-widest ${tab === t ? 'bg-white text-slate-900 shadow-sm' : 'text-slate-700'}`}>
              {t === 'take' ? 'Take tokens' : 'Sell tokens'}
            </button>
          ))}
        </div>
        <label className="flex-1 min-w-[12rem]">
          <span className="sr-only">Token type</span>
          <select value={productId} onChange={(e) => { setProductId(e.target.value); setOffer(1); }} className={INPUT} aria-label="Token type">
            {products.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        </label>
      </div>

      {tab === 'take' ? (
        <div className="space-y-4">
          <div className="flex items-center gap-3">
            <span id="tok-amount-label" className={LABEL}>How many</span>
            <div className="inline-flex items-center gap-2" role="group" aria-labelledby="tok-amount-label">
              <button type="button" className={`${BIG} border border-slate-300`} aria-label="One less" onClick={() => setCredits((c) => clampCredits(c - 1))}>
                <Minus className="w-4 h-4" aria-hidden="true" />
              </button>
              <output className="text-3xl font-black w-12 text-center" aria-live="polite">{credits}</output>
              <button type="button" className={`${BIG} border border-slate-300`} aria-label="One more" onClick={() => setCredits((c) => clampCredits(c + 1))}>
                <Plus className="w-4 h-4" aria-hidden="true" />
              </button>
            </div>
          </div>
          <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); if (code.trim()) void take(code); }}>
            <label className="flex-1">
              <span className="sr-only">Ticket or token code</span>
              <input value={code} onChange={(e) => setCode(e.target.value)} placeholder="Scan or type a ticket or token code" className={INPUT}
                autoComplete="off" autoCapitalize="characters" />
            </label>
            <button type="submit" className={`${BIG} bg-slate-900 text-white`} disabled={!code.trim() || state.phase === 'busy'}>
              Take {credits}
            </button>
          </form>
          <button type="button" className={`${BIG} border border-slate-300 w-full`} aria-pressed={cameraOn} onClick={() => setCameraOn((c) => !c)}>
            <Camera className="inline w-4 h-4 mr-2" aria-hidden="true" />{cameraOn ? 'Stop camera' : `Scan to take ${credits} ${unit}${credits === 1 ? '' : 's'}`}
          </button>
          {cameraOn && <div id="token-reader" className="w-full max-w-sm mx-auto rounded-xl overflow-hidden" />}

          <div role="status" aria-live="polite" className="min-h-[3rem]">
            {state.phase === 'busy' && <p className="text-sm text-slate-700">Checking…</p>}
            {state.phase === 'spent' && (
              <p className="rounded-xl bg-emerald-50 text-emerald-900 p-4 text-lg font-black">
                Took {state.spent} {unit}{state.spent === 1 ? '' : 's'}.
                {state.balance != null && ` ${state.balance} left${state.offline ? ' (offline)' : ''}.`}
              </p>
            )}
            {state.phase === 'refused' && (
              <p className="rounded-xl bg-rose-50 text-rose-900 p-4 text-lg font-black">
                {tokenReasonText(state.reason)}
                {state.reason === 'insufficient' && state.balance != null && ` ${state.balance} left.`}
              </p>
            )}
          </div>

          <div className="flex flex-wrap items-center gap-3 text-xs text-slate-700">
            <span>{isOffline ? 'Offline: up to what each code had at the last download.' : 'Online.'}</span>
            {roster && <span>Downloaded {new Date(roster.syncedAt).toLocaleTimeString()}.</span>}
            {queue.length > 0 && <span className="font-bold">{queue.length} spend{queue.length === 1 ? '' : 's'} to sync.</span>}
            <button type="button" className="underline disabled:opacity-50" disabled={isOffline || syncing}
              onClick={() => void (queue.length ? sync() : downloadRoster())}>
              <RefreshCw className="inline w-3 h-3 mr-1" aria-hidden="true" />{queue.length ? 'Sync now' : 'Download for offline'}
            </button>
          </div>

          {recent.length > 0 && (
            <section aria-labelledby="tok-recent">
              <h3 id="tok-recent" className="text-xs font-black uppercase tracking-widest text-slate-700 mb-2">This device</h3>
              <ul className="space-y-2">
                {recent.map((r) => (
                  <li key={r.ref} className="flex flex-wrap items-center gap-2 text-sm">
                    <span className="flex-1">{r.credits} {r.product}{r.credits === 1 ? '' : 's'} · {new Date(r.at).toLocaleTimeString()}
                      {r.offline ? ' · queued' : ''}{r.undone ? ' · undone' : ''}</span>
                    {canManage && !r.offline && !r.undone && r.ledgerId != null && (undoing === r.ref ? (
                      <>
                        <label className="sr-only" htmlFor={`tok-why-${r.ref}`}>Why undo</label>
                        <input id={`tok-why-${r.ref}`} value={undoWhy} maxLength={300} placeholder="Why" onChange={(e) => setUndoWhy(e.target.value)}
                          className="border border-slate-300 rounded-lg px-2 py-1" />
                        <button type="button" className="underline disabled:opacity-50" disabled={undoWhy.trim().length < 3} onClick={() => void undo(r)}>Undo</button>
                      </>
                    ) : (
                      <button type="button" className="underline" onClick={() => { setUndoing(r.ref); setUndoWhy(''); }}>
                        <RotateCcw className="inline w-3 h-3 mr-1" aria-hidden="true" />Undo
                      </button>
                    ))}
                  </li>
                ))}
              </ul>
            </section>
          )}
        </div>
      ) : isOffline ? (
        <p role="alert" className="text-sm text-amber-800">Selling needs a connection: the sale and the cash are recorded on the server.</p>
      ) : (
        <form className="space-y-4" onSubmit={(e) => { e.preventDefault(); void sell(); }}>
          <div className="grid grid-cols-2 gap-3">
            <label>
              <span className={LABEL}>Bundle</span>
              <select value={offer} onChange={(e) => setOffer(Number(e.target.value))} className={INPUT}>
                {(product?.offers ?? []).map((o) => (
                  <option key={o.credits} value={o.credits}>{o.credits} {unit}{o.credits === 1 ? '' : 's'} · {formatCents(o.price_cents)}</option>
                ))}
              </select>
            </label>
            <label>
              <span className={LABEL}>Quantity</span>
              <input type="number" min={1} max={20} value={qty} className={INPUT} onChange={(e) => setQty(Math.min(20, Math.max(1, parseInt(e.target.value, 10) || 1)))} />
            </label>
          </div>
          <fieldset className="flex gap-4">
            <legend className={LABEL}>Payment</legend>
            <label className="flex items-center gap-2 text-sm font-bold"><input type="radio" name="tok-pay" checked={payment === 'cash'} onChange={() => setPayment('cash')} />Cash</label>
            {canManage && <label className="flex items-center gap-2 text-sm font-bold"><input type="radio" name="tok-pay" checked={payment === 'comp'} onChange={() => setPayment('comp')} />Comp</label>}
          </fieldset>
          <label className="block">
            <span className={LABEL}>Add to a ticket or token code (optional)</span>
            <input value={topUp} onChange={(e) => setTopUp(e.target.value)} placeholder="Leave empty for a new code" className={INPUT} autoComplete="off" />
          </label>
          <p className="text-xs text-slate-700">{product?.rule}</p>
          <button type="submit" disabled={selling} className={`${BIG} w-full bg-slate-900 text-white disabled:opacity-50`}>
            {payment === 'comp' ? `Comp ${offer * qty} ${unit}s` : `Take ${formatCents(offerPrice * qty)} · ${offer * qty} ${unit}${offer * qty === 1 ? '' : 's'}`}
          </button>
          {sale && (
            <div className="rounded-xl border border-slate-200 p-4 space-y-3 text-center" role="status">
              <p className="font-black">Sold {sale.credits} {unit}{sale.credits === 1 ? '' : 's'} · {sale.balance} on this code.</p>
              {sale.code ? (
                <>
                  <div className="bg-white inline-block p-3">
                    <QRCodeSVG value={sale.code} size={160} level="M" includeMargin={false} title="Token code QR" />
                  </div>
                  <p className="text-xl font-black tracking-widest" data-testid="token-code">{formatTokenCode(sale.code)}</p>
                  <p className="text-xs text-slate-700">Write it on the wristband or hand over the QR: it is shown only now.</p>
                </>
              ) : sale.replay ? (
                <p className="text-xs text-slate-700">This sale was already recorded; its code was shown the first time.</p>
              ) : null}
              <p className="text-xs text-slate-700">{NO_CASH_VALUE}.</p>
            </div>
          )}
        </form>
      )}
    </div>
  );
}
