// OrganizerOnboarding — multi-step welcome flow for first-time
// organizers (or anyone who lands at /onboarding).
//
// Steps:
//   1. Welcome — what Exos is, what an org gets.
//   2. Create org — name + slug. Atomic batch via lib/orgs.
//   3. Brand — logo + primary/accent. Optional, can defer.
//   4. Payments — Stripe Connect, so paid tiers can sell. Optional for free events.
//   5. First event — explanatory copy + CTA into /create-event.
//   6. Done — links to dashboard, /o/:slug storefront, embed snippet.
//
// Step state is held in the URL hash (#step=N) so a refresh resumes
// where the user was. Completed-state persisted to localStorage so
// signed-in users with at least one org skip directly to the
// dashboard. The Navbar's "Get Started" link routes here for new
// signups.

import { ChangeEvent, FormEvent, ReactNode, useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { motion } from 'motion/react';
import {
  Calendar,
  Check,
  ChevronRight,
  CreditCard,
  Globe,
  Image as ImageIcon,
  Sparkles,
} from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import {
  createOrganization,
  isHexColor,
  isValidOrgSlug,
  mergeOrgTheme,
  slugify,
  updateOrganization,
} from '../lib/orgs';
import { uploadOrgLogo } from '../lib/orgLogo';
import { errMessage, isOrgHandleTaken, publicUrl } from '../lib/utils';
import { paymentsEnabled } from '../lib/payments';
import { startStripeOnboarding } from '../lib/checkout';
import { useHandleAvailability } from '../hooks/useHandleAvailability';
import { useOrgPaymentsReady } from '../hooks/useOrgPaymentsReady';

type Step = 1 | 2 | 3 | 4 | 5 | 6;
const LAST_STEP = 6;
const STEPS: { n: Step; title: string; subtitle: string }[] = [
  { n: 1, title: 'Welcome', subtitle: 'What Exos does for your venue' },
  { n: 2, title: 'Org', subtitle: 'Name your venue or promoter brand' },
  { n: 3, title: 'Brand', subtitle: 'Logo and colors for your storefront' },
  { n: 4, title: 'Payments', subtitle: 'Connect Stripe to sell paid tickets' },
  { n: 5, title: 'Event', subtitle: 'Create your first listing' },
  { n: 6, title: 'Done', subtitle: 'Where to go from here' },
];

const ONBOARDING_DONE_KEY = 'vibepass:onboarded';

export default function OrganizerOnboarding() {
  const { user, openAuthModal } = useAuth();
  const { activeOrg, orgs, refresh, setActiveOrg } = useOrganization();
  const { toast } = useToast();
  const navigate = useNavigate();

  // Read initial step from URL hash. Defaults to 1.
  const [step, setStep] = useState<Step>(() => {
    const m = /step=(\d)/.exec(window.location.hash);
    const n = m ? parseInt(m[1], 10) : 1;
    return (n >= 1 && n <= LAST_STEP ? n : 1) as Step;
  });

  // Step 2 state (org create)
  const [orgName, setOrgName] = useState('');
  const [orgSlug, setOrgSlug] = useState('');
  const [slugManuallyEdited, setSlugManuallyEdited] = useState(false);
  const [creatingOrg, setCreatingOrg] = useState(false);
  const handleState = useHandleAvailability(orgSlug);

  // Step 3 state (theme)
  const [primary, setPrimary] = useState('#FFE714');
  const [accent, setAccent] = useState('#0A0A0A');
  const [savingTheme, setSavingTheme] = useState(false);
  // The logo uploaded on this step: the org in context isn't refreshed after
  // the upload, so "Save & Continue" must not write a theme without it.
  const [logoUrl, setLogoUrl] = useState<string | null>(null);
  const colorsValid = isHexColor(primary) && isHexColor(accent);

  // Step 4 state (Stripe Connect)
  const paymentsReady = useOrgPaymentsReady(activeOrg?.id);
  const [openingStripe, setOpeningStripe] = useState(false);

  useEffect(() => {
    if (!slugManuallyEdited) setOrgSlug(slugify(orgName));
  }, [orgName, slugManuallyEdited]);

  useEffect(() => {
    window.location.hash = `step=${step}`;
  }, [step]);

  // If the user already has an org and lands here, fast-forward to
  // step 5 instead of making them re-create. We keep the door open
  // for repeat visits (e.g., via "tour" link from dashboard).
  useEffect(() => {
    if (orgs.length > 0 && step === 1) {
      // Don't force-skip — let the welcome screen render once. The
      // user can navigate forward when ready. If they're past step 1
      // we don't change anything.
    }
  }, [orgs, step]);

  if (!user) {
    return (
      <div className="max-w-2xl mx-auto p-12 text-center">
        <h2 className="text-3xl font-bold tracking-tight text-slate-900 mb-4">
          Sign in to get started
        </h2>
        <p className="text-slate-500 mb-6">
          Exos organizers need an account to manage events and track sales.
        </p>
        <button
          onClick={openAuthModal}
          className="px-8 py-3 bg-tm-blue text-white font-bold rounded hover:bg-[#015bbd] shadow-sm transition-all"
        >
          Sign In
        </button>
      </div>
    );
  }

  function goNext() {
    if (step < LAST_STEP) setStep((step + 1) as Step);
  }
  function goPrev() {
    if (step > 1) setStep((step - 1) as Step);
  }

  function finish() {
    try {
      localStorage.setItem(ONBOARDING_DONE_KEY, '1');
    } catch {
      /* ignore */
    }
    navigate('/dashboard');
  }

  async function handleCreateOrg(e: FormEvent) {
    e.preventDefault();
    if (!user) return;
    if (orgName.trim().length === 0) {
      toast({ kind: 'error', message: 'Name your org first.' });
      return;
    }
    if (!isValidOrgSlug(orgSlug)) {
      toast({ kind: 'error', message: 'Slug must be lowercase letters, numbers, dashes.' });
      return;
    }
    setCreatingOrg(true);
    try {
      const { orgId } = await createOrganization({
        name: orgName.trim(),
        slug: orgSlug,
        ownerUid: user.uid,
      });
      await refresh();
      setActiveOrg(orgId);
      toast({ kind: 'success', message: 'Org created.' });
      goNext();
    } catch (err) {
      toast({
        kind: 'error',
        message: isOrgHandleTaken(err) ? `The handle "${orgSlug}" is taken. Try a different one.` : errMessage(err, 'Could not create the org. Try again.'),
      });
    } finally {
      setCreatingOrg(false);
    }
  }

  // Merged onto the org's theme (and this step's logo): updateOrganization
  // writes the whole theme column.
  function themeWith(patch: { logoUrl?: string; primaryColor?: string; accentColor?: string }) {
    return mergeOrgTheme(activeOrg?.theme, { ...(logoUrl ? { logoUrl } : {}), ...patch });
  }

  async function handleSaveTheme() {
    if (!activeOrg) return;
    if (!colorsValid) {
      toast({ kind: 'error', message: 'Colors must be hex values like #FFE714.' });
      return;
    }
    setSavingTheme(true);
    try {
      await updateOrganization(activeOrg.id, {
        theme: themeWith({ primaryColor: primary, accentColor: accent }),
      });
      toast({ kind: 'success', message: 'Theme saved.' });
      goNext();
    } catch (err) {
      toast({ kind: 'error', message: errMessage(err, 'Could not save the theme.') });
    } finally {
      setSavingTheme(false);
    }
  }

  async function handleLogoUpload(e: ChangeEvent<HTMLInputElement>) {
    if (!activeOrg) return;
    const file = e.target.files?.[0];
    if (!file) return;
    try {
      const url = await uploadOrgLogo(activeOrg.id, file);
      // Colors only when valid; an invalid one is caught on Save & Continue.
      await updateOrganization(activeOrg.id, {
        theme: themeWith({
          logoUrl: url,
          ...(isHexColor(primary) ? { primaryColor: primary } : {}),
          ...(isHexColor(accent) ? { accentColor: accent } : {}),
        }),
      });
      setLogoUrl(url);
      toast({ kind: 'success', message: 'Logo uploaded.' });
    } catch (err) {
      toast({ kind: 'error', message: errMessage(err, 'Could not upload the logo.') });
    }
  }

  async function handleConnectStripe() {
    if (!activeOrg) return;
    setOpeningStripe(true);
    try {
      // Back to the next step (first event) once Stripe is done.
      const url = await startStripeOnboarding({
        orgId: activeOrg.id,
        returnUrl: publicUrl('onboarding#step=5'),
        refreshUrl: publicUrl('onboarding#step=4'),
      });
      window.location.href = url;
    } catch (err) {
      toast({ kind: 'error', message: errMessage(err, "Couldn't open Stripe. Try again in a minute, or set it up later in Org Settings.") });
      setOpeningStripe(false);
    }
  }

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="max-w-2xl mx-auto px-4 py-12"
    >
      {/* Stepper */}
      <div className="flex items-center justify-between mb-10">
        {STEPS.map((s, i) => {
          const done = s.n < step;
          const current = s.n === step;
          return (
            <div key={s.n} className={`flex items-center ${i < STEPS.length - 1 ? 'flex-1' : ''}`}>
              <div className="flex items-center gap-2">
                <span
                  className={`w-8 h-8 rounded-full flex items-center justify-center text-xs font-black transition-all ${
                    done
                      ? 'bg-tm-blue text-white'
                      : current
                      ? 'bg-tm-blue text-white'
                      : 'bg-white border border-slate-200 text-slate-400'
                  }`}
                >
                  {done ? <Check size={14} /> : s.n}
                </span>
                <span className={`text-xs font-bold hidden sm:inline ${current || done ? 'text-slate-900' : 'text-slate-400'}`}>
                  {s.title}
                </span>
              </div>
              {i < STEPS.length - 1 && (
                <div className={`flex-1 h-px mx-3 ${done ? 'bg-tm-blue' : 'bg-slate-200'}`} />
              )}
            </div>
          );
        })}
      </div>

      <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8">
        <p className="text-[10px] text-tm-blue font-black uppercase tracking-widest mb-2">
          Step {step} of {STEPS.length} · {STEPS[step - 1].subtitle}
        </p>
        <div className="flex items-baseline gap-3 flex-wrap mb-6">
          <h1 className="text-3xl md:text-4xl font-bold tracking-tight text-slate-900">
            {STEPS[step - 1].title}
          </h1>
          <span className="marker text-brand-secondary text-lg rotate-[-3deg] leading-none whitespace-nowrap">let's go ✦</span>
        </div>

        {step === 1 && (
          <div className="space-y-5 text-slate-600">
            <p>
              Exos is your ticketing platform: you list events, sell tickets on your
              own page, and scan them at the door. You set the prices and own every
              buyer record, with no exclusivity.
            </p>
            <p className="text-slate-500 text-sm">
              You'll set up an organization (your venue or promoter brand), give it
              a name and color, then list your first event. The whole thing takes
              under five minutes. Selling on marketplaces such as StubHub and
              SeatGeek is planned but not live yet: today Exos handles your own
              ticket sales and check-in end-to-end.
            </p>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-3 pt-3">
              <Tile icon={<Globe size={16} />} title="White-label storefront" body="Your /o/your-slug page with your colors and logo." />
              <Tile icon={<Sparkles size={16} />} title="Rotating barcodes" body="HMAC-signed QR codes that refresh every 30 seconds — no screenshots." />
              <Tile icon={<Calendar size={16} />} title="Door scanning" body="Mobile QR scanner with offline fallback for spotty venue WiFi." />
            </div>
            <div className="flex justify-end pt-4">
              <button
                onClick={goNext}
                className="px-8 py-3 bg-tm-blue text-white font-bold rounded hover:bg-[#015bbd] shadow-sm transition-all flex items-center gap-2"
              >
                Get Started <ChevronRight size={16} />
              </button>
            </div>
          </div>
        )}

        {step === 2 && (
          <form onSubmit={handleCreateOrg} className="space-y-5">
            {orgs.length > 0 ? (
              <div className="bg-blue-50 border border-blue-200 rounded-lg p-4 text-xs font-bold text-tm-blue">
                You already have {orgs.length} org{orgs.length === 1 ? '' : 's'}. You can skip
                ahead or create a new one (e.g., a second venue or brand).
              </div>
            ) : null}
            <div>
              <label htmlFor="ob-name" className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">
                Org Name *
              </label>
              <input
                id="ob-name"
                type="text"
                value={orgName}
                onChange={(e) => setOrgName(e.target.value)}
                maxLength={100}
                required
                placeholder="e.g. Mister Saturday Night, Public Records, Brooklyn Steel"
                className="w-full bg-white border border-slate-200 rounded-lg px-4 py-3 text-sm text-slate-900 focus:border-tm-blue focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 transition-all"
              />
              <p className="text-slate-400 text-xs mt-1">
                The name buyers see on tickets and the storefront.
              </p>
            </div>
            <div>
              <label htmlFor="ob-slug" className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">
                URL Slug *
              </label>
              <div className="flex items-center bg-white border border-slate-200 rounded-lg px-4 focus-within:border-tm-blue">
                <span className="text-sm text-slate-400">
                  /o/
                </span>
                <input
                  id="ob-slug"
                  type="text"
                  value={orgSlug}
                  onChange={(e) => {
                    setOrgSlug(e.target.value);
                    setSlugManuallyEdited(true);
                  }}
                  maxLength={80}
                  required
                  placeholder="brooklyn-steel"
                  className="flex-1 py-3 text-sm text-slate-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60"
                />
              </div>
              {isValidOrgSlug(orgSlug) && handleState === 'taken' ? (
                <p className="text-rose-500 text-xs mt-1 font-semibold">That handle is taken. Try a different one.</p>
              ) : isValidOrgSlug(orgSlug) && handleState === 'available' ? (
                <p className="text-emerald-600 text-xs mt-1 font-semibold">Available</p>
              ) : (
                <p className="text-slate-400 text-xs mt-1">
                  Your storefront URL — share this once you're set up.
                </p>
              )}
            </div>
            <div className="flex justify-between pt-4">
              <button
                type="button"
                onClick={goPrev}
                className="px-6 py-3 bg-white border border-slate-200 text-slate-600 font-bold rounded hover:bg-slate-50 transition-all"
              >
                Back
              </button>
              <div className="flex gap-2">
                {orgs.length > 0 && (
                  <button
                    type="button"
                    onClick={goNext}
                    className="px-6 py-3 bg-white border border-slate-200 text-slate-600 font-bold rounded hover:bg-slate-50 transition-all"
                  >
                    Skip
                  </button>
                )}
                <button
                  type="submit"
                  disabled={creatingOrg || !isValidOrgSlug(orgSlug) || handleState === 'taken'}
                  className="px-8 py-3 bg-tm-blue text-white font-bold rounded hover:bg-[#015bbd] shadow-sm transition-all disabled:opacity-50 flex items-center gap-2"
                >
                  {creatingOrg ? 'Creating…' : (
                    <>
                      Create Org <ChevronRight size={16} />
                    </>
                  )}
                </button>
              </div>
            </div>
          </form>
        )}

        {step === 3 && (
          <div className="space-y-5">
            {!activeOrg ? (
              <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4 text-xs text-yellow-700 font-bold uppercase tracking-widest">
                No active org. Go back and create one first.
              </div>
            ) : (
              <>
                <div>
                  <label className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">
                    Logo (optional)
                  </label>
                  <label
                    htmlFor="ob-logo"
                    className="inline-flex items-center gap-2 px-4 py-2 bg-white hover:bg-slate-50 border border-slate-200 rounded-lg text-[10px] font-black uppercase tracking-widest text-slate-600 cursor-pointer transition-all"
                  >
                    <ImageIcon size={14} /> Upload Logo
                  </label>
                  <input
                    id="ob-logo"
                    type="file"
                    accept="image/png,image/jpeg,image/webp,image/svg+xml"
                    onChange={handleLogoUpload}
                    className="hidden"
                  />
                  <p className="text-slate-400 text-xs mt-2">
                    {logoUrl ? 'Logo uploaded. ' : ''}PNG, JPG, WebP, SVG. Max 2 MB. Skip for now if you don't have one ready.
                  </p>
                </div>
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <label htmlFor="ob-primary" className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">
                      Primary
                    </label>
                    <div className="flex items-center gap-2">
                      <input
                        id="ob-primary"
                        type="text"
                        value={primary}
                        onChange={(e) => setPrimary(e.target.value)}
                        maxLength={7}
                        className="flex-1 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm text-slate-900 focus:border-tm-blue focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 transition-all"
                      />
                      <div className="w-10 h-10 rounded border border-slate-200" style={{ background: isHexColor(primary) ? primary : 'transparent' }} aria-hidden />
                    </div>
                    {!isHexColor(primary) && <p className="text-rose-500 text-xs mt-1">Use a hex color like #FFE714.</p>}
                  </div>
                  <div>
                    <label htmlFor="ob-accent" className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">
                      Accent
                    </label>
                    <div className="flex items-center gap-2">
                      <input
                        id="ob-accent"
                        type="text"
                        value={accent}
                        onChange={(e) => setAccent(e.target.value)}
                        maxLength={7}
                        className="flex-1 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm text-slate-900 focus:border-tm-blue focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 transition-all"
                      />
                      <div className="w-10 h-10 rounded border border-slate-200" style={{ background: isHexColor(accent) ? accent : 'transparent' }} aria-hidden />
                    </div>
                    {!isHexColor(accent) && <p className="text-rose-500 text-xs mt-1">Use a hex color like #0A0A0A.</p>}
                  </div>
                </div>
              </>
            )}
            <div className="flex justify-between pt-4">
              <button
                type="button"
                onClick={goPrev}
                className="px-6 py-3 bg-white border border-slate-200 text-slate-600 font-bold rounded hover:bg-slate-50 transition-all"
              >
                Back
              </button>
              <div className="flex gap-2">
                <button
                  type="button"
                  onClick={goNext}
                  className="px-6 py-3 bg-white border border-slate-200 text-slate-600 font-bold rounded hover:bg-slate-50 transition-all"
                >
                  Skip
                </button>
                <button
                  type="button"
                  onClick={handleSaveTheme}
                  disabled={savingTheme || !activeOrg || !colorsValid}
                  className="px-8 py-3 bg-tm-blue text-white font-bold rounded hover:bg-[#015bbd] shadow-sm transition-all disabled:opacity-50 flex items-center gap-2"
                >
                  {savingTheme ? 'Saving…' : (
                    <>
                      Save & Continue <ChevronRight size={16} />
                    </>
                  )}
                </button>
              </div>
            </div>
          </div>
        )}

        {step === 4 && (
          <div className="space-y-5 text-slate-600">
            {!paymentsEnabled() ? (
              <p>
                Paid ticketing isn't switched on yet. Free events, RSVPs and comps work now; you can
                connect Stripe later in Org Settings → Payments.
              </p>
            ) : !activeOrg ? (
              <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4 text-xs text-yellow-700 font-bold uppercase tracking-widest">
                No active org. Go back and create one first.
              </div>
            ) : paymentsReady ? (
              <p className="text-emerald-700 font-semibold">Stripe is connected: you can sell paid tickets.</p>
            ) : (
              <>
                <p>
                  To sell paid tickets, connect a Stripe account. Ticket money goes to it, and Exos
                  takes its fee. Stripe asks for your business and bank details; it takes a few minutes.
                </p>
                <p className="text-slate-500 text-sm">
                  Only selling free tickets? Skip this. Until Stripe is connected, buyers can't pay for
                  priced tiers. You can finish it any time in Org Settings → Payments.
                </p>
              </>
            )}
            <div className="flex justify-between pt-4">
              <button
                type="button"
                onClick={goPrev}
                className="px-6 py-3 bg-white border border-slate-200 text-slate-600 font-bold rounded hover:bg-slate-50 transition-all"
              >
                Back
              </button>
              <div className="flex gap-2">
                <button
                  type="button"
                  onClick={goNext}
                  className="px-6 py-3 bg-white border border-slate-200 text-slate-600 font-bold rounded hover:bg-slate-50 transition-all"
                >
                  {paymentsReady || !paymentsEnabled() ? 'Continue' : 'Skip'}
                </button>
                {paymentsEnabled() && activeOrg && !paymentsReady && (
                  <button
                    type="button"
                    onClick={handleConnectStripe}
                    disabled={openingStripe}
                    className="px-8 py-3 bg-tm-blue text-white font-bold rounded hover:bg-[#015bbd] shadow-sm transition-all disabled:opacity-50 flex items-center gap-2"
                  >
                    {openingStripe ? 'Opening Stripe…' : (
                      <>
                        <CreditCard size={16} /> Connect Stripe
                      </>
                    )}
                  </button>
                )}
              </div>
            </div>
          </div>
        )}

        {step === 5 && (
          <div className="space-y-5 text-slate-600">
            <p>
              Your storefront is live. Now create your first event.
            </p>
            <p className="text-slate-500 text-sm">
              You'll set the date, capacity, ticket tiers (GA, VIP, etc.), and
              prices. Save it as a draft first if you want to come back to it,
              or publish it the moment it's ready. Once published, the event
              shows on your /o/{activeOrg?.slug ?? 'your-slug'} storefront and
              becomes scannable at the door.
            </p>
            <div className="flex justify-between pt-4">
              <button
                type="button"
                onClick={goPrev}
                className="px-6 py-3 bg-white border border-slate-200 text-slate-600 font-bold rounded hover:bg-slate-50 transition-all"
              >
                Back
              </button>
              <div className="flex gap-2">
                <button
                  type="button"
                  onClick={goNext}
                  className="px-6 py-3 bg-white border border-slate-200 text-slate-600 font-bold rounded hover:bg-slate-50 transition-all"
                >
                  Skip
                </button>
                <button
                  type="button"
                  onClick={() => navigate('/create-event')}
                  className="px-8 py-3 bg-tm-blue text-white font-bold rounded hover:bg-[#015bbd] shadow-sm transition-all flex items-center gap-2"
                >
                  Create First Event <ChevronRight size={16} />
                </button>
              </div>
            </div>
          </div>
        )}

        {step === 6 && (
          <div className="space-y-5 text-slate-600">
            <p>
              You're set up. Here's where to go from here.
            </p>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-3 pt-2">
              <Tile
                icon={<Calendar size={16} />}
                title="Dashboard"
                body="See your events, sales, and check-in stats."
                href="/dashboard"
              />
              {activeOrg && (
                <Tile
                  icon={<Globe size={16} />}
                  title="Your storefront"
                  body={`/o/${activeOrg.slug} — share this URL anywhere.`}
                  href={`/o/${activeOrg.slug}`}
                />
              )}
            </div>
            <div className="bg-slate-50 border border-slate-200 rounded-lg p-4 text-xs text-slate-500 mt-4">
              <p className="font-black uppercase tracking-widest text-slate-400 mb-2">Tips</p>
              <ul className="space-y-1.5 list-disc list-inside">
                <li>Add team members under <strong className="text-slate-700">Members</strong> in Org Settings — give them the role they need (manager, scanner, content, finance).</li>
                <li>To embed an event card on your venue's website, copy the snippet from any event's settings page.</li>
                <li>The door scanner works offline once you've loaded the event — load it on event day before guests arrive.</li>
              </ul>
            </div>
            <div className="flex justify-end pt-4">
              <button
                type="button"
                onClick={finish}
                className="px-8 py-3 bg-tm-blue text-white font-bold rounded hover:bg-[#015bbd] shadow-sm transition-all flex items-center gap-2"
              >
                Go to Dashboard <ChevronRight size={16} />
              </button>
            </div>
          </div>
        )}
      </div>

      {/* Feature strip */}
      <div className="mt-6 grid grid-cols-3 gap-3">
        <div className="bg-white rounded-xl border border-slate-200 p-4 text-center">
          <Globe className="w-5 h-5 text-tm-blue mx-auto mb-2" />
          <p className="text-[10px] font-black text-slate-600 uppercase tracking-widest">Sell tickets</p>
        </div>
        <div className="bg-white rounded-xl border border-slate-200 p-4 text-center">
          <Sparkles className="w-5 h-5 text-tm-blue mx-auto mb-2" />
          <p className="text-[10px] font-black text-slate-600 uppercase tracking-widest">White-label</p>
        </div>
        <div className="bg-white rounded-xl border border-slate-200 p-4 text-center">
          <Calendar className="w-5 h-5 text-tm-blue mx-auto mb-2" />
          <p className="text-[10px] font-black text-slate-600 uppercase tracking-widest">Team access</p>
        </div>
      </div>
    </motion.div>
  );
}

function Tile({
  icon,
  title,
  body,
  href,
}: {
  icon: ReactNode;
  title: string;
  body: string;
  href?: string;
}) {
  const inner = (
    <>
      <div className="text-tm-blue mb-2">{icon}</div>
      <h3 className="text-sm font-bold tracking-tight text-slate-900 mb-1">{title}</h3>
      <p className="text-xs text-slate-500">{body}</p>
    </>
  );
  if (href) {
    // A router Link, so the /bridge base path is kept.
    return (
      <Link
        to={href}
        className="block bg-white rounded-xl border border-slate-200 hover:border-tm-blue p-4 transition-all"
      >
        {inner}
      </Link>
    );
  }
  return <div className="bg-white rounded-xl border border-slate-200 p-4">{inner}</div>;
}
