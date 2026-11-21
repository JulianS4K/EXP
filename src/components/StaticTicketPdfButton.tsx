// "Download PDF" for static-code tickets (mig 20261121153000): the holder's
// usable static tickets of one event, drawn in the browser by the writer the
// confirmation email uses. Renders nothing when none of them is static.

import { useState } from 'react';
import { Download } from 'lucide-react';
import type { Event, Ticket } from '../types';
import { pdfFileName, saveBytes, staticCodeUsable, staticTicketsPdfFor } from '../lib/staticTickets';

export default function StaticTicketPdfButton({ tickets, event, viewerId, holder, className = '' }: {
  tickets: Ticket[];
  event: Pick<Event, 'title' | 'date' | 'timezone' | 'location'>;
  viewerId: string | null | undefined;
  holder?: string | null;
  className?: string;
}) {
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const usable = tickets.filter((t) => staticCodeUsable(t, viewerId));
  if (usable.length === 0) return null;
  const save = async () => {
    setBusy(true);
    setFailed(false);
    try {
      const pdf = await staticTicketsPdfFor(usable, event, viewerId, holder);
      if (pdf) saveBytes(pdf, pdfFileName(event.title));
    } catch {
      setFailed(true);
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className={className}>
      <button
        type="button"
        onClick={() => void save()}
        disabled={busy}
        className="type inline-flex items-center gap-2 border border-white/20 px-3 py-2 text-[11px] uppercase tracking-widest text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary"
      >
        <Download className="w-3.5 h-3.5" aria-hidden="true" />
        {usable.length === 1 ? 'Download PDF ticket' : `Download PDF tickets (${usable.length})`}
      </button>
      {failed && <p role="alert" className="type text-[11px] text-rose-400 mt-1">Couldn't make the PDF. Try again.</p>}
    </div>
  );
}
