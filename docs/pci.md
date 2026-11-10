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
| Box office (`exos-pos`) | Cash and comp; a card only on a Stripe Terminal reader when `EXOS_POS_CARD=on` (`docs/pos.md` "Card at the door"). The reader reads the card; Exos sends and keeps the PaymentIntent id only | Card-present: the card is read and encrypted inside Stripe's PCI PTS readers; see "Box office cards" |
| Self-serve kiosk (`/kiosk`, mig 20261113100000) | A card on the kiosk's own Stripe Terminal reader only; the page has no card field and no payment script | The web page: SAQ A. The reader: as the box office |

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

**Box office cards:** Stripe Terminal is wired (mig 20261107130000, off until `EXOS_POS_CARD=on`). Only Stripe's
readers take the card (smart readers driven from the server; Tap to Pay later in a native app), and the card data
stays in the reader: no Exos page, request, table or log sees it (`exos-pos` refuses any card-looking field; the
Sell tab has no card field and loads no script). Before the first live card, re-check the SAQ type with Stripe
(card-present usually adds SAQ B-IP or a P2PE assessment to SAQ A).

**Kiosk mode** (mig 20261113100000, `docs/pos.md` "Kiosk mode") doesn't change this: the self-serve screen
(`/kiosk`) is the same SPA with **no card field and no payment script**; the buyer pays on the kiosk's Stripe
Terminal reader, and the page sends only ids (`exos-pos` refuses any card-looking field, the smoke test checks every
kiosk call). The web side stays **SAQ A**; the reader's card-present scope is the box-office question above.
Running the tablet in single-app mode keeps the public off anything but the kiosk page.

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

## Accessibility conformance (WCAG 2.1 AA)

College and municipal RFPs make WCAG 2.1 AA pass/fail (and ADA Title II applies to public buyers). This section is
the code-side evidence; GTM turns it into a VPAT 2.5 (WCAG edition). It lives here because it's the same bid kit.

**Checked automatically, on every change (CI):**

| Check | What fails the build | Where |
|---|---|---|
| axe-core 4.14 (`@axe-core/playwright`) on the built app, mocked backend | Any `serious` or `critical` violation of the `wcag2a`, `wcag2aa`, `wcag21a`, `wcag21aa` rules. `moderate` / `minor` ones and axe's "needs review" count are printed | `tests/smoke/a11y.mjs`, run by `npm run smoke` (CI job "Browser smoke") |
| Keyboard, in the same run | The first Tab stop is "Skip to content" and it moves focus into `<main>`; a seat in the seat list is picked with Enter | same |
| `eslint-plugin-jsx-a11y` (recommended rules) on `src/` | Any error or warning (`--max-warnings 0`) | `npm run lint:a11y`, `eslint.config.js` (CI job "TypeScript") |

Lint deviations from the recommended set (`eslint.config.js` says why): `no-autofocus` is off (every autofocus follows
a user action, such as a dialog or editor opening, or the door's scan box); `aria-role` ignores our components' own
`role` prop; labels may nest their text up to 4 levels.

**Pages covered by axe:** the event page (`/e/:slug` → `/event/:id`, phone and desktop), the cookie banner, the seat
picker (map, then list with a seat picked), checkout (the guest email dialog; back from Stripe to the confirmation),
My Tickets, the ticket (code locked, and with the rotating entry QR live), transfer a ticket, the Door app
(`/door`, signed out and signed in), the staff door scanner (`/checkin/:eventId`), the four app landing pages
(`/apps/door`, `/apps/events`, `/apps/promote`, `/apps/money`), the neighborhood pages (`/nyc`, and
`/nyc/:neighborhood` on phone and desktop), the mail's unfollow page (`/unfollow`) and the self-serve kiosk
(`/kiosk`: pick, questions, paid with the QR, the staff PIN dialog; the same run also fails a kiosk button under
48 px or one without a visible focus ring). The scans run with the browser set to reduced motion.

**Built in for assistive tech:** a skip link and `nav` / `main` / `footer` landmarks; `<html lang>` follows the EN /
ES switch; the seat picker's list view has one toggle button per seat, named with section, row, seat, price and
wheelchair / companion / restricted-view flags (the SVG map is `role="img"` and points to the list); errors are
`role="alert"` (checkout email, checkout questions, seat picker) and toasts are a polite live region; the quantity
is announced when it changes; the event countdown and the QR's 30-second rotation are `role="timer"`, so they aren't
read out on every tick; the entry QR has a text name. Reduced motion (the OS setting, WCAG 2.3.3): `MotionConfig
reducedMotion="user"` at the app root turns slides and scaling off, and `useMotionGate` (`src/lib/motion.ts`) skips
every fade-in, so content shows at full opacity at once; everyone else keeps the animations. The door scanner's small
text is slate-500 on white and slate-600 on grey, and `brand-secondary-ink` (#B000B0) where the magenta is text.

**Known exceptions:**

1. **Stripe's card pages.** Stripe Checkout (a redirect) and the Embedded Checkout iframe on the venue embed are
   Stripe's documents. The axe run excludes `iframe[src*="stripe.com"]` and nothing else. For those, cite Stripe's
   own Accessibility Conformance Report (VPAT) for Checkout, which Stripe provides on request; add it to the bid
   kit next to Stripe's AOC. The same goes for PayPal's buttons and windows on `/bridge/pay/paypal`.
2. **The seat map drawing** isn't operable by keyboard; the list view is the keyboard and screen-reader
   equivalent, one toggle away.
3. **What automation can't see** (roughly half of WCAG): a manual pass with VoiceOver (iOS / macOS) and NVDA,
   200% zoom and 320px reflow, focus order through dialogs, and captions on organizer-supplied event videos. That
   manual pass, or a third-party audit, is what turns this into a signed VPAT.

**Re-run:** `npm run smoke` (axe after the smoke tests; `SMOKE_PORT=4175` for another port, `SMOKE_CHROMIUM=<path>`
for a local browser) and `npm run lint:a11y`. To cover a new page, add a `check(...)` to `tests/smoke/a11y.mjs`.
