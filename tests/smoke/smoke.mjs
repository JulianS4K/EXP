// Browser smoke tests for the buyer and promoter pages, against a mocked
// Supabase (tests/smoke/mock.mjs). Run with `npm run smoke` (builds the SPA
// pointed at the mock host, serves it, runs these). No real backend needed.
import { chromium, devices } from 'playwright';
import { readFileSync } from 'node:fs';
import { handle, EV, TIER2, ADDON, TOKEN, ORG, UID, TICKET, ORG_ROW, EVENT_ROW, ownerTables, tables as baseTables } from './mock.mjs';
const BASE = process.env.SMOKE_BASE || 'http://localhost:4174/bridge';
const IG = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 340.0.2.23.108 (iPhone15,2; iOS 17_5; en_US; en; scale=3.00; 1179x2556; 624443862)';
const FB_ANDROID = 'Mozilla/5.0 (Linux; Android 14; SM-S918U Build/UP1A; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/126.0.6478.71 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/471.0.0.35.80;]';
// SMOKE_CHROMIUM: a local browser binary when Playwright's own download isn't available.
const browser = await chromium.launch(process.env.SMOKE_CHROMIUM ? { executablePath: process.env.SMOKE_CHROMIUM } : {});
const results = [];
async function run(name, fn, opts = {}) {
  const ctx = await browser.newContext({ ...devices[opts.device || 'iPhone 13'], ...(opts.ua ? { userAgent: opts.ua } : {}) });
  const log = []; const errors = [];
  // In-app browsers that block storage (Instagram / Facebook with cookies off):
  // touching localStorage or sessionStorage throws, as it does there.
  if (opts.noStorage) await ctx.addInitScript(() => {
    for (const k of ['localStorage', 'sessionStorage']) {
      Object.defineProperty(window, k, { configurable: true, get() { throw new DOMException('The operation is insecure.', 'SecurityError'); } });
    }
  });
  // Third-party hosts (pixel vendors, fonts) never load: fast, offline, and a
  // test asserts on what the app injected, not on what a vendor did.
  await ctx.route((u) => !u.href.startsWith('http://localhost') && !u.href.startsWith('https://mock.supabase.test/'), (r) => r.abort());
  await ctx.route('https://mock.supabase.test/**', (r) => handle(r, log, opts.mock));
  // A visitor who already answered the cookie banner (declined), so it stays
  // out of the way; the consent tests start fresh.
  if (!opts.freshConsent && !opts.noStorage) await ctx.addInitScript(() => {
    if (!localStorage.getItem('exos.consent.v2')) localStorage.setItem('exos.consent.v2', JSON.stringify({ analytics: 'denied', advertising: 'denied' }));
  });
  if (opts.gpc) await ctx.addInitScript(() => Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', { get: () => true, configurable: true }));
  // A stored, unexpired session: supabase-js reads it without a network call.
  if (opts.signedIn) await ctx.addInitScript((session) => {
    localStorage.setItem('sb-mock-auth-token', JSON.stringify(session));
  }, SESSION);
  const page = await ctx.newPage();
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource|401|WebSocket connection to 'wss:\/\/mock\.supabase\.test/.test(m.text())) errors.push('console: ' + m.text()); });
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
    // The order total: VIP ($50) x 3 + 2 posters ($5) = $160 (GA x 3 would be $70).
    assert(/\$160/.test(body), label + ': total is VIP x 3 + add-ons ($160), page shows ' + (body.match(/\$\d+(\.\d+)?/g) || []).join(','));
    assert(/incl\. \$10(\.00)? of add-ons/i.test(body), label + ': says what the add-ons add');
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

// ── In-app browser checkout (roadmap 7a): Instagram iOS and Facebook Android,
// storage blocked, guest checkout through a stubbed Stripe page and back. ──
// Stripe Checkout, stubbed: a page whose "Pay" goes to the success URL.
async function stubStripe(page, checkout) {
  await page.route('https://checkout.stripe.com/**', (r) => {
    // Stripe goes back to the session's success_url: the one exos-checkout
    // gave it (with the #pt= fragment for a guest), else the page's.
    const back = String(checkout.successBack ?? checkout.body?.success_url ?? '').replace('{CHECKOUT_SESSION_ID}', 'cs_test_iab');
    return r.fulfill({ contentType: 'text/html', body: `<!doctype html><title>Stripe</title><h1>Stripe test checkout</h1><a id="pay" href="${back}">Pay</a>` });
  });
}
const checkoutFn = (into) => ({ fns: { 'exos-checkout': (body) => {
  into.body = body;
  return { body: { url: 'https://checkout.stripe.com/c/pay/cs_test_iab', session_id: 'cs_test_iab' } };
} } });
// A guest order waiting for proof of the email (mig 20261105100000), as
// exos-checkout answers it: the browser token in the body, and the same token
// on Stripe's success_url fragment (withProofFragment), since storage may be
// blocked. The proof RPCs accept only that token, and the code 123456.
const PROOF_TOKEN = 'smokeProofToken_0123456789abcdefghijklmnopq';
const proofCheckoutFn = (into) => ({
  fns: { 'exos-checkout': (body) => {
    into.body = body;
    into.successBack = body.success_url + '#pt=' + PROOF_TOKEN;
    return { body: { url: 'https://checkout.stripe.com/c/pay/cs_test_iab', session_id: 'cs_test_iab', proof_token: PROOF_TOKEN } };
  } },
  rpcs: {
    exos_order_proof_status: (b) => (b.p_session_id === 'cs_test_iab' && b.p_token === PROOF_TOKEN
      ? { status: into.proven ? 'proven' : 'pending', email: 'fa…@example.com', attempts_left: 5, attached: false, tickets: [] }
      : { status: 'unknown' }),
    exos_order_proof_verify: (b) => {
      if (b.p_session_id !== 'cs_test_iab' || b.p_token !== PROOF_TOKEN) return { ok: false, error: 'unknown' };
      if (b.p_code !== '123456') return { ok: false, error: 'wrong_code', attempts_left: 4 };
      into.proven = true;
      return { ok: true, status: 'proven', attached: false, tickets: [{ ticket_id: 't1', path: '/claim/abc' }, { ticket_id: 't2', path: '/claim/def' }] };
    },
  },
});
const until = async (cond, what, ms = 5000) => {
  for (let i = 0; i < ms / 100 && !(await cond()); i++) await new Promise((r) => setTimeout(r, 100));
  assert(await cond(), 'timed out waiting for ' + what);
};
const storageThrows = (page) => page.evaluate(() => { try { localStorage.getItem('x'); return false; } catch { return true; } });
async function rejectCookies(page) {
  // No storage, so the consent banner asks on every load; the choice holds for the page.
  const b = page.getByRole('dialog').filter({ hasText: 'analytics and advertising cookies' });
  await b.waitFor({ timeout: 8000 });
  await b.getByRole('button', { name: 'Reject all' }).click();
  await b.waitFor({ state: 'hidden' });
}
async function payAsGuest(page, email) {
  await page.getByRole('button', { name: /Buy Tickets/i }).first().click();
  const dlg = page.getByRole('dialog').filter({ hasText: 'Where should we send your tickets?' });
  await dlg.waitFor({ timeout: 8000 });
  // Read before paying: the page leaves for Stripe right after.
  const text = (await dlg.innerText()).replace(/\s+/g, ' ');
  await dlg.getByLabel('Email').fill(email);
  await dlg.getByRole('button', { name: 'Continue to payment' }).click();
  return text;
}

const igCheckout = {};
await run('Instagram iOS, no storage: checkout link keeps the cart, guest pays by card, back from Stripe', async (page, log) => {
  const popups = [];
  page.context().on('page', (p) => popups.push(p.url()));
  await stubStripe(page, igCheckout);
  await page.goto(BASE + '/checkout?products=' + TIER2 + ':2&utm_source=instagram&utm_medium=story&fbclid=IwAR_iab1');
  await page.waitForURL(/\/event\//, { timeout: 8000 });
  assert(await storageThrows(page), 'storage is blocked in this context');
  await expectText(page, 'Fall Party');
  await rejectCookies(page);
  // The cart survives without sessionStorage: VIP x 2 = $100.
  await until(async () => /\$100/.test(await page.locator('body').innerText()), 'VIP x 2 pre-filled from the URL');
  // The escape hatch: menu steps, copy link, and a URL carrying cart + attribution + iab_from.
  const hatch = page.getByTestId('in-app-escape').first();
  await expectText(page, 'You can buy right here in Instagram. For Apple Pay, open this page in Safari.');
  await expectText(page, 'Open in external browser');
  const escape = await hatch.getAttribute('data-url');
  assert(escape.includes('/checkout?') && escape.includes('products=' + TIER2 + '%3A2') && escape.includes('utm_source=instagram')
    && escape.includes('fbclid=IwAR_iab1') && escape.includes('iab_from=instagram'), 'escape URL carries the cart: ' + escape);
  // http://localhost can't become x-safari-https:, so only steps + copy here (vitest covers the link).
  assert(await hatch.getByRole('link', { name: /Open in Safari/ }).count() === 0, 'no x-safari link for an http page');
  const dlg = await payAsGuest(page, 'fan@example.com');
  assert(/Pay with card, and we/.test(dlg) && dlg.includes('Card works right here.'), 'no Apple Pay promise inside Instagram: ' + dlg);
  await page.waitForURL(/checkout\.stripe\.com/, { timeout: 8000 });
  const b = igCheckout.body;
  assert(b && b.in_app_browser === 'instagram', 'records the in-app browser: ' + JSON.stringify(b));
  assert(b.guest_email === 'fan@example.com' && b.tier_id === TIER2 && b.quantity === 2, 'guest VIP x2: ' + JSON.stringify(b));
  assert(b.attribution?.utm_source === 'instagram' && b.attribution?.fbclid === 'IwAR_iab1', 'attribution kept: ' + JSON.stringify(b.attribution));
  assert(b.success_url.includes('guest=1') && b.success_url.includes('to=f***%40example.com'), 'masked inbox on the return URL: ' + b.success_url);
  assert(!b.success_url.includes('#'), 'the page asks for no fragment; exos-checkout adds it: ' + b.success_url);
  // Stripe's "Pay" goes to success_url + #pt=: the token rides in the
  // fragment, never in the query.
  const pay = await page.locator('#pay').getAttribute('href');
  assert(new URL(pay).hash === '#pt=' + PROOF_TOKEN && !new URL(pay).search.includes(PROOF_TOKEN), 'token in the fragment only: ' + pay);
  await page.locator('#pay').click();
  await page.waitForURL(/\/my-tickets/, { timeout: 8000 });
  // Proof of email: storage is blocked, so the token can only have come
  // from the fragment (the Stripe page was a full page load).
  await expectText(page, 'Confirm your email');
  await expectText(page, 'enter the 6-digit code we emailed to');
  await until(() => log.some((l) => l.startsWith('rpc exos_order_proof_status ') && l.includes('"p_token":"' + PROOF_TOKEN + '"')
    && l.includes('"p_session_id":"cs_test_iab"')), 'status asked with the fragment token');
  // ...and it's gone from the address bar (and from history) once read.
  const here = await page.evaluate(() => location.href);
  assert(!here.includes(PROOF_TOKEN) && !here.includes('pt='), 'token stripped from the URL: ' + here);
  assert(await storageThrows(page), 'still no storage');
  // A wrong code first, then the mailed one.
  const codeBox = page.getByLabel('6-digit code');
  await codeBox.fill('000000');
  await page.getByRole('button', { name: 'Confirm' }).click();
  await expectText(page, "That code isn't right. 4 tries left.");
  await codeBox.fill('123 456');
  await page.getByRole('button', { name: 'Confirm' }).click();
  await expectText(page, 'Confirmed.');
  await expectText(page, 'Claim ticket 2');
  assert(log.some((l) => l.startsWith('rpc exos_order_proof_verify ') && l.includes('"p_token":"' + PROOF_TOKEN + '"') && l.includes('"p_code":"123456"')),
    'verify sent the fragment token and the code: ' + log.filter((l) => l.includes('proof')).join(' | '));
  assert(!(await page.evaluate(() => location.href)).includes(PROOF_TOKEN), 'still not in the URL');
  assert(popups.length === 0, 'no popup or new tab: ' + popups.join(', '));
}, { ua: IG, noStorage: true, mock: proofCheckoutFn(igCheckout) });

const fbCheckout = {};
await run('Facebook Android, no storage: intent escape, guest checkout to Stripe and back', async (page) => {
  const popups = [];
  page.context().on('page', (p) => popups.push(p.url()));
  await stubStripe(page, fbCheckout);
  await page.goto(BASE + '/event/' + EV + '?utm_source=facebook&utm_medium=post');
  await expectText(page, 'Fall Party');
  assert(await storageThrows(page), 'storage is blocked in this context');
  await rejectCookies(page);
  await expectText(page, 'You can buy right here in Facebook. For Google Pay, open this page in your browser.');
  const escape = await page.getByTestId('in-app-escape').first().getAttribute('data-url');
  assert(escape.includes('utm_source=facebook') && escape.includes('iab_from=facebook'), 'escape URL: ' + escape);
  const dlg = await payAsGuest(page, 'Guest@Example.com');
  assert(/Card works right here/.test(dlg), 'the modal offers the escape for Google Pay: ' + dlg);
  await page.waitForURL(/checkout\.stripe\.com/, { timeout: 8000 });
  assert(fbCheckout.body?.in_app_browser === 'facebook' && fbCheckout.body.guest_email === 'guest@example.com', 'body: ' + JSON.stringify(fbCheckout.body));
  await page.locator('#pay').click();
  await page.waitForURL(/\/my-tickets/, { timeout: 8000 });
  await expectText(page, 'g***@example.com');
  // Back from the confirmation, then back from Stripe: the Buy button works again.
  await page.goBack();
  await page.goBack();
  await page.waitForURL(/\/event\//, { timeout: 8000 });
  await page.getByRole('button', { name: /Buy Tickets/i }).first().waitFor({ timeout: 8000 });
  assert(await page.getByRole('button', { name: /Buy Tickets/i }).first().isEnabled(), 'Buy is enabled after coming back');
  assert(popups.length === 0, 'no popup or new tab: ' + popups.join(', '));
}, { ua: FB_ANDROID, device: 'Pixel 7', noStorage: true, mock: checkoutFn(fbCheckout) });

const plainCheckout = {};
await run('a normal browser is unchanged: no banner, wallets offered, recorded as none', async (page) => {
  await stubStripe(page, plainCheckout);
  await page.goto(BASE + '/event/' + EV);
  await expectText(page, 'Fall Party');
  assert(await page.getByTestId('in-app-escape').count() === 0, 'no escape hatch in Safari');
  const dlg = await payAsGuest(page, 'fan@example.com');
  assert(/Apple Pay, Google Pay or card/.test(dlg) && !dlg.includes('Card works right here'), 'wallets offered: ' + dlg);
  await page.waitForURL(/checkout\.stripe\.com/, { timeout: 8000 });
  assert(plainCheckout.body?.in_app_browser === 'none', 'recorded as a real browser: ' + JSON.stringify(plainCheckout.body));
}, { mock: checkoutFn(plainCheckout) });

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
// Chargebacks (mig 20261001101000), as exos_disputes rows.
const dispute = (id, extra = {}) => ({
  id, org_id: ORG, event_id: EV, session_id: 'cs_1', payment_intent: 'pi_cs_1', charge_id: 'ch_1', dispute_id: 'du_' + id,
  amount_cents: 4000, fee_cents: 1500, currency: 'usd', reason: 'fraudulent', status: 'needs_response', evidence_due_by: null,
  evidence_submitted: false, livemode: true, created_at: '2026-09-24T12:00:00Z', updated_at: '2026-09-24T12:00:00Z', closed_at: null,
  last_event_id: 'evt_1', recovery_status: 'none', recovery_candidate_cents: null, raw: null, ...extra,
});
const reportMock = ownerMock({ tables: {
  exos_tickets: [], exos_discount_codes: [],
  exos_checkout_sessions: SESSIONS,
  exos_order_money: [money('cs_1', 4000, 0), money('cs_2', 2000, 0), money('cs_3', 2000, 2000), money('cs_4', 2000, 0)],
  exos_marketplace_order_money: [], exos_promoter_commissions: [],
  exos_disputes: [
    dispute('d1', { session_id: 'cs_1', status: 'needs_response', evidence_due_by: new Date(Date.now() + 5 * 864e5 + 36e5).toISOString() }),
    dispute('d2', { session_id: 'cs_2', dispute_id: 'du_lost2', status: 'lost', amount_cents: 2000, reason: 'product_not_received',
      closed_at: '2026-09-25T00:00:00Z', recovery_status: 'recovery_pending', recovery_candidate_cents: 3500 }),
  ],
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
  assert(lines[0] === 'utm_source,utm_medium,utm_campaign,promoter,ad_platform,ai_assistant,orders,tickets,gross,refunded_orders,currency', 'header ' + lines[0]);
  assert(lines.includes('instagram,paid,fall,,Meta,,1,2,40.00,0,USD'), 'Instagram row: ' + lines.join(' | '));
  assert(lines.includes(',,,dj-kay,,,1,1,20.00,1,USD'), 'promoter row (refunded): ' + lines.join(' | '));
}, { signedIn: true, mock: reportMock });

await run('event report: where buyers checked out (in-app vs browser)', async (page, log) => {
  await page.goto(BASE + '/dashboard/event/' + EV + '?tab=marketing');
  const section = page.locator('section', { has: page.getByRole('heading', { name: 'Where buyers checked out' }) });
  await section.waitFor({ timeout: 8000 });
  const text = (await section.innerText()).replace(/\s+/g, ' ');
  for (const want of ['Instagram app', 'Browser, opened from Instagram', 'In-app conversion is 50% against 67% in browsers', '25% below the browser', '$75.00']) {
    assert(text.includes(want), `panel shows "${want}": ` + text);
  }
  assert(log.some((l) => l.startsWith('rpc exos_event_in_app_report') && l.includes(EV)), 'report RPC called');
}, { signedIn: true, mock: ownerMock({ tables: reportMock.tables, rpcs: { exos_event_in_app_report: () => ({ currency: 'usd', rows: [
  { in_app_browser: 'instagram', escaped_from: null, started: 4, paid: 2, tickets: 3, gross_cents: 7500 },
  { in_app_browser: 'none', escaped_from: 'instagram', started: 1, paid: 1, tickets: 2, gross_cents: 5000 },
  { in_app_browser: 'none', escaped_from: null, started: 2, paid: 1, tickets: 1, gross_cents: 2500 },
] }) } }) });

// ── claude/exos-buyer-geo-genre (mig 20261106140000): where buyers are, genre chips ──
const GEO = (orders) => ({
  orders, tickets: orders + 1, located_orders: orders - 1, unknown_orders: 1, other_tickets: 2,
  countries: [{ country: 'US', currency: 'USD', orders: orders - 2, tickets: orders - 1, gross_cents: 10500 },
    { country: 'GB', currency: 'USD', orders: 1, tickets: 1, gross_cents: 3000 }],
  cities: [{ country: 'US', region: 'NY', city: 'Brooklyn', currency: 'USD', orders: orders - 2, tickets: orders - 1, gross_cents: 10500 }],
  unknown: [{ country: null, currency: 'USD', orders: 1, tickets: 1, gross_cents: 0 }],
});
await run('event report: where buyers are (countries, cities, unknown; org-wide)', async (page, log) => {
  await page.goto(BASE + '/dashboard/event/' + EV + '?tab=marketing');
  const section = page.locator('section', { has: page.getByRole('heading', { name: 'Where buyers are' }) });
  await section.getByText('Brooklyn, NY').waitFor({ timeout: 8000 });
  let text = (await section.innerText()).replace(/\s+/g, ' ');
  for (const want of ['United States', 'United Kingdom', 'Unknown', '$105.00', '3 of 4 orders have a location', '2 more tickets came from RSVPs']) {
    assert(text.includes(want), `panel shows "${want}": ` + text);
  }
  assert(log.some((l) => l.startsWith('rpc exos_event_buyer_geo') && l.includes(EV)), 'event RPC called');
  await section.getByRole('button', { name: 'All events' }).click();
  await section.getByText('9 of 10 orders').waitFor({ timeout: 8000 });
  assert(log.some((l) => l.startsWith('rpc exos_org_buyer_geo') && l.includes(ORG)), 'org RPC called');
}, { signedIn: true, mock: ownerMock({ tables: reportMock.tables, rpcs: {
  exos_event_buyer_geo: () => GEO(4), exos_org_buyer_geo: () => GEO(10),
} }) });

await run('home: genre chips filter the events', async (page, log) => {
  await page.goto(BASE + '/');
  const chips = page.getByRole('group', { name: 'Filter by genre' });
  await chips.getByRole('button', { name: 'JAZZ' }).waitFor({ timeout: 8000 });
  await expectText(page, 'Fall Party');
  await expectText(page, 'Late Jazz');
  await chips.getByRole('button', { name: 'JAZZ' }).click();
  await page.getByText('Fall Party').first().waitFor({ state: 'detached', timeout: 8000 });
  await expectText(page, 'Late Jazz');
  assert(log.some((l) => l.startsWith('rpc exos_api_public') && l.includes('genres.list')), 'genres from public discovery');
  assert(log.some((l) => l.startsWith('GET exos_public_events') && l.includes('genres=ov.')), 'the genre read: ' + log.filter((l) => l.includes('exos_public_events')).join(' | '));
  await chips.getByRole('button', { name: 'ALL' }).click();
  await expectText(page, 'Fall Party');
}, { mock: { tables: { exos_public_events: [
  { ...baseTables.exos_public_events[0], genres: ['House'] },
  { ...baseTables.exos_public_events[0], id: '99999999-9999-4999-8999-999999999991', slug: 'late-jazz', name: 'Late Jazz', genres: ['Jazz'] },
] }, rpcs: { exos_api_public: () => [
  { genre: 'house', name: 'House', events: 1, variants: ['House'] },
  { genre: 'jazz', name: 'Jazz', events: 1, variants: ['Jazz'] },
] } } });

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

await run('event report: Disputes block with status, amount, due date and Stripe link', async (page, log) => {
  await page.goto(BASE + '/dashboard/event/' + EV);
  const section = page.locator('section', { has: page.getByRole('heading', { name: 'Disputes' }) });
  await section.waitFor({ timeout: 8000 });
  await section.getByText('Needs response').waitFor({ timeout: 8000 });
  const text = (await section.innerText()).replace(/\s+/g, ' ');
  assert(text.includes('$40.00') && text.includes('Fraudulent'), 'open dispute row: ' + text);
  assert(/Due \w+ \d+ \(in 5 days\)/.test(text), 'evidence due date: ' + text);
  assert(/\bLOST\b/i.test(text) && text.includes('Product not received') && text.includes('$35.00 may be taken from a later payout'), 'lost row + recovery: ' + text);
  assert(/Open\s*1\s*\$40\.00 at stake/i.test(text), 'open summary: ' + text);
  assert(await section.locator('a[href="https://dashboard.stripe.com/disputes/du_d1"]').count() === 1, 'Stripe link');
  const read = log.find((l) => l.startsWith('GET exos_disputes'));
  assert(read && read.includes('event_id=eq.' + EV) && read.includes('evidence_due_by'), 'disputes read: ' + read);
}, { signedIn: true, mock: reportMock });

const DOOR_SUMMARY = {
  event: { id: EV, name: 'Fall Party', status: 'published', timezone: 'America/New_York' },
  generated_at: '2026-10-03T05:00:00Z',
  tickets: { sold: 6, voided: 1, checked_in: 4, no_shows: 2, voided_entered: 1 },
  entries: { total: 6, first: 5, reentries: 1, exits: 1, forced: 1, offline: 2, by_verification: { verified: 3, manual: 1, name: 1 } },
  first_entry_at: '2026-10-02T23:10:00Z', last_entry_at: '2026-10-03T00:45:00Z',
  peak: { start: '2026-10-02T23:15:00Z', entries: 4 },
  by_hour: [{ hour: '2026-10-02T19:00', entries: 5 }, { hour: '2026-10-02T20:00', entries: 1 }],
  by_tier: [{ tier: 'GA', sold: 4, checked_in: 3 }, { tier: 'VIP', sold: 2, checked_in: 1 }],
  by_list: [{ list: 'Main door', entries: 4, exits: 0 }, { list: 'Smoking deck', entries: 2, exits: 1 }],
  by_staff: [{ staff: 'Sam Scanner', entries: 5, refused: 2 }],
  overrides: [{ reason: 'Phone died', count: 1 }], conflicts: [{ reason: 'voided', count: 1 }],
  refused: { total: 2, by_reason: [{ reason: 'used', count: 2 }] }, inside_now: 1,
};

await run('event report: end-of-night door summary with CSV', async (page, log) => {
  await page.goto(BASE + '/dashboard/event/' + EV);
  const section = page.locator('section', { has: page.getByRole('heading', { name: 'End-of-night door summary' }) });
  await section.waitFor({ timeout: 8000 });
  const text = (await section.innerText()).replace(/\s+/g, ' ');
  for (const want of ['4 / 6', '67% showed up', '7:10 PM', 'last in 8:45 PM', 'from 7:15 PM', '1 inside now',
    '7 PM', 'Sam Scanner', 'Smoking deck', 'Phone died', 'refunded / voided', 'already checked in', 'America/New York']) {
    assert(text.includes(want), `summary shows "${want}": ` + text);
  }
  assert(log.some((l) => l.startsWith('rpc exos_event_door_summary') && l.includes(EV)), 'summary RPC called');
  const { text: csv } = await download(page, () => section.getByRole('button', { name: 'CSV' }).click());
  const lines = firstLines(csv);
  assert(lines[0] === 'section,item,value,value_2', 'header ' + lines[0]);
  assert(lines.includes('ticket_type,VIP,1,2') && lines.includes('staff,Sam Scanner,5,2'), 'rows: ' + lines.join(' | '));
}, { signedIn: true, mock: ownerMock({ tables: reportMock.tables, rpcs: { exos_event_door_summary: () => DOOR_SUMMARY } }) });

await run('event report: no door summary before the migration', async (page) => {
  await page.goto(BASE + '/dashboard/event/' + EV);
  await page.getByRole('heading', { name: 'Disputes' }).waitFor({ timeout: 8000 });
  assert(await page.getByRole('heading', { name: 'End-of-night door summary' }).count() === 0, 'hidden');
}, { signedIn: true, mock: ownerMock({ tables: reportMock.tables, rpcs: {
  exos_event_door_summary: () => ({ __status: 404, __body: { code: 'PGRST202', message: 'Could not find the function' } }) } }) });

// --- Apps suite landing pages (claude/exos-apps-pages) -------------------------
// Public, signed out. Bullets come from the facts registry (AppLanding.test.tsx
// checks what they may say); here: the page renders, carries its meta, and the
// call to action goes to the door or to sign-up.
const APP_PAGES = [
  { id: 'door', headline: 'The free door app for any event.', cta: 'Open the door app', to: '/door' },
  { id: 'events', headline: 'Create an event page and sell tickets.', cta: 'Create your organization', to: '/onboarding' },
  { id: 'promote', headline: 'Get people to your event, and see who brought them.', cta: 'Create your organization', to: '/onboarding' },
  { id: 'money', headline: 'Your sales, settlements and books in one place.', cta: 'Create your organization', to: '/onboarding' },
];
for (const app of APP_PAGES) {
  await run(`apps: /apps/${app.id} landing page`, async (page) => {
    await page.goto(BASE + '/apps/' + app.id);
    await page.getByRole('heading', { level: 1, name: app.headline }).waitFor({ timeout: 8000 });
    assert(await page.locator('[data-claims="features"] li[data-fact]').count() >= 5, 'feature bullets from the registry');
    assert(await page.locator('[data-claims] li:not([data-fact])').count() === 0, 'no bullet outside the registry');
    await expectText(page, 'coming at launch');
    assert((await page.title()).endsWith(' | Exos') && (await page.title()).startsWith('Exos '), 'title: ' + await page.title());
    const desc = await page.locator('meta[name="description"]').getAttribute('content');
    assert(desc && desc.length > 40, 'description: ' + desc);
    const canonical = await page.locator('link[rel="canonical"]').getAttribute('href');
    assert(canonical && canonical.endsWith('/bridge/apps/' + app.id), 'canonical: ' + canonical);
    // The footer links every app (cross-links are a footer, not a menu).
    const footer = page.locator('footer');
    for (const other of APP_PAGES) assert(await footer.locator(`a[href$="/apps/${other.id}"]`).count() === 1, 'footer link ' + other.id);
    await page.getByRole('link', { name: app.cta }).first().click();
    await page.waitForURL((u) => u.pathname === '/bridge' + app.to, { timeout: 8000 });
  });
}

// --- Exos Door (mig 20261013090000) ------------------------------------------
await run('door app: the pitch and sign-in when signed out', async (page) => {
  await page.goto(BASE + '/door');
  await expectText(page, 'The free door app for any event.');
  await page.getByRole('button', { name: 'Sign in or create an account' }).waitFor({ timeout: 8000 });
  const manifest = await page.locator('link[rel="manifest"]').getAttribute('href');
  assert(manifest && manifest.endsWith('door.webmanifest'), 'own install manifest: ' + manifest);
});

const EB_CSV = 'Order #,First Name,Last Name,Email,Ticket Type,Barcode #\n1001,Ada,Lovelace,ada@x.com,GA,1234 5678\n1002,Bo,Diddley,bo@x.com,VIP,87654321\n1003,,,ghost@x.com,GA,555\n';
await run('door app: import an Eventbrite attendee CSV into an event', async (page, log) => {
  await page.goto(BASE + '/door');
  await expectText(page, 'Your doors');
  await page.getByRole('button', { name: /Import CSV/ }).first().click();
  await page.locator('input[type="file"]').setInputFiles({ name: 'eventbrite-report.csv', mimeType: 'text/csv', buffer: Buffer.from(EB_CSV) });
  await expectText(page, '2 attendees to import');
  await expectText(page, '1 row(s) have no name');
  assert(await page.locator('select').first().inputValue() === 'Eventbrite', 'platform guessed from the file');
  await page.getByRole('button', { name: /Import 2 attendees/ }).click();
  await expectText(page, 'Imported 2.');
  const call = log.find((l) => l.startsWith('rpc exos_import_guests'));
  assert(call && call.includes('"p_list_id":"gl-1"') && call.includes('"code":"12345678"') && call.includes('"name":"Ada Lovelace"')
    && call.includes('"source":"Eventbrite"') && !call.includes('ghost@x.com'), 'import payload: ' + call);
  assert(log.some((l) => l.startsWith('rpc exos_upsert_guest_list') && l.includes('Eventbrite import')), 'list created');
}, { signedIn: true, mock: ownerMock({ rpcs: {
  exos_upsert_guest_list: () => 'gl-1',
  exos_import_guests: (b) => ({ inserted: b.p_rows.length, duplicates: 0, invalid: 0, errors: [] }),
} }) });

const DOOR_GUESTS = {
  tables: [], ticket_access: {},
  lists: [{ id: 'gl1', name: 'Eventbrite import', cap: null, status: 'open', promoter: null }],
  guests: [{ id: 'g1', list_id: 'gl1', guest_name: 'Ada Lovelace', plus_ones: 0, arrived: 0, arrived_at: null, note: null,
    code: '12345678', ticket: 'GA', source: 'Eventbrite' }],
};
await run('door: a code from another platform checks the imported guest in', async (page, log) => {
  await page.goto(BASE + '/checkin/' + EV);
  await page.getByText(/^Guest list/).first().click();
  const box = page.getByPlaceholder('Scan or type a ticket code');
  await box.waitFor({ timeout: 8000 });
  await box.fill('1234 5678');
  await box.press('Enter');
  await expectText(page, 'Ada Lovelace · GA · Eventbrite ticket');
  await expectText(page, '1 in');
  const call = log.find((l) => l.startsWith('rpc exos_guest_check_in'));
  assert(call && call.includes('"p_entry_id":"g1"') && call.includes('"p_count":1'), 'guest check-in: ' + call);
  await box.fill('nope-999');
  await box.press('Enter');
  await expectText(page, 'Not on the imported lists');
}, { signedIn: true, mock: ownerMock({ rpcs: {
  exos_event_door_extras: () => DOOR_GUESTS,
  exos_guest_check_in: () => ({ ok: true, reason: 'checked-in', arrived: 1, party: 1 }),
  exos_event_checkin_roster: () => [], exos_event_checkin_roster_since: () => [], exos_event_door_roster: () => [],
  exos_server_time: () => new Date().toISOString(),
} }) });

let ebState = { can_manage: true, connected: false, account_name: null, link: null };
await run('door app: connect Eventbrite and link an event (read-only sync)', async (page, log) => {
  ebState = { can_manage: true, connected: false, account_name: null, link: null };
  await page.goto(BASE + '/door');
  await expectText(page, 'Your doors');
  await page.getByRole('button', { name: /Eventbrite sync/ }).first().click();
  await expectText(page, 'Live sync from Eventbrite');
  await page.getByLabel('Eventbrite private token').fill('ABCDEFGH12345678');
  await page.getByRole('button', { name: /Connect Eventbrite/ }).click();
  await expectText(page, 'Connected to Blue Room.');
  const connect = log.find((l) => l.startsWith('fn exos-eventbrite-sync/connect'));
  assert(connect && connect.includes('"token":"ABCDEFGH12345678"'), 'connect call: ' + connect);
  assert(!log.some((l) => l.startsWith('rpc') && l.includes('ABCDEFGH')), 'token never sent to an RPC');
  await page.getByRole('button', { name: /Show my Eventbrite events/ }).click();
  await page.getByLabel('Eventbrite event').selectOption('222');
  await page.getByRole('button', { name: /Link and sync/ }).click();
  await expectText(page, 'Linked. 2 new, 1 refunded or cancelled. Up to date.');
  const link = log.find((l) => l.startsWith('fn exos-eventbrite-sync/link'));
  assert(link && link.includes('"eb_event":"222"'), 'link call: ' + link);
  await expectText(page, 'Linked to Fall Party (EB)');
  await expectText(page, '2 attendees at the door · 1 refunded or cancelled');
}, { signedIn: true, mock: ownerMock({
  rpcs: { exos_eventbrite_status: () => ebState },
  fns: {
    'exos-eventbrite-sync/connect': () => {
      ebState = { ...ebState, connected: true, account_name: 'Blue Room' };
      return { body: { connected: true, account_name: 'Blue Room' } };
    },
    'exos-eventbrite-sync/events': () => ({ body: { events: [
      { id: '111', name: 'Other night', start: '2026-10-20T00:00:00Z', status: 'live' },
      { id: '222', name: 'Fall Party (EB)', start: '2026-10-25T00:00:00Z', status: 'live' }] } }),
    'exos-eventbrite-sync/link': () => {
      ebState = { ...ebState, link: { eb_event_id: '222', eb_event_name: 'Fall Party (EB)', last_synced_at: new Date().toISOString(),
        last_ok_at: new Date().toISOString(), last_error: null, syncing: false, attendees: 2, voided: 1 } };
      return { body: { linked: true, sync: { state: 'done', rows: 3, added: 2, voided: 1, restored: 0 } } };
    },
  },
}) });

await run('door: a ticket refunded on Eventbrite is refused at the door', async (page, log) => {
  await page.goto(BASE + '/checkin/' + EV);
  await page.getByText(/^Guest list/).first().click();
  const box = page.getByPlaceholder('Scan or type a ticket code');
  await box.waitFor({ timeout: 8000 });
  await box.fill('87654321');
  await box.press('Enter');
  await expectText(page, 'Bo Diddley: not valid. The ticket was refunded on Eventbrite.');
  assert(!log.some((l) => l.startsWith('rpc exos_guest_check_in')), 'no check-in sent for a voided ticket');
}, { signedIn: true, mock: ownerMock({ rpcs: {
  exos_event_door_extras: () => ({ ...DOOR_GUESTS, guests: [...DOOR_GUESTS.guests,
    { id: 'g2', list_id: 'gl1', guest_name: 'Bo Diddley', plus_ones: 0, arrived: 0, arrived_at: null, note: null,
      code: '87654321', ticket: 'VIP', source: 'Eventbrite', voided: true, void_reason: 'refunded' }] }),
  exos_event_checkin_roster: () => [], exos_event_checkin_roster_since: () => [], exos_event_door_roster: () => [],
  exos_server_time: () => new Date().toISOString(),
} }) });

// --- Walk-up sales at the door (mig 20261107100000) -------------------------
const WALKUP_TIER = '88888888-8888-4888-8888-888888888888';
const WALKUP_ORDER = '99999999-9999-4999-8999-999999999999';
const WALKUP_DRAWER = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const WALKUP_TICKET = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
let walkupSold = false;
const walkupOrder = () => ({
  id: WALKUP_ORDER, event_id: EV, status: 'paid', payment_method: 'cash', currency: 'usd', total_cents: 2500, tax_cents: 0,
  tenders: { cash: 2500, comp: 0, card: 0 }, tier_id: WALKUP_TIER, tier_name: 'Door GA', quantity: 1, comp_quantity: 0,
  ticket_ids: [WALKUP_TICKET], tickets_scanned: 0, buyer_name: null, buyer_email: null, rung_by_me: true,
  created_at: new Date().toISOString(), can_void: true, can_refund: true, can_hand_over: true, replay: false,
});
const walkupPos = (b) => {
  switch (b.action) {
    case 'walkup_catalog': return { body: { data: {
      event: { id: EV, name: 'Fall Party', status: 'published', currency: 'USD' }, role: 'owner', can_comp: true,
      card: { connected: false, message: "Card at the door isn't connected yet." }, fee_base: 'card-tickets',
      tiers: [{ tier_id: WALKUP_TIER, name: 'Door GA', price_cents: 2500, price_source: 'door', step_name: null, step_remaining: null,
        tax: null, unit_total_cents: 2500, remaining: walkupSold ? 41 : 42 }],
      questions: [],
      drawers: [{ id: WALKUP_DRAWER, device_id: null, mine: true, opened_at: new Date().toISOString(), open_float_cents: 10000,
        cash_cents: walkupSold ? 12500 : 10000 }] } } };
    case 'recent_sales': return { body: { data: walkupSold ? [walkupOrder()] : [] } };
    case 'mint_walkup':
      if (b.payment !== 'cash' || b.tier_id !== WALKUP_TIER || b.quantity !== 1 || b.drawer_id !== WALKUP_DRAWER || !b.order_key) {
        return { status: 400, body: { error: 'refused', message: 'unexpected sale ' + JSON.stringify(b) } };
      }
      walkupSold = true;
      return { body: { data: walkupOrder() } };
    case 'order_codes': return { body: { data: { tickets: [{ ticket_id: WALKUP_TICKET,
      print_code: 'P-' + WALKUP_TICKET + ':AbCdEfGhIjKlMnOpQrStUv', event_name: 'Fall Party', starts_at: null, tier_name: 'Door GA' }], skipped: [] } } };
    default: return { status: 400, body: { error: 'unknown action' } };
  }
};
await run('door: the Sell tab sells one cash ticket and shows the QR', async (page, log) => {
  walkupSold = false;
  await page.goto(BASE + '/checkin/' + EV);
  await page.getByRole('tab', { name: 'Sell' }).click();
  await expectText(page, 'Door GA');
  await expectText(page, '42 left');
  await page.getByRole('button', { name: '$25.00', exact: true }).first().click();  // quick cash: exact
  await page.getByRole('button', { name: '$50.00', exact: true }).click();
  await expectText(page, 'Change $25.00');
  assert(await page.getByRole('radio', { name: /Card/ }).isDisabled(), 'card is disabled');
  await page.getByRole('button', { name: /Take \$25\.00 · sell 1/ }).click();
  await expectText(page, 'Sold 1 × Door GA');
  const sale = log.find((l) => l.startsWith('fn exos-pos') && l.includes('"mint_walkup"'));
  assert(sale && !/card_number|cvc|"pan"/.test(sale), 'the sale went to exos-pos without card data: ' + sale);
  await page.getByRole('button', { name: 'Show QR' }).click();
  const qr = page.getByRole('img', { name: 'Ticket QR code' });
  await qr.waitFor({ timeout: 8000 });
  assert((await qr.getAttribute('src')).startsWith('data:image/svg+xml'), 'the QR is drawn locally');
  assert(log.some((l) => l.startsWith('fn exos-pos') && l.includes('"order_codes"')), 'asked for the print code');
  await expectText(page, 'gets in once');
}, { signedIn: true, mock: ownerMock({ rpcs: {
  exos_event_door_extras: () => ({ tables: [], ticket_access: {}, lists: [], guests: [] }),
  exos_event_checkin_roster: () => [], exos_event_checkin_roster_since: () => [], exos_event_door_roster: () => [],
  exos_server_time: () => new Date().toISOString(),
}, fns: { 'exos-pos': walkupPos } }) });

// --- Card at the door (mig 20261107130000): the switch on, a mocked reader ---
const CARD_READER = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
let cardPolls = 0;
let cardSold = false;
const cardOrder = (paid) => ({ ...walkupOrder(), payment_method: paid ? 'card' : null, status: paid ? 'paid' : 'pending',
  tenders: { cash: 0, comp: 0, card: paid ? 2500 : 0 }, ticket_ids: paid ? [WALKUP_TICKET] : [],
  card: { status: paid ? 'succeeded' : 'awaiting', mode: 'reader', payment_intent: paid ? 'pi_smoke' : null, decline_code: null } });
const cardPos = (b) => {
  switch (b.action) {
    case 'walkup_catalog': {
      const c = walkupPos(b).body.data;
      return { body: { data: { ...c, card: { connected: true, switched_on: true, message: 'Charge the card on a reader.',
        readers: [{ device_id: CARD_READER, label: 'Door S700', device_type: 'stripe_s700' }], has_location: true, can_manage: true,
        tap_to_pay: false } } } };
    }
    case 'recent_sales': return { body: { data: cardSold ? [cardOrder(true)] : [] } };
    case 'mint_walkup':
      if (b.payment !== 'card' || b.drawer_id || b.comp_quantity !== 0 || b.tier_id !== WALKUP_TIER || !b.order_key) {
        return { status: 400, body: { error: 'refused', message: 'unexpected card sale ' + JSON.stringify(b) } };
      }
      return { body: { data: cardOrder(false) } };
    case 'card_payment':
      if (b.mode !== 'reader' || b.reader_device_id !== CARD_READER || b.order_id !== WALKUP_ORDER) {
        return { status: 400, body: { error: 'refused', message: 'unexpected charge ' + JSON.stringify(b) } };
      }
      return { body: { data: { order_id: WALKUP_ORDER, card: { status: 'processing', mode: 'reader', payment_intent: 'pi_smoke' } } } };
    case 'card_status':
      cardPolls += 1;
      if (cardPolls < 2) return { body: { data: { state: 'waiting', order_id: WALKUP_ORDER } } };
      cardSold = true;
      return { body: { data: { state: 'succeeded', order: cardOrder(true) } } };
    case 'order_codes': return walkupPos(b);
    default: return { status: 400, body: { error: 'unknown action' } };
  }
};
await run('door: with card on, the Sell tab charges on a reader and shows the QR', async (page, log) => {
  cardPolls = 0; cardSold = false;
  await page.goto(BASE + '/checkin/' + EV);
  await page.getByRole('tab', { name: 'Sell' }).click();
  await expectText(page, 'Door GA');
  const card = page.getByRole('radio', { name: /Card/ });
  assert(!(await card.isDisabled()), 'card is enabled with a reader');
  await card.click();
  await expectText(page, 'on Door S700');
  await page.getByRole('button', { name: /Charge \$25\.00 on reader/ }).click();
  await expectText(page, 'Tap, insert or swipe');
  await expectText(page, 'Sold 1 × Door GA', 12000);
  const sale = log.find((l) => l.startsWith('fn exos-pos') && l.includes('"mint_walkup"'));
  assert(sale && sale.includes('"payment":"card"') && !/card_number|cvc|"pan"|exp_month/.test(sale), 'a card sale with no card data: ' + sale);
  assert(log.some((l) => l.startsWith('fn exos-pos') && l.includes('"card_payment"')), 'charged on the reader');
  assert(log.filter((l) => l.startsWith('fn exos-pos') && l.includes('"card_status"')).length >= 2, 'polled until captured');
  await page.getByRole('button', { name: 'Show QR' }).click();
  const qr = page.getByRole('img', { name: 'Ticket QR code' });
  await qr.waitFor({ timeout: 8000 });
  await expectText(page, 'gets in once');
}, { signedIn: true, mock: ownerMock({ rpcs: {
  exos_event_door_extras: () => ({ tables: [], ticket_access: {}, lists: [], guests: [] }),
  exos_event_checkin_roster: () => [], exos_event_checkin_roster_since: () => [], exos_event_door_roster: () => [],
  exos_server_time: () => new Date().toISOString(),
}, fns: { 'exos-pos': cardPos } }) });

await run('payouts page lists payouts and their lines', async (page) => {
  await page.goto(BASE + '/orgs/' + ORG + '/payouts');
  await page.getByRole('heading', { name: 'Payouts' }).waitFor({ timeout: 8000 });
  await expectText(page, '$120.00');
  await expectText(page, 'Account not ready');
  await expectText(page, '1 order, 1 clawback');
  await page.getByRole('button', { name: /\$120\.00/ }).click();
  await expectText(page, 'SH-991');
  await expectText(page, 'Stripe transfer tr_123');
  const disputes = page.locator('section', { has: page.getByRole('heading', { name: 'Disputes' }) });
  await disputes.getByText('Under review').waitFor({ timeout: 8000 });
  assert((await disputes.innerText()).includes('Fall Party'), 'dispute row names the event');
  const table = await page.locator('table').first().innerText();
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
  exos_disputes: [dispute('p1', { status: 'under_review', evidence_submitted: true, event: { name: 'Fall Party' } })],
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
  // The request is logged before its answer reaches the form: wait for the value, not the call.
  const taxId = card.getByLabel('Tax ID (EIN, VAT or sales-tax number)');
  await waitFor(async () => (await taxId.inputValue()) === 'EIN 12-3456789', 'shows the saved tax id');
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

// ── Online / hybrid events, what to bring, noindex (mig 20261005090000) ──
const ONLINE_EVENT = { ...baseTables.exos_public_events[0], format: 'online', venue_name: 'Online', venue_location: 'Online',
  what_to_bring: 'Headphones and a snack.', noindex: true };

await run('online event page: badge, no map, what to bring, hidden from search', async (page) => {
  await page.goto(BASE + '/event/' + EV);
  await expectText(page, 'Ticket holders get the join link on their ticket.');
  await expectText(page, 'Headphones and a snack.');
  assert(await page.getByRole('link', { name: /directions/i }).count() === 0, 'no directions for an online event');
  assert(await page.locator('meta[name="robots"]').getAttribute('content') === 'noindex, nofollow', 'robots noindex');
  assert(await page.locator('#vibepass-jsonld').count() === 0, 'no JSON-LD on a hidden event');
}, { mock: { tables: { exos_public_events: [ONLINE_EVENT] } } });

const onlineTicketMock = (access) => ownerMock({
  tables: {
    exos_tickets: [{
      id: TICKET, event_id: EV, org_id: ORG, tier_id: null, tier_name: 'GA', buyer_id: UID, owner_id: UID, status: 'active',
      price_paid: 20, order_ref: null, channel_source: 'direct', promoter_id: null, pending_transfer_id: null, transfer_id: null,
      voided_at: null, voided_by: null, voided_reason: null, released_at: null, check_in_at: null, last_reissue_at: null,
      created_at: '2026-09-20T12:00:00Z', updated_at: '2026-09-20T12:00:00Z', attendee_name: null,
      event: { ...EVENT_ROW, format: 'online', what_to_bring: 'Headphones and a snack.', noindex: false },
    }],
    exos_ticket_barcode_secrets: [{ ticket_id: TICKET, barcode_secret: 'c2VjcmV0' }],
    exos_transfers: [], exos_event_saves: [],
  },
  rpcs: { exos_my_reschedule_offers: () => [], exos_ticket_access_needs: () => [], exos_event_online_access: () => [access] },
  fns: { 'exos-wallet/pass': () => ({ status: 503, body: { error: 'wallet not configured' } }) },
});

await run('ticket shows the join link and what to bring to the holder', async (page, log) => {
  await page.goto(BASE + '/ticket/' + TICKET);
  const join = page.getByRole('link', { name: /Join the event/ });
  await join.waitFor({ timeout: 8000 });
  assert(await join.getAttribute('href') === 'https://stream.example.com/room', 'join href');
  assert((await join.getAttribute('rel')).includes('noopener'), 'opens safely');
  await expectText(page, 'Passcode 4242');
  await expectText(page, 'Headphones and a snack.');
  assert(log.some((l) => l.startsWith('rpc exos_event_online_access') && l.includes(EV)), 'asked the access RPC');
}, { signedIn: true, mock: onlineTicketMock({ state: 'ready', join_url: 'https://stream.example.com/room', join_note: 'Passcode 4242', available_at: null }) });

await run('ticket holds the join link back until the reveal time', async (page) => {
  await page.goto(BASE + '/ticket/' + TICKET);
  await expectText(page, 'The join link appears here');
  assert(await page.getByRole('link', { name: /Join the event/ }).count() === 0, 'no link yet');
}, { signedIn: true, mock: onlineTicketMock({ state: 'later', join_url: null, join_note: null,
  available_at: new Date(Date.now() + 2 * 864e5).toISOString() }) });

// ── Price steps (mig 20261106130000): the event page shows the current step's
// price (exos_public_tiers.price already is it) and when it goes up; the mocked
// exos-checkout charges exos_tier_current_price x quantity, as the real one does,
// and that matches what the page showed. ──
const STEP = { price_cents: 2000, source: 'step', step_id: 'step-eb', step_name: 'Early bird', step_index: 1, step_count: 3,
  step_remaining: 37, step_ends_at: new Date(Date.now() + 10 * 864e5).toISOString(), next_price_cents: 2500, next_step_name: 'GA',
  door_price_cents: 3500 };
const stepCheckout = {};
await run('price steps: the event page shows the step price and when it goes up; the charge matches it', async (page) => {
  await stubStripe(page, stepCheckout);
  await page.goto(BASE + '/event/' + EV);
  await expectText(page, 'Fall Party');
  const nudge = page.getByTestId('price-step-nudge');
  await nudge.waitFor({ timeout: 8000 });
  const line = (await nudge.innerText()).replace(/\s+/g, ' ');
  assert(/goes up to \$25\.00/i.test(line) && /after 37 more are sold/i.test(line), 'the next price and when: ' + line);
  const shown = (await page.locator('p.disp.neon').first().innerText()).trim();
  const shownCents = Math.round(parseFloat(shown.replace(/[^0-9.]/g, '')) * 100);
  assert(shownCents === 2000, 'the event page shows the step price: ' + shown);
  assert(!/fee/i.test(await page.locator('p.disp.neon').first().innerText()), 'no fee line in the price');
  await payAsGuest(page, 'fan@example.com');
  await page.waitForURL(/checkout\.stripe\.com/, { timeout: 8000 });
  assert(stepCheckout.amount === shownCents * Number(stepCheckout.body.quantity),
    `the Stripe amount ${stepCheckout.amount} = shown ${shownCents} x ${stepCheckout.body.quantity}`);
}, { mock: {
  tables: { exos_public_price_steps: [{ tier_id: baseTables.exos_public_tiers[0].id, event_id: EV, price_step: STEP, door_price_cents: 3500 }] },
  fns: { 'exos-checkout': (body) => {
    stepCheckout.body = body;
    // The server's price: the current step (exos_tier_current_price), all-in (no fee rules here).
    stepCheckout.amount = STEP.price_cents * Number(body.quantity);
    return { body: { url: 'https://checkout.stripe.com/c/pay/cs_test_steps', session_id: 'cs_test_steps' } };
  } },
} });
// ── Checkout questions (mig 20261106110000): a guest answers the organizer's
// required questions, pays on the stubbed Stripe page, and the organizer's
// answers table shows what they answered. ──
const Q_SIZE = 'c0000000-0000-4000-8000-000000000001';
const Q_AGREE = 'c0000000-0000-4000-8000-000000000002';
const QUESTIONS = { questions: [
  { id: Q_SIZE, label: 'T-shirt size', help_text: null, kind: 'single_choice', options: ['S', 'M', 'L'], required: true,
    scope: 'ticket', tier_ids: null, max_length: null, min_choices: null, max_choices: null, min_value: null, max_value: null, sort_order: 0 },
  { id: Q_AGREE, label: "I agree to the venue's photo policy", help_text: null, kind: 'checkbox', options: [], required: true,
    scope: 'order', tier_ids: null, max_length: null, min_choices: null, max_choices: null, min_value: null, max_value: null, sort_order: 1 },
], party_sizes: {} };
const qCheckout = {};
// The attendees tab's other panels (refunds, guest lists, ...) read RPCs this
// test doesn't care about: answer them empty.
const withEmptyRpcs = (m) => ({ ...m, rpcs: new Proxy(m.rpcs, { get: (t, k) => (k in t ? t[k] : () => []) }) });
await run('checkout questions: required answers before paying, sent with the order, through Stripe and back', async (page, log) => {
  await stubStripe(page, qCheckout);
  await page.goto(BASE + '/event/' + EV);
  await expectText(page, 'A few questions from the organizer');
  // Buy without answering: inline errors, nothing sent.
  await page.getByRole('button', { name: /Buy Tickets/i }).first().click();
  await expectText(page, 'This answer is required.');
  const size = page.getByRole('group', { name: 'Ticket 1' });
  assert(await size.locator('[aria-invalid="true"]').count() > 0, 'the size field is marked invalid');
  assert(!log.some((l) => l.startsWith('fn exos-checkout')), 'no checkout before the answers');
  // Answer (labels are real labels: the radio by its option, the box by the question).
  await size.getByLabel('M', { exact: true }).check();
  await page.getByLabel("I agree to the venue's photo policy").check();
  await until(async () => (await page.getByText('This answer is required.').count()) === 0, 'errors clear once answered');
  await payAsGuest(page, 'fan@example.com');
  await page.waitForURL(/checkout\.stripe\.com/, { timeout: 8000 });
  const a = qCheckout.body?.answers;
  assert(a && a.order?.[Q_AGREE] === true && Array.isArray(a.tickets) && a.tickets.length === 1 && a.tickets[0][Q_SIZE] === 'M',
    'answers ride in the checkout request: ' + JSON.stringify(qCheckout.body));
  await page.locator('#pay').click();
  await page.waitForURL(/\/my-tickets/, { timeout: 8000 });
}, { mock: { ...checkoutFn(qCheckout), rpcs: { exos_public_event_questions: () => QUESTIONS } } });

await run('checkout questions: the organizer sees the buyer\'s answer in the report, with a CSV', async (page, log) => {
  await page.goto(BASE + '/dashboard/event/' + EV + '?tab=attendees');
  const panel = page.getByTestId('question-answers');
  await panel.waitFor({ timeout: 8000 });
  const text = (await panel.innerText()).replace(/\s+/g, ' ');
  assert(text.includes('T-shirt size') && text.includes('M') && text.includes('Ticket 1') && text.includes('Yes'), 'answers table: ' + text);
  assert(log.some((l) => l.startsWith('rpc exos_event_question_answers') && l.includes(EV)), 'asked the answers RPC');
  const { text: csv } = await download(page, () => panel.getByRole('button', { name: /Answers CSV/ }).click());
  const lines = firstLines(csv);
  assert(lines[0].startsWith('order_ref,ticket_id,ticket_number'), 'csv header ' + lines[0]);
  assert(lines.some((l) => l.includes('cs_test_iab') && l.includes('T-shirt size') && l.endsWith(',M,checkout,2026-11-05T12:00:00.000Z')), 'csv row: ' + lines.join(' | '));
}, { signedIn: true, mock: withEmptyRpcs(ownerMock({ tables: { exos_tickets: [], exos_discount_codes: [] }, rpcs: {
  // What exos_event_question_answers returns for the order above (its answers, as sent).
  exos_event_question_answers: () => [
    { answer_id: 'a1', question_id: Q_AGREE, order_ref: 'cs_test_iab', ticket_id: null, ticket_index: null, scope: 'order',
      label: "I agree to the venue's photo policy", current_label: "I agree to the venue's photo policy", kind: 'checkbox',
      value: qCheckout.body?.answers?.order?.[Q_AGREE] ?? null, display: qCheckout.body?.answers?.order?.[Q_AGREE] ? 'Yes' : '',
      source: 'checkout', attendee_name: null, tier_name: null, ticket_status: null, buyer_email: 'fan@example.com',
      question_archived: false, created_at: '2026-11-05T12:00:00Z' },
    { answer_id: 'a2', question_id: Q_SIZE, order_ref: 'cs_test_iab', ticket_id: TICKET, ticket_index: 1, scope: 'ticket',
      label: 'T-shirt size', current_label: 'T-shirt size', kind: 'single_choice',
      value: qCheckout.body?.answers?.tickets?.[0]?.[Q_SIZE] ?? null, display: qCheckout.body?.answers?.tickets?.[0]?.[Q_SIZE] ?? '',
      source: 'checkout', attendee_name: 'Ada', tier_name: 'GA', ticket_status: 'active', buyer_email: 'fan@example.com',
      question_archived: false, created_at: '2026-11-05T12:00:00Z' },
  ],
} })) });

// ── Conditional checkout questions (mig 20261107110000): "Guest name" shows
// only once "Bringing a guest?" is answered Yes, goes again on No, and its
// stale answer is left out of the request. ──
const Q_GUEST = 'd6c00000-0000-4000-8000-000000000001';
const Q_GUESTNAME = 'd6c00000-0000-4000-8000-000000000002';
const COND_QUESTIONS = { questions: [
  { id: Q_GUEST, label: 'Bringing a guest?', help_text: null, kind: 'single_choice', options: ['Yes', 'No'], required: true,
    scope: 'order', tier_ids: null, max_length: null, min_choices: null, max_choices: null, min_value: null, max_value: null, sort_order: 0,
    parent_question_id: null, parent_values: null },
  { id: Q_GUESTNAME, label: "Your guest's name", help_text: null, kind: 'text', options: [], required: true,
    scope: 'order', tier_ids: null, max_length: null, min_choices: null, max_choices: null, min_value: null, max_value: null, sort_order: 1,
    parent_question_id: Q_GUEST, parent_values: ['Yes'] },
], party_sizes: {} };
const condCheckout = {};
await run('conditional questions: the buyer sees B only after answering A, and B rides in the request only when shown', async (page, log) => {
  await stubStripe(page, condCheckout);
  await page.goto(BASE + '/event/' + EV);
  await expectText(page, 'Bringing a guest?');
  const guestName = page.getByLabel("Your guest's name");
  assert(await guestName.count() === 0, 'B is hidden before A is answered');
  await page.getByLabel('Yes', { exact: true }).check();
  await guestName.waitFor({ timeout: 5000 });
  // Required once shown: buying without it shows the error, nothing is sent.
  await page.getByRole('button', { name: /Buy Tickets/i }).first().click();
  await expectText(page, 'This answer is required.');
  assert(!log.some((l) => l.startsWith('fn exos-checkout')), 'no checkout while B is unanswered');
  await guestName.fill('Grace');
  // A changes to No: B goes, and its answer is left out.
  await page.getByLabel('No', { exact: true }).check();
  await until(async () => (await page.getByLabel("Your guest's name").count()) === 0, 'B hides again on No');
  await until(async () => (await page.getByText('This answer is required.').count()) === 0, 'no error left');
  await payAsGuest(page, 'fan@example.com');
  await page.waitForURL(/checkout\.stripe\.com/, { timeout: 8000 });
  const a = condCheckout.body?.answers;
  assert(a && a.order?.[Q_GUEST] === 'No' && !(Q_GUESTNAME in (a.order ?? {})),
    'only A rides in the request: ' + JSON.stringify(condCheckout.body?.answers));
}, { mock: { ...checkoutFn(condCheckout), rpcs: { exos_public_event_questions: () => COND_QUESTIONS } } });

// --- claude/exos-dice-leftovers (mig 20261108110000): walk-up questions ------
// A required question at the door: the sale waits for it, "Skip questions"
// sells anyway (the server logs the skip); answering it sells normally.
const WQ = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const walkupQSales = [];
const walkupQPos = (b) => {
  if (b.action === 'walkup_catalog') {
    const c = walkupPos(b);
    c.body.data.questions = [{ id: WQ, label: 'Company', kind: 'text', required: true, scope: 'order', options: [], tier_ids: null, hidden: false }];
    return c;
  }
  if (b.action === 'mint_walkup') {
    walkupQSales.push(b);
    return { body: { data: { ...walkupOrder(), questions_skipped: b.skip_questions === true } } };
  }
  return walkupPos(b);
};
await run('door: a required question at the door: Skip questions sells (logged), an answer sells normally', async (page, log) => {
  walkupSold = false;
  walkupQSales.length = 0;
  await page.goto(BASE + '/checkin/' + EV);
  await page.getByRole('tab', { name: 'Sell' }).click();
  await expectText(page, 'Door GA');
  await expectText(page, '1 required answer missing: Company');
  const sellBtn = page.getByRole('button', { name: /Take \$25\.00 · sell 1/ });
  assert(await sellBtn.isDisabled(), 'the sale waits for the required answer');
  await page.getByTestId('walkup-skip-questions').click();
  await expectText(page, 'Sold 1 × Door GA (questions skipped)');
  assert(walkupQSales.length === 1 && walkupQSales[0].skip_questions === true, 'the skip rides in the sale: ' + JSON.stringify(walkupQSales));
  // The next sale: answered, no skip.
  await page.getByTestId('walkup-questions-toggle').click();
  await page.getByLabel(/Company/).fill('Acme');
  await until(async () => !(await page.getByRole('button', { name: /Take \$25\.00 · sell 1/ }).isDisabled()), 'answered: the sale is on');
  assert(await page.getByTestId('walkup-skip-questions').count() === 0, 'no skip button once answered');
  await page.getByRole('button', { name: /Take \$25\.00 · sell 1/ }).click();
  await until(async () => walkupQSales.length === 2, 'the second sale went');
  assert(!('skip_questions' in walkupQSales[1]) && walkupQSales[1].answers?.order?.[WQ] === 'Acme',
    'answered sale: the answer, no skip: ' + JSON.stringify(walkupQSales[1]));
  assert(log.some((l) => l.startsWith('fn exos-pos') && l.includes('"skip_questions":true')), 'logged call');
}, { signedIn: true, mock: ownerMock({ rpcs: {
  exos_event_door_extras: () => ({ tables: [], ticket_access: {}, lists: [], guests: [] }),
  exos_event_checkin_roster: () => [], exos_event_checkin_roster_since: () => [], exos_event_door_roster: () => [],
  exos_server_time: () => new Date().toISOString(),
}, fns: { 'exos-pos': walkupQPos } }) });

// Undo an add-on scan from the scan log (mig 20261108110000): online, its own RPC.
const ADDON_PASS = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
await run('door: an add-on scan can be undone from the scan log', async (page, log) => {
  await page.goto(BASE + '/checkin/' + EV);
  const box = page.getByLabel('Search by name or pass ID');
  await box.waitFor({ timeout: 8000 });
  await box.fill(`A-${ADDON_PASS}:${UID}:${Math.floor(Date.now() / 30000)}:mac`);
  await box.press('Enter');
  await until(async () => log.some((l) => l.startsWith('rpc exos_check_in_ticket')), 'the add-on code went to the check-in');
  assert(!log.some((l) => l.includes('exos_get_ticket_for_scan')), 'an add-on code is not read as a ticket');
  await page.getByTestId('addon-undo').click();
  await page.getByLabel('Reason for undoing this check-in').fill('scanned the wrong wristband');
  await page.getByRole('button', { name: 'Undo', exact: true }).last().click();
  await expectText(page, 'Add-on scan undone');
  const call = log.find((l) => l.startsWith('rpc exos_undo_addon_check_in'));
  assert(call && call.includes(ADDON_PASS) && call.includes('scanned the wrong wristband'), 'the undo call: ' + call);
  assert(!log.some((l) => l.startsWith('rpc exos_undo_check_in')), 'not the ticket undo');
}, { signedIn: true, mock: ownerMock({ rpcs: {
  exos_event_door_extras: () => ({ tables: [], ticket_access: {}, lists: [], guests: [] }),
  exos_event_checkin_roster: () => [], exos_event_checkin_roster_since: () => [], exos_event_door_roster: () => [],
  exos_server_time: () => new Date().toISOString(),
  exos_check_in_ticket: () => ({ ok: true, reason: 'checked-in', kind: 'addon', pass_id: ADDON_PASS, addon_name: 'VIP lounge',
    check_in_at: new Date().toISOString(), verified: true }),
  exos_undo_addon_check_in: () => ({ ok: true, reason: 'undone', kind: 'addon', status: 'active', removed: 1 }),
} }) });

// The organizer dashboard's genre filter (mig 20261106140000's genres, here
// on the dashboard): only the picked genre's events stay listed.
await run('dashboard: the genre filter narrows the event list', async (page) => {
  await page.goto(BASE + '/dashboard');
  await expectText(page, 'Fall Party');
  const sel = page.getByTestId('dashboard-genre-filter');
  await sel.waitFor({ timeout: 8000 });
  const opts = await sel.locator('option').allTextContents();
  assert(opts.includes('All genres') && opts.includes('House') && opts.includes('Jazz'), 'options: ' + opts.join(', '));
  await sel.selectOption({ label: 'Jazz' });
  await expectText(page, 'Late Jazz');
  await until(async () => (await page.getByText('Fall Party', { exact: true }).count()) === 0, 'Fall Party (House) filtered out');
  await sel.selectOption({ label: 'All genres' });
  await expectText(page, 'Fall Party');
}, { signedIn: true, mock: ownerMock({ tables: { exos_events: [
  { ...EVENT_ROW, genres: ['House'] },
  { ...EVENT_ROW, id: '99999999-9999-4999-8999-999999999992', slug: 'late-jazz', name: 'Late Jazz', genres: ['Jazz'] },
] } }) });

// ── Group buy v2, "pay separately" (mig 20261108120000): a friend's seat page
// and the host's group page, against mocked RPCs. ──
const SEAT_TOKEN = 'ab'.repeat(16);
const GROUP = 'c7e00000-0000-4000-8000-000000000001';
const inMinutes = (m) => new Date(Date.now() + m * 60_000).toISOString();
const seatView = (over = {}) => ({
  seat_no: 2, seats: 4, state: 'waiting', mine: false, is_host: false, group_id: null,
  deadline: inMinutes(24), server_now: new Date().toISOString(), group_status: 'open', paid: 1, open: 3,
  event_id: EV, tier_id: TIER2,
  event: { name: 'Fall Party', starts_at: inMinutes(7 * 1440), venue_name: 'Elsewhere', image_url: null, currency: 'USD' },
  ...over,
});
const seatCheckout = {};
await run('group pay: a friend opens their seat link, sees price and time left, pays as a guest for exactly that seat', async (page, log) => {
  await stubStripe(page, seatCheckout);
  await page.goto(BASE + '/group-pay/seat/' + SEAT_TOKEN);
  await expectText(page, 'Seat 2 of 4');
  await expectText(page, '$50.00');
  await expectText(page, '1 of 4 paid');
  const t = await page.getByTestId('seat-countdown').innerText();
  assert(/2[34]:\d\d left to pay/.test(t), 'countdown: ' + t);
  const body = await page.locator('body').innerText();
  assert(!body.includes('@') && !/[0-9a-f]{32}/.test(body), 'nothing about other friends on the page');
  await page.getByLabel('Email for your ticket').fill('friend@example.com');
  await page.getByRole('button', { name: /Pay for my seat/ }).click();
  await page.waitForURL(/checkout\.stripe\.com/, { timeout: 8000 });
  const b = seatCheckout.body;
  assert(b?.group_seat === SEAT_TOKEN && b.quantity === 1 && b.tier_id === TIER2 && b.guest_email === 'friend@example.com', 'one seat, by its link: ' + JSON.stringify(b));
  assert(b.cancel_url.endsWith('/group-pay/seat/' + SEAT_TOKEN), 'cancel comes back to the seat');
  assert(log.some((l) => l.startsWith('rpc exos_group_seat_view')), 'read by the token');
}, { mock: { ...checkoutFn(seatCheckout), rpcs: { exos_group_seat_view: (b) => (b.p_token === SEAT_TOKEN ? seatView() : null) } } });

await run('group pay: a seat a friend is paying for, a released seat, and a bad link', async (page) => {
  await page.goto(BASE + '/group-pay/seat/' + SEAT_TOKEN);
  await expectText(page, 'A friend is paying for this seat right now');
  assert(await page.getByRole('button', { name: /Pay for my seat/ }).count() === 0, 'no pay button on a taken seat');
  await page.goto(BASE + '/group-pay/seat/' + 'cd'.repeat(16));
  await expectText(page, 'time ran out');
  await page.goto(BASE + '/group-pay/seat/not-a-token');
  await expectText(page, "isn't valid");
}, { mock: { rpcs: { exos_group_seat_view: (b) => (b.p_token === SEAT_TOKEN ? seatView({ state: 'paying' })
  : b.p_token === 'cd'.repeat(16) ? seatView({ state: 'released', group_status: 'closed', deadline: inMinutes(-2) }) : null) } } });

const coverCheckout = {};
await run('group pay: the host sees each seat live, texts a link, and covers the rest', async (page, log) => {
  await stubStripe(page, coverCheckout);
  await page.goto(BASE + '/group-pay/' + GROUP);
  await expectText(page, '1 of 3 paid');
  await expectText(page, 'Seat 3');
  const sms = await page.getByRole('link', { name: 'Text' }).first().getAttribute('href');
  assert(sms.startsWith('sms:') && decodeURIComponent(sms).includes('/group-pay/seat/' + 'ef'.repeat(16)), 'the text carries the seat link: ' + sms);
  page.once('dialog', (d) => d.accept());
  await page.getByRole('button', { name: /Cover the rest: 2 seats/ }).click();
  await page.waitForURL(/checkout\.stripe\.com/, { timeout: 8000 });
  const b = coverCheckout.body;
  assert(b?.group_cover === GROUP && b.quantity === 2 && !b.group_seat, 'the cover: ' + JSON.stringify(b));
  assert(log.some((l) => l.startsWith('rpc exos_group_buy_get')), 'the host read');
}, { signedIn: true, mock: { ...checkoutFn(coverCheckout), rpcs: { exos_group_buy_get: () => ({
  id: GROUP, event_id: EV, tier_id: TIER2, quantity: 3, deadline: inMinutes(20), status: 'open', server_now: new Date().toISOString(),
  can_cover: true, counts: { paid: 1, paying: 1, waiting: 1, released: 0 },
  seats: [
    { id: 's1', seat_no: 1, state: 'paid', path: '/group-pay/seat/' + 'aa'.repeat(16), paid_at: new Date().toISOString(), order_status: 'fulfilled' },
    { id: 's2', seat_no: 2, state: 'paying', path: '/group-pay/seat/' + 'ef'.repeat(16), paid_at: null, order_status: null },
    { id: 's3', seat_no: 3, state: 'waiting', path: '/group-pay/seat/' + 'bb'.repeat(16), paid_at: null, order_status: null },
  ] }) } } });

// Group pay 2 (mig 20261110110000): the host names a seat (saved on the seat
// row, host page only), and a price-step / timed group shows its locked price
// and slot.
const savedLabels = {};
const labelGroup = () => ({
  id: GROUP, event_id: EV, tier_id: TIER2, quantity: 3, deadline: inMinutes(20), status: 'open', server_now: new Date().toISOString(),
  can_cover: true, counts: { paid: 0, paying: 0, waiting: 3, released: 0 }, slot_id: '20261112T1030', unit_price_cents: 2000,
  seats: [
    { id: 's1', seat_no: 1, state: 'waiting', label: 'Sam', path: '/group-pay/seat/' + 'aa'.repeat(16), paid_at: null, order_status: null },
    { id: 's2', seat_no: 2, state: 'waiting', label: null, path: '/group-pay/seat/' + 'ef'.repeat(16), paid_at: null, order_status: null },
    { id: 's3', seat_no: 3, state: 'waiting', label: savedLabels.s3 ?? null, path: '/group-pay/seat/' + 'bb'.repeat(16), paid_at: null, order_status: null },
  ],
});
await run('group pay: the host names a seat; a locked step price and the slot show on the host page', async (page, log) => {
  await page.goto(BASE + '/group-pay/' + GROUP);
  await expectText(page, 'Seat 1: Sam');
  await expectText(page, 'at $20.00 each, entry 2026-11-12 10:30');
  const field = page.getByTestId('seat-label-3');
  assert(await field.getAttribute('aria-label') === 'Name for seat 3 (only you see this)', 'the field is labelled');
  await field.fill('  Jo  ');
  await field.press('Enter');
  await until(async () => log.some((l) => l.startsWith('PATCH exos_group_buy_seats')), 'the label is saved');
  const patch = log.find((l) => l.startsWith('PATCH exos_group_buy_seats'));
  assert(patch.includes('id=eq.s3') && patch.includes('{"label":"Jo"}'), 'saved on seat 3, trimmed: ' + patch);
  savedLabels.s3 = 'Jo';  // what the next poll of the group reads
  await expectText(page, 'Seat 3: Jo');
  assert(await page.getByRole('button', { name: /Cover the rest: 3 seats, \$60\.00/ }).count() === 1, 'the cover pays the locked price per seat');
}, { signedIn: true, mock: { rpcs: { exos_group_buy_get: labelGroup }, tables: { exos_group_buy_seats: [{ id: 's3', label: 'Jo' }] } } });

await run('group pay: a friend\'s seat page shows the locked price and the slot, never the host\'s names', async (page) => {
  await page.goto(BASE + '/group-pay/seat/' + SEAT_TOKEN);
  await expectText(page, 'Seat 2 of 4');
  await expectText(page, '$20.00');
  await expectText(page, 'Entry slot: 2026-11-12 10:30');
  const body = await page.locator('body').innerText();
  assert(!body.includes('$50.00') && !body.includes('Sam'), 'the locked price, and no labels');
}, { mock: { rpcs: { exos_group_seat_view: (b) => (b.p_token === SEAT_TOKEN ? seatView({ unit_price_cents: 2000, slot_id: '20261112T1030' }) : null) } } });

// claude/exos-org-audit: Org → Activity, the audit log (mig 20261109100000).
const auditRow = (id, over = {}) => ({
  id, at: '2026-11-09T15:04:22Z', event_id: EV, event_name: 'Fall Party', actor_uid: UID, actor_kind: 'user', actor_ref: null,
  actor_role: 'owner', actor_label: 'fan@example.com', action: 'tier.update', group: 'inventory', entity_type: 'tier',
  entity_id: TIER2, changes: { price: [40, 45] }, amount_cents: null, currency: null, reason: null, source: 'dashboard',
  request_id: null, ...over,
});
await run('org activity: the audit log, filters, and its CSV records an export', async (page, log) => {
  await page.goto(BASE + '/orgs/' + ORG + '/activity');
  await page.getByRole('heading', { name: 'Activity' }).waitFor({ timeout: 8000 });
  const table = page.getByRole('table', { name: 'Audit log' });
  await table.getByText('Tier: update').waitFor({ timeout: 8000 });
  const text = (await table.innerText()).replace(/\s+/g, ' ');
  assert(text.includes('price 40 → 45') && text.includes('fan@example.com (owner)'), 'tier row: ' + text);
  assert(text.includes('Refund: issue') && text.includes('$15.00') && text.includes('API key Box office (finance)') && text.includes('API'),
    'refund row: ' + text);
  // A filter asks the server again, with the group.
  await page.getByLabel('Kind').selectOption('money');
  await expectText(page, 'Refund: issue');
  // The money row is on the first page too: wait for the filtered call itself.
  await waitFor(() => log.some((l) => l.startsWith('rpc exos_org_audit_list') && l.includes('"p_group":"money"')), 'group filter sent');
  const { name, text: csv } = await download(page, () => page.getByRole('button', { name: /Export CSV/ }).click());
  assert(name.startsWith('activity-brooklyn-nights-'), 'file name ' + name);
  assert(firstLines(csv)[0].startsWith('id,at,event_id,event,actor_kind'), 'CSV header');
  for (let i = 0; i < 20 && !log.some((l) => l.startsWith('rpc exos_audit_export')); i++) await page.waitForTimeout(100);
  assert(log.some((l) => l.startsWith('rpc exos_audit_export') && l.includes('"p_kind":"audit"')), 'the export logs export.run');
}, { signedIn: true, mock: ownerMock({ rpcs: {
  exos_org_audit_list: (b) => (b.p_org_id !== ORG ? { __status: 403, __body: { code: '42501', message: 'not authorized' } } : {
    rows: b.p_group === 'money' ? [auditRow(9, { action: 'refund.issue', group: 'money', entity_type: 'order', entity_id: 'cs_1',
      actor_kind: 'api_key', actor_ref: 'k1', actor_role: 'finance', actor_label: 'API key Box office', changes: { scope: [null, 'order'] },
      amount_cents: 1500, currency: 'USD', source: 'api' })]
      : [auditRow(9, { action: 'refund.issue', group: 'money', entity_type: 'order', entity_id: 'cs_1', actor_kind: 'api_key',
          actor_ref: 'k1', actor_role: 'finance', actor_label: 'API key Box office', changes: { scope: [null, 'order'] },
          amount_cents: 1500, currency: 'USD', source: 'api' }), auditRow(8)],
    next_before: null, actors: [{ uid: UID, label: 'fan@example.com' }],
  }),
  exos_audit_export: () => true,
} }) });

// ── claude/exos-leftovers-9: "Add to Wallet" for add-on entry codes, and the
// event report's "N changes since publish" (mig 20261110120000). ──
const LO9_PASS = '99999999-9999-4999-8999-99999999a0a1';
const addonWalletMock = (probe) => ownerMock({
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
  rpcs: {
    exos_my_reschedule_offers: () => [], exos_ticket_access_needs: () => [],
    exos_my_addon_passes: () => [{ id: LO9_PASS, event_id: EV, addon_id: ADDON, addon_name: 'VIP lounge', unit_index: 1,
      status: 'active', check_in_at: null, owner_id: UID, barcode_secret: 'c2VjcmV0', event_name: 'Fall Party', starts_at: EVENT_ROW.starts_at }],
  },
  fns: {
    'exos-wallet/pass': () => ({ status: probe, body: probe === 503 ? { error: 'wallet not configured' } : { error: 'not your ticket' } }),
    'exos-wallet/addon-pass': () => ({ status: 409, body: { error: 'voided' } }),
  },
});

await run('add-on wallet button: shown for a usable add-on code when the wallet is set up; asks for that pass', async (page, log) => {
  await page.goto(BASE + '/ticket/' + TICKET);
  await page.getByTestId('addon-passes').waitFor({ timeout: 8000 });
  const btn = page.getByRole('button', { name: 'Add to Apple Wallet: VIP lounge' });
  await btn.waitFor({ timeout: 8000 });
  assert(await page.getByRole('button', { name: /Add to Google Wallet: VIP lounge/ }).count() === 0, 'iPhone gets Apple only');
  await btn.click();
  await expectText(page, 'This add-on was refunded');
  const call = log.find((l) => l.startsWith('fn exos-wallet/addon-pass'));
  assert(call && call.includes('"addon_pass_id":"' + LO9_PASS + '"') && call.includes('"kind":"apple"'), 'the add-on pass call: ' + call);
}, { signedIn: true, mock: addonWalletMock(403) });

await run('add-on wallet button stays hidden when exos-wallet is not configured (503)', async (page, log) => {
  await page.goto(BASE + '/ticket/' + TICKET);
  await page.getByTestId('addon-passes').waitFor({ timeout: 8000 });
  await waitFor(seen(log, 'fn exos-wallet/pass'), 'the wallet probe');
  await page.waitForTimeout(300);
  assert(await page.getByRole('button', { name: /Add to (Apple|Google) Wallet/ }).count() === 0, 'no wallet button at all');
  assert(!log.some((l) => l.startsWith('fn exos-wallet/addon-pass')), 'no add-on pass asked for');
}, { signedIn: true, mock: addonWalletMock(503) });

const AUDIT_SUMMARY = { event_id: EV, org_id: ORG, published_at: '2026-11-01T15:00:00Z', changes_since_publish: 3, changes_total: 5 };
await run('event report footer: changes since publish, linking to Activity for the event', async (page, log) => {
  await page.goto(BASE + '/dashboard/event/' + EV);
  const footer = page.getByTestId('event-audit-footer');
  await footer.waitFor({ timeout: 8000 });
  const text = (await footer.innerText()).replace(/\s+/g, ' ');
  assert(/3 changes since publish \(Nov 1, 2026\)/.test(text), 'footer: ' + text);
  assert(log.some((l) => l.startsWith('rpc exos_event_audit_summary') && l.includes(EV)), 'asked for this event');
  await footer.getByRole('link', { name: 'View activity' }).click();
  await page.getByRole('heading', { name: 'Activity' }).waitFor({ timeout: 8000 });
  assert(page.url().includes('/orgs/' + ORG + '/activity?event=' + EV), 'url: ' + page.url());
  await waitFor(() => log.some((l) => l.startsWith('rpc exos_org_audit_list') && l.includes('"p_event_id":"' + EV + '"')), 'filtered to the event');
}, { signedIn: true, mock: ownerMock({ ...reportMock, rpcs: { ...reportMock.rpcs,
  exos_event_audit_summary: (b) => (b.p_event_id === EV ? AUDIT_SUMMARY : { __status: 403, __body: { code: '42501', message: 'not authorized' } }),
  exos_org_audit_list: () => ({ rows: [auditRow(8)], next_before: null, actors: [] }),
} }) });

await run('event report footer stays hidden for a role that can\'t read the audit log (42501)', async (page, log) => {
  await page.goto(BASE + '/dashboard/event/' + EV);
  await page.locator('section', { has: page.getByRole('heading', { name: 'Money' }) }).waitFor({ timeout: 8000 });
  await waitFor(seen(log, 'rpc exos_event_audit_summary'), 'the summary call');
  await page.waitForTimeout(300);
  assert(await page.getByTestId('event-audit-footer').count() === 0, 'no footer');
}, { signedIn: true, mock: ownerMock({ ...reportMock, rpcs: { ...reportMock.rpcs,
  exos_event_audit_summary: () => ({ __status: 403, __body: { code: '42501', message: 'not authorized' } }),
} }) });

await browser.close();
for (const r of results) console.log((r.ok ? 'PASS ' : 'FAIL ') + r.name + (r.errors.length ? '\n   ' + r.errors.join('\n   ') : '') + (r.calls ? '\n   calls: ' + r.calls.join(' | ') : ''));

if (results.some((r) => !r.ok)) process.exit(1);
