// The marketplace layer (supabase/functions/_shared/marketplace): one channel
// interface over the marketplaces, shared with the edge
// functions. StubHub is the only channel wired so far; its library is ./stubhub.
export * from '../../../supabase/functions/_shared/marketplace/channel.ts';
export * from '../../../supabase/functions/_shared/marketplace/match.ts';
export * from '../../../supabase/functions/_shared/marketplace/channels.ts';
export {
  catalogEventToCandidate,
  normalizeStubHubSale,
  stubHubChannel,
} from '../../../supabase/functions/_shared/marketplace/stubhub/channel.ts';
export * from '../../../supabase/functions/_shared/marketplace/sales.ts';
