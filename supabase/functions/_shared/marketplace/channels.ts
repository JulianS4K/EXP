// The channel registry: which marketplaces are wired, built from secrets.
// StubHub only for now; SeatGeek and the rest plug in here later. A channel
// without credentials still exists (it can plan requests); it just can't
// search its catalog.
//
// Secrets (all optional; operator-set):
//   STUBHUB_ENV            'sandbox' | 'production' (default sandbox)
//   STUBHUB_CLIENT_ID / STUBHUB_CLIENT_SECRET   catalog reads (client credentials)

import type { ChannelId, MarketplaceChannel } from './channel.ts';
import { StubHubClient, clientCredentialsToken } from './stubhub/client.ts';
import { STUBHUB_ENVIRONMENTS, type StubHubEnvironment } from './stubhub/transport.ts';
import { stubHubChannel } from './stubhub/channel.ts';

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

  return out;
}
