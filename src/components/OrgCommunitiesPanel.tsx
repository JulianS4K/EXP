// Org settings → Communities (docs/communities.md, mig 20261031200000).
// Owners and managers: create a community, set how people join, invite
// members and hosts, approve requests, remove / ban, list events (members-only
// or member early access), work the report and fediverse-reply queues, and
// turn federation on. Every action is an RPC that re-checks the role.

import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { publicUrl } from '../lib/utils';
import { useToast } from '../context/ToastContext';
import { friendlyError, JOIN_MODE_LABEL, slugProblem, suggestSlug, type JoinMode } from '../lib/communities';
import {
  addCommunityEvent, blockRemote, communityAdmin, createInvite, decideRequest, inviteHost, listOrgCommunities, memberList,
  moderatePost, removeCommunityEvent, removeMember, resolveReport, reviewReply, revokeHost, revokeInvite, saveCommunity,
  unbanMember, type CommunityAdmin,
} from '../lib/communitiesApi';

const CARD = 'bg-white rounded-2xl border border-slate-200 shadow-sm p-6';
const H = 'text-xs font-black text-slate-500 uppercase tracking-widest';
const FLD = 'w-full bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm text-slate-900 focus:outline-none focus:border-tm-blue';
const BTN = 'px-3 py-1.5 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest text-slate-600 hover:border-tm-blue hover:text-tm-blue disabled:opacity-50';

type Member = Awaited<ReturnType<typeof memberList>>[number];

