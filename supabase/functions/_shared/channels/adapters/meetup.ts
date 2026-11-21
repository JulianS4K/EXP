// Meetup (GraphQL) on the channel core (social phase, mig 20261121203000;
// docs/social.md "Posting and listing APIs"): an event in the organizer's own
// group on their Meetup Pro network (createEvent), and its attendee
// allocation (list). DRY RUN ONLY: the one write path is on the allowlist
// below and goes through ctx.http (GatedHttp); exos-social pins the org's
// switch off and EXOS_MEETUP_WRITES is off.
//
// GraphQL takes every operation on ONE path, so the allowlist pins the body
// too (WriteRule.body): POST /gql only with one of the two documents below,
// a createEvent only as a DRAFT, and an editEvent only with the keys listed.
//   createEvent(input: {groupUrlname, title, description, startDateTime, duration,
//                       publishStatus: DRAFT, rsvpSettings: {rsvpLimit}})   -> event.id
//   editEvent(input: {eventId, publishStatus: PUBLISHED})                   the draft goes live
//
// TWO PASSES, NEVER ONE (Applier review of #139): upsertEvent either creates
// the DRAFT, or (given publishDraftId, a draft the organizer has reviewed on
// Meetup) publishes that draft. A create and its publish are never in the
// same pass, so nothing reaches Meetup's public listing without a second,
// confirmed step (exos-social /publish, _shared/social/run.ts).
//   editEvent(input: {eventId, rsvpSettings: {rsvpLimit}})                  the allocation (list)
//
// LIMITS (limits.ts "meetup"): 500 GraphQL points per 60 seconds per account
// (each mutation counted as MEETUP_MUTATION_POINTS, an estimate: what Meetup
// charges per mutation is unverified), and the Starter plan's 10 attendees
// per event: with the plan unknown or Starter, the RSVP limit is capped at
// 10 (the lower bound, as in the allocation).
//
// Credential: provider meetup in the store (managed; "Connect Meetup", not
// built, runs Meetup's OAuth 2 with an approved client): the access token,
// Bearer in the header. config: group_urlname (the group the event goes in),
// pro_network (the Pro network's urlname; createEvent through the API needs
// Meetup Pro), plan (starter / standard / pro, shown to the limits).
//
// UNVERIFIED (Meetup's API docs were not readable from the build session):
// the endpoint (https://api.meetup.com/gql; Meetup has also announced
// /gql-ext), every input field name, the local startDateTime format, the
// duration as ISO 8601, the answer shape (event.id, errors), the point cost,
// and featured photos (they need an upload first; none is planned).

import { caps, type ChannelAdapter, type ChannelCtx, type ExosEvent, type OrgCredential } from "../adapter.ts";
import type { WriteRule } from "../gatedHttp.ts";
import { evaluateLimits } from "../limits.ts";
import type { PlatformPost } from "../../social/postKit.ts";
import { cfgOr, createdId, newResult, plannedId, write, type AdsResult } from "./adsCommon.ts";

export const MEETUP_BASE = "https://api.meetup.com";
export const MEETUP_PATH = "/gql";
export const MEETUP_MUTATION_POINTS = 10;

export const MEETUP_CREATE_EVENT =
  "mutation ExosCreateEvent($input: CreateEventInput!) { createEvent(input: $input) { event { id eventUrl } errors { message code field } } }";
export const MEETUP_EDIT_EVENT =
  "mutation ExosEditEvent($input: EditEventInput!) { editEvent(input: $input) { event { id eventUrl status } errors { message code field } } }";

const CREATE_KEYS = new Set(["groupUrlname", "title", "description", "startDateTime", "duration", "publishStatus", "rsvpSettings", "eventType"]);
const EDIT_KEYS = new Set(["eventId", "publishStatus", "rsvpSettings"]);

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

