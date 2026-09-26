// Door lookup against the cached check-in roster: by attendee name or the
// tail of the pass id, so staff aren't stuck typing a full UUID.

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** A full pass id or scanned QR payload: send it straight to the check-in path. */
export function isFullTicketId(q: string): boolean {
  const v = q.trim();
  return UUID_RE.test(v) || v.includes(':');
}

export function rosterMatches<E extends { name: string; used?: boolean; voided?: boolean }>(
  roster: Record<string, E>,
  query: string,
  limit = 6,
): [string, E][] {
  const q = query.trim().toLowerCase();
  if (q.length < 2 || isFullTicketId(q)) return [];
  const idTail = q.replace(/[^0-9a-f]/g, '');
  const out: [string, E][] = [];
  for (const [id, entry] of Object.entries(roster)) {
    const byName = (entry.name || '').toLowerCase().includes(q);
    const byId = idTail.length >= 4 && idTail === q && id.toLowerCase().replace(/-/g, '').endsWith(idTail);
    if (byName || byId) out.push([id, entry]);
  }
  // Not-yet-admitted first, then by name.
  out.sort(([, a], [, b]) => Number(!!a.used || !!a.voided) - Number(!!b.used || !!b.voided) || (a.name || '').localeCompare(b.name || ''));
  return out.slice(0, limit);
}
