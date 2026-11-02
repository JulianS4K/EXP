// Event report → Settlement tab: the show's cash summary (gross, fees, tax,
// refunds, net by payment method, payouts) and its ledger codes (per-event
// overrides of the revenue-type codes, and the backfill that re-tags the
// show's reporting rows). Mig 20261102120000. Owner / manager / finance all
// read and write these; renders nothing for anyone else.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { useToast } from '../../context/ToastContext';
import { listGlCodes, type GlCodeRow } from '../../lib/offersApi';
import {
  backfillGlCodes, deleteAssignment, getCashSummary, listAssignments, listRevenueCodes, saveAssignment,
  type AssignmentRow, type CashSummary, type RevenueCodeRow,
} from '../../lib/financeExtrasApi';
import { initialTable, label, PAYMENT_METHOD_LABEL, REVENUE_TYPE_LABEL, REVENUE_TYPES, type TableState } from '../../lib/financeTables';
import DataTable, { type DataColumn } from './DataTable';
import { BTN, BTN_PRIMARY, FLD, LABEL, Money, Row, Section } from './ui';

interface Props {
  eventId: string;
  orgId: string;
  /** owner / manager / finance */
  canView: boolean;
}

interface MethodRow { method: string; orders: number; gross_cents: number; refunds_cents: number; net_cents: number }

