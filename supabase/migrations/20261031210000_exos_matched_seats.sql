-- ============================================================================
-- Migration 20261031210000 — Exos: matched seats (Timeleft / 222 style)
--
-- A buyer buys a seat, not a known table. Exos groups the holders into tables
-- or crews at a cutoff, staff review and swap, and shortly before the event
-- each member gets their spot, the time and the other members' first names.
--
-- Touches:  C: TABLE exos_match_configs, exos_match_spots, exos_match_intake,
--              exos_match_answers, exos_match_leftovers, exos_match_picks,
--              exos_match_reports, exos_match_blocks
--           C: TABLE exos_social_groups, exos_social_group_members (the seam
--              the group-chat builder attaches to: kind = 'matched_seats' here)
--           C: FUNCTION exos_match_* (staff, holder, service; list in
--              docs/matched-seats.md), _exos_match_* (internal)
--           W: exos_mail template allowlist (+ 'matched-reveal')
--           C: cron.schedule exos-match-5min (created INACTIVE)
-- Pre-reqs: 20261005090000 (_exos_can_edit_event), 20261016120000 (SMS opt-in
--           + outbox), 20260926040000 (organizer refunds: leftovers are
--           refunded through exos-refund, not here)
--
-- Design notes
--   * A "matched" ticket type is an ordinary tier plus one exos_match_configs
--     row. Capacity, price, holds, checkout and fulfillment are unchanged.
--   * The quiz is opt-in and minimal: age band (never a birthdate), language,
--     interest tags from the organizer's list, solo / with friends, a party
--     code, and the first name the group sees. Saved before checkout per
--     (tier, account) as intake, or per ticket afterwards; matching copies
--     intake onto the account's tickets. Answers are only used while the
--     person who gave them still holds the ticket. exos_match_sweep deletes
--     them retention_days after the event.
--   * Matching runs in exos-match (pure logic in src/lib/matching.ts, copied
--     to _shared/matching.ts). exos_match_apply re-checks every hard rule in
--     SQL before storing: one order is never split, no group above max, no
--     spot over capacity, no blocked pair together. It locks the config row,
--     so the cron and a staff "Match now" can't both write.
--   * Reveal reuses the online-event join-link pattern: nothing about the
--     spot leaves the database until reveal time, and then only to current
--     holders, by email (transactional) and by SMS only where the holder opted
--     in to the org's texts.
--   * Undersubscribed groups: the policy (merge / refund) is applied by the
--     matcher; refund leftovers are listed for staff, who refund them through
--     the existing exos-refund path. Nothing here moves money.
--   * "Would meet again" picks are shown only when mutual.
--   * Blocks: a member's block applies in every org's matching; a staff block
--     in that org's. Keys are user ids, or 'email:<address>' for guests.
--
-- Re-run safe. Prod apply needs operator OK.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_match_configs (
  tier_id             uuid PRIMARY KEY REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  org_id              uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id            uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  group_min           integer NOT NULL DEFAULT 4 CHECK (group_min BETWEEN 1 AND 50),
  group_target        integer NOT NULL DEFAULT 6 CHECK (group_target BETWEEN 1 AND 50),
  group_max           integer NOT NULL DEFAULT 8 CHECK (group_max BETWEEN 1 AND 50),
  group_count         integer CHECK (group_count IS NULL OR group_count BETWEEN 1 AND 500),
  match_hours_before  integer NOT NULL DEFAULT 24 CHECK (match_hours_before BETWEEN 1 AND 720),
  reveal_hours_before integer NOT NULL DEFAULT 3 CHECK (reveal_hours_before BETWEEN 0 AND 720),
  undersub_policy     text NOT NULL DEFAULT 'merge' CHECK (undersub_policy IN ('merge', 'refund')),
  quiz_enabled        boolean NOT NULL DEFAULT true,
  quiz_tags           text[] NOT NULL DEFAULT '{}'::text[]
                        CHECK (cardinality(quiz_tags) <= 20),
  quiz_languages      text[] NOT NULL DEFAULT ARRAY['en']::text[]
                        CHECK (cardinality(quiz_languages) BETWEEN 1 AND 10),
  retention_days      integer NOT NULL DEFAULT 14 CHECK (retention_days BETWEEN 1 AND 90),
  seed                bigint,
  status              text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'matched', 'revealed')),
  matched_at          timestamptz,
  matched_by          uuid,
  revealed_at         timestamptz,
  swept_at            timestamptz,
  created_by          uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_match_configs_sizes_chk CHECK (group_min <= group_target AND group_target <= group_max),
  CONSTRAINT exos_match_configs_times_chk CHECK (reveal_hours_before <= match_hours_before)
);
CREATE INDEX IF NOT EXISTS exos_match_configs_event_idx ON public.exos_match_configs (event_id);
CREATE INDEX IF NOT EXISTS exos_match_configs_open_idx ON public.exos_match_configs (status) WHERE status <> 'revealed';

