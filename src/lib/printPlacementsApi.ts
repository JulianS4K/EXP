// RPC calls for print placements (mig 20261121153700). Exos data only.

import { supabase } from './supabase';
import type { PrintPlacement } from './printPlacements';

export async function listPlacements(eventId: string): Promise<PrintPlacement[]> {
  const { data, error } = await supabase.rpc('exos_print_placements', { p_event_id: eventId });
  if (error) throw error;
  return Array.isArray(data) ? (data as PrintPlacement[]) : [];
}

export async function addPlacement(eventId: string, name: string): Promise<PrintPlacement> {
  const { data, error } = await supabase.rpc('exos_print_placement_add', { p_event_id: eventId, p_name: name.trim() });
  if (error) throw error;
  return data as PrintPlacement;
}

export async function removePlacement(id: string): Promise<void> {
  const { error } = await supabase.rpc('exos_print_placement_remove', { p_id: id });
  if (error) throw error;
}
