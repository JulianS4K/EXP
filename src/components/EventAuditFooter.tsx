// The event report's footer: "N changes since publish" from the org audit log
// (exos_event_audit_summary, mig 20261110120000), linking to Org → Activity
// filtered to this event. Only for the roles that read the log (owner /
// manager / finance, platform admins; the SQL checks it too): anyone else,
// an older database or nothing to say renders nothing.

import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { History } from 'lucide-react';
import { activityLink, auditFooterText, type EventAuditSummary } from '../lib/orgAudit';
import { eventAuditSummary } from '../lib/orgAuditApi';

const fmtDate = (iso: string) => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso.slice(0, 10) : d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
};

export default function EventAuditFooter({ eventId, orgId, canView }: { eventId: string; orgId: string; canView: boolean }) {
  const [summary, setSummary] = useState<EventAuditSummary | null>(null);
  useEffect(() => {
    if (!canView || !eventId) return undefined;
    let live = true;
    eventAuditSummary(eventId).then((s) => { if (live) setSummary(s); }).catch(() => { if (live) setSummary(null); });
    return () => { live = false; };
  }, [eventId, canView]);
  const text = canView ? auditFooterText(summary, fmtDate) : null;
  if (!text || !summary) return null;
  return (
    <footer className="mt-10 pt-4 border-t border-slate-200 text-xs text-slate-600 flex flex-wrap items-center gap-2" data-testid="event-audit-footer">
      <History className="w-3.5 h-3.5" aria-hidden="true" />
      <span>{text}</span>
      <span aria-hidden="true">·</span>
      <Link to={activityLink(summary.orgId || orgId, eventId)} className="underline font-bold text-slate-800 hover:text-slate-950">
        View activity
      </Link>
    </footer>
  );
}
