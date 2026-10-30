// exos-activitypub — ActivityPub federation for Exos communities
// (docs/federation.md, mig 20261031200000).
//
// OFF unless EXOS_FEDERATION=on: every route answers 404 and the delivery
// cron sends nothing. Even when on, only public communities whose organizer
// turned "Share on the fediverse" on are actors.
//
// Served on the app's own domain (EXOS_AP_ORIGIN, e.g. https://exos.app) by a
// reverse proxy that keeps the path (server.ts forwards /.well-known/webfinger,
// /.well-known/nodeinfo, /nodeinfo/* and /ap/* here). Ids and signatures use
// that origin: inbound signatures are checked against
// "(request-target): post /ap/…" and "host: <EXOS_AP_ORIGIN host>".
//
//   GET  /.well-known/webfinger?resource=acct:<name>@<host>
//   GET  /.well-known/nodeinfo, /nodeinfo/2.1
//   GET  /ap/c/<name>                     Group actor (HTML Accept → the community page)
//   GET  /ap/c/<name>/outbox              latest 20 public posts + events (as Announce)
//   GET  /ap/c/<name>/followers           count only
//   GET  /ap/c/<name>/moderators          the org actor
//   GET  /ap/o/<org_name>[/outbox]        the org's Person actor (post author)
//   GET  /ap/p/<uuid>, /ap/e/<uuid>[/page]  objects (Tombstone 410 when removed)
//   POST /ap/c/<name>/inbox, /ap/inbox    signed Follow, Undo Follow, Create (replies), Delete
//   POST /deliver                         X-Cron-Secret: sends queued deliveries
//
// Security: inbound requests need a valid draft-cavage signature (digest,
// date within 1 h) by the key of the activity's actor, fetched through the
// SSRF guard (https, public IPs only, 5 s, 256 KB, redirects re-checked).
// Replies only reach the moderation queue. Outbound delivery is the ONLY
// third-party write here and it happens only with EXOS_FEDERATION=on, to
// follower inboxes, signed with the community's key (Vault, service role).
//
// Deploy with --no-verify-jwt (remote servers send no Supabase JWT).
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, CRON_SECRET, EXOS_FEDERATION,
//      EXOS_AP_ORIGIN, EXOS_APP_BASE_URL, optional EXOS_GUEST_IP_SALT.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { clientIp, hashIp } from "../_shared/guest.ts";
import { redactError } from "../_shared/log.ts";
import { AP_ACCEPT, fetchApJson, guardedFetch, readCapped } from "../_shared/activitypub/fetchGuard.ts";
import {
  generateActorKeyPair, parseSignatureHeader, signRequest, verifyRequest, type HeaderBag, type VerifyResult,
} from "../_shared/activitypub/signature.ts";
import {
  acceptFollow, announceFor, CONTEXT, communityUrl, deleteFor, eventObject, eventPageObject, groupActor, groupId, idOf,
  nodeinfo, nodeinfoLinks, ourGroup, ourObject, orderedCollection, orgApName, parseAcct, parseRemoteActor, personActor,
  personId, postObject, softwareName, tombstone, webfinger, htmlToText, type ObjectRow, type RemoteActor, type Style,
  type Urls,
} from "../_shared/activitypub/objects.ts";

const VERSION = "1.0";
const AP_TYPE = "application/activity+json; charset=utf-8";
const INBOX_MAX = 256 * 1024;
const NET_PER_MINUTE = 300;
const HOST_PER_MINUTE = 600;
const DELIVER_BUDGET_MS = 50_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Lookup = {
  kind: "community" | "org";
  ap_name: string;
  community_id?: string;
  org_id: string;
  slug: string;
  name: string;
  tagline?: string | null;
  about?: string | null;
  banner_url?: string | null;
  created_at?: string | null;
  org?: { name: string; slug: string } | null;
  followers?: number;
  actor_id: string | null;
  public_key_pem: string | null;
};

