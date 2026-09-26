// Mounts Stripe Embedded Checkout for a session client secret (exos-checkout
// ui_mode 'embedded'). Card payments finish in place and call onComplete;
// redirect-based methods come back through /embed/return instead.

import { useEffect, useRef, useState } from 'react';
import type { StripeEmbeddedCheckout } from '@stripe/stripe-js';
import { getStripe } from '../lib/stripe';

export default function EmbeddedCheckoutMount({
  clientSecret,
  onComplete,
}: {
  clientSecret: string;
  onComplete: () => void;
}) {
  const el = useRef<HTMLDivElement>(null);
  const done = useRef(onComplete);
  done.current = onComplete;
  const [error, setError] = useState('');

  useEffect(() => {
    let cancelled = false;
    let checkout: StripeEmbeddedCheckout | null = null;
    (async () => {
      try {
        const stripe = await getStripe();
        if (!stripe) throw new Error('Stripe did not load.');
        const c = await stripe.createEmbeddedCheckoutPage({
          fetchClientSecret: () => Promise.resolve(clientSecret),
          onComplete: () => done.current(),
        });
        // Unmounted while loading (StrictMode double effect, fast Back): only
        // one Embedded Checkout may exist per page, so drop this one.
        if (cancelled || !el.current) {
          c.destroy();
          return;
        }
        checkout = c;
        c.mount(el.current);
      } catch (err) {
        console.error('Embedded checkout failed:', err);
        if (!cancelled) setError('Checkout could not load. Try again, or open the event on Exos.');
      }
    })();
    return () => {
      cancelled = true;
      checkout?.destroy();
    };
  }, [clientSecret]);

  return (
    <div>
      {error && <p className="text-xs text-red-400 mb-2" role="alert">{error}</p>}
      <div ref={el} className="min-h-[360px] bg-white" />
    </div>
  );
}
