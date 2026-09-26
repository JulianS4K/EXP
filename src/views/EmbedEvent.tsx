// EmbedEvent — chromeless event card meant to be loaded in an
// iframe on the venue's own website (white-label level 3).
//
// Lives at /embed/event/:eventId, normally created by public/embed.js (which
// passes ?host=<venue origin>). Renders the event card and, when payments are
// on, a tier + quantity picker, an in-frame sign-in (email code, see
// EmbedSignIn) and Stripe Embedded Checkout — the fan never leaves the
// venue's site. Card payments finish in place; redirect-based methods land on
// /embed/return (EmbedReturn), also inside the iframe.
//
// Falls back to "open Exos in a new tab" when payments are off, for free
// tiers, and for anything the embed doesn't do (vouchers, add-ons).
//
// What this view DOES NOT render:
//   * Navbar, footer, auth modal — chrome is the host site's job.
//
// Messages to the host page (lib/embed.ts): exos:resize and
// exos:checkout-complete, posted only to the host's exact origin. Old
// snippets without ?host= get the legacy vibepass:resize (height only).
//
// Security:
//   * Only published events are rendered — the read rule already
//     blocks drafts/cancelled to anyone but the organizer.
//   * exos-checkout re-validates everything (tier, price, limits, hold); the
//     picker is advisory. Its return_url must be our own /embed/return.
//   * New-tab links use target=_blank rel=noopener so the host site
//     can't be navigated by Exos code.

import { useEffect, useMemo, useRef, useState } from 'react';
import { useParams } from 'react-router-dom';
import { Minus, Plus } from 'lucide-react';
import { Event, Organization } from '../types';
import { getPublicEvent } from '../lib/events';
import { getPublicOrg } from '../lib/orgs';
import { ThemeProvider, useTheme } from '../context/ThemeContext';
import { useAuth } from '../context/AuthContext';
import { formatInTz } from '../lib/datetime';
import { formatCurrency, publicUrl } from '../lib/utils';
import { paymentsEnabled } from '../lib/payments';
import { buyerTierPrice } from '../lib/pricing';
import { attributionFromSearch, readAttribution, withAttribution, type Attribution } from '../lib/attribution';
import { startEmbeddedCheckout } from '../lib/checkout';
import { EMBED_COMPLETE, buildEmbedReturnUrl, buyableTiers, maxQuantity, postToHost } from '../lib/embed';
import { useEmbedHost, useEmbedResize } from '../hooks/useEmbedResize';
import EmbedSignIn from '../components/EmbedSignIn';
import EmbeddedCheckoutMount from '../components/EmbeddedCheckoutMount';

type Step = 'card' | 'pick' | 'signin' | 'starting' | 'paying' | 'done';

