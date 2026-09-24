// ShareModal — one-click share for organizers ("share my event") and
// buyers ("share that I'm going"). Uses navigator.share when the
// platform supports it (mobile Safari, Android Chrome, iOS Safari);
// falls back to a small picker with Twitter/X, Facebook, copy-link.
//
// The Open Graph + Twitter Card meta tags from lib/meta.ts apply
// already on /event/:id, so a copy-paste link unfurls with the
// event poster and title even without using an explicit share-intent
// URL. The picker below adds the platform-specific share-intent URLs
// for one-click flow.
//
// Attribution (lib/shareLinks.ts): every link is tagged with the channel
// it was shared to. A fan's share passes along the promoter they arrived
// with; a promoter's share carries their own code, so their sales land in
// the event's per-promoter Sales report (free and paid).

import { ReactNode, useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { Copy, Send, Twitter, Facebook, Link as LinkIcon, X } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { buildShareUrl, type ShareChannel, type ShareRole } from '../lib/shareLinks';

interface ShareModalProps {
  open: boolean;
  onClose: () => void;
  // What to share.
  title: string;
  url: string;
  // Optional: pre-composed text for buyer-side "I'm going" framing.
  // If omitted, a generic "Check out {title}" is used.
  text?: string;
  // Fan ("I'm going", the default) or promoter / organizer.
  role?: ShareRole;
  // Promoter code: the sharer's own (promoter) or the one a fan arrived with.
  promoterId?: string;
  campaign?: string;
  // Fan's own referral code (lib/referrals.ts), so friends are counted.
  referralCode?: string;
}

export default function ShareModal({ open, onClose, title, url, text, role = 'fan', promoterId, campaign, referralCode }: ShareModalProps) {
  const { toast } = useToast();
  const [busy, setBusy] = useState(false);

  const linkFor = (channel: ShareChannel) => buildShareUrl(url, { role, channel, promoter: promoterId, campaign, ref: referralCode });
  const shareUrl = linkFor('copy');
  const shareText = text ?? `Check out ${title}`;

  async function handleNativeShare() {
    if (busy) return;
    setBusy(true);
    try {
      // navigator.share is the platform-canonical share UX. Returns
      // a promise that rejects on user cancel — we treat that as
      // a no-op silent close.
      if (typeof navigator !== 'undefined' && 'share' in navigator) {
        // @ts-ignore — TS lib lags Web Share API in some toolchains
        await navigator.share({ title, text: shareText, url: linkFor('native') });
        onClose();
        return;
      }
      // No native share — keep the modal open so the user can pick
      // a target manually.
    } catch (err) {
      // AbortError = user cancelled. Anything else, surface.
      const msg = err instanceof Error ? err.message : '';
      if (!/abort/i.test(msg)) {
        toast({ kind: 'error', message: 'Share cancelled.' });
      }
    } finally {
      setBusy(false);
    }
  }

  async function handleCopy() {
    try {
      await navigator.clipboard.writeText(shareUrl);
      toast({ kind: 'success', message: 'Link copied.' });
      onClose();
    } catch {
      toast({ kind: 'error', message: 'Could not copy — try long-pressing the link instead.' });
    }
  }

  const twitterHref =
    'https://twitter.com/intent/tweet?text=' +
    encodeURIComponent(`${shareText} ${linkFor('x')}`);
  const facebookHref =
    'https://www.facebook.com/sharer/sharer.php?u=' + encodeURIComponent(linkFor('facebook'));
  const whatsappHref = 'https://wa.me/?text=' + encodeURIComponent(`${shareText} ${linkFor('whatsapp')}`);

  return (
    <AnimatePresence>
      {open && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          onClick={onClose}
          className="fixed inset-0 z-50 bg-black/70 flex items-end md:items-center justify-center p-4"
        >
          <motion.div
            initial={{ y: 40, opacity: 0 }}
            animate={{ y: 0, opacity: 1 }}
            exit={{ y: 40, opacity: 0 }}
            onClick={(e) => e.stopPropagation()}
            className="w-full max-w-md bg-black border border-white/10 p-6"
          >
            <div className="flex items-start justify-between mb-6">
              <h2 className="text-2xl font-black uppercase italic tracking-tighter text-white">
                Share
              </h2>
              <button
                onClick={onClose}
                aria-label="Close"
                className="p-1 text-white/40 hover:text-white transition-all"
              >
                <X size={18} />
              </button>
            </div>

            <p className="text-white/60 text-sm mb-6 truncate">{title}</p>

            <div className="grid grid-cols-2 gap-2 mb-2">
              {/* Native share button — only useful on devices that support it. */}
              {typeof navigator !== 'undefined' && 'share' in navigator && (
                <ShareButton
                  icon={<Send size={16} />}
                  label="Share…"
                  onClick={handleNativeShare}
                  primary
                />
              )}
              <ShareButton
                icon={<Twitter size={16} />}
                label="X / Twitter"
                href={twitterHref}
                external
              />
              <ShareButton
                icon={<Facebook size={16} />}
                label="Facebook"
                href={facebookHref}
                external
              />
              <ShareButton
                icon={<Send size={16} />}
                label="WhatsApp"
                href={whatsappHref}
                external
              />
              <ShareButton
                icon={<Copy size={16} />}
                label="Copy link"
                onClick={handleCopy}
              />
            </div>

            <div className="mt-4 px-3 py-2 bg-white/5 border border-white/10 text-[11px] text-white/40 font-mono break-all flex items-center gap-2">
              <LinkIcon size={12} className="flex-shrink-0" />
              <span className="truncate">{shareUrl}</span>
            </div>
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}

interface ShareButtonProps {
  icon: ReactNode;
  label: string;
  href?: string;
  onClick?: () => void;
  external?: boolean;
  primary?: boolean;
}

function ShareButton({ icon, label, href, onClick, external, primary }: ShareButtonProps) {
  const cls = `flex items-center gap-2 px-4 py-3 text-sm font-black uppercase tracking-tighter italic transition-all ${
    primary ? 'bg-brand-primary text-black hover:bg-white' : 'bg-white/5 text-white hover:bg-white/10'
  }`;
  if (href) {
    return (
      <a
        href={href}
        target={external ? '_blank' : undefined}
        rel={external ? 'noopener noreferrer' : undefined}
        className={cls}
      >
        {icon}
        <span className="truncate">{label}</span>
      </a>
    );
  }
  return (
    <button onClick={onClick} className={cls}>
      {icon}
      <span className="truncate">{label}</span>
    </button>
  );
}
