// /orgs/:orgId/seat-maps — the org's reusable seat maps (docs/seating.md).
// Owners and managers build maps; other staff view them (RLS on
// exos_seat_maps enforces it). A seated section is a grid generated from rows
// × seats with a numbering scheme, row letters or numbers, spacing, curve and
// stagger; regenerating keeps seat marks. Drag a section on the map to move
// it. In "mark seats" mode a click cycles a seat through wheelchair space →
// companion → restricted view → plain. Standing areas have a capacity and a
// box. An event uses a map from Edit Event → Reserved seating.

import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Plus, Save, Trash2 } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import SeatMapSvg from '../components/seating/SeatMapSvg';
import {
  DEFAULT_GEN, NUMBERING_SCHEMES, countSeats, generateSection, newShortId, regenerateSection, starterMap, validateMap,
  type NumberingScheme, type SeatMap, type Section, type SectionGen,
} from '../lib/seating';
import { deleteSeatMap, listSeatMaps, saveSeatMap, type SeatMapRecord } from '../lib/seatingApi';

const INPUT = 'w-full rounded border border-slate-200 bg-white px-2 py-1.5 text-sm';
const LABEL = 'block text-[10px] font-black uppercase tracking-widest text-slate-400 mb-1';
const SCHEME_LABEL: Record<NumberingScheme, string> = {
  sequential: '1, 2, 3…', reverse: '…3, 2, 1', odd: '1, 3, 5…', even: '2, 4, 6…', 'odd-reverse': '…5, 3, 1', 'even-reverse': '…6, 4, 2',
};

function nextMark(s: { accessible?: boolean; companion?: boolean; obstructed?: boolean }) {
  if (s.accessible) return { companion: true };
  if (s.companion) return { obstructed: true };
  if (s.obstructed) return {};
  return { accessible: true };
}

