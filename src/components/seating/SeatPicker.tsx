// Buyer seat picker for reserved-seating tiers (docs/seating.md).
//
// Rendered by the event page only for events with a seat map. The layout and
// seat availability come from two anon-callable reads (seatingApi), so it
// works signed out. Picking is local: the seats are held when the buyer
// checks out (exos-checkout holds them together with the cart hold, for the
// hold's 30 minutes), and a seat someone else took in the meantime comes back
// from checkout as a clear message (the parent then bumps `reloadKey`).
//
// Map view (zoom / pan, coloured by price level) and a list view with one
// toggle button per seat for keyboard and screen-reader use. "Best
// available" picks the best block for the chosen ticket type (pure
// bestAvailable in src/lib/seating.ts) from the current availability.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Accessibility, List, Map as MapIcon, Sparkles, X } from 'lucide-react';
import { bestAvailable, seatIndex, toggleSeat, type PickerData, type Row, type Seat, type Section } from '../../lib/seating';
import { LEVEL_COLORS, getPublicSeating } from '../../lib/seatingApi';
import SeatMapSvg from './SeatMapSvg';

export interface PickerTier {
  id: string;
  name: string;
  /** All-in unit price shown to the buyer. */
  price: number;
}

export interface SeatPickerProps {
  eventId: string;
  tiers: PickerTier[];
  selectedTierId: string | null;
  onSelectTier: (tierId: string) => void;
  maxPerOrder: number;
  formatPrice: (amount: number) => string;
  selection: string[];
  onSelectionChange: (seatIds: string[], labels: string[]) => void;
  /** Bump to reload availability (after checkout said a seat was taken). */
  reloadKey?: number;
}

const UNAVAILABLE = '#3f3f46';
const SELECTED = '#ffffff';
const BTN = 'min-h-9 px-3 text-[11px] font-bold uppercase tracking-widest border inline-flex items-center gap-1.5';

