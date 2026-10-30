// The event page's ticket card for a link-out event (mig 20261029170000):
// the imported price range and ticket types (display only) and a "Buy on
// Eventbrite / Luma / Posh" button to the organizer's own checkout. Exos
// sells nothing here: no tier picker, quantity, voucher or checkout.

import { ExternalLink, Ticket } from 'lucide-react';
import type { Event } from '../types';
import { formatCurrency } from '../lib/utils';
import { linkOutPriceLabel, platformLabel, type PublicLinkOut } from '../lib/linkOut';

export default function LinkOutBuyCard({ event, linkOut, onBuy }: { event: Event; linkOut: PublicLinkOut; onBuy?: () => void }) {
  const name = platformLabel(linkOut.platform);
  const price = linkOutPriceLabel(linkOut, event.currency);
  const soldOut = linkOut.status === 'sold_out';
  const gone = linkOut.status === 'cancelled' || linkOut.status === 'ended';
  const cur = linkOut.currency ?? event.currency ?? 'USD';
  return (
    <div>
      <div className="mb-8">
        <p className="type text-[11px] text-white/60 uppercase tracking-widest mb-2">price</p>
        <p className="disp text-5xl neon tracking-tight">{price ?? `On ${name}`}</p>
        <p className="type mt-1 text-[11px] uppercase tracking-widest text-white/60">as listed on {name}</p>
      </div>

      {linkOut.ticketTypes.length > 0 && (
        <ul className="mb-8 divide-y divide-white/5 border-t border-b border-white/5" aria-label="Ticket types">
          {linkOut.ticketTypes.map((t, i) => (
            <li key={`${t.name}-${i}`} className="flex justify-between gap-3 type text-[11px] py-3 uppercase tracking-widest">
              <span className="text-white/80 truncate">{t.name}</span>
              <span className={t.soldOut ? 'text-brand-accent shrink-0' : 'text-white shrink-0'}>
                {t.soldOut ? 'sold out' : t.free || t.minPrice === 0 ? 'free' : t.minPrice !== null ? formatCurrency(t.minPrice, cur) : ''}
              </span>
            </li>
          ))}
        </ul>
      )}

      {gone ? (
        <p role="status" className="type text-[11px] uppercase tracking-widest text-brand-accent">
          {linkOut.status === 'cancelled' ? `cancelled on ${name}` : 'this event is over'}
        </p>
      ) : (
        <a href={linkOut.url} target="_blank" rel="noopener noreferrer" onClick={onBuy}
          className="disp w-full bg-brand-primary text-black py-4 text-xl tracking-wide flex items-center justify-center gap-3 hover:scale-[1.01] transition-transform">
          <Ticket className="w-5 h-5" />
          <span className="tracking-wide">{soldOut ? `Sold out · see ${name}` : `Buy on ${name}`}</span>
          <ExternalLink className="w-4 h-4" aria-hidden="true" />
        </a>
      )}
      <p className="type mt-3 text-[11px] text-white/50 leading-relaxed">
        Tickets are sold by the organizer on {name}. You'll check out there; Exos doesn't sell tickets for this event.
      </p>
    </div>
  );
}
