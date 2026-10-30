// /orgs/:orgId/fans — the organization's fans (mig 20261031120000, docs/fans.md).
//
//   Fans            profiles built from orders and signups; search, filter by
//                   tags, open one (consent shown read-only), add a contact by
//                   hand, export CSV (owner / manager, logged)
//   Tags            the org's tags; tag events and see which events carry one
//   Signup forms    build a form, copy its embed snippet
//   Refund requests every event's open asks: Refund runs the usual refund
//                   (exos-refund, nonce ask:<id>), Decline sends a note
//
// Roles: fans and refunds owner / manager / finance (finance reads only);
// tags also content (read); forms owner / manager. The RPCs re-check.

import { Fragment, useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { ArrowLeft, Copy, Download, Tag as TagIcon, Undo2, UserPlus, Users, X } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import { formatCents } from '../lib/refunds';
import { csvFileName, downloadCsv, toCsv } from '../lib/csv';
import { publicUrl } from '../lib/utils';
import { listOrgEvents } from '../lib/events';
import { declineRefundAsk, refundAsk } from '../lib/refundAsks';
import {
  applyTag, deleteTag, discardFan, EMAIL_LIST_LABEL, exportFans, fanName, FANS_CSV_HEADER, fansCsvRows, getFan,
  idsWithTags, listFans, listRefundQueue, listTags, removeTag, saveFan, saveTag, tagsOn,
  type FanDetail, type FanRow, type OrgTag, type QueueAsk, type TagChip, type TaggableType,
} from '../lib/fans';
import { listSignupForms, saveSignupForm, signupSnippets, type SignupForm } from '../lib/signupForms';
import type { Event } from '../types';

type Tab = 'fans' | 'tags' | 'forms' | 'refunds';

const card = 'bg-white rounded-2xl border border-slate-200 p-5';
const btn = 'inline-flex items-center gap-1.5 px-3 py-2 rounded border border-slate-200 bg-white text-xs font-bold text-slate-700 hover:bg-slate-50 disabled:opacity-50';
const btnDark = 'inline-flex items-center gap-1.5 px-3 py-2 rounded bg-slate-900 text-white text-xs font-bold disabled:opacity-50';
const field = 'w-full bg-slate-50 border border-slate-200 rounded px-3 py-2 text-sm text-slate-900';
const label = 'block text-[10px] font-black uppercase tracking-widest text-slate-400 mb-1';

const day = (d: Date | null) => (d ? d.toLocaleDateString(undefined, { dateStyle: 'medium' }) : '');

function Chip({ t, onRemove }: { t: TagChip; onRemove?: () => void }) {
  return (
    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full border text-[11px] font-bold text-slate-700 bg-slate-50"
      style={t.color ? { borderColor: t.color } : undefined}>
      {t.color && <span className="w-2 h-2 rounded-full" style={{ background: t.color }} aria-hidden="true" />}
      {t.name}
      {onRemove && (
        <button type="button" onClick={onRemove} aria-label={`Remove tag ${t.name}`} className="text-slate-400 hover:text-rose-600">
          <X size={11} />
        </button>
      )}
    </span>
  );
}

/** Add a tag to a record: pick one, or type a new name. */
function TagAdder({ tags, type, onAdd }: { tags: OrgTag[]; type: TaggableType; onAdd: (t: { id?: string; name?: string }) => Promise<void> }) {
  const [value, setValue] = useState('');
  const usable = tags.filter((t) => !t.scope || t.scope === type);
  const submit = async () => {
    const v = value.trim();
    if (!v) return;
    const hit = usable.find((t) => t.name.toLowerCase() === v.toLowerCase());
    await onAdd(hit ? { id: hit.id } : { name: v });
    setValue('');
  };
  return (
    <span className="inline-flex gap-1">
      <input list={`tags-${type}`} value={value} onChange={(e) => setValue(e.target.value)} placeholder="Add tag" maxLength={40}
        onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); void submit(); } }}
        className="w-32 bg-slate-50 border border-slate-200 rounded px-2 py-1 text-xs" aria-label="Add a tag" />
      <datalist id={`tags-${type}`}>{usable.map((t) => <option key={t.id} value={t.name} />)}</datalist>
      <button type="button" className={btn} onClick={() => void submit()}>Add</button>
    </span>
  );
}

