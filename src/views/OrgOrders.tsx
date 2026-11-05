// /orgs/:orgId/orders — the organization's orders (mig 20261102140000).
//
//   Orders           every order: search, filter by event and status, sort by
//                    any column, paged. Row actions: edit the buyer's details
//                    and the attendee names, resend the receipt, check the
//                    whole order out at the door, see its edit history
//   Edit history     every change made here or through the API
//   Recommendations  for one event: similar public events, and fans of the
//                    org to invite (on the email list, no ticket yet)
//   Guest preview    paste names for an event's guest list and see what an
//                    import would do, without adding anyone
//   Settings         (owner) receipts to another address; resends an hour
//
// Roles (src/lib/orderDesk.ts orderPermissions): owner / manager do
// everything; finance reads orders and recommendations; the RPCs re-check.

import { Fragment, useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { ArrowDown, ArrowLeft, ArrowUp, History, LogOut, Mail, Pencil, Printer } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import { listOrgEvents } from '../lib/events';
import { listGuestLists, type GuestList } from '../lib/guestListsApi';
import {
  buyerLabel, checkOutSummary, DEFAULT_ORDER_TABLE, describeEdit, filterPreviewRows, formatOrderAmount, orderActions,
  orderPermissions, ORDER_SORTS, ORDER_STATUSES, pageCount, pageRangeLabel, parsePastedNames, previewStatusText,
  statusLabel, toggleSort, withFilter,
  type OrderEditRow, type OrderPermissions, type OrderRow, type OrderSort, type OrderTableState, type PreviewResultRow,
  type PreviewStatus,
} from '../lib/orderDesk';
import {
  checkOutOrder, fanRecommendations, getOrderSettings, listOrderEdits, listOrders, orderTickets, previewGuestList,
  printOrder, saveOrderSettings, sendReceipt, similarEvents, updateOrder, updateTicketAttendee,
  type OrderSettings, type OrderTicket,
} from '../lib/orderDeskApi';
import {
  viewRecEvents, viewRecFans, type RecEvent, type RecEventFilter, type RecEventSort, type RecFan, type RecFanSort,
} from '../lib/recommendations';
import { canPrintOrder, printSummary, printWarning } from '../lib/printOrder';
import type { Event } from '../types';
import OrderProofQueue from '../components/OrderProofQueue';

type Tab = 'orders' | 'history' | 'recs' | 'preview' | 'settings';

const card = 'bg-white rounded-2xl border border-slate-200 p-5';
const btn = 'inline-flex items-center gap-1.5 px-3 py-2 rounded border border-slate-200 bg-white text-xs font-bold text-slate-700 hover:bg-slate-50 disabled:opacity-50';
const btnDark = 'inline-flex items-center gap-1.5 px-3 py-2 rounded bg-slate-900 text-white text-xs font-bold disabled:opacity-50';
const field = 'w-full bg-slate-50 border border-slate-200 rounded px-3 py-2 text-sm text-slate-900';
const label = 'block text-[10px] font-black uppercase tracking-widest text-slate-400 mb-1';
const th = 'p-3 text-left text-[10px] uppercase tracking-widest text-slate-400 font-black';
const REC_PAGE = 25;

const when = (d: Date | string | null) => (d ? new Date(d).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '');
const err = (e: unknown) => (e as Error).message || 'Something went wrong.';

function Pager({ page, perPage, total, onPage }: { page: number; perPage: number; total: number; onPage: (p: number) => void }) {
  const pages = pageCount(total, perPage);
  return (
    <div className="flex items-center justify-between gap-2 text-xs text-slate-500 mt-3">
      <span>{pageRangeLabel(page, perPage, total)}</span>
      <span className="flex gap-2">
        <button type="button" className={btn} disabled={page <= 1} onClick={() => onPage(page - 1)}>Previous</button>
        <button type="button" className={btn} disabled={page >= pages} onClick={() => onPage(page + 1)}>Next</button>
      </span>
    </div>
  );
}

export default function OrgOrders() {
  const { orgId = '' } = useParams();
  const { user, isAdmin } = useAuth();
  const { orgs, loading } = useOrganization();
  const entry = orgs.find((o) => o.org.id === orgId);
  const perm = orderPermissions(entry?.membership.role ?? null, isAdmin);
  const [params, setParams] = useSearchParams();
  const [events, setEvents] = useState<Event[]>([]);
  useEffect(() => {
    if (orgId && perm.read) listOrgEvents(orgId).then(setEvents).catch(() => setEvents([]));
  }, [orgId, perm.read]);

  const tabs: { id: Tab; label: string; show: boolean }[] = [
    { id: 'orders', label: 'Orders', show: perm.read },
    { id: 'history', label: 'Edit history', show: perm.history },
    { id: 'recs', label: 'Recommendations', show: perm.read },
    { id: 'preview', label: 'Guest preview', show: perm.edit },
    { id: 'settings', label: 'Settings', show: perm.receiptRules },
  ];
  const visible = tabs.filter((t) => t.show);
  const tab: Tab = visible.find((t) => t.id === params.get('tab'))?.id ?? visible[0]?.id ?? 'orders';

  if (!user) return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 font-bold uppercase tracking-widest">Sign in required.</div>;
  if (!loading && !perm.read) {
    return <div className="min-h-screen bg-tm-gray text-slate-500 text-center py-24 text-sm">Orders are visible to the org's owners, managers and finance team.</div>;
  }
  return (
    <div className="min-h-screen bg-tm-gray text-slate-900">
      <div className="max-w-6xl mx-auto px-4 py-10">
        <Link to="/dashboard" className="flex items-center gap-1.5 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6">
          <ArrowLeft size={14} strokeWidth={2.5} /> Dashboard
        </Link>
        <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">{entry?.org.name ?? 'Organization'}</p>
        <h1 className="text-3xl md:text-4xl font-bold tracking-tight mb-6">Orders</h1>
        <div role="tablist" className="flex flex-wrap gap-2 mb-6">
          {visible.map((t) => (
            <button key={t.id} role="tab" aria-selected={tab === t.id} type="button" onClick={() => setParams({ tab: t.id }, { replace: true })}
              className={`px-3 py-2 rounded text-xs font-bold ${tab === t.id ? 'bg-slate-900 text-white' : 'bg-white border border-slate-200 text-slate-600'}`}>
              {t.label}
            </button>
          ))}
        </div>
        {tab === 'orders' && <OrdersTab orgId={orgId} events={events} perm={perm} />}
        {tab === 'history' && perm.history && <HistoryTab orgId={orgId} sessionId={null} />}
        {tab === 'recs' && <RecsTab events={events} />}
        {tab === 'preview' && perm.edit && <PreviewTab events={events} />}
        {tab === 'settings' && perm.receiptRules && <SettingsTab orgId={orgId} />}
      </div>
    </div>
  );
}

// ── Orders ───────────────────────────────────────────────────────────────────

function SortHead({ col, s, onSort, children }: { col: OrderSort; s: OrderTableState; onSort: (c: OrderSort) => void; children: string }) {
  const on = s.sort === col;
  return (
    <th className={th} aria-sort={on ? (s.desc ? 'descending' : 'ascending') : 'none'}>
      <button type="button" className="inline-flex items-center gap-1 uppercase" onClick={() => onSort(col)}>
        {children}{on && (s.desc ? <ArrowDown size={11} /> : <ArrowUp size={11} />)}
      </button>
    </th>
  );
}

function OrdersTab({ orgId, events, perm }: { orgId: string; events: Event[]; perm: OrderPermissions }) {
  const { toast } = useToast();
  const [s, setS] = useState<OrderTableState>(DEFAULT_ORDER_TABLE);
  const [search, setSearch] = useState('');
  const [rows, setRows] = useState<OrderRow[] | null>(null);
  const [total, setTotal] = useState(0);
  const [open, setOpen] = useState<{ id: string; kind: 'edit' | 'receipt' | 'history' } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [settings, setSettings] = useState<OrderSettings | null>(null);

  const load = useCallback(async () => {
    try {
      const r = await listOrders(orgId, s);
      setRows(r.rows);
      setTotal(r.total);
    } catch (e) {
      toast({ kind: 'error', message: err(e) });
      setRows([]);
    }
  }, [orgId, s, toast]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    if (perm.resend) getOrderSettings(orgId).then(setSettings).catch(() => setSettings(null));
  }, [orgId, perm.resend]);

  // Paper tickets (mig 20261105120000): one-time print codes, saved as a PDF.
  const print = async (o: OrderRow) => {
    if (!window.confirm(printWarning(buyerLabel(o)))) return;
    setBusy(o.sessionId);
    try {
      const r = await printOrder(o.sessionId);
      if (r.printed) {
        const url = URL.createObjectURL(new Blob([r.pdf as BlobPart], { type: 'application/pdf' }));
        const a = document.createElement('a');
        a.href = url;
        a.download = `tickets-${o.sessionId.slice(-12)}.pdf`;
        a.click();
        setTimeout(() => URL.revokeObjectURL(url), 60_000);
      }
      toast({ kind: r.printed ? 'success' : 'error', message: printSummary(r) });
    } catch (e) {
      toast({ kind: 'error', message: err(e) });
    } finally {
      setBusy(null);
    }
  };

  const checkOut = async (o: OrderRow) => {
    if (!window.confirm(`Check out every ticket on ${buyerLabel(o)}'s order that is inside? They can come back in on a re-entry list.`)) return;
    setBusy(o.sessionId);
    try {
      toast({ kind: 'success', message: checkOutSummary(await checkOutOrder(o.sessionId, null)) });
      void load();
    } catch (e) {
      toast({ kind: 'error', message: err(e) });
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2">
        <form className="flex gap-2 flex-1 min-w-[220px]" onSubmit={(e) => { e.preventDefault(); setS(withFilter(s, { search })); }}>
          <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search email, name or order id" maxLength={100}
            aria-label="Search orders" className={field} />
          <button type="submit" className={btn}>Search</button>
        </form>
        <select aria-label="Event" className={`${field} w-auto`} value={s.eventId} onChange={(e) => setS(withFilter(s, { eventId: e.target.value }))}>
          <option value="">All events</option>
          {events.map((ev) => <option key={ev.id} value={ev.id}>{ev.title}</option>)}
        </select>
        <select aria-label="Status" className={`${field} w-auto`} value={s.status}
          onChange={(e) => setS(withFilter(s, { status: e.target.value as OrderTableState['status'] }))}>
          <option value="">Any status</option>
          {ORDER_STATUSES.map((x) => <option key={x} value={x}>{statusLabel(x)}</option>)}
        </select>
      </div>
      {s.eventId && perm.edit && <OrderProofQueue eventId={s.eventId} />}
      <div className="bg-white border border-slate-200 rounded-2xl overflow-x-auto">
        <table className="w-full text-sm">
          <thead><tr>
            {ORDER_SORTS.map((c) => <Fragment key={c.id}><SortHead col={c.id} s={s} onSort={(col) => setS(toggleSort(s, col))}>{c.label}</SortHead></Fragment>)}
            <th className={th}>Tickets</th>
            <th className={th}><span className="sr-only">Actions</span></th>
          </tr></thead>
          <tbody>
            {(rows ?? []).map((o) => {
              const actions = orderActions(o, perm);
              return (
                <Fragment key={o.sessionId}><OrderRowView o={o} actions={actions} busy={busy === o.sessionId} open={open?.id === o.sessionId ? open.kind : null}
                  onOpen={(kind) => setOpen(open?.id === o.sessionId && open.kind === kind ? null : { id: o.sessionId, kind })}
                  onCheckOut={() => void checkOut(o)} orgId={orgId} settings={settings} onChanged={() => void load()}
                  onPrint={canPrintOrder(o, perm.edit) ? () => void print(o) : undefined} /></Fragment>
              );
            })}
            {rows !== null && rows.length === 0 && <tr><td colSpan={7} className="p-6 text-center text-slate-400">No orders match.</td></tr>}
            {rows === null && <tr><td colSpan={7} className="p-6 text-center text-slate-400">Loading…</td></tr>}
          </tbody>
        </table>
      </div>
      <Pager page={s.page} perPage={s.perPage} total={total} onPage={(page) => setS({ ...s, page })} />
    </div>
  );
}

function OrderRowView({ o, actions, busy, open, onOpen, onCheckOut, orgId, settings, onChanged, onPrint }: {
  o: OrderRow; actions: ReturnType<typeof orderActions>; busy: boolean; open: 'edit' | 'receipt' | 'history' | null;
  onOpen: (k: 'edit' | 'receipt' | 'history') => void; onCheckOut: () => void; orgId: string; settings: OrderSettings | null;
  onChanged: () => void; onPrint?: () => void;
}) {
  return (
    <>
      <tr className="border-t border-slate-100 align-top">
        <td className="p-3 whitespace-nowrap">{o.createdAt?.toLocaleDateString()}</td>
        <td className="p-3">{o.eventName}</td>
        <td className="p-3"><span className="font-bold">{buyerLabel(o)}</span>{o.email && <span className="block text-xs text-slate-500">{o.email}</span>}</td>
        <td className="p-3 whitespace-nowrap">{formatOrderAmount(o.amountCents, o.currency)}</td>
        <td className="p-3 whitespace-nowrap">{statusLabel(o.status)}</td>
        <td className="p-3">{o.quantity}</td>
        <td className="p-3">
          <span className="flex flex-wrap gap-1 justify-end">
            {actions.includes('edit') && <button type="button" className={btn} aria-expanded={open === 'edit'} onClick={() => onOpen('edit')}><Pencil size={12} /> Edit</button>}
            {actions.includes('receipt') && <button type="button" className={btn} aria-expanded={open === 'receipt'} onClick={() => onOpen('receipt')}><Mail size={12} /> Receipt</button>}
            {actions.includes('check_out') && <button type="button" className={btn} disabled={busy} onClick={onCheckOut}><LogOut size={12} /> Check out</button>}
            {onPrint && <button type="button" className={btn} disabled={busy} onClick={onPrint}><Printer size={12} /> Print</button>}
            {actions.includes('history') && <button type="button" className={btn} aria-expanded={open === 'history'} onClick={() => onOpen('history')}><History size={12} /> History</button>}
          </span>
        </td>
      </tr>
      {open && (
        <tr className="bg-slate-50"><td colSpan={7} className="p-4">
          {open === 'edit' && <EditOrder o={o} onSaved={onChanged} />}
          {open === 'receipt' && <ResendReceipt o={o} settings={settings} onSent={onChanged} />}
          {open === 'history' && <HistoryTab orgId={orgId} sessionId={o.sessionId} />}
        </td></tr>
      )}
    </>
  );
}

function EditOrder({ o, onSaved }: { o: OrderRow; onSaved: () => void }) {
  const { toast } = useToast();
  const [f, setF] = useState({ first_name: o.firstName ?? '', last_name: o.lastName ?? '', email: o.email ?? '', phone_number: o.phone ?? '', notes: o.notes ?? '' });
  const [tickets, setTickets] = useState<OrderTicket[] | null>(null);
  const [names, setNames] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    orderTickets(o.sessionId).then((t) => { setTickets(t); setNames(Object.fromEntries(t.map((x) => [x.id, x.attendeeName ?? '']))); })
      .catch(() => setTickets([]));
  }, [o.sessionId]);
  const save = async () => {
    setBusy(true);
    try {
      const changed = Object.fromEntries((Object.entries(f) as [string, string][]).filter(([k, v]) => {
        const was = { first_name: o.firstName, last_name: o.lastName, email: o.email, phone_number: o.phone, notes: o.notes }[k] ?? '';
        return v.trim() !== (was ?? '');
      }).map(([k, v]) => [k, v.trim() || null]));
      if (Object.keys(changed).length) await updateOrder(o.sessionId, changed);
      for (const t of tickets ?? []) {
        if ((names[t.id] ?? '').trim() !== (t.attendeeName ?? '')) await updateTicketAttendee(t.id, names[t.id].trim() || null);
      }
      toast({ kind: 'success', message: 'Saved. Prices, tickets and their holders stay as they were.' });
      onSaved();
    } catch (e) {
      toast({ kind: 'error', message: err(e) });
    } finally {
      setBusy(false);
    }
  };
  const input = (k: 'first_name' | 'last_name' | 'email' | 'phone_number', l: string, type = 'text', max = 60) => (
    <div><label className={label} htmlFor={`oe-${o.sessionId}-${k}`}>{l}</label>
      <input id={`oe-${o.sessionId}-${k}`} className={field} type={type} maxLength={max} value={f[k]} onChange={(e) => setF({ ...f, [k]: e.target.value })} /></div>
  );
  return (
    <div className="space-y-3">
      <div className="grid gap-2 sm:grid-cols-4">
        {input('first_name', 'First name')}{input('last_name', 'Last name')}{input('email', 'Email', 'email', 254)}{input('phone_number', 'Phone', 'tel', 32)}
      </div>
      <div><label className={label} htmlFor={`oe-${o.sessionId}-notes`}>Notes</label>
        <textarea id={`oe-${o.sessionId}-notes`} className={field} rows={2} maxLength={1000} value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></div>
      {tickets && tickets.length > 0 && (
        <div>
          <p className={label}>Attendees</p>
          <ul className="grid gap-2 sm:grid-cols-2">
            {tickets.map((t) => (
              <li key={t.id} className="flex items-center gap-2">
                <span className="text-xs text-slate-500 w-24 truncate">{t.tierName}</span>
                <input className={field} aria-label={`Attendee for ${t.tierName}`} maxLength={80} value={names[t.id] ?? ''}
                  disabled={t.inTransfer || (t.status !== 'active' && t.status !== 'used')}
                  onChange={(e) => setNames({ ...names, [t.id]: e.target.value })} />
              </li>
            ))}
          </ul>
          <p className="text-xs text-slate-400 mt-1">To give a ticket to someone else, the holder transfers it from their ticket (its code changes).</p>
        </div>
      )}
      <button type="button" className={btnDark} disabled={busy} onClick={() => void save()}>Save</button>
    </div>
  );
}

