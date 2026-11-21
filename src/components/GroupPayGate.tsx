// The /group-pay routes (group buy v2, "pay separately"): paused by the
// operator 2026-11-09 (mig 20261111120000), so they show a plain "not
// available" page unless the build sets VITE_EXOS_GROUP_PAY=on. The view
// inside is never rendered (or even loaded: it's lazy) while off.

import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { GROUP_PAY_OFF_TEXT, groupPayEnabled } from '../lib/groupPayFlag';

export function GroupPayUnavailable() {
  return (
    <div className="max-w-xl mx-auto px-4 py-10" data-testid="group-pay-unavailable">
      <h1 className="text-2xl font-black text-slate-900 mb-4">{GROUP_PAY_OFF_TEXT}</h1>
      <p className="text-slate-700 mb-3">
        Paying for seats separately isn't offered right now. To go with friends, buy the tickets together: after
        checkout, "Split with friends" sends each friend their ticket and a link to pay you back.
      </p>
      <Link to="/" className="text-sm font-black text-brand-primary">Browse events</Link>
    </div>
  );
}

export default function GroupPayGate({ children }: { children: ReactNode }) {
  return groupPayEnabled() ? <>{children}</> : <GroupPayUnavailable />;
}
