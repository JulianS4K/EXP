// Reddit Conversions API (v3): a Purchase to the org's Reddit pixel.
//
//   POST https://ads-api.reddit.com/api/v3/pixels/<pixel_id>/conversion_events
//   Authorization: Bearer <conversion access token>
//   { data: { test_id?, events: [ { event_at (ms), action_source: "WEBSITE",
//       type: { tracking_type: "Purchase" }, click_id: <rdt_cid>,
//       metadata: { conversion_id, currency, value, item_count },
//       user: { email: sha256, user_agent } } ] } }
//
// conversion_id = the Stripe session id, so a Reddit pixel Purchase with the
// same conversion id (when the browser pixel is added) is deduplicated.
//
// NEEDS VERIFICATION before EXOS_CONVERSIONS_LIVE: Reddit's developer docs
// could not be read from the build environment, and third-party summaries
// disagree on the v3 path (/pixels/<pixel_id>/conversion_events vs
// /conversions/events) and on field names (value vs value_decimal). Send a
// test with test_id first. Reddit has no standard refund event.
// Docs: https://business.reddithelp.com/s/article/Conversions-API (the Ads
// API reference it links to is the source to check the v3 request against).

import {
  type BuildContext, type BuildResult, type ConversionRow, type Credential,
  compact, eventSourceUrl, hashOrUndefined, skip, toMajor, tooOld, upperCurrency,
} from "./common.ts";

export const REDDIT_API_BASE = "https://ads-api.reddit.com/api/v3";

export function buildReddit(row: ConversionRow, cred: Credential, ctx: BuildContext): BuildResult {
  if (row.event_name !== "Purchase") return skip("reddit: no standard refund event");
  const pixel = cred.config.pixel_id;
  if (!pixel || !/^(a2|t2)_[A-Za-z0-9]{1,40}$/.test(pixel)) return skip("reddit: no pixel id");
  const old = tooOld(row, ctx.now);
  if (old) return skip(old);
  const p = row.payload;
  const em = hashOrUndefined(p.em);
  const clickId = p.ad_ids?.rdt_cid;
  if (!em && !clickId) return skip("reddit: nothing to match on (no email hash or rdt_cid)");

  const event = compact({
    event_at: Date.parse(row.occurred_at),
    action_source: "WEBSITE",
    type: { tracking_type: "Purchase" },
    click_id: clickId,
    event_source_url: eventSourceUrl(ctx.appBase, p.event),
    metadata: compact({
      conversion_id: row.event_id_dedupe,
      currency: upperCurrency(row.currency),
      value: toMajor(row.value_cents),
      item_count: p.quantity,
    }),
    user: compact({ email: em, user_agent: p.user_agent }),
  });

  return {
    ok: true,
    request: {
      method: "POST",
      url: `${REDDIT_API_BASE}/pixels/${encodeURIComponent(pixel)}/conversion_events`,
      headers: { "content-type": "application/json", Authorization: `Bearer ${cred.secret}` },
      body: { data: compact({ test_id: cred.test_event_code || undefined, events: [event] }) },
    },
  };
}
