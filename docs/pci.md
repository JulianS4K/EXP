# PCI DSS: Exos is SAQ A

Card data never touches Exos. Buyers type their card into Stripe's own pages (or pay through PayPal / Venmo on
PayPal's), so Exos is a **SAQ A** merchant
(the shortest self-assessment, PCI DSS v4.0.1). This doc is what an RFP's "PCI compliance" line points to, and
what keeps us eligible for SAQ A as the product grows.

## Why SAQ A

| Where a card is entered | What it is | PCI effect |
|---|---|---|
| Event page → **Stripe Checkout** (redirect to `checkout.stripe.com`) | Stripe-hosted page | SAQ A |
| Venue embed (`/bridge/embed/event/:id`) → **Stripe Embedded Checkout** | Stripe's iframe on our page | SAQ A, as long as our page can't be tampered with (below) |
| Event page → **Cash App Pay** (on Stripe Checkout, mig 20261031220000) | Stripe-hosted page, next to cards | SAQ A, same as cards |
| Event page → **Pay with Venmo / PayPal** → `/bridge/pay/paypal` | PayPal's JS SDK buttons (PayPal / Venmo log-ins in PayPal's windows; card funding switched off) on a page of its own | No card data on our page. See "PayPal / Venmo" below |
| Box office (`exos-pos`) | Cash and comp only; card is `501` (`docs/pos.md`) | Out of scope until Stripe Terminal is wired |

- No Exos code, table, log or email holds a card number, CVC or expiry. Exos keeps Stripe ids
  (`cs_…`, `pi_…`, `ch_…`) and amounts only (`grep -rn "last4\|card_number\|cvc" src supabase` finds nothing).
- Payment confirmation comes from Stripe's signed webhook (`stripe-webhook`), not from the browser.
- Organizers are paid through Stripe Connect; Exos never sees their bank details.

## What keeps us eligible (built)

| PCI DSS v4.0.1 | Control | Where |
|---|---|---|
| SAQ A eligibility: the page holding Stripe's iframe isn't open to script attacks | The embed page's CSP allows scripts from `'self'` and `js.stripe.com` only: no ad pixels, no Maps, no inline scripts. A test pins it. | `src/lib/hosting/headers.ts`, `headers.test.ts` ("the card page …") |
| 6.3.3 known vulnerabilities patched | CI fails on any high or critical advisory in a runtime dependency; Dependabot opens weekly updates | `.github/workflows/ci.yml` (Dependency audit), `.github/dependabot.yml` |
| 6.4.3 / 11.6.1 payment-page scripts | Not required for redirect / iframe merchants under SAQ A (removed Jan 2025), but the CSP above is how we'd show it anyway | as above |
| 4.2.1 strong cryptography in transit | HTTPS only, HSTS two years | `securityHeaders` (`hsts`) |
| 8.3 / 8.4 MFA on admin access | See operator checklist | — |
| 12.8 third-party service providers | Stripe (Level 1 service provider), Supabase, Render: each keeps its own attestation | see below |

**Rule for new work:** never add a script, pixel, chat widget or analytics tag to `/bridge/embed/*` or any page
that renders a Stripe card field. If a page ever needs Stripe Elements (card fields on our page), re-read this doc
first: that's still SAQ A only with the same script lock-down.

## PayPal / Venmo (operator approval 2026-10-30)

PayPal is a second processor, added to take Venmo. **PayPal's JS SDK is never loaded on a page that has a Stripe
card field**, and Stripe's is never loaded on the PayPal page:

- The event page has no card field (Stripe Checkout is a redirect). Its "Pay with Venmo / PayPal" button does a
  full page load to `/bridge/pay/paypal` (`src/views/PayPalCheckout.tsx`), so no script from the event page carries
  over. The SDK is injected only there.
- That path has its own CSP: `script-src 'self'` plus PayPal's and Venmo's hosts, no `js.stripe.com`, no pixels, no
  Maps (`src/lib/hosting/headers.ts` `isPayPalPagePath`). Every other page's CSP leaves PayPal out, the embed (Stripe
  Embedded Checkout) included. `headers.test.ts` pins both directions.
- The venue embed (`/bridge/embed/*`) never offers PayPal (`exos-checkout` refuses `processor: 'paypal'` with
  `ui_mode: 'embedded'`).
- The SDK is loaded with `disable-funding=card,credit,paylater`: PayPal's own guest card form is off, so the only
  ways to pay there are a PayPal or Venmo account, in PayPal's windows.
- A redirect flow (`paypal_flow: 'redirect'`, PayPal's hosted approval page, back to `/bridge/pay/paypal/return`)
  exists for browsers where the buttons won't render.
- Payment confirmation comes from the capture call and PayPal's verified webhook (`exos-paypal`), not the browser.
  Exos keeps PayPal ids (order, capture `ppcap_…`, refund `pprf_…`) and amounts only.
- PayPal is a PCI DSS Level 1 service provider; add its AOC to the bid kit next to Stripe's.

**Box office cards:** when Stripe Terminal is wired (`docs/pos.md`), use Stripe's readers only (card data stays
in the reader). Re-check the SAQ type then (likely SAQ B-IP or a P2PE assessment) before taking a card.

## Operator checklist (once, then yearly)

1. **SAQ A in Stripe.** Dashboard → Settings → Compliance → complete the SAQ A questionnaire. Stripe generates
   the SAQ A and the Attestation of Compliance (AOC) as PDFs. Redo every 12 months.
2. **Stripe's own AOC.** Download Stripe's PCI Level 1 service-provider AOC (Dashboard → Settings → Compliance,
   or stripe.com/docs/security). RFPs ask for both: ours (SAQ A) and the processor's.
3. **MFA everywhere with admin access:** Stripe, Supabase, Render, GitHub, the domain registrar, Google Workspace.
4. **External vulnerability scan** (SAQ A 11.3.2, quarterly) of the public site by a PCI-approved scanning
   vendor. Stripe's SAQ flow says whether it applies to our integration; if it does, keep the passing reports.
5. **Incident response (12.10.1):** if a card-related incident is suspected, roll Stripe keys
   (`docs/payments-go-live.md`), tell Stripe support, and record it in `bot_chat`.
6. Keep the PDFs (SAQ A, our AOC, Stripe's AOC, scan reports) in the bid kit folder for RFP answers.

## RFP answer (paste-ready)

> Exos does not store, process or transmit cardholder data. Card entry happens on Stripe-hosted Checkout or
> Stripe's Embedded Checkout iframe; Stripe is a PCI DSS Level 1 service provider. Exos validates annually as a
> SAQ A merchant under PCI DSS v4.0.1 (SAQ A and AOC attached, with Stripe's AOC). Pages that host payment
> fields load only first-party and Stripe scripts under a Content Security Policy, and runtime dependencies are
> scanned on every change.
