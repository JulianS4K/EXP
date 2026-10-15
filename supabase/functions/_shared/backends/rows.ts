// One attendee row as exos_backend_apply takes it (mig 20261016100000).
export interface BackendRow {
  ref: string;
  code: string | null;
  name: string | null;
  email: string | null;
  ticket: string | null;
  void: boolean;
  reason?: string;
}

/** Only https URLs; trailing slashes trimmed. Null when unusable. */
export function baseUrl(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const s = raw.trim().replace(/\/+$/, "");
  try {
    const u = new URL(s);
    if (u.protocol !== "https:" || u.username || u.password || u.search || u.hash) return null;
    return u.origin + u.pathname.replace(/\/+$/, "");
  } catch {
    return null;
  }
}

export const SLUG = /^[A-Za-z0-9._-]{1,64}$/;

/** "Ana" + "Lee" -> "Ana Lee"; empty -> null. */
export function joinName(...parts: unknown[]): string | null {
  const s = parts.map((p) => (typeof p === "string" ? p.trim() : "")).filter(Boolean).join(" ");
  return s ? s.slice(0, 80) : null;
}
