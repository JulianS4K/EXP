// The marketplace layer (supabase/functions/_shared/marketplace): one channel
// interface over StubHub, SeatGeek and the rest, shared with the edge
// functions. The StubHub library itself is ./stubhub.
export * from '../../../supabase/functions/_shared/marketplace/channel.ts';
export * from '../../../supabase/functions/_shared/marketplace/match.ts';
export * from '../../../supabase/functions/_shared/marketplace/channels.ts';
export {
  catalogEventToCandidate,
  normalizeStubHubSale,
  stubHubChannel,
} from '../../../supabase/functions/_shared/marketplace/stubhub/channel.ts';
export * from '../../../supabase/functions/_shared/marketplace/seatgeek/channel.ts';
