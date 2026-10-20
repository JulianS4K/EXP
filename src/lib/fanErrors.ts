// What a fan sees when buying or claiming fails. The RPCs and exos-checkout
// answer in operator terms ("exos_create_hold: not enough tickets available",
// "exos: exceeds max per account (hold 4, +2 would exceed limit 4)"); this
// strips the function prefix and puts the common reasons in plain words.
// Anything not recognised keeps its own (prefix-free) wording.

/** The message without leading `exos_*:` / `exos:` prefixes. */
export function stripExosPrefix(message: string): string {
  let m = message.trim();
  for (let i = 0; i < 3; i++) {
    const next = m.replace(/^exos(?:[_-][a-z0-9_-]+)?:\s*/i, '');
    if (next === m) break;
    m = next;
  }
  return m;
}

const upperFirst = (s: string) => (s ? s[0].toUpperCase() + s.slice(1) : s);

/** One message in fan words. `fallback` covers empty and transport-level errors. */
export function fanMessage(message: string | null | undefined, fallback: string): string {
  if (!message || /non-2xx status code|failed to send a request|failed to fetch|load failed/i.test(message)) return fallback;
  const m = stripExosPrefix(message);
  const l = m.toLowerCase();

  const perAccount = l.match(/max per account \(hold (\d+), \+(\d+) would exceed limit (\d+)\)/);
  if (perAccount) {
    const [, held, , limit] = perAccount;
    return Number(held) > 0
      ? `You can have up to ${limit} tickets for this event and you already have ${held}.`
      : `You can have up to ${limit} tickets for this event.`;
  }
  const perOrder = l.match(/max per order \((\d+) requested, limit (\d+)\)/);
  if (perOrder) return `You can get up to ${perOrder[2]} tickets per order.`;
  if (/purchase limit|exceeds max|per[- ]person limit/.test(l)) return 'That\'s more tickets than the organizer allows per person.';

  if (/not enough tickets|only \d+ left/.test(l)) return 'Not enough tickets left for that many. Try a smaller quantity.';
  if (/sold out|no longer available/.test(l) && !/add-on/.test(l)) return 'Sold out. Try another ticket type, or join the waitlist.';
  if (/sales (for this tier )?have ended|sales ended/.test(l)) return 'Sales for this ticket type have ended.';
  if (/sales have not started|not started for this tier/.test(l)) return 'Sales for this ticket type haven\'t opened yet.';
  if (/event not on sale|not on sale/.test(l)) return 'This event isn\'t on sale right now.';
  if (/tier not available|ticket type not available|tier not found|not valid for this ticket type/.test(l)) {
    return 'That ticket type isn\'t available. If you have a code, apply it first.';
  }
  if (/code doesn't cover|voucher covers \d+/.test(l)) return 'That code doesn\'t cover that many tickets. Try a smaller quantity.';
  if (/^voucher (invalid code|invalid)$/.test(l)) return 'That code isn\'t valid for this event.';
  if (/^voucher expired$/.test(l)) return 'That code has expired.';
  if (/^voucher already used$/.test(l)) return 'That code has already been used.';
  if (/too many attempts/.test(l)) return 'Too many tries. Wait a few minutes and try again.';
  if (/confirm your email/.test(l)) return 'Confirm your email first: open the link we sent you, then try again.';
  if (/not authenticated|^unauthorized$|invalid jwt|jwt expired/.test(l)) return 'Your session expired. Sign in and try again.';
  if (/tier is not free|use checkout/.test(l)) return 'This ticket isn\'t free any more. Reload the page to see the price.';
  return upperFirst(m);
}

/** fanMessage for a thrown error (Error, PostgREST error, or anything with .message). */
export function fanError(err: unknown, fallback: string): string {
  const message = typeof err === 'string' ? err : (err as { message?: unknown } | null)?.message;
  return fanMessage(typeof message === 'string' ? message : null, fallback);
}
