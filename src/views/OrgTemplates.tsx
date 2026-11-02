// /orgs/:orgId/templates — event templates, note templates, rental invoice
// templates and rental invoices (mig 20261102130000, docs/templates-inbound.md).
// Who sees and does what (RLS and the functions decide again):
//   event templates  read: owner, manager, content, finance; write: owner, manager
//   note templates   read: owner, manager, content, finance; write: + content
//   rental templates read: owner, manager, finance; write: owner, manager
//   rental invoices  read and write: owner, manager, finance
// Write actions are hidden from roles that can't do them.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Plus, Trash2 } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { getOrganization, getUserRoleInOrg } from '../lib/orgs';
import { supabase } from '../lib/supabase';
import { formatCents } from '../lib/dealMath';
import DataTable from '../components/DataTable';
import { BTN, BTN_PRIMARY, centsFromInput, FLD, inputFromCents, LABEL, Section, StatusBadge } from '../components/finance/ui';
import {
  applyNoteTemplate, createEventFromTemplate, createRentalInvoice, deleteEventTemplate, deleteNoteTemplate,
  deleteRentalInvoice, deleteRentalTemplate, getRentalPrefix, issueRentalInvoice, listEventTemplates, listNoteTemplates,
  listRentalInvoices, listRentalTemplates, saveEventTemplate, saveNoteTemplate, saveRentalTemplate, setRentalInvoiceStatus,
  setRentalPrefix, updateRentalInvoice,
  type EventTemplateFee, type EventTemplateRow, type EventTemplateTier, type NoteTemplateRow, type RentalInvoiceRow,
  type RentalTemplateRow,
} from '../lib/templatesApi';
import {
  canWriteRentalTemplates, rentalActions, rentalTotals, type RentalDeposit, type RentalItem, type RentalTaxFee,
} from '../lib/rentalInvoice';

type Tab = 'events' | 'notes' | 'rentals' | 'invoices';
const TAB_LABEL: Record<Tab, string> = { events: 'Event templates', notes: 'Note templates', rentals: 'Rental templates', invoices: 'Rental invoices' };
const TEMPLATE_STATUSES = ['active', 'archived'] as const;

type ErrFn = (e: unknown) => void;

export default function OrgTemplates() {
  const { orgId } = useParams();
  const { user, isAdmin } = useAuth();
  const { toast } = useToast();
  const [role, setRole] = useState<string | null | undefined>(undefined);
  const [orgName, setOrgName] = useState('');
  const [tab, setTab] = useState<Tab>('events');

  useEffect(() => {
    if (!orgId || !user?.uid) return;
    getOrganization(orgId).then((o) => setOrgName(o?.name ?? '')).catch(() => {});
    getUserRoleInOrg(orgId, user.uid).then(setRole).catch(() => setRole(null));
  }, [orgId, user?.uid]);
  const r = isAdmin ? 'owner' : role ?? null;
  const staff = r === 'owner' || r === 'manager';
  const tabs: Tab[] = [
    ...(staff || r === 'content' || r === 'finance' ? (['events', 'notes'] as Tab[]) : []),
    ...(staff || r === 'finance' ? (['rentals', 'invoices'] as Tab[]) : []),
  ];
  useEffect(() => { if (tabs.length && !tabs.includes(tab)) setTab(tabs[0]); }, [tabs, tab]);
  const onErr: ErrFn = useCallback((e) => toast({ kind: 'error', message: (e as Error).message }), [toast]);

  if (role === undefined && !isAdmin) return <div className="p-8 text-sm text-slate-500">Loading…</div>;
  if (!tabs.length || !orgId) return <div className="p-8 text-sm text-slate-500">Templates are for owners, managers, content and finance staff.</div>;

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <Link to="/dashboard" className="inline-flex items-center gap-1 text-xs text-slate-500 hover:text-slate-900 mb-4"><ArrowLeft size={14} /> Dashboard</Link>
      <h1 className="text-2xl font-black text-slate-900 mb-1">Templates</h1>
      <p className="text-sm text-slate-500 mb-6">{orgName} · saved event setups, booking notes, venue rental invoices.</p>
      <div role="tablist" className="flex gap-1 border-b border-slate-200 mb-6 overflow-x-auto">
        {tabs.map((t) => (
          <button key={t} role="tab" aria-selected={tab === t} onClick={() => setTab(t)}
            className={`px-4 py-3 text-xs font-bold uppercase tracking-widest border-b-2 -mb-px whitespace-nowrap ${tab === t ? 'border-[#026cdf] text-slate-900' : 'border-transparent text-slate-400'}`}>
            {TAB_LABEL[t]}
          </button>
        ))}
      </div>
      {tab === 'events' && <EventTemplates orgId={orgId} canEdit={staff} onErr={onErr} />}
      {tab === 'notes' && <NoteTemplates orgId={orgId} canEdit={staff || r === 'content'} onErr={onErr} />}
      {tab === 'rentals' && <RentalTemplates orgId={orgId} canEdit={canWriteRentalTemplates(r, isAdmin)} onErr={onErr} />}
      {tab === 'invoices' && <RentalInvoices orgId={orgId} role={r} isAdmin={!!isAdmin} canPrefix={staff} onErr={onErr} />}
    </div>
  );
}

const when = (s: string | null) => (s ? new Date(s).toLocaleDateString() : '—');

// ---- Event templates -----------------------------------------------------------------

