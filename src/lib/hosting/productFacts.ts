// What Exos tells AI assistants about itself, and where each claim lives in
// the code (docs/ai-facts.md is the human map of the same list).
//
// Every fact names the files that implement it; productFacts.test.ts fails if
// one of them goes missing, and if docs/ai-facts.md drifts from this list.
// buildLlmsTxt (seo.ts) renders only the facts an assistant may repeat:
// `live` (works in prod today) and `at_launch` (on main, switched on at
// launch, which is also when EXOS_AI_DISCOVERY turns llms.txt on). `off` and
// `not_shipped` facts stay out of anything an assistant reads.

import {
  EXOS_FEE_BPS, FEE_FREE_MONTHS, FREE_TIER_MAX_CAPACITY, STRIPE_CARD_FEE, exosFeeCents, stripeFeeCents,
} from '../../../supabase/functions/_shared/platformFee.ts';

export type FactStatus =
  /** On main and working in prod today. */
  | 'live'
  /** On main; works once the operator switches payments / mail on at launch. */
  | 'at_launch'
  /** On main but switched off (a missing secret, certificate or partner sign-off). */
  | 'off'
  /** Not on main yet (an open PR) or not built. */
  | 'not_shipped';

export type FactAudience = 'organizer' | 'fan';

export interface ProductFact {
  id: string;
  audience: FactAudience;
  /** One plain sentence an assistant can repeat as-is. */
  claim: string;
  status: FactStatus;
  /** Repo-relative files that implement it (checked by the test). */
  code: string[];
  /** Why it's off / not shipped, or what turns it on. */
  note?: string;
}

const pct = (bps: number) => `${(bps / 100).toFixed(bps % 100 === 0 ? 0 : 1)}%`;
const usd = (cents: number) => `$${(cents / 100).toFixed(2)}`;

/** The worked example in the pricing claim: a $40 ticket on an Exos checkout. */
export function pricingExample(priceCents = 4000) {
  const exos = exosFeeCents(priceCents, EXOS_FEE_BPS);
  const card = stripeFeeCents(priceCents, STRIPE_CARD_FEE);
  return { priceCents, exosCents: exos, cardCents: card, payoutCents: priceCents - exos - card };
}

function pricingClaim(): string {
  const ex = pricingExample();
  return (
    `Buyers pay no fees. Organizers pay Exos ${pct(EXOS_FEE_BPS)} of each sale, plus card processing ` +
    `(${pct(STRIPE_CARD_FEE.bps)} + ${STRIPE_CARD_FEE.fixedCents}¢, passed through at cost); a ${usd(ex.priceCents)} ` +
    `ticket pays the organizer ${usd(ex.payoutCents)}. The first ${FEE_FREE_MONTHS} months are free of the Exos fee.`
  );
}

