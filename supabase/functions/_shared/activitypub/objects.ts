// ActivityPub documents for Exos communities (docs/federation.md).
//
// A public community with federation on is a Group actor (what Lemmy uses for
// communities). Its org is a Person actor that posts are attributed to. Posts
// with a title are Page objects (a Lemmy post), posts without one are Note
// objects (a Mastodon status), events are Event objects. The Group Announces
// them to its followers: Lemmy-family servers get Announce{Create{Page}}
// (their documented community shape), everyone else Announce{object}.
//
// Pure (no Deno / Supabase imports) so vitest checks the JSON shapes.

export const AS_PUBLIC = "https://www.w3.org/ns/activitystreams#Public";
export const AS_CONTEXT = "https://www.w3.org/ns/activitystreams";

export const CONTEXT: unknown[] = [
  AS_CONTEXT,
  "https://w3id.org/security/v1",
  {
    lemmy: "https://join-lemmy.org/ns#",
    sensitive: "as:sensitive",
    postingRestrictedToMods: "lemmy:postingRestrictedToMods",
    manuallyApprovesFollowers: "as:manuallyApprovesFollowers",
  },
];

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const AP_NAME = /^[a-z0-9_]{3,60}$/;
const SLUG = /^[a-z0-9][a-z0-9_-]{0,80}$/;

export interface Urls {
  /** Public origin the federation is served on, e.g. https://exos.app (no path). */
  origin: string;
  /** The app's public base for HTML links, e.g. https://exos.app/bridge. */
  appBase: string;
}

export const host = (u: Urls) => new URL(u.origin).host;
export const groupId = (u: Urls, apName: string) => `${u.origin}/ap/c/${apName}`;
export const personId = (u: Urls, apName: string) => `${u.origin}/ap/o/${apName}`;
export const sharedInbox = (u: Urls) => `${u.origin}/ap/inbox`;
export const postId = (u: Urls, id: string) => `${u.origin}/ap/p/${id}`;
export const eventId = (u: Urls, id: string) => `${u.origin}/ap/e/${id}`;
export const eventPageId = (u: Urls, id: string) => `${u.origin}/ap/e/${id}/page`;
export const activityId = (u: Urls, kind: string, ref: string) => `${u.origin}/ap/activities/${kind}/${ref}`;

/** The org actor's name: "org_" + the org slug with "-" as "_". */
export function orgApName(slug: string): string {
  return "org_" + slug.toLowerCase().replace(/-/g, "_");
}

// ── text ────────────────────────────────────────────────────────────────────

export function escapeHtml(s: unknown): string {
  return String(s ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

/** Plain organizer text → safe HTML paragraphs (no markup passes through). */
export function textToHtml(s: string | null | undefined): string {
  const t = (s ?? "").trim();
  if (!t) return "";
  return t.split(/\n{2,}/).map((p) => `<p>${escapeHtml(p).replace(/\n/g, "<br>")}</p>`).join("");
}

/**
 * Remote HTML → plain text for the moderation queue. Tags are dropped, a few
 * block tags become line breaks, entities are decoded, then the result is
 * stored as text and rendered as text (never as HTML).
 */
export function htmlToText(html: unknown, max = 5000): string {
  const s = String(html ?? "")
    .replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|blockquote|h[1-6])>/gi, "\n")
    .replace(/<[^>]*>/g, "")
    .replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'").replace(/&#(\d+);/g, (_, n) => {
      const c = Number(n);
      return c > 31 && c < 0x10ffff ? String.fromCodePoint(c) : "";
    })
    .replace(/&amp;/g, "&");
  // deno-lint-ignore no-control-regex
  const flat = s.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "").replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
  return flat.length > max ? flat.slice(0, max - 1) + "…" : flat;
}

// ── WebFinger / NodeInfo ────────────────────────────────────────────────────

