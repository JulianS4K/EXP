# Native apps (iOS and Android)

**Exos Door** is the Exos SPA in a [Capacitor 8](https://capacitorjs.com) shell for iOS and Android, plus native
modules where a web view falls short: the door camera, a durable copy of the offline scan queue, haptics,
keep-awake, Apple Wallet, and native Google / Apple sign-in. It is not a React Native rewrite. The SPA is
**bundled into the app** (`apps/native/www`), never loaded from a remote `server.url`.

The app opens on the door (`/door`), but the whole SPA is in it (My Tickets, event pages, checkout). Store
accounts, D-U-N-S and the custom domain come later, so everything here builds and runs locally; the
store steps are listed under [Operator steps](#operator-steps).

Related: `docs/pci.md` (the app never hosts a card field), `docs/native-sharing.md` (the `window.ExosNative`
Stories bridge, not built in the app yet), `docs/wallet.md`, `docs/auth.md`.

## Layout

| Path | What |
|---|---|
| `src/lib/platform/native.ts` | Is this page in the app (runtime)? Was it built for the app (build flags)? The public web URL used for links out |
| `src/lib/platform/adapters.ts` | The adapter interfaces and their **web defaults** (today's browser behaviour) |
| `src/lib/platform/nativeAuth.ts` | Which sign-in buttons show where, and the ID-token sign-in |
| `src/lib/platform/deepLinks.ts` | Universal / App Links → app routes (allow-listed) |
| `src/lib/platform/install.web.ts` | The web installer: a no-op |
| `src/lib/door/pendingStore.ts` | The door's offline scan queue: localStorage, mirrored to native storage in the app |
| `apps/native/` | The Capacitor project: its own `package.json` + lockfile (exact pins), `capacitor.config.ts`, `ios/`, `android/` |
| `apps/native/src/install.ts` | The native installer: registers the Capacitor adapters before React mounts |
| `apps/native/src/scanner.ts`, `auth.ts` | ML Kit scanner + overlay; `@capgo/capacitor-social-login` |
| `apps/native/ios/App/App/ExosWalletPlugin.swift` | A local plugin: `.pkpass` bytes → the system "Add to Apple Wallet" sheet |
| `apps/native/deep-links/` | AASA, `assetlinks.json` and iOS entitlements templates |
| `apps/native/fastlane/` | `ios beta` (TestFlight) and `android internal` (Play internal track) |

Native dependencies live **only** in `apps/native/package.json`. The root `package.json` gains one script
(`build:native`) and no dependency, so the web build, `npm ci` and the CI audit are unchanged.

## How the SPA behaves in the app

**Detection** (`detectNativeApp`): Capacitor's `isNativePlatform()`, or the `ExosApp/1` user-agent token the
shell appends (`appendUserAgent`), or the `window.ExosNative` bridge. Inside the app, `lib/inAppBrowser`
reports **no in-app browser**: an app web view otherwise looks like one (iOS WKWebView has no `Safari/`,
Android's has `; wv)`), which would hide Google sign-in and the Wallet buttons and show "open in your
browser" banners.

**The native build** (`vite build --mode native`, `npm run build:native`):

| | Web build | Native build |
|---|---|---|
| Base path / router basename | `/bridge/` | `/` (Capacitor serves `www/` at its origin root; not `./`, which breaks deep routes under `BrowserRouter`) |
| Output | `dist/` | `apps/native/www/` |
| Service worker | registered | none (`sw.js` removed; the app is the offline shell) |
| Ad pixels | per org, with consent | **off**: no pixel loads, so no App Tracking Transparency prompt. Server-side conversions (`docs/marketing-conversions.md`) still report |
| Group chat (`/groups`) | behind `VITE_EXOS_SOCIAL` | **always off** (App Store 1.2: user-generated content needs reporting / blocking we don't ship in the app) |
| Stripe.js (Embedded Checkout) | venue embed only | **not in the bundle**: the `/embed/*` routes and views are left out (`App.tsx` `NATIVE_BUILD`), `lib/stripe.ts` imports `@stripe/stripe-js/pure` (nothing loads on import), and `getStripe` rejects. No card field in the app |
| Content-Security-Policy | per page, HTTP header (`src/lib/hosting/headers.ts`) | a `<meta http-equiv>` in `index.html` (`src/lib/platform/nativeCsp.ts`): scripts from the app and Google Maps only (no inline script, no Stripe, pixels, PayPal or Turnstile); network to this Supabase project, the web app's origin, Sentry and Maps; frames for the event video only |
| Links out (Stripe return pages, shares, auth mails) | the page's origin | `VITE_EXOS_WEB_URL` (required; the build fails without it) |
| Platform installer | `install.web.ts` (no-op) | `apps/native/src/install.ts` (alias `@exos/platform-install`) |

**Adapters** (`platform()`), each with a web default:

| Adapter | Web (unchanged) | Native |
|---|---|---|
| `scanner` | `null`: the door's html5-qrcode | ML Kit `startScan` (QR, Aztec, PDF417, Data Matrix, Code 128). The camera draws behind the web view, so the page hides and an overlay shows a frame, the last answer (green / red / amber), Torch and Done. One read per presentation (`scanDeduper`), a haptic per read and per answer. If the camera won't open, the door falls back to html5-qrcode |
| `storage` | localStorage | Capacitor Preferences (UserDefaults / SharedPreferences). The door's scan queue stays in localStorage and is mirrored here; a queue the OS cleared is restored on the next open |
| `walletAdd` | not handled: `WalletButtons` as before | Google: the save link in the browser sheet. Apple: `ExosWallet.addPass` (the pass bytes from `exos-wallet`, as before) |
| `openExternal` | new tab | browser sheet (SFSafariViewController / Custom Tabs) |
| `openCheckout` | same-tab redirect to Stripe | Stripe's hosted page in the browser sheet (Apple Pay / Google Pay work there; they don't in a web view with injected scripts), then back to the page's `returnTo` when it closes. A URL on the web app (free order, gift card) or an app path opens the app's own copy; any other scheme is refused (`checkoutTarget`). Used by ticket checkout, gift cards and passes (`/shop`), donations and the donor portal (`/give`), the membership billing portal and group pay |
| `nativeAuth` | `null`: the OAuth redirect | `@capgo/capacitor-social-login` → `supabase.auth.signInWithIdToken` (hashed nonce to Google / Apple, raw nonce to Supabase), then the plugin's own copy of the identity token is dropped (`forget`, `SocialLogin.logout`) |
| `door` | `null` | keep the screen on while the door page is open |

Also: PayPal / Venmo opens the public PayPal page in the browser sheet (its SDK never loads in the app).
A **waiting room with its human check on** shows "Join the line in the browser", which opens the public
event page in the browser sheet: an app web view reports `localhost` to Turnstile, and the server never
accepts a loopback hostname (`_shared/wroomJoin.ts`), so the place in line and the purchase happen there.
Universal / App Links to `/door`, `/checkin/…` and `/my-tickets` (and the same under `/bridge`) open that
route in the app (only on the web app's host or `VITE_EXOS_APP_LINK_HOSTS`; anything else is ignored).

**Sign-in in the app** (`providerPlan`): Google and Apple only through the native sheets that are set up;
Microsoft never (its redirect would leave the app); email (password or the 6-digit code) always. On iOS,
Google shows only next to Sign in with Apple (App Store 4.8). Apple on Android isn't offered (it is a web
redirect through a backend). Magic links and confirmation mails open the web app; in the app, use the code.

## Build and run locally

```bash
npm ci                                   # the web app (repo root)
cd apps/native && npm ci                 # the shell (its own lockfile)
bundle install                           # macOS: CocoaPods + fastlane from the Gemfile (cap sync runs `bundle exec pod install`)
VITE_EXOS_WEB_URL=https://<web host>/bridge \
VITE_SUPABASE_URL=… VITE_SUPABASE_ANON_KEY=… \
  npm run sync                           # vite --mode native → www/, then cap sync
npm run check                            # tsc for the shell
npx cap open ios                         # macOS + Xcode (open App.xcworkspace)
npx cap open android                     # Android Studio
```

Build-time settings (Vite env, `.env.native` or the shell; none is a secret):

| Variable | |
|---|---|
| `VITE_EXOS_WEB_URL` | **Required.** The public web app with its base, e.g. `https://exos-web.onrender.com/bridge` |
| `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` | As for the web build |
| `VITE_EXOS_GOOGLE_WEB_CLIENT_ID` | Google "Web application" OAuth client (Android; also listed in Supabase) |
| `VITE_EXOS_GOOGLE_IOS_CLIENT_ID` | Google "iOS" OAuth client |
| `VITE_EXOS_APPLE_SIGN_IN=on` | Offer Sign in with Apple (iOS) |
| `VITE_EXOS_APP_LINK_HOSTS` | Extra hosts whose door links open the app (the custom domain), comma-separated |

**iOS uses CocoaPods**, not Swift Package Manager: ML Kit has no SPM package. Deployment target 15.5. ML
Kit's pods don't build for the arm64 simulator: test on a device (or an x86_64 simulator). The root view
controller is `ExosBridgeViewController` (`SceneDelegate.swift`), which registers the local `ExosWallet`
plugin. `Library/WebKit` (the web view's storage) and `Library/Preferences` are excluded from iCloud /
computer backups at every launch (`AppDelegate.swift`), as on Android.

**Android** targets and compiles against API 36 (`android/variables.gradle`), min API 24. Backups are off
(`allowBackup="false"`, `data_extraction_rules.xml`): the door's roster and queue must not leave the device.
Capacitor adds its bridge as a document-start script, which the CSP doesn't cover; a WebView too old for
that (not updated in years) gets the bridge as an inline script, which the CSP blocks, and the app then
runs with the web defaults.

**In a desktop browser**, `apps/native/www` runs with the web defaults (Capacitor reports `web`), which is
handy for checking the bundle.

## What is and isn't verified here

Checked in this repo's container: `npm ci`, `lint`, `lint:a11y`, vitest, the web build, the native-mode
build, `npm audit --omit=dev --audit-level=high` (root) and `npm audit` (shell), the browser smoke + axe run,
`npx cap sync` (Android complete; iOS copies the bundle and plugin list, then stops at `bundle exec pod install`: no CocoaPods here, and `npx cap sync android` exits 0), `npx cap doctor` (Android OK), `tsc` for the
shell, and `fastlane lanes` (both lanes parse).

**Not verified (no Xcode, CocoaPods, Android SDK or devices here):** compiling either native project
(including `ExosWalletPlugin.swift`, its registration through `ExosBridgeViewController`, the backup
exclusion and the hand-added Xcode project entries), the CSP against Capacitor's bridge and Google Maps on a
device, the waiting room hand-off to the browser sheet, the ML Kit overlay on a
real camera, haptics, keep-awake, native Google / Apple sign-in against Supabase, the browser-sheet
checkout and its return, Preferences, App Links / Universal Links, and the fastlane uploads. Do these on
devices before the first TestFlight / internal build.

## Store rules this design follows

**Apple (App Review Guidelines)**
- **3.1.3(e) / 3.1.1:** tickets to live events are services consumed outside the app, so they are paid
  with Stripe (or PayPal), not in-app purchase. Nothing digital is unlocked in the app by paying.
- **4.2 minimum functionality:** the app is not a repackaged website: native camera scanning, an offline
  queue that survives web storage being cleared, haptics, keep-awake, Apple Wallet, native sign-in.
- **4.7.2 / 2.5.2:** the SPA is bundled in the binary (no remote `server.url`, no code download), and no
  remote web content gets native APIs: pages outside the app open in the browser sheet.
- **4.8 login services:** Google is offered only next to Sign in with Apple; email works without either.
- **5.1.1(v) account deletion:** in the app at Profile → Delete account (`DeleteAccountPanel`).
- **1.2 user-generated content:** group chat is not in the app.
- **2.1 app completeness:** App Review needs a demo login that can open the door on a test event.
- **5.1.2 / App Privacy:** no third-party tracking in the app (pixels off), so no ATT prompt. Fill in the
  App Privacy labels (account email, purchases, camera used on device only). Check Xcode's privacy report
  for each pod's privacy manifest.

**Google Play**
- **Payments policy:** Google Play billing isn't required for physical goods or services, which includes
  tickets to live events; Stripe / PayPal it is.
- **Target API:** API 36 (Android 16); check the Console's target-level notice before the first upload.
- **Account deletion:** in the app (as above), and Play's Data safety form also needs a web link to it.
- **Data safety** form, the camera permission's purpose, and a reviewer login, as for Apple.
- **Webview apps:** same answer as Apple 4.2.

## Operator steps

1. **App id.** `com.exos.door` is a placeholder; set the final one before the first upload (it can't change
   after): `appId` in `capacitor.config.ts`, `applicationId` in `android/app/build.gradle` (leave
   `namespace`), `PRODUCT_BUNDLE_IDENTIFIER` in Xcode, `EXOS_APP_ID` for fastlane, and the deep-link
   templates. Replace the default icons and splash (e.g. `npx @capacitor/assets generate`).
2. **Apple:** Developer Program (an organization needs D-U-N-S), the App ID with **Sign in with Apple** and
   **Associated Domains**, the App Store Connect app record, and an App Store Connect API key (JSON, kept
   outside the repo). In Xcode: the team, then those two capabilities (end state:
   `apps/native/deep-links/App.entitlements.template`), and the Google iOS client's reversed id as a URL
   type.
3. **Google Play:** the Play Console app, Play App Signing, an upload keystore (outside the repo), and a
   service account with release access (JSON key).
4. **Google sign-in:** Google Cloud OAuth clients: Web (its id is `VITE_EXOS_GOOGLE_WEB_CLIENT_ID`), iOS
   (bundle id), Android (package + the SHA-1 of the upload and Play signing keys). In Supabase → Auth →
   Google, add the iOS and web client ids to the authorized client ids.
5. **Apple sign-in:** in Supabase → Auth → Apple, add the bundle id to the client ids; set
   `VITE_EXOS_APPLE_SIGN_IN=on`.
6. **Edge function origins (CORS only):** the app calls the edge functions from `capacitor://localhost`
   (iOS) and `https://localhost` (Android). Set the edge secret
   `EXOS_CORS_EXTRA_ORIGINS=capacitor://localhost,https://localhost` (`_shared/corsOrigins.ts`; only those
   two and `http://localhost` are accepted, no wildcard). It only widens the CORS answer of the ten
   functions that echo allow-listed origins. **Do not** add localhost origins to `EXOS_REDIRECT_ORIGINS`
   (or Supabase Auth's redirect URLs): that list decides where Stripe, OAuth and the waiting room may send
   or accept a browser, and a localhost entry could hand a return URL to another app on the device. The
   inventory of both lists is in `docs/security.md` "Allowed origins". Check each function the app uses
   on a device.
7. **Universal / App Links:** a custom domain whose root serves the Exos web app, serving
   `/.well-known/apple-app-site-association` and `/.well-known/assetlinks.json` (from the templates: team
   id, app id, the Play signing SHA-256) as `application/json`. That route on the domain root is a
   `server.ts` change still to make (Vite's `public/` lands under `/bridge/`). Then set
   `exosAppLinkHost` in `android/gradle.properties` and the associated domains in Xcode.
8. **Store builds** (`apps/native`, Ruby + `bundle install`):

   ```bash
   APP_STORE_CONNECT_API_KEY_PATH=… EXOS_IOS_TEAM_ID=… VITE_EXOS_WEB_URL=… VITE_SUPABASE_URL=… VITE_SUPABASE_ANON_KEY=… \
     bundle exec fastlane ios beta            # → TestFlight
   PLAY_JSON_KEY_PATH=… EXOS_UPLOAD_KEYSTORE=… EXOS_UPLOAD_KEYSTORE_PASSWORD=… EXOS_UPLOAD_KEY_ALIAS=… EXOS_UPLOAD_KEY_PASSWORD=… \
   VITE_EXOS_WEB_URL=… VITE_SUPABASE_URL=… VITE_SUPABASE_ANON_KEY=… \
     bundle exec fastlane android internal    # → Play internal testing (draft)
   ```

   Both lanes upload only; review submission and release stay manual. The first Play upload of a new app
   has to be done by hand in the Console.
9. **Store listings:** screenshots, App Privacy / Data safety, the export compliance answer (HTTPS and the
   OS's own crypto only), age rating, and the reviewer demo account.

## Not built yet

- **Checkout return:** closing the browser sheet goes to My Tickets, paid or not; a guest's "check your
  email" page shows in the sheet. A return straight into the app needs the success page on a Universal
  Link domain, or a custom-scheme "Back to the app" link.
- **Checkout analytics:** `exos-checkout` reads Android app checkouts as `in_app_browser = 'webview'` (the
  user agent's `; wv)`). Teaching it the `ExosApp/` token needs the SQL mirror changed too (a migration).
- **The `window.ExosNative` Stories bridge** (`docs/native-sharing.md`): the app doesn't inject it yet.
- **Apple sign-in on Android**, push notifications, Tap to Pay (`docs/pci.md` "Box office cards").
