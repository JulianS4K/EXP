// /pay/paypal — "Pay with Venmo / PayPal" (mig 20261031220000).
//
// Its own page on purpose: PayPal's JS SDK loads here and nowhere else, and
// nothing from Stripe is on it (docs/pci.md; the CSP for this path allows
// PayPal's hosts and not js.stripe.com, src/lib/hosting/headers.ts). The cart
// comes from the event page (lib/paypal.ts stashPayPalCart); the price is the
// server's (exos-checkout prices it exactly as a Stripe checkout).
//
//   createOrder -> exos-checkout { processor: 'paypal' } (holds the seats)
//   onApprove   -> exos-paypal { action: 'capture' } -> My Tickets
//   onCancel    -> exos-paypal { action: 'cancel' } (seats back now)
// /pay/paypal/return is PayPal's redirect-flow return (?token=<order id>).

import { useEffect, useRef, useState, type ReactNode } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { ArrowLeft, Loader2 } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import {
  cancelPayPalOrder, capturePayPalOrder, createPayPalOrder, orderIdFromReturn, paypalClientId, paypalSdkUrl,
  readPayPalCart, venmoPossible, type PayPalCart,
} from '../lib/paypal';
import { formatCurrency, publicUrl } from '../lib/utils';

interface PayPalButtonsApi {
  Buttons(opts: Record<string, unknown>): { isEligible(): boolean; render(el: HTMLElement): Promise<void>; close?(): void };
  FUNDING: { PAYPAL: string; VENMO: string };
}
declare global {
  interface Window { paypal?: PayPalButtonsApi }
}

