// Share an Exos ticket type's count with an EXISTING Eventbrite ticket class
// (mig 20261014110000). Eventbrite sales take seats from Exos, and Exos keeps
// that class's capacity so Eventbrite has the shared count left to sell, one
// order's worth held back. Exos never creates ticket classes on Eventbrite.

import { useCallback, useEffect, useState } from 'react';
import { Loader2 } from 'lucide-react';
import {
  fetchInventoryStatus, listEbTicketClasses, mapEbTicketClass, mappingLine, setEbWrites, unshareable,
  type EbInventoryStatus, type EbMapping, type EbTicketClassChoice,
} from '../lib/door/eventbrite';

export default function EventbriteInventory({ eventId, orgId }: { eventId: string; orgId: string }) {
  const [status, setStatus] = useState<EbInventoryStatus | null | undefined>(undefined);
  const [classes, setClasses] = useState<EbTicketClassChoice[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<{ text: string; ok: boolean } | null>(null);

  const load = useCallback(async () => {
    try {
      setStatus(await fetchInventoryStatus(eventId));
    } catch (err) {
      console.warn('eventbrite inventory unavailable', err);
      setStatus(null);
    }
  }, [eventId]);
  useEffect(() => { void load(); }, [load]);

  const run = async (what: string, fn: () => Promise<string | void>) => {
    setBusy(what);
    setNote(null);
    try {
      const text = await fn();
      if (text) setNote({ text, ok: true });
    } catch (err) {
      setNote({ text: (err as Error)?.message || 'Something went wrong.', ok: false });
    } finally {
      setBusy(null);
      void load();
    }
  };

  if (!status || !status.linked) return null;
  const btn = 'inline-flex items-center gap-1.5 px-3 py-2 rounded-lg text-[11px] font-bold disabled:opacity-50';
  const byClass = new Map<string, EbMapping>(status.mappings.map((m) => [m.ebTicketClassId, m]));
  const tierName = (id: string) => status.tiers.find((t) => t.id === id)?.name ?? 'Ticket type';

  return (
    <div className="space-y-2 border-t border-slate-200 pt-3">
      <p className="font-bold text-slate-800">One count for Exos and Eventbrite</p>
      <p>
        Pick which Exos ticket type each Eventbrite ticket sells from. Eventbrite sales then take seats from that
        ticket type, and Exos keeps the Eventbrite ticket's capacity so it only has what's left to sell, minus one
        order's worth. Exos only changes that capacity on Eventbrite, never creates tickets there.
      </p>
      <p className={status.writesEnabled ? 'text-emerald-700' : 'text-amber-700'}>
        Sending to Eventbrite is {status.writesEnabled ? 'on for your organization' : 'off: Exos shows what it would set, and sends nothing'}.
        {status.canSwitch && (
          <button type="button" disabled={busy !== null} className="ml-2 underline"
            onClick={() => {
              if (!status.writesEnabled && !window.confirm('Let Exos set the capacity of the mapped Eventbrite tickets? Nothing else on Eventbrite is changed.')) return;
              void run('writes', async () => {
                const r = await setEbWrites(orgId, !status.writesEnabled);
                return r.writes_enabled
                  ? (r.live ? 'Sending is on.' : 'Switched on. Exos turns on sending for every organization once Eventbrite writes are enabled; until then it stays a dry run.')
                  : 'Sending is off.';
              });
            }}>
            {status.writesEnabled ? 'Turn off' : 'Turn on'}
          </button>
        )}
      </p>

      {status.mappings.length > 0 && (
        <ul className="space-y-1">
          {status.mappings.map((m) => (
            <li key={m.ebTicketClassId}>
              <strong className="text-slate-900">{m.ebTicketClassName ?? `Ticket ${m.ebTicketClassId}`}</strong> ↔ {tierName(m.tierId)}:{' '}
              <span className={m.lastError ? 'text-rose-500' : ''}>{mappingLine(m, status.writesEnabled)}</span>
              {m.oversold > 0 && (
                <span className="block text-rose-600">
                  Eventbrite sold {m.oversold} more than Exos had left. Check those orders.
                </span>
              )}
            </li>
          ))}
        </ul>
      )}

      {classes === null ? (
        <button type="button" disabled={busy !== null} className={`${btn} border border-slate-200 text-slate-700`}
          onClick={() => void run('classes', async () => {
            const list = await listEbTicketClasses(eventId);
            setClasses(list);
            return list.length === 0 ? 'That Eventbrite event has no tickets yet. Add them on Eventbrite first.' : undefined;
          })}>
          {busy === 'classes' && <Loader2 className="w-3 h-3 animate-spin" />} Choose tickets to share
        </button>
      ) : (
        <ul className="space-y-2">
          {classes.map((c) => {
            const m = byClass.get(c.id);
            const why = unshareable(c);
            return (
              <li key={c.id} className="flex flex-wrap items-center gap-2">
                <span className="min-w-[10rem] text-slate-800">
                  {c.name ?? `Ticket ${c.id}`}{c.free ? ' (free)' : ''}{c.hidden ? ' (hidden)' : ''}
                </span>
                {why ? (
                  <span className="text-slate-400">{why}</span>
                ) : (
                  <select aria-label={`Exos ticket type for ${c.name ?? c.id}`} disabled={busy !== null}
                    value={m?.tierId ?? ''}
                    onChange={(e) => {
                      const tier = e.target.value || null;
                      void run(`map-${c.id}`, async () => {
                        await mapEbTicketClass(eventId, c.id, c.name, tier);
                        return tier ? `${c.name ?? 'Ticket'} now sells from ${tierName(tier)}.` : `${c.name ?? 'Ticket'} no longer shares a count.`;
                      });
                    }}
                    className="border border-slate-200 rounded-lg px-2 py-1.5 bg-white text-xs">
                    <option value="">Not shared</option>
                    {status.tiers.filter((t) => t.capacity > 0 || t.id === m?.tierId).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                  </select>
                )}
              </li>
            );
          })}
        </ul>
      )}
      {note && <p role={note.ok ? 'status' : 'alert'} className={`text-xs ${note.ok ? 'text-emerald-700' : 'text-rose-500'}`}>{note.text}</p>}
    </div>
  );
}
