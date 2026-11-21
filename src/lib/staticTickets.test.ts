// Holder-side static tickets (mig 20261121153000): which tickets can show /
// save their code, the PDF the holder saves (the email's writer), and the
// organizer's door-code line, generated from the free-tier cutoff.
import { describe, expect, it } from 'vitest';
import { FREE_TIER_MAX_CAPACITY } from '../../supabase/functions/_shared/platformFee.ts';
import { staticCode } from '../../supabase/functions/_shared/staticCodes.ts';
import { doorCodeTierText, pdfFileName, staticCodeUsable, staticTicketsPdfFor } from './staticTickets';
import type { Ticket } from '../types';

const UID = '0b5e1c2a-0000-4000-8000-0000000000c1';
const ticket = (over: Partial<Ticket> = {}): Ticket => ({
  id: '0b5e1c2a-0000-4000-8000-000000000001', eventId: 'e1', buyerId: UID, ownerId: UID, organizerId: '',
  status: 'active', barcodeValue: '', barcodeSecret: 'sek-vector', codeMode: 'static', tierName: 'GA', ...over,
} as Ticket);
const event = { title: 'Basement Show', date: { toDate: () => new Date('2026-12-05T01:00:00Z') }, timezone: 'America/New_York', location: 'Brooklyn, NY' } as never;
const pdfText = (b: Uint8Array) => Array.from(b, (c) => String.fromCharCode(c)).join('');

describe('staticTickets', () => {
  it('only the holder\'s live static tickets can show or save the code', () => {
    expect(staticCodeUsable(ticket(), UID)).toBe(true);
    expect(staticCodeUsable(ticket({ codeMode: 'rotating' }), UID)).toBe(false);
    expect(staticCodeUsable(ticket({ status: 'used' }), UID)).toBe(false);
    expect(staticCodeUsable(ticket({ pendingTransferId: 'tr1' }), UID)).toBe(false);
    expect(staticCodeUsable(ticket({ ownerId: 'someone-else' }), UID)).toBe(false);
    expect(staticCodeUsable(ticket({ barcodeSecret: undefined }), UID)).toBe(false);
  });

  it('the saved PDF carries the code and the page fields; nothing for rotating tickets', async () => {
    const code = await staticCode(ticket().id, UID, 'sek-vector');
    const pdf = await staticTicketsPdfFor([ticket(), ticket({ id: 'x', codeMode: 'rotating' })], event, UID, 'Sam Fan');
    expect(pdf).not.toBeNull();
    const text = pdfText(pdf!);
    expect(text.startsWith('%PDF-1.4')).toBe(true);
    expect(text).toContain(code.slice(0, 39));
    expect(text).toContain(code.slice(39));
    expect(text).toContain('Basement Show');
    expect(text).toContain('Admit: Sam Fan');
    expect(text).toContain('the first scan wins');
    expect((text.match(/\/Type \/Page /g) ?? []).length).toBe(1);
    expect(await staticTicketsPdfFor([ticket({ codeMode: 'rotating' })], event, UID)).toBeNull();
    expect(pdfFileName('Basement Show!')).toBe('tickets-basement-show.pdf');
  });

  it('the organizer\'s door-code line comes from the cutoff, never a literal', () => {
    const cut = FREE_TIER_MAX_CAPACITY;
    const free = doorCodeTierText(cut, true);
    const paid = doorCodeTierText(cut + 1, true);
    expect(free).toContain('static QR');
    expect(free).toContain(`paid tier (${cut + 1} or more)`);
    expect(paid).toContain('rotating anti-screenshot');
    expect(paid).toContain(`${cut + 1} or more`);
    // A different cutoff (the operator's setting) moves the copy with it.
    expect(doorCodeTierText(149, true, 149)).toContain('paid tier (150 or more)');
    expect(doorCodeTierText(150, true, 149)).toContain('rotating');
  });
});
