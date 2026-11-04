// /groups/:groupId — a group's chat (mig 20261031230000, docs/group-chat.md).
//
// Messages come over Supabase Realtime (members-only RLS) with a 20-second
// poll as a fallback. Each member also has a masked number: texting it posts
// here and reaches everyone who turned texts on, without anyone seeing a real
// number. After the event, "Share my number / Instagram" reveals a contact
// only when the other person shares the same back.

import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Ban, Bell, BellOff, Flag, Instagram, LogOut, MessageSquare, Phone, Send, Users } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import {
  blockMember, closesLabel, contacts as loadContacts, formatPhone, formatRelayBody, groupState, instagramUrl, joinGroup,
  leaveGroup, linkify, listMessages, MAX_MESSAGE_CHARS, mergeMessages, messageProblem, muteGroup, postMessage,
  relayConsentText, reportMessage, revokeContact, setMyName, shareContact, smsOptIn, smsOptOut, subscribeMessages,
  type Contacts, type GroupMessage, type GroupState,
} from '../lib/groupChat';

const btn = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-2 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';
const box = 'border border-white/10 bg-white/[0.03] p-4';

export default function GroupChat() {
  const { groupId = '' } = useParams();
  const { user, openAuth } = useAuth();
  const { toast } = useToast();
  const [state, setState] = useState<GroupState | null>(null);
  const [notMember, setNotMember] = useState(false);
  const [messages, setMessages] = useState<GroupMessage[]>([]);
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);
  const [panel, setPanel] = useState<'none' | 'texts' | 'members' | 'contacts'>('none');
  const endRef = useRef<HTMLDivElement>(null);

  const fail = useCallback((e: unknown) => toast({ kind: 'error', message: (e as Error).message }), [toast]);

  const reload = useCallback(async () => {
    try {
      setState(await groupState(groupId));
      setNotMember(false);
    } catch {
      setNotMember(true);
    }
  }, [groupId]);

  const refresh = useCallback(async () => {
    try {
      const fresh = await listMessages(groupId);
      setMessages((prev) => mergeMessages(prev, fresh));
    } catch { /* not a member yet */ }
  }, [groupId]);

  useEffect(() => {
    if (!user || !groupId) return undefined;
    void reload();
    void refresh();
    const leave = subscribeMessages(groupId, (m) => setMessages((prev) => mergeMessages(prev, [m])));
    const poll = window.setInterval(() => void refresh(), 20_000);
    return () => { leave(); window.clearInterval(poll); };
  }, [user, groupId, reload, refresh]);

  useEffect(() => { endRef.current?.scrollIntoView({ block: 'end' }); }, [messages.length]);

  const blocked = useMemo(() => new Set(state?.members.filter((m) => m.blocked).map((m) => m.userId) ?? []), [state]);

  if (!user) return (
    <div className="wall min-h-screen flex flex-col items-center justify-center px-4 py-20 text-center">
      <p className="type text-white/60 uppercase tracking-widest text-[12px] mb-4">Sign in to open this group chat</p>
      <button type="button" onClick={() => openAuth('options')} className="bg-brand-primary text-black font-black uppercase tracking-wider px-6 py-3">Sign in</button>
    </div>
  );

  if (notMember) return (
    <div className="wall min-h-screen flex flex-col items-center justify-center px-4 py-20 text-center">
      <p className="type text-white/70 text-sm mb-4">You're not in this group yet.</p>
      <button type="button" className={btn} onClick={async () => {
        try { await joinGroup(groupId); await reload(); await refresh(); } catch (e) { fail(e); }
      }}>Join</button>
      <Link to="/groups" className="type text-[11px] text-white/50 mt-6 underline">My groups</Link>
    </div>
  );

  if (!state) return <div className="wall min-h-screen p-8 text-center type text-xs text-white/50" role="status">Loading…</div>;

  const silenced = state.me.silencedUntil && state.me.silencedUntil > new Date();
  const muted = state.me.mutedUntil && state.me.mutedUntil > new Date();
  const problem = draft ? messageProblem(draft) : null;

  const send = async (e: FormEvent) => {
    e.preventDefault();
    if (!draft.trim() || problem) return;
    setSending(true);
    try {
      await postMessage(groupId, draft, crypto.randomUUID());
      setDraft('');
      await refresh();
    } catch (err) { fail(err); } finally { setSending(false); }
  };

  return (
    <div className="wall flex flex-col h-[100dvh] max-w-3xl mx-auto">
      <header className="flex items-center gap-2 px-4 py-3 border-b border-white/10">
        <Link to="/groups" aria-label="My groups" className="p-1 text-white/70 hover:text-white"><ArrowLeft className="w-5 h-5" /></Link>
        <div className="flex-1 min-w-0">
          <h1 className="text-white font-bold truncate">{state.title}</h1>
          <p className="type text-[11px] text-white/50">{state.members.length} members{closesLabel(state.closesAt) ? ` · ${closesLabel(state.closesAt)}` : ''}</p>
        </div>
        <button type="button" aria-label="Text the group" aria-pressed={panel === 'texts'} onClick={() => setPanel(panel === 'texts' ? 'none' : 'texts')} className="p-2 text-white/70 hover:text-brand-primary"><Phone className="w-5 h-5" /></button>
        <button type="button" aria-label="Members" aria-pressed={panel === 'members'} onClick={() => setPanel(panel === 'members' ? 'none' : 'members')} className="p-2 text-white/70 hover:text-brand-primary"><Users className="w-5 h-5" /></button>
        {state.eventOver && (
          <button type="button" aria-label="Share contact" aria-pressed={panel === 'contacts'} onClick={() => setPanel(panel === 'contacts' ? 'none' : 'contacts')} className="p-2 text-white/70 hover:text-brand-primary"><Instagram className="w-5 h-5" /></button>
        )}
      </header>

      {panel !== 'none' && (
        <div className="max-h-[55dvh] overflow-y-auto border-b border-white/10 p-4">
          {panel === 'texts' && <TextsPanel state={state} onChange={reload} fail={fail} />}
          {panel === 'members' && <MembersPanel state={state} onChange={reload} fail={fail} muted={!!muted} />}
          {panel === 'contacts' && <ContactsPanel state={state} fail={fail} />}
        </div>
      )}

      <main className="flex-1 overflow-y-auto px-4 py-3 space-y-3" aria-live="polite">
        {messages.length === 0 && <p className="type text-xs text-white/50 text-center py-8">No messages yet. Say hi.</p>}
        {messages.filter((m) => !m.senderId || !blocked.has(m.senderId)).map((m) => {
          const mine = m.senderId === state.me.userId;
          if (m.source === 'system') return <p key={m.id} className="type text-[11px] text-white/50 text-center">{m.body}</p>;
          return (
            <div key={m.id} className={`flex flex-col ${mine ? 'items-end' : 'items-start'}`}>
              <span className="type text-[10px] text-white/40 mb-0.5">
                {mine ? 'You' : m.senderName}{m.source === 'sms' ? ' · by text' : ''} · {m.createdAt.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}
              </span>
              <div className={`max-w-[85%] px-3 py-2 text-sm whitespace-pre-wrap break-words ${mine ? 'bg-brand-primary/20 text-white' : 'bg-white/[0.06] text-white'}`}>
                {linkify(m.body).map((p, i) => ('href' in p
                  ? <a key={i} href={p.href} target="_blank" rel="nofollow noopener noreferrer ugc" className="underline text-brand-primary">{p.text}</a>
                  : <span key={i}>{p.text}</span>))}
              </div>
              {!mine && (
                <button type="button" className="type text-[10px] text-white/30 hover:text-white/70 mt-0.5 flex items-center gap-1" onClick={async () => {
                  const reason = window.prompt('What is wrong with this message? (sent to the organizer)');
                  if (!reason) return;
                  try {
                    const r = await reportMessage(m.id, reason);
                    toast({ kind: 'success', message: r.hidden ? 'Reported and hidden.' : 'Reported to the organizer.' });
                    if (r.hidden) setMessages((prev) => prev.filter((x) => x.id !== m.id));
                  } catch (e) { fail(e); }
                }}><Flag className="w-3 h-3" aria-hidden="true" /> Report</button>
              )}
            </div>
          );
        })}
        <div ref={endRef} />
      </main>

      {state.open ? (
        <form onSubmit={send} className="border-t border-white/10 p-3 flex gap-2 items-end" style={{ paddingBottom: 'max(0.75rem, env(safe-area-inset-bottom))' }}>
          <label className="flex-1 min-w-0">
            <span className="sr-only">Message</span>
            <textarea value={draft} onChange={(e) => setDraft(e.target.value)} rows={1} maxLength={MAX_MESSAGE_CHARS + 50}
              disabled={!!silenced} placeholder={silenced ? 'The organizer paused your messages' : 'Message the group'}
              onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void send(e as unknown as FormEvent); } }}
              className="w-full resize-none bg-black border border-white/20 px-3 py-2 text-base sm:text-sm text-white max-h-32" />
            {problem && <span className="type block text-[10px] text-red-400 mt-1">{problem}</span>}
          </label>
          <button type="submit" aria-label="Send" disabled={sending || !draft.trim() || !!problem || !!silenced}
            className="bg-brand-primary text-black p-3 disabled:opacity-40"><Send className="w-4 h-4" /></button>
        </form>
      ) : (
        <p className="type text-[11px] text-white/50 text-center border-t border-white/10 p-4">This chat has closed.</p>
      )}
    </div>
  );
}

