// /orgs/:orgId/booking-requests — the inbox of booking requests from the
// public form (/book/<org slug>) and the API (mig 20261102130000,
// docs/templates-inbound.md). Content staff review; owners and managers also
// hold dates, delete and set up the form. Nobody else sees requests.

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, ExternalLink, Trash2 } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { getOrganization, getUserRoleInOrg } from '../lib/orgs';
import { listVenues } from '../lib/bookingApi';
import DataTable from '../components/DataTable';
import { BTN, BTN_PRIMARY, FLD, LABEL, Section, StatusBadge } from '../components/finance/ui';
import {
  deleteInbound, getInboundSettings, holdFromInbound, listInbound, saveInboundSettings, setInboundStatus,
  type InboundRow, type InboundSettings,
} from '../lib/templatesApi';
import { inboundActions, inboundFormPath, INBOUND_STATUSES, type InboundStatus } from '../lib/inbound';

export default function OrgInbound() {
  const { orgId } = useParams();
  const { user, isAdmin } = useAuth();
  const { toast } = useToast();
  const [role, setRole] = useState<string | null | undefined>(undefined);
  const [org, setOrg] = useState<{ name: string; slug: string } | null>(null);
  const [rows, setRows] = useState<InboundRow[]>([]);
  const [venues, setVenues] = useState<{ id: string; name: string }[]>([]);
  const [settings, setSettings] = useState<Omit<InboundSettings, 'org_id'> | null>(null);
  const [open, setOpen] = useState<InboundRow | null>(null);
  const r = isAdmin ? 'owner' : role ?? null;
  const base = inboundActions(r, !!isAdmin);
  const onErr = useCallback((e: unknown) => toast({ kind: 'error', message: (e as Error).message }), [toast]);

  useEffect(() => {
    if (!orgId || !user?.uid) return;
    getOrganization(orgId).then((o) => setOrg(o ? { name: o.name, slug: o.slug } : null)).catch(() => {});
    getUserRoleInOrg(orgId, user.uid).then(setRole).catch(() => setRole(null));
  }, [orgId, user?.uid]);
  const load = useCallback(() => {
    if (!orgId || !base.review) return;
    listInbound(orgId).then(setRows).catch(onErr);
  }, [orgId, base.review, onErr]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    if (!orgId || !base.review) return;
    listVenues(orgId).then((v) => setVenues(v.map((x) => ({ id: x.id, name: x.name })))).catch(() => {});
    getInboundSettings(orgId).then((s) => setSettings(s ?? { enabled: false, title: null, intro: null, venue_ids: [] })).catch(() => {});
  }, [orgId, base.review]);
  const venueName = useMemo(() => new Map(venues.map((v) => [v.id, v.name])), [venues]);

  if (role === undefined && !isAdmin) return <div className="p-8 text-sm text-slate-500">Loading…</div>;
  if (!base.review || !orgId) return <div className="p-8 text-sm text-slate-500">Booking requests are for owners, managers and content staff.</div>;

  const act = (f: () => Promise<unknown>) => f().then(load).catch(onErr);
  const formUrl = org ? `${window.location.origin}${inboundFormPath(org.slug)}` : '';

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <Link to="/dashboard" className="inline-flex items-center gap-1 text-xs text-slate-500 hover:text-slate-900 mb-4"><ArrowLeft size={14} /> Dashboard</Link>
      <h1 className="text-2xl font-black text-slate-900 mb-1">Booking requests</h1>
      <p className="text-sm text-slate-500 mb-6">{org?.name} · artists and agents asking to play. Review them, hold dates, or decline.</p>

      {base.settings && settings && (
        <Section title="Public form" action={settings.enabled && org ? <a className={`${BTN} inline-flex items-center gap-1`} href={inboundFormPath(org.slug)} target="_blank" rel="noreferrer">Open <ExternalLink size={10} /></a> : undefined}>
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={settings.enabled} onChange={(e) => setSettings({ ...settings, enabled: e.target.checked })} />Take booking requests at <code className="text-xs">{formUrl}</code></label>
            <label><span className={LABEL}>Title</span><input className={FLD} value={settings.title ?? ''} maxLength={120} placeholder={`Book a show with ${org?.name ?? 'us'}`} onChange={(e) => setSettings({ ...settings, title: e.target.value || null })} /></label>
            <label className="sm:col-span-2"><span className={LABEL}>Intro</span><textarea className={FLD} rows={2} maxLength={2000} value={settings.intro ?? ''} onChange={(e) => setSettings({ ...settings, intro: e.target.value || null })} /></label>
            {venues.length > 0 && (
              <fieldset className="sm:col-span-2"><legend className={LABEL}>Venues offered (none ticked: all)</legend>
                <div className="flex flex-wrap gap-3 mt-1">
                  {venues.map((v) => (
                    <label key={v.id} className="flex items-center gap-1 text-sm"><input type="checkbox" checked={settings.venue_ids.includes(v.id)}
                      onChange={(e) => setSettings({ ...settings, venue_ids: e.target.checked ? [...settings.venue_ids, v.id] : settings.venue_ids.filter((x) => x !== v.id) })} />{v.name}</label>
                  ))}
                </div>
              </fieldset>
            )}
          </div>
          <button className={`${BTN_PRIMARY} mt-3`} onClick={() => saveInboundSettings(orgId, settings).then(() => toast({ kind: 'success', message: 'Form saved.' })).catch(onErr)}>Save form</button>
          <p className="text-xs text-slate-400 mt-2">Requests are limited per network and per email address, and a hidden field turns away most bots.</p>
        </Section>
      )}

      {open && <Detail row={open} venues={venues} role={r} isAdmin={!!isAdmin} onClose={() => setOpen(null)} onErr={onErr}
        onChanged={() => { setOpen(null); load(); }} />}

      <DataTable<InboundRow> label="Booking requests" rows={rows} rowKey={(x) => x.id}
        searchFields={(x) => [x.artist_name, x.contact_name, x.email, x.company, x.message, x.genres.join(' ')]} searchPlaceholder="Search act, contact, message"
        statuses={INBOUND_STATUSES} status={(x) => x.status} defaultStatus="new" defaultSort={{ key: 'received', dir: 'desc' }}
        onRowClick={(x) => setOpen(x)}
        columns={[
          { key: 'artist', header: 'Act', value: (x) => x.artist_name, render: (x) => <><p className="font-bold text-slate-900">{x.artist_name}</p>{x.genres.length > 0 && <p className="text-xs text-slate-400">{x.genres.join(', ')}</p>}</> },
          { key: 'contact', header: 'Contact', value: (x) => x.contact_name ?? x.email, render: (x) => <>{x.contact_name ?? '—'}{x.contact_role ? <span className="text-xs text-slate-400"> · {x.contact_role}</span> : null}<p className="text-xs text-slate-400">{x.email}</p></> },
          { key: 'venue', header: 'Venue', value: (x) => (x.venue_id ? venueName.get(x.venue_id) : null), render: (x) => (x.venue_id ? venueName.get(x.venue_id) ?? '—' : 'Any') },
          { key: 'dates', header: 'Dates', value: (x) => x.preferred_dates[0], render: (x) => x.preferred_dates.join(', ') || (x.dates_flexible ? 'Flexible' : '—') },
          { key: 'draw', header: 'Draw', align: 'right', value: (x) => x.expected_draw, render: (x) => x.expected_draw ?? '—' },
          { key: 'received', header: 'Received', value: (x) => x.created_at, render: (x) => new Date(x.created_at).toLocaleDateString() },
          { key: 'status', header: 'Status', value: (x) => x.status, render: (x) => <StatusBadge status={x.status} /> },
        ]}
        actions={(x) => (<>
          {x.status === 'new' && <button className={BTN} onClick={() => act(() => setInboundStatus(x.id, 'reviewing'))}>Review</button>}
          {x.status !== 'declined' && x.status !== 'accepted' && <button className={BTN} onClick={() => act(() => setInboundStatus(x.id, 'declined'))}>Decline</button>}
          {base.delete && <button className={BTN} aria-label={`Delete request from ${x.artist_name}`} onClick={() => { if (window.confirm(`Delete the request from ${x.artist_name}?`)) act(() => deleteInbound(x.id)); }}><Trash2 size={12} /></button>}
        </>)}
        empty="No booking requests here." />
    </div>
  );
}

