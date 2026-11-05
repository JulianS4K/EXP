// The fan API: /v1/me/… routes of exos-api (mig 20261105110000,
// docs/api/me.json). The signed-in user's own tickets, orders, transfers,
// memberships, passes, refund requests, wallet passes and profile.
//
// Who may call them: a USER token only, i.e. a personal access token
// (exos_pat_…, pinned to an organization), an account token (exos_pat_…, a
// user with no organization) or an OAuth access token (exos_oat_…), holding
// me:read / me:write. An org API key has no user and is refused (403). Every
// route is ONE call to exos_api_me(token hash, kind, action, target, args),
// which re-resolves the token, checks the scope again and runs the same
// signed-in RPC the app runs, as that user. No business rule lives here:
// this file maps a route to its action and shapes the request.
//
// An account token (no organization) may call these routes, GET /v1/me and
// DELETE /v1/personal-access-tokens/current, and nothing else. Token routes
// (/v1/me/personal-access-tokens) need a personal or account token: an OAuth
// app never manages its user's credentials (the SQL refuses it).
//
// Pure TypeScript, imported by vitest (src/lib/apiMe.test.ts).

import { isUserScope, type Scope } from './scopes.ts';

export type MeCredentialKind = 'api_key' | 'pat' | 'oauth';

/** A /v1/me route: the exos_api_me action, the path param that is its target, and wallet routes' kind. */
export interface MeRoute {
  action: string;
  target?: string;
  /** A wallet route: the pass to build. */
  wallet?: 'apple' | 'google';
  /** Season-pass routes only answer for season passes (flex packs are /me/passes). */
  passKind?: 'season' | 'flex';
}

/** Every /v1/me route, by route id (_shared/api/routes.ts). */
export const ME_ROUTES: Readonly<Record<string, MeRoute>> = {
  'get-my-profile': { action: 'profile.get' },
  'update-my-profile': { action: 'profile.update' },
  'get-my-marketing-preferences': { action: 'profile.get' },
  'set-my-marketing-preferences': { action: 'marketing.set' },
  'list-my-tickets': { action: 'tickets.list' },
  'get-my-ticket': { action: 'ticket.get', target: 'id' },
  'get-my-ticket-pkpass': { action: 'wallet.ticket', target: 'id', wallet: 'apple' },
  'get-my-ticket-google-wallet': { action: 'wallet.ticket', target: 'id', wallet: 'google' },
  'list-my-ticket-bundles': { action: 'bundles.list' },
  'get-my-ticket-bundle': { action: 'bundles.list', target: 'id' },
  'list-my-orders': { action: 'orders.list' },
  'get-my-order': { action: 'order.get', target: 'id' },
  'list-my-order-transferable': { action: 'order.transferable', target: 'id' },
  'create-my-order-transfers': { action: 'order.transfer', target: 'id' },
  'get-my-order-refund-request': { action: 'order.refund_asks', target: 'id' },
  'create-my-order-refund-request': { action: 'order.refund_ask', target: 'id' },
  'list-my-transfers': { action: 'transfers.list' },
  'create-my-transfers': { action: 'transfers.create' },
  'cancel-my-transfer': { action: 'transfer.cancel', target: 'id' },
  'claim-transfer': { action: 'transfer.claim', target: 'id' },
  'list-my-fan-memberships': { action: 'memberships.list' },
  'get-my-fan-membership': { action: 'membership.get', target: 'id' },
  'list-my-season-passes': { action: 'passes.list', passKind: 'season' },
  'get-my-season-pass': { action: 'pass.get', target: 'id', passKind: 'season' },
  'get-my-season-pass-pkpass': { action: 'wallet.season_pass', target: 'id', wallet: 'apple', passKind: 'season' },
  'get-my-season-pass-google-wallet': { action: 'wallet.season_pass', target: 'id', wallet: 'google', passKind: 'season' },
  'list-my-passes': { action: 'passes.list' },
  'get-my-pass': { action: 'pass.get', target: 'id' },
  'list-my-refund-requests': { action: 'refund_asks.list' },
  'create-my-refund-request': { action: 'refund.ask' },
  'withdraw-my-refund-request': { action: 'refund.withdraw', target: 'id' },
  'list-my-tokens': { action: 'tokens.list' },
  'create-my-token': { action: 'token.create' },
  'revoke-my-token': { action: 'token.revoke', target: 'id' },
};

