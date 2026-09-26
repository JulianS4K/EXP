import { describe, expect, it, vi } from 'vitest';

vi.mock('./supabase', () => ({ supabase: {} }));

import { deletionErrorMessage } from './account';

describe('deletionErrorMessage', () => {
  it('strips the function prefix and reads as a sentence', () => {
    expect(deletionErrorMessage({ message: 'exos_delete_my_account: you own an organization — transfer ownership before deleting your account' }))
      .toBe('You own an organization — transfer ownership before deleting your account.');
  });
  it('falls back to a generic message', () => {
    expect(deletionErrorMessage(null)).toBe('Could not delete your account. Please try again.');
    expect(deletionErrorMessage({ message: '' })).toBe('Could not delete your account. Please try again.');
  });
});
