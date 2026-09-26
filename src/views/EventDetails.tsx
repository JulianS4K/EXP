import { Accessibility as AccessIcon } from 'lucide-react';
import { EventAccessInfo } from '../components/Accessibility';
import { useEffect, useRef, useState } from 'react';
import { useParams, useNavigate, useLocation, Link } from 'react-router-dom';
import { Event, Organization } from '../types';
import { eventSharePath, getPublicEvent, getEventForEdit } from '../lib/events';
import { mintTickets, claimFreeTickets, setTicketAttendee, listMyTicketsForEvent } from '../lib/tickets';
import { startCheckout } from '../lib/checkout';
import SocialLinks from '../components/SocialLinks';
import ArtistLinks from '../components/ArtistLinks';
import AddToCalendar from '../components/AddToCalendar';
import { linksForArtist } from '../lib/artistLinks';
import { shareEventToStory } from '../lib/poster';
import { useAuth } from '../context/AuthContext';
import { Calendar, MapPin, Ticket, ShieldCheck, Share2, ArrowLeft, CheckCircle2, Copy, Send, Instagram, Minus, Plus, Tag } from 'lucide-react';
import { formatCurrency, generateBarcodeContent, handleFirestoreError, OperationType, publicUrl } from '../lib/utils';
import { getStripe } from '../lib/stripe';
import { formatInTz } from '../lib/datetime';
import { motion } from 'motion/react';
import { useToast } from '../context/ToastContext';
import { applyMeta } from '../lib/meta';
import { getPublicOrg } from '../lib/orgs';
import { initOrgPixels, trackPixelEvent } from '../lib/pixels';
import InAppBrowserBanner from '../components/InAppBrowserBanner';
import VenueMap from '../components/VenueMap';
import { captureAttribution, type Attribution } from '../lib/attribution';
import { clearPrefill, readPrefill, type CheckoutPrefill } from '../lib/checkoutLink';
import { getVoucherTier } from '../lib/vouchers';
import { attachReferral } from '../lib/referrals';
import ShareModal from '../components/ShareModal';
import { useShareTags } from '../hooks/useShareTags';
import { mentionsFor, withMentions } from '../lib/socialTags';
import EventCountdown from '../components/EventCountdown';
import WaitlistCTA from '../components/WaitlistCTA';
import SaveEventButton from '../components/SaveEventButton';
import { allInPrice, buyerTierPrice, effectiveTierPrice, nextPriceStep } from '../lib/pricing';
import TableTierInfo from '../components/TableTierInfo';
import AddonSelector, { type AddonSelection } from '../components/AddonSelector';
import { claimFreeAddons } from '../lib/addons';
import VoucherField, { type AppliedVoucher } from '../components/VoucherField';
import { useT } from '../context/LanguageContext';

const RESUME_KEY = 'exos.resumeBuy';
const RESUME_TTL_MS = 10 * 60 * 1000;