let sdkPromise: Promise<PayPalButtonsApi> | null = null;
function loadSdk(url: string): Promise<PayPalButtonsApi> {
  if (window.paypal) return Promise.resolve(window.paypal);
  sdkPromise ??= new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = url;
    s.async = true;
    s.onload = () => (window.paypal ? resolve(window.paypal) : reject(new Error('PayPal did not load')));
    s.onerror = () => { sdkPromise = null; reject(new Error('PayPal did not load')); };
    document.head.appendChild(s);
  });
  return sdkPromise;
}

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export default function PayPalCheckout() {
  const { user } = useAuth();
  const location = useLocation();
  const isReturn = location.pathname.endsWith('/return');
  const [cart] = useState<PayPalCart | null>(() => readPayPalCart());
  const [email, setEmail] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(isReturn ? 'Confirming your payment…' : null);
  const venmoRef = useRef<HTMLDivElement>(null);
  const paypalRef = useRef<HTMLDivElement>(null);
  const orderRef = useRef<string | null>(null);
  const clientId = paypalClientId();
  const guestReady = !!user || EMAIL_RE.test(email.trim());

  const done = (sessionId?: string) => {
    // A full page load leaves PayPal's SDK (and this page's CSP) behind.
    window.location.replace(publicUrl(`my-tickets?checkout=success&processor=paypal${user ? '' : '&guest=1'}${sessionId ? `&order=${encodeURIComponent(sessionId)}` : ''}`));
  };

  const capture = async (orderId: string) => {
    setBusy('Confirming your payment…');
    setError(null);
    try {
      const r = await capturePayPalOrder(orderId);
      if (r.status === 'fulfilled' || r.status === 'partially_refunded') return done(r.sessionId);
      if (r.status === 'pending') {
        setBusy(null);
        setError('PayPal is still processing this payment. Your tickets will appear in My Tickets once it clears.');
        return;
      }
      setBusy(null);
      setError('Those tickets were no longer available, so the payment is being refunded.');
    } catch (e) {
      setBusy(null);
      setError((e as Error).message);
    }
  };

  // Redirect flow: PayPal sent the buyer back with the order id.
  useEffect(() => {
    if (!isReturn) return;
    const id = orderIdFromReturn(location.search);
    if (id) void capture(id);
    else { setBusy(null); setError('That PayPal link is missing its order.'); }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isReturn]);

  // The buttons: shown once we know who the tickets go to.
  useEffect(() => {
    if (isReturn || !cart || !clientId || !guestReady) return undefined;
    let alive = true;
    const rendered: { close?(): void }[] = [];
    loadSdk(paypalSdkUrl(clientId, cart.currency)).then((paypal) => {
      if (!alive) return;
      const common = {
        style: { layout: 'vertical', shape: 'rect', height: 48 },
        createOrder: async () => {
          setError(null);
          const o = await createPayPalOrder(cart, {
            guestEmail: user ? undefined : email.trim(),
            successUrl: publicUrl('pay/paypal/return'),
            cancelUrl: publicUrl(`event/${cart.eventId}`),
          });
          orderRef.current = o.orderId;
          return o.orderId;
        },
        onApprove: async (d: { orderID?: string }) => { await capture(d.orderID ?? orderRef.current ?? ''); },
        onCancel: (d: { orderID?: string }) => { void cancelPayPalOrder(d.orderID ?? orderRef.current ?? ''); },
        onError: (e: unknown) => { setError((e as Error)?.message || 'PayPal ran into a problem. Try again.'); },
      };
      const sources: [string, HTMLDivElement | null][] = [
        ...(venmoPossible(cart.currency) ? [[paypal.FUNDING.VENMO, venmoRef.current] as [string, HTMLDivElement | null]] : []),
        [paypal.FUNDING.PAYPAL, paypalRef.current],
      ];
      for (const [fundingSource, el] of sources) {
        if (!el) continue;
        el.replaceChildren();
        const b = paypal.Buttons({ ...common, fundingSource });
        if (b.isEligible()) { rendered.push(b); void b.render(el); }
      }
    }).catch((e) => setError((e as Error).message));
    return () => { alive = false; rendered.forEach((b) => b.close?.()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cart?.eventId, clientId, guestReady, isReturn]);

  if (!clientId) {
    return <Shell><p className="text-slate-500">Paying with PayPal isn't switched on.</p></Shell>;
  }
  if (!isReturn && !cart) {
    return (
      <Shell>
        <p className="text-slate-500 mb-4">Pick your tickets on the event page first.</p>
        <Link to="/" className="text-brand-primary font-bold">Browse events</Link>
      </Shell>
    );
  }
  return (
    <Shell back={cart ? `/event/${cart.eventId}` : undefined}>
      {cart && !isReturn && (
        <div className="mb-6">
          <p className="text-[10px] font-black uppercase tracking-widest text-slate-400">Your order</p>
          <p className="text-lg font-black text-slate-900">{cart.title}</p>
          <p className="text-sm text-slate-500">
            {cart.quantity} ticket{cart.quantity > 1 ? 's' : ''}
            {cart.displayCents != null ? ` · ${formatCurrency(cart.displayCents / 100, cart.currency)} all in` : ''}
          </p>
        </div>
      )}
      {!user && !isReturn && (
        <label className="block mb-6">
          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Email for your tickets</span>
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            autoComplete="email"
            className="mt-1 w-full border-2 border-slate-200 rounded-xl px-4 py-3 font-bold focus:outline-none focus:border-brand-primary"
            placeholder="you@example.com"
          />
        </label>
      )}
      {busy && (
        <p className="flex items-center gap-2 text-slate-600 font-bold mb-4"><Loader2 className="w-4 h-4 animate-spin" />{busy}</p>
      )}
      {error && <p role="alert" className="text-red-600 text-sm font-bold mb-4">{error}</p>}
      {!isReturn && guestReady && (
        <div className={busy ? 'opacity-40 pointer-events-none' : ''}>
          <div ref={venmoRef} className="mb-3" />
          <div ref={paypalRef} />
          {cart && venmoPossible(cart.currency) && (
            <p className="text-xs text-slate-400 mt-3">Venmo shows up on US phones and browsers where you're signed in to Venmo.</p>
          )}
        </div>
      )}
      <p className="text-xs text-slate-400 mt-8">
        Paying by card? Go back and use <strong>Buy tickets</strong>; card payments are handled by Stripe on a separate page.
      </p>
    </Shell>
  );
}

function Shell({ children, back }: { children: ReactNode; back?: string }) {
  return (
    <div className="max-w-md mx-auto px-4 py-12">
      {back && (
        <Link to={back} className="inline-flex items-center gap-2 text-slate-500 text-sm font-bold mb-6">
          <ArrowLeft className="w-4 h-4" /> Back to the event
        </Link>
      )}
      <h1 className="text-2xl font-black text-slate-900 mb-6">Pay with Venmo or PayPal</h1>
      {children}
    </div>
  );
}