Deno.serve(async (req: Request): Promise<Response> => {
  if ((Deno.env.get("EXOS_FEDERATION") ?? "").toLowerCase() !== "on") return text("not found", 404);
  const origin = (Deno.env.get("EXOS_AP_ORIGIN") ?? "").replace(/\/+$/, "");
  const appBase = (Deno.env.get("EXOS_APP_BASE_URL") ?? "").replace(/\/+$/, "");
  if (!/^https:\/\/[^/]+$/.test(origin) || !/^https:\/\//.test(appBase)) {
    console.error("exos-activitypub: EXOS_AP_ORIGIN / EXOS_APP_BASE_URL not set to https URLs");
    return text("federation not configured", 503);
  }
  const urls: Urls = { origin, appBase };
  const url = new URL(req.url);
  // Path after the function name (direct calls) or as proxied (same suffix).
  const path = url.pathname.replace(/^.*?\/exos-activitypub(?=\/|$)/, "").replace(/\/+$/, "") || "/";
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  try {
    if (path === "/deliver" && req.method === "POST") {
      const authErr = requireCronSecret(req);
      if (authErr) return authErr;
      return json(await deliver(sb, urls), 200, "application/json");
    }
    if (req.method === "POST") {
      if (path === "/ap/inbox") return await inbox(sb, urls, req, path + url.search, null);
      const m = path.match(/^\/ap\/c\/([a-z0-9_]{3,60})\/inbox$/);
      if (m) return await inbox(sb, urls, req, path + url.search, m[1]);
      return text("not found", 404);
    }
    if (req.method !== "GET" && req.method !== "HEAD") return text("method not allowed", 405, { Allow: "GET, HEAD, POST" });

    const salt = Deno.env.get("EXOS_GUEST_IP_SALT") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const net = (await hashIp(clientIp((h) => req.headers.get(h)), salt)) ?? "unknown";
    const limited = await rateLimited(sb, `ap:${net}`, NET_PER_MINUTE);
    if (limited === "error") return text("temporarily unavailable", 503, { "Retry-After": "30" });
    if (limited) return text("rate limit exceeded", 429, { "Retry-After": "60" });
    return await get(sb, urls, req, path, url);
  } catch (e) {
    console.error("exos-activitypub: failed", path, redactError(e));
    return text("something went wrong", 500);
  }
});

// ── GET ─────────────────────────────────────────────────────────────────────

async function get(sb: SupabaseClient, u: Urls, req: Request, path: string, url: URL): Promise<Response> {
  if (path === "/.well-known/webfinger") {
    const name = parseAcct(url.searchParams.get("resource"), new URL(u.origin).host);
    if (!name) return text("not found", 404);
    const l = await lookup(sb, name);
    if (!l) return text("not found", 404);
    const html = l.kind === "community" ? communityUrl(u, l.slug) : `${u.appBase}/o/${encodeURIComponent(l.slug)}`;
    return json(webfinger(u, l.ap_name, l.kind, html), 200, "application/jrd+json; charset=utf-8");
  }
  if (path === "/.well-known/nodeinfo") return json(nodeinfoLinks(u), 200, "application/json");
  if (path === "/nodeinfo/2.1") {
    return json(nodeinfo(VERSION), 200, 'application/json; profile="http://nodeinfo.diaspora.software/ns/schema/2.1#"');
  }

  let m = path.match(/^\/ap\/c\/([a-z0-9_]{3,60})(\/outbox|\/followers|\/moderators)?$/);
  if (m) {
    const l = await lookup(sb, m[1]);
    if (!l || l.kind !== "community") return text("not found", 404);
    const gid = groupId(u, l.ap_name);
    if (!m[2]) {
      if (!wantsJson(req)) return Response.redirect(communityUrl(u, l.slug), 302);
      const { pem } = await ensureKey(sb, l);
      return json(groupActor(u, {
        ap_name: l.ap_name, slug: l.slug, name: l.name, tagline: l.tagline, about: l.about, banner_url: l.banner_url,
        created_at: l.created_at, public_key_pem: pem, org: l.org,
      }));
    }
    if (m[2] === "/followers") return json(orderedCollection(`${gid}/followers`, Number(l.followers ?? 0)));
    if (m[2] === "/moderators") {
      return json(orderedCollection(`${gid}/moderators`, 1, l.org ? [personId(u, orgApName(l.org.slug))] : []));
    }
    const { data, error } = await sb.rpc("exos_ap_outbox", { p_community_id: l.community_id, p_limit: 20 });
    if (error) throw new Error(`outbox: ${error.message}`);
    const rows = ((data as { items?: ObjectRow[] } | null)?.items ?? []).filter(Boolean);
    // Lemmy reads a community outbox as Announce{Create{Page}}; untitled
    // posts (Notes) are listed as Announce{Note} for everyone else.
    const items = rows.map((r) => announceFor(u, r, "activity") ?? announceFor(u, r, "object")).filter(Boolean);
    return json(orderedCollection(`${gid}/outbox`, Number((data as { total?: number } | null)?.total ?? items.length), items));
  }

  m = path.match(/^\/ap\/o\/(org_[a-z0-9_]{1,56})(\/outbox)?$/);
  if (m) {
    const l = await lookup(sb, m[1]);
    if (!l || l.kind !== "org") return text("not found", 404);
    if (m[2]) return json(orderedCollection(`${personId(u, l.ap_name)}/outbox`, 0, []));
    if (!wantsJson(req)) return Response.redirect(`${u.appBase}/o/${encodeURIComponent(l.slug)}`, 302);
    const { pem } = await ensureKey(sb, l);
    return json(personActor(u, { ap_name: l.ap_name, slug: l.slug, name: l.name, public_key_pem: pem }));
  }

  m = path.match(/^\/ap\/(p|e)\/([0-9a-f-]{36})(\/page)?$/i);
  if (m && UUID.test(m[2]) && !(m[1] === "p" && m[3])) {
    const kind = m[1] === "p" ? "post" : "event";
    const { data, error } = await sb.rpc("exos_ap_object", { p_kind: kind, p_id: m[2].toLowerCase() });
    if (error) throw new Error(`object: ${error.message}`);
    const row = data as (ObjectRow & { gone?: boolean }) | null;
    if (!row) return text("not found", 404);
    if (row.gone) return json(tombstone(`${u.origin}${path}`), 410);
    if (!wantsJson(req)) {
      return Response.redirect(row.kind === "post" ? `${communityUrl(u, row.community.slug)}#post-${row.id}` : `${u.appBase}/event/${row.id}`, 302);
    }
    if (row.kind === "post") return json(postObject(u, row));
    return json(m[3] ? eventPageObject(u, row) : eventObject(u, row));
  }

  return text("not found", 404);
}

