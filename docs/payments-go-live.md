# Payments go-live runbook

How to switch Exos payments on. **Status (2026-09-24): payments are dormant on purpose.** The three
payment functions have never been deployed, and no Stripe webhook is registered. Every step
below that touches production (secrets, deploys, the Stripe dashboard, applying migrations) is an
operator action. Nothing in this runbook should run without the operator's go-ahead.

While the database is shared with Terminal-2, the functions are deployed from
`Terminal-2/supabase/functions/` to project `hzrizjeaxlqcxfrtczpq`. This repo keeps copies (see
`supabase/README.md`).

## Pricing model: all-in (operator decision 2026-09-24)

Every price a buyer sees is the full amount they pay. Buyers are charged **no service fee**: the
platform fee is a Stripe application fee taken from the organizer's share. Exclusive tax is added
**per ticket, inside the displayed price**. `allInCents` in `supabase/functions/_shared/pricing.ts`
and `allInPrice` in `src/lib/pricing.ts` must stay identical, and `pricingParity.test.ts` enforces
that. If a buyer-paid fee is ever added, it has to go into that same all-in figure, never onto a
separate checkout line. (The FTC's rule on live-event ticket fees is the external reason; confirm
the details with counsel.)

## 0. Before you start

- [ ] Migrations `20260924215000`, `…223000`, `20260925020000` and `…021000` are applied (done 2026-09-24/25).
- [ ] Every P0 migration is applied (`supabase/migrations/20260924205115`, `…205508`, `…205916`,
      `…210103`), plus all-in pricing (`…211840`). Check with `SELECT name FROM supabase_migrations.schema_migrations WHERE name LIKE '%exos_p0%';`
- [ ] Stripe account with **Connect** enabled. Charges are **destination charges**
      (`transfer_data.destination`) with an `application_fee_amount`, so the platform pays Stripe's
      fee and carries lost chargebacks. **Operator decision pending:** the account type
      (`EXOS_CONNECT_ACCOUNT_TYPE`: `standard`, today's default, or `express`, which suits
      destination charges), a minimum fee per ticket, and whether lost chargebacks are recovered
      from the organizer.
- [ ] Events are priced in a two-decimal currency (`_shared/currency.ts`: USD, EUR, GBP, CAD,
      AUD, MXN, BRL). Checkout refuses others; a zero-decimal one like JPY would be charged 100x.
- [ ] Checkout takes cards only (Apple Pay and Google Pay included). Bank debits and other
      delayed methods would outlive the 30-minute seat hold.
- [ ] Decide the platform fee. `EXOS_PLATFORM_FEE_BPS` defaults to `500` (5%). The operator
      confirms the model and the rate. `exos-checkout` carries a `TODO(operator)` for this.
- [ ] Transactional email works: `RESEND_API_KEY` and `EXOS_MAIL_FROM` are set for `exos-mail-drain`,
      and at least one real email has gone out. Ticket emails are part of checkout.

## 1. Secrets (Supabase → Edge Functions → Secrets)

| Secret | Used by | Notes |
|---|---|---|
| `STRIPE_SECRET_KEY` | exos-checkout, stripe-webhook, exos-reconcile-checkouts, exos-connect-onboard | Use `sk_test_…` first and switch to live in step 6 |
| `STRIPE_WEBHOOK_SECRET` | stripe-webhook | `whsec_…` of the platform endpoint (step 3). Test and live have **different** secrets |
| `STRIPE_CONNECT_WEBHOOK_SECRET` | stripe-webhook | `whsec_…` of the connected-accounts endpoint (step 3). Without it organizers never become `chargesEnabled` |
| `CRON_SECRET` | exos-reconcile-checkouts (and the other cron functions) | Must match what `_cron_invoke_edge_fn` sends |
| `EXOS_REDIRECT_ORIGINS` | exos-checkout, exos-connect-onboard | **Required.** Comma-separated origins the browser may be sent back to after Stripe, e.g. `https://vibepass-storefront-test.onrender.com`. Exact origin match, https only (http only for localhost). Unset means both functions refuse every request |
| `EXOS_PLATFORM_FEE_BPS` | exos-checkout | Optional, default 500 |
| `EXOS_CONNECT_ACCOUNT_TYPE` | exos-connect-onboard | Optional: `standard` (default) or `express` for new organizer accounts |
| `EXOS_GUEST_IP_SALT` | exos-checkout | Optional. Salt for the hashed client IP behind the guest checkout rate limit. Defaults to a server secret; set it if you want to rotate it independently |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | all | Supabase sets these automatically |

**The SPA build is also a switch.** The storefront's paid checkout and the org's "Connect Stripe"
button only appear when the bundle is built with `VITE_STRIPE_PUBLISHABLE_KEY` (`pk_test_…` or
`pk_live_…`; publishable keys are meant to be public). Today's `/bridge/` bundle was built without
it, which is part of why payments are dormant. Checkout itself redirects to the Stripe-hosted page.

## 2. Deploy the functions