/** The body check: one of the two pinned documents, a DRAFT create, an edit with only its keys. */
export function meetupBodyAllowed(body: unknown): boolean {
  if (!isObj(body) || !isObj(body.variables) || !isObj(body.variables.input)) return false;
  if (Object.keys(body).some((k) => k !== "query" && k !== "variables")) return false;
  const input = body.variables.input;
  if (Object.keys(body.variables).length !== 1) return false;
  if (body.query === MEETUP_CREATE_EVENT) {
    return input.publishStatus === "DRAFT" && Object.keys(input).every((k) => CREATE_KEYS.has(k));
  }
  if (body.query === MEETUP_EDIT_EVENT) {
    if (typeof input.eventId !== "string" || !Object.keys(input).every((k) => EDIT_KEYS.has(k))) return false;
    return input.publishStatus === undefined || input.publishStatus === "PUBLISHED";
  }
  return false;
}

/** Exactly the writes the Meetup adapter makes (one path, two documents). */
export const MEETUP_WRITES: WriteRule[] = [{ method: "POST", path: /^\/gql$/, body: meetupBodyAllowed }];

export const meetupStandIn = (_m: unknown, _path: string, body: unknown): unknown => {
  const doc = isObj(body) ? body.query : null;
  const field = doc === MEETUP_CREATE_EVENT ? "createEvent" : "editEvent";
  return { data: { [field]: { event: { id: plannedId("meetup_event"), eventUrl: null }, errors: [] } }, dry_run: true };
};

export function meetupHttp(creds: OrgCredential | null) {
  const group = typeof creds?.config.group_urlname === "string" ? creds.config.group_urlname : "";
  return {
    channel: "meetup",
    base: MEETUP_BASE,
    writes: MEETUP_WRITES,
    headers: creds?.secret ? { Authorization: `Bearer ${creds.secret}` } : {},
    secrets: [creds?.secret],
    standIn: meetupStandIn,
    limits: { platform: "meetup", scopeKey: group.slice(0, 64) },
  };
}

/** "2026-12-04T21:00" in the event's zone (Meetup takes a local date-time; unverified). */
export function meetupLocal(iso: string | null, tz: string): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  try {
    const p: Record<string, string> = {};
    for (const x of new Intl.DateTimeFormat("en-US", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(d)) p[x.type] = x.value;
    return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
  } catch {
    return iso.slice(0, 16);
  }
}

/** ISO 8601 duration from start to end; 2 hours when the end is unknown. */
export function meetupDuration(start: string | null, end: string | null): string {
  const ms = start && end ? Date.parse(end) - Date.parse(start) : NaN;
  const minutes = Number.isFinite(ms) && ms > 0 ? Math.min(Math.round(ms / 60_000), 14 * 24 * 60) : 120;
  const h = Math.floor(minutes / 60), m = minutes % 60;
  return `PT${h ? `${h}H` : ""}${m ? `${m}M` : ""}` || "PT2H";
}

const plan = (ctx: ChannelCtx): string | null => {
  const v = ctx.creds.config.plan;
  return typeof v === "string" && /^(starter|standard|pro)$/i.test(v) ? v.toLowerCase() : null;
};

/** The RSVP limit Meetup would get: the allocation, capped by the Starter plan's 10 (unknown plan = Starter). */
export function meetupRsvpLimit(ctx: ChannelCtx, attendees: number | null): { limit: number | null; note: string | null } {
  const v = evaluateLimits("meetup", { plan: plan(ctx), attendees }, {}, { metric: "attendees", n: attendees ?? 0 });
  const cap = v.caps.find((h) => h.ruleId === "meetup_starter_attendees");
  if (!cap) return { limit: attendees, note: null };
  const max = v.maxUnits ?? 10;
  return { limit: attendees === null ? max : Math.min(attendees, max), note: cap.reason };
}

async function gql(ctx: ChannelCtx, res: AdsResult, op: string, query: string, input: Record<string, unknown>, attendees: number | null) {
  return await write(ctx, res, "POST", MEETUP_PATH, { query, variables: { input } }, {
    op, usage: { metric: "points", n: MEETUP_MUTATION_POINTS }, facts: { plan: plan(ctx), attendees },
  });
}

const eventIdOf = (b: any, field: string) => b?.data?.[field]?.event?.id;

/** Meetup's own event ids (the publish pass takes one). */
export const MEETUP_EVENT_ID = /^[A-Za-z0-9_-]{1,64}$/;

/**
 * One pass: createEvent as a DRAFT, or, given publishDraftId, editEvent that
 * draft to PUBLISHED. Never both. link: {post, attendees, publishDraftId?}.
 */
