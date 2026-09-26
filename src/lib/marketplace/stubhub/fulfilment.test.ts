import { describe, it, expect } from 'vitest';
import {
  FulfilmentError,
  attachETicketsRequest,
  confirmSaleRequest,
  mobileTransferRequest,
  saleDeadline,
  type MobileTransferProvider,
} from './fulfilment';

describe('sale request builders', () => {
  it('confirm', () => {
    expect(confirmSaleRequest()).toEqual({ confirmed: true });
  });

  it('mobile transfer validates the provider and trims the confirmation number', () => {
    expect(mobileTransferRequest('Ticketmaster', ' TM-123 ')).toEqual({
      confirmed: true,
      mobile_provider: 'Ticketmaster',
      transfer_confirmation_number: 'TM-123',
    });
    expect(() => mobileTransferRequest('Exos' as MobileTransferProvider, 'x')).toThrow(FulfilmentError);
    expect(() => mobileTransferRequest('AXS', '  ')).toThrow(/confirmation/);
  });

  it('attach e-tickets needs unique ids', () => {
    expect(attachETicketsRequest([1, 2])).toEqual({ confirmed: true, eticket_ids: [1, 2] });
    expect(() => attachETicketsRequest([])).toThrow(FulfilmentError);
    expect(() => attachETicketsRequest([1, 1])).toThrow(/duplicate/);
  });
});

describe('saleDeadline', () => {
  const now = new Date('2026-10-01T12:00:00Z');
  const sale = { confirm_by: '2026-10-01T18:00:00Z', ship_by: '2026-10-01T10:00:00Z' };

  it('asks for confirmation first', () => {
    expect(saleDeadline(sale, { confirmed: false, delivered: false }, now)).toEqual({
      action: 'confirm',
      due: new Date('2026-10-01T18:00:00Z'),
      overdue: false,
      remainingMs: 6 * 3600_000,
    });
  });

  it('then delivery, flagging overdue', () => {
    expect(saleDeadline(sale, { confirmed: true, delivered: false }, now)).toMatchObject({
      action: 'deliver',
      overdue: true,
      remainingMs: -2 * 3600_000,
    });
  });

  it('nothing once delivered; tolerates missing or bad dates', () => {
    expect(saleDeadline(sale, { confirmed: true, delivered: true }, now).action).toBe('none');
    expect(saleDeadline({ confirm_by: null, ship_by: 'garbage' }, { confirmed: false, delivered: false }, now)).toEqual({
      action: 'confirm',
      due: null,
      overdue: false,
      remainingMs: null,
    });
  });
});
