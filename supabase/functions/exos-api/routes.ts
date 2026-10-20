// Pure pieces of exos-api (no I/O), shared with routes_test.ts.

// exos_tickets has no owner_email: the buyer's email is buyer_email. It is
// returned as owner_email (PostgREST alias) so the response shape is unchanged.
export const ATTENDEE_SELECT =
  "id, tier_name, owner_email:buyer_email, status, check_in_at, price_paid, channel_source, created_at";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Event ids are uuids; anything else is a 404, not a Postgres cast error (500). */
export function isUuid(s: string | undefined): boolean {
  return !!s && UUID_RE.test(s);
}

/** The table columns a select list reads ("alias:column" reads column). */
export function selectedColumns(select: string): string[] {
  return select.split(",").map((c) => c.trim()).filter(Boolean).map((c) => c.split(":").pop()!.trim());
}
