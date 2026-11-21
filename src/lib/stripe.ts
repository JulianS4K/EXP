// /pure: importing this module loads nothing; js.stripe.com is fetched only when
// loadStripe() runs (the default entry injects the script on import).
import { loadStripe } from '@stripe/stripe-js/pure';
import type { Stripe } from '@stripe/stripe-js';
import { nativeBuildFlags } from './platform/native';

// Stripe lives in its own module so that views which only need helpers like
// formatCurrency (Home, MyTickets, OrganizerDashboard) don't drag the Stripe
// SDK into the initial bundle. Only EventDetails currently calls getStripe().
let stripePromise: Promise<Stripe | null> | undefined;

export const getStripe = () => {
  // PCI (docs/pci.md): the native app never hosts a Stripe card field. It
  // pays on Stripe's hosted Checkout in the browser sheet instead.
  if (!nativeBuildFlags().stripeJs) return Promise.reject(new Error('Card fields are not available in the app. Use hosted Checkout.'));
  if (!stripePromise) {
    const key = (import.meta as any).env?.VITE_STRIPE_PUBLISHABLE_KEY;
    if (!key) {
      console.warn('VITE_STRIPE_PUBLISHABLE_KEY not set. Checkout will fail.');
    }
    stripePromise = loadStripe(key || '');
  }
  return stripePromise;
};
