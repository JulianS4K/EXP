// Social / "friends" features are paused (operator 2026-11-17, mig
// 20261117100000): split with friends, matched seats, group chats and the
// masked SMS relay. Nothing new can start; what exists keeps working.
//
// The SQL switch (exos_platform_settings social_features_enabled, off by
// default) refuses every new start with SQLSTATE XSOFF. The one edge route
// that starts work on its own is exos-match's /run (a staff "Match now" /
// "Reshuffle"): it is refused with 403 social_off unless EXOS_SOCIAL=on
// (unset = off), checked first, before the JWT, the body or any DB call. The
// cron keeps grouping and revealing ticket types that were matched before the
// pause, so their buyers aren't stranded. exos-sms-relay needs no env switch:
// the SQL stops the relay while off (nothing queued or claimed but keyword
// answers) and its sends stay a dry run unless EXOS_SMS_RELAY=on.
export const SOCIAL_OFF = { error: "This feature isn't available", reason: "social_off" } as const;

/** EXOS_SOCIAL: on only when exactly "on" (any case, trimmed); unset is off. */
export function socialEnvOn(v: string | null | undefined): boolean {
  return typeof v === "string" && v.trim().toLowerCase() === "on";
}

/** The 403 for a route that starts social work while the env is off; null to go on. */
export function socialOffGate(env: string | null | undefined): { status: 403; body: Record<string, unknown> } | null {
  return socialEnvOn(env) ? null : { status: 403, body: { ...SOCIAL_OFF } };
}

/** An RPC error from the SQL switch (XSOFF) as the same 403; null for anything else. */
export function socialOffFromError(error: { code?: string | null } | null | undefined): { status: 403; body: Record<string, unknown> } | null {
  return error?.code === "XSOFF" ? { status: 403, body: { ...SOCIAL_OFF } } : null;
}
