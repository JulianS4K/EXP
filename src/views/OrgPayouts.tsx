// /orgs/:orgId/payouts — the org's marketplace payouts, read-only
// (docs/payouts.md). Exos checkouts don't appear here: Stripe pays those to
// the organizer's connected account directly. Marketplace sales are paid by
// Exos (exos-payouts) once the marketplace has paid us; each payout lists the
// orders it covers and any clawbacks. Owner / manager / finance (RLS on
// exos_org_payouts / _lines enforces it); a CSV export per line. Below them,
// the org's chargebacks on Exos checkout orders (DisputesPanel, mig
// 20261001101000).

import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Download, Landmark } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { formatCents } from '../lib/refunds';
import { csvFileName, downloadCsv, toCsv } from '../lib/csv';
import { getOrgPayouts } from '../lib/settlementApi';
import DisputesPanel from '../components/DisputesPanel';
import {
  canSeeMoney,
  groupPayouts,
  PAYOUTS_CSV_HEADER,
  payoutsCsvRows,
  payoutTotals,
  type PayoutWithLines,
} from '../lib/settlement';

const STATUS_STYLE: Record<string, string> = {
  planned: 'bg-sky-50 text-sky-700 border-sky-200',
  sending: 'bg-sky-50 text-sky-700 border-sky-200',
  sent: 'bg-emerald-50 text-emerald-700 border-emerald-200',
  failed: 'bg-rose-50 text-rose-600 border-rose-200',
  cancelled: 'bg-slate-100 text-slate-500 border-slate-200',
};

function when(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString(undefined, { dateStyle: 'medium' });
}

