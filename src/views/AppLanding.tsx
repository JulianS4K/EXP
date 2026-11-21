// The public, signed-out landing page of one Exos app (/apps/door, /apps/events,
// /apps/promote, /apps/money; docs/strategy.md "Apps"). Every bullet and price
// below is a facts-registry claim (src/lib/apps/landing.ts); AppLanding.test.tsx
// fails if the page says anything the registry doesn't allow.

import { useEffect } from 'react';
import { Link } from 'react-router-dom';
import { ArrowRight, Check } from 'lucide-react';
import { applyMeta } from '../lib/meta';
import { publicUrl } from '../lib/utils';
import {
  APP_LANDINGS, AT_LAUNCH_LABEL, PRICING_FACT_IDS, appLanding, landingClaims,
  type AppId, type LandingClaim,
} from '../lib/apps/landing';

function claimItem(c: LandingClaim) {
  return (
    <li key={c.id} data-fact={c.id} className="flex gap-3 border border-white/10 bg-white/[0.03] p-4">
      <Check aria-hidden="true" className="w-5 h-5 text-brand-primary shrink-0 mt-0.5" />
      <span className="type text-sm md:text-base leading-relaxed text-white/85">
        {c.claim}
        {c.atLaunch && (
          <span className="ml-2 inline-block align-middle border border-brand-secondary/70 px-2 py-0.5 text-[11px] uppercase tracking-widest text-white">
            {AT_LAUNCH_LABEL}
          </span>
        )}
      </span>
    </li>
  );
}

export default function AppLanding({ app: id }: { app: AppId }) {
  const app = appLanding(id);
  const features = landingClaims(app.factIds);
  const pricing = landingClaims(PRICING_FACT_IDS);
  const others = APP_LANDINGS.filter((a) => a.id !== id);

  useEffect(() => {
    try {
      applyMeta({ title: app.title, description: app.description, canonicalUrl: publicUrl(app.path) });
    } catch { /* non-fatal */ }
  }, [app]);

  return (
    <div className="wall min-h-screen text-white" data-app-landing={app.id}>
      <header className="border-b border-white/10">
        <div className="max-w-5xl mx-auto px-4 sm:px-6 lg:px-8 pt-12 pb-12">
          <p className="type text-[12px] uppercase tracking-[0.3em] text-white/70 mb-5">Exos · {app.name}</p>
          <h1 className="disp text-5xl md:text-7xl leading-[0.9] tracking-tight mb-6">{app.headline}</h1>
          <p className="type text-base md:text-lg text-white/80 max-w-2xl leading-relaxed mb-8">{app.intro}</p>
          <Link
            to={app.cta.to}
            className="disp inline-flex items-center gap-2 bg-brand-primary text-black text-xl px-6 py-2.5 tracking-wide hover:scale-[1.02] transition-transform focus:outline-none focus-visible:ring-2 focus-visible:ring-white"
          >
            {app.cta.label}
            <ArrowRight aria-hidden="true" className="w-5 h-5" />
          </Link>
        </div>
      </header>

      <div className="max-w-5xl mx-auto px-4 sm:px-6 lg:px-8 py-12 space-y-14">
        <section aria-labelledby="app-features">
          <h2 id="app-features" className="disp text-3xl md:text-4xl tracking-wide mb-6">What it does</h2>
          <ul data-claims="features" className="grid grid-cols-1 md:grid-cols-2 gap-3">
            {features.map(claimItem)}
          </ul>
        </section>

        <section aria-labelledby="app-pricing">
          <h2 id="app-pricing" className="disp text-3xl md:text-4xl tracking-wide mb-6">What it costs</h2>
          {id === 'door' && (
            <p className="type text-sm md:text-base text-white/80 mb-4">
              The door app is free. If you also sell tickets on Exos:
            </p>
          )}
          <ul data-claims="pricing" className="grid grid-cols-1 gap-3">
            {pricing.map(claimItem)}
          </ul>
        </section>

        <section aria-labelledby="app-start" className="border border-white/15 p-6 md:p-8">
          <h2 id="app-start" className="disp text-3xl tracking-wide mb-3">Start now</h2>
          <p className="type text-sm md:text-base text-white/80 mb-5">
            {id === 'door'
              ? 'Sign in, name your organization and import your first attendee list.'
              : 'Sign in and name your venue, promoter or party. It takes a minute.'}
          </p>
          <Link
            to={app.cta.to}
            className="disp inline-flex items-center gap-2 bg-white text-black text-lg px-5 py-2 tracking-wide hover:bg-brand-primary transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary"
          >
            {app.cta.label}
            <ArrowRight aria-hidden="true" className="w-5 h-5" />
          </Link>
        </section>

        <nav aria-label="Other Exos apps">
          <h2 className="type text-[12px] uppercase tracking-[0.3em] text-white/70 mb-3">Other Exos apps</h2>
          <ul className="flex flex-wrap gap-3">
            {others.map((a) => (
              <li key={a.id}>
                <Link to={a.path} className="type inline-block border border-white/20 px-4 py-2 text-sm text-white/85 hover:border-brand-primary hover:text-white transition-colors">
                  {a.name}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
      </div>
    </div>
  );
}
