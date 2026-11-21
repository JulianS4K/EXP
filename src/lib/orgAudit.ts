// Org → Activity (claude/exos-org-audit, mig 20261109100000): the org audit
// log's rows as the dashboard shows them, their labels and CSV. Pure (the
// calls are in orgAuditApi.ts). docs/security.md "Org audit log".

import { toCsv } from './csv';
import { AUDIT_GROUP_NAMES, auditGroup, type AuditGroup } from '../../supabase/functions/_shared/api/audit.ts';

export { AUDIT_GROUP_NAMES, auditGroup, type AuditGroup };

export interface AuditRow {
  id: number;
  at: string;
  event_id: string | null;
  event_name: string | null;
  actor_uid: string | null;
  actor_kind: 'user' | 'api_key' | 'oauth_app' | 'service' | 'cron';
  actor_ref: string | null;
  actor_role: string | null;
  actor_label: string;
  action: string;
  group: AuditGroup | 'other';
  entity_type: string;
  entity_id: string | null;
  changes: Record<string, unknown>;
  amount_cents: number | null;
  currency: string | null;
  reason: string | null;
  source: string;
  request_id: string | null;
}

export interface AuditPage {
  rows: AuditRow[];
  /** Pass as `before` for the next (older) page; null at the end. */
  nextBefore: number | null;
  actors: { uid: string; label: string }[];
}

export interface AuditFilters {
  eventId?: string | null;
  actorUid?: string | null;
  group?: AuditGroup | null;
  /** yyyy-mm-dd, inclusive. */
  from?: string | null;
  /** yyyy-mm-dd, inclusive (the whole day). */
  to?: string | null;
}

export const GROUP_LABEL: Record<AuditGroup, string> = {
  inventory: 'Inventory', money: 'Money', access: 'Access', data: 'Exports',
};

const SOURCE_LABEL: Record<string, string> = {
  dashboard: 'Dashboard', api: 'API', door: 'Door', pos: 'Box office', webhook: 'Webhook', system: 'Exos',
};

/** "refund_ask.decline" → "Refund ask: decline". */
export function actionLabel(action: string): string {
  const [head, verb] = String(action).split('.');
  const words = (s: string | undefined) => (s ?? '').replace(/_/g, ' ');
  const h = words(head);
  return `${h.charAt(0).toUpperCase()}${h.slice(1)}: ${words(verb)}`;
}

export function sourceLabel(source: string): string {
  return SOURCE_LABEL[source] ?? source;
}

function show(v: unknown): string {
  if (v === null || v === undefined) return '—';
  if (Array.isArray(v)) return v.map(show).join(', ');
  if (typeof v === 'object') return '(changed)';
  return String(v);
}

/** "price 40 → 45; status draft → published"; a field set from nothing shows its value. */
export function changeSummary(changes: Record<string, unknown> | null | undefined): string {
  if (!changes) return '';
  return Object.entries(changes).map(([k, v]) => {
    const name = k.replace(/_/g, ' ');
    if (Array.isArray(v) && v.length === 2) {
      return v[0] === null || v[0] === undefined ? `${name} ${show(v[1])}` : `${name} ${show(v[0])} → ${show(v[1])}`;
    }
    return `${name} ${show(v)}`;
  }).join('; ');
}

/** "$15.00" for cents in a currency; '' without an amount. */
export function amountLabel(cents: number | null, currency: string | null): string {
  if (cents === null || cents === undefined) return '';
  const cur = currency || 'USD';
  try {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: cur }).format(cents / 100);
  } catch {
    return `${(cents / 100).toFixed(2)} ${cur}`;
  }
}

/** Who acted, for a person: "oa@x.com (owner) via API key". */
export function actorText(r: Pick<AuditRow, 'actor_label' | 'actor_role' | 'actor_kind'>): string {
  const role = r.actor_role && r.actor_role !== 'platform_admin' ? ` (${r.actor_role})` : '';
  return `${r.actor_label}${r.actor_kind === 'oauth_app' ? ' via an app' : ''}${role}`;
}

export const AUDIT_CSV_HEADER = [
  'id', 'at', 'event_id', 'event', 'actor_kind', 'actor_id', 'actor', 'actor_ref', 'actor_role', 'action', 'group',
  'entity_type', 'entity_id', 'changes', 'amount_cents', 'currency', 'reason', 'source', 'request_id',
];

export function auditCsv(rows: AuditRow[]): string {
  return toCsv(AUDIT_CSV_HEADER, rows.map((r) => [
    r.id, r.at, r.event_id, r.event_name, r.actor_kind, r.actor_uid, r.actor_label, r.actor_ref, r.actor_role, r.action,
    r.group, r.entity_type, r.entity_id, JSON.stringify(r.changes ?? {}), r.amount_cents, r.currency, r.reason, r.source,
    r.request_id,
  ]));
}

/** The RPC arguments for a filter set (dates are whole days in the viewer's zone). */
export function auditArgs(orgId: string, f: AuditFilters, before: number | null, limit: number): Record<string, unknown> {
  const day = (d: string, end: boolean) => {
    const t = new Date(`${d}T00:00:00`);
    if (Number.isNaN(t.getTime())) return null;
    if (end) t.setDate(t.getDate() + 1);
    return t.toISOString();
  };
  return {
    p_org_id: orgId,
    p_event_id: f.eventId || null,
    p_actor_uid: f.actorUid || null,
    p_group: f.group || null,
    p_from: f.from ? day(f.from, false) : null,
    p_to: f.to ? day(f.to, true) : null,
    p_before: before,
    p_limit: limit,
  };
}

export type ExportKind = 'audit' | 'donations' | 'price_disclosure' | 'attendees';
