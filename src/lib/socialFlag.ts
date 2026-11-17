/// <reference types="vite/client" />
// Social / "friends" features are paused (operator 2026-11-17, mig
// 20261117100000): Exos narrows to ticket selling, promotion and distribution.
// Hidden, code kept: split with friends (/split/:sessionId), matched seats
// (the event editor panel, the event page quiz, the ticket's group card) and
// group chats (/groups, /groups/:groupId, /orgs/:orgId/groups) are only built
// in with VITE_EXOS_SOCIAL=on (unset = off). The server refuses new starts on
// its own either way (the social_features_enabled platform setting, SQLSTATE
// XSOFF). What already exists keeps working where a buyer needs it: an
// existing split's pay-back checklist, a ticket type already sold as matched
// seats, claim links.

export type SocialFeature = 'split' | 'matched' | 'chat';

export const SOCIAL_OFF_TITLE: Record<SocialFeature, string> = {
  split: "Split with friends isn't available",
  matched: "Matched seats aren't available",
  chat: "Group chat isn't available",
};

/**
 * On only when the build sets VITE_EXOS_SOCIAL=on. Read on each call (tests
 * stub it). `import.meta.env.VITE_…` is spelled out, uncast, so Vite and
 * vitest both see it.
 */
export function socialEnabled(env?: { VITE_EXOS_SOCIAL?: string }): boolean {
  const v: unknown = env ? env.VITE_EXOS_SOCIAL : import.meta.env.VITE_EXOS_SOCIAL;
  return typeof v === 'string' && v.trim().toLowerCase() === 'on';
}
