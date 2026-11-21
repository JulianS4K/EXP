// Followers (mig 20261111110000, docs/fans.md "Followers"): the "new event"
// mail's counts on the event editor, the follower list + CSV on the Fans page,
// and the one-click unfollow page. Organizers get counts, and rows only for
// followers who are already their fans: names and fan status, never an
// address (mig 20261112100000; addresses come only from the logged CSV
// export). Pure up top, calls below.

import { supabase } from './supabase';
import type { CsvCell } from './csv';

export type NoticeReason = 'cancelled' | 'hidden' | 'started' | 'series_date' | null;

export type FollowerNotice =
  | { state: 'before'; followers: number; eligible: boolean; reason: NoticeReason; willNotify: number }
  | { state: 'after'; followers: number; eligible: boolean; reason: NoticeReason; notified: number; waiting: number; notNotified: number };

const int = (v: unknown) => {
  const x = typeof v === 'string' ? Number(v) : v;
  return typeof x === 'number' && Number.isFinite(x) ? Math.max(0, Math.floor(x)) : 0;
};
const plural = (k: number, one: string, many = `${one}s`) => `${k} ${k === 1 ? one : many}`;

const REASONS: Record<Exclude<NoticeReason, null>, string> = {
  cancelled: 'the event is cancelled',
  hidden: 'the event is hidden from search and listings',
  started: 'the event has already started',
  series_date: 'followers hear about a series from its first date',
};

export function parseNotice(data: unknown): FollowerNotice | null {
  const d = data as any;
  if (!d || (d.state !== 'before' && d.state !== 'after')) return null;
  const reason = (Object.keys(REASONS) as NoticeReason[]).includes(d.reason) ? (d.reason as NoticeReason) : null;
  const base = { followers: int(d.followers), eligible: d.eligible === true, reason };
  return d.state === 'before'
    ? { state: 'before', ...base, willNotify: int(d.will_notify) }
    : { state: 'after', ...base, notified: int(d.notified), waiting: int(d.waiting), notNotified: int(d.not_notified) };
}

/** The one line the event editor shows, or null when the org has no followers. */
export function noticeLine(n: FollowerNotice | null): string | null {
  if (!n || n.followers === 0) return null;
  if (n.state === 'before') {
    if (!n.eligible) return `Followers won't be emailed: ${REASONS[n.reason ?? 'hidden']}.`;
    if (n.willNotify === 0) return `None of your ${plural(n.followers, 'follower')} can be emailed right now.`;
    return `${plural(n.willNotify, 'follower')} will be notified when you publish.`;
  }
  // The publish only records who to tell; the follower digest sends the
  // emails in batches (mig 20261112100000), so right after publishing they
  // are all still waiting.
  const batches = 'sent in batches, at most one email a day per follower';
  if (n.waiting > 0 && n.notified === 0) return `${plural(n.waiting, 'follower')} waiting for the new-event email (${batches}).`;
  const parts = [`Notified ${plural(n.notified, 'follower')}`];
  if (n.waiting > 0) parts.push(`${n.waiting} more waiting (${batches})`);
  return `${parts.join(', ')}.`;
}

/** A follower on the list: no address (the export has those). */
export interface FollowerRow {
  fanId: string;
  firstName: string | null;
  lastName: string | null;
  followedAt: Date | null;
  emailList: 'subscribed' | 'unsubscribed' | 'none';
  getsNewEventMail: boolean;
}

export interface OrgFollowers {
  total: number;
  /** Followers shown as rows: they have a fan profile with the org. */
  listed: number;
  /** Followers the org sees only as a count. */
  notListed: number;
  getsNewEventMail: number;
  rows: FollowerRow[];
}

const str = (v: unknown) => (typeof v === 'string' && v.trim() !== '' ? v : null);
const date = (v: unknown) => {
  const t = typeof v === 'string' ? Date.parse(v) : NaN;
  return Number.isNaN(t) ? null : new Date(t);
};
const list = (v: unknown): FollowerRow['emailList'] => (v === 'subscribed' || v === 'unsubscribed' ? v : 'none');

export function parseFollowerRow(r: any): FollowerRow | null {
  const fanId = str(r?.fan_id);
  if (!fanId) return null;
  return {
    fanId, firstName: str(r?.first_name), lastName: str(r?.last_name),
    followedAt: date(r?.followed_at), emailList: list(r?.email_list), getsNewEventMail: r?.gets_new_event_mail === true,
  };
}

export function parseOrgFollowers(data: unknown): OrgFollowers {
  const d = (data ?? {}) as any;
  return {
    total: int(d.total), listed: int(d.listed), notListed: int(d.not_listed), getsNewEventMail: int(d.gets_new_event_mail),
    rows: (Array.isArray(d.rows) ? d.rows : []).map(parseFollowerRow).filter((r: FollowerRow | null): r is FollowerRow => !!r),
  };
}

export const FOLLOWERS_CSV_HEADER = ['email', 'first_name', 'last_name', 'followed_at', 'email_list', 'gets_new_event_email'];

/** A row's display name, or null when the fan gave none. */
export function followerName(r: Pick<FollowerRow, 'firstName' | 'lastName'>): string | null {
  return [r.firstName, r.lastName].filter(Boolean).join(' ') || null;
}

/** Rows of exos_org_followers_export as CSV cells (csv.ts quotes and defuses formulas). */
export function followersCsvRows(rows: unknown[]): CsvCell[][] {
  return (Array.isArray(rows) ? rows : []).map((r: any) => [
    String(r?.email ?? ''), r?.first_name ?? '', r?.last_name ?? '', r?.followed_at ?? '', list(r?.email_list),
    r?.gets_new_event_mail === true ? 'yes' : 'no',
  ]);
}

/** A 64-hex unfollow token from the mail link, or null. */
export function unfollowToken(raw: string | null | undefined): string | null {
  const t = (raw ?? '').trim().toLowerCase();
  return /^[0-9a-f]{64}$/.test(t) ? t : null;
}

// ── calls ──────────────────────────────────────────────────────────────────

const msg = (e: { message?: string }) => new Error((e.message ?? 'Failed.').replace(/^exos_\w+: /, ''));

export async function getFollowerNotice(eventId: string): Promise<FollowerNotice | null> {
  const { data, error } = await supabase.rpc('exos_event_follower_notice', { p_event_id: eventId });
  if (error) throw msg(error);
  return parseNotice(data);
}

export async function listOrgFollowers(orgId: string, limit = 100, offset = 0): Promise<OrgFollowers> {
  const { data, error } = await supabase.rpc('exos_org_followers', { p_org_id: orgId, p_limit: limit, p_offset: offset });
  if (error) throw msg(error);
  return parseOrgFollowers(data);
}

export async function exportOrgFollowers(orgId: string): Promise<{ count: number; rows: unknown[] }> {
  const { data, error } = await supabase.rpc('exos_org_followers_export', { p_org_id: orgId });
  if (error) throw msg(error);
  return { count: int((data as any)?.count), rows: Array.isArray((data as any)?.rows) ? (data as any).rows : [] };
}

/** Unfollow from the mail link. ok false: the link isn't valid. */
export async function unfollowByToken(token: string): Promise<{ ok: boolean; orgName: string | null }> {
  const { data, error } = await supabase.rpc('exos_unfollow_by_token', { p_token: token });
  if (error) throw msg(error);
  return { ok: (data as any)?.ok === true, orgName: str((data as any)?.org_name) };
}
