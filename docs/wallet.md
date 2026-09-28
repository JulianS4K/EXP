# Apple Wallet and Google Wallet passes

Status (2026-09-29): backend authored, **not applied or deployed**. Migration
`20260929072000_exos_wallet_passes`, edge function `exos-wallet`, pure builders in
`supabase/functions/_shared/wallet/`, tests in `src/lib/wallet/` and
`tests/exos/test_wallet_passes.sql`. The SPA buttons (TicketDetail) aren't built yet.
Until the operator adds credentials, every wallet route answers **503 "wallet not
configured"**, and nothing is ever signed with a made-up key.

## What the holder gets

- **Apple Wallet:** a signed `.pkpass`. It updates itself: when the ticket changes, Exos
  pushes, the iPhone asks what changed, and it downloads the new pass. After a transfer
  or refund, the new pass is marked `voided` and has no code.
- **Google Wallet:** a "Save to Google Wallet" link. The pass shows a **rotating** QR
  code (Google's `rotatingBarcode`, TOTP-based). After a transfer or refund its object
  goes `INACTIVE`.

Both show the event name, the local start and doors times (in the event's time zone,
whatever the phone's zone), the venue, the tier and section, and the attendee name when
one is set. They don't show the buyer's email, the price or any account id beyond what
the door code already carries (the ticket id and the holder's user id, the same as the
app's QR).

## The door codes

The app's QR rotates every 30 seconds: `T-{ticket}:{owner}:{bucket}:{HMAC-SHA256(barcode_secret)}`
(`src/lib/barcode.ts`), and `exos_check_in_ticket` accepts ±2 buckets. A pass can't run
that code, so passes carry a `W-` code, which `exos_check_in_ticket` now also accepts
(the migration patches it; the scanner's local check in `src/lib/barcode.ts` knows it too):

| Pass | Code | Proof |
|---|---|---|
| Google | `W-{ticket}:{owner}:g{epoch}:{8 digits}` | RFC 6238 TOTP, HMAC-SHA1, 30 s steps, ±2 steps at the door. Key = first 20 bytes of `HMAC-SHA256(barcode_secret, "wallet-g:{ticket}:{owner}:{epoch}")` |
| Apple | `W-{ticket}:{owner}:a{epoch}:{mac}` | `base64url(HMAC-SHA256(barcode_secret, "wallet-a:{ticket}:{owner}:{epoch}"))` |

The door accepts a `W-` code only if the ticket's **live** pass (`exos_wallet_passes`,
status `active`) belongs to the current owner and is at that `epoch`. After that, the
usual checks apply: event scope, doors open, not in transfer, not voided, single use
(the atomic `active → used` flip).

The code and the TOTP key are derived **in SQL** (`_exos_wallet_apple_code`,
`_exos_wallet_google_key`). The edge function gets them from `exos_wallet_pass_payload`
and never sees `barcode_secret`. The `wallet-a:` / `wallet-g:` prefixes keep these MACs
apart from the `T-` HMAC. `src/lib/wallet/walletCodes.test.ts` and
`test_wallet_passes.sql` (W0) pin the TypeScript and SQL versions to the same vectors.

### What each code resists (the security trade-off)

| Threat | App (`T-`) | Google (`W-…g`) | Apple (`W-…a`) |
|---|---|---|---|
| Screenshot shared ahead of the event | dies in about 90 s | dies in about 90 s | **works until the pass updates** |
| Screenshot after a transfer | dead (new owner + secret) | dead | dead |
| After a refund / release | dead (voided) | dead (pass voided) | dead (pass voided) |
| Holder reissues ("my pass leaked") | n/a | new key, old codes dead | new code, old one dead |
| Same code at two doors | first scan wins | first scan wins | first scan wins |

**Apple is the weak one.** iOS can't render a rotating code for a third-party pass, so
the Apple code is static between updates: anyone with a screenshot can use it until the
holder is admitted or the pass changes. It is no worse than a PDF ticket and much better
than an unsigned one:

- it's single use: whoever scans first gets in, and the loser's "already used" answer
  shows when and at which door;
- a transfer rotates the secret and changes the owner, so every earlier wallet code
  (Apple or Google) dies at the door straight away, even before any push lands;
- a refund / release / organizer void voids the pass at once (trigger), so its code is
  refused;
- the holder can **reissue** (`POST /exos-wallet/reissue`): the epoch goes up, the old
  code is refused, and the pass updates with the new one;
- `sharingProhibited` is set, so Wallet's own share button is off.

If an event needs screenshot-proof entry, have holders use the app (rotating `T-`) or
Google Wallet (rotating TOTP). A per-event "no static wallet codes" switch would be a
small follow-up: refuse `a{epoch}` codes for events that set it.

The pass also carries `relevantDate` / `relevantDates` (doors, from an hour before, to the
end) and the venue location, so it comes up on the lock screen at the right time and place.

### Offline doors

The scanner's local check verifies the `W-` signature (MAC or TOTP) with the ticket's
cached secret. It can't see the live epoch, so a reissued pass's old code admits
offline. The upload (`exos_check_in_offline`) then re-verifies at the scan time against
the live epoch, and a stale code comes back as a **conflict** in the scan report, the same
as a ticket transferred after the roster download (test W10).

## How it flows

```
holder (SPA) --JWT--> POST /exos-wallet/pass {ticket_id, kind}
                         exos_wallet_issue_pass     (SQL, as the holder: owner check)
                         exos_wallet_pass_payload   (service role: code / key, no secret)
                         apple:  pass.json -> manifest (SHA-1) -> PKCS#7 signature -> .pkpass
                         google: store class + object (REST), return a save link

ticket change (void / transfer / check-in / reissue)
   -> trigger exos_tg_wallet_ticket_changed: void (epoch+1) or refresh; push_pending = true
cron POST /exos-wallet/push (x-cron-secret)
   -> exos_wallet_push_queue -> APNs push per device (Apple) / object PUT (Google)
   -> exos_wallet_push_done (only passes that didn't change again meanwhile)
iPhone -> GET  /apple/v1/devices/{device}/registrations/{passType}?passesUpdatedSince=tag
       -> GET  /apple/v1/passes/{passType}/{serial}   (ApplePass token, If-Modified-Since → 304)
```

- **One live pass per ticket.** The Apple pass and the Google object share the serial.
  A void never comes back: the new holder after a transfer gets a **new serial**, so the old
  holder's phone keeps fetching the old serial, which is voided.
- **authenticationToken:** 32 random bytes, stored only as its SHA-256
  (`auth_token_hash`, not readable by clients). Each `.pkpass` download makes a new token
  (the new file replaces the old one in Wallet).
- **Google:** the object is stored server to server, and the save JWT names only its id,
  so the TOTP key never appears in a URL. Google gets the derived key and never
  `barcode_secret`.

### Tables and grants

| Object | Who |
|---|---|
| `exos_wallet_passes` | holder: `SELECT` of own rows, without `auth_token_hash`; no client writes |
| `exos_wallet_registrations` | service role only |
| `exos_wallet_issue_pass`, `exos_wallet_reissue` | `authenticated`; the caller must own the ticket |
| `exos_wallet_pass_payload`, `exos_wallet_fetch_pass`, `exos_wallet_register_device`, `exos_wallet_unregister_device`, `exos_wallet_updated_serials`, `exos_wallet_push_queue`, `exos_wallet_push_done`, `exos_wallet_drop_push_tokens` | service role only; the PassKit ones check the ApplePass token |
| `_exos_wallet_*` helpers | nobody (called from SECURITY DEFINER functions) |

## Routes (`exos-wallet`)

| Route | Auth | Answer |
|---|---|---|
| `POST /exos-wallet/pass` `{ticket_id, kind:"apple"}` | Supabase JWT (holder) | `.pkpass` (`application/vnd.apple.pkpass`) |
| `POST /exos-wallet/pass` `{ticket_id, kind:"google"}` | Supabase JWT (holder) | `{ save_url, serial }` |
| `POST /exos-wallet/reissue` `{ticket_id}` | Supabase JWT (holder) | `{ ok, code_epoch }` |
| `POST /exos-wallet/push` | `x-cron-secret` | summary; a dry run until pushes are configured |
| `POST /exos-wallet/apple/v1/devices/{d}/registrations/{pt}/{serial}` | `ApplePass <token>` | 201 new / 200 known / 401 |
| `DELETE` same path | `ApplePass <token>` | 200 / 401 |
| `GET /exos-wallet/apple/v1/devices/{d}/registrations/{pt}?passesUpdatedSince=` | none (Apple sends none) | 200 `{serialNumbers, lastUpdated}` / 204 |
| `GET /exos-wallet/apple/v1/passes/{pt}/{serial}` | `ApplePass <token>` | 200 `.pkpass` / 304 / 401 |
| `POST /exos-wallet/apple/v1/log` | none | 200 (logs 10 lines at most, 300 chars each) |

Errors: 403 not your ticket; 409 `not-active` / `in-transfer` / `no-secret` / `no-pass`;
503 wallet not configured.

## Operator setup

Everything here needs operator permission (secrets, deploys and migrations on the shared
project). Do it in this order.

### 1. Apple

1. Apple Developer → Certificates, IDs & Profiles → **Identifiers → Pass Type IDs** →
   register one, e.g. `pass.com.exos.ticket`.
2. Create its **Pass Type ID Certificate** (upload a CSR), download the `.cer`, and
   export the certificate + private key from Keychain as a `.p12`.
3. Download Apple's **WWDR intermediate** (G4) certificate.
4. Convert to PEM (the key must be unencrypted; the function refuses encrypted keys):
   ```bash
   openssl pkcs12 -in pass.p12 -clcerts -nokeys -out pass-cert.pem
   openssl pkcs12 -in pass.p12 -nocerts -nodes -out pass-key.pem
   openssl x509 -inform DER -in AppleWWDRCAG4.cer -out wwdr.pem
   ```
5. The Team ID is on the Membership page.

### 2. Google

1. [Google Pay & Wallet Console](https://pay.google.com/business/console) → Google
   Wallet API → note the **Issuer ID** (numeric). Request publishing access when ready.
2. Google Cloud: enable the **Google Wallet API**, create a service account, make a JSON
   key, and add the service account's email as a user in the Wallet console (Developer).

### 3. Secrets (never commit, never log)

| Env | Value |
|---|---|
| `EXOS_WALLET_APPLE_PASS_TYPE_ID` | e.g. `pass.com.exos.ticket` |
| `EXOS_WALLET_APPLE_TEAM_ID` | Apple Team ID |
| `EXOS_WALLET_APPLE_CERT` | `pass-cert.pem` contents |
| `EXOS_WALLET_APPLE_PRIVATE_KEY` | `pass-key.pem` contents (unencrypted PKCS#8 or PKCS#1 RSA) |
| `EXOS_WALLET_APPLE_WWDR_CERT` | `wwdr.pem` contents |
| `EXOS_WALLET_APPLE_PUSH` | `live` to send APNs pushes (see below); anything else = dry run |
| `EXOS_WALLET_PUBLIC_URL` | optional; defaults to `$SUPABASE_URL/functions/v1/exos-wallet` (must be https) |
| `EXOS_WALLET_GOOGLE_ISSUER_ID` | numeric issuer id |
| `EXOS_WALLET_GOOGLE_SERVICE_ACCOUNT_KEY` | the service account JSON key |
| `EXOS_WALLET_GOOGLE_ORIGINS` | optional, comma-separated origins for the save JWT (e.g. the site) |
| `CRON_SECRET` | already set for the other crons |

The two private-key secrets end in `_KEY`, so `_shared/log.ts`'s scrubber redacts their
values from any error report. The function logs fixed messages only, never PEM or JSON
contents.

```bash
supabase secrets set --project-ref hzrizjeaxlqcxfrtczpq \
  EXOS_WALLET_APPLE_PASS_TYPE_ID=pass.com.exos.ticket EXOS_WALLET_APPLE_TEAM_ID=XXXXXXXXXX \
  EXOS_WALLET_APPLE_CERT="$(cat pass-cert.pem)" EXOS_WALLET_APPLE_PRIVATE_KEY="$(cat pass-key.pem)" \
  EXOS_WALLET_APPLE_WWDR_CERT="$(cat wwdr.pem)" \
  EXOS_WALLET_GOOGLE_ISSUER_ID=3388000000000000000 \
  EXOS_WALLET_GOOGLE_SERVICE_ACCOUNT_KEY="$(cat sa.json)"
```

### 4. Migration, then deploy

1. Apply `20260929072000_exos_wallet_passes` (it patches `exos_check_in_ticket`, so it
   needs `20260929040000_exos_door_hardening` first).
2. Ship the SPA bundle carrying the `src/lib/barcode.ts` change, so that **offline**
   scanners accept `W-` codes. Online scans are checked on the server either way.
3. Deploy:
   ```bash
   supabase functions deploy exos-wallet --no-verify-jwt --project-ref hzrizjeaxlqcxfrtczpq
   ```
   **Why `--no-verify-jwt`:** Apple's servers and devices call the PassKit web service
   (`/apple/v1/...`) with no Supabase JWT, only `Authorization: ApplePass <token>`, and
   the gateway would reject them. Every route authenticates in code instead: the holder
   routes call `auth.getUser()` and the database checks ownership, the PassKit routes
   check the pass token hash, and `/push` needs `x-cron-secret`.
4. Schedule the push run every few minutes (pg_cron + pg_net, like the other drains):
   `POST .../functions/v1/exos-wallet/push` with header `x-cron-secret`.

### APNs pushes: verify before switching on

Apple pass pushes go over HTTP/2 to `api.push.apple.com`, authenticated with the Pass
Type ID certificate as a **TLS client certificate**. The function uses
`Deno.createHttpClient({ cert, key })` when the runtime has it. That hasn't been verified
on Supabase's edge runtime. Until `EXOS_WALLET_APPLE_PUSH=live` is set and tested,
`/push` is a dry run: it reports `planned_not_sent` and leaves the passes push-pending.
Devices still pick up changes when Wallet refreshes on its own, or when the holder pulls to
refresh the pass. The door never depends on a push: voids and transfers are enforced in
SQL at once. If the runtime can't do client certificates, send pushes from a small relay
that has the certificate. Google needs no push: `/push` rewrites the object, and Google
syncs it to the phone.

## Tests

- `npx vitest run src/lib/wallet`: pass.json fields, local times, manifest SHA-1,
  bundle round trip with a fake signer, a real PKCS#7 signature with throwaway keys
  (verified with WebCrypto; also checked by hand with `openssl cms -verify`), the Google
  class / object / `rotatingBarcode`, JWT claims with a fake signer (and a real RS256
  one), the skinny-JWT flow with a fake fetch, token checks, void / transfer rules, routes
  and the APNs pusher.
- `tests/exos/test_wallet_passes.sql` (in `run_p0.sh`, also after the replay): owner-only
  issue, RLS / grants (another user can't create, read, register or fetch a pass for
  someone else's ticket), token-checked PassKit functions, both codes at the door, reissue,
  transfer and refund voiding, push queue, and offline replay.

## Design notes

The hi.events `Services/Domain/Wallet` module that CLAUDE.md points to isn't in its
current `main` (checked 2026-09-29), and pretix does wallet passes in a separate plugin
(passbook) that wasn't reviewed. So this design follows Apple's PassKit web service and
Google's Wallet REST references directly, plus Exos's own door rules
(`20260702120000`, `20260929040000`).
