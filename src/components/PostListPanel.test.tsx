// @vitest-environment jsdom
// "Post / list this event" (mig 20261121203000): every platform listed with
// its status (connected / not connected, always a dry run) and its notes;
// planning shows each platform's post (text, link, image), warnings and the
// requests with their payloads, and says nothing was sent. The pure status
// helpers and the post kit's labels are checked here too.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';

const h = vi.hoisted(() => ({ planArgs: [] as unknown[][], ctxArgs: [] as unknown[][], fail: false, ctxFail: false }));
vi.mock('../lib/supabase', () => ({ supabase: {}, initialAuthUrl: '' }));
vi.mock('../lib/socialPlan', async (orig) => {
  const real = await orig<typeof import('../lib/socialPlan')>();
  return {
    ...real,
    loadSocialContext: async (...args: unknown[]) => {
      h.ctxArgs.push(args);
      if (h.ctxFail) throw new Error('owners and managers only');
      return CTX;
    },
    planSocialPosts: async (...args: unknown[]) => {
      h.planArgs.push(args);
      if (h.fail) throw new Error('owners and managers only');
      return PLAN;
    },
  };
});

import PostListPanel from './PostListPanel';
import { connectInfo, planSummary, platformStatus, type SocialContext, type SocialPlanResponse } from '../lib/socialPlan';
import { stepLabel, channelLabel } from '../lib/channelAudit';

const ORG = '11111111-1111-4111-8111-111111111111';
const EV = '22222222-2222-4222-8222-222222222222';

const CTX: SocialContext = {
  org: { id: ORG, name: 'Social Hall', venue_org: true },
  event: { id: EV, name: 'Post Night', slug: 'post-night', image_url: 'https://img.example/post.jpg', venue_name: 'Social Hall', location_open: true },
  connected: { ig_publish: true, tiktok_publish: false, meetup: true, linkedin: false, google_business: true },
  facts: { meetup_plan: 'starter', meetup_pro_network: false, linkedin_org_page: false, gbp_verified_days: 30, gbp_own_connection: false },
};

const post = (platform: string, over: Record<string, unknown> = {}) => ({
  platform, title: 'Post Night', text: 'Thu, Dec 3, 2026, 9:00 PM\nSocial Hall\n\nTickets: link in bio.', url: null,
  imageUrl: 'https://img.example/post.jpg', videoUrl: null, startsAt: '2026-12-04T02:00:00Z', endsAt: null, timezone: 'America/New_York',
  venue: 'Social Hall', address: '', online: false, warnings: [], ...over,
});

const PLAN: SocialPlanResponse = {
  dry_run: true,
  connected: CTX.connected,
  platforms: [
    {
      platform: 'instagram', label: 'Instagram',
      status: { connected: true, provider: 'ig_publish', dryRun: true, app: 'meta', connect: 'stub' },
      post: post('instagram', { warnings: ['Links in the description were left out: Instagram captions can\'t carry a clickable link.'] }) as never,
      result: { channel: 'instagram', connected: true, planned: true, ids: { container: 'planned_ig_container' }, warnings: [],
        steps: [{ op: 'post.container', method: 'POST', path: '/v25.0/1784/media', planned: true, ok: true },
                { op: 'post.publish', method: 'POST', path: '/v25.0/1784/media_publish', planned: true, ok: true }] },
      steps: [
        { op: 'post.container', method: 'POST', path: '/v25.0/1784/media', live: false, body: { image_url: 'https://img.example/post.jpg', caption: 'Post Night' } },
        { op: 'post.publish', method: 'POST', path: '/v25.0/1784/media_publish', live: false, body: { creation_id: 'planned_ig_container' } },
      ],
    },
    {
      platform: 'google_business', label: 'Google Business Profile',
      status: { connected: true, provider: 'google_business', dryRun: true, app: 'google', connect: 'stub', via: 'ads_google_ads' },
      post: post('google_business', { url: 'https://exos.example/e/post-night?utm_source=google_business' }) as never,
      result: { channel: 'google_business', connected: true, planned: true, ids: {}, warnings: [], stopped: 'Google Business Profile event posts need a verified profile that has been verified for at least 60 days: until then, nothing is posted.',
        steps: [{ op: 'post.local_post', method: 'POST', path: '/v4/accounts/1/locations/2/localPosts', planned: false, ok: false, error: 'LIMIT_BLOCKED' }] },
      steps: [{ op: 'post.local_post', method: 'POST', path: '/v4/accounts/1/locations/2/localPosts', live: false, body: { topicType: 'EVENT' }, error: 'LIMIT_BLOCKED' }],
    },
  ],
};

beforeEach(() => { h.planArgs = []; h.ctxArgs = []; h.fail = false; h.ctxFail = false; });
afterEach(cleanup);

