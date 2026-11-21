// Instagram content publishing on the channel core (social phase, mig
// 20261121203000; docs/social.md "Posting and listing APIs"): publishPost
// to the organizer's OWN professional (business / creator) Instagram account.
// DRY RUN ONLY: both writes are on the allowlist below and go through ctx.http
// (GatedHttp); exos-social pins the org's switch off
// (SOCIAL_WRITES_PINNED_OFF) and EXOS_INSTAGRAM_WRITES is off.
//
// Two steps (Instagram Graph API, Facebook Login: the same Meta app as the
// ads phase's ads_meta_api, _shared/social/apps.ts):
//   POST /v25.0/<ig-user-id>/media          {image_url, caption}                  an image post
//                                            {media_type: REELS, video_url, caption} a reel
//   POST /v25.0/<ig-user-id>/media_publish  {creation_id: <the container id>}
// A post is counted when it is published: 100 per account per 24 hours
// (limits.ts "instagram", metric posts). Captions come from the post kit:
// no link in them (not clickable), "Tickets: link in bio".
//
// Credential: provider ig_publish in the store (managed; a "Connect
// Instagram" flow, not built, writes it): an access token with
// instagram_basic + instagram_content_publish for the Page the professional
// account is linked to; config ig_user_id (digits). Bearer token in the header.
//
// VERIFIED (well-known public Graph API paths): the two edges, image_url /
// caption / creation_id, media_type REELS with video_url, the 2,200-character
// caption. UNVERIFIED (Meta's docs were not readable from the build session):
// that 100 is the current 24-hour number (GET /<ig-user>/content_publishing_limit
// reads it; nothing here calls it), JPEG-only images, that a reel's container
// must finish processing (status_code FINISHED) before media_publish, and
// whether v25.0 is still current.

import { caps, type ChannelAdapter, type ChannelCtx, type ExosEvent, type OrgCredential, type SocialPost } from "../adapter.ts";
import type { WriteRule } from "../gatedHttp.ts";
import { META_GRAPH_VERSION } from "../../conversions/meta.ts";
import { cfgOr, createdId, newResult, standInBy, write, type AdsResult } from "./adsCommon.ts";

export const INSTAGRAM_BASE = "https://graph.facebook.com";
const V = META_GRAPH_VERSION.replace(/\./g, "\\.");
const IG = "(?:[0-9]{1,25}|planned_account)";

/** Exactly the writes the Instagram adapter makes. */
export const INSTAGRAM_WRITES: WriteRule[] = [
  { method: "POST", path: new RegExp(`^/${V}/${IG}/media$`) },
  { method: "POST", path: new RegExp(`^/${V}/${IG}/media_publish$`) },
];

export const instagramStandIn = standInBy([[/\/media_publish$/, "ig_media"], [/\/media$/, "ig_container"]]);

/** GatedHttp options for this channel (the token in a header only). */
export function instagramHttp(creds: OrgCredential | null) {
  const ig = typeof creds?.config.ig_user_id === "string" ? creds.config.ig_user_id : "";
  return {
    channel: "instagram",
    base: INSTAGRAM_BASE,
    writes: INSTAGRAM_WRITES,
    headers: creds?.secret ? { Authorization: `Bearer ${creds.secret}` } : {},
    secrets: [creds?.secret],
    standIn: instagramStandIn,
    limits: { platform: "instagram", scopeKey: ig.slice(0, 64) },
  };
}

const p = (path: string) => `/${META_GRAPH_VERSION}${path}`;

async function publishPost(ctx: ChannelCtx, _ev: ExosEvent, post: SocialPost): Promise<AdsResult> {
  const res = newResult("instagram", ctx);
  const ig = cfgOr(ctx.creds.config, "ig_user_id", /^[0-9]{1,25}$/, "account");
  if (!res.connected || !ig.set) res.warnings.push("Instagram isn't connected: the account below is a placeholder.");
  const caption = post.text.slice(0, 2200);
  if (/https?:\/\//i.test(caption)) {
    res.stopped = "The caption has a link: Instagram captions can't carry one (use link in bio).";
    return res;
  }
  const media = post.videoUrl
    ? { media_type: "REELS", video_url: post.videoUrl, caption }
    : post.imageUrl ? { image_url: post.imageUrl, caption } : null;
  if (!media) { res.stopped = "Instagram needs an image or a video."; return res; }
  if (post.videoUrl) res.warnings.push("A reel's container has to finish processing before it can be published (Exos would wait for it; unverified).");

  const c = await write(ctx, res, "POST", p(`/${ig.value}/media`), media, { op: "post.container" });
  const containerId = createdId(c, (b) => b?.id);
  if (!containerId) { res.stopped = c.error ?? "the container wasn't created"; return res; }
  res.ids.container = containerId;

  const pub = await write(ctx, res, "POST", p(`/${ig.value}/media_publish`), { creation_id: containerId }, {
    op: "post.publish",
    usage: { metric: "posts", n: 1 },
  });
  const mediaId = createdId(pub, (b) => b?.id);
  if (mediaId) res.ids.media = mediaId;
  else res.stopped = pub.error === "LIMIT_CAPPED" ? "Instagram's 100 posts a day are used up: try again tomorrow." : pub.error ?? "not published";
  return res;
}

export const instagramAdapter: ChannelAdapter = {
  id: "instagram",
  label: "Instagram",
  status: "core",
  caps: caps({ role: "secondary", publishPost: true }),
  writes: INSTAGRAM_WRITES,
  publishPost,
};
