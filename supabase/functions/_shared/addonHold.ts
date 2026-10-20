// Add-on stock held with the cart hold (mig 20261021130000). exos-checkout
// reserves the order's add-ons on its ticket hold before the Stripe session,
// so two buyers can't both pay for the last locker (the loser's whole order
// used to fail at fulfillment and be refunded).

export interface AddonHoldLine {
  addon_id: string;
  quantity: number;
}

type RpcClient = {
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ error: { code?: string; message?: string } | null }>;
};

/** Reserve `lines` on hold `holdId`. null = held (or nothing to hold), else
 *  the reason to show the buyer. Before the migration is applied there is no
 *  RPC: the order goes on as before (fulfillment still re-checks the stock). */
export async function holdAddons(sb: RpcClient, holdId: string | null, lines: AddonHoldLine[]): Promise<string | null> {
  if (!holdId || lines.length === 0) return null;
  const { error } = await sb.rpc("exos_hold_addons", {
    p_hold_id: holdId,
    p_addons: lines.map((l) => ({ addon_id: l.addon_id, quantity: l.quantity })),
  });
  if (!error) return null;
  if (error.code === "PGRST202" || error.code === "42883") return null;
  return (error.message || "add-on sold out").replace(/^exos_hold_addons: /, "");
}
