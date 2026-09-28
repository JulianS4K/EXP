import React, { useState, useEffect, useId, useRef } from 'react';
import { Link } from 'react-router-dom';
import { Mail, KeyRound, ShieldCheck, Ticket, ArrowLeft, Loader2 } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { currentInAppBrowser, IN_APP_LABEL } from '../lib/inAppBrowser';
import { authUrl, callbackUrl, rememberReturnPath } from '../lib/authUrls';
import { checkPassword, cleanEmail, isValidEmail, mapAuthError, type FriendlyAuthError } from '../lib/authRules';
import { useCooldown, RESEND_COOLDOWN_S } from '../hooks/useCooldown';
import { AuthField, AuthNotices, PasswordRules, authLinkButton, authPrimaryButton } from './AuthFields';
import Dialog from './Dialog';

// Screens of the sign-in modal. 'code' is the passwordless path (email a
// 6-digit code, type it here) that guest checkout and transfer mails promise;
// 'check-email' follows a sign-up while the confirmation link is pending.
export type AuthView = 'options' | 'email-login' | 'email-signup' | 'check-email' | 'code' | 'forgot';

const TITLES: Record<AuthView, string> = {
  options: 'Get On The List',
  'email-login': 'Sign In',
  'email-signup': 'Create Account',
  'check-email': 'Check Your Email',
  code: 'Email Me A Code',
  forgot: 'Reset Password',
};

// Shown after "forgot password" whatever happened, so the form never tells
// anyone whether an address has an account.
export const RESET_SENT_MESSAGE = "If an account exists for that email, we've sent a link to reset the password. It can take a minute to arrive; check spam too.";