function ResendReceipt({ o, settings, onSent }: { o: OrderRow; settings: OrderSettings | null; onSent: () => void }) {
  const { toast } = useToast();
  const [to, setTo] = useState('');
  const [busy, setBusy] = useState(false);
  const send = async () => {
    setBusy(true);
    try {
      const r = await sendReceipt(o.sessionId, to.trim() || null);
      toast({ kind: 'success', message: `Receipt sent to ${r.to}. ${r.resendsLeft} more this hour.` });
      setTo('');
      onSent();
    } catch (e) {
      toast({ kind: 'error', message: err(e) });
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="flex flex-wrap items-end gap-2">
      {settings?.receiptOverrideEmail ? (
        <div className="min-w-[260px]"><label className={label} htmlFor={`rr-${o.sessionId}`}>Send to (blank: {o.email ?? 'the buyer'})</label>
          <input id={`rr-${o.sessionId}`} className={field} type="email" maxLength={254} value={to} onChange={(e) => setTo(e.target.value)} /></div>
      ) : (
        <p className="text-sm text-slate-600">The receipt goes to the address the order was placed with (this organization doesn't send receipts elsewhere). It has no ticket links.</p>
      )}
      <button type="button" className={btnDark} disabled={busy} onClick={() => void send()}><Mail size={12} /> Send receipt</button>
      <span className="text-xs text-slate-400">{o.receiptsSent} resent so far</span>
    </div>
  );
}

// ── Edit history ───────────────────────────────────────────────────────────────

const ACTIONS: { id: string; label: string }[] = [
  { id: '', label: 'All' }, { id: 'order.update', label: 'Order edits' }, { id: 'ticket.update', label: 'Attendees' },
  { id: 'order.receipt', label: 'Receipts' }, { id: 'order.check_out', label: 'Check-outs' },
];

function HistoryTab({ orgId, sessionId }: { orgId: string; sessionId: string | null }) {
  const { toast } = useToast();
  const [action, setAction] = useState('');
  const [page, setPage] = useState(1);
  const [rows, setRows] = useState<OrderEditRow[] | null>(null);
  const [total, setTotal] = useState(0);
  useEffect(() => {
    listOrderEdits(orgId, { sessionId: sessionId ?? undefined, action, limit: 25, offset: (page - 1) * 25 })
      .then((r) => { setRows(r.rows); setTotal(r.total); })
      .catch((e) => { toast({ kind: 'error', message: err(e) }); setRows([]); });
  }, [orgId, sessionId, action, page, toast]);
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap gap-2">
        {ACTIONS.map((a) => (
          <button key={a.id} type="button" aria-pressed={action === a.id} onClick={() => { setAction(a.id); setPage(1); }}
            className={`${btn} ${action === a.id ? 'border-slate-900 text-slate-900' : ''}`}>{a.label}</button>
        ))}
      </div>
      <div className="bg-white border border-slate-200 rounded-2xl overflow-x-auto">
        <table className="w-full text-sm">
          <thead><tr><th className={th}>When</th>{!sessionId && <th className={th}>Order</th>}<th className={th}>Change</th><th className={th}>By</th></tr></thead>
          <tbody>
            {(rows ?? []).map((r) => (
              <tr key={r.id} className="border-t border-slate-100">
                <td className="p-3 whitespace-nowrap">{when(r.createdAt)}</td>
                {!sessionId && <td className="p-3 font-mono text-xs">{r.sessionId}</td>}
                <td className="p-3">{describeEdit(r)}</td>
                <td className="p-3 text-xs text-slate-500">{r.actorEmail ?? 'unknown'}{r.viaApi ? ' (API)' : ''}</td>
              </tr>
            ))}
            {rows !== null && rows.length === 0 && <tr><td colSpan={4} className="p-6 text-center text-slate-400">No changes yet.</td></tr>}
          </tbody>
        </table>
      </div>
      <Pager page={page} perPage={25} total={total} onPage={setPage} />
    </div>
  );
}

// ── Recommendations ──────────────────────────────────────────────────────────

function RecsTab({ events }: { events: Event[] }) {
  const { toast } = useToast();
  const [eventId, setEventId] = useState('');
  const [cross, setCross] = useState(false);
  const [evFilter, setEvFilter] = useState<RecEventFilter>('all');
  const [evSort, setEvSort] = useState<RecEventSort>('score');
  const [evPage, setEvPage] = useState(1);
  const [ev, setEv] = useState<{ total: number; rows: RecEvent[] } | null>(null);
  const [fanSearch, setFanSearch] = useState('');
  const [fanSort, setFanSort] = useState<RecFanSort>('score');
  const [fanPage, setFanPage] = useState(1);
  const [fans, setFans] = useState<{ total: number; rows: RecFan[] } | null>(null);

  useEffect(() => {
    if (!eventId) return;
    similarEvents(eventId, cross, REC_PAGE, (evPage - 1) * REC_PAGE).then(setEv)
      .catch((e) => { toast({ kind: 'error', message: err(e) }); setEv({ total: 0, rows: [] }); });
  }, [eventId, cross, evPage, toast]);
  useEffect(() => {
    if (!eventId) return;
    fanRecommendations(eventId, REC_PAGE, (fanPage - 1) * REC_PAGE).then(setFans)
      .catch((e) => { toast({ kind: 'error', message: err(e) }); setFans({ total: 0, rows: [] }); });
  }, [eventId, fanPage, toast]);
  const evRows = useMemo(() => viewRecEvents(ev?.rows ?? [], evFilter, evSort), [ev, evFilter, evSort]);
  const fanRows = useMemo(() => viewRecFans(fans?.rows ?? [], fanSearch, fanSort), [fans, fanSearch, fanSort]);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end gap-3">
        <div className="min-w-[260px]"><label className={label} htmlFor="rec-event">Event</label>
          <select id="rec-event" className={field} value={eventId} onChange={(e) => { setEventId(e.target.value); setEvPage(1); setFanPage(1); }}>
            <option value="">Pick an event</option>
            {events.map((x) => <option key={x.id} value={x.id}>{x.title}</option>)}
          </select></div>
        <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={cross} onChange={(e) => { setCross(e.target.checked); setEvPage(1); }} />
          Include other organizers' public events</label>
      </div>
      {!eventId && <p className="text-sm text-slate-500">Pick an event to see similar events and fans to invite. Only public, upcoming events are ever suggested.</p>}
      {eventId && (
        <section className={card}>
          <div className="flex flex-wrap items-center justify-between gap-2 mb-3">
            <h2 className="font-bold">Similar events</h2>
            <span className="flex gap-2">
              <select aria-label="Show" className={`${field} w-auto`} value={evFilter} onChange={(e) => setEvFilter(e.target.value as RecEventFilter)}>
                <option value="all">All</option><option value="org">Ours</option><option value="other">Other organizers</option>
              </select>
              <select aria-label="Sort" className={`${field} w-auto`} value={evSort} onChange={(e) => setEvSort(e.target.value as RecEventSort)}>
                <option value="score">Best match</option><option value="date">Date</option><option value="name">Name</option>
              </select>
            </span>
          </div>
          <div className="overflow-x-auto"><table className="w-full text-sm">
            <thead><tr><th className={th}>Event</th><th className={th}>Date</th><th className={th}>Organizer</th><th className={th}>Score</th><th className={th}>Why</th></tr></thead>
            <tbody>
              {evRows.map((r) => (
                <tr key={r.id} className="border-t border-slate-100">
                  <td className="p-3 font-bold">{r.name}{r.venueName && <span className="block text-xs font-normal text-slate-500">{r.venueName}</span>}</td>
                  <td className="p-3 whitespace-nowrap">{when(r.startsAt)}</td>
                  <td className="p-3">{r.sameOrg ? 'You' : r.orgName}</td>
                  <td className="p-3">{r.score}</td>
                  <td className="p-3 text-xs text-slate-500">{r.reasons.join(' · ')}</td>
                </tr>
              ))}
              {ev && evRows.length === 0 && <tr><td colSpan={5} className="p-6 text-center text-slate-400">Nothing similar yet.</td></tr>}
            </tbody>
          </table></div>
          <Pager page={evPage} perPage={REC_PAGE} total={ev?.total ?? 0} onPage={setEvPage} />
        </section>
      )}
      {eventId && (
        <section className={card}>
          <div className="flex flex-wrap items-center justify-between gap-2 mb-3">
            <h2 className="font-bold">Fans to invite</h2>
            <span className="flex gap-2">
              <input className={`${field} w-48`} aria-label="Search fans" placeholder="Search this page" value={fanSearch} onChange={(e) => setFanSearch(e.target.value)} />
              <select aria-label="Sort fans" className={`${field} w-auto`} value={fanSort} onChange={(e) => setFanSort(e.target.value as RecFanSort)}>
                <option value="score">Best match</option><option value="recent">Recent buyers</option><option value="email">Email</option>
              </select>
            </span>
          </div>
          <p className="text-xs text-slate-500 mb-2">Fans on your email list (they joined it themselves) with no ticket for this event yet.</p>
          <div className="overflow-x-auto"><table className="w-full text-sm">
            <thead><tr><th className={th}>Fan</th><th className={th}>Orders</th><th className={th}>Last order</th><th className={th}>Score</th><th className={th}>Why</th></tr></thead>
            <tbody>
              {fanRows.map((f) => (
                <tr key={f.id} className="border-t border-slate-100">
                  <td className="p-3"><span className="font-bold">{f.name ?? f.email}</span>{f.name && <span className="block text-xs text-slate-500">{f.email}</span>}</td>
                  <td className="p-3">{f.ordersCount}</td>
                  <td className="p-3 whitespace-nowrap">{f.lastOrderAt ? new Date(f.lastOrderAt).toLocaleDateString() : ''}</td>
                  <td className="p-3">{f.score}</td>
                  <td className="p-3 text-xs text-slate-500">{f.reasons.join(' · ')}</td>
                </tr>
              ))}
              {fans && fanRows.length === 0 && <tr><td colSpan={5} className="p-6 text-center text-slate-400">No fans to suggest yet.</td></tr>}
            </tbody>
          </table></div>
          <Pager page={fanPage} perPage={REC_PAGE} total={fans?.total ?? 0} onPage={setFanPage} />
        </section>
      )}
    </div>
  );
}

