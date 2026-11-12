# Promote events on Discord

How an organizer promotes an Exos event in their **own** Discord server, what
Exos may send to Discord, and what the operator sets up first. Operator ask,
2026-11-11: "find and add Discord events as a way to promote events".

Code: `supabase/functions/exos-discord/` (routes, the cron), `supabase/functions/_shared/channels/discord.ts`
(the allowlist, payloads, the scheduled-event pass, the bot install), mig
`20261113130000_exos_discord.sql`, `src/components/DiscordPanel.tsx` (Org settings → Discord),
`src/components/DiscordEventPanel.tsx` (Edit event → Promote on Discord), `src/lib/discord.ts`.
Tests: `tests/exos/test_discord.sql`, `supabase/functions/_shared/channels/discord_test.ts`,
`src/lib/discord.test.ts`, `src/components/DiscordPanel.test.tsx`, the smoke + a11y steps "org settings: Discord".

## Two levels, both off by default

| | 1. Announcements | 2. Discord events |
|---|---|---|
| What the server sees | One message in a channel: an embed with the event name (linked), date and time in the event's zone (plus Discord's relative time), venue, image (its URL; Discord fetches it), the org's name and a **Get tickets** link button | The event on the server's **Events** tab (an EXTERNAL scheduled event): name, start and end, location = the Exos event page, description starting "Get tickets: …", and the cover when it is one uploaded to Exos (below) |
| How it's connected | An owner / manager pastes a channel webhook URL (channel settings → Integrations → Webhooks → Copy Webhook URL) | An owner / manager clicks **Add Exos bot to your server** (Discord's bot authorization; they need Manage Server there) |
| When it happens | **Post to Discord** / **Post a reminder** on the event, or on publish when the org ticked "Announce each event on Discord when it's published" | **Show on Discord** on the event; Exos then creates it, updates it when the Exos event changes, cancels it when the Exos event is cancelled, deletes it when unticked or unpublished |
| Limits | Once per event per kind (publish, reminder); 10 requests a minute and 30 posts an hour per org | 20 passes a minute per org; an edit is sent once it settles (15 seconds) |
| Needs | `EXOS_DISCORD_ENABLED=on` | the same, plus the platform's Discord application (below) |

Nothing reaches Discord unless the org's owner ticks **Send to Discord** AND the
operator set `EXOS_DISCORD_WRITES=on`. Until then every post and every
Discord event is a **dry run**: Exos records what it would have sent (the
webhook token redacted) and the panels say so. With `EXOS_DISCORD_ENABLED`
unset the panels don't render and `exos-discord` answers 503 to everything but
`/config`.

## What Exos may send (CLAUDE.md, the Discord exception)

The only requests (`_shared/channels/discord.ts`, `allowedRequest`; anything
else throws before `fetch`), all to `https://discord.com/api/v10`:

| Method | Path | Bound to |
|---|---|---|
| POST | `/guilds/{guild}/scheduled-events` | the org's linked guild |
| GET / PATCH / DELETE | `/guilds/{guild}/scheduled-events/{id}` | the org's linked guild |
| POST | `/webhooks/{id}/{token}?wait=true&with_components=true` | the org's own webhook id |

Plus, during the bot install, the OAuth code exchange at
`https://discord.com/api/v10/oauth2/token` (writes nothing on Discord). No
other messages, no roles, members or channels, no DMs. Every webhook body
carries `allowed_mentions: {"parse": []}` and no `content`, so a name like
"@everyone" never pings; venue text is markdown-escaped. The bot asks for
**CREATE_EVENTS** only (`1 << 44`): create events, and edit / delete the ones
it made.

## Storage and security

- **Webhook URL.** Checked in SQL (`exos_discord_webhook_parts`): exactly
  `https://discord.com` or `https://discordapp.com`, `/api[/v<n>]/webhooks/<17-20 digit id>/<token>`;
  no port, user info, query, fragment, encoding or other host. The edge function never calls the
  pasted URL: it rebuilds `https://discord.com/api/v10/webhooks/<id>/<token>` from the two parts,
  so there is no SSRF. The token goes to Vault (`exos_discord_webhook:<org>`); the table keeps
  the webhook id; the panel shows `…1234` only. A refusal never echoes the URL.
