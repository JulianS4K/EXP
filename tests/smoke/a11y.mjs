// Accessibility gate (WCAG 2.0 / 2.1 A + AA) for the buyer path and the Door
// app, with axe-core against the same mocked Supabase as smoke.mjs. Run by
// `npm run smoke` (tests/smoke/run.sh) after the smoke tests; CI's smoke job
// runs it. docs/pci.md "Accessibility conformance" lists what it covers.
//
// A page fails on any `serious` or `critical` violation; `moderate` and
// `minor` ones are printed so they can be fixed, but don't fail the run.
import { chromium, devices } from 'playwright';
import AxeBuilder from '@axe-core/playwright';
import { handle, EV, TIER, TIER2, ORG, UID, TICKET, EVENT_ROW, ownerTables, tables } from './mock.mjs';
import { KIOSK_CRED, kioskPos } from './mock.mjs'; // claude/exos-kiosk

const BASE = process.env.SMOKE_BASE || 'http://localhost:4174/bridge';
const TAGS = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'];
const BLOCKING = new Set(['serious', 'critical']);
// The only exclusion: Stripe's card iframe (Stripe Checkout / Embedded
// Checkout). It's Stripe's own document, outside our code and our PCI scope
// (docs/pci.md); Stripe publishes its own VPAT for it. Nothing else is skipped.
const EXCLUDE = ['iframe[src*="stripe.com"]'];

const browser = await chromium.launch(process.env.SMOKE_CHROMIUM ? { executablePath: process.env.SMOKE_CHROMIUM } : {});
const SESSION = {
  access_token: 'mock-access', refresh_token: 'mock-refresh', token_type: 'bearer', expires_in: 3600,
  expires_at: Math.floor(Date.now() / 1000) + 3600,
  user: { id: UID, aud: 'authenticated', role: 'authenticated',
    email: 'fan@example.com', email_confirmed_at: new Date().toISOString(), app_metadata: {}, user_metadata: {} },
};
const results = [];

// Contrast is judged on what the user ends up seeing, not on a frame of a
// fade-in: CI's faster headless Chromium reached the scan mid-animation
// (a dialog fading in, an overlay over the live ticket) and measured
// half-faded colors. Every animation and transition jumps to its end state.
const SETTLE_CSS = `*, *::before, *::after {
  animation-duration: 0s !important; animation-delay: 0s !important;
  transition-duration: 0s !important; transition-delay: 0s !important; }`;

async function scan(page, name, advisory) {
  await page.addStyleTag({ content: SETTLE_CSS });
  // JS animations (motion/react: the ticket card fades in from opacity 0)
  // ignore CSS. Wait for every Web Animation to finish and for inline
  // opacity to stop changing (up to 3 s) before judging contrast.
  await page.evaluate(async () => {
    const frame = () => new Promise((r) => requestAnimationFrame(() => r()));
    await Promise.race([
      Promise.all(document.getAnimations().map((a) => a.finished.catch(() => {}))),
      new Promise((r) => setTimeout(r, 3000)),
    ]);
    const snap = () => [...document.querySelectorAll('[style*="opacity"]')].map((el) => getComputedStyle(el).opacity).join(',');
    let prev = snap();
    for (let i = 0; i < 60; i++) {
      await frame(); await frame();
      const now = snap();
      if (now === prev) break;
      prev = now;
    }
  });
  const r = await new AxeBuilder({ page }).withTags(TAGS).exclude(EXCLUDE).analyze();
  // An advisory page (a known gap, docs/pci.md) prints its violations as
  // warnings until it's fixed, then moves to the blocking list.
  const blocking = advisory ? [] : r.violations.filter((v) => BLOCKING.has(v.impact));
  const other = r.violations.filter((v) => !blocking.includes(v));
  // `incomplete`: nodes axe can't decide alone (text over an image or a
  // gradient); listed for the manual review, not failed.
  results.push({ name: name + (advisory ? ' [advisory]' : ''), blocking, other, passes: r.passes.length, review: r.incomplete.reduce((n, v) => n + v.nodes.length, 0) });
}

