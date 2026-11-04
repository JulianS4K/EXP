// /orgs/:orgId/venue-requests — booking requests between organizations
// (mig 20261104180000, docs/org-access.md).
//   * Received: a promoter asks for a date at a venue this org runs. Owners
//     and managers approve (a hold, or a draft event of this org) and choose
//     what the promoter may do on that event, or decline. Content staff see
//     the table.
//   * Sent: this org asks another org's venue (search the directory).
//   * Shared events: the grants this org gave (change or revoke them), and the
//     events other venues shared with this org.

import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { getUserRoleInOrg } from '../lib/orgs';
import DataTable from '../components/DataTable';
import { BTN, BTN_PRIMARY, FLD, LABEL, Section, StatusBadge } from '../components/finance/ui';
import {
  createVenueRequest, decideVenueRequest, DEFAULT_GRANT_SCOPES, GRANT_SCOPE_INFO, GRANT_SCOPES, listCohostedEvents,
  listPartnerGrants, listVenueRequests, revokePartnerGrant, searchVenueDirectory, setPartnerGrant,
  type CohostedEvent, type DirectoryVenue, type GrantScope, type PartnerGrant, type VenueRequest,
} from '../lib/orgAccess';

const STATUSES = ['pending', 'approved', 'declined', 'withdrawn'] as const;
type Tab = 'received' | 'sent' | 'shared';

function errText(e: unknown): string {
  return String((e as { message?: string })?.message ?? e).replace(/^[a-z_]+: /, '').slice(0, 240);
}

