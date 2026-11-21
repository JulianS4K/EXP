// Cloudflare Turnstile for a waiting room with its check on (mig
// 20261118120000). Loads Cloudflare's script only when rendered, which is only
// in the queue on the event page and /event/:id/queue: never on a page with a
// Stripe card field (docs/pci.md; the CSP allows challenges.cloudflare.com on
// those two pages only, src/lib/hosting/headers.ts).

import { useEffect, useRef } from 'react';
import { TURNSTILE_ACTION, TURNSTILE_SRC } from '../lib/waitingRoom';

interface TurnstileApi {
  render: (el: HTMLElement, o: Record<string, unknown>) => string;
  remove?: (id: string) => void;
}
const ts = (): TurnstileApi | undefined => (window as unknown as { turnstile?: TurnstileApi }).turnstile;

export default function TurnstileWidget({ siteKey, onToken }: { siteKey: string; onToken: (token: string) => void }) {
  const box = useRef<HTMLDivElement>(null);
  const cb = useRef(onToken);
  cb.current = onToken;
  useEffect(() => {
    let cancelled = false;
    let id: string | null = null;
    const mount = () => {
      const api = ts();
      if (cancelled || !box.current || !api) return;
      id = api.render(box.current, {
        sitekey: siteKey, action: TURNSTILE_ACTION, callback: (t: string) => cb.current(t),
      });
    };
    if (ts()) mount();
    else {
      let s = document.querySelector<HTMLScriptElement>(`script[src="${TURNSTILE_SRC}"]`);
      if (!s) {
        s = document.createElement('script');
        s.src = TURNSTILE_SRC;
        s.async = true;
        document.head.appendChild(s);
      }
      s.addEventListener('load', mount);
    }
    return () => {
      cancelled = true;
      const api = ts();
      if (id && api?.remove) api.remove(id);
    };
  }, [siteKey]);
  return <div ref={box} data-turnstile className="min-h-[65px]" />;
}
