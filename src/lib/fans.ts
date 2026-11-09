// Fan profiles, tags and the org refund-request queue (mig 20261031120000,
// docs/fans.md). Profiles are built from orders and signups; consent is shown,
// never set here (the RPCs refuse it). Pure parsing / CSV up top, calls below.

import { supabase } from './supabase';
import type { CsvCell } from './csv';

export type EmailListStatus = 'subscribed' | 'pending' | 'unsubscribed' | 'none';
export type TaggableType = 'event' | 'fan' | 'artist';

export interface TagChip { id: string; name: string; color: string | null; taggedItemId?: string }

export interface FanRow {
  id: string;
  email: string;
  firstName: string | null;
  lastName: string | null;
  hasAccount: boolean;
  source: string;
  ordersCount: number;
  firstOrderAt: Date | null;
  lastOrderAt: Date | null;
  emailList: EmailListStatus;
  tags: TagChip[];
  createdAt: Date | null;
}

export interface FanMoney { currency: string; paidCents: number; refundedCents: number; orders: number }

export interface FanConsent {
  emailList: { status: EmailListStatus; since: Date | null; source: string | null; unsubscribedAt: Date | null };
  followsOrg: boolean;
  adConsent: 'granted' | 'denied' | null;
  marketingMailOptOut: boolean;
  sms: { status: 'subscribed' | 'opted_out' | 'none'; phoneHint: string | null; since: Date | null };
}

export interface FanDetail extends Omit<FanRow, 'ordersCount' | 'firstOrderAt' | 'lastOrderAt' | 'emailList'> {
  stats: { orders: number; tickets: number; firstOrderAt: Date | null; lastOrderAt: Date | null; money: FanMoney[] };
  consent: FanConsent;
  orders: { sessionId: string; eventId: string; eventName: string; startsAt: Date | null; quantity: number; amountCents: number; currency: string; status: string; createdAt: Date | null }[];
  signups: { formId: string; formName: string; createdAt: Date | null; emailRequested: boolean; confirmedAt: Date | null; smsRequested: boolean; smsConfirmedAt: Date | null }[];
}

export interface OrgTag { id: string; name: string; scope: TaggableType | null; color: string | null; canonicalTagId: string | null; itemsCount: number }

export interface QueueAsk {
  askId: string; ticketId: string; eventId: string; eventName: string; startsAt: Date | null; tierName: string;
  sessionId: string; buyerEmail: string; reason: string | null; amountCents: number; currency: string;
  status: 'open' | 'refunded' | 'declined' | 'withdrawn'; declineNote: string | null; createdAt: Date | null;
  ticketStatus: string; checkedIn: boolean;
}

const date = (v: unknown): Date | null => {
  if (!v) return null;
  const d = new Date(String(v));
  return Number.isNaN(d.getTime()) ? null : d;
};
const int = (v: unknown) => Math.max(0, Math.trunc(Number(v) || 0));
const listStatus = (v: unknown): EmailListStatus =>
  v === 'subscribed' || v === 'pending' || v === 'unsubscribed' ? v : 'none';
const taggable = (v: unknown): TaggableType | null => (v === 'event' || v === 'fan' || v === 'artist' ? v : null);

export function parseTagChips(v: unknown): TagChip[] {
  return (Array.isArray(v) ? v : []).map((t: any) => ({
    id: String(t?.id ?? ''), name: String(t?.name ?? ''), color: t?.color ?? null,
    ...(t?.tagged_item_id ? { taggedItemId: String(t.tagged_item_id) } : {}),
  }));
}

export function parseFanRow(r: any): FanRow {
  return {
    id: String(r?.id ?? ''),
    email: String(r?.email ?? ''),
    firstName: r?.first_name ?? null,
    lastName: r?.last_name ?? null,
    hasAccount: r?.has_account === true,
    source: String(r?.source ?? 'order'),
    ordersCount: int(r?.orders_count),
    firstOrderAt: date(r?.first_order_at),
    lastOrderAt: date(r?.last_order_at),
    emailList: listStatus(r?.email_list),
    tags: parseTagChips(r?.tags),
    createdAt: date(r?.created_at),
  };
}