// ── Guest preview ──────────────────────────────────────────────────────────────

const PREVIEW_TABS: { id: PreviewStatus | ''; label: string }[] = [
  { id: '', label: 'All' }, { id: 'ready', label: 'Ready' }, { id: 'duplicate', label: 'Duplicates' },
  { id: 'invalid', label: 'Skipped' }, { id: 'too_many_plus_ones', label: 'Too many plus-ones' },
];

function PreviewTab({ events }: { events: Event[] }) {
  const { toast } = useToast();
  const [eventId, setEventId] = useState('');
  const [lists, setLists] = useState<GuestList[]>([]);
  const [listId, setListId] = useState('');
  const [text, setText] = useState('');
  const [status, setStatus] = useState<PreviewStatus | ''>('');
  const [out, setOut] = useState<{ rows: PreviewResultRow[]; summary: Record<string, number>; capacity: Record<string, unknown>; skipped: number } | null>(null);
  useEffect(() => {
    setLists([]); setListId(''); setOut(null);
    if (eventId) listGuestLists(eventId).then((r) => setLists(r.lists)).catch(() => setLists([]));
  }, [eventId]);
  const run = async () => {
    const parsed = parsePastedNames(text);
    try {
      const r = await previewGuestList(eventId, listId || null, parsed.rows);
      setOut({ rows: r.rows ?? [], summary: r.summary ?? {}, capacity: r.capacity ?? {}, skipped: parsed.skipped.length });
    } catch (e) {
      toast({ kind: 'error', message: err(e) });
    }
  };
  const shown = out ? filterPreviewRows(out.rows, status) : [];
  const cap = out?.capacity ?? {};
  return (
    <div className="space-y-4">
      <div className="grid gap-2 sm:grid-cols-2">
        <div><label className={label} htmlFor="gp-event">Event</label>
          <select id="gp-event" className={field} value={eventId} onChange={(e) => setEventId(e.target.value)}>
            <option value="">Pick an event</option>{events.map((x) => <option key={x.id} value={x.id}>{x.title}</option>)}
          </select></div>
        <div><label className={label} htmlFor="gp-list">Guest list</label>
          <select id="gp-list" className={field} value={listId} onChange={(e) => setListId(e.target.value)} disabled={!eventId}>
            <option value="">Any list (duplicates only)</option>{lists.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
          </select></div>
      </div>
      <div><label className={label} htmlFor="gp-text">Names, one per line (+2 adds plus-ones)</label>
        <textarea id="gp-text" className={field} rows={6} value={text} onChange={(e) => setText(e.target.value)} placeholder={'Maya Chen +2\nTessa'} /></div>
      <button type="button" className={btnDark} disabled={!eventId || !text.trim()} onClick={() => void run()}>Preview</button>
      {out && (
        <div className={card}>
          <p className="text-sm mb-3">
            {out.summary.ready ?? 0} ready ({out.summary.heads ?? 0} people), {out.summary.duplicates ?? 0} duplicates, {out.summary.invalid ?? 0} skipped
            {out.skipped ? `, ${out.skipped} lines that aren't names` : ''}.
            {cap.list_cap != null && ` List cap ${String(cap.list_cap)}: ${String(cap.list_cap_left_after)} left after.`}
            {cap.counts_toward_capacity === true && cap.event_left_after != null && ` Event: ${String(cap.event_left_after)} left after.`}
            {' '}Nothing was added.
          </p>
          <div className="flex flex-wrap gap-2 mb-3">
            {PREVIEW_TABS.map((t) => <button key={t.id} type="button" aria-pressed={status === t.id} onClick={() => setStatus(t.id)}
              className={`${btn} ${status === t.id ? 'border-slate-900 text-slate-900' : ''}`}>{t.label}</button>)}
          </div>
          <table className="w-full text-sm">
            <thead><tr><th className={th}>#</th><th className={th}>Name</th><th className={th}>People</th><th className={th}>Status</th></tr></thead>
            <tbody>{shown.map((r) => (
              <tr key={r.row} className="border-t border-slate-100">
                <td className="p-3 text-slate-400">{r.row}</td><td className="p-3">{r.name ?? ''}</td><td className="p-3">{r.tickets ?? ''}</td>
                <td className="p-3">{previewStatusText(r)}</td>
              </tr>
            ))}</tbody>
          </table>
        </div>
      )}
    </div>
  );
}

// ── Settings (owner) ─────────────────────────────────────────────────────────────

function SettingsTab({ orgId }: { orgId: string }) {
  const { toast } = useToast();
  const [s, setS] = useState<OrderSettings | null>(null);
  useEffect(() => { getOrderSettings(orgId).then(setS).catch((e) => toast({ kind: 'error', message: err(e) })); }, [orgId, toast]);
  if (!s) return <p className="text-sm text-slate-400">Loading…</p>;
  const save = async () => {
    try {
      setS(await saveOrderSettings(orgId, s));
      toast({ kind: 'success', message: 'Saved.' });
    } catch (e) {
      toast({ kind: 'error', message: err(e) });
    }
  };
  return (
    <div className={`${card} space-y-4 max-w-xl`}>
      <label className="flex items-start gap-2 text-sm">
        <input type="checkbox" className="mt-1" checked={s.receiptOverrideEmail} onChange={(e) => setS({ ...s, receiptOverrideEmail: e.target.checked })} />
        <span>Staff may send a receipt to another address than the buyer's. Receipts never contain ticket links, so this can't hand tickets over.</span>
      </label>
      <div className="max-w-[200px]"><label className={label} htmlFor="os-rate">Resends per order per hour</label>
        <input id="os-rate" className={field} type="number" min={1} max={10} value={s.receiptResendsPerHour}
          onChange={(e) => setS({ ...s, receiptResendsPerHour: Math.min(10, Math.max(1, Number(e.target.value) || 1)) })} /></div>
      <button type="button" className={btnDark} onClick={() => void save()}>Save</button>
    </div>
  );
}
