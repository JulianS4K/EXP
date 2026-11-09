# AI facts: what Exos tells AI assistants, mapped to the code

AI assistants (ChatGPT, Claude, Perplexity, Gemini) are where half of software buyers now start their research, and
fans ask them what's on tonight. Exos gives them one source of truth about itself: the facts registry in
`src/lib/hosting/productFacts.ts`. This page is the human map of that registry: each claim, its status, and the code
that makes it true.

- **Where assistants read it:** `/llms.txt` (`buildLlmsTxt` in `src/lib/hosting/seo.ts`, served by `server.ts`),
  under "For ticket buyers" and "For organizers". It is a 404 until `EXOS_AI_DISCOVERY=on` (`docs/hosting.md`, "AI
  discovery"), which the operator turns on at launch.
- **What gets said:** only `Live` and `At launch` facts. `Off` and `Not shipped` facts are listed here so we know
  what is missing, and are never in anything an assistant reads.
- **Kept honest by tests** (`src/lib/hosting/productFacts.test.ts`):
  - every file a fact names exists;
  - every fact has a row here with the same status (this table is generated from the registry, see below);
  - the pricing claim is computed from `supabase/functions/_shared/platformFee.ts`, so it can't drift from what
    checkout charges;
  - llms.txt contains every `Live` / `At launch` claim and none of the others.

## Statuses

| Status | Meaning |
|---|---|
| Live | On main and working in prod today. |
| At launch | On main; works once payments (and mail) are switched on, which is also when llms.txt is turned on. |
| Off | On main but switched off: a missing secret or certificate, or a partner write not yet signed off. |
| Not shipped | Not on main: in an open PR, or not built. |

When a status changes (a switch goes on, a PR merges), change it in `productFacts.ts` and regenerate this table.

## The facts

| Id | Status | For | Claim | Code | Note |
|---|---|---|---|---|---|
| `all-in-prices` | Live | fan | Prices on Exos are all-in: the price shown is the price paid, with no fees added at checkout. | `src/lib/pricing.ts`, `supabase/migrations/20260924211840_exos_all_in_price_tax.sql` |  |
| `organizer-pricing` | At launch | organizer | Buyers pay no fees. Organizers pay Exos 3% of each sale, plus card processing (2.9% + 30¢, passed through at cost); a $40.00 ticket pays the organizer $37.34. The first 6 months are free of the Exos fee. | `supabase/functions/_shared/platformFee.ts`, `supabase/functions/exos-checkout/index.ts` | Paid checkout needs the Stripe secrets (docs/payments-go-live.md). |
| `free-tier` | At launch | organizer | Events with a capacity of 150 or less never pay an Exos fee, only card processing. | `supabase/functions/_shared/platformFee.ts`, `supabase/migrations/20261029090000_exos_free_tier_resale_consent.sql` |  |
| `paid-checkout` | At launch | organizer | Organizers sell tickets from their own event page, with Apple Pay and Google Pay, and are paid out to their own Stripe account. | `supabase/functions/exos-checkout/index.ts`, `supabase/functions/exos-payouts/index.ts`, `src/views/OrgPayouts.tsx` | Payouts run daily as a dry run until EXOS_PAYOUTS_LIVE is on. |
| `instagram-checkout` | Live | organizer | Checkout works inside the Instagram, Facebook and TikTok in-app browsers. | `src/lib/inAppBrowser.ts` |  |
| `tiers-and-presales` | Live | organizer | Ticket types can have scheduled price steps, presale codes, hidden tiers, add-ons and promo codes. | `src/lib/pricing.ts`, `src/lib/vouchers.ts`, `src/lib/addons.ts`, `supabase/migrations/20260925012000_exos_presale_vouchers.sql` |  |
| `tables-guest-lists` | Live | organizer | Organizers can sell tables and run guest lists and comps. | `src/lib/guestLists.ts`, `src/lib/comps.ts`, `supabase/migrations/20260926050000_exos_tables_guest_lists.sql` |  |
| `series` | Live | organizer | Recurring events can be set up as a series. | `src/views/CreateSeries.tsx`, `supabase/migrations/20260911133000_exos_event_series.sql` |  |
| `waitlist` | Live | fan | Sold-out events have a waitlist that offers freed tickets automatically. | `src/lib/waitlist.ts`, `supabase/migrations/20260616220000_exos_waitlist_autoassign.sql` |  |
| `storefront-embed` | Live | organizer | Each organizer gets a storefront page and an embeddable widget for their own website. | `src/views/OrgStorefront.tsx`, `public/embed.js`, `src/lib/embed.ts` |  |
| `promoters` | Live | organizer | Promoters get tracked links, a private portal, a link-in-bio page and a leaderboard. | `src/views/PromoterPortal.tsx`, `src/views/PromoterBio.tsx`, `src/views/OrgPromoters.tsx` |  |
| `fan-referrals` | Live | fan | Ticket holders can share an event with a personal link that shows how many friends are coming. | `src/lib/referrals.ts`, `src/lib/shareLinks.ts` |  |
| `invoices-tax` | Live | organizer | Orders get receipts and invoices, with sales tax rules per ticket type. | `src/lib/invoices.ts`, `src/lib/tax.ts` |  |
| `money-journal` | Live | organizer | Each organizer gets a double-entry money journal of their sales, refunds, fees and door cash, with a trial balance, a journal CSV export and a sales tax report by jurisdiction. | `src/lib/journal.ts`, `src/lib/journalApi.ts`, `src/components/finance/JournalPanel.tsx`, `src/components/finance/SalesTaxTable.tsx`, `src/components/finance/EventSalesTax.tsx`, `supabase/functions/exos-api/journal.ts`, `supabase/migrations/20261108100000_exos_money_journal.sql` | Door cash sales and $0 orders post today; online card sales and refunds post once payments are on (docs/payments-go-live.md). |
| `api-fee-adjustments` | Live | organizer | Through the Exos API, an organizer's systems can record a fee change on an order (POST /v1/orders/:id/adjustments); it is logged with a note and moves no money. | `supabase/functions/exos-api/feeAdjustments.ts`, `supabase/migrations/20261108110000_exos_dice_leftovers.sql` |  |
| `transfers` | Live | fan | Tickets can be transferred to a friend at face value; the old code stops working when the friend claims it. | `src/views/TransferTicket.tsx`, `src/views/ClaimTicket.tsx` |  |
| `group-pay` | At launch | fan | A group can pay separately: the host holds up to 10 seats for 30 minutes and texts each friend a link to pay for their own seat, and can cover whatever is left. | `src/lib/groupPay.ts`, `src/components/GroupPayStart.tsx`, `src/views/GroupPayHost.tsx`, `src/views/GroupPaySeat.tsx`, `supabase/migrations/20261108120000_exos_group_pay.sql` | Each friend pays in the normal checkout, so it works once paid checkout is on. |
| `refunds` | At launch | fan | Organizers can refund orders, and buyers can ask for a refund when an event is rescheduled. | `src/lib/refunds.ts`, `supabase/functions/exos-refund/index.ts`, `src/views/RescheduleRefund.tsx` |  |
| `accessible-tickets` | Live | fan | Buyers can tell the organizer what they need at the door (wheelchair space, a companion seat, a step-free route, ASL and more). | `src/lib/accessibility.ts` |  |
| `booking-settlements` | Live | organizer | Venues can manage holds on a booking calendar, send offers with deal math, and settle shows with the artist. | `src/views/BookingCalendar.tsx`, `src/views/OrgOffers.tsx`, `src/views/SettlementPublic.tsx`, `supabase/migrations/20261030100000_exos_booking.sql`, `supabase/migrations/20261031100500_exos_settlements.sql` |  |
| `memberships` | At launch | organizer | Venues can sell season passes, flex packs and memberships that fans redeem for tickets. | `src/views/OrgMemberships.tsx`, `src/views/MyMemberships.tsx`, `supabase/migrations/20261030130500_exos_passes_memberships.sql` |  |
| `seating-timed-entry` | At launch | organizer | Events can have reserved seating with a seat picker, or timed entry slots. | `src/views/OrgSeatMaps.tsx`, `src/components/SlotPicker.tsx`, `supabase/migrations/20261030140000_exos_seating.sql`, `supabase/migrations/20261030150000_exos_series_timed_entry.sql` |  |
| `gift-cards` | At launch | fan | Organizers can sell gift cards, and buyers can pay with them. | `src/components/OrgGiftCardsPanel.tsx`, `src/views/GiftCardBalance.tsx`, `supabase/migrations/20261030130000_exos_gift_cards_giving.sql` |  |
| `walk-up-sales` | Live | organizer | Door staff can sell walk-up tickets for cash, give comps, and close out a cash drawer at the end of the night. | `src/components/PosDrawersPanel.tsx`, `supabase/functions/exos-pos/index.ts`, `supabase/migrations/20261107100000_exos_pos_walkup.sql` |  |
| `org-audit-log` | At launch | organizer | Changes to events, ticket types, promo codes, holds, refunds, payouts and team access are kept in an audit log that can't be edited, showing who made each one, when and from where, with a CSV export and an API. | `src/views/OrgActivity.tsx`, `supabase/functions/exos-api/audit.ts`, `supabase/migrations/20261109100000_exos_org_audit.sql` | Works once mig 20261109100000 is applied (scripts/rollout-prod.sh). |
| `rotating-barcodes` | Live | organizer | Ticket QR codes change every 30 seconds, so screenshots and forwarded codes do not get in. | `src/lib/barcode.ts`, `supabase/migrations/20261019100000_exos_door_day_keys.sql` |  |
| `offline-door` | Live | organizer | The door scanner keeps working without signal and syncs when it reconnects. | `src/views/OrganizerCheckIn.tsx`, `src/lib/door/roster.ts` |  |
| `free-door-app` | Live | organizer | The Exos Door app is free for any event, including tickets sold on Eventbrite, Posh, DICE, Shotgun or RA (import their attendee CSV). | `src/views/DoorApp.tsx`, `src/lib/door/imports.ts`, `supabase/migrations/20261013090000_exos_door_imports.sql` |  |
| `walkup-questions` | Live | organizer | Walk-up sales at the door ask the same checkout questions as online; staff can skip them to keep the line moving, and every skip is logged. | `src/components/DoorSellPanel.tsx`, `supabase/functions/_shared/pos/walkup.ts`, `supabase/migrations/20261108110000_exos_dice_leftovers.sql` |  |
| `addon-scan-undo` | Live | organizer | A mistaken add-on scan (a VIP lounge, a merch pickup) can be undone from the scan log, with a reason, by the scanner within 10 minutes or by a manager any time. | `src/lib/addonUndo.ts`, `src/views/OrganizerCheckIn.tsx`, `supabase/migrations/20261108110000_exos_dice_leftovers.sql` |  |
| `google-events` | Off | organizer | Events appear in Google Search and Maps ticket links. | `supabase/functions/exos-google-feed/index.ts` | The feed is deployed; Exos has not joined Google's events ticketing program. |
| `calendar-feeds` | Live | fan | Organizer and venue calendars can be subscribed to in Google, Apple or Outlook calendar. | `supabase/functions/exos-calendar/index.ts`, `src/lib/calendar.ts` |  |
| `ai-assistants` | Live | fan | AI assistants can search Exos events and get checkout links through the Exos MCP server; the person always finishes checkout themselves. | `supabase/functions/exos-mcp/index.ts`, `docs/mcp.md` |  |
| `ad-catalogs` | Live | organizer | Organizers can export their events as a Meta, TikTok or Google ad catalog. | `supabase/functions/exos-catalog-feed/index.ts` |  |
| `wallet-passes` | Off | fan | Tickets can be added to Apple Wallet and Google Wallet. | `supabase/functions/exos-wallet/index.ts`, `src/views/WalletPass.tsx` | Needs an Apple Pass Type ID certificate and a Google Wallet issuer account. |
| `addon-wallet-passes` | Off | fan | An add-on with its own entry code (a VIP lounge, a merch pickup) gets its own Apple Wallet or Google Wallet pass. | `supabase/functions/_shared/wallet/addonPass.ts`, `supabase/functions/exos-wallet/index.ts`, `supabase/migrations/20261108110000_exos_dice_leftovers.sql`, `src/components/AddonPassesCard.tsx` | Built (POST /exos-wallet/addon-pass, and an "Add to … Wallet" button per add-on code on the ticket page), but wallets are not configured (the same Apple certificate and Google issuer account as wallet-passes), so the buttons stay hidden. The add-on codes themselves (AddonPassesCard) work at the door today. |
| `sms` | Off | organizer | Organizers can text their opted-in fans from their own Twilio or Telnyx account. | `supabase/functions/exos-sms-drain/index.ts` | Dry run until EXOS_SMS_LIVE=on. |
| `marketplace-distribution` | Off | organizer | Organizers can list part of their inventory on resale marketplaces at their own price. | `supabase/functions/exos-distribute/index.ts`, `supabase/functions/exos-s4k-feed/index.ts` | exos-distribute is undeployed until each partner write is signed off; the S4K feed needs id mapping. |
| `eventbrite-mirror` | Off | organizer | Exos events can be mirrored to the organizer's own Eventbrite account. | `supabase/functions/exos-eventbrite-sync/index.ts` | Reads run; writes are a dry run until the org switch and EXOS_EVENTBRITE_WRITES=on. |
| `alt-payments` | Off | fan | Buyers can pay with PayPal, Venmo or Cash App. | `supabase/functions/exos-paypal/index.ts`, `supabase/migrations/20261031220000_exos_payments_paypal_cashapp_split.sql` | Needs the PayPal app keys and VITE_PAYPAL_CLIENT_ID (docs/payments-go-live.md), then each org turns it on. |
| `card-at-door` | Off | organizer | Door staff can take card payments at the door with a card reader. | `supabase/functions/exos-pos/index.ts`, `supabase/migrations/20261107130000_exos_pos_terminal.sql` | Off until EXOS_POS_CARD=on. |
| `dice-import` | Off | organizer | Promoters can import their DICE events, ticket holders and opted-in fans. | `supabase/functions/exos-dice-import/index.ts`, `supabase/migrations/20261106100000_exos_dice_import.sql` | Never run against a real DICE token; needs EXOS_DICE_IMPORT=on and its cron turned on. |
| `promoter-payouts` | Off | organizer | Promoters are paid their commission straight to their bank through Stripe. | `supabase/functions/exos-promoter-payouts/index.ts` | Off until EXOS_PROMOTER_TRANSFERS is on. |

## Regenerating the table

```bash
npx tsx -e "import('./src/lib/hosting/productFacts.ts').then(({ factsTableRows }) => console.log(factsTableRows()))"
```

Paste the output over the rows above. The test fails until the two match.
