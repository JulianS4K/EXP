// The holder's add-on entry codes (mig 20261107110000): exos_my_addon_passes
// returns the caller's own passes with the secret their app signs with (the
// door only ever gets day keys). Pure parsing + the RPC call.

import { supabase } from './supabase';

export interface AddonPass {
  id: string;
  eventId: string;
  addonId: string | null;
  addonName: string;
  unitIndex: number;
  /** How many units of this add-on the holder has for the event (for "2 of 3"). */
  unitCount: number;
  status: 'active' | 'used' | 'voided';
  /** null once voided. */
  barcodeSecret: string | null;
  /** The wallet code's epoch (mig 20261111140000); null until the unit is added to a wallet. */
  walletEpoch: number | null;
}

export function parseAddonPasses(raw: unknown): AddonPass[] {
  if (!Array.isArray(raw)) return [];
  const rows = (raw as Record<string, unknown>[])
    .filter((r) => r && typeof r.id === 'string')
    .map((r): AddonPass => ({
      id: String(r.id),
      eventId: String(r.event_id ?? ''),
      addonId: typeof r.addon_id === 'string' ? r.addon_id : null,
      addonName: typeof r.addon_name === 'string' && r.addon_name ? r.addon_name : 'Add-on',
      unitIndex: Math.max(1, Math.trunc(Number(r.unit_index) || 1)),
      unitCount: 1,
      status: r.status === 'used' || r.status === 'voided' ? r.status : 'active',
      barcodeSecret: typeof r.barcode_secret === 'string' && r.barcode_secret ? r.barcode_secret : null,
      walletEpoch: typeof r.wallet_epoch === 'number' && Number.isInteger(r.wallet_epoch) && r.wallet_epoch >= 1 ? r.wallet_epoch : null,
    }));
  const counts = new Map<string, number>();
  for (const p of rows) counts.set(`${p.eventId}:${p.addonId ?? p.addonName}`, (counts.get(`${p.eventId}:${p.addonId ?? p.addonName}`) ?? 0) + 1);
  const seen = new Map<string, number>();
  return rows.map((p) => {
    const k = `${p.eventId}:${p.addonId ?? p.addonName}`;
    const n = (seen.get(k) ?? 0) + 1;
    seen.set(k, n);
    return { ...p, unitIndex: n, unitCount: counts.get(k) ?? 1 };
  });
}

export async function listMyAddonPasses(eventId: string | null): Promise<AddonPass[]> {
  const { data, error } = await supabase.rpc('exos_my_addon_passes', { p_event_id: eventId });
  if (error) {
    const code = (error as { code?: string }).code;
    if (code === 'PGRST202' || code === '42883') return [];
    throw error;
  }
  return parseAddonPasses(data);
}
