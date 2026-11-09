// Undo an add-on scan (mig 20261108110000, exos_undo_addon_check_in).
//
// A ticket's undo (exos_undo_check_in) is an owner / manager action with a
// reason. An add-on's entry code is scanned at a side door (a VIP lounge, a
// merch pickup) where a scanner works alone, so the add-on undo adds one
// rule: the scanner who made the pass's last entry may undo that one scan
// within ADDON_UNDO_WINDOW_MINUTES of it (on the server clock). Anyone else,
// or later, needs an owner or manager, whose undo clears every scan. A reason is always required and every undo is logged
// (exos_addon_pass_undos, with the scans it removed).
//
// Offline, the door queues the undo (a QueuedScan of kind 'addon-undo', with a
// client ref and the time it was done); the merge replays it through the same
// RPC: the same ref twice is one undo, and only scans at or before the undo
// are removed, so a later entry by another door stands.

import { supabase } from './supabase';
import { newClientRef, type QueuedScan } from './offlineCheckins';

/** The scanner's own window. Same as the SQL (v_window in exos_undo_addon_check_in). */
export const ADDON_UNDO_WINDOW_MINUTES = 10;
/** A scanner's undo queued offline must reach the server within the window
 *  plus this, on the server's clock (v_grace): a back-dated undo time can't
 *  stretch the window. A scanner's undo removes their one scan only. */
export const ADDON_UNDO_SYNC_GRACE_MINUTES = 60;

export type AddonUndoAccess = 'allowed' | 'needs-manager' | 'window-passed';

/** May this member undo this add-on scan? (The server decides; this drives the button.) */
export function addonUndoAccess(i: { manager: boolean; scannedByMe: boolean; scannedAt: number; now: number }): AddonUndoAccess {
  if (i.manager) return 'allowed';
  if (!i.scannedByMe) return 'needs-manager';
  return i.now - i.scannedAt <= ADDON_UNDO_WINDOW_MINUTES * 60_000 ? 'allowed' : 'window-passed';
}

/** What the door says for each refusal. */
export const ADDON_UNDO_TEXT: Record<string, string> = {
  'needs-manager': 'Only the scanner who scanned it (within 10 minutes) or an owner / manager can undo this.',
  'undo-window-passed': 'More than 10 minutes since the scan: ask an owner or manager to undo it.',
  'reason-required': 'Say why (at least 3 characters).',
  'not-checked-in': 'That add-on is not checked in.',
  voided: 'That add-on was refunded.',
  'wrong-event': 'That add-on is for another event.',
  'not-assigned': "You're not door staff for this event.",
  'bad-undo-time': "This device's clock is off: undo it again online.",
  'bad-client-ref': 'That undo was already used for another pass.',
  'not-found': 'Unknown add-on pass.',
};

export interface AddonUndoResult {
  ok: boolean;
  reason: string;
  status?: 'active' | 'used';
  removed?: number;
  duplicate?: boolean;
  window_minutes?: number;
}

/** Undo now (online), or replay a queued offline undo (clientRef + undoneAt). */
export async function undoAddonCheckIn(
  passId: string,
  eventId: string,
  reason: string,
  opts: { clientRef?: string; undoneAt?: number; device?: string } = {},
): Promise<AddonUndoResult> {
  const { data, error } = await supabase.rpc('exos_undo_addon_check_in', {
    p_pass_id: passId,
    p_event_id: eventId,
    p_reason: reason,
    p_client_ref: opts.clientRef ?? null,
    p_undone_at: opts.undoneAt != null ? new Date(opts.undoneAt).toISOString() : null,
    p_device: opts.device ?? null,
  });
  if (error) throw error;
  return (data ?? { ok: false, reason: 'not-found' }) as AddonUndoResult;
}

/** The offline queue's entry for an undo done without a network. */
export function queuedAddonUndo(passId: string, reason: string, at: number, makeRef: () => string = newClientRef): QueuedScan {
  return { ref: makeRef(), ticketId: passId, payload: null, scannedAt: at, source: 'manual', reason, kind: 'addon-undo' };
}