function EventTemplates({ orgId, canEdit, onErr }: { orgId: string; canEdit: boolean; onErr: ErrFn }) {
  const navigate = useNavigate();
  const { toast } = useToast();
  const [rows, setRows] = useState<EventTemplateRow[]>([]);
  const [editing, setEditing] = useState<Partial<EventTemplateRow> | null>(null);
  const [making, setMaking] = useState<EventTemplateRow | null>(null);
  const load = useCallback(() => listEventTemplates(orgId).then(setRows).catch(onErr), [orgId, onErr]);
  useEffect(() => { load(); }, [load]);

  const act = (f: () => Promise<unknown>) => f().then(load).catch(onErr);
  const save = async () => {
    if (!editing?.name?.trim()) return;
    try {
      await saveEventTemplate(orgId, editing, editing.id);
      setEditing(null);
      load();
    } catch (e) { onErr(e); }
  };

  return (
    <>
      {canEdit && !editing && (
        <button className={`${BTN_PRIMARY} mb-4`} onClick={() => setEditing({ name: '', tiers: [{ name: 'General Admission', price_cents: 2000, capacity: 100 }], fee_rules: [], inherit_org_fees: true, event_fields: {}, description: '' })}>
          <Plus size={12} className="inline mr-1" />New event template
        </button>
      )}
      {editing && <EventTemplateEditor value={editing} onChange={setEditing} onSave={save} onCancel={() => setEditing(null)} />}
      {making && (
        <MakeEvent template={making} onCancel={() => setMaking(null)} onErr={onErr}
          onDone={(id) => { toast({ kind: 'success', message: 'Draft event created.' }); navigate(`/edit-event/${id}`); }} />
      )}
      <DataTable<EventTemplateRow> label="Event templates" rows={rows} rowKey={(t) => t.id}
        searchFields={(t) => [t.name, t.event_name, t.description]} searchPlaceholder="Search templates"
        statuses={TEMPLATE_STATUSES} status={(t) => t.status} defaultStatus="active" defaultSort={{ key: 'name', dir: 'asc' }}
        columns={[
          { key: 'name', header: 'Template', value: (t) => t.name, render: (t) => <><p className="font-bold text-slate-900">{t.name}</p>{t.event_name && <p className="text-xs text-slate-400">{t.event_name}</p>}</> },
          { key: 'tiers', header: 'Ticket types', value: (t) => t.tiers.length, render: (t) => t.tiers.map((x) => `${x.name} ${formatCents(x.price_cents, String(t.event_fields.currency ?? 'USD'))}`).join(' · ') || '—' },
          { key: 'capacity', header: 'Capacity', align: 'right', value: (t) => t.capacity ?? t.tiers.reduce((s, x) => s + x.capacity, 0), render: (t) => t.capacity ?? t.tiers.reduce((s, x) => s + x.capacity, 0) },
          { key: 'used', header: 'Used', align: 'right', value: (t) => t.use_count, render: (t) => t.use_count },
          { key: 'last', header: 'Last used', value: (t) => t.last_used_at, render: (t) => when(t.last_used_at) },
          { key: 'status', header: 'Status', value: (t) => t.status, render: (t) => <StatusBadge status={t.status} /> },
        ]}
        actions={canEdit ? (t) => (<>
          {t.status === 'active' && <button className={BTN} onClick={() => setMaking(t)}>Create event</button>}
          <button className={BTN} onClick={() => setEditing(t)}>Edit</button>
          <button className={BTN} onClick={() => act(() => saveEventTemplate(orgId, { status: t.status === 'active' ? 'archived' : 'active' }, t.id))}>
            {t.status === 'active' ? 'Archive' : 'Restore'}
          </button>
          <button className={BTN} aria-label={`Delete ${t.name}`} onClick={() => { if (window.confirm(`Delete ${t.name}?`)) act(() => deleteEventTemplate(t.id)); }}><Trash2 size={12} /></button>
        </>) : undefined}
        empty="No event templates yet. Save one here, or from an event's page (Save as template)." />
    </>
  );
}

function MakeEvent({ template, onCancel, onDone, onErr }: { template: EventTemplateRow; onCancel: () => void; onDone: (id: string) => void; onErr: ErrFn }) {
  const [name, setName] = useState(template.event_name ?? template.name);
  const [start, setStart] = useState('');
  const [busy, setBusy] = useState(false);
  const go = async () => {
    setBusy(true);
    try {
      onDone(await createEventFromTemplate(template.id, { name: name.trim() || undefined, ...(start ? { starts_at: new Date(start).toISOString() } : {}) }));
    } catch (e) { onErr(e); } finally { setBusy(false); }
  };
  return (
    <Section title={`Create an event from ${template.name}`}>
      <div className="flex flex-wrap gap-2 items-end">
        <label className="flex-1 min-w-[200px]"><span className={LABEL}>Event name</span><input className={FLD} value={name} maxLength={200} onChange={(e) => setName(e.target.value)} /></label>
        <label><span className={LABEL}>Starts (your time)</span><input className={FLD} type="datetime-local" value={start} onChange={(e) => setStart(e.target.value)} /></label>
        <button className={BTN_PRIMARY} disabled={busy} onClick={go}>Create draft</button>
        <button className={BTN} onClick={onCancel}>Cancel</button>
      </div>
      <p className="text-xs text-slate-400 mt-2">The draft gets the template's ticket types, fee rules and settings; doors and end follow from the start. Publish it from the event page.</p>
    </Section>
  );
}

const intOrNull = (v: string, max: number) => (v.trim() === '' ? null : Math.max(0, Math.min(max, Math.floor(Number(v) || 0))));