export default function OrgCommunitiesPanel({ orgId }: { orgId: string }) {
  const { toast } = useToast();
  const [list, setList] = useState<Awaited<ReturnType<typeof listOrgCommunities>>>([]);
  const [sel, setSel] = useState<string | null>(null);
  const [admin, setAdmin] = useState<CommunityAdmin | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [tab, setTab] = useState<'active' | 'pending' | 'banned'>('active');
  const [newName, setNewName] = useState('');
  const [newSlug, setNewSlug] = useState('');
  const [busy, setBusy] = useState(false);
  const [lastLink, setLastLink] = useState<string | null>(null);
  const [orgEvents, setOrgEvents] = useState<{ id: string; name: string; starts_at: string | null }[]>([]);

  const reload = useCallback(async () => {
    try {
      setList(await listOrgCommunities(orgId));
      if (sel) {
        setAdmin(await communityAdmin(sel));
        setMembers(await memberList(sel, tab));
      }
    } catch (e) {
      toast({ kind: 'error', message: friendlyError(e) });
    }
  }, [orgId, sel, tab, toast]);

  useEffect(() => { void reload(); }, [reload]);
  useEffect(() => {
    supabase.from('exos_events').select('id, name, starts_at').eq('org_id', orgId).order('starts_at', { ascending: false }).limit(200)
      .then(({ data }) => setOrgEvents((data ?? []) as typeof orgEvents));
  }, [orgId]);

  const act = async (fn: () => Promise<unknown>, ok: string) => {
    setBusy(true);
    try {
      const r = await fn();
      const path = (r as { path?: string } | null)?.path;
      if (path) setLastLink(publicUrl(path));
      toast({ kind: 'success', message: ok });
      await reload();
    } catch (e) {
      toast({ kind: 'error', message: friendlyError(e) });
    } finally {
      setBusy(false);
    }
  };

  const c = admin?.community;
  return (
    <div className={CARD} id="communities">
      <h2 className={`${H} mb-2`}>Communities</h2>
      <p className="text-xs text-slate-400 mb-4">
        A page people join to hear about every event you (and the hosts you invite) run. Members choose email and/or texts;
        mail carries an unsubscribe link and texts honor STOP.
      </p>

      <div className="flex flex-wrap gap-2 mb-4">
        {list.map((x) => (
          <button key={x.id} type="button" onClick={() => setSel(x.id)}
            className={`${BTN} ${sel === x.id ? 'border-tm-blue text-tm-blue' : ''}`}>{x.name}{x.status === 'archived' ? ' (archived)' : ''}</button>
        ))}
      </div>

      <div className="grid sm:grid-cols-3 gap-2 mb-6">
        <input className={FLD} placeholder="New community name" value={newName}
          onChange={(e) => { setNewName(e.target.value); if (!newSlug) setNewSlug(''); }} />
        <input className={FLD} placeholder={newName ? suggestSlug(newName) : 'link-name'} value={newSlug} onChange={(e) => setNewSlug(e.target.value.toLowerCase())} />
        <button type="button" className={BTN} disabled={busy || !newName.trim() || !!slugProblem(newSlug || suggestSlug(newName))}
          onClick={() => void act(async () => {
            const r = await saveCommunity(orgId, null, { name: newName.trim(), slug: newSlug || suggestSlug(newName) });
            setSel(String(r.id)); setNewName(''); setNewSlug('');
          }, 'Community created.')}>Create</button>
        {newName && slugProblem(newSlug || suggestSlug(newName)) && <p className="text-[11px] text-red-500 sm:col-span-3">{slugProblem(newSlug || suggestSlug(newName))}</p>}
      </div>

      {c && admin && (
        <div className="space-y-6">
          <div key={c.id}><Settings c={c} busy={busy} onSave={(f) => void act(() => saveCommunity(orgId, c.id, f), 'Saved.')} /></div>
          <p className="text-xs text-slate-500">
            {admin.counts.members} members ({admin.counts.email} by email, {admin.counts.sms} by text) · {admin.counts.pending} waiting ·{' '}
            {admin.counts.banned} banned{c.federation_enabled ? ` · ${admin.counts.fediverse_followers} fediverse followers` : ''} ·{' '}
            <a className="underline" href={publicUrl(`/c/${c.slug}`)} target="_blank" rel="noreferrer">Open page</a>
          </p>
          {lastLink && (
            <div className="text-xs bg-slate-50 rounded p-2 break-all">
              Invite link (shown once): <code>{lastLink}</code>{' '}
              <button type="button" className="underline" onClick={() => void navigator.clipboard.writeText(lastLink)}>Copy</button>
            </div>
          )}

          <section>
            <h3 className={`${H} mb-2`}>Members</h3>
            <div className="flex gap-2 mb-2">
              {(['active', 'pending', 'banned'] as const).map((t) => (
                <button key={t} type="button" className={`${BTN} ${tab === t ? 'border-tm-blue text-tm-blue' : ''}`} onClick={() => setTab(t)}>{t}</button>
              ))}
            </div>
            <ul className="divide-y divide-slate-100 text-sm max-h-72 overflow-auto">
              {members.map((m) => (
                <li key={m.user_id} className="py-2 flex flex-wrap gap-2 items-center justify-between">
                  <span>{m.email} <span className="text-[11px] text-slate-400">{[m.notify_email && 'email', m.notify_sms && 'text', m.ban_reason].filter(Boolean).join(' · ')}</span></span>
                  <span className="flex gap-1">
                    {tab === 'pending' && <>
                      <button type="button" className={BTN} disabled={busy} onClick={() => void act(() => decideRequest(c.id, m.user_id, true), 'Approved.')}>Approve</button>
                      <button type="button" className={BTN} disabled={busy} onClick={() => void act(() => decideRequest(c.id, m.user_id, false), 'Declined.')}>Decline</button>
                    </>}
                    {tab === 'active' && <button type="button" className={BTN} disabled={busy} onClick={() => void act(() => removeMember(c.id, m.user_id, false, null), 'Removed.')}>Remove</button>}
                    {tab !== 'banned' && <button type="button" className={BTN} disabled={busy} onClick={() => {
                      const reason = window.prompt('Reason for the ban (only organizers see it)') ?? '';
                      void act(() => removeMember(c.id, m.user_id, true, reason || null), 'Banned.');
                    }}>Ban</button>}
                    {tab === 'banned' && <button type="button" className={BTN} disabled={busy} onClick={() => void act(() => unbanMember(c.id, m.user_id), 'Unbanned.')}>Unban</button>}
                  </span>
                </li>
              ))}
              {members.length === 0 && <li className="py-2 text-slate-400">Nobody here.</li>}
            </ul>
          </section>

          <InviteForms busy={busy}
            onMember={(email, uses) => void act(() => createInvite(c.id, email, uses), 'Invite created. Send them the link.')}
            onHost={(email, name) => void act(() => inviteHost(c.id, email, name, null), 'Host invite created. Send them the link.')} />
          {admin.invites.length > 0 && (
            <ul className="text-xs text-slate-500 space-y-1">
              {admin.invites.map((i) => (
                <li key={i.id}>{i.email ?? `Link (${i.uses}/${i.max_uses} used)`} · until {new Date(i.expires_at).toLocaleDateString()}{' '}
                  <button type="button" className="underline" onClick={() => void act(() => revokeInvite(i.id), 'Invite revoked.')}>revoke</button></li>
              ))}
            </ul>
          )}
          {admin.hosts.length > 0 && (
            <ul className="text-xs text-slate-500 space-y-1">
              {admin.hosts.map((h) => (
                <li key={h.id}>Host: {h.display_name} ({h.email}) · {h.status}{' '}
                  <button type="button" className="underline" onClick={() => void act(() => revokeHost(h.id), 'Host removed.')}>remove</button></li>
              ))}
            </ul>
          )}

          <EventsSection admin={admin} orgEvents={orgEvents} busy={busy}
            onAdd={(id, mo, early, rule, prods) => void act(() => addCommunityEvent(c.id, id, mo, early, rule, prods), 'Event listed.')}
            onRemove={(id) => void act(() => removeCommunityEvent(c.id, id), 'Event removed from the community.')} />

          <section>
            <h3 className={`${H} mb-2`}>Posts</h3>
            <ul className="text-sm divide-y divide-slate-100 max-h-72 overflow-auto">
              {admin.posts.map((p) => (
                <li key={p.id} className="py-2 flex justify-between gap-2">
                  <span className="min-w-0"><span className="font-semibold">{p.title ?? p.body.slice(0, 60)}</span>
                    <span className="text-[11px] text-slate-400"> {[p.status, p.visibility, p.host && `by ${p.host}`, p.notified_at && 'members notified', p.notify_note, p.open_reports ? `${p.open_reports} reports` : null].filter(Boolean).join(' · ')}</span></span>
                  <span className="flex gap-1 shrink-0">
                    {p.status === 'published' ? <button type="button" className={BTN} onClick={() => void act(() => moderatePost(p.id, 'hide'), 'Hidden.')}>Hide</button>
                      : <button type="button" className={BTN} onClick={() => void act(() => moderatePost(p.id, 'restore'), 'Restored.')}>Restore</button>}
                    {p.status !== 'removed' && <button type="button" className={BTN} onClick={() => void act(() => moderatePost(p.id, 'remove'), 'Removed.')}>Remove</button>}
                  </span>
                </li>
              ))}
              {admin.posts.length === 0 && <li className="py-2 text-slate-400">No posts yet. Post from the community page.</li>}
            </ul>
          </section>

          {admin.reports.length > 0 && (
            <section>
              <h3 className={`${H} mb-2`}>Reports</h3>
              <ul className="text-sm space-y-2">
                {admin.reports.map((r) => (
                  <li key={r.id} className="border border-slate-100 rounded p-2">
                    <p className="text-xs text-slate-500">{r.reason}{r.note ? `: ${r.note}` : ''}</p>
                    <p className="text-sm">{r.post_excerpt}</p>
                    <div className="flex gap-1 mt-1">
                      {(['dismiss', 'hide', 'remove', 'ban'] as const).map((a) => (
                        <button key={a} type="button" className={BTN} disabled={busy} onClick={() => void act(() => resolveReport(r.id, a), 'Done.')}>{a === 'ban' ? 'Remove + ban author' : a}</button>
                      ))}
                    </div>
                  </li>
                ))}
              </ul>
            </section>
          )}

          {c.federation_enabled && (
            <section>
              <h3 className={`${H} mb-2`}>Fediverse replies waiting</h3>
              <ul className="text-sm space-y-2">
                {admin.remote_replies.map((r) => (
                  <li key={r.id} className="border border-slate-100 rounded p-2">
                    <p className="text-xs text-slate-500">{r.actor_name} {r.actor_handle}</p>
                    <p className="whitespace-pre-line">{r.content_text}</p>
                    <div className="flex gap-1 mt-1">
                      <button type="button" className={BTN} onClick={() => void act(() => reviewReply(r.id, true), 'Shown on the page.')}>Approve</button>
                      <button type="button" className={BTN} onClick={() => void act(() => reviewReply(r.id, false), 'Rejected.')}>Reject</button>
                      <button type="button" className={BTN} onClick={() => void act(() => blockRemote(c.id, r.actor_uri), 'Blocked.')}>Block account</button>
                    </div>
                  </li>
                ))}
                {admin.remote_replies.length === 0 && <li className="text-slate-400 text-xs">Nothing waiting.</li>}
              </ul>
              <BlockForm blocks={admin.blocks} onBlock={(p, b) => void act(() => blockRemote(c.id, p, b), b ? 'Blocked.' : 'Unblocked.')} />
            </section>
          )}
        </div>
      )}
    </div>
  );
}

