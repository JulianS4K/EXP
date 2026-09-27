// Gametime order handling: request bodies, pure.
//
// Gametime's flow (API docs + onboarding guide): a sale arrives (webhook and
// email), the seller checks the purchase STATUS (a `rejected` one is only
// there for reconciliation: stop), confirms it (POST /confirm, "only if
// delivery is guaranteed") or rejects it, then fulfils it the way the
// listing said. Exos lists as mobile transfer, so fulfilment is
// POST /confirm_transfer with the transfer URLs: one Exos claim link per
// ticket (/claim/{transferId}); the buyer claims them into any Exos account.
// transfer_type `generic`: the transfer isn't on Ticketmaster, AXS, ...

import type { FormFields } from './transport.ts';

export class GametimeFulfilmentError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'GametimeFulfilmentError';
  }
}

/** POST /confirm body: optional seat numbers (Exos: the internal GA seats). */
export function confirmBody(seats?: ReadonlyArray<string | number>): { seats?: string[] } | undefined {
  if (!seats?.length) return undefined;
  return { seats: seats.map((s) => String(s)) };
}

export interface TransferConfirmation {
  orderNumber: string;
  urls: string[];
  quantity: number;
}

/** POST /confirm_transfer form: transfer_url[] once per ticket, transfer_type generic. */
export function transferConfirmationForm(t: TransferConfirmation): FormFields {
  if (!t.orderNumber.trim()) throw new GametimeFulfilmentError('order number is required');
  const urls = t.urls.map((u) => u.trim()).filter(Boolean);
  if (!urls.length) throw new GametimeFulfilmentError('at least one transfer url is required');
  if (new Set(urls).size !== urls.length) throw new GametimeFulfilmentError('duplicate transfer urls');
  if (urls.length !== t.quantity) throw new GametimeFulfilmentError(`${urls.length} transfer urls for ${t.quantity} tickets`);
  for (const u of urls) if (!/^https:\/\//.test(u)) throw new GametimeFulfilmentError(`transfer url must be https: ${u}`);
  return [...urls.map((u) => ['transfer_url[]', u] as const), ['transfer_type', 'generic'] as const];
}