describe('PostListPanel', () => {
  it('lists every platform with its status, always a dry run, and its notes', async () => {
    render(<PostListPanel eventId={EV} orgId={ORG} />);
    await waitFor(() => expect(h.ctxArgs).toEqual([[ORG, EV]]));
    const ig = await screen.findByTestId('post-platform-instagram');
    await waitFor(() => expect(within(ig).getByText('Connected')).toBeTruthy());
    expect(within(ig).getByText('Dry run')).toBeTruthy();
    const tt = screen.getByTestId('post-platform-tiktok');
    expect(within(tt).getByText('Not connected')).toBeTruthy();
    expect(within(tt).getByText(/private \(only you\)/)).toBeTruthy();
    expect(within(tt).getByText(/Connect through the TikTok app: not available yet/)).toBeTruthy();
    const mu = screen.getByTestId('post-platform-meetup');
    expect(within(mu).getByText(/Meetup Pro network/)).toBeTruthy();
    expect(within(mu).getByText(/10 attendees per event/)).toBeTruthy();
    expect(within(screen.getByTestId('post-platform-linkedin')).getByText(/Needs a LinkedIn organization page/)).toBeTruthy();
    const gbp = screen.getByTestId('post-platform-google_business');
    expect(within(gbp).getByText(/verified 60\+ days ago/)).toBeTruthy();
    expect(within(gbp).getByText(/Uses your Google connection/)).toBeTruthy();
    expect(screen.getAllByText('Dry run')).toHaveLength(5);
  });

  it('plans the chosen platforms and shows each post, its warnings and the payloads; nothing sent', async () => {
    render(<PostListPanel eventId={EV} orgId={ORG} />);
    await screen.findByTestId('post-platform-tiktok');
    fireEvent.click(within(screen.getByTestId('post-platform-tiktok')).getByRole('checkbox'));
    fireEvent.click(screen.getByRole('button', { name: 'Plan the posts' }));
    await screen.findByTestId('post-plan');
    expect(h.planArgs).toEqual([[ORG, EV, ['instagram', 'meetup', 'linkedin', 'google_business']]]);
    expect(screen.getByText('Dry run: nothing was sent.')).toBeTruthy();
    const [ig, gbp] = screen.getAllByTestId('post-plan-platform');
    expect(within(ig).getByText('None (link in bio)')).toBeTruthy();
    expect(within(ig).getByText(/left out: Instagram captions/)).toBeTruthy();
    expect(within(ig).getByText('/v25.0/1784/media_publish')).toBeTruthy();
    expect(within(ig).getByText('Publish the post')).toBeTruthy();
    fireEvent.click(within(ig).getAllByRole('button', { name: 'Payload' })[1]);
    expect(within(ig).getByText(/planned_ig_container/)).toBeTruthy();
    expect(within(gbp).getByText(/Stopped: Google Business Profile event posts need/)).toBeTruthy();
    expect(within(gbp).getByText('(LIMIT_BLOCKED)')).toBeTruthy();
    expect(within(gbp).getByText('https://exos.example/e/post-night?utm_source=google_business')).toBeTruthy();
  });

  it('shows the error when planning is refused, and none of the platforms are planned without a choice', async () => {
    h.fail = true;
    render(<PostListPanel eventId={EV} orgId={ORG} />);
    await screen.findByTestId('post-platform-instagram');
    fireEvent.click(screen.getByRole('button', { name: 'Plan the posts' }));
    expect((await screen.findByRole('alert')).textContent).toContain('owners and managers only');
    expect(screen.queryByTestId('post-plan')).toBeNull();
    for (const p of ['instagram', 'tiktok', 'meetup', 'linkedin', 'google_business']) {
      fireEvent.click(within(screen.getByTestId(`post-platform-${p}`)).getByRole('checkbox'));
    }
    expect((screen.getByRole('button', { name: 'Plan the posts' }) as HTMLButtonElement).disabled).toBe(true);
  });

  it('says so when the context is refused', async () => {
    h.ctxFail = true;
    render(<PostListPanel eventId={EV} orgId={ORG} />);
    expect((await screen.findByRole('alert')).textContent).toContain('owners and managers only');
  });
});

describe('socialPlan helpers', () => {
  it('statuses and connect info', () => {
    expect(platformStatus(null, 'instagram')).toEqual({ word: 'not_connected', notes: [] });
    expect(platformStatus({ ...CTX, org: { ...CTX.org, venue_org: false } }, 'google_business').notes[0]).toContain('run their own venue');
    expect(platformStatus({ ...CTX, facts: { ...CTX.facts, meetup_plan: 'pro', meetup_pro_network: true } }, 'meetup').notes).toEqual([]);
    expect(connectInfo('instagram')).toEqual({ app: 'Meta (Facebook, Instagram)', built: false });
    expect(connectInfo('google_business').app).toBe('Google');
    expect(planSummary(PLAN.platforms[0])).toBe('2 requests planned; nothing sent.');
    expect(stepLabel('event.create_draft')).toBe('Create the event (draft)');
    expect(channelLabel('google_business')).toBe('Google Business Profile');
  });
});
