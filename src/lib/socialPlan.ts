// "Post / list this event" in the app (mig 20261121203000; docs/social.md
// "Posting and listing APIs"): each platform's status from
// exos_social_post_context, and the plan from exos-social. Everything is a
// DRY RUN: exos-social sends nothing to any platform, records what it would
// send in "What we'd send" (Org settings) and returns it here. Owner /
// manager (both check the role first).
//
// Pure helpers first (vitest), then the calls.

import { supabase } from './supabase';
import { PLATFORM_LABEL, SOCIAL_PLATFORMS, type PlatformPost, type SocialPlatform } from '../../supabase/functions/_shared/social/postKit.ts';
import { familyOf, VENDOR_APPS } from '../../supabase/functions/_shared/social/apps.ts';
import {
  TIKTOK_DISCLOSE, tiktokDeclaration, tiktokDiscloseLabel, type TikTokChoices, type TikTokCreatorView,
} from '../../supabase/functions/_shared/channels/adapters/tiktok.ts';

export { PLATFORM_LABEL, SOCIAL_PLATFORMS, TIKTOK_DISCLOSE, tiktokDeclaration, tiktokDiscloseLabel };
export type { PlatformPost, SocialPlatform, TikTokChoices, TikTokCreatorView };

/** The store provider each platform's credential lives under. */
export const PLATFORM_PROVIDER: Record<SocialPlatform, string> = {
  instagram: 'ig_publish',
  tiktok: 'tiktok_publish',
  meetup: 'meetup',
  linkedin: 'linkedin',
  google_business: 'google_business',
};

/** What the platform does with the event, in a few words. */
export const PLATFORM_ACTION: Record<SocialPlatform, string> = {
  instagram: 'Post to your Instagram professional account',
  tiktok: 'Photo post on your TikTok (Direct Post)',
  meetup: 'List it in your Meetup Pro group (a draft first; publishing it is a separate step)',
  linkedin: 'An event on your LinkedIn organization page',
  google_business: 'An event post on your venue\'s Google Business Profile',
};

export interface SocialContext {
  org: { id: string; name: string; venue_org: boolean };
  event: Record<string, unknown> & { id: string; name: string };
  connected: Record<string, boolean>;
  facts: {
    meetup_plan: string | null;
    meetup_pro_network: boolean;
    linkedin_org_page: boolean;
    gbp_verified_days: number | null;
  };
}

export interface SocialStepView { op: string; method: string; path: string; live: boolean; body: unknown; error?: string; warnings?: string[] }

export interface SocialPlatformPlan {
  platform: SocialPlatform;
  label: string;
  status: { connected: boolean; provider: string; dryRun: boolean; app: string | null; connect: 'built' | 'stub' };
  post: PlatformPost;
  result: {
    channel: string; connected: boolean; planned: boolean; ids: Record<string, string>; warnings: string[]; stopped?: string;
    steps: Array<{ op: string; method: string; path: string; planned: boolean; ok: boolean; error?: string }>;
    /** TikTok: what the creator may choose, and what the plan still needs from them. */
    tiktok?: TikTokCreatorView;
  };
  steps: SocialStepView[];
  /** The plan's confirm digest (null: stopped or nothing to send). A publish needs it. */
  confirm: string | null;
}

export interface SocialPlanResponse {
  dry_run: true;
  connected: Record<string, boolean>;
  platforms: SocialPlatformPlan[];
}

export type StatusWord = 'connected' | 'not_connected';
export const STATUS_TEXT: Record<StatusWord, string> = { connected: 'Connected', not_connected: 'Not connected' };

/** A platform's status line before (or without) a plan: connected or not, and always a dry run. */
export function platformStatus(ctx: SocialContext | null, p: SocialPlatform): { word: StatusWord; notes: string[] } {
  const connected = ctx?.connected?.[PLATFORM_PROVIDER[p]] === true;
  const notes: string[] = [];
  const f = ctx?.facts;
  if (p === 'tiktok') notes.push('Posts would be private (only you) until TikTok audits the Exos app.');
  if (p === 'meetup' && f) {
    if (!f.meetup_pro_network) notes.push('Meetup\'s API needs a group on a Meetup Pro network.');
    if (!f.meetup_plan || f.meetup_plan === 'starter') notes.push('Starter plan (or unknown): 10 attendees per event.');
  }
  if (p === 'linkedin' && f && !f.linkedin_org_page) notes.push('Needs a LinkedIn organization page (not a personal profile).');
  if (p === 'google_business' && ctx) {
    if (!ctx.org.venue_org) notes.push('For organizations that run their own venue.');
    if (f && (f.gbp_verified_days === null || f.gbp_verified_days < 60)) notes.push('Needs a Business Profile verified 60+ days ago.');
    notes.push('Connects on its own (Business Profile access only), separate from Google Ads.');
  }
  return { word: connected ? 'connected' : 'not_connected', notes };
}

