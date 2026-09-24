import { useState } from 'react';
import { ExternalLink, Copy, Check } from 'lucide-react';
import { androidOpenInBrowserUrl, currentInAppBrowser, IN_APP_LABEL, isAndroid } from '../lib/inAppBrowser';

// Shown on public event and storefront pages inside Instagram / Facebook /
// TikTok browsers. Checkout works in place; the banner only offers a way out
// for buyers who want Apple Pay or Google sign-in (see lib/inAppBrowser.ts).
export default function InAppBrowserBanner() {
  const [app] = useState(currentInAppBrowser);
  const [copied, setCopied] = useState(false);
  if (!app) return null;

  const href = typeof window !== 'undefined' ? window.location.href : '';
  const intent = typeof navigator !== 'undefined' && isAndroid(navigator.userAgent) ? androidOpenInBrowserUrl(href) : null;

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(href);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      /* clipboard blocked; the menu hint still applies */
    }
  };

  return (
    <div role="note" className="border-b border-white/10 bg-[#111] px-4 py-3 type text-[11px] uppercase tracking-widest text-white/70">
      <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-x-4 gap-y-2">
        <span>
          You can buy right here in {IN_APP_LABEL[app]}.{' '}
          {intent ? 'For Apple Pay or Google Pay, open this page in your browser.' : 'For Apple Pay, tap ••• and choose "Open in browser".'}
        </span>
        {intent ? (
          <a href={intent} className="inline-flex items-center gap-1 text-brand-primary hover:underline">
            <ExternalLink className="h-3 w-3" /> Open in browser
          </a>
        ) : (
          <button type="button" onClick={copy} className="inline-flex items-center gap-1 text-brand-primary hover:underline">
            {copied ? <Check className="h-3 w-3" /> : <Copy className="h-3 w-3" />} {copied ? 'Link copied' : 'Copy link'}
          </button>
        )}
      </div>
    </div>
  );
}