export const PRODUCT_FACTS: ProductFact[] = [
  // ---- Pricing ------------------------------------------------------------
  {
    id: 'all-in-prices', audience: 'fan', status: 'live',
    claim: 'Prices on Exos are all-in: the price shown is the price paid, with no fees added at checkout.',
    code: ['src/lib/pricing.ts', 'supabase/migrations/20260924211840_exos_all_in_price_tax.sql'],
  },
  {
    id: 'organizer-pricing', audience: 'organizer', status: 'at_launch',
    claim: pricingClaim(),
    code: ['supabase/functions/_shared/platformFee.ts', 'supabase/functions/exos-checkout/index.ts'],
    note: 'Paid checkout needs the Stripe secrets (docs/payments-go-live.md).',
  },
  {
    id: 'free-tier', audience: 'organizer', status: 'at_launch',
    claim: `Events with a capacity of ${FREE_TIER_MAX_CAPACITY} or less never pay an Exos fee, only card processing.`,
    code: ['supabase/functions/_shared/platformFee.ts', 'supabase/migrations/20261029090000_exos_free_tier_resale_consent.sql'],
  },

  // ---- Selling ------------------------------------------------------------
  {
    id: 'paid-checkout', audience: 'organizer', status: 'at_launch',
    claim: 'Organizers sell tickets from their own event page, with Apple Pay and Google Pay, and are paid out to their own Stripe account.',
    code: ['supabase/functions/exos-checkout/index.ts', 'supabase/functions/exos-payouts/index.ts', 'src/views/OrgPayouts.tsx'],
    note: 'Payouts run daily as a dry run until EXOS_PAYOUTS_LIVE is on.',
  },
  {
    id: 'instagram-checkout', audience: 'organizer', status: 'live',
    claim: 'Checkout works inside the Instagram, Facebook and TikTok in-app browsers.',
    code: ['src/lib/inAppBrowser.ts'],
  },
  {
    id: 'tiers-and-presales', audience: 'organizer', status: 'live',
    claim: 'Ticket types can have scheduled price steps, presale codes, hidden tiers, add-ons and promo codes.',
    code: ['src/lib/pricing.ts', 'src/lib/vouchers.ts', 'src/lib/addons.ts', 'supabase/migrations/20260925012000_exos_presale_vouchers.sql'],
  },
  {
    id: 'tables-guest-lists', audience: 'organizer', status: 'live',
    claim: 'Organizers can sell tables and run guest lists and comps.',
    code: ['src/lib/guestLists.ts', 'src/lib/comps.ts', 'supabase/migrations/20260926050000_exos_tables_guest_lists.sql'],
  },
  {
    id: 'series', audience: 'organizer', status: 'live',
    claim: 'Recurring events can be set up as a series.',
    code: ['src/views/CreateSeries.tsx', 'supabase/migrations/20260911133000_exos_event_series.sql'],
  },
  {
    id: 'waitlist', audience: 'fan', status: 'live',
    claim: 'Sold-out events have a waitlist that offers freed tickets automatically.',
    code: ['src/lib/waitlist.ts', 'supabase/migrations/20260616220000_exos_waitlist_autoassign.sql'],
  },
  {
    id: 'storefront-embed', audience: 'organizer', status: 'live',
    claim: 'Each organizer gets a storefront page and an embeddable widget for their own website.',
    code: ['src/views/OrgStorefront.tsx', 'public/embed.js', 'src/lib/embed.ts'],
  },
  {
    id: 'promoters', audience: 'organizer', status: 'live',
    claim: 'Promoters get tracked links, a private portal, a link-in-bio page and a leaderboard.',
    code: ['src/views/PromoterPortal.tsx', 'src/views/PromoterBio.tsx', 'src/views/OrgPromoters.tsx'],
  },
  {
    id: 'fan-referrals', audience: 'fan', status: 'live',
    claim: 'Ticket holders can share an event with a personal link that shows how many friends are coming.',
    code: ['src/lib/referrals.ts', 'src/lib/shareLinks.ts'],
  },
  {
    id: 'invoices-tax', audience: 'organizer', status: 'live',
    claim: 'Orders get receipts and invoices, with sales tax rules per ticket type.',
    code: ['src/lib/invoices.ts', 'src/lib/tax.ts'],
  },
  {
    id: 'money-journal', audience: 'organizer', status: 'live',
    claim: 'Each organizer gets a double-entry money journal of their sales, refunds, fees, gift cards, payouts and door cash, with a trial balance, a journal CSV export and a sales tax report by jurisdiction.',
    code: ['src/lib/journal.ts', 'src/lib/journalApi.ts', 'src/components/finance/JournalPanel.tsx',
      'src/components/finance/SalesTaxTable.tsx', 'src/components/finance/EventSalesTax.tsx',
      'supabase/functions/exos-api/journal.ts', 'supabase/migrations/20261108100000_exos_money_journal.sql',
      'supabase/migrations/20261110100000_exos_journal_complete.sql'],
    note: 'Door cash sales, the cash drawer, gift cards and $0 orders post today; online card sales, card at the door, refunds and payouts post once payments are on (docs/payments-go-live.md).',
  },
  {
    id: 'attendance-report', audience: 'organizer', status: 'not_shipped',
    claim: 'Organizers get an attendance report for each event: attendees by billing postal code (areas with fewer than 5 buyers grouped together, never named) and daily sales pace against an earlier event, downloadable as XLSX along with the settlement, sales tax and journal reports.',
    code: ['src/lib/attendanceReport.ts', 'src/lib/xlsx.ts', 'src/components/AttendanceReportPanel.tsx',
      'supabase/functions/exos-api/attendance.ts', 'supabase/migrations/20261113120000_exos_attendance_report.sql'],
    note: 'Branch claude/exos-attendance-report (wave 13): not on main, migration not applied. Postal codes exist only for paid orders since mig 20261106140000, so the rollup is empty until card payments are on.',
  },
  {
    id: 'api-fee-adjustments', audience: 'organizer', status: 'live',
    claim: 'Through the Exos API, an organizer\'s systems can record a fee change on an order (POST /v1/orders/:id/adjustments); it is logged with a note and moves no money.',
    code: ['supabase/functions/exos-api/feeAdjustments.ts', 'supabase/migrations/20261108110000_exos_dice_leftovers.sql'],
  },

  // ---- Fans ---------------------------------------------------------------
  {
    id: 'transfers', audience: 'fan', status: 'live',
    claim: 'Tickets can be transferred to a friend at face value; the old code stops working when the friend claims it.',
    code: ['src/views/TransferTicket.tsx', 'src/views/ClaimTicket.tsx'],
  },
  {
    id: 'group-pay', audience: 'fan', status: 'off',
    claim: 'A group can pay separately: the host holds up to 10 seats for 30 minutes (timed-entry and price-step tickets too, at one slot and one locked price) and texts each friend a link to pay for their own seat, and can cover whatever is left.',
    code: ['src/lib/groupPay.ts', 'src/components/GroupPayStart.tsx', 'src/views/GroupPayHost.tsx', 'src/views/GroupPaySeat.tsx',
      'supabase/migrations/20261108120000_exos_group_pay.sql', 'supabase/migrations/20261110110000_exos_group_pay_2.sql',
      'supabase/migrations/20261111120000_exos_group_pay_off.sql', 'src/lib/groupPayFlag.ts'],
    note: 'Paused by operator 2026-11-09: dormant behind the group_pay_enabled platform setting, EXOS_GROUP_PAY on exos-checkout and VITE_EXOS_GROUP_PAY in the build, all off. "Split with friends" (the host pays, friends pay back) is unaffected.',
  },
  {
    id: 'refunds', audience: 'fan', status: 'at_launch',
    claim: 'Organizers can refund orders, and buyers can ask for a refund when an event is rescheduled.',
    code: ['src/lib/refunds.ts', 'supabase/functions/exos-refund/index.ts', 'src/views/RescheduleRefund.tsx'],
  },
  {
    id: 'accessible-tickets', audience: 'fan', status: 'live',
    claim: 'Buyers can tell the organizer what they need at the door (wheelchair space, a companion seat, a step-free route, ASL and more).',
    code: ['src/lib/accessibility.ts'],
  },

  {
    id: 'booking-settlements', audience: 'organizer', status: 'live',
    claim: 'Venues can manage holds on a booking calendar, send offers with deal math, and settle shows with the artist.',
    code: ['src/views/BookingCalendar.tsx', 'src/views/OrgOffers.tsx', 'src/views/SettlementPublic.tsx',
      'supabase/migrations/20261030100000_exos_booking.sql', 'supabase/migrations/20261031100500_exos_settlements.sql'],
  },
  {
    id: 'memberships', audience: 'organizer', status: 'at_launch',
    claim: 'Venues can sell season passes, flex packs and memberships that fans redeem for tickets.',
    code: ['src/views/OrgMemberships.tsx', 'src/views/MyMemberships.tsx',
      'supabase/migrations/20261030130500_exos_passes_memberships.sql'],
  },
  {
    id: 'seating-timed-entry', audience: 'organizer', status: 'at_launch',
    claim: 'Events can have reserved seating with a seat picker, or timed entry slots.',
    code: ['src/views/OrgSeatMaps.tsx', 'src/components/SlotPicker.tsx',
      'supabase/migrations/20261030140000_exos_seating.sql', 'supabase/migrations/20261030150000_exos_series_timed_entry.sql'],
  },
  {
    id: 'gift-cards', audience: 'fan', status: 'at_launch',
    claim: 'Organizers can sell gift cards, and buyers can pay with them.',
    code: ['src/components/OrgGiftCardsPanel.tsx', 'src/views/GiftCardBalance.tsx',
      'supabase/migrations/20261030130000_exos_gift_cards_giving.sql'],
  },
  {
    id: 'walk-up-sales', audience: 'organizer', status: 'live',
    claim: 'Door staff can sell walk-up tickets for cash, give comps, and close out a cash drawer at the end of the night.',
    code: ['src/components/PosDrawersPanel.tsx', 'supabase/functions/exos-pos/index.ts',
      'supabase/migrations/20261107100000_exos_pos_walkup.sql'],
  },
  {
    id: 'org-audit-log', audience: 'organizer', status: 'at_launch',
    claim: 'Changes to events, ticket types, promo codes, holds, refunds, payouts and team access are kept in an audit log that can\'t be edited, showing who made each one, when and from where, with a CSV export and an API.',
    code: ['src/views/OrgActivity.tsx', 'supabase/functions/exos-api/audit.ts',
      'supabase/migrations/20261109100000_exos_org_audit.sql'],
    note: 'Works once mig 20261109100000 is applied (scripts/rollout-prod.sh).',
  },

  // ---- Door ---------------------------------------------------------------
  {
    id: 'rotating-barcodes', audience: 'organizer', status: 'live',
    claim: 'Ticket QR codes change every 30 seconds, so screenshots and forwarded codes do not get in.',
    code: ['src/lib/barcode.ts', 'supabase/migrations/20261019100000_exos_door_day_keys.sql'],
  },
  {
    id: 'offline-door', audience: 'organizer', status: 'live',
    claim: 'The door scanner keeps working without signal and syncs when it reconnects.',
    code: ['src/views/OrganizerCheckIn.tsx', 'src/lib/door/roster.ts'],
  },
  {
    id: 'free-door-app', audience: 'organizer', status: 'live',
    claim: 'The Exos Door app is free for any event, including tickets sold on Eventbrite, Posh, DICE, Shotgun or RA (import their attendee CSV).',
    code: ['src/views/DoorApp.tsx', 'src/lib/door/imports.ts', 'supabase/migrations/20261013090000_exos_door_imports.sql'],
  },
  {
    id: 'door-name-checkin', audience: 'organizer', status: 'live',
    claim: 'Door staff can check guests in by name as well as by scanning, on as many phones as they need.',
    code: ['src/views/OrganizerCheckIn.tsx', 'src/lib/door/roster.ts', 'src/views/DoorApp.tsx'],
    note: 'An organizer can turn check-in by name off for an event (QR only).',
  },
  {
    id: 'fair-days', audience: 'organizer', status: 'live',
    claim: 'Fairs and rodeos can set up day passes, multi-day and any-day passes, parking and camping in one step, with a check-in list per day that admits each pass only on its days, a lot list for parking and camping codes, and gate-by-gate entries every 15 minutes on the door report.',
    code: ['src/lib/fairSetup.ts', 'src/components/FairSetupPanel.tsx', 'src/components/DoorThroughputPanel.tsx',
      'src/lib/door/lists.ts', 'supabase/migrations/20261113110000_exos_fair_day.sql'],
    note: 'Live once mig 20261113110000 is applied (scripts/rollout-prod.sh); selling paid passes needs payments on (docs/payments-go-live.md).',
  },
  {
    id: 'walkup-questions', audience: 'organizer', status: 'live',
    claim: 'Walk-up sales at the door ask the same checkout questions as online; staff can skip them to keep the line moving, and every skip is logged.',
    code: ['src/components/DoorSellPanel.tsx', 'supabase/functions/_shared/pos/walkup.ts',
      'supabase/migrations/20261108110000_exos_dice_leftovers.sql'],
  },
  {
    id: 'addon-scan-undo', audience: 'organizer', status: 'live',
    claim: 'A mistaken add-on scan (a VIP lounge, a merch pickup) can be undone from the scan log, with a reason, by the scanner within 10 minutes or by a manager any time.',
    code: ['src/lib/addonUndo.ts', 'src/views/OrganizerCheckIn.tsx', 'supabase/migrations/20261108110000_exos_dice_leftovers.sql'],
  },

  // ---- Discovery ----------------------------------------------------------
  {
    id: 'google-events', audience: 'organizer', status: 'off',
    claim: 'Events appear in Google Search and Maps ticket links.',
    code: ['supabase/functions/exos-google-feed/index.ts'],
    note: 'The feed is deployed; Exos has not joined Google\'s events ticketing program.',
  },
  {
    id: 'neighborhood-pages', audience: 'fan', status: 'live',
    claim: 'Exos has a page of this week\'s events for each New York neighborhood, such as Bushwick, Williamsburg, Ridgewood and the Lower East Side, at /nyc.',
    code: ['src/views/NeighborhoodPage.tsx', 'src/views/NeighborhoodsIndex.tsx', 'src/lib/neighborhoods.ts',
      'supabase/migrations/20261111110000_exos_neighborhoods.sql'],
    note: 'Live once mig 20261111110000 is applied (scripts/rollout-prod.sh); events need a geocoded venue (exos-geocode).',
  },
  {
    id: 'follower-new-event-email', audience: 'fan', status: 'off',
    claim: 'Fans who follow an organizer get an email when it announces a new event, at most one a day, with a one-click unfollow link.',
    code: ['src/lib/followers.ts', 'supabase/functions/_shared/mail-templates.ts',
      'supabase/migrations/20261111110000_exos_neighborhoods.sql'],
    note: 'Queued, never sent, until exos-mail-drain runs with Resend (docs/email.md); the hourly batch cron exos-follower-digests-hourly is created inactive.',
  },
  {
    id: 'calendar-feeds', audience: 'fan', status: 'live',
    claim: 'Organizer and venue calendars can be subscribed to in Google, Apple or Outlook calendar.',
    code: ['supabase/functions/exos-calendar/index.ts', 'src/lib/calendar.ts'],
  },
  {
    id: 'ai-assistants', audience: 'fan', status: 'live',
    claim: 'AI assistants can search Exos events and get checkout links through the Exos MCP server; the person always finishes checkout themselves.',
    code: ['supabase/functions/exos-mcp/index.ts', 'docs/mcp.md'],
  },
  {
    id: 'ad-catalogs', audience: 'organizer', status: 'live',
    claim: 'Organizers can export their events as a Meta, TikTok or Google ad catalog.',
    code: ['supabase/functions/exos-catalog-feed/index.ts'],
  },

  // ---- Off or not shipped (never told to assistants) ------------------------
  {
    id: 'wallet-passes', audience: 'fan', status: 'off',
    claim: 'Tickets can be added to Apple Wallet and Google Wallet.',
    code: ['supabase/functions/exos-wallet/index.ts', 'src/views/WalletPass.tsx'],
    note: 'Needs an Apple Pass Type ID certificate and a Google Wallet issuer account.',
  },
  {
    id: 'addon-wallet-passes', audience: 'fan', status: 'off',
    claim: 'An add-on with its own entry code (a VIP lounge, a merch pickup) gets its own Apple Wallet or Google Wallet pass.',
    code: ['supabase/functions/_shared/wallet/addonPass.ts', 'supabase/functions/exos-wallet/index.ts',
      'supabase/migrations/20261108110000_exos_dice_leftovers.sql', 'src/components/AddonPassesCard.tsx'],
    note: 'Built (POST /exos-wallet/addon-pass, and an "Add to … Wallet" button per add-on code on the ticket page), but wallets are not configured (the same Apple certificate and Google issuer account as wallet-passes), so the buttons stay hidden. The add-on codes themselves (AddonPassesCard) work at the door today.',
  },
  {
    id: 'sms', audience: 'organizer', status: 'off',
    claim: 'Organizers can text their opted-in fans from their own Twilio or Telnyx account.',
    code: ['supabase/functions/exos-sms-drain/index.ts'],
    note: 'Dry run until EXOS_SMS_LIVE=on.',
  },
  {
    id: 'marketplace-distribution', audience: 'organizer', status: 'off',
    claim: 'Organizers can list part of their inventory on resale marketplaces at their own price.',
    code: ['supabase/functions/exos-distribute/index.ts', 'supabase/functions/exos-s4k-feed/index.ts'],
    note: 'exos-distribute is undeployed until each partner write is signed off; the S4K feed needs id mapping.',
  },
  {
    id: 'eventbrite-mirror', audience: 'organizer', status: 'off',
    claim: 'Exos events can be mirrored to the organizer\'s own Eventbrite account.',
    code: ['supabase/functions/exos-eventbrite-sync/index.ts'],
    note: 'Reads run; writes are a dry run until the org switch and EXOS_EVENTBRITE_WRITES=on.',
  },
  {
    id: 'alt-payments', audience: 'fan', status: 'off',
    claim: 'Buyers can pay with PayPal, Venmo or Cash App.',
    code: ['supabase/functions/exos-paypal/index.ts', 'supabase/migrations/20261031220000_exos_payments_paypal_cashapp_split.sql'],
    note: 'Needs the PayPal app keys and VITE_PAYPAL_CLIENT_ID (docs/payments-go-live.md), then each org turns it on.',
  },
  {
    id: 'card-at-door', audience: 'organizer', status: 'off',
    claim: 'Door staff can take card payments at the door with a card reader.',
    code: ['supabase/functions/exos-pos/index.ts', 'supabase/migrations/20261107130000_exos_pos_terminal.sql'],
    note: 'Off until EXOS_POS_CARD=on.',
  },
  {
    id: 'kiosk-mode', audience: 'organizer', status: 'off',
    claim: 'Organizers can run self-serve ticket kiosks: a locked screen that sells one event\'s tickets by card on its own reader, resets after each buyer, and only staff with the PIN can leave.',
    code: ['src/views/Kiosk.tsx', 'src/lib/kiosk.ts', 'supabase/functions/exos-pos/index.ts', 'supabase/migrations/20261113100000_exos_kiosk.sql'],
    note: 'Built, but it sells only by card at the door, which is off until EXOS_POS_CARD=on; until then a kiosk shows "unavailable".',
  },
  {
    id: 'dice-import', audience: 'organizer', status: 'off',
    claim: 'Promoters can import their DICE events, ticket holders and opted-in fans.',
    code: ['supabase/functions/exos-dice-import/index.ts', 'supabase/migrations/20261106100000_exos_dice_import.sql'],
    note: 'Never run against a real DICE token; needs EXOS_DICE_IMPORT=on and its cron turned on.',
  },
  {
    id: 'promoter-payouts', audience: 'organizer', status: 'off',
    claim: 'Promoters are paid their commission straight to their bank through Stripe.',
    code: ['supabase/functions/exos-promoter-payouts/index.ts'],
    note: 'Off until EXOS_PROMOTER_TRANSFERS is on.',
  },
  {
    id: 'discord-promotion', audience: 'organizer', status: 'off',
    claim: 'Organizers can promote events in their own Discord server: an announcement in a channel when an event is published, and the event on the server\'s Discord events list, kept in step with Exos.',
    code: ['src/components/DiscordPanel.tsx', 'src/components/DiscordEventPanel.tsx', 'src/lib/discord.ts',
      'supabase/functions/exos-discord/index.ts', 'supabase/functions/_shared/channels/discord.ts',
      'supabase/migrations/20261113130000_exos_discord.sql'],
    note: 'Branch claude/exos-discord: not on main, migration not applied. Dark until EXOS_DISCORD_ENABLED=on; a dry run until the org switch and EXOS_DISCORD_WRITES=on; the bot needs the platform\'s Discord application (docs/discord.md).',
  },  {
    id: 'spanish', audience: 'fan', status: 'not_shipped',
    claim: 'Exos works in Spanish for ticket buyers and door staff: the event page, checkout, tickets, sending a ticket, the main buyer emails, the door scanner and the door till. Organizers can add a Spanish title and description to an event.',
    code: ['src/lib/i18n/dict.ts', 'src/lib/i18n/checkout.ts', 'src/lib/i18n/door.ts', 'src/lib/i18n/pos.ts',
      'supabase/functions/_shared/mail-es.ts', 'supabase/migrations/20261114130000_exos_event_i18n.sql'],
    note: 'Branch claude/exos-spanish: not on main, migration not applied. The money and legal wording waits for a human review (docs/i18n-review.md); organizer screens are English.',
  },
];

const STATUS_LABEL: Record<FactStatus, string> = {
  live: 'Live', at_launch: 'At launch', off: 'Off', not_shipped: 'Not shipped',
};

/** The table rows of docs/ai-facts.md, one per fact (the test checks the doc matches). */
export function factsTableRows(facts: ProductFact[] = PRODUCT_FACTS): string {
  return facts.map((f) => {
    const code = f.code.length ? f.code.map((c) => '`' + c + '`').join(', ') : '—';
    return `| \`${f.id}\` | ${STATUS_LABEL[f.status]} | ${f.audience} | ${f.claim.replace(/\|/g, '\\|')} | ${code} | ${f.note ?? ''} |`;
  }).join('\n');
}

/** The facts an assistant may repeat: live today, or on at launch with llms.txt itself. */
export function assistantFacts(facts: ProductFact[] = PRODUCT_FACTS): ProductFact[] {
  return facts.filter((f) => f.status === 'live' || f.status === 'at_launch');
}
