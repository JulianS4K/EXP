// The channel registry: which marketplaces are wired, built from secrets.
// StubHub, SeatGeek, Gametime, GoTickets, Vivid Seats and Ticket Evolution; the rest plug in here later. A channel without
// credentials still exists (it can plan requests); it just can't search its
// catalog.
//
// Secrets (all optional; operator-set):
//   STUBHUB_ENV            'sandbox' | 'production' (default sandbox)
//   STUBHUB_CLIENT_ID / STUBHUB_CLIENT_SECRET   catalog reads (client credentials)
//   SEATGEEK_CLIENT_ID     SeatGeek Platform API event search (read-only)
//   VIVID_API_TOKEN        Vivid Seats Broker Portal token (event search here;
//   VIVID_INTEGRATOR_TOKEN orders in exos-marketplace-sales), + the optional
//                          X-Integrator-Token
//   TEVO_REVIEWER_ID       the Ticket Evolution user id that accepts orders
//                          (TEvo delivery plans; its reads are in exos-marketplace-sales)

import type { ChannelId, MarketplaceChannel } from './channel.ts';
import { StubHubClient, clientCredentialsToken } from './stubhub/client.ts';
import { STUBHUB_ENVIRONMENTS, type StubHubEnvironment } from './stubhub/transport.ts';
import { stubHubChannel } from './stubhub/channel.ts';
import { seatGeekChannel } from './seatgeek/channel.ts';
import { SeatGeekPlatformClient } from './seatgeek/platform.ts';
import { gametimeChannel } from './gametime/channel.ts';
import { goTicketsChannel } from './gotickets/channel.ts';
import { vividChannel } from './vivid/channel.ts';
import { VividClient } from './vivid/client.ts';
import { evoChannel } from './tevo/channel.ts';

export type Env = (key: string) => string | undefined;

export function channelsFromEnv(env: Env, fetchImpl?: typeof fetch): Map<ChannelId, MarketplaceChannel> {
  const out = new Map<ChannelId, MarketplaceChannel>();

  const shEnv: StubHubEnvironment = env('STUBHUB_ENV') === 'production' ? 'production' : 'sandbox';
  const shId = env('STUBHUB_CLIENT_ID');
  const shSecret = env('STUBHUB_CLIENT_SECRET');
  const shClient = shId && shSecret
    ? new StubHubClient({
        environment: shEnv,
        accessToken: clientCredentialsToken({
          tokenUrl: STUBHUB_ENVIRONMENTS[shEnv].tokenUrl,
          clientId: shId,
          clientSecret: shSecret,
          ...(fetchImpl ? { fetch: fetchImpl } : {}),
        }),
        ...(fetchImpl ? { fetch: fetchImpl } : {}),
      })
    : undefined;
  out.set('stubhub', stubHubChannel(shClient));

  const sgClientId = env('SEATGEEK_CLIENT_ID')?.trim();
  out.set('seatgeek', seatGeekChannel(sgClientId ? new SeatGeekPlatformClient(sgClientId, fetchImpl ? { fetch: fetchImpl } : {}) : undefined));

  // No event search on Gametime: listings carry the event as text.
  out.set('gametime', gametimeChannel());
  // GoTickets maps listings to its events itself.
  out.set('gotickets', goTicketsChannel());

  const vividToken = env('VIVID_API_TOKEN')?.trim();
  const vividIntegrator = env('VIVID_INTEGRATOR_TOKEN')?.trim() || null;
  out.set('vivid', vividChannel(vividToken
    ? new VividClient({ credentials: () => ({ apiToken: vividToken, integratorToken: vividIntegrator }), ...(fetchImpl ? { fetch: fetchImpl } : {}) })
    : undefined));

  const reviewer = Number.parseInt(env('TEVO_REVIEWER_ID') ?? '', 10);
  out.set('evo', evoChannel({ reviewerId: Number.isInteger(reviewer) && reviewer > 0 ? reviewer : null }));

  return out;
}
