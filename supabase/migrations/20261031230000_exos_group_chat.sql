-- ============================================================================
-- Migration 20261031230000 — Exos: group chat for social groups (in-app chat,
-- masked SMS relay, mutual contact reveal)
--
-- Touches:  W: TABLE exos_social_groups, exos_social_group_members (CREATE
--              TABLE IF NOT EXISTS with the same columns as
--              20261031210000_exos_matched_seats, which creates them first
--              when both are applied; chat columns added with ADD COLUMN IF
--              NOT EXISTS; triggers hand out / release pool numbers for rows
--              either migration writes)
--              TABLE exos_group_messages, exos_group_reports, exos_group_blocks,
--              exos_group_moderation_log (new)
--              TABLE exos_sms_relay_numbers (platform pool), exos_sms_relay_assignments,
--              exos_sms_relay_outbox, exos_sms_relay_consents, exos_sms_relay_stops (new)
--              TABLE exos_group_contact_shares, exos_group_contact_log (new)
--              FUNCTION exos_group_* / exos_sms_relay_* / _exos_group_* (new; list below)
--              PUBLICATION supabase_realtime ADD TABLE exos_group_messages (when present)
--              cron: exos-sms-relay-1min, exos-group-chat-retention-daily (when pg_cron present)
--           R: exos_orgs, exos_events, exos_org_memberships, exos_tickets,
--              exos_platform_settings, exos_profiles (optional)
-- Pre-reqs: 20261016120000 (SMS: exos_sms_normalize_phone),
--           20261014140000 (exos_platform_settings)
--
-- Operator decision 2026-10-30: joining a group gives both an in-app chat and
-- a masked number by default. Real phone numbers or Instagram handles are only
-- shared when both people opt in (exos_group_share_contact).
--
-- In-app chat. Messages are rows in exos_group_messages, readable through RLS
-- by the group's active members only (and not between two people where one
-- blocked the other). Supabase Realtime pushes INSERTs under that same RLS.
-- Posting goes through exos_group_post (length cap 1,000, at most 3 links, 10
-- a minute and 300 a day per member per group, idempotent client ref). Org
-- staff never read through RLS: exos_group_moderation_read needs a reason and
-- writes exos_group_moderation_log. The chat closes close_after_days (the
-- organizer's N, 0-90, default 7) after the event ends; the retention sweep
-- deletes a closed group's messages after group_chat_retention_days
-- (platform setting, default 30).
--
-- SMS relay. Platform numbers sit in exos_sms_relay_numbers (no org: the pool
-- is shared by every org, like exos_platform_settings). Each (member, group)
-- gets one pool number in exos_sms_relay_assignments. The routing key is
-- (phone, pool number): two live assignments can never share it (unique
-- indexes below), so an inbound text from a phone to a pool number names one
-- group. A member gets relayed texts only after exos_group_sms_opt_in with the
-- consent text (stored, plus a row in exos_sms_relay_consents). STOP on a pool
-- number leaves that group's relay; STOPALL stops every relay text to that
-- phone (exos_sms_relay_stops); START undoes both; HELP answers. Quiet hours
-- (9:00-20:00 in the group's time zone, New York by default, as for SMS
-- campaigns) delay relayed texts; keyword replies go straight out. Each group
-- has a daily cap of SMS segments (daily_sms_cap, default 300 per rolling 24 h,
-- 0 turns the relay off); over the cap a text is skipped and the chat says so.
-- exos-sms-relay sends; with EXOS_SMS_RELAY unset every send is a dry run.
-- US A2P 10DLC registration is required before the numbers go live
-- (docs/group-chat.md).
--
-- Mutual reveal. After the event a member can share their phone or Instagram
-- with one member or the whole group. The other person sees it only while
-- they share the same kind back (to that member or to the group). Shares are
-- revocable (the value is erased), leaving or being removed revokes them, and
-- every share / revoke / first view is logged.
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Groups and members (generic: matched tables, community chats, attendee chats)
-- ---------------------------------------------------------------------------
-- The same columns as 20261031210000_exos_matched_seats, which runs first and
-- creates them when both are applied (then these CREATEs are no-ops). Not
-- copied: spot_id's FK to exos_match_spots (that table is matched seats').
CREATE TABLE IF NOT EXISTS public.exos_social_groups (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_]{1,39}$'),
  tier_id     uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE SET NULL,
  spot_id     uuid,
  label       text CHECK (label IS NULL OR char_length(label) <= 80),
  status      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'locked', 'revealed', 'dissolved')),
  meet_at     timestamptz,
  score       numeric,
  seed        bigint,
  revealed_at timestamptz,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_social_groups_event_idx ON public.exos_social_groups (event_id, kind);
CREATE INDEX IF NOT EXISTS exos_social_groups_tier_idx ON public.exos_social_groups (tier_id) WHERE tier_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_social_group_members (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id       uuid NOT NULL REFERENCES public.exos_social_groups (id) ON DELETE CASCADE,
  org_id         uuid NOT NULL,                 -- set from the group by trigger
  event_id       uuid NOT NULL,                 -- "
  kind           text NOT NULL,                 -- "
  ticket_id      uuid REFERENCES public.exos_tickets (id) ON DELETE SET NULL,
  user_id        uuid,
  display_name   text CHECK (display_name IS NULL OR char_length(display_name) <= 40),
  role           text NOT NULL DEFAULT 'member' CHECK (role IN ('member', 'host')),
  status         text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'removed', 'left')),
  removed_reason text CHECK (removed_reason IS NULL OR char_length(removed_reason) <= 300),
  removed_by     uuid,
  removed_at     timestamptz,
  notified_at    timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (group_id, ticket_id)
);
CREATE INDEX IF NOT EXISTS exos_social_group_members_group_idx ON public.exos_social_group_members (group_id);
CREATE INDEX IF NOT EXISTS exos_social_group_members_user_idx ON public.exos_social_group_members (user_id);
CREATE UNIQUE INDEX IF NOT EXISTS exos_social_group_members_one_active
  ON public.exos_social_group_members (kind, ticket_id) WHERE status = 'active' AND ticket_id IS NOT NULL;

-- Chat columns. A group's name is its label. The chat is open while the
-- group is 'revealed' (matched seats: once the table is revealed; groups made
-- here start revealed), until close_after_days after the event ends.
ALTER TABLE public.exos_social_groups ADD COLUMN IF NOT EXISTS join_policy text NOT NULL DEFAULT 'invite';
ALTER TABLE public.exos_social_groups ADD COLUMN IF NOT EXISTS close_after_days integer NOT NULL DEFAULT 7;
ALTER TABLE public.exos_social_groups ADD COLUMN IF NOT EXISTS closed_at timestamptz;
ALTER TABLE public.exos_social_groups ADD COLUMN IF NOT EXISTS timezone text;
ALTER TABLE public.exos_social_groups ADD COLUMN IF NOT EXISTS relay_enabled boolean NOT NULL DEFAULT true;
ALTER TABLE public.exos_social_groups ADD COLUMN IF NOT EXISTS daily_sms_cap integer NOT NULL DEFAULT 300;
ALTER TABLE public.exos_social_groups ADD COLUMN IF NOT EXISTS purged_at timestamptz;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_social_groups_chat_ck') THEN
    ALTER TABLE public.exos_social_groups ADD CONSTRAINT exos_social_groups_chat_ck CHECK (
      join_policy IN ('invite', 'ticket_holders', 'open')
      AND close_after_days BETWEEN 0 AND 90
      AND daily_sms_cap BETWEEN 0 AND 5000);
  END IF;
END $$;
COMMENT ON COLUMN public.exos_social_groups.close_after_days IS
  'Group chat (mig 20261031230000, docs/group-chat.md): the chat closes this many days after the event ends.';
ALTER TABLE public.exos_social_group_members ADD COLUMN IF NOT EXISTS muted_until timestamptz;
ALTER TABLE public.exos_social_group_members ADD COLUMN IF NOT EXISTS silenced_until timestamptz;

-- Every child row carries its group's org.
CREATE OR REPLACE FUNCTION public._exos_tg_group_child_org()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  SELECT g.org_id INTO NEW.org_id FROM public.exos_social_groups g WHERE g.id = NEW.group_id;
  IF NEW.org_id IS NULL THEN
    RAISE EXCEPTION 'group % not found', NEW.group_id USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_group_child_org() FROM PUBLIC, anon, authenticated;

-- Members: org / event / kind from the group (matched seats has the same
-- trigger under its own name; both set the same values).
CREATE OR REPLACE FUNCTION public._exos_tg_group_member_fill()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  SELECT g.org_id, g.event_id, g.kind INTO NEW.org_id, NEW.event_id, NEW.kind
    FROM public.exos_social_groups g WHERE g.id = NEW.group_id;
  IF NEW.org_id IS NULL THEN
    RAISE EXCEPTION 'group % not found', NEW.group_id USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_group_member_fill() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_social_group_members_org ON public.exos_social_group_members;
