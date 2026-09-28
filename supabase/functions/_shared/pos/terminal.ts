// Venue POS: the card reader, as an interface. NOTHING HERE TALKS TO STRIPE.
//
// Stripe Terminal is not wired (docs/pos.md). This file defines what the POS
// needs from a reader so the rest can be built and tested now:
//   PaymentTerminal     the contract a real Stripe Terminal adapter will meet
//   FakeTerminal        deterministic, scripted, in-memory: for tests and demos
//   NotWiredTerminal    what production gets today: every call refuses
//
// NO CARD DATA crosses this interface. The reader handles the card (card
// present, EMV / tap); Exos only ever sees an opaque reference (a Stripe
// PaymentIntent id, later) and the outcome. Never add PAN, expiry, CVC,
// cardholder name or track data to these types.

export interface CollectRequest {
  amountCents: number;
  tipCents?: number;
  currency: string;
  /** Stable per attempt: the same key never charges twice. */
  idempotencyKey: string;
  /** exos_pos_orders.id, for the processor's metadata. */
  orderId: string;
}

export type CollectStatus = 'succeeded' | 'declined' | 'canceled' | 'offline_queued';

export interface CollectResult {
  status: CollectStatus;
  /** Opaque processor reference (exos_pos_payments.terminal_ref). Absent when nothing was charged. */
  terminalRef?: string;
  amountCents: number;
  tipCents: number;
  /** Processor decline code, for the screen. Never card data. */
  declineCode?: string;
}

export interface RefundResult {
  status: 'succeeded' | 'failed';
  refundRef?: string;
  amountCents: number;
}

export interface PaymentTerminal {
  readonly kind: 'fake' | 'stripe-terminal' | 'not-wired';
  /** Pair with a registered reader (exos_pos_devices.hardware_ref). */
  connect(readerRef: string): Promise<void>;
  collect(req: CollectRequest): Promise<CollectResult>;
  refund(terminalRef: string, amountCents: number): Promise<RefundResult>;
  /** Abort the payment currently on the reader, if any. */
  cancel(): Promise<void>;
}

export class PaymentsNotWiredError extends Error {
  constructor(action: string) {
    super(`POS card payments are not wired yet (${action}): Stripe Terminal is scaffolding only, see docs/pos.md`);
    this.name = 'PaymentsNotWiredError';
  }
}

/** Production today: the reader exists as a type, never as a charge. */
export class NotWiredTerminal implements PaymentTerminal {
  readonly kind = 'not-wired' as const;
  connect(): Promise<void> { return Promise.reject(new PaymentsNotWiredError('connect')); }
  collect(): Promise<CollectResult> { return Promise.reject(new PaymentsNotWiredError('collect')); }
  refund(): Promise<RefundResult> { return Promise.reject(new PaymentsNotWiredError('refund')); }
  cancel(): Promise<void> { return Promise.reject(new PaymentsNotWiredError('cancel')); }
}

export type FakeOutcome = 'succeeded' | 'declined' | 'canceled' | 'offline_queued';

/**
 * A reader that does what it's told. Queue outcomes with `script`; with an
 * empty script every collect succeeds. Idempotent on idempotencyKey like the
 * real processor. Records every call in `log`.
 */
export class FakeTerminal implements PaymentTerminal {
  readonly kind = 'fake' as const;
  readonly log: { op: 'connect' | 'collect' | 'refund' | 'cancel'; detail: string }[] = [];
  private readerRef: string | null = null;
  private seq = 0;
  private readonly outcomes: FakeOutcome[] = [];
  private readonly byKey = new Map<string, CollectResult>();
  private readonly charges = new Map<string, { amountCents: number; refundedCents: number }>();

  script(...outcomes: FakeOutcome[]): this {
    this.outcomes.push(...outcomes);
    return this;
  }

  connect(readerRef: string): Promise<void> {
    this.log.push({ op: 'connect', detail: readerRef });
    this.readerRef = readerRef;
    return Promise.resolve();
  }

  collect(req: CollectRequest): Promise<CollectResult> {
    this.log.push({ op: 'collect', detail: `${req.orderId}:${req.amountCents}+${req.tipCents ?? 0}` });
    if (!this.readerRef) return Promise.reject(new Error('FakeTerminal: no reader connected'));
    if (!Number.isInteger(req.amountCents) || req.amountCents <= 0) {
      return Promise.reject(new Error('FakeTerminal: amount must be positive whole cents'));
    }
    const seen = this.byKey.get(req.idempotencyKey);
    if (seen) return Promise.resolve(seen);
    const outcome = this.outcomes.shift() ?? 'succeeded';
    const tip = req.tipCents ?? 0;
    let result: CollectResult;
    if (outcome === 'succeeded' || outcome === 'offline_queued') {
      this.seq += 1;
      const ref = `fake_pi_${String(this.seq).padStart(6, '0')}`;
      this.charges.set(ref, { amountCents: req.amountCents + tip, refundedCents: 0 });
      result = { status: outcome, terminalRef: ref, amountCents: req.amountCents, tipCents: tip };
    } else {
      result = { status: outcome, amountCents: 0, tipCents: 0, declineCode: outcome === 'declined' ? 'card_declined' : undefined };
    }
    this.byKey.set(req.idempotencyKey, result);
    return Promise.resolve(result);
  }

  refund(terminalRef: string, amountCents: number): Promise<RefundResult> {
    this.log.push({ op: 'refund', detail: `${terminalRef}:${amountCents}` });
    const c = this.charges.get(terminalRef);
    if (!c || amountCents <= 0 || c.refundedCents + amountCents > c.amountCents) {
      return Promise.resolve({ status: 'failed', amountCents: 0 });
    }
    c.refundedCents += amountCents;
    return Promise.resolve({ status: 'succeeded', refundRef: `fake_re_${terminalRef.slice(8)}_${c.refundedCents}`, amountCents });
  }

  cancel(): Promise<void> {
    this.log.push({ op: 'cancel', detail: '' });
    return Promise.resolve();
  }
}
