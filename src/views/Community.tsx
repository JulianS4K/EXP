// /c/:slug — a community's public page (docs/communities.md, mig
// 20261031200000): banner, about, upcoming and past events, posts, member
// count and the join button. Joining asks which channels the person wants
// (email; texts only after the organizer's own SMS opt-in, so STOP keeps
// working) and stores the consent text shown. ?invite=… joins an invite-only
// community, ?host=… accepts a host role, ?settings=1 opens the channel
// settings (the link in community mails).

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { applyMeta } from '../lib/meta';
import { publicUrl } from '../lib/utils';
import { formatInTz } from '../lib/datetime';
import {
  consentText, eventBadge, eventIdFromLink, fediverseHandles, friendlyError, inviteToken, joinAction, memberCountLabel, placeLine,
  type PublicCommunity,
} from '../lib/communities';
import {
  acceptHostInvite, addCommunityEvent, getPublicCommunity, joinCommunity, leaveCommunity, previewInvite, proposeEvent, reportPost,
  setCommunityNotify, writePost,
} from '../lib/communitiesApi';

const BTN = 'px-5 py-2.5 rounded-full text-xs font-black uppercase tracking-widest disabled:opacity-50';
const FLD = 'w-full bg-white/5 border border-white/15 rounded-lg px-3 py-2 text-sm text-white placeholder-white/40 focus:outline-none focus:border-white/50';
const REPORT_REASONS = ['spam', 'harassment', 'hate', 'sexual', 'violence', 'misleading', 'other'];

