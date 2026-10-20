// The fan's profile page: the organizers they follow (exos_org_follows, RLS:
// own rows only) and the name shown on their account (auth user_metadata,
// mirrored to exos_profiles for organizers' attendee lists).
import { supabase } from './supabase';

export interface FollowedOrg {
  id: string;
  name: string;
  slug: string;
  followers: number;
}

/** Organizers the signed-in user follows, most recently followed first. */
export async function listFollowedOrgs(): Promise<FollowedOrg[]> {
  const { data, error } = await supabase
    .from('exos_org_follows')
    .select('org_id, created_at')
    .order('created_at', { ascending: false });
  if (error) throw error;
  const ids = (data ?? []).map((r: { org_id: string }) => r.org_id);
  if (ids.length === 0) return [];
  const { data: orgs, error: orgErr } = await supabase
    .from('exos_public_orgs')
    .select('id, name, slug, followers_count')
    .in('id', ids);
  if (orgErr) throw orgErr;
  const byId = new Map((orgs ?? []).map((o: any) => [o.id as string, o]));
  return ids.flatMap((id) => {
    const o = byId.get(id);
    return o ? [{ id, name: String(o.name ?? ''), slug: String(o.slug ?? ''), followers: Number(o.followers_count) || 0 }] : [];
  });
}

export const DISPLAY_NAME_MAX = 60;

/** A display name as stored: trimmed, inner whitespace collapsed, control
 *  characters dropped. Throws when nothing is left or it's too long. */
export function cleanDisplayName(raw: string): string {
  const name = raw.replace(/[\u0000-\u001f\u007f]/g, '').replace(/\s+/g, ' ').trim();
  if (!name) throw new Error('Enter a name.');
  if (name.length > DISPLAY_NAME_MAX) throw new Error(`Keep it under ${DISPLAY_NAME_MAX} characters.`);
  return name;
}

/** Save the account's display name (the session picks it up via USER_UPDATED). */
export async function updateDisplayName(uid: string, raw: string): Promise<string> {
  const name = cleanDisplayName(raw);
  const { error } = await supabase.auth.updateUser({ data: { display_name: name } });
  if (error) throw error;
  // Best-effort mirror; the auth record is the source.
  try {
    await supabase.from('exos_profiles').upsert({ id: uid, display_name: name }, { onConflict: 'id' });
  } catch {
    /* non-fatal */
  }
  return name;
}
