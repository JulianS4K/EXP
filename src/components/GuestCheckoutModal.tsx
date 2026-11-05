// GuestCheckoutModal: pay with just an email (mig 20260928050000). Shown when a
// signed-out buyer taps Buy on a paid ticket. Tickets go to the Exos account
// with that email, or arrive as claim links (sign in later with a one-time
// code, no password). "Sign in instead" keeps the old path.

import { FormEvent, useState } from 'react';
import Dialog from './Dialog';
import { Mail, X } from 'lucide-react';
import { isGuestEmail } from '../lib/guestCheckout';
import { currentInAppState, escapeReasons } from '../lib/inAppBrowser';
import { EscapeHatch } from './InAppBrowserBanner';

const LAST_EMAIL_KEY = 'exos.guestEmail';

interface GuestCheckoutModalProps {
  open: boolean;
  busy?: boolean;
  onClose: () => void;
  onContinue: (email: string) => void;
  onSignIn: () => void;
  /** Free tickets: no payment step; the claim links are emailed right away. */
  free?: boolean;
  /** In an in-app browser: what "open in your browser" should open (the cart's checkout link). */
  escapeUrl?: string;
}

export default function GuestCheckoutModal({ open, busy, onClose, onContinue, onSignIn, free = false, escapeUrl }: GuestCheckoutModalProps) {
  // Inside Instagram / Facebook: card works here, wallets usually don't.
  const [inApp] = useState(currentInAppState);
  const walletsHere = !inApp.kind || escapeReasons(inApp).every((r) => r === 'storage');
  const [email, setEmail] = useState(() => {
    try { return localStorage.getItem(LAST_EMAIL_KEY) ?? ''; } catch { return ''; }
  });
  const [touched, setTouched] = useState(false);
  const valid = isGuestEmail(email);

  const submit = (e: FormEvent) => {
    e.preventDefault();
    setTouched(true);
    if (!valid || busy) return;
    const clean = email.trim().toLowerCase();
    try { localStorage.setItem(LAST_EMAIL_KEY, clean); } catch { /* storage blocked */ }
    onContinue(clean);
  };

  return (
    <Dialog open={open} onClose={onClose} labelledBy="guest-checkout-title" placement="sheet" dismissible={!busy}>
          <form onSubmit={submit} noValidate>
            <div className="flex items-start justify-between mb-4">
              <h2 id="guest-checkout-title" className="text-2xl font-black uppercase italic tracking-tighter text-white">
                Where should we send your tickets?
              </h2>
              <button type="button" onClick={onClose} aria-label="Close" className="p-1 text-white/60 hover:text-white transition-all focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary">
                <X className="w-5 h-5" />
              </button>
            </div>
            <p className="text-white/60 text-sm mb-4">
              {free
                ? "No account needed. We'll email your free tickets. To show your QR at the door, open the email and sign in with a one-time code."
                : `No account needed. Pay with ${walletsHere ? 'Apple Pay, Google Pay or card' : 'card'}, and we'll email your tickets. To show your QR at the door, open the email and sign in with a one-time code.`}
            </p>
            {!free && !walletsHere && (
              <EscapeHatch url={escapeUrl} state={inApp} lead="Card works right here."
                className="mb-4 border border-white/10 bg-white/5 p-3 text-xs text-white/70" />
            )}
            <label htmlFor="guest-email" className="type text-[11px] text-white/60 uppercase tracking-widest">Email</label>
            <div className="mt-1 mb-2 flex items-center gap-2 bg-white/5 border border-white/20 focus-within:border-brand-primary focus-within:ring-2 focus-within:ring-brand-primary/40 px-3">
              <Mail className="w-4 h-4 text-white/60" aria-hidden="true" />
              <input
                id="guest-email"
                type="email"
                inputMode="email"
                autoComplete="email"
                autoFocus
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                onBlur={() => setTouched(true)}
                aria-invalid={touched && !valid}
                aria-describedby={touched && !valid ? 'guest-email-error' : undefined}
                className="w-full bg-transparent py-3 text-white focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60"
                placeholder="you@example.com"
              />
            </div>
            {touched && !valid && <p id="guest-email-error" className="text-red-400 text-xs mb-2" role="alert">Enter a valid email.</p>}
            <button
              type="submit"
              disabled={busy}
              className="w-full mt-2 bg-brand-primary text-black font-black uppercase tracking-wider py-4 disabled:opacity-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white"
            >
              {free ? (busy ? 'Sending…' : 'Send my tickets') : (busy ? 'Starting checkout…' : 'Continue to payment')}
            </button>
            <button
              type="button"
              onClick={onSignIn}
              className="w-full mt-3 text-white/60 hover:text-white text-sm underline underline-offset-4"
            >
              Have an account? Sign in instead
            </button>
          </form>
    </Dialog>
  );
}
