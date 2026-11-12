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
| What the server sees | One message in a channel: an embed with the event name (linked), date and time in the event's zone (plus Discord's relative time), venue, image, the org's name and a **Get tickets** link button | The event on the server's **Events** tab (an EXTERNAL scheduled event): name, start and end, location = the Exos event page, description starting "Get tickets: …", cover image |
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
  honoured (`retry_after`); a post that may or may not have gone out (a timeout, a crashed pass)
  is never resent by itself: it shows "check the channel before posting again".
- **Logs and errors** carry Discord's numeric error code only, never its message text, the
  webhook token or the bot token (`redactDiscord`, `redactError`).
- **Disconnect.** "Remove webhook" deletes the Vault secret (queued posts fail). "Disconnect server"
  unlinks the guild; Discord events already there stay (untick Show on Discord first to remove them),
  and the bot leaves when someone removes it in Discord (Server settings → Integrations).
- **Audit** (`exos_org_audit`): `discord.webhook_set`, `discord.webhook_remove`, `discord.settings`,
  `discord.guild_link`, `discord.guild_unlink`, `discord.event_show`, `discord.post` (sent or dry run,
  with the person who asked). No token or full webhook id.

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
