// /print/qr/:eventId — the event's print placements as a printable sheet of
// labelled QR codes (bare layout: no navbar or footer, like /invoice). Opened
// from the Promote page's "Posters and flyers" section. Owner / manager /
// finance only (exos_print_placements refuses anyone else).

import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { Printer } from 'lucide-react';
import QrSheet from '../components/QrSheet';
import { eventSharePath, getEventForEdit } from '../lib/events';
import { publicUrl } from '../lib/utils';
import { placementSheet, type SheetItem } from '../lib/printPlacements';
import { listPlacements } from '../lib/printPlacementsApi';

export default function PrintQrSheet() {
  const { eventId } = useParams();
  const [state, setState] = useState<{ title: string; items: SheetItem[] } | 'loading' | 'failed'>('loading');

  useEffect(() => {
    let cancelled = false;
    if (!eventId) return undefined;
    void (async () => {
      try {
        const [ev, placements] = await Promise.all([getEventForEdit(eventId), listPlacements(eventId)]);
        if (cancelled) return;
        if (!ev) { setState('failed'); return; }
        setState({ title: ev.title, items: placementSheet(publicUrl(eventSharePath(ev)), placements) });
      } catch {
        if (!cancelled) setState('failed');
      }
    })();
    return () => { cancelled = true; };
  }, [eventId]);

  return (
    <div className="min-h-screen bg-white text-slate-900">
      <div className="max-w-3xl mx-auto px-4 py-8 print:p-0 print:max-w-none">
        <div className="flex flex-wrap items-center justify-between gap-3 mb-6 print:hidden">
          <Link to={`/dashboard/event/${eventId ?? ''}/promote`} className="text-sm font-bold text-slate-700 underline">Back to Promote</Link>
          {typeof state === 'object' && state.items.length > 0 && (
            <button type="button" onClick={() => window.print()}
              className="inline-flex items-center gap-2 px-4 py-2 rounded bg-slate-900 text-white text-sm font-bold">
              <Printer size={14} aria-hidden="true" /> Print
            </button>
          )}
        </div>
        {state === 'loading' ? (
          <p className="text-sm text-slate-600">Loading…</p>
        ) : state === 'failed' ? (
          <p className="text-sm text-slate-600">This sheet isn't available. Sign in as the event's owner, manager or finance.</p>
        ) : (
          <QrSheet title={state.title} subtitle="Scan for tickets. Each code is tracked to its spot." items={state.items} />
        )}
      </div>
    </div>
  );
}
