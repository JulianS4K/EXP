# Giving: donations and campaigns

Organizations (nonprofit venues, community promoters) run giving campaigns with a goal and a public page, and take
donations online, with ticket orders, and in person.

- **Code:** migration `20261030130000_exos_gift_cards_giving.sql`; `exos-commerce` (`donate`), `exos-checkout`
  (`donation`), `stripe-webhook`; `_shared/commerce.ts` (amount parsing, cover-the-fees, round-up).
- **UI:** Org settings → Giving (`OrgGivingPanel`), `/give/:orgSlug/:campaignSlug` (`Give.tsx`), the add-a-donation
  choice on the event page (`CheckoutExtras`).
- **Tests:** `tests/exos/test_gift_cards_giving.sql` (G9–G11), `src/lib/commerce.test.ts`.

## Campaigns (`exos_giving_campaigns`)

Name, slug (unique in the org, the page `/give/:orgSlug/:slug`), description, image, currency, goal (0 = no goal and
no progress bar), start / end, up to 8 suggested amounts, cover-the-fees (default on, 3 %), `checkout_add_on` (offer
it at ticket checkout), `round_up`, and `tax_receipt_text`. Owners and managers edit; finance reads. A campaign with
donations can't be deleted or change currency (turn it off instead).

The amount raised and the gift count are **computed** from the donations in `exos_public_giving_campaigns` (anon
can read active campaigns), never a counter a client could move.

## Donations (`exos_donations`)

Gift amount, the cover-the-fees part, total, currency, method (`card`, `checkout`, `cash`, `check`, `other`), donor
(account, email, name), anonymous, note, the order it came with, status (`received`, `refunded`), receipt number. No
client writes; staff (owner / manager / finance) read the org's, a donor reads their own. Each has a unique key per
org (`order:<session>`, `stripe:<session>`, `ext:<till id>`), so a replayed webhook or a retried form is one row.

- **Online** (`donate`): Stripe Checkout with the gift as one line and the cover-the-fees top-up as a second;
  `checkout.session.completed` (metadata `exos_kind = donation`) records it. Signing in is optional (the email is for
  the receipt).
- **With a ticket order**: `exos-checkout` takes `donation: { campaign_id, amount_cents }` for an open campaign of the
  event's org with `checkout_add_on`, in the event's currency. It is its own Stripe line ("Donation: <campaign>")
  **after the tax**: no fee applies and it is never taxed. The session records `donation_cents` and
  `donation_campaign_id`; `exos_fulfill_checkout` records the donation in the same transaction as the tickets. A gift
  card may pay for it like anything else in the order. The ticket price, the refund split per ticket and the invoice
  leave the donation out; the price-disclosure record lists it as a `donation` line. A full refund of the order
  marks it refunded (the total comes down); a single ticket refund doesn't touch it.
- **Offline** (`exos_record_offline_donation`): cash or check recorded by owner / manager / finance; the check number
  as the external id prevents doubles.

Every new donation queues the `donation.received` webhook.

## Receipts

Each donation with an email gets one receipt mail ("donation-receipt"): receipt number (per org), date, campaign,
payment method, the gift, the cover-the-fees part and the total, then the campaign's `tax_receipt_text`. Until the
organization fills that in, a **placeholder** asks it to ("[Legal name of the organization] is a [registered charity /
501(c)(3) nonprofit], tax ID [number] …"). Don't rely on it as a tax receipt before replacing it: what a valid receipt
must say differs by country, and a donation made with a ticket order may need a "goods and services" statement for
the ticket part.

## Export

Org settings → Giving → Donations CSV (`exos_donations_export`, owner / manager / finance): `date, campaign, amount,
cover_fees, total, currency, method, donor_name, donor_email, anonymous, order_id, status, note, receipt_number`,
amounts in major units, formula cells escaped (`src/lib/csv.ts`).

## Fees

The Exos platform fee applies to the card charge as for any payment (a donation is part of the charge). Organizer fee
rules (`docs/fees.md`) never apply to a donation line.

## Not covered yet

- Recurring donations (Stripe subscriptions for gifts): the membership subscription plumbing would carry them.
- `exos-api` routes for donations (see the mapping in `docs/memberships.md`).