export function parseFanDetail(r: any): FanDetail {
  const c = r?.consent ?? {};
  const sms = c.sms ?? {};
  return {
    id: String(r?.id ?? ''),
    email: String(r?.email ?? ''),
    firstName: r?.first_name ?? null,
    lastName: r?.last_name ?? null,
    hasAccount: r?.has_account === true,
    source: String(r?.source ?? 'order'),
    tags: parseTagChips(r?.tags),
    createdAt: date(r?.created_at),
    stats: {
      orders: int(r?.stats?.orders),
      tickets: int(r?.stats?.tickets),
      firstOrderAt: date(r?.stats?.first_order_at),
      lastOrderAt: date(r?.stats?.last_order_at),
      money: (Array.isArray(r?.stats?.money) ? r.stats.money : []).map((m: any) => ({
        currency: String(m?.currency ?? 'usd'), paidCents: int(m?.paid_cents), refundedCents: int(m?.refunded_cents), orders: int(m?.orders),
      })),
    },
    consent: {
      emailList: {
        status: listStatus(c.email_list?.status), since: date(c.email_list?.since),
        source: c.email_list?.source ?? null, unsubscribedAt: date(c.email_list?.unsubscribed_at),
      },
      followsOrg: c.follows_org === true,
      adConsent: c.ad_consent === 'granted' || c.ad_consent === 'denied' ? c.ad_consent : null,
      marketingMailOptOut: c.marketing_mail_opt_out === true,
      sms: {
        status: sms.status === 'subscribed' || sms.status === 'opted_out' ? sms.status : 'none',
        phoneHint: sms.phone_hint ?? null, since: date(sms.since),
      },
    },
    orders: (Array.isArray(r?.orders) ? r.orders : []).map((o: any) => ({
      sessionId: String(o?.session_id ?? ''), eventId: String(o?.event_id ?? ''), eventName: String(o?.event_name ?? 'Event'),
      startsAt: date(o?.starts_at), quantity: int(o?.quantity), amountCents: int(o?.amount_cents),
      currency: String(o?.currency ?? 'usd'), status: String(o?.status ?? ''), createdAt: date(o?.created_at),
    })),
    signups: (Array.isArray(r?.signups) ? r.signups : []).map((s: any) => ({
      formId: String(s?.form_id ?? ''), formName: String(s?.form_name ?? ''), createdAt: date(s?.created_at),
      emailRequested: s?.email_requested === true, confirmedAt: date(s?.confirmed_at),
      smsRequested: s?.sms_requested === true, smsConfirmedAt: date(s?.sms_confirmed_at),
    })),
  };
}

export function parseOrgTag(r: any): OrgTag {
  return {
    id: String(r?.id ?? ''), name: String(r?.name ?? ''), scope: taggable(r?.scope), color: r?.color ?? null,
    canonicalTagId: r?.canonical_tag_id ?? null, itemsCount: int(r?.items_count),
  };
}

export function parseQueueAsk(r: any): QueueAsk {
  const s = r?.status;
  return {
    askId: String(r?.id ?? ''), ticketId: String(r?.ticket_id ?? ''), eventId: String(r?.event_id ?? ''),
    eventName: String(r?.event_name ?? 'Event'), startsAt: date(r?.starts_at), tierName: String(r?.tier_name ?? ''),
    sessionId: String(r?.session_id ?? ''), buyerEmail: String(r?.buyer_email ?? ''), reason: r?.reason ?? null,
    amountCents: int(r?.amount_cents), currency: String(r?.currency ?? 'usd'),
    status: s === 'refunded' || s === 'declined' || s === 'withdrawn' ? s : 'open',
    declineNote: r?.decline_note ?? null, createdAt: date(r?.created_at),
    ticketStatus: String(r?.ticket_status ?? ''), checkedIn: r?.checked_in === true,
  };
}