- **The server (guild).** Read from Discord's token response (`guild` object), never from the
  redirect's `guild_id` (Discord's docs call that a hint; a forged callback could otherwise name
  someone else's server). The install uses the shared OAuth state (`exos_oauth_states`, provider
  `discord`): single use, 10 minutes, a finish token in the URL fragment, finished only by the
  user who started it, who must still be owner / manager. A server links to one org.
- **Roles in SQL.** Owner / manager for everything; only an owner turns sending on. Every lookup
  goes through the event's own org; another org's event answers like an unknown one.
- **Rate limits before any call to Discord** (in the RPCs and the claims). Discord's own 429s are
  honoured (`retry_after`, plus `X-RateLimit-Global` / `X-RateLimit-Scope`).
- **A post is retried only when it can't have gone out**: a 429, or a request that never left (the
  breaker or the platform cap refused it, or the connection never opened). A 5xx, a timeout, a dropped
  connection or a crashed pass may have posted, so it becomes an error that says "check the channel
  before posting again", and is never resent by itself.
- **The cover image is never fetched over HTTP.** Only a cover uploaded to this project's own
  public storage (`<SUPABASE_URL>/storage/v1/object/public/exos-media/event-images/<uid>/<uuid>.<ext>`,
  what `uploadEventImage` makes; parsed strictly: same origin, no query, no `..`, no escapes) is read,
  with the service client (`storage.list` for the size, then `download`), at most 4 MB, and sent only
  if its first bytes are PNG, JPEG or GIF. Any other image URL gives the Discord event no cover. It
  is read only when the event really goes out, never in a dry run. (The announcement embed carries
  the image URL itself; Discord fetches that, not Exos.)
