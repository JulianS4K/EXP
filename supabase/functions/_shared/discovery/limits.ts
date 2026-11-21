// Channel limits: what a channel's own rules or plan caps mean for an event,
// shown on the recommended-listings view with a short reason (operator
// 2026-11-21). Kept small on purpose: one row per rule, shaped like the
// channel-core platform limits table (id, rule, action, reason, source) so
// the suggestion view can be pointed at that table when the branches meet.
// 'block' takes the channel off the suggestions for that event; 'warn' keeps
// it with the reason. Nothing here counts or enforces anything.
//
// Sources (checked 2026-11-21, as given by Growth's research):
//   * Shotgun: free events must be 100% free, with no paid or parallel
//     ticketing elsewhere (support-pro.shotgun.live, article 33562373508498).
//   * Meetup: the Starter plan caps attendance at 10 per event; Standard or
//     Pro lifts it.
//   * AllEvents: the free plan allows 5 active upcoming events.
//   * Google events: a free event must be publicly bookable, so an
//     invite-only event (no public ticket type) or one hidden from search
//     isn't eligible.
//   * Partiful: in-app invites capped at 1,000 per event; a free event's
//     link takes unlimited guests.
//   * Resale marketplaces (StubHub, SeatGeek, Vivid Seats, Gametime,
//     GoTickets, Ticket Evolution, TickPick): nothing to resell at $0.
//
// Pure: no Deno or Supabase imports.

/** What the rules look at, worked out from the event (limitFacts). */
export interface LimitFacts {
  /** Every public ticket type is $0 (or there is none). */
  free: boolean;
  /** No public ticket type: tickets only through codes or invitations. */
  inviteOnly: boolean;
  /** The organizer hid the event from search (noindex). */
  hidden: boolean;
}

export interface ChannelLimit {
  /** Stable row id. */
  id: string;
  /** Channel ids (discovery channels or marketplaces) the row is about. */
  channels: readonly string[];
  /** When the row applies; omitted = always. */
  rule?: (f: LimitFacts) => boolean;
  action: 'warn' | 'block';
  reason: string;
  /** Where the limit comes from. */
  source: string;
}

export const RESALE_MARKETPLACES = ['stubhub', 'seatgeek', 'vivid', 'gametime', 'gotickets', 'evo', 'tickpick'] as const;

export const CHANNEL_LIMITS: readonly ChannelLimit[] = [
  {
    id: 'shotgun_free_exclusive', channels: ['shotgun'], rule: (f) => f.free, action: 'block',
    reason: 'Shotgun lists a free event only if it is 100% free there, with no ticketing anywhere else.',
    source: 'support-pro.shotgun.live, article 33562373508498',
  },
  {
    id: 'meetup_starter_cap', channels: ['meetup'], action: 'warn',
    reason: "Meetup's Starter plan caps an event at 10 attendees: you need Standard or Pro for more.",
    source: 'Meetup organizer plans',
  },
  {
    id: 'allevents_free_plan', channels: ['allevents'], action: 'warn',
    reason: "AllEvents' free plan allows 5 active upcoming events at a time.",
    source: 'AllEvents organizer plans',
  },
  {
    id: 'google_free_bookable', channels: ['google_events'], rule: (f) => f.free && (f.inviteOnly || f.hidden), action: 'warn',
    reason: 'Google lists a free event only if anyone can book it: an invite-only or hidden event is not eligible.',
    source: 'Google events (free events must be publicly bookable)',
  },
  {
    id: 'partiful_invite_cap', channels: ['partiful'], action: 'warn',
    reason: 'Partiful caps in-app invites at 1,000 per event (a free event takes unlimited guests through its link).',
    source: 'Partiful (operator research 2026-11-21)',
  },
  {
    id: 'resale_no_free', channels: RESALE_MARKETPLACES, rule: (f) => f.free, action: 'block',
    reason: 'Free tickets have nothing to resell, so resale marketplaces are left out.',
    source: 'operator 2026-11-21',
  },
];

interface TierLike { price: number | string | null | undefined }

/** The facts for an event: its public ticket types and its noindex flag. */
export function limitFacts(e: { noindex?: boolean | null; tiers?: readonly TierLike[] | null }): LimitFacts {
  const tiers = e.tiers ?? [];
  return {
    free: tiers.every((t) => !(Number(t.price) > 0)),
    inviteOnly: tiers.length === 0,
    hidden: e.noindex === true,
  };
}

/** The rows that apply to this channel for this event (block first). */
export function channelLimits(channelId: string, f: LimitFacts): ChannelLimit[] {
  return CHANNEL_LIMITS
    .filter((l) => l.channels.includes(channelId) && (l.rule ? l.rule(f) : true))
    .sort((a, b) => (a.action === b.action ? 0 : a.action === 'block' ? -1 : 1));
}

/** Should the channel be left off the suggestions for this event? */
export function hiddenByLimit(channelId: string, f: LimitFacts): boolean {
  return channelLimits(channelId, f).some((l) => l.action === 'block');
}
