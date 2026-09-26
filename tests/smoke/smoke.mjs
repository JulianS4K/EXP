// Browser smoke tests for the buyer and promoter pages, against a mocked
// Supabase (tests/smoke/mock.mjs). Run with `npm run smoke` (builds the SPA
// pointed at the mock host, serves it, runs these). No real backend needed.
import { chromium, devices } from 'playwright';
import { handle, EV, TIER2, ADDON, TOKEN } from './mock.mjs';
const BASE = process.env.SMOKE_BASE || 'http://localhost:4174/bridge';
const IG = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 340.0.2.23.108 (iPhone15,2; iOS 17_5; en_US; en; scale=3.00; 1179x2556; 624443862)';
const browser = await chromium.launch();
const results = [];
async function run(name, fn, opts = {}) {
  const ctx = await browser.newContext({ ...devices['iPhone 13'], ...(opts.ua ? { userAgent: opts.ua } : {}) });
  const log = []; const errors = [];
  await ctx.route('https://mock.supabase.test/**', (r) => handle(r, log));
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
const expectText = async (page, text, timeout = 8000) => page.getByText(text, { exact: false }).first().waitFor({ timeout });
const assert = (c, m) => { if (!c) throw new Error(m); };

await run('event page renders with directions', async (page) => {
  await page.goto(BASE + '/event/' + EV);
  await expectText(page, 'Fall Party');
  const dir = page.getByRole('link', { name: /directions/i });
  assert((await dir.getAttribute('href')).includes('google.com/maps/dir'), 'directions link');
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
});

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

await browser.close();
for (const r of results) console.log((r.ok ? 'PASS ' : 'FAIL ') + r.name + (r.errors.length ? '\n   ' + r.errors.join('\n   ') : '') + (r.calls ? '\n   calls: ' + r.calls.join(' | ') : ''));

if (results.some((r) => !r.ok)) process.exit(1);
