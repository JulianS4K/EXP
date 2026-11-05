// Where the event happens (mig 20261105130000, docs/promoter-events.md), in
// the event editor (CreateEvent, EditEvent):
//   * At a venue / A venue not on Exos: the editor's own venue name and address
//     fields (passed in as `venueFields`), unchanged.
//   * Secret location: the public area, then the exact place (only ticket
//     holders get it, at the reveal time) and when it goes out.
//   * To be announced: an optional area, and whether tickets sell before then.
// A free-text venue (or the secret place) whose name and city match a venue
// another organization runs on Exos gets a gentle suggestion to send it a
// booking request. Nothing is ever linked or blocked by it.

import { useEffect, useState, type ChangeEvent, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { EyeOff, HelpCircle, Lock, MapPin } from 'lucide-react';
import {
  LOCATION_MODE_INFO, LOCATION_MODES, REVEAL_PRESETS, revealPreset, type Address, type LocationDraft, type LocationMode,
} from '../lib/eventLocation';
import { hasLocationModes, venueMatches, type VenueMatch } from '../lib/eventLocationApi';

/** True once this database has location modes (mig 20261105130000). */
export function useLocationModes(): boolean {
  const [ok, setOk] = useState(false);
  useEffect(() => {
    let live = true;
    void hasLocationModes().then((v) => { if (live) setOk(v); });
    return () => { live = false; };
  }, []);
  return ok;
}

const FIELD =
  'w-full bg-black border border-white/20 py-3 px-4 text-white text-sm font-medium focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary';
const LABEL = 'type text-[11px] text-white/60 uppercase tracking-widest ml-1';
const ICONS: Record<LocationMode, typeof MapPin> = {
  venue_record: MapPin, unlisted_venue: MapPin, secret_location: Lock, tba: HelpCircle,
};

function AddressFields({ value, onChange, label }: { value: Address; onChange: (a: Address) => void; label: string }) {
  const set = (k: keyof Address) => (e: ChangeEvent<HTMLInputElement>) => onChange({ ...value, [k]: e.target.value });
  return (
    <div className="grid grid-cols-1 md:grid-cols-6 gap-3">
      <input className={`md:col-span-6 ${FIELD}`} placeholder="Street" aria-label={`${label} street`} maxLength={120}
        value={value.street ?? ''} onChange={set('street')} />
      <input className={`md:col-span-3 ${FIELD}`} placeholder="City" aria-label={`${label} city`} maxLength={80}
        value={value.city ?? ''} onChange={set('city')} />
      <input className={`md:col-span-2 ${FIELD}`} placeholder="State / Region" aria-label={`${label} region`} maxLength={80}
        value={value.region ?? ''} onChange={set('region')} />
      <input className={`md:col-span-1 ${FIELD}`} placeholder="Postal" aria-label={`${label} postal code`} maxLength={20}
        value={value.postal ?? ''} onChange={set('postal')} />
    </div>
  );
}

/** "This venue is on Exos": looked up as the organizer types (debounced). */
export function VenueOnExosHint({ orgId, name, city }: { orgId: string | null | undefined; name: string; city: string }) {
  const [matches, setMatches] = useState<VenueMatch[]>([]);
  useEffect(() => {
    if (!orgId || !name.trim() || !city.trim()) { setMatches([]); return undefined; }
    let live = true;
    const t = setTimeout(() => {
      venueMatches(orgId, name, city).then((m) => { if (live) setMatches(m); }).catch(() => { if (live) setMatches([]); });
    }, 500);
    return () => { live = false; clearTimeout(t); };
  }, [orgId, name, city]);
  if (!orgId || matches.length === 0) return null;
  return (
    <div role="note" className="border border-brand-primary/40 bg-brand-primary/5 px-4 py-3 text-xs text-white/80">
      <p className="font-bold text-white">This venue is on Exos{matches.length > 1 ? ` (${matches.length} matches)` : ''}: request to book?</p>
      <p className="mt-1 text-white/60">
        {matches.map((m) => `${m.name}${m.city ? `, ${m.city}` : ''} (run by ${m.org.name}${m.verified ? ', verified' : ''})`).join('; ')}.
        {' '}You can keep going as you are; a booking request puts the night on their calendar.
      </p>
      <Link to={`/orgs/${orgId}/venue-requests?tab=sent&q=${encodeURIComponent(name.trim())}`}
        className="inline-block mt-2 underline text-brand-primary">Send a booking request</Link>
    </div>
  );
}

export default function LocationModePicker({
  draft, onChange, orgId, venueFields, venueName, venueCity, disabled,
}: {
  draft: LocationDraft;
  onChange: (d: LocationDraft) => void;
  orgId: string | null | undefined;
  /** The editor's venue name + address inputs, shown for the two venue modes. */
  venueFields: ReactNode;
  /** The typed venue name and city (for the "on Exos" hint in the unlisted mode). */
  venueName: string;
  venueCity: string;
  disabled?: boolean;
}) {
  const set = (patch: Partial<LocationDraft>) => onChange({ ...draft, ...patch });
  const preset = revealPreset(draft.revealHours);
  return (
    <div className="space-y-4">
      <div role="radiogroup" aria-label="Where it happens" className="grid grid-cols-2 md:grid-cols-4 gap-2">
        {LOCATION_MODES.map((m) => {
          const Icon = ICONS[m];
          return (
            <label key={m} className={`border px-3 py-3 cursor-pointer text-xs ${draft.mode === m ? 'border-brand-primary bg-brand-primary/10 text-white' : 'border-white/20 text-white/70'} ${disabled ? 'opacity-60 cursor-not-allowed' : ''}`}>
              <input type="radio" className="sr-only" name="location-mode" checked={draft.mode === m} disabled={disabled}
                onChange={() => set({ mode: m })} />
              <span className="flex items-center gap-2 font-bold uppercase tracking-widest text-[10px]"><Icon className="w-3.5 h-3.5" aria-hidden="true" />{LOCATION_MODE_INFO[m].label}</span>
              <span className="block mt-1 text-white/50 normal-case">{LOCATION_MODE_INFO[m].hint}</span>
            </label>
          );
        })}
      </div>

      {(draft.mode === 'venue_record' || draft.mode === 'unlisted_venue') && (
        <>
          {venueFields}
          {draft.mode === 'unlisted_venue' && <VenueOnExosHint orgId={orgId} name={venueName} city={venueCity} />}
        </>
      )}

      {draft.mode === 'secret_location' && (
        <div className="space-y-4">
          <div className="space-y-2">
            <label htmlFor="loc-area" className={LABEL}>Area shown on the event page *</label>
            <input id="loc-area" className={FIELD} maxLength={200} placeholder="e.g. Bushwick, Brooklyn" value={draft.area}
              disabled={disabled} onChange={(e) => set({ area: e.target.value })} />
          </div>
          <div className="border border-white/15 p-4 space-y-3">
            <p className="flex items-center gap-2 text-xs text-white/70"><EyeOff className="w-4 h-4" aria-hidden="true" />
              Only ticket holders get this, at the time below: on their ticket, by email and text, in their wallet pass.
              Never on the event page, feeds or partners.</p>
            <input className={FIELD} maxLength={200} placeholder="Place name (optional), e.g. Warehouse 9" aria-label="Secret place name"
              value={draft.secretName} disabled={disabled} onChange={(e) => set({ secretName: e.target.value })} />
            <AddressFields label="Secret address" value={draft.secretAddress} onChange={(a) => set({ secretAddress: a })} />
            <textarea className={FIELD} rows={2} maxLength={1000} placeholder="Directions for ticket holders (optional)"
              aria-label="Directions" value={draft.directions} disabled={disabled} onChange={(e) => set({ directions: e.target.value })} />
            <div className="space-y-2">
              <label htmlFor="loc-reveal" className={LABEL}>Ticket holders get the address</label>
              <div className="flex gap-2 items-center">
                <select id="loc-reveal" className={FIELD} disabled={disabled} value={preset === null ? 'custom' : String(preset)}
                  onChange={(e) => set({ revealHours: e.target.value === 'custom' ? (draft.revealHours ?? 24) : Number(e.target.value) })}>
                  {REVEAL_PRESETS.map((p) => <option key={p.hours} value={p.hours}>{p.label} the start</option>)}
                  <option value="custom">Hours before the start…</option>
                </select>
                {preset === null && (
                  <input type="number" min={0} max={720} className={`${FIELD} w-28`} aria-label="Hours before the start"
                    value={draft.revealHours ?? ''} disabled={disabled}
                    onChange={(e) => set({ revealHours: e.target.value === '' ? null : Number(e.target.value) })} />
                )}
              </div>
            </div>
            <VenueOnExosHint orgId={orgId} name={draft.secretName} city={draft.secretAddress.city ?? ''} />
          </div>
        </div>
      )}

      {draft.mode === 'tba' && (
        <div className="space-y-4">
          <div className="space-y-2">
            <label htmlFor="loc-tba-area" className={LABEL}>City or area (optional)</label>
            <input id="loc-tba-area" className={FIELD} maxLength={200} placeholder="e.g. Somewhere in Queens" value={draft.area}
              disabled={disabled} onChange={(e) => set({ area: e.target.value })} />
          </div>
          <fieldset className="space-y-2">
            <legend className={LABEL}>Sell tickets before the location is announced? *</legend>
            {([true, false] as const).map((v) => (
              <label key={String(v)} className="flex items-center gap-2 text-sm text-white/80">
                <input type="radio" name="tba-sales" checked={draft.tbaAllowSales === v} disabled={disabled}
                  onChange={() => set({ tbaAllowSales: v })} />
                {v ? 'Yes, sell now (ticket holders are told when it is set)' : 'Not yet: publish the page, open sales once it is set'}
              </label>
            ))}
          </fieldset>
        </div>
      )}

      {draft.mode !== 'venue_record' && (
        <p className="type text-[11px] text-white/50">Every ticket type needs a capacity (no unlimited types without a venue on Exos).</p>
      )}
    </div>
  );
}