CREATE TABLE IF NOT EXISTS public.exos_match_spots (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tier_id     uuid NOT NULL REFERENCES public.exos_match_configs (tier_id) ON DELETE CASCADE,
  org_id      uuid NOT NULL,
  event_id    uuid NOT NULL,
  name        text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
  address     text CHECK (address IS NULL OR char_length(address) <= 300),
  details     text CHECK (details IS NULL OR char_length(details) <= 500),
  meet_at     timestamptz,                      -- NULL = the event's start
  capacity    integer NOT NULL CHECK (capacity BETWEEN 1 AND 2000),
  sort_order  integer NOT NULL DEFAULT 0,
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_match_spots_tier_idx ON public.exos_match_spots (tier_id, sort_order);

-- Quiz answers. Same shape for intake (before checkout, per account) and
-- answers (per ticket).
CREATE TABLE IF NOT EXISTS public.exos_match_intake (
  tier_id      uuid NOT NULL REFERENCES public.exos_match_configs (tier_id) ON DELETE CASCADE,
  user_id      uuid NOT NULL,
  org_id       uuid NOT NULL,
  event_id     uuid NOT NULL,
  age_band     text CHECK (age_band IN ('18-24', '25-34', '35-44', '45-54', '55+')),
  language     text CHECK (language ~ '^[a-z]{2,3}$'),
  tags         text[] NOT NULL DEFAULT '{}'::text[] CHECK (cardinality(tags) <= 5),
  mode         text CHECK (mode IN ('solo', 'friends')),
  party_code   text CHECK (party_code ~ '^[A-Z0-9]{4,12}$'),
  display_name text CHECK (char_length(display_name) BETWEEN 1 AND 40),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tier_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.exos_match_answers (
  ticket_id    uuid PRIMARY KEY REFERENCES public.exos_tickets (id) ON DELETE CASCADE,
  tier_id      uuid NOT NULL REFERENCES public.exos_match_configs (tier_id) ON DELETE CASCADE,
  user_id      uuid NOT NULL,                   -- who answered; ignored once they no longer hold it
  org_id       uuid NOT NULL,
  event_id     uuid NOT NULL,
  age_band     text CHECK (age_band IN ('18-24', '25-34', '35-44', '45-54', '55+')),
  language     text CHECK (language ~ '^[a-z]{2,3}$'),
  tags         text[] NOT NULL DEFAULT '{}'::text[] CHECK (cardinality(tags) <= 5),
  mode         text CHECK (mode IN ('solo', 'friends')),
  party_code   text CHECK (party_code ~ '^[A-Z0-9]{4,12}$'),
  display_name text CHECK (char_length(display_name) BETWEEN 1 AND 40),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_match_answers_tier_idx ON public.exos_match_answers (tier_id);

-- The seam for social features. kind = 'matched_seats' for this migration's
-- tables / crews; other builders add their own kinds (any lower_snake word).
CREATE TABLE IF NOT EXISTS public.exos_social_groups (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  kind        text NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_]{1,39}$'),
  tier_id     uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE SET NULL,
  spot_id     uuid REFERENCES public.exos_match_spots (id) ON DELETE SET NULL,
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
  user_id        uuid,                          -- holder when added (the ticket's owner is current)
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
-- One active seat per ticket per kind.
CREATE UNIQUE INDEX IF NOT EXISTS exos_social_group_members_one_active
  ON public.exos_social_group_members (kind, ticket_id) WHERE status = 'active' AND ticket_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_match_leftovers (
  ticket_id   uuid PRIMARY KEY REFERENCES public.exos_tickets (id) ON DELETE CASCADE,
  tier_id     uuid NOT NULL REFERENCES public.exos_match_configs (tier_id) ON DELETE CASCADE,
  org_id      uuid NOT NULL,
  event_id    uuid NOT NULL,
  reason      text NOT NULL CHECK (reason IN ('party_too_big', 'no_room', 'blocked', 'undersubscribed', 'late', 'removed')),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_match_leftovers_tier_idx ON public.exos_match_leftovers (tier_id);

-- "Would meet again": from one member to another of the same group.
CREATE TABLE IF NOT EXISTS public.exos_match_picks (
  group_id    uuid NOT NULL REFERENCES public.exos_social_groups (id) ON DELETE CASCADE,
  from_member uuid NOT NULL REFERENCES public.exos_social_group_members (id) ON DELETE CASCADE,
  to_member   uuid NOT NULL REFERENCES public.exos_social_group_members (id) ON DELETE CASCADE,
  org_id      uuid NOT NULL,
  event_id    uuid NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (from_member, to_member),
  CHECK (from_member <> to_member)
);
CREATE INDEX IF NOT EXISTS exos_match_picks_to_idx ON public.exos_match_picks (to_member);

CREATE TABLE IF NOT EXISTS public.exos_match_reports (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL,
  event_id     uuid NOT NULL,
  group_id     uuid REFERENCES public.exos_social_groups (id) ON DELETE SET NULL,
  reporter_id  uuid NOT NULL,
  member_id    uuid REFERENCES public.exos_social_group_members (id) ON DELETE SET NULL,
  reason       text NOT NULL CHECK (reason IN ('safety', 'harassment', 'inappropriate', 'no_show', 'other')),
  details      text CHECK (details IS NULL OR char_length(details) <= 1000),
  status       text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'reviewed', 'actioned', 'dismissed')),
  reviewed_by  uuid,
  reviewed_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_match_reports_org_idx ON public.exos_match_reports (org_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_match_reports_reporter_idx ON public.exos_match_reports (reporter_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.exos_match_blocks (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,   -- where it was made
  a_key       text NOT NULL CHECK (char_length(a_key) BETWEEN 1 AND 330),
  b_key       text NOT NULL CHECK (char_length(b_key) BETWEEN 1 AND 330),
  source      text NOT NULL CHECK (source IN ('member', 'staff')),
  reason      text CHECK (reason IS NULL OR char_length(reason) <= 300),
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (a_key <> b_key)
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_match_blocks_pair
  ON public.exos_match_blocks (org_id, source, least(a_key, b_key), greatest(a_key, b_key));
CREATE INDEX IF NOT EXISTS exos_match_blocks_a_idx ON public.exos_match_blocks (a_key);
CREATE INDEX IF NOT EXISTS exos_match_blocks_b_idx ON public.exos_match_blocks (b_key);

-- RLS on everything. Clients read staff-facing rows through policies; every
-- write (and every holder read) goes through the definer RPCs below.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_match_configs', 'exos_match_spots', 'exos_match_intake',
      'exos_match_answers', 'exos_social_groups', 'exos_social_group_members',
      'exos_match_leftovers', 'exos_match_picks', 'exos_match_reports', 'exos_match_blocks'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['exos_match_configs', 'exos_match_spots', 'exos_match_intake',
      'exos_match_answers', 'exos_social_groups', 'exos_social_group_members',
      'exos_match_reports'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I '
                   'FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at()', t || '_touch', t);
  END LOOP;
  -- Staff (owner / manager) read their org's rows.
  FOREACH t IN ARRAY ARRAY['exos_match_configs', 'exos_match_spots', 'exos_social_groups',
      'exos_social_group_members', 'exos_match_leftovers', 'exos_match_reports'] LOOP
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_staff_read', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated '
                   'USING (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'']))',
                   t || '_staff_read', t);
  END LOOP;
END $$;
-- Staff blocks are visible to that org's staff; a member's block is visible to nobody.
GRANT SELECT ON public.exos_match_blocks TO authenticated;
DROP POLICY IF EXISTS exos_match_blocks_staff_read ON public.exos_match_blocks;
CREATE POLICY exos_match_blocks_staff_read ON public.exos_match_blocks FOR SELECT TO authenticated
  USING (source = 'staff' AND (public.exos_is_admin() OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager'])));

-- Members: org / event / kind come from the group; the ticket must be the event's.
CREATE OR REPLACE FUNCTION public.exos_tg_social_member_fill()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE g record;
BEGIN
  SELECT org_id, event_id, kind INTO g FROM public.exos_social_groups WHERE id = NEW.group_id;
  IF g.org_id IS NULL THEN
    RAISE EXCEPTION 'exos_social_group_members: no such group' USING ERRCODE = '23503';
  END IF;
  NEW.org_id := g.org_id; NEW.event_id := g.event_id; NEW.kind := g.kind;
  IF NEW.ticket_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.ticket_id IS DISTINCT FROM OLD.ticket_id)
     AND NOT EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.id = NEW.ticket_id AND t.event_id = g.event_id) THEN
    RAISE EXCEPTION 'exos_social_group_members: ticket is not for this event' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_social_member_fill() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_social_group_members_fill ON public.exos_social_group_members;
CREATE TRIGGER exos_social_group_members_fill BEFORE INSERT OR UPDATE OF group_id, ticket_id
  ON public.exos_social_group_members FOR EACH ROW EXECUTE FUNCTION public.exos_tg_social_member_fill();

-- ---------------------------------------------------------------------------
-- 2. Internal helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_match_esc(p text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;
REVOKE ALL ON FUNCTION public._exos_match_esc(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_match_esc(text) TO service_role;

-- Who holds a ticket, as a block key.
CREATE OR REPLACE FUNCTION public._exos_match_user_key(p_owner uuid, p_email text, p_ticket uuid)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(p_owner::text, 'email:' || nullif(lower(btrim(p_email)), ''), 'ticket:' || p_ticket::text)
$$;
REVOKE ALL ON FUNCTION public._exos_match_user_key(uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_match_user_key(uuid, text, uuid) TO service_role;

-- Match / reveal times for a tier.
CREATE OR REPLACE FUNCTION public._exos_match_times(p_tier_id uuid, OUT match_at timestamptz, OUT reveal_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT e.starts_at - make_interval(hours => c.match_hours_before),
         e.starts_at - make_interval(hours => c.reveal_hours_before)
    FROM public.exos_match_configs c JOIN public.exos_events e ON e.id = c.event_id
   WHERE c.tier_id = p_tier_id
$$;
REVOKE ALL ON FUNCTION public._exos_match_times(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_match_times(uuid) TO service_role;

-- Validate + normalize quiz answers against the tier's options. Raises 22023.
CREATE OR REPLACE FUNCTION public._exos_match_clean_answers(p_tier_id uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c      public.exos_match_configs%ROWTYPE;
  v_age  text := nullif(btrim(coalesce(p ->> 'age_band', '')), '');
  v_lang text := nullif(lower(btrim(coalesce(p ->> 'language', ''))), '');
  v_mode text := nullif(btrim(coalesce(p ->> 'mode', '')), '');
  v_code text := upper(regexp_replace(coalesce(p ->> 'party_code', ''), '[^A-Za-z0-9]', '', 'g'));
  v_name text := btrim(regexp_replace(coalesce(p ->> 'display_name', ''), '[<>"&\s]+', ' ', 'g'));
  v_tags text[] := '{}';
BEGIN
  SELECT * INTO c FROM public.exos_match_configs WHERE tier_id = p_tier_id;
  IF c.tier_id IS NULL THEN
    RAISE EXCEPTION 'not a matched ticket type' USING ERRCODE = '22023';
  END IF;
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RAISE EXCEPTION 'answers must be an object' USING ERRCODE = '22023';
  END IF;
  IF v_age IS NOT NULL AND v_age NOT IN ('18-24', '25-34', '35-44', '45-54', '55+') THEN
    RAISE EXCEPTION 'pick an age band' USING ERRCODE = '22023';
  END IF;
  IF v_lang IS NOT NULL AND NOT (v_lang = ANY (c.quiz_languages)) THEN
    RAISE EXCEPTION 'pick one of the listed languages' USING ERRCODE = '22023';
  END IF;
  IF v_mode IS NOT NULL AND v_mode NOT IN ('solo', 'friends') THEN
    RAISE EXCEPTION 'solo or friends' USING ERRCODE = '22023';
  END IF;
  IF v_code = '' THEN v_code := NULL;
  ELSIF char_length(v_code) NOT BETWEEN 4 AND 12 THEN
    RAISE EXCEPTION 'a party code is 4 to 12 letters or digits' USING ERRCODE = '22023';
  END IF;
  -- First name only: the first word, at most 40 characters.
  v_name := nullif(left(split_part(v_name, ' ', 1), 40), '');
  IF p ? 'tags' THEN
    IF jsonb_typeof(p -> 'tags') <> 'array' THEN
      RAISE EXCEPTION 'tags must be a list' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(array_agg(DISTINCT x ORDER BY x), '{}') INTO v_tags
      FROM jsonb_array_elements_text(p -> 'tags') x;
    IF cardinality(v_tags) > 5 THEN
      RAISE EXCEPTION 'pick up to 5 interests' USING ERRCODE = '22023';
    END IF;
    IF NOT (v_tags <@ c.quiz_tags) THEN
      RAISE EXCEPTION 'pick interests from the list' USING ERRCODE = '22023';
    END IF;
  END IF;
  RETURN jsonb_build_object('age_band', v_age, 'language', v_lang, 'tags', to_jsonb(v_tags),
                            'mode', v_mode, 'party_code', v_code, 'display_name', v_name);
END $$;
REVOKE ALL ON FUNCTION public._exos_match_clean_answers(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_match_clean_answers(uuid, jsonb) TO service_role;

-- Staff gate for a tier: owner / manager of the event's org (or admin).
-- Returns the config row; raises 42501 otherwise.
CREATE OR REPLACE FUNCTION public._exos_match_staff_cfg(p_tier_id uuid, p_actor uuid DEFAULT NULL)
RETURNS public.exos_match_configs
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_match_configs%ROWTYPE;
BEGIN
  SELECT * INTO c FROM public.exos_match_configs WHERE tier_id = p_tier_id;
  IF c.tier_id IS NULL THEN
    RAISE EXCEPTION 'not a matched ticket type' USING ERRCODE = '42501';
  END IF;
  IF p_actor IS NOT NULL THEN
    -- Service call on behalf of a verified user (exos-match "Match now").
    IF NOT EXISTS (SELECT 1 FROM public.exos_org_memberships m
                    WHERE m.org_id = c.org_id AND m.user_id = p_actor
                      AND m.disabled IS NOT TRUE AND m.role IN ('owner', 'manager')) THEN
      RAISE EXCEPTION 'owner or manager only' USING ERRCODE = '42501';
    END IF;
  ELSIF auth.uid() IS NULL OR NOT public._exos_can_edit_event(c.event_id) THEN
    RAISE EXCEPTION 'owner or manager only' USING ERRCODE = '42501';
  END IF;
  RETURN c;
END $$;
REVOKE ALL ON FUNCTION public._exos_match_staff_cfg(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_match_staff_cfg(uuid, uuid) TO service_role;

-- Is this pair blocked for matching in this org? (member blocks: any org)
CREATE OR REPLACE FUNCTION public._exos_match_blocked(p_org uuid, p_a text, p_b text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_match_blocks b
                  WHERE (b.source = 'member' OR b.org_id = p_org)
                    AND ((b.a_key = p_a AND b.b_key = p_b) OR (b.a_key = p_b AND b.b_key = p_a)))
$$;
REVOKE ALL ON FUNCTION public._exos_match_blocked(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_match_blocked(uuid, text, text) TO service_role;

-- A group member's first name as the group sees it.
CREATE OR REPLACE FUNCTION public._exos_match_first_name(p_member uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(nullif(m.display_name, ''),
                  nullif(left(split_part(btrim(coalesce(t.attendee_name, '')), ' ', 1), 40), ''),
                  'Guest')
    FROM public.exos_social_group_members m
    LEFT JOIN public.exos_tickets t ON t.id = m.ticket_id
   WHERE m.id = p_member
$$;
REVOKE ALL ON FUNCTION public._exos_match_first_name(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_match_first_name(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Mail template allowlist (+ matched-reveal): live list ∪ known ∪ new.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['matched-reveal'];
  v_vals text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_mail'::regclass AND c.conname = 'exos_mail_template_check';
  IF strpos(coalesce(v_def, ''), '''{') > 0 THEN
    v_live := string_to_array(substring(v_def FROM '''\{([^}]*)\}'''), ',');
  ELSE
    SELECT array_agg(m[1]) INTO v_live
      FROM regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g') AS m;
  END IF;
  IF v_new <@ coalesce(v_live, '{}'::text[]) THEN
    RETURN;
  END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM (
    SELECT btrim(unnest(coalesce(v_live, '{}'::text[])), ' "') AS x
    UNION
    SELECT unnest(ARRAY[
      'transfer-initiated','transfer-claimed','org-invite','event-cancelled','event-updated',
      'event-announce','ticket-issued','waitlist-open','event-announcement','event-rescheduled',
      'event-reminder','order-failed','checkout-abandoned','marketplace-attention',
      'event-published','inventory-low','inventory-sold-out','payout-sent',
      'payout-pending','fee-free-ending','org-welcome','org-first-event',
      'org-connect-stripe','org-sales-digest','org-weekly-summary',
      'refund-issued','post-event','dispute-opened','dispute-won','dispute-lost'] || v_new)
  ) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check '
                 'CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

-- ---------------------------------------------------------------------------
-- 4. Staff: settings and spots
-- ---------------------------------------------------------------------------
-- Make a tier "matched" (or update it). p_config keys: group_min, group_target,
-- group_max, group_count, match_hours_before, reveal_hours_before,
-- undersub_policy, quiz_enabled, quiz_tags, quiz_languages, retention_days, seed.
-- Sizes and times are frozen once matching has run.
CREATE OR REPLACE FUNCTION public.exos_match_set_config(p_tier_id uuid, p_config jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tier  record;
  v_old   public.exos_match_configs%ROWTYPE;
  v_new   public.exos_match_configs%ROWTYPE;
  v_tags  text[];
  v_langs text[];
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_match_set_config: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT t.id, t.event_id, e.org_id INTO v_tier
    FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
   WHERE t.id = p_tier_id;
  IF v_tier.id IS NULL OR NOT public._exos_can_edit_event(v_tier.event_id) THEN
    RAISE EXCEPTION 'exos_match_set_config: not authorized for this ticket type' USING ERRCODE = '42501';
  END IF;
  IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
    RAISE EXCEPTION 'exos_match_set_config: settings must be an object' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_old FROM public.exos_match_configs WHERE tier_id = p_tier_id FOR UPDATE;

  IF p_config ? 'quiz_tags' THEN
    IF jsonb_typeof(p_config -> 'quiz_tags') <> 'array' THEN
      RAISE EXCEPTION 'exos_match_set_config: quiz_tags must be a list' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(array_agg(DISTINCT x ORDER BY x), '{}') INTO v_tags
      FROM (SELECT lower(btrim(x)) AS x FROM jsonb_array_elements_text(p_config -> 'quiz_tags') x) y
     WHERE x <> '';
    IF EXISTS (SELECT 1 FROM unnest(v_tags) x WHERE x !~ '^[a-z0-9][a-z0-9 &/-]{0,29}$') THEN
      RAISE EXCEPTION 'exos_match_set_config: interests are 1 to 30 letters, digits, spaces' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_config ? 'quiz_languages' THEN
    IF jsonb_typeof(p_config -> 'quiz_languages') <> 'array' THEN
      RAISE EXCEPTION 'exos_match_set_config: quiz_languages must be a list' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(array_agg(DISTINCT x ORDER BY x), '{}') INTO v_langs
      FROM (SELECT lower(btrim(x)) AS x FROM jsonb_array_elements_text(p_config -> 'quiz_languages') x) y;
    IF EXISTS (SELECT 1 FROM unnest(v_langs) x WHERE x !~ '^[a-z]{2,3}$') THEN
      RAISE EXCEPTION 'exos_match_set_config: languages are 2-3 letter codes (en, es)' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_new := v_old;
  v_new.tier_id := p_tier_id;
  v_new.org_id := v_tier.org_id;
  v_new.event_id := v_tier.event_id;
  BEGIN
    v_new.group_min           := coalesce((p_config ->> 'group_min')::int, v_old.group_min, 4);
    v_new.group_target        := coalesce((p_config ->> 'group_target')::int, v_old.group_target, 6);
    v_new.group_max           := coalesce((p_config ->> 'group_max')::int, v_old.group_max, 8);
    v_new.group_count         := CASE WHEN p_config ? 'group_count' THEN (p_config ->> 'group_count')::int ELSE v_old.group_count END;
    v_new.match_hours_before  := coalesce((p_config ->> 'match_hours_before')::int, v_old.match_hours_before, 24);
    v_new.reveal_hours_before := coalesce((p_config ->> 'reveal_hours_before')::int, v_old.reveal_hours_before, 3);
    v_new.undersub_policy     := coalesce(p_config ->> 'undersub_policy', v_old.undersub_policy, 'merge');
    v_new.quiz_enabled        := coalesce((p_config ->> 'quiz_enabled')::boolean, v_old.quiz_enabled, true);
    v_new.retention_days      := coalesce((p_config ->> 'retention_days')::int, v_old.retention_days, 14);
    v_new.seed                := CASE WHEN p_config ? 'seed' THEN (p_config ->> 'seed')::bigint ELSE v_old.seed END;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'exos_match_set_config: numbers only' USING ERRCODE = '22023';
  END;
  v_new.quiz_tags      := coalesce(v_tags, v_old.quiz_tags, '{}');
  v_new.quiz_languages := coalesce(v_langs, v_old.quiz_languages, ARRAY['en']);

  IF v_old.tier_id IS NOT NULL AND v_old.status <> 'open' AND (
       v_new.group_min, v_new.group_target, v_new.group_max, v_new.group_count,
       v_new.match_hours_before, v_new.undersub_policy)
       IS DISTINCT FROM (v_old.group_min, v_old.group_target, v_old.group_max, v_old.group_count,
       v_old.match_hours_before, v_old.undersub_policy) THEN
    RAISE EXCEPTION 'exos_match_set_config: groups are already matched; sizes and the cutoff are fixed' USING ERRCODE = '55000';
  END IF;

  INSERT INTO public.exos_match_configs AS c (tier_id, org_id, event_id, group_min, group_target, group_max,
      group_count, match_hours_before, reveal_hours_before, undersub_policy, quiz_enabled, quiz_tags,
      quiz_languages, retention_days, seed, created_by)
  VALUES (p_tier_id, v_new.org_id, v_new.event_id, v_new.group_min, v_new.group_target, v_new.group_max,
      v_new.group_count, v_new.match_hours_before, v_new.reveal_hours_before, v_new.undersub_policy,
      v_new.quiz_enabled, v_new.quiz_tags, v_new.quiz_languages, v_new.retention_days, v_new.seed, auth.uid())
  ON CONFLICT (tier_id) DO UPDATE SET
      group_min = EXCLUDED.group_min, group_target = EXCLUDED.group_target, group_max = EXCLUDED.group_max,
      group_count = EXCLUDED.group_count, match_hours_before = EXCLUDED.match_hours_before,
      reveal_hours_before = EXCLUDED.reveal_hours_before, undersub_policy = EXCLUDED.undersub_policy,
      quiz_enabled = EXCLUDED.quiz_enabled, quiz_tags = EXCLUDED.quiz_tags,
      quiz_languages = EXCLUDED.quiz_languages, retention_days = EXCLUDED.retention_days, seed = EXCLUDED.seed;
  RETURN (SELECT to_jsonb(c) FROM public.exos_match_configs c WHERE c.tier_id = p_tier_id);
EXCEPTION WHEN check_violation THEN
  RAISE EXCEPTION 'exos_match_set_config: sizes need min <= target <= max (1-50); reveal no earlier than the cutoff'
    USING ERRCODE = '22023';
END $$;
REVOKE ALL ON FUNCTION public.exos_match_set_config(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_set_config(uuid, jsonb) TO authenticated, service_role;

-- Add or edit a spot (restaurant, bar, meeting point). p_spot: id?, name,
-- address, details, meet_at, capacity, sort_order, active.
CREATE OR REPLACE FUNCTION public.exos_match_upsert_spot(p_tier_id uuid, p_spot jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c    public.exos_match_configs%ROWTYPE := public._exos_match_staff_cfg(p_tier_id);
  v_id uuid;
BEGIN
  IF p_spot IS NULL OR jsonb_typeof(p_spot) <> 'object' THEN
    RAISE EXCEPTION 'exos_match_upsert_spot: spot must be an object' USING ERRCODE = '22023';
  END IF;
  BEGIN
    v_id := nullif(p_spot ->> 'id', '')::uuid;
    IF v_id IS NULL THEN
      IF (SELECT count(*) FROM public.exos_match_spots WHERE tier_id = p_tier_id) >= 100 THEN
        RAISE EXCEPTION 'exos_match_upsert_spot: at most 100 spots' USING ERRCODE = '54000';
      END IF;
      INSERT INTO public.exos_match_spots (tier_id, org_id, event_id, name, address, details, meet_at, capacity, sort_order, active)
      VALUES (p_tier_id, c.org_id, c.event_id, btrim(p_spot ->> 'name'), nullif(btrim(p_spot ->> 'address'), ''),
              nullif(btrim(p_spot ->> 'details'), ''), nullif(p_spot ->> 'meet_at', '')::timestamptz,
              (p_spot ->> 'capacity')::int, coalesce((p_spot ->> 'sort_order')::int, 0),
              coalesce((p_spot ->> 'active')::boolean, true))
      RETURNING id INTO v_id;
    ELSE
      UPDATE public.exos_match_spots s SET
             name = coalesce(btrim(p_spot ->> 'name'), s.name),
             address = CASE WHEN p_spot ? 'address' THEN nullif(btrim(p_spot ->> 'address'), '') ELSE s.address END,
             details = CASE WHEN p_spot ? 'details' THEN nullif(btrim(p_spot ->> 'details'), '') ELSE s.details END,
             meet_at = CASE WHEN p_spot ? 'meet_at' THEN nullif(p_spot ->> 'meet_at', '')::timestamptz ELSE s.meet_at END,
             capacity = coalesce((p_spot ->> 'capacity')::int, s.capacity),
             sort_order = coalesce((p_spot ->> 'sort_order')::int, s.sort_order),
             active = coalesce((p_spot ->> 'active')::boolean, s.active)
       WHERE s.id = v_id AND s.tier_id = p_tier_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'exos_match_upsert_spot: no such spot on this ticket type' USING ERRCODE = '22023';
      END IF;
    END IF;
  EXCEPTION
    WHEN invalid_text_representation OR invalid_datetime_format OR datetime_field_overflow THEN
      RAISE EXCEPTION 'exos_match_upsert_spot: check the capacity and time' USING ERRCODE = '22023';
    WHEN check_violation OR not_null_violation THEN
      RAISE EXCEPTION 'exos_match_upsert_spot: a name (up to 120) and a capacity (1-2000) are needed' USING ERRCODE = '22023';
  END;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_match_upsert_spot(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_upsert_spot(uuid, jsonb) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_match_delete_spot(p_spot_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_tier uuid;
BEGIN
  SELECT tier_id INTO v_tier FROM public.exos_match_spots WHERE id = p_spot_id;
  PERFORM public._exos_match_staff_cfg(v_tier);
  IF EXISTS (SELECT 1 FROM public.exos_social_groups g WHERE g.spot_id = p_spot_id AND g.status <> 'dissolved') THEN
    RAISE EXCEPTION 'exos_match_delete_spot: groups sit here; turn it off instead' USING ERRCODE = '55000';
  END IF;
  DELETE FROM public.exos_match_spots WHERE id = p_spot_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_match_delete_spot(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_delete_spot(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Public: what the event page needs (no spots, no people)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_match_public(p_event_id uuid)
RETURNS TABLE (tier_id uuid, group_min int, group_target int, group_max int, quiz_enabled boolean,
               quiz_tags text[], quiz_languages text[], match_at timestamptz, reveal_at timestamptz,
               spot_count int, status text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT c.tier_id, c.group_min, c.group_target, c.group_max, c.quiz_enabled, c.quiz_tags, c.quiz_languages,
         e.starts_at - make_interval(hours => c.match_hours_before),
         e.starts_at - make_interval(hours => c.reveal_hours_before),
         (SELECT count(*)::int FROM public.exos_match_spots s WHERE s.tier_id = c.tier_id AND s.active),
         c.status
    FROM public.exos_match_configs c
    JOIN public.exos_events e ON e.id = c.event_id
    JOIN public.exos_ticket_tiers t ON t.id = c.tier_id
   WHERE c.event_id = p_event_id AND e.status = 'published' AND t.visibility = 'public'
   ORDER BY t.sort_order, c.tier_id
$$;
REVOKE ALL ON FUNCTION public.exos_match_public(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_public(uuid) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Holders: quiz
-- ---------------------------------------------------------------------------
-- Before checkout (signed in): answers for this tier, copied onto the
-- account's tickets when matching runs.
CREATE OR REPLACE FUNCTION public.exos_match_save_intake(p_tier_id uuid, p_answers jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c public.exos_match_configs%ROWTYPE;
  a jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_match_save_intake: sign in first' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO c FROM public.exos_match_configs WHERE tier_id = p_tier_id;
  IF c.tier_id IS NULL OR NOT c.quiz_enabled OR c.status <> 'open'
     OR NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = c.event_id AND e.status = 'published') THEN
    RAISE EXCEPTION 'exos_match_save_intake: this ticket type takes no answers now' USING ERRCODE = '22023';
  END IF;
  a := public._exos_match_clean_answers(p_tier_id, p_answers);
  INSERT INTO public.exos_match_intake AS i (tier_id, user_id, org_id, event_id, age_band, language, tags, mode, party_code, display_name)
  VALUES (p_tier_id, auth.uid(), c.org_id, c.event_id, a ->> 'age_band', a ->> 'language',
          ARRAY(SELECT jsonb_array_elements_text(a -> 'tags')), a ->> 'mode', a ->> 'party_code', a ->> 'display_name')
  ON CONFLICT (tier_id, user_id) DO UPDATE SET
     age_band = EXCLUDED.age_band, language = EXCLUDED.language, tags = EXCLUDED.tags,
     mode = EXCLUDED.mode, party_code = EXCLUDED.party_code, display_name = EXCLUDED.display_name;
  RETURN a;
END $$;
REVOKE ALL ON FUNCTION public.exos_match_save_intake(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_save_intake(uuid, jsonb) TO authenticated, service_role;

-- After purchase: answers for one ticket (its current holder), until matching.
CREATE OR REPLACE FUNCTION public.exos_match_set_answers(p_ticket_id uuid, p_answers jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  t record;
  c public.exos_match_configs%ROWTYPE;
  a jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_match_set_answers: sign in first' USING ERRCODE = '42501';
  END IF;
  SELECT id, tier_id, owner_id, status INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF t.id IS NULL OR t.owner_id IS DISTINCT FROM auth.uid() OR t.status <> 'active' THEN
    RAISE EXCEPTION 'exos_match_set_answers: not your ticket' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO c FROM public.exos_match_configs WHERE tier_id = t.tier_id;
  IF c.tier_id IS NULL OR NOT c.quiz_enabled THEN
    RAISE EXCEPTION 'exos_match_set_answers: this ticket takes no answers' USING ERRCODE = '22023';
  END IF;
  IF c.status <> 'open' THEN
    RAISE EXCEPTION 'exos_match_set_answers: groups are already matched' USING ERRCODE = '55000';
  END IF;
  a := public._exos_match_clean_answers(t.tier_id, p_answers);
  INSERT INTO public.exos_match_answers AS x (ticket_id, tier_id, user_id, org_id, event_id, age_band, language, tags, mode, party_code, display_name)
  VALUES (p_ticket_id, t.tier_id, auth.uid(), c.org_id, c.event_id, a ->> 'age_band', a ->> 'language',
          ARRAY(SELECT jsonb_array_elements_text(a -> 'tags')), a ->> 'mode', a ->> 'party_code', a ->> 'display_name')
  ON CONFLICT (ticket_id) DO UPDATE SET
     user_id = EXCLUDED.user_id, age_band = EXCLUDED.age_band, language = EXCLUDED.language, tags = EXCLUDED.tags,
     mode = EXCLUDED.mode, party_code = EXCLUDED.party_code, display_name = EXCLUDED.display_name;
  RETURN a;
END $$;
REVOKE ALL ON FUNCTION public.exos_match_set_answers(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_set_answers(uuid, jsonb) TO authenticated, service_role;

-- Delete my answers for this ticket (and my intake for its tier).
CREATE OR REPLACE FUNCTION public.exos_match_clear_answers(p_ticket_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_tier uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_match_clear_answers: sign in first' USING ERRCODE = '42501';
  END IF;
  SELECT tier_id INTO v_tier FROM public.exos_tickets WHERE id = p_ticket_id AND owner_id = auth.uid();
  IF v_tier IS NULL THEN
    RAISE EXCEPTION 'exos_match_clear_answers: not your ticket' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.exos_match_answers WHERE ticket_id = p_ticket_id;
  DELETE FROM public.exos_match_intake WHERE tier_id = v_tier AND user_id = auth.uid();
END $$;
REVOKE ALL ON FUNCTION public.exos_match_clear_answers(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_clear_answers(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Service: matching (exos-match edge function)
-- ---------------------------------------------------------------------------
-- Tiers whose cutoff has passed and that haven't been matched.
CREATE OR REPLACE FUNCTION public.exos_match_due()
RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT c.tier_id
    FROM public.exos_match_configs c JOIN public.exos_events e ON e.id = c.event_id
   WHERE c.status = 'open' AND e.status = 'published' AND e.starts_at IS NOT NULL
     AND now() >= e.starts_at - make_interval(hours => c.match_hours_before)
     AND now() < coalesce(e.ends_at, e.starts_at + interval '12 hours')
   ORDER BY e.starts_at
   LIMIT 50
$$;
REVOKE ALL ON FUNCTION public.exos_match_due() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_due() TO service_role;

-- Everything the matcher needs. p_actor: the verified user for "Match now"
-- (owner / manager checked here), NULL for the cron. Copies intake onto the
-- holders' tickets first.
CREATE OR REPLACE FUNCTION public.exos_match_inputs(p_tier_id uuid, p_actor uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c public.exos_match_configs%ROWTYPE;
BEGIN
  IF p_actor IS NOT NULL THEN
    c := public._exos_match_staff_cfg(p_tier_id, p_actor);
  ELSE
    SELECT * INTO c FROM public.exos_match_configs WHERE tier_id = p_tier_id;
  END IF;
  IF c.tier_id IS NULL THEN
    RAISE EXCEPTION 'exos_match_inputs: not a matched ticket type' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.exos_match_answers (ticket_id, tier_id, user_id, org_id, event_id, age_band, language, tags, mode, party_code, display_name)
  SELECT t.id, c.tier_id, i.user_id, c.org_id, c.event_id, i.age_band, i.language, i.tags, i.mode, i.party_code, i.display_name
    FROM public.exos_tickets t
    JOIN public.exos_match_intake i ON i.tier_id = c.tier_id AND i.user_id = t.owner_id
   WHERE t.tier_id = c.tier_id AND t.status = 'active'
     AND NOT EXISTS (SELECT 1 FROM public.exos_match_answers a WHERE a.ticket_id = t.id AND a.user_id = t.owner_id)
  ON CONFLICT (ticket_id) DO UPDATE SET
     user_id = EXCLUDED.user_id, age_band = EXCLUDED.age_band, language = EXCLUDED.language, tags = EXCLUDED.tags,
     mode = EXCLUDED.mode, party_code = EXCLUDED.party_code, display_name = EXCLUDED.display_name;

  RETURN jsonb_build_object(
    'tier_id', c.tier_id,
    'status', c.status,
    'settings', jsonb_build_object('min', c.group_min, 'target', c.group_target, 'max', c.group_max,
                                   'groupCount', c.group_count, 'policy', c.undersub_policy, 'seed', c.seed),
    'spots', coalesce((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'capacity', s.capacity) ORDER BY s.sort_order, s.id)
                         FROM public.exos_match_spots s WHERE s.tier_id = c.tier_id AND s.active), '[]'::jsonb),
    'members', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'ticketId', t.id,
               'userKey', public._exos_match_user_key(t.owner_id, t.buyer_email, t.id),
               'orderKey', coalesce(nullif(t.order_ref, ''), t.id::text),
               'partyCode', a.party_code, 'ageBand', a.age_band, 'language', a.language,
               'tags', coalesce(to_jsonb(a.tags), '[]'::jsonb)) ORDER BY t.id)
        FROM public.exos_tickets t
        LEFT JOIN public.exos_match_answers a ON a.ticket_id = t.id AND a.user_id = t.owner_id
       WHERE t.tier_id = c.tier_id AND t.status = 'active'), '[]'::jsonb),
    'blocks', coalesce((
      WITH k AS (SELECT DISTINCT public._exos_match_user_key(t.owner_id, t.buyer_email, t.id) AS key
                   FROM public.exos_tickets t WHERE t.tier_id = c.tier_id AND t.status = 'active')
      SELECT jsonb_agg(DISTINCT jsonb_build_array(b.a_key, b.b_key))
        FROM public.exos_match_blocks b
       WHERE (b.source = 'member' OR b.org_id = c.org_id)
         AND b.a_key IN (SELECT key FROM k) AND b.b_key IN (SELECT key FROM k)), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_match_inputs(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_inputs(uuid, uuid) TO service_role;

-- Store a matcher result after re-checking the hard rules. p_result:
--   { groups: [{ spotId, ticketIds: [uuid], score }], leftovers: [{ ticketId, reason }] }
-- Allowed while the tier is open, or matched with every group still a draft
-- (a re-run). Active tickets the result doesn't mention (sold after the
-- inputs were read) become leftovers with reason 'late'.
CREATE OR REPLACE FUNCTION public.exos_match_apply(p_tier_id uuid, p_actor uuid, p_seed bigint, p_result jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c      public.exos_match_configs%ROWTYPE;
  v_meet timestamptz;
  g      jsonb;
  v_gid  uuid;
  v_n    int := 0;
  v_i    int := 0;
  v_bad  text;
  v_left int;
BEGIN
  IF p_actor IS NOT NULL THEN
    PERFORM public._exos_match_staff_cfg(p_tier_id, p_actor);
  END IF;
  SELECT * INTO c FROM public.exos_match_configs WHERE tier_id = p_tier_id FOR UPDATE;
  IF c.tier_id IS NULL THEN
    RAISE EXCEPTION 'exos_match_apply: not a matched ticket type' USING ERRCODE = '22023';
  END IF;
  IF c.status = 'revealed' OR (c.status = 'matched' AND EXISTS (
       SELECT 1 FROM public.exos_social_groups x
        WHERE x.tier_id = p_tier_id AND x.kind = 'matched_seats' AND x.status IN ('locked', 'revealed'))) THEN
    RAISE EXCEPTION 'exos_match_apply: groups are locked or revealed; unlock them to re-run' USING ERRCODE = '55000';
  END IF;
  IF p_result IS NULL OR jsonb_typeof(p_result -> 'groups') <> 'array'
     OR jsonb_typeof(coalesce(p_result -> 'leftovers', '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'exos_match_apply: bad result' USING ERRCODE = '22023';
  END IF;

  -- Flatten the result.
  CREATE TEMP TABLE IF NOT EXISTS pg_temp._m (gi int, spot_id uuid, ticket_id uuid, score numeric) ON COMMIT DROP;
  TRUNCATE pg_temp._m;
  BEGIN
    INSERT INTO pg_temp._m
    SELECT gi::int, (gr ->> 'spotId')::uuid, tid::uuid, (gr ->> 'score')::numeric
      FROM jsonb_array_elements(p_result -> 'groups') WITH ORDINALITY AS x(gr, gi),
           jsonb_array_elements_text(gr -> 'ticketIds') AS tid;
    INSERT INTO pg_temp._m
    SELECT NULL, NULL, (l ->> 'ticketId')::uuid, NULL
      FROM jsonb_array_elements(coalesce(p_result -> 'leftovers', '[]'::jsonb)) l;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'exos_match_apply: bad ids in result' USING ERRCODE = '22023';
  END;

  -- Every ticket at most once, and each an active ticket of this tier.
  IF EXISTS (SELECT 1 FROM pg_temp._m GROUP BY ticket_id HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'exos_match_apply: a ticket appears twice' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_temp._m LEFT JOIN public.exos_tickets t ON t.id = pg_temp._m.ticket_id
              WHERE t.id IS NULL OR t.tier_id IS DISTINCT FROM p_tier_id OR t.status <> 'active') THEN
    RAISE EXCEPTION 'exos_match_apply: a ticket is not an active ticket of this type' USING ERRCODE = '22023';
  END IF;
  -- Spots belong to the tier and are on.
  IF EXISTS (SELECT 1 FROM pg_temp._m LEFT JOIN public.exos_match_spots s ON s.id = pg_temp._m.spot_id AND s.tier_id = p_tier_id AND s.active
              WHERE pg_temp._m.gi IS NOT NULL AND s.id IS NULL) THEN
    RAISE EXCEPTION 'exos_match_apply: unknown spot' USING ERRCODE = '22023';
  END IF;
  -- Size and capacity.
  IF EXISTS (SELECT 1 FROM pg_temp._m WHERE gi IS NOT NULL GROUP BY gi HAVING count(*) > c.group_max) THEN
    RAISE EXCEPTION 'exos_match_apply: a group is above the maximum (%)', c.group_max USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_temp._m JOIN public.exos_match_spots s ON s.id = pg_temp._m.spot_id
              GROUP BY s.id, s.capacity HAVING count(*) > s.capacity) THEN
    RAISE EXCEPTION 'exos_match_apply: a spot is over capacity' USING ERRCODE = '22023';
  END IF;
  -- One order is never split (placed vs left over counts as split too).
  SELECT t1.order_ref INTO v_bad
    FROM pg_temp._m m1 JOIN public.exos_tickets t1 ON t1.id = m1.ticket_id
    JOIN public.exos_tickets t2 ON t2.order_ref = t1.order_ref AND t2.tier_id = p_tier_id AND t2.status = 'active' AND t2.id <> t1.id
    LEFT JOIN pg_temp._m m2 ON m2.ticket_id = t2.id
   WHERE nullif(t1.order_ref, '') IS NOT NULL AND m2.ticket_id IS NOT NULL
     AND m1.gi IS DISTINCT FROM m2.gi
   LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'exos_match_apply: an order would be split' USING ERRCODE = '22023';
  END IF;
  -- No blocked pair together.
  IF EXISTS (
    SELECT 1 FROM pg_temp._m m1 JOIN pg_temp._m m2 ON m1.gi = m2.gi AND m1.ticket_id < m2.ticket_id
      JOIN public.exos_tickets t1 ON t1.id = m1.ticket_id
      JOIN public.exos_tickets t2 ON t2.id = m2.ticket_id
     WHERE public._exos_match_blocked(c.org_id,
             public._exos_match_user_key(t1.owner_id, t1.buyer_email, t1.id),
             public._exos_match_user_key(t2.owner_id, t2.buyer_email, t2.id))) THEN
    RAISE EXCEPTION 'exos_match_apply: a blocked pair would sit together' USING ERRCODE = '22023';
  END IF;

  -- Replace the previous draft (re-run) and write.
  DELETE FROM public.exos_social_groups WHERE tier_id = p_tier_id AND kind = 'matched_seats';
  DELETE FROM public.exos_match_leftovers WHERE tier_id = p_tier_id;
  SELECT e.starts_at INTO v_meet FROM public.exos_events e WHERE e.id = c.event_id;

  FOR g IN SELECT jsonb_build_object('gi', gi, 'spot', min(spot_id::text), 'score', max(score))
             FROM pg_temp._m WHERE gi IS NOT NULL GROUP BY gi ORDER BY gi LOOP
    v_i := v_i + 1;
    INSERT INTO public.exos_social_groups (org_id, event_id, kind, tier_id, spot_id, label, status, meet_at, score, seed, created_by)
    SELECT c.org_id, c.event_id, 'matched_seats', p_tier_id, s.id, 'Group ' || v_i, 'draft',
           coalesce(s.meet_at, v_meet), (g ->> 'score')::numeric, p_seed, p_actor
      FROM public.exos_match_spots s WHERE s.id = (g ->> 'spot')::uuid
    RETURNING id INTO v_gid;
    INSERT INTO public.exos_social_group_members (group_id, org_id, event_id, kind, ticket_id, user_id, display_name)
    SELECT v_gid, c.org_id, c.event_id, 'matched_seats', t.id, t.owner_id, a.display_name
      FROM pg_temp._m JOIN public.exos_tickets t ON t.id = pg_temp._m.ticket_id
      LEFT JOIN public.exos_match_answers a ON a.ticket_id = t.id AND a.user_id = t.owner_id
     WHERE pg_temp._m.gi = (g ->> 'gi')::int
     ORDER BY t.id;
    v_n := v_n + 1;
  END LOOP;

  INSERT INTO public.exos_match_leftovers (ticket_id, tier_id, org_id, event_id, reason)
  SELECT (l ->> 'ticketId')::uuid, p_tier_id, c.org_id, c.event_id,
         CASE WHEN l ->> 'reason' IN ('party_too_big', 'no_room', 'blocked', 'undersubscribed') THEN l ->> 'reason' ELSE 'no_room' END
    FROM jsonb_array_elements(coalesce(p_result -> 'leftovers', '[]'::jsonb)) l;
  INSERT INTO public.exos_match_leftovers (ticket_id, tier_id, org_id, event_id, reason)
  SELECT t.id, p_tier_id, c.org_id, c.event_id, 'late'
    FROM public.exos_tickets t
   WHERE t.tier_id = p_tier_id AND t.status = 'active'
     AND NOT EXISTS (SELECT 1 FROM pg_temp._m WHERE pg_temp._m.ticket_id = t.id)
  ON CONFLICT (ticket_id) DO NOTHING;
  SELECT count(*) INTO v_left FROM public.exos_match_leftovers WHERE tier_id = p_tier_id;

  UPDATE public.exos_match_configs
     SET status = 'matched', matched_at = now(), matched_by = p_actor, seed = p_seed
   WHERE tier_id = p_tier_id;
  RETURN jsonb_build_object('groups', v_n, 'placed', (SELECT count(*) FROM pg_temp._m WHERE gi IS NOT NULL), 'leftovers', v_left);
END $$;
REVOKE ALL ON FUNCTION public.exos_match_apply(uuid, uuid, bigint, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_apply(uuid, uuid, bigint, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Staff: review, swap, remove, lock, reveal, reports
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_match_staff_view(p_tier_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c public.exos_match_configs%ROWTYPE := public._exos_match_staff_cfg(p_tier_id);
  v_t record;
BEGIN
  SELECT * INTO v_t FROM public._exos_match_times(p_tier_id);
  RETURN jsonb_build_object(
    'config', to_jsonb(c) || jsonb_build_object('match_at', v_t.match_at, 'reveal_at', v_t.reveal_at),
    'holders', (SELECT count(*) FROM public.exos_tickets t WHERE t.tier_id = p_tier_id AND t.status = 'active'),
    'answered', (SELECT count(*) FROM public.exos_tickets t
                   WHERE t.tier_id = p_tier_id AND t.status = 'active'
                     AND (EXISTS (SELECT 1 FROM public.exos_match_answers a WHERE a.ticket_id = t.id AND a.user_id = t.owner_id)
                          OR EXISTS (SELECT 1 FROM public.exos_match_intake i WHERE i.tier_id = p_tier_id AND i.user_id = t.owner_id))),
    'spots', coalesce((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.sort_order, s.name)
                         FROM public.exos_match_spots s WHERE s.tier_id = p_tier_id), '[]'::jsonb),
    'groups', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', g.id, 'label', g.label, 'status', g.status, 'spot_id', g.spot_id, 'meet_at', g.meet_at,
               'score', g.score, 'revealed_at', g.revealed_at,
               'members', coalesce((
                 SELECT jsonb_agg(jsonb_build_object(
                          'id', m.id, 'ticket_id', m.ticket_id, 'status', m.status,
                          'first_name', public._exos_match_first_name(m.id),
                          'order_ref', t.order_ref, 'removed_reason', m.removed_reason,
                          'age_band', a.age_band, 'language', a.language, 'tags', a.tags,
                          'party_code', a.party_code) ORDER BY m.status, m.created_at, m.id)
                   FROM public.exos_social_group_members m
                   LEFT JOIN public.exos_tickets t ON t.id = m.ticket_id
                   LEFT JOIN public.exos_match_answers a ON a.ticket_id = m.ticket_id AND a.user_id = t.owner_id
                  WHERE m.group_id = g.id), '[]'::jsonb)) ORDER BY g.created_at, g.label)
        FROM public.exos_social_groups g
       WHERE g.tier_id = p_tier_id AND g.kind = 'matched_seats'), '[]'::jsonb),
    'leftovers', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'ticket_id', l.ticket_id, 'reason', l.reason, 'status', t.status,
               'price_paid', t.price_paid, 'order_ref', t.order_ref,
               'first_name', coalesce(nullif(split_part(btrim(coalesce(t.attendee_name, '')), ' ', 1), ''), 'Guest'),
               'session_id', (SELECT s.session_id FROM public.exos_checkout_sessions s
                               WHERE s.event_id = c.event_id AND l.ticket_id = ANY (s.ticket_ids) LIMIT 1))
               ORDER BY l.reason, l.ticket_id)
        FROM public.exos_match_leftovers l JOIN public.exos_tickets t ON t.id = l.ticket_id
       WHERE l.tier_id = p_tier_id), '[]'::jsonb),
    'reports', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', r.id, 'group_id', r.group_id, 'member_id', r.member_id, 'reason', r.reason,
               'details', r.details, 'status', r.status, 'created_at', r.created_at,
               'member_first_name', CASE WHEN r.member_id IS NULL THEN NULL ELSE public._exos_match_first_name(r.member_id) END)
               ORDER BY r.created_at DESC)
        FROM public.exos_match_reports r
        JOIN public.exos_social_groups g ON g.id = r.group_id
       WHERE g.tier_id = p_tier_id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_match_staff_view(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_staff_view(uuid) TO authenticated, service_role;

-- Internal: may this member join that group? (size, spot capacity, blocks)
CREATE OR REPLACE FUNCTION public._exos_match_can_join(p_member uuid, p_group uuid, p_ignore uuid DEFAULT NULL)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  g  record;
  c  public.exos_match_configs%ROWTYPE;
  mk text;
BEGIN
  SELECT x.id, x.tier_id, x.spot_id, x.status, x.org_id INTO g FROM public.exos_social_groups x WHERE x.id = p_group;
  SELECT * INTO c FROM public.exos_match_configs WHERE tier_id = g.tier_id;
  IF (SELECT count(*) FROM public.exos_social_group_members m
       WHERE m.group_id = p_group AND m.status = 'active' AND m.id IS DISTINCT FROM p_ignore) + 1 > c.group_max THEN
    RETURN 'that group is full (max ' || c.group_max || ')';
  END IF;
  IF (SELECT count(*) FROM public.exos_social_group_members m JOIN public.exos_social_groups x ON x.id = m.group_id
       WHERE x.spot_id = g.spot_id AND x.status <> 'dissolved' AND m.status = 'active'
         AND m.id IS DISTINCT FROM p_ignore AND m.id <> p_member) + 1
     > (SELECT capacity FROM public.exos_match_spots WHERE id = g.spot_id) THEN
    RETURN 'that spot is full';
  END IF;
  SELECT public._exos_match_user_key(t.owner_id, t.buyer_email, t.id) INTO mk
    FROM public.exos_social_group_members m JOIN public.exos_tickets t ON t.id = m.ticket_id WHERE m.id = p_member;
  IF EXISTS (SELECT 1 FROM public.exos_social_group_members m JOIN public.exos_tickets t ON t.id = m.ticket_id
              WHERE m.group_id = p_group AND m.status = 'active' AND m.id <> p_member AND m.id IS DISTINCT FROM p_ignore
                AND public._exos_match_blocked(g.org_id, mk, public._exos_match_user_key(t.owner_id, t.buyer_email, t.id))) THEN
    RETURN 'a blocked pair would sit together';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_match_can_join(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_match_can_join(uuid, uuid, uuid) TO service_role;

-- Move one member (p_member_id) to another group of the same tier, or place a
-- leftover ticket (p_ticket_id) in a group. Before reveal only.
CREATE OR REPLACE FUNCTION public.exos_match_move(p_group_id uuid, p_member_id uuid DEFAULT NULL, p_ticket_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  g    record;
  m    record;
  v_err text;
  v_id uuid;
BEGIN
  SELECT x.id, x.tier_id, x.status INTO g FROM public.exos_social_groups x WHERE x.id = p_group_id AND x.kind = 'matched_seats';
  PERFORM public._exos_match_staff_cfg(g.tier_id);
  PERFORM 1 FROM public.exos_match_configs WHERE tier_id = g.tier_id FOR UPDATE;
  IF g.status NOT IN ('draft', 'locked') THEN
    RAISE EXCEPTION 'exos_match_move: that group is already revealed' USING ERRCODE = '55000';
  END IF;
  IF p_member_id IS NOT NULL THEN
    SELECT mm.id, mm.ticket_id, x.tier_id, x.status AS gstatus INTO m
      FROM public.exos_social_group_members mm JOIN public.exos_social_groups x ON x.id = mm.group_id
     WHERE mm.id = p_member_id AND mm.status = 'active';
    IF m.id IS NULL OR m.tier_id IS DISTINCT FROM g.tier_id OR m.gstatus NOT IN ('draft', 'locked') THEN
      RAISE EXCEPTION 'exos_match_move: no such member in an unrevealed group of this ticket type' USING ERRCODE = '22023';
    END IF;
    v_err := public._exos_match_can_join(p_member_id, p_group_id);
    IF v_err IS NOT NULL THEN
      RAISE EXCEPTION 'exos_match_move: %', v_err USING ERRCODE = '22023';
    END IF;
    UPDATE public.exos_social_group_members SET group_id = p_group_id WHERE id = p_member_id;
    RETURN p_member_id;
  END IF;
  -- Place a leftover.
  IF NOT EXISTS (SELECT 1 FROM public.exos_match_leftovers l JOIN public.exos_tickets t ON t.id = l.ticket_id
                  WHERE l.ticket_id = p_ticket_id AND l.tier_id = g.tier_id AND t.status = 'active') THEN
    RAISE EXCEPTION 'exos_match_move: that ticket is not waiting for a group' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.exos_social_group_members (group_id, org_id, event_id, kind, ticket_id, user_id, display_name, status)
  SELECT p_group_id, t.org_id, t.event_id, 'matched_seats', t.id, t.owner_id, a.display_name, 'left'
    FROM public.exos_tickets t LEFT JOIN public.exos_match_answers a ON a.ticket_id = t.id AND a.user_id = t.owner_id
   WHERE t.id = p_ticket_id
  ON CONFLICT (group_id, ticket_id) DO UPDATE SET status = 'left'
  RETURNING id INTO v_id;
  v_err := public._exos_match_can_join(v_id, p_group_id);
  IF v_err IS NOT NULL THEN
    RAISE EXCEPTION 'exos_match_move: %', v_err USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_social_group_members SET status = 'active', removed_reason = NULL, removed_by = NULL, removed_at = NULL
   WHERE id = v_id;
  DELETE FROM public.exos_match_leftovers WHERE ticket_id = p_ticket_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_match_move(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_move(uuid, uuid, uuid) TO authenticated, service_role;

-- Swap two members of different groups (same tier). Before reveal only.
CREATE OR REPLACE FUNCTION public.exos_match_swap(p_member_a uuid, p_member_b uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  a record;
  b record;
  v_err text;
BEGIN
  SELECT m.id, m.group_id, g.tier_id, g.status INTO a
    FROM public.exos_social_group_members m JOIN public.exos_social_groups g ON g.id = m.group_id
   WHERE m.id = p_member_a AND m.status = 'active' AND g.kind = 'matched_seats';
  SELECT m.id, m.group_id, g.tier_id, g.status INTO b
    FROM public.exos_social_group_members m JOIN public.exos_social_groups g ON g.id = m.group_id
   WHERE m.id = p_member_b AND m.status = 'active' AND g.kind = 'matched_seats';
  IF a.id IS NULL OR b.id IS NULL OR a.tier_id IS DISTINCT FROM b.tier_id THEN
    RAISE EXCEPTION 'exos_match_swap: pick two members of this ticket type' USING ERRCODE = '22023';
  END IF;
  PERFORM public._exos_match_staff_cfg(a.tier_id);
  PERFORM 1 FROM public.exos_match_configs WHERE tier_id = a.tier_id FOR UPDATE;
  IF a.status NOT IN ('draft', 'locked') OR b.status NOT IN ('draft', 'locked') THEN
    RAISE EXCEPTION 'exos_match_swap: a group is already revealed' USING ERRCODE = '55000';
  END IF;
  IF a.group_id = b.group_id THEN RETURN; END IF;
  v_err := coalesce(public._exos_match_can_join(p_member_a, b.group_id, p_member_b),
                    public._exos_match_can_join(p_member_b, a.group_id, p_member_a));
  IF v_err IS NOT NULL THEN
    RAISE EXCEPTION 'exos_match_swap: %', v_err USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_social_group_members SET group_id = CASE id WHEN p_member_a THEN b.group_id ELSE a.group_id END
   WHERE id IN (p_member_a, p_member_b);
END $$;
REVOKE ALL ON FUNCTION public.exos_match_swap(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_swap(uuid, uuid) TO authenticated, service_role;

-- Remove someone from a group (any time). p_block: they are also never grouped
-- with the others again (staff blocks, this org).
CREATE OR REPLACE FUNCTION public.exos_match_remove_member(p_member_id uuid, p_reason text DEFAULT NULL, p_block boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  m  record;
  mk text;
BEGIN
  SELECT x.id, x.group_id, x.ticket_id, g.tier_id, g.org_id INTO m
    FROM public.exos_social_group_members x JOIN public.exos_social_groups g ON g.id = x.group_id
   WHERE x.id = p_member_id AND g.kind = 'matched_seats';
  IF m.id IS NULL THEN
    RAISE EXCEPTION 'exos_match_remove_member: no such member' USING ERRCODE = '22023';
  END IF;
  PERFORM public._exos_match_staff_cfg(m.tier_id);
  UPDATE public.exos_social_group_members
     SET status = 'removed', removed_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300),
         removed_by = auth.uid(), removed_at = now()
   WHERE id = p_member_id AND status = 'active';
  IF p_block THEN
    SELECT public._exos_match_user_key(t.owner_id, t.buyer_email, t.id) INTO mk FROM public.exos_tickets t WHERE t.id = m.ticket_id;
    INSERT INTO public.exos_match_blocks (org_id, a_key, b_key, source, reason, created_by)
    SELECT DISTINCT m.org_id, mk, public._exos_match_user_key(t.owner_id, t.buyer_email, t.id), 'staff',
           left(nullif(btrim(coalesce(p_reason, '')), ''), 300), auth.uid()
      FROM public.exos_social_group_members o JOIN public.exos_tickets t ON t.id = o.ticket_id
     WHERE o.group_id = m.group_id AND o.id <> p_member_id
       AND public._exos_match_user_key(t.owner_id, t.buyer_email, t.id) <> mk
    ON CONFLICT DO NOTHING;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.exos_match_remove_member(uuid, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_remove_member(uuid, text, boolean) TO authenticated, service_role;

-- Lock (reviewed: a re-run can't overwrite) or unlock the drafts.
CREATE OR REPLACE FUNCTION public.exos_match_lock(p_tier_id uuid, p_locked boolean DEFAULT true)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n int;
BEGIN
  PERFORM public._exos_match_staff_cfg(p_tier_id);
  PERFORM 1 FROM public.exos_match_configs WHERE tier_id = p_tier_id FOR UPDATE;
  UPDATE public.exos_social_groups SET status = CASE WHEN p_locked THEN 'locked' ELSE 'draft' END
   WHERE tier_id = p_tier_id AND kind = 'matched_seats'
     AND status = CASE WHEN p_locked THEN 'draft' ELSE 'locked' END;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_match_lock(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_lock(uuid, boolean) TO authenticated, service_role;

-- Internal reveal: groups -> revealed; each active member who still holds the
-- ticket gets one email and, if they opted in to the org's texts, one SMS.
-- Idempotent (notified_at).
CREATE OR REPLACE FUNCTION public._exos_match_reveal(p_tier_id uuid)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c        public.exos_match_configs%ROWTYPE;
  v_ev     record;
  v_org    text;
  v_tz     text;
  v_prov   text;
  v_camp   uuid;
  r        record;
  v_when   text;
  v_names  text;
  v_n      int := 0;
  v_phone  text;
  v_body   text;
BEGIN
  SELECT * INTO c FROM public.exos_match_configs WHERE tier_id = p_tier_id FOR UPDATE;
  IF c.tier_id IS NULL OR c.status = 'open' THEN RETURN 0; END IF;
  SELECT e.id, e.name, e.timezone, e.status INTO v_ev FROM public.exos_events e WHERE e.id = c.event_id;
  IF v_ev.status = 'cancelled' THEN RETURN 0; END IF;
  SELECT name INTO v_org FROM public.exos_orgs WHERE id = c.org_id;
  v_tz := coalesce(nullif(v_ev.timezone, ''), 'UTC');
  BEGIN
    PERFORM now() AT TIME ZONE v_tz;
  EXCEPTION WHEN OTHERS THEN v_tz := 'UTC';
  END;

  UPDATE public.exos_social_groups SET status = 'revealed', revealed_at = now()
   WHERE tier_id = p_tier_id AND kind = 'matched_seats' AND status IN ('draft', 'locked');
  UPDATE public.exos_match_configs SET status = 'revealed', revealed_at = coalesce(revealed_at, now())
   WHERE tier_id = p_tier_id;

  IF to_regclass('public.exos_org_integrations') IS NOT NULL THEN
    EXECUTE $q$SELECT i.provider FROM public.exos_org_integrations i
                WHERE i.org_id = $1 AND i.provider IN ('twilio', 'telnyx') AND i.status = 'connected'
                ORDER BY (i.provider = 'twilio') DESC LIMIT 1$q$ INTO v_prov USING c.org_id;
  END IF;

  FOR r IN
    SELECT m.id AS member_id, m.group_id, t.owner_id, t.buyer_email, u.email AS owner_email,
           g.meet_at, s.name AS spot_name, s.address, s.details
      FROM public.exos_social_group_members m
      JOIN public.exos_social_groups g ON g.id = m.group_id
      JOIN public.exos_tickets t ON t.id = m.ticket_id
      LEFT JOIN auth.users u ON u.id = t.owner_id
      LEFT JOIN public.exos_match_spots s ON s.id = g.spot_id
     WHERE g.tier_id = p_tier_id AND g.kind = 'matched_seats' AND g.status = 'revealed'
       AND m.status = 'active' AND m.notified_at IS NULL AND t.status IN ('active', 'used')
     ORDER BY m.group_id, m.id
  LOOP
    v_when := to_char(r.meet_at AT TIME ZONE v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');
    SELECT string_agg(public._exos_match_first_name(o.id), ', ' ORDER BY o.created_at, o.id) INTO v_names
      FROM public.exos_social_group_members o
     WHERE o.group_id = r.group_id AND o.status = 'active' AND o.id <> r.member_id;

    IF coalesce(r.owner_email, r.buyer_email) IS NOT NULL THEN
      INSERT INTO public.exos_mail (template, to_email, subject, html, status)
      VALUES ('matched-reveal', lower(coalesce(r.owner_email, r.buyer_email)),
              left('Your group for ' || public._exos_match_esc(v_ev.name) || ': ' || public._exos_match_esc(r.spot_name), 200),
              '<p>Here is where your group meets for <strong>' || public._exos_match_esc(v_ev.name) || '</strong>.</p>' ||
              '<p><strong>' || public._exos_match_esc(r.spot_name) || '</strong>' ||
              CASE WHEN r.address IS NOT NULL THEN '<br>' || public._exos_match_esc(r.address) ELSE '' END ||
              '<br>' || public._exos_match_esc(v_when) || ' (' || public._exos_match_esc(v_tz) || ')</p>' ||
              CASE WHEN r.details IS NOT NULL THEN '<p>' || public._exos_match_esc(r.details) || '</p>' ELSE '' END ||
              CASE WHEN v_names IS NOT NULL THEN '<p>You''re with: ' || public._exos_match_esc(v_names) || '</p>' ELSE '' END ||
              '<p><a href="{{app_url}}/my-tickets">Your ticket</a> has the details too.</p>',
              'pending');
    END IF;

    IF v_prov IS NOT NULL AND r.owner_id IS NOT NULL THEN
      SELECT s.phone INTO v_phone FROM public.exos_sms_subscribers s
       WHERE s.org_id = c.org_id AND s.user_id = r.owner_id AND s.opted_out_at IS NULL
       ORDER BY s.consented_at DESC LIMIT 1;
      IF v_phone IS NOT NULL THEN
        IF v_camp IS NULL THEN
          INSERT INTO public.exos_sms_campaigns (org_id, event_id, audience, body, provider, status, send_after)
          VALUES (c.org_id, c.event_id, 'event_buyers',
                  left(coalesce(v_org, 'Exos') || ': matched-seat reveal for ' || coalesce(v_ev.name, 'your event'), 480),
                  v_prov, 'queued', now())
          RETURNING id INTO v_camp;
        END IF;
        v_body := left(left(coalesce(v_org, 'Exos'), 40) || ': your group for ' || left(coalesce(v_ev.name, 'the event'), 60) ||
                       ' meets at ' || left(coalesce(r.spot_name, ''), 80) ||
                       CASE WHEN r.address IS NOT NULL THEN ', ' || left(r.address, 120) ELSE '' END ||
                       ', ' || v_when || '.' ||
                       CASE WHEN v_names IS NOT NULL THEN ' With ' || left(v_names, 120) || '.' ELSE '' END, 440)
                  || ' Reply STOP to opt out.';
        INSERT INTO public.exos_sms_outbox (campaign_id, org_id, phone, body, send_after)
        VALUES (v_camp, c.org_id, v_phone, v_body, now())
        ON CONFLICT DO NOTHING;
      END IF;
      v_phone := NULL;
    END IF;

    UPDATE public.exos_social_group_members SET notified_at = now() WHERE id = r.member_id;
    v_n := v_n + 1;
  END LOOP;
  IF v_camp IS NOT NULL THEN
    UPDATE public.exos_sms_campaigns SET queued_count = (SELECT count(*) FROM public.exos_sms_outbox WHERE campaign_id = v_camp)
     WHERE id = v_camp;
  END IF;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_match_reveal(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_match_reveal(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_match_reveal_now(p_tier_id uuid)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_match_configs%ROWTYPE := public._exos_match_staff_cfg(p_tier_id);
BEGIN
  IF c.status = 'open' THEN
    RAISE EXCEPTION 'exos_match_reveal_now: match the groups first' USING ERRCODE = '55000';
  END IF;
  RETURN public._exos_match_reveal(p_tier_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_match_reveal_now(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_reveal_now(uuid) TO authenticated, service_role;

-- Cron: reveal every matched tier whose reveal time has come (and members
-- placed after an earlier reveal).
CREATE OR REPLACE FUNCTION public.exos_match_reveal_due()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record; v_n int := 0;
BEGIN
  FOR r IN SELECT c.tier_id FROM public.exos_match_configs c JOIN public.exos_events e ON e.id = c.event_id
            WHERE c.status IN ('matched', 'revealed') AND e.starts_at IS NOT NULL AND e.status = 'published'
              AND now() >= e.starts_at - make_interval(hours => c.reveal_hours_before)
              AND now() < coalesce(e.ends_at, e.starts_at + interval '12 hours')
              AND (c.status = 'matched' OR EXISTS (
                    SELECT 1 FROM public.exos_social_group_members m JOIN public.exos_social_groups g ON g.id = m.group_id
                     WHERE g.tier_id = c.tier_id AND g.kind = 'matched_seats' AND m.status = 'active' AND m.notified_at IS NULL))
            LIMIT 50 LOOP
    v_n := v_n + public._exos_match_reveal(r.tier_id);
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_match_reveal_due() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_reveal_due() TO service_role;

CREATE OR REPLACE FUNCTION public.exos_match_review_report(p_report_id uuid, p_status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_tier uuid;
BEGIN
  IF p_status NOT IN ('reviewed', 'actioned', 'dismissed', 'open') THEN
    RAISE EXCEPTION 'exos_match_review_report: bad status' USING ERRCODE = '22023';
  END IF;
  SELECT g.tier_id INTO v_tier FROM public.exos_match_reports r JOIN public.exos_social_groups g ON g.id = r.group_id
   WHERE r.id = p_report_id;
  PERFORM public._exos_match_staff_cfg(v_tier);
  UPDATE public.exos_match_reports SET status = p_status, reviewed_by = auth.uid(), reviewed_at = now()
   WHERE id = p_report_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_match_review_report(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_review_report(uuid, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. Holders: my group, would-meet-again, report, block
-- ---------------------------------------------------------------------------
-- Internal: the caller's active membership for a ticket they hold.
CREATE OR REPLACE FUNCTION public._exos_match_my_member(p_ticket_id uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT m.id FROM public.exos_social_group_members m
    JOIN public.exos_tickets t ON t.id = m.ticket_id
   WHERE m.ticket_id = p_ticket_id AND m.kind = 'matched_seats' AND m.status = 'active'
     AND t.owner_id = auth.uid() AND auth.uid() IS NOT NULL AND t.status IN ('active', 'used')
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._exos_match_my_member(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._exos_match_my_member(uuid) TO service_role;

-- state: not_matched (no matched config) | not_holder | waiting (before
-- matching) | leftover | removed | matched (grouped, not revealed yet) | revealed
CREATE OR REPLACE FUNCTION public.exos_match_my_group(p_ticket_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  t      record;
  c      public.exos_match_configs%ROWTYPE;
  v_t    record;
  v_me   uuid;
  g      record;
  v_left text;
  v_ans  jsonb;
  v_ev   record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_match_my_group: sign in first' USING ERRCODE = '42501';
  END IF;
  SELECT id, tier_id, owner_id, status, event_id INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF t.id IS NULL OR t.owner_id IS DISTINCT FROM auth.uid() OR t.status NOT IN ('active', 'used') THEN
    RETURN jsonb_build_object('state', 'not_holder');
  END IF;
  SELECT * INTO c FROM public.exos_match_configs WHERE tier_id = t.tier_id;
  IF c.tier_id IS NULL THEN
    RETURN jsonb_build_object('state', 'not_matched');
  END IF;
  SELECT * INTO v_t FROM public._exos_match_times(c.tier_id);
  SELECT e.starts_at, e.ends_at INTO v_ev FROM public.exos_events e WHERE e.id = c.event_id;
  SELECT to_jsonb(x) - 'ticket_id' - 'tier_id' - 'user_id' - 'org_id' - 'event_id' INTO v_ans
    FROM (SELECT a.* FROM public.exos_match_answers a WHERE a.ticket_id = p_ticket_id AND a.user_id = auth.uid()
          UNION ALL
          SELECT NULL, i.tier_id, i.user_id, i.org_id, i.event_id, i.age_band, i.language, i.tags, i.mode,
                 i.party_code, i.display_name, i.created_at, i.updated_at
            FROM public.exos_match_intake i WHERE i.tier_id = c.tier_id AND i.user_id = auth.uid()
          LIMIT 1) x;
  IF c.status = 'open' THEN
    RETURN jsonb_build_object('state', 'waiting', 'match_at', v_t.match_at, 'reveal_at', v_t.reveal_at,
      'quiz_enabled', c.quiz_enabled, 'quiz_tags', c.quiz_tags, 'quiz_languages', c.quiz_languages,
      'answers', v_ans);
  END IF;
  SELECT reason INTO v_left FROM public.exos_match_leftovers WHERE ticket_id = p_ticket_id;
  IF v_left IS NOT NULL THEN
    RETURN jsonb_build_object('state', 'leftover', 'reason', v_left, 'policy', c.undersub_policy);
  END IF;
  v_me := public._exos_match_my_member(p_ticket_id);
  IF v_me IS NULL THEN
    IF EXISTS (SELECT 1 FROM public.exos_social_group_members m WHERE m.ticket_id = p_ticket_id
                AND m.kind = 'matched_seats' AND m.status = 'removed') THEN
      RETURN jsonb_build_object('state', 'removed');
    END IF;
    RETURN jsonb_build_object('state', 'leftover', 'reason', 'no_room', 'policy', c.undersub_policy);
  END IF;
  SELECT x.id, x.status, x.meet_at, x.label, x.spot_id INTO g
    FROM public.exos_social_groups x JOIN public.exos_social_group_members m ON m.group_id = x.id WHERE m.id = v_me;
  IF g.status <> 'revealed' THEN
    RETURN jsonb_build_object('state', 'matched', 'reveal_at', v_t.reveal_at,
      'group_size', (SELECT count(*) FROM public.exos_social_group_members m WHERE m.group_id = g.id AND m.status = 'active'));
  END IF;
  RETURN jsonb_build_object(
    'state', 'revealed',
    'group_id', g.id,
    'me', v_me,
    'meet_at', g.meet_at,
    'spot', (SELECT jsonb_build_object('name', s.name, 'address', s.address, 'details', s.details)
               FROM public.exos_match_spots s WHERE s.id = g.spot_id),
    'after_event', now() >= coalesce(g.meet_at, v_ev.starts_at),
    'members', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', m.id, 'first_name', public._exos_match_first_name(m.id), 'is_me', m.id = v_me,
               'picked', EXISTS (SELECT 1 FROM public.exos_match_picks p WHERE p.from_member = v_me AND p.to_member = m.id),
               'mutual', EXISTS (SELECT 1 FROM public.exos_match_picks p WHERE p.from_member = v_me AND p.to_member = m.id)
                     AND EXISTS (SELECT 1 FROM public.exos_match_picks p WHERE p.from_member = m.id AND p.to_member = v_me))
               ORDER BY m.created_at, m.id)
        FROM public.exos_social_group_members m WHERE m.group_id = g.id AND m.status = 'active'), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_match_my_group(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_my_group(uuid) TO authenticated, service_role;

-- "Would meet again" (on / off) for another member of my revealed group,
-- from the meeting time until 30 days after. Only mutual picks are ever shown.
CREATE OR REPLACE FUNCTION public.exos_match_pick(p_ticket_id uuid, p_member_id uuid, p_on boolean DEFAULT true)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me uuid := public._exos_match_my_member(p_ticket_id);
  g    record;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'exos_match_pick: not your group' USING ERRCODE = '42501';
  END IF;
  SELECT x.id, x.status, x.meet_at, x.org_id, x.event_id INTO g
    FROM public.exos_social_groups x JOIN public.exos_social_group_members m ON m.group_id = x.id WHERE m.id = v_me;
  IF g.status <> 'revealed' OR now() < g.meet_at OR now() > g.meet_at + interval '30 days' THEN
    RAISE EXCEPTION 'exos_match_pick: picks open once you have met, for 30 days' USING ERRCODE = '55000';
  END IF;
  IF p_member_id = v_me OR NOT EXISTS (SELECT 1 FROM public.exos_social_group_members m
                                         WHERE m.id = p_member_id AND m.group_id = g.id AND m.status = 'active') THEN
    RAISE EXCEPTION 'exos_match_pick: pick someone else in your group' USING ERRCODE = '22023';
  END IF;
  IF p_on THEN
    INSERT INTO public.exos_match_picks (group_id, from_member, to_member, org_id, event_id)
    VALUES (g.id, v_me, p_member_id, g.org_id, g.event_id) ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.exos_match_picks WHERE from_member = v_me AND to_member = p_member_id;
  END IF;
  RETURN EXISTS (SELECT 1 FROM public.exos_match_picks WHERE from_member = v_me AND to_member = p_member_id)
     AND EXISTS (SELECT 1 FROM public.exos_match_picks WHERE from_member = p_member_id AND to_member = v_me);
END $$;
REVOKE ALL ON FUNCTION public.exos_match_pick(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_pick(uuid, uuid, boolean) TO authenticated, service_role;

-- Report a member of my group to the organizer. 10 a day per account.
CREATE OR REPLACE FUNCTION public.exos_match_report(p_ticket_id uuid, p_member_id uuid, p_reason text, p_details text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me uuid;
  g    record;
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_match_report: sign in first' USING ERRCODE = '42501';
  END IF;
  -- A removed member can still report (someone may have had them removed).
  SELECT m.id INTO v_me FROM public.exos_social_group_members m JOIN public.exos_tickets t ON t.id = m.ticket_id
   WHERE m.ticket_id = p_ticket_id AND m.kind = 'matched_seats' AND t.owner_id = auth.uid()
   ORDER BY (m.status = 'active') DESC LIMIT 1;
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'exos_match_report: not your group' USING ERRCODE = '42501';
  END IF;
  SELECT x.id, x.org_id, x.event_id, x.status INTO g
    FROM public.exos_social_groups x JOIN public.exos_social_group_members m ON m.group_id = x.id WHERE m.id = v_me;
  IF g.status <> 'revealed' THEN
    RAISE EXCEPTION 'exos_match_report: your group is not revealed yet' USING ERRCODE = '55000';
  END IF;
  IF p_member_id = v_me OR NOT EXISTS (SELECT 1 FROM public.exos_social_group_members m
                                         WHERE m.id = p_member_id AND m.group_id = g.id) THEN
    RAISE EXCEPTION 'exos_match_report: pick someone in your group' USING ERRCODE = '22023';
  END IF;
  IF p_reason NOT IN ('safety', 'harassment', 'inappropriate', 'no_show', 'other') THEN
    RAISE EXCEPTION 'exos_match_report: pick a reason' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_match_reports r
       WHERE r.reporter_id = auth.uid() AND r.created_at > now() - interval '1 day') >= 10 THEN
    RAISE EXCEPTION 'exos_match_report: too many reports today' USING ERRCODE = '54000';
  END IF;
  INSERT INTO public.exos_match_reports (org_id, event_id, group_id, reporter_id, member_id, reason, details)
  VALUES (g.org_id, g.event_id, g.id, auth.uid(), p_member_id, p_reason, left(nullif(btrim(coalesce(p_details, '')), ''), 1000))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_match_report(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_report(uuid, uuid, text, text) TO authenticated, service_role;

-- Block a member of my group: never grouped with them again (any organizer).
CREATE OR REPLACE FUNCTION public.exos_match_block(p_ticket_id uuid, p_member_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me  uuid;
  v_grp uuid;
  v_org uuid;
  v_key text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_match_block: sign in first' USING ERRCODE = '42501';
  END IF;
  SELECT m.id, m.group_id, m.org_id INTO v_me, v_grp, v_org
    FROM public.exos_social_group_members m JOIN public.exos_tickets t ON t.id = m.ticket_id
   WHERE m.ticket_id = p_ticket_id AND m.kind = 'matched_seats' AND t.owner_id = auth.uid()
   ORDER BY (m.status = 'active') DESC LIMIT 1;
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'exos_match_block: not your group' USING ERRCODE = '42501';
  END IF;
  SELECT public._exos_match_user_key(t.owner_id, t.buyer_email, t.id) INTO v_key
    FROM public.exos_social_group_members m JOIN public.exos_tickets t ON t.id = m.ticket_id
   WHERE m.id = p_member_id AND m.group_id = v_grp AND m.id <> v_me;
  IF v_key IS NULL THEN
    RAISE EXCEPTION 'exos_match_block: pick someone in your group' USING ERRCODE = '22023';
  END IF;
  IF v_key = auth.uid()::text THEN RETURN; END IF;    -- my own second ticket
  INSERT INTO public.exos_match_blocks (org_id, a_key, b_key, source, created_by)
  VALUES (v_org, auth.uid()::text, v_key, 'member', auth.uid())
  ON CONFLICT DO NOTHING;
  -- A block also withdraws my "would meet again" pick for them.
  DELETE FROM public.exos_match_picks WHERE from_member = v_me AND to_member = p_member_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_match_block(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_block(uuid, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10. Retention sweep: delete quiz answers retention_days after the event.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_match_sweep()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record; v_n int := 0; v_k int;
BEGIN
  FOR r IN SELECT c.tier_id FROM public.exos_match_configs c JOIN public.exos_events e ON e.id = c.event_id
            WHERE coalesce(e.ends_at, e.starts_at) IS NOT NULL
              AND now() > coalesce(e.ends_at, e.starts_at) + make_interval(days => c.retention_days)
              AND (c.swept_at IS NULL
                   OR EXISTS (SELECT 1 FROM public.exos_match_answers a WHERE a.tier_id = c.tier_id)
                   OR EXISTS (SELECT 1 FROM public.exos_match_intake i WHERE i.tier_id = c.tier_id))
            LIMIT 200 LOOP
    DELETE FROM public.exos_match_answers WHERE tier_id = r.tier_id;
    GET DIAGNOSTICS v_k = ROW_COUNT; v_n := v_n + v_k;
    DELETE FROM public.exos_match_intake WHERE tier_id = r.tier_id;
    GET DIAGNOSTICS v_k = ROW_COUNT; v_n := v_n + v_k;
    UPDATE public.exos_match_configs SET swept_at = now() WHERE tier_id = r.tier_id;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_match_sweep() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_match_sweep() TO service_role;

-- ---------------------------------------------------------------------------
-- 11. Cron: exos-match every 5 minutes, created INACTIVE (operator turns it on).
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_job bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-match-5min') THEN
      RAISE NOTICE 'exos-match-5min: already scheduled, left as is';
      RETURN;
    END IF;
    v_job := cron.schedule('exos-match-5min', '*/5 * * * *', $cron$
      SELECT public._cron_invoke_edge_fn(
        coalesce(nullif(current_setting('app.exos_functions_url', true), ''),
                 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1') || '/exos-match/cron', '{}'::jsonb);
    $cron$);
    PERFORM cron.alter_job(v_job, active := false);
  END IF;
END $$;

-- ROLLBACK (manual): unschedule exos-match-5min; drop the exos_match_* and
-- _exos_match_* functions, exos_tg_social_member_fill, and the tables
-- exos_match_picks, exos_match_reports, exos_match_blocks, exos_match_leftovers,
-- exos_social_group_members, exos_social_groups, exos_match_answers,
-- exos_match_intake, exos_match_spots, exos_match_configs (in that order).
-- The 'matched-reveal' mail template can stay in the allowlist.
