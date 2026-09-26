// The channel registry: which marketplaces are wired, built from secrets.
// A channel without credentials still exists (it can plan requests and read
// sales Terminal-2 already pulled); it just can't search its catalog.
//
// Secrets (all optional; operator-set):
//   STUBHUB_ENV            'sandbox' | 'production' (default sandbox)
//   STUBHUB_CLIENT_ID / STUBHUB_CLIENT_SECRET   catalog reads (client credentials)
//   SEATGEEK_CLIENT_ID     Platform API catalog reads

import type { ChannelId, MarketplaceChannel } from './channel.ts';
import { StubHubClient, clientCredentialsToken } from './stubhub/client.ts';
import { STUBHUB_ENVIRONMENTS, type StubHubEnvironment } from './stubhub/transport.ts';
import { stubHubChannel } from './stubhub/channel.ts';
import { seatGeekChannel } from './seatgeek/channel.ts';

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

  out.set('seatgeek', seatGeekChannel({ clientId: env('SEATGEEK_CLIENT_ID'), ...(fetchImpl ? { fetch: fetchImpl } : {}) }));

  return out;
}