export default function OrgFans() {
  const { orgId = '' } = useParams();
  const navigate = useNavigate();
  const { user, isAdmin } = useAuth();
  const { orgs, loading: orgsLoading } = useOrganization();
  const entry = orgs.find((o) => o.org.id === orgId);
  const role = entry?.membership.role ?? (isAdmin ? 'owner' : null);
  const canRead = role === 'owner' || role === 'manager' || role === 'finance';
  const canWrite = role === 'owner' || role === 'manager';
  const canTags = canRead || role === 'content';
  const [params, setParams] = useSearchParams();
  const tabs: { id: Tab; label: string; show: boolean }[] = [
    { id: 'fans', label: 'Fans', show: canRead },
    { id: 'tags', label: 'Tags', show: canTags },
    { id: 'forms', label: 'Signup forms', show: canWrite },
    { id: 'refunds', label: 'Refund requests', show: canRead },
  ];
  const visible = tabs.filter((t) => t.show);
  const requested = params.get('tab') as Tab | null;
  const tab: Tab = visible.find((t) => t.id === requested)?.id ?? visible[0]?.id ?? 'fans';
  const [tags, setTags] = useState<OrgTag[]>([]);
  const reloadTags = useCallback(() => {
    if (!orgId || !canTags) return;
    listTags(orgId).then(setTags).catch(() => setTags([]));
  }, [orgId, canTags]);
  useEffect(reloadTags, [reloadTags]);

  if (!user) return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 font-bold uppercase tracking-widest">Sign in required.</div>;
  if (!orgsLoading && visible.length === 0) {
    return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 text-sm">Fans are visible to the org's owners, managers and finance team.</div>;
  }

  return (
    <div className="min-h-screen bg-tm-gray text-slate-900">
      <div className="max-w-5xl mx-auto px-4 py-10">
        <button onClick={() => navigate('/dashboard')}
          className="flex items-center gap-1.5 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6">
          <ArrowLeft size={14} strokeWidth={2.5} /> Dashboard
        </button>
        <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">{entry?.org.name ?? 'Organization'}</p>
        <h1 className="text-3xl md:text-4xl font-bold tracking-tight mb-6">Fans</h1>
        <div role="tablist" className="flex flex-wrap gap-2 mb-6">
          {visible.map((t) => (
            <button key={t.id} role="tab" aria-selected={tab === t.id} type="button"
              onClick={() => setParams({ tab: t.id }, { replace: true })}
              className={`px-3 py-2 rounded text-xs font-bold ${tab === t.id ? 'bg-slate-900 text-white' : 'bg-white border border-slate-200 text-slate-600'}`}>
              {t.label}
            </button>
          ))}
        </div>
        {tab === 'fans' && <FansTab orgId={orgId} orgName={entry?.org.name ?? ''} canWrite={canWrite} tags={tags} onTagsChanged={reloadTags} />}
        {tab === 'tags' && <TagsTab orgId={orgId} canWrite={canWrite} tags={tags} onTagsChanged={reloadTags} />}
        {tab === 'forms' && <FormsTab orgId={orgId} tags={tags} />}
        {tab === 'refunds' && <RefundsTab orgId={orgId} canAct={canRead} />}
      </div>
    </div>
  );
}

// ── Fans ───────────────────────────────────────────────────────────────────

