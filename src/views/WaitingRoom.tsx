// /event/:id/queue: the waiting room on its own (mig 20261118120000), a light
// page for a big on-sale (the share link an organizer can post: it loads less
// than the event page). Shows this browser's place in line; once admitted, or
// when there is no line, it sends the buyer to the event page to buy. No login.

import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { applyMeta } from '../lib/meta';
import { supabase } from '../lib/supabase';
import WaitingRoomGate from '../components/WaitingRoomGate';

export default function WaitingRoom() {
  const { id = '' } = useParams<{ id: string }>();
  const [ev, setEv] = useState<{ name: string; timezone: string | null } | null>(null);

  useEffect(() => {
    try { applyMeta({ title: 'Waiting room', description: 'Your place in line for tickets.' }); } catch { /* non-fatal */ }
    let alive = true;
    supabase.from('exos_public_events').select('name, timezone').eq('id', id).maybeSingle()
      .then(({ data }) => { if (alive && data) setEv(data as { name: string; timezone: string | null }); });
    return () => { alive = false; };
  }, [id]);

  return (
    <div className="wall min-h-[70vh] flex flex-col items-center justify-center px-6">
      <div className="w-full max-w-md space-y-6">
        <h1 className="disp text-3xl md:text-4xl tracking-tight text-center">{ev?.name ?? 'Tickets'}</h1>
        <WaitingRoomGate eventId={id} timezone={ev?.timezone}>
          <div className="text-center space-y-4">
            <p className="type text-sm text-white/80">You can pick your tickets now.</p>
            <Link to={`/event/${id}`}
              className="inline-block px-6 py-3 rounded-full bg-brand-primary text-black text-xs font-black uppercase tracking-widest">
              Go to tickets
            </Link>
          </div>
        </WaitingRoomGate>
      </div>
    </div>
  );
}