export default function EventLedgerPanel({ eventId, orgId, canView }: Props) {
  const { toast } = useToast();
  const [cash, setCash] = useState<CashSummary | null>(null);
  const [codes, setCodes] = useState<GlCodeRow[]>([]);
  const [revenue, setRevenue] = useState<RevenueCodeRow[]>([]);
  const [overrides, setOverrides] = useState<AssignmentRow[]>([]);
  const [busy, setBusy] = useState(false);
  const [newType, setNewType] = useState('');
  const [newCode, setNewCode] = useState('');
  const [methodTable, setMethodTable] = useState<TableState>(() => initialTable('gross_cents', 'desc', 25));
  const canWrite = canView;

  const fail = useCallback((e: unknown) => toast({ kind: 'error', message: (e as Error).message }), [toast]);
  const load = useCallback(async () => {
    if (!canView) return;
    try {
      const [c, g, r, o] = await Promise.all([getCashSummary(eventId), listGlCodes(orgId), listRevenueCodes(orgId), listAssignments(eventId)]);
      setCash(c); setCodes(g.filter((x) => !x.discarded_at)); setRevenue(r); setOverrides(o);
    } catch (e) { fail(e); }
  }, [eventId, orgId, canView, fail]);
  useEffect(() => { load(); }, [load]);

  const cur = cash?.currency ?? 'USD';
  const methodColumns = useMemo<DataColumn<MethodRow>[]>(() => [
    { key: 'method', header: 'Payment method', value: (r) => label(PAYMENT_METHOD_LABEL, r.method), searchable: true },
    { key: 'orders', header: 'Orders', align: 'right', value: (r) => r.orders },
    { key: 'gross_cents', header: 'Gross', align: 'right', value: (r) => r.gross_cents, render: (r) => <Money cents={r.gross_cents} currency={cur} /> },
    { key: 'refunds_cents', header: 'Refunds', align: 'right', value: (r) => r.refunds_cents, render: (r) => <Money cents={-r.refunds_cents} currency={cur} /> },
    { key: 'net_cents', header: 'Net', align: 'right', value: (r) => r.net_cents, render: (r) => <Money cents={r.net_cents} currency={cur} /> },
  ], [cur]);

  if (!canView || !cash) return null;
  const codeName = (id: string | null | undefined) => {
    const g = codes.find((x) => x.id === id);
    return g ? `${g.code} ${g.name}` : 'Uncoded';
  };
  const orgCode = new Map<string, string>(revenue.map((r) => [r.revenue_type, r.gl_code_id]));
  const overridden = new Set(overrides.map((o) => o.revenue_type));

  const act = async (fn: () => Promise<unknown>, ok?: string) => {
    setBusy(true);
    try { await fn(); if (ok) toast({ kind: 'success', message: ok }); await load(); } catch (e) { fail(e); } finally { setBusy(false); }
  };

  return (
    <>
      <Section title="Cash summary">
        <div className="grid sm:grid-cols-2 gap-x-8">
          <div>
            <Row label="Gross (online and POS)"><Money cents={cash.gross_cents} currency={cur} /></Row>
            <Row label="Tax"><Money cents={-cash.tax_cents} currency={cur} /></Row>
            <Row label="Refunds"><Money cents={-cash.refunds_cents} currency={cur} /></Row>
            <Row label="Platform fees"><Money cents={-cash.fees.platform_fees_cents} currency={cur} /></Row>
            <Row label="Net" strong><Money cents={cash.net_cents} currency={cur} strong /></Row>
          </div>
          <div>
            <Row label="Buyer fees collected"><Money cents={cash.fees.buyer_fees_cents} currency={cur} /></Row>
            <Row label="Comps">{cash.comps.tickets} ticket{cash.comps.tickets === 1 ? '' : 's'}{cash.comps.pos_cents ? <> · <Money cents={cash.comps.pos_cents} currency={cur} /> POS</> : null}</Row>
            <Row label="Paid out by Stripe"><Money cents={cash.payouts.stripe_transferred_cents} currency={cur} /></Row>
            <Row label="Stripe, not yet transferred"><Money cents={cash.payouts.stripe_pending_cents} currency={cur} /></Row>
            <Row label="PayPal owed to you"><Money cents={cash.payouts.paypal_owed_cents} currency={cur} /></Row>
          </div>
        </div>
        <div className="mt-4">
          <DataTable<MethodRow> caption="By payment method" rows={cash.by_payment_method} rowKey={(r) => r.method} columns={methodColumns}
            state={methodTable} onState={setMethodTable} empty="No payments yet." />
        </div>
      </Section>

      <Section title="Ledger codes" action={canWrite && (
        <button className={BTN_PRIMARY} disabled={busy} onClick={() => act(async () => {
          const r = await backfillGlCodes(eventId);
          toast({ kind: 'success', message: `Backfill: ${r.created} new, ${r.retagged} re-tagged, ${r.removed} removed (${r.rows} rows).` });
        })}>Backfill</button>
      )}>
        <p className="text-xs text-slate-400 mb-3">Each revenue type posts to your organization's code unless this show overrides it. Backfill builds the show's reporting rows and re-tags them; running it again changes nothing.</p>
        <table className="w-full text-sm">
          <thead><tr className="text-[10px] uppercase tracking-widest text-slate-400 text-left">
            <th className="py-1">Revenue type</th><th>Organization code</th><th>This show</th><th /></tr></thead>
          <tbody>
            {overrides.map((o) => (
              <tr key={o.id} className="border-t border-slate-100">
                <td className="py-1.5">{label(REVENUE_TYPE_LABEL, o.revenue_type)}</td>
                <td className="text-xs text-slate-500">{codeName(orgCode.get(o.revenue_type))}</td>
                <td className="w-64">{canWrite ? (
                  <select className={FLD} value={o.gl_code_id} disabled={busy} onChange={(e) => act(() => saveAssignment(eventId, o.revenue_type, e.target.value, o.id))}>
                    {codes.map((g) => <option key={g.id} value={g.id}>{g.code} {g.name}</option>)}
                  </select>) : codeName(o.gl_code_id)}</td>
                <td className="w-24 text-right">{canWrite && <button className={BTN} disabled={busy} onClick={() => act(() => deleteAssignment(o.id))}>Remove</button>}</td>
              </tr>
            ))}
            {!overrides.length && <tr><td colSpan={4} className="py-3 text-center text-slate-400">No overrides: every type uses the organization's code.</td></tr>}
          </tbody>
        </table>
        {canWrite && (
          <div className="flex flex-wrap gap-2 items-end mt-3">
            <label><span className={LABEL}>Override</span>
              <select className={FLD} value={newType} onChange={(e) => setNewType(e.target.value)}>
                <option value="">Revenue type…</option>
                {REVENUE_TYPES.filter((t) => !overridden.has(t)).map((t) => <option key={t} value={t}>{label(REVENUE_TYPE_LABEL, t)}</option>)}
              </select></label>
            <label className="flex-1 min-w-[200px]"><span className={LABEL}>With code</span>
              <select className={FLD} value={newCode} onChange={(e) => setNewCode(e.target.value)}>
                <option value="">Code…</option>
                {codes.map((g) => <option key={g.id} value={g.id}>{g.code} {g.name}</option>)}
              </select></label>
            <button className={BTN_PRIMARY} disabled={busy || !newType || !newCode}
              onClick={() => act(async () => { await saveAssignment(eventId, newType, newCode); setNewType(''); setNewCode(''); })}>Add</button>
          </div>
        )}
      </Section>
    </>
  );
}
