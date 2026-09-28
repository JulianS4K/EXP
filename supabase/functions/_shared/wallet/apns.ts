// Apple Wallet update pushes. A pass push is an empty JSON payload sent over
// APNs to each registered device's push token, with the Pass Type ID as the
// topic, authenticated with the Pass Type ID certificate (TLS client cert).
// The device then asks the web service which serials changed and fetches them.
//
// The transport is injected: the edge function builds a fetch bound to an
// HTTP client carrying the certificate, when the runtime supports that and the
// operator turned pushes on (EXOS_WALLET_APPLE_PUSH=live). Otherwise pushes are
// a dry run: planned, reported, not sent, and the passes stay push-pending.

import type { FetchLike } from "./google.ts";

export const APNS_HOST = "https://api.push.apple.com";

export interface PushResult {
  sent: number;
  failed: number;
  /** Tokens APNs says are gone (HTTP 410): safe to drop. */
  unregistered: string[];
}

export interface PassPusher {
  readonly live: boolean;
  push(passTypeIdentifier: string, pushTokens: string[]): Promise<PushResult>;
}

export const dryRunPusher: PassPusher = {
  live: false,
  push: () => Promise.resolve({ sent: 0, failed: 0, unregistered: [] }),
};

const TOKEN_RE = /^[0-9a-fA-F]{8,256}$/;

export function apnsPusher(fetchFn: FetchLike, host = APNS_HOST): PassPusher {
  return {
    live: true,
    async push(topic, tokens) {
      const out: PushResult = { sent: 0, failed: 0, unregistered: [] };
      for (const t of tokens) {
        if (!TOKEN_RE.test(t)) {
          out.failed++;
          continue;
        }
        try {
          const res = await fetchFn(`${host}/3/device/${t}`, {
            method: "POST",
            headers: { "apns-topic": topic, "content-type": "application/json" },
            body: "{}",
          });
          if (res.ok) out.sent++;
          else if (res.status === 410) {
            out.unregistered.push(t);
          } else out.failed++;
          await res.body?.cancel();
        } catch {
          out.failed++;
        }
      }
      return out;
    },
  };
}
