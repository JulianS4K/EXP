import { describe, expect, it } from 'vitest';
import { orderPermissions } from './orderDesk';
import { canPrintOrder, parsePrintState, PRINTED_TICKET_TEXT, printSummary, printWarning } from './printOrder';

describe('printing an order (Orders page)', () => {
  it('owners and managers print issued orders', () => {
    const staff = (role: string | null, admin = false) => orderPermissions(role, admin).edit;
    expect(canPrintOrder({ status: 'fulfilled' }, staff('owner'))).toBe(true);
    expect(canPrintOrder({ status: 'partially_refunded' }, staff('manager'))).toBe(true);
    expect(canPrintOrder({ status: 'fulfilled' }, staff('scanner'))).toBe(false);
    expect(canPrintOrder({ status: 'fulfilled' }, staff('finance'))).toBe(false);
    expect(canPrintOrder({ status: 'refunded' }, staff('owner'))).toBe(false);
    expect(canPrintOrder({ status: 'pending' }, staff(null, true))).toBe(false);
    expect(canPrintOrder({ status: 'fulfilled' }, staff(null, true))).toBe(true);
  });
  it('says what printing does and what happened', () => {
    expect(printWarning('Sam')).toMatch(/admits once.*app and wallet codes/);
    expect(printSummary({ printed: 2, skipped: [] })).toBe('Printed 2 tickets.');
    expect(printSummary({ printed: 1, skipped: [{ ticket_id: 'a', reason: 'used' }, { ticket_id: 'b', reason: 'used' }] }))
      .toBe('Printed 1 ticket. 2 skipped (used).');
    expect(printSummary({ printed: 0, skipped: [{ ticket_id: 'a', reason: 'in-transfer' }] }))
      .toBe('No ticket on this order can be printed. 1 skipped (in-transfer).');
  });
  it('the ticket page notice and the print state', () => {
    expect(PRINTED_TICKET_TEXT).toBe('This ticket was printed. Use the paper ticket, or void it to use your phone.');
    expect(parsePrintState({ printed: true, printed_at: '2026-11-05T20:00:00Z' })).toEqual({ printed: true, printedAt: '2026-11-05T20:00:00Z' });
    expect(parsePrintState(null)).toEqual({ printed: false, printedAt: null });
    expect(parsePrintState({ printed: 'yes' })).toEqual({ printed: false, printedAt: null });
  });
});