/** "acct:name@host" (or "name@host", "@name@host", "!name@host") → name, if host matches. */
export function parseAcct(resource: string | null, ourHost: string): string | null {
  if (!resource) return null;
  let r = resource.trim();
  if (/^https:\/\//i.test(r)) {
    // An actor URL is a valid resource too.
    try {
      const u = new URL(r);
      if (u.host.toLowerCase() !== ourHost.toLowerCase()) return null;
      const m = u.pathname.match(/^\/ap\/[co]\/([a-z0-9_]{3,60})$/);
      return m ? m[1] : null;
    } catch {
      return null;
    }
  }
  r = r.replace(/^acct:/i, "").replace(/^[@!]/, "");
  const at = r.lastIndexOf("@");
  if (at <= 0) return null;
  const name = r.slice(0, at).toLowerCase();
  const h = r.slice(at + 1).toLowerCase();
  if (h !== ourHost.toLowerCase() || !AP_NAME.test(name)) return null;
  return name;
}

export function webfinger(u: Urls, apName: string, kind: "community" | "org", htmlUrl: string) {
  const id = kind === "community" ? groupId(u, apName) : personId(u, apName);
  return {
    subject: `acct:${apName}@${host(u)}`,
    aliases: [id, htmlUrl],
    links: [
      { rel: "http://webfinger.net/rel/profile-page", type: "text/html", href: htmlUrl },
      {
        rel: "self",
        type: "application/activity+json",
        href: id,
        properties: { "https://www.w3.org/ns/activitystreams#type": kind === "community" ? "Group" : "Person" },
      },
    ],
  };
}

export function nodeinfoLinks(u: Urls) {
  return { links: [{ rel: "http://nodeinfo.diaspora.software/ns/schema/2.1", href: `${u.origin}/nodeinfo/2.1` }] };
}

export function nodeinfo(version: string) {
  return {
    version: "2.1",
    software: { name: "exos", version, homepage: "https://github.com/JulianS4K/EXP" },
    protocols: ["activitypub"],
    services: { inbound: [], outbound: [] },
    openRegistrations: true,
    usage: { users: {} },
    metadata: {},
  };
}

// ── actors ──────────────────────────────────────────────────────────────────

export interface CommunityRow {
  ap_name: string;
  slug: string;
  name: string;
  tagline?: string | null;
  about?: string | null;
  banner_url?: string | null;
  created_at?: string | null;
  public_key_pem: string;
  org?: { name: string; slug: string } | null;
}

export interface OrgRow {
  ap_name: string;
  slug: string;
  name: string;
  public_key_pem: string;
}

export function communityUrl(u: Urls, slug: string) {
  if (!SLUG.test(slug)) throw new Error("bad slug");
  return `${u.appBase}/c/${slug}`;
}

