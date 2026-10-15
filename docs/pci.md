# PCI DSS: Exos is SAQ A

Card data never touches Exos. Buyers type their card into Stripe's own pages, so Exos is a **SAQ A** merchant
(the shortest self-assessment, PCI DSS v4.0.1). This doc is what an RFP's "PCI compliance" line points to, and
what keeps us eligible for SAQ A as the product grows.

## Why SAQ A

| Where a card is entered | What it is | PCI effect |
|---|---|---|
| Event page → **Stripe Checkout** (redirect to `checkout.stripe.com`) | Stripe-hosted page | SAQ A |
| Venue embed (`/bridge/embed/event/:id`) → **Stripe Embedded Checkout** | Stripe's iframe on our page | SAQ A, as long as our page can't be tampered with (below) |
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
