// Everything a promoter needs to sell one event, tied to their promoter code:
//   * a "buy now" checkout link (lib/checkoutLink.ts) that opens the event
//     with their pick of ticket type, quantity and voucher already filled in;
//   * an Instagram / Facebook story poster (the native app hands it straight
//     to Stories; the web uses the share sheet);
//   * tracked share links per channel.
// Every sale through any of these carries the code, so it lands in the
// event's per-promoter Sales report (paid sales since mig 20260924223000).
// Used on the organizer's Promote page and the public promoter kit page.

import { useMemo, useState } from 'react';
import { Copy, Instagram, Link as LinkIcon, Share2, ShoppingCart } from 'lucide-react';
import type { Event } from '../types';
import { publicUrl } from '../lib/utils';
import { eventSharePath } from '../lib/events';
import { buildCheckoutLink } from '../lib/checkoutLink';
import { buildShareUrl, shareAttribution, type ShareChannel } from '../lib/shareLinks';
import { shareEventToStory } from '../lib/poster';
import { formatInTz } from '../lib/datetime';
import { useToast } from '../context/ToastContext';
import ShareModal from './ShareModal';
import { useShareTags } from '../hooks/useShareTags';
import { mentionsFor } from '../lib/socialTags';

const LINK_CHANNELS: { channel: ShareChannel; label: string }[] = [
  { channel: 'instagram_bio', label: 'Instagram bio' },
  { channel: 'instagram_story', label: 'Instagram story' },
  { channel: 'tiktok', label: 'TikTok' },
  { channel: 'whatsapp', label: 'WhatsApp' },
  { channel: 'sms', label: 'Text message' },
  { channel: 'email', label: 'Email' },
];

export default function PromoterKitPanel({ event, promoter }: { event: Event; promoter: string }) {
  const { toast } = useToast();
  const tiers = event.ticketTiers ?? [];
  // A promoter's share tags the organizer.
  const shareTags = useShareTags({ orgId: event.orgId, includePromoter: false, enabled: !!event.orgId });
  const [tierId, setTierId] = useState(tiers[0]?.id ?? '');
  const [quantity, setQuantity] = useState(1);
  const [coupon, setCoupon] = useState('');
  const [channel, setChannel] = useState<ShareChannel>('instagram_bio');
  const [shareOpen, setShareOpen] = useState(false);

  const eventUrl = publicUrl(eventSharePath(event));
  const checkoutLink = useMemo(
    () => tierId
      ? buildCheckoutLink(publicUrl('checkout'), {
          eventId: event.id, tierId, quantity,
          coupon: coupon.trim() || undefined,
          attribution: shareAttribution({ role: 'promoter', channel, promoter }),
        })
      : '',
    [event.id, tierId, quantity, coupon, channel, promoter],
  );

  const copy = async (value: string, label: string) => {
    try {
      await navigator.clipboard.writeText(value);
      toast({ kind: 'success', message: label });
    } catch {
      toast({ kind: 'error', message: 'Could not copy. Long-press the link to copy it.' });
    }
  };

  const shareStory = () => shareEventToStory(
    {
      title: event.title,
      url: eventUrl,
      imageUrl: event.image,
      dateLabel: event.date
        ? formatInTz(event.date.toDate(), event.timezone, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
        : undefined,
      venue: event.location,
      role: 'promoter',
      promoter,
      mentions: mentionsFor('instagram_story', shareTags),
    },
    toast,
  );

  const field = 'bg-black border border-white/20 px-3 py-2 text-sm text-white focus:outline-none focus:border-brand-primary';

  return (
    <div className="space-y-5">
      <div>
        <p className="type text-[10px] uppercase tracking-widest text-white/50 mb-2 flex items-center gap-2">
          <ShoppingCart className="w-3 h-3" /> Buy-now link
        </p>
        {tiers.length === 0 ? (
          <p className="text-[11px] text-white/40 italic">Add a ticket type to this event to make a buy-now link.</p>
        ) : (
          <>
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 mb-2">
              <select aria-label="Ticket type" value={tierId} onChange={(e) => setTierId(e.target.value)} className={`${field} col-span-2`}>
                {tiers.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
              </select>
              <select aria-label="Quantity" value={quantity} onChange={(e) => setQuantity(Number(e.target.value))} className={field}>
                {Array.from({ length: 10 }, (_, i) => i + 1).map((n) => <option key={n} value={n}>{n} ticket{n > 1 ? 's' : ''}</option>)}
              </select>
              <select aria-label="Where you'll post it" value={channel} onChange={(e) => setChannel(e.target.value as ShareChannel)} className={field}>
                {LINK_CHANNELS.map((c) => <option key={c.channel} value={c.channel}>{c.label}</option>)}
              </select>
            </div>
            <input
              value={coupon}
              onChange={(e) => setCoupon(e.target.value.replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64))}
              placeholder="Voucher code to apply (optional)"
              aria-label="Voucher code"
              className={`${field} w-full mb-2`}
            />
            <div className="flex items-center gap-2 bg-black/40 border border-white/10 px-3 py-2">
              <span className="flex-1 text-[11px] font-mono text-white/60 truncate">{checkoutLink}</span>
              <button onClick={() => copy(checkoutLink, 'Buy-now link copied.')} aria-label="Copy buy-now link" className="p-2 text-white/40 hover:text-brand-primary transition-colors shrink-0">
                <Copy className="w-4 h-4" />
              </button>
            </div>
            <p className="text-[11px] text-white/40 mt-2">
              Opens the event with this cart filled in. Prices and availability are checked again at checkout.
            </p>
          </>
        )}
      </div>

      <div className="flex flex-wrap gap-2">
        <button onClick={shareStory} className="inline-flex items-center gap-2 bg-brand-primary text-black px-4 py-2 text-sm font-black uppercase">
          <Instagram className="w-4 h-4" /> Story poster
        </button>
        <button onClick={() => setShareOpen(true)} className="inline-flex items-center gap-2 bg-white/5 text-white px-4 py-2 text-sm font-black uppercase hover:bg-white/10">
          <Share2 className="w-4 h-4" /> Share
        </button>
      </div>

      <div>
        <p className="type text-[10px] uppercase tracking-widest text-white/50 mb-2 flex items-center gap-2">
          <LinkIcon className="w-3 h-3" /> Event links by channel
        </p>
        <div className="space-y-2">
          {LINK_CHANNELS.map((c) => {
            const link = buildShareUrl(eventUrl, { role: 'promoter', channel: c.channel, promoter });
            return (
              <div key={c.channel} className="flex items-center gap-2 bg-black/40 border border-white/10 px-3 py-2">
                <span className="type text-[10px] uppercase tracking-widest text-white/50 w-28 shrink-0">{c.label}</span>
                <span className="flex-1 text-[11px] font-mono text-white/60 truncate">{link}</span>
                <button onClick={() => copy(link, `${c.label} link copied.`)} aria-label={`Copy ${c.label} link`} className="p-2 text-white/40 hover:text-brand-primary transition-colors shrink-0">
                  <Copy className="w-4 h-4" />
                </button>
              </div>
            );
          })}
        </div>
      </div>

      <ShareModal
        open={shareOpen}
        onClose={() => setShareOpen(false)}
        title={event.title}
        url={eventUrl}
        role="promoter"
        promoterId={promoter}
        tags={shareTags}
      />
    </div>
  );
}