- **Circuit breaker** (Discord bans an IP or a token at 10,000 invalid requests in 10 minutes;
  `exos_discord_platform`, `exos_discord_call_gate` before every call, `exos_discord_call_result`
  after every refusal):
  - 300 Discord calls a minute across every org, counted in SQL before each call;
  - a **401** on a bot call stops every bot call platform-wide until the bot token changes (its
    SHA-256 fingerprint differs) or the operator runs `SELECT public.exos_discord_breaker_clear();`.
    Webhook posts go on (they don't use the token);
  - more than **500 invalid answers** (401, 403, a 429 that isn't scope `shared`) in 10 minutes stops
    every Discord call, bot and webhook, until the operator clears it;
  - a **global 429** pauses every bot call for its `retry_after`;
  - a server that refuses the bot (**403** 50001 / 50013, **unknown guild** 10004) is marked broken
    and skipped until it's linked again (the panel says "Reconnect the bot"); a webhook Discord
    refuses (**10015**, 401, 403, 404) is marked broken and skipped until a new URL is saved;
  - backoff holds for "sync now" too (`next_try_at`); the org panel says when Discord is paused.
- **Leases.** The cron claims one row at a time, each with its own 2-minute lease, and starts no row
  after its 90-second budget; a row makes at most two Discord calls (10 s each) and one cover read,
  so a lease can't run out under it.
- **Logs and errors** carry Discord's numeric error code only, never its message text, the
  webhook token or the bot token (`redactDiscord`, `redactError`).
- **Disconnect.** "Remove webhook" deletes the Vault secret (queued posts fail). "Disconnect server"
  unlinks the guild; Discord events already there stay (untick Show on Discord first to remove them),
  and the bot leaves when someone removes it in Discord (Server settings → Integrations).
- **Audit** (`exos_org_audit`): `discord.webhook_set`, `discord.webhook_remove`, `discord.settings`,
  `discord.guild_link`, `discord.guild_unlink`, `discord.event_show`, `discord.post` (sent or dry run,
  with the person who asked). No token or full webhook id.

## By design (reviewed, left as is)

- **One announcement per event per kind, for good.** Once a publish (or reminder) post went out, it
  isn't posted again, even after the org saves a different webhook. A dry run or an error can be
  posted again.
- **Disconnecting doesn't clean up Discord.** "Disconnect server" stops Exos managing the server's
  events but leaves them there (untick Show on Discord first to remove them), and deleting an Exos
  event leaves its Discord event; Discord ends an EXTERNAL event at its end time anyway.
- **A scheduled event's create may be repeated** if Discord accepted it but the answer was lost
  (a 5xx or a timeout on create): the pass retries with backoff, which can leave a duplicate the
  organizer deletes in Discord. Posts never do this (above).
- **The webhook is the one the org saved.** Exos doesn't check that it belongs to the linked server
  (no extra GET); it only posts to that webhook.
- **One org per server, first come.** A Discord server already linked to another org is refused
  (no takeover path); the bot stays in the server until its admins remove it. Relinking an org to a
  different server leaves the old server's events there, no longer managed.
- **Managers can repoint.** With writes on, an owner or manager can save a different webhook or link
  a different server (audited: `discord.webhook_set`, `discord.guild_link`); only the owner turns
  writes on.

## What the operator sets up

1. Apply `20261113130000_exos_discord` (`scripts/rollout-prod.sh`), deploy `exos-discord` with
   `--no-verify-jwt`, ship the SPA.
2. For level 2, create a Discord application (discord.com/developers/applications): add a bot; turn
   **Public Bot** on (organizers add it to their servers) and **Requires OAuth2 Code Grant** on (so
   the server comes from the token response); under OAuth2 add the redirect URI
   `<SUPABASE_URL>/functions/v1/exos-discord/callback` (or set `DISCORD_REDIRECT_URI`). No privileged
   gateway intents are needed (Exos never connects to the gateway).
3. Secrets on the functions: `DISCORD_APPLICATION_ID`, `DISCORD_CLIENT_SECRET`, `DISCORD_BOT_TOKEN`;
   `EXOS_APP_URL` must already be in `EXOS_REDIRECT_ORIGINS`.
4. `EXOS_DISCORD_ENABLED=on` to show it; check a dry run; then `EXOS_DISCORD_WRITES=on`.
5. Turn the cron on: `SELECT cron.alter_job(jobid, active := true) FROM cron.job WHERE jobname = 'exos-discord-2min';`
   (without it, posts still go out from the buttons; queued publish announcements and event edits wait).
6. If the breaker trips (the org panels say "Discord is paused"): read
   `SELECT * FROM public.exos_discord_platform;`, fix the cause (a revoked bot token: set a new
   `DISCORD_BOT_TOKEN`, which clears a 401 by itself), then `SELECT public.exos_discord_breaker_clear();`.

## Discord API facts this relies on (checked 2026-11-12, docs.discord.com)

- Scheduled events: `POST /guilds/{guild.id}/scheduled-events`; EXTERNAL is `entity_type` 3 and needs
  `entity_metadata.location` (1-100 characters) and `scheduled_end_time`; `privacy_level` 2 is
  GUILD_ONLY; `image` is a data URI (JPG, PNG or GIF); name 1-100, description 1-1000 characters; at
  most 100 SCHEDULED / ACTIVE events per guild; cancel = `PATCH {status: 4}` from SCHEDULED; DELETE
  answers 204; Discord ends an EXTERNAL event at its end time.
- Permissions: CREATE_EVENTS (`1 << 44`) creates events and edits / deletes the bot's own;
  MANAGE_EVENTS (`1 << 33`) would cover everyone's (not asked for).
- Bot install: `scope=bot&permissions=…&response_type=code&redirect_uri=…`; the redirect's
  `guild_id` "should only be used as a hint"; the token response has the `guild`.
- Webhooks: `POST /webhooks/{id}/{token}`, `?wait=true` returns the message; `with_components=true`
  lets a non-application webhook send non-interactive components (link buttons); `allowed_mentions`.
- Rate limits: per route and global (50 requests a second per bot); a 429 carries `retry_after`.
- `User-Agent: DiscordBot ($url, $version)` is required.

Other platforms: no public Luma or Posh Discord integration was found (Luma's help pages are rendered
in the browser and couldn't be read from here: **unverified**). Community bots (Sesh, Apollo) and
automation tools create Discord events from calendars; Exos does the same from its own events.
