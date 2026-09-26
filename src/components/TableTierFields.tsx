// Tier editor block for table packages (mig 20260926050000), shared by
// CreateEvent and EditEvent. A table tier's quantity is the number of
// tables; each table admits `party size` people and mints that many tickets
// to the buyer. The tier price is the deposit per table; the minimum spend
// is shown to the buyer and the door, never charged online.

import type { TableTierDraft } from '../lib/tables';

const inputCls =
  'w-full bg-black border border-white/20 py-3 px-5 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors disabled:opacity-50';
const labelCls = 'type text-[9px] text-white/40 uppercase tracking-widest ml-1';

export default function TableTierFields({
  value,
  onChange,
  locked = false,
  currency = 'USD',
}: {
  value: TableTierDraft;
  onChange: (next: TableTierDraft) => void;
  /** True once the tier has sales: table on/off and party size can't change. */
  locked?: boolean;
  currency?: string;
}) {
  const set = (patch: Partial<TableTierDraft>) => onChange({ ...value, ...patch });
  return (
    <div className="col-span-2 border border-white/10 p-4 space-y-4">
      <label className="flex items-center gap-3 cursor-pointer">
        <input
          type="checkbox"
          checked={value.isTable}
          disabled={locked}
          onChange={(e) => set({ isTable: e.target.checked, partySize: value.partySize || (e.target.checked ? '4' : '') })}
          className="w-4 h-4 accent-brand-primary"
        />
        <span className="type text-[10px] text-white uppercase tracking-widest">Sell as tables (bottle service, booths)</span>
      </label>
      {value.isTable && (
        <>
          <p className="type text-[9px] text-white/40 uppercase tracking-widest leading-relaxed">
            Quantity = number of tables. Price = deposit per table. Each table gives the buyer one ticket per person.
            {locked ? ' This tier has sales, so party size is locked.' : ''}
          </p>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div className="space-y-2">
              <label className={labelCls}>Party size</label>
              <input
                type="number"
                min={1}
                max={50}
                required
                disabled={locked}
                className={inputCls}
                value={value.partySize}
                onChange={(e) => set({ partySize: e.target.value })}
              />
            </div>
            <div className="space-y-2">
              <label className={labelCls}>Minimum spend ({currency.toUpperCase()})</label>
              <input
                type="number"
                min={0}
                step="1"
                placeholder="optional"
                className={inputCls}
                value={value.minSpend}
                onChange={(e) => set({ minSpend: e.target.value })}
              />
            </div>
            <div className="space-y-2">
              <label className={labelCls}>Section</label>
              <input
                type="text"
                maxLength={60}
                placeholder="e.g. Mezzanine"
                className={inputCls}
                value={value.sectionLabel}
                onChange={(e) => set({ sectionLabel: e.target.value })}
              />
            </div>
          </div>
        </>
      )}
    </div>
  );
}
