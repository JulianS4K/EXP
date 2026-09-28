// Which events a scanner may work the door of (mig 20260929041000). No events
// picked = every event of the org (the default). Once limited, check-in, the
// offline list and barcode secrets only answer for the picked events. Owners
// and managers are never limited. Rendered on OrgMembers for scanner rows.

import { useState } from 'react';
import { setScannerEvents } from '../lib/orgs';
import { useToast } from '../context/ToastContext';

export interface ScopeEvent {
  id: string;
  title: string;
}

export default function ScannerEventScope({
  orgId,
  uid,
  events,
  assigned,
  onSaved,
}: {
  orgId: string;
  uid: string;
  events: ScopeEvent[];
  assigned: string[];
  onSaved: (eventIds: string[]) => void;
}) {
  const { toast } = useToast();
  const [open, setOpen] = useState(false);
  const [picked, setPicked] = useState<string[]>(assigned);
  const [saving, setSaving] = useState(false);

  const summary =
    assigned.length === 0
      ? 'All events'
      : assigned.length === 1
      ? events.find((e) => e.id === assigned[0])?.title ?? '1 event'
      : `${assigned.length} events`;

  const save = async () => {
    setSaving(true);
    try {
      await setScannerEvents(orgId, uid, picked);
      onSaved(picked);
      setOpen(false);
      toast({ kind: 'success', message: picked.length ? `Limited to ${picked.length} event(s).` : 'Can scan every event.' });
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Could not save.' });
    } finally {
      setSaving(false);
    }
  };

  if (!open) {
    return (
      <button
        type="button"
        onClick={() => { setPicked(assigned); setOpen(true); }}
        className="text-[11px] text-slate-500 hover:text-slate-900 underline decoration-dotted"
        title="Limit which events this scanner can check people in for"
      >
        Door access: {summary}
      </button>
    );
  }

  return (
    <div className="mt-2 p-3 rounded-lg border border-slate-200 bg-slate-50 space-y-2 max-w-sm">
      <p className="text-[11px] font-bold text-slate-600">
        Events this scanner can work. None ticked = all events.
      </p>
      {events.length === 0 ? (
        <p className="text-[11px] text-slate-400">No events yet.</p>
      ) : (
        <ul className="max-h-48 overflow-y-auto space-y-1">
          {events.map((e) => (
            <li key={e.id}>
              <label className="flex items-center gap-2 text-xs text-slate-700">
                <input
                  type="checkbox"
                  checked={picked.includes(e.id)}
                  onChange={(ev) =>
                    setPicked((p) => (ev.target.checked ? [...p, e.id] : p.filter((x) => x !== e.id)))
                  }
                />
                <span className="truncate">{e.title}</span>
              </label>
            </li>
          ))}
        </ul>
      )}
      <div className="flex gap-2">
        <button
          type="button"
          onClick={save}
          disabled={saving}
          className="px-3 py-1.5 bg-slate-900 text-white rounded text-[10px] font-black uppercase tracking-widest disabled:opacity-50"
        >
          {saving ? 'Saving…' : 'Save'}
        </button>
        <button
          type="button"
          onClick={() => setOpen(false)}
          className="px-3 py-1.5 bg-white border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest text-slate-600"
        >
          Cancel
        </button>
      </div>
    </div>
  );
}
