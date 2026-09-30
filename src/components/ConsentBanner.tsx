// Cookie consent banner: two categories (lib/consent.ts).
//
// Shows until the visitor has chosen for both analytics (GA4) and advertising
// (Meta, TikTok, Reddit, Snap, X, Google ads signals). "Accept all" and
// "Reject all" decide both; "Choose" opens two toggles. Nothing tracking loads
// before a category is granted (lib/pixels.ts). "Cookie settings" in the
// footer reopens it (openConsentSettings) so a choice can be changed later.
//
// Global Privacy Control: the advertising toggle starts off and the banner
// says why; switching it on (or "Accept all") is the explicit opt-in.

import { useEffect, useId, useState } from 'react';
import { Link } from 'react-router-dom';
import { getConsentState, onOpenConsentSettings, setConsentChoice } from '../lib/consent';

const BTN = 'px-4 py-2 text-xs font-black uppercase tracking-tighter italic transition-all';

export default function ConsentBanner() {
  const [show, setShow] = useState(false);
  const [choosing, setChoosing] = useState(false);
  const [analytics, setAnalytics] = useState(false);
  const [advertising, setAdvertising] = useState(false);
  const [gpc, setGpc] = useState(false);
  const titleId = useId();

  useEffect(() => {
    const load = (open: boolean) => {
      const s = getConsentState();
      setGpc(s.gpc);
      setAnalytics(s.analytics === 'granted');
      setAdvertising(s.advertising === 'granted');
      setChoosing(open);
      setShow(open || !s.decided);
    };
    load(false);
    return onOpenConsentSettings(() => load(true));
  }, []);

  if (!show) return null;

  const decide = (a: boolean, ad: boolean) => {
    setConsentChoice({ analytics: a, advertising: ad });
    setShow(false);
    setChoosing(false);
  };

  return (
    <div
      role="dialog"
      aria-labelledby={titleId}
      className="fixed bottom-0 inset-x-0 z-[60] bg-black border-t border-white/10 px-4 py-4 md:py-3"
    >
      <div className="max-w-5xl mx-auto">
        <div className="flex flex-col md:flex-row md:items-center gap-3 md:gap-6">
          <p id={titleId} className="text-xs text-white/60 leading-relaxed flex-grow">
            Organizers can measure their events with analytics and advertising cookies. They load only
            if you allow them. See our{' '}
            <Link to="/privacy" className="underline hover:text-white">privacy policy</Link>.
            {gpc && (
              <span className="block mt-1 text-white/50">
                Your browser sends Global Privacy Control, so advertising cookies stay off unless you turn them on here.
              </span>
            )}
          </p>
          {!choosing && (
            <div className="flex flex-wrap gap-2 flex-shrink-0">
              <button onClick={() => setChoosing(true)} className={`${BTN} bg-white/5 text-white/70 hover:bg-white/10`}>
                Choose
              </button>
              <button onClick={() => decide(false, false)} className={`${BTN} bg-white/5 text-white/70 hover:bg-white/10`}>
                Reject all
              </button>
              <button onClick={() => decide(true, true)} className={`${BTN} bg-brand-primary text-black hover:bg-white`}>
                Accept all
              </button>
            </div>
          )}
        </div>
        {choosing && (
          <div className="mt-3 flex flex-col md:flex-row md:items-end gap-3 md:gap-6">
            <div className="flex-grow grid gap-2 md:grid-cols-2">
              <label className="flex items-start gap-2 text-xs text-white/70">
                <input
                  type="checkbox"
                  className="mt-0.5"
                  checked={analytics}
                  onChange={(e) => setAnalytics(e.target.checked)}
                />
                <span>
                  <strong className="text-white">Analytics</strong>: Google Analytics, so organizers can see how
                  their event pages perform.
                </span>
              </label>
              <label className="flex items-start gap-2 text-xs text-white/70">
                <input
                  type="checkbox"
                  className="mt-0.5"
                  checked={advertising}
                  onChange={(e) => setAdvertising(e.target.checked)}
                />
                <span>
                  <strong className="text-white">Advertising</strong>: Meta, TikTok, Reddit, Snapchat, X and Google
                  ads, so organizers can measure and target their ads.
                </span>
              </label>
            </div>
            <div className="flex flex-wrap gap-2 flex-shrink-0">
              <button onClick={() => decide(false, false)} className={`${BTN} bg-white/5 text-white/70 hover:bg-white/10`}>
                Reject all
              </button>
              <button onClick={() => decide(analytics, advertising)} className={`${BTN} bg-brand-primary text-black hover:bg-white`}>
                Save choices
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
