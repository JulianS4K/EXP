// EmbedReturn — /embed/return, inside the venue-site iframe. Stripe Embedded
// Checkout sends the frame here only for redirect-based payment methods (card
// payments finish in place in EmbedEvent). Query: session_id (Stripe fills
// {CHECKOUT_SESSION_ID}), event, host (the venue origin, from embed.js).
//
// Reads the buyer's own exos_checkout_sessions row (RLS: buyer_uid =
// auth.uid()) until the webhook fulfills it, then tells the host page with
// exos:checkout-complete, posted only to the host's exact origin. If the
// iframe lost its session (storage blocked), it says so honestly instead of
// guessing.

import { useEffect, useRef, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { publicUrl } from '../lib/utils';
import { EMBED_COMPLETE, postToHost } from '../lib/embed';
import { useEmbedHost, useEmbedResize } from '../hooks/useEmbedResize';

type State = 'checking' | 'fulfilled' | 'failed' | 'pending' | 'unknown';

const SESSION_RE = /^cs_[A-Za-z0-9_]{1,255}$/;
const EVENT_RE = /^[A-Za-z0-9-]{1,64}$/;

export default function EmbedReturn() {
  const [params] = useSearchParams();
  const sessionId = SESSION_RE.test(params.get('session_id') ?? '') ? params.get('session_id')! : null;
  const eventId = EVENT_RE.test(params.get('event') ?? '') ? params.get('event')! : null;
  const host = useEmbedHost();
  const root = useRef<HTMLDivElement>(null);
  useEmbedResize(host, root);
  const [state, setState] = useState<State>(sessionId ? 'checking' : 'unknown');
  const told = useRef(false);

  useEffect(() => {
    if (!sessionId) return undefined;
    let alive = true;
    let tries = 0;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const poll = async () => {
      tries += 1;
      const { data: auth } = await supabase.auth.getSession();
      if (!auth.session) {
        if (alive) setState('unknown');
        return;
      }
      const { data } = await supabase
        .from('exos_checkout_sessions')
        .select('status')
        .eq('session_id', sessionId)
        .maybeSingle();
      if (!alive) return;
      const status = (data as { status?: string } | null)?.status;
      if (status === 'fulfilled') { setState('fulfilled'); return; }
      if (status === 'failed' || status === 'expired' || status === 'refunded') { setState('failed'); return; }
      if (tries >= 15) { setState('pending'); return; }
      timer = setTimeout(poll, 2000);
    };
    void poll();
    return () => {
      alive = false;
      if (timer) clearTimeout(timer);
    };
  }, [sessionId]);

  useEffect(() => {
    if (state !== 'fulfilled' || told.current || !eventId) return;
    told.current = true;
    postToHost(
      { type: EMBED_COMPLETE, eventId, sessionId: sessionId ?? undefined },
      host,
      window.parent === window ? null : window.parent,
    );
  }, [state, eventId, sessionId, host]);

  const backTo = eventId ? `/embed/event/${eventId}${host ? `?host=${encodeURIComponent(host)}` : ''}` : null;
  const copy: Record<State, { title: string; body: string }> = {
    checking: { title: 'CHECKING…', body: 'Confirming your payment.' },
    fulfilled: { title: "YOU'RE IN.", body: 'Payment received. Your tickets are in My Tickets on Exos.' },
    failed: { title: 'NOT COMPLETED', body: 'The payment did not go through, so nothing was charged. You can try again.' },
    pending: { title: 'PROCESSING', body: 'Your payment is still clearing. Your tickets appear in My Tickets on Exos once it does.' },
    unknown: { title: 'ALMOST DONE', body: 'If your payment went through, your tickets are in My Tickets on Exos.' },
  };
  const c = copy[state];

  return (
    <div ref={root}>
      <div className="max-w-md bg-[#0a0a0a] text-white border border-white/20 p-6 text-center space-y-4">
        <p className={`disp text-2xl ${state === 'checking' ? 'animate-pulse' : ''}`}>{c.title}</p>
        <p className="text-sm text-white/70">{c.body}</p>
        {state !== 'checking' && (
          <a
            href={publicUrl('my-tickets')}
            target="_blank"
            rel="noopener noreferrer"
            className="disp block w-full py-3 text-lg tracking-wide bg-white text-black"
          >
            MY TICKETS →
          </a>
        )}
        {backTo && state !== 'checking' && (
          <Link to={backTo} className="type block text-[10px] uppercase tracking-widest text-white/40 hover:text-white/70">
            ← Back to the event
          </Link>
        )}
        <p className="type text-[9px] uppercase tracking-[0.25em] text-white/25">▲ secured by exos</p>
      </div>
    </div>
  );
}
