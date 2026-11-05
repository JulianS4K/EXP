// Names that are really emails (mig 20261105100000, SIM-ORG-14): a guest
// list or attendee export with its columns swapped imports people named
// "ana@example.com". Refused wherever a person's name is typed or imported:
// guest imports and adds, comps, guest checkout, RSVP, order / ticket edits.
// Same rule as public.exos_name_has_email. Pure, no imports.

/** Why such a name is refused (the database raises the same words). */
export const NAME_IS_EMAIL = "name looks like an email; are your columns swapped?";

const EMAIL_IN_TEXT = /[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}/i;

/** True when the name is, or contains, an email address. */
export function nameLooksLikeEmail(name: unknown): boolean {
  return typeof name === "string" && EMAIL_IN_TEXT.test(name);
}

/** The refusal for a name, or null when it is fine (empty names are the
 *  caller's own "add a name" check). */
export function nameError(name: unknown): string | null {
  return nameLooksLikeEmail(name) ? NAME_IS_EMAIL : null;
}

/** Throws NAME_IS_EMAIL for such a name (the SPA's form helpers call it
 *  before the round trip; the database refuses it anyway). */
export function assertNotEmailName(name: unknown): void {
  if (nameLooksLikeEmail(name)) throw new Error(NAME_IS_EMAIL);
}
