// /orgs/:orgId/groups — the organizer's social groups (mig 20261031230000,
// docs/group-chat.md): create a group, set when its chat closes and its daily
// text cap, review reports. Staff never read chats by default; reading one
// for moderation asks for a reason and is logged.

import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Eye, Flag } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { listOrgEvents } from '../lib/events';
import {
  createGroup, moderate, moderationRead, openReports, orgGroups, updateGroupSettings, closesLabel,
  type ModerationRow, type OpenReport, type OrgGroup,
} from '../lib/groupChat';

const btn = 'type text-[11px] uppercase tracking-widest border border-white/20 px-3 py-2 text-white/80 hover:border-brand-primary hover:text-brand-primary disabled:opacity-40';
const input = 'bg-black border border-white/20 px-3 py-2 text-base sm:text-xs text-white min-w-0';

export default function OrgGroups() {
  const { orgId = '' } = useParams();
  const { toast } = useToast();
  const [groups, setGroups] = useState<OrgGroup[]>([]);
  const [reports, setReports] = useState<OpenReport[] | null>(null);
  const [events, setEvents] = useState<{ id: string; title: string }[]>([]);
  const [title, setTitle] = useState('');
  const [kind, setKind] = useState('event_attendees');
  const [eventId, setEventId] = useState('');
  const [days, setDays] = useState(7);
  const [cap, setCap] = useState(300);
  const [reading, setReading] = useState<{ group: OrgGroup; rows: ModerationRow[] } | null>(null);
  const fail = useCallback((e: unknown) => toast({ kind: 'error', message: (e as Error).message }), [toast]);

  const load = useCallback(() => orgGroups(orgId).then(setGroups).catch(fail), [orgId, fail]);
  useEffect(() => {
    void load();
    listOrgEvents(orgId).then((es) => setEvents(es.map((e) => ({ id: e.id, title: e.title })))).catch(() => {});
  }, [orgId, load]);

  const create = async (e: FormEvent) => {
    e.preventDefault();
    try {
      await createGroup(orgId, title, kind, eventId, days, cap);
      setTitle('');
      toast({ kind: 'success', message: 'Group created.' });
      await load();
    } catch (err) { fail(err); }
  };

  return (
    <div className="wall min-h-screen px-4 py-8 sm:px-8">
      <div className="max-w-4xl mx-auto space-y-8">
        <div className="flex items-center gap-3">
          <Link to={`/orgs/${orgId}/settings`} aria-label="Back" className="text-white/60 hover:text-white"><ArrowLeft className="w-5 h-5" /></Link>
          <h1 className="disp text-3xl tracking-tight">Group chats</h1>
        </div>

        <form onSubmit={create} className="border border-white/10 p-4 grid gap-3 sm:grid-cols-2">
          <label className="grid gap-1"><span className="type text-[10px] uppercase tracking-widest text-white/50">Title</span>
            <input className={input} value={title} maxLength={80} onChange={(e) => setTitle(e.target.value)} required /></label>
          <label className="grid gap-1"><span className="type text-[10px] uppercase tracking-widest text-white/50">Kind</span>
            <select className={input} value={kind} onChange={(e) => setKind(e.target.value)}>
              <option value="event_attendees">Event attendees (ticket holders join)</option>
              <option value="matched_table">Matched table (you add people)</option>
              <option value="community">Community (anyone can join)</option>
              <option value="custom">Invite only</option>
            </select></label>
          <label className="grid gap-1"><span className="type text-[10px] uppercase tracking-widest text-white/50">Event</span>
            <select className={input} value={eventId} onChange={(e) => setEventId(e.target.value)} required>
              <option value="" disabled>Pick an event</option>
              {events.map((ev) => <option key={ev.id} value={ev.id}>{ev.title}</option>)}
            </select></label>
          <div className="grid grid-cols-2 gap-3">
            <label className="grid gap-1"><span className="type text-[10px] uppercase tracking-widest text-white/50">Close days after event</span>
              <input className={input} type="number" min={0} max={90} value={days} onChange={(e) => setDays(Number(e.target.value))} /></label>
            <label className="grid gap-1"><span className="type text-[10px] uppercase tracking-widest text-white/50">Texts per day (segments)</span>
              <input className={input} type="number" min={0} max={5000} value={cap} onChange={(e) => setCap(Number(e.target.value))} /></label>
          </div>
          <div className="sm:col-span-2"><button type="submit" className={btn}>Create group</button></div>
        </form>

        <section>
          <h2 className="type text-[11px] uppercase tracking-widest text-white/60 mb-2">Groups</h2>
          <div className="overflow-x-auto border border-white/10">
            <table className="w-full text-sm">
              <thead className="type text-[10px] uppercase tracking-widest text-white/50 text-left">
                <tr><th className="p-2">Group</th><th className="p-2">Members</th><th className="p-2">Texts 24 h</th><th className="p-2">Close after</th><th className="p-2">Daily cap</th><th className="p-2" /></tr>
              </thead>
              <tbody className="divide-y divide-white/10">
                {groups.map((g) => (
                  <tr key={g.id}>
                    <td className="p-2"><span className="text-white">{g.title}</span>
                      <span className="type block text-[10px] text-white/40">{g.kind} · {closesLabel(g.closesAt) ?? 'open'}{g.openReports ? ` · ${g.openReports} reports` : ''}</span></td>
                    <td className="p-2 text-white/80">{g.members} ({g.smsMembers} by text)</td>
                    <td className="p-2 text-white/80">{g.smsSegments24h}</td>
                    <td className="p-2"><input aria-label="Close after days" className={`${input} w-16`} type="number" min={0} max={90} defaultValue={g.closeAfterDays}
                      onBlur={(e) => Number(e.target.value) !== g.closeAfterDays && updateGroupSettings(g.id, { closeAfterDays: Number(e.target.value) }).then(load).catch(fail)} /></td>
                    <td className="p-2"><input aria-label="Daily text cap" className={`${input} w-20`} type="number" min={0} max={5000} defaultValue={g.dailySmsCap}
                      onBlur={(e) => Number(e.target.value) !== g.dailySmsCap && updateGroupSettings(g.id, { dailySmsCap: Number(e.target.value) }).then(load).catch(fail)} /></td>
                    <td className="p-2">
                      <button type="button" className="type text-[10px] text-white/50 hover:text-white flex items-center gap-1" onClick={async () => {
                        const reason = window.prompt('Why are you reading this chat? (logged)');
                        if (!reason) return;
                        try { setReading({ group: g, rows: await moderationRead(g.id, reason) }); } catch (e) { fail(e); }
                      }}><Eye className="w-3 h-3" aria-hidden="true" /> Read (logged)</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>

        {reading && (
          <section className="border border-white/10 p-4">
            <div className="flex items-center justify-between mb-2">
              <h2 className="type text-[11px] uppercase tracking-widest text-white/60">{reading.group.title} (moderation view)</h2>
              <button type="button" className={btn} onClick={() => setReading(null)}>Close</button>
            </div>
            <ul className="space-y-2 max-h-96 overflow-y-auto">
              {reading.rows.map((m) => (
                <li key={m.id} className="text-sm">
                  <span className="type text-[10px] text-white/40">{m.senderName} · {m.createdAt.toLocaleString()}{m.hidden ? ' · hidden' : ''}{m.reports ? ` · ${m.reports} reports` : ''}</span>
                  <p className="text-white/90 whitespace-pre-wrap break-words">{m.body}</p>
                  {m.senderId && (
                    <button type="button" className="type text-[10px] text-white/50 hover:text-white" onClick={async () => {
                      const reason = window.prompt('Reason for hiding (logged)');
                      if (!reason) return;
                      try { await moderate(reading.group.id, m.hidden ? 'unhide_message' : 'hide_message', reason, m.id); setReading(null); await load(); } catch (e) { fail(e); }
                    }}>{m.hidden ? 'Unhide' : 'Hide'}</button>
                  )}
                </li>
              ))}
            </ul>
          </section>
        )}

        <section>
          <div className="flex items-center gap-3 mb-2">
            <h2 className="type text-[11px] uppercase tracking-widest text-white/60">Reports</h2>
            <button type="button" className={`${btn} flex items-center gap-1`} onClick={() => openReports(orgId).then(setReports).catch(fail)}>
              <Flag className="w-3 h-3" aria-hidden="true" /> Review open reports (logged)</button>
          </div>
          {reports?.length === 0 && <p className="type text-xs text-white/50">No open reports.</p>}
          <ul className="space-y-3">
            {reports?.map((r) => (
              <li key={r.id} className="border border-white/10 p-3">
                <p className="type text-[10px] text-white/40">{r.groupTitle} · {r.senderName} · reported "{r.reason}"{r.hidden ? ' · hidden' : ''}</p>
                <p className="text-sm text-white whitespace-pre-wrap break-words my-1">{r.body}</p>
                <div className="flex gap-2">
                  <button type="button" className={btn} onClick={async () => {
                    try { await moderate(r.groupId, 'hide_message', `report: ${r.reason}`.slice(0, 300), r.messageId); setReports(await openReports(orgId)); } catch (e) { fail(e); }
                  }}>Hide</button>
                  <button type="button" className={btn} onClick={async () => {
                    try { await moderate(r.groupId, 'dismiss_report', 'reviewed, no action', r.messageId); setReports(await openReports(orgId)); } catch (e) { fail(e); }
                  }}>Dismiss</button>
                </div>
              </li>
            ))}
          </ul>
        </section>
      </div>
    </div>
  );
}
