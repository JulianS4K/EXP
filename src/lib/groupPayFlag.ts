/// <reference types="vite/client" />
// Group pay v2, "pay separately" (migs 20261108120000 / 20261110110000), is
// paused for good (operator 2026-11-09, mig 20261111120000). It ships dormant:
// the event page's start button and the /group-pay routes are only built in
// with VITE_EXOS_GROUP_PAY=on (unset = off). The server refuses on its own
// either way (EXOS_GROUP_PAY on exos-checkout, the group_pay_enabled platform
// setting in SQL). "Split with friends" (v1, /split/:sessionId) is not affected.

export const GROUP_PAY_OFF_TEXT = "Group pay isn't available";

/**
 * On only when the build sets VITE_EXOS_GROUP_PAY=on. Read on each call (tests
 * stub it). `import.meta.env.VITE_…` is spelled out, uncast, so Vite and vitest
 * both see it.
 */
export function groupPayEnabled(env?: { VITE_EXOS_GROUP_PAY?: string }): boolean {
  const v: unknown = env ? env.VITE_EXOS_GROUP_PAY : import.meta.env.VITE_EXOS_GROUP_PAY;
  return typeof v === 'string' && v.trim().toLowerCase() === 'on';
}