function Settings({ c, busy, onSave }: { c: CommunityAdmin['community']; busy: boolean; onSave: (f: Record<string, unknown>) => void }) {
  const s = (k: string) => (c[k] as string | null) ?? '';
  const [f, setF] = useState({
    name: s('name'), tagline: s('tagline'), about: s('about'), banner_url: s('banner_url'), city: s('city'), region: s('region'),
    country: s('country'), join_mode: c.join_mode as JoinMode, visibility: c.visibility, federation_enabled: !!c.federation_enabled,
    status: c.status,
  });
  const upd = (k: keyof typeof f, v: unknown) => setF((x) => ({ ...x, [k]: v }));
  return (
    <section className="grid sm:grid-cols-2 gap-2">
      <input className={FLD} value={f.name} maxLength={80} onChange={(e) => upd('name', e.target.value)} placeholder="Name" />
      <input className={FLD} value={f.tagline} maxLength={140} onChange={(e) => upd('tagline', e.target.value)} placeholder="Tagline" />
      <textarea className={`${FLD} sm:col-span-2`} rows={3} maxLength={5000} value={f.about} onChange={(e) => upd('about', e.target.value)} placeholder="About" />
      <input className={`${FLD} sm:col-span-2`} value={f.banner_url} onChange={(e) => upd('banner_url', e.target.value)} placeholder="Banner image URL (https://…)" />
      <input className={FLD} value={f.city} onChange={(e) => upd('city', e.target.value)} placeholder="City (for the directory)" />
      <div className="flex gap-2">
        <input className={FLD} value={f.region} onChange={(e) => upd('region', e.target.value)} placeholder="State / region" />
        <input className={FLD} value={f.country} maxLength={2} onChange={(e) => upd('country', e.target.value.toUpperCase())} placeholder="US" />
      </div>
      <select className={FLD} value={f.join_mode} onChange={(e) => upd('join_mode', e.target.value)}>
        {(Object.keys(JOIN_MODE_LABEL) as JoinMode[]).map((m) => <option key={m} value={m}>{JOIN_MODE_LABEL[m]}</option>)}
      </select>
      <select className={FLD} value={f.visibility} onChange={(e) => upd('visibility', e.target.value)}>
        <option value="public">Listed in the directory</option>
        <option value="unlisted">Unlisted (link only)</option>
      </select>
      <label className="flex gap-2 items-center text-xs text-slate-600 sm:col-span-2">
        <input type="checkbox" checked={f.federation_enabled} onChange={(e) => upd('federation_enabled', e.target.checked)} />
        Share on the fediverse: people on Mastodon, Lemmy and other servers can follow without an Exos account (public posts and non-members-only events only; their replies wait for your approval).
      </label>
      <label className="flex gap-2 items-center text-xs text-slate-600 sm:col-span-2">
        <input type="checkbox" checked={f.status === 'archived'} onChange={(e) => upd('status', e.target.checked ? 'archived' : 'active')} /> Archived (page hidden)
      </label>
      <button type="button" className={`${BTN} w-fit`} disabled={busy} onClick={() => onSave(f)}>Save community</button>
    </section>
  );
}

