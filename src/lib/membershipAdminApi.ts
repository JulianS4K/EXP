// Dashboard calls for /orgs/:orgId/memberships (mig 20261102100000): the same
// RPCs the partner API's writes run (exos_api_commerce_write calls them), so
// the dashboard and the API can't drift. Pure rules: ./membershipAdmin.

import { supabase } from './supabase';
import type { ProductAction, ProductStatus } from './membershipAdmin';

export interface AdminProduct {
  id: string;
  name: string;
  description: string | null;
  image_url: string | null;
  price_cents: number;
  currency: string;
  billing: 'month' | 'year' | 'once';
  duration_days: number;
  discount_percent: number | string;
  presale: boolean;
  free_tickets_per_period: number;
  guest_allowance: number;
  household_seats: number;
  giftable: boolean;
  status: ProductStatus;
  active: boolean;
  archived_at: string | null;
  created_at: string;
  updated_at: string;
  members_count: number;
}

export interface AdminMembership {
  id: string;
  product_id: string | null;
  product_name: string;
  billing: string;
  holder_email: string | null;
  member_name: string | null;
  has_account: boolean;
  status: string;
  effective_status: string;
  current_period_start: string | null;
  current_period_end: string | null;
  cancel_at_period_end: boolean;
  source: string;
  ended_reason: string | null;
  stripe_billed: boolean;
  staff_notes: string | null;
  created_at: string;
}

export interface ImportedAttendee {
  id: string;
  event_id: string;
  event_name: string;
  starts_at: string | null;
  list_name: string;
  guest_name: string;
  email: string | null;
  phone: string | null;
  plus_ones: number;
  arrived: number;
  note: string | null;
  code: string | null;
  ticket_label: string | null;
  source: string | null;
  synced: boolean;
  voided: boolean;
  created_at: string;
}

export interface ServerPage<T> {
  total: number;
  rows: T[];
}

async function call<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data as T;
}

export const listAdminProducts = (orgId: string) =>
  call<AdminProduct[]>('exos_org_membership_products', { p_org_id: orgId });

export const saveAdminProduct = (orgId: string, id: string | null, fields: Record<string, unknown>) =>
  call<AdminProduct>('exos_membership_product_save', { p_org_id: orgId, p_id: id, p_fields: fields });

export const transitionProduct = (id: string, action: ProductAction) =>
  call<AdminProduct>('exos_membership_product_transition', { p_id: id, p_action: action });

export const listAdminMemberships = (orgId: string, q: {
  status?: string; productId?: string; search?: string; sort: string; desc: boolean; limit: number; offset: number;
}) => call<ServerPage<AdminMembership>>('exos_org_memberships_page', {
  p_org_id: orgId, p_status: q.status || null, p_product_id: q.productId || null, p_search: q.search || null,
  p_sort: q.sort, p_desc: q.desc, p_limit: q.limit, p_offset: q.offset,
});

export const issueMembership = (orgId: string, fields: Record<string, unknown>) =>
  call<AdminMembership>('exos_membership_issue', { p_org_id: orgId, p_fields: fields });

export const updateMembership = (id: string, fields: Record<string, unknown>) =>
  call<AdminMembership>('exos_membership_update', { p_membership_id: id, p_fields: fields });

export const listImportedAttendees = (orgId: string, q: {
  eventId?: string; source?: string; search?: string; sort: string; desc: boolean; limit: number; offset: number;
}) => call<ServerPage<ImportedAttendee>>('exos_org_imported_attendees', {
  p_org_id: orgId, p_event_id: q.eventId || null, p_source: q.source || null, p_search: q.search || null,
  p_sort: q.sort, p_desc: q.desc, p_limit: q.limit, p_offset: q.offset,
});

export const updateImportedAttendee = (id: string, fields: Record<string, unknown>) =>
  call<ImportedAttendee>('exos_imported_attendee_update', { p_id: id, p_fields: fields });

export const deleteImportedAttendee = (id: string) =>
  call<{ id: string; deleted: boolean }>('exos_imported_attendee_delete', { p_id: id });
