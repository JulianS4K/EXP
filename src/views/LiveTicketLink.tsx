// /t/:ticketId#k=<key> — the live ticket behind a partner's signed link
// (mig 20261031130000, docs/partner-sales.md). No account needed: the 256-bit
// key in the fragment (never sent to a server) unlocks the ticket's current
// door code, which the database signs and which changes every 30 seconds, so
// a screenshot won't scan. The wallet pass is the fallback (exos-wallet
// POST /link-pass).

import { useEffect, useState, type ReactNode } from 'react';
import { useParams } from 'react-router-dom';
import { QRCodeSVG } from 'qrcode.react';
import { fetchTicketLink } from '../lib/developerPlatform';
import { linkKeyFromHash, nextRefreshMs, stateMessage, type LinkView } from '../lib/ticketLink';

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

export default function LiveTicketLink() {
  const { ticketId = '' } = useParams();
  const [key] = useState(() => (typeof window === 'undefined' ? null : linkKeyFromHash(window.location.hash)));
  const [view, setView] = useState<LinkView | null>(null);
  const [walletMsg, setWalletMsg] = useState<string | null>(null);

  useEffect(() => {
    if (!key) return undefined;
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      try {
        const v = await fetchTicketLink(ticketId, key);
        if (stop) return;
        setView(v);
        if (v.ok && v.state === 'valid') timer = setTimeout(tick, nextRefreshMs(v));
      } catch {
        if (!stop) timer = setTimeout(tick, 10_000);
      }
    };
    tick();
    return () => { stop = true; if (timer) clearTimeout(timer); };
  }, [ticketId, key]);

  const wallet = async (kind: 'apple' | 'google') => {
    const base = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
    if (!base || !key) return;
    setWalletMsg(null);
    const anon = env.VITE_SUPABASE_ANON_KEY ?? '';
    const res = await fetch(`${base}/functions/v1/exos-wallet/link-pass`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...(anon ? { apikey: anon, Authorization: `Bearer ${anon}` } : {}) },
      body: JSON.stringify({ ticket_id: ticketId, link_key: key, kind }),
    }).catch(() => null);
    if (!res || !res.ok) {
      setWalletMsg(res?.status === 503 ? 'Wallet passes aren\'t available for this event.' : 'Couldn\'t make the pass. Use this page at the door.');
      return;
    }
    if (kind === 'google') {
      const { save_url } = await res.json();
      if (typeof save_url === 'string' && save_url.startsWith('https://pay.google.com/')) window.location.assign(save_url);
    } else {
      const blob = await res.blob();
      window.location.assign(URL.createObjectURL(blob));
    }
  };

  if (!key) return <Frame><p className="text-sm text-white/60">This ticket link is incomplete. Open the full link from your email or the site you bought from.</p></Frame>;
  if (!view) return <Frame><p className="text-sm text-white/50">Loading your ticket…</p></Frame>;
  if (!view.ok) return <Frame><p className="text-sm text-white/60">This ticket link doesn't work any more. It may have been transferred or reissued.</p></Frame>;

  const msg = stateMessage(view.state);
  return (
    <Frame>
      <div className="space-y-1">
        <h1 className="text-xl font-black">{view.event?.name}</h1>
        <p className="text-xs text-white/60">
          {view.event?.starts_at ? new Date(view.event.starts_at).toLocaleString(undefined, { timeZone: view.event.timezone ?? undefined }) : ''}
          {view.event?.venue_name ? ` · ${view.event.venue_name}` : ''}
        </p>
        <p className="text-xs text-white/80">{view.tier_name}{view.attendee_name ? ` · ${view.attendee_name}` : ''}</p>
      </div>
      {view.code ? (
        <div className="bg-white p-4 flex justify-center">
          <QRCodeSVG value={view.code} size={220} level="H" includeMargin={false} fgColor="#000000" />
        </div>
      ) : (
        <p className="text-sm text-white">{msg}</p>
      )}
      {view.code && (
        <>
          <p className="text-[11px] text-white/40">The code changes every 30 seconds; screenshots won't scan. Keep this link to yourself: anyone with it can use the ticket.</p>
          <div className="flex gap-2">
            <button type="button" className="flex-1 border border-white/20 px-3 py-2 text-[11px] uppercase tracking-widest" onClick={() => wallet('apple')}>Apple Wallet</button>
            <button type="button" className="flex-1 border border-white/20 px-3 py-2 text-[11px] uppercase tracking-widest" onClick={() => wallet('google')}>Google Wallet</button>
          </div>
          {walletMsg && <p className="text-[11px] text-amber-400">{walletMsg}</p>}
        </>
      )}
    </Frame>
  );
}

function Frame({ children }: { children: ReactNode }) {
  return <div className="max-w-sm mx-auto px-4 py-12 text-white"><div className="bg-[#111] border border-white/10 p-6 space-y-5">{children}</div></div>;
}
