// deno test supabase/functions/_shared/addonHold_test.ts
import { holdAddons } from "./addonHold.ts";

function check(cond: boolean, msg: string) {
  if (!cond) throw new Error(msg);
}

function fakeRpc(error: { code?: string; message?: string } | null) {
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  return {
    calls,
    rpc(fn: string, args: Record<string, unknown>) {
      calls.push({ fn, args });
      return Promise.resolve({ error });
    },
  };
}

const LOCKER = [{ addon_id: "a9", quantity: 1 }];

Deno.test("holds the order's add-ons on the cart hold", async () => {
  const sb = fakeRpc(null);
  check(await holdAddons(sb, "h1", LOCKER) === null, "held");
  check(sb.calls.length === 1 && sb.calls[0].fn === "exos_hold_addons", "one rpc");
  check(sb.calls[0].args.p_hold_id === "h1", "hold id");
  check(JSON.stringify(sb.calls[0].args.p_addons) === '[{"addon_id":"a9","quantity":1}]', "lines");
});

Deno.test("sold out: the buyer is told before paying", async () => {
  const sb = fakeRpc({ code: "23514", message: 'exos_hold_addons: add-on "Locker" is sold out' });
  check(await holdAddons(sb, "h1", LOCKER) === 'add-on "Locker" is sold out', "reason");
});

Deno.test("no hold or no add-ons: nothing to do", async () => {
  const sb = fakeRpc(null);
  check(await holdAddons(sb, null, LOCKER) === null, "bypass voucher, no hold");
  check(await holdAddons(sb, "h1", []) === null, "no add-ons");
  check(sb.calls.length === 0, "no rpc");
});

Deno.test("before the migration: the order goes on", async () => {
  check(await holdAddons(fakeRpc({ code: "PGRST202", message: "not found" }), "h1", LOCKER) === null, "PGRST202");
  check(await holdAddons(fakeRpc({ code: "42883", message: "no function" }), "h1", LOCKER) === null, "42883");
});
