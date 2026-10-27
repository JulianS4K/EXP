// The passed-on fee rules (mig 20261027100000, docs/fees.md) of a set of
// events, for the feeds that show prices (exos-catalog-feed, exos-google-feed).
// Reads exos_public_fee_rules, which the anon key can read. The prices then
// fold them in with allInCents, exactly like the storefront and exos-checkout.
//
// Never throws: a database without the view (or a failed read) prices without
// fees, as before fee rules existed, and logs it.

import { attachTierFees, feeRulesByEvent, PUBLIC_FEE_RULE_COLS, type FeeRule } from "./fees.ts";

// deno-lint-ignore no-explicit-any
type Client = { from: (t: string) => any };

// serviceRole: read exos_effective_fee_rules instead (every event, e.g. a
// cancelled one's last prices; the price functions keep the passed-on rules).
export async function loadPublicFeeRules(
  sb: Client, eventIds: string[], opts: { serviceRole?: boolean } = {},
): Promise<Map<string, FeeRule[]>> {
  const ids = [...new Set(eventIds.filter(Boolean))];
  const rows: unknown[] = [];
  const [view, cols] = opts.serviceRole
    ? ["exos_effective_fee_rules", "*"]
    : ["exos_public_fee_rules", PUBLIC_FEE_RULE_COLS];
  try {
    for (let i = 0; i < ids.length; i += 200) {
      const { data, error } = await sb.from(view).select(cols)
        .in("event_id", ids.slice(i, i + 200)).order("rank", { ascending: true });
      if (error) throw error;
      rows.push(...((data ?? []) as unknown[]));
    }
  } catch (e) {
    console.error("fee rules: not read; prices without passed-on fees", (e as { message?: string })?.message ?? e);
    return new Map();
  }
  return feeRulesByEvent(rows);
}

/** Tier rows with their passed-on fees (passed_on_fees) for the price functions. */
export async function withPublicTierFees<T extends { id?: unknown; event_id?: unknown }>(
  sb: Client, tiers: T[], opts: { serviceRole?: boolean } = {},
): Promise<(T & { passed_on_fees: FeeRule[] })[]> {
  if (tiers.length === 0) return [];
  const byEvent = await loadPublicFeeRules(sb, tiers.map((t) => String(t.event_id)), opts);
  return attachTierFees(tiers, byEvent);
}