export default function Community() {
  const { slug = '' } = useParams();
  const { user, openAuthModal } = useAuth();
  const { toast } = useToast();
  const [c, setC] = useState<PublicCommunity | null | undefined>(undefined);
  const [busy, setBusy] = useState(false);
  const [email, setEmail] = useState(true);
  const [sms, setSms] = useState(false);
  const [showSettings, setShowSettings] = useState(() => {
    try { return new URLSearchParams(window.location.search).get('settings') === '1'; } catch { return false; }
  });
  const invite = useMemo(() => {
    try { return inviteToken(window.location.search); } catch { return null; }
  }, []);
  const [invitePreview, setInvitePreview] = useState<{ valid: boolean; kind: string; display_name?: string } | null>(null);

  const load = useCallback(async () => {
    try {
      const data = await getPublicCommunity(slug);
      setC(data);
      if (data?.me) {
        setEmail(data.me.notify_email ?? true);
        setSms(!!data.me.notify_sms);
      }
    } catch (e) {
      console.error('community load failed', e);
      setC(null);
    }
  }, [slug]);

  useEffect(() => { void load(); }, [load, user?.uid]);
  useEffect(() => {
    if (!invite) return;
    previewInvite(invite.token).then((p) => setInvitePreview(p)).catch(() => setInvitePreview(null));
  }, [invite]);
  useEffect(() => {
    if (!c) return;
    try {
      applyMeta({ title: c.name, description: c.tagline || c.about?.slice(0, 160) || `${c.name} on Exos`, imageUrl: c.banner_url ?? undefined, canonicalUrl: publicUrl(`/c/${c.slug}`), noindex: c.visibility === 'unlisted' });
    } catch { /* non-fatal */ }
  }, [c]);

  if (c === undefined) return <div className="wall min-h-[60vh]" />;
  if (c === null) {
    return (
      <div className="wall min-h-[60vh] flex flex-col items-center justify-center text-center px-6">
        <p className="disp text-3xl mb-4">This community isn't here.</p>
        <Link to="/communities" className="text-sm underline text-white/70">Find communities near you</Link>
      </div>
    );
  }

  const status = c.me?.status;
  const action = joinAction(c.join_mode, status, !!user, invite?.kind === 'member' && invitePreview?.valid !== false);
  const consent = consentText(c.name, email, sms);
  const host = (() => { try { return window.location.host; } catch { return ''; } })();
  const handles = fediverseHandles(c.slug, host);
  const canPost = !!(c.me?.admin || c.me?.host);

  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setBusy(true);
    try {
      await fn();
      toast({ kind: 'success', message: ok });
      await load();
    } catch (e) {
      toast({ kind: 'error', message: friendlyError(e) });
    } finally {
      setBusy(false);
    }
  };

  const join = () => {
    if (!user) return openAuthModal();
    void run(() => joinCommunity(c.id, email, sms, email || sms ? consent : null, invite?.kind === 'member' ? invite.token : null),
      c.join_mode === 'approval' && !invite ? 'Request sent.' : `You joined ${c.name}.`);
  };

  return (
    <div className="wall min-h-screen text-white">
      <div className="relative h-56 md:h-72 bg-white/5 overflow-hidden">
        {c.banner_url && <img src={c.banner_url} alt="" className="absolute inset-0 w-full h-full object-cover opacity-70" />}
        <div className="absolute inset-0 bg-gradient-to-t from-black via-black/40 to-transparent" />
        <div className="absolute bottom-0 left-0 right-0 max-w-5xl mx-auto px-6 pb-6">
          <h1 className="disp text-4xl md:text-6xl tracking-tight">{c.name}</h1>
          {c.tagline && <p className="text-white/80 mt-1">{c.tagline}</p>}
          <p className="text-xs text-white/60 mt-2">
            {[placeLine(c), memberCountLabel(c.member_count), c.org ? `by ${c.org.name}` : null].filter(Boolean).join(' · ')}
          </p>
        </div>
      </div>

      <div className="max-w-5xl mx-auto px-6 py-8 grid md:grid-cols-3 gap-8">
        <div className="md:col-span-2 space-y-10">
          {invite?.kind === 'host' && (
            <div className="rounded-xl border border-white/20 p-4">
              <p className="text-sm mb-3">
                {invitePreview?.valid === false ? "This host invite isn't valid any more."
                  : `You're invited to host in ${c.name}${invitePreview?.display_name ? ` as ${invitePreview.display_name}` : ''}. Hosts can add their events and write posts here.`}
              </p>
              {invitePreview?.valid !== false && (
                <button type="button" disabled={busy} className={`${BTN} bg-white text-black`}
                  onClick={() => (user ? void run(() => acceptHostInvite(invite.token), "You're a host now.") : openAuthModal())}>
                  {user ? 'Accept host invite' : 'Sign in to accept'}
                </button>
              )}
            </div>
          )}

          {c.about && <section><h2 className="text-xs font-black uppercase tracking-widest text-white/50 mb-2">About</h2>
            <p className="whitespace-pre-line text-white/85">{c.about}</p></section>}

          <section>
            <h2 className="text-xs font-black uppercase tracking-widest text-white/50 mb-3">Upcoming</h2>
            {c.upcoming.length === 0 ? <p className="text-sm text-white/50">Nothing on the calendar yet.</p> : (
              <ul className="space-y-3">
                {c.upcoming.map((e) => (
                  <li key={e.id}>
                    <Link to={`/event/${e.id}`} className="flex gap-4 items-center rounded-xl border border-white/10 hover:border-white/40 p-3">
                      {e.image_url && <img src={e.image_url} alt="" className="w-16 h-16 rounded-lg object-cover" />}
                      <div>
                        <p className="font-bold">{e.name}</p>
                        <p className="text-xs text-white/60">
                          {[e.starts_at ? formatInTz(new Date(e.starts_at), e.timezone ?? undefined) : null, e.venue_name].filter(Boolean).join(' · ')}
                        </p>
                        {eventBadge(e) && <span className="inline-block mt-1 text-[10px] font-black uppercase tracking-widest bg-white text-black px-2 py-0.5 rounded">{eventBadge(e)}</span>}
                      </div>
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </section>

          {canPost && <Composer communityId={c.id} isHost={!!c.me?.host && !c.me?.admin} onDone={load} />}

          <section>
            <h2 className="text-xs font-black uppercase tracking-widest text-white/50 mb-3">Posts</h2>
            {c.posts.length === 0 ? <p className="text-sm text-white/50">No posts yet.</p> : (
              <ul className="space-y-5">
                {c.posts.map((p) => (
                  <li key={p.id} id={`post-${p.id}`} className="rounded-xl border border-white/10 p-4">
                    {p.title && <p className="font-bold mb-1">{p.title}</p>}
                    <p className="whitespace-pre-line text-sm text-white/85">{p.body}</p>
                    <p className="text-[11px] text-white/45 mt-2">
                      {[p.by, formatInTz(new Date(p.created_at), undefined), p.visibility === 'members' ? 'Members only' : null].filter(Boolean).join(' · ')}
                    </p>
                    {p.replies.length > 0 && (
                      <ul className="mt-3 space-y-2 border-l border-white/15 pl-3">
                        {p.replies.map((r, i) => (
                          <li key={i} className="text-sm">
                            <span className="text-white/60">{r.actor_name || r.actor_handle}</span>{' '}
                            {r.actor_handle && <span className="text-[11px] text-white/40">{r.actor_handle}</span>}
                            {/* Remote text, approved by a moderator; rendered as text only. */}
                            <p className="whitespace-pre-line text-white/80">{r.content_text}</p>
                          </li>
                        ))}
                      </ul>
                    )}
                    {user && <ReportButton postId={p.id} />}
                  </li>
                ))}
              </ul>
            )}
          </section>

          {c.past.length > 0 && (
            <section>
              <h2 className="text-xs font-black uppercase tracking-widest text-white/50 mb-3">Past events</h2>
              <ul className="grid sm:grid-cols-2 gap-2">
                {c.past.map((e) => (
                  <li key={e.id} className="text-sm text-white/70">
                    <Link to={`/event/${e.id}`} className="hover:underline">{e.name}</Link>
                    {e.starts_at && <span className="text-white/40"> · {formatInTz(new Date(e.starts_at), e.timezone ?? undefined, { dateStyle: 'medium' })}</span>}
                  </li>
                ))}
              </ul>
            </section>
          )}
        </div>

        <aside className="space-y-6">
          <div className="rounded-xl border border-white/15 p-5">
            {(action.kind === 'join' || action.kind === 'request' || action.kind === 'sign_in') && user && (
              <div className="space-y-2 mb-4 text-sm">
                <p className="text-white/60 text-xs">Hear about new events and news by:</p>
                <label className="flex gap-2 items-center"><input type="checkbox" checked={email} onChange={(e) => setEmail(e.target.checked)} /> Email</label>
                <label className={`flex gap-2 items-center ${c.me?.sms_subscribed ? '' : 'opacity-50'}`}>
                  <input type="checkbox" checked={sms} disabled={!c.me?.sms_subscribed} onChange={(e) => setSms(e.target.checked)} /> Text
                </label>
                {!c.me?.sms_subscribed && <p className="text-[11px] text-white/45">Texts: sign up for this organizer's texts first (on any of their event pages).</p>}
                {(email || sms) && <p className="text-[11px] text-white/45">{consent}</p>}
              </div>
            )}
            {action.kind === 'member' ? (
              <div className="space-y-3">
                <p className="text-sm font-bold">You're a member.</p>
                <button type="button" className="text-xs underline text-white/70" onClick={() => setShowSettings((s) => !s)}>Notification settings</button>
                {showSettings && (
                  <div className="space-y-2 text-sm">
                    <label className="flex gap-2 items-center"><input type="checkbox" checked={email} onChange={(e) => setEmail(e.target.checked)} /> Email</label>
                    <label className={`flex gap-2 items-center ${c.me?.sms_subscribed ? '' : 'opacity-50'}`}>
                      <input type="checkbox" checked={sms} disabled={!c.me?.sms_subscribed && !sms} onChange={(e) => setSms(e.target.checked)} /> Text
                    </label>
                    {(email || sms) && <p className="text-[11px] text-white/45">{consent}</p>}
                    <button type="button" disabled={busy} className={`${BTN} bg-white text-black`}
                      onClick={() => void run(() => setCommunityNotify(c.id, email, sms, email || sms ? consent : null), 'Saved.')}>Save</button>
                    <button type="button" disabled={busy} className="block text-xs underline text-white/60"
                      onClick={() => void run(() => leaveCommunity(c.id), `You left ${c.name}.`)}>Leave community</button>
                  </div>
                )}
              </div>
            ) : (
              <button type="button" disabled={busy || ['pending', 'banned', 'invite_only'].includes(action.kind)}
                className={`${BTN} w-full bg-white text-black`} onClick={join}>
                {action.label}
              </button>
            )}
            {invite?.kind === 'member' && invitePreview?.valid === false && <p className="text-xs text-white/50 mt-2">This invite isn't valid any more.</p>}
            {c.me?.admin && c.org && <Link to={`/orgs/${c.org.id}/settings#communities`} className="block text-xs underline text-white/60 mt-3">Manage this community</Link>}
          </div>

          {c.hosts.length > 0 && (
            <div className="text-sm">
              <p className="text-xs font-black uppercase tracking-widest text-white/50 mb-2">Hosts</p>
              <ul className="space-y-1">
                {c.hosts.map((h, i) => <li key={i}>{h.display_name}{h.org ? <span className="text-white/40"> · {h.org.name}</span> : null}</li>)}
              </ul>
            </div>
          )}

          {c.federated && (
            <div className="text-xs text-white/60 space-y-1">
              <p className="font-black uppercase tracking-widest text-white/50">Follow from the fediverse</p>
              <p>Mastodon: <code className="text-white/80">{handles.mastodon}</code></p>
              <p>Lemmy: <code className="text-white/80">{handles.lemmy}</code></p>
              <p className="text-white/40">Replies there are checked by the organizer before they show here.</p>
            </div>
          )}
          <Link to="/communities" className="block text-xs underline text-white/50">More communities</Link>
        </aside>
      </div>
    </div>
  );
}

function ReportButton({ postId }: { postId: string }) {
  const { toast } = useToast();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('spam');
  if (!open) return <button type="button" className="text-[11px] text-white/40 underline mt-2" onClick={() => setOpen(true)}>Report</button>;
  return (
    <div className="mt-2 flex gap-2 items-center text-xs">
      <select value={reason} onChange={(e) => setReason(e.target.value)} className="bg-black border border-white/20 rounded px-2 py-1">
        {REPORT_REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
      </select>
      <button type="button" className="underline" onClick={async () => {
        try {
          await reportPost(postId, reason, null);
          toast({ kind: 'success', message: 'Thanks, the organizer will look at it.' });
          setOpen(false);
        } catch (e) {
          toast({ kind: 'error', message: friendlyError(e) });
        }
      }}>Send report</button>
    </div>
  );
}

function Composer({ communityId, isHost, onDone }: { communityId: string; isHost: boolean; onDone: () => Promise<void> }) {
  const { toast } = useToast();
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [members, setMembers] = useState(false);
  const [notify, setNotify] = useState(false);
  const [evName, setEvName] = useState('');
  const [evAt, setEvAt] = useState('');
  const [evVenue, setEvVenue] = useState('');
  const [evLink, setEvLink] = useState('');
  const [busy, setBusy] = useState(false);

  const addOwn = async () => {
    const id = eventIdFromLink(evLink);
    if (!id) return;
    setBusy(true);
    try {
      await addCommunityEvent(communityId, id, false, null, 'community', []);
      toast({ kind: 'success', message: 'Added. Members hear about it once it is published.' });
      setEvLink('');
      await onDone();
    } catch (e) {
      toast({ kind: 'error', message: friendlyError(e) });
    } finally {
      setBusy(false);
    }
  };

  const post = async () => {
    setBusy(true);
    try {
      const r = await writePost(communityId, title.trim() || null, body, members ? 'members' : 'public', notify);
      toast({ kind: r.notify_note ? 'error' : 'success', message: r.notify_note ? `Posted. Not sent to members: ${r.notify_note}.` : 'Posted.' });
      setTitle(''); setBody(''); setNotify(false);
      await onDone();
    } catch (e) {
      toast({ kind: 'error', message: friendlyError(e) });
    } finally {
      setBusy(false);
    }
  };

  const propose = async () => {
    setBusy(true);
    try {
      const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
      await proposeEvent(communityId, evName, new Date(evAt).toISOString(), tz, evVenue || null);
      toast({ kind: 'success', message: 'Sent to the organizer as a draft. They publish it.' });
      setEvName(''); setEvAt(''); setEvVenue('');
    } catch (e) {
      toast({ kind: 'error', message: friendlyError(e) });
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="rounded-xl border border-white/15 p-4 space-y-3">
      <h2 className="text-xs font-black uppercase tracking-widest text-white/50">Write a post</h2>
      <input className={FLD} placeholder="Title (optional)" maxLength={140} value={title} onChange={(e) => setTitle(e.target.value)} />
      <textarea className={FLD} rows={4} maxLength={5000} placeholder="What's new?" value={body} onChange={(e) => setBody(e.target.value)} />
      <div className="flex flex-wrap gap-4 text-xs text-white/70">
        <label className="flex gap-2 items-center"><input type="checkbox" checked={members} onChange={(e) => setMembers(e.target.checked)} /> Members only</label>
        <label className="flex gap-2 items-center"><input type="checkbox" checked={notify} onChange={(e) => setNotify(e.target.checked)} /> Email / text members (3 a day)</label>
      </div>
      <button type="button" disabled={busy || !body.trim()} className={`${BTN} bg-white text-black`} onClick={post}>Post</button>
      {isHost && (
        <div className="pt-4 border-t border-white/10 space-y-2">
          <h3 className="text-xs font-black uppercase tracking-widest text-white/50">Propose an event</h3>
          <input className={FLD} placeholder="Event name" maxLength={120} value={evName} onChange={(e) => setEvName(e.target.value)} />
          <input className={FLD} type="datetime-local" value={evAt} onChange={(e) => setEvAt(e.target.value)} />
          <input className={FLD} placeholder="Where" value={evVenue} onChange={(e) => setEvVenue(e.target.value)} />
          <button type="button" disabled={busy || !evName.trim() || !evAt} className={`${BTN} border border-white/40`} onClick={propose}>Send to organizer</button>
          <h3 className="text-xs font-black uppercase tracking-widest text-white/50 pt-2">Add one of your events</h3>
          <input className={FLD} placeholder="Paste your event's link" value={evLink} onChange={(e) => setEvLink(e.target.value)} />
          <button type="button" disabled={busy || !eventIdFromLink(evLink)} className={`${BTN} border border-white/40`} onClick={addOwn}>Add to this community</button>
          <p className="text-[11px] text-white/40">An event of an organization you own or manage on Exos.</p>
        </div>
      )}
    </section>
  );
}
