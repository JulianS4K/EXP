// Browser smoke tests for the buyer and promoter pages, against a mocked
// Supabase (tests/smoke/mock.mjs). Run with `npm run smoke` (builds the SPA
// pointed at the mock host, serves it, runs these). No real backend needed.
import { chromium, devices } from 'playwright';
import { readFileSync } from 'node:fs';
import { handle, EV, TIER2, ADDON, TOKEN, ORG, UID, TICKET, ORG_ROW, EVENT_ROW, ownerTables, tables as baseTables } from './mock.mjs';
const BASE = process.env.SMOKE_BASE || 'http://localhost:4174/bridge';
const IG = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 340.0.2.23.108 (iPhone15,2; iOS 17_5; en_US; en; scale=3.00; 1179x2556; 624443862)';
const browser = await chromium.launch();
const results = [];
async function run(name, fn, opts = {}) {
  const ctx = await browser.newContext({ ...devices[opts.device || 'iPhone 13'], ...(opts.ua ? { userAgent: opts.ua } : {}) });
  const log = []; const errors = [];
  // Third-party hosts (pixel vendors, fonts) never load: fast, offline, and a
  // test asserts on what the app injected, not on what a vendor did.
  await ctx.route((u) => !u.href.startsWith('http://localhost') && !u.href.startsWith('https://mock.supabase.test/'), (r) => r.abort());
  await ctx.route('https://mock.supabase.test/**', (r) => handle(r, log, opts.mock));
  // A visitor who already answered the cookie banner (declined), so it stays
  // out of the way; the consent tests start fresh.
  if (!opts.freshConsent) await ctx.addInitScript(() => {
    if (!localStorage.getItem('exos.consent.v2')) localStorage.setItem('exos.consent.v2', JSON.stringify({ analytics: 'denied', advertising: 'denied' }));
  });
  if (opts.gpc) await ctx.addInitScript(() => Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', { get: () => true, configurable: true }));
  // A stored, unexpired session: supabase-js reads it without a network call.
  if (opts.signedIn) await ctx.addInitScript((session) => {
    localStorage.setItem('sb-mock-auth-token', JSON.stringify(session));
  }, SESSION);
  const page = await ctx.newPage();
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource|401/.test(m.text())) errors.push('console: ' + m.text()); });
  try {
    await fn(page, log);
    results.push({ name, ok: errors.length === 0, errors });
  } catch (e) {
    results.push({ name, ok: false, errors: [String(e.message || e).split('\n')[0], ...errors], calls: log.slice(-6) });
    await page.screenshot({ path: 'tests/smoke/fail-' + name.replace(/\W+/g, '_') + '.png' }).catch(() => {});
  }
  await ctx.close();
}
const SESSION = {
  access_token: 'mock-access', refresh_token: 'mock-refresh', token_type: 'bearer', expires_in: 3600,
  expires_at: Math.floor(Date.now() / 1000) + 3600,
  user: { id: UID, aud: 'authenticated', role: 'authenticated',
    email: 'fan@example.com', email_confirmed_at: new Date().toISOString(), app_metadata: {}, user_metadata: {} },
};
const expectText = async (page, text, timeout = 8000) => page.getByText(text, { exact: false }).first().waitFor({ timeout });
const assert = (c, m) => { if (!c) throw new Error(m); };

await run('event page renders with directions', async (page) => {
  await page.goto(BASE + '/event/' + EV);
  await expectText(page, 'Fall Party');
  const dir = page.getByRole('link', { name: /directions/i });
  assert((await dir.getAttribute('href')).includes('google.com/maps/dir'), 'directions link');
});

await run('store page renders markdown safely, lineup, FAQ and good to know', async (page) => {
  await page.goto(BASE + '/event/' + EV);
  await expectText(page, 'Four rooms of house till late.');
  assert(await page.locator('strong', { hasText: 'Big' }).count() >= 1, 'markdown bold rendered');
  assert(await page.locator('a[href^="javascript:"]').count() === 0, 'no javascript: link');
  assert(await page.locator('img[src="x"]').count() === 0, 'raw HTML stays text');
  assert(!(await page.evaluate(() => window.__xss)), 'no script ran');
  await expectText(page, '23:30');
  await page.getByText('Is there a coat check?').click();
  await expectText(page, 'Yes, $3.');
  await expectText(page, 'Ages 21+');
  await expectText(page, 'Refunds available up to 7 days before the event.');
});

