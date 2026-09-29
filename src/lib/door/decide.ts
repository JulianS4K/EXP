// The door's scan decision: one pure function the scanner page calls for
// every read (camera or typed). It never touches the network or storage; the
// page gathers the inputs (cached roster entry, local signature check, network
// state, doors / test-window times) and acts on the answer.
//
// The rules, in short:
//   * Online, the cached roster is a HINT. Anything the cache could be stale
//     about (used, voided, mid-transfer, a signature that no longer matches
//     because the ticket moved) goes to the server, which is the authority.
//   * Offline, or when the server can't be reached (a request failed or timed
//     out), the cache is all there is, so every local rule applies: refused if
//     used, voided, mid-transfer, already queued on this device, signature bad,
//     or doors not open. A pre-doors scan inside the test window is a test OK
//     and is never queued (a queued scan would burn the ticket on replay).
//   * A scan this device admitted that hasn't uploaded yet counts as used,
//     online too (the server doesn't know about it yet).
//   * Check in by name (exos_door_checkin_by_name, mig 20260929130000): staff
//     find someone in the door list and check them in without a live code,
//     claimed ticket or not, as the event's door_name_checkin allows ('staff':
//     any door role, 'managers': owner / manager, 'off': QR only). Online the
//     server decides; offline the saved list does and the check-in is queued
//     with kind 'name'. A parked ticket (minted for an email with no account
//     and held on the org until the buyer claims it) has no code of its own
//     for the buyer to show, so reading it goes to the by-name confirmation.
//   * The same read twice within DUPLICATE_READ_MS is ignored (camera double
//     decodes), and a camera re-read of the ticket just admitted is ignored for
//     SAME_TICKET_HOLD_MS so the green verdict isn't replaced by "already used".

import { extractTicketIdFromAny } from '../barcode';

export const DUPLICATE_READ_MS = 2_000;
export const SAME_TICKET_HOLD_MS = 8_000;

export type DoorSource = 'camera' | 'manual';

/** 'unreachable' = the browser says online but the server isn't answering
 *  (a request failed or timed out): decided exactly like 'offline'. */
export type DoorNetwork = 'online' | 'offline' | 'unreachable';

export interface ParsedDoorCode {
  raw: string;
  /** The ticket id inside the code (signed, wallet, legacy or bare). */
  ticketId: string | null;
  /** Typed ticket id with no signed code: a manager override. */
  bare: boolean;
}

/** A camera read is never a bare override: a scanned bare id is a forgery
 *  downgrade and fails the signature check. */
export function parseDoorCode(raw: string, source: DoorSource): ParsedDoorCode {
  const v = (raw || '').trim();
  const bare = source === 'manual' && v !== '' && !v.startsWith('T-') && !v.startsWith('W-') && !v.includes(':');
  const id = v ? extractTicketIdFromAny(v) || v : null;
  // Ticket ids are UUIDs: anything over 128 chars can't be one.
  return { raw: v, ticketId: id && id.length <= 128 ? id : null, bare };
}

export interface DoorCachedTicket {
  used: boolean;
  voided?: boolean;
  pendingTransferId?: string | null;
  /** Unclaimed ticket held on the org for its buyer (roster `parked`). */
  parked?: boolean;
  /** Set when the entry came from a single-ticket server read. */
  eventId?: string;
}

export interface DoorGate {
  /** coalesce(doors_at, starts_at), ms. */
  opensAt: number | null;
  /** End of the pre-doors test window (only when test mode is on), ms. */
  testUntil: number | null;
  cancelled?: boolean;
}

export interface RecentRead {
  raw: string;
  ticketId: string | null;
  at: number;
  source: DoorSource;
  admitted: boolean;
}

/** exos_events.door_name_checkin. */
export type NameCheckinMode = 'staff' | 'managers' | 'off';

/** The column's value, or null when the database doesn't have it yet. */
export function parseNameCheckinMode(v: unknown): NameCheckinMode | null {
  return v === 'staff' || v === 'managers' || v === 'off' ? v : null;
}