export default function SeatPicker(props: SeatPickerProps) {
  const { eventId, tiers, selectedTierId, onSelectTier, maxPerOrder, formatPrice, selection, onSelectionChange, reloadKey = 0 } = props;
  const [data, setData] = useState<PickerData | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [view, setView] = useState<'map' | 'list'>('map');
  const [bestQty, setBestQty] = useState(2);

  const load = useCallback(async () => {
    try {
      const d = await getPublicSeating(eventId);
      setData(d);
      setLoadError(null);
    } catch (err) {
      setLoadError((err as Error).message || 'Could not load the seat map.');
    }
  }, [eventId]);

  // Load, then refresh availability every 20 s while the page is open.
  useEffect(() => {
    void load();
    const id = window.setInterval(() => void load(), 20_000);
    return () => window.clearInterval(id);
  }, [load, reloadKey]);

  const index = useMemo(() => (data ? seatIndex(data.map) : new Map()), [data]);
  const tierById = useMemo(() => new Map(tiers.map((x) => [x.id, x])), [tiers]);
  const colorOf = useCallback((tierId: string) => {
    const i = data?.seatedTierIds.indexOf(tierId) ?? -1;
    return LEVEL_COLORS[Math.max(0, i) % LEVEL_COLORS.length];
  }, [data]);
  const labelsOf = useCallback((ids: string[]) => ids.map((id) => data?.labels.get(id) ?? id), [data]);

  // Seats that became unavailable drop out of the selection.
  useEffect(() => {
    if (!data || selection.length === 0) return;
    const keep = selection.filter((id) => !data.unavailable.has(id) && data.levels[id]);
    if (keep.length !== selection.length) {
      setMessage('Some of your seats were just taken by someone else. Pick another seat.');
      onSelectionChange(keep, labelsOf(keep));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [data]);

  const pick = (seatId: string) => {
    if (!data) return;
    const tierId = data.levels[seatId];
    if (tierId && !tierById.has(tierId)) {
      setMessage('That seat is not on sale.');
      return;
    }
    const r = toggleSeat(selection, seatId, data, maxPerOrder);
    setMessage(r.error ?? null);
    if (r.error) return;
    if (r.selection.length > 0 && tierId && tierId !== selectedTierId) onSelectTier(tierId);
    onSelectionChange(r.selection, labelsOf(r.selection));
  };

  const pickBest = () => {
    if (!data) return;
    const tierId = selectedTierId && data.seatedTierIds.includes(selectedTierId) ? selectedTierId : data.seatedTierIds.find((x) => tierById.has(x));
    if (!tierId) {
      setMessage('Pick a ticket type first.');
      return;
    }
    const best = bestAvailable(data.map, data.levels, data.unavailable, tierId, bestQty);
    if (!best) {
      setMessage(`There aren't ${bestQty} seats left at this price.`);
      return;
    }
    if (tierId !== selectedTierId) onSelectTier(tierId);
    setMessage(best.together ? null : `No ${bestQty} seats together: these are the best seats apart.`);
    onSelectionChange(best.seatIds, labelsOf(best.seatIds));
  };

  if (loadError) return <p className="text-sm text-red-300" role="alert">{loadError}</p>;
  if (!data) return <p className="type text-[11px] text-white/60 uppercase tracking-widest">Loading the seat map…</p>;

  const seatedTiers = data.seatedTierIds.map((id) => tierById.get(id)).filter((x): x is PickerTier => !!x);
  const sel = new Set(selection);
  const onSale = (seat: Seat) => {
    const tierId = data.levels[seat.id];
    return !!tierId && tierById.has(tierId) && !data.unavailable.has(seat.id);
  };
  const seatTitle = (seat: Seat, row: Row, sec: Section) => {
    const tier = tierById.get(data.levels[seat.id] ?? '');
    const status = !onSale(seat) ? 'unavailable' : tier ? `${tier.name} · ${formatPrice(tier.price)}` : 'not on sale';
    const extras = [seat.accessible ? 'wheelchair space' : '', seat.companion ? 'companion seat' : '', seat.obstructed ? 'restricted view' : ''].filter(Boolean);
    return `${sec.name} · Row ${row.label} · Seat ${seat.label}: ${status}${extras.length ? ` (${extras.join(', ')})` : ''}`;
  };

  return (
    <div className="space-y-4" data-testid="seat-picker">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="type text-[11px] text-white/60 uppercase tracking-widest">Pick your seats</p>
        <div className="flex gap-1" role="group" aria-label="Seat map or list">
          <button type="button" aria-pressed={view === 'map'} onClick={() => setView('map')}
            className={`${BTN} ${view === 'map' ? 'border-brand-primary text-white' : 'border-white/15 text-white/60'}`}>
            <MapIcon size={12} aria-hidden="true" /> Map
          </button>
          <button type="button" aria-pressed={view === 'list'} onClick={() => setView('list')}
            className={`${BTN} ${view === 'list' ? 'border-brand-primary text-white' : 'border-white/15 text-white/60'}`}>
            <List size={12} aria-hidden="true" /> List
          </button>
        </div>
      </div>

      <ul className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-white/80" aria-label="Legend">
        {seatedTiers.map((x) => (
          <li key={x.id} className="flex items-center gap-1.5">
            <span className="inline-block w-3 h-3 rounded-full" style={{ background: colorOf(x.id) }} aria-hidden="true" />
            {x.name} · {formatPrice(x.price)}
          </li>
        ))}
        <li className="flex items-center gap-1.5"><span className="inline-block w-3 h-3 rounded-full border-2 border-black" style={{ background: SELECTED }} aria-hidden="true" />Your seats</li>
        <li className="flex items-center gap-1.5"><span className="inline-block w-3 h-3 rounded-full" style={{ background: UNAVAILABLE }} aria-hidden="true" />Unavailable</li>
        <li className="flex items-center gap-1.5"><Accessibility size={12} aria-hidden="true" />Wheelchair space (white ring)</li>
      </ul>

      {view === 'map' ? (
        <SeatMapSvg
          map={data.map}
          ariaLabel="Seat map. Use the list view to pick seats with a keyboard or screen reader."
          seatStyle={(seat) => {
            if (sel.has(seat.id)) return { fill: SELECTED, stroke: '#00FF00' };
            if (!onSale(seat)) return { fill: UNAVAILABLE, opacity: 0.8 };
            const tierId = data.levels[seat.id];
            const dim = !!selectedTierId && data.seatedTierIds.includes(selectedTierId) && tierId !== selectedTierId;
            return { fill: colorOf(tierId), opacity: dim ? 0.35 : 1 };
          }}
          seatTitle={seatTitle}
          onSeatClick={(id) => pick(id)}
          gaStyle={(sec) => ({ fill: data.levels[sec.id] ? colorOf(data.levels[sec.id]) : '#3f3f46', opacity: 0.2 })}
          height={340}
        />
      ) : (
        <div className="max-h-96 overflow-y-auto border border-white/10 p-3 space-y-4" data-testid="seat-list">
          {data.map.sections.filter((s) => s.kind === 'seated').map((sec) => {
            const rows = sec.rows
              .map((row) => ({ row, seats: row.seats.filter((seat) => tierById.has(data.levels[seat.id] ?? '')) }))
              .filter((r) => r.seats.length > 0);
            if (rows.length === 0) return null;
            return (
              <fieldset key={sec.id} className="space-y-2">
                <legend className="text-xs font-black uppercase tracking-widest text-white/80">{sec.name}</legend>
                {rows.map(({ row, seats }) => (
                  <div key={row.id} className="flex flex-wrap items-center gap-1">
                    <span className="w-16 text-xs text-white/60">Row {row.label}</span>
                    {seats.map((seat) => {
                      const free = onSale(seat);
                      const on = sel.has(seat.id);
                      return (
                        <button key={seat.id} type="button" disabled={!free && !on} aria-pressed={on}
                          aria-label={seatTitle(seat, row, sec)} onClick={() => pick(seat.id)}
                          className={`min-w-9 min-h-9 px-1 text-xs font-bold border ${on ? 'bg-brand-primary text-black border-white' : 'bg-white/5 text-white border-white/20 hover:border-brand-primary'} ${!free && !on ? 'opacity-30 line-through' : ''}`}>
                          {seat.label}{seat.accessible ? ' ♿' : ''}
                        </button>
                      );
                    })}
                  </div>
                ))}
              </fieldset>
            );
          })}
        </div>
      )}

      <div className="flex flex-wrap items-end gap-2">
        <label className="type text-[11px] uppercase tracking-widest text-white/70" htmlFor="best-qty">
          How many
          <select id="best-qty" value={bestQty} onChange={(e) => setBestQty(Number(e.target.value))}
            className="ml-2 min-h-9 bg-white/5 border border-white/15 px-2 text-white">
            {Array.from({ length: maxPerOrder }, (_, i) => i + 1).map((n) => <option key={n} value={n}>{n}</option>)}
          </select>
        </label>
        <button type="button" onClick={pickBest} className={`${BTN} border-white/20 text-white hover:border-brand-primary`} data-testid="best-available">
          <Sparkles size={12} aria-hidden="true" /> Best available
        </button>
      </div>

      {message && <p className="text-sm text-amber-300" role="alert" data-testid="seat-message">{message}</p>}

      {selection.length > 0 && (
        <div className="border border-brand-primary/40 bg-brand-primary/5 p-3 space-y-2" data-testid="seat-selection" aria-live="polite">
          <p className="type text-[11px] uppercase tracking-widest text-white">
            Your seat{selection.length > 1 ? 's' : ''} ({selection.length})
          </p>
          <ul className="text-sm text-white/80 space-y-1">
            {selection.map((id) => {
              const e = index.get(id);
              return (
                <li key={id} className="flex items-center justify-between gap-2">
                  <span>{data.labels.get(id) ?? id}</span>
                  <button type="button" className="text-white/60 hover:text-white min-h-9 min-w-9 flex items-center justify-center"
                    aria-label={`Remove seat ${e?.seat.label ?? id}`} onClick={() => pick(id)}>
                    <X size={14} />
                  </button>
                </li>
              );
            })}
          </ul>
          <p className="type text-[10px] text-white/50">Your seats are held for 30 minutes once you check out.</p>
          <button type="button" className="type text-[11px] uppercase tracking-widest text-white/60 underline" onClick={() => onSelectionChange([], [])}>
            Clear
          </button>
        </div>
      )}
    </div>
  );
}