await run('checkout link pre-fills tier, quantity and add-on; survives reload', async (page, log) => {
  await page.goto(BASE + '/checkout?products=' + TIER2 + ':3,' + ADDON + ':2&promoter=dj-kay&utm_source=instagram');
  await page.waitForURL(/\/event\//, { timeout: 8000 });
  assert(page.url().includes('promoter=dj-kay'), 'attribution carried to the event URL');
  await expectText(page, 'Fall Party');
  const check = async (label) => {
    await page.waitForTimeout(800);
    const body = await page.locator('body').innerText();
    // VIP ($50) x 3 = $150; the default tier (GA $20) x 3 would be $60.
    assert(/\$150/.test(body), label + ': total is VIP x 3 ($150), page shows ' + (body.match(/\$\d+(\.\d+)?/g) || []).join(','));
    const posterRow = page.locator('div.border-2', { hasText: 'Poster' }).first();
    assert(/\b2\b/.test(await posterRow.innerText()), label + ': add-on quantity 2');
  };
  await check('first load');
  await page.reload();
  await expectText(page, 'Fall Party');
  await check('after reload');
});

await run('bad checkout link explains itself', async (page) => {
  await page.goto(BASE + '/checkout?products=junk');
  await expectText(page, 'no tickets in it');
});

await run('signed-out code entry asks for sign-in first', async (page, log) => {
  await page.goto(BASE + '/event/' + EV);
  await expectText(page, 'Fall Party');
  const voucher = page.getByPlaceholder(/voucher|code/i).first();
  await voucher.fill('PRESALE');
  await page.getByRole('button', { name: /sign in to apply/i }).click();
  await expectText(page, 'code');
  await page.getByRole('dialog').first().waitFor({ timeout: 8000 });
  assert(!log.some((l) => l.includes('exos_check_voucher')), 'no code check while signed out');
});

await run('voucher reveals the hidden tier', async (page, log) => {
  await page.goto(BASE + '/event/' + EV);
  await expectText(page, 'Fall Party');
  const voucher = page.getByPlaceholder(/voucher|code/i).first();
  await voucher.fill('PRESALE');
  await voucher.press('Enter');
  // The tier fetch starts after the voucher check resolves, and "Presale" can
  // appear from the check's own message first, so wait for the fetch itself.
  for (let i = 0; i < 50 && !log.some((l) => l.includes('exos_voucher_tier')); i++) await page.waitForTimeout(100);
  assert(log.some((l) => l.includes('exos_voucher_tier')), 'called exos_voucher_tier');
  await expectText(page, 'Presale');
}, { signedIn: true });

await run('promoter link in bio lists events with the code', async (page) => {
  await page.goto(BASE + '/l/bk-nights/dj-kay');
  await expectText(page, 'DJ Kay');
  const link = page.getByRole('link', { name: /Fall Party/ });
  const href = await link.getAttribute('href');
  assert(href.includes('promoter=dj-kay') && href.includes('utm_medium=bio'), 'event link carries code: ' + href);
});

await run('inactive bio link', async (page) => {
  await page.goto(BASE + '/l/bk-nights/nobody');
  await expectText(page, "isn't active");
});

await run('promoter portal shows sales, bio link and kit', async (page) => {
  await page.goto(BASE + '/p/' + TOKEN);
  await expectText(page, '7 sold');
  await expectText(page, '/l/bk-nights/dj-kay');
  await page.getByRole('button', { name: /Fall Party/ }).click();
  await expectText(page, 'Buy-now link');
  const body = await page.locator('body').innerText();
  assert(body.includes('/checkout?event=') && body.includes('promoter=dj-kay'), 'buy-now link built');
});

await run('fan share tags the organizer and the promoter', async (page) => {
  await page.goto(BASE + '/event/' + EV + '?promoter=dj-kay');
  await expectText(page, 'Fall Party');
  await page.getByRole('button', { name: /share link/i }).click();
  await expectText(page, 'Tags @bknights @dj.kay');
  const x = await page.getByRole('link', { name: /X \/ Twitter/ }).getAttribute('href');
  const text = decodeURIComponent(x);
  assert(text.includes('with @bknights') && !text.includes('@dj.kay'), 'X text uses X handles only: ' + text);
  const fb = await page.getByRole('link', { name: /Facebook/ }).getAttribute('href');
  assert(!decodeURIComponent(fb).includes('@'), 'Facebook gets no mentions');
});

await run('promoter sets their handles and tagging switch', async (page, log) => {
  await page.goto(BASE + '/p/' + TOKEN);
  await expectText(page, 'Get tagged');
  await page.getByLabel('X handle').fill('x.com/djkay');
  await page.getByLabel('Tag me in shares').uncheck();
  await page.getByRole('button', { name: /^Save$/ }).click();
  await expectText(page, "Shares won't tag you");
  assert(log.some((l) => l.includes('exos_promoter_set_socials')), 'saved through the kit token');
});

await run('events map falls back to a list without a key', async (page) => {
  await page.goto(BASE + '/map');
  await expectText(page, 'Fall Party');
});

await run('Instagram in-app banner', async (page) => {
  await page.goto(BASE + '/event/' + EV);
  await expectText(page, 'You can buy right here in Instagram');
}, { ua: IG });

// ── This week's screens: consent, marketing settings, sources, money, payouts, wallet ──

const waitFor = async (cond, what, ms = 5000) => {
  for (let i = 0; i < ms / 100 && !(await cond()); i++) await new Promise((r) => setTimeout(r, 100));
  assert(await cond(), 'timed out waiting for ' + what);
};
const seen = (log, needle) => () => log.some((l) => l.includes(needle));
// Download a file the page saves (Blob + <a download>), as text without the BOM.
async function download(page, click) {
  const [dl] = await Promise.all([page.waitForEvent('download', { timeout: 8000 }), click()]);
  return { name: dl.suggestedFilename(), text: readFileSync(await dl.path(), 'utf8').replace(/^﻿/, '') };
}
const firstLines = (text) => text.split(/\r\n/);

// Consent: the org has one analytics and one advertising pixel.
const PIXELS = { meta: '123456789012345', ga4: 'G-ABC123XYZ9' };
const pixelOrg = { tables: { exos_public_orgs: [{ ...baseTables.exos_public_orgs[0], marketing: { pixels: PIXELS } }] } };
const VENDOR_SRC = /fbevents|googletagmanager|analytics\.tiktok|redditstatic|sc-static|ads-twitter/;
const scriptSrcs = (page) => page.evaluate(() => [...document.querySelectorAll('script[src]')].map((s) => s.src));
const banner = (page) => page.getByRole('dialog').filter({ hasText: 'analytics and advertising cookies' });
async function openEventWithBanner(page, log) {
  await page.goto(BASE + '/event/' + EV);
  await expectText(page, 'Fall Party');
  await banner(page).waitFor({ timeout: 8000 });
  // The org read is what registers the pixels: after it, anything consent allows has loaded.
  await waitFor(seen(log, 'exos_public_orgs'), 'the org read');
  await page.waitForTimeout(200);
}

await run('consent: first visit asks, Reject all injects no pixel', async (page, log) => {
  await openEventWithBanner(page, log);
  assert(!(await scriptSrcs(page)).some((s) => VENDOR_SRC.test(s)), 'nothing loads before a choice');
  await banner(page).getByRole('button', { name: 'Reject all' }).click();
  await banner(page).waitFor({ state: 'hidden' });
  await page.waitForTimeout(300);
  const srcs = await scriptSrcs(page);
  assert(!srcs.some((s) => VENDOR_SRC.test(s)), 'no vendor script after Reject all: ' + srcs.join(' '));
  assert(await page.evaluate(() => !window.fbq && !window.gtag && !window.ttq), 'no pixel globals');
  await page.reload();
  await expectText(page, 'Fall Party');
  await page.waitForTimeout(500);
  assert(await banner(page).count() === 0, 'the choice sticks across reloads');
}, { freshConsent: true, mock: pixelOrg });

await run('consent: Choose analytics only loads GA4 and not Meta; Cookie settings reopens', async (page, log) => {
  await openEventWithBanner(page, log);
  await banner(page).getByRole('button', { name: 'Choose' }).click();
  await banner(page).getByRole('checkbox', { name: /Analytics/ }).check();
  assert(!(await banner(page).getByRole('checkbox', { name: /Advertising/ }).isChecked()), 'advertising starts off');
  await banner(page).getByRole('button', { name: 'Save choices' }).click();
  await banner(page).waitFor({ state: 'hidden' });
  await waitFor(async () => (await scriptSrcs(page)).some((s) => s.includes('googletagmanager.com/gtag/js?id=G-ABC123XYZ9')), 'gtag.js injected');
  const srcs = await scriptSrcs(page);
  assert(!srcs.some((s) => /fbevents|tiktok|redditstatic|sc-static|ads-twitter/.test(s)), 'no advertising script: ' + srcs.join(' '));
  assert(await page.evaluate(() => typeof window.gtag === 'function' && !window.fbq), 'gtag only');
  const consent = await page.evaluate(() => (window.dataLayer || []).map((a) => Array.from(a)).filter((a) => a[0] === 'consent' && a[1] === 'update').pop()?.[2]);
  assert(consent?.analytics_storage === 'granted' && consent?.ad_storage === 'denied', 'Consent Mode update: ' + JSON.stringify(consent));
  // The footer link reopens the banner on the toggles, showing the saved choice.
  await page.getByRole('button', { name: 'Cookie settings' }).click();
  await banner(page).getByRole('button', { name: 'Save choices' }).waitFor({ timeout: 5000 });
  assert(await banner(page).getByRole('checkbox', { name: /Analytics/ }).isChecked(), 'analytics shows as on');
  assert(!(await banner(page).getByRole('checkbox', { name: /Advertising/ }).isChecked()), 'advertising shows as off');
}, { freshConsent: true, mock: pixelOrg });

await run('consent: Global Privacy Control pre-denies advertising', async (page, log) => {
  await openEventWithBanner(page, log);
  await expectText(page, 'Your browser sends Global Privacy Control');
  assert(await page.evaluate(() => navigator.globalPrivacyControl === true), 'GPC set');
  await banner(page).getByRole('button', { name: 'Choose' }).click();
  assert(!(await banner(page).getByRole('checkbox', { name: /Advertising/ }).isChecked()), 'advertising off under GPC');
  await banner(page).getByRole('checkbox', { name: /Analytics/ }).check();
  await banner(page).getByRole('button', { name: 'Save choices' }).click();
  await waitFor(async () => (await scriptSrcs(page)).some((s) => s.includes('googletagmanager.com/gtag/js')), 'gtag.js injected');
  assert(!(await scriptSrcs(page)).some((s) => s.includes('fbevents')), 'Meta stays off');
  const stored = await page.evaluate(() => JSON.parse(localStorage.getItem('exos.consent.v2') || '{}'));
  assert(stored.analytics === 'granted' && stored.advertising === 'denied', 'stored choice: ' + JSON.stringify(stored));
}, { freshConsent: true, gpc: true, mock: pixelOrg });

// Org settings, signed in as the org owner.
const HASH = (c) => c.repeat(64);
const AD_CREDS = [{
  platform: 'meta', config: { pixel_id: '123456789012345' }, has_secret: true, enabled: true, test_event_code: null,
  updated_at: '2026-09-29T10:00:00Z', sent_30d: 12, skipped_30d: 1, failed_30d: 0, pending: 2, last_sent_at: null,
}];
const ownerMock = (extra = {}) => ({
  tables: { ...ownerTables, ...(extra.tables || {}) },
  rpcs: {
    exos_list_ad_credentials: (b) => (b.p_org_id === ORG ? AD_CREDS : { __status: 403, __body: { code: '42501', message: 'owners and managers only' } }),
    exos_set_ad_credential: () => ({}),
    // The rest of the org pages' reads, empty.
    exos_list_api_keys: () => [], exos_org_comp_usage: () => 0,
    exos_event_analytics: () => ({}), exos_waitlist_summary: () => [{ waiting: 0, notified: 0, offered: 0, converted: 0, total_quantity: 0 }],
    exos_get_referral_reward_rule: () => ({}), exos_referral_leaderboard: () => [],
    exos_org_audience_export: (b) => (b.p_org_id === ORG ? {
      count: 2, generated_at: '2026-09-30T12:00:00Z',
      rows: [
        { email_sha256: HASH('a'), phone_sha256: HASH('b'), phone_digits_sha256: HASH('c') },
        { email_sha256: HASH('d'), phone_sha256: null, phone_digits_sha256: null },
      ],
    } : null),
    ...(extra.rpcs || {}),
  },
  fns: extra.fns,
});
const settingsCard = (page, heading) => page.locator('div.rounded-2xl').filter({ has: page.getByRole('heading', { name: heading }) }).last();

await run('org settings: a bad Meta pixel id blocks save', async (page, log) => {
  await page.goto(BASE + '/orgs/' + ORG + '/settings');
  await expectText(page, 'Marketing & socials');
  const meta = page.getByLabel('Meta Pixel');
  await meta.fill('12ab');
  await expectText(page, 'Should look like 123456789012345');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expectText(page, 'Fix the pixel ids marked in red');
  assert(!log.some((l) => l.startsWith('PATCH exos_orgs')), 'nothing saved with a bad id');
  await meta.fill('123456789012345');
  assert(await page.getByText('Should look like 123456789012345').count() === 0, 'error clears');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expectText(page, 'Saved.');
  const patch = log.find((l) => l.startsWith('PATCH exos_orgs'));
  assert(patch && patch.includes('"meta":"123456789012345"'), 'saved the pixel: ' + patch);
}, { signedIn: true, mock: ownerMock() });

await run('org settings: Ads & conversions lists six platforms with write-only tokens', async (page, log) => {
  await page.goto(BASE + '/orgs/' + ORG + '/settings');
  const card = settingsCard(page, 'Ads & conversions');
  await card.waitFor({ timeout: 8000 });
  await waitFor(seen(log, 'exos_list_ad_credentials'), 'credentials read');
  for (const label of ['Meta (Facebook / Instagram)', 'TikTok', 'Google Analytics 4', 'Google Ads', 'Reddit', 'Snapchat']) {
    await card.getByRole('button', { name: new RegExp('^' + label.replace(/[()/]/g, '\\$&')) }).waitFor({ timeout: 5000 });
  }
  await card.getByRole('button', { name: /^Meta/ }).click();
  await card.getByText('Last 30 days: 12 sent, 2 waiting, 1 skipped, 0 failed').waitFor({ timeout: 5000 });
  const token = card.locator('input[type=password]');
  assert(await token.count() === 1, 'one token field');
  assert(await token.inputValue() === '' && (await token.getAttribute('placeholder')) === '•••• saved', 'saved token is never shown');
  assert(await card.getByLabel('Pixel (dataset) ID').inputValue() === '123456789012345', 'ids are shown');
  // Saving without touching the token keeps it (p_secret null).
  await card.getByRole('button', { name: /^Save$/ }).click();
  await expectText(page, 'Meta (Facebook / Instagram) saved.');
  const save = log.find((l) => l.startsWith('rpc exos_set_ad_credential'));
  assert(save && save.includes('"p_secret":null') && save.includes('"p_platform":"meta"'), 'blank token keeps the saved one: ' + save);
  await card.getByRole('button', { name: /^TikTok/ }).click();
  assert((await card.locator('input[type=password]').getAttribute('placeholder')) === 'Paste the token', 'unsaved platform asks for a token');
}, { signedIn: true, mock: ownerMock() });

await run('org settings: catalog feed URLs and hashed audience CSV', async (page, log) => {
  await page.goto(BASE + '/orgs/' + ORG + '/settings');
  await settingsCard(page, 'Catalog feed').waitFor({ timeout: 8000 });
  const feed = 'https://mock.supabase.test/functions/v1/exos-catalog-feed/bk-nights';
  assert(await page.getByLabel('Meta Commerce Manager (CSV) feed URL').inputValue() === feed + '.csv?format=meta', 'Meta feed URL');
  assert(await page.getByLabel('TikTok Catalog Manager (CSV) feed URL').inputValue() === feed + '.csv?format=tiktok', 'TikTok feed URL');
  assert(await page.getByLabel('Google Merchant Center (XML) feed URL').inputValue() === feed + '.xml?format=google', 'Google feed URL');
  const card = settingsCard(page, 'Audience export');
  const { name, text } = await download(page, () => card.getByRole('button', { name: 'Download CSV' }).click());
  const lines = firstLines(text);
  assert(lines[0] === 'email,phone', 'Meta header row: ' + lines[0]);
  assert(lines[1] === `${HASH('a')},${HASH('c')}`, 'Meta phone is the digits-only hash');
  assert(lines[2] === `${HASH('d')},`, 'no phone, empty cell');
  assert(/^bk-nights-meta-audience-\d{4}-\d{2}-\d{2}\.csv$/.test(name), 'file name ' + name);
  assert(log.some((l) => l.includes('rpc exos_org_audience_export') && l.includes('"p_event_id":null')), 'org-wide export');
  await expectText(page, 'Exported 2 people.');
}, { signedIn: true, mock: ownerMock() });

// Event report: sources and money.
const SESSIONS = [
  { session_id: 'cs_1', event_id: EV, status: 'fulfilled', quantity: 2, amount_cents: 4000, currency: 'usd', promoter_id: null,
    attribution: { utm_source: 'Instagram', utm_medium: 'paid', utm_campaign: 'fall' }, ad_ids: { fbclid: 'IwAR1', fbp: 'fb.1.2.3' } },
  { session_id: 'cs_2', event_id: EV, status: 'fulfilled', quantity: 1, amount_cents: 2000, currency: 'usd', promoter_id: null,
    attribution: {}, ad_ids: { ttclid: 'E.C.P.x1' } },
  { session_id: 'cs_3', event_id: EV, status: 'refunded', quantity: 1, amount_cents: 2000, currency: 'usd', promoter_id: 'dj-kay',
    attribution: null, ad_ids: null },
  { session_id: 'cs_4', event_id: EV, status: 'fulfilled', quantity: 1, amount_cents: 2000, currency: 'usd', promoter_id: null,
    attribution: null, ad_ids: null },
];
const money = (id, gross, refunded, extra = {}) => ({
  session_id: id, org_id: ORG, event_id: EV, status: refunded ? 'refunded' : 'fulfilled', currency: 'usd',
  created_at: '2026-09-20T12:00:00Z', fulfilled_at: '2026-09-20T12:01:00Z', gross_cents: gross, tax_cents: 0,
  application_fee_cents: Math.round(gross * 0.08), exos_fee_cents: Math.round(gross * 0.05), card_fee_est_cents: Math.round(gross * 0.03),
  card_fee_actual_cents: null, fee_bps: 500, fee_free: false, organizer_net_cents: gross - Math.round(gross * 0.08), platform_net_cents: null,
  refunded_cents: refunded, payment_intent: 'pi_' + id, transfer_id: null, balance_txn_id: null, ...extra,
});
const reportMock = ownerMock({ tables: {
  exos_tickets: [], exos_discount_codes: [],
  exos_checkout_sessions: SESSIONS,
  exos_order_money: [money('cs_1', 4000, 0), money('cs_2', 2000, 0), money('cs_3', 2000, 2000), money('cs_4', 2000, 0)],
  exos_marketplace_order_money: [], exos_promoter_commissions: [],
} });

await run('event report: Sources by UTM, promoter and ad platform, with CSV', async (page, log) => {
  await page.goto(BASE + '/dashboard/event/' + EV + '?tab=marketing');
  await page.getByRole('heading', { name: 'Sources' }).waitFor({ timeout: 8000 });
  await expectText(page, 'instagram / paid · fall · Meta');
  await expectText(page, 'TikTok');
  await expectText(page, 'promoter dj-kay');
  await expectText(page, 'Direct / unknown');
  await expectText(page, '3 of 4 orders have a source.');
  assert(log.some((l) => l.startsWith('GET exos_checkout_sessions') && l.includes('ad_ids')), 'reads ad_ids');
  assert(await page.getByText('Ad click ids aren’t recorded').count() === 0, 'no old-schema note');
  const { text } = await download(page, () => page.getByRole('button', { name: /Sources CSV/ }).click());
  const lines = firstLines(text);
  assert(lines[0] === 'utm_source,utm_medium,utm_campaign,promoter,ad_platform,orders,tickets,gross,refunded_orders,currency', 'header ' + lines[0]);
  assert(lines.includes('instagram,paid,fall,,Meta,1,2,40.00,0,USD'), 'Instagram row: ' + lines.join(' | '));
  assert(lines.includes(',,,dj-kay,,1,1,20.00,1,USD'), 'promoter row (refunded): ' + lines.join(' | '));
}, { signedIn: true, mock: reportMock });

await run('event report: Money summary from the order money view', async (page, log) => {
  await page.goto(BASE + '/dashboard/event/' + EV);
  const section = page.locator('section', { has: page.getByRole('heading', { name: 'Money' }) });
  await section.waitFor({ timeout: 8000 });
  const text = await section.innerText();
  assert(text.includes('$100.00'), 'gross $100: ' + text.replace(/\s+/g, ' '));
  assert(/Refunds\s*\$20\.00/i.test(text), 'refunds $20');
  assert(/Your net after refunds\s*\$73\.60/i.test(text), 'net after refunds (fees come back in proportion)');
  assert(/Tickets sold\s*5\s*4 orders/i.test(text), 'tickets from checkout quantities: ' + text.replace(/\s+/g, ' '));
  const read = log.find((l) => l.startsWith('GET exos_order_money'));
  assert(read && read.includes('organizer_net_cents') && read.includes('card_fee_actual_cents'), 'money columns: ' + read);
  const { text: csv } = await download(page, () => section.getByRole('button', { name: /Orders CSV/ }).click());
  assert(firstLines(csv)[0].startsWith('source,order_id,status,created_at,currency,tickets,gross'), 'orders CSV header');
  assert(firstLines(csv).length >= 5, 'one row per order');
}, { signedIn: true, mock: reportMock });

await run('payouts page lists payouts and their lines', async (page) => {
  await page.goto(BASE + '/orgs/' + ORG + '/payouts');
  await page.getByRole('heading', { name: 'Payouts' }).waitFor({ timeout: 8000 });
  await expectText(page, '$120.00');
  await expectText(page, 'Account not ready');
  await expectText(page, '1 order, 1 clawback');
  await page.getByRole('button', { name: /\$120\.00/ }).click();
  await expectText(page, 'SH-991');
  await expectText(page, 'Stripe transfer tr_123');
  const table = await page.locator('table').innerText();
  assert(table.includes('Fall Party') && table.includes('clawback') && table.includes('-$30.00'), 'lines: ' + table.replace(/\s+/g, ' '));
  const { text } = await download(page, () => page.getByRole('button', { name: /Export CSV/ }).click());
  assert(firstLines(text)[0].startsWith('payout_id,payout_status'), 'payouts CSV header');
}, { signedIn: true, mock: ownerMock({ tables: {
  exos_org_payouts: [
    { id: 'po_1', org_id: ORG, currency: 'USD', amount: 120, status: 'sent', stripe_transfer_id: 'tr_123', error: null,
      created_at: '2026-09-25T12:00:00Z', updated_at: '2026-09-25T12:00:00Z', sent_at: '2026-09-25T12:05:00Z' },
    { id: 'po_2', org_id: ORG, currency: 'USD', amount: 30, status: 'failed', stripe_transfer_id: null, error: 'Account not ready',
      created_at: '2026-09-20T12:00:00Z', updated_at: '2026-09-20T12:00:00Z', sent_at: null },
  ],
  exos_org_payout_lines: [
    { id: 'pl_1', payout_id: 'po_1', org_id: ORG, order_id: '88888888-8888-4888-8888-888888888881', kind: 'sale', amount: 150, created_at: '2026-09-25T12:00:00Z',
      order: { channel: 'stubhub', external_order_id: 'SH-991', event_id: EV, event: { name: 'Fall Party' } } },
    { id: 'pl_2', payout_id: 'po_1', org_id: ORG, order_id: '88888888-8888-4888-8888-888888888882', kind: 'clawback', amount: -30, created_at: '2026-09-25T12:00:01Z',
      order: { channel: 'seatgeek', external_order_id: 'SG-12', event_id: EV, event: { name: 'Fall Party' } } },
  ],
} }) });

// Wallet buttons on My Tickets.
const walletMock = (status) => ownerMock({
  tables: {
    exos_tickets: [{
      id: TICKET, event_id: EV, org_id: ORG, tier_id: null, tier_name: 'GA', buyer_id: UID, owner_id: UID, status: 'active',
      price_paid: 20, order_ref: null, channel_source: 'direct', promoter_id: null, pending_transfer_id: null, transfer_id: null,
      voided_at: null, voided_by: null, voided_reason: null, released_at: null, check_in_at: null, last_reissue_at: null,
      created_at: '2026-09-20T12:00:00Z', updated_at: '2026-09-20T12:00:00Z', attendee_name: null, event: EVENT_ROW,
    }],
    exos_ticket_barcode_secrets: [{ ticket_id: TICKET, barcode_secret: 'c2VjcmV0' }],
    exos_transfers: [], exos_event_saves: [],
  },
  rpcs: { exos_my_reschedule_offers: () => [] },
  fns: { 'exos-wallet/pass': () => ({ status, body: status === 503 ? { error: 'wallet not configured' } : { error: 'not your ticket' } }) },
});

await run('wallet buttons stay hidden when exos-wallet is not configured (503)', async (page, log) => {
  await page.goto(BASE + '/my-tickets');
  await expectText(page, 'Fall Party');
  await waitFor(seen(log, 'fn exos-wallet/pass'), 'the wallet probe');
  await page.waitForTimeout(300);
  assert(await page.getByRole('button', { name: /Add to (Apple|Google) Wallet/ }).count() === 0, 'no wallet button');
  assert(await page.evaluate(() => sessionStorage.getItem('exos.wallet.availability')) === '{"apple":false}', 'probe answer cached');
}, { signedIn: true, mock: walletMock(503) });

await run('wallet buttons show on an owned active ticket when the probe gets 403', async (page, log) => {
  await page.goto(BASE + '/my-tickets');
  await expectText(page, 'Fall Party');
  await page.getByRole('button', { name: 'Add to Apple Wallet' }).waitFor({ timeout: 8000 });
  assert(await page.getByRole('button', { name: 'Add to Google Wallet' }).count() === 0, 'iPhone gets Apple only');
  const probe = log.find((l) => l.startsWith('fn exos-wallet/pass'));
  assert(probe.includes('00000000-0000-0000-0000-000000000000') && !probe.includes(TICKET), 'the probe asks for the nil ticket: ' + probe);
}, { signedIn: true, mock: walletMock(403) });

// Receipts, invoices and credit notes (mig 20261001100000).
const INV_ID = '99999999-9999-4999-8999-999999999991';
const CN_ID = '99999999-9999-4999-8999-999999999992';
const CN = { id: CN_ID, number: 'CN-000001', amount_cents: 3333, tax_cents: 303, currency: 'usd', reason: 'requested_by_customer', created_at: '2026-09-25T12:00:00Z' };
const INVOICE_DOC = {
  invoice: { id: INV_ID, number: 'INV-000001', issued_at: '2026-09-20T12:00:00Z', currency: 'usd',
    subtotal_cents: 10000, tax_cents: 1000, total_cents: 11000, status: 'issued', session_id: 'cs_1' },
  seller: { name: 'Brooklyn Nights', legal_name: 'BK Nights LLC', legal_address: '1 Main St\nBrooklyn, NY 11201',
    tax_id: 'EIN 12-3456789', invoice_footer: 'Thanks for coming.' },
  buyer: { name: null, email: 'fan@example.com' },
  event: { id: EV, name: 'Fall Party', starts_at: EVENT_ROW.starts_at, timezone: 'America/New_York', venue_name: 'Elsewhere' },
  order: { session_id: 'cs_1', paid_at: '2026-09-20T12:00:00Z', quantity: 2 },
  lines: [
    { kind: 'ticket', name: 'GA', quantity: 2, unit_cents: 5000, total_cents: 10000, tax_cents: 1000, tax_included: true, tax_name: 'Sales tax 10%', tax_rate: 10 },
    { kind: 'addon', name: 'Poster', quantity: 1, unit_cents: 1000, total_cents: 1000, tax_cents: 0, tax_included: false, tax_name: null, tax_rate: null },
  ],
  credit_notes: [CN],
  viewer: 'buyer',
};
const invoiceMock = ownerMock({ rpcs: {
  exos_invoice_document: (b) => (b.p_invoice_id === INV_ID ? INVOICE_DOC : { __status: 403, __body: { code: '42501', message: 'exos_invoice_document: not found' } }),
  exos_credit_note_document: (b) => (b.p_credit_note_id === CN_ID ? { ...INVOICE_DOC, credit_note: CN } : { __status: 403, __body: { code: '42501', message: 'not found' } }),
} });

await run('receipt page: seller, lines, tax per rate, credit notes, print', async (page, log) => {
  await page.goto(BASE + '/invoice/' + INV_ID);
  await page.getByRole('heading', { name: 'Receipt' }).waitFor({ timeout: 8000 });
  const doc = page.locator('article');
  const text = (await doc.innerText()).replace(/\s+/g, ' ');
  for (const t of ['INV-000001', 'BK Nights LLC', 'trading as Brooklyn Nights', 'Brooklyn, NY 11201', 'Tax ID: EIN 12-3456789',
    'fan@example.com', 'Fall Party', 'GA', 'Poster', 'Sales tax 10%', '$110.00', 'CN-000001', '−$33.33', '$76.67', 'Thanks for coming.']) {
    assert(text.includes(t), 'receipt shows ' + t + ': ' + text);
  }
  assert(/Subtotal \(excl\. tax\)\s*\$100\.00/.test(text), 'subtotal excl. tax');
  assert(await page.locator('nav').count() === 0, 'bare layout: no navbar');
  assert(await page.getByRole('button', { name: /Print/ }).isVisible(), 'print button');
  assert(await page.title() === 'receipt-INV-000001', 'print file name: ' + await page.title());
  await page.emulateMedia({ media: 'print' });
  assert(!(await page.getByRole('button', { name: /Print/ }).isVisible()), 'print hides the buttons');
  await page.emulateMedia({ media: 'screen' });
  assert(log.some((l) => l.startsWith('rpc exos_invoice_document') && l.includes(INV_ID)), 'reads the document RPC');
  await doc.getByRole('link', { name: 'CN-000001' }).click();
  await page.getByRole('heading', { name: 'Credit note' }).waitFor({ timeout: 8000 });
  const cn = (await page.locator('article').innerText()).replace(/\s+/g, ' ');
  assert(cn.includes('Refund on invoice INV-000001') && cn.includes('−$3.03') && cn.includes('requested by customer'), 'credit note: ' + cn);
}, { signedIn: true, mock: invoiceMock });

await run('receipt page: someone else\'s receipt says not found', async (page) => {
  await page.goto(BASE + '/invoice/99999999-9999-4999-8999-999999999999');
  await page.getByRole('heading', { name: 'Not found' }).waitFor({ timeout: 8000 });
}, { signedIn: true, mock: invoiceMock });

await run('my tickets: Receipt link per order', async (page) => {
  await page.goto(BASE + '/my-tickets');
  await expectText(page, 'Fall Party');
  await page.getByRole('button', { name: 'RECEIPTS' }).click();
  await expectText(page, 'INV-000001 · $110.00 · $33.33 refunded');
  await page.getByRole('link', { name: 'RECEIPT', exact: true }).click();
  await page.waitForURL(/\/invoice\//, { timeout: 8000 });
  await page.getByRole('heading', { name: 'Receipt' }).waitFor({ timeout: 8000 });
}, { signedIn: true, mock: ownerMock({
  tables: {
    exos_tickets: [{
      id: TICKET, event_id: EV, org_id: ORG, tier_id: null, tier_name: 'GA', buyer_id: UID, owner_id: UID, status: 'active',
      price_paid: 50, order_ref: 'cs_1', channel_source: 'direct', promoter_id: null, pending_transfer_id: null, transfer_id: null,
      voided_at: null, voided_by: null, voided_reason: null, released_at: null, check_in_at: null, last_reissue_at: null,
      created_at: '2026-09-20T12:00:00Z', updated_at: '2026-09-20T12:00:00Z', attendee_name: null, event: EVENT_ROW,
    }],
    exos_ticket_barcode_secrets: [], exos_transfers: [], exos_event_saves: [],
  },
  rpcs: {
    exos_my_reschedule_offers: () => [],
    exos_my_invoices: () => [{ id: INV_ID, number: 'INV-000001', session_id: 'cs_1', event_id: EV, total_cents: 11000,
      currency: 'usd', issued_at: '2026-09-20T12:00:00Z', refunded_cents: 3333 }],
    exos_invoice_document: () => INVOICE_DOC,
  },
  fns: { 'exos-wallet/pass': () => ({ status: 503, body: { error: 'wallet not configured' } }) },
}) });

await run('event report: Money lists receipts and the CSV has invoice numbers', async (page, log) => {
  await page.goto(BASE + '/dashboard/event/' + EV);
  const section = page.locator('section', { has: page.getByRole('heading', { name: 'Money' }) });
  await section.waitFor({ timeout: 8000 });
  await section.getByText('Receipts (2)').click();
  const link = section.getByRole('link', { name: 'INV-000001' });
  assert((await link.getAttribute('href')).endsWith('/invoice/' + INV_ID), 'links to the receipt');
  assert(log.some((l) => l.startsWith('GET exos_invoice_totals') && l.includes('refunded_cents')), 'reads exos_invoice_totals');
  const { text } = await download(page, () => section.getByRole('button', { name: /Orders CSV/ }).click());
  const lines = firstLines(text);
  assert(lines[0].endsWith(',invoice_number'), 'CSV header: ' + lines[0]);
  assert(lines.some((l) => l.startsWith('exos,cs_1,') && l.endsWith(',INV-000001')), 'cs_1 has its invoice number');
  assert(lines.some((l) => l.startsWith('exos,cs_2,') && l.endsWith(',INV-000002')), 'cs_2 has its invoice number');
}, { signedIn: true, mock: { ...reportMock, tables: { ...reportMock.tables, exos_invoice_totals: [
  { id: INV_ID, org_id: ORG, event_id: EV, number: 'INV-000001', session_id: 'cs_1', total_cents: 4000, currency: 'usd',
    issued_at: '2026-09-20T12:00:00Z', refunded_cents: 0 },
  { id: '99999999-9999-4999-8999-999999999993', org_id: ORG, event_id: EV, number: 'INV-000002', session_id: 'cs_2',
    total_cents: 2000, currency: 'usd', issued_at: '2026-09-20T12:00:00Z', refunded_cents: 0 },
] } } });

await run('org settings: Legal & invoices saves the seller details', async (page, log) => {
  await page.goto(BASE + '/orgs/' + ORG + '/settings');
  const card = settingsCard(page, 'Legal & invoices');
  await card.waitFor({ timeout: 8000 });
  await waitFor(seen(log, 'GET exos_org_legal'), 'legal details read');
  assert(await card.getByLabel('Tax ID (EIN, VAT or sales-tax number)').inputValue() === 'EIN 12-3456789', 'shows the saved tax id');
  await card.getByLabel('Legal name').fill('BK Nights Holdings LLC');
  await card.getByLabel('Receipt footer').fill('x'.repeat(501));
  await expectText(page, 'At most 500 characters');
  await card.getByRole('button', { name: 'Save legal details' }).click();
  await expectText(page, 'Shorten the fields marked in red.');
  assert(!log.some((l) => l.startsWith('POST exos_org_legal')), 'nothing saved while too long');
  await card.getByLabel('Receipt footer').fill('Thanks!');
  await card.getByRole('button', { name: 'Save legal details' }).click();
  await expectText(page, 'Legal details saved.');
  const post = log.find((l) => l.startsWith('POST exos_org_legal'));
  assert(post && post.includes('on_conflict=org_id') && post.includes('"legal_name":"BK Nights Holdings LLC"')
    && post.includes('"invoice_footer":"Thanks!"') && post.includes('"tax_id":"EIN 12-3456789"'), 'upsert: ' + post);
}, { signedIn: true, mock: ownerMock({ tables: { exos_org_legal: [
  { org_id: ORG, legal_name: 'BK Nights LLC', legal_address: '1 Main St', tax_id: 'EIN 12-3456789', invoice_footer: null, updated_at: '2026-09-30T12:00:00Z' },
] } }) });

await browser.close();
for (const r of results) console.log((r.ok ? 'PASS ' : 'FAIL ') + r.name + (r.errors.length ? '\n   ' + r.errors.join('\n   ') : '') + (r.calls ? '\n   calls: ' + r.calls.join(' | ') : ''));

if (results.some((r) => !r.ok)) process.exit(1);
