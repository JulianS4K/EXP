// Event location modes in the dashboard and on the event / ticket pages
// (mig 20261105130000, docs/promoter-events.md). The rules are in
// supabase/functions/_shared/eventLocation.ts (shared with the edge
// functions); this adds the editor's draft and what it saves. Pure: the
// calls are in eventLocationApi.ts.

import {
  addressLine, isPromoterMode, isPrivateMode, orgTypeDefaults, parseLocationMode, revealAtFromHours,
  REVEAL_PRESETS, type Address, type LocationMode, type OrgType,
} from '../../supabase/functions/_shared/eventLocation.ts';

export {
  addressLine, effectiveRevealAt, feedLocation, holderLocation, isPrivateMode, isPromoterMode, isRevealed,
  LOCATION_MODES, locationBlockers, ORG_TYPES, orgTypeDefaults, parseLocationMode, parseOrgType, publicLocation,
  revealAtFromHours, REVEAL_PRESETS, salesOpen, venueMatchKey,
  type Address, type Blocker, type HolderLocation, type HolderLocationView, type LocationMode, type OrgType,
  type PublicLocation,
} from '../../supabase/functions/_shared/eventLocation.ts';

/** How each mode reads in the picker. */
export const LOCATION_MODE_INFO: Record<LocationMode, { label: string; hint: string }> = {
  venue_record: { label: 'At a venue', hint: 'A venue you book or run (link it from Booking once saved).' },
  unlisted_venue: { label: 'A venue not on Exos', hint: 'Its name and address show on the event page.' },
  secret_location: { label: 'Secret location', hint: 'The page shows the area; ticket holders get the address at the reveal time.' },
  tba: { label: 'To be announced', hint: 'Publish now and set the place later; ticket holders hear when it is set.' },
};

export const ORG_TYPE_INFO: Record<OrgType, { label: string; hint: string }> = {
  organizer: { label: 'Organizer', hint: 'Venues, promoters, festivals: everything shows.' },
  promoter: { label: 'Promoter (no venue)', hint: 'Events at venues not on Exos, pop-ups and secret locations. Venue tools stay out of the way.' },
  collective: { label: 'Collective (no venue)', hint: 'Like a promoter: your own events wherever they happen.' },
};

export interface LocationDraft {
  mode: LocationMode;
  /** venue_record / unlisted_venue: the venue's public name. */
  venueName: string;
  /** The public area / city (secret: all the public sees; tba: optional). */
  area: string;
  /** venue_record / unlisted_venue: the public address. */
  address: Address;
  /** secret_location: the place, only for ticket holders. */
  secretName: string;
  secretAddress: Address;
  directions: string;
  /** secret_location: hours before the start the address goes out. */
  revealHours: number | null;
  /** tba: sell before the location is announced? null = not chosen yet. */
  tbaAllowSales: boolean | null;
}

const blankAddress = (): Address => ({ street: '', city: '', region: '', postal: '', country: '' });

/** A new event's draft: the org type's default mode, a 24 h reveal. */
export function blankLocationDraft(orgType: OrgType = 'organizer'): LocationDraft {
  return {
    mode: orgTypeDefaults(orgType).defaultLocationMode,
    venueName: '', area: '', address: blankAddress(),
    secretName: '', secretAddress: blankAddress(), directions: '',
    revealHours: 24, tbaAllowSales: null,
  };
}

/** The answer of exos_event_location (staff) as a draft. */
export interface StaffLocationView {
  location_mode?: unknown;
  venue_name?: string | null;
  venue_location?: string | null;
  venue_address?: Address | null;
  location_reveal_at?: string | null;
  tba_allow_sales?: boolean | null;
  secret_location?: { venue_name?: string | null; address?: Address | null; directions?: string | null } | null;
}

