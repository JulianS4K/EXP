// X (Twitter) Conversions API: a Purchase to the org's X pixel.
//
//   POST https://ads-api.x.com/12/measurement/conversions/<pixel_id>
//   Authorization: OAuth oauth_consumer_key=…, oauth_token=…, oauth_signature=… (OAuth 1.0a, HMAC-SHA1)
//   { conversions: [ { conversion_time (ISO 8601), event_id: "tw-<pixel>-<event>",
//       identifiers: [ { twclid } | { hashed_email } ], number_items,
//       price_currency, value, conversion_id, description } ] }
//
// conversion_id = the Stripe session id, the same conversion_id the browser
// X pixel's Purchase carries (src/lib/pixels.ts xEvent), so X counts one.
// twclid is the click id captured at checkout (ad_ids.twclid); hashed_email
// is sha256(lower(trim(email))) (payload.em).
//
// Credentials: the org's row in the channel-core store, provider ads_x
// (exos_integration_secret): config {pixel_id, event_id}, secret
// {"token", "token_secret"} (the advertiser's OAuth 1.0a user token, from an
// X sign-in that is NOT built yet: an operator step). The consumer key and
// secret are Exos's X developer app (env X_ADS_CONSUMER_KEY /
// X_ADS_CONSUMER_SECRET); without them the request is planned only.
// The request is signed and sent by the x_ads adapter through GatedHttp
// (channels/adapters/xAds.ts); this builder makes the unsigned request the
// drain stores in payload_planned.
//
// UNVERIFIED (X's developer docs were not readable from the build session):
// the identifiers' shape, value as a number, the 12 version segment and the
// age window (held to 7 days here). Send one with a test pixel first.
// X has no standard refund event.
// Docs: https://developer.x.com/en/docs/x-ads-api/measurement/web-conversions/conversion-api

import {
  type BuildContext, type BuildResult, type ConversionRow, type Credential,
  compact, hashOrUndefined, skip, toMajor, tooOld, upperCurrency,
} from "./common.ts";

export const X_ADS_BASE = "https://ads-api.x.com";
export const X_ADS_VERSION = "12";
/** X takes at most this many conversions in one request (unverified). */
export const X_MAX_CONVERSIONS = 500;

export const X_PIXEL_RE = /^[a-z0-9]{3,20}$/;
export const X_EVENT_RE = /^tw-[a-z0-9]{3,20}-[a-z0-9]{3,20}$/;

/** The path on X_ADS_BASE (what the x_ads allowlist pins). */
export const xConversionsPath = (pixel: string): string => `/${X_ADS_VERSION}/measurement/conversions/${encodeURIComponent(pixel)}`;

export function buildX(row: ConversionRow, cred: Credential, ctx: BuildContext): BuildResult {
  if (row.event_name !== "Purchase") return skip("x: no standard refund event");
  const pixel = cred.config.pixel_id;
  const eventId = cred.config.event_id;
  if (!pixel || !X_PIXEL_RE.test(pixel)) return skip("x: no pixel id");
  if (!eventId || !X_EVENT_RE.test(eventId) || !eventId.startsWith(`tw-${pixel}-`)) return skip("x: no purchase event id for the pixel");
  const old = tooOld(row, ctx.now);
  if (old) return skip(old);
  const p = row.payload;
  const em = hashOrUndefined(p.em);
  const twclid = p.ad_ids?.twclid;
  if (!em && !twclid) return skip("x: nothing to match on (no email hash or twclid)");
  const identifiers: Array<Record<string, string>> = [];
  if (twclid) identifiers.push({ twclid });
  if (em) identifiers.push({ hashed_email: em });

  const conversion = compact({
    conversion_time: new Date(Date.parse(row.occurred_at)).toISOString(),
    event_id: eventId,
    identifiers,
    number_items: p.quantity,
    price_currency: upperCurrency(row.currency),
    value: toMajor(row.value_cents),
    conversion_id: row.event_id_dedupe,
    description: p.event?.name ? p.event.name.slice(0, 100) : undefined,
  });
  return {
    ok: true,
    request: {
      method: "POST",
      url: `${X_ADS_BASE}${xConversionsPath(pixel)}`,
      // Signed per request by the x_ads adapter (OAuth 1.0a); never stored.
      headers: { "content-type": "application/json", Authorization: "OAuth <signed when sent>" },
      body: { conversions: [conversion] },
    },
  };
}
