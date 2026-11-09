# Group chat and the masked SMS relay

Social groups (matched tables, community chats, event attendee chats) each get
an in-app chat and, for every member, a masked phone number they can text the
group from. Nobody sees anyone else's real number. Phone numbers or Instagram
handles are shared only when both people choose to (operator decision
2026-10-30).

Migration `20261031230000_exos_group_chat.sql`, edge function
`exos-sms-relay`, shared helpers `supabase/functions/_shared/sms/relay.ts`,
app code `src/lib/groupChat.ts` and the views `/groups`, `/groups/:id` and
`/orgs/:orgId/groups`. Security rows: `docs/security.md`.

## Before turning the relay on

- **US A2P 10DLC registration is required** for the pool numbers before any
  text goes out (brand + campaign registered with The Campaign Registry
  through Twilio or Telnyx; use case "group messaging / conversational",
  sample messages, the opt-in flow below and the HELP / STOP answers).
  Unregistered 10DLC traffic is filtered or blocked by US carriers. Toll-free
  numbers need toll-free verification instead.
- The relay is behind **`EXOS_SMS_RELAY=on`** on `exos-sms-relay`, **off by
  default**. Off, every due text is recorded as `dry_run`; inbound STOP / HELP
  are still recorded (compliance doesn't wait for the switch).
- Sending real SMS is the only third-party write this feature makes, and only
  with that switch on. It never touches the organizer's own Twilio / Telnyx
  account (that's SMS campaigns, `exos-sms-drain`): the relay uses the
  platform's account.

### Setup

1. Buy numbers on the platform's Twilio and / or Telnyx account and register
   them (above). Add each to the pool (service role):
   `INSERT INTO exos_sms_relay_numbers (provider, phone) VALUES ('twilio', '+1...');`
   A number is retired with `active = false`, never deleted while assigned.
2. Function secrets: `EXOS_RELAY_TWILIO_ACCOUNT_SID`,
   `EXOS_RELAY_TWILIO_AUTH_TOKEN` and / or `EXOS_RELAY_TELNYX_API_KEY`,
   `EXOS_RELAY_TELNYX_PUBLIC_KEY` (webhook signing key),
   optional `EXOS_RELAY_TELNYX_PROFILE_ID`, and `EXOS_SMS_RELAY_PUBLIC_URL`
   if Twilio posts to a URL other than
   `<SUPABASE_URL>/functions/v1/exos-sms-relay` (the Twilio signature covers
   the exact URL).
3. Point each number's inbound webhook at
   `.../exos-sms-relay/inbound/twilio` or `.../exos-sms-relay/inbound/telnyx`.
   Deploy with `--no-verify-jwt`. Signatures are checked:
   `X-Twilio-Signature` (HMAC-SHA1 with the auth token) and Telnyx's Ed25519
   (`telnyx-signature-ed25519` over `timestamp|body`, 5-minute window).
4. The migration schedules `exos-sms-relay-1min` (the drain) and
   `exos-group-chat-retention-daily` when pg_cron is there.
5. Only then set `EXOS_SMS_RELAY=on`.

## How it works

### Groups

`exos_social_groups` and `exos_social_group_members` are shared with matched
seats (`20261031210000_exos_matched_seats`): both migrations create them with
the same columns, whichever runs first. Every group belongs to one event
(`event_id` is required there) and is named by its `label`. This feature adds
`join_policy`, `close_after_days`, `daily_sms_cap`, `relay_enabled`,
`timezone`, `closed_at`, `purged_at` (groups) and `muted_until`,
`silenced_until` (members). A member table row is per ticket for matched
seats, so one person can have several; the chat treats a person as in while
any of their rows is active.

The chat is open while the group's `status` is `revealed`: matched tables get
their chat (and masked numbers) when they're revealed, groups made here start
revealed, and `dissolved` closes it. Owners and managers create groups and add
people; ticket holders join an event attendee group themselves; anyone signed
in joins a community group.

### In-app chat

- Messages live in `exos_group_messages`. RLS lets only the group's active
  members read them, never hidden messages, never between two people where one
  blocked the other. Supabase Realtime pushes new rows under that same policy;
  the page also polls every 20 seconds.
- Posting (`exos_group_post`): 1 to 1,000 characters, at most 3 links, 10 a
  minute and 300 a day per member per group. Links show as plain links with
  `rel="nofollow noopener noreferrer ugc"`; only http(s) and www.
- Report (3 distinct reports hide a message until staff look), block (both
  ways, across that org's groups, app and SMS), mute (no relayed texts for a
  while).
- Staff never read chats through RLS. Reading one for moderation needs a
  reason and is logged (`exos_group_moderation_log`); so is reviewing reports
  and every moderation action (hide, silence, remove, close).
- The chat closes `close_after_days` (the organizer's N, 0 to 90, default 7)
  after the event ends (its end time, else start + 6 hours), or when staff
  close it.
- Retention: `group_chat_retention_days` (platform setting, default 30) after
  closing, the sweep deletes the group's messages, reports and outbox and
  erases contact shares. The consent, contact and moderation logs stay.

### Masked numbers

- Joining (or the group being revealed) gives a member a pool number for
  that group right away, by trigger, whoever wrote the member row. Numbers are
  reused across groups, but the **routing key (phone, pool number) is unique**
  among live assignments: one phone can be in many groups, never two on the
  same number. A person also never holds the same number twice. When the pool
  has no number left for someone, the app says so and the chat still works.
- Texts go only to members who turned them on in the app with their phone and
  the consent line (stored with the time, plus a row in
  `exos_sms_relay_consents`). A confirmation text follows.
- Inbound: the webhook verifies the signature, then `(from, to)` finds the
  group. The text lands in the chat and goes to every other opted-in member
  from **their own** pool number as `First: text` (links become
  "[link in app]", 306 characters at most).
- **STOP** (UNSUBSCRIBE, CANCEL, END, QUIT...) on a pool number leaves that
  group's texts; **STOPALL** stops every relay text to that phone;
  **START** turns them back on; **HELP** answers with who we are, rates and
  how to stop. Each STOP / START gets one confirmation. Opting in again in the
  app clears a STOPALL.
- Quiet hours: relayed texts wait for 9:00-20:00 in the group's (or event's)
  time zone, New York by default. Keyword answers go straight out.
- Cost cap: `daily_sms_cap` SMS segments per group per rolling 24 hours
  (default 300; 0 turns texts off). Over the cap a text is skipped and the chat
  says so once a day.

### Mutual reveal

After the event a member can share their phone (by default the one they gave
for texts) or Instagram handle with one member or the whole group. The other
person sees it only while they share the same kind back, to that member or to
the group. One-sided shares are never shown. Taking a share back erases it;
leaving the group takes back everything you shared there. Shares, take-backs
and first views are logged in `exos_group_contact_log`.

## Not built yet

- Push notifications for new messages (the relay covers people who want
  texts).
- Images or attachments in the chat.
- MMS / group MMS: the relay is one-to-one texts from each member's number.
- A platform-wide daily SMS budget across all groups (each group has its own).
