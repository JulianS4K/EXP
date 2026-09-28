// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import GuestCheckoutModal from './GuestCheckoutModal';

beforeEach(() => localStorage.clear());
afterEach(cleanup);

function setup(props: { busy?: boolean } = {}) {
  const onContinue = vi.fn();
  const onClose = vi.fn();
  const onSignIn = vi.fn();
  render(<GuestCheckoutModal open onClose={onClose} onContinue={onContinue} onSignIn={onSignIn} {...props} />);
  const email = screen.getByLabelText('Email') as HTMLInputElement;
  const submit = screen.getByRole('button', { name: /continue to payment|starting checkout/i });
  return { onContinue, onClose, onSignIn, email, submit };
}

describe('GuestCheckoutModal', () => {
  it('is a labelled dialog with the email field focused', () => {
    const { email } = setup();
    expect(screen.getByRole('dialog', { name: /where should we send your tickets/i })).toBeTruthy();
    expect(document.activeElement).toBe(email);
  });

  it('blocks an invalid email and says why', () => {
    const { email, submit, onContinue } = setup();
    fireEvent.change(email, { target: { value: 'not-an-email' } });
    fireEvent.click(submit);
    expect(onContinue).not.toHaveBeenCalled();
    expect(screen.getByRole('alert').textContent).toMatch(/valid email/i);
    expect(email.getAttribute('aria-invalid')).toBe('true');
  });

  it('continues with the cleaned-up email and remembers it', () => {
    const { email, submit, onContinue } = setup();
    fireEvent.change(email, { target: { value: '  Fan@Example.COM ' } });
    fireEvent.click(submit);
    expect(onContinue).toHaveBeenCalledWith('fan@example.com');
    expect(localStorage.getItem('exos.guestEmail')).toBe('fan@example.com');
  });

  it("can't be dismissed or resubmitted while checkout is starting", () => {
    const { email, submit, onContinue, onClose } = setup({ busy: true });
    fireEvent.change(email, { target: { value: 'fan@example.com' } });
    fireEvent.click(submit);
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onContinue).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('offers sign-in instead', () => {
    const { onSignIn } = setup();
    fireEvent.click(screen.getByRole('button', { name: /sign in instead/i }));
    expect(onSignIn).toHaveBeenCalled();
  });

  it('free tickets: no payment wording, sends the tickets', () => {
    const onContinue = vi.fn();
    render(<GuestCheckoutModal open free onClose={vi.fn()} onContinue={onContinue} onSignIn={vi.fn()} />);
    expect(screen.queryByText(/pay with/i)).toBeNull();
    fireEvent.change(screen.getByLabelText('Email'), { target: { value: 'Fan@Example.com' } });
    fireEvent.click(screen.getByRole('button', { name: /send my tickets/i }));
    expect(onContinue).toHaveBeenCalledWith('fan@example.com');
  });
});
