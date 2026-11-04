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
  EXOS_FEE_BPS, FEE_FREE_MONTHS, STRIPE_CARD_FEE, exosFeeCents, stripeFeeCents,
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
    id: 'free-tier', audience: 'organizer', status: 'not_shipped',
    claim: 'Events with a capacity of 150 or less never pay an Exos fee.',
    code: [],
    note: 'In the open build stack (mig 20261029090000, #79/#80), not on main.',
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

  // ---- Fans ---------------------------------------------------------------
  {
    id: 'transfers', audience: 'fan', status: 'live',
    claim: 'Tickets can be transferred to a friend at face value; the old code stops working when the friend claims it.',
    code: ['src/views/TransferTicket.tsx', 'src/views/ClaimTicket.tsx'],
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

  // ---- Discovery ----------------------------------------------------------
  {
    id: 'google-events', audience: 'organizer', status: 'off',
    claim: 'Events appear in Google Search and Maps ticket links.',
    code: ['supabase/functions/exos-google-feed/index.ts'],
    note: 'The feed is deployed; Exos has not joined Google\'s events ticketing program.',
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
    id: 'booking-settlements', audience: 'organizer', status: 'not_shipped',
    claim: 'Venues can manage holds, offers, deal math and settlements in Exos.',
    code: [],
    note: 'Open build stack (#67, #71, #79/#80).',
  },
  {
    id: 'memberships', audience: 'organizer', status: 'not_shipped',
    claim: 'Venues can sell season passes, flex packs and memberships.',
    code: [],
    note: 'Open build stack (#70, #79/#80).',
  },
  {
    id: 'alt-payments', audience: 'fan', status: 'not_shipped',
    claim: 'Buyers can pay with Venmo, PayPal or Cash App.',
    code: [],
    note: 'Open build stack (#77, #79/#80).',
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
