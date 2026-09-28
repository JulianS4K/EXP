// What a ticket change does to its wallet pass. The database trigger
// exos_tg_wallet_ticket_changed (mig 20260929072000) is what runs; this is the
// same rule in TypeScript, for tests and for anyone reasoning about it.
//
//   voided (refund / release / organizer void) → pass voided, epoch + 1, push
//   owner changed (transfer claimed)          → pass voided, epoch + 1, push
//   anything else the pass shows (checked in, undo, transfer started or
//   cancelled, secret rotated, name)          → pass refreshed, push
//   nothing relevant changed                  → nothing
//
// A voided pass is never re-activated: the new holder gets a new serial, so
// the old holder's devices keep fetching a voided pass.

export interface TicketSnap {
  status: string;
  ownerId: string | null;
  barcodeSecret: string | null;
  pendingTransferId: string | null;
  attendeeName: string | null;
  releasedAt?: string | null;
}

export interface PassSnap {
  status: "active" | "voided";
  codeEpoch: number;
  pushPending: boolean;
  voidReason: string | null;
}

export type WalletEffect =
  | { action: "none" }
  | { action: "void"; reason: "ticket-voided" | "released" | "transferred" }
  | { action: "refresh" };

export function walletEffect(prev: TicketSnap, next: TicketSnap): WalletEffect {
  if (next.status === "voided" && prev.status !== "voided") {
    return { action: "void", reason: next.releasedAt ? "released" : "ticket-voided" };
  }
  if (next.ownerId !== prev.ownerId) return { action: "void", reason: "transferred" };
  if (
    next.status !== prev.status ||
    next.barcodeSecret !== prev.barcodeSecret ||
    next.pendingTransferId !== prev.pendingTransferId ||
    next.attendeeName !== prev.attendeeName
  ) return { action: "refresh" };
  return { action: "none" };
}

export function applyEffect(pass: PassSnap, effect: WalletEffect): PassSnap {
  if (pass.status !== "active" || effect.action === "none") return pass;
  if (effect.action === "void") {
    return { status: "voided", codeEpoch: pass.codeEpoch + 1, pushPending: true, voidReason: effect.reason };
  }
  return { ...pass, pushPending: true };
}

/** Does the door accept a W- code of this epoch for this pass? */
export function doorAcceptsEpoch(pass: PassSnap | null, epoch: number): boolean {
  return !!pass && pass.status === "active" && pass.codeEpoch === epoch;
}
