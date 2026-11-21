// The printable QR sheet: one labelled QR code per print placement
// (lib/printPlacements.ts). Laid out for A4 / Letter: two per row, never
// split across pages. Pure presentation; PrintQrSheet loads the data.

import { QRCodeSVG } from 'qrcode.react';
import type { SheetItem } from '../lib/printPlacements';

export default function QrSheet({ title, subtitle, items }: { title: string; subtitle?: string; items: readonly SheetItem[] }) {
  return (
    <section aria-label="QR codes to print" className="text-slate-900">
      <header className="mb-6">
        <h1 className="text-2xl font-black">{title}</h1>
        {subtitle && <p className="text-sm text-slate-600">{subtitle}</p>}
      </header>
      {items.length === 0 ? (
        <p className="text-sm text-slate-600">No placements yet. Add them on the event's Promote page.</p>
      ) : (
        <ul className="grid grid-cols-1 sm:grid-cols-2 print:grid-cols-2 gap-6">
          {items.map((it) => (
            <li key={it.id} className="border border-slate-300 rounded-lg p-4 flex flex-col items-center text-center break-inside-avoid">
              <QRCodeSVG value={it.url} size={180} level="M" marginSize={2} title={`QR code for ${it.name}`} />
              <p className="mt-3 font-bold">{it.name}</p>
              <p className="text-[10px] font-mono text-slate-500 break-all">{it.slug}</p>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
