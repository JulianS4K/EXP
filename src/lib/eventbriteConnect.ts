// "Connect Eventbrite" helpers (exos-eventbrite-oauth, mig 20261029140000).
// Pure, so vitest covers it; the fetch calls are in ./door/eventbrite, the
// return from Eventbrite is read by ./oauthReturn and confirmed in
// components/OAuthFinish.tsx. After /finish, a sign-in started from an
// event's door page goes back there (eventPickPath) so the organizer picks
// the Eventbrite event straight away.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Where to pick the Eventbrite event after connecting from an event's door
 * page: that event's report, door tab, with the picker opened. Null for
 * anything that isn't an event id (stay on the settings page).
 */
export function eventPickPath(eventId: unknown): string | null {
  return typeof eventId === 'string' && UUID.test(eventId)
    ? `/dashboard/event/${eventId}?tab=door&eventbrite=pick`
    : null;
}

/** Whether a door page was opened to pick the Eventbrite event (?eventbrite=pick). */
export const wantsEventbritePick = (search: string): boolean =>
  new URLSearchParams(search).get('eventbrite') === 'pick';

/** Eventbrite's authorize page, and nothing else, is where Connect may send the browser. */
export const isEventbriteAuthorizeUrl = (u: unknown): u is string =>
  typeof u === 'string' && u.startsWith('https://www.eventbrite.com/oauth/authorize?');

export function eventbriteErrorMessage(reason: string): string {
  switch (reason) {
    case 'denied': return 'Eventbrite wasn’t connected: access was declined on Eventbrite’s page.';
    case 'expired':
    case 'state': return 'That Eventbrite sign-in expired or was already used. Click Connect Eventbrite again.';
    case 'auth': return 'Sign in to Exos in this browser, then connect Eventbrite again.';
    case 'forbidden': return 'Only owners and managers can connect Eventbrite.';
    case 'rate': return 'Too many tries. Wait a few minutes, then connect Eventbrite again.';
    case 'config': return 'The Exos app on Eventbrite isn’t set up right (client id, secret or redirect URI). Tell your Exos admin.';
    case 'not_configured': return 'Connecting with Eventbrite isn’t set up on this Exos server yet. Paste a private token instead.';
    case 'eventbrite':
    case 'exchange': return 'Eventbrite didn’t finish the connection. Try again.';
    default: return 'Could not connect Eventbrite. Try again.';
  }
}

/** One line for how the org's account is connected. */
export function authMethodLabel(m: string | null | undefined): string {
  if (m === 'oauth') return 'Connected with Eventbrite sign-in';
  if (m === 'private_token') return 'Connected with a private token';
  return 'Not connected';
}
