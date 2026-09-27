// Gametime writer: orders, listing edits and the inventory file, NOT LIVE.
//
// CLAUDE.md Hard Rule #2 holds: nothing in Exos sends a write to Gametime
// today. Same design as the StubHub and SeatGeek writers:
//   dry-run (default)  every method returns what it would send; no fetch.
//   live               needs a WriteAuthorization naming the operator, when,
//                      where it's recorded, and exactly which endpoints.
//
// Always refused:
//   * a listing edit / delete for a listing id that isn't an Exos one;
//   * the inventory upload unless the authorization says the Gametime account
//     holds only Exos listings (dedicatedAccount): the file is the account's
//     inventory, so on a shared account it would take over the broker's
//     listings. The FTP upload itself isn't built yet: live mode refuses it.

import { GAMETIME_ENDPOINTS, GAMETIME_FTP_HOSTS, type EndpointName, type GametimeEnvironment } from './endpoints.ts';
import { RETRY_THROTTLED, execute, relativeUrl, transportConfig, type FetchLike, type FormFields, type KeySource, type RequestParts, type TransportConfig } from './transport.ts';
import { confirmBody, transferConfirmationForm, type TransferConfirmation } from './fulfilment.ts';
import { gametimeInventoryCsv, type GametimeCsvRow } from './inventory.ts';
import { isExosListingId } from '../listingIds.ts';
import type { GametimeListingEdit } from './types.ts';

type WriteEndpoint = {
  [K in EndpointName]: (typeof GAMETIME_ENDPOINTS)[K]['access'] extends 'read' ? never : K;
}[EndpointName];
export type GametimeWriteEndpoint = WriteEndpoint;

export const GAMETIME_WRITE_ROADMAP: ReadonlyArray<{ phase: string; endpoints: readonly GametimeWriteEndpoint[] }> = [
  { phase: '1. Inventory file (dedicated account only) + heartbeat every < 6 h', endpoints: ['uploadInventory'] },
  { phase: '2. Listing management between files (quantity / lots, delete)', endpoints: ['editListing', 'deleteListing'] },
  { phase: '3. Orders: confirm, then confirm the transfer with the claim links', endpoints: ['confirmPurchase', 'rejectPurchase', 'confirmTransfer'] },
];

export interface GametimeWriteAuthorization {
  approvedBy: string;
  approvedAt: string;
  reference: string;
  endpoints: readonly GametimeWriteEndpoint[];
  /** The Gametime account carries Exos listings only (required for uploadInventory). */
  dedicatedAccount?: boolean;
}

export type GametimeWriterMode = { mode: 'dry-run' } | { mode: 'live'; authorization: GametimeWriteAuthorization };

export interface GametimePlannedWrite {
  endpoint: GametimeWriteEndpoint;
  method: string;
  /** Relative to the API base (never carries the key), or the FTP target. */
  url: string;
  body?: unknown;
  form?: FormFields;
  /** uploadInventory: the file. */
  csv?: string;
}

export type GametimeWriteResult<T> =
  | { dryRun: true; planned: GametimePlannedWrite }
  | { dryRun: false; planned: GametimePlannedWrite; response: T };

export class GametimeWriteRefusedError extends Error {
  constructor(readonly endpoint: string, reason: string) {
    super(`gametime write "${endpoint}" refused: ${reason} (CLAUDE.md Hard Rule #2)`);
    this.name = 'GametimeWriteRefusedError';
  }
}

export interface GametimeWriterOptions {
  mode?: GametimeWriterMode;
  apiKey?: KeySource;
  environment?: GametimeEnvironment;
  baseUrl?: string;
  fetch?: FetchLike;
  maxRetries?: number;
  sleep?: (ms: number) => Promise<void>;
}

function validateAuthorization(a: GametimeWriteAuthorization): string | null {
  if (!a.approvedBy?.trim()) return 'authorization has no approvedBy';
  if (!a.reference?.trim()) return 'authorization has no reference to where the approval is recorded';
  if (Number.isNaN(Date.parse(a.approvedAt))) return 'authorization approvedAt is not a timestamp';
  if (!a.endpoints?.length) return 'authorization covers no endpoints';
  for (const e of a.endpoints) {
    const access = (GAMETIME_ENDPOINTS as Record<string, { access: string }>)[e]?.access;
    if (access !== 'write' && access !== 'upload') return `"${e}" is not an allowed write endpoint`;
  }
  return null;
}

export class GametimeWriter {
  private readonly mode: GametimeWriterMode;
  private readonly cfg: TransportConfig | null;
  private readonly environment: GametimeEnvironment;