/** The scope each action needs: must equal _exos_api_me_action_scope in the migration (apiMe.test.ts). */
export const ME_ACTION_SCOPE: Readonly<Record<string, Scope>> = {
  'profile.get': 'me:read', 'tickets.list': 'me:read', 'ticket.get': 'me:read', 'bundles.list': 'me:read',
  'orders.list': 'me:read', 'order.get': 'me:read', 'order.transferable': 'me:read', 'transfers.list': 'me:read',
  'memberships.list': 'me:read', 'membership.get': 'me:read', 'passes.list': 'me:read', 'pass.get': 'me:read',
  'refund_asks.list': 'me:read', 'order.refund_asks': 'me:read', 'wallet.ticket': 'me:read',
  'wallet.season_pass': 'me:read',
  'profile.update': 'me:write', 'marketing.set': 'me:write', 'transfers.create': 'me:write',
  'order.transfer': 'me:write', 'transfer.cancel': 'me:write', 'transfer.claim': 'me:write',
  'refund.ask': 'me:write', 'order.refund_ask': 'me:write', 'refund.withdraw': 'me:write',
  'tokens.list': 'me:read', 'token.create': 'me:write', 'token.revoke': 'me:write',
};

export function isMeRoute(routeId: string): boolean {
  return Object.prototype.hasOwnProperty.call(ME_ROUTES, routeId);
}

/** A route whose scope is a user scope needs a user token. */
export function needsUserToken(scope: string | null): boolean {
  return scope !== null && isUserScope(scope);
}

/**
 * Why this credential may not call this route, or null when it may.
 *   * a /v1/me route: user tokens only (an org API key has no user);
 *   * an account token (no organization): the /v1/me routes, GET /v1/me and
 *     revoking itself, nothing else.
 */
export function meRefusal(
  kind: MeCredentialKind, account: boolean, routeId: string, scope: string | null,
): string | null {
  if (needsUserToken(scope) && kind === 'api_key') {
    return 'this route acts as a user: use a personal access token, an account token or an OAuth token (an organization API key has no user)';
  }
  if (account && !needsUserToken(scope) && routeId !== 'me' && routeId !== 'revoke-current-token') {
    return 'an account token belongs to no organization: it can call /v1/me/… only';
  }
  return null;
}

export class MeBodyError extends Error {}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$/;

function unwrapped(body: Record<string, unknown>, ...wrappers: string[]): Record<string, unknown> {
  for (const w of wrappers) {
    const v = body[w];
    if (v && typeof v === 'object' && !Array.isArray(v)) return v as Record<string, unknown>;
  }
  return body;
}

function uuidList(v: unknown, name: string, max = 50): string[] {
  const list = typeof v === 'string' ? v.split(',').map((s) => s.trim()).filter(Boolean) : v;
  if (!Array.isArray(list) || list.length < 1 || list.length > max) {
    throw new MeBodyError(`${name} must be a list of 1 to ${max} ids`);
  }
  for (const x of list) if (typeof x !== 'string' || !UUID_RE.test(x)) throw new MeBodyError(`${name} must be ticket UUIDs`);
  return [...new Set(list as string[])];
}

function email(v: unknown, name: string): string {
  const s = typeof v === 'string' ? v.trim() : '';
  if (!EMAIL_RE.test(s) || s.length > 254) throw new MeBodyError(`${name} must be an email address`);
  return s.toLowerCase();
}