| Function | Entry | Extra files in the bundle | `verify_jwt` | Why |
|---|---|---|---|---|
| `exos-checkout` | `index.ts` | `../_shared/pricing.ts`, `../_shared/redirects.ts`, `../_shared/attribution.ts` | **true** | Called by signed-in buyers |
| `exos-connect-onboard` | `index.ts` | `../_shared/redirects.ts` | **true** | Called by the org owner |
| `stripe-webhook` | `index.ts` | `../_shared/auto-refund.ts` | **false** | Stripe doesn't send a JWT; the Stripe signature is the auth |
| `exos-reconcile-checkouts` | `index.ts` | `../_shared/cron-auth.ts`, `../_shared/auto-refund.ts` | **false** | Called by pg_cron; `CRON_SECRET` is the auth |

**Apply migrations `20260924215000` and `20260924223000` first** (all-or-nothing fulfillment, promoter attribution). `exos-checkout` writes the columns the second one adds.
Also apply **`20260925020000`** (dispute recording, reconcile bookkeeping) before deploying `stripe-webhook`
and `exos-reconcile-checkouts`: without it the dispute handler returns 500 and the sweep does nothing.

With the CLI (from `Terminal-2/`): `supabase functions deploy <name> --project-ref hzrizjeaxlqcxfrtczpq`,
adding `--no-verify-jwt` for the last two. Then schedule the reconcile sweep by applying
`20260702144637_exos_reconcile_checkouts_cron.sql` (a cron change: operator-gated). As of 2026-09-25
that cron is **not** scheduled in prod; the file was held back because the function wasn't deployed.

**Never deploy `exos-distribute`.** It exists to POST listings to Automatiq, and the project's
read-only-upstream rule forbids that without explicit operator authorization.

### Rebuild the SPA with the publishable key

```bash
VITE_SUPABASE_URL=… VITE_SUPABASE_ANON_KEY=… VITE_STRIPE_PUBLISHABLE_KEY=pk_test_… npm run build
# copy dist/ → Terminal-2/static/bridge/ and ship that through a Terminal-2 PR
```

## 3. Register the Stripe webhook (test mode first)

Two endpoints, same URL: `https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/stripe-webhook`.
Stripe dashboard → Developers → Webhooks → Add endpoint, pinned to API version **2024-06-20** (the
version the handler is written against).

1. **Platform endpoint.** Listen to events on *your account*:
   `checkout.session.completed`, `checkout.session.async_payment_succeeded`,
   `checkout.session.async_payment_failed`, `checkout.session.expired`,
   `charge.refunded`, `charge.refund.updated`, `refund.updated`, `refund.failed`,
   `charge.dispute.created`, `charge.dispute.updated`, `charge.dispute.closed`.
   A refund voids tickets only once it has **succeeded**; a pending one that later fails leaves
   them with the buyer (the refund events settle it).
   Destination charges raise these on the platform. Signing secret → `STRIPE_WEBHOOK_SECRET`.
2. **Connected-accounts endpoint.** Listen to events on *connected accounts*: `account.updated`.
   This is how an organizer's onboarding status (`chargesEnabled`, `payoutsEnabled`) reaches Exos.
   Signing secret → `STRIPE_CONNECT_WEBHOOK_SECRET`.

The handler accepts a signature from either secret.

## 4. End-to-end test in Stripe test mode

Use a throwaway org and event with a paid tier, capacity 3. Card `4242 4242 4242 4242`.
Keep `Terminal-2/tests/exos/test_money_path_refunds.sql` open, because it encodes the expected state
for each case.

