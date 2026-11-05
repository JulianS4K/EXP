// Shown on the ticket page while the ticket is printed: the door then takes
// only the paper, so the QR here and the wallet pass are refused (mig
// 20261105120000). The holder can void the paper to use the phone again.

import { useEffect, useState } from 'react';
import { Printer } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { PRINTED_TICKET_TEXT } from '../lib/printOrder';
import { ticketPrintState, voidTicketPrint } from '../lib/ticketPrintApi';

export default function TicketPrintedNotice({ ticketId, onVoided }: { ticketId: string; onVoided?: () => void }) {
  const { toast } = useToast();
  const [printed, setPrinted] = useState(false);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let alive = true;
    setPrinted(false);
    ticketPrintState(ticketId).then((s) => { if (alive) setPrinted(s.printed); }).catch(() => undefined);
    return () => { alive = false; };
  }, [ticketId]);
  if (!printed) return null;
  const voidPaper = async () => {
    if (!window.confirm('Void the paper ticket? It stops working at the door, and this phone (and your wallet pass) works again.')) return;
    setBusy(true);
    try {
      await voidTicketPrint(ticketId);
      setPrinted(false);
      toast({ kind: 'success', message: 'Paper ticket voided. Use your phone at the door.' });
      onVoided?.();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message || 'Something went wrong.' });
    } finally {
      setBusy(false);
    }
  };
  return (
    <div role="status" className="w-full max-w-[300px] mb-4 border-[3px] border-black bg-amber-100 text-black p-3 flex flex-col gap-2">
      <p className="type text-[12px] leading-snug flex items-start gap-2">
        <Printer className="w-4 h-4 shrink-0 mt-0.5" aria-hidden="true" />
        <span>{PRINTED_TICKET_TEXT}</span>
      </p>
      <button type="button" disabled={busy} onClick={() => void voidPaper()}
        className="type text-[11px] uppercase tracking-widest border-2 border-black px-3 py-1.5 self-start hover:bg-black hover:text-white disabled:opacity-50">
        Void the paper ticket
      </button>
    </div>
  );
}
