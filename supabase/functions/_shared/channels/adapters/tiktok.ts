// TikTok Content Posting API, Direct Post, on the channel core (social
// phase, mig 20261121203000; docs/social.md "Posting and listing APIs"):
// publishPost to the organizer's own TikTok account. DRY RUN ONLY: every
// write is on the allowlist below and goes through ctx.http (GatedHttp);
// exos-social pins the org's switch off and EXOS_TIKTOK_WRITES is off.
//
//   POST /v2/post/publish/creator_info/query/   {}  (a read TikTok makes a POST: the privacy
//                                                    levels the creator may use, the daily cap)
//   POST /v2/post/publish/content/init/         {post_info: {title, description, privacy_level,
//                                                 disable_comment, auto_add_music,
//                                                 brand_organic_toggle, brand_content_toggle},
//                                                source_info: {source: PULL_FROM_URL, photo_images,
//                                                 photo_cover_index}, post_mode: DIRECT_POST,
//                                                media_type: PHOTO}
//   POST /v2/post/publish/video/init/           {post_info: {title, privacy_level, ...},
//                                                source_info: {source: PULL_FROM_URL, video_url}}
//
// THE CREATOR DECIDES (TikTok's Content Sharing Guidelines for Direct Post;
// Applier review of #139): Exos never picks for them.
//   * privacy_level: one of creator_info's privacy_level_options, chosen by
//     the creator, with NO default. Until one is chosen the plan stops
//     (needs: privacy_level) and no init payload is built.
//   * comments / duets / stitches: off unless the creator turns each on, and
//     never on when creator_info says the creator disabled it in TikTok.
//     auto_add_music (photos) only when the creator asks for it.
//   * disclosure: the creator says whether the post promotes their own brand
//     (brand_organic_toggle, "Promotional content") or someone else's for
//     something in return (brand_content_toggle, "Paid partnership"), or
//     neither. No default. Branded content can't be private (SELF_ONLY).
//   * consent: TikTok's declaration (tiktokDeclaration) is shown by the post
//     button and the creator must accept it (needs: consent).
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

/** The creator's own choices for one post (the panel asks; nothing defaults on). */
export interface TikTokChoices {
  /** One of creator_info's privacy_level_options. No default. */
  privacyLevel?: string | null;
  allowComment?: boolean;
  allowDuet?: boolean;
  allowStitch?: boolean;
  /** Photo posts: let TikTok add music. Off unless chosen. */
  autoAddMusic?: boolean;
  /** none, your_brand (Promotional content) or branded_content (Paid partnership). No default. */
  disclose?: "none" | "your_brand" | "branded_content" | null;
  /** The creator accepted tiktokDeclaration(disclose). */
  consent?: boolean;
}

/** The creator's TikTok choices from the request: only known keys and types; anything else dropped. */
export function parseTikTokChoices(raw: unknown): TikTokChoices {
  const r = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const bool = (k: string) => (typeof r[k] === "boolean" ? r[k] as boolean : undefined);
  return {
    privacyLevel: typeof r.privacyLevel === "string" && /^[A-Z_]{1,40}$/.test(r.privacyLevel) ? r.privacyLevel : null,
    allowComment: bool("allowComment"), allowDuet: bool("allowDuet"), allowStitch: bool("allowStitch"),
    autoAddMusic: bool("autoAddMusic"),
    disclose: TIKTOK_DISCLOSE.includes(r.disclose as never) ? r.disclose as TikTokChoices["disclose"] : null,
    consent: r.consent === true,
  };
}

/** What the panel shows the creator, from creator_info (or the dry-run stand-in). */
export interface TikTokCreatorView {
  /** Levels the creator may choose now (SELF_ONLY only until the app is audited). */
  privacyOptions: string[];
  commentDisabled: boolean;
  duetDisabled: boolean;
  stitchDisabled: boolean;
  /** What the plan still needs from the creator before a post could be built. */
  needs: Array<"privacy_level" | "disclose" | "consent">;
}

export const TIKTOK_DISCLOSE = ["none", "your_brand", "branded_content"] as const;

/** TikTok's required declaration, shown next to the post button (Content Sharing Guidelines). */
export function tiktokDeclaration(disclose: TikTokChoices["disclose"]): string {
  return disclose === "branded_content"
    ? "By posting, you agree to TikTok's Branded Content Policy and Music Usage Confirmation."
    : "By posting, you agree to TikTok's Music Usage Confirmation.";
}

