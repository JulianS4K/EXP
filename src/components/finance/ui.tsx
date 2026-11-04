// Shared bits for the offer / settlement / finance screens
// (docs/offers-settlements.md). Amounts live in cents; inputs show major
// units.

import { ReactNode } from 'react';
import { formatCents } from '../../lib/dealMath';

export const BTN =
  'px-3 py-2 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest text-slate-600 hover:border-tm-blue hover:text-tm-blue transition-colors disabled:opacity-40';
export const BTN_PRIMARY =
  'px-3 py-2 rounded bg-slate-900 text-white text-[10px] font-black uppercase tracking-widest hover:bg-slate-700 transition-colors disabled:opacity-40';
export const FLD =
  'bg-white border border-slate-200 rounded px-2 py-1.5 text-sm text-slate-900 w-full focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60';
export const LABEL = 'text-[10px] font-black uppercase tracking-widest text-slate-400';

/** "1500.5" / "1,500.50" → 150050; '' → null; junk → NaN. */
export function centsFromInput(v: string): number | null {
  const s = v.trim().replace(/[,\s$€£]/g, '');
  if (!s) return null;
  if (!/^\d+(\.\d{0,2})?$/.test(s)) return Number.NaN;
  return Math.round(Number(s) * 100);
}

/** 150050 → "1500.50"; null → ''. */
export function inputFromCents(c: number | null | undefined): string {
  return c === null || c === undefined ? '' : (Math.round(c) / 100).toFixed(2);
}

export function Money({ cents, currency, strong }: { cents: number; currency: string; strong?: boolean }) {
  const s = formatCents(cents, currency);
  return <span className={`tabular-nums ${cents < 0 ? 'text-red-600' : ''} ${strong ? 'font-bold' : ''}`}>{s}</span>;
}

export function Section({ title, children, action }: { title: string; children: ReactNode; action?: ReactNode }) {
  return (
    <section className="bg-white border border-slate-200 rounded shadow-sm p-5 mb-6">
      <div className="flex items-center justify-between gap-3 mb-4">
        <h2 className="text-xs font-black uppercase tracking-widest text-slate-500">{title}</h2>
        {action}
      </div>
      {children}
    </section>
  );
}

export function Row({ label, children, strong }: { label: ReactNode; children: ReactNode; strong?: boolean; key?: string | number }) {
  return (
    <div className={`flex justify-between gap-4 py-1.5 border-b border-slate-100 text-sm ${strong ? 'font-bold text-slate-900' : 'text-slate-700'}`}>
      <span>{label}</span>
      <span className="text-right">{children}</span>
    </div>
  );
}

export const STATUS_STYLE: Record<string, string> = {
  draft: 'bg-slate-100 text-slate-600',
  sent: 'bg-blue-50 text-blue-700',
  accepted: 'bg-green-50 text-green-700',
  declined: 'bg-red-50 text-red-700',
  expired: 'bg-amber-50 text-amber-700',
  cancelled: 'bg-slate-100 text-slate-400 line-through',
  finalized: 'bg-green-50 text-green-700',
};

export function StatusBadge({ status }: { status: string }) {
  return (
    <span className={`text-[10px] font-black uppercase tracking-widest px-2 py-0.5 rounded ${STATUS_STYLE[status] ?? 'bg-slate-100 text-slate-600'}`}>
      {status}
    </span>
  );
}
