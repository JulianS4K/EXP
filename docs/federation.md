# Federation (ActivityPub)

People on Mastodon, Lemmy, Threads and other ActivityPub servers can follow an Exos [community](communities.md)
without an Exos account. Each public community whose organizer turned on "Share on the fediverse" is an ActivityPub
`Group`, the type Lemmy uses for its communities.

**Off by default.** Nothing federates unless `EXOS_FEDERATION=on` is set on both the `exos-activitypub` edge function
and the web server (`server.ts`), and the delivery cron is turned on. With it off every federation path is a 404 and
nothing is sent anywhere.

- **Code:** `supabase/functions/exos-activitypub/index.ts`; pure modules in `supabase/functions/_shared/activitypub/`:
  `signature.ts` (HTTP Signatures), `objects.ts` (actor / object / activity JSON), `fetchGuard.ts` (SSRF-guarded
  fetch, on `_shared/ssrf.ts`); SQL in `20261031200000_exos_communities.sql` (`exos_ap_*`).
- **Tests:** `src/lib/activitypub.test.ts` (signature vectors, JSON shapes, SSRF cases), section C11 of
  `tests/exos/test_communities.sql`.

## Names and URLs

All ids live on the app's public origin, `EXOS_AP_ORIGIN` (e.g. `https://exos.app`, no path).

| Thing | URL |
|---|---|
| WebFinger | `/.well-known/webfinger?resource=acct:<name>@<host>` (also `!name@host` and the actor URL) |
| NodeInfo | `/.well-known/nodeinfo` → `/nodeinfo/2.1` |
| Community (Group) | `/ap/c/<name>`, with `/inbox`, `/outbox`, `/followers`, `/moderators` |
| Org (Person, the posts' author) | `/ap/o/org_<org slug>` |
| Shared inbox | `/ap/inbox` |
| Post / event | `/ap/p/<uuid>`, `/ap/e/<uuid>` (and `/ap/e/<uuid>/page`, the Lemmy form of an event) |

`<name>` is the community slug with `-` as `_` (Lemmy community names are `[a-z0-9_]`); it's unique, so `run-club` and
`run_club` can't both exist. Community slugs can't start with `org_`. On Mastodon search `@bar_run_club@exos.app`, on
Lemmy `!bar_run_club@exos.app`.

A browser opening an actor or object URL (no ActivityPub `Accept`) is redirected to the community or event page.

## Hosting

The edge function is reached through a reverse proxy on the app domain that keeps the path, because inbound
signatures cover the path and `host`. `server.ts` does this when `EXOS_FEDERATION=on`: it forwards
`/.well-known/webfinger`, `/.well-known/nodeinfo`, `/nodeinfo/*` and `/ap/*` to
`<VITE_SUPABASE_URL>/functions/v1/exos-activitypub/<same path>` with the raw body (256 KB cap) and the
signature headers. **When the public domain is Terminal-2's** (which proxies only `/bridge/*` to `exos-web` today),
Terminal-2 must forward those root paths too; that is a change in Terminal-2, not made here.

Deploy the function with `--no-verify-jwt`. Secrets: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `CRON_SECRET`,
`EXOS_FEDERATION=on`, `EXOS_AP_ORIGIN`, `EXOS_APP_BASE_URL` (where HTML links go, e.g. `https://exos.app/bridge`).

## What's federated

| Exos | ActivityPub | Lemmy-family followers | Others (Mastodon, Threads, …) |
|---|---|---|---|
| Public post with a title | `Page` (name, content, `audience` = the Group) | `Announce{Create{Page}}` | `Announce{Page}` |
| Public post without a title | `Note` | not sent (Lemmy has no top-level Note) | `Announce{Note}` |
| Event (not members-only) | `Event` (name, `startTime`, `endTime`, `location` Place, link) | `Announce{Create{Page}}` (the event as a post linking to tickets) | `Announce{Event}` |
| Post removed / hidden after it went out | `Delete` (Tombstone) | `Announce{Delete}` by the Group | `Delete` by the org Person |
| Members-only posts and events, unlisted / archived communities | nothing | | |

The Group's `attributedTo` is its moderators collection (Lemmy's convention), which lists the org's Person.
`postingRestrictedToMods` is true: only the organizer and hosts post. Posts are attributed to the org's Person;
a host's post says "(Posted by <host>)" in the text. The outbox lists the latest 20 items in the Lemmy form; the
followers collection is a count only.

"Lemmy-family" is decided per follower from their server's NodeInfo `software.name` at Follow time (`lemmy`, `mbin`,
`kbin`, `piefed`); unknown means the plain form.

## Inbox