export default function OrgSeatMaps() {
  const { orgId } = useParams();
  const navigate = useNavigate();
  const { user, isAdmin } = useAuth();
  const { orgs } = useOrganization();
  const entry = orgs.find((o) => o.org.id === orgId);
  const canEdit = isAdmin || entry?.membership.role === 'owner' || entry?.membership.role === 'manager';
  const [maps, setMaps] = useState<SeatMapRecord[] | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [map, setMap] = useState<SeatMap | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [markMode, setMarkMode] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const reload = async () => {
    if (!orgId) return;
    try {
      setMaps(await listSeatMaps(orgId));
    } catch (e) {
      setError((e as Error).message);
      setMaps([]);
    }
  };
  useEffect(() => { void reload(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [orgId]);

  const sec = useMemo(() => map?.sections.find((s) => s.id === selected) ?? null, [map, selected]);
  const problem = map ? validateMap(map) : null;

  const open = (r: SeatMapRecord | null) => {
    setError(null);
    setEditingId(r?.id ?? null);
    setName(r?.name ?? 'Main room');
    setMap(r ? r.map : starterMap());
    setSelected(r ? r.map.sections[0]?.id ?? null : 's1');
  };
  const patchSection = (id: string, fn: (s: Section) => Section) =>
    setMap((m) => (m ? { ...m, sections: m.sections.map((s) => (s.id === id ? fn(s) : s)) } : m));
  const patchGen = (patch: Partial<SectionGen>) => {
    if (!sec || sec.kind !== 'seated') return;
    patchSection(sec.id, (s) => regenerateSection(s, { ...(s.gen ?? DEFAULT_GEN), ...patch }));
  };
  const addSection = (kind: 'seated' | 'ga') => {
    if (!map) return;
    const id = newShortId(kind === 'ga' ? 'g' : 's', new Set(map.sections.map((s) => s.id)));
    const next: Section = kind === 'ga'
      ? { id, name: 'Standing', kind: 'ga', x: 40, y: 420, w: 220, h: 120, capacity: 100, rows: [] }
      : generateSection(id, `Section ${map.sections.length + 1}`, 120, 300, DEFAULT_GEN);
    setMap({ ...map, sections: [...map.sections, next] });
    setSelected(id);
  };
  const save = async () => {
    if (!orgId || !map) return;
    const err = validateMap(map);
    if (err) { setError(err); return; }
    setSaving(true);
    setError(null);
    try {
      const saved = await saveSeatMap(orgId, { id: editingId ?? undefined, name, map });
      setEditingId(saved.id);
      await reload();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };
  const remove = async (id: string) => {
    if (!window.confirm('Delete this seat map? Events already using it keep their copy.')) return;
    try {
      await deleteSeatMap(id);
      if (editingId === id) { setMap(null); setEditingId(null); }
      await reload();
    } catch (e) {
      setError((e as Error).message);
    }
  };

  if (!user) return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 font-bold uppercase tracking-widest">Sign in required.</div>;

  const gen = sec?.kind === 'seated' ? sec.gen ?? DEFAULT_GEN : null;
  return (
    <div className="min-h-screen bg-tm-gray text-slate-900">
      <div className="max-w-6xl mx-auto px-4 py-10">
        <button onClick={() => navigate(`/orgs/${orgId}/settings`)}
          className="flex items-center gap-1.5 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6">
          <ArrowLeft size={14} strokeWidth={2.5} /> Org settings
        </button>
        <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">{entry?.org.name ?? 'Organization'}</p>
        <h1 className="text-3xl md:text-4xl font-bold tracking-tight mb-2">Seat maps</h1>
        <p className="text-sm text-slate-600 mb-6 max-w-prose">
          Build a room's map once and use it for every reserved-seating show there (Edit Event → Reserved seating).
          Box office and partner sales stay general admission.
        </p>
        {error && <p className="mb-4 text-sm text-rose-600" role="alert">{error}</p>}

        <div className="grid grid-cols-1 lg:grid-cols-4 gap-6">
          <aside className="space-y-2">
            {maps === null ? <p className="text-sm text-slate-400">Loading…</p> : maps.length === 0 ? (
              <p className="text-sm text-slate-500">No seat maps yet.</p>
            ) : maps.map((r) => (
              <div key={r.id} className={`flex items-center justify-between gap-2 rounded border bg-white p-3 ${editingId === r.id ? 'border-tm-blue' : 'border-slate-200'}`}>
                <button type="button" className="text-left text-sm" onClick={() => open(r)}>
                  <span className="font-bold block">{r.name}</span>
                  <span className="text-slate-500">{r.seatCount.toLocaleString()} seats · v{r.version}</span>
                </button>
                {canEdit && (
                  <button type="button" aria-label={`Delete ${r.name}`} onClick={() => void remove(r.id)} className="text-slate-400 hover:text-rose-600 p-2">
                    <Trash2 size={14} />
                  </button>
                )}
              </div>
            ))}
            {canEdit && (
              <button type="button" onClick={() => open(null)}
                className="w-full inline-flex items-center justify-center gap-1.5 rounded border border-dashed border-slate-300 bg-white p-3 text-sm font-bold text-slate-700 hover:bg-slate-50">
                <Plus size={14} /> New seat map
              </button>
            )}
          </aside>

          {map && (
            <section className="lg:col-span-3 space-y-4">
              <div className="flex flex-wrap items-end gap-3">
                <label className="flex-1 min-w-48">
                  <span className={LABEL}>Name</span>
                  <input className={INPUT} value={name} maxLength={100} disabled={!canEdit} onChange={(e) => setName(e.target.value)} />
                </label>
                <label>
                  <span className={LABEL}>Stage label</span>
                  <input className={INPUT} value={map.stage.label} maxLength={40} disabled={!canEdit}
                    onChange={(e) => setMap({ ...map, stage: { ...map.stage, label: e.target.value } })} />
                </label>
                <p className="text-sm text-slate-500">{countSeats(map).toLocaleString()} seats</p>
                {canEdit && (
                  <button type="button" onClick={() => void save()} disabled={saving || !!problem || !name.trim()}
                    className="inline-flex items-center gap-1.5 rounded bg-tm-blue px-4 py-2 text-sm font-bold text-white disabled:opacity-50">
                    <Save size={14} /> {saving ? 'Saving…' : 'Save'}
                  </button>
                )}
              </div>
              {problem && <p className="text-sm text-amber-700" role="status">{problem}</p>}

              <div className="rounded bg-slate-900 p-2">
                <SeatMapSvg
                  map={map}
                  ariaLabel={`Seat map ${name}`}
                  seatStyle={(seat) => ({
                    fill: seat.accessible ? '#38bdf8' : seat.companion ? '#a78bfa' : seat.obstructed ? '#f59e0b' : '#00FF00',
                    opacity: 0.9,
                  })}
                  seatTitle={(seat, row, s) => `${s.name} · Row ${row.label} · Seat ${seat.label}${seat.accessible ? ' (wheelchair space)' : seat.companion ? ' (companion)' : seat.obstructed ? ' (restricted view)' : ''}`}
                  onSeatClick={canEdit && markMode ? (seatId, s) => patchSection(s.id, (x) => ({
                    ...x,
                    rows: x.rows.map((r) => ({
                      ...r,
                      seats: r.seats.map((q) => {
                        if (q.id !== seatId) return q;
                        const { accessible: _a, companion: _c, obstructed: _o, ...rest } = q;
                        return { ...rest, ...nextMark(q) };
                      }),
                    })),
                  })) : undefined}
                  selectedSectionId={selected}
                  onSectionSelect={(s) => setSelected(s.id)}
                  onSectionMove={canEdit && !markMode ? (id, x, y) => patchSection(id, (s) => ({ ...s, x, y })) : undefined}
                  height={420}
                />
              </div>
              <p className="text-xs text-slate-500">
                Drag a section to move it. Legend: green seat, <span className="text-sky-600">blue wheelchair space</span>,{' '}
                <span className="text-violet-600">violet companion</span>, <span className="text-amber-600">amber restricted view</span>.
              </p>

              {canEdit && (
                <div className="flex flex-wrap gap-2">
                  <button type="button" onClick={() => addSection('seated')} className="rounded border border-slate-200 bg-white px-3 py-2 text-xs font-bold">+ Seated section</button>
                  <button type="button" onClick={() => addSection('ga')} className="rounded border border-slate-200 bg-white px-3 py-2 text-xs font-bold">+ Standing area</button>
                  <button type="button" aria-pressed={markMode} onClick={() => setMarkMode((v) => !v)}
                    className={`rounded border px-3 py-2 text-xs font-bold ${markMode ? 'border-tm-blue bg-blue-50 text-tm-blue' : 'border-slate-200 bg-white'}`}>
                    {markMode ? 'Marking seats (click a seat)' : 'Mark seats'}
                  </button>
                </div>
              )}

              <div className="flex flex-wrap gap-2" role="tablist" aria-label="Sections">
                {map.sections.map((s) => (
                  <button key={s.id} type="button" role="tab" aria-selected={s.id === selected} onClick={() => setSelected(s.id)}
                    className={`rounded-full border px-3 py-1 text-xs font-bold ${s.id === selected ? 'border-tm-blue bg-blue-50 text-tm-blue' : 'border-slate-200 bg-white text-slate-600'}`}>
                    {s.name}
                  </button>
                ))}
              </div>

              {sec && (
                <fieldset disabled={!canEdit} className="rounded border border-slate-200 bg-white p-4 grid grid-cols-2 md:grid-cols-4 gap-3">
                  <label className="col-span-2">
                    <span className={LABEL}>Section name</span>
                    <input className={INPUT} value={sec.name} maxLength={40} onChange={(e) => patchSection(sec.id, (s) => ({ ...s, name: e.target.value }))} />
                  </label>
                  {sec.kind === 'ga' ? (
                    <>
                      <label>
                        <span className={LABEL}>Capacity</span>
                        <input type="number" min={1} className={INPUT} value={sec.capacity ?? 0}
                          onChange={(e) => patchSection(sec.id, (s) => ({ ...s, capacity: Math.max(0, Math.round(Number(e.target.value) || 0)) }))} />
                      </label>
                      <label>
                        <span className={LABEL}>Box (w × h)</span>
                        <span className="flex gap-1">
                          <input type="number" min={10} className={INPUT} value={sec.w ?? 200} onChange={(e) => patchSection(sec.id, (s) => ({ ...s, w: Number(e.target.value) || 10 }))} aria-label="Width" />
                          <input type="number" min={10} className={INPUT} value={sec.h ?? 120} onChange={(e) => patchSection(sec.id, (s) => ({ ...s, h: Number(e.target.value) || 10 }))} aria-label="Height" />
                        </span>
                      </label>
                    </>
                  ) : gen && (
                    <>
                      <label>
                        <span className={LABEL}>Rows</span>
                        <input type="number" min={1} max={200} className={INPUT} value={gen.rows} onChange={(e) => patchGen({ rows: Math.max(1, Math.min(200, Number(e.target.value) || 1)) })} />
                      </label>
                      <label>
                        <span className={LABEL}>Seats per row</span>
                        <input type="number" min={1} max={200} className={INPUT} value={gen.seatsPerRow} onChange={(e) => patchGen({ seatsPerRow: Math.max(1, Math.min(200, Number(e.target.value) || 1)) })} />
                      </label>
                      <label>
                        <span className={LABEL}>Numbering</span>
                        <select className={INPUT} value={gen.scheme} onChange={(e) => patchGen({ scheme: e.target.value as NumberingScheme })}>
                          {NUMBERING_SCHEMES.map((x) => <option key={x} value={x}>{SCHEME_LABEL[x]}</option>)}
                        </select>
                      </label>
                      <label>
                        <span className={LABEL}>First seat number</span>
                        <input type="number" min={0} className={INPUT} value={gen.startNumber} onChange={(e) => patchGen({ startNumber: Math.max(0, Number(e.target.value) || 0) })} />
                      </label>
                      <label>
                        <span className={LABEL}>Rows named</span>
                        <select className={INPUT} value={gen.rowStyle} onChange={(e) => patchGen({ rowStyle: e.target.value === 'numbers' ? 'numbers' : 'letters', rowStart: e.target.value === 'numbers' ? '1' : 'A' })}>
                          <option value="letters">A, B, C…</option>
                          <option value="numbers">1, 2, 3…</option>
                        </select>
                      </label>
                      <label>
                        <span className={LABEL}>First row</span>
                        <input className={INPUT} value={gen.rowStart} maxLength={3} onChange={(e) => patchGen({ rowStart: e.target.value })} />
                      </label>
                      <label>
                        <span className={LABEL}>Seat spacing</span>
                        <input type="number" min={4} max={200} className={INPUT} value={gen.spacing} onChange={(e) => patchGen({ spacing: Math.max(4, Number(e.target.value) || 4) })} />
                      </label>
                      <label>
                        <span className={LABEL}>Curve</span>
                        <input type="range" min={0} max={1} step={0.1} className="w-full" value={gen.curve} onChange={(e) => patchGen({ curve: Number(e.target.value) })} />
                      </label>
                      <label className="flex items-center gap-2 text-sm">
                        <input type="checkbox" checked={gen.stagger} onChange={(e) => patchGen({ stagger: e.target.checked })} /> Stagger rows
                      </label>
                    </>
                  )}
                  {canEdit && map.sections.length > 1 && (
                    <button type="button" onClick={() => { setMap({ ...map, sections: map.sections.filter((s) => s.id !== sec.id) }); setSelected(map.sections[0]?.id ?? null); }}
                      className="col-span-2 md:col-span-4 justify-self-start inline-flex items-center gap-1.5 text-xs font-bold text-rose-600">
                      <Trash2 size={12} /> Remove section
                    </button>
                  )}
                </fieldset>
              )}
            </section>
          )}
        </div>
      </div>
    </div>
  );
}
