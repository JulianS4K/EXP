// SVG rendering of a seat map (src/lib/seating.ts), shared by the seat-map
// editor, the event editor's block mode and the buyer's seat picker.
//
// Zoom with the +/- buttons (or + - 0 while the map has focus) and pan with
// the arrow keys or by dragging the background. The SVG is a picture with an
// accessible name; every seat is also reachable without a pointer through
// the list views the callers render next to it.

import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent, type PointerEvent as ReactPointerEvent } from 'react';
import { Minus, Plus, RotateCcw } from 'lucide-react';
import type { Row, Seat, SeatMap, Section } from '../../lib/seating';

export interface SeatStyle {
  fill: string;
  stroke?: string;
  /** Draw an × over the seat (blocked / sold). */
  cross?: boolean;
  opacity?: number;
}

export interface SeatMapSvgProps {
  map: SeatMap;
  ariaLabel: string;
  seatStyle: (seat: Seat, row: Row, section: Section) => SeatStyle;
  seatTitle?: (seat: Seat, row: Row, section: Section) => string;
  onSeatClick?: (seatId: string, section: Section) => void;
  gaStyle?: (section: Section) => SeatStyle;
  /** Editor: outline the selected section, drag sections to move them. */
  selectedSectionId?: string | null;
  onSectionSelect?: (section: Section) => void;
  onSectionMove?: (sectionId: string, x: number, y: number) => void;
  height?: number;
}

function seatRadius(sec: Section): number {
  const spacing = sec.gen?.spacing ?? 24;
  return Math.max(1.5, Math.min(10, spacing * 0.38));
}

const ZOOM_BTN = 'min-h-9 min-w-9 bg-black/80 border border-white/20 text-white flex items-center justify-center hover:border-brand-primary';