/** May this person check someone in by name? `isManager` = owner, manager or
 *  platform admin. Per-event scanner scope is the server's (the page only
 *  opens for staff of the event). */
export type NameCheckinAccess = 'allowed' | 'needs-manager' | 'off';
export function nameCheckinAccess(mode: NameCheckinMode, isManager: boolean): NameCheckinAccess {
  if (mode === 'off') return 'off';
  if (mode === 'managers' && !isManager) return 'needs-manager';
  return 'allowed';
}

export interface ScanDecisionInput {
  code: ParsedDoorCode;
  source: DoorSource;
  /** Override reason (owner / manager), already given. */
  reason?: string;
  /** "Check in by name" was confirmed for this ticket (a note is optional). */
  byName?: boolean;
  /** The event's door_name_checkin (default 'staff'). */
  nameCheckin?: NameCheckinMode;
  eventId: string;
  entry?: DoorCachedTicket | null;
  /** A scan of this ticket is waiting in this device's upload queue. */
  queued?: boolean;
  /** Local signature check against the cached secret (null = not checked). */
  verify?: { ok: boolean; reason?: string } | null;
  network: DoorNetwork;
  gate: DoorGate;
  /** Scan time, server-corrected ms. */
  now: number;
  canOverride: boolean;
  recent?: RecentRead | null;
}

export type DoorRejectReason =
  | 'not-found'
  | 'unknown-offline'
  | 'needs-manager'
  | 'invalid-barcode'
  | 'used'
  | 'voided'
  | 'in-transfer'
  | 'doors-not-open'
  | 'wrong-event'
  | 'event-cancelled'
  /** Check in by name: the event allows it for owners / managers only. */
  | 'name-needs-manager'
  /** Check in by name is off for this event (QR only). */
  | 'name-off';

export type ScanDecision =
  | { action: 'ignore' }
  | { action: 'needs-reason'; ticketId: string }
  /** An unclaimed ticket was read: show the by-name confirmation. */
  | { action: 'confirm-name'; ticketId: string }
  | { action: 'ask-server'; ticketId: string; byName?: boolean }
  | { action: 'admit'; ticketId: string; test: boolean; queue: boolean; byName?: boolean }
  | { action: 'reject'; ticketId: string | null; reason: DoorRejectReason; opensAt?: number };

export function isDuplicateRead(
  input: Pick<ScanDecisionInput, 'code' | 'source' | 'reason' | 'byName' | 'now' | 'recent'>,
): boolean {
  const r = input.recent;
  if (!r || input.reason || input.byName) return false;
  const age = input.now - r.at;
  if (age < 0) return false;
  if (r.raw === input.code.raw && age < DUPLICATE_READ_MS) return true;
  return (
    input.source === 'camera' && r.source === 'camera' && r.admitted &&
    !!input.code.ticketId && r.ticketId === input.code.ticketId && age < SAME_TICKET_HOLD_MS
  );
}

