// Deal terms form (flat / versus / plus / door, guarantee, percentage,
// expenses cap, promoter profit, bonuses, merch, deposit; a pool's floor and
// cap). Edits a TermsJson in cents; the database validates again.

import { DEAL_TYPES, type TermsJson } from '../../lib/dealMath';
import { BTN, centsFromInput, FLD, inputFromCents, LABEL } from './ui';

const DEAL_LABELS: Record<string, string> = {
  flat: 'Flat guarantee', versus: 'Guarantee versus %', plus: 'Guarantee plus %', door: 'Door deal (% of net)',
};

export default function TermsEditor({ terms, onChange, disabled, pool = false }: {
  terms: TermsJson; onChange: (t: TermsJson) => void; disabled?: boolean; pool?: boolean; key?: string;
}) {
  const set = (patch: Partial<TermsJson>) => onChange({ ...terms, ...patch });
  const money = (k: keyof TermsJson, label: string, nullable = false) => (
    <label className="block">
      <span className={LABEL}>{label}</span>
      <input className={FLD} inputMode="decimal" disabled={disabled}
        defaultValue={inputFromCents(terms[k] as number | null | undefined)}
        onBlur={(e) => {
          const c = centsFromInput(e.target.value);
          if (c === null) set({ [k]: nullable ? null : 0 } as Partial<TermsJson>);
          else if (!Number.isNaN(c)) set({ [k]: c } as Partial<TermsJson>);
        }} />
    </label>
  );
  const pct = (k: keyof TermsJson, label: string, nullable = false) => (
    <label className="block">
      <span className={LABEL}>{label}</span>
      <input className={FLD} inputMode="decimal" disabled={disabled}
        defaultValue={terms[k] === null || terms[k] === undefined ? '' : String(terms[k])}
        onBlur={(e) => {
          const s = e.target.value.trim().replace('%', '');
          if (!s) set({ [k]: nullable ? null : 0 } as Partial<TermsJson>);
          else if (Number.isFinite(Number(s))) set({ [k]: Math.min(100, Math.max(0, Number(s))) } as Partial<TermsJson>);
        }} />
    </label>
  );
  const type = terms.deal_type ?? 'flat';
  const bonuses = terms.bonuses ?? [];
  return (
    <div className="grid gap-3 sm:grid-cols-3">
      <label className="block sm:col-span-3">
        <span className={LABEL}>Deal</span>
        <select className={FLD} value={type} disabled={disabled} onChange={(e) => set({ deal_type: e.target.value })}>
          {DEAL_TYPES.map((d) => <option key={d} value={d}>{DEAL_LABELS[d]}</option>)}
        </select>
      </label>
      {money('guarantee_cents', type === 'door' ? 'Guarantee (minimum)' : 'Guarantee')}
      {type !== 'flat' && pct('percentage', type === 'door' ? '% of net box office' : type === 'plus' ? '% above the split point' : '% of net after expenses')}
      {(type === 'versus' || type === 'plus') && money('expenses_cap_cents', 'Expenses cap (blank = none)', true)}
      {type === 'plus' && pct('promoter_profit_percent', 'Promoter profit %')}
      {pool && money('payout_floor_cents', 'Pool floor (blank = none)', true)}
      {pool && money('payout_cap_cents', 'Pool cap (blank = none)', true)}
      {!pool && pct('merch_artist_percent', 'Merch to artist % (blank = none)', true)}
      {!pool && money('deposit_cents', 'Deposit')}
      {!pool && (
        <label className="block">
          <span className={LABEL}>Deposit due</span>
          <input className={FLD} type="date" disabled={disabled} value={terms.deposit_due_on ?? ''}
            onChange={(e) => set({ deposit_due_on: e.target.value || null })} />
        </label>
      )}
      {!pool && (
        <div className="sm:col-span-3">
          <span className={LABEL}>Bonuses (cumulative: every threshold reached pays)</span>
          {bonuses.map((b, i) => (
            <div key={i} className="flex gap-2 items-center mt-1">
              <input className={FLD} inputMode="numeric" aria-label="Tickets sold" disabled={disabled} defaultValue={String(b.sold)}
                onBlur={(e) => {
                  const n = Number(e.target.value);
                  if (Number.isInteger(n) && n > 0) set({ bonuses: bonuses.map((x, j) => (j === i ? { ...x, sold: n } : x)) });
                }} />
              <span className="text-xs text-slate-500 shrink-0">tickets pays</span>
              <input className={FLD} inputMode="decimal" aria-label="Bonus amount" disabled={disabled} defaultValue={inputFromCents(b.amount_cents)}
                onBlur={(e) => {
                  const c = centsFromInput(e.target.value);
                  if (c !== null && !Number.isNaN(c)) set({ bonuses: bonuses.map((x, j) => (j === i ? { ...x, amount_cents: c } : x)) });
                }} />
              <button type="button" className={BTN} disabled={disabled} onClick={() => set({ bonuses: bonuses.filter((_, j) => j !== i) })}>Remove</button>
            </div>
          ))}
          {bonuses.length < 10 && (
            <button type="button" className={`${BTN} mt-2`} disabled={disabled}
              onClick={() => set({ bonuses: [...bonuses, { sold: 100, amount_cents: 0 }] })}>Add a bonus</button>
          )}
        </div>
      )}
      {!pool && (
        <>
          <label className="block sm:col-span-3">
            <span className={LABEL}>Hospitality</span>
            <textarea className={FLD} rows={2} disabled={disabled} value={terms.hospitality ?? ''} maxLength={2000}
              onChange={(e) => set({ hospitality: e.target.value })} />
          </label>
          <label className="block sm:col-span-3">
            <span className={LABEL}>Rider</span>
            <textarea className={FLD} rows={2} disabled={disabled} value={terms.rider ?? ''} maxLength={2000}
              onChange={(e) => set({ rider: e.target.value })} />
          </label>
        </>
      )}
    </div>
  );
}