function InviteForms({ busy, onMember, onHost }: { busy: boolean; onMember: (email: string | null, uses: number) => void; onHost: (email: string, name: string) => void }) {
  const [email, setEmail] = useState('');
  const [uses, setUses] = useState(25);
  const [hEmail, setHEmail] = useState('');
  const [hName, setHName] = useState('');
  return (
    <section className="grid sm:grid-cols-2 gap-4">
      <div className="space-y-2">
        <h3 className={H}>Invite members</h3>
        <input className={FLD} value={email} onChange={(e) => setEmail(e.target.value)} placeholder="Their email (or leave empty for a shared link)" />
        {!email && <input className={FLD} type="number" min={1} max={500} value={uses} onChange={(e) => setUses(Number(e.target.value))} />}
        <button type="button" className={BTN} disabled={busy} onClick={() => onMember(email.trim() || null, email ? 1 : uses)}>Create invite link</button>
      </div>
      <div className="space-y-2">
        <h3 className={H}>Invite a host</h3>
        <input className={FLD} value={hName} onChange={(e) => setHName(e.target.value)} placeholder="Shown as (e.g. Saturday Run Club)" />
        <input className={FLD} value={hEmail} onChange={(e) => setHEmail(e.target.value)} placeholder="Their email" />
        <p className="text-[11px] text-slate-400">Hosts can add their own events and write posts here. Nothing else in your organization.</p>
        <button type="button" className={BTN} disabled={busy || !hEmail.trim() || !hName.trim()} onClick={() => onHost(hEmail.trim(), hName.trim())}>Create host invite</button>
      </div>
    </section>
  );
}