export default function OrgVenueRequests() {
  const { orgId } = useParams();
  const { user, isAdmin } = useAuth();
  const { toast } = useToast();
  const [role, setRole] = useState<string | null | undefined>(undefined);
  const [tab, setTab] = useState<Tab>('received');
  const [received, setReceived] = useState<VenueRequest[]>([]);
  const [sent, setSent] = useState<VenueRequest[]>([]);
  const [grants, setGrants] = useState<PartnerGrant[]>([]);
  const [shared, setShared] = useState<CohostedEvent[]>([]);
  const [open, setOpen] = useState<VenueRequest | null>(null);
  const r = isAdmin ? 'owner' : role ?? null;
  const canSee = r === 'owner' || r === 'manager' || r === 'content';
  const canDecide = r === 'owner' || r === 'manager';
  const onErr = useCallback((e: unknown) => toast({ kind: 'error', message: errText(e) }), [toast]);

  useEffect(() => {
    if (!orgId || !user?.uid) return;
    getUserRoleInOrg(orgId, user.uid).then(setRole).catch(() => setRole(null));
  }, [orgId, user?.uid]);
  const load = useCallback(() => {
    if (!orgId || !canSee) return;
    listVenueRequests(orgId, 'received').then(setReceived).catch(onErr);
    listVenueRequests(orgId, 'sent').then(setSent).catch(onErr);
    listPartnerGrants(orgId).then(setGrants).catch(onErr);
    listCohostedEvents(orgId).then(setShared).catch(onErr);
  }, [orgId, canSee, onErr]);
  useEffect(() => { load(); }, [load]);

  if (role === undefined && !isAdmin) return <div className="p-8 text-sm text-slate-500">Loading…</div>;
  if (!canSee || !orgId) return <div className="p-8 text-sm text-slate-500">Venue requests are for owners, managers and content staff.</div>;

  const tabBtn = (t: Tab, label: string, n: number) => (
    <button key={t} type="button" role="tab" aria-selected={tab === t}
      className={`${tab === t ? BTN_PRIMARY : BTN} mr-2`} onClick={() => setTab(t)}>{label}{n ? ` (${n})` : ''}</button>
  );

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <Link to="/dashboard" className="inline-flex items-center gap-1 text-xs text-slate-500 hover:text-slate-900 mb-4"><ArrowLeft size={14} /> Dashboard</Link>
      <h1 className="text-2xl font-black text-slate-900 mb-1">Venue requests</h1>
      <p className="text-sm text-slate-500 mb-6">
        A venue another organization runs on Exos takes events through it. Promoters ask for a date here; the venue approves
        a hold or a draft event and decides what the promoter may do on it. The event stays the venue's: it sells, refunds and
        settles like the venue's other shows.
      </p>
      <div role="tablist" className="mb-4">
        {tabBtn('received', 'Received', received.filter((x) => x.status === 'pending').length)}
        {tabBtn('sent', 'Sent', 0)}
        {tabBtn('shared', 'Shared events', grants.filter((g) => !g.revoked_at).length + shared.length)}
      </div>

      {tab === 'received' && (<>
        {open && <Decide req={open} canDecide={canDecide} onClose={() => setOpen(null)} onErr={onErr}
          onDone={() => { setOpen(null); load(); }} />}
        <DataTable<VenueRequest> label="Requests received" rows={received} rowKey={(x) => x.id}
          searchFields={(x) => [x.title, x.requester_org.name, x.venue.name, x.message]} searchPlaceholder="Search show, promoter, venue"
          statuses={STATUSES} status={(x) => x.status} defaultStatus="pending" defaultSort={{ key: 'date', dir: 'asc' }}
          onRowClick={(x) => setOpen(x)}
          columns={[
            { key: 'title', header: 'Show', value: (x) => x.title, render: (x) => <><p className="font-bold text-slate-900">{x.title}</p><p className="text-xs text-slate-400">{x.requester_org.name}</p></> },
            { key: 'venue', header: 'Venue', value: (x) => x.venue.name, render: (x) => <>{x.venue.name}{x.room ? <span className="text-xs text-slate-400"> · {x.room.name}</span> : null}</> },
            { key: 'date', header: 'Date', value: (x) => x.date, render: (x) => <>{x.date}{x.start_time ? <span className="text-xs text-slate-400"> {x.start_time}</span> : null}</> },
            { key: 'draw', header: 'Draw', align: 'right', value: (x) => x.expected_draw, render: (x) => x.expected_draw ?? '—' },
            { key: 'status', header: 'Status', value: (x) => x.status, render: (x) => <StatusBadge status={x.status} /> },
          ]}
          empty="No requests here." />
      </>)}

      {tab === 'sent' && (<>
        {canDecide && <NewRequest orgId={orgId} onErr={onErr} onDone={() => { load(); toast({ kind: 'success', message: 'Request sent.' }); }} />}
        <DataTable<VenueRequest> label="Requests sent" rows={sent} rowKey={(x) => x.id}
          searchFields={(x) => [x.title, x.venue_org.name, x.venue.name]} searchPlaceholder="Search show, venue"
          statuses={STATUSES} status={(x) => x.status} defaultSort={{ key: 'date', dir: 'asc' }}
          columns={[
            { key: 'title', header: 'Show', value: (x) => x.title },
            { key: 'venue', header: 'Venue', value: (x) => x.venue.name, render: (x) => <>{x.venue.name}<p className="text-xs text-slate-400">{x.venue_org.name}</p></> },
            { key: 'date', header: 'Date', value: (x) => x.date },
            { key: 'status', header: 'Status', value: (x) => x.status, render: (x) => <><StatusBadge status={x.status} />{x.decline_reason ? <p className="text-xs text-slate-400">{x.decline_reason}</p> : null}</> },
            { key: 'grant', header: 'You may', value: (x) => x.grant?.scopes.join(' '), render: (x) => x.grant && !x.grant.revoked_at ? x.grant.scopes.join(', ') : '—' },
          ]}
          actions={(x) => canDecide && x.status === 'pending'
            ? <button className={BTN} onClick={() => decideVenueRequest(x.id, 'withdraw').then(load).catch(onErr)}>Withdraw</button>
            : null}
          empty="You haven't asked a venue yet." />
      </>)}

      {tab === 'shared' && (<>
        <Section title="Events you shared">
          <DataTable<PartnerGrant> label="Grants given" rows={grants} rowKey={(x) => x.id}
            searchFields={(x) => [x.event.name, x.grantee_org.name]}
            columns={[
              { key: 'event', header: 'Event', value: (x) => x.event.name },
              { key: 'org', header: 'Promoter', value: (x) => x.grantee_org.name },
              { key: 'scopes', header: 'May', value: (x) => x.scopes.join(' '), render: (x) => x.revoked_at ? <span className="text-slate-400">Revoked</span>
                : <GrantScopes value={x.scopes} disabled={!canDecide} onChange={(s) => setPartnerGrant(x.id, s).then(load).catch(onErr)} /> },
            ]}
            actions={(x) => canDecide && !x.revoked_at
              ? <button className={BTN} onClick={() => { if (window.confirm(`Revoke ${x.grantee_org.name}'s access to ${x.event.name}?`)) revokePartnerGrant(x.id).then(load).catch(onErr); }}>Revoke</button>
              : null}
            empty="No events shared." />
        </Section>
        <Section title="Events shared with you">
          <DataTable<CohostedEvent> label="Co-hosted events" rows={shared} rowKey={(x) => x.id}
            columns={[
              { key: 'event', header: 'Event', value: (x) => x.name, render: (x) => <><p className="font-bold">{x.name}</p><p className="text-xs text-slate-400">{x.venue_name}</p></> },
              { key: 'host', header: 'Venue', value: (x) => x.host_org.name },
              { key: 'starts', header: 'Starts', value: (x) => x.starts_at, render: (x) => (x.starts_at ? new Date(x.starts_at).toLocaleString() : '—') },
              { key: 'scopes', header: 'You may', value: (x) => x.scopes.join(', ') },
            ]}
            empty="No venue has shared an event with you yet." />
          <p className="text-xs text-slate-400 mt-2">Work on these through the API (/v1/cohosted-events) with a key that has the same scopes.</p>
        </Section>
      </>)}
    </div>
  );
}

