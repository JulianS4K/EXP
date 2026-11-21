// @vitest-environment jsdom
// The ads phase's preview (mig 20261121190500): "Boost this event" shows the
// planned campaign per platform (paused, $0 price and budget by default, the
// steps and their payloads, the warnings) and says nothing was sent; "Ad
// audiences" shows the consenting count and Reddit's audience warnings; the
// "What we'd send" panel labels the ad steps. Every plan is a dry run.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';

const h = vi.hoisted(() => ({ boostArgs: [] as unknown[][], audienceArgs: [] as unknown[][], fail: false, rows: [] as any[] }));
vi.mock('../lib/supabase', () => ({ supabase: {}, initialAuthUrl: '' }));
vi.mock('../lib/adsPlan', async (orig) => {
  const real = await orig<typeof import('../lib/adsPlan')>();
  return {
    ...real,
    planBoost: async (...args: unknown[]) => {
      h.boostArgs.push(args);
      if (h.fail) throw new Error('owners and managers only');
      return BOOST;
    },
    planAudience: async (...args: unknown[]) => { h.audienceArgs.push(args); return AUDIENCE; },
  };
});
vi.mock('../lib/channelAudit', async (orig) => {
  const real = await orig<typeof import('../lib/channelAudit')>();
  return { ...real, fetchPlannedWrites: async () => h.rows, fetchUsageSummary: async () => [] };
});

import BoostEventPanel from './BoostEventPanel';
import AdAudienceSyncPanel from './AdAudienceSyncPanel';
import ChannelAuditPanel from './ChannelAuditPanel';
import { budgetCents, geoLine, money, pausedSummary, type AudiencePlanResponse, type BoostPlanResponse } from '../lib/adsPlan';
import { stepLabel } from '../lib/channelAudit';

const ORG = '11111111-1111-4111-8111-111111111111';
const EV = '22222222-2222-4222-8222-222222222222';
const step = (op: string, path: string, body: unknown) => ({ op, method: 'POST', path, live: false, body });
const ok = (op: string, path: string) => ({ op, method: 'POST', path, planned: true, ok: true });

const BOOST: BoostPlanResponse = {
  dry_run: true,
  connected: { ads_meta_api: true, ads_reddit_api: false },
  plan: {
    name: 'Exos boost: Boost Night', headline: 'Boost Night', body: 'Sat, Dec 5, 8:00 PM at Hall. Tickets from $25.00. Get tickets on Exos.',
    imageUrl: 'https://img.example/boost.jpg', url: 'https://exos.example/e/boost-night?utm_source=exos', cta: 'BUY_TICKETS',
    startTime: '2026-11-21T12:00:00Z', endTime: '2026-12-06T01:00:00Z', dailyBudgetCents: 0, priceCents: 0, currency: 'USD',
    geo: { kind: 'radius', miles: 10, zips: ['10001', '11211'], boroughs: ['Manhattan', 'Brooklyn'] },
    communities: ['nyc', 'Brooklyn'], warnings: ['The daily budget is $0: set one before switching the campaign on (it is created paused either way).'],
    blocked: null,
  },
  channels: [
    {
      channel: 'meta_ads',
      result: { channel: 'meta_ads', connected: true, planned: true, ids: { campaign: 'planned_campaign' },
        warnings: ['The daily budget is $0: set one before switching the campaign on (it is created paused either way).'],
        steps: [ok('campaign.create', '/v25.0/act_123/campaigns'), ok('adset.create', '/v25.0/act_123/adsets'),
                ok('creative.create', '/v25.0/act_123/adcreatives'), ok('ad.create', '/v25.0/act_123/ads')] },
      steps: [step('campaign.create', '/v25.0/act_123/campaigns', { objective: 'OUTCOME_SALES', status: 'PAUSED' }),
              step('adset.create', '/v25.0/act_123/adsets', { status: 'PAUSED', daily_budget: 0 }),
              step('creative.create', '/v25.0/act_123/adcreatives', { object_story_spec: { link_data: { call_to_action: { type: 'BUY_TICKETS' } } } }),
              step('ad.create', '/v25.0/act_123/ads', { status: 'PAUSED' })],
    },
    {
      channel: 'reddit_ads',
      result: { channel: 'reddit_ads', connected: false, planned: true, ids: {}, warnings: ["Reddit Ads isn't connected: the ad account below is a placeholder."],
        steps: [ok('campaign.create', '/api/v3/ad_accounts/planned_account/campaigns')] },
      steps: [step('campaign.create', '/api/v3/ad_accounts/planned_account/campaigns', { data: { objective: 'CONVERSIONS', configured_status: 'PAUSED' } })],
    },
  ],
};

const AUDIENCE: AudiencePlanResponse = {
  dry_run: true, connected: {}, channel: 'reddit_ads',
  audience: { rows: 12, noConsent: 0, noIdentifier: 0, duplicates: 2, members: 10, withEmail: 10, withPhone: 3 },
  result: { channel: 'reddit_ads', connected: false, planned: true, ids: { audience: 'planned_audience' }, steps: [],
    warnings: ['Only 10 people have an email on this list, and fewer will match: Reddit needs at least 1,000 matched users before the audience can be used.',
               'Reddit takes up to 36 hours to process an uploaded list.', 'A Reddit custom audience expires after a year: Exos would have to upload it again.'] },
  steps: [step('audience.create', '/api/v3/ad_accounts/planned_account/custom_audiences', {}),
          step('audience.add_users', '/api/v3/custom_audiences/planned_audience/users', { data: { user_data: '[10 hashed rows (EMAIL_SHA256), not recorded]' } })],
};