CREATE TRIGGER exos_social_group_members_org BEFORE INSERT OR UPDATE OF group_id ON public.exos_social_group_members
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_group_member_fill();
DROP TRIGGER IF EXISTS exos_social_groups_touch ON public.exos_social_groups;
CREATE TRIGGER exos_social_groups_touch BEFORE UPDATE ON public.exos_social_groups
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DROP TRIGGER IF EXISTS exos_social_group_members_touch ON public.exos_social_group_members;
CREATE TRIGGER exos_social_group_members_touch BEFORE UPDATE ON public.exos_social_group_members
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ---------------------------------------------------------------------------
-- Messages, reports, blocks, moderation log
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_group_messages (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id      uuid NOT NULL REFERENCES public.exos_social_groups (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL,
  sender_id     uuid REFERENCES auth.users (id) ON DELETE SET NULL,   -- NULL: system note
  sender_name   text NOT NULL CHECK (length(sender_name) BETWEEN 1 AND 40),
  body          text NOT NULL CHECK (length(body) BETWEEN 1 AND 1000),
  source        text NOT NULL DEFAULT 'app' CHECK (source IN ('app', 'sms', 'system')),
  client_ref    text CHECK (client_ref IS NULL OR length(client_ref) <= 64),
  provider_ref  text CHECK (provider_ref IS NULL OR length(provider_ref) <= 80),
  hidden_at     timestamptz,
  hidden_reason text CHECK (hidden_reason IS NULL OR length(hidden_reason) <= 200),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.exos_group_messages IS
  'Group chat messages (mig 20261031230000). RLS: the group''s active members only; posts via exos_group_post / the SMS relay.';
CREATE INDEX IF NOT EXISTS exos_group_messages_group_idx ON public.exos_group_messages (group_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_group_messages_sender_idx ON public.exos_group_messages (group_id, sender_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS exos_group_messages_client_ref_uq ON public.exos_group_messages (group_id, sender_id, client_ref) WHERE client_ref IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_group_messages_provider_ref_uq ON public.exos_group_messages (provider_ref) WHERE provider_ref IS NOT NULL;
DROP TRIGGER IF EXISTS exos_group_messages_org ON public.exos_group_messages;
CREATE TRIGGER exos_group_messages_org BEFORE INSERT ON public.exos_group_messages
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_group_child_org();
DROP TRIGGER IF EXISTS exos_group_messages_touch ON public.exos_group_messages;
CREATE TRIGGER exos_group_messages_touch BEFORE UPDATE ON public.exos_group_messages
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

CREATE TABLE IF NOT EXISTS public.exos_group_reports (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL,
  group_id    uuid NOT NULL REFERENCES public.exos_social_groups (id) ON DELETE CASCADE,
  message_id  uuid NOT NULL REFERENCES public.exos_group_messages (id) ON DELETE CASCADE,
  reporter_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  reason      text NOT NULL CHECK (length(reason) BETWEEN 1 AND 300),
  status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'dismissed', 'actioned')),
  resolved_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  resolved_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (message_id, reporter_id)
);
CREATE INDEX IF NOT EXISTS exos_group_reports_open_idx ON public.exos_group_reports (org_id, created_at DESC) WHERE status = 'open';
DROP TRIGGER IF EXISTS exos_group_reports_org ON public.exos_group_reports;
CREATE TRIGGER exos_group_reports_org BEFORE INSERT ON public.exos_group_reports
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_group_child_org();
DROP TRIGGER IF EXISTS exos_group_reports_touch ON public.exos_group_reports;
CREATE TRIGGER exos_group_reports_touch BEFORE UPDATE ON public.exos_group_reports
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- A block holds across that org's groups, both ways: neither sees the other's
-- messages or contact shares, and no relayed text goes between them.
CREATE TABLE IF NOT EXISTS public.exos_group_blocks (
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  blocker_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  blocked_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, blocker_id, blocked_id),
  CHECK (blocker_id <> blocked_id)
);
CREATE INDEX IF NOT EXISTS exos_group_blocks_blocked_idx ON public.exos_group_blocks (org_id, blocked_id);

CREATE TABLE IF NOT EXISTS public.exos_group_moderation_log (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid NOT NULL,
  group_id          uuid REFERENCES public.exos_social_groups (id) ON DELETE SET NULL,
  actor_id          uuid,                    -- NULL: automatic (report threshold)
  action            text NOT NULL CHECK (action IN ('read', 'review_reports', 'hide_message', 'unhide_message',
                      'silence_member', 'unsilence_member', 'remove_member', 'close_group', 'reopen_group',
                      'dismiss_report', 'auto_hide')),
  reason            text CHECK (reason IS NULL OR length(reason) <= 300),
  target_message_id uuid,
  target_user_id    uuid,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_group_moderation_log_org_idx ON public.exos_group_moderation_log (org_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- SMS relay: pool, assignments (the routing key), outbox, consent log, stops
-- ---------------------------------------------------------------------------
-- Platform numbers, shared by every org (no org_id by design; RLS on, no
-- client grants). The operator adds rows; a number is never deleted while
-- assigned (set active = false to stop handing it out).
CREATE TABLE IF NOT EXISTS public.exos_sms_relay_numbers (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider   text NOT NULL CHECK (provider IN ('twilio', 'telnyx')),
  phone      text NOT NULL UNIQUE CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS exos_sms_relay_numbers_touch ON public.exos_sms_relay_numbers;
CREATE TRIGGER exos_sms_relay_numbers_touch BEFORE UPDATE ON public.exos_sms_relay_numbers
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

CREATE TABLE IF NOT EXISTS public.exos_sms_relay_assignments (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid NOT NULL,
  group_id       uuid NOT NULL REFERENCES public.exos_social_groups (id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  number_id      uuid REFERENCES public.exos_sms_relay_numbers (id),   -- NULL: pool exhausted for this person
  phone          text CHECK (phone IS NULL OR phone ~ '^\+[1-9][0-9]{7,14}$'),
  consent_text   text CHECK (consent_text IS NULL OR length(consent_text) BETWEEN 20 AND 600),
  consented_at   timestamptz,
  sms_stopped_at timestamptz,
  released_at    timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CHECK ((consented_at IS NULL) = (consent_text IS NULL)),
  CHECK (consented_at IS NULL OR phone IS NOT NULL)
);
-- The routing key: one live (phone, pool number) pair names one group.
CREATE UNIQUE INDEX IF NOT EXISTS exos_sms_relay_route_uq ON public.exos_sms_relay_assignments (phone, number_id)
  WHERE released_at IS NULL AND phone IS NOT NULL AND number_id IS NOT NULL;
-- A person never holds the same pool number for two groups (so adding a phone later can't collide).
CREATE UNIQUE INDEX IF NOT EXISTS exos_sms_relay_user_number_uq ON public.exos_sms_relay_assignments (user_id, number_id)
  WHERE released_at IS NULL AND number_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_sms_relay_member_uq ON public.exos_sms_relay_assignments (group_id, user_id)
  WHERE released_at IS NULL;
CREATE INDEX IF NOT EXISTS exos_sms_relay_assign_number_idx ON public.exos_sms_relay_assignments (number_id) WHERE released_at IS NULL;
DROP TRIGGER IF EXISTS exos_sms_relay_assignments_org ON public.exos_sms_relay_assignments;
CREATE TRIGGER exos_sms_relay_assignments_org BEFORE INSERT ON public.exos_sms_relay_assignments
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_group_child_org();
DROP TRIGGER IF EXISTS exos_sms_relay_assignments_touch ON public.exos_sms_relay_assignments;
CREATE TRIGGER exos_sms_relay_assignments_touch BEFORE UPDATE ON public.exos_sms_relay_assignments
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- Outbox. kind relay = a group message; confirm = the opt-in confirmation;
-- reply = an answer to STOP / START / HELP (org_id NULL only when the sender
-- isn't in any group: a HELP from an unknown phone still gets an answer).
CREATE TABLE IF NOT EXISTS public.exos_sms_relay_outbox (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid,
  group_id          uuid REFERENCES public.exos_social_groups (id) ON DELETE CASCADE,
  kind              text NOT NULL CHECK (kind IN ('relay', 'confirm', 'reply')),
  message_id        uuid REFERENCES public.exos_group_messages (id) ON DELETE SET NULL,
  assignment_id     uuid REFERENCES public.exos_sms_relay_assignments (id) ON DELETE CASCADE,
  recipient_user_id uuid,
  number_id         uuid NOT NULL REFERENCES public.exos_sms_relay_numbers (id),
  to_phone          text NOT NULL CHECK (to_phone ~ '^\+[1-9][0-9]{7,14}$'),
  body              text NOT NULL CHECK (length(body) BETWEEN 1 AND 480),
  segments          integer NOT NULL CHECK (segments BETWEEN 1 AND 10),
  status            text NOT NULL DEFAULT 'queued'
                      CHECK (status IN ('queued', 'sending', 'sent', 'dry_run', 'failed', 'skipped')),
  send_after        timestamptz NOT NULL DEFAULT now(),
  attempts          integer NOT NULL DEFAULT 0,
  lease_until       timestamptz,
  provider_id       text,
  error             text CHECK (error IS NULL OR length(error) <= 200),
  sent_at           timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (kind = 'reply' OR (org_id IS NOT NULL AND group_id IS NOT NULL AND assignment_id IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_sms_relay_outbox_msg_uq ON public.exos_sms_relay_outbox (message_id, assignment_id) WHERE kind = 'relay';
CREATE INDEX IF NOT EXISTS exos_sms_relay_outbox_due_idx ON public.exos_sms_relay_outbox (send_after) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS exos_sms_relay_outbox_group_idx ON public.exos_sms_relay_outbox (group_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_sms_relay_outbox_phone_idx ON public.exos_sms_relay_outbox (to_phone, created_at DESC);

-- Consent log: append-only, kept after the group is purged (compliance record).
CREATE TABLE IF NOT EXISTS public.exos_sms_relay_consents (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL,
  group_id     uuid,
  user_id      uuid,
  phone        text NOT NULL,
  number_phone text,
  action       text NOT NULL CHECK (action IN ('opt_in', 'opt_out', 'stop', 'start', 'stop_all', 'start_all', 'released')),
  source       text NOT NULL CHECK (source IN ('app', 'sms', 'system')),
  consent_text text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_sms_relay_consents_phone_idx ON public.exos_sms_relay_consents (phone, created_at DESC);

-- Global STOP (STOPALL) per phone: no relay text of any group goes to it.
CREATE TABLE IF NOT EXISTS public.exos_sms_relay_stops (
  phone      text PRIMARY KEY CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
  stopped_at timestamptz NOT NULL DEFAULT now(),
  source     text NOT NULL DEFAULT 'sms' CHECK (source IN ('sms', 'operator'))
);

-- ---------------------------------------------------------------------------
-- Mutual contact reveal
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_group_contact_shares (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL,
  group_id   uuid NOT NULL REFERENCES public.exos_social_groups (id) ON DELETE CASCADE,
  from_user  uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  to_user    uuid REFERENCES auth.users (id) ON DELETE CASCADE,   -- NULL: the whole group
  kind       text NOT NULL CHECK (kind IN ('phone', 'instagram')),
  value      text CHECK (value IS NULL OR length(value) BETWEEN 1 AND 40),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  CHECK (to_user IS DISTINCT FROM from_user),
  CHECK ((revoked_at IS NULL) = (value IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_group_contact_shares_live_uq ON public.exos_group_contact_shares
  (group_id, from_user, coalesce(to_user, '00000000-0000-0000-0000-000000000000'::uuid), kind) WHERE revoked_at IS NULL;
DROP TRIGGER IF EXISTS exos_group_contact_shares_org ON public.exos_group_contact_shares;
CREATE TRIGGER exos_group_contact_shares_org BEFORE INSERT ON public.exos_group_contact_shares
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_group_child_org();
DROP TRIGGER IF EXISTS exos_group_contact_shares_touch ON public.exos_group_contact_shares;
CREATE TRIGGER exos_group_contact_shares_touch BEFORE UPDATE ON public.exos_group_contact_shares
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

CREATE TABLE IF NOT EXISTS public.exos_group_contact_log (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL,
  group_id   uuid NOT NULL,
  actor_id   uuid NOT NULL,
  other_id   uuid,              -- share / revoke: the member it was for (NULL = group); view: whose contact
  kind       text NOT NULL CHECK (kind IN ('phone', 'instagram')),
  action     text NOT NULL CHECK (action IN ('share', 'revoke', 'view')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_group_contact_log_view_uq ON public.exos_group_contact_log (group_id, actor_id, other_id, kind)
  WHERE action = 'view';

-- Every table: RLS on, nothing for anon; the three client-readable ones get
-- SELECT below (with policies), everything else goes through the RPCs.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_social_groups', 'exos_social_group_members', 'exos_group_messages',
    'exos_group_reports', 'exos_group_blocks', 'exos_group_moderation_log', 'exos_sms_relay_numbers',
    'exos_sms_relay_assignments', 'exos_sms_relay_outbox', 'exos_sms_relay_consents', 'exos_sms_relay_stops',
    'exos_group_contact_shares', 'exos_group_contact_log'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT ALL ON TABLE public.%I TO service_role', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Helpers (RLS predicates and internals)
-- ---------------------------------------------------------------------------
-- Is the caller an active member of the group? (RLS predicate)
CREATE OR REPLACE FUNCTION public.exos_is_group_member(p_group_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_social_group_members m
                  WHERE m.group_id = p_group_id AND m.user_id = auth.uid() AND m.status = 'active')
$$;
REVOKE ALL ON FUNCTION public.exos_is_group_member(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_is_group_member(uuid) TO authenticated, service_role;

-- Did the caller and p_other block each other in this org? (RLS predicate)
CREATE OR REPLACE FUNCTION public.exos_group_blocked_with(p_org_id uuid, p_other uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT p_other IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.exos_group_blocks b
     WHERE b.org_id = p_org_id
       AND ((b.blocker_id = auth.uid() AND b.blocked_id = p_other)
         OR (b.blocker_id = p_other AND b.blocked_id = auth.uid())))
$$;
REVOKE ALL ON FUNCTION public.exos_group_blocked_with(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_group_blocked_with(uuid, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._exos_group_blocked(p_org_id uuid, p_a uuid, p_b uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_group_blocks b
                  WHERE b.org_id = p_org_id
                    AND ((b.blocker_id = p_a AND b.blocked_id = p_b) OR (b.blocker_id = p_b AND b.blocked_id = p_a)))
$$;
REVOKE ALL ON FUNCTION public._exos_group_blocked(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;

-- When the chat closes: N days after the event ends (ends_at, else starts_at +
-- 6 h). No event: only when closed by hand.
CREATE OR REPLACE FUNCTION public.exos_group_closes_at(p_group_id uuid)
RETURNS timestamptz
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN g.closed_at IS NOT NULL THEN g.closed_at
              WHEN e.id IS NULL THEN NULL
              ELSE coalesce(e.ends_at, e.starts_at + interval '6 hours') + make_interval(days => g.close_after_days) END
    FROM public.exos_social_groups g LEFT JOIN public.exos_events e ON e.id = g.event_id
   WHERE g.id = p_group_id
$$;
REVOKE ALL ON FUNCTION public.exos_group_closes_at(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_group_closes_at(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._exos_group_open(p_group_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(public.exos_group_closes_at(p_group_id) > now(), true)
     AND EXISTS (SELECT 1 FROM public.exos_social_groups WHERE id = p_group_id AND purged_at IS NULL AND status = 'revealed')
$$;
REVOKE ALL ON FUNCTION public._exos_group_open(uuid) FROM PUBLIC, anon, authenticated;

-- Has the event ended (mutual reveal opens then)? No event: yes.
CREATE OR REPLACE FUNCTION public._exos_group_event_over(p_group_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce((SELECT coalesce(e.ends_at, e.starts_at + interval '3 hours') <= now()
                     FROM public.exos_social_groups g JOIN public.exos_events e ON e.id = g.event_id
                    WHERE g.id = p_group_id), true)
$$;
REVOKE ALL ON FUNCTION public._exos_group_event_over(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_group_staff(p_org_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ SELECT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) OR public.exos_is_admin() $$;
REVOKE ALL ON FUNCTION public._exos_group_staff(uuid) FROM PUBLIC, anon, authenticated;

-- SMS segments: printable ASCII as GSM-7 (160 / 153), anything else UCS-2
-- (70 / 67). Conservative: a few GSM extras (£, é...) count as UCS-2.
CREATE OR REPLACE FUNCTION public._exos_sms_segments(p_text text)
RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN p_text ~ ('^[' || chr(10) || chr(13) || ' -~]*$')
              THEN CASE WHEN length(p_text) <= 160 THEN 1 ELSE ceil(length(p_text) / 153.0)::int END
              ELSE CASE WHEN length(p_text) <= 70 THEN 1 ELSE ceil(length(p_text) / 67.0)::int END END
$$;
REVOKE ALL ON FUNCTION public._exos_sms_segments(text) FROM PUBLIC, anon, authenticated;

-- What a relayed text says: "<first name>: <text>", links replaced (they're in
-- the app), whitespace collapsed, at most 306 characters. Mirrored by
-- formatRelayBody in supabase/functions/_shared/sms/relay.ts.
CREATE OR REPLACE FUNCTION public.exos_relay_format(p_name text, p_body text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_name text := btrim(regexp_replace(regexp_replace(coalesce(p_name, ''), '[^A-Za-z0-9 .''-]', '', 'g'), '\s+', ' ', 'g'));
  v_text text;
  v_full text;
BEGIN
  v_name := left(coalesce(nullif(split_part(v_name, ' ', 1), ''), 'Member'), 20);
  v_text := regexp_replace(coalesce(p_body, ''), '(https?://|www\.)\S+', '[link in app]', 'gi');
  v_text := btrim(regexp_replace(v_text, '\s+', ' ', 'g'));
  v_full := v_name || ': ' || v_text;
  IF length(v_full) > 306 THEN
    v_full := left(v_full, 303) || '...';
  END IF;
  RETURN v_full;
END $$;
GRANT EXECUTE ON FUNCTION public.exos_relay_format(text, text) TO anon, authenticated, service_role;

-- The next moment inside 9:00-20:00 in p_tz (same window as SMS campaigns).
CREATE OR REPLACE FUNCTION public._exos_quiet_hours_next(p_at timestamptz, p_tz text)
RETURNS timestamptz
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tz    text := coalesce(nullif(p_tz, ''), 'America/New_York');
  v_local timestamp;
BEGIN
  BEGIN
    v_local := p_at AT TIME ZONE v_tz;
  EXCEPTION WHEN others THEN
    v_tz := 'America/New_York';
    v_local := p_at AT TIME ZONE v_tz;
  END;
  IF v_local::time < time '09:00' THEN
    RETURN (date_trunc('day', v_local) + interval '9 hours') AT TIME ZONE v_tz;
  ELSIF v_local::time >= time '20:00' THEN
    RETURN (date_trunc('day', v_local) + interval '1 day 9 hours') AT TIME ZONE v_tz;
  END IF;
  RETURN p_at;
END $$;
REVOKE ALL ON FUNCTION public._exos_quiet_hours_next(timestamptz, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_group_tz(p_group_id uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(nullif(g.timezone, ''), nullif(e.timezone, ''), 'America/New_York')
    FROM public.exos_social_groups g LEFT JOIN public.exos_events e ON e.id = g.event_id
   WHERE g.id = p_group_id
$$;
REVOKE ALL ON FUNCTION public._exos_group_tz(uuid) FROM PUBLIC, anon, authenticated;

-- The name a member shows as: their profile's display name when there is one.
CREATE OR REPLACE FUNCTION public._exos_group_default_name(p_user uuid)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v text;
BEGIN
  IF to_regclass('public.exos_profiles') IS NOT NULL THEN
    EXECUTE 'SELECT nullif(btrim(display_name), '''') FROM public.exos_profiles WHERE id = $1' INTO v USING p_user;
  END IF;
  RETURN left(coalesce(v, 'Member'), 40);
END $$;
REVOKE ALL ON FUNCTION public._exos_group_default_name(uuid) FROM PUBLIC, anon, authenticated;

-- A pool number for (user, phone): one this person / phone doesn't already
-- hold in another live group, least used first. Callers hold the per-user and
-- per-phone advisory locks; the unique indexes are the backstop.
CREATE OR REPLACE FUNCTION public._exos_relay_pick_number(p_user uuid, p_phone text, p_except uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT n.id FROM public.exos_sms_relay_numbers n
   WHERE n.active
     AND NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_assignments a
                      WHERE a.number_id = n.id AND a.released_at IS NULL AND a.id IS DISTINCT FROM p_except
                        AND (a.user_id = p_user OR (p_phone IS NOT NULL AND a.phone = p_phone)))
   ORDER BY (SELECT count(*) FROM public.exos_sms_relay_assignments a2 WHERE a2.number_id = n.id AND a2.released_at IS NULL),
            n.created_at, n.id
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._exos_relay_pick_number(uuid, text, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_relay_lock(p_user uuid, p_phone text)
RETURNS void
LANGUAGE plpgsql VOLATILE
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_relay_user:' || p_user::text, 0));
  IF p_phone IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('exos_relay_phone:' || p_phone, 0));
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_relay_lock(uuid, text) FROM PUBLIC, anon, authenticated;

-- Add a member (idempotent; rejoining after leaving adds them back). The
-- member trigger below gives them a pool number (operator decision: chat +
-- masked number by default). Internal: the join / staff RPCs call it; other
-- definer functions may too. Matched seats inserts its own rows (one per
-- ticket, so a person can have several); everything here reads "is any row
-- of this person active".
CREATE OR REPLACE FUNCTION public._exos_group_add_member(p_group_id uuid, p_user uuid, p_role text DEFAULT 'member')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public._exos_group_open(p_group_id) THEN
    RAISE EXCEPTION 'this group chat has closed' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('exos_group_member:' || p_group_id::text || ':' || p_user::text, 0));
  IF EXISTS (SELECT 1 FROM public.exos_social_group_members WHERE group_id = p_group_id AND user_id = p_user AND status = 'active') THEN
    RETURN jsonb_build_object('joined', true, 'group_id', p_group_id);
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_social_group_members WHERE group_id = p_group_id AND user_id = p_user AND status = 'removed') THEN
    RAISE EXCEPTION 'removed from this group by the organizer' USING ERRCODE = '42501';
  END IF;
  IF (SELECT count(DISTINCT user_id) FROM public.exos_social_group_members WHERE group_id = p_group_id AND status = 'active') >= 500 THEN
    RAISE EXCEPTION 'this group is full (500 members)' USING ERRCODE = '54000';
  END IF;
  UPDATE public.exos_social_group_members SET status = 'active', removed_at = NULL, role = coalesce(p_role, role)
   WHERE id = (SELECT id FROM public.exos_social_group_members
                WHERE group_id = p_group_id AND user_id = p_user AND status = 'left' AND ticket_id IS NULL
                ORDER BY created_at DESC LIMIT 1);
  IF NOT FOUND THEN
    INSERT INTO public.exos_social_group_members (group_id, user_id, role, status, display_name)
    VALUES (p_group_id, p_user, coalesce(p_role, 'member'), 'active', public._exos_group_default_name(p_user));
  END IF;
  RETURN jsonb_build_object('joined', true, 'group_id', p_group_id);
END $$;
REVOKE ALL ON FUNCTION public._exos_group_add_member(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_group_add_member(uuid, uuid, text) TO service_role;

-- Release a member's pool number and drop what's still queued for them.
CREATE OR REPLACE FUNCTION public._exos_relay_release(p_group_id uuid, p_user uuid, p_why text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE a public.exos_sms_relay_assignments%ROWTYPE;
BEGIN
  FOR a IN UPDATE public.exos_sms_relay_assignments SET released_at = now()
            WHERE group_id = p_group_id AND (p_user IS NULL OR user_id = p_user) AND released_at IS NULL
           RETURNING * LOOP
    UPDATE public.exos_sms_relay_outbox SET status = 'skipped', error = left(p_why, 200)
     WHERE assignment_id = a.id AND status = 'queued';
    IF a.phone IS NOT NULL THEN
      INSERT INTO public.exos_sms_relay_consents (org_id, group_id, user_id, phone, number_phone, action, source)
      VALUES (a.org_id, a.group_id, a.user_id, a.phone,
              (SELECT phone FROM public.exos_sms_relay_numbers WHERE id = a.number_id), 'released', 'system');
    END IF;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public._exos_relay_release(uuid, uuid, text) FROM PUBLIC, anon, authenticated;

-- Revoke every live contact share of a member in a group (leaving / removal).
CREATE OR REPLACE FUNCTION public._exos_group_revoke_all_shares(p_group_id uuid, p_user uuid)
RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH r AS (
    UPDATE public.exos_group_contact_shares SET revoked_at = now(), value = NULL
     WHERE group_id = p_group_id AND from_user = p_user AND revoked_at IS NULL
    RETURNING org_id, group_id, from_user, to_user, kind)
  INSERT INTO public.exos_group_contact_log (org_id, group_id, actor_id, other_id, kind, action)
  SELECT org_id, group_id, from_user, to_user, kind, 'revoke' FROM r
$$;
REVOKE ALL ON FUNCTION public._exos_group_revoke_all_shares(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- Give an active member of an open group a pool number if they have none.
CREATE OR REPLACE FUNCTION public._exos_relay_ensure(p_group_id uuid, p_user uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_user IS NULL OR NOT public._exos_group_open(p_group_id) THEN RETURN; END IF;
  PERFORM public._exos_relay_lock(p_user, NULL);
  IF NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_assignments
                  WHERE group_id = p_group_id AND user_id = p_user AND released_at IS NULL) THEN
    INSERT INTO public.exos_sms_relay_assignments (group_id, user_id, number_id)
    VALUES (p_group_id, p_user, public._exos_relay_pick_number(p_user, NULL));
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_relay_ensure(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- Whatever adds or removes a member (this migration's RPCs or matched seats'):
-- joining gets a number; the person's last active row going away releases it
-- and takes back their contact shares.
CREATE OR REPLACE FUNCTION public._exos_tg_group_member_relay()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status = 'active' AND NEW.user_id IS NOT NULL THEN
    PERFORM public._exos_relay_ensure(NEW.group_id, NEW.user_id);
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'active' AND OLD.user_id IS NOT NULL
     AND (NEW.status <> 'active' OR NEW.user_id IS DISTINCT FROM OLD.user_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_social_group_members x
                      WHERE x.group_id = OLD.group_id AND x.user_id = OLD.user_id AND x.status = 'active') THEN
    PERFORM public._exos_relay_release(OLD.group_id, OLD.user_id, CASE NEW.status WHEN 'removed' THEN 'removed' ELSE 'left the group' END);
    PERFORM public._exos_group_revoke_all_shares(OLD.group_id, OLD.user_id);
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_group_member_relay() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_social_group_members_relay ON public.exos_social_group_members;
CREATE TRIGGER exos_social_group_members_relay AFTER INSERT OR UPDATE OF status, user_id ON public.exos_social_group_members
  FOR EACH ROW EXECUTE FUNCTION public._exos_tg_group_member_relay();

-- A group being revealed hands out numbers; dissolved or closed releases them.
CREATE OR REPLACE FUNCTION public._exos_tg_group_status_relay()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE u uuid;
BEGIN
  IF NEW.status = 'revealed' AND NEW.closed_at IS NULL THEN
    FOR u IN SELECT DISTINCT m.user_id FROM public.exos_social_group_members m
              WHERE m.group_id = NEW.id AND m.status = 'active' AND m.user_id IS NOT NULL LOOP
      PERFORM public._exos_relay_ensure(NEW.id, u);
    END LOOP;
  ELSIF NEW.status = 'dissolved' OR NEW.closed_at IS NOT NULL THEN
    PERFORM public._exos_relay_release(NEW.id, NULL, 'group closed');
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_group_status_relay() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_social_groups_relay ON public.exos_social_groups;
CREATE TRIGGER exos_social_groups_relay AFTER UPDATE OF status, closed_at ON public.exos_social_groups
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status OR OLD.closed_at IS DISTINCT FROM NEW.closed_at)
  EXECUTE FUNCTION public._exos_tg_group_status_relay();

-- Queue a relayed copy of a message to every other member who opted in.
-- Locks the group row, so the daily cap can't be overrun by parallel posts.
CREATE OR REPLACE FUNCTION public._exos_group_fanout(p_message_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  m        public.exos_group_messages%ROWTYPE;
  g        public.exos_social_groups%ROWTYPE;
  r        record;
  v_body   text;
  v_seg    int;
  v_used   int;
  v_at     timestamptz;
  v_queued int := 0;
  v_capped int := 0;
BEGIN
  SELECT * INTO m FROM public.exos_group_messages WHERE id = p_message_id;
  IF NOT FOUND OR m.source = 'system' OR m.hidden_at IS NOT NULL THEN
    RETURN jsonb_build_object('queued', 0, 'capped', 0);
  END IF;
  SELECT * INTO g FROM public.exos_social_groups WHERE id = m.group_id FOR UPDATE;
  IF NOT g.relay_enabled OR g.daily_sms_cap = 0 THEN
    RETURN jsonb_build_object('queued', 0, 'capped', 0);
  END IF;
  v_body := public.exos_relay_format(m.sender_name, m.body);
  v_seg  := public._exos_sms_segments(v_body);
  v_at   := public._exos_quiet_hours_next(now(), public._exos_group_tz(g.id));
  SELECT coalesce(sum(o.segments), 0) INTO v_used FROM public.exos_sms_relay_outbox o
   WHERE o.group_id = g.id AND o.created_at > now() - interval '24 hours' AND o.status <> 'skipped';

  FOR r IN
    SELECT a.id AS assignment_id, a.user_id, a.phone, a.number_id
      FROM public.exos_sms_relay_assignments a
      JOIN public.exos_sms_relay_numbers n ON n.id = a.number_id AND n.active
     WHERE a.group_id = g.id AND a.released_at IS NULL AND a.consented_at IS NOT NULL AND a.sms_stopped_at IS NULL
       AND a.user_id IS DISTINCT FROM m.sender_id
       AND EXISTS (SELECT 1 FROM public.exos_social_group_members mem
                    WHERE mem.group_id = a.group_id AND mem.user_id = a.user_id AND mem.status = 'active'
                      AND (mem.muted_until IS NULL OR mem.muted_until <= now()))
       AND NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_stops s WHERE s.phone = a.phone)
       AND (m.sender_id IS NULL OR NOT public._exos_group_blocked(g.org_id, a.user_id, m.sender_id))
     ORDER BY a.created_at
  LOOP
    IF v_used + v_seg > g.daily_sms_cap THEN
      INSERT INTO public.exos_sms_relay_outbox (org_id, group_id, kind, message_id, assignment_id, recipient_user_id,
                                                number_id, to_phone, body, segments, status, error, send_after)
      VALUES (g.org_id, g.id, 'relay', m.id, r.assignment_id, r.user_id, r.number_id, r.phone, v_body, v_seg,
              'skipped', 'group daily cap', now())
      ON CONFLICT DO NOTHING;
      v_capped := v_capped + 1;
    ELSE
      INSERT INTO public.exos_sms_relay_outbox (org_id, group_id, kind, message_id, assignment_id, recipient_user_id,
                                                number_id, to_phone, body, segments, send_after)
      VALUES (g.org_id, g.id, 'relay', m.id, r.assignment_id, r.user_id, r.number_id, r.phone, v_body, v_seg, v_at)
      ON CONFLICT DO NOTHING;
      IF FOUND THEN
        v_used := v_used + v_seg;
        v_queued := v_queued + 1;
      END IF;
    END IF;
  END LOOP;

  -- Say so in the chat once a day when the cap stops texts.
  IF v_capped > 0 AND NOT EXISTS (
       SELECT 1 FROM public.exos_group_messages x
        WHERE x.group_id = g.id AND x.source = 'system' AND x.client_ref = 'sms-cap'
          AND x.created_at > now() - interval '24 hours') THEN
    INSERT INTO public.exos_group_messages (group_id, sender_id, sender_name, body, source, client_ref)
    VALUES (g.id, NULL, 'Exos', 'Texts are paused for today: this group reached its daily text limit. The chat here still works.',
            'system', 'sms-cap')
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN jsonb_build_object('queued', v_queued, 'capped', v_capped);
END $$;
REVOKE ALL ON FUNCTION public._exos_group_fanout(uuid) FROM PUBLIC, anon, authenticated;

-- The one insert path for member messages (app and SMS): checks the member,
-- the group, the length and links, the rate limits, then fans out.
CREATE OR REPLACE FUNCTION public._exos_group_insert_message(
  p_group_id uuid, p_user uuid, p_body text, p_source text, p_client_ref text, p_provider_ref text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  mem    public.exos_social_group_members%ROWTYPE;
  v_body text := btrim(regexp_replace(coalesce(p_body, ''), '(\r?\n){3,}', E'\n\n', 'g'));
  v_ref  text := nullif(btrim(coalesce(p_client_ref, '')), '');
  v_id   uuid;
  v_out  jsonb;
BEGIN
  SELECT * INTO mem FROM public.exos_social_group_members WHERE group_id = p_group_id AND user_id = p_user
   ORDER BY (status = 'active') DESC, created_at LIMIT 1;
  IF NOT FOUND OR mem.status <> 'active' THEN
    RAISE EXCEPTION 'you''re not in this group' USING ERRCODE = '42501';
  END IF;
  IF NOT public._exos_group_open(p_group_id) THEN
    RAISE EXCEPTION 'this group chat has closed' USING ERRCODE = '22023';
  END IF;
  IF mem.silenced_until IS NOT NULL AND mem.silenced_until > now() THEN
    RAISE EXCEPTION 'the organizer paused your messages in this group' USING ERRCODE = '42501';
  END IF;
  IF length(v_body) < 1 OR length(v_body) > 1000 THEN
    RAISE EXCEPTION 'messages are 1 to 1,000 characters' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM regexp_matches(v_body, '(https?://|www\.)', 'gi')) > 3 THEN
    RAISE EXCEPTION 'at most 3 links in a message' USING ERRCODE = '22023';
  END IF;
  IF v_ref IS NOT NULL AND length(v_ref) > 64 THEN
    RAISE EXCEPTION 'client ref too long' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('exos_group_post:' || p_group_id::text || ':' || p_user::text, 0));
  IF v_ref IS NOT NULL THEN
    SELECT id INTO v_id FROM public.exos_group_messages WHERE group_id = p_group_id AND sender_id = p_user AND client_ref = v_ref;
    IF v_id IS NOT NULL THEN
      RETURN jsonb_build_object('message_id', v_id, 'duplicate', true);
    END IF;
  END IF;
  IF (SELECT count(*) FROM public.exos_group_messages
       WHERE group_id = p_group_id AND sender_id = p_user AND created_at > now() - interval '1 minute') >= 10 THEN
    RAISE EXCEPTION 'slow down: at most 10 messages a minute' USING ERRCODE = '54000';
  END IF;
  IF (SELECT count(*) FROM public.exos_group_messages
       WHERE group_id = p_group_id AND sender_id = p_user AND created_at > now() - interval '1 day') >= 300 THEN
    RAISE EXCEPTION 'daily limit reached: at most 300 messages a day in a group' USING ERRCODE = '54000';
  END IF;

  INSERT INTO public.exos_group_messages (group_id, sender_id, sender_name, body, source, client_ref, provider_ref)
  VALUES (p_group_id, p_user, coalesce(nullif(mem.display_name, ''), 'Member'), v_body, p_source, v_ref, p_provider_ref)
  RETURNING id INTO v_id;
  v_out := public._exos_group_fanout(v_id);
  RETURN jsonb_build_object('message_id', v_id, 'duplicate', false, 'sms_queued', v_out->'queued', 'sms_capped', v_out->'capped');
END $$;
REVOKE ALL ON FUNCTION public._exos_group_insert_message(uuid, uuid, text, text, text, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- RLS policies
-- ---------------------------------------------------------------------------
GRANT SELECT ON public.exos_social_groups, public.exos_social_group_members, public.exos_group_messages TO authenticated;

-- Groups and member rows: staff read their org's (the same policy, by name,
-- as matched seats). Members get their group through exos_group_state.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_social_groups', 'exos_social_group_members'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_staff_read', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated '
                   'USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'']))',
                   t || '_staff_read', t);
  END LOOP;
END $$;

-- Messages: active members only, nothing hidden, nothing between blocked
-- people. Staff have no policy here (moderation reads are logged RPCs).
DROP POLICY IF EXISTS exos_group_messages_member_read ON public.exos_group_messages;
CREATE POLICY exos_group_messages_member_read ON public.exos_group_messages FOR SELECT TO authenticated
  USING (hidden_at IS NULL
         AND public.exos_is_group_member(group_id)
         AND NOT public.exos_group_blocked_with(org_id, sender_id));

-- Realtime: INSERTs pushed to subscribers under the policy above.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (SELECT 1 FROM pg_publication_tables
                      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'exos_group_messages') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.exos_group_messages;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Organizers: groups, settings, members
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_group_create(
  p_org_id uuid, p_title text, p_kind text DEFAULT 'custom', p_event_id uuid DEFAULT NULL,
  p_join_policy text DEFAULT NULL, p_close_after_days int DEFAULT 7, p_daily_sms_cap int DEFAULT 300
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_title  text := btrim(coalesce(p_title, ''));
  v_policy text := coalesce(p_join_policy, CASE p_kind WHEN 'event_attendees' THEN 'ticket_holders' WHEN 'community' THEN 'open' ELSE 'invite' END);
  v_id     uuid;
BEGIN
  IF NOT public._exos_group_staff(p_org_id) THEN
    RAISE EXCEPTION 'exos_group_create: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_kind NOT IN ('matched_table', 'community', 'event_attendees', 'custom') THEN
    RAISE EXCEPTION 'exos_group_create: unknown kind' USING ERRCODE = '22023';
  END IF;
  IF length(v_title) < 1 OR length(v_title) > 80 THEN
    RAISE EXCEPTION 'exos_group_create: a title of 1 to 80 characters' USING ERRCODE = '22023';
  END IF;
  -- Every group belongs to an event (exos_social_groups.event_id is NOT NULL).
  IF p_event_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = p_org_id) THEN
    RAISE EXCEPTION 'exos_group_create: pick one of your events' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_social_groups WHERE org_id = p_org_id AND created_at > now() - interval '1 day') >= 200 THEN
    RAISE EXCEPTION 'exos_group_create: at most 200 groups a day' USING ERRCODE = '54000';
  END IF;
  INSERT INTO public.exos_social_groups (org_id, event_id, kind, label, status, revealed_at, created_by,
                                         join_policy, close_after_days, daily_sms_cap)
  VALUES (p_org_id, p_event_id, p_kind, v_title, 'revealed', now(), auth.uid(),
          v_policy, coalesce(p_close_after_days, 7), coalesce(p_daily_sms_cap, 300))
  RETURNING id INTO v_id;
  RETURN v_id;
EXCEPTION WHEN check_violation THEN
  RAISE EXCEPTION 'exos_group_create: close after 0 to 90 days; daily text cap 0 to 5,000' USING ERRCODE = '22023';
END $$;
REVOKE ALL ON FUNCTION public.exos_group_create(uuid, text, text, uuid, text, int, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_create(uuid, text, text, uuid, text, int, int) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_group_update_settings(
  p_group_id uuid, p_title text DEFAULT NULL, p_close_after_days int DEFAULT NULL, p_daily_sms_cap int DEFAULT NULL,
  p_relay_enabled boolean DEFAULT NULL, p_join_policy text DEFAULT NULL, p_timezone text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE g public.exos_social_groups%ROWTYPE;
BEGIN
  SELECT * INTO g FROM public.exos_social_groups WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND OR NOT public._exos_group_staff(g.org_id) THEN
    RAISE EXCEPTION 'exos_group_update_settings: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_timezone IS NOT NULL AND p_timezone <> '' AND NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = p_timezone) THEN
    RAISE EXCEPTION 'exos_group_update_settings: unknown time zone' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_social_groups SET
    label            = coalesce(nullif(left(btrim(p_title), 80), ''), label),
    close_after_days = coalesce(p_close_after_days, close_after_days),
    daily_sms_cap    = coalesce(p_daily_sms_cap, daily_sms_cap),
    relay_enabled    = coalesce(p_relay_enabled, relay_enabled),
    join_policy      = coalesce(p_join_policy, join_policy),
    timezone         = CASE WHEN p_timezone IS NULL THEN timezone ELSE nullif(p_timezone, '') END
   WHERE id = p_group_id
  RETURNING * INTO g;
  RETURN jsonb_build_object('id', g.id, 'title', g.label, 'close_after_days', g.close_after_days,
    'daily_sms_cap', g.daily_sms_cap, 'relay_enabled', g.relay_enabled, 'join_policy', g.join_policy,
    'timezone', g.timezone, 'closes_at', public.exos_group_closes_at(g.id));
EXCEPTION WHEN check_violation THEN
  RAISE EXCEPTION 'exos_group_update_settings: title 1-80 characters, close after 0 to 90 days, daily text cap 0 to 5,000' USING ERRCODE = '22023';
END $$;
REVOKE ALL ON FUNCTION public.exos_group_update_settings(uuid, text, int, int, boolean, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_update_settings(uuid, text, int, int, boolean, text, text) TO authenticated, service_role;

-- Owner / manager: add someone (matched tables, invites).
CREATE OR REPLACE FUNCTION public.exos_group_add_member(p_group_id uuid, p_user_id uuid, p_role text DEFAULT 'member')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_social_groups WHERE id = p_group_id;
  IF v_org IS NULL OR NOT public._exos_group_staff(v_org) THEN
    RAISE EXCEPTION 'exos_group_add_member: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_role NOT IN ('member', 'host') THEN
    RAISE EXCEPTION 'exos_group_add_member: role is member or host' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_user_id) THEN
    RAISE EXCEPTION 'exos_group_add_member: no such account' USING ERRCODE = '22023';
  END IF;
  RETURN public._exos_group_add_member(p_group_id, p_user_id, p_role);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_add_member(uuid, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_add_member(uuid, uuid, text) TO authenticated, service_role;

-- Owner / manager: the org's groups with counts (no message content).
CREATE OR REPLACE FUNCTION public.exos_org_groups(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public._exos_group_staff(p_org_id) THEN
    RAISE EXCEPTION 'exos_org_groups: owner or manager only' USING ERRCODE = '42501';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x->>'created_at' DESC) FROM (
    SELECT jsonb_build_object('id', g.id, 'title', coalesce(g.label, 'Group chat'), 'kind', g.kind, 'event_id', g.event_id, 'status', g.status,
             'join_policy', g.join_policy, 'close_after_days', g.close_after_days, 'daily_sms_cap', g.daily_sms_cap,
             'relay_enabled', g.relay_enabled, 'timezone', g.timezone, 'created_at', g.created_at,
             'closes_at', public.exos_group_closes_at(g.id), 'open', public._exos_group_open(g.id),
             'members', (SELECT count(DISTINCT m.user_id) FROM public.exos_social_group_members m WHERE m.group_id = g.id AND m.status = 'active'),
             'sms_members', (SELECT count(*) FROM public.exos_sms_relay_assignments a
                              WHERE a.group_id = g.id AND a.released_at IS NULL AND a.consented_at IS NOT NULL AND a.sms_stopped_at IS NULL),
             'sms_segments_24h', (SELECT coalesce(sum(o.segments), 0) FROM public.exos_sms_relay_outbox o
                                   WHERE o.group_id = g.id AND o.created_at > now() - interval '24 hours' AND o.status <> 'skipped'),
             'open_reports', (SELECT count(*) FROM public.exos_group_reports r WHERE r.group_id = g.id AND r.status = 'open')) AS x
      FROM public.exos_social_groups g WHERE g.org_id = p_org_id ORDER BY g.created_at DESC LIMIT 200) q), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_org_groups(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_org_groups(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Members: join, leave, state, post, mute, block, report
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_group_join(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  g     public.exos_social_groups%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_group_join: sign in first' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO g FROM public.exos_social_groups WHERE id = p_group_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_group_join: group not found' USING ERRCODE = '22023';
  END IF;
  IF public.exos_is_group_member(p_group_id) THEN
    RETURN jsonb_build_object('joined', true, 'group_id', p_group_id);
  END IF;
  IF g.join_policy = 'invite' THEN
    RAISE EXCEPTION 'exos_group_join: invite only' USING ERRCODE = '42501';
  ELSIF g.join_policy = 'ticket_holders' AND NOT EXISTS (
          SELECT 1 FROM public.exos_tickets t
           WHERE t.event_id = g.event_id AND t.owner_id = v_uid AND t.status IN ('active', 'used')) THEN
    RAISE EXCEPTION 'exos_group_join: for ticket holders of this event' USING ERRCODE = '42501';
  END IF;
  BEGIN
    RETURN public._exos_group_add_member(p_group_id, v_uid, 'member');
  EXCEPTION WHEN raise_exception OR insufficient_privilege OR invalid_parameter_value OR program_limit_exceeded THEN
    RAISE EXCEPTION 'exos_group_join: %', SQLERRM USING ERRCODE = SQLSTATE;
  END;
END $$;
REVOKE ALL ON FUNCTION public.exos_group_join(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_join(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_group_leave(p_group_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  -- The member trigger releases the number and takes back contact shares.
  UPDATE public.exos_social_group_members SET status = 'left', removed_at = now()
   WHERE group_id = p_group_id AND user_id = v_uid AND status = 'active';
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.exos_group_leave(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_leave(uuid) TO authenticated, service_role;

-- My groups (active), with when each closes.
CREATE OR REPLACE FUNCTION public.exos_my_groups()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'title', coalesce(g.label, 'Group chat'), 'kind', g.kind, 'org_id', g.org_id,
           'event_id', g.event_id, 'closes_at', public.exos_group_closes_at(g.id), 'open', public._exos_group_open(g.id),
           'last_message_at', (SELECT max(x.created_at) FROM public.exos_group_messages x WHERE x.group_id = g.id AND x.hidden_at IS NULL))
         ORDER BY m.joined DESC), '[]'::jsonb)
    FROM (SELECT group_id, min(created_at) AS joined FROM public.exos_social_group_members
           WHERE user_id = auth.uid() AND status = 'active' GROUP BY group_id) m
    JOIN public.exos_social_groups g ON g.id = m.group_id AND g.status = 'revealed'
$$;
REVOKE ALL ON FUNCTION public.exos_my_groups() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_my_groups() TO authenticated, service_role;

-- The group as its member sees it: settings, the member list (names only),
-- my masked number and SMS status. Never anyone's real number.
CREATE OR REPLACE FUNCTION public.exos_group_state(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  g     public.exos_social_groups%ROWTYPE;
  mem   public.exos_social_group_members%ROWTYPE;
  a     public.exos_sms_relay_assignments%ROWTYPE;
BEGIN
  SELECT * INTO g FROM public.exos_social_groups WHERE id = p_group_id;
  SELECT * INTO mem FROM public.exos_social_group_members WHERE group_id = p_group_id AND user_id = v_uid AND status = 'active'
   ORDER BY created_at LIMIT 1;
  IF g.id IS NULL OR mem.user_id IS NULL OR g.status <> 'revealed' THEN
    RAISE EXCEPTION 'exos_group_state: not a member' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO a FROM public.exos_sms_relay_assignments WHERE group_id = p_group_id AND user_id = v_uid AND released_at IS NULL;
  RETURN jsonb_build_object(
    'id', g.id, 'org_id', g.org_id, 'event_id', g.event_id, 'title', coalesce(g.label, 'Group chat'), 'kind', g.kind,
    'closes_at', public.exos_group_closes_at(g.id), 'open', public._exos_group_open(g.id),
    'event_over', public._exos_group_event_over(g.id), 'relay_enabled', g.relay_enabled AND g.daily_sms_cap > 0,
    'me', jsonb_build_object('user_id', v_uid, 'display_name', mem.display_name, 'role', mem.role,
            'muted_until', mem.muted_until, 'silenced_until', mem.silenced_until,
            'relay_number', (SELECT n.phone FROM public.exos_sms_relay_numbers n WHERE n.id = a.number_id),
            'sms_on', a.consented_at IS NOT NULL AND a.sms_stopped_at IS NULL
                      AND NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_stops s WHERE s.phone = a.phone),
            'sms_phone_hint', CASE WHEN a.phone IS NOT NULL THEN '…' || right(a.phone, 4) END,
            'sms_stopped', a.sms_stopped_at IS NOT NULL),
    'members', coalesce((SELECT jsonb_agg(jsonb_build_object('user_id', m.user_id, 'display_name', m.display_name,
                   'role', m.role, 'me', m.user_id = v_uid,
                   'blocked', public._exos_group_blocked(g.org_id, v_uid, m.user_id)) ORDER BY m.created_at)
                 FROM (SELECT DISTINCT ON (x.user_id) x.* FROM public.exos_social_group_members x
                        WHERE x.group_id = g.id AND x.status = 'active' AND x.user_id IS NOT NULL
                        ORDER BY x.user_id, x.created_at) m), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_group_state(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_state(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_group_post(p_group_id uuid, p_body text, p_client_ref text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'sign in first' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_group_insert_message(p_group_id, auth.uid(), p_body, 'app', p_client_ref, NULL);
EXCEPTION WHEN raise_exception OR insufficient_privilege OR invalid_parameter_value OR program_limit_exceeded THEN
  RAISE EXCEPTION 'exos_group_post: %', SQLERRM USING ERRCODE = SQLSTATE;
END $$;
REVOKE ALL ON FUNCTION public.exos_group_post(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_post(uuid, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_group_set_name(p_group_id uuid, p_name text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
BEGIN
  IF length(v) < 1 OR length(v) > 40 THEN
    RAISE EXCEPTION 'exos_group_set_name: 1 to 40 characters' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_social_group_members SET display_name = v
   WHERE group_id = p_group_id AND user_id = auth.uid() AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_group_set_name: not a member' USING ERRCODE = '42501';
  END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public.exos_group_set_name(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_set_name(uuid, text) TO authenticated, service_role;

-- Mute the group for myself (no relayed texts) until p_until; NULL unmutes.
CREATE OR REPLACE FUNCTION public.exos_group_mute(p_group_id uuid, p_until timestamptz)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.exos_social_group_members SET muted_until = CASE WHEN p_until > now() THEN least(p_until, now() + interval '1 year') END
   WHERE group_id = p_group_id AND user_id = auth.uid() AND status = 'active';
  IF NOT FOUND THEN RETURN false; END IF;
  IF p_until > now() THEN
    UPDATE public.exos_sms_relay_outbox o SET status = 'skipped', error = 'muted'
      FROM public.exos_sms_relay_assignments a
     WHERE o.assignment_id = a.id AND a.group_id = p_group_id AND a.user_id = auth.uid()
       AND o.status = 'queued' AND o.kind = 'relay';
  END IF;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_group_mute(uuid, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_mute(uuid, timestamptz) TO authenticated, service_role;

-- Block / unblock another member (holds across this org's groups).
CREATE OR REPLACE FUNCTION public.exos_group_block(p_group_id uuid, p_user_id uuid, p_block boolean DEFAULT true)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_social_groups WHERE id = p_group_id;
  IF v_uid IS NULL OR v_org IS NULL OR NOT public.exos_is_group_member(p_group_id) THEN
    RAISE EXCEPTION 'exos_group_block: not a member' USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NULL OR p_user_id = v_uid THEN
    RAISE EXCEPTION 'exos_group_block: pick someone else' USING ERRCODE = '22023';
  END IF;
  IF p_block THEN
    IF NOT EXISTS (SELECT 1 FROM public.exos_social_group_members WHERE group_id = p_group_id AND user_id = p_user_id) THEN
      RAISE EXCEPTION 'exos_group_block: not in this group' USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(*) FROM public.exos_group_blocks WHERE blocker_id = v_uid AND created_at > now() - interval '1 day') >= 50 THEN
      RAISE EXCEPTION 'exos_group_block: too many blocks today' USING ERRCODE = '54000';
    END IF;
    INSERT INTO public.exos_group_blocks (org_id, blocker_id, blocked_id) VALUES (v_org, v_uid, p_user_id) ON CONFLICT DO NOTHING;
    -- Nothing already queued between the two goes out.
    UPDATE public.exos_sms_relay_outbox o SET status = 'skipped', error = 'blocked'
      FROM public.exos_group_messages m
     WHERE o.message_id = m.id AND o.status = 'queued' AND o.org_id = v_org
       AND ((m.sender_id = p_user_id AND o.recipient_user_id = v_uid) OR (m.sender_id = v_uid AND o.recipient_user_id = p_user_id));
  ELSE
    DELETE FROM public.exos_group_blocks WHERE org_id = v_org AND blocker_id = v_uid AND blocked_id = p_user_id;
  END IF;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_group_block(uuid, uuid, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_block(uuid, uuid, boolean) TO authenticated, service_role;

-- Report a message. Three distinct reports hide it until staff review.
CREATE OR REPLACE FUNCTION public.exos_group_report(p_message_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  m        public.exos_group_messages%ROWTYPE;
  v_reason text := left(btrim(coalesce(p_reason, '')), 300);
  v_n      int;
BEGIN
  SELECT * INTO m FROM public.exos_group_messages WHERE id = p_message_id FOR UPDATE;
  IF NOT FOUND OR v_uid IS NULL OR NOT public.exos_is_group_member(m.group_id) THEN
    RAISE EXCEPTION 'exos_group_report: message not found' USING ERRCODE = '42501';
  END IF;
  IF m.sender_id = v_uid THEN
    RAISE EXCEPTION 'exos_group_report: that''s your own message' USING ERRCODE = '22023';
  END IF;
  IF length(v_reason) < 1 THEN
    RAISE EXCEPTION 'exos_group_report: say what''s wrong' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_group_reports WHERE reporter_id = v_uid AND created_at > now() - interval '1 day') >= 30 THEN
    RAISE EXCEPTION 'exos_group_report: too many reports today' USING ERRCODE = '54000';
  END IF;
  INSERT INTO public.exos_group_reports (group_id, message_id, reporter_id, reason)
  VALUES (m.group_id, m.id, v_uid, v_reason) ON CONFLICT (message_id, reporter_id) DO NOTHING;
  SELECT count(*) INTO v_n FROM public.exos_group_reports WHERE message_id = m.id AND status = 'open';
  IF v_n >= 3 AND m.hidden_at IS NULL THEN
    UPDATE public.exos_group_messages SET hidden_at = now(), hidden_reason = 'hidden after 3 reports' WHERE id = m.id;
    UPDATE public.exos_sms_relay_outbox SET status = 'skipped', error = 'hidden' WHERE message_id = m.id AND status = 'queued';
    INSERT INTO public.exos_group_moderation_log (org_id, group_id, actor_id, action, reason, target_message_id, target_user_id)
    VALUES (m.org_id, m.group_id, NULL, 'auto_hide', '3 reports', m.id, m.sender_id);
  END IF;
  RETURN jsonb_build_object('reported', true, 'hidden', v_n >= 3);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_report(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_report(uuid, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Staff moderation (owner / manager; every call is logged)
-- ---------------------------------------------------------------------------
-- Read a group's messages (hidden ones included) for moderation. A reason is
-- required and stored.
CREATE OR REPLACE FUNCTION public.exos_group_moderation_read(
  p_group_id uuid, p_reason text, p_before timestamptz DEFAULT NULL, p_limit int DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org    uuid;
  v_reason text := left(btrim(coalesce(p_reason, '')), 300);
BEGIN
  SELECT org_id INTO v_org FROM public.exos_social_groups WHERE id = p_group_id;
  IF v_org IS NULL OR NOT public._exos_group_staff(v_org) THEN
    RAISE EXCEPTION 'exos_group_moderation_read: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF length(v_reason) < 5 THEN
    RAISE EXCEPTION 'exos_group_moderation_read: give a reason (it is logged)' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_group_moderation_log (org_id, group_id, actor_id, action, reason)
  VALUES (v_org, p_group_id, auth.uid(), 'read', v_reason);
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x->>'created_at' DESC) FROM (
    SELECT jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'sender_name', m.sender_name, 'body', m.body,
             'source', m.source, 'created_at', m.created_at, 'hidden_at', m.hidden_at, 'hidden_reason', m.hidden_reason,
             'reports', (SELECT count(*) FROM public.exos_group_reports r WHERE r.message_id = m.id AND r.status = 'open')) AS x
      FROM public.exos_group_messages m
     WHERE m.group_id = p_group_id AND (p_before IS NULL OR m.created_at < p_before)
     ORDER BY m.created_at DESC LIMIT greatest(1, least(coalesce(p_limit, 100), 200))) q), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_moderation_read(uuid, text, timestamptz, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_moderation_read(uuid, text, timestamptz, int) TO authenticated, service_role;

-- Open reports across the org's groups, with the reported text (logged).
CREATE OR REPLACE FUNCTION public.exos_group_reports_open(p_org_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public._exos_group_staff(p_org_id) THEN
    RAISE EXCEPTION 'exos_group_reports_open: owner or manager only' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.exos_group_moderation_log (org_id, actor_id, action) VALUES (p_org_id, auth.uid(), 'review_reports');
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x->>'created_at') FROM (
    SELECT jsonb_build_object('id', r.id, 'group_id', r.group_id, 'group_title', coalesce(g.label, 'Group chat'), 'message_id', m.id,
             'sender_id', m.sender_id, 'sender_name', m.sender_name, 'body', m.body, 'hidden', m.hidden_at IS NOT NULL,
             'reason', r.reason, 'created_at', r.created_at) AS x
      FROM public.exos_group_reports r
      JOIN public.exos_group_messages m ON m.id = r.message_id
      JOIN public.exos_social_groups g ON g.id = r.group_id
     WHERE r.org_id = p_org_id AND r.status = 'open'
     ORDER BY r.created_at LIMIT 200) q), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_reports_open(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_reports_open(uuid) TO authenticated, service_role;

-- One entry point for moderation actions:
--   hide_message / unhide_message (p_message_id), silence_member (p_user_id,
--   p_hours 1-720) / unsilence_member, remove_member, close_group /
--   reopen_group, dismiss_report (p_message_id: all its open reports).
-- Hiding marks the message's open reports actioned.
CREATE OR REPLACE FUNCTION public.exos_group_moderate(
  p_group_id uuid, p_action text, p_reason text, p_message_id uuid DEFAULT NULL, p_user_id uuid DEFAULT NULL, p_hours int DEFAULT 24
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  g        public.exos_social_groups%ROWTYPE;
  v_reason text := left(btrim(coalesce(p_reason, '')), 300);
  v_ok     boolean := false;
BEGIN
  SELECT * INTO g FROM public.exos_social_groups WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND OR NOT public._exos_group_staff(g.org_id) THEN
    RAISE EXCEPTION 'exos_group_moderate: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF length(v_reason) < 3 THEN
    RAISE EXCEPTION 'exos_group_moderate: give a reason (it is logged)' USING ERRCODE = '22023';
  END IF;
  IF p_action IN ('hide_message', 'unhide_message', 'dismiss_report')
     AND NOT EXISTS (SELECT 1 FROM public.exos_group_messages WHERE id = p_message_id AND group_id = p_group_id) THEN
    RAISE EXCEPTION 'exos_group_moderate: message not in this group' USING ERRCODE = '22023';
  END IF;
  IF p_action IN ('silence_member', 'unsilence_member', 'remove_member')
     AND NOT EXISTS (SELECT 1 FROM public.exos_social_group_members WHERE group_id = p_group_id AND user_id = p_user_id) THEN
    RAISE EXCEPTION 'exos_group_moderate: member not in this group' USING ERRCODE = '22023';
  END IF;

  IF p_action = 'hide_message' THEN
    UPDATE public.exos_group_messages SET hidden_at = coalesce(hidden_at, now()), hidden_reason = v_reason WHERE id = p_message_id;
    UPDATE public.exos_sms_relay_outbox SET status = 'skipped', error = 'hidden' WHERE message_id = p_message_id AND status = 'queued';
    UPDATE public.exos_group_reports SET status = 'actioned', resolved_by = auth.uid(), resolved_at = now()
     WHERE message_id = p_message_id AND status = 'open';
    v_ok := true;
  ELSIF p_action = 'unhide_message' THEN
    UPDATE public.exos_group_messages SET hidden_at = NULL, hidden_reason = NULL WHERE id = p_message_id;
    v_ok := true;
  ELSIF p_action = 'dismiss_report' THEN
    UPDATE public.exos_group_reports SET status = 'dismissed', resolved_by = auth.uid(), resolved_at = now()
     WHERE message_id = p_message_id AND status = 'open';
    v_ok := FOUND;
  ELSIF p_action = 'silence_member' THEN
    IF p_hours IS NULL OR p_hours < 1 OR p_hours > 720 THEN
      RAISE EXCEPTION 'exos_group_moderate: 1 to 720 hours' USING ERRCODE = '22023';
    END IF;
    UPDATE public.exos_social_group_members SET silenced_until = now() + make_interval(hours => p_hours)
     WHERE group_id = p_group_id AND user_id = p_user_id;
    v_ok := true;
  ELSIF p_action = 'unsilence_member' THEN
    UPDATE public.exos_social_group_members SET silenced_until = NULL WHERE group_id = p_group_id AND user_id = p_user_id;
    v_ok := true;
  ELSIF p_action = 'remove_member' THEN
    UPDATE public.exos_social_group_members
       SET status = 'removed', removed_at = now(), removed_by = auth.uid(), removed_reason = v_reason
     WHERE group_id = p_group_id AND user_id = p_user_id AND status <> 'removed';
    v_ok := true;
  ELSIF p_action = 'close_group' THEN
    UPDATE public.exos_social_groups SET closed_at = coalesce(closed_at, now()) WHERE id = p_group_id;
    v_ok := true;
  ELSIF p_action = 'reopen_group' THEN
    IF g.purged_at IS NOT NULL THEN
      RAISE EXCEPTION 'exos_group_moderate: this group''s messages were already deleted' USING ERRCODE = '22023';
    END IF;
    UPDATE public.exos_social_groups SET closed_at = NULL WHERE id = p_group_id;
    IF NOT public._exos_group_open(p_group_id) THEN
      RAISE EXCEPTION 'exos_group_moderate: still past its close time; raise "close after" in the settings first' USING ERRCODE = '22023';
    END IF;
    v_ok := true;
  ELSE
    RAISE EXCEPTION 'exos_group_moderate: unknown action' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.exos_group_moderation_log (org_id, group_id, actor_id, action, reason, target_message_id, target_user_id)
  VALUES (g.org_id, p_group_id, auth.uid(), p_action, v_reason, p_message_id, p_user_id);
  RETURN v_ok;
END $$;
REVOKE ALL ON FUNCTION public.exos_group_moderate(uuid, text, text, uuid, uuid, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_moderate(uuid, text, text, uuid, uuid, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- SMS relay: opt in / out (app), inbound, drain
-- ---------------------------------------------------------------------------
-- Opt in to this group's texts with my phone and the consent text I saw. If
-- the phone already uses my pool number in another group (another account on
-- the same phone), I get another number. Queues a confirmation text.
CREATE OR REPLACE FUNCTION public.exos_group_sms_opt_in(p_group_id uuid, p_phone text, p_consent_text text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_phone text := public.exos_sms_normalize_phone(p_phone);
  v_text  text := btrim(coalesce(p_consent_text, ''));
  g       public.exos_social_groups%ROWTYPE;
  a       public.exos_sms_relay_assignments%ROWTYPE;
  v_num   uuid;
  v_nphone text;
  v_body  text;
BEGIN
  IF v_uid IS NULL OR NOT public.exos_is_group_member(p_group_id) THEN
    RAISE EXCEPTION 'exos_group_sms_opt_in: not a member' USING ERRCODE = '42501';
  END IF;
  IF v_phone IS NULL THEN
    RAISE EXCEPTION 'exos_group_sms_opt_in: enter a mobile number, e.g. +1 212 555 0100' USING ERRCODE = '22023';
  END IF;
  IF length(v_text) < 20 OR length(v_text) > 600 OR v_text !~* 'stop' OR v_text !~* 'help' THEN
    RAISE EXCEPTION 'exos_group_sms_opt_in: missing consent text' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO g FROM public.exos_social_groups WHERE id = p_group_id;
  IF NOT public._exos_group_open(p_group_id) THEN
    RAISE EXCEPTION 'exos_group_sms_opt_in: this group chat has closed' USING ERRCODE = '22023';
  END IF;
  IF NOT g.relay_enabled OR g.daily_sms_cap = 0 THEN
    RAISE EXCEPTION 'exos_group_sms_opt_in: texts are off for this group' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_sms_relay_consents
       WHERE user_id = v_uid AND action = 'opt_in' AND created_at > now() - interval '1 day') >= 10 THEN
    RAISE EXCEPTION 'exos_group_sms_opt_in: too many sign-ups today' USING ERRCODE = '54000';
  END IF;

  PERFORM public._exos_relay_lock(v_uid, v_phone);
  SELECT * INTO a FROM public.exos_sms_relay_assignments
   WHERE group_id = p_group_id AND user_id = v_uid AND released_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.exos_sms_relay_assignments (group_id, user_id) VALUES (p_group_id, v_uid) RETURNING * INTO a;
  END IF;
  v_num := a.number_id;
  IF v_num IS NULL OR EXISTS (SELECT 1 FROM public.exos_sms_relay_assignments x
                               WHERE x.number_id = v_num AND x.phone = v_phone AND x.released_at IS NULL AND x.id <> a.id) THEN
    v_num := public._exos_relay_pick_number(v_uid, v_phone, a.id);
  END IF;
  IF v_num IS NULL THEN
    RAISE EXCEPTION 'exos_group_sms_opt_in: no text number is free for you right now; the chat here still works' USING ERRCODE = '54000';
  END IF;
  UPDATE public.exos_sms_relay_assignments
     SET number_id = v_num, phone = v_phone, consent_text = v_text, consented_at = now(), sms_stopped_at = NULL
   WHERE id = a.id;
  -- Opting in again in the app is a fresh "yes" to relay texts: clear a STOPALL.
  DELETE FROM public.exos_sms_relay_stops WHERE phone = v_phone;
  SELECT phone INTO v_nphone FROM public.exos_sms_relay_numbers WHERE id = v_num;
  INSERT INTO public.exos_sms_relay_consents (org_id, group_id, user_id, phone, number_phone, action, source, consent_text)
  VALUES (g.org_id, g.id, v_uid, v_phone, v_nphone, 'opt_in', 'app', v_text);

  v_body := left('Exos group chat: you''ll get "' || left(coalesce(g.label, 'Group chat'), 40) || '" messages here. Text this number to message the group. '
                 || 'Msg freq varies. Msg & data rates may apply. Reply HELP for help, STOP to cancel.', 480);
  INSERT INTO public.exos_sms_relay_outbox (org_id, group_id, kind, assignment_id, recipient_user_id, number_id, to_phone, body, segments, send_after)
  VALUES (g.org_id, g.id, 'confirm', a.id, v_uid, v_num, v_phone, v_body, public._exos_sms_segments(v_body),
          public._exos_quiet_hours_next(now(), public._exos_group_tz(g.id)));
  RETURN jsonb_build_object('sms_on', true, 'relay_number', v_nphone, 'phone_hint', '…' || right(v_phone, 4));
END $$;
REVOKE ALL ON FUNCTION public.exos_group_sms_opt_in(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_sms_opt_in(uuid, text, text) TO authenticated, service_role;

-- Stop this group's texts from the app (the number stays assigned).
CREATE OR REPLACE FUNCTION public.exos_group_sms_opt_out(p_group_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE a public.exos_sms_relay_assignments%ROWTYPE;
BEGIN
  UPDATE public.exos_sms_relay_assignments SET sms_stopped_at = now()
   WHERE group_id = p_group_id AND user_id = auth.uid() AND released_at IS NULL
     AND consented_at IS NOT NULL AND sms_stopped_at IS NULL
  RETURNING * INTO a;
  IF a.id IS NULL THEN RETURN false; END IF;
  UPDATE public.exos_sms_relay_outbox SET status = 'skipped', error = 'opted out' WHERE assignment_id = a.id AND status = 'queued';
  INSERT INTO public.exos_sms_relay_consents (org_id, group_id, user_id, phone, number_phone, action, source)
  VALUES (a.org_id, a.group_id, a.user_id, a.phone, (SELECT phone FROM public.exos_sms_relay_numbers WHERE id = a.number_id), 'opt_out', 'app');
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_group_sms_opt_out(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_sms_opt_out(uuid) TO authenticated, service_role;

-- Queue a keyword answer (sent even during quiet hours; 5 an hour per phone).
CREATE OR REPLACE FUNCTION public._exos_relay_reply(p_number_id uuid, p_phone text, p_body text,
  p_org_id uuid DEFAULT NULL, p_group_id uuid DEFAULT NULL, p_assignment_id uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF (SELECT count(*) FROM public.exos_sms_relay_outbox
       WHERE to_phone = p_phone AND kind = 'reply' AND created_at > now() - interval '1 hour') >= 5 THEN
    RETURN false;
  END IF;
  INSERT INTO public.exos_sms_relay_outbox (org_id, group_id, kind, assignment_id, number_id, to_phone, body, segments)
  VALUES (p_org_id, p_group_id, 'reply', p_assignment_id, p_number_id, p_phone, left(p_body, 480), public._exos_sms_segments(left(p_body, 480)));
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public._exos_relay_reply(uuid, text, text, uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;

-- An inbound text, after exos-sms-relay verified the provider's signature.
-- p_keyword is relayKeyword() of the text (stop / stop_all / start / help /
-- NULL). The (from, to) pair is the routing key. Returns what happened.
CREATE OR REPLACE FUNCTION public.exos_sms_relay_inbound(
  p_provider text, p_from text, p_to text, p_text text, p_keyword text DEFAULT NULL, p_provider_ref text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_from text := public.exos_sms_normalize_phone(p_from);
  v_to   text := public.exos_sms_normalize_phone(p_to);
  n      public.exos_sms_relay_numbers%ROWTYPE;
  a      public.exos_sms_relay_assignments%ROWTYPE;
  g      public.exos_social_groups%ROWTYPE;
  v_out  jsonb;
  v_title text;
BEGIN
  IF p_keyword IS NOT NULL AND p_keyword NOT IN ('stop', 'stop_all', 'start', 'help') THEN
    RAISE EXCEPTION 'exos_sms_relay_inbound: bad keyword' USING ERRCODE = '22023';
  END IF;
  IF v_from IS NULL OR v_to IS NULL THEN
    RETURN jsonb_build_object('action', 'ignored');
  END IF;
  SELECT * INTO n FROM public.exos_sms_relay_numbers WHERE phone = v_to AND provider = p_provider;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('action', 'unknown_number');
  END IF;
  SELECT * INTO a FROM public.exos_sms_relay_assignments
   WHERE phone = v_from AND number_id = n.id AND released_at IS NULL FOR UPDATE;
  IF a.id IS NOT NULL THEN
    SELECT * INTO g FROM public.exos_social_groups WHERE id = a.group_id;
    v_title := left(coalesce(g.label, 'Group chat'), 40);
  END IF;

  IF p_keyword = 'stop_all' THEN
    INSERT INTO public.exos_sms_relay_stops (phone, source) VALUES (v_from, 'sms') ON CONFLICT (phone) DO NOTHING;
    WITH s AS (
      UPDATE public.exos_sms_relay_assignments SET sms_stopped_at = coalesce(sms_stopped_at, now())
       WHERE phone = v_from AND released_at IS NULL
      RETURNING id, org_id, group_id, user_id)
    INSERT INTO public.exos_sms_relay_consents (org_id, group_id, user_id, phone, number_phone, action, source)
    SELECT s.org_id, s.group_id, s.user_id, v_from, v_to, 'stop_all', 'sms' FROM s;
    UPDATE public.exos_sms_relay_outbox SET status = 'skipped', error = 'stopped'
     WHERE to_phone = v_from AND status = 'queued' AND kind <> 'reply';
    PERFORM public._exos_relay_reply(n.id, v_from, 'Exos: you won''t get any more Exos group texts. Reply START to turn them back on.',
                                     a.org_id, a.group_id, a.id);
    RETURN jsonb_build_object('action', 'stopped_all');
  ELSIF p_keyword = 'stop' THEN
    IF a.id IS NULL THEN
      RETURN jsonb_build_object('action', 'ignored');
    END IF;
    UPDATE public.exos_sms_relay_assignments SET sms_stopped_at = coalesce(sms_stopped_at, now()) WHERE id = a.id;
    UPDATE public.exos_sms_relay_outbox SET status = 'skipped', error = 'stopped'
     WHERE assignment_id = a.id AND status = 'queued' AND kind <> 'reply';
    INSERT INTO public.exos_sms_relay_consents (org_id, group_id, user_id, phone, number_phone, action, source)
    VALUES (a.org_id, a.group_id, a.user_id, v_from, v_to, 'stop', 'sms');
    PERFORM public._exos_relay_reply(n.id, v_from, 'Exos: you left the texts for "' || v_title
                                     || '". No more messages from this number. Reply START to rejoin.', a.org_id, a.group_id, a.id);
    RETURN jsonb_build_object('action', 'stopped', 'group_id', a.group_id);
  ELSIF p_keyword = 'start' THEN
    DELETE FROM public.exos_sms_relay_stops WHERE phone = v_from;
    IF FOUND THEN
      INSERT INTO public.exos_sms_relay_consents (org_id, group_id, user_id, phone, number_phone, action, source)
      SELECT x.org_id, x.group_id, x.user_id, v_from, v_to, 'start_all', 'sms'
        FROM public.exos_sms_relay_assignments x WHERE x.phone = v_from AND x.released_at IS NULL AND x.consented_at IS NOT NULL;
      UPDATE public.exos_sms_relay_assignments SET sms_stopped_at = NULL
       WHERE phone = v_from AND released_at IS NULL AND consented_at IS NOT NULL;
    END IF;
    IF a.id IS NULL OR a.consented_at IS NULL THEN
      RETURN jsonb_build_object('action', 'ignored');
    END IF;
    UPDATE public.exos_sms_relay_assignments SET sms_stopped_at = NULL WHERE id = a.id;
    INSERT INTO public.exos_sms_relay_consents (org_id, group_id, user_id, phone, number_phone, action, source)
    VALUES (a.org_id, a.group_id, a.user_id, v_from, v_to, 'start', 'sms');
    PERFORM public._exos_relay_reply(n.id, v_from, 'Exos: texts for "' || v_title
                                     || '" are back on. Msg & data rates may apply. Reply STOP to cancel, HELP for help.', a.org_id, a.group_id, a.id);
    RETURN jsonb_build_object('action', 'started', 'group_id', a.group_id);
  ELSIF p_keyword = 'help' THEN
    PERFORM public._exos_relay_reply(n.id, v_from,
      CASE WHEN a.id IS NOT NULL
           THEN 'Exos group chat: texts to this number go to "' || v_title || '". '
           ELSE 'Exos group chat. ' END
      || 'Msg freq varies. Msg & data rates may apply. Reply STOP to leave this group''s texts, STOPALL for all. More help in the Exos app.',
      a.org_id, a.group_id, a.id);
    RETURN jsonb_build_object('action', 'help');
  END IF;

  -- A message for the group.
  IF a.id IS NULL OR a.consented_at IS NULL THEN
    RETURN jsonb_build_object('action', 'unknown_sender');
  END IF;
  IF a.sms_stopped_at IS NOT NULL OR EXISTS (SELECT 1 FROM public.exos_sms_relay_stops WHERE phone = v_from) THEN
    RETURN jsonb_build_object('action', 'stopped_sender');
  END IF;
  IF p_provider_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_group_messages WHERE provider_ref = left(p_provider_ref, 80)) THEN
    RETURN jsonb_build_object('action', 'duplicate');
  END IF;
  IF NOT public._exos_group_open(a.group_id) THEN
    IF NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_outbox WHERE assignment_id = a.id AND kind = 'reply'
                    AND body LIKE 'Exos: this group chat has closed%' AND created_at > now() - interval '1 day') THEN
      PERFORM public._exos_relay_reply(n.id, v_from, 'Exos: this group chat has closed, so texts here no longer reach anyone.',
                                       a.org_id, a.group_id, a.id);
    END IF;
    RETURN jsonb_build_object('action', 'closed');
  END IF;
  BEGIN
    v_out := public._exos_group_insert_message(a.group_id, a.user_id, left(coalesce(p_text, ''), 1000), 'sms', NULL, left(p_provider_ref, 80));
  EXCEPTION WHEN raise_exception OR insufficient_privilege OR invalid_parameter_value OR program_limit_exceeded THEN
    RETURN jsonb_build_object('action', 'refused', 'why', SQLERRM);
  END;
  RETURN jsonb_build_object('action', 'relayed', 'group_id', a.group_id, 'message_id', v_out->'message_id',
                            'queued', v_out->'sms_queued', 'capped', v_out->'sms_capped');
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_relay_inbound(text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_sms_relay_inbound(text, text, text, text, text, text) TO service_role;

-- Drain: due texts with a 2-minute lease. The last check before sending:
-- anything to a stopped / released / muted / left recipient is skipped
-- (keyword replies always go).
CREATE OR REPLACE FUNCTION public.exos_sms_relay_claim(p_limit int DEFAULT 50)
RETURNS TABLE (id uuid, provider text, from_phone text, to_phone text, body text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE public.exos_sms_relay_outbox o SET status = 'skipped', error = 'no longer opted in'
   WHERE o.status = 'queued' AND o.send_after <= now() AND o.kind <> 'reply'
     AND (EXISTS (SELECT 1 FROM public.exos_sms_relay_stops s WHERE s.phone = o.to_phone)
          OR NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_assignments a
                          JOIN public.exos_social_group_members m ON m.group_id = a.group_id AND m.user_id = a.user_id
                         WHERE a.id = o.assignment_id AND a.released_at IS NULL AND a.consented_at IS NOT NULL
                           AND a.sms_stopped_at IS NULL AND a.phone = o.to_phone AND m.status = 'active'
                           AND (o.kind <> 'relay' OR m.muted_until IS NULL OR m.muted_until <= now())));
  RETURN QUERY
  WITH due AS (
    SELECT o.id FROM public.exos_sms_relay_outbox o
     WHERE (o.status = 'queued' OR (o.status = 'sending' AND o.lease_until < now() AND o.attempts < 3))
       AND o.send_after <= now()
     ORDER BY o.send_after
     LIMIT greatest(1, least(coalesce(p_limit, 50), 200))
     FOR UPDATE OF o SKIP LOCKED
  )
  UPDATE public.exos_sms_relay_outbox o
     SET status = 'sending', attempts = o.attempts + 1, lease_until = now() + interval '2 minutes'
    FROM due, public.exos_sms_relay_numbers n
   WHERE o.id = due.id AND n.id = o.number_id
  RETURNING o.id, n.provider, n.phone, o.to_phone, o.body;
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_relay_claim(int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_sms_relay_claim(int) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_sms_relay_mark(p_id uuid, p_status text, p_provider_id text DEFAULT NULL, p_error text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_status NOT IN ('sent', 'dry_run', 'failed', 'queued') THEN
    RAISE EXCEPTION 'exos_sms_relay_mark: bad status' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_sms_relay_outbox
     SET status = p_status, provider_id = left(p_provider_id, 80), error = left(p_error, 200),
         sent_at = CASE WHEN p_status IN ('sent', 'dry_run') THEN now() END,
         lease_until = NULL,
         send_after = CASE WHEN p_status = 'queued' THEN now() + interval '5 minutes' ELSE send_after END
   WHERE id = p_id AND status = 'sending';
  RETURN FOUND;
END $$;
REVOKE ALL ON FUNCTION public.exos_sms_relay_mark(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_sms_relay_mark(uuid, text, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- Mutual contact reveal
-- ---------------------------------------------------------------------------
-- Share my phone or Instagram with one member (p_to_user) or the whole group
-- (NULL). Phone defaults to the number I gave for texts.
CREATE OR REPLACE FUNCTION public.exos_group_share_contact(p_group_id uuid, p_kind text, p_to_user uuid DEFAULT NULL, p_value text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_org uuid;
  v_val text;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_social_groups WHERE id = p_group_id;
  IF v_uid IS NULL OR v_org IS NULL OR NOT public.exos_is_group_member(p_group_id) THEN
    RAISE EXCEPTION 'exos_group_share_contact: not a member' USING ERRCODE = '42501';
  END IF;
  IF NOT public._exos_group_event_over(p_group_id) THEN
    RAISE EXCEPTION 'exos_group_share_contact: sharing opens after the event' USING ERRCODE = '22023';
  END IF;
  IF p_kind NOT IN ('phone', 'instagram') THEN
    RAISE EXCEPTION 'exos_group_share_contact: phone or instagram' USING ERRCODE = '22023';
  END IF;
  IF p_to_user IS NOT NULL THEN
    IF p_to_user = v_uid OR NOT EXISTS (SELECT 1 FROM public.exos_social_group_members
                                         WHERE group_id = p_group_id AND user_id = p_to_user AND status = 'active') THEN
      RAISE EXCEPTION 'exos_group_share_contact: pick someone in this group' USING ERRCODE = '22023';
    END IF;
    IF public._exos_group_blocked(v_org, v_uid, p_to_user) THEN
      RAISE EXCEPTION 'exos_group_share_contact: pick someone in this group' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_kind = 'phone' THEN
    v_val := coalesce(public.exos_sms_normalize_phone(p_value),
                      CASE WHEN nullif(btrim(coalesce(p_value, '')), '') IS NULL THEN
                        (SELECT phone FROM public.exos_sms_relay_assignments
                          WHERE group_id = p_group_id AND user_id = v_uid AND released_at IS NULL) END);
    IF v_val IS NULL THEN
      RAISE EXCEPTION 'exos_group_share_contact: enter a mobile number' USING ERRCODE = '22023';
    END IF;
  ELSE
    v_val := regexp_replace(btrim(coalesce(p_value, '')), '^@', '');
    IF v_val !~ '^[A-Za-z0-9._]{1,30}$' THEN
      RAISE EXCEPTION 'exos_group_share_contact: enter an Instagram handle' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF (SELECT count(*) FROM public.exos_group_contact_log
       WHERE actor_id = v_uid AND action = 'share' AND created_at > now() - interval '1 day') >= 100 THEN
    RAISE EXCEPTION 'exos_group_share_contact: too many shares today' USING ERRCODE = '54000';
  END IF;
  UPDATE public.exos_group_contact_shares SET value = v_val
   WHERE group_id = p_group_id AND from_user = v_uid AND to_user IS NOT DISTINCT FROM p_to_user
     AND kind = p_kind AND revoked_at IS NULL;
  IF NOT FOUND THEN
    INSERT INTO public.exos_group_contact_shares (group_id, from_user, to_user, kind, value)
    VALUES (p_group_id, v_uid, p_to_user, p_kind, v_val);
  END IF;
  INSERT INTO public.exos_group_contact_log (org_id, group_id, actor_id, other_id, kind, action)
  VALUES (v_org, p_group_id, v_uid, p_to_user, p_kind, 'share');
  RETURN jsonb_build_object('shared', true, 'kind', p_kind, 'to_user', p_to_user);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_share_contact(uuid, text, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_share_contact(uuid, text, uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_group_revoke_contact(p_group_id uuid, p_kind text, p_to_user uuid DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  UPDATE public.exos_group_contact_shares SET revoked_at = now(), value = NULL
   WHERE group_id = p_group_id AND from_user = auth.uid() AND to_user IS NOT DISTINCT FROM p_to_user
     AND kind = p_kind AND revoked_at IS NULL
  RETURNING org_id INTO v_org;
  IF v_org IS NULL THEN RETURN false; END IF;
  INSERT INTO public.exos_group_contact_log (org_id, group_id, actor_id, other_id, kind, action)
  VALUES (v_org, p_group_id, auth.uid(), p_to_user, p_kind, 'revoke');
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_group_revoke_contact(uuid, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_revoke_contact(uuid, text, uuid) TO authenticated, service_role;

-- What I shared, and what others revealed to me. U's contact of kind K shows
-- only while U shares K with me (or the group) AND I share K with U (or the
-- group), both live, both active members, neither blocked. One-sided shares
-- are never shown to the other side. First views are logged.
CREATE OR REPLACE FUNCTION public.exos_group_contacts(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_org uuid;
  v_rev jsonb;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_social_groups WHERE id = p_group_id;
  IF v_uid IS NULL OR v_org IS NULL OR NOT public.exos_is_group_member(p_group_id) THEN
    RAISE EXCEPTION 'exos_group_contacts: not a member' USING ERRCODE = '42501';
  END IF;
  WITH rev AS (
  SELECT DISTINCT ON (theirs.from_user, theirs.kind) theirs.from_user AS other_id, mem.display_name, theirs.kind, theirs.value
    FROM public.exos_group_contact_shares theirs
    JOIN public.exos_social_group_members mem ON mem.group_id = theirs.group_id AND mem.user_id = theirs.from_user AND mem.status = 'active'
   WHERE theirs.group_id = p_group_id AND theirs.revoked_at IS NULL AND theirs.from_user <> v_uid
     AND (theirs.to_user IS NULL OR theirs.to_user = v_uid)
     AND EXISTS (SELECT 1 FROM public.exos_group_contact_shares mine
                  WHERE mine.group_id = p_group_id AND mine.from_user = v_uid AND mine.revoked_at IS NULL
                    AND mine.kind = theirs.kind AND (mine.to_user IS NULL OR mine.to_user = theirs.from_user))
     AND NOT public._exos_group_blocked(v_org, v_uid, theirs.from_user)
   ORDER BY theirs.from_user, theirs.kind, (theirs.to_user IS NULL), theirs.updated_at DESC
  ), logged AS (
    INSERT INTO public.exos_group_contact_log (org_id, group_id, actor_id, other_id, kind, action)
    SELECT v_org, p_group_id, v_uid, rev.other_id, rev.kind, 'view' FROM rev
    ON CONFLICT (group_id, actor_id, other_id, kind) WHERE action = 'view' DO NOTHING
    RETURNING 1)
  SELECT coalesce(jsonb_agg(jsonb_build_object('user_id', other_id, 'display_name', display_name, 'kind', kind, 'value', value)
                            ORDER BY display_name, kind), '[]'::jsonb) INTO v_rev FROM rev;
  RETURN jsonb_build_object(
    'event_over', public._exos_group_event_over(p_group_id),
    'mine', coalesce((SELECT jsonb_agg(jsonb_build_object('kind', s.kind, 'to_user', s.to_user, 'value', s.value,
                        'to_name', (SELECT m.display_name FROM public.exos_social_group_members m
                                     WHERE m.group_id = s.group_id AND m.user_id = s.to_user ORDER BY m.created_at LIMIT 1)) ORDER BY s.created_at)
                       FROM public.exos_group_contact_shares s
                      WHERE s.group_id = p_group_id AND s.from_user = v_uid AND s.revoked_at IS NULL), '[]'::jsonb),
    'revealed', v_rev);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_contacts(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_group_contacts(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Retention sweep (service role; daily cron)
-- ---------------------------------------------------------------------------
--  1. A group past its close time is marked closed and its pool numbers are
--     released (the routing keys free up for other groups).
--  2. group_chat_retention_days (default 30) after closing, its messages,
--     reports and outbox go, and contact shares are erased (revoked). The
--     consent log, contact log and moderation log stay (records).
--  3. Sent outbox rows older than 30 days lose their copy of the text.
CREATE OR REPLACE FUNCTION public.exos_group_retention_sweep()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_days   int := 30;
  v_closed int := 0;
  v_purged int := 0;
  v_msgs   int := 0;
  r        record;
BEGIN
  SELECT CASE WHEN jsonb_typeof(value) = 'number' THEN (value #>> '{}')::int END INTO v_days
    FROM public.exos_platform_settings WHERE key = 'group_chat_retention_days';
  v_days := greatest(coalesce(v_days, 30), 1);

  FOR r IN SELECT g.id, public.exos_group_closes_at(g.id) AS closes FROM public.exos_social_groups g
            WHERE g.closed_at IS NULL AND g.event_id IS NOT NULL LOOP
    IF r.closes IS NOT NULL AND r.closes <= now() THEN
      UPDATE public.exos_social_groups SET closed_at = r.closes WHERE id = r.id;
      v_closed := v_closed + 1;
    END IF;
  END LOOP;
  FOR r IN SELECT g.id FROM public.exos_social_groups g
            WHERE g.closed_at IS NOT NULL AND g.closed_at <= now()
              AND EXISTS (SELECT 1 FROM public.exos_sms_relay_assignments a WHERE a.group_id = g.id AND a.released_at IS NULL) LOOP
    PERFORM public._exos_relay_release(r.id, NULL, 'group closed');
  END LOOP;

  FOR r IN SELECT g.id FROM public.exos_social_groups g
            WHERE g.purged_at IS NULL AND g.closed_at IS NOT NULL AND g.closed_at < now() - make_interval(days => v_days) LOOP
    DELETE FROM public.exos_sms_relay_outbox WHERE group_id = r.id;
    WITH d AS (DELETE FROM public.exos_group_messages WHERE group_id = r.id RETURNING 1) SELECT v_msgs + count(*) INTO v_msgs FROM d;
    UPDATE public.exos_group_contact_shares SET revoked_at = now(), value = NULL WHERE group_id = r.id AND revoked_at IS NULL;
    UPDATE public.exos_social_groups SET purged_at = now() WHERE id = r.id;
    v_purged := v_purged + 1;
  END LOOP;

  UPDATE public.exos_sms_relay_outbox SET body = '[deleted]'
   WHERE created_at < now() - interval '30 days' AND status IN ('sent', 'dry_run', 'failed', 'skipped') AND body <> '[deleted]';
  RETURN jsonb_build_object('closed', v_closed, 'purged_groups', v_purged, 'deleted_messages', v_msgs, 'retention_days', v_days);
END $$;
REVOKE ALL ON FUNCTION public.exos_group_retention_sweep() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_group_retention_sweep() TO service_role;

-- Cron: the relay drain every minute (deploy exos-sms-relay first; it only
-- records dry runs until EXOS_SMS_RELAY=on), the retention sweep daily.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NOT NULL THEN
      IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-sms-relay-1min') THEN
        PERFORM cron.unschedule('exos-sms-relay-1min');
      END IF;
      PERFORM cron.schedule('exos-sms-relay-1min', '* * * * *', $cron$
        SELECT public._cron_invoke_edge_fn(
          coalesce(nullif(current_setting('app.exos_functions_url', true), ''),
                   'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1') || '/exos-sms-relay/cron', '{}'::jsonb);
      $cron$);
    END IF;
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-group-chat-retention-daily') THEN
      PERFORM cron.unschedule('exos-group-chat-retention-daily');
    END IF;
    PERFORM cron.schedule('exos-group-chat-retention-daily', '17 7 * * *', 'SELECT public.exos_group_retention_sweep()');
  END IF;
END $$;

-- ROLLBACK (manual): unschedule exos-sms-relay-1min and
-- exos-group-chat-retention-daily; drop the publication entry, the functions
-- above and the tables (exos_social_groups / _members only if matched seats
-- doesn't use them).
