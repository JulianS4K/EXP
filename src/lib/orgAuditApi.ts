// The org audit log's calls (claude/exos-org-audit, mig 20261109100000):
// exos_org_audit_list (owner / manager / finance or a platform admin, checked
// in SQL) and exos_audit_export, the export.run row a CSV built in the
// browser records. Rows and labels: orgAudit.ts.

import { supabase } from './supabase';
import { auditArgs, type AuditFilters, type AuditPage, type AuditRow, type ExportKind } from './orgAudit';

export async function listOrgAudit(orgId: string, f: AuditFilters, before: number | null = null, limit = 100): Promise<AuditPage> {
  const { data, error } = await supabase.rpc('exos_org_audit_list', auditArgs(orgId, f, before, limit));
  if (error) throw error;
  const d = (data ?? {}) as { rows?: AuditRow[]; next_before?: number | null; actors?: { uid: string; label: string }[] };
  return { rows: d.rows ?? [], nextBefore: d.next_before ?? null, actors: d.actors ?? [] };
}

/** Every row the filters match (up to `max`), page by page, for the CSV. */
export async function allOrgAudit(orgId: string, f: AuditFilters, max = 20000): Promise<AuditRow[]> {
  const out: AuditRow[] = [];
  let before: number | null = null;
  while (out.length < max) {
    const page = await listOrgAudit(orgId, f, before, 500);
    out.push(...page.rows);
    if (page.nextBefore === null || page.rows.length === 0) break;
    before = page.nextBefore;
  }
  return out.slice(0, max);
}

/**
 * Record an export the browser built (export.run). Best effort: an export is
 * never held up by its log row (an older database, a role that may export but
 * not log, a rate limit).
 */
export async function logExport(orgId: string | null | undefined, kind: ExportKind, rowCount: number, eventId?: string | null): Promise<void> {
  if (!orgId && !eventId) return;
  try {
    await supabase.rpc('exos_audit_export', {
      p_org_id: orgId ?? null, p_kind: kind, p_row_count: Math.max(0, Math.floor(rowCount)), p_event_id: eventId ?? null,
    });
  } catch {
    /* best effort */
  }
}