function GrantScopes({ value, onChange, disabled }: { value: readonly string[]; onChange: (s: GrantScope[]) => void; disabled?: boolean }) {
  return (
    <div className="flex flex-wrap gap-2">
      {GRANT_SCOPES.map((s) => (
        <label key={s} className="flex items-center gap-1 text-xs" title={GRANT_SCOPE_INFO[s]}>
          <input type="checkbox" disabled={disabled} checked={value.includes(s)}
            onChange={(e) => onChange(GRANT_SCOPES.filter((x) => (x === s ? e.target.checked : value.includes(x))))} />{s}
        </label>
      ))}
    </div>
  );
}

function Decide({ req, canDecide, onClose, onDone, onErr }: {
  req: VenueRequest; canDecide: boolean; onClose: () => void; onDone: () => void; onErr: (e: unknown) => void;
}) {
  const [create, setCreate] = useState<'hold' | 'event'>('hold');
  const [scopes, setScopes] = useState<GrantScope[]>([...DEFAULT_GRANT_SCOPES]);
  const [reason, setReason] = useState('');
  return (
    <Section title={`${req.title} · ${req.requester_org.name}`} action={<button className={BTN} onClick={onClose}>Close</button>}>
      <div className="grid gap-4 sm:grid-cols-2 text-sm">
        <div className="space-y-1">
          <p><span className={LABEL}>Venue </span>{req.venue.name}{req.room ? ` · ${req.room.name}` : ''}</p>
          <p><span className={LABEL}>Date </span>{req.date}{req.start_time ? ` ${req.start_time}` : ''}</p>
          <p><span className={LABEL}>Expected draw </span>{req.expected_draw ?? '—'}</p>
          <p className="whitespace-pre-wrap text-slate-700 mt-2">{req.message || <span className="text-slate-400">No message.</span>}</p>
        </div>
        {canDecide && req.status === 'pending' ? (
          <div className="space-y-3">
            <fieldset><legend className={LABEL}>Approve as</legend>
              <label className="mr-4 text-sm"><input type="radio" checked={create === 'hold'} onChange={() => setCreate('hold')} /> A hold on your calendar</label>
              <label className="text-sm"><input type="radio" checked={create === 'event'} onChange={() => setCreate('event')} /> A draft event</label>
            </fieldset>
            <fieldset><legend className={LABEL}>The promoter may, on that event</legend>
              <GrantScopes value={scopes} onChange={setScopes} />
              <p className="text-xs text-slate-400 mt-1">Refunds and payouts stay with you.</p>
            </fieldset>
            <button className={BTN_PRIMARY} disabled={!scopes.length}
              onClick={() => decideVenueRequest(req.id, 'approve', { create, scopes }).then(onDone).catch(onErr)}>Approve</button>
            <div className="border-t border-slate-100 pt-3">
              <label className="block"><span className={LABEL}>Reason (shown to them)</span>
                <input className={FLD} maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} /></label>
              <button className={`${BTN} mt-2`} onClick={() => decideVenueRequest(req.id, 'decline', { reason: reason || null }).then(onDone).catch(onErr)}>Decline</button>
            </div>
          </div>
        ) : <p className="text-slate-500">{req.status === 'pending' ? 'Owners and managers decide.' : `This request is ${req.status}.`}</p>}
      </div>
    </Section>
  );
}