export function groupActor(u: Urls, c: CommunityRow) {
  if (!AP_NAME.test(c.ap_name)) throw new Error("bad ap_name");
  const id = groupId(u, c.ap_name);
  const about = [c.tagline, c.about].filter((x) => x && String(x).trim()).join("\n\n");
  const doc: Record<string, unknown> = {
    "@context": CONTEXT,
    type: "Group",
    id,
    preferredUsername: c.ap_name,
    name: c.name,
    summary: textToHtml(about),
    source: { content: about, mediaType: "text/markdown" },
    url: communityUrl(u, c.slug),
    inbox: `${id}/inbox`,
    outbox: `${id}/outbox`,
    followers: `${id}/followers`,
    // Lemmy: the moderators collection. Posting is the organizer's and hosts'.
    attributedTo: `${id}/moderators`,
    postingRestrictedToMods: true,
    sensitive: false,
    manuallyApprovesFollowers: false,
    discoverable: true,
    endpoints: { sharedInbox: sharedInbox(u) },
    publicKey: { id: `${id}#main-key`, owner: id, publicKeyPem: c.public_key_pem },
  };
  if (c.created_at) doc.published = new Date(c.created_at).toISOString();
  if (c.banner_url && /^https:\/\//.test(c.banner_url)) doc.image = { type: "Image", url: c.banner_url };
  return doc;
}

export function personActor(u: Urls, o: OrgRow) {
  if (!AP_NAME.test(o.ap_name)) throw new Error("bad ap_name");
  const id = personId(u, o.ap_name);
  return {
    "@context": CONTEXT,
    type: "Person",
    id,
    preferredUsername: o.ap_name,
    name: o.name,
    summary: textToHtml(`Organizer on Exos.`),
    url: SLUG.test(o.slug) ? `${u.appBase}/o/${o.slug}` : u.appBase,
    inbox: sharedInbox(u),
    outbox: `${id}/outbox`,
    endpoints: { sharedInbox: sharedInbox(u) },
    manuallyApprovesFollowers: true,
    discoverable: false,
    publicKey: { id: `${id}#main-key`, owner: id, publicKeyPem: o.public_key_pem },
  };
}

// ── objects ─────────────────────────────────────────────────────────────────

export interface PostRow {
  kind: "post";
  id: string;
  title: string | null;
  body: string;
  created_at: string;
  updated_at?: string | null;
  gone?: boolean;
  host?: string | null;
  community: { ap_name: string; slug: string; name: string };
  org: { slug: string; name: string };
}

export interface EventRow {
  kind: "event";
  id: string;
  name: string | null;
  description?: string | null;
  starts_at?: string | null;
  ends_at?: string | null;
  timezone?: string | null;
  venue_name?: string | null;
  venue_location?: string | null;
  image_url?: string | null;
  created_at: string;
  updated_at?: string | null;
  gone?: boolean;
  community: { ap_name: string; slug: string; name: string };
  org: { slug: string; name: string };
}

export type ObjectRow = PostRow | EventRow;

function iso(s: string | null | undefined): string | undefined {
  if (!s) return undefined;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? undefined : d.toISOString();
}

function addressing(u: Urls, apName: string) {
  const g = groupId(u, apName);
  return { to: [AS_PUBLIC, g], cc: [`${g}/followers`], audience: g };
}

export function postObject(u: Urls, p: PostRow) {
  if (!UUID.test(p.id)) throw new Error("bad id");
  const body = p.host ? `${p.body}\n\n(Posted by ${p.host})` : p.body;
  const base = {
    "@context": CONTEXT,
    id: postId(u, p.id),
    attributedTo: personId(u, orgApName(p.org.slug)),
    ...addressing(u, p.community.ap_name),
    content: textToHtml(body),
    mediaType: "text/html",
    source: { content: body, mediaType: "text/markdown" },
    url: `${communityUrl(u, p.community.slug)}#post-${p.id}`,
    published: iso(p.created_at),
    updated: iso(p.updated_at ?? undefined),
    sensitive: false,
  };
  return p.title ? { ...base, type: "Page", name: p.title } : { ...base, type: "Note" };
}

function eventWhen(e: EventRow): string {
  if (!e.starts_at) return "";
  const d = new Date(e.starts_at);
  if (Number.isNaN(d.getTime())) return "";
  try {
    return new Intl.DateTimeFormat("en-US", {
      weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
      timeZone: e.timezone || "UTC", timeZoneName: "short",
    }).format(d);
  } catch {
    return d.toISOString();
  }
}

export function eventUrl(u: Urls, id: string) {
  if (!UUID.test(id)) throw new Error("bad id");
  return `${u.appBase}/event/${id}`;
}

export function eventObject(u: Urls, e: EventRow) {
  if (!UUID.test(e.id)) throw new Error("bad id");
  const where = [e.venue_name, e.venue_location].filter(Boolean).join(", ");
  const text = [eventWhen(e), where, e.description ?? ""].filter((x) => x && x.trim()).join("\n\n");
  const doc: Record<string, unknown> = {
    "@context": CONTEXT,
    type: "Event",
    id: eventId(u, e.id),
    name: e.name ?? "Event",
    attributedTo: personId(u, orgApName(e.org.slug)),
    ...addressing(u, e.community.ap_name),
    content: textToHtml(text) + `<p><a href="${escapeHtml(eventUrl(u, e.id))}">Tickets</a></p>`,
    mediaType: "text/html",
    url: eventUrl(u, e.id),
    startTime: iso(e.starts_at),
    endTime: iso(e.ends_at),
    published: iso(e.created_at),
    updated: iso(e.updated_at ?? undefined),
  };
  if (e.timezone) doc.timezone = e.timezone;
  if (where) doc.location = { type: "Place", name: e.venue_name ?? where, address: e.venue_location ?? undefined };
  if (e.image_url && /^https:\/\//.test(e.image_url)) doc.image = { type: "Image", url: e.image_url };
  return doc;
}

/** The event as a Lemmy post (a Page linking to the event), its own id. */
export function eventPageObject(u: Urls, e: EventRow) {
  const when = eventWhen(e);
  const where = [e.venue_name, e.venue_location].filter(Boolean).join(", ");
  const text = [when, where, e.description ?? ""].filter((x) => x && x.trim()).join("\n\n");
  return {
    "@context": CONTEXT,
    type: "Page",
    id: eventPageId(u, e.id),
    name: `${e.name ?? "Event"}${when ? ` (${when})` : ""}`.slice(0, 200),
    attributedTo: personId(u, orgApName(e.org.slug)),
    ...addressing(u, e.community.ap_name),
    content: textToHtml(text),
    mediaType: "text/html",
    source: { content: text, mediaType: "text/markdown" },
    url: eventUrl(u, e.id),
    published: iso(e.created_at),
    sensitive: false,
  };
}

export function tombstone(id: string) {
  return { "@context": CONTEXT, type: "Tombstone", id };
}

// ── collections ─────────────────────────────────────────────────────────────

export function orderedCollection(id: string, totalItems: number, orderedItems?: unknown[], extra: Record<string, unknown> = {}) {
  const c: Record<string, unknown> = { "@context": CONTEXT, type: "OrderedCollection", id, totalItems, ...extra };
  if (orderedItems) c.orderedItems = orderedItems;
  return c;
}

// ── activities ──────────────────────────────────────────────────────────────

export type Style = "object" | "activity";

function strip<T extends Record<string, unknown>>(o: T): Omit<T, "@context"> {
  const { ["@context"]: _c, ...rest } = o;
  return rest;
}

/** What to send to followers for a post / event, per style. null = nothing for this style. */
export function announceFor(u: Urls, row: ObjectRow, style: Style): Record<string, unknown> | null {
  const g = groupId(u, row.community.ap_name);
  let obj: Record<string, unknown>;
  if (row.kind === "post") {
    // Lemmy has no top-level Note: untitled posts are for Mastodon-style followers.
    if (style === "activity" && !row.title) return null;
    obj = postObject(u, row);
  } else {
    obj = style === "activity" ? eventPageObject(u, row) : eventObject(u, row);
  }
  const inner = strip(obj);
  const announceBase = {
    "@context": CONTEXT,
    type: "Announce",
    actor: g,
    to: [AS_PUBLIC],
    cc: [`${g}/followers`],
    published: new Date().toISOString(),
  };
  if (style === "object") {
    return { ...announceBase, id: activityId(u, "announce", `${row.kind}-${row.id}`), object: inner };
  }
  return {
    ...announceBase,
    id: activityId(u, "announce", `${row.kind}-${row.id}-create`),
    object: {
      type: "Create",
      id: activityId(u, "create", `${row.kind}-${row.id}`),
      actor: inner.attributedTo,
      to: inner.to,
      cc: inner.cc,
      audience: g,
      object: inner,
    },
  };
}

/**
 * Removing a post. Mastodon-style: Delete by the author (signed with the org
 * Person's key). Lemmy-style: the Group announces the author's Delete.
 */
export function deleteFor(u: Urls, row: PostRow, style: Style): { signer: "org" | "community"; activity: Record<string, unknown> } {
  const g = groupId(u, row.community.ap_name);
  const author = personId(u, orgApName(row.org.slug));
  const del = {
    type: "Delete",
    id: activityId(u, "delete", `post-${row.id}`),
    actor: author,
    to: [AS_PUBLIC],
    cc: [`${g}/followers`],
    audience: g,
    object: postId(u, row.id),
  };
  if (style === "object") return { signer: "org", activity: { "@context": CONTEXT, ...del, object: strip(tombstone(postId(u, row.id))) } };
  return {
    signer: "community",
    activity: {
      "@context": CONTEXT, type: "Announce", id: activityId(u, "announce", `delete-post-${row.id}`), actor: g,
      to: [AS_PUBLIC], cc: [`${g}/followers`], object: del,
    },
  };
}

export function acceptFollow(u: Urls, apName: string, follow: Record<string, unknown>) {
  const g = groupId(u, apName);
  const fid = typeof follow.id === "string" ? follow.id : "";
  // Stable per Follow id, so a retried Accept is the same activity.
  let h = 0;
  for (const ch of fid) h = (Math.imul(31, h) + ch.charCodeAt(0)) | 0;
  return {
    "@context": CONTEXT,
    type: "Accept",
    id: `${g}/accept/${(h >>> 0).toString(16)}-${fid.length}`,
    actor: g,
    to: [follow.actor],
    object: { type: "Follow", id: fid || undefined, actor: follow.actor, object: g },
  };
}

// ── inbound helpers ─────────────────────────────────────────────────────────

export function idOf(v: unknown): string | null {
  if (typeof v === "string") return v;
  if (v && typeof v === "object" && typeof (v as { id?: unknown }).id === "string") return (v as { id: string }).id;
  return null;
}

/** Which of our objects an inReplyTo points at: { kind, id } or null. */
export function ourObject(u: Urls, ref: unknown): { kind: "post" | "event"; id: string } | null {
  const s = idOf(ref);
  if (!s || !s.startsWith(u.origin + "/ap/")) return null;
  const m = s.slice(u.origin.length).match(/^\/ap\/(p|e)\/([0-9a-f-]{36})(?:\/page)?$/i);
  if (!m || !UUID.test(m[2])) return null;
  return { kind: m[1] === "p" ? "post" : "event", id: m[2].toLowerCase() };
}

/** Which of our communities a URL (Group id or inbox) names. */
export function ourGroup(u: Urls, ref: unknown): string | null {
  const s = idOf(ref);
  if (!s || !s.startsWith(u.origin + "/ap/c/")) return null;
  const m = s.slice(u.origin.length).match(/^\/ap\/c\/([a-z0-9_]{3,60})(?:\/inbox)?$/);
  return m ? m[1] : null;
}

export interface RemoteActor {
  id: string;
  inbox: string;
  sharedInbox: string | null;
  keyId: string;
  publicKeyPem: string;
  handle: string | null;
  name: string | null;
}

/** Validate a fetched actor document; the key must belong to it and live on its host. */
export function parseRemoteActor(doc: Record<string, unknown>, expectedId: string): RemoteActor | null {
  const id = idOf(doc.id);
  if (!id || id !== expectedId || !/^https:\/\//.test(id)) return null;
  const inbox = typeof doc.inbox === "string" ? doc.inbox : null;
  const pk = doc.publicKey as Record<string, unknown> | undefined;
  if (!inbox || !/^https:\/\//.test(inbox) || !pk) return null;
  const keyId = idOf(pk.id);
  const owner = idOf(pk.owner);
  const pem = typeof pk.publicKeyPem === "string" ? pk.publicKeyPem : null;
  if (!keyId || !pem || owner !== id) return null;
  const sameHost = (a: string, b: string) => {
    try {
      return new URL(a).host === new URL(b).host;
    } catch {
      return false;
    }
  };
  if (!sameHost(keyId, id) || !sameHost(inbox, id)) return null;
  const endpoints = doc.endpoints as Record<string, unknown> | undefined;
  const shared = typeof endpoints?.sharedInbox === "string" && /^https:\/\//.test(endpoints.sharedInbox) && sameHost(endpoints.sharedInbox, id)
    ? endpoints.sharedInbox
    : null;
  const user = typeof doc.preferredUsername === "string" ? doc.preferredUsername.slice(0, 80) : null;
  return {
    id,
    inbox,
    sharedInbox: shared,
    keyId,
    publicKeyPem: pem,
    handle: user ? `@${user}@${new URL(id).host}` : null,
    name: typeof doc.name === "string" ? doc.name.slice(0, 120) : user,
  };
}

/** The software name from a NodeInfo document ("mastodon", "lemmy", …). */
export function softwareName(doc: unknown): string | null {
  const n = (doc as { software?: { name?: unknown } })?.software?.name;
  return typeof n === "string" && /^[a-z0-9._-]{1,40}$/i.test(n) ? n.toLowerCase() : null;
}
