// "Delete my account": exos_delete_my_account (mig 20260926010000) closes and
// anonymises the signed-in user's account. Order records stay for organizers
// without personal data; the login can't be used again.
import { supabase } from './supabase';

/** Server refusal text, without the function-name prefix. */
export function deletionErrorMessage(err: unknown): string {
  const raw = (err as { message?: string } | null)?.message ?? '';
  const msg = raw.replace(/^exos_delete_my_account:\s*/i, '').trim();
  return msg ? msg.charAt(0).toUpperCase() + msg.slice(1) + '.' : 'Could not delete your account. Please try again.';
}

export async function deleteMyAccount(): Promise<void> {
  const { error } = await supabase.rpc('exos_delete_my_account');
  if (error) throw error;
}
