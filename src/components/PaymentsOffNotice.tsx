import { hasPaidPrice, paymentsEnabled } from '../lib/payments';

/** Tells organizers that priced tiers can't be bought until payments are on. */
export default function PaymentsOffNotice({ prices }: { prices: Array<number | string | null | undefined> }) {
  if (paymentsEnabled() || !hasPaidPrice(prices)) return null;
  return (
    <div role="note" className="border border-yellow-400/40 bg-yellow-400/10 px-4 py-3 text-xs text-yellow-100">
      <strong className="font-bold">Paid tickets aren't on sale yet.</strong> Online payments are switched off, so
      buyers see priced tiers as "Coming soon". Free tiers, comps and box-office tickets work now.
    </div>
  );
}
