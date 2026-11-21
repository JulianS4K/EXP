// X (Twitter) conversions on the channel core (ads phase, mig
// 20261121190500): the X Conversions API sender of the conversions outbox.
// exos-conversions-drain builds the request (conversions/x.ts), stores it in
// payload_planned, and, only when EXOS_CONVERSIONS_LIVE=true and Exos's X app
// keys are set, hands it to this adapter, which signs it (OAuth 1.0a) and
// sends it through ctx.http: GatedHttp sends only with the org's switch (the
// ads_x row's writes_enabled) AND EXOS_X_ADS_WRITES=on, on the one allowlisted
// path. Every flag is off: today this is a dry run end to end.
//
//   POST https://ads-api.x.com/12/measurement/conversions/<pixel_id>
//   Authorization: OAuth … (HMAC-SHA1; the consumer key / secret are Exos's X
//   app, the token / token secret the advertiser's, from the store's ads_x
//   secret {"token", "token_secret"})

import { caps, type ChannelAdapter, type ChannelCtx, type OrgCredential } from "../adapter.ts";
import type { WriteRule } from "../gatedHttp.ts";
import { oauth1Header, parseXTokenSecret } from "../../oauth1.ts";
import { X_ADS_BASE, X_PIXEL_RE, xConversionsPath } from "../../conversions/x.ts";

/** Exactly the write the adapter makes. */
export const X_ADS_WRITES: WriteRule[] = [
  { method: "POST", path: /^\/12\/measurement\/conversions\/[a-z0-9]{3,20}$/ },
];

export interface XAppKeys { consumerKey: string; consumerSecret: string }

/** Exos's X app keys from env, or null (then X rows stay planned only). */
export function xAppKeys(env: (k: string) => string | undefined | null): XAppKeys | null {
  const consumerKey = (env("X_ADS_CONSUMER_KEY") ?? "").trim();
  const consumerSecret = (env("X_ADS_CONSUMER_SECRET") ?? "").trim();
  return consumerKey && consumerSecret ? { consumerKey, consumerSecret } : null;
}

/** GatedHttp options for this channel; every key is a secret to redact. */
export function xAdsHttp(creds: OrgCredential | null, app: XAppKeys | null) {
  const t = parseXTokenSecret(creds?.secret);
  return {
    channel: "x_ads",
    base: X_ADS_BASE,
    writes: X_ADS_WRITES,
    secrets: [creds?.secret, t?.token, t?.tokenSecret, app?.consumerSecret],
  };
}

export interface XConversion {
  pixelId: string;
  /** The body conversions/x.ts built ({conversions: [...]}). */
  body: unknown;
  app: XAppKeys;
  nonce?: string;
  timestamp?: number;
}

async function sendConversion(ctx: ChannelCtx, conversion: Record<string, unknown>) {
  const c = conversion as unknown as XConversion;
  if (!X_PIXEL_RE.test(String(c.pixelId ?? ""))) return { ok: false, status: 0, error: "x: no pixel id", live: false, planned: false };
  const t = parseXTokenSecret(ctx.creds.secret);
  if (!t) return { ok: false, status: 0, error: "x: no X token saved (connect X)", live: false, planned: false };
  const path = xConversionsPath(c.pixelId);
  const auth = await oauth1Header("POST", `${X_ADS_BASE}${path}`,
    { consumerKey: c.app.consumerKey, consumerSecret: c.app.consumerSecret, token: t.token, tokenSecret: t.tokenSecret },
    { nonce: c.nonce, timestamp: c.timestamp });
  return ctx.http.request("POST", path, { body: c.body, headers: { Authorization: auth }, op: "conversion.send" });
}

export const xAdsAdapter: ChannelAdapter = {
  id: "x_ads",
  label: "X Ads (conversions)",
  status: "core",
  caps: caps({ role: "secondary", sendConversion: true }),
  writes: X_ADS_WRITES,
  sendConversion,
};
