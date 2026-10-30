// Event page extras before "Buy": pay with a gift card, add a donation
// (docs/gift-cards.md, docs/giving.md). The event page hands off to Stripe's
// hosted Checkout, so no card field (and no script) is added here (docs/pci.md).
//
// The gift card is only checked by exos-checkout (rate-limited); this field
// validates the check character locally so a typo is caught before the round
// trip. The donation goes to the org's first open campaign that offers
// add-a-donation in the event's currency, as its own line after tax.

import { useEffect, useState } from 'react';
import { Gift, HeartHandshake } from 'lucide-react';
import {
  checkoutDonationOption, formatGiftCardCode, giftCardCheckOk, majorToCents, normalizeGiftCardCode,
  roundUpDonationCents, type GivingCampaign,
} from '../lib/commerce';
import { formatCurrency } from '../lib/utils';

export interface CheckoutExtrasValue {
  giftCardCode?: string;
  donation?: { campaign_id: string; amount_cents: number };
}

interface Props {
  orgId?: string | null;
  currency: string;
  /** Order total in cents before the donation (for the round-up choice). */
  orderCents: number;
  onChange: (v: CheckoutExtrasValue) => void;
}

const inputCls = 'w-full bg-white/5 border border-white/15 px-3 py-2 text-sm text-white placeholder-white/30 focus:outline-none focus:border-brand-primary';

export default function CheckoutExtras({ orgId, currency, orderCents, onChange }: Props) {
  const [campaign, setCampaign] = useState<GivingCampaign | null>(null);
  const [code, setCode] = useState('');
  const [donation, setDonation] = useState<number | null>(null);
  const [custom, setCustom] = useState('');
  const [showGift, setShowGift] = useState(false);

  useEffect(() => {
    let live = true;
    if (!orgId) { setCampaign(null); return undefined; }
    checkoutDonationOption(orgId, currency).then((c) => { if (live) setCampaign(c); }).catch(() => undefined);
    return () => { live = false; };
  }, [orgId, currency]);

  const codeOk = code.trim() === '' || giftCardCheckOk(code);
  useEffect(() => {
    const v: CheckoutExtrasValue = {};
    const norm = normalizeGiftCardCode(code);
    if (norm && giftCardCheckOk(norm)) v.giftCardCode = norm;
    if (campaign && donation && donation >= 100) v.donation = { campaign_id: campaign.id, amount_cents: donation };
    onChange(v);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [code, donation, campaign?.id]);

  const roundUp = campaign?.round_up ? roundUpDonationCents(orderCents) : 0;
  const choices = [...(campaign?.suggested_cents ?? []).slice(0, 4), ...(roundUp >= 100 ? [roundUp] : [])];

  return (
    <div className="mb-4 space-y-3">
      {campaign && (
        <div className="border border-white/10 p-3">
          <div className="type text-[11px] text-white/70 flex items-center gap-2 mb-2">
            <HeartHandshake className="w-4 h-4" /> Add a donation to {campaign.name}
          </div>
          <div className="flex flex-wrap gap-2">
            <button type="button" onClick={() => setDonation(null)}
              className={`px-3 py-1 text-xs border ${donation === null ? 'border-brand-primary text-brand-primary' : 'border-white/20 text-white/60'}`}>
              No thanks
            </button>
            {choices.map((c, i) => (
              <button key={`${c}-${i}`} type="button" onClick={() => { setDonation(c); setCustom(''); }}
                className={`px-3 py-1 text-xs border ${donation === c && !custom ? 'border-brand-primary text-brand-primary' : 'border-white/20 text-white/60'}`}>
                {formatCurrency(c / 100, currency)}{c === roundUp && roundUp > 0 && i === choices.length - 1 ? ' (round up)' : ''}
              </button>
            ))}
            <input aria-label="Other amount" inputMode="decimal" placeholder="Other" value={custom}
              onChange={(e) => { setCustom(e.target.value); setDonation(majorToCents(e.target.value)); }}
              className={`${inputCls} w-24`} />
          </div>
          <p className="type mt-2 text-[10px] text-white/40">Added after tax, no fees.</p>
        </div>
      )}
      {showGift ? (
        <div>
          <label className="type text-[11px] text-white/70 flex items-center gap-2 mb-1" htmlFor="gift-card-code">
            <Gift className="w-4 h-4" /> Gift card code
          </label>
          <input id="gift-card-code" autoComplete="off" spellCheck={false} placeholder="XXXX-XXXX-XXXX-XXXX"
            value={code} onChange={(e) => setCode(e.target.value)}
            onBlur={() => { if (giftCardCheckOk(code)) setCode(formatGiftCardCode(code)); }}
            className={`${inputCls} font-mono tracking-widest uppercase`} />
          {!codeOk && <p className="type mt-1 text-[11px] text-red-400">That code doesn't look right: check for a typo.</p>}
          {codeOk && code.trim() !== '' && (
            <p className="type mt-1 text-[11px] text-white/50">Applied at checkout: the card pays what it can, the rest goes on your card.</p>
          )}
        </div>
      ) : (
        <button type="button" onClick={() => setShowGift(true)} className="type text-[11px] text-white/60 underline flex items-center gap-1">
          <Gift className="w-3 h-3" /> Have a gift card?
        </button>
      )}
    </div>
  );
}
