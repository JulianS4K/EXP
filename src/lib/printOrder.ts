// Printing an order's tickets from the Orders page (mig 20261105120000,
// docs/wallet.md "Printed tickets"). exos_order_print mints a one-time print
// code per printable ticket (owner / manager); the PDF is drawn in the
// browser (printOrder in ./orderDeskApi.ts) by the same writer exos-api uses,
// so the codes go from the database straight into a file the organizer saves
// or prints. Pure: the rules and the copy.

export interface PrintedOrder {
  pdf: Uint8Array;
  printed: number;
  skipped: Array<{ ticket_id: string; reason: string }>;
}

/** The holder's ticket page while the ticket is printed (its app and wallet codes are refused at the door). */
export const PRINTED_TICKET_TEXT = 'This ticket was printed. Use the paper ticket, or void it to use your phone.';

/** exos_ticket_print_state's answer, read defensively. */
export function parsePrintState(v: unknown): { printed: boolean; printedAt: string | null } {
  const o = v && typeof v === 'object' ? v as Record<string, unknown> : {};
  return { printed: o.printed === true, printedAt: typeof o.printed_at === 'string' ? o.printed_at : null };
}

/** Owners and managers print (`staff`, orderPermissions().edit); only an order whose tickets were issued has any. */
export function canPrintOrder(o: { status: string }, staff: boolean): boolean {
  return staff && (o.status === 'fulfilled' || o.status === 'partially_refunded');
}

/** The confirm text: printing changes how the buyer gets in. */
export function printWarning(buyer: string): string {
  return `Print paper tickets for ${buyer}'s order? Each paper admits once. While it exists, the buyer's app and wallet codes `
    + "won't open the door (void the paper to give them back). Printing again voids the last paper.";
}

/** "Printed 2 tickets. 1 skipped (used)." */
export function printSummary(r: Pick<PrintedOrder, 'printed' | 'skipped'>): string {
  const head = r.printed === 0 ? 'No ticket on this order can be printed.' : `Printed ${r.printed} ticket${r.printed === 1 ? '' : 's'}.`;
  if (!r.skipped.length) return head;
  const why = [...new Set(r.skipped.map((s) => s.reason))].join(', ');
  return `${head} ${r.skipped.length} skipped (${why}).`;
}
