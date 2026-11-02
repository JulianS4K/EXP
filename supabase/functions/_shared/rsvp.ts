// Phone-number RSVP (mig 20261102150000, docs/organizer-guide.md "Phone
// RSVP"): the pure parts of exos-rsvp, shared with the SPA tests. No Deno or
// Node APIs, so vitest imports it too.

export const MAX_RSVP_BODY = 8 * 1024;
const E164 = /^\+[1-9][0-9]{7,14}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Same rule as public.exos_sms_normalize_phone (default country +1). */
export function normalizeRsvpPhone(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const s = raw.replace(/[^0-9+]/g, '');
  if (E164.test(s)) return s;
  if (/^[2-9][0-9]{9}$/.test(s)) return `+1${s}`;
  if (/^1[2-9][0-9]{9}$/.test(s)) return `+${s}`;
  return null;
}

/** "+12125550123" -> "•••• 0123" for screens that confirm where a code went. */
export function maskPhone(e164: string | null | undefined): string {
  const d = String(e164 ?? '').replace(/[^0-9]/g, '');
  return d.length >= 4 ? `•••• ${d.slice(-4)}` : '••••';
}

export type RsvpAction = 'info' | 'start' | 'verify';

export interface RsvpRequest {
  action: RsvpAction;
  eventId?: string;
  name?: string;
  phone?: string;
  email?: string | null;
  plusOnes?: number;
  promoter?: string | null;
  rsvpId?: string;
  code?: string;
  /** The hidden "website" field: a person never fills it. */
  honeypot: boolean;
}

export class RsvpInputError extends Error {}

const str = (v: unknown, max: number): string | undefined =>
  typeof v === 'string' ? v.trim().slice(0, max) : undefined;

/** Validate a request body (already JSON-parsed). Throws RsvpInputError. */
export function parseRsvpRequest(raw: unknown): RsvpRequest {
  const b = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const action = b.action;
  if (action !== 'info' && action !== 'start' && action !== 'verify') throw new RsvpInputError('unknown action');
  const honeypot = typeof b.website === 'string' && b.website.trim() !== '';
  if (action === 'verify') {
    const rsvpId = str(b.rsvp_id, 36);
    const code = str(b.code, 12)?.replace(/\s+/g, '');
    if (!rsvpId || !UUID.test(rsvpId)) throw new RsvpInputError('rsvp_id is required');
    if (!code || !/^[0-9]{6}$/.test(code)) throw new RsvpInputError('enter the 6-digit code');
    return { action, rsvpId, code, honeypot };
  }
  const eventId = str(b.event_id, 36);
  if (!eventId || !UUID.test(eventId)) throw new RsvpInputError('event_id is required');
  if (action === 'info') return { action, eventId, honeypot };
  const name = str(b.name, 80);
  if (!name) throw new RsvpInputError('enter your name');
  const phone = str(b.phone, 40);
  if (!phone) throw new RsvpInputError('enter your mobile number');
  const email = str(b.email, 254) || null;
  const plus = Number(b.plus_ones ?? 0);
  if (!Number.isInteger(plus) || plus < 0 || plus > 9) throw new RsvpInputError('plus_ones must be 0-9');
  const promoter = str(b.promoter, 64) || null;
  if (promoter && !/^[A-Za-z0-9_-]{1,64}$/.test(promoter)) throw new RsvpInputError('bad promoter code');
  return { action, eventId, name, phone, email, plusOnes: plus, promoter, honeypot };
}

/** A believable answer for a bot that filled the honeypot: nothing is written. */
export function honeypotAnswer(action: RsvpAction): Record<string, unknown> {
  if (action === 'start') return { ok: true, rsvp_id: '00000000-0000-4000-8000-000000000000', channel: 'sms', to: '••••' };
  if (action === 'verify') return { ok: false, error: 'wrong_code', attempts_left: 4 };
  return { ok: false, reason: 'off' };
}

/** Texts are available when the org has a provider connected and sending is live. */
export function smsAvailable(live: boolean, provider: { status?: string | null; secret?: string | null } | null): boolean {
  return live && !!provider && !!provider.secret && provider.status !== 'disabled' && provider.status !== 'error';
}

const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);

/** The one-time code text. */
export function codeText(eventName: string | null | undefined, code: string): string {
  return `${code} is your code to RSVP for ${clip(eventName || 'the event', 60)}. It works for 10 minutes. Don't share it.`;
}

/** The tickets text: one link per ticket (the guest's first, then plus-ones). */
export function ticketsText(eventName: string | null | undefined, urls: string[]): string {
  const name = clip(eventName || 'the event', 60);
  const links = urls.filter(Boolean);
  if (links.length === 0) return `You're in for ${name}. Open Exos to see your ticket.`;
  if (links.length === 1) return `You're in for ${name}. Your ticket (show it at the door): ${links[0]}`;
  const rest = links.slice(1).map((u, i) => `+${i + 1}: ${u}`).join('\n');
  return `You're in for ${name}. Your ticket: ${links[0]}\nSend each guest their own link:\n${rest}`;
}

/** What the page says for each error the SQL can answer. */
export function rsvpErrorMessage(error: string | undefined, extra: { max_plus_ones?: number; attempts_left?: number } = {}): string {
  switch (error) {
    case 'bad_phone': return 'Enter a mobile number, e.g. (212) 555-0100 or +44 7700 900123.';
    case 'bad_name': return 'Enter your name.';
    case 'bad_email': return 'That email doesn\'t look right.';
    case 'too_many_guests':
      return extra.max_plus_ones ? `You can bring up to ${extra.max_plus_ones} guest${extra.max_plus_ones === 1 ? '' : 's'}.` : 'This event doesn\'t take plus-ones.';
    case 'sold_out': return 'This event is full. Join the waitlist and we\'ll tell you if a spot opens.';
    case 'no_channel': return 'We can\'t text you a code for this event right now. Add your email and we\'ll send it there.';
    case 'rate_limited': return 'Too many tries. Wait a few minutes and try again.';
    case 'wrong_code':
      return extra.attempts_left ? `That code isn't right. ${extra.attempts_left} tr${extra.attempts_left === 1 ? 'y' : 'ies'} left.` : 'That code isn\'t right.';
    case 'locked': return 'Too many wrong codes. Start again to get a new one.';
    case 'expired': return 'That code expired. Start again to get a new one.';
    case 'used': return 'That code was already used. Check your texts for your ticket link.';
    case 'off': return 'RSVP by phone isn\'t open for this event.';
    case 'closed': return 'RSVPs for this event are closed.';
    case 'over': return 'This event is over.';
    default: return 'Something went wrong. Try again.';
  }
}
