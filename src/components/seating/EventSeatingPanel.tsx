// Edit Event → Reserved seating (docs/seating.md). Pick one of the org's seat
// maps, give each section (or row) a ticket type, save
// (exos_set_event_seating). Seated ticket types get their capacity from the
// seats; their capacity field on the form is then ignored by the database.
// Once seats are sold, owners and managers block / unblock single seats here
// (kills, house seats, camera positions). Self-contained, not part of the
// form submit; owner / manager only (the RPCs check it).

import { useEffect, useMemo, useState } from 'react';
import { Armchair } from 'lucide-react';
import SeatMapSvg from './SeatMapSvg';
import { LEVEL_COLORS, getEventSeating, getSeatStatus, listSeatMaps, setEventSeating, setSeatsBlocked, type EventSeatingAdmin, type SeatMapRecord, type StaffSeat } from '../../lib/seatingApi';
import { capacityByTier, levelsError, tierForSeat, type Levels, type SeatMap } from '../../lib/seating';

interface TierLite { id: string; name: string; kind?: string }

const SEL = 'bg-black border border-white/15 px-2 py-2 text-white text-sm min-h-9';
const BTN = 'min-h-9 px-4 text-[11px] font-bold uppercase tracking-widest border';

export default function EventSeatingPanel({ eventId, orgId, tiers, canEdit }: { eventId: string; orgId: string; tiers: TierLite[]; canEdit: boolean }) {
  const [maps, setMaps] = useState<SeatMapRecord[]>([]);
  const [current, setCurrent] = useState<EventSeatingAdmin | null | undefined>(undefined);
  const [mapId, setMapId] = useState<string>('');
  const [levels, setLevels] = useState<Levels>({});
  const [status, setStatus] = useState<StaffSeat[]>([]);
  const [blockMode, setBlockMode] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = async () => {
    try {
      const [m, c] = await Promise.all([listSeatMaps(orgId).catch(() => []), getEventSeating(eventId)]);
      setMaps(m);
      setCurrent(c);
      setMapId(c?.mapId ?? '');
      setLevels(c?.levels ?? {});
      setStatus(c ? await getSeatStatus(eventId).catch(() => []) : []);
    } catch (e) {
      setMsg((e as Error).message);
      setCurrent(null);
    }
  };
  useEffect(() => { void load(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [eventId, orgId]);

  const chosen: SeatMap | null = useMemo(() => {
    if (current && mapId === (current.mapId ?? '')) return current.map;
    return maps.find((m) => m.id === mapId)?.map ?? null;
  }, [current, maps, mapId]);
  const sold = status.some((s) => s.status === 'sold' || s.status === 'held');
  const byId = useMemo(() => new Map(status.map((s) => [s.seatId, s])), [status]);
  const tierIds = tiers.map((t) => t.id);
  const colorOf = (tid: string) => LEVEL_COLORS[Math.max(0, tierIds.indexOf(tid)) % LEVEL_COLORS.length];
  const problem = chosen ? levelsError(chosen, levels, tierIds) : null;
  const caps = chosen ? capacityByTier(chosen, levels) : {};

  const save = async (clear = false) => {
    setBusy(true);
    setMsg(null);
    try {
      const r = await setEventSeating(eventId, clear ? null : mapId, clear ? {} : levels);
      setMsg(clear ? 'Reserved seating removed: every ticket type is general admission again.' : `Saved: ${r.seatCount} seats.`);
      await load();
    } catch (e) {
      setMsg((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const toggleBlock = async (seatId: string) => {
    const s = byId.get(seatId);
    if (!s || (s.status !== 'available' && s.status !== 'blocked')) {
      setMsg('Only free seats can be blocked.');
      return;
    }
    try {
      await setSeatsBlocked(eventId, [seatId], s.status === 'available', 'blocked in the event editor');
      setStatus(await getSeatStatus(eventId));
    } catch (e) {
      setMsg((e as Error).message);
    }
  };

  if (current === undefined) return null;
  const counts = status.reduce<Record<string, number>>((n, s) => ({ ...n, [s.status]: (n[s.status] ?? 0) + 1 }), {});

  return (
    <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-6" data-testid="event-seating">
      <div>
        <h2 className="disp text-lg uppercase tracking-wide text-white leading-none flex items-center gap-2">
          <Armchair className="w-5 h-5 text-brand-primary" aria-hidden="true" /> Reserved seating
        </h2>
        <p className="type text-xs text-white/50 mt-2">
          Sell ticket types as seats on a map. Buyers pick their seats; box office and partners keep selling general admission.
          Maps are built under your org's settings → Seat maps.
        </p>
      </div>

      {maps.length === 0 && !current ? (
        <p className="type text-xs text-white/60">No seat maps yet. Build one in your org settings.</p>
      ) : (
        <div className="flex flex-wrap items-end gap-3">
          <label className="type text-[11px] uppercase tracking-widest text-white/60">
            Seat map
            <select className={`${SEL} ml-2`} value={mapId} disabled={!canEdit || sold}
              onChange={(e) => { setMapId(e.target.value); setLevels({}); }}>
              <option value="">General admission (no map)</option>
              {maps.map((m) => <option key={m.id} value={m.id}>{m.name} ({m.seatCount} seats)</option>)}
            </select>
          </label>
          {current && <span className="type text-[11px] text-white/50">Saved: {current.seatCount} seats{current.mapVersion ? ` (map v${current.mapVersion})` : ''}</span>}
        </div>
      )}

      {chosen && (
        <>
          <div className="space-y-2">
            <p className="type text-[11px] uppercase tracking-widest text-white/60">Ticket type per section</p>
            {chosen.sections.map((sec) => (
              <div key={sec.id} className="flex flex-wrap items-center gap-3">
                <span className="w-40 text-sm text-white">{sec.name}{sec.kind === 'ga' ? ` (standing, ${sec.capacity ?? 0})` : ''}</span>
                <select className={SEL} value={levels[sec.id] ?? ''} disabled={!canEdit || sold} aria-label={`Ticket type for ${sec.name}`}
                  onChange={(e) => setLevels((l) => {
                    const next = { ...l };
                    if (e.target.value) next[sec.id] = e.target.value; else delete next[sec.id];
                    return next;
                  })}>
                  <option value="">Not on sale</option>
                  {tiers.filter((t) => t.kind !== 'table').map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                </select>
                {sec.kind === 'seated' && sec.rows.length > 1 && canEdit && !sold && (
                  <details className="text-xs text-white/60">
                    <summary className="cursor-pointer">Per row</summary>
                    <div className="mt-2 grid grid-cols-2 gap-1">
                      {sec.rows.map((r) => (
                        <label key={r.id} className="flex items-center gap-1">
                          Row {r.label}
                          <select className={SEL} value={levels[`${sec.id}-${r.id}`] ?? ''}
                            onChange={(e) => setLevels((l) => {
                              const next = { ...l };
                              if (e.target.value) next[`${sec.id}-${r.id}`] = e.target.value; else delete next[`${sec.id}-${r.id}`];
                              return next;
                            })}>
                            <option value="">(section)</option>
                            {tiers.filter((t) => t.kind !== 'table').map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                          </select>
                        </label>
                      ))}
                    </div>
                  </details>
                )}
              </div>
            ))}
            <ul className="type text-[11px] text-white/60 space-y-0.5">
              {Object.entries(caps).map(([tid, c]) => (
                <li key={tid}>
                  <span className="inline-block w-2.5 h-2.5 rounded-full mr-1.5 align-middle" style={{ background: colorOf(tid) }} aria-hidden="true" />
                  {tiers.find((t) => t.id === tid)?.name ?? tid}: {c.seats > 0 ? `${c.seats} seats (capacity set from the map)` : `${c.ga} standing`}
                </li>
              ))}
            </ul>
          </div>

          <SeatMapSvg
            map={chosen}
            ariaLabel="Event seat map"
            seatStyle={(seat, row, sec) => {
              const st = byId.get(seat.id)?.status;
              if (st === 'sold') return { fill: '#71717a', cross: true };
              if (st === 'held') return { fill: '#a1a1aa' };
              if (st === 'blocked') return { fill: '#18181b', stroke: '#f87171', cross: true };
              const tid = tierForSeat(levels, sec.id, row.id, seat.id);
              return tid ? { fill: colorOf(tid) } : { fill: '#3f3f46', opacity: 0.6 };
            }}
            seatTitle={(seat, row, sec) => `${sec.name} · Row ${row.label} · Seat ${seat.label}: ${byId.get(seat.id)?.status ?? 'not saved yet'}`}
            onSeatClick={blockMode && canEdit ? (id) => void toggleBlock(id) : undefined}
            gaStyle={(sec) => ({ fill: levels[sec.id] ? colorOf(levels[sec.id]) : '#3f3f46', opacity: 0.25 })}
            height={320}
          />
          {status.length > 0 && (
            <p className="type text-[11px] text-white/60">
              {counts.available ?? 0} available · {counts.held ?? 0} held · {counts.sold ?? 0} sold · {counts.blocked ?? 0} blocked
            </p>
          )}
          {problem && mapId && <p className="text-sm text-amber-300" role="status">{problem}</p>}
        </>
      )}

      {msg && <p className="text-sm text-white/80" role="status">{msg}</p>}

      {canEdit && (
        <div className="flex flex-wrap gap-2">
          {!sold && mapId && (
            <button type="button" disabled={busy || !!problem} onClick={() => void save()}
              className={`${BTN} border-brand-primary text-brand-primary disabled:opacity-40`}>
              Save seating
            </button>
          )}
          {!sold && current && !mapId && (
            <button type="button" disabled={busy} onClick={() => void save(true)} className={`${BTN} border-white/30 text-white`}>
              Remove reserved seating
            </button>
          )}
          {current && (
            <button type="button" aria-pressed={blockMode} onClick={() => setBlockMode((v) => !v)}
              className={`${BTN} ${blockMode ? 'border-red-400 text-red-300' : 'border-white/20 text-white/70'}`}>
              {blockMode ? 'Blocking: click a free seat to block or unblock' : 'Block seats'}
            </button>
          )}
        </div>
      )}
      {sold && <p className="type text-[11px] text-white/50">Seats are held or sold, so the map and its ticket types are locked. Block or unblock single seats instead.</p>}
    </section>
  );
}
