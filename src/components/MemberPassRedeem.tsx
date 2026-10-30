// Event page: the member price notice, and "Use my pass" / "Use a member free
// ticket" for the selected ticket type (docs/memberships.md). Redemptions are
// $0 orders through the normal fulfillment (capacity and limits apply); the
// request id makes a double tap return the same tickets.

import { useEffect, useMemo, useState } from 'react';
import { BadgeCheck } from 'lucide-react';
import {
  myMemberBenefit, myMemberships, myPasses, passCovers, passLeftLabel, redeemMemberFree, redeemPass,
  type MemberBenefit, type MyMembership, type MyPass,
} from '../lib/commerce';

interface Props {
  orgId?: string | null;
  event: { id: string; starts_at: string | null };
  tierId: string | null;
  quantity: number;
  signedIn: boolean;
  onIssued: (count: number) => void;
}

export default function MemberPassRedeem({ orgId, event, tierId, quantity, signedIn, onIssued }: Props) {
  const [benefit, setBenefit] = useState<MemberBenefit | null>(null);
  const [passes, setPasses] = useState<MyPass[]>([]);
  const [members, setMembers] = useState<MyMembership[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  // One request id per choice on screen: a retry returns the same tickets.
  const requestId = useMemo(() => crypto.randomUUID(), [tierId, quantity]);

  useEffect(() => {
    if (!signedIn || !orgId) return;
    myMemberBenefit(orgId).then(setBenefit).catch(() => undefined);
    myPasses().then((p) => setPasses(p.filter((x) => x.org_id === orgId && x.status === 'active'))).catch(() => undefined);
    myMemberships().then((m) => setMembers(m.filter((x) => x.org_id === orgId))).catch(() => undefined);
  }, [signedIn, orgId]);

  if (!signedIn || !orgId) return null;
  const usable = tierId ? passes.filter((p) => passCovers(p.eligibility, event, tierId)
    && (p.credits_total === null || p.credits_total - p.credits_used >= quantity)) : [];
  const free = members.filter((m) => Number(m.benefits.free_tickets_per_period) > m.free_used_this_period
    && quantity <= 1 + Number(m.benefits.guest_allowance ?? 0));

  const run = async (fn: () => ReturnType<typeof redeemPass>) => {
    setBusy(true); setErr(null);
    try {
      const r = await fn();
      if (r.error) setErr(r.error); else onIssued(r.ticket_ids?.length ?? 0);
    } catch (x: any) { setErr(x?.message || 'Could not use it.'); }
    finally { setBusy(false); }
  };

  if (!benefit && usable.length === 0 && free.length === 0) return null;
  return (
    <div className="mb-4 border border-white/10 p-3 space-y-2 type text-[11px] text-white/70">
      {benefit && Number(benefit.discount_percent) > 0 && (
        <p className="flex items-center gap-2"><BadgeCheck className="w-4 h-4" />
          {benefit.product_name}: {Number(benefit.discount_percent)}% member price at checkout
          (up to {1 + benefit.guest_allowance} ticket{benefit.guest_allowance > 0 ? 's' : ''} per order).</p>
      )}
      {tierId && usable.map((p) => (
        <button key={p.id} disabled={busy} className="block underline" onClick={() => run(() => redeemPass(p.id, event.id, tierId, quantity, requestId))}>
          Use my {p.name} ({passLeftLabel(p)})
        </button>
      ))}
      {tierId && free.map((m) => (
        <button key={m.id} disabled={busy} className="block underline" onClick={() => run(() => redeemMemberFree(m.id, event.id, tierId, quantity, requestId))}>
          Use a free member ticket ({m.product_name})
        </button>
      ))}
      {err && <p role="alert" className="text-red-400">{err}</p>}
    </div>
  );
}
