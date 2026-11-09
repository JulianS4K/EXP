// "Pay separately" on the event page's ticket picker (group buy v2, mig
// 20261108120000): hold the picked number of seats for 30 minutes and send
// each friend their own link to pay. Signed-in buyers only (the hold is theirs
// until friends pay); the host page is /group-pay/:groupId. A timed type
// (mig 20261110110000): the whole group takes the slot picked above.
// Paused by the operator 2026-11-09 (mig 20261111120000): renders nothing
// unless the build sets VITE_EXOS_GROUP_PAY=on.

import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Users } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { canStartGroup, maxGroupSize, startGroup } from '../lib/groupPay';
import { groupPayEnabled } from '../lib/groupPayFlag';

type Props = {
  eventId: string;
  tierId: string;
  quantity: number;
  maxPerOrder?: number | null;
  signedIn: boolean;
  /** A timed type: a slot must be picked first. */
  needsSlot?: boolean;
  slotId?: string | null;
};

export default function GroupPayStart(props: Props) {
  return groupPayEnabled() ? <GroupPayStartOn {...props} /> : null;
}

function GroupPayStartOn({ eventId, tierId, quantity, maxPerOrder, signedIn, needsSlot = false, slotId = null }: Props) {
  const navigate = useNavigate();
  const { toast } = useToast();
  const [busy, setBusy] = useState(false);
  const max = maxGroupSize(maxPerOrder);
  const ok = canStartGroup(quantity, maxPerOrder) && (!needsSlot || !!slotId);

  const start = async () => {
    if (!signedIn) {
      toast({ kind: 'info', message: 'Sign in to start a group.' });
      return;
    }
    setBusy(true);
    try {
      const g = await startGroup(eventId, tierId, quantity, needsSlot ? slotId : null);
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
        We hold {ok ? quantity : 'the'} seats{needsSlot ? ' in your time slot' : ''} for 30 minutes and you get one link per seat. Each friend pays for their own
        ticket; anything unpaid goes back on sale (or you cover the rest).
      </p>
      <button
        type="button"
        disabled={busy || !ok}
        onClick={() => void start()}
        className="disp w-full mt-3 border border-white/30 text-white py-3 text-base tracking-wide hover:border-white transition-colors disabled:opacity-40"
      >
        {busy ? 'Holding seats…' : ok ? `Start a group of ${quantity}` : needsSlot && !slotId && canStartGroup(quantity, maxPerOrder) ? 'Pick a time slot first' : 'Pick 2 or more tickets'}
      </button>
    </div>
  );
}