  constructor(opts: GametimeWriterOptions = {}) {
    this.mode = opts.mode ?? { mode: 'dry-run' };
    this.environment = opts.environment ?? 'production';
    if (this.mode.mode === 'live') {
      const bad = validateAuthorization(this.mode.authorization);
      if (bad) throw new GametimeWriteRefusedError('*', bad);
      if (!opts.apiKey) throw new Error('gametime writer: live mode needs an API key');
      this.cfg = transportConfig({ ...opts, apiKey: opts.apiKey });
    } else {
      this.cfg = null;
    }
  }

  get isLive(): boolean {
    return this.mode.mode === 'live';
  }

  private scope(endpoint: GametimeWriteEndpoint) {
    if (this.mode.mode === 'live' && !this.mode.authorization.endpoints.includes(endpoint)) {
      throw new GametimeWriteRefusedError(endpoint, 'not in the authorization scope');
    }
  }

  private async write<T>(endpoint: Exclude<GametimeWriteEndpoint, 'uploadInventory'>, parts: RequestParts = {}): Promise<GametimeWriteResult<T>> {
    const ep = GAMETIME_ENDPOINTS[endpoint];
    const planned: GametimePlannedWrite = { endpoint, method: ep.method, url: relativeUrl(ep, parts) };
    if (parts.body !== undefined) planned.body = parts.body;
    if (parts.form) planned.form = parts.form;
    if (this.mode.mode === 'dry-run' || !this.cfg) return { dryRun: true, planned };
    this.scope(endpoint);
    const res = await execute(this.cfg, ep, parts, RETRY_THROTTLED);
    const text = res.status === 204 ? '' : await res.text();
    let response: unknown = null;
    if (text) {
      try {
        response = JSON.parse(text);
      } catch {
        response = text;
      }
    }
    return { dryRun: false, planned, response: response as T };
  }

  confirmPurchase(orderNumber: string, seats?: ReadonlyArray<string | number>) {
    const body = confirmBody(seats);
    return this.write<unknown>('confirmPurchase', { path: { orderNumber }, ...(body ? { body } : {}) });
  }

  rejectPurchase(orderNumber: string) {
    return this.write<unknown>('rejectPurchase', { path: { orderNumber } });
  }

  /** After the tickets were transferred: one Exos claim link per ticket. */
  confirmTransfer(t: TransferConfirmation) {
    return this.write<unknown>('confirmTransfer', { path: { orderNumber: t.orderNumber }, form: transferConfirmationForm(t) });
  }

  /** POST /listings/{id}: quantity + purchasable lots (quantity 0 removes it). Exos ids only. */
  editListing(id: string, edit: GametimeListingEdit) {
    this.assertExos(id, 'editListing');
    if (!Number.isInteger(edit.quantity) || edit.quantity < 0) throw new GametimeWriteRefusedError('editListing', 'bad quantity');
    if (edit.lots.some((l) => !Number.isInteger(l) || l < 1 || l > edit.quantity)) {
      throw new GametimeWriteRefusedError('editListing', 'lots must be whole quantities up to the listing quantity');
    }
    return this.write<unknown>('editListing', { path: { id }, body: edit });
  }

  deleteListing(id: string) {
    this.assertExos(id, 'deleteListing');
    return this.write<null>('deleteListing', { path: { id } });
  }

  /**
   * The inventory file (FTP). Exos listings only, and only for a Gametime
   * account that holds nothing else. Live upload isn't built: refused.
   */
  uploadInventory(rows: ReadonlyArray<GametimeCsvRow>): GametimeWriteResult<never> {
    const csv = gametimeInventoryCsv(rows); // refuses non-Exos TicketIDs
    const planned: GametimePlannedWrite = {
      endpoint: 'uploadInventory',
      method: 'FTP STOR',
      url: `ftp://${GAMETIME_FTP_HOSTS[this.environment]}/inventory.csv`,
      csv,
    };
    if (this.mode.mode === 'dry-run') return { dryRun: true, planned };
    this.scope('uploadInventory');
    if (this.mode.authorization.dedicatedAccount !== true) {
      throw new GametimeWriteRefusedError('uploadInventory',
        'the file replaces the account inventory; allowed only on a Gametime account that holds Exos listings alone (dedicatedAccount)');
    }
    throw new GametimeWriteRefusedError('uploadInventory', 'the FTP upload is not built yet');
  }

  private assertExos(id: string, endpoint: string) {
    if (!isExosListingId(id)) {
      throw new GametimeWriteRefusedError(endpoint, `"${id}" is not an Exos listing id`);
    }
  }
}