async function check(name, fn, opts = {}) {
  const ctx = await browser.newContext({ ...devices[opts.device || 'iPhone 13'], reducedMotion: 'reduce' });
  // Freeze motion from the first paint: a transition already running when
  // scan() adds SETTLE_CSS keeps running (changing its duration doesn't stop
  // it), and the live ticket was caught under a half-faded overlay.
  await ctx.addInitScript((css) => {
    const add = () => { const s = document.createElement('style'); s.textContent = css; document.documentElement.appendChild(s); };
    if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add, { once: true });
  }, SETTLE_CSS);
  await ctx.route((u) => !u.href.startsWith('http://localhost') && !u.href.startsWith('https://mock.supabase.test/'), (r) => r.abort());
  await ctx.route('https://mock.supabase.test/**', (r) => handle(r, [], opts.mock));
  // The cookie banner already answered (it has its own scan below).
  if (!opts.freshConsent) await ctx.addInitScript(() => {
    localStorage.setItem('exos.consent.v2', JSON.stringify({ analytics: 'denied', advertising: 'denied' }));
  });
  if (opts.signedIn) await ctx.addInitScript((s) => localStorage.setItem('sb-mock-auth-token', JSON.stringify(s)), SESSION);
  const page = await ctx.newPage();
  try {
    await fn(page, (label) => scan(page, label ? `${name}: ${label}` : name, opts.advisory));
  } catch (e) {
    results.push({ name, error: String(e.message || e).split('\n')[0] });
    await page.screenshot({ path: 'tests/smoke/fail-a11y-' + name.replace(/\W+/g, '_') + '.png' }).catch(() => {});
  }
  await ctx.close();
}
const text = (page, t) => page.getByText(t, { exact: false }).first().waitFor({ timeout: 8000 });

// Owner fixtures (the Door app lists the user's orgs and events).
const ownerMock = (extra = {}) => ({
  tables: { ...ownerTables, ...(extra.tables || {}) },
  rpcs: { exos_list_api_keys: () => [], exos_org_comp_usage: () => 0, ...(extra.rpcs || {}) },
  fns: extra.fns,
});
const TICKET_ROW = {
  id: TICKET, event_id: EV, org_id: ORG, tier_id: TIER, tier_name: 'GA', buyer_id: UID, owner_id: UID, status: 'active',
  price_paid: 20, order_ref: 'cs_1', channel_source: 'direct', promoter_id: null, pending_transfer_id: null, transfer_id: null,
  voided_at: null, voided_by: null, voided_reason: null, released_at: null, check_in_at: null, last_reissue_at: null,
  created_at: '2026-09-20T12:00:00Z', updated_at: '2026-09-20T12:00:00Z', attendee_name: null, event: EVENT_ROW,
};
const ticketMock = ownerMock({
  tables: {
    exos_tickets: [TICKET_ROW],
    exos_ticket_barcode_secrets: [{ ticket_id: TICKET, barcode_secret: 'c2VjcmV0' }],
    exos_transfers: [], exos_event_saves: [],
  },
  rpcs: { exos_my_reschedule_offers: () => [], exos_ticket_access_needs: () => [], exos_my_invoices: () => [] },
  fns: { 'exos-wallet/pass': () => ({ status: 503, body: { error: 'wallet not configured' } }) },
});

// The same ticket two hours before the show: the rotating entry QR is live.
const soon = new Date(Date.now() + 2 * 3600e3).toISOString();
const SOON_EVENT = { ...EVENT_ROW, starts_at: soon, occurs_at_local: soon.slice(0, 19) };
const liveTicketMock = { ...ticketMock, tables: { ...ticketMock.tables,
  exos_events: [SOON_EVENT], exos_public_events: [{ ...tables.exos_public_events[0], starts_at: soon, occurs_at_local: soon.slice(0, 19) }],
  exos_tickets: [{ ...TICKET_ROW, event: SOON_EVENT }] } };