export default function OrgPayouts() {
  const { orgId } = useParams();
  const navigate = useNavigate();
  const { user, isAdmin } = useAuth();
  const { orgs, loading: orgsLoading } = useOrganization();
  const entry = orgs.find((o) => o.org.id === orgId);
  const allowed = canSeeMoney(entry?.membership.role, isAdmin);
  // undefined = loading, null = not available on this database / no access.
  const [payouts, setPayouts] = useState<PayoutWithLines[] | null | undefined>(undefined);
  const [openId, setOpenId] = useState<string | null>(null);

  useEffect(() => {
    if (!orgId || !allowed) return undefined;
    let cancelled = false;
    void getOrgPayouts(orgId).then((d) => {
      if (!cancelled) setPayouts(d ? groupPayouts(d.payouts, d.lines) : null);
    });
    return () => {
      cancelled = true;
    };
  }, [orgId, allowed]);

  const totals = useMemo(() => payoutTotals(payouts ?? []), [payouts]);

  if (!user) {
    return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 font-bold uppercase tracking-widest">Sign in required.</div>;
  }
  if (!orgsLoading && !allowed) {
    return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 text-sm">Payouts are visible to the org's owners, managers and finance team.</div>;
  }

  const exportCsv = () => {
    if (!payouts) return;
    downloadCsv(csvFileName(['payouts', entry?.org.name]), toCsv(PAYOUTS_CSV_HEADER, payoutsCsvRows(payouts)));
  };

  return (
    <div className="min-h-screen bg-tm-gray text-slate-900">
      <div className="max-w-5xl mx-auto px-4 py-10">
        <button onClick={() => navigate('/dashboard')}
          className="flex items-center gap-1.5 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6 transition-colors">
          <ArrowLeft size={14} strokeWidth={2.5} /> Dashboard
        </button>
        <div className="flex flex-wrap items-end justify-between gap-4 mb-8">
          <div>
            <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">{entry?.org.name ?? 'Organization'}</p>
            <h1 className="text-3xl md:text-4xl font-bold tracking-tight">Payouts</h1>
          </div>
          {payouts && payouts.length > 0 && (
            <button type="button" onClick={exportCsv}
              className="inline-flex items-center gap-1.5 px-4 py-2.5 rounded border border-slate-200 bg-white text-xs font-bold text-slate-700 hover:bg-slate-50">
              <Download size={14} aria-hidden="true" /> Export CSV
            </button>
          )}
        </div>

        <p className="text-sm text-slate-600 mb-6 max-w-prose">
          Sales through Exos checkout are paid out by Stripe directly to your connected account, on Stripe's schedule.
          This page lists what Exos pays you for <strong>marketplace</strong> sales, after the marketplace pays us.
          A cancelled order that was already paid is taken off a later payout (a clawback).
        </p>

        {payouts === undefined ? (
          <p className="text-slate-400 text-sm">Loading…</p>
        ) : payouts === null ? (
          <div className="bg-white rounded-2xl border border-slate-200 p-8 text-center text-slate-500 text-sm">
            Payouts aren't available yet.
          </div>
        ) : payouts.length === 0 ? (
          <div className="bg-white rounded-2xl border border-slate-200 p-8 text-center text-slate-500 text-sm">
            <Landmark className="w-5 h-5 mx-auto mb-2 text-slate-300" aria-hidden="true" />
            No payouts yet.
          </div>
        ) : (
          <>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-3 mb-6">
              {totals.map((t) => (
                <div key={t.currency} className="contents">
                  <Tile label={`Paid (${t.currency})`} value={formatCents(t.sentCents, t.currency)} />
                  <Tile label="On the way" value={formatCents(t.pendingCents, t.currency)} />
                  <Tile label="Failed" value={formatCents(t.failedCents, t.currency)} />
                </div>
              ))}
            </div>
            <ul className="space-y-3">
              {payouts.map((p) => {
                const open = openId === p.id;
                return (
                  <li key={p.id} className="bg-white rounded-2xl border border-slate-200">
                    <button type="button" onClick={() => setOpenId(open ? null : p.id)} aria-expanded={open}
                      className="w-full flex flex-wrap items-center justify-between gap-3 p-5 text-left">
                      <div className="text-sm">
                        <p className="font-bold">{formatCents(p.amountCents, p.currency)}</p>
                        <p className="text-slate-500">
                          {p.status === 'sent' && p.sent_at ? `Sent ${when(p.sent_at)}` : `Created ${when(p.created_at)}`}
                          {' · '}{p.sales} order{p.sales === 1 ? '' : 's'}{p.clawbacks ? `, ${p.clawbacks} clawback${p.clawbacks === 1 ? '' : 's'}` : ''}
                        </p>
                        {p.status === 'failed' && p.error && <p className="text-rose-600 text-xs mt-1">{p.error}</p>}
                      </div>
                      <span className={`inline-block px-2 py-0.5 text-[10px] font-bold uppercase tracking-widest border rounded-full ${STATUS_STYLE[p.status] ?? STATUS_STYLE.cancelled}`}>
                        {p.status === 'sending' ? 'sending' : p.status}
                      </span>
                    </button>
                    {open && (
                      <div className="border-t border-slate-100 px-5 pb-5 overflow-x-auto">
                        {p.stripe_transfer_id && <p className="text-xs text-slate-400 mt-3 font-mono">Stripe transfer {p.stripe_transfer_id}</p>}
                        {p.lines.length === 0 ? (
                          <p className="text-xs text-slate-400 mt-3">No orders on this payout.</p>
                        ) : (
                          <table className="w-full text-sm mt-3">
                            <thead>
                              <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
                                <th className="py-2 font-black">Order</th>
                                <th className="py-2 font-black">Event</th>
                                <th className="py-2 font-black">Kind</th>
                                <th className="py-2 font-black text-right">Amount</th>
                              </tr>
                            </thead>
                            <tbody>
                              {p.lines.map((l) => (
                                <tr key={l.id} className="border-b border-slate-50 last:border-b-0">
                                  <td className="py-2 text-slate-700 text-xs">
                                    {l.channel ? <span className="uppercase font-bold mr-1">{l.channel}</span> : null}
                                    <span className="font-mono">{l.external_order_id ?? l.order_id.slice(0, 8)}</span>
                                  </td>
                                  <td className="py-2 text-slate-700">{l.event_name ?? '—'}</td>
                                  <td className="py-2 text-slate-500 text-xs">{l.kind}</td>
                                  <td className={`py-2 text-right ${l.amountCents < 0 ? 'text-rose-600' : 'text-slate-800'}`}>{formatCents(l.amountCents, p.currency)}</td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        )}
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          </>
        )}

        {/* Chargebacks on the org's Exos checkout orders (mig 20261001101000). */}
        <div className="mt-10">
          <DisputesPanel orgId={orgId} canView={allowed} />
        </div>
      </div>
    </div>
  );
}

function Tile({ label, value }: { label: string; value: string }) {
  return (
    <div className="bg-white rounded-2xl border border-slate-200 px-5 py-4">
      <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest">{label}</p>
      <p className="text-xl font-black text-slate-800">{value}</p>
    </div>
  );
}