/** Staff-facing words for each consent state (never an action). */
export const EMAIL_LIST_LABEL: Record<EmailListStatus, string> = {
  subscribed: 'On your email list',
  pending: 'Signed up, confirm mail not clicked yet',
  unsubscribed: 'Unsubscribed',
  none: 'Not on your email list',
};

/** "Dana Lee", else the email. */
export function fanName(f: Pick<FanRow, 'firstName' | 'lastName' | 'email'>): string {
  const n = [f.firstName, f.lastName].filter(Boolean).join(' ').trim();
  return n || f.email;
}

// ── export ─────────────────────────────────────────────────────────────────

export const FANS_CSV_HEADER = [
  'email', 'first_name', 'last_name', 'has_account', 'source', 'orders', 'first_order_at', 'last_order_at',
  'email_list', 'tags', 'created_at',
];

/** Rows of exos_org_fans_export as CSV cells (csv.ts quotes and defuses formulas). */
export function fansCsvRows(rows: unknown[]): CsvCell[][] {
  return (Array.isArray(rows) ? rows : []).map((r: any) => [
    String(r?.email ?? ''), r?.first_name ?? '', r?.last_name ?? '', r?.has_account === true ? 'yes' : 'no',
    String(r?.source ?? ''), int(r?.orders_count), r?.first_order_at ?? '', r?.last_order_at ?? '',
    listStatus(r?.email_list), (Array.isArray(r?.tags) ? r.tags : []).map(String).join('; '), r?.created_at ?? '',
  ]);
}

// ── calls ──────────────────────────────────────────────────────────────────

const msg = (e: { message?: string }) => new Error((e.message ?? 'Failed.').replace(/^exos_\w+: /, ''));

export async function listFans(orgId: string, opts: { search?: string; tagIds?: string[]; sort?: string; limit?: number; offset?: number } = {}) {
  const { data, error } = await supabase.rpc('exos_org_fans', {
    p_org_id: orgId, p_search: opts.search?.trim() || null, p_tag_ids: opts.tagIds?.length ? opts.tagIds : null,
    p_sort: opts.sort ?? 'created_at desc', p_limit: opts.limit ?? 50, p_offset: opts.offset ?? 0,
  });
  if (error) throw msg(error);
  return { total: int(data?.total), rows: (Array.isArray(data?.rows) ? data.rows : []).map(parseFanRow) };
}

export async function getFan(orgId: string, fanId: string): Promise<FanDetail> {
  const { data, error } = await supabase.rpc('exos_org_fan', { p_org_id: orgId, p_fan_id: fanId });
  if (error) throw msg(error);
  return parseFanDetail(data);
}

export async function saveFan(orgId: string, fanId: string | null, fields: { email?: string; first_name?: string | null; last_name?: string | null }) {
  const { data, error } = await supabase.rpc('exos_org_fan_save', { p_org_id: orgId, p_fan_id: fanId, p_fields: fields });
  if (error) throw msg(error);
  return parseFanDetail(data);
}

export async function discardFan(orgId: string, fanId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_org_fan_discard', { p_org_id: orgId, p_fan_id: fanId });
  if (error) throw msg(error);
}

export async function exportFans(orgId: string, search?: string, tagIds?: string[]): Promise<{ count: number; rows: unknown[] }> {
  const { data, error } = await supabase.rpc('exos_org_fans_export', {
    p_org_id: orgId, p_search: search?.trim() || null, p_tag_ids: tagIds?.length ? tagIds : null,
  });
  if (error) throw msg(error);
  return { count: int(data?.count), rows: Array.isArray(data?.rows) ? data.rows : [] };
}

export async function listTags(orgId: string, scope?: TaggableType): Promise<OrgTag[]> {
  const { data, error } = await supabase.rpc('exos_org_tags', { p_org_id: orgId, p_scope: scope ?? null });
  if (error) throw msg(error);
  return (Array.isArray(data) ? data : []).map(parseOrgTag);
}