Handled: `Follow` (of a federating community; auto-accepted, `Accept` queued), `Undo{Follow}`, `Create` of a
`Note` / `Page` / `Article` replying (`inReplyTo`) to one of our posts or events, `Delete` (of the sender's own reply,
or of the sender's account). Everything else gets 202 and is ignored.

Replies go to the **moderation queue** (`exos_ap_remote_replies`, `pending`), never straight onto the page. Their HTML
is reduced to plain text (scripts dropped, tags stripped, 5,000 chars) and they're shown as text after an owner /
manager approves them in Org settings → Communities. Limits: 20 replies an hour per remote account, 500 pending per
community, 5,000 followers per community. Owners / managers can block an account URL or a whole domain (subdomains
included); a block drops that follower and rejects their pending replies.

## Signatures

**Outbound** (draft-cavage-http-signatures-12): `Host`, `Date`, `Digest: SHA-256=…` and
`Signature: keyId="<actor>#main-key",algorithm="rsa-sha256",headers="(request-target) host date digest content-type"`,
RSA-SHA256 (PKCS#1 v1.5). One RSA-2048 key pair per actor (each community's Group, each org's Person), made on first
use with WebCrypto. The public key is in `exos_ap_actors` and the actor document; the **private key is a Supabase
Vault secret** (`exos_ap_key:<actor id>`), readable only through `exos_ap_signing_key` (service role).

**Inbound:** the signature must cover `(request-target)`, `host` and `date` (+ `digest` on POST); the `Date` must be
within 1 hour of now; the body's SHA-256 must match `Digest`; the algorithm must be `rsa-sha256` or `hs2019`
(Lemmy's label for the same). The key is the activity actor's: its document is fetched, `publicKey.owner` must be the
actor and `publicKey.id` the request's `keyId`, both on the actor's host. Keys are cached for a day
(`exos_ap_remote_actors`, service role only); a failed check refetches once (key rotation). The activity's object
(a reply, a deleted note) must be on the actor's host and, for a reply, attributed to the actor. 600 inbound requests a
minute per remote host, 300 GETs a minute per network.

## SSRF guard

Every remote fetch (actor documents, NodeInfo) and every delivery goes through `guardedFetch`: https only, no
credentials in the URL, no `localhost` / `.local` / `.internal` names, every A and AAAA address public (no private,
loopback, link-local, CGNAT, metadata, documentation, multicast or IPv6 transition ranges), 5–10 s timeouts,
256 KB (fetches) / 64 KB (delivery responses) caps while streaming, redirects followed by hand at most 3 times with
each hop re-checked, and none at all for POSTs. A blocked inbox is a permanent failure. Residual risk: DNS rebinding
between our lookup and `fetch()`'s own.

## Delivery

`exos_ap_deliveries` is the outbox: one row per (activity, inbox), shared inboxes deduplicated. The JSON is built when
it's sent, so a post removed in the meantime isn't sent. `exos_ap_claim` leases rows for 2 minutes; `exos_ap_mark`
records the result. Backoff after a failure: 1 min, 5 min, 30 min, 2 h, 6 h, 12 h, 24 h; dead after 8 attempts, or at
once on a 4xx other than 408 / 429 or a blocked URL. A 410 drops the follower. Turning federation off (or making the
community unlisted / archived) cancels what's queued.

**Delivery to remote servers is the only third-party write here**, and only to inboxes of servers that followed the
community, only with `EXOS_FEDERATION=on`.

The cron `exos-ap-deliver-1min` (POST `/exos-activitypub/deliver`, `X-Cron-Secret`) is created **inactive**. To turn
federation on:

1. Deploy `exos-activitypub` with the secrets above; set `EXOS_FEDERATION=on` on it and on the web server; check the
   proxy (`curl https://<host>/.well-known/nodeinfo`).
2. `SELECT cron.alter_job(jobid, active := true) FROM cron.job WHERE jobname = 'exos-ap-deliver-1min';`
3. An organizer turns on "Share on the fediverse" for a public community.

## Compatibility notes

Designed from Lemmy's and Mastodon's documented federation behavior, from memory (no network access while building;
Lemmy's code is AGPL and was not used). Not yet tested against live servers; check these first:

| Assumption | Verified? |
|---|---|
| Lemmy resolves `!name@host` with WebFinger and expects the `self` link's `properties` type `Group` | from Lemmy docs, not run |
| Lemmy accepts `Announce{Create{Page}}` from a Group whose posts are attributed to a `Person` on the same host, `audience` = Group | from Lemmy docs, not run |
| Lemmy reads the community outbox as a single `OrderedCollection` of those Announces | not verified |
| Lemmy's `moderators` collection via the Group's `attributedTo`; `postingRestrictedToMods` | from Lemmy docs, not run |
| Lemmy signs with `algorithm="hs2019"` (RSA-SHA256) | believed, not run |
| Mastodon shows a Group's `Announce` of an embedded `Note` / `Page` / `Event` as a boost (Page and Event as title + link) | from Mastodon docs, not run |
| Mastodon requires the signer to be the activity's actor (hence Delete by the Person, signed with the Person's key) | from Mastodon docs |
| Mastodon in authorized-fetch mode may refuse our unsigned GET of an actor; we don't sign GETs yet | known gap |
| Threads follows Groups | not verified |

## Not built yet

- Signed GETs (needed for servers in authorized-fetch / secure mode).
- `Update` when a post or event changes; `Like` / `Announce` counts; `Flag` (remote reports).
- Letting Exos members' own posts federate (only the organizer's and hosts' posts do).
- Following remote accounts or communities from Exos.
