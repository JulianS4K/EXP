import { useState } from 'react';
import { ExternalLink, Copy, Check } from 'lucide-react';
import {
  copyText, currentInAppState, escapeReasons, IN_APP_LABEL, openInBrowserPlan, type EscapeReason, type InAppState,
} from '../lib/inAppBrowser';

// The "open in your browser" escape hatch for Instagram / Facebook / TikTok
// browsers (lib/inAppBrowser.ts). Checkout works in place; this only offers a
// way out for what the app's browser can't do (Apple Pay, Google Pay, Apple
// Wallet, or a page whose storage is blocked). It never blocks the purchase.
//
//   * Android: an intent: link that opens the default browser.
//   * iOS: an x-safari-https: link (some apps pass it to Safari, some don't),
//     the app's own menu steps, and Copy link (with a by-hand fallback).
//   * `url` is what the browser should open: the event page passes a
//     checkout link carrying the buyer's cart and attribution, so nothing
//     is lost on the way.

const REASON_TEXT: Record<EscapeReason, string> = {
  apple_pay: 'For Apple Pay, open this page in Safari.',
  google_pay: 'For Google Pay, open this page in your browser.',
  wallet: '',
  storage: "This app's browser won't keep your place if you leave the page.",
};

export function EscapeHatch({
  url, reasons, lead, state = currentInAppState(), tone = 'dark', className = '',
}: {
  url?: string;
  /** Override the reasons (e.g. 'wallet' on a ticket). */
  reasons?: EscapeReason[];
  /** The first sentence; defaults to "You can buy right here in Instagram." */
  lead?: string;
  state?: InAppState;
  tone?: 'dark' | 'light';
  className?: string;
}) {
  const [copied, setCopied] = useState<'yes' | 'failed' | null>(null);
  if (!state.kind) return null;
  const href = url ?? (typeof window !== 'undefined' ? window.location.href : '');
  const plan = openInBrowserPlan(href, state);
  if (!plan) return null;
  const why = (reasons ?? escapeReasons(state)).map((r) => REASON_TEXT[r]).filter(Boolean);
  const label = IN_APP_LABEL[state.kind];
  const browser = state.platform === 'ios' ? 'Safari' : 'browser';
  const accent = tone === 'dark' ? 'text-brand-primary' : 'text-slate-900 underline';

  const copy = async () => {
    setCopied((await copyText(plan.url)) ? 'yes' : 'failed');
    setTimeout(() => setCopied((c) => (c === 'yes' ? null : c)), 2500);
  };

  return (
    <div className={className} data-testid="in-app-escape" data-url={plan.url}>
      <p>
        {lead ?? `You can buy right here in ${label}.`}{why.length > 0 ? ' ' + why.join(' ') : ''}{' '}
        <span className="opacity-80">{plan.steps}</span>
      </p>
      <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-2">
        {plan.href && (
          <a href={plan.href} className={`inline-flex items-center gap-1 ${accent} hover:underline`}>
            <ExternalLink className="h-3 w-3" aria-hidden="true" /> Open in {browser}
          </a>
        )}
        <button type="button" onClick={() => void copy()} className={`inline-flex items-center gap-1 ${accent} hover:underline`}>
          {copied === 'yes' ? <Check className="h-3 w-3" aria-hidden="true" /> : <Copy className="h-3 w-3" aria-hidden="true" />}
          {copied === 'yes' ? 'Link copied' : 'Copy link'}
        </button>
      </div>
      {copied === 'failed' && (
        // Clipboard blocked too: the link to long-press and copy by hand.
        <label className="mt-2 block normal-case tracking-normal">
          <span className="sr-only">Link to this page</span>
          <input readOnly value={plan.url} onFocus={(e) => e.currentTarget.select()}
            className={`w-full px-2 py-1 text-[12px] ${tone === 'dark' ? 'bg-white/10 text-white' : 'bg-slate-100 text-slate-900'}`} />
        </label>
      )}
    </div>
  );
}

// Shown on public event, storefront and bio pages inside in-app browsers.
export default function InAppBrowserBanner({ url }: { url?: string }) {
  const [state] = useState(currentInAppState);
  if (!state.kind) return null;
  return (
    <div role="note" className="border-b border-white/10 bg-[#111] px-4 py-3 type text-[11px] uppercase tracking-widest text-white/70">
      <EscapeHatch url={url} state={state} className="mx-auto max-w-5xl" />
    </div>
  );
}
