# Sign-in, sign-up and passwords

How people get into Exos, which routes the auth emails land on, and the Supabase
settings an operator has to set by hand (nothing here can be done from code, and
nothing in this repo calls the Supabase management API).

## Flows

All of it goes through `supabase.auth` (supabase-js 2, `src/lib/supabase.ts`). The
client uses the default **implicit** flow (`flowType` unset) with
`detectSessionInUrl`: an email link comes back as `#access_token=…&type=…` and works
on any device, which matters because people open these mails on their phones. PKCE
would tie each link to the browser that asked for it. The landing pages still
handle `?code=` (PKCE) and `?token_hash=…&type=…` links, so switching a template or
the client over later doesn't break them.

| Flow | Where | Supabase call | Lands on |
|---|---|---|---|
| Sign up (email + password) | Sign-in modal → Sign Up | `signUp({ email, password, options: { data: { display_name }, emailRedirectTo } })` | `/auth/callback?next=…` |
| Resend confirmation | "Check your email" screen, the "email not confirmed" error, an expired confirm link | `resend({ type: 'signup' })`, 60 s cooldown | `/auth/callback?next=…` |
| Sign in with password | Modal → Password | `signInWithPassword` | stays on the page |
| Sign in with an email code | Modal → Email Code; the claim page (`/claim/:id`); the guest "check your email" screen on My Tickets | `signInWithOtp({ email, options: { shouldCreateUser: true } })`, then `verifyOtp({ email, token, type: 'email' })` | stays on the page (the mail's link goes to `/auth/callback`) |
| Forgot password | Modal → Password → "Forgot password?" | `resetPasswordForEmail(email, { redirectTo: <base>/reset-password })` | `/reset-password` |
| Set a new password | `/reset-password` | recovery session from the link, then `updateUser({ password })` | back to where they started |
| Google / Apple / Microsoft | Modal | `signInWithOAuth({ redirectTo })` | `/auth/callback?next=…` |
| Change password | Profile → Account & security | `updateUser({ password })`; on `reauthentication_needed`: `reauthenticate()` + `updateUser({ password, nonce })` | — |
| Change email | Profile → Account & security | `updateUser({ email }, { emailRedirectTo })` | `/auth/callback?next=/profile` |
| Sign out | Navbar menu, Profile | `signOut({ scope: 'local' })` | — |
| Sign out of all devices | Profile → Account & security | `signOut({ scope: 'global' })` | — |

The venue-site iframe (`/embed/event/:id`, `src/components/EmbedSignIn.tsx`) keeps its
own code-or-password form: no redirects work inside a partitioned iframe.

Note: supabase-js's own default for `signOut()` is `global`. The navbar "sign out" used
to call it bare, which signed people out on every device; it now passes `local`.

### Messages that don't leak accounts

- Forgot password always answers "If an account exists for that email, we've sent a
  link", including on errors (a per-address rate limit only exists for real accounts, so
  it would give one away). Only a network failure is shown.
- Sign-up shows the same "check your email" screen whether or not the address already has
  an account (Supabase answers both the same way while confirmations are on). If
  confirmations are ever turned off Supabase returns `user_already_exists`; we show a
  neutral "couldn't use that email here, sign in or reset your password".
- Error mapping lives in `src/lib/authRules.ts` (`mapAuthError`): wrong password, email not
  confirmed (with a resend button), rate limited (with the wait Supabase gives), bad or
  expired code / link, weak or reused password, re-auth needed, network.

### Password rules