function EventTemplateEditor({ value, onChange, onSave, onCancel }: {
  value: Partial<EventTemplateRow>; onChange: (v: Partial<EventTemplateRow>) => void; onSave: () => void; onCancel: () => void;
}) {
  const v = value;
  const tiers = v.tiers ?? [];
  const fees = v.fee_rules ?? [];
  const fields = v.event_fields ?? {};
  const setTier = (i: number, t: Partial<EventTemplateTier>) => onChange({ ...v, tiers: tiers.map((x, j) => (j === i ? { ...x, ...t } : x)) });
  const setFee = (i: number, f: Partial<EventTemplateFee>) => onChange({ ...v, fee_rules: fees.map((x, j) => (j === i ? { ...x, ...f } : x)) });
  const setField = (k: string, val: string) => {
    const next = { ...fields };
    if (val.trim()) next[k] = val.trim(); else delete next[k];
    onChange({ ...v, event_fields: next });
  };
  return (
    <Section title={v.id ? 'Edit event template' : 'New event template'}>
      <div className="grid gap-3 sm:grid-cols-3 mb-4">
        <label><span className={LABEL}>Template name</span><input className={FLD} value={v.name ?? ''} maxLength={100} onChange={(e) => onChange({ ...v, name: e.target.value })} /></label>
        <label><span className={LABEL}>Event name</span><input className={FLD} value={v.event_name ?? ''} maxLength={200} placeholder="(the template name)" onChange={(e) => onChange({ ...v, event_name: e.target.value || null })} /></label>
        <label><span className={LABEL}>Capacity</span><input className={FLD} inputMode="numeric" value={v.capacity ?? ''} placeholder="(sum of tickets)" onChange={(e) => onChange({ ...v, capacity: intOrNull(e.target.value, 1_000_000) })} /></label>
        <label><span className={LABEL}>Doors (minutes before)</span><input className={FLD} inputMode="numeric" value={v.doors_offset_minutes ?? ''} onChange={(e) => onChange({ ...v, doors_offset_minutes: intOrNull(e.target.value, 1440) })} /></label>
        <label><span className={LABEL}>Length (minutes)</span><input className={FLD} inputMode="numeric" value={v.duration_minutes ?? ''} onChange={(e) => onChange({ ...v, duration_minutes: intOrNull(e.target.value, 10080) || null })} /></label>
        <label><span className={LABEL}>Time zone</span><input className={FLD} value={String(fields.timezone ?? '')} placeholder="America/New_York" onChange={(e) => setField('timezone', e.target.value)} /></label>
        <label><span className={LABEL}>Venue name</span><input className={FLD} value={String(fields.venue_name ?? '')} onChange={(e) => setField('venue_name', e.target.value)} /></label>
        <label className="flex items-center gap-2 mt-5 text-sm"><input type="checkbox" checked={v.inherit_org_fees ?? true} onChange={(e) => onChange({ ...v, inherit_org_fees: e.target.checked })} />Also apply the organization's fee rules</label>
      </div>
      <label className="block mb-4"><span className={LABEL}>Description</span>
        <textarea className={FLD} rows={3} maxLength={20000} value={v.description ?? ''} onChange={(e) => onChange({ ...v, description: e.target.value })} /></label>
      <p className={`${LABEL} mb-2`}>Ticket types (all-in prices)</p>
      {tiers.map((t, i) => (
        <div key={i} className="grid gap-2 grid-cols-[1fr_100px_90px_110px_auto] mb-2 items-center">
          <input className={FLD} aria-label="Ticket type name" value={t.name} maxLength={100} onChange={(e) => setTier(i, { name: e.target.value })} />
          <input className={FLD} aria-label="Price" inputMode="decimal" defaultValue={inputFromCents(t.price_cents)}
            onBlur={(e) => { const c = centsFromInput(e.target.value); if (c !== null && !Number.isNaN(c)) setTier(i, { price_cents: c }); }} />
          <input className={FLD} aria-label="Capacity" inputMode="numeric" value={t.capacity} onChange={(e) => setTier(i, { capacity: intOrNull(e.target.value, 1_000_000) ?? 0 })} />
          <select className={FLD} aria-label="Visibility" value={t.visibility ?? 'public'} onChange={(e) => setTier(i, { visibility: e.target.value as 'public' | 'hidden' })}>
            <option value="public">Public</option><option value="hidden">Hidden</option>
          </select>
          <button className={BTN} aria-label="Remove ticket type" onClick={() => onChange({ ...v, tiers: tiers.filter((_, j) => j !== i) })}><Trash2 size={12} /></button>
        </div>
      ))}
      <button className={`${BTN} mb-4`} disabled={tiers.length >= 50} onClick={() => onChange({ ...v, tiers: [...tiers, { name: '', price_cents: 0, capacity: 0 }] })}>Add ticket type</button>
      <p className={`${LABEL} mb-2`}>Event fee rules</p>
      {fees.map((f, i) => (
        <div key={i} className="grid gap-2 grid-cols-[1fr_130px_110px_100px_auto] mb-2 items-center">
          <input className={FLD} aria-label="Fee name" value={f.name} maxLength={60} onChange={(e) => setFee(i, { name: e.target.value })} />
          <select className={FLD} aria-label="Who pays" value={f.kind} onChange={(e) => setFee(i, { kind: e.target.value as EventTemplateFee['kind'] })}>
            <option value="passed_on">In the price</option><option value="absorbed">Absorbed</option>
          </select>
          <select className={FLD} aria-label="Calculation" value={f.calc}
            onChange={(e) => setFee(i, e.target.value === 'fixed' ? { calc: 'fixed', amount_cents: f.amount_cents ?? 0, percent: undefined } : { calc: 'percent', percent: f.percent ?? 0, amount_cents: undefined })}>
            <option value="fixed">Per ticket ($)</option><option value="percent">Percent</option>
          </select>
          <input className={FLD} aria-label="Amount" inputMode="decimal"
            defaultValue={f.calc === 'fixed' ? inputFromCents(f.amount_cents ?? 0) : String(f.percent ?? '')}
            onBlur={(e) => {
              if (f.calc === 'fixed') { const c = centsFromInput(e.target.value); if (c !== null && !Number.isNaN(c)) setFee(i, { amount_cents: c }); }
              else setFee(i, { percent: Math.min(100, Math.max(0, Number(e.target.value) || 0)) });
            }} />
          <button className={BTN} aria-label="Remove fee rule" onClick={() => onChange({ ...v, fee_rules: fees.filter((_, j) => j !== i) })}><Trash2 size={12} /></button>
        </div>
      ))}
      <button className={BTN} disabled={fees.length >= 25} onClick={() => onChange({ ...v, fee_rules: [...fees, { name: '', kind: 'passed_on', calc: 'fixed', amount_cents: 0 }] })}>Add fee rule</button>
      <div className="flex gap-2 mt-5">
        <button className={BTN_PRIMARY} disabled={!v.name?.trim()} onClick={onSave}>Save</button>
        <button className={BTN} onClick={onCancel}>Cancel</button>
      </div>
    </Section>
  );
}

