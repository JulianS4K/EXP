// LinkedIn Event Management on the channel core (social phase, mig
// 20261121203000; docs/social.md "Posting and listing APIs"): an event on
// the organizer's LinkedIn ORGANIZATION page (createEvent). DRY RUN ONLY: the
// one write is on the allowlist below and goes through ctx.http (GatedHttp);
// exos-social pins the org's switch off and EXOS_LINKEDIN_WRITES is off.
//
//   POST https://api.linkedin.com/rest/events
//     headers LinkedIn-Version: <YYYYMM>, X-Restli-Protocol-Version: 2.0.0
//     {organizer: urn:li:organization:<id>, name: {localized: {en_US}}, description: {localized: {en_US}},
//      eventFormat: IN_PERSON | ONLINE, startsAt / endsAt (epoch ms), externalUrl (the Exos ticket link),
//      address (in person, open locations only)}
//
// Organization pages only: an organizer that isn't urn:li:organization:<digits>
// (a member's own profile) is refused before anything is planned. LinkedIn
// has no draft event in this API (unverified): the plan says the event would
// be public at once. Invites are NOT sent: the 1,000 invites a week across
// all events (limits.ts "linkedin") is shown, nothing is counted against it.
//
// Credential: provider linkedin in the store (managed; "Connect LinkedIn",
// not built, runs LinkedIn's OAuth 2 for the one Exos app with the events and
// organization-admin scopes): the access token, Bearer in the header.
// config: organization_id (digits; the page the organizer administers).
//
// UNVERIFIED (LinkedIn's Event Management docs were not readable from the
// build session; the API is limited to approved partners): every body field
// above, the version header value, the scope names (rw_events,
// r_organization_admin), and that no draft state exists.

import { caps, type ChannelAdapter, type ChannelCtx, type ExosEvent, type OrgCredential } from "../adapter.ts";
import type { WriteRule } from "../gatedHttp.ts";
import { rulesFor } from "../limits.ts";
import type { PlatformPost } from "../../social/postKit.ts";
import { cfgOr, createdId, newResult, standInBy, write, type AdsResult } from "./adsCommon.ts";

export const LINKEDIN_BASE = "https://api.linkedin.com";
/** The Marketing API version LinkedIn wants in a header (YYYYMM; unverified which months are live). */
export const LINKEDIN_VERSION = "202511";

/** Exactly the write the LinkedIn adapter makes. */
export const LINKEDIN_WRITES: WriteRule[] = [{ method: "POST", path: /^\/rest\/events$/ }];

export const linkedinStandIn = standInBy([[/\/rest\/events$/, "linkedin_event"]]);

export function linkedinHttp(creds: OrgCredential | null) {
  const org = typeof creds?.config.organization_id === "string" ? creds.config.organization_id : "";
  return {
    channel: "linkedin",
    base: LINKEDIN_BASE,
    writes: LINKEDIN_WRITES,
    headers: {
      ...(creds?.secret ? { Authorization: `Bearer ${creds.secret}` } : {}),
      "LinkedIn-Version": LINKEDIN_VERSION,
      "X-Restli-Protocol-Version": "2.0.0",
    },
    secrets: [creds?.secret],
    standIn: linkedinStandIn,
    limits: { platform: "linkedin", scopeKey: org.slice(0, 64) },
  };
}

const ms = (iso: string | null): number | null => {
  const t = iso ? Date.parse(iso) : NaN;
  return Number.isFinite(t) ? t : null;
};

/** link: {post}. */
async function upsertEvent(ctx: ChannelCtx, _ev: ExosEvent, link: unknown): Promise<AdsResult> {
  const post = ((link ?? {}) as { post?: PlatformPost }).post;
  const res = newResult("linkedin", ctx);
  if (!post) { res.stopped = "nothing to list"; return res; }
  const raw = ctx.creds.config.organizer_urn;
  if (typeof raw === "string" && raw && !/^urn:li:organization:[0-9]{1,20}$/.test(raw)) {
    res.stopped = "LinkedIn events go on an organization page: a member's own profile isn't supported.";
    return res;
  }
  const org = cfgOr(ctx.creds.config, "organization_id", /^[0-9]{1,20}$/, "organization");
  if (!res.connected || !org.set) res.warnings.push("LinkedIn isn't connected: the organization page below is a placeholder.");
  res.warnings.push("LinkedIn's events API has no draft (unverified): the event would be public on the page at once.");
  for (const r of rulesFor("linkedin")) res.warnings.push(`${r.reason} Exos sends no invites.`);
  const startsAt = ms(post.startsAt);
  if (startsAt === null) { res.stopped = "The event has no start time."; return res; }
  const loc = (s: string) => ({ localized: { en_US: s } });
  const r = await write(ctx, res, "POST", "/rest/events", {
    organizer: `urn:li:organization:${org.value}`,
    name: loc(post.title),
    description: loc(post.text),
    eventFormat: post.online ? "ONLINE" : "IN_PERSON",
    startsAt,
    ...(ms(post.endsAt) !== null ? { endsAt: ms(post.endsAt) } : {}),
    ...(post.url ? { externalUrl: post.url } : {}),
    ...(!post.online && post.address ? { address: { line1: post.address } } : {}),
  }, { op: "event.create_on_page" });
  const id = createdId(r, (b) => b?.id);
  if (id) res.ids.event = id;
  else res.stopped = r.error ?? "not created";
  return res;
}

export const linkedinAdapter: ChannelAdapter = {
  id: "linkedin",
  label: "LinkedIn",
  status: "core",
  caps: caps({ role: "secondary", createEvent: true }),
  writes: LINKEDIN_WRITES,
  upsertEvent,
};
