// Reading a Luma or Posh PUBLIC event page — NOT ENABLED.
//
// TODO(operator decision, spec §7.2): importing a pasted Luma or Posh link
// with its details filled in means reading the event's public web page
// (Luma's API key only reads the org's own calendar; Posh has no API). That
// needs the operator's OK and a check of each platform's terms first. Until
// then exos-event-import creates a DRAFT link-out event from the link and the
// details the organizer types, and nothing calls this function.
//
// When it is approved, implement it here and only here:
//   * fetch only https URLs that parseEventUrl accepted (luma.com / lu.ma /
//     posh.vip), through _shared/ssrf.ts urlIsBlocked first, GET only,
//     redirect: "manual", a short timeout and a size cap;
//   * read the page's schema.org Event JSON-LD (name, startDate, location,
//     offers, image) — no other scraping;
//   * return the same ImportData shape as eventbrite.ts so the import RPC is
//     unchanged; and add the re-check for these platforms to the cron.

import type { ImportData } from './eventbrite.ts';
import type { ParsedEventUrl } from './urls.ts';

export class PublicPageReadsDisabled extends Error {
  constructor() {
    super('Reading Luma / Posh public event pages is not enabled (pending the operator\'s decision).');
  }
}

/** Not called anywhere. Throws until the operator approves public-page reads. */
// deno-lint-ignore require-await
export async function fetchPublicEventPage(_link: ParsedEventUrl): Promise<ImportData> {
  throw new PublicPageReadsDisabled();
}
