// One OAuth app per vendor family (social phase, mig 20261121203000;
// docs/social.md "Posting and listing APIs"): which Exos app each platform's
// connection goes through, the scopes it asks for, and which store providers
// it writes. CONNECT FLOWS ARE NOT BUILT (stubs): nothing here calls a vendor.
// Each flow, when built, follows exos-oauth-google's shape (state hash in
// exos_oauth_states, a finish token in the URL fragment, the same user
// confirming) and writes its provider through _exos_integration_put.
//
//   meta      the Meta app from the ads phase (ads_meta_api); Instagram is a
//             second product on it, not a second app
//   google    the existing Google OAuth client (GOOGLE_OAUTH_CLIENT_ID,
//             exos-oauth-google): Business Profile is one more scope
//   linkedin  one LinkedIn app
//   tiktok    one TikTok app (Login Kit + Content Posting)
//   meetup    one Meetup OAuth client
//
// Scope names: Meta's and Google's are the documented ones; LinkedIn's,
// TikTok's and Meetup's are unverified (their docs were not readable from
// the build session). Pure.

export type VendorFamily = "meta" | "google" | "linkedin" | "tiktok" | "meetup";

export interface VendorApp {
  family: VendorFamily;
  label: string;
  /** Env holding the app's id and secret (platform accounts stay in env; docs/security.md). */
  env: { id: string; secret: string };
  scopes: readonly string[];
  /** Store providers this app's connection writes. */
  providers: readonly string[];
  /** Built: an edge function runs it. Stub: documented, not built. */
  connect: "built" | "stub";
  /** Where the flow lives (or would). */
  flow: string;
  /** What the vendor must approve before anyone outside the test users can connect. */
  review: string;
  scopesVerified: boolean;
}

export const VENDOR_APPS: Readonly<Record<VendorFamily, VendorApp>> = {
  meta: {
    family: "meta", label: "Meta (Facebook, Instagram)",
    env: { id: "META_APP_ID", secret: "META_APP_SECRET" },
    scopes: ["ads_management", "business_management", "pages_show_list", "pages_read_engagement", "instagram_basic", "instagram_content_publish"],
    providers: ["ads_meta_api", "ig_publish"],
    connect: "stub", flow: "exos-oauth-meta (not built): Facebook Login for Business, then pick the Page and its Instagram professional account",
    review: "Meta App Review: Advanced Access for instagram_content_publish and ads_management, Business Verification",
    scopesVerified: true,
  },
  google: {
    family: "google", label: "Google",
    env: { id: "GOOGLE_OAUTH_CLIENT_ID", secret: "GOOGLE_OAUTH_CLIENT_SECRET" },
    scopes: ["https://www.googleapis.com/auth/datamanager", "https://www.googleapis.com/auth/business.manage"],
    providers: ["ads_google_ads", "google_business"],
    connect: "stub", flow: "exos-oauth-google (built for Google Ads); Business Profile adds business.manage to the same client and writes google_business (not built)",
    review: "the Business Profile API access request form (quota 0 until approved) and OAuth verification of the sensitive scopes",
    scopesVerified: true,
  },
  linkedin: {
    family: "linkedin", label: "LinkedIn",
    env: { id: "LINKEDIN_CLIENT_ID", secret: "LINKEDIN_CLIENT_SECRET" },
    scopes: ["rw_events", "r_organization_admin"],
    providers: ["linkedin"],
    connect: "stub", flow: "exos-oauth-linkedin (not built): LinkedIn OAuth 2 (3-legged), then pick the organization page",
    review: "LinkedIn's Event Management API program (Community Management / partner access)",
    scopesVerified: false,
  },
  tiktok: {
    family: "tiktok", label: "TikTok",
    env: { id: "TIKTOK_CLIENT_KEY", secret: "TIKTOK_CLIENT_SECRET" },
    scopes: ["user.info.basic", "video.publish"],
    providers: ["tiktok_publish"],
    connect: "stub", flow: "exos-oauth-tiktok (not built): TikTok Login Kit (web), PKCE",
    review: "TikTok app review for Content Posting (Direct Post), then the audit that lifts SELF_ONLY",
    scopesVerified: false,
  },
  meetup: {
    family: "meetup", label: "Meetup",
    env: { id: "MEETUP_CLIENT_ID", secret: "MEETUP_CLIENT_SECRET" },
    scopes: ["basic", "event_management"],
    providers: ["meetup"],
    connect: "stub", flow: "exos-oauth-meetup (not built): Meetup OAuth 2 for a Pro network organizer, then pick the group",
    review: "an approved Meetup OAuth client (Meetup Pro)",
    scopesVerified: false,
  },
};

/** The family whose app connects this store provider. */
export function familyOf(provider: string): VendorFamily | null {
  for (const a of Object.values(VENDOR_APPS)) if (a.providers.includes(provider)) return a.family;
  return null;
}

/** Is the app's id set in env (the first thing a connect flow would need)? Never reads the secret's value. */
export function appConfigured(family: VendorFamily, env: (k: string) => string | undefined | null): boolean {
  return (env(VENDOR_APPS[family].env.id) ?? "").trim() !== "";
}
