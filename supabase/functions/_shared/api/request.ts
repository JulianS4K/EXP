// Request bodies, Idempotency-Keys and SQLSTATE → HTTP for exos-api.
// docs/api-reference.md ("Paging, limits, errors").
//
// exos-api/index.ts reads a body with readCapped (./body.ts), then hands the
// text here; the SQL functions raise fixed SQLSTATEs that rpcStatus maps.
// Kept apart from index.ts so the request handling is testable
// (src/lib/sim/partner.test.ts).
//
// Pure TypeScript, imported by vitest.

import { formBody } from './body.ts';
import { railsFormBody } from '../partners/sales.ts';

/** A request the API refuses before doing anything: status + message. */
export class RequestError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

/**
 * The body of a POST / PUT / PATCH from its (already capped) text.
 *   flat:  JSON or one-level form fields; any other declared type is 415.
 *   rails: the partner contract and the platform routes take any declared
 *          type and Rails-style nested forms (_shared/partners/sales.ts).
 * An empty body is {}. A JSON array passes (PUT /events/:id/lineup takes a
 * bare list); a JSON scalar or null is 400.
 */
export function parseBodyText(contentType: string | null, text: string, mode: 'flat' | 'rails' = 'flat'): Record<string, unknown> {
  const ct = (contentType ?? '').toLowerCase();
  const isForm = ct.includes('application/x-www-form-urlencoded');
  if (mode === 'flat' && ct && !isForm && !ct.includes('json')) {
    throw new RequestError(415, 'send a JSON body (Content-Type: application/json) or a form-encoded one.');
  }
  if (!text.trim()) return {};
  if (isForm) return mode === 'rails' ? railsFormBody(text) : formBody(text);
  let v: unknown;
  try {
    v = JSON.parse(text);
  } catch {
    throw new RequestError(400, mode === 'rails' ? 'the body must be JSON or form-encoded' : 'the body is not valid JSON.');
  }
  if (!v || typeof v !== 'object') throw new RequestError(400, 'the body must be a JSON object.');
  return v as Record<string, unknown>;
}

export const IDEMPOTENCY_KEY_RE = /^[A-Za-z0-9_.:-]{8,100}$/;

/** An Idempotency-Key header value: null when absent; 400 when malformed. */
export function idempotencyKeyOf(v: string | null): string | null {
  if (v === null) return null;
  if (!IDEMPOTENCY_KEY_RE.test(v)) throw new RequestError(400, 'Idempotency-Key must be 8-100 letters, digits, _ . : or -');
  return v;
}

/**
 * SQLSTATEs the service-role SQL functions raise, as HTTP statuses (rpcError
 * and the partner contract's errorResponse in exos-api/index.ts). The EX*
 * codes are the partner-sales core's (mig 20261031130000): EXSLD sold out,
 * EX422 not on sale through this channel, EX409 a finished reservation.
 */
export const RPC_STATUS: Record<string, number> = {
  '22023': 400, '42501': 403, P0002: 404, '23505': 409, '55000': 409, '54000': 409,
  EX409: 409, EX422: 422, EXSLD: 409,
};

/** A raised SQL error as an HTTP answer, or null for anything unmapped (a 500). */
export function rpcAnswer(e: unknown): { status: number; body: Record<string, unknown> } | null {
  const err = e as { code?: unknown; message?: unknown } | null;
  const code = typeof err?.code === 'string' ? err.code : '';
  if (!(code in RPC_STATUS)) return null;
  const body: Record<string, unknown> = { error: String(err?.message ?? 'invalid request').slice(0, 300) };
  if (code === 'EXSLD') body.reason = 'sold_out';
  if (code === 'EX422') body.reason = 'not_available';
  return { status: RPC_STATUS[code], body };
}

// Routes of the developer platform and partner sales (#74, migs 20261031130000 /
// 130500). A personal or OAuth token may call these and every GET; any other
// write needs an org API key, since those writes record or check an API key id
// (exos_api_write, booking, offers, listing keys).
export const PLATFORM_ROUTES: ReadonlySet<string> = new Set([
  'list-distribution-partners', 'create-distribution-partner', 'update-distribution-partner',
  'revoke-distribution-partner', 'get-event-distribution', 'set-event-distribution', 'list-ticket-reservations',
  'get-ticket-reservation', 'build-organizer-reservation', 'create-organizer-reservation',
  'update-organizer-reservation', 'cancel-organizer-reservation', 'complete-organizer-reservation', 'get-team',
  'update-team', 'list-team-members', 'update-team-member', 'remove-team-member', 'list-team-invitations',
  'create-team-invitation', 'cancel-team-invitation', 'list-team-roles', 'list-my-memberships',
  'revoke-current-token',
]);

/**
 * May this credential call this route? An org API key: anything its scopes
 * allow. A personal or OAuth token: every GET and the platform routes only.
 */
export function userTokenMayCall(kind: 'api_key' | 'pat' | 'oauth', method: string, routeId: string): boolean {
  return kind === 'api_key' || method === 'GET' || PLATFORM_ROUTES.has(routeId);
}