function optText(v: unknown, name: string, max: number): string | null {
  if (v === undefined || v === null || v === '') return null;
  if (typeof v !== 'string') throw new MeBodyError(`${name} must be a string`);
  const s = v.trim().replace(/\s+/g, ' ');
  if (s.length > max) throw new MeBodyError(`${name} is at most ${max} characters`);
  return s || null;
}

function bool(v: unknown, name: string): boolean {
  if (v === true || v === 'true' || v === '1') return true;
  if (v === false || v === 'false' || v === '0') return false;
  throw new MeBodyError(`${name} must be true or false`);
}

/**
 * The args of a /v1/me write, from its body (JSON or form). Opendate's
 * wrappers are accepted (ticket_transfer, refund_request, user).
 */
export function meWriteArgs(routeId: string, raw: Record<string, unknown>): Record<string, unknown> {
  switch (routeId) {
    case 'update-my-profile': {
      const b = unwrapped(raw, 'user', 'profile');
      const out: Record<string, unknown> = {};
      for (const k of Object.keys(b)) {
        if (k !== 'display_name' && k !== 'name') throw new MeBodyError(`unknown or read-only field: ${k.slice(0, 40)}`);
      }
      const v = b.display_name ?? b.name;
      if (v !== undefined) out.display_name = optText(v, 'display_name', 80);
      return out;
    }
    case 'set-my-marketing-preferences': {
      const b = unwrapped(raw, 'marketing_preferences', 'user');
      const v = b.marketing_emails ?? b.subscribe_to_marketing_email ?? b.email_opt_in;
      if (v === undefined) throw new MeBodyError('marketing_emails is required');
      return { marketing_emails: bool(v, 'marketing_emails') };
    }
    case 'create-my-transfers': {
      const b = unwrapped(raw, 'ticket_transfer');
      const items = b.items ?? b.transfers;
      if (items !== undefined) {
        if (!Array.isArray(items) || items.length < 1 || items.length > 50) {
          throw new MeBodyError('items must be a list of 1 to 50 { ticket_id, email, name }');
        }
        return {
          items: items.map((it, i) => {
            const o = (it && typeof it === 'object' ? it : {}) as Record<string, unknown>;
            if (typeof o.ticket_id !== 'string' || !UUID_RE.test(o.ticket_id)) {
              throw new MeBodyError(`items[${i}].ticket_id must be a ticket UUID`);
            }
            return { ticket_id: o.ticket_id, email: email(o.email, `items[${i}].email`), name: optText(o.name, `items[${i}].name`, 100) };
          }),
        };
      }
      const ids = uuidList(b.ticket_ids ?? (b.ticket_id !== undefined ? [b.ticket_id] : undefined), 'ticket_ids');
      const to = email(b.email ?? b.recipient_email, 'email');
      const name = optText(b.name ?? b.recipient_name, 'name', 100);
      return { items: ids.map((id) => ({ ticket_id: id, email: to, name })) };
    }
    case 'create-my-order-transfers': {
      const b = unwrapped(raw, 'ticket_transfer');
      const out: Record<string, unknown> = {
        email: email(b.email ?? b.recipient_email, 'email'),
        name: optText(b.name ?? b.recipient_name, 'name', 100),
      };
      if (b.ticket_ids !== undefined) out.ticket_ids = uuidList(b.ticket_ids, 'ticket_ids');
      return out;
    }
    case 'claim-transfer': {
      const b = unwrapped(raw, 'ticket_transfer');
      const key = b.key ?? b.claim_key;
      if (typeof key !== 'string' || !/^[A-Za-z0-9_-]{16,128}$/.test(key.trim())) {
        throw new MeBodyError('key (from the claim link) is required');
      }
      return { key: key.trim() };
    }
    case 'create-my-refund-request': {
      const b = unwrapped(raw, 'refund_request');
      return { ticket_ids: uuidList(b.ticket_ids, 'ticket_ids'), reason: optText(b.reason, 'reason', 500) };
    }
    case 'create-my-token': {
      const b = unwrapped(raw, 'personal_access_token', 'token');
      for (const k of Object.keys(b)) {
        if (!['name', 'scopes', 'expires_days'].includes(k)) throw new MeBodyError(`unknown or read-only field: ${k.slice(0, 40)}`);
      }
      const scopes = typeof b.scopes === 'string' ? b.scopes.split(/[\s,]+/).filter(Boolean) : b.scopes;
      if (!Array.isArray(scopes) || scopes.length < 1 || scopes.length > 40 || scopes.some((x) => typeof x !== 'string')) {
        throw new MeBodyError('scopes must be a list of scope names');
      }
      const out: Record<string, unknown> = { name: optText(b.name, 'name', 80) ?? 'Token', scopes: [...new Set(scopes as string[])] };
      if (b.expires_days !== undefined) {
        const d = b.expires_days === null || b.expires_days === '' ? null : Number(b.expires_days);
        if (d !== null && ![30, 90, 365].includes(d)) throw new MeBodyError('expires_days must be 30, 90, 365 or null');
        out.expires_days = d;
      }
      return out;
    }
    case 'create-my-order-refund-request': {
      const b = unwrapped(raw, 'refund_request');
      const out: Record<string, unknown> = { reason: optText(b.reason ?? b.notes, 'reason', 500) };
      if (b.ticket_ids !== undefined) out.ticket_ids = uuidList(b.ticket_ids, 'ticket_ids');
      return out;
    }
  }
  return {};
}

