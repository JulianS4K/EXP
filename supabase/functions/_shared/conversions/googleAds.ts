// Google Ads offline click conversions through the Data Manager API.
//
// PLANNED ONLY: exos-conversions-drain builds this request and stores it in
// payload_planned but never sends it, even with EXOS_CONVERSIONS_LIVE=true.
// Two things are missing:
//   1. OAuth. The Data Manager API takes an OAuth 2.0 access token (scope
//      https://www.googleapis.com/auth/datamanager) for a Google account with
//      access to the Ads account. The org's stored secret is meant to be a
//      refresh token; exchanging it needs an Exos OAuth client (id + secret)
//      and a consent flow (an exos-oauth-google function), not built yet.
//   2. Verification. Google moved offline conversion imports from the Google
//      Ads API ConversionUploadService to the Data Manager API (cut-over
//      2026-06-15, per the marketing audit). The shape below follows the
//      public reference as far as it could be read from search results
//      (developers.google.com was not reachable from the build environment);
//      check every field against the live reference with validateOnly: true.
//
//   POST https://datamanager.googleapis.com/v1/events:ingest
//   Authorization: Bearer <OAuth access token>
//   { destinations: [ { operatingAccount: { accountType: "GOOGLE_ADS",
//       accountId: <customer id> }, loginAccount?: {…},
//       productDestinationId: <conversion action id> } ],
//     encoding: "HEX",
//     events: [ { adIdentifiers: { gclid | gbraid | wbraid }, conversionValue,
//       currency, eventTimestamp (RFC 3339), transactionId, eventSource: "WEB",
//       userData: { userIdentifiers: [ { emailAddress: sha256 hex } ] },
//       consent: { adUserData: "CONSENT_GRANTED", adPersonalization: "CONSENT_GRANTED" } } ],
//     validateOnly? }
//
// Refunds (retractions) are a different call and are not queued for Google Ads.
// Docs: https://developers.google.com/data-manager/api/reference/rest/v1/events/ingest
//       https://developers.google.com/data-manager/api/devguides/events/google-ads/offline/send-events
//       https://developers.google.com/data-manager/api/devguides/concepts/destinations

import {
  type BuildContext, type BuildResult, type ConversionRow, type Credential,
  compact, hashOrUndefined, skip, toMajor, tooOld, upperCurrency,
} from "./common.ts";

export const DATA_MANAGER_INGEST_URL = "https://datamanager.googleapis.com/v1/events:ingest";

/** Always true: the Google Ads sender is planned only (see the header). */
export const GOOGLE_ADS_PLANNED_ONLY = true;

export function buildGoogleAds(row: ConversionRow, cred: Credential, ctx: BuildContext): BuildResult {
  if (row.event_name !== "Purchase") return skip("google_ads: refunds are retractions, not sent");
  const customer = cred.config.customer_id;
  const action = cred.config.conversion_action_id;
  if (!customer || !/^[0-9]{10}$/.test(customer) || !action || !/^[0-9]{1,20}$/.test(action)) {
    return skip("google_ads: no customer id / conversion action");
  }
  const old = tooOld(row, ctx.now);
  if (old) return skip(old);
  const p = row.payload;
  const ids = p.ad_ids ?? {};
  // One click id: gclid wins; gbraid / wbraid are the iOS alternatives.
  const adIdentifiers = ids.gclid ? { gclid: ids.gclid }
    : ids.gbraid ? { gbraid: ids.gbraid }
    : ids.wbraid ? { wbraid: ids.wbraid }
    : undefined;
  const em = hashOrUndefined(p.em_google);
  if (!adIdentifiers && !em) return skip("google_ads: nothing to match on (no gclid / gbraid / wbraid or email hash)");
  const login = cred.config.login_customer_id;

  const event = compact({
    adIdentifiers,
    conversionValue: toMajor(row.value_cents),
    currency: upperCurrency(row.currency),
    eventTimestamp: new Date(Date.parse(row.occurred_at)).toISOString(),
    transactionId: p.transaction_id,
    eventSource: "WEB",
    userData: em ? { userIdentifiers: [{ emailAddress: em }] } : undefined,
    consent: { adUserData: "CONSENT_GRANTED", adPersonalization: "CONSENT_GRANTED" },
  });

  return {
    ok: true,
    request: {
      method: "POST",
      url: DATA_MANAGER_INGEST_URL,
      // The real token comes from an OAuth exchange that isn't built; the
      // stored refresh token is never put in the request.
      headers: { "content-type": "application/json", Authorization: "Bearer <oauth access token>" },
      body: compact({
        destinations: [compact({
          operatingAccount: { accountType: "GOOGLE_ADS", accountId: customer },
          loginAccount: login && /^[0-9]{10}$/.test(login) ? { accountType: "GOOGLE_ADS", accountId: login } : undefined,
          productDestinationId: action,
        })],
        encoding: "HEX",
        events: [event],
        validateOnly: cred.test_event_code ? true : undefined,
      }),
    },
  };
}