export default function EventDetails() {
  const { id } = useParams();
  const t = useT();
  const { user, isAdmin, signIn, isAuthModalOpen } = useAuth();
  // Set when Buy opened the sign-in modal on this page (state still intact).
  const pendingBuyRef = useRef(false);
  const navigate = useNavigate();
  const { toast } = useToast();
  const [event, setEvent] = useState<Event | null>(null);
  const [org, setOrg] = useState<Organization | null>(null);
  const [loading, setLoading] = useState(true);
  const [purchasing, setPurchasing] = useState(false);
  const [selectedTierId, setSelectedTierId] = useState<string | null>(null);
  // Phone buy bar: shown while the buy card is off screen.
  const buyCardRef = useRef<HTMLDivElement>(null);
  const [buyInView, setBuyInView] = useState(false);
  // The literal code that's currently applied — needed so we can pass it
  // through to the Stripe metadata and the post-purchase usage increment.
  const [quantity, setQuantity] = useState(1);
  // Optional per-ticket attendee names, index-aligned with quantity. Stamped
  // onto the minted tickets after a free claim (best-effort, owner RPC).
  const [attendeeNames, setAttendeeNames] = useState<string[]>([]);
  const [addonSel, setAddonSel] = useState<AddonSelection>({ items: [], totalCents: 0 });
  const [voucher, setVoucher] = useState<AppliedVoucher | null>(null);
  // A hidden tier the applied voucher unlocks. The public tier list never
  // contains hidden tiers, so it's fetched separately (exos_voucher_tier).
  const [unlockedTier, setUnlockedTier] = useState<NonNullable<Event['ticketTiers']>[number] | null>(null);
  // Where this buyer came from (promoter link, ad, Instagram Shop), kept for
  // the visit so it survives sign-in; and a cart pre-filled by a checkout link.
  const [attribution, setAttribution] = useState<Attribution>({});
  const [prefill, setPrefill] = useState<CheckoutPrefill | null>(null);
  // Accounts a share tags: the organizer and the promoter who brought this fan.
  const shareTags = useShareTags({ org, promoterCode: attribution.promoter, enabled: !!org });
  useEffect(() => {
    if (!id) return;
    setAttribution(captureAttribution(id, window.location.search));
    setPrefill(readPrefill(id));
  }, [id]);
  const location = useLocation();
  useEffect(() => {
    const notes = (location.state as { checkoutNotes?: string[] } | null)?.checkoutNotes;
    if (notes && notes.length > 0) toast({ kind: 'info', message: notes.join(' ') });
  }, [location.state]);
  const [userTicketCount, setUserTicketCount] = useState(0);
  // Per-tier sold/capacity, sourced from the events/{id}/tierSales sub-
  // collection. Buyers can no longer mutate the embedded ticketTiers array
  // (the rule lockdown that closed the price-rewrite vulnerability) so the
  // embedded `sold` is no longer authoritative — these counts are.
  const [showShare, setShowShare] = useState(false);

  // Per-account ticket count gates max-per-account at checkout. Lands in
  // phase-2 with the exos_tickets table; stays 0 until then.
  useEffect(() => {
    setUserTicketCount(0);
  }, [user, id]);

  useEffect(() => {
    async function fetchEvent() {
      if (!id) { setLoading(false); return; }
      // Published events via the public view; fall back to the staff read so an
      // organizer can preview their own draft (RLS gates that to org staff).
      let data = await getPublicEvent(id);
      if (!data && user) data = await getEventForEdit(id);
      if (data) {
        setEvent(data);
        // Default to the first tier, but keep a choice the buyer (or a
        // checkout link, or a voucher) already made: this effect re-runs when
        // the session resolves or the buyer signs in.
        if (data.ticketTiers && data.ticketTiers.length > 0) {
          // First tier that still has room; a sold-out tier only when all are.
          const open = data.ticketTiers.find((t) => (t.capacity ?? 0) - (t.sold ?? 0) > 0);
          const first = (open ?? data.ticketTiers[0]).id;
          setSelectedTierId((cur) => cur ?? first);
        }
        // SEO: per-event meta tags (Open Graph, Twitter Card,
        // Schema.org Event). Crawlers that execute JS pick this up;
        // social-card previewers fall back to the index.html defaults.
        try {
          const startIso = data.date?.toDate ? data.date.toDate().toISOString() : undefined;
          const endIso = data.timing?.endTime?.toDate?.()?.toISOString();
          const remaining = Math.max(0, (data.totalTickets || 0) - (data.ticketsSold || 0));
          applyMeta({
            title: data.title,
            description: (data.description || '').slice(0, 200),
            imageUrl: data.image || undefined,
            canonicalUrl: publicUrl(`event/${data.id}`),
            event: startIso
              ? {
                  name: data.title,
                  startDate: startIso,
                  endDate: endIso,
                  location: {
                    name: data.location,
                    streetAddress: data.address?.street,
                    city: data.address?.city,
                    region: data.address?.region,
                    country: data.address?.country,
                    postal: data.address?.postal,
                  },
                  image: data.image,
                  description: (data.description || '').slice(0, 200),
                  offers: {
                    price: data.price,
                    currency: data.currency || 'USD',
                    availability: remaining > 0 ? 'InStock' : 'SoldOut',
                    url: publicUrl(`event/${data.id}`),
                  },
                }
              : undefined,
          });
        } catch (err) {
          // Meta-tag failures are non-fatal — they don't block render.
          console.warn('Meta apply failed:', err);
        }
        // Marketing: load the hosting org's pixels (consent-gated) and fire a
        // ViewContent for this event. The public event row carries only
        // orgId, so fetch the public org for its marketing config.
        if (data.orgId) {
          getPublicOrg(data.orgId)
            .then((o) => {
              if (!alive) return;   // navigated away: don't load pixels on the next page
              setOrg(o ?? null);
              initOrgPixels(data.orgId, o?.marketing?.pixels);
              trackPixelEvent('ViewContent', { content_name: data.title, content_ids: [data.id] });
            })
            .catch(() => {/* non-fatal */});
        }
      }
      setLoading(false);
    }
    // A thrown fetch (network/Supabase error) must still clear the spinner so
    // the "Event not found" state renders instead of an infinite loader.
    let alive = true;
    fetchEvent().catch((err) => {
      console.warn('Event load failed:', err);
      setLoading(false);
    });
    return () => { alive = false; };
  }, [id, user]);

  // (Live per-tier sold/capacity subscription removed — phase-1 reads
  // sold/capacity off the mapped tiers; real-time counters return in phase-2
  // with the exos_tickets fulfillment path.)

  // Tiers visible to the current viewer: public ones, plus a hidden tier when
  // the applied voucher is restricted to it — the same rule exos-checkout
  // enforces server-side, so nothing is shown that can't be bought.
  const allTiers = [
    ...(event?.ticketTiers || []),
    ...(unlockedTier && !(event?.ticketTiers || []).some((t) => t.id === unlockedTier.id) ? [unlockedTier] : []),
  ];
  const visibleTiers = allTiers.filter((t) => {
    const visibility = (t as { visibility?: string }).visibility ?? 'public';
    if (visibility === 'public') return true;
    return !!voucher?.restrictTierId && voucher.restrictTierId === t.id;
  });

  const selectedTier = visibleTiers.find((t) => t.id === selectedTierId);

  /** Returns null if the tier is currently on sale, otherwise an
   *  explanation string ("Sales open at..." / "Sales ended"). */
  const tierWindowStatus = (
    tier: NonNullable<typeof event>['ticketTiers'] extends (infer T)[] ? T : never,
  ): string | null => {
    const t = tier as {
      salesStart?: { toMillis: () => number } | null;
      salesEnd?: { toMillis: () => number } | null;
    };
    const now = Date.now();
    if (t.salesStart && t.salesStart.toMillis() > now) {
      return `Sales open at ${formatInTz(new Date(t.salesStart.toMillis()), event?.timezone, { dateStyle: 'medium', timeStyle: 'short' })}.`;
    }
    if (t.salesEnd && t.salesEnd.toMillis() < now) {
      return 'Sales for this tier have ended.';
    }
    return null;
  };
  
  // All-in: exactly what exos-checkout will charge per ticket — the scheduled
  // price (or a server-validated voucher's pinned price) plus exclusive tax.
  const calculateFinalPrice = () => {
    if (!event) return 0;
    if (!selectedTier) return event.price;
    const voucherApplies =
      voucher?.overridePrice != null && (!voucher.restrictTierId || voucher.restrictTierId === selectedTier.id);
    const base = voucherApplies
      ? (voucher!.overridePrice as number)
      : effectiveTierPrice(selectedTier.price, selectedTier.priceSchedule);
    return allInPrice(base, selectedTier.exclusiveTaxPercent);
  };

  const priceToDisplay = calculateFinalPrice();

  const maxPerOrder = event?.purchaseLimits?.maxPerOrder || 8;

  // Apply a checkout link's tier + quantity once the event's tiers are known.
  // (A hidden tier only shows once its voucher applies; the voucher field
  // re-selects it then.)
  useEffect(() => {
    if (!prefill || !event?.ticketTiers?.length) return;
    if (event.ticketTiers.some((t) => t.id === prefill.tierId)) setSelectedTierId(prefill.tierId);
    setQuantity(Math.max(1, Math.min(maxPerOrder, prefill.quantity)));
  }, [prefill, event?.id]);
  // A voucher restricted to a tier the page doesn't list (hidden tier): fetch
  // it, show it and select it. Dropped again if the voucher is removed.
  useEffect(() => {
    const tierId = voucher?.restrictTierId;
    if (!event || !voucher || !tierId) { setUnlockedTier(null); return undefined; }
    if ((event.ticketTiers || []).some((t) => t.id === tierId)) {
      setSelectedTierId(tierId);
      return undefined;
    }
    let alive = true;
    getVoucherTier(event.id, voucher.code, user?.email ?? null).then((t) => {
      if (!alive || !t) return;
      setUnlockedTier(t);
      setSelectedTierId(t.id);
    });
    return () => { alive = false; };
  }, [event?.id, voucher?.code, voucher?.restrictTierId]);
  const maxPerAccount = event?.purchaseLimits?.maxPerAccount || 8;
  // Paid checkout is gated on the Stripe publishable key — the backend
  // (exos-checkout + exos_fulfill_checkout) is built but stays dormant until
  // payments are switched on. No key → paid tiers show "Coming soon".
  const stripeEnabled = !!(import.meta as { env?: { VITE_STRIPE_PUBLISHABLE_KEY?: string } }).env?.VITE_STRIPE_PUBLISHABLE_KEY;
  // Same routing rule as handlePurchase: anything priced needs checkout.
  const nominalPrice = (selectedTier ?? allTiers[0])?.price ?? event?.price ?? 0;
  const paidNotOnSale = !stripeEnabled && (nominalPrice > 0 || addonSel.totalCents > 0);

  const handlePurchase = async () => {
    if (!event) return;
    // Tell a buyer paid tickets aren't on sale yet BEFORE asking them to sign in.
    if (paidNotOnSale) {
      toast({ kind: 'info', title: t('event.comingSoonTitle'), message: t('event.comingSoon') });
      return;
    }
    if (!user) {
      // Pick up where they left off once signed in (survives the OAuth
      // round trip, which reloads the page).
      pendingBuyRef.current = true;
      // A redirect sign-in (Google/Apple) reloads the page: keep the choice so
      // it can be put back, never replayed without a tap.
      try {
        sessionStorage.setItem(RESUME_KEY, JSON.stringify({ id: event.id, at: Date.now(), tierId: selectedTierId, qty: quantity }));
      } catch { /* storage blocked */ }
      toast({ kind: 'info', message: 'Sign in to grab your ticket.' });
      await signIn();
      return;
    }
    // Never fall back to another tier: buying tier 0 when the buyer picked a
    // (voucher-unlocked) tier that isn't loaded would charge the wrong price.
    const tier = selectedTierId ? allTiers.find((t) => t.id === selectedTierId) : allTiers[0];
    if (!tier?.id) {
      toast({ kind: 'error', message: selectedTierId ? 'That ticket type is no longer available. Pick another.' : 'No ticket tier available for this event yet.' });
      return;
    }
    const unitPrice = tier.price ?? event.price ?? 0;
    // A purchase needs Stripe checkout whenever there's anything PRICED — a paid
    // tier OR paid add-ons. The free-claim path (exos_claim_free_tickets /
    // _free_addons) only accepts a $0 tier + $0 extras and hard-rejects priced
    // items, so a paid tier discounted to $0 must STILL go through checkout (the
    // discount is redeemed server-side there, not via the free path). We
    // therefore route on the nominal prices, never on a discounted total —
    // discount codes are org-secret + not yet server-validated.
    const needsCheckout = unitPrice > 0 || addonSel.totalCents > 0;

    if (needsCheckout) {
      if (!stripeEnabled) {
        toast({ kind: 'info', title: t('event.comingSoonTitle'), message: t('event.comingSoon') });
        return;
      }
      setPurchasing(true);
      try {
        const url = await startCheckout({
          eventId: event.id,
          tierId: tier.id,
          quantity,
          successUrl: publicUrl('my-tickets?checkout=success'),
          cancelUrl: publicUrl(`event/${event.id}`),
          addons: addonSel.items,
          voucherCode: voucher?.code,
          attribution,
        });
        clearPrefill(event.id);
        window.location.href = url; // leave the SPA for Stripe-hosted checkout
      } catch (err: any) {
        console.error('Checkout failed:', err);
        toast({ kind: 'error', message: err?.message || 'Could not start checkout.' });
        setPurchasing(false);
      }
      return;
    }

    // Free claim — mint to the buyer, capturing campaign attribution off the URL
    // (?promoter / ?utm_source) so it lands in the event's Sales report.
    setPurchasing(true);
    try {
      // Shared idempotency/order ref so any free $0 extras attach to this claim.
      const orderRef = crypto.randomUUID();
      const ids = await claimFreeTickets({
        eventId: event.id,
        tierId: tier.id,
        quantity,
        promoterId: attribution.promoter ?? null,
        channel: attribution.utm_source ?? null,
        // Idempotency key for this claim attempt — a network retry returns the
        // same tickets instead of minting twice (button is disabled meanwhile).
        orderRef,
      });
      // Credit the friend whose link brought this buyer (paid orders are
      // credited at fulfillment from the checkout attribution).
      if (attribution.ref) void attachReferral(orderRef, attribution.ref);
      // Stamp attendee names onto the new tickets (best-effort — a name hiccup
      // must not fail a claim that already minted).
      // Pair names with tickets in MINT order. A fresh mint returns ids in
      // order, but the RPC's idempotent-retry branch (same order_ref) returns
      // them unordered — so re-read this order's tickets sorted by creation
      // time rather than trusting the array position.
      const wanted = attendeeNames.slice(0, ids.length).map((n) => (n || '').trim());
      let ordered = ids;
      if (wanted.some(Boolean) && ids.length > 1) {
        try {
          const mine = await listMyTicketsForEvent(event.id);
          const thisOrder = mine
            .filter((t) => t.orderId === orderRef && ids.includes(t.id))
            .sort((a, b) => (a.purchaseDate?.toMillis?.() ?? 0) - (b.purchaseDate?.toMillis?.() ?? 0) || a.id.localeCompare(b.id));
          if (thisOrder.length === ids.length) ordered = thisOrder.map((t) => t.id);
        } catch (e) {
          console.warn('could not re-order tickets for naming; using mint order', e);
        }
      }
      const nameResults = await Promise.allSettled(
        ordered.map((id, i) => (wanted[i] ? setTicketAttendee(id, wanted[i]) : Promise.resolve(null))),
      );
      const nameFailures = nameResults.filter((r) => r.status === 'rejected');
      if (nameFailures.length > 0) {
        console.error('setTicketAttendee failed for', nameFailures.length, 'ticket(s):', nameFailures);
        toast({
          kind: 'warn',
          message: t('event.namesNotSaved', { n: nameFailures.length }),
        });
      }
      // Attach any free extras (best-effort — a swag hiccup shouldn't fail the
      // ticket claim the buyer already completed).
      if (addonSel.items.length > 0) {
        try {
          await claimFreeAddons(event.id, orderRef, addonSel.items);
        } catch (addErr) {
          console.error('claimFreeAddons failed:', addErr);
        }
      }
      trackPixelEvent('Purchase', {
        content_name: event.title,
        content_ids: [event.id],
        value: 0,
        currency: event.currency || 'USD',
        num_items: ids.length,
      });
      clearPrefill(event.id);
      // My Tickets shows the confirmation (see its ?claimed handler).
      navigate(`/my-tickets?claimed=${ids.length}`);
    } catch (err: any) {
      console.error('Free claim failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not reserve tickets. Please try again.' });
    } finally {
      setPurchasing(false);
    }
  };

  // After sign-in. Same page (email sign-in, nothing reloaded): the buyer's
  // choices are intact, so carry on with the purchase they tapped. After a
  // redirect sign-in the page reloaded: put their ticket type and quantity
  // back and ask for one more tap. Never buys on a later, unrelated visit.
  useEffect(() => {
    if (!user || !event) return;
    let saved: { id?: string; at?: number; tierId?: string | null; qty?: number } | null = null;
    try {
      const raw = sessionStorage.getItem(RESUME_KEY);
      if (raw) saved = JSON.parse(raw);
      sessionStorage.removeItem(RESUME_KEY);
    } catch { /* storage blocked or bad JSON */ }
    if (pendingBuyRef.current) {
      pendingBuyRef.current = false;
      void handlePurchase();
      return;
    }
    if (!saved || saved.id !== event.id || !saved.at || Date.now() - saved.at > RESUME_TTL_MS) return;
    if (saved.tierId && (event.ticketTiers ?? []).some((t) => t.id === saved!.tierId)) setSelectedTierId(saved.tierId);
    if (saved.qty && saved.qty > 0) setQuantity(Math.min(maxPerOrder, saved.qty));
    toast({ kind: 'info', message: "You're signed in. Check your tickets and tap Buy to finish." });
    buyCardRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user?.uid, event?.id]);

  // Closing the sign-in modal without signing in drops the pending purchase.
  useEffect(() => {
    if (isAuthModalOpen || user || !pendingBuyRef.current) return;
    pendingBuyRef.current = false;
    try { sessionStorage.removeItem(RESUME_KEY); } catch { /* storage blocked */ }
  }, [isAuthModalOpen, user]);

  useEffect(() => {
    const el = buyCardRef.current;
    if (!el || typeof IntersectionObserver === 'undefined') return undefined;
    const io = new IntersectionObserver(([entry]) => setBuyInView(entry.isIntersecting), { threshold: 0.15 });
    io.observe(el);
    return () => io.disconnect();
  }, [event?.id, loading]);

  const handleShare = async () => {
    const shareData = {
      title: event?.title,
      text: `Join me at ${event?.title}!`,
      url: window.location.href,
    };

    try {
      if (navigator.share) {
        await navigator.share(shareData);
      } else {
        await navigator.clipboard.writeText(window.location.href);
        toast({ kind: 'success', message: 'Link copied to clipboard.' });
      }
    } catch (err) {
      console.error('Error sharing:', err);
    }
  };

  /**
   * TEST-MODE BYPASS — admin only.
   *
   * Mints a ticket directly without going through Stripe checkout.
   * Used for end-to-end validation of the QR / check-in flow without
   * needing a real payment processor wired up. The ticket is written
   * with a `bypass_test_<random>` stripeSessionId so admin tooling can
   * later filter and purge test tickets.
   *
   * Mirrors the writes that MyTickets fulfillment does on real
   * Stripe-success (ticket doc + tierSales increment + event
   * ticketsSold increment), so the resulting ticket behaves
   * identically to a real one — same rotating HMAC barcode, same
   * check-in flow, same audit-log path.
   *
   * The "TEST" label on the button is intentionally loud so this
   * never gets confused with a real purchase. We also gate visibility
   * on `isAdmin` so regular users don't see it.
   */
  const handleTestBuy = async () => {
    if (!user || !event) return;
    if (!isAdmin) {
      toast({ kind: 'error', message: 'Test mint is admin-only.' });
      return;
    }
    // Comp / test-mint via the SECDEF exos_mint_tickets RPC (org-staff or
    // admin). Mints real exos_tickets rows — same rotating-barcode + check-in
    // path as a paid ticket — so the end-to-end flow (wallet → door scan →
    // transfer) is exercisable without Stripe checkout (which stays phase-2).
    setPurchasing(true);
    try {
      const tier = selectedTierId ? allTiers.find((t) => t.id === selectedTierId) : allTiers[0];
      const ids = await mintTickets({
        eventId: event.id,
        tierId: tier?.id ?? null,
        quantity,
        orderRef: `comp_${crypto.randomUUID()}`,
        pricePaid: 0,
      });
      toast({ kind: 'success', message: `Minted ${ids.length} test ticket(s).` });
      navigate('/my-tickets');
    } catch (err: any) {
      console.error('Test mint failed:', err);
      toast({ kind: 'error', message: err?.message || 'Test mint failed.' });
    } finally {
      setPurchasing(false);
    }
  };

  const handleInstagramStory = async () => {
    if (!event) return;
    // Share the event POSTER image to the OS share sheet (→ Instagram Story),
    // with the URL copied for the link sticker. Shared impl in lib/poster.ts.
    await shareEventToStory(
      {
        title: event.title,
        url: publicUrl(eventSharePath(event)),
        imageUrl: event.image,
        dateLabel: event.date
          ? formatInTz(event.date.toDate(), event.timezone, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
          : undefined,
        venue: event.location,
        role: 'fan',
        promoter: attribution.promoter,
        mentions: mentionsFor('instagram_story', shareTags),
      },
      toast,
    );
  };

  const handleSMSShare = () => {
    const text = `${withMentions(`Join me at ${event?.title}!`, mentionsFor('sms', shareTags))} Access intel here: ${window.location.href}`;
    window.location.href = `sms:?&body=${encodeURIComponent(text)}`;
  };

  if (loading) return <div className="wall min-h-screen"><div className="max-w-7xl mx-auto p-24 text-center type text-white/50 uppercase tracking-[0.3em] animate-pulse">loading experience details…</div></div>;
  if (!event) return <div className="wall min-h-screen"><div className="max-w-7xl mx-auto p-20 text-center type text-white/50 uppercase tracking-widest text-xs">event not found.</div></div>;

  // Helper: live sold/capacity for a given tier from the sub-collection,
  // falling back to the embedded values if the sub-collection hasn't loaded
  // yet (first paint) or the tier predates the sub-collection migration.
  const liveTier = (tierId: string, fallbackCap?: number) => {
    const t = event?.ticketTiers?.find((x) => x.id === tierId);
    return {
      sold: t?.sold ?? 0,
      capacity: t?.capacity ?? fallbackCap ?? 0,
    };
  };

  // Lifecycle gate. Drafts are only renderable to the organizer; if a
  // non-organizer somehow lands here (e.g. they bookmarked a draft URL,
  // or the rule loosens later), show a friendly "not available" instead
  // of half-rendering the page. Cancelled events stay viewable so old
  // ticket-holders can find context.
  const eventStatus = event.status ?? 'published';
  const isOrganizer = !!user && user.uid === event.organizerId;
  // Draft visibility is enforced server-side: getPublicEvent returns
  // published-only and getEventForEdit is RLS-gated to org staff, so a draft in
  // state means the viewer is authorized — no extra client gate needed.

  const soldOut = selectedTier
    ? (() => {
        const t = liveTier(selectedTier.id, selectedTier.capacity);
        return t.sold >= t.capacity;
      })()
    : event.ticketsSold >= event.totalTickets;

  const primaryStyle = event.branding?.primaryColor ? { backgroundColor: event.branding.primaryColor } : {};
  const accentStyle = event.branding?.accentColor ? { color: event.branding.accentColor } : {};
  const accentBgStyle = event.branding?.accentColor ? { backgroundColor: event.branding.accentColor } : {};
  const accentBorderStyle = event.branding?.accentColor ? { borderColor: event.branding.accentColor } : {};

  return (
    <div className="wall grain min-h-screen text-white relative">
      <InAppBrowserBanner />
      {/* Local reproduction of the mockup's bespoke `.grain` film-grain
          overlay — not in index.css, so it's copied verbatim from the
          EventDetails/Checkout mockup <style> blocks. `.wall`, `.disp`,
          `.type`, `.neon`, `.xerox`, `.stamp` all live in index.css. */}
      <style>{`
        .grain::before{ content:""; position:fixed; inset:0; z-index:1; pointer-events:none; opacity:.055; mix-blend-mode:overlay; background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='180'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E"); }
      `}</style>
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8 relative z-10">
        <button onClick={() => navigate(-1)} className="type inline-flex items-center gap-2 text-white/50 hover:text-white mb-10 transition-colors text-[12px] uppercase tracking-widest">
          <ArrowLeft className="w-4 h-4 text-brand-primary" />
          back to events
        </button>

        {eventStatus === 'cancelled' && (
          <div className="mb-8 p-5 border border-brand-accent/40 bg-brand-accent/10">
            <p className="type text-xs uppercase tracking-widest text-brand-accent mb-2">
              This event has been cancelled
            </p>
            {event.cancelReason && (
              <p className="text-sm text-red-100/80 mb-2">
                <span className="type uppercase tracking-widest text-brand-accent/60 text-[10px]">Reason: </span>
                {event.cancelReason}
              </p>
            )}
            <p className="type text-xs text-red-100/60 leading-relaxed">
              If you bought directly through this site, your refund will be issued
              automatically within 5 business days. If you bought via a partner site
              (StubHub, Vivid Seats, etc.) please contact that channel for refund
              processing.
            </p>
          </div>
        )}

        {eventStatus === 'draft' && isOrganizer && (
          <div className="mb-8 p-4 border border-amber-300/30 bg-amber-300/10 flex items-center justify-between">
            <p className="type text-[10px] uppercase tracking-widest text-amber-200">
              DRAFT — only you can see this. Publish from the Edit screen to list it.
            </p>
            <Link
              to={`/edit-event/${event.id}`}
              className="type text-[10px] uppercase tracking-widest text-amber-200 hover:text-white"
            >
              Edit →
            </Link>
          </div>
        )}
        {eventStatus === 'cancelled' && (
          <div className="mb-8 p-4 border border-brand-accent/40 bg-brand-accent/10">
            <p className="type text-[10px] uppercase tracking-widest text-brand-accent">
              CANCELLED — sales are closed.
            </p>
          </div>
        )}

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-14">
          {/* Left Column: Image and Description */}
          <div className="lg:col-span-2">
            <div className="group aspect-video relative mb-12 border border-white/10 overflow-hidden">
              <img
                src={event.image || 'https://images.unsplash.com/photo-1516450360452-9312f5e86fc7?q=80&w=1200'}
                alt={event.title}
                className="xerox w-full h-full object-cover transition-all duration-700"
              />
              <div className="absolute inset-0 bg-gradient-to-t from-black via-transparent to-transparent opacity-80"></div>
              <div className="absolute bottom-8 left-8 right-8">
                <span className="disp bg-brand-primary text-black px-3 text-lg tracking-wide inline-block mb-3">
                  {event.category}
                </span>
                <h1 className="disp text-5xl md:text-7xl tracking-tight leading-[0.85]">{event.title}</h1>
              </div>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-px bg-white/10 border border-white/10 mb-14">
              <div className="flex items-center gap-5 p-7 bg-[#111]">
                <div className="w-12 h-12 bg-white/5 flex items-center justify-center shrink-0">
                   <Calendar className="text-brand-primary w-6 h-6" />
                </div>
                <div>
                   <p className="type text-[10px] text-white/30 uppercase tracking-widest mb-1">date &amp; time</p>
                   <p className="disp text-xl tracking-tight">{formatInTz(event.date.toDate(), event.timezone, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}</p>
                   {event.date && eventStatus !== 'cancelled' && (
                     <p className="type text-[10px] text-brand-primary uppercase tracking-widest mt-1">
                       <EventCountdown
                         startsAt={event.date.toDate()}
                         doorsOpen={
                           event.timing?.doorsOpen
                             ? typeof event.timing.doorsOpen === 'string'
                               ? new Date(event.timing.doorsOpen)
                               : (event.timing.doorsOpen as any).toDate?.() ?? null
                             : null
                         }
                       />
                     </p>
                   )}
                   {event.timing && (
                     <div className="flex gap-3 mt-1 type text-[10px] text-white/40 uppercase tracking-widest">
                        {event.timing.doorsOpen && (
                          <span>
                            DOORS {formatInTz(
                              typeof event.timing.doorsOpen === 'string'
                                ? new Date(event.timing.doorsOpen)
                                : (event.timing.doorsOpen as any).toDate(),
                              event.timezone,
                              { hour: 'numeric', minute: '2-digit' },
                            )}
                          </span>
                        )}
                        {event.timing.startTime && (
                          <span className="text-brand-primary">
                            START {formatInTz(
                              typeof event.timing.startTime === 'string'
                                ? new Date(event.timing.startTime)
                                : (event.timing.startTime as any).toDate(),
                              event.timezone,
                              { hour: 'numeric', minute: '2-digit' },
                            )}
                          </span>
                        )}
                        {event.timezone && (
                          <span className="text-white/30">// {event.timezone}</span>
                        )}
                     </div>
                   )}
                </div>
              </div>
              <div className="flex items-center gap-5 p-7 bg-[#111]">
                <div className="w-12 h-12 bg-white/5 flex items-center justify-center shrink-0">
                   <MapPin className="text-brand-primary w-6 h-6" />
                </div>
                <div>
                   <p className="type text-[10px] text-white/30 uppercase tracking-widest mb-1">location</p>
                   <p className="disp text-xl tracking-tight">{event.location}</p>
                </div>
              </div>
              <VenueMap eventId={event.id} location={event.location} address={event.address} />
              <EventAccessInfo accessibility={event.accessibility} />

              {/* Performers block — only renders when the organizer
                  has set at least one. First name is treated as the
                  headliner (slightly larger). The block sits above
                  genres because at a music event, performer names
                  are usually what the buyer cares about most. */}
              {event.performers && event.performers.length > 0 ? (
                <div className="p-7 bg-[#111] sm:col-span-2">
                  <p className="type text-[10px] text-white/30 uppercase tracking-widest mb-3">performers</p>
                  <div className="flex flex-wrap items-baseline gap-x-5 gap-y-2">
                    {event.performers.map((name, i) => {
                      const links = linksForArtist(name, event.artistLinks);
                      return (
                        <span key={name} className="inline-flex items-center gap-2">
                          <span
                            className={
                              i === 0
                                ? 'disp text-3xl tracking-tight text-white'
                                : 'disp text-xl tracking-tight text-white/60'
                            }
                          >
                            {name}
                          </span>
                          {links ? <ArtistLinks artist={links} /> : null}
                        </span>
                      );
                    })}
                  </div>
                </div>
              ) : null}
              <div className="flex items-center gap-5 p-7 bg-[#111] sm:col-span-2">
                <div className="w-12 h-12 bg-white/5 flex items-center justify-center shrink-0">
                   <Tag className="text-brand-primary w-6 h-6" />
                </div>
                <div>
                   <p className="type text-[10px] text-white/30 uppercase tracking-widest mb-1">genres</p>
                   <p className="disp text-xl tracking-tight">
                      {event.genres?.join(', ') || event.category}
                      {event.subgenres && event.subgenres.length > 0 && <span className="text-white/40 ml-2">({event.subgenres.join(', ')})</span>}
                   </p>
                </div>
              </div>
            </div>

            <div className="mb-14">
              <h2 className="disp text-3xl tracking-tight mb-6 border-l-4 border-brand-primary pl-4">ABOUT THE EVENT</h2>
              <p className="type text-white/60 text-base leading-relaxed whitespace-pre-wrap">{event.description}</p>
            </div>

            <div className="mb-14 bg-[#111] border border-white/10 p-7 flex items-center justify-between group">
               <div className="flex items-center gap-5">
                  <div className="w-16 h-16 bg-brand-primary flex items-center justify-center disp text-3xl text-black">
                    {(org?.name || 'O').charAt(0).toUpperCase()}
                  </div>
                  <div>
                    <p className="type text-[10px] text-white/40 uppercase tracking-widest mb-1">presented by</p>
                    <h3 className="disp text-2xl tracking-tight">{org?.name || 'Event Organizer'}</h3>
                    {org?.marketing?.socials && Object.values(org.marketing.socials).some(Boolean) ? (
                      <SocialLinks socials={org.marketing.socials} className="flex items-center gap-3 mt-2" />
                    ) : null}
                  </div>
               </div>
               <Link to={`/organizer/${event.orgId ?? ''}`} className="type px-5 py-2.5 bg-white/5 border border-white/10 text-[11px] uppercase tracking-widest group-hover:bg-brand-primary group-hover:text-black transition-colors">
                  view profile
               </Link>
            </div>
          </div>

          {/* Right Column: Checkout Card */}
          <div className="lg:col-span-1">
            <div id="buy" ref={buyCardRef} className="lg:sticky top-24 bg-[#111] border border-white/10 overflow-hidden scroll-mt-24">
              <div className="p-7">
                <div className="mb-8">
                    <p className="type text-[10px] text-white/30 uppercase tracking-widest mb-2">price</p>
                    <p className="disp text-6xl neon tracking-tight">{formatCurrency(priceToDisplay * quantity, event.currency)}</p>
                    <p className="type mt-1 text-[10px] uppercase tracking-widest text-white/40">
                      {selectedTier?.exclusiveTaxPercent ? 'all-in · incl. tax · no fees at checkout' : 'all-in · no fees at checkout'}
                    </p>
                    {selectedTier && (() => {
                      // Scheduled-pricing urgency nudge: surface the next upward
                      // step so buyers see "price rises to $X on <date>".
                      const cur = effectiveTierPrice(selectedTier.price, selectedTier.priceSchedule);
                      const next = nextPriceStep(selectedTier.priceSchedule);
                      if (!next || next.price <= cur) return null;
                      const nextAllIn = allInPrice(next.price, selectedTier.exclusiveTaxPercent);
                      return (
                        <p className="type mt-2 text-[10px] uppercase tracking-widest text-brand-accent">
                          ⏱ price rises to {formatCurrency(nextAllIn, event.currency)} on{' '}
                          {formatInTz(new Date(next.startsAt), event.timezone, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })}
                        </p>
                      );
                    })()}
                </div>

                {/* Tier Selection */}
                {event.ticketTiers && event.ticketTiers.length > 0 && (
                  <div className="mb-8 space-y-2">
                     <p className="type text-[10px] text-white/30 uppercase tracking-widest mb-3">{t('event.pickTicket')}</p>
                     {visibleTiers.map((tier) => {
                       const tierLive = liveTier(tier.id, tier.capacity);
                       const tierLeft = Math.max(0, tierLive.capacity - tierLive.sold);
                       return (
                       <button
                         key={tier.id}
                         onClick={() => setSelectedTierId(tier.id)}
                         aria-pressed={selectedTierId === tier.id}
                         className={`w-full p-5 text-left border-2 transition-all relative overflow-hidden flex flex-col items-start ${
                           selectedTierId === tier.id
                             ? 'border-brand-primary bg-brand-primary/5'
                             : 'border-white/10 hover:border-white/30 hover:bg-white/5'
                         } ${tierLeft === 0 ? 'opacity-60' : ''}`}
                       >
                         {selectedTierId === tier.id && (
                            <div className="absolute top-0 right-0 w-7 h-7 bg-brand-primary flex items-center justify-center">
                               <CheckCircle2 className="w-4 h-4 text-black" />
                            </div>
                         )}

                         <div className="flex justify-between items-center w-full mb-1 gap-3">
                            <p className="disp text-xl tracking-tight text-white">{tier.name}</p>
                            {(() => {
                              const eff = buyerTierPrice(tier);
                              const opening = allInPrice(tier.price, tier.exclusiveTaxPercent);
                              const markedDown = eff < opening;
                              return (
                                <span className="inline-flex items-center gap-2 shrink-0">
                                  {markedDown && (
                                    <span className="type text-white/30 line-through text-xs">{formatCurrency(opening, event.currency)}</span>
                                  )}
                                  <span className="stamp neon text-base">{formatCurrency(eff, event.currency)}</span>
                                </span>
                              );
                            })()}
                         </div>

                         <p className="type text-[10px] text-white/50 mb-3">{tier.description}</p>
                         {tier.accessible && (
                           <p className="type text-[11px] text-sky-200 mb-3 flex items-start gap-1.5">
                             <AccessIcon className="w-3.5 h-3.5 mt-px shrink-0" aria-hidden="true" />
                             <span><span className="font-bold">Accessible</span>{tier.accessibleNote ? ` · ${tier.accessibleNote}` : ''}</span>
                           </p>
                         )}
                         <TableTierInfo eventId={event.id} tierId={tier.id} price={buyerTierPrice(tier)} currency={event.currency} />

                         <div className="flex items-center gap-2">
                           <span className={`w-1.5 h-1.5 ${tierLeft < 10 ? 'bg-brand-accent' : 'bg-brand-primary'}`}></span>
                           <span className={`type text-[9px] uppercase tracking-widest leading-none ${tierLeft === 0 ? 'text-brand-accent' : 'text-white/40'}`}>
                             {tierLeft === 0
                               ? t('event.tierSoldOut')
                               : !stripeEnabled && tier.price > 0
                                 ? t('event.onSaleSoon')
                                 : t('event.left', { n: tierLeft })}
                           </span>
                         </div>
                       </button>
                       );
                     })}
                  </div>
                )}

                <div className="mb-8">
                   <p className="type text-[10px] text-white/30 uppercase tracking-widest mb-3">quantity</p>
                   <div className="flex items-center gap-5 bg-black p-3 border border-white/10">
                      <button
                        onClick={() => setQuantity(Math.max(1, quantity - 1))}
                        className="w-10 h-10 bg-white/5 flex items-center justify-center hover:bg-white/10 transition-colors"
                      >
                        <Minus className="w-4 h-4 text-white" />
                      </button>
                      <span className="disp text-2xl flex-1 text-center">{quantity}</span>
                      <button
                        onClick={() => setQuantity(Math.min(maxPerOrder, quantity + 1))}
                        className="w-10 h-10 bg-white/5 flex items-center justify-center hover:bg-white/10 transition-colors"
                      >
                        <Plus className="w-4 h-4 text-white" />
                      </button>
                   </div>
                   <p className="type text-[9px] text-white/20 uppercase tracking-widest mt-2">max per order: {maxPerOrder} · total limit: {maxPerAccount}</p>
                </div>

                {/* Who is going — optional per-ticket names. FREE claim path only:
                    the paid path hands off to Stripe and never sees these (the
                    checkout metadata route is a later add). */}
                {priceToDisplay === 0 && addonSel.totalCents === 0 && (
                <div className="mb-8">
                   <p className="type text-[10px] text-white/30 uppercase tracking-widest mb-3">{t('event.whosGoing')} <span className="text-white/20">{t('event.optional')}</span></p>
                   <div className="space-y-2">
                     {Array.from({ length: quantity }).map((_, i) => (
                       <input
                         key={i}
                         value={attendeeNames[i] ?? ''}
                         maxLength={80}
                         onChange={(e) => setAttendeeNames((prev) => { const next = [...prev]; next[i] = e.target.value; return next; })}
                         aria-label={`Name on ticket ${i + 1}`}
                         placeholder={i === 0 ? t('event.ticketYou', { n: 1, name: user?.displayName || t('event.you') }) : t('event.ticketFriend', { n: i + 1 })}
                         className="type w-full bg-black border border-white/10 px-3 py-2.5 text-white text-sm placeholder-white/25 focus:border-brand-primary outline-none"
                       />
                     ))}
                   </div>
                </div>
                )}

                <div className="space-y-6 mb-6">
                  <div className="divide-y divide-white/5 border-t border-white/5">
                    <div className="flex justify-between type text-[10px] py-3.5 uppercase tracking-widest">
                      <span className="text-white/30">status</span>
                      <span className={soldOut ? 'text-brand-accent' : 'neon'}>
                        {soldOut ? t('event.soldOut') : t('event.available')}
                      </span>
                    </div>
                    <div className="flex justify-between type text-[10px] py-3.5 uppercase tracking-widest">
                      <span className="text-white/30">tickets available</span>
                      <span className="text-white">
                        {selectedTier
                          ? (() => {
                              const t = liveTier(selectedTier.id, selectedTier.capacity);
                              return `${Math.max(0, t.capacity - t.sold)}`;
                            })()
                          : `${event.totalTickets - event.ticketsSold}`}
                      </span>
                    </div>
                  </div>
                </div>

                {/* A valid voucher can unlock a sold-out event (or pin a price). */}
                <VoucherField
                  eventId={event.id}
                  email={user?.email ?? null}
                  onApplied={setVoucher}
                  initialCode={prefill?.coupon}
                />

                {(!soldOut || voucher?.canBypass) && (
                  <AddonSelector
                    eventId={event.id}
                    currency={event.currency || 'USD'}
                    onChange={setAddonSel}
                    initialQty={prefill?.addons}
                  />
                )}

                <button
                  disabled={(soldOut && !voucher?.canBypass) || purchasing || paidNotOnSale}
                  onClick={handlePurchase}
                  className="disp w-full bg-brand-primary text-black py-4 text-xl tracking-wide flex items-center justify-center gap-3 hover:scale-[1.01] transition-transform disabled:bg-white/10 disabled:text-white/20 disabled:scale-100"
                >
                  {purchasing ? (
                    <span className="animate-pulse tracking-wide">{t('event.processing')}</span>
                  ) : (
                    <>
                      <Ticket className="w-5 h-5" />
                      <span className="tracking-wide">{(soldOut && !voucher?.canBypass) ? t('event.soldOut') : paidNotOnSale ? t('event.onSaleSoon') : t('event.buy')}</span>
                    </>
                  )}
                </button>

                {paidNotOnSale && !soldOut && (
                  <p className="type mt-3 text-[11px] text-white/50 leading-relaxed">
                    {t('event.onSaleSoonHint')}
                  </p>
                )}

                {soldOut && !voucher?.canBypass && (
                  <div className="mt-3">
                    <WaitlistCTA
                      eventId={event.id}
                      tierId={selectedTierId}
                      defaultEmail={user?.email ?? null}
                      defaultName={user?.displayName ?? null}
                      accentStyle={accentBgStyle}
                    />
                  </div>
                )}

                {/*
                  TEST-MODE bypass — admin-only. Skips Stripe and mints
                  a ticket directly so we can validate QR + check-in
                  end-to-end without payments wired. Visible label is
                  intentionally loud so this never gets confused with a
                  real purchase. Remove once Stripe Connect is live and
                  buyers pay through the regular flow.
                */}
                {isAdmin && !soldOut && (
                  <button
                    type="button"
                    disabled={purchasing}
                    onClick={handleTestBuy}
                    className="type mt-3 w-full bg-amber-500/10 border-2 border-amber-500/40 hover:bg-amber-500/20 text-amber-200 py-3 uppercase tracking-widest text-[11px] transition-all disabled:opacity-50"
                  >
                    🧪 test mint (admin · bypasses stripe)
                  </button>
                )}

                <div className="mt-7 flex flex-col gap-3.5 type text-[10px] uppercase tracking-widest text-white/30">
                  <div className="flex items-center gap-3">
                    <ShieldCheck className="w-4 h-4 text-brand-primary" />
                    secure digital entry
                  </div>
                  <button onClick={() => setShowShare(true)} className="flex items-center gap-3 hover:text-brand-primary transition-colors text-left">
                    <Share2 className="w-4 h-4 text-brand-primary" />
                    share link
                  </button>
                  <button onClick={handleSMSShare} className="flex items-center gap-3 hover:text-brand-primary transition-colors text-left">
                    <Send className="w-4 h-4 text-brand-primary" />
                    send via sms
                  </button>
                  <AddToCalendar event={event} />
                  <button onClick={handleInstagramStory} className="flex items-center gap-3 hover:text-brand-primary transition-colors text-left">
                    <Instagram className="w-4 h-4 text-brand-primary" />
                    share to instagram
                  </button>
                  <SaveEventButton eventId={event.id} variant="row" />
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      {!buyInView && eventStatus !== 'cancelled' && (() => {
        const open = visibleTiers.filter((tier) => {
          const l = liveTier(tier.id, tier.capacity);
          return l.capacity - l.sold > 0;
        });
        const from = open.length ? Math.min(...open.map((tier) => buyerTierPrice(tier))) : null;
        return (
          <div className="lg:hidden fixed bottom-0 inset-x-0 z-40 bg-black/95 border-t border-white/10 backdrop-blur px-4 py-3 flex items-center gap-4" style={{ paddingBottom: 'max(0.75rem, env(safe-area-inset-bottom))' }}>
            <div className="min-w-0 flex-1">
              <p className="type text-[10px] uppercase tracking-widest text-white/40">{from == null ? t('event.soldOut') : t('event.from')}</p>
              {from != null && <p className="disp text-2xl neon leading-none">{from === 0 ? t('event.free') : formatCurrency(from, event.currency)}</p>}
            </div>
            <button
              type="button"
              onClick={() => buyCardRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' })}
              className="disp bg-brand-primary text-black px-6 py-3 text-lg tracking-wide shrink-0"
            >
              {from == null ? t('event.joinWaitlist') : t('event.getTickets')}
            </button>
          </div>
        );
      })()}

      {/*
        Unified share modal — single entry point for the "Share Link"
        button on the event card. Falls back to platform pickers when
        navigator.share isn't available. Promoter attribution is
        threaded through if the URL we're on already has ?promoter=X
        — that's how a buyer who arrived via a promoter link can pass
        the same attribution forward when they share.
      */}
      {event && (
        <ShareModal
          open={showShare}
          onClose={() => setShowShare(false)}
          title={event.title}
          url={window.location.href.split('?')[0]}
          promoterId={attribution.promoter}
          tags={shareTags}
        />
      )}
    </div>
  );
}