// ---- Note templates ----------------------------------------------------------------------

function NoteTemplates({ orgId, canEdit, onErr }: { orgId: string; canEdit: boolean; onErr: ErrFn }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<NoteTemplateRow[]>([]);
  const [events, setEvents] = useState<{ id: string; name: string }[]>([]);
  const [editing, setEditing] = useState<Partial<NoteTemplateRow> | null>(null);
  const [applying, setApplying] = useState<NoteTemplateRow | null>(null);
  const [eventId, setEventId] = useState('');
  const load = useCallback(() => listNoteTemplates(orgId).then(setRows).catch(onErr), [orgId, onErr]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    if (!canEdit) return;
    supabase.from('exos_events').select('id, name').eq('org_id', orgId).neq('status', 'cancelled').order('starts_at', { ascending: false }).limit(200)
      .then(({ data }) => setEvents((data ?? []) as { id: string; name: string }[]));
  }, [orgId, canEdit]);
  const act = (f: () => Promise<unknown>) => f().then(load).catch(onErr);

  return (
    <>
      {canEdit && !editing && <button className={`${BTN_PRIMARY} mb-4`} onClick={() => setEditing({ title: '', body: '' })}><Plus size={12} className="inline mr-1" />New note template</button>}
      {editing && (
        <Section title={editing.id ? 'Edit note template' : 'New note template'}>
          <label className="block mb-3"><span className={LABEL}>Title</span><input className={FLD} value={editing.title ?? ''} maxLength={100} onChange={(e) => setEditing({ ...editing, title: e.target.value })} /></label>
          <label className="block"><span className={LABEL}>Note</span><textarea className={FLD} rows={6} maxLength={5000} value={editing.body ?? ''} onChange={(e) => setEditing({ ...editing, body: e.target.value })} /></label>
          <div className="flex gap-2 mt-4">
            <button className={BTN_PRIMARY} disabled={!editing.title?.trim() || !editing.body?.trim()}
              onClick={() => saveNoteTemplate(orgId, { title: editing.title!, body: editing.body! }, editing.id).then(() => { setEditing(null); load(); }).catch(onErr)}>Save</button>
            <button className={BTN} onClick={() => setEditing(null)}>Cancel</button>
          </div>
        </Section>
      )}
      {applying && (
        <Section title={`Add "${applying.title}" to a show`}>
          <div className="flex flex-wrap gap-2 items-end">
            <label className="flex-1 min-w-[220px]"><span className={LABEL}>Event</span>
              <select className={FLD} value={eventId} onChange={(e) => setEventId(e.target.value)}>
                <option value="">Choose…</option>
                {events.map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}
              </select></label>
            <button className={BTN_PRIMARY} disabled={!eventId}
              onClick={() => applyNoteTemplate(orgId, applying, eventId).then(() => { toast({ kind: 'success', message: 'Note added to the show.' }); setApplying(null); setEventId(''); }).catch(onErr)}>Add note</button>
            <button className={BTN} onClick={() => setApplying(null)}>Cancel</button>
          </div>
        </Section>
      )}
      <DataTable<NoteTemplateRow> label="Note templates" rows={rows} rowKey={(t) => t.id} searchFields={(t) => [t.title, t.body]} searchPlaceholder="Search notes"
        statuses={TEMPLATE_STATUSES} status={(t) => t.status} defaultStatus="active" defaultSort={{ key: 'title', dir: 'asc' }}
        columns={[
          { key: 'title', header: 'Title', value: (t) => t.title, render: (t) => <span className="font-bold text-slate-900">{t.title}</span> },
          { key: 'body', header: 'Note', render: (t) => <span className="text-slate-600">{t.body.length > 120 ? `${t.body.slice(0, 120)}…` : t.body}</span> },
          { key: 'updated', header: 'Updated', value: (t) => t.updated_at, render: (t) => when(t.updated_at) },
          { key: 'status', header: 'Status', value: (t) => t.status, render: (t) => <StatusBadge status={t.status} /> },
        ]}
        actions={canEdit ? (t) => (<>
          {t.status === 'active' && <button className={BTN} onClick={() => setApplying(t)}>Add to show</button>}
          <button className={BTN} onClick={() => setEditing(t)}>Edit</button>
          <button className={BTN} onClick={() => act(() => saveNoteTemplate(orgId, { title: t.title, body: t.body, status: t.status === 'active' ? 'archived' : 'active' }, t.id))}>
            {t.status === 'active' ? 'Archive' : 'Restore'}
          </button>
          <button className={BTN} aria-label={`Delete ${t.title}`} onClick={() => { if (window.confirm(`Delete ${t.title}?`)) act(() => deleteNoteTemplate(t.id)); }}><Trash2 size={12} /></button>
        </>) : undefined}
        empty="No note templates yet." />
    </>
  );
}

