// Edit event → "Post / list this event" (social phase, mig 20261121203000;
// docs/social.md "Posting and listing APIs"): Instagram, TikTok, Meetup,
// LinkedIn and Google Business Profile, each with its status (connected or
// not, always a dry run for now) and, once planned, exactly what Exos would
// send. A DRY RUN: nothing goes to any platform; the plan is also listed under
// "What we'd send" in Org settings. The story poster (lib/poster.ts) is for
// Stories you post yourself. Owner / manager (both calls check the role).
//
// TikTok: the creator picks who can see the post (no default), which
// interactions to allow (all off until turned on; off for good when their
// TikTok settings disable them), whether it promotes a brand, and accepts
// TikTok's declaration, before Exos builds the post (TikTok's Content
// Sharing Guidelines). Publishing is a separate, confirmed step per platform:
// it sends exactly the plan reviewed here, and is switched off in this build.

import { useEffect, useState } from 'react';
import { Share2 } from 'lucide-react';
import {
  PLATFORM_ACTION, PLATFORM_LABEL, SOCIAL_PLATFORMS, STATUS_TEXT, connectInfo, loadSocialContext, planSocialPosts, planSummary,
  platformStatus, publishSocialPost, tiktokDeclaration, tiktokDiscloseLabel, tiktokMissing,
  type SocialContext, type SocialPlanResponse, type SocialPlatform, type TikTokChoices,
} from '../lib/socialPlan';

const PRIVACY_TEXT: Record<string, string> = {
  PUBLIC_TO_EVERYONE: 'Everyone', MUTUAL_FOLLOW_FRIENDS: 'Friends', FOLLOWER_OF_CREATOR: 'Followers', SELF_ONLY: 'Only me',
};
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
  const [tiktok, setTiktok] = useState<TikTokChoices>({});
  const [meetupDraftId, setMeetupDraftId] = useState('');
  const [publishMsg, setPublishMsg] = useState<Record<string, string>>({});

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
      setPublishMsg({});
      setPlan(await planSocialPosts(orgId, eventId, chosen, { tiktok, meetupDraftId: meetupDraftId.trim() || null }));
    } catch (e) {
      setPlan(null);
      setError(e instanceof Error ? e.message : 'Planning failed.');
    } finally {
      setBusy(false);
    }
  };

  const publish = async (platform: SocialPlatform, confirm: string) => {
    try {
      const a = await publishSocialPost(orgId, eventId, platform, confirm, { tiktok, meetupDraftId: meetupDraftId.trim() || null });
      setPublishMsg((m) => ({ ...m, [platform]: a.message }));
    } catch (e) {
      setPublishMsg((m) => ({ ...m, [platform]: e instanceof Error ? e.message : 'Publishing failed.' }));
    }
  };

  const ttView = plan?.platforms.find((p) => p.platform === 'tiktok')?.result.tiktok;
  const setTt = (patch: Partial<TikTokChoices>) => setTiktok((t) => ({ ...t, ...patch }));

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
                {p === 'tiktok' && chosen.includes('tiktok') && (
                  <fieldset data-testid="tiktok-choices" className="space-y-2 border-t border-slate-100 pt-2">
                    <legend className="text-[11px] font-bold text-slate-700">Your TikTok choices</legend>
                    <div role="radiogroup" aria-label="Who can see this post" className="space-y-1">
                      <p className="text-[11px] font-bold text-slate-700">Who can see this post</p>
                      {ttView ? ttView.privacyOptions.map((o) => (
                        <label key={o} className="flex items-center gap-2 text-[11px] text-slate-800">
                          <input type="radio" name="tiktok-privacy" checked={tiktok.privacyLevel === o} onChange={() => setTt({ privacyLevel: o })} />
                          {PRIVACY_TEXT[o] ?? o}
                        </label>
                      )) : <p className="text-[11px] text-slate-600">Plan once to see the options TikTok gives your account.</p>}
                    </div>
                    <div className="space-y-1">
                      <p className="text-[11px] font-bold text-slate-700">Allow</p>
                      {([['allowComment', 'Comments', ttView?.commentDisabled], ['allowDuet', 'Duets (videos)', ttView?.duetDisabled], ['allowStitch', 'Stitches (videos)', ttView?.stitchDisabled]] as const).map(([k, label, off]) => (
                        <label key={k} className="flex items-center gap-2 text-[11px] text-slate-800">
                          <input type="checkbox" disabled={off === true} checked={off !== true && tiktok[k] === true} onChange={(e) => setTt({ [k]: e.target.checked })} />
                          {label}{off === true ? ' (turned off in your TikTok settings)' : ''}
                        </label>
                      ))}
                      <label className="flex items-center gap-2 text-[11px] text-slate-800">
                        <input type="checkbox" checked={tiktok.autoAddMusic === true} onChange={(e) => setTt({ autoAddMusic: e.target.checked })} />
                        Let TikTok add music (photo posts)
                      </label>
                    </div>
                    <div role="radiogroup" aria-label="Does this post promote a brand" className="space-y-1">
                      <p className="text-[11px] font-bold text-slate-700">Does this post promote a brand?</p>
                      {([['none', 'No'], ['your_brand', 'Yes, my own brand or business'], ['branded_content', 'Yes, someone else\'s, for something in return']] as const).map(([v, label]) => (
                        <label key={v} className="flex items-center gap-2 text-[11px] text-slate-800">
                          <input type="radio" name="tiktok-disclose" checked={tiktok.disclose === v} onChange={() => setTt({ disclose: v })} />
                          {label}
                        </label>
                      ))}
                      {tiktokDiscloseLabel(tiktok.disclose) && (
                        <p className="text-[11px] text-slate-600">TikTok labels it &ldquo;{tiktokDiscloseLabel(tiktok.disclose)}&rdquo;.</p>
                      )}
                    </div>
                    <label className="flex items-start gap-2 text-[11px] text-slate-800">
                      <input type="checkbox" checked={tiktok.consent === true} onChange={(e) => setTt({ consent: e.target.checked })} />
                      <span data-testid="tiktok-declaration">{tiktokDeclaration(tiktok.disclose)}</span>
                    </label>
                    {tiktokMissing(tiktok).length > 0 && (
                      <p role="note" className="text-[11px] text-amber-800">Still to choose: {tiktokMissing(tiktok).join(', ')}.</p>
                    )}
                  </fieldset>
                )}
                {p === 'meetup' && chosen.includes('meetup') && (
                  <label className="block text-[11px] text-slate-700 border-t border-slate-100 pt-2">
                    Publish a draft you checked on Meetup (its event id), instead of creating one
                    <input type="text" value={meetupDraftId} onChange={(e) => setMeetupDraftId(e.target.value)} placeholder="Meetup event id"
                      className="mt-1 block w-full border border-slate-300 rounded px-2 py-1 text-[11px]" />
                  </label>
                )}
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
                {pl.confirm && (
                  <div className="space-y-1 border-t border-slate-100 pt-2">
                    <button type="button" data-testid={`publish-${pl.platform}`} onClick={() => publish(pl.platform, pl.confirm!)}
                      className="text-[11px] font-bold border border-slate-300 text-slate-800 rounded px-2 py-1">
                      Publish exactly this to {pl.label}
                    </button>
                    {publishMsg[pl.platform] && <p role="status" className="text-[11px] text-slate-700">{publishMsg[pl.platform]}</p>}
                  </div>
                )}
              </div>
            ))}
            <p className="text-[11px] text-slate-600">The same requests are listed under What we&apos;d send in Org settings.</p>
          </div>
        )}
      </div>
    </section>
  );
}
