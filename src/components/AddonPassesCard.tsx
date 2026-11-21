// The holder's add-on entry codes for an event (mig 20261107110000; DICE
// Extra.hasSeparateAccessBarcode): one rotating code per add-on unit with its
// own barcode (a VIP lounge, a merch pickup), signed exactly like a ticket's
// (lib/barcode signAddonBarcode, 30-second buckets, the day key). Staff scan it
// at the check-in list for that add-on. Hidden when there are none, offline,
// or before the migration (exos_my_addon_passes missing). Each usable unit
// gets "Add to … Wallet" (a pass of its own, mig 20261108110000) once the
// wallet probe says that wallet is set up, and "Reissue" once it is in a
// wallet (a new wallet code; the old one stops working, mig 20261111140000).

import { useEffect, useState } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import { currentBucket, signAddonBarcode } from '../lib/barcode';
import { secondsLeftInWindow, serverNow } from '../lib/serverClock';
import { listMyAddonPasses, type AddonPass } from '../lib/addonPasses';
import { addonReissueEligible, addonWalletEligible } from '../lib/walletButtons';
import { AddonWalletButtons, useAvailableWallets } from './WalletButtons';

export default function AddonPassesCard({ eventId, ownerId }: { eventId: string; ownerId: string }) {
  const [passes, setPasses] = useState<AddonPass[]>([]);
  const [codes, setCodes] = useState<Record<string, string>>({});
  const [left, setLeft] = useState(secondsLeftInWindow());

  useEffect(() => {
    let live = true;
    listMyAddonPasses(eventId).then((p) => { if (live) setPasses(p); }).catch(() => { if (live) setPasses([]); });
    return () => { live = false; };
  }, [eventId]);

  const live = passes.filter((p) => p.status !== 'voided' && p.barcodeSecret);
  const sig = live.map((p) => p.id).join(',');
  useEffect(() => {
    if (live.length === 0) return undefined;
    let cancelled = false;
    let lastBucket = -1;
    const refresh = async () => {
      const bucket = currentBucket(serverNow());
      lastBucket = bucket;
      const next: Record<string, string> = {};
      for (const p of live) {
        try {
          next[p.id] = await signAddonBarcode(p.id, ownerId, p.barcodeSecret as string, bucket);
        } catch {
          /* no secure context: no code */
        }
      }
      if (!cancelled) setCodes(next);
    };
    void refresh();
    const t = setInterval(() => {
      setLeft(secondsLeftInWindow());
      if (currentBucket(serverNow()) !== lastBucket) void refresh();
    }, 1000);
    return () => { cancelled = true; clearInterval(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sig, ownerId]);

  // Wallet buttons per unit (POST /exos-wallet/addon-pass): only once the
  // session probe says a wallet is set up, as the ticket's buttons.
  const wallets = useAvailableWallets(passes.some(addonWalletEligible));

  if (passes.length === 0) return null;
  return (
    <section className="mt-6 border border-white/10 p-5 space-y-4" aria-labelledby="addon-passes-title" data-testid="addon-passes">
      <h3 id="addon-passes-title" className="type text-[11px] text-white/60 uppercase tracking-widest">Add-on entry codes</h3>
      <p className="type text-[11px] text-white/50">Show these at their own entrance (not the main door). They refresh every 30 seconds.</p>
      <ul className="grid gap-4 sm:grid-cols-2">
        {passes.map((p) => (
          <li key={p.id} className="bg-white/[0.03] border border-white/5 p-4 flex flex-col items-center gap-3">
            <p className="type text-sm text-white">{p.addonName}{p.unitCount > 1 ? ` · ${p.unitIndex} of ${p.unitCount}` : ''}</p>
            {p.status === 'voided' ? (
              <p className="type text-[11px] text-brand-accent">Refunded: this code no longer works.</p>
            ) : codes[p.id] ? (
              <div className="bg-white p-3" aria-label={`${p.addonName} entry code`}>
                <QRCodeSVG value={codes[p.id]} size={160} level="H" includeMargin={false} fgColor="#000000" />
              </div>
            ) : (
              <p className="type text-[11px] text-white/50">Preparing the code…</p>
            )}
            <p className="type text-[10px] text-white/40 uppercase tracking-widest">
              {p.status === 'used' ? 'Scanned in' : p.status === 'voided' ? '' : `Refreshes in ${left}s`}
            </p>
            {addonWalletEligible(p) && (
              <AddonWalletButtons
                passId={p.id}
                name={`${p.addonName}${p.unitCount > 1 ? ` ${p.unitIndex} of ${p.unitCount}` : ''}`}
                kinds={wallets.kinds}
                platform={wallets.platform}
                onUnavailable={wallets.markUnavailable}
                canReissue={addonReissueEligible(p)}
              />
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}
