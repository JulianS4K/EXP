// GA4 Measurement Protocol: purchase and refund to the org's web stream.
//
//   POST https://www.google-analytics.com/mp/collect?measurement_id=G-…&api_secret=…
//   { client_id, timestamp_micros, user_data: { sha256_email_address: [...] },
//     consent: { ad_user_data, ad_personalization },
//     events: [ { name: "purchase" | "refund", params: { transaction_id,
//       value, currency, items: [ { item_id, item_name, quantity, price } ] } } ] }
//
// client_id must be the browser's GA client id (from the _ga cookie, captured
// with consent at checkout); without it the row is skipped rather than
// inventing a user. transaction_id = the Stripe session id, the same one the
// browser purchase carries, so GA4 can drop the duplicate purchase.
// The api_secret is a query parameter by design of the protocol; it is
// redacted from payload_planned. MP answers 2xx even for a malformed hit, so
// "sent" means accepted for transport only; validate with /debug/mp/collect.
// timestamp_micros may be at most 72 hours old.
// Docs: https://developers.google.com/analytics/devguides/collection/protocol/ga4/sending-events
//       https://developers.google.com/analytics/devguides/collection/protocol/ga4/reference
//       https://developers.google.com/analytics/devguides/collection/ga4/uid-data (user_data)

import {
  type BuildContext, type BuildResult, type ConversionRow, type Credential,
  compact, hashOrUndefined, skip, toMajor, tooOld, unitPrice, upperCurrency,
} from "./common.ts";

export const GA4_COLLECT_URL = "https://www.google-analytics.com/mp/collect";

export function buildGa4(row: ConversionRow, cred: Credential, ctx: BuildContext): BuildResult {
  const mid = cred.config.measurement_id;
  if (!mid || !/^G-[A-Z0-9]{4,20}$/.test(mid)) return skip("ga4: no measurement id");
  const old = tooOld(row, ctx.now);
  if (old) return skip(old);
  const p = row.payload;
  const clientId = p.ad_ids?.ga_client_id;
  if (!clientId) return skip("ga4: no GA client id captured at checkout");
  const em = hashOrUndefined(p.em_google);
  const ph = hashOrUndefined(p.ph);

  const isRefund = row.event_name === "Refund";
  const params = compact({
    transaction_id: p.transaction_id,
    value: toMajor(row.value_cents),
    currency: upperCurrency(row.currency),
    // A partial refund names no items (GA4 then takes the value as given);
    // a purchase lists the one ticket line.
    items: !isRefund && p.event?.id
      ? [compact({
          item_id: p.event.id,
          item_name: p.event.name,
          quantity: p.quantity ?? 1,
          price: unitPrice(row.value_cents, p.quantity),
        })]
      : undefined,
    debug_mode: cred.test_event_code ? 1 : undefined,
  });

  const q = new URLSearchParams({ measurement_id: mid, api_secret: cred.secret });
  return {
    ok: true,
    request: {
      method: "POST",
      url: `${GA4_COLLECT_URL}?${q.toString()}`,
      headers: { "content-type": "application/json" },
      body: compact({
        client_id: clientId,
        timestamp_micros: Date.parse(row.occurred_at) * 1000,
        user_data: em || ph
          ? compact({ sha256_email_address: em ? [em] : undefined, sha256_phone_number: ph ? [ph] : undefined })
          : undefined,
        consent: { ad_user_data: "GRANTED", ad_personalization: "GRANTED" },
        events: [{ name: isRefund ? "refund" : "purchase", params }],
      }),
    },
  };
}