`src/lib/authRules.ts`, shown live under every new-password field: at least **8**
characters, at most 72 bytes (bcrypt's limit, which Supabase enforces), at least two of
lowercase / uppercase / digits / symbols, and not the email or its local part. Supabase's
own floor is separate (default 6), so the operator sets it to 8 too (below).

## Routes

| Route | File | Does |
|---|---|---|
| `/auth/callback` | `src/views/AuthCallback.tsx` | Finishes confirm-signup, magic-link, email-change and OAuth redirects: waits for supabase-js to store the session, exchanges `?code=` or verifies `?token_hash=` if needed, then goes to `?next=` (or the path remembered in localStorage, or `/`). A recovery link is sent on to `/reset-password`. Expired / used links get a "resend confirmation" form and sign-in buttons. The first leg of a secure email change (`#message=…`) gets "now confirm on your other address". |
| `/reset-password` | `src/views/ResetPassword.tsx` | Shows the new-password form when the page was opened from a recovery link (implicit `#…type=recovery`, `?code=`, `?token_hash=`) or `PASSWORD_RECOVERY` fired. Dead links get a "send a new link" form. A signed-in visit without a link is pointed at account settings. After saving: signed in, back to the remembered page. |

If Supabase ever drops a recovery link on the Site URL instead (redirect not
allow-listed), `AuthContext` sees `PASSWORD_RECOVERY` and navigates to
`/reset-password` anyway.

### Redirect URLs and the return path

`src/lib/authUrls.ts` builds every redirect: current origin (falls back to
`VITE_APP_URL` outside a browser) + vite base (`/bridge`) + route. So each host sends
people back to itself: `https://exos-web.onrender.com/bridge/…`,
`https://vibepass-storefront-test.onrender.com/bridge/…`, `http://localhost:3000/bridge/…`.

Before any redirect the current page is remembered (`?next=` on the callback URL, plus
localStorage for 24 h). `sanitizeReturnPath` only follows same-origin, app-relative
paths: no scheme, no `//host`, no backslashes or control characters, nothing that
resolves off-site, never back to `/auth/callback` or `/reset-password`. Everything else
goes to `/`.

## Operator checklist (Supabase Dashboard)

**Heads-up: the Supabase project is shared with Terminal-2.** Auth settings, templates
and SMTP are project-wide, so Terminal-2's users get the same emails and redirects.
Add to the allow-list rather than replacing entries, and check with Terminal-2 before
changing the Site URL or rewording templates.

1. **Authentication → URL Configuration**
   - Site URL: leave as is if Terminal-2 depends on it; otherwise
     `https://vibepass-storefront-test.onrender.com/bridge/` (the public link).
   - Redirect URLs, add:
     - `https://exos-web.onrender.com/bridge/**`
     - `https://vibepass-storefront-test.onrender.com/bridge/**`
     - `http://localhost:3000/bridge/**`

     Without these Supabase silently sends every email link to the Site URL (and drops
     `?next=`).
2. **Authentication → Sign In / Providers → Email**
   - Email provider on, "Confirm email" on.
   - "Secure email change" on (recommended; the app tells people to confirm on both
     addresses). "Secure password change" either way; the app handles both.
   - Minimum password length: **8** (matches `PASSWORD_MIN_LENGTH`). Password
     requirements: leave at "No required characters". The form already asks for two
     kinds of character, but any two (e.g. lowercase + symbol); a stricter server rule
     would refuse passwords the form accepted, and people would see the weak-password
     message.
   - Leaked password protection (HaveIBeenPwned, paid plans): turn on if available; the
     app explains a `pwned` refusal.
   - Email OTP expiry: 3600 s or less. OTP length: 6 (the form accepts 6–10 digits).
   - "Allow new users to sign up" must stay on: `signInWithOtp` creates accounts
     (`shouldCreateUser: true`) for guest buyers claiming their tickets.
3. **Authentication → Emails → Templates** (suggested copy; keep `{{ .ConfirmationURL }}`
   and `{{ .Token }}` exactly as written):
   - **Confirm signup** — Subject: `Confirm your Exos account`. Body: "Tap to confirm your
     email and finish setting up Exos: `<a href="{{ .ConfirmationURL }}">Confirm my
     email</a>`. Or enter this code: `{{ .Token }}`. Didn't sign up? Ignore this email."
   - **Magic Link** (this is the sign-in code email) — Subject: `Your Exos sign-in code:
     {{ .Token }}`. Body: "Your code is **{{ .Token }}**. Enter it on the sign-in screen.
     It expires in 1 hour. Or `<a href="{{ .ConfirmationURL }}">sign in with one
     tap</a>`. Didn't ask for this? Ignore it; nobody can sign in without the code."
     **`{{ .Token }}` is required**: without it the email only has a link, and the code
     box (modal, claim page, embed) has nothing to take.
   - **Reset Password** — Subject: `Reset your Exos password`. Body: "Someone asked to
     reset the password for this email. `<a href="{{ .ConfirmationURL }}">Choose a new
     password</a>`. The link works once and expires in 1 hour. Didn't ask? Ignore this
     email; your password stays the same."
   - **Change Email Address** — Subject: `Confirm your new Exos email`. Body: "Confirm
     changing your Exos email from {{ .Email }} to {{ .NewEmail }}: `<a
     href="{{ .ConfirmationURL }}">Confirm the change</a>`. Didn't ask? Ignore this
     email and your address stays the same."
   - **Reauthentication** (secure password change) — Subject: `Your Exos verification
     code`. Body: "Enter **{{ .Token }}** to confirm your password change."
   - Mail scanners that pre-open links can burn one-time links. If that shows up in
     support, switch a template to link straight to the app with the hashed token, e.g.
     `{{ .SiteURL }}/auth/callback?token_hash={{ .TokenHash }}&type=signup` (or
     `/reset-password?token_hash={{ .TokenHash }}&type=recovery`); both pages verify
     `token_hash` links. Mind the Site URL (with or without `/bridge`) when doing this.
4. **Authentication → Emails → SMTP Settings**: custom SMTP through Resend (the same
   provider `exos-mail-drain` uses). Host `smtp.resend.com`, port 465, user `resend`,
   password: a Resend API key with sending access only, sender: the verified address in
   `EXOS_MAIL_FROM` (e.g. `Exos <tickets@yourdomain>`). Supabase's built-in mailer only
   delivers to team members and a handful of mails an hour; it's not usable for real
   users.
5. **Authentication → Rate Limits**: with custom SMTP, raise "emails sent" from the
   default to about 100 / hour to start. Keep the per-address resend interval at 60 s
   (the app's cooldown matches). "Token verifications" and "sign-ups and sign-ins" can
   stay at their defaults.
6. **Providers** (already set up for Google / Apple / Azure): make sure each provider's
   redirect goes through Supabase (`https://<project>.supabase.co/auth/v1/callback`) and
   that nothing points at the old per-page URLs; the app now sends OAuth back through
   `/bridge/auth/callback`.

## Testing

- Unit: `src/lib/authUrls.test.ts` (redirect builder, return-path sanitizer),
  `src/lib/authRules.test.ts` (password rules, error mapping),
  `src/components/AuthModal.test.tsx` (sign-in errors, email code, forgot password,
  sign-up + resend cooldown), `src/views/AuthLanding.test.tsx` (`/reset-password`,
  `/auth/callback`).
- By hand, after the checklist: sign up → confirm from a phone; sign in with a code from
  the claim page; forgot password → open the link twice (second time shows "expired");
  change email; change password on a session older than a day (secure password change);
  sign out of all devices and check a second browser is signed out within the hour (the
  access token lives until it expires).
