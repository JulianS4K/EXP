// The reserved seat(s) of tickets (mig 20261030140000), for My Tickets and the
// ticket page. Renders nothing for general admission (or before the
// migration). One small read per set of ticket ids.

import { useEffect, useState } from 'react';
import { Armchair } from 'lucide-react';
import { getTicketSeats, type TicketSeat } from '../../lib/seatingApi';

export function useTicketSeats(ticketIds: string[]): Map<string, TicketSeat> {
  const key = [...ticketIds].sort().join(',');
  const [seats, setSeats] = useState<Map<string, TicketSeat>>(new Map());
  useEffect(() => {
    let live = true;
    if (!key) {
      setSeats(new Map());
      return undefined;
    }
    getTicketSeats(key.split(',')).then((m) => { if (live) setSeats(m); }).catch(() => undefined);
    return () => { live = false; };
  }, [key]);
  return seats;
}

export default function TicketSeats({ ticketIds, className = '' }: { ticketIds: string[]; className?: string }) {
  const seats = useTicketSeats(ticketIds);
  const labels = ticketIds.map((id) => seats.get(id)?.label).filter((x): x is string => !!x);
  if (labels.length === 0) return null;
  return (
    <p className={`type text-[11px] uppercase tracking-widest flex items-start gap-1.5 ${className}`} data-testid="ticket-seats">
      <Armchair className="w-3.5 h-3.5 mt-px shrink-0" aria-hidden="true" />
      <span>{labels.length > 1 ? 'Seats: ' : 'Seat: '}{labels.join('; ')}</span>
    </p>
  );
}
