// GuestCheckoutModal: pay with just an email (mig 20260928050000). Shown when a
// signed-out buyer taps Buy on a paid ticket. Tickets go to the Exos account
// with that email, or arrive as claim links (sign in later with a one-time
// code, no password). "Sign in instead" keeps the old path.

import { FormEvent, useState } from 'react';
import { AnimatePresence, motion } from 'motion/react';
import { Mail, X } from 'lucide-react';
import { isGuestEmail } from '../lib/guestCheckout';

const LAST_EMAIL_KEY = 'exos.guestEmail';

interface GuestCheckoutModalProps {
  open: boolean;
  busy?: boolean;
  onClose: () => void;
  onContinue: (email: string) => void;
  onSignIn: () => void;
}

export default function GuestCheckoutModal({ open, busy, onClose, onContinue, onSignIn }: GuestCheckoutModalProps) {
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
    <AnimatePresence>
      {open && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          className="fixed inset-0 z-50 bg-black/70 flex items-end md:items-center justify-center p-4"
          onClick={onClose}
          role="dialog"
          aria-modal="true"
          aria-labelledby="guest-checkout-title"
        >
          <motion.form
            initial={{ y: 24, opacity: 0 }}
            animate={{ y: 0, opacity: 1 }}
            exit={{ y: 24, opacity: 0 }}
            className="w-full max-w-md bg-black border border-white/10 p-6"
            onClick={(e) => e.stopPropagation()}
            onSubmit={submit}
          >
            <div className="flex items-start justify-between mb-4">
              <h2 id="guest-checkout-title" className="text-2xl font-black uppercase italic tracking-tighter text-white">
                Where should we send your tickets?
              </h2>
              <button type="button" onClick={onClose} aria-label="Close" className="p-1 text-white/40 hover:text-white transition-all">
                <X className="w-5 h-5" />
              </button>
            </div>
            <p className="text-white/60 text-sm mb-4">
              No account needed. Pay with Apple Pay, Google Pay or card, and we'll email your tickets. To show your
              QR at the door, open the email and sign in with a one-time code.
            </p>
            <label htmlFor="guest-email" className="type text-[11px] text-white/60 uppercase tracking-widest">Email</label>
            <div className="mt-1 mb-2 flex items-center gap-2 bg-white/5 border border-white/20 focus-within:border-brand-primary px-3">
              <Mail className="w-4 h-4 text-white/40" aria-hidden="true" />
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
                className="w-full bg-transparent py-3 text-white focus:outline-none"
                placeholder="you@example.com"
              />
            </div>
            {touched && !valid && <p className="text-red-400 text-xs mb-2" role="alert">Enter a valid email.</p>}
            <button
              type="submit"
              disabled={busy}
              className="w-full mt-2 bg-brand-primary text-black font-black uppercase tracking-wider py-4 disabled:opacity-50"
            >
              {busy ? 'Starting checkout…' : 'Continue to payment'}
            </button>
            <button
              type="button"
              onClick={onSignIn}
              className="w-full mt-3 text-white/60 hover:text-white text-sm underline underline-offset-4"
            >
              Have an account? Sign in instead
            </button>
          </motion.form>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
