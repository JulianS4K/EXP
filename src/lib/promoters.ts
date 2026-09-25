// Promoters: an organizer's street team (mig 20260924233000). Each has a code
// (what ?promoter= carries, so every free and paid ticket through their links
// is credited) and a private kit link (/p/:token) showing their own sales.

import { supabase } from './supabase';
import type { SocialHandles } from './socialTags';

export interface Promoter {
  id: string;
  orgId: string;
  code: string;
  name: string;
  email: string | null;
  status: 'active' | 'paused';
  kitToken: string;
  socials: SocialHandles;
  allowTagging: boolean;
}

export interface PromoterStat {
  promoterId: string;
  code: string;
  name: string;
  status: 'active' | 'paused';
  tickets: number;
  gross: number;
}

export interface PromoterKitData {
  promoter: { name: string; code: string; socials?: SocialHandles; allow_tagging?: boolean };
  org: { id: string; name: string; slug: string };
  events: { event_id: string; name: string; starts_at: string | null; tickets: number; gross: number; currency: string | null }[];
}

export { codeFromName } from './shareLinks';

export async function listPromoters(orgId: string): Promise<Promoter[]> {
  const { data, error } = await supabase
    .from('exos_promoters')
    .select('id, org_id, code, name, email, status, kit_token, socials, allow_tagging')
    .eq('org_id', orgId)
    .order('created_at', { ascending: true });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id, orgId: r.org_id, code: r.code, name: r.name, email: r.email, status: r.status, kitToken: r.kit_token,
    socials: r.socials ?? {}, allowTagging: r.allow_tagging !== false,
  }));
}

export async function upsertPromoter(
  orgId: string,
  input: { code: string; name: string; email?: string; socials?: SocialHandles; allowTagging?: boolean },
): Promise<string> {
  const { data, error } = await supabase.rpc('exos_upsert_promoter', {
    p_org_id: orgId, p_code: input.code, p_name: input.name, p_email: input.email || null,
    // Only sent when set, so leaving them out keeps what's stored.
    ...(input.socials ? { p_socials: input.socials } : {}),
    ...(input.allowTagging !== undefined ? { p_allow_tagging: input.allowTagging } : {}),
  });
  if (error) throw error;
  return data as string;
}

export async function setPromoterStatus(promoterId: string, status: 'active' | 'paused', rotateToken = false): Promise<void> {
  const { error } = await supabase.rpc('exos_set_promoter_status', {
    p_promoter_id: promoterId, p_status: status, p_rotate_token: rotateToken,
  });
  if (error) throw error;
}

export async function orgPromoterStats(orgId: string, eventId?: string): Promise<PromoterStat[]> {
  const { data, error } = await supabase.rpc('exos_org_promoter_stats', { p_org_id: orgId, p_event_id: eventId ?? null });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    promoterId: r.promoter_id, code: r.code, name: r.name, status: r.status,
    tickets: Number(r.tickets) || 0, gross: Number(r.gross) || 0,
  }));
}

export async function getPromoterKit(token: string): Promise<PromoterKitData | null> {
  const { data, error } = await supabase.rpc('exos_promoter_kit', { p_token: token });
  if (error || !data) return null;
  return data as PromoterKitData;
}

export interface PublicPromoterCard {
  /** socials is empty unless the promoter allows tagging. */
  promoter: { name: string; code: string; socials?: SocialHandles };
  org: { id: string; name: string; slug: string };
}

// The link-in-bio page's header: the promoter's display name, active only.
export async function getPublicPromoter(orgSlug: string, code: string): Promise<PublicPromoterCard | null> {
  const { data, error } = await supabase.rpc('exos_public_promoter', { p_org_slug: orgSlug, p_code: code });
  if (error || !data) return null;
  return data as PublicPromoterCard;
}

// The promoter sets their own handles and tagging switch from their kit page.
export async function setPromoterSocials(token: string, socials: SocialHandles, allowTagging: boolean): Promise<void> {
  const { error } = await supabase.rpc('exos_promoter_set_socials', {
    p_token: token, p_socials: socials, p_allow_tagging: allowTagging,
  });
  if (error) throw error;
}

// One public link a promoter can put in their Instagram / TikTok bio.
export function linkInBioPath(orgSlug: string, code: string): string {
  return `l/${encodeURIComponent(orgSlug)}/${encodeURIComponent(code)}`;
}
