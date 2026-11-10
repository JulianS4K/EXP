// The editor's fair setup (mig 20261113110000): one call, one transaction.
// exos_fair_setup checks the caller is an owner / manager of the event's org.

import { supabase } from './supabase';
import type { FairPlan } from './fairSetup';

export interface FairSetupResult {
  tierIds: Record<string, string>;
  addonIds: Record<string, string>;
  listIds: string[];
  /** The event's new end (the last day's close), when it moved. */
  endsAt: string | null;
}

/** Write the plan. Throws with the server's message (already set up, not
 *  allowed, a bad value); a database without the function says so. */
export async function runFairSetup(eventId: string, plan: FairPlan): Promise<FairSetupResult> {
  const { data, error } = await supabase.rpc('exos_fair_setup', { p_event_id: eventId, p_plan: plan });
  if (error) {
    const code = (error as { code?: string }).code;
    if (code === 'PGRST202' || code === '42883') throw new Error('Fair setup is not available on this server yet.');
    throw new Error(String(error.message || 'Could not set up the fair.').replace(/^exos_fair_setup: /, ''));
  }
  const d = (data ?? {}) as Record<string, unknown>;
  return {
    tierIds: (d.tier_ids ?? {}) as Record<string, string>,
    addonIds: (d.addon_ids ?? {}) as Record<string, string>,
    listIds: Array.isArray(d.list_ids) ? (d.list_ids as string[]) : [],
    endsAt: typeof d.ends_at === 'string' ? d.ends_at : null,
  };
}
