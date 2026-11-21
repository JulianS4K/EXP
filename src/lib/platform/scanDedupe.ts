// The native camera (ML Kit) reports the code in view on every frame. The
// door wants one read per presentation: the same text again within
// `windowMs` is the same ticket still in front of the lens, not a second
// scan. A different code passes at once (the next person in line).

export function scanDeduper(windowMs = 2500, now: () => number = Date.now): (text: string) => boolean {
  let last: { text: string; at: number } | null = null;
  return (text: string) => {
    const t = text.trim();
    if (!t) return false;
    const at = now();
    if (last && last.text === t && at - last.at < windowMs) {
      last = { text: t, at }; // still in view: keep the window open
      return false;
    }
    last = { text: t, at };
    return true;
  };
}

/** What a door status means for feedback: a good read, a refusal, or nothing yet. */
export function scanFeedback(status: string): 'success' | 'error' | 'attention' | null {
  switch (status) {
    case 'success':
      return 'success';
    case 'not-found':
    case 'already-used':
    case 'invalid-barcode':
      return 'error';
    case 'needs-reason':
    case 'by-name':
      return 'attention';
    default:
      return null;
  }
}
