// Small building blocks shared by the sign-in modal, /reset-password,
// /auth/callback and the account settings panel, so labels, autocomplete
// hints and the error/notice live regions are the same everywhere.

import { useId, type InputHTMLAttributes, type ReactNode } from 'react';
import { Check } from 'lucide-react';
import { checkPassword, PASSWORD_MIN_LENGTH } from '../lib/authRules';

export const authInputClass =
  'w-full type bg-black border border-white/20 p-4 text-white placeholder-white/35 focus:border-brand-primary focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 transition-colors aria-[invalid=true]:border-brand-accent';
export const authLabelClass = 'block type text-[11px] uppercase tracking-widest text-white/60 mb-2';
export const authPrimaryButton =
  'w-full flex items-center justify-center bg-brand-primary text-black p-4 disp text-xl uppercase tracking-wide hover:bg-white transition-colors disabled:opacity-50';
export const authLinkButton =
  'type text-[11px] uppercase tracking-widest text-white/60 hover:text-brand-primary transition-colors underline-offset-4 hover:underline disabled:opacity-40 disabled:no-underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary';

type FieldProps = Omit<InputHTMLAttributes<HTMLInputElement>, 'id'> & {
  label: string;
  /** Extra text under the input (rules, hints). */
  hint?: ReactNode;
  invalid?: boolean;
  /** id of an error message elsewhere that describes this field. */
  errorId?: string;
};

export function AuthField({ label, hint, invalid, errorId, className, ...input }: FieldProps) {
  const id = useId();
  const hintId = `${id}-hint`;
  const describedBy = [hint ? hintId : null, invalid && errorId ? errorId : null].filter(Boolean).join(' ') || undefined;
  return (
    <div>
      <label htmlFor={id} className={authLabelClass}>{label}</label>
      <input
        id={id}
        className={`${authInputClass} ${className ?? ''}`}
        aria-invalid={invalid || undefined}
        aria-describedby={describedBy}
        {...input}
      />
      {hint && <div id={hintId} className="mt-2">{hint}</div>}
    </div>
  );
}

/** Live checklist under a new-password field. */
export function PasswordRules({ password, email }: { password: string; email?: string }) {
  const lengthOk = password.length >= PASSWORD_MIN_LENGTH;
  const { problems } = checkPassword(password, { email });
  const mixOk = password.length > 0 && !problems.some((p) => p.startsWith('Mix'));
  const notEmail = !problems.some((p) => p.includes('email'));
  const rows: [boolean, string][] = [
    [lengthOk, `At least ${PASSWORD_MIN_LENGTH} characters`],
    [mixOk, 'Two or more of: lowercase, uppercase, numbers, symbols'],
    [notEmail || !password, 'Not your email address'],
  ];
  return (
    <ul className="space-y-1">
      {rows.map(([ok, text]) => (
        <li key={text} className={`type text-[11px] flex items-center gap-2 ${ok ? 'text-brand-primary' : 'text-white/50'}`}>
          <Check className={`w-3 h-3 shrink-0 ${ok ? '' : 'opacity-30'}`} aria-hidden="true" />
          <span>{text}</span>
          <span className="sr-only">{ok ? '(done)' : '(not yet)'}</span>
        </li>
      ))}
    </ul>
  );
}

/**
 * Error + info banners: role="alert" (assertive) for errors, role="status"
 * (polite) for notices, so screen readers announce them as they appear.
 */
export function AuthNotices({ error, info, errorId, children }: { error?: string; info?: string; errorId?: string; children?: ReactNode }) {
  return (
    <>
      {error && (
        <div id={errorId} role="alert" className="mb-6 p-4 bg-brand-accent/10 border-l-4 border-brand-accent border-y border-r border-white/10 text-brand-accent type text-[12px] leading-relaxed">
          {error}
          {children}
        </div>
      )}
      {info && (
        <div role="status" className="mb-6 p-4 bg-brand-primary/10 border-l-4 border-brand-primary border-y border-r border-white/10 text-brand-primary type text-[12px] leading-relaxed">
          {info}
        </div>
      )}
    </>
  );
}