function TextsPanel({ state, onChange, fail }: { state: GroupState; onChange: () => Promise<void>; fail: (e: unknown) => void }) {
  const { toast } = useToast();
  const [phone, setPhone] = useState('');
  const [agree, setAgree] = useState(false);
  const [busy, setBusy] = useState(false);
  if (!state.relayEnabled) return <p className="type text-xs text-white/60">Texts are off for this group.</p>;
  return (
    <div className={box}>
      <p className="type text-xs text-white/80 flex items-center gap-2 mb-2">
        <MessageSquare className="w-4 h-4 text-brand-primary" aria-hidden="true" /> Text the group from your phone
      </p>
      {state.me.relayNumber
        ? <p className="text-sm text-white">Your group number: <strong>{formatPhone(state.me.relayNumber)}</strong></p>
        : <p className="type text-xs text-white/60">No text number is free for you right now; the chat here still works.</p>}
      <p className="type text-[11px] text-white/50 mt-1">Your real number stays hidden. Others see texts as "{formatRelayBody(state.me.displayName, 'your message')}".</p>
      {state.me.smsOn ? (
        <div className="mt-3">
          <p className="type text-xs text-white/70">Texts go to {state.me.smsPhoneHint}. Reply STOP to that number to stop.</p>
          <button type="button" className={`${btn} mt-2`} disabled={busy} onClick={async () => {
            setBusy(true);
            try { await smsOptOut(state.id); toast({ kind: 'success', message: 'No more texts from this group.' }); await onChange(); }
            catch (e) { fail(e); } finally { setBusy(false); }
          }}>Stop texts</button>
        </div>
      ) : state.me.relayNumber && (
        <div className="mt-3">
          <div className="flex gap-2">
            <input type="tel" inputMode="tel" autoComplete="tel" value={phone} onChange={(e) => setPhone(e.target.value)}
              placeholder="+1 212 555 0100" aria-label="Your mobile number"
              className="flex-1 min-w-0 bg-black border border-white/20 px-3 py-2 text-base sm:text-xs text-white" />
            <button type="button" className={btn} disabled={busy || !agree || phone.trim().length < 10} onClick={async () => {
              setBusy(true);
              try { await smsOptIn(state.id, state.title, phone); toast({ kind: 'success', message: 'Texts are on.' }); await onChange(); }
              catch (e) { fail(e); } finally { setBusy(false); }
            }}>Turn on</button>
          </div>
          <label className="type mt-2 flex items-start gap-2 text-[11px] text-white/50 leading-relaxed">
            <input type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} className="mt-0.5 accent-brand-primary" />
            <span>{relayConsentText(state.title)}</span>
          </label>
        </div>
      )}
    </div>
  );
}