// ── inbox ───────────────────────────────────────────────────────────────────

async function inbox(sb: SupabaseClient, u: Urls, req: Request, publicPath: string, routeName: string | null): Promise<Response> {
  let raw: string;
  try {
    raw = await readCapped(req, INBOX_MAX);
  } catch {
    return text("payload too large", 413);
  }
  let act: Record<string, unknown>;
  try {
    const j = JSON.parse(raw);
    if (!j || typeof j !== "object" || Array.isArray(j)) throw new Error("not an object");
    act = j as Record<string, unknown>;
  } catch {
    return text("bad JSON", 400);
  }
  const actorUri = idOf(act.actor);
  const sig = parseSignatureHeader(req.headers.get("signature"));
  if (!actorUri || !/^https:\/\//.test(actorUri) || !sig) return text("signature required", 401);
  let actorHost: string;
  try {
    actorHost = new URL(actorUri).host;
    if (new URL(sig.keyId).host !== actorHost) return text("key does not belong to the actor", 401);
  } catch {
    return text("bad actor", 400);
  }
  const limited = await rateLimited(sb, `apin:${actorHost}`.slice(0, 200), HOST_PER_MINUTE);
  if (limited === "error") return text("temporarily unavailable", 503, { "Retry-After": "30" });
  if (limited) return text("rate limit exceeded", 429, { "Retry-After": "60" });

  // Verify as addressed: our public host + the path the sender POSTed to.
  const headers: HeaderBag = {};
  req.headers.forEach((v, k) => (headers[k] = v));
  headers.host = new URL(u.origin).host;
  const type = String(act.type ?? "");

  let actor = await remoteActor(sb, actorUri, false);
  if (!actor && type === "Delete" && idOf(act.object) === actorUri) {
    // An account deletion whose actor is already gone: nothing to verify against.
    return text("accepted", 202);
  }
  if (!actor) return text("could not fetch the actor's key", 401);
  let check: VerifyResult = actor.keyId === sig.keyId
    ? await verifyRequest({ method: "POST", pathWithQuery: publicPath, headers, body: raw, publicKey: actor.publicKeyPem, parsed: sig })
    : { ok: false, reason: "key changed" };
  if (!check.ok) {
    // Key rotated since we cached it: fetch again, once.
    actor = await remoteActor(sb, actorUri, true);
    if (!actor || actor.keyId !== sig.keyId) return text("unknown key", 401);
    check = await verifyRequest({ method: "POST", pathWithQuery: publicPath, headers, body: raw, publicKey: actor.publicKeyPem, parsed: sig });
    if (!check.ok) return text(`bad signature: ${check.reason ?? ""}`, 401);
  }

  const sameHost = (id: string | null) => {
    try {
      return !!id && new URL(id).host === actorHost;
    } catch {
      return false;
    }
  };

  if (type === "Follow") {
    const name = ourGroup(u, act.object) ?? routeName;
    if (!name || (routeName && name !== routeName)) return text("not ours", 404);
    const l = await lookup(sb, name);
    if (!l || l.kind !== "community") return text("not found", 404);
    const software = await detectSoftware(actorUri);
    const { data, error } = await sb.rpc("exos_ap_follow", {
      p_community_id: l.community_id, p_actor_uri: actor.id, p_inbox: actor.inbox, p_shared_inbox: actor.sharedInbox,
      p_follow: { id: idOf(act.id), type: "Follow", actor: actor.id, object: groupId(u, l.ap_name) }, p_software: software,
    });
    if (error) throw new Error(`follow: ${error.message}`);
    return text(String(data), data === "accepted" ? 202 : 403);
  }

  if (type === "Undo") {
    const inner = act.object as Record<string, unknown> | string;
    const innerType = typeof inner === "object" && inner ? String(inner.type ?? "") : "";
    if (innerType && innerType !== "Follow") return text("ignored", 202);
    if (typeof inner === "object" && inner && idOf(inner.actor) !== actor.id) return text("not your follow", 403);
    const name = (typeof inner === "object" && inner ? ourGroup(u, inner.object) : null) ?? routeName;
    const l = name ? await lookup(sb, name) : null;
    await sb.rpc("exos_ap_unfollow", { p_community_id: l?.community_id ?? null, p_actor_uri: actor.id });
    return text("accepted", 202);
  }

  if (type === "Create") {
    const obj = act.object as Record<string, unknown> | null;
    if (!obj || typeof obj !== "object") return text("ignored", 202);
    const objId = idOf(obj.id);
    if (!sameHost(objId) || idOf(obj.attributedTo) !== actor.id) return text("object is not the actor's", 403);
    const target = ourObject(u, obj.inReplyTo);
    if (!target || !["Note", "Page", "Article"].includes(String(obj.type))) return text("ignored", 202);
    const content = htmlToText(obj.content ?? obj.name ?? "");
    const link = typeof obj.url === "string" ? obj.url : idOf(obj.url);
    const { data, error } = await sb.rpc("exos_ap_record_reply", {
      p_kind: target.kind, p_target: target.id, p_activity_id: idOf(act.id), p_object_id: objId, p_actor_uri: actor.id,
      p_actor_name: actor.name, p_actor_handle: actor.handle, p_content: content, p_url: sameHost(link) ? link : null,
    });
    if (error) throw new Error(`reply: ${error.message}`);
    return text(String(data), 202);
  }

  if (type === "Delete") {
    const objId = idOf(act.object);
    if (!objId || !sameHost(objId)) return text("ignored", 202);
    await sb.rpc("exos_ap_remote_delete", { p_actor_uri: actor.id, p_object_id: objId });
    return text("accepted", 202);
  }

  // Like, Announce, Update, Flag, …: not handled (yet).
  return text("ignored", 202);
}

async function remoteActor(sb: SupabaseClient, uri: string, refresh: boolean): Promise<RemoteActor | null> {
  if (!refresh) {
    const { data } = await sb.rpc("exos_ap_remote_actor", { p_actor_uri: uri });
    const c = data as Record<string, string | null> | null;
    if (c?.key_id && c.public_key_pem && c.inbox_uri) {
      return { id: uri, keyId: c.key_id, publicKeyPem: c.public_key_pem, inbox: c.inbox_uri, sharedInbox: c.shared_inbox_uri,
        handle: c.handle, name: c.name };
    }
  }
  const r = await fetchApJson(uri, { timeoutMs: 5000, maxBytes: INBOX_MAX });
  if (!r.ok) return null;
  const a = parseRemoteActor(r.json, uri);
  if (!a) return null;
  await sb.rpc("exos_ap_remote_actor_put", {
    p_actor_uri: a.id, p_key_id: a.keyId, p_public_key_pem: a.publicKeyPem, p_inbox: a.inbox, p_shared_inbox: a.sharedInbox,
    p_handle: a.handle, p_name: a.name,
  });
  return a;
}

/** NodeInfo software name of the actor's server ("lemmy", "mastodon", …), best effort. */
async function detectSoftware(actorUri: string): Promise<string | null> {
  try {
    const base = new URL(actorUri).origin;
    const links = await fetchApJson(`${base}/.well-known/nodeinfo`, { timeoutMs: 4000, maxBytes: 32 * 1024, headers: { accept: "application/json" } });
    if (!links.ok) return null;
    const list = (links.json.links as Array<{ rel?: string; href?: string }> | undefined) ?? [];
    const href = list.find((l) => /nodeinfo\.diaspora\.software\/ns\/schema\/2\.[01]$/.test(l.rel ?? ""))?.href;
    if (!href || new URL(href).origin !== base) return null;
    const ni = await fetchApJson(href, { timeoutMs: 4000, maxBytes: 64 * 1024, headers: { accept: "application/json" } });
    return ni.ok ? softwareName(ni.json) : null;
  } catch {
    return null;
  }
}

// ── delivery ────────────────────────────────────────────────────────────────

type Claim = {
  id: string; kind: string; ref_id: string | null; style: Style; payload: Record<string, unknown> | null;
  inbox_uri: string; attempts: number; community_id: string; ap_name: string; actor_id: string | null;
};

async function deliver(sb: SupabaseClient, u: Urls) {
  const started = Date.now();
  const keys = new Map<string, string>();
  const out = { sent: 0, failed: 0, dead: 0, skipped: 0 };
  while (Date.now() - started < DELIVER_BUDGET_MS) {
    const { data, error } = await sb.rpc("exos_ap_claim", { p_limit: 25 });
    if (error) throw new Error(`claim: ${error.message}`);
    const batch = (data ?? []) as Claim[];
    if (batch.length === 0) break;
    for (const d of batch) {
      const res = await deliverOne(sb, u, d, keys).catch((e) => ({ ok: false, status: 0, error: String(redactError(e)).slice(0, 200), permanent: false }));
      const { data: st } = await sb.rpc("exos_ap_mark", {
        p_id: d.id, p_ok: res.ok, p_status: res.status || null, p_error: res.error ?? null, p_permanent: res.permanent ?? false,
      });
      if (res.ok && res.error) out.skipped++;
      else if (res.ok) out.sent++;
      else if (st === "dead") out.dead++;
      else out.failed++;
    }
  }
  return out;
}

async function deliverOne(
  sb: SupabaseClient, u: Urls, d: Claim, keys: Map<string, string>,
): Promise<{ ok: boolean; status: number; error?: string; permanent?: boolean }> {
  let activity: Record<string, unknown> | null = null;
  let signer: { actorId: string | null; actorUri: string; kind: "community" | "org"; ref: string; slug?: string } = {
    actorId: d.actor_id, actorUri: groupId(u, d.ap_name), kind: "community", ref: d.community_id,
  };

  if (d.kind === "accept") {
    if (!d.payload) return { ok: false, status: 0, error: "no Follow", permanent: true };
    activity = acceptFollow(u, d.ap_name, d.payload);
  } else if (d.kind === "create_post" || d.kind === "create_event" || d.kind === "delete_post") {
    const objKind = d.kind === "create_event" ? "event" : "post";
    const { data, error } = await sb.rpc("exos_ap_object", { p_kind: objKind, p_id: d.ref_id });
    if (error) throw new Error(`object: ${error.message}`);
    const row = data as (ObjectRow & { gone?: boolean }) | null;
    if (!row) return { ok: false, status: 0, error: "nothing to send", permanent: true };
    if (d.kind === "delete_post") {
      if (row.kind !== "post") return { ok: false, status: 0, error: "not a post", permanent: true };
      const del = deleteFor(u, row, d.style);
      activity = del.activity;
      if (del.signer === "org") {
        const name = orgApName(row.org.slug);
        const l = await lookup(sb, name);
        if (!l) return { ok: false, status: 0, error: "org actor gone", permanent: true };
        const k = await ensureKey(sb, l);
        signer = { actorId: k.actorId, actorUri: personId(u, name), kind: "org", ref: l.org_id };
      }
    } else {
      if (row.gone) return { ok: false, status: 0, error: "removed before sending", permanent: true };
      activity = announceFor(u, row, d.style);
      if (!activity) return { ok: true, status: 0, error: "skipped: not shown on this server type" };
    }
  } else {
    return { ok: false, status: 0, error: `unknown kind ${d.kind}`, permanent: true };
  }

  if (!signer.actorId && signer.kind === "community") {
    const l = await lookup(sb, d.ap_name);
    if (!l) return { ok: false, status: 0, error: "community no longer federates", permanent: true };
    signer.actorId = (await ensureKey(sb, l)).actorId;
  }
  if (!signer.actorId) return { ok: false, status: 0, error: "no signing key" };
  let pem = keys.get(signer.actorId);
  if (!pem) {
    const { data, error } = await sb.rpc("exos_ap_signing_key", { p_actor_id: signer.actorId });
    if (error || typeof data !== "string") return { ok: false, status: 0, error: "signing key unavailable" };
    pem = data;
    keys.set(signer.actorId, pem);
  }

  const body = JSON.stringify(activity);
  const headers = await signRequest({
    method: "POST", url: d.inbox_uri, body, keyId: `${signer.actorUri}#main-key`, privateKey: pem,
    headers: { "content-type": "application/activity+json", accept: AP_ACCEPT, "user-agent": `Exos/${VERSION} (+${u.origin})` },
  });
  const r = await guardedFetch(d.inbox_uri, { method: "POST", headers, body, timeoutMs: 10_000, maxBytes: 64 * 1024 });
  if (r.ok) return { ok: true, status: r.status };
  return { ok: false, status: r.status, error: r.error ?? `HTTP ${r.status}`, permanent: !!r.blocked };
}

// ── helpers ─────────────────────────────────────────────────────────────────

async function lookup(sb: SupabaseClient, name: string): Promise<Lookup | null> {
  const { data, error } = await sb.rpc("exos_ap_lookup", { p_name: name });
  if (error) throw new Error(`lookup: ${error.message}`);
  return (data as Lookup | null) ?? null;
}

/** The actor's public key + id, creating the pair on first use (private half → Vault). */
async function ensureKey(sb: SupabaseClient, l: Lookup): Promise<{ pem: string; actorId: string }> {
  if (l.public_key_pem && l.actor_id) return { pem: l.public_key_pem, actorId: l.actor_id };
  const pair = await generateActorKeyPair();
  const { data, error } = await sb.rpc("exos_ap_store_key", {
    p_kind: l.kind, p_ref: l.kind === "community" ? l.community_id : l.org_id,
    p_public_pem: pair.publicPem, p_private_pem: pair.privatePem,
  });
  if (error) throw new Error(`store key: ${error.message}`);
  const k = data as { public_key_pem: string; actor_id: string };
  return { pem: String(k.public_key_pem), actorId: String(k.actor_id) };
}

async function rateLimited(sb: SupabaseClient, bucket: string, limit: number): Promise<boolean | "error"> {
  const { data, error } = await sb.rpc("exos_rate_hit", { p_bucket: bucket, p_limit: limit });
  if (error) {
    console.error("exos-activitypub: rate limiter error (refusing)", error.message);
    return "error";
  }
  return data === false;
}

function wantsJson(req: Request): boolean {
  const a = req.headers.get("accept") ?? "";
  return /application\/(activity\+json|ld\+json|json)/i.test(a) || a === "" || a === "*/*";
}

function json(body: unknown, status = 200, type = AP_TYPE): Response {
  const doc = body && typeof body === "object" && !Array.isArray(body) && !("@context" in body) && type === AP_TYPE
    ? { "@context": CONTEXT, ...(body as Record<string, unknown>) }
    : body;
  return new Response(JSON.stringify(doc), {
    status,
    headers: {
      "Content-Type": type,
      "Cache-Control": status === 200 ? "public, max-age=300" : "no-store",
      "X-Content-Type-Options": "nosniff",
      "Access-Control-Allow-Origin": "*",
    },
  });
}

function text(body: string, status: number, extra: Record<string, string> = {}): Response {
  return new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", ...extra } });
}
