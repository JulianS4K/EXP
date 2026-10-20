// What each org role can do: ONE table for every screen that gates a button
// (Members matrix, dashboard, event report, promoters, settings). Pure, no
// Supabase.
//
// The server is the authority: each row names the RLS policies / RPCs that
// enforce it (`sources`), and orgRoles.test.ts reads supabase/migrations to
// check the roles here equal the roles there. Change a role list in SQL and
// that test fails until this table says the same.

import type { OrgRole } from '../types';

export type OrgCapability =
  | 'editEvents'
  | 'publishEvents'
  | 'viewMoney'
  | 'refund'
  | 'voidTicket'
  | 'releaseSeat'
  | 'scan'
  | 'doorOverride'
  | 'announce'
  | 'promoCodes'
  | 'promoters'
  | 'promoterPayouts'
  | 'storefront'
  | 'orgSettings'
  | 'members'
  | 'viewPayouts'
  | 'connectStripe';

/**
 * Where the rule is enforced. `sql`: a policy or function in
 * supabase/migrations (its latest definition); `only: false` when the body
 * also checks other role lists (e.g. scanners may call, managers may act).
 * `file`: a line in an edge function.
 */
export type CapabilitySource =
  | { kind: 'sql'; name: string; only?: boolean }
  | { kind: 'file'; path: string; contains: string };

export interface CapabilityRule {
  /** Row label in the Members matrix. */
  label: string;
  /** "Only owners and managers can <action>." */
  action: string;
  roles: readonly OrgRole[];
  sources: readonly CapabilitySource[];
}

const sql = (name: string, only = true): CapabilitySource => ({ kind: 'sql', name, only });

export const ROLE_CAPABILITIES: Record<OrgCapability, CapabilityRule> = {
  editEvents: {
    label: 'Create, edit & clone events',
    action: 'create, edit or clone events',
    roles: ['owner', 'manager'],
    sources: [sql('exos_events_ins'), sql('exos_events_upd')],
  },
  publishEvents: {
    label: 'Publish / cancel events',
    action: 'publish or cancel events',
    roles: ['owner', 'manager'],
    sources: [sql('exos_events_upd')],
  },
  viewMoney: {
    label: 'View sales & financials',
    action: 'see sales and money',
    roles: ['owner', 'manager', 'finance'],
    sources: [sql('exos_order_refunds_sel'), sql('exos_disputes_sel'), sql('exos_event_refund_orders')],
  },
  refund: {
    label: 'Refund tickets',
    action: 'refund tickets',
    roles: ['owner', 'manager', 'finance'],
    sources: [sql('exos_refund_preview'), sql('exos_refund_claim')],
  },
  voidTicket: {
    label: 'Void tickets',
    action: 'void tickets',
    roles: ['owner', 'manager', 'finance'],
    sources: [sql('exos_void_ticket')],
  },
  releaseSeat: {
    label: 'Release a free seat back on sale',
    action: 'release seats',
    roles: ['owner', 'manager'],
    sources: [sql('exos_release_ticket')],
  },
  scan: {
    label: 'Scan at the door (scanners: all or chosen events)',
    action: 'scan at the door',
    roles: ['owner', 'manager', 'scanner'],
    sources: [sql('exos_check_in_offline'), sql('exos_event_checkin_roster')],
  },
  doorOverride: {
    label: 'Door override / undo a check-in',
    action: 'override or undo a check-in',
    roles: ['owner', 'manager'],
    sources: [sql('exos_undo_check_in', false)],
  },
  announce: {
    label: 'Send announcements',
    action: 'send announcements',
    roles: ['owner', 'manager'],
    sources: [sql('exos_send_event_announcement'), sql('exos_announce_to_followers')],
  },
  promoCodes: {
    label: 'Promo codes & promo links',
    action: 'make promo codes and promo links',
    roles: ['owner', 'manager'],
    sources: [sql('exos_vouchers_write'), sql('exos_issue_voucher')],
  },
  promoters: {
    label: 'Add, pause & set terms for promoters',
    action: 'add, pause or change promoters',
    roles: ['owner', 'manager'],
    sources: [sql('exos_upsert_promoter'), sql('exos_set_promoter_status'), sql('exos_set_promoter_terms')],
  },
  promoterPayouts: {
    label: 'Record promoter payouts',
    action: 'record promoter payouts',
    roles: ['owner', 'manager', 'finance'],
    sources: [sql('exos_record_promoter_payout')],
  },
  storefront: {
    label: 'Edit storefront & website',
    action: 'edit the storefront and website',
    roles: ['owner', 'manager'],
    sources: [sql('exos_set_org_site'), sql('exos_add_org_domain')],
  },
  orgSettings: {
    label: 'Org profile, branding & checkout reminders',
    action: 'change org settings',
    roles: ['owner'],
    sources: [sql('exos_orgs_upd')],
  },
  members: {
    label: 'Manage members',
    action: 'manage members',
    roles: ['owner'],
    sources: [sql('exos_memberships_ins'), sql('exos_memberships_upd'), sql('exos_memberships_del')],
  },
  viewPayouts: {
    label: 'See payouts & fee terms',
    action: 'see payouts and fee terms',
    roles: ['owner', 'manager', 'finance'],
    sources: [sql('exos_org_payouts_sel'), sql('exos_org_billing_sel')],
  },
  connectStripe: {
    label: 'Connect Stripe (bank for payouts)',
    action: 'connect Stripe',
    roles: ['owner'],
    sources: [{ kind: 'file', path: 'supabase/functions/exos-connect-onboard/index.ts', contains: 'mem.role !== "owner"' }],
  },
};