function MembersPanel({ state, onChange, fail, muted }: { state: GroupState; onChange: () => Promise<void>; fail: (e: unknown) => void; muted: boolean }) {
  const { toast } = useToast();
  const [name, setName] = useState(state.me.displayName);
  return (
    <div className="space-y-4">
      <form className="flex gap-2" onSubmit={async (e) => {
        e.preventDefault();
        try { await setMyName(state.id, name); toast({ kind: 'success', message: 'Name updated.' }); await onChange(); } catch (err) { fail(err); }
      }}>
        <label className="flex-1 min-w-0">
          <span className="type block text-[10px] text-white/50 uppercase tracking-widest mb-1">Your name here</span>
          <input value={name} maxLength={40} onChange={(e) => setName(e.target.value)} className="w-full bg-black border border-white/20 px-3 py-2 text-base sm:text-xs text-white" />
        </label>
        <button type="submit" className={`${btn} self-end`}>Save</button>
      </form>
      <ul className="divide-y divide-white/10 border border-white/10">
        {state.members.map((m) => (
          <li key={m.userId} className="flex items-center gap-2 px-3 py-2">
            <span className="flex-1 min-w-0 truncate text-sm text-white">{m.displayName}{m.me ? ' (you)' : ''}{m.role === 'host' ? ' · host' : ''}</span>
            {!m.me && (
              <button type="button" className="type text-[10px] text-white/50 hover:text-white flex items-center gap-1" onClick={async () => {
                try { await blockMember(state.id, m.userId, !m.blocked); await onChange(); } catch (e) { fail(e); }
              }}><Ban className="w-3 h-3" aria-hidden="true" /> {m.blocked ? 'Unblock' : 'Block'}</button>
            )}
          </li>
        ))}
      </ul>
      <div className="flex flex-wrap gap-2">
        <button type="button" className={`${btn} flex items-center gap-1`} onClick={async () => {
          try { await muteGroup(state.id, muted ? null : new Date(Date.now() + 8 * 3600_000)); await onChange(); } catch (e) { fail(e); }
        }}>{muted ? <><Bell className="w-3 h-3" aria-hidden="true" /> Unmute</> : <><BellOff className="w-3 h-3" aria-hidden="true" /> Mute texts 8 h</>}</button>
        <button type="button" className={`${btn} flex items-center gap-1`} onClick={async () => {
          if (!window.confirm('Leave this group? Your group number and anything you shared are taken back.')) return;
          try { await leaveGroup(state.id); window.location.assign('/groups'); } catch (e) { fail(e); }
        }}><LogOut className="w-3 h-3" aria-hidden="true" /> Leave</button>
      </div>
    </div>
  );
}

