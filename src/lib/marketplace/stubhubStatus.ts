// What the event editor says about an event's StubHub event request
// (exos_distribution_listings, channel 'stubhub'; mig 20260926190000).
// Pure, so the wording is tested without a database.

export interface StubHubDistributionRow {
  status: string;
  error: string | null;
  external_event_id: string | null;
  planned_request: { body?: { event?: { name?: string }; venue?: { name?: string; city?: string } } } | null;
  last_synced_at: string | null;
}

export type StubHubStatusTone = 'muted' | 'info' | 'ok' | 'warn';

export interface StubHubStatus {
  tone: StubHubStatusTone;
  text: string;
}

export function stubHubStatus(
  row: StubHubDistributionRow | null,
  ev: { stubhubTicked: boolean; published: boolean; primaryMarketOnly: boolean },
): StubHubStatus | null {
  if (row?.external_event_id) return { tone: 'ok', text: `On StubHub (event ${row.external_event_id}).` };
  if (!ev.stubhubTicked) return null;
  if (ev.primaryMarketOnly) return { tone: 'muted', text: 'Primary market only is on, so nothing goes to StubHub.' };
  if (!row) {
    return ev.published
      ? { tone: 'muted', text: 'Save to queue the StubHub event request.' }
      : { tone: 'muted', text: 'The StubHub event is requested when you publish.' };
  }
  switch (row.status) {
    case 'pending':
      return { tone: 'info', text: 'Queued: Exos is preparing the StubHub event request.' };
    case 'planned': {
      const b = row.planned_request?.body;
      const what = [b?.event?.name, [b?.venue?.name, b?.venue?.city].filter(Boolean).join(', ')].filter(Boolean).join(' at ');
      return {
        tone: 'info',
        text: `StubHub event request ready${what ? ` for ${what}` : ''}. Not sent yet: StubHub selling isn't switched on.`,
      };
    }
    case 'failed':
      return { tone: 'warn', text: `Couldn't prepare the StubHub request: ${row.error || 'unknown error'}. Fix it and save.` };
    default:
      return { tone: 'muted', text: `StubHub: ${row.status}.` };
  }
}