// ---- Rental lines editor (templates and draft invoices) ----------------------------------------

interface Lines {
  currency: string;
  attendance_count: number | null;
  discount_cents: number;
  items: RentalItem[];
  tax_fees: RentalTaxFee[];
  deposits: RentalDeposit[];
}

function LinesEditor({ value, onChange }: { value: Lines; onChange: (v: Lines) => void }) {
  const v = value;
  const totals = rentalTotals(v.items, v.attendance_count, v.discount_cents, v.tax_fees, v.deposits);
  const setItem = (i: number, x: Partial<RentalItem>) => onChange({ ...v, items: v.items.map((y, j) => (j === i ? { ...y, ...x } : y)) });
  return (
    <div>
      <div className="grid gap-3 sm:grid-cols-3 mb-3">
        <label><span className={LABEL}>Currency</span><input className={FLD} value={v.currency} maxLength={3} onChange={(e) => onChange({ ...v, currency: e.target.value.toUpperCase() })} /></label>
        <label><span className={LABEL}>Expected heads</span><input className={FLD} inputMode="numeric" value={v.attendance_count ?? ''} onChange={(e) => onChange({ ...v, attendance_count: intOrNull(e.target.value, 1_000_000) })} /></label>
        <label><span className={LABEL}>Discount</span><input className={FLD} inputMode="decimal" defaultValue={inputFromCents(v.discount_cents)}
          onBlur={(e) => { const c = centsFromInput(e.target.value); if (!Number.isNaN(c)) onChange({ ...v, discount_cents: c ?? 0 }); }} /></label>
      </div>
      <p className={`${LABEL} mb-2`}>Lines</p>
      {v.items.map((it, i) => (
        <div key={i} className="grid gap-2 grid-cols-[1fr_80px_120px_100px_100px_auto] mb-2 items-center">
          <input className={FLD} aria-label="Line" value={it.title} maxLength={120} onChange={(e) => setItem(i, { title: e.target.value })} />
          <input className={FLD} aria-label="Quantity" inputMode="decimal" value={String(it.quantity ?? 1)} onChange={(e) => setItem(i, { quantity: e.target.value })} />
          <select className={FLD} aria-label="Cost type" value={it.cost_type ?? 'fixed'} onChange={(e) => setItem(i, { cost_type: e.target.value as RentalItem['cost_type'] })}>
            <option value="fixed">Fixed</option><option value="per_head">Per head</option>
          </select>
          <input className={FLD} aria-label="Cost" inputMode="decimal" defaultValue={inputFromCents(it.cost_cents)}
            onBlur={(e) => { const c = centsFromInput(e.target.value); if (c !== null && !Number.isNaN(c)) setItem(i, { cost_cents: c }); }} />
          <span className="text-right tabular-nums text-sm">{formatCents(totals.lines[i] ?? 0, v.currency)}</span>
          <button className={BTN} aria-label="Remove line" onClick={() => onChange({ ...v, items: v.items.filter((_, j) => j !== i) })}><Trash2 size={12} /></button>
        </div>
      ))}
      <button className={`${BTN} mb-3`} disabled={v.items.length >= 100} onClick={() => onChange({ ...v, items: [...v.items, { title: '', quantity: 1, cost_type: 'fixed', cost_cents: 0 }] })}>Add line</button>
      <p className={`${LABEL} mb-2`}>Taxes and fees</p>
      {v.tax_fees.map((t, i) => (
        <div key={i} className="grid gap-2 grid-cols-[1fr_100px_auto] mb-2">
          <input className={FLD} aria-label="Tax name" value={t.name} maxLength={60} onChange={(e) => onChange({ ...v, tax_fees: v.tax_fees.map((x, j) => (j === i ? { ...x, name: e.target.value } : x)) })} />
          <input className={FLD} aria-label="Rate %" inputMode="decimal" value={String(t.rate_percent)} onChange={(e) => onChange({ ...v, tax_fees: v.tax_fees.map((x, j) => (j === i ? { ...x, rate_percent: e.target.value } : x)) })} />
          <button className={BTN} aria-label="Remove tax" onClick={() => onChange({ ...v, tax_fees: v.tax_fees.filter((_, j) => j !== i) })}><Trash2 size={12} /></button>
        </div>
      ))}
      <button className={`${BTN} mb-3`} disabled={v.tax_fees.length >= 10} onClick={() => onChange({ ...v, tax_fees: [...v.tax_fees, { name: 'Sales tax', rate_percent: 0 }] })}>Add tax / fee</button>
      <p className={`${LABEL} mb-2`}>Deposits</p>
      {v.deposits.map((d, i) => (
        <div key={i} className="grid gap-2 grid-cols-[110px_100px_150px_auto] mb-2">
          <select className={FLD} aria-label="Deposit type" value={d.deposit_type} onChange={(e) => onChange({ ...v, deposits: v.deposits.map((x, j) => (j === i ? { ...x, deposit_type: e.target.value as RentalDeposit['deposit_type'], value: 0 } : x)) })}>
            <option value="percent">Percent</option><option value="flat">Flat</option>
          </select>
          <input className={FLD} aria-label="Deposit value" inputMode="decimal" defaultValue={d.deposit_type === 'flat' ? inputFromCents(d.value) : String(d.value)}
            onBlur={(e) => {
              const val = d.deposit_type === 'flat' ? centsFromInput(e.target.value) ?? 0 : Math.min(100, Math.max(0, Number(e.target.value) || 0));
              if (!Number.isNaN(val)) onChange({ ...v, deposits: v.deposits.map((x, j) => (j === i ? { ...x, value: val } : x)) });
            }} />
          <input className={FLD} aria-label="Days before the rental" inputMode="numeric" value={d.relative_due_days ?? 0}
            onChange={(e) => onChange({ ...v, deposits: v.deposits.map((x, j) => (j === i ? { ...x, due_date_type: 'relative', relative_due_days: Math.floor(Number(e.target.value) || 0) } : x)) })} />
          <button className={BTN} aria-label="Remove deposit" onClick={() => onChange({ ...v, deposits: v.deposits.filter((_, j) => j !== i) })}><Trash2 size={12} /></button>
        </div>
      ))}
      <button className={`${BTN} mb-3`} disabled={v.deposits.length >= 10} onClick={() => onChange({ ...v, deposits: [...v.deposits, { deposit_type: 'percent', value: 50, due_date_type: 'relative', relative_due_days: 14 }] })}>Add deposit</button>
      <div className="text-sm text-right space-y-0.5 tabular-nums">
        <p>Subtotal {formatCents(totals.subtotal_cents, v.currency)}{totals.discount_cents ? ` · discount −${formatCents(totals.discount_cents, v.currency)}` : ''}</p>
        {totals.taxes.map((t, i) => <p key={i}>{t.name} {formatCents(t.cents, v.currency)}</p>)}
        <p className="font-bold text-slate-900">Total {formatCents(totals.total_cents, v.currency)}{totals.deposits_cents ? ` · deposits ${formatCents(totals.deposits_cents, v.currency)}` : ''}</p>
      </div>
    </div>
  );
}

