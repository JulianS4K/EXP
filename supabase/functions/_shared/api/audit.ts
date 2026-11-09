// The org audit log (mig 20261109100000, docs/security.md "Org audit log"):
// the action groups, the actor header exos-api sends, and the API row shape.
// Shared by exos-api (GET /v1/audit) and the dashboard (src/lib/orgAudit.ts).
//
//   * AUDIT_GROUPS must equal _exos_audit_group() in the migration
//     (src/lib/orgAudit.test.ts reads it).
//   * actorHeaders() is what exos-api adds to its PostgREST calls so the
//     audit rows its writes cause name the credential (an API key's id, a
//     personal token's id, an OAuth app's client id), never a secret. The
//     database believes these headers only on service-role requests.
//
// Pure TypeScript with no Deno or Supabase imports, so vitest can import it.

export const AUDIT_GROUPS = {
  inventory: ['event', 'tier', 'quota', 'voucher', 'hold'],
  money: ['refund', 'refund_ask', 'fee', 'comp', 'ticket', 'order', 'pos', 'gift_card', 'donation', 'payout', 'promoter', 'settlement'],
  access: ['member', 'invite', 'api_key', 'oauth_app', 'role_scopes'],
  data: ['export'],
} as const;

export type AuditGroup = keyof typeof AUDIT_GROUPS;
export const AUDIT_GROUP_NAMES = Object.keys(AUDIT_GROUPS) as AuditGroup[];

export const AUDIT_ACTOR_KINDS = ['user', 'api_key', 'oauth_app', 'service', 'cron'] as const;
export type AuditActorKind = (typeof AUDIT_ACTOR_KINDS)[number];

export const AUDIT_SOURCES = ['dashboard', 'api', 'door', 'pos', 'webhook', 'system'] as const;
export type AuditSource = (typeof AUDIT_SOURCES)[number];

/** The group an action (`group.verb`) belongs to; 'other' for one we don't know. */
export function auditGroup(action: string): AuditGroup | 'other' {
  const head = String(action ?? '').split('.')[0];
  for (const g of AUDIT_GROUP_NAMES) if ((AUDIT_GROUPS[g] as readonly string[]).includes(head)) return g;
  return 'other';
}

/** The prefixes (`event.`, `tier.`, …) of a group, for a PostgREST `like` filter. */
export function groupPrefixes(group: AuditGroup): string[] {
  return AUDIT_GROUPS[group].map((p) => `${p}.`);
}

/** An action name: the `group.verb` shape the table's CHECK enforces. */
export const ACTION_RE = /^[a-z_]{2,30}\.[a-z_]{2,40}$/;

export interface AuditCredential {
  kind: 'api_key' | 'pat' | 'oauth';
  id: string;
  userId?: string | null;
  clientId?: string | null;
}

const SAFE_REF = /^[A-Za-z0-9_.-]{1,100}$/;

/**
 * The headers exos-api sends with every PostgREST call made for a request:
 * X-Exos-Actor (api_key:<id> | pat:<id> | oauth_app:<client id>),
 * X-Exos-Actor-Uid (a user token's user), X-Exos-Request-Id.
 */
export function actorHeaders(cred: AuditCredential, requestId: string): Record<string, string> {
  const h: Record<string, string> = {};
  if (cred.kind === 'api_key' && SAFE_REF.test(cred.id)) h['x-exos-actor'] = `api_key:${cred.id}`;
  else if (cred.kind === 'pat' && SAFE_REF.test(cred.id)) h['x-exos-actor'] = `pat:${cred.id}`;
  else if (cred.kind === 'oauth' && cred.clientId && SAFE_REF.test(cred.clientId)) h['x-exos-actor'] = `oauth_app:${cred.clientId}`;
  if (cred.kind !== 'api_key' && cred.userId && /^[0-9a-f-]{36}$/i.test(cred.userId)) h['x-exos-actor-uid'] = cred.userId;
  if (/^[A-Za-z0-9_.:-]{1,100}$/.test(requestId)) h['x-exos-request-id'] = requestId;
  return h;
}

/** A row of exos_org_audit as GET /v1/audit shows it. */
// deno-lint-ignore no-explicit-any
export function apiAuditRow(r: any): Record<string, unknown> {
  return {
    id: Number(r.id),
    at: r.at,
    event_id: r.event_id ?? null,
    action: r.action,
    group: auditGroup(r.action),
    entity: { type: r.entity_type, id: r.entity_id ?? null },
    actor: { kind: r.actor_kind, user_id: r.actor_uid ?? null, ref: r.actor_ref ?? null, role: r.actor_role ?? null },
    changes: r.changes ?? {},
    amount_cents: r.amount_cents === null || r.amount_cents === undefined ? null : Number(r.amount_cents),
    currency: r.currency ?? null,
    reason: r.reason ?? null,
    source: r.source,
    request_id: r.request_id ?? null,
  };
}

/** The columns GET /v1/audit selects (never anything else exists to select). */
export const AUDIT_COLS =
  'id, at, event_id, actor_uid, actor_kind, actor_ref, actor_role, action, entity_type, entity_id, changes, ' +
  'amount_cents, currency, reason, source, request_id';