export function draftFromView(v: StaffLocationView | null | undefined, startsAtIso: string | null): LocationDraft {
  const d = blankLocationDraft();
  if (!v) return d;
  d.mode = parseLocationMode(v.location_mode);
  d.venueName = v.venue_name ?? '';
  d.area = v.venue_location ?? '';
  d.address = { ...blankAddress(), ...(v.venue_address ?? {}) };
  d.secretName = v.secret_location?.venue_name ?? '';
  d.secretAddress = { ...blankAddress(), ...(v.secret_location?.address ?? {}) };
  d.directions = v.secret_location?.directions ?? '';
  d.tbaAllowSales = v.tba_allow_sales ?? null;
  const r = v.location_reveal_at ? Date.parse(v.location_reveal_at) : NaN;
  const s = startsAtIso ? Date.parse(startsAtIso) : NaN;
  d.revealHours = Number.isFinite(r) && Number.isFinite(s) ? Math.max(0, Math.round((s - r) / 3600_000)) : d.revealHours;
  return d;
}

const trimAddress = (a: Address): Address | null => {
  const out: Address = {};
  for (const k of ['street', 'city', 'region', 'postal', 'country'] as const) {
    const v = (a[k] ?? '').trim();
    if (v) out[k] = v;
  }
  return Object.keys(out).length ? out : null;
};

/**
 * The public venue fields the event row carries for this draft (what the
 * event insert / update sends). Private modes carry the area only, so the
 * row never has a secret.
 */
export function publicVenueFields(d: LocationDraft): { venueName: string | null; venueLocation: string | null; venueAddress: Address | null } {
  if (isPrivateMode(d.mode)) return { venueName: null, venueLocation: d.area.trim() || null, venueAddress: null };
  const name = d.venueName.trim();
  return { venueName: name || null, venueLocation: d.area.trim() || name || null, venueAddress: trimAddress(d.address) };
}

/** The body of exos_event_location_set for this draft (startsAtIso: the event's start as saved). */
export function draftToPayload(d: LocationDraft, startsAtIso: string | null): Record<string, unknown> {
  const pub = publicVenueFields(d);
  const out: Record<string, unknown> = {
    location_mode: d.mode,
    venue_location: pub.venueLocation,
  };
  if (!isPrivateMode(d.mode)) {
    out.venue_name = pub.venueName;
    out.venue_address = pub.venueAddress;
  }
  if (d.mode === 'secret_location') {
    const at = d.revealHours === null ? null : revealAtFromHours(startsAtIso, d.revealHours);
    out.location_reveal_at = at;
    const addr = trimAddress(d.secretAddress);
    if (addr?.street) {
      out.secret_location = {
        venue_name: d.secretName.trim() || null,
        address: addr,
        directions: d.directions.trim() || null,
      };
    }
  }
  if (d.mode === 'tba') out.tba_allow_sales = d.tbaAllowSales;
  return out;
}

/** The editor's own check before saving; null when it can be saved (publishing has its own blockers). */
export function validateLocationDraft(d: LocationDraft, opts: { online?: boolean } = {}): string | null {
  if (opts.online) return null;
  if (d.area.length > 200) return 'The area is at most 200 characters.';
  if (d.mode === 'venue_record' || d.mode === 'unlisted_venue') {
    if (!d.venueName.trim()) return 'Please enter a venue.';
    if (d.mode === 'unlisted_venue' && !(d.address.street ?? '').trim() && !(d.address.city ?? '').trim()) {
      return 'Add the venue\'s address (at least the street or the city).';
    }
  }
  if (d.mode === 'secret_location') {
    if (!d.area.trim()) return 'Add the area or neighbourhood the public sees.';
    if (!(d.secretAddress.street ?? '').trim()) return 'Add the exact address (ticket holders get it at the reveal).';
    if (d.revealHours === null || !(d.revealHours >= 0) || d.revealHours > 720) return 'Pick when ticket holders get the address.';
    if ((d.directions ?? '').length > 1000) return 'Directions are at most 1000 characters.';
  }
  if (d.mode === 'tba' && d.tbaAllowSales === null) return 'Choose whether tickets sell before the location is announced.';
  return null;
}

/** Does this mode need a capacity on every ticket type (no unlimited)? */
export function needsCapacity(mode: LocationMode): boolean {
  return isPromoterMode(mode);
}

/** The reveal preset whose hours match, for the select (null: custom). */
export function revealPreset(hours: number | null): number | null {
  return REVEAL_PRESETS.some((p) => p.hours === hours) ? hours : null;
}

/** One line for an address the holder sees ("Warehouse 9, 77 Kent Ave, Brooklyn"). */
export function holderAddressLine(name: string | null | undefined, a: Address | null | undefined): string {
  return addressLine(name, a);
}
