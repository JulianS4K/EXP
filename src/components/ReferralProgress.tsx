// ReferralProgress — the fan's "bring your friends" card with rewards
// (migs 20260924234500 + 20260926030000).
//
// Shows how many friends' tickets count, how many more earn the next reward,
// a share link tagged with the fan's code, and earned reward codes. A free
// reward is claimed here (exos_redeem_referral_reward mints the ticket);
// a discount code goes in the voucher field on the event page. Rewards live
// in-app only for now (no email). Renders nothing for signed-out users or
// fans without a ticket to the event.

import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Copy, Gift, Share2 } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import {
  myReferralCode, myReferralProgress, redeemReferralReward, type ReferralProgress as Progress,
} from '../lib/referrals';
import { describeReward } from '../lib/referralRewards';
import { buildShareUrl } from '../lib/shareLinks';
import { formatCurrency, publicUrl } from '../lib/utils';

export default function ReferralProgress({
  eventId,
  eventTitle,
  currency = 'USD',
  promoterId,
  onRedeemed,
}: {
  eventId: string;
  eventTitle?: string;
  currency?: string;
  /** The promoter the fan's own ticket came through, passed along in the link. */
  promoterId?: string;
  onRedeemed?: (ticketId: string) => void;
}) {
  const { user } = useAuth();
  const { toast } = useToast();
  const [progress, setProgress] = useState<Progress | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(async () => {
    // Creating the code needs a ticket; no code, no card.
    const code = await myReferralCode(eventId);
    if (!code) { setProgress(null); return; }
    setProgress(await myReferralProgress(eventId));
  }, [eventId]);

  useEffect(() => {
    if (!user) return undefined;
    let alive = true;
    load().catch(() => { if (alive) setProgress(null); });
    return () => { alive = false; };
  }, [user, load]);

  if (!user || !progress?.code) return null;

  const link = buildShareUrl(publicUrl(`event/${eventId}`), {
    role: 'fan', channel: 'copy', promoter: promoterId || undefined, ref: progress.code,
  });
  const rule = progress.rule;
  const earnedCount = progress.rewards.filter((r) => r.status === 'issued').length;
  const capped = rule != null && earnedCount >= rule.maxRewards;
  const remaining = progress.nextThreshold != null ? Math.max(0, progress.nextThreshold - progress.counted) : 0;
  const pct = rule && progress.nextThreshold
    ? Math.min(100, Math.round(((progress.counted % rule.everyN) / rule.everyN) * 100))
    : 100;

  const copy = async (value: string, message: string) => {
    try {
      await navigator.clipboard.writeText(value);
      toast({ kind: 'success', message });
    } catch {
      toast({ kind: 'warn', message: value });
    }
  };

  const share = async () => {
    const text = eventTitle ? `Come to ${eventTitle} with me` : 'Come with me';
    if (typeof navigator !== 'undefined' && navigator.share) {
      try { await navigator.share({ title: eventTitle, text, url: link }); return; } catch { /* cancelled */ }
    }
    await copy(link, 'Link copied.');
  };

  const claim = async (rewardId: string) => {
    setBusy(rewardId);
    try {
      const ticketId = await redeemReferralReward(rewardId);
      toast({ kind: 'success', message: 'Your free ticket is in your wallet.' });
      onRedeemed?.(ticketId);
      await load();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message?.replace(/^exos_redeem_referral_reward: /, '') || 'Could not claim the ticket.' });
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="mb-6 border border-brand-primary/40 bg-brand-primary/5 p-5">
      <p className="type text-[10px] uppercase tracking-widest text-brand-primary mb-1">Bring your friends</p>
      <p className="disp text-2xl tracking-wide text-white">
        {progress.counted === 0 ? 'Nobody yet' : `${progress.counted} ticket${progress.counted === 1 ? '' : 's'} through you`}
      </p>

      {rule ? (
        <>
          <p className="text-xs text-white/60 mt-1">
            Every {rule.everyN} friends' ticket{rule.everyN === 1 ? '' : 's'} earns you{' '}
            {describeReward(rule.kind, rule.value, { currency, tierName: rule.rewardTierName })}
            {rule.rewardEventId !== eventId && rule.rewardEventName ? ` to ${rule.rewardEventName}` : ''}
            {rule.maxRewards > 1 ? `, up to ${rule.maxRewards}` : ''}.
            {!rule.countFreeClaims ? ' Paid tickets count.' : ''}
          </p>
          {!capped && (
            <>
              <div className="h-1.5 bg-white/10 mt-3" aria-hidden>
                <div className="h-1.5 bg-brand-primary" style={{ width: `${pct}%` }} />
              </div>
              <p className="type text-[10px] uppercase tracking-widest text-white/50 mt-2">
                {remaining} more to your next reward
              </p>
            </>
          )}
          {capped && (
            <p className="type text-[10px] uppercase tracking-widest text-white/50 mt-2">You've earned every reward for this event.</p>
          )}
          {!progress.emailConfirmed && (
            <p className="text-xs text-amber-300 mt-2">Confirm your email to receive rewards.</p>
          )}
        </>
      ) : (
        <p className="text-xs text-white/60 mt-1">
          Share your link: we count everyone who gets tickets through you.
        </p>
      )}

      <div className="flex gap-2 mt-4">
        <button type="button" onClick={share}
          className="type flex-1 flex items-center justify-center gap-2 bg-white/5 border border-white/10 text-white/70 py-3 text-[11px] uppercase tracking-widest hover:bg-white hover:text-black transition-colors">
          <Share2 className="w-3.5 h-3.5 text-brand-primary" /> Share your link
        </button>
        <button type="button" onClick={() => copy(link, 'Link copied.')} aria-label="Copy your link"
          className="flex items-center justify-center bg-white/5 border border-white/10 text-white/70 px-4 hover:bg-white hover:text-black transition-colors">
          <Copy className="w-3.5 h-3.5" />
        </button>
      </div>

      {progress.rewards.length > 0 && (
        <ul className="mt-4 space-y-2">
          {progress.rewards.map((r) => (
            <li key={r.id} className="flex items-center gap-3 border border-white/10 bg-black/30 p-3">
              <Gift className="w-4 h-4 text-brand-primary shrink-0" />
              <div className="flex-1 min-w-0">
                <p className="text-sm text-white truncate">
                  {r.free ? 'Free ticket' : r.price != null ? `${formatCurrency(r.price, currency)} ticket` : 'Reward'}
                  {r.tierName ? ` · ${r.tierName}` : ''}
                  {r.eventId !== eventId && r.eventName ? ` · ${r.eventName}` : ''}
                </p>
                <p className="type text-[10px] uppercase tracking-widest text-white/50">
                  {r.status === 'revoked' ? 'Cancelled: friends’ tickets were refunded'
                    : r.redeemed ? 'Used'
                    : r.code}
                </p>
              </div>
              {r.status === 'issued' && !r.redeemed && r.code && (
                r.free ? (
                  <button type="button" disabled={busy === r.id} onClick={() => claim(r.id)}
                    className="type bg-brand-primary text-black px-3 py-2 text-[10px] uppercase tracking-widest disabled:opacity-50">
                    {busy === r.id ? 'Claiming…' : 'Claim'}
                  </button>
                ) : (
                  <div className="flex gap-1">
                    <button type="button" onClick={() => copy(r.code!, 'Code copied.')} aria-label="Copy code"
                      className="bg-white/5 border border-white/10 text-white/70 px-2 py-2 hover:bg-white hover:text-black">
                      <Copy className="w-3.5 h-3.5" />
                    </button>
                    <Link to={`/event/${r.eventId}`}
                      className="type bg-white/5 border border-white/10 text-white/70 px-3 py-2 text-[10px] uppercase tracking-widest hover:bg-white hover:text-black">
                      Use
                    </Link>
                  </div>
                )
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
