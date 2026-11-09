// Printed tickets (mig 20261105120000, docs/wallet.md "Printed tickets"):
// the QR encoder (decoded with zxing, a separate implementation, to prove it
// scans), the page and PDF renders, the door's local check of a P- code and
// the box-office request shapes.
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { QR_MAX_BYTES, qrMatrix, qrSvg } from '../../supabase/functions/_shared/print/qr';
import {
  PRINT_CODE_RE, printCodeTicketId, printFormat, printHtml, printPdf, ticketLines, whenText, type PrintTicket,
} from '../../supabase/functions/_shared/print/tickets';
import { parseDoorKeys, type DoorKeys } from '../../supabase/functions/_shared/doorKeys';
import {
  BoxError, capacityBody, clockBody, printTicketId, reservationFields, retagBody, shiftWindow,
} from '../../supabase/functions/_shared/api/boxOffice';
import { extractTicketIdFromAny, normalizeCodePrefix, verifyBarcode } from './barcode';
import { decideScan, parseDoorCode } from './door/decide';

const require = createRequire(import.meta.url);
// eslint-disable-next-line @typescript-eslint/no-require-imports
const z = require('html5-qrcode/third_party/zxing-js.umd.js');

function decode(m: boolean[][]): string {
  const scale = 4;
  const q = 4;
  const n = (m.length + 2 * q) * scale;
  const lum = new Uint8ClampedArray(n * n).fill(255);
  m.forEach((row, y) => row.forEach((dark, x) => {
    if (!dark) return;
    for (let dy = 0; dy < scale; dy++) for (let dx = 0; dx < scale; dx++) lum[((y + q) * scale + dy) * n + (x + q) * scale + dx] = 0;
  }));
  const bmp = new z.BinaryBitmap(new z.HybridBinarizer(new z.RGBLuminanceSource(lum, n, n)));
  return new z.QRCodeReader().decode(bmp).getText();
}

const TID = '11111111-2222-3333-4444-555555555555';
const CODE = `P-${TID}:abcdefghijklmnopqrstuv`;
const sha = (s: string) => createHash('sha256').update(s).digest('hex');

describe('QR encoder', () => {
  it('scans back to the same text (zxing), every version up to 6', () => {
    for (const s of ['A', 'Hello, world!', CODE, `P-${TID}:A-_09zZaa11bb22cc33dd44`, 'x'.repeat(60), 'é ticket ✓', 'y'.repeat(QR_MAX_BYTES)]) {
      expect(decode(qrMatrix(s))).toBe(s);
    }
  });
  it('a print code fits version 4 or less (33 modules); too long throws', () => {
    expect(qrMatrix(CODE).length).toBeLessThanOrEqual(33);
    expect(qrMatrix('A').length).toBe(21);
    expect(() => qrMatrix('z'.repeat(QR_MAX_BYTES + 1))).toThrow();
  });
  it('draws an SVG with a quiet zone and nothing remote', () => {
    const svg = qrSvg(CODE, 200);
    expect(svg).toMatch(/^<svg xmlns="http:\/\/www.w3.org\/2000\/svg" viewBox="0 0 (\d+) \1"/);
    expect(svg).not.toMatch(/href|<script|<image/);
  });
});

const T: PrintTicket = {
  ticket_id: TID, print_code: CODE, event_name: 'Rock & <Roll> Night', starts_at: '2026-11-08T01:00:00Z',
  timezone: 'America/New_York', venue_name: 'The "Room"', venue_location: 'Brooklyn, NY', tier_name: 'GA',
  attendee_name: "Sam O'Lee", seat_label: 'B12', org_name: 'Org', order_ref: 'cs_1',
};

