// Edit event → "Post / list this event" (social phase, mig 20261121203000;
// docs/social.md "Posting and listing APIs"): Instagram, TikTok, Meetup,
// LinkedIn and Google Business Profile, each with its status (connected or
// not, always a dry run for now) and, once planned, exactly what Exos would
// send. A DRY RUN: nothing goes to any platform; the plan is also listed under
// "What we'd send" in Org settings. The story poster (lib/poster.ts) is for
// Stories you post yourself. Owner / manager (both calls check the role).

import { useEffect, useState } from 'react';
import { Share2 } from 'lucide-react';
import {
  PLATFORM_ACTION, PLATFORM_LABEL, SOCIAL_PLATFORMS, STATUS_TEXT, connectInfo, loadSocialContext, planSocialPosts, planSummary,
  platformStatus, type SocialContext, type SocialPlanResponse, type SocialPlatform,
} from '../lib/socialPlan';
import { stepLabel } from '../lib/channelAudit';
import { composeStoryPoster } from '../lib/poster';
import { publicUrl } from '../lib/utils';

export default function PostListPanel({ eventId, orgId }: { eventId: string; orgId: string }) {
  const [ctx, setCtx] = useState<SocialContext | null>(null);
  const [ctxError, setCtxError] = useState<string | null>(null);
  const [chosen, setChosen] = useState<SocialPlatform[]>([...SOCIAL_PLATFORMS]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [plan, setPlan] = useState<SocialPlanResponse | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [poster, setPoster] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    loadSocialContext(orgId, eventId)
      .then((c) => { if (live) setCtx(c); })
      .catch((e) => { if (live) setCtxError(e instanceof Error ? e.message : 'Could not load the platforms.'); });
    return () => { live = false; };
  }, [orgId, eventId]);

  useEffect(() => () => { if (poster) URL.revokeObjectURL(poster); }, [poster]);

  const toggle = (p: SocialPlatform) => setChosen((c) => (c.includes(p) ? c.filter((x) => x !== p) : [...c, p]));

  const run = async () => {
    setBusy(true);
    setError(null);
    try {
      setPlan(await planSocialPosts(orgId, eventId, chosen));
    } catch (e) {
      setPlan(null);
      setError(e instanceof Error ? e.message : 'Planning failed.');
    } finally {
      setBusy(false);
    }
  };

  const makePoster = async () => {
    const ev = ctx?.event;
    if (!ev) return;
    const slug = typeof ev.slug === 'string' && ev.slug ? `e/${encodeURIComponent(ev.slug)}` : `event/${ev.id}`;
    const blob = await composeStoryPoster({
      title: String(ev.name), url: publicUrl(slug), imageUrl: typeof ev.image_url === 'string' ? ev.image_url : null,
      venue: ev.location_open === false ? undefined : (typeof ev.venue_name === 'string' ? ev.venue_name : undefined),
    }).catch(() => null);
    if (blob) setPoster(URL.createObjectURL(blob));
  };

  return (
    <section data-testid="post-list-panel" aria-labelledby="post-list-title"
      className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 md:p-8 space-y-4">
      <div className="flex items-center gap-2">
        <Share2 className="w-4 h-4 text-slate-500" aria-hidden="true" />
        <h2 id="post-list-title" className="text-sm font-black text-slate-900 uppercase tracking-widest">Post / list this event</h2>
      </div>
      <p className="text-xs text-slate-600">
        Post the event to your own accounts and list it where people look for things to do. This is a preview: Exos
        sends nothing to these platforms yet. Plan it to see exactly what would be sent.
      </p>
      {ctxError && <p role="alert" className="text-[11px] text-rose-800">{ctxError}</p>}

      <fieldset className="space-y-2">
        <legend className="text-[11px] font-bold text-slate-700">Platforms</legend>
        <ul className="space-y-2">
          {SOCIAL_PLATFORMS.map((p) => {
            const s = platformStatus(ctx, p);
            const c = connectInfo(p);
            return (
              <li key={p} data-testid={`post-platform-${p}`} className="border border-slate-200 rounded-lg p-3 space-y-1">
                <div className="flex flex-wrap items-center gap-2">
                  <label className="flex items-center gap-2 text-xs font-bold text-slate-800">
                    <input type="checkbox" checked={chosen.includes(p)} onChange={() => toggle(p)} />
                    {PLATFORM_LABEL[p]}
                  </label>
                  <span className={`text-[10px] font-bold rounded px-1.5 py-0.5 ${s.word === 'connected' ? 'bg-emerald-50 text-emerald-800' : 'bg-slate-100 text-slate-700'}`}>
                    {STATUS_TEXT[s.word]}
                  </span>
                  <span className="text-[10px] font-bold rounded px-1.5 py-0.5 bg-amber-50 text-amber-800">Dry run</span>
                </div>
                <p className="text-[11px] text-slate-600">{PLATFORM_ACTION[p]}.</p>
                {s.word === 'not_connected' && (
                  <p className="text-[11px] text-slate-600">
                    Connect through the {c.app} app: {c.built ? 'in Settings.' : 'not available yet.'}
                  </p>
                )}
                {s.notes.map((n) => <p key={n} role="note" className="text-[11px] text-amber-800">{n}</p>)}
              </li>
            );
          })}
        </ul>
      </fieldset>
      <div className="flex flex-wrap gap-2">
        <button type="button" disabled={busy || chosen.length === 0} onClick={run}
          className="text-xs font-bold bg-slate-900 text-white rounded-lg px-3 py-2 disabled:opacity-50">
          {busy ? 'Planning…' : 'Plan the posts'}
        </button>
        <button type="button" disabled={!ctx} onClick={makePoster}
          className="text-xs font-bold border border-slate-300 text-slate-800 rounded-lg px-3 py-2 disabled:opacity-50">
          Make a story poster
        </button>
        {poster && (
          <a href={poster} download="exos-story-poster.png" className="text-xs font-bold underline text-slate-800 self-center">
            Download the poster (post it to Stories yourself)
          </a>
        )}
      </div>

      <div aria-live="polite">
        {error && <p role="alert" className="text-[11px] text-rose-800">{error}</p>}
        {plan && (
          <div data-testid="post-plan" className="space-y-3">
            <p className="text-[11px] font-bold text-emerald-800">Dry run: nothing was sent.</p>
            {plan.platforms.map((pl) => (
              <div key={pl.platform} data-testid="post-plan-platform" className="border border-slate-200 rounded-lg p-3 space-y-2">
                <h3 className="text-xs font-black text-slate-700 uppercase tracking-widest">{pl.label}</h3>
                <p className="text-[11px] text-slate-700">{planSummary(pl)}</p>
                <dl className="grid grid-cols-[auto,1fr] gap-x-3 gap-y-1 text-[11px] text-slate-800">
                  {pl.post.title && (<><dt className="font-bold">Title</dt><dd>{pl.post.title}</dd></>)}
                  <dt className="font-bold">Text</dt><dd className="whitespace-pre-wrap">{pl.post.text}</dd>
                  <dt className="font-bold">Link</dt><dd className="break-all">{pl.post.url ?? 'None (link in bio)'}</dd>
                  <dt className="font-bold">Image</dt><dd className="break-all">{pl.post.imageUrl ?? 'None'}</dd>
                </dl>
                {[...new Set([...pl.post.warnings, ...pl.result.warnings])].map((w) => (
                  <p key={w} role="note" className="text-[11px] text-amber-800 bg-amber-50 rounded px-2 py-1">{w}</p>
                ))}
                <ol className="space-y-1">
                  {pl.steps.map((s, i) => {
                    const id = `post-${pl.platform}-${i}`;
                    return (
                      <li key={id} className="text-[11px]">
                        <span className="font-mono font-bold">{s.method}</span>{' '}
                        <span className="font-mono break-all">{s.path}</span>{' '}
                        <span className="text-slate-600">{stepLabel(s.op)}</span>
                        {s.error && <span className="text-rose-800"> ({s.error})</span>}
                        <button type="button" className="ml-2 underline font-bold text-slate-700"
                          aria-expanded={open === id} aria-controls={id} onClick={() => setOpen(open === id ? null : id)}>
                          {open === id ? 'Hide' : 'Payload'}
                        </button>
                        {open === id && (
                          <pre id={id} className="text-[10px] bg-slate-50 border border-slate-200 rounded p-2 whitespace-pre-wrap break-all">
                            {JSON.stringify(s.body, null, 2)}
                          </pre>
                        )}
                      </li>
                    );
                  })}
                </ol>
              </div>
            ))}
            <p className="text-[11px] text-slate-600">The same requests are listed under What we&apos;d send in Org settings.</p>
          </div>
        )}
      </div>
    </section>
  );
}
