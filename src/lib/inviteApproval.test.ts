// Owner approval for staff invites (mig 20261104200000): who may decide, the
// wording, the typo check, and the invite page's outcome.
import { describe, expect, it } from 'vitest';
import { canDecide, claimOutcome, emailComparison, pendingHeadline } from './inviteApproval';

describe('canDecide (mirrors _exos_member_decider)', () => {
  it('owners any role; managers below manager; never yourself; nobody else', () => {
    expect(canDecide('owner', 'manager')).toBe(true);
    expect(canDecide('manager', 'scanner')).toBe(true);
    expect(canDecide('manager', 'finance')).toBe(true);
    expect(canDecide('manager', 'manager')).toBe(false);
    expect(canDecide('finance', 'scanner')).toBe(false);
    expect(canDecide('scanner', 'scanner')).toBe(false);
    expect(canDecide(null, 'scanner')).toBe(false);
    expect(canDecide('owner', 'scanner', true)).toBe(false);
  });
});

describe('wording', () => {
  it('names the account and the role', () => {
    expect(pendingHeadline({ account_email: 'sam@x.com', role: 'manager', current_role: null }))
      .toBe('sam@x.com accepted your invite as manager');
    expect(pendingHeadline({ account_email: 'sam@x.com', role: 'manager', current_role: 'scanner' }))
      .toBe('sam@x.com (already scanner) accepted an invite as manager');
  });
});

describe('emailComparison', () => {
  it('match, a one-letter typo, another address', () => {
    expect(emailComparison('Sam@X.com', 'sam@x.com ')).toBe('match');
    expect(emailComparison('mrg@x.com', 'mgr@x.com')).toBe('typo');
    expect(emailComparison('sam@gmial.com', 'sam@gmail.com')).toBe('typo');
    expect(emailComparison('mrg@x.com', 'stranger@elsewhere.org')).toBe('different');
    expect(emailComparison(null, 'a@x.com')).toBe('unknown');
  });
});

describe('claimOutcome', () => {
  it('waiting while pending, joined when active', () => {
    expect(claimOutcome({ status: 'pending_approval', pending_role: 'manager', disabled: true })).toBe('waiting');
    expect(claimOutcome({ status: 'active', pending_role: 'manager', disabled: false })).toBe('waiting');
    expect(claimOutcome({ status: 'active', pending_role: null, disabled: false })).toBe('joined');
    expect(claimOutcome({ status: 'active', disabled: true })).toBe('unchanged');
    expect(claimOutcome(null)).toBe('unchanged');
  });
});