function EmbedInner({ event, org, host }: { event: Event; org: Organization | null; host: string | null }) {
  const { theme } = useTheme();
  const { user } = useAuth();
  const currency = event.currency || 'USD';

  // Sale attribution: the embed itself, plus any promoter / UTM tags embed.js
  // forwarded from the venue page's URL (those win).
  const attribution: Attribution = useMemo(() => readAttribution((k) => ({
    utm_source: 'embed', utm_medium: 'iframe', utm_content: org?.slug ?? 'unknown',
    ...attributionFromSearch(typeof window !== 'undefined' ? window.location.search : ''),
  } as Record<string, unknown>)[k]), [org?.slug]);
  const buyHref = withAttribution(publicUrl(`event/${event.id}`), attribution);

  const tiers = buyableTiers(event.ticketTiers);
  const paidTiers = tiers.filter((t) => buyerTierPrice(t) > 0);
  // In-frame checkout needs payments on and at least one paid tier on sale.
  const inFrame = paymentsEnabled() && paidTiers.length > 0;

  const [step, setStep] = useState<Step>('card');
  const [tierId, setTierId] = useState<string>('');
  const [quantity, setQuantity] = useState(1);
  const [error, setError] = useState('');
  const [session, setSession] = useState<{ key: string; clientSecret: string; sessionId: string } | null>(null);

  const tier = paidTiers.find((t) => t.id === tierId) ?? paidTiers[0];
  const maxQty = tier ? maxQuantity(tier, event.purchaseLimits?.maxPerOrder) : 0;
  const unit = tier ? buyerTierPrice(tier) : 0;

  useEffect(() => {
    if (quantity > maxQty && maxQty > 0) setQuantity(maxQty);
  }, [maxQty]);

  const startPayment = async () => {
    if (!tier) return;
    setError('');
    // Same tier + quantity as an open session: reuse it (its seats are held).
    const key = `${tier.id}:${quantity}`;
    if (session?.key === key) {
      setStep('paying');
      return;
    }
    setStep('starting');
    try {
      const s = await startEmbeddedCheckout({
        eventId: event.id,
        tierId: tier.id,
        quantity,
        returnUrl: buildEmbedReturnUrl(publicUrl('embed/return'), event.id, host),
        attribution,
      });
      setSession({ key, ...s });
      setStep('paying');
    } catch (err) {
      setError((err as Error)?.message || 'Could not start checkout.');
      setStep('pick');
    }
  };

  // Signed in from the email code / password form: carry on to payment.
  useEffect(() => {
    if (step === 'signin' && user) void startPayment();
  }, [step, user]);

  const onContinue = () => {
    if (!user) setStep('signin');
    else void startPayment();
  };

  const onComplete = () => {
    setStep('done');
    postToHost({ type: EMBED_COMPLETE, eventId: event.id, sessionId: session?.sessionId }, host, window.parent === window ? null : window.parent);
  };

  const remaining = Math.max(0, (event.totalTickets || 0) - (event.ticketsSold || 0));
  const soldOut = remaining === 0 && (event.totalTickets || 0) > 0;
  const accent = theme.primary;
  const small = 'type text-[10px] uppercase tracking-widest text-white/40 hover:text-white/70';
  const cta = 'disp block w-full py-3 text-lg tracking-wide text-center hover:scale-[1.01] transition-transform disabled:opacity-50';

  return (
    <div
      className="group max-w-md bg-[#0a0a0a] text-white overflow-hidden border"
      style={{
        borderColor: theme.primary,
        borderLeftWidth: '4px',
      }}
    >
      {step !== 'paying' && (event.image ? (
        <div className="relative h-44 overflow-hidden">
          <img src={event.image} className="xerox w-full h-full object-cover" alt="" />
          <div className="absolute inset-0 bg-gradient-to-t from-[#0a0a0a] via-transparent to-transparent" />
          {theme.logoUrl && (
            <img
              src={theme.logoUrl}
              alt={`${org?.name ?? 'Organizer'} logo`}
              className="absolute top-3 right-3 h-7"
            />
          )}
          <div className="absolute bottom-3 left-4 right-4">
            <h2 className="disp text-3xl leading-[0.9] tracking-tight text-white">{event.title}</h2>
          </div>
        </div>
      ) : (
        <div className="p-5 pb-0">
          {theme.logoUrl && (
            <img
              src={theme.logoUrl}
              alt={`${org?.name ?? 'Organizer'} logo`}
              className="h-8 mb-3"
            />
          )}
          <h2 className="disp text-3xl leading-[0.9] tracking-tight text-white">{event.title}</h2>
        </div>
      ))}

      <div className="p-5">
        {step !== 'paying' && (
          <div className="flex items-center justify-between gap-3 mb-4 type text-[11px] uppercase tracking-widest text-white/50">
            <span>
              {event.date
                ? formatInTz(event.date.toDate(), event.timezone || 'UTC')
                : 'TBA'}
            </span>
            <span className="text-right">{event.location}</span>
          </div>
        )}

        {soldOut && step === 'card' ? (
          <div className="px-6 py-3 bg-white/5 text-white/40 text-center disp text-lg tracking-wide">
            SOLD OUT
          </div>
        ) : !inFrame ? (
          <a
            href={buyHref}
            target="_blank"
            rel="noopener noreferrer"
            className={cta}
            style={{ background: accent, color: '#000' }}
          >
            GET TICKETS →
          </a>
        ) : step === 'card' ? (
          <button type="button" onClick={() => setStep('pick')} className={cta} style={{ background: accent, color: '#000' }}>
            GET TICKETS
          </button>
        ) : step === 'pick' || step === 'starting' ? (
          <div className="space-y-4">
            <div className="space-y-2" role="radiogroup" aria-label="Ticket type">
              {paidTiers.map((t) => {
                const on = t.id === tier?.id;
                return (
                  <button
                    key={t.id}
                    type="button"
                    role="radio"
                    aria-checked={on}
                    onClick={() => setTierId(t.id)}
                    className={`w-full flex items-center justify-between gap-3 px-3 py-2.5 border text-left ${on ? 'bg-white/5' : 'border-white/10 hover:border-white/30'}`}
                    style={on ? { borderColor: accent } : undefined}
                  >
                    <span className="text-sm font-bold">{t.name}</span>
                    <span className="type text-xs text-white/70">{formatCurrency(buyerTierPrice(t), currency)}</span>
                  </button>
                );
              })}
            </div>
            <div className="flex items-center justify-between">
              <span className="type text-[11px] uppercase tracking-widest text-white/50">Quantity</span>
              <div className="flex items-center gap-3">
                <button type="button" aria-label="Fewer" disabled={quantity <= 1} onClick={() => setQuantity((q) => Math.max(1, q - 1))} className="p-1.5 border border-white/15 disabled:opacity-30"><Minus className="w-3.5 h-3.5" /></button>
                <span className="w-6 text-center font-bold" aria-live="polite">{quantity}</span>
                <button type="button" aria-label="More" disabled={quantity >= maxQty} onClick={() => setQuantity((q) => Math.min(maxQty, q + 1))} className="p-1.5 border border-white/15 disabled:opacity-30"><Plus className="w-3.5 h-3.5" /></button>
              </div>
            </div>
            <div className="flex items-baseline justify-between border-t border-white/10 pt-3">
              <span className="type text-[11px] uppercase tracking-widest text-white/50">Total</span>
              <span className="disp text-2xl">{formatCurrency(unit * quantity, currency)}</span>
            </div>
            <p className="type text-[9px] uppercase tracking-widest text-white/30">All-in price. Taxes included, no added fees.</p>
            {error && <p className="text-xs text-red-400" role="alert">{error}</p>}
            <button type="button" disabled={step === 'starting' || maxQty < 1} onClick={onContinue} className={cta} style={{ background: accent, color: '#000' }}>
              {step === 'starting' ? 'HOLDING YOUR SEATS…' : 'CONTINUE'}
            </button>
            <div className="flex justify-between">
              <button type="button" onClick={() => setStep('card')} className={small}>← Back</button>
              <a href={buyHref} target="_blank" rel="noopener noreferrer" className={small}>Have a code? Open on Exos</a>
            </div>
          </div>
        ) : step === 'signin' ? (
          <EmbedSignIn accent={accent} onCancel={() => setStep('pick')} />
        ) : step === 'paying' && session ? (
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <button type="button" onClick={() => setStep('pick')} className={small}>← Change tickets</button>
              <span className="type text-[10px] uppercase tracking-widest text-white/40">{event.title}</span>
            </div>
            <EmbeddedCheckoutMount clientSecret={session.clientSecret} onComplete={onComplete} />
          </div>
        ) : step === 'done' ? (
          <div className="space-y-3 text-center">
            <p className="disp text-2xl" style={{ color: accent }}>YOU'RE IN.</p>
            <p className="text-sm text-white/70">
              Payment received. Your tickets land in My Tickets on Exos in a moment{user?.email ? ` (signed in as ${user.email})` : ''}.
            </p>
            <a href={publicUrl('my-tickets')} target="_blank" rel="noopener noreferrer" className={cta} style={{ background: accent, color: '#000' }}>
              MY TICKETS →
            </a>
          </div>
        ) : null}

        <p className="type text-[9px] uppercase tracking-[0.25em] text-white/25 text-center mt-3">▲ secured by exos</p>
      </div>
    </div>
  );
}

