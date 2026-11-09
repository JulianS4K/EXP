// /split/:sessionId — split with friends, restaurant-style (mig 20261031220000).
//
// The host bought every ticket. Here they add friends (name, email, phone),
// set each friend's share (even by default), and text each one their ticket
// link plus a prefilled Venmo (or Cash App) link to pay the host back. The
// text goes from the host's own phone (an sms: link); Exos sends the ticket
// claim email, never touches the money, and keeps a paid / not-paid
// checklist the host ticks. Send mode: tickets now (default) or once marked
// paid.

import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Check, Copy, MessageSquare, Plus, Trash2 } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { getPublicEvent } from '../lib/events';
import {
  friendMessage, friendShares, getSplit, markSharePaid, normalizeCashtag, normalizeVenmo, noteNudge, saveSplit, smsUrl,
  totalShares, type SplitState,
} from '../lib/split';
import { formatCurrency, publicUrl } from '../lib/utils';

interface FriendDraft { name: string; email: string; phone: string; amount: string }

const input = 'w-full border-2 border-slate-200 rounded-xl px-3 py-2 font-bold text-sm focus:outline-none focus:border-brand-primary';
const label = 'text-[10px] font-black uppercase tracking-widest text-slate-400';

export default function SplitWithFriends() {
  const { sessionId = '' } = useParams();
  const { user } = useAuth();
  const { toast } = useToast();
  const [state, setState] = useState<SplitState | null>(null);
  const [title, setTitle] = useState('your event');
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [venmo, setVenmo] = useState('');
  const [cashapp, setCashapp] = useState('');
  const [sendMode, setSendMode] = useState<'now' | 'on_paid'>('now');
  const [friends, setFriends] = useState<FriendDraft[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!user) return undefined;
    let alive = true;
    getSplit(sessionId).then(async (s) => {
      if (!alive) return;
      setState(s);
      setVenmo(s.split?.venmoHandle ?? '');
      setCashapp(s.split?.cashappTag ?? '');
      setSendMode(s.split?.sendMode ?? 'now');
      const ev = await getPublicEvent(s.eventId).catch(() => null);
      if (alive && ev?.title) setTitle(ev.title);
    }).catch((e) => alive && setLoadErr((e as Error).message));
    return () => { alive = false; };
  }, [sessionId, user]);

  // Tickets the host can still send: theirs, active, not in transfer, not shared.
  const free = useMemo(() => {
    if (!state) return [];
    const shared = new Set(state.shares.map((s) => s.ticketId));
    return state.tickets.filter((t) => t.mine && t.status === 'active' && !t.pendingTransfer && !shared.has(t.ticketId));
  }, [state]);

  // Even split by default: every ticket costs the same; the host keeps theirs.
  const suggested = useMemo(() => {
    if (!state || friends.length === 0) return [];
    const already = state.shares.length;
    return friendShares(state.amountCents, state.quantity, already + friends.length).slice(already);
  }, [state, friends.length]);

  if (!user) return <Shell><p className="text-slate-500">Sign in with the account that bought the tickets.</p></Shell>;
  if (loadErr) return <Shell><p className="text-red-600 font-bold">{loadErr}</p></Shell>;
  if (!state) return <Shell><p className="text-slate-500">Loading…</p></Shell>;

  const cur = state.currency;
  const money = (c: number) => formatCurrency(c / 100, cur);
  const amountOf = (f: FriendDraft, i: number) => (f.amount.trim() === '' ? suggested[i] ?? 0 : Math.round(Number(f.amount) * 100));
  const drafts = friends.map((f, i) => ({ ...f, cents: amountOf(f, i) }));
  const draftTotal = drafts.reduce((n, d) => n + (Number.isFinite(d.cents) ? d.cents : 0), 0);
  const overTotal = totalShares(state.shares) + draftTotal > state.amountCents;
  const handlesOk = (venmo.trim() === '' || normalizeVenmo(venmo)) && (cashapp.trim() === '' || normalizeCashtag(cashapp))
    && (normalizeVenmo(venmo) || normalizeCashtag(cashapp));

  const save = async () => {
    if (drafts.length > free.length) return toast({ kind: 'error', message: `You have ${free.length} ticket(s) left to send.` });
    setSaving(true);
    try {
      const s = await saveSplit({
        sessionId,
        venmo: normalizeVenmo(venmo) ?? undefined,
        cashapp: normalizeCashtag(cashapp) ?? undefined,
        sendMode,
        note: `${title} tickets`,
        shares: drafts.map((d, i) => ({ ticketId: free[i].ticketId, name: d.name, email: d.email, phone: d.phone, amountCents: d.cents })),
      });
      setState(s);
      setFriends([]);
      toast({ kind: 'success', message: sendMode === 'now' ? 'Tickets sent. Now text each friend.' : 'Saved. Tickets go out when you tick them paid.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setSaving(false);
    }
  };

  const message = (s: SplitState['shares'][number]) => friendMessage({
    friendName: s.name, eventTitle: title, cents: s.amountCents,
    claimUrl: s.claimPath ? publicUrl(s.claimPath) : null,
    venmo: state.split?.venmoHandle, cashapp: state.split?.cashappTag,
  });

  const togglePaid = async (id: string, paid: boolean) => {
    try { setState(await markSharePaid(id, paid)); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  };

  return (
    <Shell>
      <p className="text-slate-500 text-sm mb-6">
        {title}: {state.quantity} tickets, {money(state.amountCents)} paid. Friends pay you back directly; Exos never handles that money.
      </p>

      {state.shares.length > 0 && (
        <section className="mb-10">
          <h2 className={`${label} mb-3`}>Who's paid</h2>
          <ul className="space-y-3">
            {state.shares.map((s) => (
              <li key={s.id} className="border border-slate-200 rounded-2xl p-4">
                <div className="flex items-center justify-between gap-3">
                  <label className="flex items-center gap-3 font-bold text-slate-900">
                    <input type="checkbox" checked={s.paid} onChange={(e) => void togglePaid(s.id, e.target.checked)} className="w-5 h-5" />
                    {s.name} <span className="text-slate-400 font-normal">{money(s.amountCents)}</span>
                  </label>
                  {s.paid ? <span className="text-emerald-600 text-xs font-black flex items-center gap-1"><Check className="w-4 h-4" />PAID</span>
                    : <span className="text-amber-600 text-xs font-black">NOT YET</span>}
                </div>
                <p className="text-xs text-slate-400 mt-1">
                  {s.transferStatus === 'claimed' ? 'Ticket claimed' : s.transferStatus === 'pending' ? 'Ticket sent, not claimed yet'
                    : s.transferStatus ? `Ticket ${s.transferStatus}` : 'Ticket goes out when you tick paid'}
                  {s.nudgeCount > 0 ? ` · nudged ${s.nudgeCount}×` : ''}
                </p>
                <div className="flex gap-2 mt-3">
                  <a
                    href={smsUrl(s.phone, message(s))}
                    onClick={() => { if (!s.paid) void noteNudge(s.id).catch(() => undefined); }}
                    className="flex items-center gap-1 text-xs font-black uppercase tracking-widest border border-slate-200 rounded-lg px-3 py-2"
                  >
                    <MessageSquare className="w-4 h-4" /> {s.paid ? 'Text' : 'Text / nudge'}
                  </a>
                  <button
                    type="button"
                    onClick={() => { void navigator.clipboard?.writeText(message(s)); toast({ kind: 'info', message: 'Message copied.' }); }}
                    className="flex items-center gap-1 text-xs font-black uppercase tracking-widest border border-slate-200 rounded-lg px-3 py-2"
                  >
                    <Copy className="w-4 h-4" /> Copy
                  </button>
                </div>
              </li>
            ))}
          </ul>
        </section>
      )}

      {free.length > 0 && (
        <section>
          <h2 className={`${label} mb-3`}>{state.shares.length ? 'Add more friends' : 'Split it'}</h2>
          <div className="grid grid-cols-2 gap-3 mb-4">
            <label><span className={label}>Your Venmo</span><input className={input} value={venmo} onChange={(e) => setVenmo(e.target.value)} placeholder="@you" /></label>
            <label><span className={label}>Cash App (backup)</span><input className={input} value={cashapp} onChange={(e) => setCashapp(e.target.value)} placeholder="$you" /></label>
          </div>
          <fieldset className="mb-4 text-sm">
            <legend className={label}>Send tickets</legend>
            <label className="mr-4"><input type="radio" checked={sendMode === 'now'} onChange={() => setSendMode('now')} /> Now</label>
            <label><input type="radio" checked={sendMode === 'on_paid'} onChange={() => setSendMode('on_paid')} /> When I mark them paid</label>
          </fieldset>
          {drafts.map((d, i) => (
            <div key={i} className="border border-slate-200 rounded-2xl p-4 mb-3 grid grid-cols-2 gap-2">
              <input className={input} placeholder="Name" value={d.name} onChange={(e) => setFriends(friends.map((f, j) => (j === i ? { ...f, name: e.target.value } : f)))} />
              <input className={input} placeholder="Email (for the ticket)" type="email" value={d.email} onChange={(e) => setFriends(friends.map((f, j) => (j === i ? { ...f, email: e.target.value } : f)))} />
              <input className={input} placeholder="Phone (for your text)" type="tel" value={d.phone} onChange={(e) => setFriends(friends.map((f, j) => (j === i ? { ...f, phone: e.target.value } : f)))} />
              <div className="flex gap-2">
                <input className={input} inputMode="decimal" placeholder={((suggested[i] ?? 0) / 100).toFixed(2)} value={d.amount}
                  onChange={(e) => setFriends(friends.map((f, j) => (j === i ? { ...f, amount: e.target.value } : f)))} />
                <button type="button" aria-label="Remove" onClick={() => setFriends(friends.filter((_, j) => j !== i))}><Trash2 className="w-4 h-4 text-slate-400" /></button>
              </div>
            </div>
          ))}
          {friends.length < free.length && (
            <button type="button" onClick={() => setFriends([...friends, { name: '', email: '', phone: '', amount: '' }])}
              className="flex items-center gap-2 text-sm font-black text-brand-primary mb-4">
              <Plus className="w-4 h-4" /> Add a friend ({free.length - friends.length} ticket{free.length - friends.length === 1 ? '' : 's'} left)
            </button>
          )}
          {overTotal && <p className="text-red-600 text-xs font-bold mb-2">The shares add up to more than you paid.</p>}
          {friends.length > 0 && (
            <button type="button" disabled={saving || overTotal || !handlesOk || drafts.some((d) => !d.name.trim() || !d.email.includes('@') || !Number.isFinite(d.cents) || d.cents < 0)}
              onClick={() => void save()}
              className="w-full bg-slate-900 text-white rounded-xl py-3 font-black uppercase tracking-widest text-xs disabled:opacity-40">
              {saving ? 'Saving…' : sendMode === 'now' ? 'Send tickets' : 'Save split'}
            </button>
          )}
        </section>
      )}
    </Shell>
  );
}

function Shell({ children }: { children: ReactNode }) {
  return (
    <div className="max-w-xl mx-auto px-4 py-12">
      <Link to="/my-tickets" className="inline-flex items-center gap-2 text-slate-500 text-sm font-bold mb-6">
        <ArrowLeft className="w-4 h-4" /> My Tickets
      </Link>
      <h1 className="text-2xl font-black text-slate-900 mb-2">Split with friends</h1>
      {children}
    </div>
  );
}