beforeEach(() => { h.boostArgs = []; h.audienceArgs = []; h.fail = false; h.rows = []; });
afterEach(cleanup);

describe('adsPlan helpers', () => {
  it('formats money and budgets, the geo line and the summary', () => {
    expect(money(2500)).toBe('$25.00');
    expect(budgetCents('20')).toBe(2000);
    expect(budgetCents('$1,250.50')).toBe(125050);
    expect(budgetCents('-5')).toBe(0);
    expect(budgetCents('abc')).toBe(0);
    expect(geoLine(BOOST.plan.geo)).toContain('Within 10 miles of the venue');
    expect(geoLine({ kind: 'none', reason: 'No venue.' })).toBe('No venue.');
    expect(pausedSummary(BOOST.channels[0].result)).toBe('4 of 4 steps planned; created paused, nothing sent.');
    expect(stepLabel('adset.create')).toBe('Create the ad set (paused)');
    expect(stepLabel('event.create')).toBe('event.create');
  });
});

describe('BoostEventPanel', () => {
  it('plans on the chosen platforms with a $0 budget by default and shows the paused, unsent plan', async () => {
    render(<BoostEventPanel eventId={EV} orgId={ORG} />);
    fireEvent.click(screen.getByRole('button', { name: 'Plan the campaign' }));
    const plan = await screen.findByTestId('boost-plan');
    expect(h.boostArgs).toEqual([[ORG, EV, ['meta_ads', 'reddit_ads'], 0]]);
    expect(plan.textContent).toContain('Dry run: nothing was sent.');
    expect(plan.textContent).toContain('Exos boost: Boost Night');
    expect(plan.textContent).toContain('Free');
    expect(plan.textContent).toContain('$0.00');
    expect(plan.textContent).toContain('r/nyc, r/Brooklyn');
    const channels = screen.getAllByTestId('boost-channel');
    expect(channels).toHaveLength(2);
    expect(channels[0].textContent).toContain('Create the campaign (paused)');
    expect(channels[0].textContent).toContain('created paused, nothing sent');
    expect(channels[1].textContent).toContain("Reddit Ads isn't connected");
    // One warning shown once per platform even when the plan and the result both carry it.
    expect(channels[0].querySelectorAll('[role="note"]')).toHaveLength(1);
    fireEvent.click(screen.getAllByRole('button', { name: 'Payload' })[0]);
    expect(screen.getByText(/"objective": "OUTCOME_SALES"/)).toBeTruthy();
  });

  it('sends the typed budget and only the ticked platforms; shows a refusal', async () => {
    render(<BoostEventPanel eventId={EV} orgId={ORG} />);
    fireEvent.click(screen.getByLabelText('Reddit'));
    fireEvent.change(screen.getByLabelText('Daily budget (USD)'), { target: { value: '15.5' } });
    h.fail = true;
    fireEvent.click(screen.getByRole('button', { name: 'Plan the campaign' }));
    expect((await screen.findByRole('alert')).textContent).toBe('owners and managers only');
    expect(h.boostArgs).toEqual([[ORG, EV, ['meta_ads'], 1550]]);
    expect(screen.queryByTestId('boost-plan')).toBeNull();
    fireEvent.click(screen.getByLabelText('Meta (Facebook and Instagram)'));
    expect((screen.getByRole('button', { name: 'Plan the campaign' }) as HTMLButtonElement).disabled).toBe(true);
  });
});

describe('AdAudienceSyncPanel', () => {
  it('plans a Reddit list: the consenting count, Reddit\'s warnings, hashed rows never shown', async () => {
    render(<AdAudienceSyncPanel orgId={ORG} />);
    fireEvent.change(screen.getByLabelText('Platform'), { target: { value: 'reddit_ads' } });
    fireEvent.click(screen.getByRole('button', { name: 'Plan the audience' }));
    const out = await screen.findByTestId('ad-audience-plan');
    expect(h.audienceArgs).toEqual([[ORG, 'reddit_ads']]);
    expect(out.textContent).toContain('10 people who agreed to advertising (10 with an email, 3 with a phone)');
    expect(out.textContent).toContain('1,000 matched users');
    expect(out.textContent).toContain('36 hours');
    expect(out.textContent).toContain('expires after a year');
    expect(out.textContent).toContain('Upload hashed people to the audience');
  });
});

describe("What we'd send with ad steps", () => {
  it('labels the ad channels and their steps', async () => {
    h.rows = [{
      id: 'a1', channel: 'reddit_ads', op: 'ad_group.create', method: 'POST', path: '/api/v3/ad_accounts/a2_x/ad_groups', live: false,
      request: { headers: { Authorization: '[redacted]' }, body: { data: { configured_status: 'PAUSED' } } }, response: { stand_in: true },
      status: null, ok: true, error: null, warnings: null, event_id: EV, at: '2026-11-21T12:00:00Z',
    }];
    render(<ChannelAuditPanel orgId={ORG} />);
    await screen.findByTestId('channel-audit-panel');
    await waitFor(() => expect(screen.getByText('Reddit Ads')).toBeTruthy());
    expect(screen.getByText('Create the ad group (paused)')).toBeTruthy();
  });
});
