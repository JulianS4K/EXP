// exos: waiting room (mig 20261118120000): expire one of our own Stripe
// Checkout sessions (the platform account; never a third party's) when the
// same buyer takes over their turn (exos-checkout) or ends a lapsed turn's
// open checkout to join again (exos-wroom-join, end_checkout).
// Stripe only expires a session that is `open`: a `complete` one (paid, or
// paid with an async method still processing) or an `expired` one is refused,
// so on an error we read the session and report where it stands. Callers go
// ahead only on "expired".
import Stripe from "https://esm.sh/stripe@16?target=deno";
import type { StripeEnd } from "./wroomCheckout.ts";

export async function expireOwnStripeSession(stripeKey: string | undefined, id: string): Promise<StripeEnd> {
  if (!stripeKey || !/^cs_[A-Za-z0-9_]{1,250}$/.test(id)) return "unknown";
  const st = new Stripe(stripeKey, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" });
  try {
    const s = await st.checkout.sessions.expire(id);
    return s.status === "expired" ? "expired" : "unknown";
  } catch (e) {
    try {
      const s = await st.checkout.sessions.retrieve(id);
      return s.status === "expired" || s.status === "complete" || s.status === "open" ? s.status : "unknown";
    } catch {
      console.error("exos waiting room: Stripe session expire failed", e);
      return "unknown";
    }
  }
}