// Reserved seating (mig 20261030140000): VIP is seated, two rows of four.
const seat = (row, n, avail = true, accessible = false) => ({
  seat_id: `orch-${row}-${n}`, section_id: 'orch', section: 'Orchestra', row_label: row, number: String(n),
  label: `Orchestra · Row ${row} · Seat ${n}`, tier_id: TIER2, x: 100 + n * 30, y: row === 'A' ? 150 : 180,
  accessible, companion: false, obstructed: false, available: avail,
});
const seatingMock = { rpcs: {
  exos_public_event_seating: () => ({
    map: { width: 600, height: 300, stage: { x: 150, y: 20, w: 300, h: 50, label: 'Stage' },
      sections: [{ id: 'orch', name: 'Orchestra', kind: 'seated', x: 0, y: 0 }] },
    seated_tier_ids: [TIER2], seat_count: 8,
  }),
  exos_public_event_seats: () => [1, 2, 3, 4].flatMap((n) => [seat('A', n, n !== 2, n === 1), seat('B', n)]),
} };

// Stripe Checkout, stubbed as in smoke.mjs: "Pay" goes back to the success URL.
const checkout = {};
const checkoutMock = { fns: { 'exos-checkout': (body) => {
  checkout.back = body.success_url.replace('{CHECKOUT_SESSION_ID}', 'cs_test_a11y');
  return { body: { url: 'https://checkout.stripe.com/c/pay/cs_test_a11y', session_id: 'cs_test_a11y' } };
} } };