function FansTab({ orgId, orgName, canWrite, tags, onTagsChanged }: {
  orgId: string; orgName: string; canWrite: boolean; tags: OrgTag[]; onTagsChanged: () => void;
}) {
  const { toast } = useToast();
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState('');
  const [tagFilter, setTagFilter] = useState<string[]>([]);
  const [rows, setRows] = useState<FanRow[] | null>(null);
  const [total, setTotal] = useState(0);
  const [openId, setOpenId] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async (offset = 0) => {
    try {
      const r = await listFans(orgId, { search: query, tagIds: tagFilter, offset });
      setTotal(r.total);
      setRows((prev) => (offset === 0 ? r.rows : [...(prev ?? []), ...r.rows]));
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
      setRows([]);
    }
  }, [orgId, query, tagFilter, toast]);
  useEffect(() => { void load(0); }, [load]);

  const doExport = async () => {
    setBusy(true);
    try {
      const r = await exportFans(orgId, query, tagFilter);
      downloadCsv(csvFileName(['fans', orgName]), toCsv(FANS_CSV_HEADER, fansCsvRows(r.rows)));
      toast({ kind: 'success', message: `Exported ${r.count} fan${r.count === 1 ? '' : 's'}. The export is logged.` });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const fanTags = tags.filter((t) => !t.scope || t.scope === 'fan');

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <form className="flex gap-2 flex-1 min-w-[220px]" onSubmit={(e) => { e.preventDefault(); setQuery(search); }}>
          <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search email or name" maxLength={100}
            aria-label="Search fans" className={field} />
          <button type="submit" className={btn}>Search</button>
        </form>
        {canWrite && (
          <>
            <button type="button" className={btn} onClick={() => setAdding((v) => !v)}><UserPlus size={14} /> Add fan</button>
            <button type="button" className={btn} disabled={busy} onClick={() => void doExport()}><Download size={14} /> Export CSV</button>
          </>
        )}
      </div>
      {fanTags.length > 0 && (
        <div className="flex flex-wrap items-center gap-2" aria-label="Filter by tag">
          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Tags</span>
          {fanTags.map((t) => {
            const on = tagFilter.includes(t.id);
            return (
              <button key={t.id} type="button" aria-pressed={on}
                onClick={() => setTagFilter(on ? tagFilter.filter((x) => x !== t.id) : [...tagFilter, t.id])}
                className={`px-2 py-0.5 rounded-full text-[11px] font-bold border ${on ? 'bg-slate-900 text-white border-slate-900' : 'bg-white text-slate-600 border-slate-200'}`}>
                {t.name}
              </button>
            );
          })}
        </div>
      )}
      {adding && <AddFan orgId={orgId} onDone={(id) => { setAdding(false); void load(0); if (id) setOpenId(id); }} />}
      <p className="text-xs text-slate-500">
        {rows === null ? 'Loading…' : `${total} fan${total === 1 ? '' : 's'}`}. Profiles come from orders and signup forms.
        Consent is the fan's own: they join and leave lists themselves.
      </p>
      <ul className="space-y-2">
        {(rows ?? []).map((f) => (
          <li key={f.id} className={card}>
            <button type="button" className="w-full text-left flex flex-wrap items-center justify-between gap-2"
              onClick={() => setOpenId(openId === f.id ? null : f.id)} aria-expanded={openId === f.id}>
              <span className="min-w-0">
                <span className="block font-bold truncate">{fanName(f)}</span>
                <span className="block text-xs text-slate-500 truncate">
                  {f.email}{f.ordersCount ? ` · ${f.ordersCount} order${f.ordersCount === 1 ? '' : 's'}` : ''}
                  {f.lastOrderAt ? ` · last ${day(f.lastOrderAt)}` : ''}
                </span>
              </span>
              <span className="flex flex-wrap gap-1 items-center">
                {f.tags.map((t) => <Fragment key={t.id}><Chip t={t} /></Fragment>)}
                <span className="text-[10px] font-bold uppercase tracking-widest text-slate-400">{f.emailList === 'subscribed' ? 'On list' : f.emailList === 'pending' ? 'Pending' : ''}</span>
              </span>
            </button>
            {openId === f.id && (
              <FanPanel orgId={orgId} fanId={f.id} canWrite={canWrite} tags={tags}
                onChanged={() => { void load(0); onTagsChanged(); }} onRemoved={() => { setOpenId(null); void load(0); }} />
            )}
          </li>
        ))}
      </ul>
      {rows && rows.length < total && (
        <button type="button" className={btn} onClick={() => void load(rows.length)}>Load more</button>
      )}
    </div>
  );
}

function AddFan({ orgId, onDone }: { orgId: string; onDone: (id: string | null) => void }) {
  const { toast } = useToast();
  const [email, setEmail] = useState('');
  const [first, setFirst] = useState('');
  const [last, setLast] = useState('');
  const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true);
    try {
      const d = await saveFan(orgId, null, { email, first_name: first || null, last_name: last || null });
      toast({ kind: 'success', message: 'Fan added. They are on no list until they sign up themselves.' });
      onDone(d.id);
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className={`${card} grid gap-2 sm:grid-cols-4 items-end`}>
      <div><label className={label} htmlFor="af-email">Email</label><input id="af-email" className={field} type="email" value={email} onChange={(e) => setEmail(e.target.value)} /></div>
      <div><label className={label} htmlFor="af-first">First name</label><input id="af-first" className={field} maxLength={60} value={first} onChange={(e) => setFirst(e.target.value)} /></div>
      <div><label className={label} htmlFor="af-last">Last name</label><input id="af-last" className={field} maxLength={60} value={last} onChange={(e) => setLast(e.target.value)} /></div>
      <div className="flex gap-2"><button type="button" className={btnDark} disabled={busy || !email} onClick={() => void save()}>Add</button>
        <button type="button" className={btn} onClick={() => onDone(null)}>Cancel</button></div>
    </div>
  );
}