/** The label TikTok puts on a disclosed post. */
export function tiktokDiscloseLabel(disclose: TikTokChoices["disclose"]): string | null {
  return disclose === "your_brand" ? "Promotional content" : disclose === "branded_content" ? "Paid partnership" : null;
}

export const TIKTOK_SELF_ONLY_WARNING =
  "TikTok hasn't audited the Exos app yet, so every post would be private (SELF_ONLY: only you would see it).";

/** TikTok's answer shapes, with a planned_ id (adsCommon.ts convention). */
export const tiktokStandIn = (_m: unknown, path: string): unknown => {
  if (/creator_info/.test(path)) {
    return {
      data: { privacy_level_options: ["SELF_ONLY"], creator_username: null, comment_disabled: false, duet_disabled: false, stitch_disabled: false, dry_run: true },
      error: { code: "ok" },
    };
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

/** The privacy levels the creator may choose: creator_info's options, SELF_ONLY only until the app is audited. */
export function tiktokPrivacyOptions(audited: boolean, options: unknown): string[] {
  const opts = Array.isArray(options) ? options.map(String).filter((o) => /^[A-Z_]{1,40}$/.test(o)) : [];
  return audited ? opts : opts.filter((o) => o === "SELF_ONLY");
}

export type TikTokResult = AdsResult & { tiktok?: TikTokCreatorView };

/** publishPost, given whether the Exos app is audited (EXOS_TIKTOK_APP_AUDITED=on) and the creator's choices. */
export function tiktokPublish(audited: boolean, choices: TikTokChoices = {}) {
  return async (ctx: ChannelCtx, _ev: ExosEvent, post: SocialPost): Promise<TikTokResult> => {
    const res: TikTokResult = newResult("tiktok", ctx);
    if (!res.connected) res.warnings.push("TikTok isn't connected: nothing would reach an account yet.");
    if (!audited) res.warnings.push(TIKTOK_SELF_ONLY_WARNING);
    if (!post.imageUrl && !post.videoUrl) { res.stopped = "TikTok needs an image or a video."; return res; }

    const info = await write(ctx, res, "POST", "/v2/post/publish/creator_info/query/", {}, { op: "post.creator_info" });
    const d = info.body?.data ?? {};
    const view: TikTokCreatorView = {
      privacyOptions: tiktokPrivacyOptions(audited, d.privacy_level_options),
      commentDisabled: d.comment_disabled === true,
      duetDisabled: d.duet_disabled === true,
      stitchDisabled: d.stitch_disabled === true,
      needs: [],
    };
    res.tiktok = view;
    const privacy = typeof choices.privacyLevel === "string" ? choices.privacyLevel : null;
    const disclose = TIKTOK_DISCLOSE.includes(choices.disclose as never) ? choices.disclose! : null;
    if (!privacy) view.needs.push("privacy_level");
    if (!disclose) view.needs.push("disclose");
    if (choices.consent !== true) view.needs.push("consent");
    if (privacy && !view.privacyOptions.includes(privacy)) {
      res.stopped = `TikTok doesn't offer ${privacy} for this account right now; choose one of ${view.privacyOptions.join(", ") || "none"}.`;
      return res;
    }
    if (disclose === "branded_content" && privacy === "SELF_ONLY") {
      res.stopped = "Branded content can't be private on TikTok: choose who can see it, or change the disclosure.";
      return res;
    }
    if (view.needs.length) {
      res.stopped = `Choose on TikTok first: ${view.needs.map((n) => n === "privacy_level" ? "who can see the post" : n === "disclose" ? "whether it promotes a brand" : "agree to TikTok's terms").join(", ")}.`;
      return res;
    }

    const title = (post.title ?? "").slice(0, 90);
    const brand = { brand_organic_toggle: disclose === "your_brand", brand_content_toggle: disclose === "branded_content" };
    const postInfo = {
      title, privacy_level: privacy,
      disable_comment: view.commentDisabled || choices.allowComment !== true,
      ...(post.videoUrl
        ? { disable_duet: view.duetDisabled || choices.allowDuet !== true, disable_stitch: view.stitchDisabled || choices.allowStitch !== true }
        : { description: post.text.slice(0, 4000), auto_add_music: choices.autoAddMusic === true }),
      ...brand,
    };
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
