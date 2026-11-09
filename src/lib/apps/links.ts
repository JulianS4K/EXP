// The apps suite's public pages, for links (the site footer). Kept apart from
// landing.ts so the footer, which is in the first download, doesn't pull in
// the facts registry; landing.test.ts checks the two lists agree.

export const APP_LINKS = [
  { id: 'door', path: '/apps/door', name: 'Door' },
  { id: 'events', path: '/apps/events', name: 'Events' },
  { id: 'promote', path: '/apps/promote', name: 'Promote' },
  { id: 'money', path: '/apps/money', name: 'Money' },
] as const;