export default function SeatMapSvg(props: SeatMapSvgProps) {
  const { map, ariaLabel, seatStyle, seatTitle, onSeatClick, gaStyle, selectedSectionId, onSectionSelect, onSectionMove, height = 380 } = props;
  const full = useMemo(() => ({ x: -20, y: -20, w: map.width + 40, h: map.height + 40 }), [map.width, map.height]);
  const [view, setView] = useState(full);
  const svgRef = useRef<SVGSVGElement | null>(null);
  const drag = useRef<{ kind: 'pan' | 'section'; id?: string; startX: number; startY: number; orig: { x: number; y: number } } | null>(null);

  useEffect(() => setView(full), [full]);

  const zoom = useCallback((factor: number) => {
    setView((v) => {
      const w = Math.max(80, Math.min(full.w * 2, v.w * factor));
      const h = (w / v.w) * v.h;
      return { x: v.x + (v.w - w) / 2, y: v.y + (v.h - h) / 2, w, h };
    });
  }, [full.w]);
  const pan = (dx: number, dy: number) => setView((v) => ({ ...v, x: v.x + dx * v.w, y: v.y + dy * v.h }));

  const toSvg = (e: { clientX: number; clientY: number }) => {
    const svg = svgRef.current;
    const ctm = svg?.getScreenCTM();
    if (!svg || !ctm) return { x: 0, y: 0 };
    const pt = svg.createSVGPoint();
    pt.x = e.clientX;
    pt.y = e.clientY;
    const p = pt.matrixTransform(ctm.inverse());
    return { x: p.x, y: p.y };
  };

  const onPointerDown = (e: ReactPointerEvent<SVGSVGElement>) => {
    const target = e.target as Element;
    const secId = target.closest('[data-section-id]')?.getAttribute('data-section-id') ?? undefined;
    if (secId && onSectionMove && !target.closest('[data-seat-id]')) {
      const sec = map.sections.find((s) => s.id === secId);
      if (!sec) return;
      onSectionSelect?.(sec);
      const p = toSvg(e);
      drag.current = { kind: 'section', id: secId, startX: p.x, startY: p.y, orig: { x: sec.x, y: sec.y } };
    } else if (!target.closest('[data-seat-id]')) {
      drag.current = { kind: 'pan', startX: e.clientX, startY: e.clientY, orig: { x: view.x, y: view.y } };
    } else {
      return;
    }
    e.currentTarget.setPointerCapture?.(e.pointerId);
  };

  const onPointerMove = (e: ReactPointerEvent<SVGSVGElement>) => {
    const d = drag.current;
    if (!d) return;
    if (d.kind === 'section' && d.id) {
      const p = toSvg(e);
      onSectionMove?.(d.id, Math.round(d.orig.x + p.x - d.startX), Math.round(d.orig.y + p.y - d.startY));
    } else {
      const rect = svgRef.current?.getBoundingClientRect();
      if (!rect) return;
      const dx = ((e.clientX - d.startX) / Math.max(1, rect.width)) * view.w;
      const dy = ((e.clientY - d.startY) / Math.max(1, rect.height)) * view.h;
      setView((v) => ({ ...v, x: d.orig.x - dx, y: d.orig.y - dy }));
    }
  };

  const onKeyDown = (e: KeyboardEvent<SVGSVGElement>) => {
    if (e.key === '+' || e.key === '=') zoom(0.8);
    else if (e.key === '-') zoom(1.25);
    else if (e.key === '0') setView(full);
    else if (e.key === 'ArrowLeft') pan(-0.1, 0);
    else if (e.key === 'ArrowRight') pan(0.1, 0);
    else if (e.key === 'ArrowUp') pan(0, -0.1);
    else if (e.key === 'ArrowDown') pan(0, 0.1);
    else return;
    e.preventDefault();
  };

  const st = map.stage;
  return (
    <div className="relative border border-white/10 bg-black/40">
      <div className="absolute right-2 top-2 z-10 flex gap-1">
        <button type="button" onClick={() => zoom(0.8)} aria-label="Zoom in" className={ZOOM_BTN}><Plus size={14} /></button>
        <button type="button" onClick={() => zoom(1.25)} aria-label="Zoom out" className={ZOOM_BTN}><Minus size={14} /></button>
        <button type="button" onClick={() => setView(full)} aria-label="Reset zoom" className={ZOOM_BTN}><RotateCcw size={14} /></button>
      </div>
      <svg
        ref={svgRef}
        role="img"
        aria-label={ariaLabel}
        tabIndex={0}
        viewBox={`${view.x} ${view.y} ${view.w} ${view.h}`}
        style={{ height, touchAction: 'none' }}
        className="w-full select-none focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={() => { drag.current = null; }}
        onPointerCancel={() => { drag.current = null; }}
        onKeyDown={onKeyDown}
      >
        {st.w > 0 && st.h > 0 && (
          <>
            <rect x={st.x} y={st.y} width={st.w} height={st.h} fill="#27272a" stroke="#52525b" />
            <text x={st.x + st.w / 2} y={st.y + st.h / 2 + 5} textAnchor="middle" fontSize={16} fontWeight={800} fill="#e4e4e7">
              {st.label}
            </text>
          </>
        )}
        {map.sections.map((sec) => {
          const selected = sec.id === selectedSectionId;
          if (sec.kind === 'ga') {
            const s = gaStyle?.(sec) ?? { fill: '#3f3f46' };
            return (
              <g key={sec.id} transform={`translate(${sec.x} ${sec.y})`} data-section-id={sec.id}>
                <rect width={sec.w ?? 100} height={sec.h ?? 60} fill={s.fill} fillOpacity={s.opacity ?? 0.35}
                  stroke={selected ? '#00FF00' : (s.stroke ?? s.fill)} strokeWidth={selected ? 3 : 1.5}>
                  <title>{`${sec.name} (standing${sec.capacity ? `, ${sec.capacity}` : ''})`}</title>
                </rect>
                <text x={(sec.w ?? 100) / 2} y={(sec.h ?? 60) / 2 + 5} textAnchor="middle" fontSize={14} fontWeight={700} fill="#fafafa" pointerEvents="none">
                  {sec.name}
                </text>
              </g>
            );
          }
          const r = seatRadius(sec);
          let minX = Infinity; let minY = Infinity; let maxX = -Infinity; let maxY = -Infinity;
          for (const row of sec.rows) for (const seat of row.seats) {
            minX = Math.min(minX, seat.x); minY = Math.min(minY, seat.y);
            maxX = Math.max(maxX, seat.x); maxY = Math.max(maxY, seat.y);
          }
          if (!Number.isFinite(minX)) { minX = 0; minY = 0; maxX = 0; maxY = 0; }
          return (
            <g key={sec.id} transform={`translate(${sec.x} ${sec.y})`} data-section-id={sec.id} style={{ cursor: onSectionMove ? 'move' : undefined }}>
              <rect x={minX - r - 6} y={minY - r - 6} width={maxX - minX + 2 * r + 12} height={maxY - minY + 2 * r + 12}
                fill={selected ? 'rgba(0,255,0,0.06)' : 'transparent'} stroke={selected ? '#00FF00' : 'rgba(255,255,255,0.08)'}
                strokeDasharray={selected ? undefined : '4 4'} />
              <text x={sec.labelX ?? (minX + maxX) / 2} y={sec.labelY ?? minY - r - 10} textAnchor="middle" fontSize={13} fontWeight={800} fill="#d4d4d8" pointerEvents="none">
                {sec.name}
              </text>
              {sec.rows.map((row) => (
                <g key={row.id}>
                  {row.seats[0] && (
                    <text x={row.seats[0].x - r - 6} y={row.seats[0].y + 3.5} textAnchor="end" fontSize={Math.max(6, r)} fill="#a1a1aa" pointerEvents="none">
                      {row.label}
                    </text>
                  )}
                  {row.seats.map((seat) => {
                    const s = seatStyle(seat, row, sec);
                    return (
                      <g key={seat.id}>
                        <circle
                          data-seat-id={seat.id}
                          cx={seat.x} cy={seat.y} r={r}
                          fill={s.fill} fillOpacity={s.opacity ?? 1}
                          stroke={s.stroke ?? (seat.accessible ? '#ffffff' : 'none')}
                          strokeWidth={s.stroke || seat.accessible ? Math.max(1, r * 0.3) : 0}
                          strokeDasharray={seat.obstructed ? `${r * 0.5} ${r * 0.4}` : undefined}
                          style={{ cursor: onSeatClick ? 'pointer' : undefined }}
                          onClick={onSeatClick ? (e) => { e.stopPropagation(); onSeatClick(seat.id, sec); } : undefined}
                        >
                          {seatTitle && <title>{seatTitle(seat, row, sec)}</title>}
                        </circle>
                        {s.cross && (
                          <path d={`M${seat.x - r * 0.6} ${seat.y - r * 0.6}L${seat.x + r * 0.6} ${seat.y + r * 0.6}M${seat.x + r * 0.6} ${seat.y - r * 0.6}L${seat.x - r * 0.6} ${seat.y + r * 0.6}`}
                            stroke="#18181b" strokeWidth={Math.max(1, r * 0.25)} pointerEvents="none" />
                        )}
                      </g>
                    );
                  })}
                </g>
              ))}
            </g>
          );
        })}
      </svg>
    </div>
  );
}
