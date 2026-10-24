import { Link } from 'react-router-dom';
import { paidNeedsConnect } from '../lib/payments';

/**
 * Paid tiers on an org that hasn't finished Stripe Connect: buyers can't pay
 * until it has. `ready` comes from useOrgPaymentsReady (null = unknown, no notice).
 */
export default function ConnectPaymentsNotice({
  orgId,
  prices,
  ready,
}: {
  orgId: string | null | undefined;
  prices: Array<number | string | null | undefined>;
  ready: boolean | null;
}) {
  if (!orgId || !paidNeedsConnect(prices, ready)) return null;
  return (
    <div role="alert" className="border border-amber-400/40 bg-amber-400/10 px-4 py-3 text-xs text-amber-100">
      <strong className="font-bold">Buyers can't pay for these tickets yet.</strong> Your organization hasn't
      finished Stripe setup, so checkout refuses priced tiers. Free tiers work now.{' '}
      <Link to={`/orgs/${orgId}/settings`} className="underline font-bold">Set up payments</Link>
    </div>
  );
}

/** The question asked before publishing paid tiers without Stripe Connect. */
export const PUBLISH_WITHOUT_PAYMENTS =
  "Your organization hasn't finished Stripe setup, so buyers can't pay for the priced tickets yet (free tickets work). Publish anyway?";
