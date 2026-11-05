// The holder's side of printed tickets (mig 20261105120000, docs/wallet.md
// "Printed tickets"): is this ticket printed, and voiding the paper to use
// the phone again. Both RPCs check the caller is the holder (or staff).

import { supabase } from './supabase';
import { parsePrintState } from './printOrder';

export async function ticketPrintState(ticketId: string): Promise<{ printed: boolean; printedAt: string | null }> {
  const { data, error } = await supabase.rpc('exos_ticket_print_state', { p_ticket_id: ticketId });
  // A database without printed tickets yet: nothing is printed.
  if (error) return { printed: false, printedAt: null };
  return parsePrintState(data);
}

export async function voidTicketPrint(ticketId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc('exos_ticket_print_void', { p_ticket_id: ticketId });
  if (error) throw new Error((error.message ?? 'Failed.').replace(/^_?exos_\w+: /, ''));
  return (data as { voided?: boolean } | null)?.voided === true;
}
