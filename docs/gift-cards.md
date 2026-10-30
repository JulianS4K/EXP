# Gift cards

An organization sells gift cards online and at the box office, and buyers spend them at checkout on that
organization's events. A gift card is a **way to pay, not a discount**: the all-in price (fees and tax included,
`docs/fees.md`) is computed first, then the card pays what it can and the rest goes on the buyer's card.

- **Code:** migration `20261030130000_exos_gift_cards_giving.sql`; `supabase/functions/exos-checkout` (redeem),
  `supabase/functions/exos-commerce` (buy online, balance lookup), `supabase/functions/stripe-webhook` (fulfil,
  refund); `supabase/functions/_shared/commerce.ts` (code format, how much a card pays; re-exported by
  `src/lib/commerce.ts`).
- **UI:** Org settings → Gift cards (`OrgGiftCardsPanel`), `/shop/:orgSlug`, `/gift-cards/balance`, the "Have a gift
  card?" field on the event page (`CheckoutExtras`).
- **Tests:** `tests/exos/test_gift_cards_giving.sql` (run by `run_p0.sh`), `src/lib/commerce.test.ts`.

## Tables

| Table | What | Who |
|---|---|---|
| `exos_gift_card_products` | What the org sells: fixed amounts or an open range, design image, optional expiry | owner / manager write; finance and door staff read; buyers read active ones through `exos_public_gift_card_products` |
| `exos_gift_cards` | One card: SHA-256 of the code, last 4, balance, initial value, source (`online`, `box_office`, `api`, `dashboard`), payment method, purchaser, recipient, expiry | owner / manager / finance read; no client writes |
| `exos_gift_card_ledger` | Every balance change: `issue` +, `redeem` −, `release` +, `refund` +, `void` −, `adjust`, with `balance_after`; unique per (card, kind, key) | service role only (staff read through `exos_gift_card_ledger_for`) |
| `exos_gift_card_redemptions` | What an order took from which card (`held` → `captured`, or `released`), and how much was refunded | service role only |

Every balance change locks the card row and writes one ledger row, so a card's balance always equals the sum of its
ledger (the harness checks it).

**Expiry defaults to none.** In the US the CARD Act requires at least five years and several states ban expiry
outright; the EU and UK have their own rules. Set `expiry_months` only after checking the law where you sell.

## Codes

16 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no 0/O/1/I): 15 random (75 bits, from
`gen_random_bytes`) and a Luhn mod 32 check character, so any single mistyped character is caught before a lookup.
Shown as `XXXX-XXXX-XXXX-XXXX`; dashes, spaces and case are ignored.

Only the SHA-256 of the code is stored. The plain code is returned once by the issuing call and put in the
"gift-card-issued" mail. A lost code: owner or manager → **New code** (`exos_gift_card_reissue_code`), which mails a
new code and stops the old one.

Lookups (balance, checkout) are limited to 10 a minute per account or hashed IP, and a miss counts (the lookup returns
an error instead of raising, so the rate-limit hit isn't rolled back).

## Selling

- **Online** (`/shop/:orgSlug` → `exos-commerce` `buy_gift_card`): Stripe Checkout, destination charge to the
  organizer and the usual application fee. `checkout.session.completed` (metadata `exos_kind = gift_card`) →
  `exos_commerce_fulfill` issues the card (idempotent per Stripe session) and mails the code to the recipient, or to
  the buyer when there's no recipient.
- **Box office / dashboard** (`exos_gift_card_issue`): owner and manager record cash, check, comp or a card taken on
  their own terminal; door staff (scanner) cash or check only. `p_external_id` (the till's sale id) makes a retry
  return the same card.

Selling a gift card isn't event revenue; spending it is (the tickets carry the full price, see below).

## At checkout

`exos-checkout` takes `gift_card_code`. In order:

1. Price the order as always (all-in tickets, add-ons, the donation line).
2. Quote the card (`exos_gift_card_quote`, nothing reserved). The card pays `giftCardApplied(total, balance)`: all of
   it when the balance covers it, otherwise as much as leaves a card charge Stripe accepts (at least 0.50).
3. **Partly paid:** a one-off Stripe coupon for the card's part (`duration: once`, `max_redemptions: 1`, "Gift card
   ending XXXX") is attached to the session, so the receipt still lists every line. The session row records
   `amount_cents` = what Stripe charges and `gift_card_cents` = the card's part. Right after the row is written the
   card is **held** (`exos_gift_card_hold`, the balance moves now). If the balance moved since the quote, the Stripe
   session is expired and the buyer gets a 409 before seeing it.
4. **Fully paid:** no Stripe. The order (`gc_…`) is recorded, held and fulfilled at once.
5. `exos_fulfill_checkout` **captures** the hold inside its all-or-nothing block, in the same transaction as the
   tickets; a missing or released hold fails the order.

The Exos application fee is on the card charge only: the gift card's own sale already paid it.

Tickets keep `price_paid` = the order's value (card + gift card, without donation and add-ons), so reports and
refund shares are unchanged. The invoice total is the order's value too, and the price-disclosure record counts the
gift card part as paid (no false mismatch).

## Giving it back

A trigger on the order's status (`exos_tg_checkout_commerce`):

- `failed` (sold out while paying, …) or `expired` (Stripe's `checkout.session.expired`): the held amount goes back
  (`release`).
- `refunded` (a full refund, a lost dispute): what wasn't refunded to the card yet goes back (`refund`).

Each happens once. `exos_gift_card_release_stale()` (service role, for a cron; not scheduled yet) releases holds of
orders that are no longer pending, or still pending after two hours.

**Partial refunds** (one ticket voided, an organizer refund of part of an order) only refund the card part through
Stripe. To put part of a gift card payment back, owner / manager call `exos_gift_card_refund_order(session, amount,
key)` (idempotent per key, never more than was taken).

**Refunding a gift card purchase** (Stripe refund of the `buy_gift_card` payment): `exos_commerce_refund` voids what
is left on the card. Whatever was already spent stays spent.

## Not covered yet

- A card taken at the door for a gift card sale through Stripe Terminal (box office cards are recorded as
  `card`, taken on the venue's own terminal; `docs/pos.md`).
- The receipt mail says "Paid: <card amount>"; it doesn't list the gift card part separately yet.
- `exos-api` POST routes for issuing (the partner API is read-only; see the mapping in `docs/memberships.md`).
