// Snap Conversions API v3: a PURCHASE to the org's Snap Pixel.
//
//   POST https://tr.snapchat.com/v3/<pixel_id>/events?access_token=<token>
//   { data: [ { event_name: "PURCHASE", event_time (unix s), event_id,
//       action_source: "website", event_source_url,
//       user_data: { em: [sha256], client_user_agent, sc_click_id },
//       custom_data: { value, currency, order_id, num_items, content_ids } } ] }
//
// event_id = the Stripe session id (dedupes with a Snap Pixel Purchase using
// the same client_dedup_id / event id). With a test event code set, the
// request goes to /v3/<pixel_id>/events/validate instead, which checks the
// payload without recording it.
// The token is a query parameter as Snap documents it; it is redacted from
// payload_planned and never logged. v2 was deprecated in 2025.
// NEEDS VERIFICATION of the /events/validate path and the PURCHASE casing
// against the live docs before EXOS_CONVERSIONS_LIVE (not readable from the
// build environment). Snap has no standard refund event.
// Docs: https://developers.snap.com/api/marketing-api/Conversions-API/UsingTheAPI
//       https://developers.snap.com/marketing-api/Conversions-API/MigrationGuide

import {
  type BuildContext, type BuildResult, type ConversionRow, type Credential,
  compact, eventSourceUrl, hashOrUndefined, skip, toMajor, tooOld, unixSeconds, upperCurrency,
} from "./common.ts";

export const SNAP_API_BASE = "https://tr.snapchat.com/v3";

export function buildSnap(row: ConversionRow, cred: Credential, ctx: BuildContext): BuildResult {
  if (row.event_name !== "Purchase") return skip("snap: no standard refund event");
  const pixel = cred.config.pixel_id;
  if (!pixel || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(pixel)) {
    return skip("snap: no pixel id");
  }
  const old = tooOld(row, ctx.now);
  if (old) return skip(old);
  const p = row.payload;
  const em = hashOrUndefined(p.em);
  const ph = hashOrUndefined(p.ph);
  const clickId = p.ad_ids?.ScCid;
  if (!em && !ph && !clickId) return skip("snap: nothing to match on (no email hash or ScCid)");

  const event = compact({
    event_name: "PURCHASE",
    event_time: unixSeconds(row.occurred_at),
    event_id: row.event_id_dedupe,
    action_source: "website",
    event_source_url: eventSourceUrl(ctx.appBase, p.event),
    user_data: compact({
      em: em ? [em] : undefined,
      ph: ph ? [ph] : undefined,
      client_user_agent: p.user_agent,
      sc_click_id: clickId,
    }),
    custom_data: compact({
      value: toMajor(row.value_cents),
      currency: upperCurrency(row.currency),
      order_id: p.transaction_id,
      num_items: p.quantity,
      content_ids: p.event?.id ? [p.event.id] : undefined,
    }),
  });

  const path = cred.test_event_code ? "events/validate" : "events";
  const q = new URLSearchParams({ access_token: cred.secret });
  return {
    ok: true,
    request: {
      method: "POST",
      url: `${SNAP_API_BASE}/${pixel.toLowerCase()}/${path}?${q.toString()}`,
      headers: { "content-type": "application/json" },
      body: { data: [event] },
    },
  };
}
