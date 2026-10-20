// How the door shows a refusal (OrganizerCheckIn): a title that says what is
// wrong at a glance ("Refunded", "Wrong door", "Before doors"), the reason
// underneath at body size, and the "rescan the live QR" hint only when the
// code itself is the problem. Advice to rescan is wrong for a refunded ticket
// or the wrong door: the next scan says the same. Pure, unit-tested.

export interface RefusalView {
  title: string;
  /** The code can't be trusted as read (screenshot, stale, tampered, clock):
   *  ask the holder to open the ticket and rescan the live QR. */
  rescan: boolean;
}

const VIEWS: Record<string, RefusalView> = {
  voided: { title: 'Refunded', rescan: false },
  'wrong-event': { title: 'Wrong event', rescan: false },
  'wrong-list': { title: 'Wrong door', rescan: false },
  'invalid-time': { title: 'List closed', rescan: false },
  'doors-not-open': { title: 'Before doors', rescan: false },
  'needs-manager': { title: 'Needs a manager', rescan: false },
  'name-needs-manager': { title: 'Needs a manager', rescan: false },
  'name-off': { title: 'Scan the code', rescan: false },
  'name-checkin-off': { title: 'Scan the code', rescan: false },
  'in-transfer': { title: 'Mid-transfer', rescan: false },
  'event-cancelled': { title: 'Event cancelled', rescan: false },
  'exit-not-allowed': { title: 'No re-entry', rescan: false },
  'unknown-list': { title: 'List removed', rescan: false },
  'not-assigned': { title: 'Not assigned', rescan: false },
  'not-authorized': { title: 'Not authorized', rescan: false },
  'reason-required': { title: 'Reason needed', rescan: false },
  'bad-scan-time': { title: 'Too old', rescan: false },
  // The code itself.
  'invalid-barcode': { title: 'Code rejected', rescan: true },
  'barcode-rejected': { title: 'Code rejected', rescan: true },
  'barcode-expired': { title: 'Code expired', rescan: true },
  'bucket-expired': { title: 'Code expired', rescan: true },
  'signature-mismatch': { title: 'Code rejected', rescan: true },
  malformed: { title: "Can't read code", rescan: true },
  'bad-bucket': { title: "Can't read code", rescan: true },
  'legacy-no-secret': { title: 'Old ticket format', rescan: true },
  'no-key': { title: "Can't check offline", rescan: false },
};

/** The view for a refusal reason (a server reason, a local decision reason
 *  or a local signature result). Unknown reasons read "Not admitted" with no
 *  rescan hint. */
export function refusalView(reason: string | null | undefined): RefusalView {
  return (reason && VIEWS[reason]) || { title: 'Not admitted', rescan: false };
}
