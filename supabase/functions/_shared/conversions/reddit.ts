// Reddit Conversions API (v3): a Purchase to the org's Reddit pixel.
//
//   POST https://ads-api.reddit.com/api/v3/pixels/<pixel_id>/conversion_events
//   Authorization: Bearer <conversion access token>
//   { data: { test_id?, events: [ { event_at (ms), action_source: "WEBSITE",
//       type: { tracking_type: "PURCHASE" }, click_id: <rdt_cid>,
//       metadata: { conversion_id, currency, value, item_count },
//       user: { email: sha256 (Reddit-normalized), user_agent } } ] } }
//
// Confirmed against the v3 reference (operator brief 2026-11-21, ads phase):
//   * the path is /api/v3/pixels/{pixel_id}/conversion_events;
//   * tracking_type is the v3 enum in UPPER_SNAKE (PURCHASE, PAGE_VISIT,
//     ADD_TO_CART, ...); the browser pixel's PascalCase names
//     (src/lib/pixels.ts redditEvent) are a different API and stay as they are;
//   * the value is metadata.value (major units);
//   * at most 1,000 events per request (REDDIT_MAX_EVENTS, redditBatches);
//   * events up to 7 days old (MAX_AGE_MS.reddit);
//   * metadata.conversion_id dedupes against the browser pixel's
//     conversionId (both are the Stripe session id).
// The email is Reddit's own normalization (lower case, "+tag" and the dots
// of the local part dropped, every domain): payload.em_reddit, written by the
// outbox trigger since mig 20261121190500 (_exos_email_sha256_reddit); a row
// queued before that carries only em, which is sent instead (the same hash
// for any address without a "+" or a dot before the @).
// Send a test with test_id before EXOS_CONVERSIONS_LIVE. Reddit has no
// standard refund event.
// Docs: https://business.reddithelp.com/s/article/Conversions-API (the Ads
// API reference it links to).

import {
  type BuildContext, type BuildResult, type ConversionRow, type Credential,
  compact, eventSourceUrl, hashOrUndefined, skip, toMajor, tooOld, upperCurrency,
} from "./common.ts";

export const REDDIT_API_BASE = "https://ads-api.reddit.com/api/v3";

/** Reddit takes at most this many events in one conversion_events request. */
export const REDDIT_MAX_EVENTS = 1000;

/** The v3 tracking types (UPPER_SNAKE), by the canonical event names Exos uses. */
export const REDDIT_TRACKING_TYPE = {
  PageVisit: "PAGE_VISIT",
  ViewContent: "VIEW_CONTENT",
  Search: "SEARCH",
  AddToCart: "ADD_TO_CART",
  AddToWishlist: "ADD_TO_WISHLIST",
  Purchase: "PURCHASE",
  Lead: "LEAD",
  SignUp: "SIGN_UP",
} as const;
export type RedditTrackingType = (typeof REDDIT_TRACKING_TYPE)[keyof typeof REDDIT_TRACKING_TYPE];

/** Events split into requests of at most REDDIT_MAX_EVENTS, order kept. */
export function redditBatches<T>(events: readonly T[], max = REDDIT_MAX_EVENTS): T[][] {
  const size = Math.max(1, Math.min(Math.floor(max), REDDIT_MAX_EVENTS));
  const out: T[][] = [];
  for (let i = 0; i < events.length; i += size) out.push(events.slice(i, i + size));
  return out;
}

export function buildReddit(row: ConversionRow, cred: Credential, ctx: BuildContext): BuildResult {
  if (row.event_name !== "Purchase") return skip("reddit: no standard refund event");
  const pixel = cred.config.pixel_id;
  if (!pixel || !/^(a2|t2)_[A-Za-z0-9]{1,40}$/.test(pixel)) return skip("reddit: no pixel id");
  const old = tooOld(row, ctx.now);
  if (old) return skip(old);
  const p = row.payload;
  const em = hashOrUndefined(p.em_reddit) ?? hashOrUndefined(p.em);
  const clickId = p.ad_ids?.rdt_cid;
  if (!em && !clickId) return skip("reddit: nothing to match on (no email hash or rdt_cid)");

  const event = compact({
    event_at: Date.parse(row.occurred_at),
    action_source: "WEBSITE",
    type: { tracking_type: REDDIT_TRACKING_TYPE.Purchase },
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
