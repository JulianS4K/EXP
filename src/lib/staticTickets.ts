// Static-code tickets on the holder's side (mig 20261121153000,
// docs/wallet.md "Static codes"). A ticket issued with code_mode 'static'
// shows one S- code that never changes, derived here from the ticket's
// barcode secret (the same secret the rotating code uses, read through the
// gated view) and its holder, and can be saved as a PDF drawn by the same
// writer the confirmation email uses. Pure helpers plus the browser save.

import type { Event, Ticket } from '../types';
import { staticCode } from '../../supabase/functions/_shared/staticCodes.ts';
import { staticTicketsPdf, type PrintTicket } from '../../supabase/functions/_shared/print/tickets.ts';
import { FREE_TIER_MAX_CAPACITY, isFreeTier } from '../../supabase/functions/_shared/platformFee.ts';

/** The ticket page's line under a static code. */
export const STATIC_CODE_NOTE = "This code doesn't change, so you can print it or save the PDF. It lets one person in: the first scan wins, so keep it to yourself.";

/** The confirm before a new static code (exos_ticket_static_reissue). */
export const STATIC_REISSUE_CONFIRM = 'Get a new code for this ticket? The current code, its PDF and any printout or screenshot of it stop working at the door.';

export function isStaticTicket(t: Pick<Ticket, 'codeMode'> | null | undefined): boolean {
  return t?.codeMode === 'static';
}

/** Can the holder show or save this ticket's static code now? */
export function staticCodeUsable(t: Pick<Ticket, 'codeMode' | 'status' | 'pendingTransferId' | 'barcodeSecret' | 'ownerId'>, viewerId: string | null | undefined): boolean {
  return isStaticTicket(t) && t.status === 'active' && !t.pendingTransferId && !!t.barcodeSecret && !!viewerId && t.ownerId === viewerId;
}

/** The ticket's S- code for its holder (null without a secret). */
export async function staticTicketCode(t: Pick<Ticket, 'id' | 'ownerId' | 'barcodeSecret'>): Promise<string | null> {
  if (!t.barcodeSecret || !t.ownerId) return null;
  return staticCode(t.id, t.ownerId, t.barcodeSecret);
}

/** The PDF page fields for one ticket (what the email's PDF carries). */
export function staticPrintRow(t: Pick<Ticket, 'id' | 'tierName' | 'attendeeName' | 'orderId'>, code: string, event: Pick<Event, 'title' | 'date' | 'timezone' | 'location'> & { venueName?: string | null; orgName?: string | null }, holder?: string | null): PrintTicket {
  const d = event.date?.toDate?.();
  return {
    ticket_id: t.id,
    print_code: code,
    event_name: event.title,
    starts_at: d && !Number.isNaN(d.getTime()) ? d.toISOString() : null,
    timezone: event.timezone ?? null,
    venue_name: event.venueName ?? null,
    venue_location: event.location ?? null,
    tier_name: t.tierName ?? null,
    attendee_name: t.attendeeName || holder || null,
    org_name: event.orgName ?? null,
    order_ref: t.orderId ?? null,
  };
}

/** The PDF of the holder's usable static tickets of one event, or null if none. */
export async function staticTicketsPdfFor(
  tickets: Ticket[],
  event: Pick<Event, 'title' | 'date' | 'timezone' | 'location'>,
  viewerId: string | null | undefined,
  holder?: string | null,
): Promise<Uint8Array | null> {
  const rows: PrintTicket[] = [];
  for (const t of tickets) {
    if (!staticCodeUsable(t, viewerId)) continue;
    const code = await staticTicketCode(t);
    if (code) rows.push(staticPrintRow(t, code, event, holder));
  }
  return rows.length ? staticTicketsPdf(rows, event.title || 'Tickets') : null;
}

/** "tickets-my-show.pdf". */
export function pdfFileName(title: string | null | undefined): string {
  const slug = (title ?? '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60);
  return `tickets${slug ? `-${slug}` : ''}.pdf`;
}

/** Hands the browser a file to save. */
export function saveBytes(bytes: Uint8Array, filename: string, type = 'application/pdf'): void {
  const url = URL.createObjectURL(new Blob([bytes as BlobPart], { type }));
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

/** The organizer's line on door codes for an event of this size (event
 *  settings, next to the free-tier / resale rules). Generated from the
 *  cutoff, never a literal: "paid tier" = over FREE_TIER_MAX_CAPACITY. */
export function doorCodeTierText(maxCapacity: number, bounded: boolean, cutoff: number = FREE_TIER_MAX_CAPACITY): string {
  const paidFrom = Math.trunc(cutoff) + 1;
  return bounded && isFreeTier(maxCapacity, cutoff)
    ? `Door codes: one static QR per ticket, emailed as a PDF. Rotating anti-screenshot QR codes are on the paid tier (${paidFrom} or more).`
    : `Door codes: rotating anti-screenshot QR codes (the paid tier, ${paidFrom} or more). Tickets issued while the event was under ${paidFrom} keep their static QR.`;
}
