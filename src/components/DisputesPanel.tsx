// Chargebacks (disputes) for one event (event report, next to Money) or one
// org (Payouts page). Read-only; owner / manager / finance only (canView, and
// RLS on exos_disputes). Hidden when the caller can't view or the table isn't
// on this database yet (mig 20261001101000). The dispute itself lives on the
// Exos platform's Stripe account; the Stripe link is for Exos staff.

import { useEffect, useMemo, useState } from 'react';
import { ExternalLink, ShieldAlert } from 'lucide-react';
import { formatCents } from '../lib/refunds';
import {
  disputeDueLabel,
  disputeReasonLabel,
  disputeStatusLabel,
  isOpenDispute,
  stripeDisputeLink,
  summarizeDisputes,
  type DisputeRow,
} from '../lib/disputesView';
import { getDisputes } from '../lib/disputesApi';

const STATUS_STYLE: Record<string, string> = {
  open: 'bg-amber-50 text-amber-700 border-amber-200',
  won: 'bg-emerald-50 text-emerald-700 border-emerald-200',
  lost: 'bg-rose-50 text-rose-600 border-rose-200',
  closed: 'bg-slate-100 text-slate-500 border-slate-200',
};

function when(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString(undefined, { dateStyle: 'medium' });
}

export default function DisputesPanel({ eventId, orgId, canView, currency = 'USD' }: {
  eventId?: string; orgId?: string; canView: boolean; currency?: string;
}) {
  const [rows, setRows] = useState<DisputeRow[] | null>(null);

  useEffect(() => {
    if (!canView || (!eventId && !orgId)) return undefined;
    let cancelled = false;
    void getDisputes(eventId ? { eventId } : { orgId }).then((d) => {
      if (!cancelled) setRows(d);
    });
    return () => {
      cancelled = true;
    };
  }, [eventId, orgId, canView]);

  const s = useMemo(() => summarizeDisputes(rows ?? []), [rows]);
  if (!canView || !rows) return null;
  const cur = rows[0]?.currency || currency;
  const money = (cents: number | null | undefined, c = cur) => formatCents(cents ?? 0, c);

  return (
    <section className="bg-white rounded-2xl p-6 shadow-sm mb-8 border border-slate-100" aria-labelledby="disputes-title">
      <div className="flex items-center gap-2 mb-1">
        <ShieldAlert className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h3 id="disputes-title" className="text-sm font-bold text-slate-700">Disputes</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Chargebacks a buyer's bank opened on Exos checkout orders. Tickets stay valid while a dispute is open; a lost one
        refunds the buyer and voids the order. Evidence goes to the bank from the Exos platform's Stripe account, so send
        the Exos team what you have before the due date.
      </p>

      {rows.length === 0 ? (
        <p className="text-sm text-slate-500">No disputes.</p>
      ) : (
        <>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
            <Stat label="Open" value={String(s.open)} hint={s.open ? `${money(s.openCents)} at stake` : undefined} />
            <Stat label="Lost" value={money(s.lostCents)} hint={`${s.lost} dispute${s.lost === 1 ? '' : 's'}`} />
            <Stat label="Won" value={String(s.won)} />
            <Stat label="Dispute fees" value={money(s.feesCents)} hint="charged by Stripe" />
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
                  <th className="py-2 font-black">Opened</th>
                  {orgId && <th className="py-2 font-black">Event</th>}
                  <th className="py-2 font-black">Order</th>
                  <th className="py-2 font-black">Reason</th>
                  <th className="py-2 font-black">Status</th>
                  <th className="py-2 font-black text-right">Amount</th>
                  <th className="py-2 font-black">Evidence</th>
                  <th className="py-2 font-black"><span className="sr-only">Stripe</span></th>
                </tr>
              </thead>
              <tbody>
                {rows.map((d) => {
                  const open = isOpenDispute(d.status);
                  const style = open ? STATUS_STYLE.open : STATUS_STYLE[d.status] ?? STATUS_STYLE.closed;
                  const due = disputeDueLabel(d);
                  const link = stripeDisputeLink(d);
                  return (
                    <tr key={d.id} className="border-b border-slate-50 last:border-b-0 align-top">
                      <td className="py-2 text-slate-600 whitespace-nowrap">{when(d.created_at)}</td>
                      {orgId && <td className="py-2 text-slate-700">{d.event?.name ?? '—'}</td>}
                      <td className="py-2 text-xs font-mono text-slate-500">{d.session_id ? d.session_id.slice(-10) : '—'}</td>
                      <td className="py-2 text-slate-700">{disputeReasonLabel(d.reason)}</td>
                      <td className="py-2">
                        <span className={`inline-block px-2 py-0.5 text-[10px] font-bold uppercase tracking-widest border rounded-full ${style}`}>
                          {disputeStatusLabel(d.status)}
                        </span>
                        {d.status === 'lost' && d.recovery_status === 'recovery_pending' && (
                          <p className="text-[10px] text-rose-600 mt-1">{money(d.recovery_candidate_cents, d.currency)} may be taken from a later payout</p>
                        )}
                      </td>
                      <td className="py-2 text-right text-slate-800 whitespace-nowrap">
                        {money(d.amount_cents, d.currency)}
                        {d.fee_cents ? <p className="text-[10px] text-slate-400">+ {money(d.fee_cents, d.currency)} fee</p> : null}
                      </td>
                      <td className="py-2 text-xs">
                        {d.evidence_submitted ? <span className="text-emerald-700">Submitted</span>
                          : due ? <span className={due.startsWith('Overdue') ? 'text-rose-600 font-bold' : 'text-amber-700 font-bold'}>{due}</span>
                          : <span className="text-slate-400">—</span>}
                      </td>
                      <td className="py-2 text-right">
                        {link && (
                          <a href={link} target="_blank" rel="noopener noreferrer" title="The Exos platform's Stripe dashboard (Exos staff)"
                            className="inline-flex items-center gap-1 text-xs text-slate-500 hover:text-slate-900">
                            Stripe <ExternalLink size={12} aria-hidden="true" />
                          </a>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </section>
  );
}

function Stat({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="bg-slate-50 rounded-xl px-4 py-3">
      <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest">{label}</p>
      <p className="text-lg font-black text-slate-800">{value}</p>
      {hint && <p className="text-[10px] text-slate-400 mt-0.5">{hint}</p>}
    </div>
  );
}