function ContactsPanel({ state, fail }: { state: GroupState; fail: (e: unknown) => void }) {
  const [c, setC] = useState<Contacts | null>(null);
  const [kind, setKind] = useState<'phone' | 'instagram'>('instagram');
  const [to, setTo] = useState<string>('');
  const [value, setValue] = useState('');
  const load = useCallback(() => loadContacts(state.id).then(setC).catch(fail), [state.id, fail]);
  useEffect(() => { void load(); }, [load]);
  const others = state.members.filter((m) => !m.me && !m.blocked);
  return (
    <div className="space-y-4">
      <p className="type text-[11px] text-white/60">
        Share your number or Instagram with one person or the whole group. They see it only if they share the same with you too. You can take it back any time.
      </p>
      <form className="grid gap-2 sm:grid-cols-[auto_1fr_1fr_auto]" onSubmit={async (e) => {
        e.preventDefault();
        try { await shareContact(state.id, kind, to || null, value || undefined); setValue(''); await load(); } catch (err) { fail(err); }
      }}>
        <select value={kind} onChange={(e) => setKind(e.target.value as 'phone' | 'instagram')} aria-label="What to share" className="bg-black border border-white/20 px-2 py-2 text-base sm:text-xs text-white">
          <option value="instagram">Instagram</option><option value="phone">Phone</option>
        </select>
        <select value={to} onChange={(e) => setTo(e.target.value)} aria-label="With" className="bg-black border border-white/20 px-2 py-2 text-base sm:text-xs text-white">
          <option value="">Everyone in the group</option>
          {others.map((m) => <option key={m.userId} value={m.userId}>{m.displayName}</option>)}
        </select>
        <input value={value} onChange={(e) => setValue(e.target.value)} aria-label={kind === 'phone' ? 'Phone number' : 'Instagram handle'}
          placeholder={kind === 'phone' ? (state.me.smsPhoneHint ? `Your text number (${state.me.smsPhoneHint})` : '+1 212 555 0100') : '@handle'}
          className="bg-black border border-white/20 px-3 py-2 text-base sm:text-xs text-white min-w-0" />
        <button type="submit" className={btn}>Share</button>
      </form>
      {c && c.mine.length > 0 && (
        <div>
          <p className="type text-[10px] uppercase tracking-widest text-white/50 mb-1">You shared</p>
          <ul className="space-y-1">
            {c.mine.map((s) => (
              <li key={`${s.kind}:${s.toUser ?? 'all'}`} className="flex items-center gap-2 text-sm text-white">
                <span className="flex-1 min-w-0 truncate">{s.kind === 'phone' ? formatPhone(s.value) : `@${s.value}`} with {s.toName ?? 'everyone'}</span>
                <button type="button" className="type text-[10px] text-white/50 hover:text-white" onClick={async () => {
                  try { await revokeContact(state.id, s.kind, s.toUser); await load(); } catch (e) { fail(e); }
                }}>Take back</button>
              </li>
            ))}
          </ul>
        </div>
      )}
      <div>
        <p className="type text-[10px] uppercase tracking-widest text-white/50 mb-1">Shared with you (both ways)</p>
        {!c || c.revealed.length === 0
          ? <p className="type text-[11px] text-white/40">Nothing yet.</p>
          : <ul className="space-y-1">{c.revealed.map((r) => (
              <li key={`${r.userId}:${r.kind}`} className="text-sm text-white">
                {r.displayName}: {r.kind === 'phone'
                  ? <a href={`sms:${r.value}`} className="underline">{formatPhone(r.value)}</a>
                  : <a href={instagramUrl(r.value)} target="_blank" rel="noopener noreferrer" className="underline">@{r.value}</a>}
              </li>))}
            </ul>}
      </div>
    </div>
  );
}