// ── Buyer path ──────────────────────────────────────────────────────────────
await check('event page (/e/:slug, phone)', async (page, run) => {
  await page.goto(BASE + '/e/fall-party');
  await page.waitForURL(/\/event\//, { timeout: 8000 });
  await text(page, 'Four rooms of house till late.');
  await run();
});

await check('event page (desktop)', async (page, run) => {
  await page.goto(BASE + '/event/' + EV);
  await text(page, 'Four rooms of house till late.');
  // WCAG 2.4.1: the first Tab stop is the skip link, and it lands in <main>.
  await page.keyboard.press('Tab');
  const skip = await page.evaluate(() => document.activeElement?.textContent?.trim());
  if (skip !== 'Skip to content') throw new Error('first Tab stop is not the skip link: ' + skip);
  await page.keyboard.press('Enter');
  const into = await page.evaluate(() => document.activeElement?.id);
  if (into !== 'main') throw new Error('skip link did not move focus to main: ' + into);
  await run();
}, { device: 'Desktop Chrome' });

await check('cookie banner', async (page, run) => {
  await page.goto(BASE + '/event/' + EV);
  await page.getByRole('dialog').filter({ hasText: 'analytics and advertising cookies' }).waitFor({ timeout: 8000 });
  await run();
}, { freshConsent: true });

await check('seat picker', async (page, run) => {
  await page.goto(BASE + '/event/' + EV);
  await text(page, 'Fall Party');
  await page.getByRole('button', { name: /VIP/ }).first().click();
  await page.getByTestId('seat-picker').waitFor({ timeout: 8000 });
  await run('map');
  await page.getByRole('button', { name: 'List', exact: true }).click();
  // Keyboard: a seat in the list view is a button; Enter picks it.
  const first = page.getByTestId('seat-list').getByRole('button').first();
  await first.focus();
  await page.keyboard.press('Enter');
  await page.getByTestId('seat-selection').waitFor({ timeout: 5000 });
  await run('list, one seat picked');
}, { mock: seatingMock, device: 'Desktop Chrome' });

await check('checkout (guest email dialog)', async (page, run) => {
  await page.goto(BASE + '/checkout?products=' + TIER2 + ':2');
  await page.waitForURL(/\/event\//, { timeout: 8000 });
  await text(page, 'Fall Party');
  await page.getByRole('button', { name: /Buy Tickets/i }).first().click();
  await page.getByRole('dialog').filter({ hasText: 'Where should we send your tickets?' }).waitFor({ timeout: 8000 });
  await run();
}, { mock: checkoutMock });

await check('checkout (back from Stripe)', async (page, run) => {
  await page.route('https://checkout.stripe.com/**', (r) => r.fulfill({ contentType: 'text/html',
    body: `<!doctype html><html lang="en"><title>Stripe</title><main><a id="pay" href="${checkout.back}">Pay</a></main></html>` }));
  await page.goto(BASE + '/event/' + EV);
  await text(page, 'Fall Party');
  await page.getByRole('button', { name: /Buy Tickets/i }).first().click();
  const dlg = page.getByRole('dialog').filter({ hasText: 'Where should we send your tickets?' });
  await dlg.getByLabel('Email').fill('fan@example.com');
  await dlg.getByRole('button', { name: 'Continue to payment' }).click();
  await page.waitForURL(/checkout\.stripe\.com/, { timeout: 8000 });
  await page.locator('#pay').click();
  await page.waitForURL(/\/my-tickets/, { timeout: 8000 });
  await page.waitForLoadState('networkidle');
  await run();
}, { mock: checkoutMock });

await check('my tickets', async (page, run) => {
  await page.goto(BASE + '/my-tickets');
  await text(page, 'Fall Party');
  await run();
}, { signedIn: true, mock: ticketMock });

await check('ticket view', async (page, run) => {
  await page.goto(BASE + '/ticket/' + TICKET);
  await text(page, 'Fall Party');
  // Reduced motion (this context asks for it): the ticket card's fade-in is
  // skipped, so nothing is part-transparent the moment it shows up.
  const faded = await page.evaluate(() => [...document.querySelectorAll('[style*="opacity"]')]
    .filter((el) => parseFloat(getComputedStyle(el).opacity) < 1).map((el) => el.className.toString().slice(0, 60)));
  if (faded.length) throw new Error('reduced motion: content still fading in: ' + faded.join(' | '));
  await page.waitForLoadState('networkidle');
  await run();
}, { signedIn: true, mock: ticketMock });

await check('ticket view (entry QR live)', async (page, run) => {
  await page.goto(BASE + '/ticket/' + TICKET);
  await page.getByRole('img', { name: /Entry QR code/ }).waitFor({ timeout: 8000 });
  await run();
}, { signedIn: true, mock: liveTicketMock });

await check('transfer a ticket', async (page, run) => {
  await page.goto(BASE + '/transfer/' + TICKET);
  await page.getByLabel('recipient email').waitFor({ timeout: 8000 });
  await run();
}, { signedIn: true, mock: ticketMock });

// ── Apps suite landing pages (public, signed out) ─────────────────────────
for (const [id, headline, device] of [
  ['door', 'The free door app for any event, even with no signal.', 'iPhone 13'],
  ['events', 'Create an event page. Ticket sales open at launch.', 'Desktop Chrome'],
  ['promote', 'Get people to your event, and see who brought them.', 'iPhone 13'],
  ['money', 'Your sales, settlements and books in one place.', 'Desktop Chrome'],
]) {
  await check(`app landing (/apps/${id})`, async (page, run) => {
    await page.goto(BASE + '/apps/' + id);
    await page.getByRole('heading', { level: 1, name: headline }).waitFor({ timeout: 8000 });
    await run();
  }, { device });
}

// ── Neighborhood pages + unfollow (mig 20261111110000) ─────────────────────
await check('neighborhoods index (/nyc)', async (page, run) => {
  await page.goto(BASE + '/nyc');
  await page.getByRole('heading', { name: 'Queens' }).waitFor({ timeout: 8000 });
  await run();
});

await check('neighborhood page (/nyc/bushwick, phone)', async (page, run) => {
  await page.goto(BASE + '/nyc/bushwick');
  await text(page, 'Fall Party');
  await run();
});

await check('neighborhood page (desktop)', async (page, run) => {
  await page.goto(BASE + '/nyc/bushwick');
  await text(page, 'Fall Party');
  await run();
}, { device: 'Desktop Chrome' });

await check('unfollow link', async (page, run) => {
  await page.goto(BASE + '/unfollow?t=' + 'a'.repeat(64));
  await text(page, 'Stop following this organizer?');
  await run();
});

// ── Door app ────────────────────────────────────────────────────────────────
await check('door app (signed out)', async (page, run) => {
  await page.goto(BASE + '/door');
  await text(page, 'The free door app for any event.');
  await run();
});

await check('door app (signed in)', async (page, run) => {
  await page.goto(BASE + '/door');
  await text(page, 'Your doors');
  await page.waitForLoadState('networkidle');
  await run();
}, { signedIn: true, mock: ownerMock() });

// The staff scanner: the Tickets tab (scan box, counts, scan log, refused
// scans), then the Guest list tab.
await check('door scanner (/checkin)', async (page, run) => {
  await page.goto(BASE + '/checkin/' + EV);
  await page.getByPlaceholder('Scan or type a ticket code').or(page.getByText(/^Guest list/).first()).first().waitFor({ timeout: 8000 });
  await page.waitForLoadState('networkidle');
  await run('tickets');
  await page.getByRole('tab', { name: /^Guest list/ }).click();
  await page.getByRole('tab', { name: /^Guest list/, selected: true }).waitFor({ timeout: 5000 });
  await page.waitForLoadState('networkidle');
  await run('guest list');
}, { signedIn: true, mock: ownerMock({ rpcs: {
  exos_event_door_extras: () => ({ tables: [], ticket_access: {}, lists: [], guests: [] }),
  exos_event_checkin_roster: () => [], exos_event_checkin_roster_since: () => [], exos_event_door_roster: () => [],
  exos_server_time: () => new Date().toISOString(),
} }) });

// Kiosk mode (mig 20261113100000): the self-serve screen, blocking. Big touch
// targets and visible focus are its own rules (src/views/Kiosk.tsx); axe
// checks names, contrast, labels and the PIN dialog.
await check('kiosk screen', async (page, run) => {
  await page.addInitScript((cred) => localStorage.setItem('exos.kiosk.v1', JSON.stringify(cred)), KIOSK_CRED);
  await page.goto(BASE + '/kiosk');
  await text(page, 'County Fair');
  await run('pick');
  await page.getByRole('radio', { name: /Adult/ }).click();
  await page.getByRole('button', { name: 'Continue' }).click();
  await page.getByLabel(/ZIP code/).waitFor({ timeout: 8000 });
  await run('questions');
  await page.getByLabel(/ZIP code/).fill('86001');
  await page.getByRole('button', { name: /by card/ }).click();
  await text(page, 'Paid. Here are your tickets.');
  await page.getByRole('img', { name: /Ticket QR code/ }).waitFor({ timeout: 8000 });
  await run('paid');
  // Focus is visible on the kiosk's buttons (a ring, not the browser default only).
  await page.getByRole('button', { name: 'Done' }).focus();
  await page.keyboard.press('Tab');
  await page.keyboard.press('Shift+Tab');
  const ring = await page.getByRole('button', { name: 'Done' }).evaluate((el) => getComputedStyle(el).boxShadow);
  if (!ring || ring === 'none') throw new Error('no visible focus ring on the kiosk button');
  const small = await page.evaluate(() => [...document.querySelectorAll('main button')]
    .filter((b) => { const r = b.getBoundingClientRect(); return r.width > 0 && (r.height < 48 || r.width < 48); })
    .map((b) => b.textContent?.trim() || b.getAttribute('aria-label')));
  if (small.length) throw new Error('kiosk touch targets under 48 px: ' + small.join(', '));
  await page.getByRole('button', { name: 'Staff' }).click();
  await page.getByLabel('Admin PIN').waitFor({ timeout: 5000 });
  await run('staff PIN');
}, { mock: { fns: { 'exos-pos': kioskPos({}) } } });

await browser.close();

let failed = false;
const fmt = (v) => `   [${v.impact}] ${v.id}: ${v.help} (${v.nodes.length})\n` +
  v.nodes.slice(0, 12).map((n) => `      ${n.target.join(' ')}${n.failureSummary ? ' :: ' + n.failureSummary.split('\n').slice(1).join(' ').trim() : ''}` +
    `\n        ${n.html.slice(0, 160)}`).join('\n');
for (const r of results) {
  if (r.error) { failed = true; console.log(`FAIL a11y ${r.name}\n   ${r.error}`); continue; }
  if (r.blocking.length) failed = true;
  const status = r.blocking.length ? 'FAIL' : r.other.some((v) => BLOCKING.has(v.impact)) ? 'WARN' : 'PASS';
  console.log(`${status} a11y ${r.name} (${r.passes} rules pass, ${r.review} nodes for manual review)`);
  for (const v of r.blocking) console.log(fmt(v));
  for (const v of r.other) console.log(fmt(v).replace(/^ {3}\[/, '   warn ['));
}
if (failed) process.exit(1);
