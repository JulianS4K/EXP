// Edit event → Sell through partners → Caps (mig 20261104200000,
// docs/partner-sales.md "Caps"). Signed-in RPCs: owner / manager of the
// event's org (the SQL checks the role). The rules and the request shape are
// supabase/functions/_shared/partners/caps.ts.

import { supabase } from './supabase';
import type { PartnerCap, PartnerCapInput } from '../../supabase/functions/_shared/partners/caps.ts';

export {
  capSummary, findCap, MAX_PARTNER_CAP, parseCapField, type PartnerCap, type PartnerCapInput,
} from '../../supabase/functions/_shared/partners/caps.ts';

/** The event's caps with what each partner holds + sold; null when unavailable (older schema, no role). */
export async function fetchPartnerCaps(eventId: string): Promise<PartnerCap[] | null> {
  const { data, error } = await supabase.rpc('exos_partner_caps', { p_event_id: eventId });
  if (error) return null;
  return (data ?? []) as PartnerCap[];
}

/** Set (max_tickets) or remove (null) caps; answers the event's caps. */
export async function setPartnerCaps(eventId: string, caps: PartnerCapInput[]): Promise<PartnerCap[]> {
  const { data, error } = await supabase.rpc('exos_set_partner_caps', { p_event_id: eventId, p_caps: caps });
  if (error) throw error;
  return (data ?? []) as PartnerCap[];
}