function EventsSection({ admin, orgEvents, busy, onAdd, onRemove }: {
  admin: CommunityAdmin; orgEvents: { id: string; name: string; starts_at: string | null }[]; busy: boolean;
  onAdd: (id: string, membersOnly: boolean, early: string | null, rule: 'community' | 'membership' | 'either', prods: string[]) => void;
  onRemove: (id: string) => void;
}) {
  const [ev, setEv] = useState('');
  const [access, setAccess] = useState<'open' | 'members' | 'early'>('open');
  const [early, setEarly] = useState('');
  const [rule, setRule] = useState<'community' | 'membership' | 'either'>('community');
  const [prods, setProds] = useState('');
  const listed = new Set(admin.events.map((e) => e.event_id));
  return (
    <section className="space-y-2">
      <h3 className={H}>Events</h3>
      <ul className="text-sm divide-y divide-slate-100">
        {admin.events.map((e) => (
          <li key={e.event_id} className="py-1.5 flex justify-between gap-2">
            <span>{e.name} <span className="text-[11px] text-slate-400">{[e.status, e.members_only && 'members only',
              e.early_access_until && `early access until ${new Date(e.early_access_until).toLocaleString()}`, e.host && `by ${e.host}`,
              e.announced_at ? 'announced' : e.announce_note].filter(Boolean).join(' · ')}</span></span>
            <button type="button" className={BTN} onClick={() => onRemove(e.event_id)}>Remove</button>
          </li>
        ))}
      </ul>
      <div className="grid sm:grid-cols-2 gap-2">
        <select className={FLD} value={ev} onChange={(e) => setEv(e.target.value)}>
          <option value="">Pick one of your events…</option>
          {orgEvents.filter((e) => !listed.has(e.id)).map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}
        </select>
        <select className={FLD} value={access} onChange={(e) => setAccess(e.target.value as typeof access)}>
          <option value="open">Open to everyone</option>
          <option value="members">Members only</option>
          <option value="early">Member early access, then everyone</option>
        </select>
        {access === 'early' && <input className={FLD} type="datetime-local" value={early} onChange={(e) => setEarly(e.target.value)} />}
        {access !== 'open' && (
          <select className={FLD} value={rule} onChange={(e) => setRule(e.target.value as typeof rule)}>
            <option value="community">Community members</option>
            <option value="membership">Paid membership holders (Memberships)</option>
            <option value="either">Either</option>
          </select>
        )}
        {access !== 'open' && rule !== 'community' && (
          <input className={`${FLD} sm:col-span-2`} value={prods} onChange={(e) => setProds(e.target.value)} placeholder="Membership product ids, comma-separated" />
        )}
      </div>
      <p className="text-[11px] text-slate-400">Members hear about each event once it's published (up to 5 a day). Members-only events stay off the fediverse.</p>
      <button type="button" className={BTN} disabled={busy || !ev || (access === 'early' && !early)} onClick={() => onAdd(ev, access === 'members',
        access === 'early' ? new Date(early).toISOString() : null, access === 'open' ? 'community' : rule,
        access !== 'open' && rule !== 'community' ? prods.split(',').map((x) => x.trim()).filter(Boolean) : [])}>List in community</button>
    </section>
  );
}

function BlockForm({ blocks, onBlock }: { blocks: string[]; onBlock: (pattern: string, block: boolean) => void }) {
  const [p, setP] = useState('');
  return (
    <div className="mt-3 space-y-1">
      <div className="flex gap-2">
        <input className={FLD} value={p} onChange={(e) => setP(e.target.value)} placeholder="Block a server (example.social) or an account URL" />
        <button type="button" className={BTN} disabled={!p.trim()} onClick={() => { onBlock(p.trim(), true); setP(''); }}>Block</button>
      </div>
      {blocks.map((b) => <p key={b} className="text-xs text-slate-500">{b} <button type="button" className="underline" onClick={() => onBlock(b, false)}>unblock</button></p>)}
    </div>
  );
}
