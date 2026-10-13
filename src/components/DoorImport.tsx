// Exos Door: import an attendee export from another platform (Eventbrite,
// Posh, DICE, Shotgun, RA, Partiful or any spreadsheet) into a guest list of
// an Exos event, so the door checks those people in by name or by scanning
// the barcode the other platform issued (mig 20261013090000). The file is
// read in the browser; only the mapped columns are uploaded.

import { useState } from 'react';
import { FileUp, Loader2 } from 'lucide-react';
import {
  IMPORT_SOURCES,
  detectColumns,
  guessSource,
  parseCsv,
  planImport,
  type ColumnMap,
  type ImportField,
} from '../lib/door/imports';
import { findGuestListId, importGuests, type ImportResult } from '../lib/door/api';
import { upsertGuestList } from '../lib/guestListsApi';

const FIELDS: Array<{ id: ImportField; label: string }> = [
  { id: 'name', label: 'Full name' },
  { id: 'firstName', label: 'First name' },
  { id: 'lastName', label: 'Last name' },
  { id: 'email', label: 'Email' },
  { id: 'phone', label: 'Phone' },
  { id: 'code', label: 'Barcode / ticket code' },
  { id: 'ticket', label: 'Ticket type' },
  { id: 'note', label: 'Note' },
];

const MAX_FILE_BYTES = 10 * 1024 * 1024;