describe('print renders', () => {
  it('parses ?format=', () => {
    expect(printFormat(null)).toBe('json');
    expect(printFormat('')).toBe('json');
    expect(printFormat(' PDF ')).toBe('pdf');
    expect(printFormat('html')).toBe('html');
    expect(printFormat('fgl')).toBeNull();
  });
  it('reads the ticket id from a print code, either case', () => {
    expect(PRINT_CODE_RE.test(CODE)).toBe(true);
    expect(printCodeTicketId(CODE)).toBe(TID);
    expect(printCodeTicketId('p' + CODE.slice(1))).toBe(TID);
    expect(printCodeTicketId(CODE + 'x')).toBeNull();
    expect(printCodeTicketId(`T-${TID}:x:1:y`)).toBeNull();
  });
  it('says when, in the event zone, and the lines in order', () => {
    expect(whenText(T)).toBe('Saturday, November 7, 2026 at 8:00 PM EST');
    expect(whenText({ starts_at: null, occurs_at_local: 'Doors 7pm' })).toBe('Doors 7pm');
    expect(whenText({ starts_at: null })).toBe('Date to be announced');
    expect(ticketLines(T)).toEqual(['Saturday, November 7, 2026 at 8:00 PM EST', 'The "Room", Brooklyn, NY', 'GA · Seat B12', "Admit: Sam O'Lee"]);
  });
  it('the page escapes every field and has no script or remote asset', () => {
    const html = printHtml([T, { ...T, ticket_id: 'x' }], 'Order <1>');
    expect(html).toContain('Rock &amp; &lt;Roll&gt; Night');
    expect(html).toContain('The &quot;Room&quot;');
    expect(html).toContain('Sam O&#39;Lee');
    expect(html).toContain('<title>Order &lt;1&gt;</title>');
    expect(html).not.toMatch(/<script|src=|href=|@import|url\(/i);
    expect(html.match(/<section class="ticket">/g)).toHaveLength(2);
    expect(html).toContain('<svg');
  });
  it('the PDF has one page a ticket and a correct cross-reference table', () => {
    const bytes = printPdf([T, T, T], 'Tickets');
    const text = Array.from(bytes, (b) => String.fromCharCode(b)).join('');
    expect(text.startsWith('%PDF-1.4\n')).toBe(true);
    expect(text.trimEnd().endsWith('%%EOF')).toBe(true);
    expect(text.match(/\/Type \/Page /g)).toHaveLength(3);
    expect(text).toContain('/Count 3');
    const xref = Number(/startxref\n(\d+)/.exec(text)![1]);
    expect(text.slice(xref, xref + 4)).toBe('xref');
    const offsets = [...text.slice(xref).matchAll(/^(\d{10}) 00000 n $/gm)].map((m) => Number(m[1]));
    offsets.forEach((o, i) => expect(text.slice(o, o + `${i + 1} 0 obj`.length)).toBe(`${i + 1} 0 obj`));
    // Each content stream's /Length is its byte length.
    for (const m of text.matchAll(/<< \/Length (\d+) >>\nstream\n/g)) {
      const start = m.index! + m[0].length;
      expect(text.slice(start + Number(m[1]), start + Number(m[1]) + 10)).toBe('\nendstream');
    }
    // Text is escaped: no raw parentheses from the name break the string.
    expect(text).toContain('(Rock & <Roll> Night) Tj');
  });
});

describe('the door and a print code', () => {
  const keys = (p?: string): DoorKeys => ({ d: {}, ...(p ? { p } : {}) });
  it('door keys carry p (a SHA-256), nothing else is taken', () => {
    expect(parseDoorKeys({ d: {}, p: sha(CODE) })?.p).toBe(sha(CODE));
    expect(parseDoorKeys({ d: {}, p: 'nope' })?.p).toBeUndefined();
  });
  it('checks a P- code against the hash it holds, lower-case prefix too', async () => {
    expect(await verifyBarcode(CODE, keys(sha(CODE)))).toMatchObject({ ok: true, ticketId: TID });
    expect(await verifyBarcode('p' + CODE.slice(1), keys(sha(CODE)))).toMatchObject({ ok: true, ticketId: TID });
    expect(await verifyBarcode(CODE, keys(sha('P-other')))).toMatchObject({ ok: false, reason: 'signature-mismatch' });
    expect(await verifyBarcode(CODE, keys())).toMatchObject({ ok: false, reason: 'no-key', ticketId: TID });
    expect(await verifyBarcode(CODE, 'a-secret')).toMatchObject({ ok: false, reason: 'no-key' });
    expect(await verifyBarcode(`P-${TID}:short`, keys(sha(CODE)))).toMatchObject({ ok: false, reason: 'malformed' });
  });
  it('a printed ticket refuses its app and wallet codes locally', async () => {
    const t = await verifyBarcode(`T-${TID}:owner:1:mac`, keys(sha(CODE)));
    expect(t).toMatchObject({ ok: false, reason: 'printed', ticketId: TID });
    expect(await verifyBarcode(`W-${TID}:owner:a1:mac`, keys(sha(CODE)))).toMatchObject({ ok: false, reason: 'printed' });
  });
  it('parses the ticket id out of a P- code; never a bare override', () => {
    expect(normalizeCodePrefix('p-abc')).toBe('P-abc');
    expect(extractTicketIdFromAny(CODE)).toBe(TID);
    expect(parseDoorCode(CODE, 'manual')).toMatchObject({ ticketId: TID, bare: false });
    expect(parseDoorCode(CODE, 'camera')).toMatchObject({ ticketId: TID, bare: false });
  });
  it('online, a printed refusal asks the server (the paper may be void since the download); offline it refuses', () => {
    const base = {
      code: parseDoorCode(`T-${TID}:o:1:m`, 'camera'), source: 'camera' as const, eventId: 'e1', now: 1_000,
      entry: { used: false }, gate: { opensAt: 0, testUntil: null }, recent: null, canOverride: false,
      verify: { ok: false, reason: 'printed' },
    };
    expect(decideScan({ ...base, network: 'online' })).toMatchObject({ action: 'ask-server' });
    expect(decideScan({ ...base, network: 'offline' })).toMatchObject({ action: 'reject', reason: 'invalid-barcode' });
  });
});

describe('box-office request shapes', () => {
  it('a print path names a ticket by id, app code or print code', () => {
    expect(printTicketId(TID.toUpperCase())).toBe(TID);
    expect(printTicketId(`T-${TID}:o:1:m`)).toBe(TID);
    expect(printTicketId(CODE)).toBe(TID);
    expect(printTicketId('123')).toBeNull();
    expect(printTicketId(undefined)).toBeNull();
  });
  it('reservations: wrapped or flat, the allowed fields, card readers and gifts refused', () => {
    expect(reservationFields({ membership_reservation: { email: 'a@x.com', first_name: 'A', membership_product_price_id: 12 } }))
      .toEqual({ email: 'a@x.com', first_name: 'A' });
    expect(reservationFields({ email: 'a@x.com', payment_method: 'check', payment_reference: '#9', device_name: 'Box' }))
      .toEqual({ email: 'a@x.com', payment_method: 'check', payment_reference: '#9', device_name: 'Box' });
    expect(() => reservationFields({})).toThrow(BoxError);
    expect(() => reservationFields({ email: 'a@x.com', payment_method: 'card' })).toThrow(/cash, check or external/);
    expect(() => reservationFields({ email: 'a@x.com', use_card_reader: true })).toThrow(/card readers/);
    expect(() => reservationFields({ email: 'a@x.com', gift: { email: 'b@x.com' } })).toThrow(/gift/);
    expect(() => reservationFields({ email: 7 })).toThrow(/text/);
  });
  it('capacity: a whole number or null', () => {
    expect(capacityBody({ capacity: 5 })).toEqual({ capacity: 5 });
    expect(capacityBody({ capacity: '7' })).toEqual({ capacity: 7 });
    expect(capacityBody({ capacity: null })).toEqual({ capacity: null });
    expect(() => capacityBody({})).toThrow(/required/);
    for (const v of [0, 1.5, -1, 'x', 2_000_000]) expect(() => capacityBody({ capacity: v })).toThrow(BoxError);
  });
  it('clock in / out and the report window', () => {
    expect(clockBody({ staff_shift: { event_id: TID.toUpperCase(), note: 'doors' } })).toEqual({ event_id: TID, device_id: null, note: 'doors' });
    expect(() => clockBody({ device_id: 'x' })).toThrow(/UUID/);
    expect(() => clockBody({ note: 'n'.repeat(301) })).toThrow(/300/);
    expect(shiftWindow(new URLSearchParams('from=2026-11-01&to=2026-11-05T12:00:00Z')))
      .toEqual({ from: '2026-11-01T00:00:00.000Z', to: '2026-11-05T12:00:00.000Z' });
    expect(shiftWindow(new URLSearchParams())).toEqual({ from: null, to: null });
    expect(() => shiftWindow(new URLSearchParams('from=yesterday'))).toThrow(/ISO/);
  });
  it('retag: a tag id or a name', () => {
    expect(retagBody({ tagged_item: { tag_id: TID } })).toEqual({ tag_id: TID, tag_name: null });
    expect(retagBody({ tag_attributes: { name: 'VIP' } })).toEqual({ tag_id: null, tag_name: 'VIP' });
    expect(retagBody({ tag_name: 'VIP' })).toEqual({ tag_id: null, tag_name: 'VIP' });
    expect(() => retagBody({})).toThrow(/tag_id/);
    expect(() => retagBody({ tag_id: 'x' })).toThrow(/UUID/);
  });
});
