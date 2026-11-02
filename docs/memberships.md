# Memberships, season passes and flex packs

Next to tickets, an organization can sell:

- **Memberships**: monthly or yearly (a Stripe subscription) or a one-time term (one payment for N days). Members get
  a ticket discount, member presales, free tickets per period, a guest allowance and household seats. Memberships can
  be given as gifts.
- **Season passes**: one admission to each eligible event (named events, or every org event in a date range).
- **Flex packs**: N admissions to spend on any eligible event.

Gift cards and donations: [gift-cards.md](gift-cards.md), [giving.md](giving.md). With none of this configured,
checkout, prices and orders are exactly as before.

- **Code:** migration `20261030130500_exos_passes_memberships.sql`; `exos-commerce` (buy, billing portal),
  `exos-checkout` (member price, presale gate), `stripe-webhook` (subscription events); `_shared/commerce.ts`
  (`memberUnitCents`, `memberPriceApplies`, `passCovers`, `membershipStatusFromStripe`).
- **UI:** Org settings → Memberships & passes (`OrgMembershipsPanel`, incl. card lookup and comp gifts),
  `/shop/:orgSlug`, `/me/memberships` (`MyMemberships`: card QR, household, billing portal, passes, gift cards),
  `/membership/claim`, the event page (`MemberPassRedeem`: member price notice, "Use my pass", member free tickets).
- **Tests:** `tests/exos/test_passes_memberships.sql`, `tests/exos/test_membership_writes.sql` (run by `run_p0.sh`),
  `src/lib/commerce.test.ts`, `src/lib/membershipAdmin.test.ts`, `src/lib/apiMemberships.test.ts`, `src/lib/wallet/seasonPass.test.ts`.

## Products