export default function DoorImport({ eventId, onImported }: { eventId: string; onImported?: (r: ImportResult) => void }) {
  const [fileName, setFileName] = useState('');
  const [table, setTable] = useState<string[][] | null>(null);
  const [map, setMap] = useState<ColumnMap>({});
  const [source, setSource] = useState<string>('Other');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<ImportResult | null>(null);

  const header = table?.[0] ?? [];
  const plan = table ? planImport(table, map, source) : null;
  const hasName = map.name !== undefined || map.firstName !== undefined || map.lastName !== undefined;

  const readFile = async (f: File) => {
    setError(null);
    setResult(null);
    if (f.size > MAX_FILE_BYTES) {
      setError('That file is over 10 MB. Export just the attendee list.');
      return;
    }
    const text = await f.text();
    const t = parseCsv(text);
    if (t.length < 2) {
      setError('No rows found. Export the attendee list as CSV (comma, semicolon or tab separated).');
      setTable(null);
      return;
    }
    setFileName(f.name);
    setTable(t);
    setMap(detectColumns(t[0]));
    setSource(guessSource(f.name, t[0]));
  };

  const run = async () => {
    if (!plan || plan.rows.length === 0) return;
    setBusy(true);
    setError(null);
    try {
      // Same list for the same platform: a second import adds to it.
      const listName = `${source} import`.slice(0, 80);
      const listId = (await findGuestListId(eventId, listName))
        ?? (await upsertGuestList(eventId, { name: listName, maxPlusOnes: 5 }));
      const r = await importGuests(listId, plan.rows);
      setResult(r);
      onImported?.(r);
    } catch (err) {
      console.error('door import failed', err);
      const msg = (err as { message?: string })?.message ?? '';
      setError(/owners and managers/i.test(msg)
        ? 'Only owners and managers can import attendees.'
        : 'The import failed. Nothing partial was lost: run it again and duplicates are skipped.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <section aria-labelledby="door-import-title" className="space-y-4">
      <div>
        <h3 id="door-import-title" className="text-sm font-bold text-slate-800">Import attendees from another platform</h3>
        <p className="text-xs text-slate-500 mt-1">
          Export the attendee list from Eventbrite, Posh, DICE, Shotgun, RA or any spreadsheet as CSV. The door then
          checks people in by name or by scanning the barcode on their ticket. Importing the same file again adds
          nobody twice.
        </p>
      </div>

      <label className="flex items-center justify-center gap-2 border-2 border-dashed border-slate-200 rounded-2xl py-6 text-sm text-slate-600 cursor-pointer hover:border-slate-300">
        <FileUp className="w-4 h-4" />
        {fileName ? `${fileName} · ${Math.max(0, (table?.length ?? 1) - 1)} rows` : 'Choose a CSV file'}
        <input
          type="file"
          accept=".csv,text/csv,text/plain,.tsv"
          className="sr-only"
          onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) void readFile(f);
          }}
        />
      </label>

      {table && (
        <>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <label className="text-xs text-slate-600">
              <span className="block font-bold mb-1">Sold on</span>
              <select value={source} onChange={(e) => setSource(e.target.value)}
                className="w-full border border-slate-200 rounded-lg px-2 py-2 bg-white text-sm">
                {IMPORT_SOURCES.map((s) => <option key={s} value={s}>{s}</option>)}
              </select>
            </label>
            {FIELDS.map((f) => (
              <label key={f.id} className="text-xs text-slate-600">
                <span className="block font-bold mb-1">{f.label}</span>
                <select
                  value={map[f.id] ?? ''}
                  onChange={(e) => setMap((m) => {
                    const next = { ...m };
                    if (e.target.value === '') delete next[f.id];
                    else next[f.id] = Number(e.target.value);
                    return next;
                  })}
                  className="w-full border border-slate-200 rounded-lg px-2 py-2 bg-white text-sm"
                >
                  <option value="">Not in this file</option>
                  {header.map((h, i) => <option key={i} value={i}>{h || `Column ${i + 1}`}</option>)}
                </select>
              </label>
            ))}
          </div>

          {plan && (
            <div className="text-xs text-slate-600 bg-slate-50 rounded-xl p-3 space-y-1">
              <p>
                <strong className="text-slate-900">{plan.rows.length}</strong> attendee{plan.rows.length === 1 ? '' : 's'} to import
                {map.code === undefined ? ' (no code column: check-in by name only)' : ''}.
              </p>
              {plan.noName > 0 && <p>{plan.noName} row(s) have no name and are skipped.</p>}
              {plan.repeatedCodes > 0 && <p>{plan.repeatedCodes} row(s) repeat an earlier row and are kept once.</p>}
              {plan.sharedCodes > 0 && (
                <p>{plan.sharedCodes} attendee(s) share a code with someone else (an order number?): imported for check-in by name.</p>
              )}
              {plan.overLimit > 0 && <p>{plan.overLimit} row(s) are past the 5,000 limit: import them in a second file.</p>}
              {plan.rows.slice(0, 3).map((r, i) => (
                <p key={i} className="font-mono text-[11px] text-slate-500 truncate">
                  {r.name}{r.ticket ? ` · ${r.ticket}` : ''}{r.code ? ` · ${r.code}` : ''}
                </p>
              ))}
            </div>
          )}

          <button
            type="button"
            onClick={() => void run()}
            disabled={busy || !hasName || !plan || plan.rows.length === 0}
            className="inline-flex items-center gap-2 px-4 py-2 bg-slate-900 text-white rounded-lg text-[11px] font-black uppercase tracking-widest disabled:opacity-50"
          >
            {busy && <Loader2 className="w-3 h-3 animate-spin" />}
            Import {plan?.rows.length ?? 0} attendees
          </button>
          {!hasName && <p className="text-xs text-rose-500">Pick the name column (or first and last name).</p>}
        </>
      )}

      {error && <p role="alert" className="text-xs text-rose-500">{error}</p>}
      {result && (
        <p role="status" className="text-xs text-emerald-700 bg-emerald-50 rounded-xl p-3">
          Imported {result.inserted}. {result.duplicates > 0 ? `${result.duplicates} already there. ` : ''}
          {result.invalid > 0 ? `${result.invalid} skipped (${result.errors.slice(0, 3).map((e) => `row ${e.row}: ${e.reason}`).join('; ')}).` : ''}
        </p>
      )}
    </section>
  );
}