export function decideScan(input: ScanDecisionInput): ScanDecision {
  const { code, entry, gate, now } = input;
  if (!code.raw) return { action: 'reject', ticketId: null, reason: 'not-found' };
  if (isDuplicateRead(input)) return { action: 'ignore' };
  const ticketId = code.ticketId;
  if (!ticketId) return { action: 'reject', ticketId: null, reason: 'not-found' };

  if (input.byName) return decideByName(input, ticketId);
  // An unclaimed ticket has no code of its own for the buyer to show: reading
  // it (a typed id, or the org's copy) goes to the by-name confirmation.
  const parked =
    !!entry?.parked && !entry.used && !entry.voided && !input.queued &&
    !(entry.eventId && entry.eventId !== input.eventId);
  if (parked) {
    const access = nameCheckinAccess(input.nameCheckin ?? 'staff', input.canOverride);
    if (access === 'allowed') return { action: 'confirm-name', ticketId };
    return { action: 'reject', ticketId, reason: access === 'needs-manager' ? 'name-needs-manager' : 'name-off' };
  }

  // Typed ticket id: an owner / manager override that needs a reason (the
  // server enforces both; this only saves a round trip).
  if (code.bare && !input.reason) {
    return input.canOverride
      ? { action: 'needs-reason', ticketId }
      : { action: 'reject', ticketId, reason: 'needs-manager' };
  }

  if (entry?.eventId && entry.eventId !== input.eventId) {
    return { action: 'reject', ticketId, reason: 'wrong-event' };
  }

  // Admitted on this device and not uploaded yet: used, whatever the network.
  if (input.queued) return { action: 'reject', ticketId, reason: 'used' };

  const v = input.verify;
  if (input.network === 'online') {
    // A signature that doesn't match the CACHED secret may just mean the
    // ticket was transferred since the download: the server decides. A code
    // that is malformed or outside its time window fails there too, and the
    // local copy says why (clock skew, screenshot).
    if (entry && v && !v.ok && v.reason !== 'signature-mismatch') {
      return { action: 'reject', ticketId, reason: 'invalid-barcode' };
    }
    return { action: 'ask-server', ticketId };
  }

  // Offline or unreachable: the cached list is the only authority.
  if (gate.cancelled) return { action: 'reject', ticketId, reason: 'event-cancelled' };
  if (!entry) return { action: 'reject', ticketId, reason: 'unknown-offline' };
  if (v && !v.ok) return { action: 'reject', ticketId, reason: 'invalid-barcode' };
  if (entry.voided) return { action: 'reject', ticketId, reason: 'voided' };
  if (entry.pendingTransferId) return { action: 'reject', ticketId, reason: 'in-transfer' };
  if (entry.used) return { action: 'reject', ticketId, reason: 'used' };
  if (gate.opensAt != null && now < gate.opensAt) {
    if (gate.testUntil != null && now < gate.testUntil) {
      return { action: 'admit', ticketId, test: true, queue: false };
    }
    return { action: 'reject', ticketId, reason: 'doors-not-open', opensAt: gate.opensAt };
  }
  return { action: 'admit', ticketId, test: false, queue: true };
}

/** "Check in by name", confirmed. Any active ticket of the event, claimed or
 *  not, as the event's setting allows. Online the server decides
 *  (exos_door_checkin_by_name); offline the saved list does and the check-in
 *  is queued (replayed with its client ref). A holder's own pending transfer
 *  is refused: the ticket may already be the friend's. */
function decideByName(input: ScanDecisionInput, ticketId: string): ScanDecision {
  const { entry, gate, now } = input;
  const access = nameCheckinAccess(input.nameCheckin ?? 'staff', input.canOverride);
  if (access === 'off') return { action: 'reject', ticketId, reason: 'name-off' };
  if (access === 'needs-manager') return { action: 'reject', ticketId, reason: 'name-needs-manager' };
  if (entry?.eventId && entry.eventId !== input.eventId) return { action: 'reject', ticketId, reason: 'wrong-event' };
  // Checked in on this device and not uploaded yet: used, whatever the network.
  if (input.queued) return { action: 'reject', ticketId, reason: 'used' };
  if (input.network === 'online') return { action: 'ask-server', ticketId, byName: true };
  if (gate.cancelled) return { action: 'reject', ticketId, reason: 'event-cancelled' };
  if (!entry) return { action: 'reject', ticketId, reason: 'unknown-offline' };
  if (entry.voided) return { action: 'reject', ticketId, reason: 'voided' };
  if (entry.used) return { action: 'reject', ticketId, reason: 'used' };
  if (entry.pendingTransferId && !entry.parked) return { action: 'reject', ticketId, reason: 'in-transfer' };
  if (gate.opensAt != null && now < gate.opensAt) {
    if (gate.testUntil != null && now < gate.testUntil) {
      return { action: 'admit', ticketId, test: true, queue: false, byName: true };
    }
    return { action: 'reject', ticketId, reason: 'doors-not-open', opensAt: gate.opensAt };
  }
  return { action: 'admit', ticketId, test: false, queue: true, byName: true };
}
