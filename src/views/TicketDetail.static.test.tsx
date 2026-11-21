// @vitest-environment jsdom
// My Tickets → a pass (mig 20261121153000): a static-code ticket shows its one
// S- code (no countdown, no 24-hour lock) and the PDF download; a rotating
// ticket keeps the 30-second countdown and offers no PDF.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { staticCode } from '../../supabase/functions/_shared/staticCodes.ts';

const UID = '0b5e1c2a-0000-4000-8000-0000000000c1';
const TID = '0b5e1c2a-0000-4000-8000-000000000001';

const h = vi.hoisted(() => ({ ticket: null as Record<string, unknown> | null, event: null as Record<string, unknown> | null }));

vi.mock('../lib/supabase', () => ({ supabase: {} }));
vi.mock('../context/AuthContext', () => ({
  useAuth: () => ({ user: { uid: '0b5e1c2a-0000-4000-8000-0000000000c1', email: 'fan@x.com', displayName: 'Sam Fan' } }),
}));
vi.mock('../context/ToastContext', () => ({ useToast: () => ({ toast: vi.fn() }) }));
vi.mock('../context/LanguageContext', () => ({ useT: () => (k: string) => k }));
vi.mock('../lib/tickets', () => ({
  getTicket: vi.fn(async () => ({ ...h.ticket, event: h.event })),
  listMyTicketsForEvent: vi.fn(async () => [h.ticket]),
  setTicketAttendee: vi.fn(),
  syncServerClock: vi.fn(async () => undefined),
}));
vi.mock('../lib/passCache', () => ({ loadPasses: () => null, savePasses: () => undefined }));
vi.mock('../lib/referrals', () => ({ myReferralCode: async () => null, myReferralStats: async () => null }));
vi.mock('../hooks/useShareTags', () => ({ useShareTags: () => [] }));
vi.mock('../components/TicketLocation', () => ({ default: () => null }));
vi.mock('../components/TicketAccessNeeds', () => ({ default: () => null }));
vi.mock('../components/RefundAskCard', () => ({ default: () => null }));
vi.mock('../components/AddonPassesCard', () => ({ default: () => null }));
vi.mock('../components/SmsOptIn', () => ({ default: () => null }));
vi.mock('../components/AddToCalendar', () => ({ default: () => null }));
vi.mock('../components/WalletButtons', () => ({ default: () => null }));
vi.mock('../components/ShareModal', () => ({ default: () => null }));
vi.mock('../components/OrganizerUpdates', () => ({ default: () => null }));
vi.mock('../components/RescheduleNotice', () => ({ default: () => null }));
vi.mock('../components/ReferralProgress', () => ({ default: () => null }));
vi.mock('../components/TicketOnlineAccess', () => ({ default: () => null }));
vi.mock('../components/TicketMatchedGroup', () => ({ default: () => null }));
vi.mock('../components/seating/TicketSeats', () => ({ default: () => null }));
vi.mock('../components/TicketPrintedNotice', () => ({ default: () => null }));

import TicketDetail from './TicketDetail';

const ts = (d: Date) => ({ toDate: () => d });

function setUp(codeMode: 'static' | 'rotating', startsInHours: number) {
  h.event = {
    id: 'e1', title: 'Basement Show', date: ts(new Date(Date.now() + startsInHours * 3600_000)),
    location: 'Brooklyn, NY', timezone: 'America/New_York', category: 'Music', orgId: 'o1',
  };
  h.ticket = {
    id: TID, eventId: 'e1', ownerId: UID, buyerId: UID, status: 'active', barcodeSecret: 'sek-vector',
    tierName: 'GA', pendingTransferId: null, codeMode,
  };
}

function renderPass() {
  return render(
    <MemoryRouter initialEntries={[`/ticket/${TID}`]}>
      <Routes><Route path="/ticket/:id" element={<TicketDetail />} /></Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.stubGlobal('matchMedia', (q: string) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }));
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe('TicketDetail: static-code tickets', () => {
  it('shows the one static code, no countdown, and the PDF download, days before the show', async () => {
    setUp('static', 72);
    renderPass();
    const code = await staticCode(TID, UID, 'sek-vector');
    expect(await screen.findByLabelText('Entry code')).toHaveProperty('textContent', code);
    expect(screen.getByRole('img', { name: /Entry QR code/ })).toBeTruthy();
    expect(screen.queryByRole('timer')).toBeNull();
    expect(screen.queryByText('ticket.locked')).toBeNull();
    expect(screen.getByRole('button', { name: 'Download PDF ticket' })).toBeTruthy();
    expect(screen.getByText(/This code doesn't change/)).toBeTruthy();
  });

  it('a rotating ticket keeps the countdown and has no PDF', async () => {
    setUp('rotating', 2);
    renderPass();
    await waitFor(() => expect(screen.getByRole('timer')).toBeTruthy());
    expect(screen.queryByLabelText('Entry code')).toBeNull();
    expect(screen.queryByRole('button', { name: /Download PDF/ })).toBeNull();
  });

  it('a rotating ticket days out is still locked', async () => {
    setUp('rotating', 72);
    renderPass();
    expect(await screen.findByText('ticket.locked')).toBeTruthy();
  });
});
