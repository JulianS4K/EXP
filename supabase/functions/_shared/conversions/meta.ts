// Meta Conversions API (Facebook / Instagram): a Purchase to the org's pixel
// (dataset).
//
//   POST https://graph.facebook.com/<version>/<pixel_id>/events
//   { data: [ { event_name, event_time (unix s), event_id, action_source:
//     "website", event_source_url, user_data: { em: [sha256], client_user_agent,
//     fbp, fbc }, custom_data: { value, currency, content_ids, content_type,
//     num_items, order_id } } ], access_token, test_event_code? }
//
// event_id = the Stripe session id, the same eventID the browser Purchase
// pixel sends (src/lib/purchasePixel.ts), so Meta keeps one of the two.
// The token goes in the body (never the URL). Meta needs client_user_agent
// for website events; without it the row is skipped. No IP is sent (we only
// keep a salted hash of it), which costs some match quality.
// Meta has no standard refund event: Refund rows are never queued for it.
// Docs: https://developers.facebook.com/docs/marketing-api/conversions-api/using-the-api

import {
  type BuildContext, type BuildResult, type ConversionRow, type Credential,
  compact, eventSourceUrl, hashOrUndefined, skip, toMajor, tooOld, unixSeconds, upperCurrency,
} from "./common.ts";

/** Pinned Graph API version (v25.0 shipped 2026-02-18). Bump in one place. */
export const META_GRAPH_VERSION = "v25.0";

const FBCLID_RE = /^[A-Za-z0-9._-]{1,256}$/;

/** fbc from the _fbc cookie, else synthesized from fbclid: fb.1.<ms>.<fbclid>. */
export function metaFbc(row: ConversionRow): string | undefined {
  const ids = row.payload.ad_ids ?? {};
  if (ids.fbc) return ids.fbc;
  if (!ids.fbclid || !FBCLID_RE.test(ids.fbclid)) return undefined;
  const at = Date.parse(row.payload.click_at ?? row.occurred_at);
  return Number.isFinite(at) ? `fb.1.${at}.${ids.fbclid}` : undefined;
}

export function buildMeta(row: ConversionRow, cred: Credential, ctx: BuildContext): BuildResult {
  if (row.event_name !== "Purchase") return skip("meta: no standard refund event");
  const pixel = cred.config.pixel_id;
  if (!pixel || !/^[0-9]{5,20}$/.test(pixel)) return skip("meta: no pixel id");
  const old = tooOld(row, ctx.now);
  if (old) return skip(old);
  const p = row.payload;
  if (!p.user_agent) return skip("meta: no user agent (required for website events)");
  const em = hashOrUndefined(p.em);
  const ph = hashOrUndefined(p.ph);
  const eventId = p.event?.id;

  const event = compact({
    event_name: "Purchase",
    event_time: unixSeconds(row.occurred_at),
    event_id: row.event_id_dedupe,
    action_source: "website",
    event_source_url: eventSourceUrl(ctx.appBase, p.event),
    user_data: compact({
      em: em ? [em] : undefined,
      ph: ph ? [ph] : undefined,
      client_user_agent: p.user_agent,
      fbp: p.ad_ids?.fbp,
      fbc: metaFbc(row),
    }),
    custom_data: compact({
      value: toMajor(row.value_cents),
      currency: upperCurrency(row.currency),
      content_ids: eventId ? [eventId] : undefined,
      content_type: "product",
      content_name: p.event?.name,
      num_items: p.quantity,
      order_id: p.transaction_id,
    }),
  });

  return {
    ok: true,
    request: {
      method: "POST",
      url: `https://graph.facebook.com/${META_GRAPH_VERSION}/${pixel}/events`,
      headers: { "content-type": "application/json" },
      body: compact({ data: [event], test_event_code: cred.test_event_code || undefined, access_token: cred.secret }),
    },
  };
}