const linesOf = (r: Partial<RentalTemplateRow> | Partial<RentalInvoiceRow>): Lines => ({
  currency: r.currency ?? 'USD', attendance_count: r.attendance_count ?? null, discount_cents: r.discount_cents ?? 0,
  items: r.items ?? [], tax_fees: r.tax_fees ?? [], deposits: r.deposits ?? [],
});

// ---- Rental templates ----------------------------------------------------------------------------

function RentalTemplates({ orgId, canEdit, onErr }: { orgId: string; canEdit: boolean; onErr: ErrFn }) {
  const [rows, setRows] = useState<RentalTemplateRow[]>([]);
  const [editing, setEditing] = useState<Partial<RentalTemplateRow> | null>(null);
  const load = useCallback(() => listRentalTemplates(orgId).then(setRows).catch(onErr), [orgId, onErr]);
  useEffect(() => { load(); }, [load]);
  const act = (f: () => Promise<unknown>) => f().then(load).catch(onErr);
  return (
    <>
      {canEdit && !editing && <button className={`${BTN_PRIMARY} mb-4`} onClick={() => setEditing({ title: '', currency: 'USD', items: [{ title: 'Room hire', quantity: 1, cost_type: 'fixed', cost_cents: 0 }], tax_fees: [], deposits: [], discount_cents: 0, notes: '', terms: '' })}><Plus size={12} className="inline mr-1" />New rental template</button>}
      {editing && (
        <Section title={editing.id ? 'Edit rental template' : 'New rental template'}>
          <div className="grid gap-3 sm:grid-cols-2 mb-3">
            <label><span className={LABEL}>Title</span><input className={FLD} value={editing.title ?? ''} maxLength={100} onChange={(e) => setEditing({ ...editing, title: e.target.value })} /></label>
            <label><span className={LABEL}>Payee</span><input className={FLD} value={editing.payee_name ?? ''} maxLength={200} onChange={(e) => setEditing({ ...editing, payee_name: e.target.value || null })} /></label>
          </div>
          <LinesEditor value={linesOf(editing)} onChange={(l) => setEditing({ ...editing, ...l })} />
          <label className="block mt-3"><span className={LABEL}>Terms</span><textarea className={FLD} rows={3} maxLength={20000} value={editing.terms ?? ''} onChange={(e) => setEditing({ ...editing, terms: e.target.value })} /></label>
          <div className="flex gap-2 mt-4">
            <button className={BTN_PRIMARY} disabled={!editing.title?.trim()} onClick={() => saveRentalTemplate(orgId, editing, editing.id).then(() => { setEditing(null); load(); }).catch(onErr)}>Save</button>
            <button className={BTN} onClick={() => setEditing(null)}>Cancel</button>
          </div>
        </Section>
      )}
      <DataTable<RentalTemplateRow> label="Rental invoice templates" rows={rows} rowKey={(t) => t.id} searchFields={(t) => [t.title, t.payee_name]}
        statuses={TEMPLATE_STATUSES} status={(t) => t.status} defaultStatus="active" defaultSort={{ key: 'title', dir: 'asc' }}
        columns={[
          { key: 'title', header: 'Template', value: (t) => t.title, render: (t) => <span className="font-bold text-slate-900">{t.title}</span> },
          { key: 'lines', header: 'Lines', align: 'right', value: (t) => t.items.length, render: (t) => t.items.length },
          { key: 'total', header: 'Total', align: 'right', value: (t) => rentalTotals(t.items, t.attendance_count, t.discount_cents, t.tax_fees).total_cents,
            render: (t) => formatCents(rentalTotals(t.items, t.attendance_count, t.discount_cents, t.tax_fees).total_cents, t.currency) },
          { key: 'updated', header: 'Updated', value: (t) => t.updated_at, render: (t) => when(t.updated_at) },
          { key: 'status', header: 'Status', value: (t) => t.status, render: (t) => <StatusBadge status={t.status} /> },
        ]}
        actions={canEdit ? (t) => (<>
          <button className={BTN} onClick={() => setEditing(t)}>Edit</button>
          <button className={BTN} onClick={() => act(() => saveRentalTemplate(orgId, { status: t.status === 'active' ? 'archived' : 'active' }, t.id))}>{t.status === 'active' ? 'Archive' : 'Restore'}</button>
          <button className={BTN} aria-label={`Delete ${t.title}`} onClick={() => { if (window.confirm(`Delete ${t.title}?`)) act(() => deleteRentalTemplate(t.id)); }}><Trash2 size={12} /></button>
        </>) : undefined}
        empty="No rental templates yet." />
    </>
  );
}

