// TikTok Content Posting API, Direct Post, on the channel core (social
// phase, mig 20261121203000; docs/social.md "Posting and listing APIs"):
// publishPost to the organizer's own TikTok account. DRY RUN ONLY: every
// write is on the allowlist below and goes through ctx.http (GatedHttp);
// exos-social pins the org's switch off and EXOS_TIKTOK_WRITES is off.
//
//   POST /v2/post/publish/creator_info/query/   {}  (a read TikTok makes a POST: the privacy
//                                                    levels the creator may use, the daily cap)
//   POST /v2/post/publish/content/init/         {post_info: {title, description, privacy_level,
//                                                 disable_comment, auto_add_music},
//                                                source_info: {source: PULL_FROM_URL, photo_images,
//                                                 photo_cover_index}, post_mode: DIRECT_POST,
//                                                media_type: PHOTO}
//   POST /v2/post/publish/video/init/           {post_info: {title, privacy_level, ...},
//                                                source_info: {source: PULL_FROM_URL, video_url}}
//
// UNAUDITED APPS POST PRIVATELY. Until TikTok audits the Exos app, every
// Direct Post is SELF_ONLY (only the creator sees it): the plan always says
// so. EXOS_TIKTOK_APP_AUDITED=on (after the audit) lets the post use
// PUBLIC_TO_EVERYONE when creator_info offers it. TikTok's rules: no QR code
// or contact details in the creative; ad text takes no URL, @ or # (posts: a
// URL is warned about; postKit.ts).
//
// Credential: provider tiktok_publish in the store (managed; "Connect
// TikTok", not built, runs TikTok Login Kit with video.publish): the user
// access token, Bearer in the header. config: open_id (optional, shown only).
//
// UNVERIFIED (TikTok's developer docs were not readable from the build
// session): every field name above, the 6-a-minute init rate and the daily
// post cap (limits.ts "tiktok"), PULL_FROM_URL needing the image host's
// domain verified in the TikTok developer portal, and the 90-character title.

import { caps, type ChannelAdapter, type ChannelCtx, type ExosEvent, type OrgCredential, type SocialPost } from "../adapter.ts";
import type { WriteRule } from "../gatedHttp.ts";
import { createdId, newResult, write, type AdsResult } from "./adsCommon.ts";

export const TIKTOK_BASE = "https://open.tiktokapis.com";

/** Exactly the writes the TikTok adapter makes. */
export const TIKTOK_WRITES: WriteRule[] = [
  { method: "POST", path: /^\/v2\/post\/publish\/creator_info\/query\/$/ },
  { method: "POST", path: /^\/v2\/post\/publish\/content\/init\/$/ },
  { method: "POST", path: /^\/v2\/post\/publish\/video\/init\/$/ },
];

export const TIKTOK_SELF_ONLY_WARNING =
  "TikTok hasn't audited the Exos app yet, so every post would be private (SELF_ONLY: only you would see it).";

/** TikTok's answer shapes, with a planned_ id (adsCommon.ts convention). */
export const tiktokStandIn = (_m: unknown, path: string): unknown => {
  if (/creator_info/.test(path)) {
    return { data: { privacy_level_options: ["SELF_ONLY"], creator_username: null, dry_run: true }, error: { code: "ok" } };
  }
  return { data: { publish_id: "planned_publish" }, error: { code: "ok" }, dry_run: true };
};

export function tiktokHttp(creds: OrgCredential | null) {
  const openId = typeof creds?.config.open_id === "string" ? creds.config.open_id : "";
  return {
    channel: "tiktok",
    base: TIKTOK_BASE,
    writes: TIKTOK_WRITES,
    headers: creds?.secret ? { Authorization: `Bearer ${creds.secret}` } : {},
    secrets: [creds?.secret],
    standIn: tiktokStandIn,
    limits: { platform: "tiktok", scopeKey: openId.slice(0, 64) },
  };
}

/** The privacy level a post would use: SELF_ONLY unless the app is audited and the creator may post publicly. */
export function tiktokPrivacy(audited: boolean, options: unknown): string {
  const opts = Array.isArray(options) ? options.map(String) : [];
  return audited && opts.includes("PUBLIC_TO_EVERYONE") ? "PUBLIC_TO_EVERYONE" : "SELF_ONLY";
}

/** publishPost, given whether the Exos app is audited (EXOS_TIKTOK_APP_AUDITED=on). */
export function tiktokPublish(audited: boolean) {
  return async (ctx: ChannelCtx, _ev: ExosEvent, post: SocialPost): Promise<AdsResult> => {
    const res = newResult("tiktok", ctx);
    if (!res.connected) res.warnings.push("TikTok isn't connected: nothing would reach an account yet.");
    if (!audited) res.warnings.push(TIKTOK_SELF_ONLY_WARNING);
    if (!post.imageUrl && !post.videoUrl) { res.stopped = "TikTok needs an image or a video."; return res; }

    const info = await write(ctx, res, "POST", "/v2/post/publish/creator_info/query/", {}, { op: "post.creator_info" });
    const privacy = tiktokPrivacy(audited, info.body?.data?.privacy_level_options);
    const title = (post.title ?? "").slice(0, 90);
    const postInfo = { title, privacy_level: privacy, disable_comment: false, ...(post.videoUrl ? { disable_duet: false, disable_stitch: false } : { description: post.text.slice(0, 4000), auto_add_music: true }) };
    const r = post.videoUrl
      ? await write(ctx, res, "POST", "/v2/post/publish/video/init/", {
          post_info: postInfo, source_info: { source: "PULL_FROM_URL", video_url: post.videoUrl },
        }, { op: "post.init", usage: { metric: "inits", n: 1 } })
      : await write(ctx, res, "POST", "/v2/post/publish/content/init/", {
          post_info: postInfo,
          source_info: { source: "PULL_FROM_URL", photo_images: [post.imageUrl], photo_cover_index: 0 },
          post_mode: "DIRECT_POST",
          media_type: "PHOTO",
        }, { op: "post.init", usage: { metric: "inits", n: 1 } });
    const id = createdId(r, (b) => b?.data?.publish_id);
    if (id) res.ids.publish = id;
    else res.stopped = r.error ?? "not posted";
    return res;
  };
}

export const tiktokAdapter: ChannelAdapter = {
  id: "tiktok",
  label: "TikTok",
  status: "core",
  caps: caps({ role: "secondary", publishPost: true }),
  writes: TIKTOK_WRITES,
  publishPost: tiktokPublish(false),
};