/** The vendor app a platform connects through, and whether its connect flow exists yet. */
export function connectInfo(p: SocialPlatform): { app: string; built: boolean } {
  const fam = familyOf(PLATFORM_PROVIDER[p]);
  const a = fam ? VENDOR_APPS[fam] : null;
  return { app: a?.label ?? p, built: a?.connect === 'built' };
}

/** One line per platform plan. */
export function planSummary(p: SocialPlatformPlan): string {
  const n = p.steps.length;
  const stop = p.result.stopped ? ` Stopped: ${p.result.stopped}` : '';
  return `${n} request${n === 1 ? '' : 's'} planned; nothing sent.${stop}`;
}

// ---- calls -----------------------------------------------------------------

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

export async function loadSocialContext(orgId: string, eventId: string): Promise<SocialContext> {
  const { data, error } = await supabase.rpc('exos_social_post_context', { p_org_id: orgId, p_event_id: eventId });
  if (error) throw new Error(error.message?.replace(/^exos_\w+: /, '') || 'Could not load the platforms.');
  return data as SocialContext;
}

/** What the TikTok controls must still be set to before a post could be built (panel-side check). */
export function tiktokMissing(c: TikTokChoices): string[] {
  const out: string[] = [];
  if (!c.privacyLevel) out.push('who can see the post');
  if (!c.disclose) out.push('whether it promotes a brand');
  if (c.consent !== true) out.push("agreeing to TikTok's terms");
  return out;
}

export interface PlanOptions { tiktok?: TikTokChoices; meetupDraftId?: string | null }

async function socialCall(route: 'plan' | 'publish', body: Record<string, unknown>): Promise<{ ok: boolean; status: number; out: any }> {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  if (!url) throw new Error('Post planning isn\'t configured here.');
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  if (!jwt) throw new Error('Sign in first.');
  const anon = env.VITE_SUPABASE_ANON_KEY ?? '';
  const res = await fetch(`${url}/functions/v1/exos-social/${route}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${jwt}`, ...(anon ? { apikey: anon } : {}) },
    body: JSON.stringify(body),
  });
  return { ok: res.ok, status: res.status, out: await res.json().catch(() => null) };
}

export async function planSocialPosts(orgId: string, eventId: string, platforms: SocialPlatform[], opts: PlanOptions = {}): Promise<SocialPlanResponse> {
  const { ok, status, out } = await socialCall('plan', {
    org: orgId, event: eventId, platforms, tiktok: opts.tiktok ?? {}, ...(opts.meetupDraftId ? { meetupDraftId: opts.meetupDraftId } : {}),
  });
  if (!ok) throw new Error(typeof out?.error === 'string' ? out.error : `Planning failed (${status}).`);
  return out as SocialPlanResponse;
}

export interface PublishAnswer { published: boolean; reason?: string; message: string }

/** Publish one reviewed plan (its confirm). While publishing is switched off, the answer says so and nothing is sent. */
export async function publishSocialPost(orgId: string, eventId: string, platform: SocialPlatform, confirm: string, opts: PlanOptions = {}): Promise<PublishAnswer> {
  const { ok, status, out } = await socialCall('publish', {
    org: orgId, event: eventId, platform, confirm, tiktok: opts.tiktok ?? {}, ...(opts.meetupDraftId ? { meetupDraftId: opts.meetupDraftId } : {}),
  });
  if (ok && out?.published === true) return { published: true, message: 'Sent.' };
  if (status === 409) return { published: false, reason: out?.reason, message: typeof out?.error === 'string' ? out.error : 'Not sent.' };
  throw new Error(typeof out?.error === 'string' ? out.error : `Publishing failed (${status}).`);
}