function FanPanel({ orgId, fanId, canWrite, tags, onChanged, onRemoved }: {
  orgId: string; fanId: string; canWrite: boolean; tags: OrgTag[]; onChanged: () => void; onRemoved: () => void;
}) {
  const { toast } = useToast();
  const [d, setD] = useState<FanDetail | null>(null);
  const [first, setFirst] = useState('');
  const [last, setLast] = useState('');
  const load = useCallback(() => {
    getFan(orgId, fanId).then((x) => { setD(x); setFirst(x.firstName ?? ''); setLast(x.lastName ?? ''); })
      .catch((e) => toast({ kind: 'error', message: (e as Error).message }));
  }, [orgId, fanId, toast]);
  useEffect(load, [load]);
  if (!d) return <p className="text-xs text-slate-400 mt-3">Loading…</p>;
  const c = d.consent;
  const act = async (fn: () => Promise<unknown>, ok: string) => {
    try { await fn(); toast({ kind: 'success', message: ok }); load(); onChanged(); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  };
  return (
    <div className="mt-4 grid gap-4 md:grid-cols-2 text-sm">
      <div className="space-y-3">
        <div>
          <p className={label}>Contact</p>
          {canWrite ? (
            <div className="flex gap-2">
              <input className={field} aria-label="First name" maxLength={60} value={first} onChange={(e) => setFirst(e.target.value)} />
              <input className={field} aria-label="Last name" maxLength={60} value={last} onChange={(e) => setLast(e.target.value)} />
              <button type="button" className={btn} onClick={() => void act(() => saveFan(orgId, fanId, { first_name: first || null, last_name: last || null }), 'Saved.')}>Save</button>
            </div>
          ) : <p>{fanName(d)}</p>}
          <p className="text-xs text-slate-500 mt-1">{d.email} · {d.hasAccount ? 'has an Exos account' : 'no Exos account'} · from {d.source}</p>
        </div>
        <div>
          <p className={label}>Consent (set by the fan)</p>
          <ul className="text-xs text-slate-600 space-y-0.5">
            <li>Email list: {EMAIL_LIST_LABEL[c.emailList.status]}{c.emailList.since ? ` since ${day(c.emailList.since)}` : ''}</li>
            <li>Follows {d.hasAccount ? (c.followsOrg ? 'you: yes' : 'you: no') : 'you: needs an account'}</li>
            <li>Ads choice at checkout: {c.adConsent === 'granted' ? 'yes' : c.adConsent === 'denied' ? 'no' : 'not asked'}</li>
            <li>Texts: {c.sms.status === 'subscribed' ? `on (${c.sms.phoneHint})` : c.sms.status === 'opted_out' ? 'stopped' : 'off'}</li>
            {c.marketingMailOptOut && <li>Turned off all follow-up emails on Exos</li>}
          </ul>
        </div>
        <div>
          <p className={label}>Tags</p>
          <div className="flex flex-wrap gap-1 items-center">
            {d.tags.map((t) => (
              <Fragment key={t.id}><Chip t={t} onRemove={canWrite && t.taggedItemId ? () => void act(() => removeTag(orgId, t.taggedItemId!), 'Tag removed.') : undefined} /></Fragment>
            ))}
            {canWrite && <TagAdder tags={tags} type="fan" onAdd={(t) => act(() => applyTag(orgId, 'fan', fanId, t), 'Tagged.')} />}
          </div>
        </div>
        {canWrite && (
          <button type="button" className="text-xs text-rose-600 hover:underline" onClick={() => {
            if (!window.confirm('Remove this contact? Orders stay; a new order or signup brings it back.')) return;
            void discardFan(orgId, fanId).then(() => { toast({ kind: 'success', message: 'Removed.' }); onRemoved(); })
              .catch((e) => toast({ kind: 'error', message: (e as Error).message }));
          }}>Remove contact</button>
        )}
      </div>
      <div className="space-y-3">
        <div>
          <p className={label}>Orders</p>
          <p className="text-xs text-slate-600">
            {d.stats.orders} order{d.stats.orders === 1 ? '' : 's'}, {d.stats.tickets} ticket{d.stats.tickets === 1 ? '' : 's'}
            {d.stats.money.map((m) => ` · ${formatCents(m.paidCents - m.refundedCents, m.currency)} net`).join('')}
          </p>
          <ul className="mt-1 divide-y divide-slate-100 text-xs">
            {d.orders.map((o) => (
              <li key={o.sessionId} className="py-1 flex justify-between gap-2">
                <span className="truncate">{o.eventName} · {o.quantity}×</span>
                <span className="text-slate-500 shrink-0">{formatCents(o.amountCents, o.currency)}{o.status !== 'fulfilled' ? ` · ${o.status.replace('_', ' ')}` : ''}</span>
              </li>
            ))}
          </ul>
        </div>
        {d.signups.length > 0 && (
          <div>
            <p className={label}>Signups</p>
            <ul className="text-xs text-slate-600">
              {d.signups.map((s, i) => (
                <li key={i}>{s.formName} · {day(s.createdAt)} · {s.confirmedAt ? 'confirmed' : 'not confirmed'}{s.smsRequested ? (s.smsConfirmedAt ? ' · texts on' : ' · texts asked') : ''}</li>
              ))}
            </ul>
          </div>
        )}
      </div>
    </div>
  );
}

// ── Tags ───────────────────────────────────────────────────────────────────

function TagsTab({ orgId, canWrite, tags, onTagsChanged }: { orgId: string; canWrite: boolean; tags: OrgTag[]; onTagsChanged: () => void }) {
  const { toast } = useToast();
  const [name, setName] = useState('');
  const [scope, setScope] = useState<TaggableType | ''>('');
  const [color, setColor] = useState('#64748b');
  const [events, setEvents] = useState<Event[]>([]);
  const [eventTags, setEventTags] = useState<Record<string, TagChip[]>>({});
  const [filter, setFilter] = useState<string[]>([]);
  const [matching, setMatching] = useState<Set<string> | null>(null);

  const loadEvents = useCallback(async () => {
    const evs = await listOrgEvents(orgId).catch(() => [] as Event[]);
    setEvents(evs);
    setEventTags(await tagsOn(orgId, 'event', evs.slice(0, 1000).map((e) => e.id)).catch(() => ({})));
  }, [orgId]);
  useEffect(() => { void loadEvents(); }, [loadEvents]);
  useEffect(() => {
    let alive = true;
    idsWithTags(orgId, 'event', filter).then((s) => { if (alive) setMatching(s); }).catch(() => { if (alive) setMatching(null); });
    return () => { alive = false; };
  }, [orgId, filter, eventTags]);

  const run = async (fn: () => Promise<unknown>, ok: string) => {
    try { await fn(); toast({ kind: 'success', message: ok }); onTagsChanged(); void loadEvents(); } catch (e) { toast({ kind: 'error', message: (e as Error).message }); }
  };
  const shown = matching ? events.filter((e) => matching.has(e.id)) : events;

  return (
    <div className="space-y-4">
      {canWrite && (
        <div className={`${card} grid gap-2 sm:grid-cols-4 items-end`}>
          <div><label className={label} htmlFor="tg-name">New tag</label><input id="tg-name" className={field} maxLength={40} value={name} onChange={(e) => setName(e.target.value)} /></div>
          <div><label className={label} htmlFor="tg-scope">For</label>
            <select id="tg-scope" className={field} value={scope} onChange={(e) => setScope(e.target.value as TaggableType | '')}>
              <option value="">Anything</option><option value="event">Events</option><option value="fan">Fans</option><option value="artist">Artists</option>
            </select></div>
          <div><label className={label} htmlFor="tg-color">Color</label><input id="tg-color" type="color" className="h-9 w-16" value={color} onChange={(e) => setColor(e.target.value)} /></div>
          <button type="button" className={btnDark} disabled={!name.trim()}
            onClick={() => void run(() => saveTag(orgId, null, { name: name.trim(), scope: scope || null, color }), 'Tag created.').then(() => setName(''))}>
            <TagIcon size={14} /> Create
          </button>
        </div>
      )}
      <ul className="grid gap-2 sm:grid-cols-2">
        {tags.map((t) => (
          <li key={t.id} className={`${card} flex items-center justify-between gap-2`}>
            <span><Chip t={t} /> <span className="text-xs text-slate-500">{t.scope ? `${t.scope}s` : 'anything'} · on {t.itemsCount}</span></span>
            {canWrite && (
              <span className="flex gap-2">
                <button type="button" className="text-xs text-slate-500 hover:underline" onClick={() => {
                  const n = window.prompt('Rename tag', t.name);
                  if (n && n.trim() && n.trim() !== t.name) void run(() => saveTag(orgId, t.id, { name: n.trim() }), 'Renamed.');
                }}>Rename</button>
                <button type="button" className="text-xs text-rose-600 hover:underline" onClick={() => {
                  if (window.confirm(`Delete "${t.name}"? It comes off ${t.itemsCount} record${t.itemsCount === 1 ? '' : 's'}.`)) void run(() => deleteTag(orgId, t.id), 'Deleted.');
                }}>Delete</button>
              </span>
            )}
          </li>
        ))}
        {tags.length === 0 && <li className="text-xs text-slate-400">No tags yet.</li>}
      </ul>
      <div className={card}>
        <div className="flex flex-wrap items-center gap-2 mb-3">
          <h2 className="text-sm font-bold">Events</h2>
          {tags.filter((t) => !t.scope || t.scope === 'event').map((t) => {
            const on = filter.includes(t.id);
            return (
              <button key={t.id} type="button" aria-pressed={on} onClick={() => setFilter(on ? filter.filter((x) => x !== t.id) : [...filter, t.id])}
                className={`px-2 py-0.5 rounded-full text-[11px] font-bold border ${on ? 'bg-slate-900 text-white border-slate-900' : 'bg-white text-slate-600 border-slate-200'}`}>
                {t.name}
              </button>
            );
          })}
        </div>
        <ul className="divide-y divide-slate-100">
          {shown.map((e) => (
            <li key={e.id} className="py-2 flex flex-wrap items-center justify-between gap-2 text-sm">
              <span className="min-w-0 truncate">{e.title}</span>
              <span className="flex flex-wrap items-center gap-1">
                {(eventTags[e.id] ?? []).map((t) => (
                  <Fragment key={t.id}><Chip t={t} onRemove={canWrite && t.taggedItemId ? () => void run(() => removeTag(orgId, t.taggedItemId!), 'Tag removed.') : undefined} /></Fragment>
                ))}
                {canWrite && <TagAdder tags={tags} type="event" onAdd={(t) => run(() => applyTag(orgId, 'event', e.id, t), 'Tagged.')} />}
              </span>
            </li>
          ))}
          {shown.length === 0 && <li className="py-2 text-xs text-slate-400">No events{filter.length ? ' with these tags' : ''}.</li>}
        </ul>
      </div>
    </div>
  );
}

// ── Signup forms ───────────────────────────────────────────────────────────

const EMPTY_FORM = { name: '', title: '', intro: '', button_label: '', ask_name: true, offer_sms: false, default_tag_ids: [] as string[], status: 'active' };

function FormsTab({ orgId, tags }: { orgId: string; tags: OrgTag[] }) {
  const { toast } = useToast();
  const [forms, setForms] = useState<SignupForm[] | null>(null);
  const [editing, setEditing] = useState<string | 'new' | null>(null);
  const [draft, setDraft] = useState(EMPTY_FORM);
  const load = useCallback(() => {
    listSignupForms(orgId).then(setForms).catch((e) => { toast({ kind: 'error', message: (e as Error).message }); setForms([]); });
  }, [orgId, toast]);
  useEffect(load, [load]);
  const appBase = useMemo(() => publicUrl('/').replace(/\/+$/, ''), []);

  const edit = (f: SignupForm | null) => {
    setEditing(f ? f.id : 'new');
    setDraft(f ? {
      name: f.name, title: f.title, intro: f.intro ?? '', button_label: f.buttonLabel ?? '', ask_name: f.askName,
      offer_sms: f.offerSms, default_tag_ids: f.defaultTagIds, status: f.status,
    } : EMPTY_FORM);
  };
  const save = async () => {
    try {
      await saveSignupForm(orgId, editing === 'new' ? null : editing, draft);
      toast({ kind: 'success', message: 'Form saved.' });
      setEditing(null);
      load();
    } catch (e) {
      toast({ kind: 'error', message: (e as Error).message });
    }
  };
  const copy = async (text: string) => {
    try { await navigator.clipboard.writeText(text); toast({ kind: 'success', message: 'Copied.' }); }
    catch { toast({ kind: 'error', message: 'Could not copy; select the text and copy it.' }); }
  };
  const fanTags = tags.filter((t) => !t.scope || t.scope === 'fan');

  return (
    <div className="space-y-4">
      <p className="text-xs text-slate-500 max-w-prose">
        Put a form on your site and fans join your email list. Every signup gets a confirm email first (double opt-in);
        texts, when offered, use the same consent words as the ticket page and are turned on by the fan, signed in.
      </p>
      <button type="button" className={btnDark} onClick={() => edit(null)}><Users size={14} /> New form</button>
      {editing && (
        <div className={`${card} grid gap-3 sm:grid-cols-2`}>
          <div><label className={label} htmlFor="sf-name">Name (for you)</label><input id="sf-name" className={field} maxLength={80} value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} /></div>
          <div><label className={label} htmlFor="sf-title">Title (fans see it)</label><input id="sf-title" className={field} maxLength={120} value={draft.title} onChange={(e) => setDraft({ ...draft, title: e.target.value })} /></div>
          <div className="sm:col-span-2"><label className={label} htmlFor="sf-intro">Intro</label><textarea id="sf-intro" className={field} rows={2} maxLength={500} value={draft.intro} onChange={(e) => setDraft({ ...draft, intro: e.target.value })} /></div>
          <div><label className={label} htmlFor="sf-btn">Button</label><input id="sf-btn" className={field} maxLength={40} placeholder="Sign up" value={draft.button_label} onChange={(e) => setDraft({ ...draft, button_label: e.target.value })} /></div>
          <div><label className={label} htmlFor="sf-status">Status</label>
            <select id="sf-status" className={field} value={draft.status} onChange={(e) => setDraft({ ...draft, status: e.target.value })}>
              <option value="active">Taking signups</option><option value="paused">Paused</option><option value="archived">Archived</option>
            </select></div>
          <label className="text-sm flex items-center gap-2"><input type="checkbox" checked={draft.ask_name} onChange={(e) => setDraft({ ...draft, ask_name: e.target.checked })} /> Ask for a name</label>
          <label className="text-sm flex items-center gap-2"><input type="checkbox" checked={draft.offer_sms} onChange={(e) => setDraft({ ...draft, offer_sms: e.target.checked })} /> Offer texts</label>
          {fanTags.length > 0 && (
            <div className="sm:col-span-2">
              <p className={label}>Tag new signups</p>
              <div className="flex flex-wrap gap-2">
                {fanTags.map((t) => {
                  const on = draft.default_tag_ids.includes(t.id);
                  return (
                    <label key={t.id} className="text-xs flex items-center gap-1">
                      <input type="checkbox" checked={on} onChange={() => setDraft({
                        ...draft, default_tag_ids: on ? draft.default_tag_ids.filter((x) => x !== t.id) : [...draft.default_tag_ids, t.id],
                      })} /> {t.name}
                    </label>
                  );
                })}
              </div>
            </div>
          )}
          <div className="flex gap-2"><button type="button" className={btnDark} onClick={() => void save()}>Save</button>
            <button type="button" className={btn} onClick={() => setEditing(null)}>Cancel</button></div>
        </div>
      )}
      <ul className="space-y-3">
        {(forms ?? []).map((f) => {
          const s = signupSnippets(appBase, f.id, f.name);
          return (
            <li key={f.id} className={card}>
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span><span className="font-bold">{f.name}</span> <span className="text-xs text-slate-500">· {f.title} · {f.status}</span></span>
                <span className="text-xs text-slate-500">{f.submissions} signups, {f.confirmed} confirmed
                  <button type="button" className="ml-3 underline" onClick={() => edit(f)}>Edit</button></span>
              </div>
              <p className={`${label} mt-3`}>Embed snippet</p>
              <pre className="bg-slate-50 border border-slate-200 rounded p-3 text-[11px] whitespace-pre-wrap break-all">{s.script}</pre>
              <div className="flex flex-wrap gap-2 mt-2">
                <button type="button" className={btn} onClick={() => void copy(s.script)}><Copy size={12} /> Copy snippet</button>
                <button type="button" className={btn} onClick={() => void copy(s.iframe)}><Copy size={12} /> Copy plain iframe</button>
                <a className={btn} href={s.link} target="_blank" rel="noopener noreferrer">Preview</a>
              </div>
            </li>
          );
        })}
        {forms?.length === 0 && <li className="text-xs text-slate-400">No forms yet.</li>}
      </ul>
    </div>
  );
}