function NewRequest({ orgId, onDone, onErr }: { orgId: string; onDone: () => void; onErr: (e: unknown) => void }) {
  const [q, setQ] = useState('');
  const [found, setFound] = useState<DirectoryVenue[]>([]);
  const [venue, setVenue] = useState<DirectoryVenue | null>(null);
  const [room, setRoom] = useState('');
  const [date, setDate] = useState('');
  const [time, setTime] = useState('');
  const [title, setTitle] = useState('');
  const [message, setMessage] = useState('');
  const [draw, setDraw] = useState('');
  const search = () => searchVenueDirectory(orgId, q).then(setFound).catch(onErr);
  const send = () => createVenueRequest(orgId, {
    venue_id: venue!.id, room_id: room || null, date, start_time: time || null, title, message,
    expected_draw: draw ? Number(draw) : null,
  }).then(() => { setVenue(null); setTitle(''); setMessage(''); setDate(''); onDone(); }).catch(onErr);
  return (
    <Section title="Ask a venue for a date">
      <div className="flex gap-2 mb-3">
        <input className={FLD} placeholder="Venue name or city" value={q} onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') search(); }} aria-label="Search venues" />
        <button className={BTN} disabled={q.trim().length < 2} onClick={search}>Search</button>
      </div>
      {!venue && found.length > 0 && (
        <ul className="mb-3 text-sm">
          {found.map((v) => (
            <li key={v.id}><button className="text-[#026cdf] hover:underline" onClick={() => { setVenue(v); setRoom(''); }}>
              {v.name}{v.city ? `, ${v.city}` : ''}</button> <span className="text-xs text-slate-400">{v.org.name}</span></li>
          ))}
        </ul>
      )}
      {venue && (
        <div className="grid gap-3 sm:grid-cols-2">
          <p className="sm:col-span-2 text-sm"><span className={LABEL}>Venue </span>{venue.name} · {venue.org.name} <button className={BTN} onClick={() => setVenue(null)}>Change</button></p>
          {venue.rooms.length > 0 && (
            <label><span className={LABEL}>Room</span>
              <select className={FLD} value={room} onChange={(e) => setRoom(e.target.value)}>
                <option value="">The whole venue</option>
                {venue.rooms.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
              </select></label>
          )}
          <label><span className={LABEL}>Date</span><input className={FLD} type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
          <label><span className={LABEL}>Start (venue time)</span><input className={FLD} type="time" value={time} onChange={(e) => setTime(e.target.value)} /></label>
          <label><span className={LABEL}>Show</span><input className={FLD} maxLength={100} value={title} onChange={(e) => setTitle(e.target.value)} /></label>
          <label><span className={LABEL}>Expected draw</span><input className={FLD} type="number" min={0} value={draw} onChange={(e) => setDraw(e.target.value)} /></label>
          <label className="sm:col-span-2"><span className={LABEL}>Message</span><textarea className={FLD} rows={2} maxLength={2000} value={message} onChange={(e) => setMessage(e.target.value)} /></label>
          <div><button className={BTN_PRIMARY} disabled={!date || !title.trim()} onClick={send}>Send request</button></div>
        </div>
      )}
    </Section>
  );
}