function Detail({ row, venues, role, isAdmin, onClose, onChanged, onErr }: {
  row: InboundRow; venues: { id: string; name: string }[]; role: string | null; isAdmin: boolean;
  onClose: () => void; onChanged: () => void; onErr: (e: unknown) => void;
}) {
  const a = inboundActions(role, isAdmin, !!row.hold_id);
  const [status, setStatus] = useState<InboundStatus>(row.status);
  const [note, setNote] = useState(row.staff_note);
  const [venue, setVenue] = useState(row.venue_id ?? venues[0]?.id ?? '');
  const [dates, setDates] = useState(row.preferred_dates.join(', '));
  const dateList = dates.split(',').map((d) => d.trim()).filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d));
  return (
    <Section title={`Request: ${row.artist_name}`} action={<button className={BTN} onClick={onClose}>Close</button>}>
      <div className="grid gap-4 sm:grid-cols-2 text-sm">
        <div className="space-y-1">
          <p><span className={LABEL}>Contact </span>{row.contact_name ?? '—'}{row.contact_role ? ` (${row.contact_role})` : ''}{row.company ? `, ${row.company}` : ''}</p>
          <p><span className={LABEL}>Email </span>{row.email ? <a className="text-[#026cdf]" href={`mailto:${row.email}`}>{row.email}</a> : '—'}{row.phone ? ` · ${row.phone}` : ''}</p>
          <p><span className={LABEL}>Links </span>{Object.entries(row.links).map(([k, v]) => <a key={k} className="text-[#026cdf] mr-2" href={v} target="_blank" rel="noreferrer noopener">{k}</a>)}{!Object.keys(row.links).length && '—'}</p>
          <p><span className={LABEL}>Source </span>{row.source}{row.hold_id ? ' · hold made' : ''}</p>
          <p className="whitespace-pre-wrap text-slate-700 mt-2">{row.message || <span className="text-slate-400">No message.</span>}</p>
        </div>
        <div>
          <label className="block mb-2"><span className={LABEL}>Status</span>
            <select className={FLD} value={status} onChange={(e) => setStatus(e.target.value as InboundStatus)}>
              {INBOUND_STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
            </select></label>
          <label className="block mb-2"><span className={LABEL}>Staff note</span><textarea className={FLD} rows={3} maxLength={2000} value={note} onChange={(e) => setNote(e.target.value)} /></label>
          <button className={BTN_PRIMARY} onClick={() => setInboundStatus(row.id, status === row.status ? null : status, note).then(onChanged).catch(onErr)}>Save review</button>
          {a.hold && venues.length > 0 && (
            <div className="mt-4 border-t border-slate-100 pt-3">
              <p className={`${LABEL} mb-1`}>Hold dates</p>
              <div className="grid gap-2 grid-cols-2">
                <select className={FLD} aria-label="Venue" value={venue} onChange={(e) => setVenue(e.target.value)}>{venues.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}</select>
                <input className={FLD} aria-label="Dates (YYYY-MM-DD, comma separated)" value={dates} onChange={(e) => setDates(e.target.value)} placeholder="2027-03-05, 2027-03-06" />
              </div>
              <button className={`${BTN} mt-2`} disabled={!venue || !dateList.length}
                onClick={() => holdFromInbound(row.id, venue, dateList).then(onChanged).catch(onErr)}>Hold {dateList.length || ''} date{dateList.length === 1 ? '' : 's'} and accept</button>
            </div>
          )}
        </div>
      </div>
    </Section>
  );
}
