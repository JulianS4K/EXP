# Guest checkout: what the paying browser carries

A guest pays with just an email. The browser that paid has to carry a few
things across the trip to Stripe or PayPal and back. Instagram and Facebook's
in-app browsers (and other webviews) can block localStorage, sessionStorage
and cookies, so each one also has a carrier that needs no storage.

Proof of email (mig 20261105100000) is described in
[`payments-go-live.md`](payments-go-live.md) ("Proof of email before the tickets
are released"); the RPCs and their limits are in [`security.md`](security.md).
In-app browser detection, escapes and the report are mig 20261105140000
(`src/lib/inAppBrowser.ts`, `supabase/functions/_shared/inAppBrowser.ts`).

| What | Normal browser | Storage blocked (in-app) | Who sees it | Why it's safe there |
|---|---|---|---|---|
| Cart from a checkout link | the page's prefill (storage) | `?cart=` on the event URL (`src/lib/checkoutLink.ts`) | our host, like any link | Not secret; the server re-prices everything |
| PayPal cart (event page to `/pay/paypal`) | sessionStorage | `#cart=` fragment (`src/lib/paypal.ts`) | the browser only | Not secret; re-priced by exos-checkout |
| The inbox on the "payment received" page | localStorage (`exos.guestEmail`) | `?to=j***@gmail.com` on the success URL | our host, Stripe | Masked: first letter and domain only |
| Proof token (releases the tickets together with the mailed code) | localStorage (`exos:proof:<order>`) | `#pt=<token>` fragment on the return URL: exos-checkout adds it to Stripe's `success_url` and PayPal's redirect `return_url`; the SPA adds it to its own redirects (free order, gift card, after the PayPal capture) | the browser; Stripe and PayPal keep the full return URL on their side | A fragment is never sent in a request or a Referer, and the page strips it with `history.replaceState` as soon as it reads it, before the org's pixels load. **The token alone releases nothing**: the 6-digit code emailed to the buyer (or an SMS code) is still needed, 5 wrong codes lock it, and a wrong token answers like no order |

Notes on the proof token's fragment:

- Read by `takeProofTokenFromUrl` (`src/lib/orderProof.ts`), kept in memory for
  the page load, and passed to `OrderProofPanel`. `recallProofToken` tries
  localStorage, then memory, then the fragment.
- PayPal appends `?token=…&PayerID=…` to the return URL. `orderIdFromReturn`
  reads the order id from the query or, should PayPal put it after our
  fragment (`#pt=…?token=…`), from the fragment.
- The embedded (venue iframe) checkout doesn't get one: it signs in first and
  finishes in place.
- If a provider ever dropped fragments, the next carrier would be a query
  parameter, which our host's access logs and a Referer could see. The token
  being worthless without the code is what would make that acceptable; it is
  not used today.