| # | Do | Expect (check in SQL) |
|---|---|---|
| 1 | Org owner runs Connect onboarding and finishes the Stripe form | `exos_org_secrets.payments` has `chargesEnabled: true` (from `account.updated`) |
| 2 | Buy 2 tickets | Session `fulfilled`, 2 active tickets with `order_ref = session_id`, an `exos_order_payments` row, one ticket email queued, and the fee shown on the Stripe payment |
| 3 | Refund $10 of it in the Stripe dashboard | Session `partially_refunded`, tickets **still active**, one refund row with Stripe's `re_…` id |
| 4 | Refund the rest | Session `refunded`, **both tickets voided**, tier `sold` back down by 2 |
| 5 | Buy 1 ticket, then open a dispute (test card `4000 0000 0000 0259`) | Session keeps its status and gets `dispute_status`; tickets stay valid. Lose it (submit losing evidence in test mode) → tickets voided |
| 6 | On a tier with nothing sold, start checkout for 2, then set the tier's `capacity` to 1 in SQL and pay. (`capacity = 0` means *unlimited*, so don't use 0) | Session `failed`, automatic refund with `reverse_transfer` (the connected account's balance goes down, not the platform's) |
| 7 | Start checkout and leave it for 30 minutes | Session `expired`, hold released. Stripe sessions expire at 30 minutes |
| 8 | Hidden tier: buy by UUID with no voucher | 409 from exos-checkout, no Stripe session |
| 9 | Tier with a `price_schedule` step already started | The Stripe line item shows the scheduled price, which is also what the storefront shows |
| 11 | **All-in:** a tier priced $10.05 with an 8.875% exclusive tax rule; buy 3 | The storefront shows **$10.94** per ticket ("all-in · incl. tax"), and Stripe charges **$32.82**. That's one line at $10.94 × 3, whose description notes the tax included. There's no separate Tax line and no fee line |
| 10 | Replay an event from the Stripe dashboard | Nothing changes (every handler is idempotent) |
| 12 | **Guest, no account:** signed out, Buy, enter a new email, pay | Session `fulfilled` with `guest = true` and no `buyer_uid`; tickets owned by the org owner, each with a pending transfer to the email; one `transfer-initiated` mail with a claim link per ticket. Open a link, sign in with the one-time code: the ticket (and any add-ons) move to that account |
| 13 | **Guest, existing account:** signed out, buy with the email of a confirmed account | Tickets owned by that account, no transfers, a `ticket-issued` mail |
| 14 | Six guest checkouts from one network within 10 minutes | The sixth gets "too many checkouts from this network" (409), no Stripe session |
| 16 | **Promo code:** create `EARLY20` (20% off, 100 uses) in Edit event → Promo and access codes; apply it on a $40 tier and buy 2 | The event page shows $32 per ticket (plus any tax), Stripe charges $64, tickets record `price_paid` 32, the code shows 2/100 used |
| 17 | A $5-off code on a $4 tier | 409 "that code takes off more than the ticket price", no Stripe session |
| 15 | Untick **Guest checkout** in Edit event, then buy signed out | The Buy button opens sign-in, not the email step; a direct call with `guest_email` gets 409 "sign in to buy tickets for this event" |

Useful queries:

```sql
SELECT session_id, status, amount_cents, failure_reason FROM exos_checkout_sessions ORDER BY created_at DESC LIMIT 10;
SELECT refund_id, amount_cents, status, is_partial FROM exos_order_refunds WHERE session_id = '<cs_…>';
SELECT status, count(*) FROM exos_tickets WHERE order_ref = '<cs_…>' GROUP BY 1;
```

## 5. Watch after launch

- Webhook failures: Stripe dashboard → Webhooks → endpoint → failed deliveries. A 500 means a
  ledger write failed and Stripe will retry, which is intended.
- Sessions stuck `failed` with money taken: `SELECT * FROM exos_checkout_sessions WHERE status='failed' AND payment_intent IS NOT NULL;`
  The reconcile cron refunds these. If rows pile up here, alert on it.
- Edge function logs: `stripe-webhook`, `exos-reconcile-checkouts`.

## 6. Switch to live

Repeat steps 1–3 with live keys and a live webhook endpoint, which has its own `whsec_…`. Run
steps 2–4 of the test table with a real card and refund yourself.

## Rollback

Rebuild the SPA **without** `VITE_STRIPE_PUBLISHABLE_KEY`, which hides paid checkout, and undeploy
`exos-checkout` so no new sessions can start. Keep the webhook endpoint enabled until in-flight
sessions have settled, because refunds and disputes still need it.
`stripe-webhook` is idempotent and safe to keep running.

## Guest checkout (mig 20260928050000)

A signed-out buyer on a paid ticket gets an email step ("Where should we send your tickets?") instead of a
sign-in wall, then Stripe's page (Apple Pay / Google Pay / card). `exos-checkout` takes `guest_email` when there is
no JWT and calls the service-role `exos_create_guest_hold`. At fulfilment the tickets go to the confirmed account
with that email, or are parked on the org owner with a claim link per ticket (the marketplace-order path), so the
buyer never needs an account to pay and signs in with a one-time code only to show the QR.

Limits that replace "a confirmed inbox per hold": one live cart per email per event; maxPerOrder, and maxPerAccount
counted per email; five guest holds per network per 10 minutes (salted IP hash, never the IP); live guest holds
capped at a quarter of what's left for the event (at least 10 seats). Organizers switch guests off per event with
**Guest checkout** in Edit event (`purchase_limits.guestCheckout = false`). Capacity-bypass codes and free claims
still need an account. The embedded (venue-site iframe) checkout still signs in first.

## Known gaps (see `KANBAN.md`)

Fixed since this list was first written: redirect URLs are allow-listed (`EXOS_REDIRECT_ORIGINS`),
add-ons are re-checked at fulfilment (an order that can't be filled fails and is refunded),
holds respect the event's house cap, refunds void only once they succeed, the reconcile sweep
writes the payment ledger, receipts show the amount and tax, and Connect onboarding can't create
two accounts for one org.

Still open:
- The fee model (minimum per ticket, who pays Stripe's fee) and the chargeback policy are operator
  decisions; until then a cheap ticket or any refund can cost the platform money.
- Tax: rates are organizer-entered; there is no Stripe Tax or nexus logic.
- Organizer payout reporting beyond the Connect status.
- The money edge functions have no handler-level tests (the SQL harnesses cover the database side).
