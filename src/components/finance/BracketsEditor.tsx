// An offer's tiered deal brackets (mig 20261102120000): the percentage
// changes from each threshold upward. Owners and managers edit while the
// offer is a draft; everyone else who can see the offer reads them. The
// maths and validation are src/lib/dealMath.ts (dealBrackets).

import { useState } from 'react';
import { bracketErrors, describeBrackets, formatCents, type BracketBasis } from '../../lib/dealMath';
import { deleteBracket, saveBracket, type BracketRow } from '../../lib/financeExtrasApi';
import { initialTable, type TableState } from '../../lib/dataTable';
import DataTable, { type DataColumn } from '../DataTable';
import { BTN, BTN_PRIMARY, centsFromInput, FLD, inputFromCents, LABEL } from './ui';

interface Props {
  offerId: string;
  brackets: BracketRow[];
  /** The offer's own percentage (below the first threshold). */
  percentage: number;
  dealType: string;
  currency: string;
  /** owner / manager on a draft offer */
  canEdit: boolean;
  /** Saved or deleted: reload. */
  onChange: () => Promise<void>;
  onError: (e: unknown) => void;
  key?: string;
}

export default function BracketsEditor({ offerId, brackets, percentage, dealType, currency, canEdit, onChange, onError }: Props) {
  const [table, setTable] = useState<TableState>(() => initialTable('threshold'));
  const [basis, setBasis] = useState<BracketBasis>(brackets[0]?.basis ?? 'amount');
  const [threshold, setThreshold] = useState('');
  const [pct, setPct] = useState('');
  const [editing, setEditing] = useState<{ id: string; threshold: string; pct: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const lockedBasis = brackets[0]?.basis ?? null;
  const unit = (lockedBasis ?? basis) === 'tickets' ? 'tickets' : 'amount';
  const money = (c: number) => formatCents(c, currency);
  const show = (b: Pick<BracketRow, 'basis' | 'threshold'>) => (b.basis === 'tickets' ? `${b.threshold.toLocaleString('en-US')} tickets` : money(b.threshold));
  const parseThreshold = (v: string) => (unit === 'tickets' ? (/^\d+$/.test(v.trim()) ? Number(v.trim()) : Number.NaN) : centsFromInput(v) ?? Number.NaN);

  const columns: DataColumn<BracketRow>[] = [
    { key: 'threshold', header: 'From', value: (b) => b.threshold, render: (b) => editing?.id === b.id
      ? <input className={FLD} value={editing.threshold} onChange={(e) => setEditing({ ...editing, threshold: e.target.value })} aria-label="From" />
      : show(b) },
    { key: 'percentage', header: 'Percentage', align: 'right', value: (b) => b.percentage, render: (b) => editing?.id === b.id
      ? <input className={`${FLD} text-right`} value={editing.pct} onChange={(e) => setEditing({ ...editing, pct: e.target.value })} aria-label="Percentage" />
      : `${b.percentage}%` },
  ];

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    try { await fn(); await onChange(); } catch (e) { onError(e); } finally { setBusy(false); }
  };
  const check = (rows: { basis: string; threshold: number; percentage: number }[]) => {
    const errs = bracketErrors(rows);
    if (errs.length) throw new Error(errs.join('; '));
  };

  const add = () => run(async () => {
    const b = { basis: lockedBasis ?? basis, threshold: parseThreshold(threshold), percentage: Number(pct) };
    check([...brackets, b]);
    await saveBracket(offerId, b);
    setThreshold(''); setPct('');
  });
  const saveEdit = () => editing && run(async () => {
    const cur = brackets.find((x) => x.id === editing.id)!;
    const b = { basis: cur.basis, threshold: parseThreshold(editing.threshold), percentage: Number(editing.pct) };
    check([...brackets.filter((x) => x.id !== editing.id), b]);
    await saveBracket(offerId, b, editing.id);
    setEditing(null);
  });

  const summary = brackets.length
    ? describeBrackets(percentage, { basis: brackets[0].basis, tiers: brackets }, money)
    : null;

  return (
    <div className="mt-4 border-t border-slate-100 pt-4">
      <div className="flex items-baseline justify-between gap-2 mb-2">
        <span className={LABEL}>Tiered percentage</span>
        {summary && <span className="text-xs text-slate-600">{summary}</span>}
      </div>
      {dealType === 'flat' && brackets.length > 0 && (
        <p className="text-xs text-amber-700 mb-2">A flat deal has no percentage, so these brackets don't apply until the deal type changes.</p>
      )}
      <p className="text-xs text-slate-400 mb-3">
        Below the first threshold the offer's {percentage}% applies. Thresholds are on {unit === 'tickets' ? 'paid tickets sold' : 'the amount the percentage applies to'}; each one is unique, so tiers never overlap.
        {!canEdit && ' Brackets change only on a draft offer, by an owner or manager.'}
      </p>
      {brackets.length > 0 && (
        <DataTable<BracketRow> dense label="Deal brackets" rows={brackets} rowKey={(b) => b.id} columns={columns} state={table} onState={setTable}
          actions={canEdit ? (b) => (editing?.id === b.id
            ? <><button className={BTN} disabled={busy} onClick={saveEdit}>Save</button> <button className={BTN} onClick={() => setEditing(null)}>Cancel</button></>
            : <><button className={BTN} disabled={busy} onClick={() => setEditing({ id: b.id, threshold: b.basis === 'tickets' ? String(b.threshold) : inputFromCents(b.threshold), pct: String(b.percentage) })}>Edit</button>{' '}
              <button className={BTN} disabled={busy} onClick={() => run(() => deleteBracket(b.id))}>Delete</button></>) : undefined} />
      )}
      {canEdit && (
        <div className="flex flex-wrap gap-2 items-end mt-3">
          <label><span className={LABEL}>Basis</span>
            <select className={FLD} value={lockedBasis ?? basis} disabled={!!lockedBasis} onChange={(e) => setBasis(e.target.value as BracketBasis)}>
              <option value="amount">Amount</option><option value="tickets">Tickets sold</option>
            </select></label>
          <label><span className={LABEL}>From {unit === 'tickets' ? '(tickets)' : `(${currency})`}</span>
            <input className={FLD} value={threshold} onChange={(e) => setThreshold(e.target.value)} placeholder={unit === 'tickets' ? '1000' : '20000.00'} /></label>
          <label><span className={LABEL}>Percentage</span>
            <input className={FLD} value={pct} onChange={(e) => setPct(e.target.value)} placeholder="90" /></label>
          <button className={BTN_PRIMARY} disabled={busy || !threshold.trim() || !pct.trim()} onClick={add}>Add bracket</button>
        </div>
      )}
    </div>
  );
}