/** The args of a /v1/me read from its query (filters). */
export function meReadArgs(routeId: string, q: URLSearchParams): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (routeId === 'list-my-tickets') {
    const ev = q.get('event_id');
    if (ev !== null) {
      if (!UUID_RE.test(ev)) throw new MeBodyError('event_id must be a UUID');
      out.event_id = ev;
    }
    const st = q.get('status');
    if (st !== null) {
      if (!['active', 'used', 'voided', 'refunded', 'transferred'].includes(st)) {
        throw new MeBodyError('status must be active, used, voided, refunded or transferred');
      }
      out.status = st;
    }
  }
  if (routeId === 'list-my-passes') {
    const k = q.get('kind');
    if (k !== null) {
      if (k !== 'season' && k !== 'flex') throw new MeBodyError('kind must be season or flex');
      out.kind = k;
    }
  }
  return out;
}

/** The profile answer of GET /v1/me/marketing-preferences: just the preference. */
export function marketingView(profile: Record<string, unknown> | null): { marketing_emails: boolean } {
  return { marketing_emails: profile?.marketing_emails !== false };
}

/** A why-not reason from exos_wallet_issue_pass / exos_wallet_season_pass as an HTTP status. */
export function walletRefusalStatus(reason: unknown): number {
  return reason === 'record_not_found' ? 404 : 409;
}

// SQLSTATEs of exos_api_me / exos_api_gap_write and the RPCs they call, as
// HTTP statuses. The app's own RPCs raise many refusals as plain exceptions
// (P0001: "ticket already has a pending transfer", "this claim link is not
// valid" is 42501): those are the user's request being refused, a 409.
const GAP_SQL_STATUS: Record<string, number> = {
  '22023': 400, '22P02': 400, '22007': 400, '22008': 400, '22001': 400, '22003': 400, '23502': 400,
  '42501': 403, P0002: 404,
  '23505': 409, '23503': 409, '23514': 409, '55000': 409, P0001: 409,
  '54000': 429,
};

/** A raised SQL error of a fan-API / gap write as { status, message }, or null (a 500). */
export function gapSqlError(e: unknown): { status: number; message: string } | null {
  const err = e as { code?: unknown; message?: unknown } | null;
  const code = typeof err?.code === 'string' ? err.code : '';
  if (!(code in GAP_SQL_STATUS)) return null;
  const message = String(err?.message ?? 'invalid request')
    .replace(/^(exos|_exos)_[a-z_]+: /, '').replace(/^(exos|_exos)_[a-z_]+: /, '').slice(0, 300);
  return { status: GAP_SQL_STATUS[code], message };
}