| Table | Fields |
|---|---|
| `exos_membership_products` | name, price (per period or term), `billing` (`month` / `year` = subscription, `once` = `duration_days`; can't change), `discount_percent` (0–100, 3 decimals), `presale`, `free_tickets_per_period`, `guest_allowance`, `household_seats`, `giftable`, `active` |
| `exos_pass_products` | `kind` (`season` / `flex`), price, `credits` (flex), `per_event_limit` (season default 1), `event_ids` or `date_from` / `date_to`, `tier_ids` (empty = all), `valid_until`, `sales_end`, `max_sold`, `sold` (server-kept) |

Owners and managers write; finance reads; buyers read active products through `exos_public_membership_products` /
`exos_public_pass_products`. A product that has sold can't be deleted (archive it). Editing a product never changes
existing members or passes: each keeps a snapshot (`benefits`, `eligibility`), and a subscription keeps the price it
started with in Stripe.

**Lifecycle** (mig 20261102100000): `exos_membership_products.status` is `draft` → `published` ⇄ `unpublished` →
`archived`. A new product (dashboard or API) starts as a draft; only `published` is on sale. Archiving is final: an
archived product is never published or edited again, and its members keep their benefits until their period ends.
A trigger keeps `active` (`= published`) and `archived_at` in step with the status, so checkout and the public view are
unchanged, and an older client that flips `active` moves the status (a draft turned on is published; nothing revives an
archived one). Writes: `exos_membership_product_save(org, id, fields)` (create as a draft / update; unknown fields,
`billing` and `currency` after creation refused; names unique among the org's live products) and
`exos_membership_product_transition(id, publish | unpublish | archive)` (the same state again is a no-op).

**Dashboard:** `/orgs/:orgId/memberships` (linked from Org settings → Memberships): Products (search, status filter,
sort, page; edit, publish, unpublish, archive), Members (`exos_org_memberships_page`: status / product filters,
search, sort, server paging; issue, rename, notes, end date, cancel, reactivate) and Imported attendees (below).
Owner / manager write; finance reads products and members; scanners see nothing. Pure rules: `src/lib/membershipAdmin.ts`.

## Memberships (`exos_fan_memberships`)

Holder (account + email), status (`pending` gift, `active`, `past_due`, `cancelled`, `expired`), current period, Stripe
subscription and customer ids, `benefits` snapshot, `source` (`purchase`, `gift`, `comp`). No client writes; the
holder and owner / manager / finance read; the gift token hash is not readable at all.

`exos_membership_effective_status` evaluates status on read: active past the period end = `expired` (how one-time
terms end); `past_due` keeps benefits for 3 days; a cancelled subscription keeps them until the paid period ends.

### Stripe

| Event | What happens |
|---|---|
| `checkout.session.completed` (`exos_kind = membership`) | `exos_commerce_fulfill` creates the membership (or the pending gift and its claim mail). A subscription takes its period end from the subscription; the customer id is kept for the portal. |
| `invoice.paid` | `exos_membership_sync`: the period end moves forward (`membership.renewed`). A first invoice that lands before the session completes is ignored (unknown subscription). |
| `customer.subscription.updated` | Status mirrored (`active`/`trialing` → active, `past_due`/`unpaid` → past_due, `canceled` → cancelled, `incomplete_expired` → expired), `cancel_at_period_end`, period end. A stale event never revives a cancelled membership. |
| `customer.subscription.deleted` | Cancelled (`membership.cancelled`). |

Endings are sticky. A refunded purchase (`ended_reason = 'refunded'`) or a cancelled gift (`'gift_cancelled'`) is
terminal: no later event changes it. A `customer.subscription.updated` can end or degrade a membership but never
revives a cancelled / expired one and never moves the period end; only `invoice.paid` for a period **after** the
current one extends it (and is the only way a Stripe-cancelled membership comes back). When a membership purchase is
refunded, stripe-webhook also cancels the Stripe subscription (platform account), so billing stops. A subscription
session's refund is matched through its first invoice's PaymentIntent.

Both API shapes are read (`subscription.current_period_end` / `items.data[].current_period_end`;
`invoice.subscription` / `invoice.parent.subscription_details.subscription`). Add these events to the Stripe webhook
endpoint. Subscriptions are created on the platform account with `transfer_data` to the organizer and an
`application_fee_percent` equal to the usual fee.

**Renew / cancel / change card**: Stripe's customer portal (`membership_portal` in exos-commerce; holder only,
subscriptions only). Turn the portal on in the Stripe dashboard. A one-time term is renewed by buying again: the new
term starts when the current one ends.

### Gifts

Anyone signed in can buy a giftable membership for an email (one payment for one period, no renewal); owners and
managers can comp one (`exos_membership_gift`). It's created `pending`; the recipient gets a claim link valid 90 days
(`/membership/claim?token=…`, 256-bit token, only its SHA-256 stored). Claiming (`exos_membership_claim_gift`) makes
the signed-in account the holder and starts the term that day. An unclaimed gift can be cancelled by the giver or an
owner / manager (`exos_membership_cancel_gift`); a paid gift isn't refunded automatically.

### Household

The holder adds up to `household_seats` emails (`exos_membership_household_set`); each gets a mail. Anti-spam: 10
changes a minute per account, at most 2 × seats + 4 adds / removes per membership per billing period (at least the
last 30 days), at most 3 household mails a day to one address, and no mail to an address removed from the same
membership in the last 24 hours (re-adding it is silent). Every change is logged in
`exos_membership_household_changes` (service role only). Anyone signed in
with a **confirmed** email on the list gets the member price, presales and free tickets. Only the holder manages
billing and the household.

### Membership card and door lookup

`/me/memberships` shows a QR (`exos-member:<membership id>`). It is not an entry code: door staff look it up with
`exos_membership_scan(org, id)` (Org settings → Memberships & passes → Look up), which answers valid / status /
product / first name, never the email.

## Member price (order of operations)

1. Tier price (scheduled), 2. promo code (as before), 3. **member discount** on the result, rounded half up once
(`memberUnitCents`), only when the order has at most 1 + `guest_allowance` tickets, 4. fees on the discounted price,
5. tax, 6. donation line, 7. gift card. The Stripe ticket line says "(member price)"; the session records
`membership_id` and `member_discount_percent`. The event page shows signed-in members their discount.

## Member presales (`exos_member_presales`)

Per event (`exos_set_member_presale`, owner / manager): from `starts_at` (or now) until `ends_at`, the covered tiers
(all when empty) sell only to members of the listed products (any of the org's when empty) whose benefits include
presale. Everyone else, guests included, gets 403 "Tickets are on presale for members right now." from exos-checkout.
It holds on every path: checkout fulfillment checks it again (a non-member's order that reaches fulfillment fails and
is refunded), pass and member-free redemptions check it, and a trigger on ticket insert
(`exos_tg_ticket_member_presale`) refuses free claims and any other signed-in issuing by a non-member. Staff of the org
(owner / manager / scanner: comps, guest lists, box office) keep their override; a server-side insert with no
signed-in user outside checkout (marketplace / feed orders the organizer set up) passes. Not yet: letting members buy before a tier's own
`sales_start`.

## Using passes and member free tickets

`exos_pass_redeem(pass, event, tier, quantity, request_id)` and `exos_membership_redeem(membership, …)`: the event must
be the org's, published and sold on Exos; the tier public and on sale; the pass must cover the event (named, or a
start inside the range) and tier. The redemption is a **$0 order** (`pass_…` / `mbr_…`) run through
`exos_fulfill_checkout`, so tier and event capacity, shared quotas and the per-account limit apply exactly as for a
paid ticket, and the credit is taken **in the same transaction** with the pass / membership row locked (two
redemptions racing for the last credit can't both pass). Ledgers: `exos_pass_redemptions`,
`exos_membership_redemptions` (free tickets keyed by the period end, so they reset on renewal). A retry with the same
request id returns the tickets already issued. Tickets have `price_paid = 0`, so they stay out of the box-office gross.

## Refunds

A full Stripe refund of a pass or membership purchase (`exos_commerce_refund`) voids the pass / ends the membership
for good (`ended_reason = 'refunded'`), and for a subscription stripe-webhook cancels it in Stripe. Refunds of later
renewal invoices aren't matched to the membership yet.
Voiding a pass ticket doesn't give the credit back.

### Staff-issued memberships (mig 20261102100000)

`exos_membership_issue(org, { product_id, email, member_name?, source: comp | import, expires_at?, staff_notes? })`
(owner / manager, 30 a minute): an `active` membership with the product's benefits, `billing = 'once'`, no Stripe
subscription, ending at `expires_at` (default one period of the product). `source = 'import'` is a member who paid
somewhere else (a roster move). The account is matched by confirmed email; with none yet it is held for the email and
`exos_claim_my_memberships()` (called by `/me/memberships`) attaches it once that email is confirmed. Refused while the
email holds a live (or pending) membership of the product, or when the product is archived.
`exos_membership_update(id, { member_name?, staff_notes?, status?: active | cancelled | expired, expires_at? })`: the
name and notes always; status and end date only when Stripe doesn't bill it, it isn't an unclaimed gift and it has no
`ended_reason` (a refund is never revived). Cancel / expire end the benefits now. `staff_notes` and `issued_by` have no
client column grant (staff read them through `exos_org_memberships_page`); `member_name` is readable by the holder.

### Imported attendees (door imports)

Attendees imported from another platform are guest entries with a `source`, an external code or an `external_ref`
(`exos_import_guests`, the Posh / Eventbrite paths). `exos_org_imported_attendees(org, event?, source?, search?, sort,
desc, limit, offset)` lists them (owner / manager). `exos_imported_attendee_update(id, fields)` edits name, email,
phone, plus-ones and note through `exos_update_guest` (list caps, capacity) and the code (normalized, unique per event,
fixed once the party checked in), ticket label and source; `exos_imported_attendee_delete(id)` removes one through
`exos_remove_guest` (not once checked in). Rows synced from Eventbrite (`external_ref`) are the sync's: refused here.

## Partner API

Writes (mig 20261102100000, `docs/api/membership-writes.json`): `POST /v1/membership-products`,
`PATCH /v1/membership-products/:id`, `POST /v1/membership-products/:id/{publish,unpublish,archive}`,
`POST /v1/memberships`, `PATCH /v1/memberships/:id` (`commerce:write`), and `GET /v1/migrated-attendees[/:id]`,
`PATCH` / `DELETE /v1/migrated-attendees/:id` (`tickets:read` / `tickets:write`). Each runs
`exos_api_commerce_write(key, action, target, args, idempotency key)`: the steps of `exos_api_write` (the key's org,
scope re-checked, runs as the key's creator while an active member, Idempotency-Key replay, logged in
`exos_api_writes`) and then the dashboard RPC above. Opendate's field names are accepted
(`supabase/functions/_shared/api/memberships.ts`). `GET /v1/membership-products` takes `?status=` and Opendate's
`?q[status_not_eq]=archived`.

Read routes with `commerce:read` (`docs/api/commerce.json`, `/developers`). Mapping against Opendate's v2 API
(memberships, membership_products, membership_reservations, membership_scans, gift_card_sales, giving_campaigns):

| Opendate endpoint | Exos |
|---|---|
| `GET /memberships` | `GET /v1/memberships` (+ `GET /v1/memberships/:id`) |
| `POST /memberships/:id/gift` | Org settings → Memberships → Comp (`exos_membership_gift`); fans: `buy_membership` with `gift_to_email` (exos-commerce). No partner write route yet |
| `DELETE /memberships/:id/gift` | `exos_membership_cancel_gift` (giver or owner / manager). No partner write route yet |
| `GET /users/current/memberships[/:token]` (fan app) | `exos_my_memberships()` (signed-in RPC; shared rows without billing details) |
| `GET /membership_products`, `GET /membership_products/:id` | `GET /v1/membership-products`, `GET /v1/membership-products/:id` |
| `POST /membership_products`, `PATCH /membership_products/:id` | `POST /v1/membership-products`, `PATCH /v1/membership-products/:id` (a draft; one price per product) |
| `POST /membership_products/:id/publish` / `unpublish` | `POST /v1/membership-products/:id/publish` / `unpublish` |
| `POST /membership_products/:id/archive` | `POST /v1/membership-products/:id/archive` (final; Opendate restores with publish, Exos doesn't) |
| `POST /admin/memberships`, `PATCH /admin/memberships/:id` | `POST /v1/memberships`, `PATCH /v1/memberships/:id` (per organization) |
| `PATCH` / `DELETE /admin/migrated_attendees/:id` | `PATCH` / `DELETE /v1/migrated-attendees/:id` |
| `GET /users/current/season_passes/:id/pkpass`, `…/google_wallet_url` | exos-wallet `POST /season-pass` (`docs/wallet.md`) |
| `POST /membership_products/:id/membership_reservations`, `DELETE …/:token`, `POST …/:token/complete` | Doesn't apply: memberships aren't capacity-limited, so there's nothing to reserve; Exos's flow is one Stripe Checkout session (`buy_membership`) completed by the webhook, and an abandoned one simply expires |
| `POST /membership_scans` | `exos_membership_scan(org, membership id)` (door staff; Org settings lookup). No partner route: door scans are a signed-in staff action |
| `GET /gift_card_products` | `GET /v1/gift-card-products` |
| `GET /gift_card_products/:id/quote` | `exos_gift_card_quote` inside exos-checkout / exos-commerce; amounts are fixed or a min–max range, so a quote is the amount itself |
| `POST /gift_card_products/:id/gift_card_orders` | Online: `buy_gift_card` (exos-commerce); box office: `exos_gift_card_issue`. No partner write route yet |
| `GET /gift_card_products/:id/gift_card_orders/:token` | `GET /v1/gift-cards/:id` (with its ledger) and `GET /v1/gift-cards` |
| `POST /confirms/:id/organizer_ticket_reservations/:token/gift_card_redemptions`, `DELETE …/:id` | `gift_card_code` on exos-checkout (removing it = not sending it); `exos_gift_card_refund_order` puts a payment back |
| `GET /giving_campaigns`, `GET /giving_campaigns/:id` | `GET /v1/giving-campaigns`, `GET /v1/giving-campaigns/:id` (raised totals); public `exos_public_giving_campaigns` |
| `POST /giving_campaigns/:id/donations` | `donate` (exos-commerce, Stripe Checkout) or add-a-donation on exos-checkout |
| `POST /giving_campaigns/:id/offline_donations` | `exos_record_offline_donation` (Org settings). No partner write route yet |
| `POST /giving_campaigns/:id/recurring_donations` | Not built yet (would reuse the membership subscription plumbing) |
| — (no Opendate equivalent) | `GET /v1/donations`, `GET /v1/pass-products`, `GET /v1/passes`, `GET /v1/events/:id/member-presale` |

Gifts, gift cards and offline donations are still signed-in staff actions in the app.

## Not covered yet

- Prorating or switching between membership products (do it in the Stripe portal, or cancel and rebuy).
- A wallet (Apple / Google) membership card; the QR on `/me/memberships` is the card for now. Season passes and flex
  packs have wallet cards (exos-wallet `POST /season-pass`).
- Recurring donations; partner write routes for gifts, gift cards and donations.
- Imported memberships don't open a Stripe subscription that bills later (Opendate's trial-then-invoice import): an
  imported member gets a one-time term, and renews by buying.