// ---- Rental invoices ---------------------------------------------------------------------------------

function RentalInvoices({ orgId, role, isAdmin, canPrefix, onErr }: { orgId: string; role: string | null; isAdmin: boolean; canPrefix: boolean; onErr: ErrFn }) {
  const [rows, setRows] = useState<RentalInvoiceRow[]>([]);
  const [templates, setTemplates] = useState<RentalTemplateRow[]>([]);
  const [holds, setHolds] = useState<{ id: string; title: string; first_date: string | null }[]>([]);
  const [draft, setDraft] = useState<{ template_id: string; hold_id: string; bill_to_name: string; bill_to_email: string; rental_date: string } | null>(null);
  const [editing, setEditing] = useState<RentalInvoiceRow | null>(null);
  const [prefix, setPrefix] = useState('R-');
  const canWrite = rentalActions('draft', role, isAdmin).edit;
  const load = useCallback(() => listRentalInvoices(orgId).then(setRows).catch(onErr), [orgId, onErr]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    listRentalTemplates(orgId).then((t) => setTemplates(t.filter((x) => x.status === 'active'))).catch(() => {});
    getRentalPrefix(orgId).then(setPrefix).catch(() => {});
    supabase.from('exos_holds').select('id, title, first_date').eq('org_id', orgId).neq('status', 'cleared').order('first_date', { ascending: false }).limit(200)
      .then(({ data }) => setHolds((data ?? []) as typeof holds));
  }, [orgId]);
  const act = (f: () => Promise<unknown>) => f().then(load).catch(onErr);
  const holdName = useMemo(() => new Map(holds.map((h) => [h.id, h.title])), [holds]);

  const create = async () => {
    if (!draft) return;
    const body: Record<string, unknown> = {};
    if (draft.template_id) body.template_id = draft.template_id; else body.title = 'Rental';
    if (draft.hold_id) body.hold_id = draft.hold_id;
    if (draft.bill_to_name.trim()) body.bill_to_name = draft.bill_to_name.trim();
    if (draft.bill_to_email.trim()) body.bill_to_email = draft.bill_to_email.trim();
    if (draft.rental_date) body.rental_date = draft.rental_date;
    try {
      const r = await createRentalInvoice(orgId, body);
      setDraft(null);
      await load();
      setEditing(r);
    } catch (e) { onErr(e); }
  };

  return (
    <>
      {canWrite && !draft && !editing && (
        <div className="flex flex-wrap gap-2 items-end mb-4">
          <button className={BTN_PRIMARY} onClick={() => setDraft({ template_id: templates[0]?.id ?? '', hold_id: '', bill_to_name: '', bill_to_email: '', rental_date: '' })}><Plus size={12} className="inline mr-1" />New rental invoice</button>
          {canPrefix && (
            <label className="ml-auto flex items-end gap-2"><span className={LABEL}>Number prefix</span>
              <input className={`${FLD} w-28`} value={prefix} maxLength={16} onChange={(e) => setPrefix(e.target.value)} />
              <button className={BTN} onClick={() => setRentalPrefix(orgId, prefix).then(setPrefix).catch(onErr)}>Set</button>
            </label>
          )}
        </div>
      )}
      {draft && (
        <Section title="New rental invoice">
          <div className="grid gap-3 sm:grid-cols-3">
            <label><span className={LABEL}>Template</span><select className={FLD} value={draft.template_id} onChange={(e) => setDraft({ ...draft, template_id: e.target.value })}>
              <option value="">None (blank)</option>{templates.map((t) => <option key={t.id} value={t.id}>{t.title}</option>)}</select></label>
            <label><span className={LABEL}>Hold</span><select className={FLD} value={draft.hold_id} onChange={(e) => setDraft({ ...draft, hold_id: e.target.value })}>
              <option value="">None</option>{holds.map((h) => <option key={h.id} value={h.id}>{h.title}{h.first_date ? ` · ${h.first_date}` : ''}</option>)}</select></label>
            <label><span className={LABEL}>Rental date</span><input className={FLD} type="date" value={draft.rental_date} onChange={(e) => setDraft({ ...draft, rental_date: e.target.value })} /></label>
            <label><span className={LABEL}>Bill to</span><input className={FLD} value={draft.bill_to_name} maxLength={200} onChange={(e) => setDraft({ ...draft, bill_to_name: e.target.value })} /></label>
            <label><span className={LABEL}>Email</span><input className={FLD} type="email" value={draft.bill_to_email} maxLength={200} onChange={(e) => setDraft({ ...draft, bill_to_email: e.target.value })} /></label>
          </div>
          <div className="flex gap-2 mt-4"><button className={BTN_PRIMARY} onClick={create}>Create draft</button><button className={BTN} onClick={() => setDraft(null)}>Cancel</button></div>
        </Section>
      )}
      {editing && (
        <Section title={`Edit draft: ${editing.title}`}>
          <div className="grid gap-3 sm:grid-cols-3 mb-3">
            <label><span className={LABEL}>Title</span><input className={FLD} value={editing.title} maxLength={100} onChange={(e) => setEditing({ ...editing, title: e.target.value })} /></label>
            <label><span className={LABEL}>Bill to</span><input className={FLD} value={editing.bill_to_name ?? ''} maxLength={200} onChange={(e) => setEditing({ ...editing, bill_to_name: e.target.value || null })} /></label>
            <label><span className={LABEL}>Email</span><input className={FLD} type="email" value={editing.bill_to_email ?? ''} maxLength={200} onChange={(e) => setEditing({ ...editing, bill_to_email: e.target.value || null })} /></label>
            <label><span className={LABEL}>Due</span><input className={FLD} type="date" value={editing.due_on ?? ''} onChange={(e) => setEditing({ ...editing, due_on: e.target.value || null })} /></label>
          </div>
          <LinesEditor value={linesOf(editing)} onChange={(l) => setEditing({ ...editing, ...l })} />
          <div className="flex gap-2 mt-4">
            <button className={BTN_PRIMARY} disabled={!editing.title.trim()} onClick={() => updateRentalInvoice(editing.id, {
              title: editing.title, bill_to_name: editing.bill_to_name, bill_to_email: editing.bill_to_email, due_on: editing.due_on,
              currency: editing.currency, attendance_count: editing.attendance_count, discount_cents: editing.discount_cents,
              items: editing.items, tax_fees: editing.tax_fees, deposits: editing.deposits,
            }).then(() => { setEditing(null); load(); }).catch(onErr)}>Save draft</button>
            <button className={BTN} onClick={() => setEditing(null)}>Close</button>
          </div>
        </Section>
      )}
      <DataTable<RentalInvoiceRow> label="Rental invoices" rows={rows} rowKey={(i) => i.id}
        searchFields={(i) => [i.number, i.title, i.bill_to_name, i.bill_to_email, i.hold_id ? holdName.get(i.hold_id) : null]} searchPlaceholder="Search number, title, bill to"
        statuses={['draft', 'issued', 'paid', 'void']} status={(i) => i.status} defaultSort={{ key: 'created', dir: 'desc' }}
        columns={[
          { key: 'number', header: 'Number', value: (i) => i.number_seq, render: (i) => i.number ?? <span className="text-slate-400">draft</span> },
          { key: 'title', header: 'Invoice', value: (i) => i.title, render: (i) => <><p className="font-bold text-slate-900">{i.title}</p>{i.hold_id && <p className="text-xs text-slate-400">{holdName.get(i.hold_id) ?? 'Hold'}</p>}</> },
          { key: 'bill', header: 'Bill to', value: (i) => i.bill_to_name, render: (i) => i.bill_to_name ?? '—' },
          { key: 'date', header: 'Rental date', value: (i) => i.rental_date, render: (i) => i.rental_date ?? '—' },
          { key: 'total', header: 'Total', align: 'right', value: (i) => i.total_cents, render: (i) => formatCents(i.total_cents, i.currency) },
          { key: 'created', header: 'Created', value: (i) => i.created_at, render: (i) => when(i.created_at) },
          { key: 'status', header: 'Status', value: (i) => i.status, render: (i) => <StatusBadge status={i.status} /> },
        ]}
        actions={(i) => {
          const a = rentalActions(i.status, role, isAdmin);
          return (<>
            {a.edit && <button className={BTN} onClick={() => setEditing(i)}>Edit</button>}
            {a.issue && <button className={BTN} onClick={() => { if (window.confirm('Issue this invoice? It gets the next number and can no longer be edited.')) act(() => issueRentalInvoice(i.id)); }}>Issue</button>}
            {a.pay && <button className={BTN} onClick={() => act(() => setRentalInvoiceStatus(i.id, 'paid'))}>Mark paid</button>}
            {a.unpay && <button className={BTN} onClick={() => act(() => setRentalInvoiceStatus(i.id, 'issued'))}>Unmark paid</button>}
            {a.void && <button className={BTN} onClick={() => { const why = window.prompt('Void this invoice? It keeps its number. Reason (optional):'); if (why !== null) act(() => setRentalInvoiceStatus(i.id, 'void', why)); }}>Void</button>}
            {a.delete && <button className={BTN} aria-label={`Delete ${i.title}`} onClick={() => { if (window.confirm('Delete this draft?')) act(() => deleteRentalInvoice(i.id)); }}><Trash2 size={12} /></button>}
          </>);
        }}
        empty="No rental invoices yet." />
    </>
  );
}
