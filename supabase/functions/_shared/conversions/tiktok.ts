// TikTok Events API 2.0: a Purchase to the org's pixel.
//
//   POST https://business-api.tiktok.com/open_api/v1.3/event/track/
//   Access-Token: <token>
//   { event_source: "web", event_source_id: <pixel code>, test_event_code?,
//     data: [ { event: "Purchase", event_time (unix s), event_id,
//       user: { email: sha256, ttclid, user_agent },
//       properties: { value, currency, content_type: "product",
//         contents: [ { content_id, content_name, quantity, price } ], order_id },
//       page: { url } } ] }
//
// event_id = the Stripe session id, the same event_id the browser pixel's
// Purchase carries. "Purchase" replaced "CompletePayment" as the standard
// name in 2025. TikTok has no standard refund event.
// Docs: https://business-api.tiktok.com/portal/docs?id=1771101303285761 and
// https://ads.tiktok.com/help/article/getting-started-events-api

import {
  type BuildContext, type BuildResult, type ConversionRow, type Credential,
  compact, eventSourceUrl, hashOrUndefined, skip, toMajor, tooOld, unitPrice, unixSeconds, upperCurrency,
} from "./common.ts";

export const TIKTOK_EVENTS_URL = "https://business-api.tiktok.com/open_api/v1.3/event/track/";

export function buildTikTok(row: ConversionRow, cred: Credential, ctx: BuildContext): BuildResult {
  if (row.event_name !== "Purchase") return skip("tiktok: no standard refund event");
  const pixel = cred.config.pixel_code;
  if (!pixel || !/^[A-Z0-9]{10,40}$/.test(pixel)) return skip("tiktok: no pixel code");
  const old = tooOld(row, ctx.now);
  if (old) return skip(old);
  const p = row.payload;
  const em = hashOrUndefined(p.em);
  const ph = hashOrUndefined(p.ph);
  const ttclid = p.ad_ids?.ttclid;
  if (!em && !ph && !ttclid) return skip("tiktok: nothing to match on (no email hash or ttclid)");
  const url = eventSourceUrl(ctx.appBase, p.event);

  const event = compact({
    event: "Purchase",
    event_time: unixSeconds(row.occurred_at),
    event_id: row.event_id_dedupe,
    user: compact({ email: em, phone: ph, ttclid, user_agent: p.user_agent }),
    properties: compact({
      value: toMajor(row.value_cents),
      currency: upperCurrency(row.currency),
      content_type: "product",
      contents: p.event?.id
        ? [compact({
            content_id: p.event.id,
            content_name: p.event.name,
            quantity: p.quantity ?? 1,
            price: unitPrice(row.value_cents, p.quantity),
          })]
        : undefined,
      order_id: p.transaction_id,
    }),
    page: url ? { url } : undefined,
  });

  return {
    ok: true,
    request: {
      method: "POST",
      url: TIKTOK_EVENTS_URL,
      headers: { "content-type": "application/json", "Access-Token": cred.secret },
      body: compact({
        event_source: "web",
        event_source_id: pixel,
        test_event_code: cred.test_event_code || undefined,
        data: [event],
      }),
    },
  };
}