export default function AuthModal({
  isOpen,
  onClose,
  initialView = 'options',
  initialEmail = '',
}: {
  isOpen: boolean;
  onClose: () => void;
  initialView?: AuthView;
  initialEmail?: string;
}) {
  const [method, setMethod] = useState<AuthView>(initialView);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [name, setName] = useState('');
  const [code, setCode] = useState('');
  const [codeSent, setCodeSent] = useState(false);
  const [error, setError] = useState<FriendlyAuthError | null>(null);
  const [info, setInfo] = useState('');
  const [loading, setLoading] = useState(false);
  const cooldown = useCooldown();
  // Google blocks OAuth inside in-app webviews and Microsoft is unreliable
  // there; email and Apple sign-in work, so those stay.
  const [inApp] = useState(currentInAppBrowser);
  const titleId = useId();
  const errorId = `${titleId}-error`;
  // Screens without an input to autofocus move focus to their message.
  const checkEmailRef = useRef<HTMLParagraphElement>(null);
  useEffect(() => {
    if (method === 'check-email') checkEmailRef.current?.focus();
  }, [method]);

  useEffect(() => {
    if (isOpen) {
      setMethod(initialView);
      setEmail(initialEmail);
      setPassword('');
      setConfirm('');
      setName('');
      setCode('');
      setCodeSent(false);
      setError(null);
      setInfo('');
      setLoading(false);
    }
  }, [isOpen, initialView, initialEmail]);

  const go = (next: AuthView) => {
    setMethod(next);
    setError(null);
    setInfo('');
    setPassword('');
    setConfirm('');
    setCode('');
    setCodeSent(false);
  };

  const fail = (err: unknown) => {
    const mapped = mapAuthError(err);
    setError(mapped);
    if (mapped.kind === 'rate_limited') cooldown.start(mapped.retryAfter ?? RESEND_COOLDOWN_S);
    setLoading(false);
  };

  const requireEmail = (): string | null => {
    if (!isValidEmail(email)) {
      setError({ kind: 'email_invalid', message: 'Enter a valid email address.' });
      return null;
    }
    return cleanEmail(email);
  };

  const handleProviderSignIn = async (providerName: 'google' | 'apple' | 'microsoft') => {
    setLoading(true);
    setError(null);
    // Supabase names the Microsoft provider 'azure'.
    const provider = providerName === 'microsoft' ? 'azure' : providerName;

    try {
      // Back to this page via /auth/callback (keeps the /bridge base path and
      // the event they were buying).
      rememberReturnPath();
      const { error } = await supabase.auth.signInWithOAuth({
        provider,
        options: { redirectTo: callbackUrl() },
      });
      if (error) throw error;
      // OAuth is a redirect flow — the browser navigates to the provider and
      // AuthContext picks up the session on return.
    } catch (err) {
      console.error(err);
      fail(err);
    }
  };

  const handleSignUp = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setInfo('');
    const addr = requireEmail();
    if (!addr) return;
    const pw = checkPassword(password, { email: addr });
    if (!pw.ok) {
      setError({ kind: 'weak_password', message: pw.problems.join(' ') });
      return;
    }
    if (password !== confirm) {
      setError({ kind: 'weak_password', message: "The two passwords don't match." });
      return;
    }
    setLoading(true);
    try {
      rememberReturnPath();
      const { data, error } = await supabase.auth.signUp({
        email: addr,
        password,
        options: { data: { display_name: name.trim() }, emailRedirectTo: callbackUrl() },
      });
      if (error) throw error;
      setLoading(false);
      // Confirmations off: signed in already, AuthContext closes the modal.
      if (data.session) return;
      // Otherwise (including Supabase's obfuscated reply for an address that
      // already has an account) the same neutral "check your email" screen.
      setEmail(addr);
      setMethod('check-email');
      cooldown.start(RESEND_COOLDOWN_S);
    } catch (err) {
      console.error(err);
      fail(err);
    }
  };

  const resendConfirmation = async () => {
    const addr = requireEmail();
    if (!addr || cooldown.left > 0) return;
    setLoading(true);
    setError(null);
    setInfo('');
    const { error } = await supabase.auth.resend({ type: 'signup', email: addr, options: { emailRedirectTo: callbackUrl() } });
    if (error) return fail(error);
    setLoading(false);
    setInfo(`If ${addr} is waiting to be confirmed, a new link is on its way.`);
    cooldown.start(RESEND_COOLDOWN_S);
  };

  const handleSignIn = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setInfo('');
    const addr = requireEmail();
    if (!addr) return;
    setLoading(true);
    try {
      const { error } = await supabase.auth.signInWithPassword({ email: addr, password });
      if (error) throw error;
      // AuthContext closes the modal on the SIGNED_IN auth state change.
    } catch (err) {
      fail(err);
    }
  };

  const sendCode = async (e?: React.FormEvent) => {
    e?.preventDefault();
    setError(null);
    setInfo('');
    const addr = requireEmail();
    if (!addr || cooldown.left > 0) return;
    setLoading(true);
    rememberReturnPath();
    const { error } = await supabase.auth.signInWithOtp({
      email: addr,
      options: { shouldCreateUser: true, emailRedirectTo: callbackUrl() },
    });
    if (error) return fail(error);
    setLoading(false);
    setEmail(addr);
    setCodeSent(true);
    setCode('');
    setInfo(`We sent a 6-digit code to ${addr}. The email's link works too.`);
    cooldown.start(RESEND_COOLDOWN_S);
  };

  const verifyCode = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    const token = code.replace(/\s/g, '');
    if (!/^\d{6,10}$/.test(token)) {
      setError({ kind: 'otp_invalid', message: 'Enter the 6-digit code from the email.' });
      return;
    }
    setLoading(true);
    const { error } = await supabase.auth.verifyOtp({ email: cleanEmail(email), token, type: 'email' });
    // Success: AuthContext picks up SIGNED_IN and closes the modal.
    if (error) fail(error);
  };

  const handleForgot = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setInfo('');
    const addr = requireEmail();
    if (!addr) return;
    setLoading(true);
    rememberReturnPath();
    const { error } = await supabase.auth.resetPasswordForEmail(addr, { redirectTo: authUrl('/reset-password') });
    setLoading(false);
    // Only a network failure is worth showing; anything else (including a
    // per-address rate limit, which only exists for real accounts) gets the
    // same neutral line.
    if (error && mapAuthError(error).kind === 'network') return fail(error);
    if (error) console.warn('resetPasswordForEmail:', error.message);
    setInfo(RESET_SENT_MESSAGE);
    cooldown.start(RESEND_COOLDOWN_S);
  };

  const back = method === 'forgot' ? 'email-login' : 'options';
  const busyLabel = <Loader2 className="w-5 h-5 animate-spin" aria-label="Working" />;
  const emailField = (autoFocus: boolean) => (
    <AuthField
      label="Email Address"
      type="email"
      autoComplete="email"
      autoCapitalize="none"
      spellCheck={false}
      placeholder="you@domain.com"
      value={email}
      onChange={(e) => setEmail(e.target.value)}
      required
      autoFocus={autoFocus}
      invalid={error?.kind === 'email_invalid'}
      errorId={errorId}
    />
  );

  return (
    <Dialog
      open={isOpen}
      onClose={onClose}
      labelledBy={titleId}
      backdropClassName="bg-black/90 backdrop-blur-sm"
      className="bg-[#0e0e0e] border border-white/12 w-full max-w-md shadow-2xl overflow-hidden max-h-[calc(100dvh-2rem)] overflow-y-auto"
    >
          <div className="p-6 border-b border-white/10 flex justify-between items-center bg-black">
             <div className="flex items-center gap-3">
                {method !== 'options' && (
                  <button type="button" onClick={() => go(back)} aria-label="Back" className="mr-1 text-white/60 hover:text-brand-primary transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary">
                    <ArrowLeft className="w-4 h-4" />
                  </button>
                )}
                <div className="w-9 h-9 bg-brand-primary flex items-center justify-center shrink-0">
                  <Ticket className="w-5 h-5 text-black" />
                </div>
                <h2 id={titleId} className="disp text-2xl uppercase tracking-tight leading-none pt-1" style={{ transform: 'skewX(-4deg)' }}>
                  {TITLES[method]}
                </h2>
             </div>
             <button type="button" onClick={onClose} className="type text-white/60 hover:text-white text-[11px] uppercase tracking-widest transition-colors">close [x]</button>
          </div>

          <div className="p-8">
            <AuthNotices error={error?.message} info={info} errorId={errorId}>
              {error?.kind === 'email_not_confirmed' && (
                <button type="button" onClick={resendConfirmation} disabled={loading || cooldown.left > 0} className={`${authLinkButton} block mt-3 text-brand-accent`}>
                  {cooldown.left > 0 ? `Resend confirmation email (${cooldown.left}s)` : 'Resend confirmation email'}
                </button>
              )}
            </AuthNotices>

            {method === 'options' && (
              <div className="space-y-4">
                {inApp && (
                  <p className="type text-[11px] uppercase tracking-widest text-white/60 text-center">
                    Google sign-in doesn't work inside {IN_APP_LABEL[inApp]}. Use email or Apple, or open this page in your browser.
                  </p>
                )}
                {!inApp && (
                <button
                  type="button"
                  onClick={() => handleProviderSignIn('google')}
                  disabled={loading}
                  className="w-full flex items-center justify-center gap-3 p-4 bg-white text-black disp text-lg uppercase tracking-wide hover:bg-brand-primary transition-colors"
                >
                  <svg className="w-4 h-4" viewBox="0 0 24 24" aria-hidden="true">
                    <path fill="currentColor" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" />
                    <path fill="currentColor" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" />
                    <path fill="currentColor" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z" />
                    <path fill="currentColor" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" />
                  </svg>
                  <span>Continue with Google</span>
                </button>
                )}

                <button
                  type="button"
                  onClick={() => handleProviderSignIn('apple')}
                  disabled={loading}
                  className="w-full flex items-center justify-center gap-3 p-4 bg-black border border-white/20 text-white disp text-lg uppercase tracking-wide hover:border-brand-primary hover:text-brand-primary transition-colors"
                >
                  <svg className="w-4 h-4" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                    <path d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.56-1.701z" />
                  </svg>
                  <span>Continue with Apple</span>
                </button>

                {!inApp && (
                <button
                  type="button"
                  onClick={() => handleProviderSignIn('microsoft')}
                  disabled={loading}
                  className="w-full flex items-center justify-center gap-3 p-4 bg-black border border-white/20 text-white disp text-lg uppercase tracking-wide hover:border-brand-primary hover:text-brand-primary transition-colors"
                >
                  <svg className="w-4 h-4" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                    <path d="M11.4 24H0V12.6h11.4V24zM24 24H12.6V12.6H24V24zM11.4 11.4H0V0h11.4v11.4zm12.6 0H12.6V0H24v11.4z" />
                  </svg>
                  <span>Continue with Microsoft</span>
                </button>
                )}

                <div className="relative py-4">
                  <div className="absolute inset-0 flex items-center">
                    <div className="w-full border-t border-white/10"></div>
                  </div>
                  <div className="relative flex justify-center">
                    <span className="bg-[#0e0e0e] px-4 type text-[11px] text-white/60 uppercase tracking-widest">or</span>
                  </div>
                </div>

                <div className="grid grid-cols-3 gap-3">
                  <button
                    type="button"
                    onClick={() => go('code')}
                    disabled={loading}
                    className="flex flex-col items-center justify-center p-4 border border-white/10 hover:border-brand-primary text-white hover:text-brand-primary transition-colors group"
                  >
                     <KeyRound className="w-6 h-6 mb-2 text-white/60 group-hover:text-brand-primary transition-colors" aria-hidden="true" />
                     <span className="type text-[11px] uppercase tracking-widest text-center">Email Code</span>
                  </button>
                  <button
                    type="button"
                    onClick={() => go('email-login')}
                    disabled={loading}
                    className="flex flex-col items-center justify-center p-4 border border-white/10 hover:border-brand-primary text-white hover:text-brand-primary transition-colors group"
                  >
                     <Mail className="w-6 h-6 mb-2 text-white/60 group-hover:text-brand-primary transition-colors" aria-hidden="true" />
                     <span className="type text-[11px] uppercase tracking-widest text-center">Password</span>
                  </button>
                  <button
                    type="button"
                    onClick={() => go('email-signup')}
                    disabled={loading}
                    className="flex flex-col items-center justify-center p-4 border border-white/10 hover:border-brand-primary text-white hover:text-brand-primary transition-colors group"
                  >
                     <ShieldCheck className="w-6 h-6 mb-2 text-white/60 group-hover:text-brand-primary transition-colors" aria-hidden="true" />
                     <span className="type text-[11px] uppercase tracking-widest text-center">Sign Up</span>
                  </button>
                </div>

              </div>
            )}

            {method === 'email-login' && (
              <form key="login" onSubmit={handleSignIn} className="space-y-4" noValidate>
                {emailField(true)}
                <AuthField
                  label="Password"
                  type="password"
                  autoComplete="current-password"
                  placeholder="••••••••"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  required
                  invalid={error?.kind === 'invalid_credentials'}
                  errorId={errorId}
                />
                <div className="flex justify-between gap-4">
                  <button type="button" onClick={() => go('forgot')} className={authLinkButton}>Forgot password?</button>
                  <button type="button" onClick={() => go('code')} className={authLinkButton}>Email me a code</button>
                </div>
                <button type="submit" disabled={loading} className={`${authPrimaryButton} mt-6`}>
                  {loading ? busyLabel : 'Sign In'}
                </button>
                <p className="type text-[11px] uppercase tracking-widest text-white/50 text-center">
                  New here? <button type="button" onClick={() => go('email-signup')} className={authLinkButton}>Create an account</button>
                </p>
              </form>
            )}

            {method === 'email-signup' && (
              <form key="signup" onSubmit={handleSignUp} className="space-y-4" noValidate>
                <AuthField
                  label="Display Name"
                  type="text"
                  autoComplete="name"
                  placeholder="e.g. Satoshi Nakamoto"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  required
                  autoFocus
                />
                {emailField(false)}
                <AuthField
                  label="Password"
                  type="password"
                  autoComplete="new-password"
                  placeholder="••••••••"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  required
                  invalid={error?.kind === 'weak_password'}
                  errorId={errorId}
                  hint={<PasswordRules password={password} email={email} />}
                />
                <AuthField
                  label="Confirm Password"
                  type="password"
                  autoComplete="new-password"
                  placeholder="••••••••"
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  required
                  invalid={!!confirm && confirm !== password}
                />
                <p className="type text-[11px] text-white/60 leading-relaxed">
                  By creating an account you agree to the{' '}
                  <Link to="/terms" target="_blank" rel="noopener" className="underline hover:text-brand-primary">Terms of Service</Link> and{' '}
                  <Link to="/privacy" target="_blank" rel="noopener" className="underline hover:text-brand-primary">Privacy Policy</Link>.
                </p>
                <button type="submit" disabled={loading} className={`${authPrimaryButton} mt-6`}>
                  {loading ? busyLabel : 'Create Account'}
                </button>
              </form>
            )}

            {method === 'check-email' && (
              <div className="space-y-6">
                <p ref={checkEmailRef} className="type text-[13px] text-white/80 leading-relaxed focus:outline-none" tabIndex={-1}>
                  If <strong className="text-white">{email}</strong> can be used for a new account, we've sent it a confirmation link.
                  Open it on any device to finish. Already have an account? Sign in, or reset your password.
                </p>
                <button type="button" onClick={resendConfirmation} disabled={loading || cooldown.left > 0} className={authPrimaryButton}>
                  {loading ? busyLabel : cooldown.left > 0 ? `Resend in ${cooldown.left}s` : 'Resend confirmation email'}
                </button>
                <div className="flex justify-between gap-4">
                  <button type="button" onClick={() => go('email-login')} className={authLinkButton}>Back to sign in</button>
                  <button type="button" onClick={() => go('email-signup')} className={authLinkButton}>Use another email</button>
                </div>
              </div>
            )}

            {method === 'code' && !codeSent && (
              <form key="code-email" onSubmit={sendCode} className="space-y-4" noValidate>
                <p className="type text-[12px] text-white/60 leading-relaxed">
                  No password needed. We'll email you a 6-digit code; new here and we'll make your account.
                </p>
                {emailField(true)}
                <button type="submit" disabled={loading || cooldown.left > 0} className={`${authPrimaryButton} mt-6`}>
                  {loading ? busyLabel : cooldown.left > 0 ? `Wait ${cooldown.left}s` : 'Email Me A Code'}
                </button>
                <button type="button" onClick={() => go('email-login')} className={authLinkButton}>Use a password instead</button>
              </form>
            )}

            {method === 'code' && codeSent && (
              <form key="code-verify" onSubmit={verifyCode} className="space-y-4" noValidate>
                <AuthField
                  label="6-digit code"
                  type="text"
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  pattern="[0-9]*"
                  maxLength={10}
                  placeholder="123456"
                  value={code}
                  onChange={(e) => setCode(e.target.value.replace(/[^\d]/g, ''))}
                  required
                  autoFocus
                  className="tracking-[0.4em] text-center text-xl"
                  invalid={error?.kind === 'otp_invalid'}
                  errorId={errorId}
                />
                <button type="submit" disabled={loading} className={`${authPrimaryButton} mt-6`}>
                  {loading ? busyLabel : 'Sign In'}
                </button>
                <div className="flex justify-between gap-4">
                  <button type="button" onClick={() => sendCode()} disabled={loading || cooldown.left > 0} className={authLinkButton}>
                    {cooldown.left > 0 ? `Send again (${cooldown.left}s)` : 'Send a new code'}
                  </button>
                  <button type="button" onClick={() => { setCodeSent(false); setCode(''); setError(null); setInfo(''); }} className={authLinkButton}>
                    Change email
                  </button>
                </div>
              </form>
            )}

            {method === 'forgot' && (
              <form key="forgot" onSubmit={handleForgot} className="space-y-4" noValidate>
                <p className="type text-[12px] text-white/60 leading-relaxed">
                  Enter your account email and we'll send a link to set a new password.
                </p>
                {emailField(true)}
                <button type="submit" disabled={loading || cooldown.left > 0} className={`${authPrimaryButton} mt-6`}>
                  {loading ? busyLabel : cooldown.left > 0 ? `Send again in ${cooldown.left}s` : 'Send Reset Link'}
                </button>
                <button type="button" onClick={() => go('code')} className={authLinkButton}>Sign in with an email code instead</button>
              </form>
            )}
          </div>
          <div className="px-8 py-4 border-t border-white/10 bg-black text-center">
            <p className="type text-[11px] text-white/60 uppercase tracking-widest leading-relaxed">
              By continuing, you agree to our Terms of Service and Privacy Policy.
            </p>
          </div>
    </Dialog>
  );
}
