// "Pay separately" on the event page's ticket picker (group buy v2, mig
// 20261108120000): hold the picked number of seats for 30 minutes and send
// each friend their own link to pay. Signed-in buyers only (the hold is theirs
// until friends pay); the host page is /group-pay/:groupId.

import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Users } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { canStartGroup, maxGroupSize, startGroup } from '../lib/groupPay';

export default function GroupPayStart({ eventId, tierId, quantity, maxPerOrder, signedIn }: {
  eventId: string;
  tierId: string;
  quantity: number;
  maxPerOrder?: number | null;
  signedIn: boolean;
}) {
  const navigate = useNavigate();
  const { toast } = useToast();
  const [busy, setBusy] = useState(false);
  const max = maxGroupSize(maxPerOrder);
  const ok = canStartGroup(quantity, maxPerOrder);

  const start = async () => {
    if (!signedIn) {
      toast({ kind: 'info', message: 'Sign in to start a group.' });
      return;
    }
    setBusy(true);
    try {
      const g = await startGroup(eventId, tierId, quantity);
      navigate(`/group-pay/${g.id}`);
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
      setBusy(false);
    }
  };

  return (
    <div className="mt-3 border border-white/15 p-3" data-testid="group-pay-start">
      <p className="type text-[11px] text-white/70 uppercase tracking-widest flex items-center gap-2">
        <Users className="w-4 h-4" /> Pay separately: up to {max} friends
      </p>
      <p className="type text-[11px] text-white/50 leading-relaxed mt-1">
        We hold {ok ? quantity : 'the'} seats for 30 minutes and you get one link per seat. Each friend pays for their own
        ticket; anything unpaid goes back on sale (or you cover the rest).
      </p>
      <button
        type="button"
        disabled={busy || !ok}
        onClick={() => void start()}
        className="disp w-full mt-3 border border-white/30 text-white py-3 text-base tracking-wide hover:border-white transition-colors disabled:opacity-40"
      >
        {busy ? 'Holding seats…' : ok ? `Start a group of ${quantity}` : 'Pick 2 or more tickets'}
      </button>
    </div>
  );
}
