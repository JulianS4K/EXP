// Google Customer Match on the channel core (ads phase, mig 20261121190500),
// through Google's Data Manager API, NOT the Google Ads API: new Google Ads
// API adopters are refused since 2026-04-01 (operator brief 2026-11-21), and
// the Data Manager API is what the conversions already use (googleAds.ts).
// DRY RUN ONLY: the one write is on the allowlist below and goes through
// ctx.http (GatedHttp); exos-ads pins the org's switch off and
// EXOS_GOOGLE_CUSTOMER_MATCH_WRITES is off.
//
// Credential: provider ads_google_ads (the same "Connect Google Ads" refresh
// token, exos-oauth-google, scope https://www.googleapis.com/auth/datamanager)
// plus its config's customer_id / login_customer_id. A live send would swap
// the refresh token for an access token (googleOAuth.ts
// createAccessTokenCache) and put it in the Authorization header; a dry run
// never calls Google, so the header holds a placeholder. The Customer Match
// list itself is made in Google Ads (Tools -> Audience manager -> Your data
// segments -> Customer list); its id comes with the request (user_list_id).
//
//   POST https://datamanager.googleapis.com/v1/audienceMembers:ingest
//   { destinations: [ { operatingAccount: { accountType: GOOGLE_ADS, accountId }, loginAccount?,
//       productDestinationId: <user list id> } ],
//     audienceMembers: [ { userData: { userIdentifiers: [ { emailAddress }, { phoneNumber } ] } } ],
//     consent: { adUserData: CONSENT_GRANTED, adPersonalization: CONSENT_GRANTED },
//     encoding: HEX, termsOfService: { customerMatchTermsOfServiceStatus: ACCEPTED }, validateOnly? }
//
// UNVERIFIED (developers.google.com was not readable from the build session):
// the field names above, 10,000 members per request, termsOfService (the
// organizer accepts Google's Customer Match terms in Google Ads first), and
// the size Google needs before a list serves. Check with validateOnly: true.

import { caps, type ChannelAdapter, type ChannelCtx, type OrgCredential } from "../adapter.ts";
import type { WriteRule } from "../gatedHttp.ts";
import { chunk, googleMembers, hashedRowsSummary } from "../../ads/audience.ts";
import type { HashedIdentifiers } from "../../hashedIds.ts";
import { cfgOr, newResult, plannedId, standInBy, write, type AdsResult } from "./adsCommon.ts";

export const DATA_MANAGER_BASE = "https://datamanager.googleapis.com";
export const GOOGLE_AUDIENCE_BATCH = 10_000;

/** Exactly the write the adapter makes. */
export const GOOGLE_CUSTOMER_MATCH_WRITES: WriteRule[] = [
  { method: "POST", path: /^\/v1\/audienceMembers:ingest$/ },
];

export const googleCustomerMatchStandIn = standInBy([[/audienceMembers:ingest$/, "request"]], (id) => ({ requestId: id }));

/**
 * GatedHttp options for this channel. `accessToken`: only for a live send
 * (minted from the refresh token); without one the header is a placeholder.
 */
export function googleCustomerMatchHttp(creds: OrgCredential | null, accessToken?: string | null) {
  return {
    channel: "google_customer_match",
    base: DATA_MANAGER_BASE,
    writes: GOOGLE_CUSTOMER_MATCH_WRITES,
    headers: { Authorization: `Bearer ${accessToken ?? "<oauth access token>"}` },
    secrets: [creds?.secret, accessToken],
    standIn: googleCustomerMatchStandIn,
  };
}

async function syncAudience(ctx: ChannelCtx, audience: { id: string; name?: string; members: HashedIdentifiers[]; externalId?: string | null }): Promise<AdsResult> {
  const res = newResult("google_customer_match", ctx);
  const customer = cfgOr(ctx.creds.config, "customer_id", /^[0-9]{10}$/, "customer");
  if (!res.connected || !customer.set) res.warnings.push("Google Ads isn't connected (Connect Google Ads, then the customer id): the account below is a placeholder.");
  const listId = audience.externalId && /^[0-9]{1,20}$/.test(audience.externalId) ? audience.externalId : plannedId("user_list");
  if (listId.startsWith("planned_")) {
    res.warnings.push("Make a Customer Match list in Google Ads (Audience manager -> Your data segments -> Customer list) and give Exos its id.");
  }
  res.warnings.push("Google needs the organizer to accept its Customer Match terms in Google Ads first, and a list of about 1,000 members before it serves on most networks (unverified).");
  const members = googleMembers(audience.members);
  if (!members.length) { res.stopped = "Nobody on the list: no one has granted advertising consent yet."; return res; }
  res.ids.user_list = listId;
  const login = typeof ctx.creds.config.login_customer_id === "string" && /^[0-9]{10}$/.test(ctx.creds.config.login_customer_id)
    ? ctx.creds.config.login_customer_id : null;
  const destination = {
    operatingAccount: { accountType: "GOOGLE_ADS", accountId: customer.value },
    ...(login ? { loginAccount: { accountType: "GOOGLE_ADS", accountId: login } } : {}),
    productDestinationId: listId,
  };
  const batches = chunk(members, GOOGLE_AUDIENCE_BATCH);
  for (let i = 0; i < batches.length; i++) {
    const body = {
      destinations: [destination],
      audienceMembers: batches[i],
      consent: { adUserData: "CONSENT_GRANTED", adPersonalization: "CONSENT_GRANTED" },
      encoding: "HEX",
      termsOfService: { customerMatchTermsOfServiceStatus: "ACCEPTED" },
    };
    const r = await write(ctx, res, "POST", "/v1/audienceMembers:ingest", body, {
      op: "audience.add_members",
      auditBody: { ...body, audienceMembers: hashedRowsSummary(batches[i].length, ["emailAddress", "phoneNumber"]) },
    });
    if (!r.ok) { res.stopped = r.error ?? "upload refused"; res.deferred = members.length - i * GOOGLE_AUDIENCE_BATCH; break; }
  }
  return res;
}

export const googleCustomerMatchAdapter: ChannelAdapter = {
  id: "google_customer_match",
  label: "Google Customer Match",
  status: "core",
  caps: caps({ role: "secondary", syncAudience: true }),
  writes: GOOGLE_CUSTOMER_MATCH_WRITES,
  syncAudience,
};