async function upsertEvent(ctx: ChannelCtx, _ev: ExosEvent, link: unknown): Promise<AdsResult> {
  const l = (link ?? {}) as { post?: PlatformPost; attendees?: number | null; publishDraftId?: string | null };
  const res = newResult("meetup", ctx);
  if (l.publishDraftId !== undefined && l.publishDraftId !== null) {
    if (typeof l.publishDraftId !== "string" || !MEETUP_EVENT_ID.test(l.publishDraftId) || l.publishDraftId.startsWith("planned_")) {
      res.stopped = "That isn't a Meetup draft id.";
      return res;
    }
    const pub = await gql(ctx, res, "event.publish", MEETUP_EDIT_EVENT, { eventId: l.publishDraftId, publishStatus: "PUBLISHED" }, null);
    res.ids.event = l.publishDraftId;
    if (!pub.ok) res.stopped = pub.error ?? "not published";
    return res;
  }
  const post = l.post;
  if (!post) { res.stopped = "nothing to list"; return res; }
  const group = cfgOr(ctx.creds.config, "group_urlname", /^[A-Za-z0-9-]{1,80}$/, "group");
  if (!res.connected || !group.set) res.warnings.push("Meetup isn't connected: the group below is a placeholder.");
  if (typeof ctx.creds.config.pro_network !== "string") {
    res.warnings.push("Meetup's API only creates events for a group on a Meetup Pro network: connect the Pro network's group.");
  }
  const attendees = typeof l.attendees === "number" && l.attendees >= 0 ? Math.floor(l.attendees) : null;
  const rsvp = meetupRsvpLimit(ctx, attendees);
  if (rsvp.note) res.warnings.push(rsvp.note);
  const start = meetupLocal(post.startsAt, post.timezone);
  if (!start) { res.stopped = "The event has no start time."; return res; }
  res.warnings.push("Meetup gets no image from Exos (a featured photo needs an upload first): add one on Meetup.");

  const input: Record<string, unknown> = {
    groupUrlname: group.value,
    title: post.title,
    description: post.text,
    startDateTime: start,
    duration: meetupDuration(post.startsAt, post.endsAt),
    publishStatus: "DRAFT",
    ...(post.online ? { eventType: "ONLINE" } : { eventType: "PHYSICAL" }),
    ...(rsvp.limit !== null ? { rsvpSettings: { rsvpLimit: rsvp.limit } } : {}),
  };
  const c = await gql(ctx, res, "event.create_draft", MEETUP_CREATE_EVENT, input, attendees);
  const id = createdId(c, (b) => eventIdOf(b, "createEvent"));
  if (!id) { res.stopped = c.error ?? "the draft wasn't created"; return res; }
  res.ids.event = id;
  res.warnings.push("Meetup keeps it as a draft: check it on Meetup, then publish it from Exos as a separate step.");
  return res;
}

/** The allocation on an event already on Meetup: its RSVP limit (capped on Starter). alloc: {eventId, attendees}. */
async function planListings(ctx: ChannelCtx, alloc: unknown, _prev: unknown): Promise<AdsResult> {
  const a = (alloc ?? {}) as { eventId?: string; attendees?: number };
  const res = newResult("meetup", ctx);
  const eventId = typeof a.eventId === "string" && MEETUP_EVENT_ID.test(a.eventId) ? a.eventId : plannedId("meetup_event");
  const attendees = typeof a.attendees === "number" && a.attendees >= 0 ? Math.floor(a.attendees) : null;
  const rsvp = meetupRsvpLimit(ctx, attendees);
  if (rsvp.note) res.warnings.push(rsvp.note);
  if (rsvp.limit === null) { res.stopped = "No allocation given."; return res; }
  const r = await gql(ctx, res, "event.allocation", MEETUP_EDIT_EVENT, { eventId, rsvpSettings: { rsvpLimit: rsvp.limit } }, attendees);
  if (!r.ok) res.stopped = r.error ?? "not changed";
  res.ids.event = eventId;
  return res;
}

export const meetupAdapter: ChannelAdapter = {
  id: "meetup",
  label: "Meetup",
  status: "core",
  caps: caps({ role: "secondary", createEvent: true, list: true }),
  writes: MEETUP_WRITES,
  upsertEvent,
  planListings,
};
