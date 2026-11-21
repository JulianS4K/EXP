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
//             exos-oauth-google)
//   linkedin  one LinkedIn app
//   tiktok    one TikTok app (Login Kit + Content Posting)
//   meetup    one Meetup OAuth client
//
// ONE GRANT PER PRODUCT (Applier review of #139). An app's products never
// share a grant: each connection asks only for its own product's scopes and
// writes only its own store provider, so connecting Instagram publishing
// doesn't grant ads management, and connecting Google Ads never carries
// Business Profile management. Google Business Profile is its own
// authorization request on the same client (business.manage alone, asked for
// when the organizer connects Business Profile, without
// include_granted_scopes, so neither token is widened), with its own refresh
// token in google_business. Nothing reads another product's secret.
//
// Scope names: Meta's and Google's are the documented ones; LinkedIn's,
// TikTok's and Meetup's are unverified (their docs were not readable from
// the build session). Pure.

export type VendorFamily = "meta" | "google" | "linkedin" | "tiktok" | "meetup";

/** One product on a vendor app: its own grant, its own scopes, its own store provider. */
export interface VendorProduct {
  /** The store provider this product's connection writes (and the only one it reads). */
  provider: string;
  label: string;
  /** Exactly the scopes this product's grant asks for. */
  scopes: readonly string[];
}

export interface VendorApp {
  family: VendorFamily;
  label: string;
  /** Env holding the app's id and secret (platform accounts stay in env; docs/security.md). */
  env: { id: string; secret: string };
  /** One grant each; never combined into one consent screen. */
  products: readonly VendorProduct[];
  /** Store providers this app's connections write (one per product). */
  providers: readonly string[];
  /** Built: an edge function runs it. Stub: documented, not built. */
  connect: "built" | "stub";
  /** Where the flow lives (or would). */
  flow: string;
  /** What the vendor must approve before anyone outside the test users can connect. */
  review: string;
  scopesVerified: boolean;
}

const app = (a: Omit<VendorApp, "providers">): VendorApp => ({ ...a, providers: a.products.map((p) => p.provider) });

export const VENDOR_APPS: Readonly<Record<VendorFamily, VendorApp>> = {
  meta: app({
    family: "meta", label: "Meta (Facebook, Instagram)",
    env: { id: "META_APP_ID", secret: "META_APP_SECRET" },
    products: [
      { provider: "ads_meta_api", label: "Meta ads", scopes: ["ads_management", "ads_read", "business_management"] },
      { provider: "ig_publish", label: "Instagram posts", scopes: ["instagram_basic", "instagram_content_publish", "pages_show_list", "pages_read_engagement"] },
    ],
    connect: "stub", flow: "exos-oauth-meta (not built): Facebook Login for Business, one login per product; Instagram picks the Page and its Instagram professional account",
    review: "Meta App Review: Advanced Access for instagram_content_publish (Instagram) and ads_management (ads), Business Verification",
    scopesVerified: true,
  }),
  google: app({
    family: "google", label: "Google",
    env: { id: "GOOGLE_OAUTH_CLIENT_ID", secret: "GOOGLE_OAUTH_CLIENT_SECRET" },
    products: [
      { provider: "ads_google_ads", label: "Google Ads", scopes: ["https://www.googleapis.com/auth/datamanager"] },
      { provider: "google_business", label: "Google Business Profile", scopes: ["https://www.googleapis.com/auth/business.manage"] },
    ],
    connect: "stub", flow: "exos-oauth-google (built for Google Ads); Business Profile is its own sign-in on the same client (business.manage only, its own refresh token in google_business; not built)",
    review: "the Business Profile API access request form (quota 0 until approved) and OAuth verification of the sensitive scopes",
    scopesVerified: true,
  }),
  linkedin: app({
    family: "linkedin", label: "LinkedIn",
    env: { id: "LINKEDIN_CLIENT_ID", secret: "LINKEDIN_CLIENT_SECRET" },
    products: [{ provider: "linkedin", label: "LinkedIn events", scopes: ["rw_events", "r_organization_admin"] }],
    connect: "stub", flow: "exos-oauth-linkedin (not built): LinkedIn OAuth 2 (3-legged), then pick the organization page",
    review: "LinkedIn's Event Management API program (Community Management / partner access)",
    scopesVerified: false,
  }),
  tiktok: app({
    family: "tiktok", label: "TikTok",
    env: { id: "TIKTOK_CLIENT_KEY", secret: "TIKTOK_CLIENT_SECRET" },
    products: [{ provider: "tiktok_publish", label: "TikTok posts", scopes: ["user.info.basic", "video.publish"] }],
    connect: "stub", flow: "exos-oauth-tiktok (not built): TikTok Login Kit (web), PKCE",
    review: "TikTok app review for Content Posting (Direct Post), then the audit that lifts SELF_ONLY",
    scopesVerified: false,
  }),
  meetup: app({
    family: "meetup", label: "Meetup",
    env: { id: "MEETUP_CLIENT_ID", secret: "MEETUP_CLIENT_SECRET" },
    products: [{ provider: "meetup", label: "Meetup events", scopes: ["basic", "event_management"] }],
    connect: "stub", flow: "exos-oauth-meetup (not built): Meetup OAuth 2 for a Pro network organizer, then pick the group",
    review: "an approved Meetup OAuth client (Meetup Pro)",
    scopesVerified: false,
  }),
};

/** The scopes one store provider's grant asks for (only its own product's), or [] when unknown. */
export function scopesFor(provider: string): readonly string[] {
  for (const a of Object.values(VENDOR_APPS)) for (const p of a.products) if (p.provider === provider) return p.scopes;
  return [];
}

/** The family whose app connects this store provider. */
export function familyOf(provider: string): VendorFamily | null {
  for (const a of Object.values(VENDOR_APPS)) if (a.providers.includes(provider)) return a.family;
  return null;
}

/** Is the app's id set in env (the first thing a connect flow would need)? Never reads the secret's value. */
export function appConfigured(family: VendorFamily, env: (k: string) => string | undefined | null): boolean {
  return (env(VENDOR_APPS[family].env.id) ?? "").trim() !== "";
}