/** Column order of the Members matrix. */
export const MATRIX_ROLES: readonly OrgRole[] = ['owner', 'manager', 'finance', 'scanner', 'content'];

/** Matrix rows, in display order. */
export const MATRIX_CAPABILITIES: readonly OrgCapability[] = [
  'editEvents', 'publishEvents', 'viewMoney', 'refund', 'voidTicket', 'releaseSeat', 'scan', 'doorOverride',
  'announce', 'promoCodes', 'promoters', 'promoterPayouts', 'storefront', 'orgSettings', 'members',
  'viewPayouts', 'connectStripe',
];

/**
 * The caller's role in one org, from their memberships (OrganizationContext's
 * list). A page about one event or org gates on this, not on the active org.
 */
export function roleInOrg(
  entries: readonly { org: { id: string }; membership: { role: OrgRole } }[],
  orgId: string | null | undefined,
): OrgRole | null {
  if (!orgId) return null;
  return entries.find((e) => e.org.id === orgId)?.membership.role ?? null;
}

/** May `role` do `cap`? Platform admins may do everything (support mode). */
export function can(role: OrgRole | string | null | undefined, cap: OrgCapability, isAdmin = false): boolean {
  if (isAdmin) return true;
  if (!role) return false;
  return (ROLE_CAPABILITIES[cap].roles as readonly string[]).includes(role);
}

const ROLE_WORDS: Record<OrgRole, string> = {
  owner: 'owners',
  manager: 'managers',
  finance: 'finance',
  scanner: 'scanners',
  content: 'content',
};

/** "owners and managers", "owners, managers and finance". */
export function rolesPhrase(roles: readonly OrgRole[]): string {
  const w = roles.map((r) => ROLE_WORDS[r]);
  if (w.length <= 1) return w[0] ?? 'nobody';
  return `${w.slice(0, -1).join(', ')} and ${w[w.length - 1]}`;
}

/** Why a button is off: "Only owners and managers can create, edit or clone events." */
export function cannotReason(cap: OrgCapability): string {
  return `Only ${rolesPhrase(ROLE_CAPABILITIES[cap].roles)} can ${ROLE_CAPABILITIES[cap].action}.`;
}