export default function EmbedEvent() {
  const { eventId } = useParams<{ eventId: string }>();
  const [event, setEvent] = useState<Event | null>(null);
  const [org, setOrg] = useState<Organization | null>(null);
  const [status, setStatus] = useState<'loading' | 'found' | 'not-found'>('loading');
  const host = useEmbedHost();
  const root = useRef<HTMLDivElement>(null);
  useEmbedResize(host, root);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!eventId) {
        setStatus('not-found');
        return;
      }
      try {
        // Public view returns published-only, so drafts/cancelled → null → not-found.
        const ev = await getPublicEvent(eventId);
        if (cancelled) return;
        if (!ev) {
          setStatus('not-found');
          return;
        }
        setEvent(ev);
        if (ev.orgId) {
          const o = await getPublicOrg(ev.orgId);
          if (!cancelled) setOrg(o);
        }
        setStatus('found');
      } catch (err) {
        console.error('Embed load failed:', err);
        if (!cancelled) setStatus('not-found');
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [eventId]);

  // One root element across all states so the resize observer keeps
  // measuring it (the frame shrinks back after checkout too).
  return (
    <div ref={root}>
      {status === 'loading' ? (
        <div className="bg-black text-white/40 p-8 text-center type text-[11px] uppercase tracking-[0.3em] animate-pulse">
          Loading…
        </div>
      ) : status === 'not-found' ? (
        <div className="bg-black text-white/40 p-8 text-center type text-xs uppercase tracking-widest">
          Event unavailable.
        </div>
      ) : (
        <ThemeProvider org={org}>
          <EmbedInner event={event!} org={org} host={host} />
        </ThemeProvider>
      )}
    </div>
  );
}