// ── Refund requests ────────────────────────────────────────────────────────

function RefundsTab({ orgId, canAct }: { orgId: string; canAct: boolean }) {
  const { toast } = useToast();
  const [status, setStatus] = useState<QueueAsk['status'] | 'all'>('open');
  const [rows, setRows] = useState<QueueAsk[] | null>(null);
  const [total, setTotal] = useState(0);
  const [busy, setBusy] = useState<string | null>(null);
  const [declining, setDeclining] = useState<string | null>(null);
  const [note, setNote] = useState('');
  const load = useCallback((offset = 0) => {
    listRefundQueue(orgId, status === 'all' ? null : status, offset)
      .then((r) => { setTotal(r.total); setRows((prev) => (offset === 0 ? r.rows : [...(prev ?? []), ...r.rows])); })
      .catch((e) => { toast({ kind: 'error', message: (e as Error).message }); setRows([]); });
  }, [orgId, status, toast]);
  useEffect(() => load(0), [load]);

  const refund = async (a: QueueAsk) => {
    if (!window.confirm(`Refund ${formatCents(a.amountCents, a.currency)} to ${a.buyerEmail || 'the buyer'}? The ticket stops working.`)) return;
    setBusy(a.askId);
    try {
      const out = await refundAsk(a);
      if (out.status === 'succeeded' || out.status === 'pending') toast({ kind: 'success', message: `Refunded ${formatCents(out.amountCents ?? a.amountCents, a.currency)}.` });
      else toast({ kind: 'error', message: out.error || 'Stripe didn\'t confirm the refund. Try again; it won\'t refund twice.' });
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'Refund failed.' });
    } finally {
      setBusy(null);
      load(0);
    }
  };
  const decline = async (a: QueueAsk) => {
    setBusy(a.askId);
    try {
      await declineRefundAsk(a.askId, note);
      toast({ kind: 'success', message: 'Declined. The buyer sees your note on their ticket.' });
      setDeclining(null);
      setNote('');
    } catch (e) {
      toast({ kind: 'error', message: (e as Error)?.message || 'Not saved.' });
    } finally {
      setBusy(null);
      load(0);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <Undo2 size={16} className="text-slate-500" aria-hidden="true" />
        <select aria-label="Status" className="bg-white border border-slate-200 rounded px-2 py-1.5 text-xs" value={status}
          onChange={(e) => setStatus(e.target.value as QueueAsk['status'] | 'all')}>
          <option value="open">Open</option><option value="refunded">Refunded</option><option value="declined">Declined</option>
          <option value="withdrawn">Withdrawn</option><option value="all">All</option>
        </select>
        <span className="text-xs text-slate-500">{rows === null ? 'Loading…' : `${total} request${total === 1 ? '' : 's'}`}.
          Buyers ask from their ticket within your refund policy; nothing is refunded until you say so.</span>
      </div>
      <ul className="space-y-3">
        {(rows ?? []).map((a) => (
          <li key={a.askId} className={card}>
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <span className="text-sm font-bold">{a.eventName} · {a.tierName}</span>
              <span className="text-sm font-bold">{formatCents(a.amountCents, a.currency)}</span>
            </div>
            <p className="text-[11px] text-slate-400 mt-0.5">
              {a.buyerEmail || 'Buyer'} · asked {day(a.createdAt)}
              {a.checkedIn ? ' · already scanned in' : a.ticketStatus !== 'active' ? ` · ticket ${a.ticketStatus}` : ''}
              {a.status !== 'open' ? ` · ${a.status}` : ''}
            </p>
            {a.reason && <p className="text-xs text-slate-600 mt-2">“{a.reason}”</p>}
            {a.declineNote && <p className="text-xs text-slate-500 mt-1">Your note: {a.declineNote}</p>}
            {a.status === 'open' && canAct && (declining === a.askId ? (
              <div className="mt-3 space-y-2">
                <label className={label} htmlFor={`qd-${a.askId}`}>Note to the buyer (optional)</label>
                <textarea id={`qd-${a.askId}`} className={field} rows={2} maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} />
                <div className="flex gap-2">
                  <button type="button" className={btnDark} disabled={busy === a.askId} onClick={() => void decline(a)}>Decline</button>
                  <button type="button" className={btn} onClick={() => { setDeclining(null); setNote(''); }}>Back</button>
                </div>
              </div>
            ) : (
              <div className="mt-3 flex gap-2">
                <button type="button" className={btnDark} disabled={busy === a.askId || a.checkedIn || a.ticketStatus !== 'active'} onClick={() => void refund(a)}>
                  {busy === a.askId ? 'Refunding…' : 'Refund'}
                </button>
                <button type="button" className={btn} disabled={busy === a.askId} onClick={() => setDeclining(a.askId)}>Decline</button>
              </div>
            ))}
          </li>
        ))}
      </ul>
      {rows && rows.length < total && <button type="button" className={btn} onClick={() => load(rows.length)}>Load more</button>}
    </div>
  );
}