export async function saveTag(orgId: string, tagId: string | null, fields: { name?: string; scope?: TaggableType | null; color?: string | null }) {
  const { data, error } = await supabase.rpc('exos_tag_save', { p_org_id: orgId, p_tag_id: tagId, p_fields: fields });
  if (error) throw msg(error);
  return parseOrgTag(data);
}

export async function deleteTag(orgId: string, tagId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_tag_delete', { p_org_id: orgId, p_tag_id: tagId });
  if (error) throw msg(error);
}

export async function applyTag(orgId: string, type: TaggableType, id: string, tag: { id?: string; name?: string }) {
  const { data, error } = await supabase.rpc('exos_tag_apply', {
    p_org_id: orgId, p_tag_id: tag.id ?? null, p_tag_name: tag.name ?? null, p_type: type, p_id: id,
  });
  if (error) throw msg(error);
  return { taggedItemId: String(data?.id ?? ''), tagId: String(data?.tag_id ?? '') };
}

export async function removeTag(orgId: string, taggedItemId: string): Promise<void> {
  const { error } = await supabase.rpc('exos_tag_remove', { p_org_id: orgId, p_tagged_item_id: taggedItemId });
  if (error) throw msg(error);
}

/** Tags on these records, by record id. */
export async function tagsOn(orgId: string, type: TaggableType, ids: string[]): Promise<Record<string, TagChip[]>> {
  if (ids.length === 0) return {};
  const { data, error } = await supabase.rpc('exos_org_tagged', { p_org_id: orgId, p_type: type, p_ids: ids });
  if (error) throw msg(error);
  const out: Record<string, TagChip[]> = {};
  for (const r of (Array.isArray(data) ? data : []) as any[]) {
    (out[r.taggable_id] ??= []).push({ id: String(r.tag_id), name: String(r.name), color: r.color ?? null, taggedItemId: String(r.tagged_item_id) });
  }
  return out;
}

/** Ids of this type carrying ALL these tags. */
export async function idsWithTags(orgId: string, type: TaggableType, tagIds: string[]): Promise<Set<string> | null> {
  if (tagIds.length === 0) return null;
  const { data, error } = await supabase.rpc('exos_org_tag_filter', { p_org_id: orgId, p_type: type, p_tag_ids: tagIds });
  if (error) throw msg(error);
  return new Set((Array.isArray(data) ? data : []).map(String));
}

export async function listRefundQueue(orgId: string, status: QueueAsk['status'] | null = 'open', offset = 0) {
  const { data, error } = await supabase.rpc('exos_org_refund_asks', { p_org_id: orgId, p_status: status, p_limit: 50, p_offset: offset });
  if (error) throw msg(error);
  return { total: int(data?.total), rows: (Array.isArray(data?.rows) ? data.rows : []).map(parseQueueAsk) };
}

export interface MyAsk {
  askId: string; ticketId: string; eventId: string; eventName: string; startsAt: Date | null; tierName: string;
  amountCents: number; currency: string; status: QueueAsk['status']; declineNote: string | null; createdAt: Date | null;
}

export function parseMyAskRow(r: any): MyAsk {
  const s = r?.status;
  return {
    askId: String(r?.ask_id ?? ''), ticketId: String(r?.ticket_id ?? ''), eventId: String(r?.event_id ?? ''),
    eventName: String(r?.event_name ?? 'Event'), startsAt: date(r?.starts_at), tierName: String(r?.tier_name ?? ''),
    amountCents: int(r?.amount_cents), currency: String(r?.currency ?? 'usd'),
    status: s === 'refunded' || s === 'declined' || s === 'withdrawn' ? s : 'open',
    declineNote: r?.decline_note ?? null, createdAt: date(r?.created_at),
  };
}

export async function listMyRefundAsks(): Promise<MyAsk[]> {
  const { data, error } = await supabase.rpc('exos_my_refund_asks_all');
  if (error) throw msg(error);
  return (Array.isArray(data) ? data : []).map(parseMyAskRow);
}
