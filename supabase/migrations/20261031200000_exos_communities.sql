-- ============================================================================
-- Migration 20261031200000 — Exos: communities (the "third place" layer) and
--                            ActivityPub federation for them
--
-- Touches:  C: TABLE exos_communities, exos_community_hosts,
--              exos_community_members, exos_community_invites,
--              exos_community_events, exos_community_posts,
--              exos_community_reports, exos_ap_actors, exos_ap_followers,
--              exos_ap_blocks, exos_ap_remote_replies, exos_ap_deliveries,
--              exos_ap_remote_actors
--           C: FUNCTION exos_community_* (organizer, host and member RPCs),
--              exos_public_community, exos_public_communities,
--              exos_public_event_communities, exos_community_invite_preview
--              (anon), exos_community_checkout_gate (service role),
--              exos_ap_* (service role: the exos-activitypub edge function),
--              triggers exos_tg_ticket_community_gate (exos_tickets),
--              exos_tg_event_published_community (exos_events)
--           W: exos_mail template allowlist (+community-post,
--              +community-event), exos_sms_campaigns (+community_id,
--              audience +'community')
--           R: exos_orgs, exos_events, exos_org_memberships, auth.users,
--              exos_sms_subscribers, exos_org_integrations, vault.*;
--              exos_fan_memberships / _exos_member_best when present
--              (memberships, dynamic SQL)
--           C: cron.schedule 'exos-ap-deliver-1min', created INACTIVE
-- Pre-reqs: 20261016120000 (SMS), 20260929071000 (exos_mail_enqueue),
--           20260929060000 (exos_rate_hit), Vault (prereq_vault.sql locally)
--
-- A community belongs to an org. Its owner / manager run it; "hosts" are
-- invited people (often from another org: the run club that meets at the
-- bar) who can only add events and write posts in that one community.
--
-- Members join with consent: open, by approval, or by invite only. They pick
-- the channels they hear on (email, and texts only when they already opted in
-- to the org's texts through exos_sms_opt_in, so STOP keeps working). Every
-- new event in a community is announced to members through those channels;
-- posts can be. Mail goes through exos_mail_enqueue as a marketing mail
-- (unsubscribe link, account-level opt-out honoured); texts go through the
-- SMS outbox (quiet hours, 8 a month cap, STOP skip at claim time).
--
-- Rate limits (all server-side): 30 joins a day per account; 10 posts a day per
-- author per community and 50 per community; posts that notify members: 3 a
-- day and 10 a week per community; event announcements: 5 a day per
-- community; 10 reports a day per account; 100 invites a day per community.
--
-- Members-only events and early access: exos_community_events.members_only /
-- early_access_until. Access rule 'community' (members), 'membership' (holders
-- of the listed membership products, from the memberships migration; fails
-- closed when that migration isn't applied), or 'either'. Enforced before
-- payment in exos-checkout (exos_community_checkout_gate) and on every
-- signed-in ticket insert (trigger), with the org's door staff exempt.
--
-- Federation (docs/federation.md): each public community with
-- federation_enabled is an ActivityPub Group; the community's org is a Person
-- that posts are attributed to. Actor keys: RSA 2048, the private half only in
-- Vault ('exos_ap_key:<actor id>'), handed to the service role only. Deliveries
-- go through exos_ap_deliveries (lease, backoff, dead after 8 attempts). The
-- whole thing is inert unless the edge function has EXOS_FEDERATION=on; the
-- delivery cron is created inactive.
--
-- Re-run safe. Prod apply needs operator OK.
-- ROLLBACK (manual): unschedule 'exos-ap-deliver-1min'; DROP TRIGGER
--   exos_tickets_community_gate ON exos_tickets, exos_events_community_publish
--   ON exos_events; drop the functions and the thirteen tables; DELETE FROM
--   vault.secrets WHERE name LIKE 'exos_ap_key:%'; ALTER TABLE
--   exos_sms_campaigns DROP COLUMN community_id (audience list may stay).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Communities
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_communities (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  slug               text NOT NULL UNIQUE
                       CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{1,38}[a-z0-9]$' AND slug !~ '^org[_-]'
                              AND slug NOT IN ('new', 'admin', 'api', 'ap', 'inbox', 'settings', 'directory', 'communities', 'www', 'exos')),
  -- The ActivityPub name (WebFinger acct:<ap_name>@host): Lemmy community
  -- names are [a-z0-9_]. Unique, so "run-club" and "run_club" can't both exist.
  ap_name            text GENERATED ALWAYS AS (replace(slug, '-', '_')) STORED UNIQUE,
  name               text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
  tagline            text CHECK (tagline IS NULL OR char_length(tagline) <= 140),
  about              text CHECK (about IS NULL OR char_length(about) <= 5000),
  banner_url         text CHECK (banner_url IS NULL OR (banner_url ~ '^https://[^[:space:]"<>]+$' AND char_length(banner_url) <= 500)),
  city               text CHECK (city IS NULL OR char_length(city) <= 80),
  city_key           text GENERATED ALWAYS AS (nullif(lower(btrim(coalesce(city, ''))), '')) STORED,
  region             text CHECK (region IS NULL OR char_length(region) <= 80),
  country            text CHECK (country IS NULL OR country ~ '^[A-Z]{2}$'),
  join_mode          text NOT NULL DEFAULT 'open' CHECK (join_mode IN ('open', 'approval', 'invite')),
  visibility         text NOT NULL DEFAULT 'public' CHECK (visibility IN ('public', 'unlisted')),
  federation_enabled boolean NOT NULL DEFAULT false,
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  created_by         uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_communities_org_idx ON public.exos_communities (org_id);
CREATE INDEX IF NOT EXISTS exos_communities_city_idx ON public.exos_communities (city_key) WHERE status = 'active' AND visibility = 'public';

CREATE TABLE IF NOT EXISTS public.exos_community_hosts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id  uuid NOT NULL REFERENCES public.exos_communities (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  user_id       uuid REFERENCES auth.users (id) ON DELETE CASCADE,
  email         text NOT NULL CHECK (email = lower(email) AND char_length(email) <= 320),
  host_org_id   uuid REFERENCES public.exos_orgs (id) ON DELETE SET NULL,  -- the org they represent, if any
  display_name  text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 80),
  status        text NOT NULL DEFAULT 'invited' CHECK (status IN ('invited', 'active', 'revoked')),
  token_hash    text UNIQUE CHECK (token_hash IS NULL OR token_hash ~ '^[0-9a-f]{64}$'),
  invited_by    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  expires_at    timestamptz NOT NULL DEFAULT now() + interval '14 days',
  accepted_at   timestamptz,
  revoked_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_community_hosts_user_uq ON public.exos_community_hosts (community_id, user_id) WHERE user_id IS NOT NULL AND status <> 'revoked';
CREATE INDEX IF NOT EXISTS exos_community_hosts_comm_idx ON public.exos_community_hosts (community_id, status);
CREATE INDEX IF NOT EXISTS exos_community_hosts_user_idx ON public.exos_community_hosts (user_id) WHERE user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_community_members (
  community_id  uuid NOT NULL REFERENCES public.exos_communities (id) ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  status        text NOT NULL CHECK (status IN ('pending', 'active', 'banned', 'removed', 'left', 'declined')),
  notify_email  boolean NOT NULL DEFAULT false,
  notify_sms    boolean NOT NULL DEFAULT false,
  consent_text  text CHECK (consent_text IS NULL OR char_length(consent_text) <= 600),
  consented_at  timestamptz,
  requested_at  timestamptz NOT NULL DEFAULT now(),
  joined_at     timestamptz,
  decided_by    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  ban_reason    text CHECK (ban_reason IS NULL OR char_length(ban_reason) <= 300),
  banned_at     timestamptz,
  invite_id     uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (community_id, user_id)
);
CREATE INDEX IF NOT EXISTS exos_community_members_user_idx ON public.exos_community_members (user_id);
CREATE INDEX IF NOT EXISTS exos_community_members_active_idx ON public.exos_community_members (community_id) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS public.exos_community_invites (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id  uuid NOT NULL REFERENCES public.exos_communities (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  email         text CHECK (email IS NULL OR (email = lower(email) AND char_length(email) <= 320)),
  token_hash    text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  max_uses      integer NOT NULL DEFAULT 1 CHECK (max_uses BETWEEN 1 AND 500),
  uses          integer NOT NULL DEFAULT 0 CHECK (uses >= 0),
  created_by    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  expires_at    timestamptz NOT NULL DEFAULT now() + interval '30 days',
  revoked_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_community_invites_comm_idx ON public.exos_community_invites (community_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.exos_community_events (
  community_id    uuid NOT NULL REFERENCES public.exos_communities (id) ON DELETE CASCADE,
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,  -- the community's org
  event_org_id    uuid NOT NULL,                                                     -- the event's org (a host's own)
  host_id         uuid REFERENCES public.exos_community_hosts (id) ON DELETE SET NULL,
  added_by        uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  members_only    boolean NOT NULL DEFAULT false,
  early_access_until timestamptz,
  access_rule     text NOT NULL DEFAULT 'community' CHECK (access_rule IN ('community', 'membership', 'either')),
  membership_product_ids uuid[] NOT NULL DEFAULT '{}' CHECK (cardinality(membership_product_ids) <= 20),
  announced_at    timestamptz,
  announce_note   text CHECK (announce_note IS NULL OR char_length(announce_note) <= 120),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (community_id, event_id),
  CONSTRAINT exos_community_events_rule_chk CHECK (access_rule = 'community' OR cardinality(membership_product_ids) > 0)
);
CREATE INDEX IF NOT EXISTS exos_community_events_event_idx ON public.exos_community_events (event_id);

CREATE TABLE IF NOT EXISTS public.exos_community_posts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id  uuid NOT NULL REFERENCES public.exos_communities (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  author_uid    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  host_id       uuid REFERENCES public.exos_community_hosts (id) ON DELETE SET NULL,
  title         text CHECK (title IS NULL OR char_length(title) BETWEEN 1 AND 140),
  body          text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 5000),
  visibility    text NOT NULL DEFAULT 'public' CHECK (visibility IN ('public', 'members')),
  status        text NOT NULL DEFAULT 'published' CHECK (status IN ('published', 'hidden', 'removed')),
  notify        boolean NOT NULL DEFAULT false,
  notified_at   timestamptz,
  notify_note   text CHECK (notify_note IS NULL OR char_length(notify_note) <= 120),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_community_posts_comm_idx ON public.exos_community_posts (community_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_community_posts_author_idx ON public.exos_community_posts (author_uid, created_at DESC);

CREATE TABLE IF NOT EXISTS public.exos_community_reports (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id       uuid NOT NULL REFERENCES public.exos_community_posts (id) ON DELETE CASCADE,
  community_id  uuid NOT NULL REFERENCES public.exos_communities (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  reporter_uid  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  reason        text NOT NULL CHECK (reason IN ('spam', 'harassment', 'hate', 'sexual', 'violence', 'misleading', 'other')),
  note          text CHECK (note IS NULL OR char_length(note) <= 500),
  status        text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'dismissed')),
  action        text CHECK (action IS NULL OR action IN ('dismiss', 'hide', 'remove', 'ban')),
  resolved_by   uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  resolved_at   timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (post_id, reporter_uid)
);
CREATE INDEX IF NOT EXISTS exos_community_reports_open_idx ON public.exos_community_reports (community_id) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS exos_community_reports_reporter_idx ON public.exos_community_reports (reporter_uid, created_at DESC);

-- ---------------------------------------------------------------------------
-- 2. Federation tables (service role only)
-- ---------------------------------------------------------------------------
-- One key pair per actor: a community (Group) or an org (Person, the author of
-- the community's posts). The private key is a Vault secret; key_secret_id
-- points at it and is never readable by a client.
CREATE TABLE IF NOT EXISTS public.exos_ap_actors (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id         uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  kind           text NOT NULL CHECK (kind IN ('community', 'org')),
  community_id   uuid UNIQUE REFERENCES public.exos_communities (id) ON DELETE CASCADE,
  public_key_pem text NOT NULL CHECK (public_key_pem LIKE '-----BEGIN PUBLIC KEY-----%' AND char_length(public_key_pem) <= 2000),
  key_secret_id  uuid NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_ap_actors_ref_chk CHECK ((kind = 'community') = (community_id IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_ap_actors_org_uq ON public.exos_ap_actors (org_id) WHERE kind = 'org';

CREATE TABLE IF NOT EXISTS public.exos_ap_followers (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id       uuid NOT NULL REFERENCES public.exos_communities (id) ON DELETE CASCADE,
  org_id             uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  actor_uri          text NOT NULL CHECK (actor_uri ~ '^https://' AND char_length(actor_uri) <= 500),
  inbox_uri          text NOT NULL CHECK (inbox_uri ~ '^https://' AND char_length(inbox_uri) <= 500),
  shared_inbox_uri   text CHECK (shared_inbox_uri IS NULL OR (shared_inbox_uri ~ '^https://' AND char_length(shared_inbox_uri) <= 500)),
  follow_activity_id text CHECK (follow_activity_id IS NULL OR char_length(follow_activity_id) <= 500),
  software           text CHECK (software IS NULL OR software ~ '^[a-z0-9._-]{1,40}$'),
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'removed')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (community_id, actor_uri)
);
CREATE INDEX IF NOT EXISTS exos_ap_followers_comm_idx ON public.exos_ap_followers (community_id) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS exos_ap_followers_actor_idx ON public.exos_ap_followers (actor_uri);

-- Remote actors or whole domains a community won't federate with.
CREATE TABLE IF NOT EXISTS public.exos_ap_blocks (
  community_id uuid NOT NULL REFERENCES public.exos_communities (id) ON DELETE CASCADE,
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  pattern      text NOT NULL CHECK (char_length(pattern) BETWEEN 3 AND 500 AND pattern ~ '^(https://[^[:space:]]+|[a-z0-9.-]+)$'),
  created_by   uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (community_id, pattern)
);

-- Replies from the fediverse wait here for a moderator; only approved ones
-- show on the public page. Plain text only (tags stripped by the edge function
-- and again never rendered as HTML).
CREATE TABLE IF NOT EXISTS public.exos_ap_remote_replies (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id  uuid NOT NULL REFERENCES public.exos_communities (id) ON DELETE CASCADE,
  org_id        uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  post_id       uuid REFERENCES public.exos_community_posts (id) ON DELETE CASCADE,
  event_id      uuid REFERENCES public.exos_events (id) ON DELETE CASCADE,
  activity_id   text CHECK (activity_id IS NULL OR char_length(activity_id) <= 500),
  object_id     text NOT NULL UNIQUE CHECK (object_id ~ '^https://' AND char_length(object_id) <= 500),
  actor_uri     text NOT NULL CHECK (actor_uri ~ '^https://' AND char_length(actor_uri) <= 500),
  actor_name    text CHECK (actor_name IS NULL OR char_length(actor_name) <= 120),
  actor_handle  text CHECK (actor_handle IS NULL OR char_length(actor_handle) <= 200),
  content_text  text NOT NULL CHECK (char_length(content_text) BETWEEN 1 AND 5000),
  url           text CHECK (url IS NULL OR (url ~ '^https://' AND char_length(url) <= 500)),
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'deleted')),
  reviewed_by   uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  reviewed_at   timestamptz,
  received_at   timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_ap_remote_replies_target_chk CHECK (num_nonnulls(post_id, event_id) = 1)
);
CREATE INDEX IF NOT EXISTS exos_ap_remote_replies_queue_idx ON public.exos_ap_remote_replies (community_id, received_at DESC) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS exos_ap_remote_replies_actor_idx ON public.exos_ap_remote_replies (actor_uri, received_at DESC);

-- Outbound deliveries: one row per (activity, inbox). The edge function builds
-- the JSON when it sends (from kind + ref_id), so a post removed meanwhile is
-- skipped, and signs it with the actor's key.
CREATE TABLE IF NOT EXISTS public.exos_ap_deliveries (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  community_id    uuid NOT NULL REFERENCES public.exos_communities (id) ON DELETE CASCADE,
  kind            text NOT NULL CHECK (kind IN ('accept', 'create_post', 'delete_post', 'create_event', 'update_event')),
  ref_id          uuid,
  dedupe_key      text NOT NULL CHECK (char_length(dedupe_key) <= 600),
  style           text NOT NULL DEFAULT 'object' CHECK (style IN ('object', 'activity')),
  payload         jsonb CHECK (payload IS NULL OR (jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 8000)),
  inbox_uri       text NOT NULL CHECK (inbox_uri ~ '^https://' AND char_length(inbox_uri) <= 500),
  status          text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sending', 'sent', 'dead', 'cancelled')),
  attempts        integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  lease_until     timestamptz,
  last_status     integer,
  last_error      text CHECK (last_error IS NULL OR char_length(last_error) <= 300),
  sent_at         timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (dedupe_key, inbox_uri)
);
CREATE INDEX IF NOT EXISTS exos_ap_deliveries_due_idx ON public.exos_ap_deliveries (next_attempt_at) WHERE status IN ('queued', 'sending');

-- Remote actor key cache (public data fetched from other servers). The one
-- table here without org_id: a remote actor isn't any org's data, and the
-- same actor can follow several orgs' communities.
CREATE TABLE IF NOT EXISTS public.exos_ap_remote_actors (
  actor_uri        text PRIMARY KEY CHECK (actor_uri ~ '^https://' AND char_length(actor_uri) <= 500),
  key_id           text NOT NULL CHECK (char_length(key_id) <= 600),
  public_key_pem   text NOT NULL CHECK (char_length(public_key_pem) <= 4000),
  inbox_uri        text CHECK (inbox_uri IS NULL OR char_length(inbox_uri) <= 500),
  shared_inbox_uri text CHECK (shared_inbox_uri IS NULL OR char_length(shared_inbox_uri) <= 500),
  handle           text CHECK (handle IS NULL OR char_length(handle) <= 200),
  name             text CHECK (name IS NULL OR char_length(name) <= 120),
  fetched_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_ap_remote_actors_key_idx ON public.exos_ap_remote_actors (key_id);

-- updated_at triggers
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_communities','exos_community_hosts','exos_community_members','exos_community_invites',
                           'exos_community_events','exos_community_posts','exos_community_reports','exos_ap_actors',
                           'exos_ap_followers','exos_ap_blocks','exos_ap_remote_replies','exos_ap_deliveries',
                           'exos_ap_remote_actors'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at()', t || '_touch', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3. RLS + grants. Writes are RPC-only everywhere. Staff of the org (and the
--    person themselves for their own member / host row) can read.
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text; r text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_communities','exos_community_hosts','exos_community_members','exos_community_invites',
                           'exos_community_events','exos_community_posts','exos_community_reports','exos_ap_actors',
                           'exos_ap_followers','exos_ap_blocks','exos_ap_remote_replies','exos_ap_deliveries',
                           'exos_ap_remote_actors'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    FOREACH r IN ARRAY ARRAY['coworker_readonly','analyst_ro'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
END $$;

GRANT SELECT ON public.exos_communities, public.exos_community_members, public.exos_community_events,
                public.exos_community_posts TO authenticated;
-- No token hashes and no reporter ids through the table grants.
GRANT SELECT (id, community_id, org_id, user_id, email, host_org_id, display_name, status, expires_at, accepted_at,
              revoked_at, created_at, updated_at) ON public.exos_community_hosts TO authenticated;
GRANT SELECT (id, community_id, org_id, email, max_uses, uses, expires_at, revoked_at, created_at)
  ON public.exos_community_invites TO authenticated;
GRANT SELECT (id, post_id, community_id, org_id, reason, note, status, action, resolved_at, created_at)
  ON public.exos_community_reports TO authenticated;

DROP POLICY IF EXISTS exos_communities_sel ON public.exos_communities;
CREATE POLICY exos_communities_sel ON public.exos_communities FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance','content','scanner']) OR public.exos_is_admin());

DROP POLICY IF EXISTS exos_community_hosts_sel ON public.exos_community_hosts;
CREATE POLICY exos_community_hosts_sel ON public.exos_community_hosts FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()) OR public.exos_has_org_role(org_id, ARRAY['owner','manager']));

DROP POLICY IF EXISTS exos_community_members_sel ON public.exos_community_members;
CREATE POLICY exos_community_members_sel ON public.exos_community_members FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()) OR public.exos_has_org_role(org_id, ARRAY['owner','manager']));

DROP POLICY IF EXISTS exos_community_invites_sel ON public.exos_community_invites;
CREATE POLICY exos_community_invites_sel ON public.exos_community_invites FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));

DROP POLICY IF EXISTS exos_community_events_sel ON public.exos_community_events;
CREATE POLICY exos_community_events_sel ON public.exos_community_events FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager','finance','content','scanner']));

DROP POLICY IF EXISTS exos_community_posts_sel ON public.exos_community_posts;
CREATE POLICY exos_community_posts_sel ON public.exos_community_posts FOR SELECT TO authenticated
  USING (author_uid = (SELECT auth.uid()) OR public.exos_has_org_role(org_id, ARRAY['owner','manager','content']));

DROP POLICY IF EXISTS exos_community_reports_sel ON public.exos_community_reports;
CREATE POLICY exos_community_reports_sel ON public.exos_community_reports FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner','manager']));

-- ---------------------------------------------------------------------------
-- 4. Mail template allowlist and SMS campaign audience
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_new  text[] := ARRAY['community-post','community-event'];
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
    RETURN;  -- already allowed; leave the live list alone
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

ALTER TABLE public.exos_sms_campaigns ADD COLUMN IF NOT EXISTS community_id uuid
  REFERENCES public.exos_communities (id) ON DELETE SET NULL;
DO $$
BEGIN
  IF strpos(coalesce((SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
                       WHERE c.conrelid = 'public.exos_sms_campaigns'::regclass
                         AND c.conname = 'exos_sms_campaigns_audience_check'), ''), 'community') = 0 THEN
    ALTER TABLE public.exos_sms_campaigns DROP CONSTRAINT IF EXISTS exos_sms_campaigns_audience_check;
    ALTER TABLE public.exos_sms_campaigns ADD CONSTRAINT exos_sms_campaigns_audience_check
      CHECK (audience IN ('org', 'event_buyers', 'community'));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5. Helpers (no client EXECUTE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_comm_is_admin(p_org_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT auth.uid() IS NOT NULL AND (public.exos_has_org_role(p_org_id, ARRAY['owner','manager']) OR public.exos_is_admin())
$$;
REVOKE ALL ON FUNCTION public._exos_comm_is_admin(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_comm_host_id(p_community_id uuid, p_uid uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT h.id FROM public.exos_community_hosts h
   WHERE h.community_id = p_community_id AND h.user_id = p_uid AND h.status = 'active' AND p_uid IS NOT NULL
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._exos_comm_host_id(uuid, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_comm_is_member(p_community_id uuid, p_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT p_uid IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_community_members m
                                        WHERE m.community_id = p_community_id AND m.user_id = p_uid AND m.status = 'active')
$$;
REVOKE ALL ON FUNCTION public._exos_comm_is_member(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- Members, hosts and the org's staff see members-only posts.
CREATE OR REPLACE FUNCTION public._exos_comm_insider(p_community_id uuid, p_org_id uuid, p_uid uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT p_uid IS NOT NULL AND (
           public._exos_comm_is_member(p_community_id, p_uid)
        OR public._exos_comm_host_id(p_community_id, p_uid) IS NOT NULL
        OR EXISTS (SELECT 1 FROM public.exos_org_memberships m
                    WHERE m.org_id = p_org_id AND m.user_id = p_uid AND m.disabled IS NOT TRUE
                      AND m.role IN ('owner','manager','content')))
$$;
REVOKE ALL ON FUNCTION public._exos_comm_insider(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_comm_token_hash(p_token text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p_token ~ '^ecv_[0-9a-f]{64}$' OR p_token ~ '^ech_[0-9a-f]{64}$'
              THEN encode(extensions.digest(p_token, 'sha256'), 'hex') END
$$;
REVOKE ALL ON FUNCTION public._exos_comm_token_hash(text) FROM PUBLIC, anon, authenticated;

-- The membership seam (memberships migration, 20261030130500): does this
-- account hold a live membership of one of these products? Dynamic so this
-- migration applies without it; without it the answer is no (fail closed).
CREATE OR REPLACE FUNCTION public._exos_comm_has_membership(p_org_id uuid, p_uid uuid, p_product_ids uuid[])
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v boolean;
BEGIN
  IF p_uid IS NULL OR cardinality(coalesce(p_product_ids, '{}')) = 0 THEN RETURN false; END IF;
  IF to_regprocedure('public._exos_member_best(uuid,uuid,uuid[],boolean)') IS NULL THEN RETURN false; END IF;
  EXECUTE 'SELECT (public._exos_member_best($1, $2, $3, false)).id IS NOT NULL' INTO v USING p_org_id, p_uid, p_product_ids;
  RETURN coalesce(v, false);
END $$;
REVOKE ALL ON FUNCTION public._exos_comm_has_membership(uuid, uuid, uuid[]) FROM PUBLIC, anon, authenticated;

-- Is this account kept out of the event by a community's members-only or
-- early-access rule? Allowed when ANY gating community lets them in.
CREATE OR REPLACE FUNCTION public._exos_comm_gate(p_event_id uuid, p_uid uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record; v_first record; v_any boolean := false;
BEGIN
  -- v_first is only read once v_any is true.
  FOR r IN
    SELECT ce.*, c.slug, c.name AS community_name, c.org_id AS c_org
      FROM public.exos_community_events ce JOIN public.exos_communities c ON c.id = ce.community_id
     WHERE ce.event_id = p_event_id AND c.status = 'active'
       AND (ce.members_only OR (ce.early_access_until IS NOT NULL AND ce.early_access_until > now()))
     ORDER BY ce.created_at
  LOOP
    IF NOT v_any THEN v_first := r; END IF;
    v_any := true;
    IF p_uid IS NOT NULL AND (
         (r.access_rule IN ('community', 'either') AND public._exos_comm_is_member(r.community_id, p_uid))
      OR (r.access_rule IN ('membership', 'either') AND public._exos_comm_has_membership(r.c_org, p_uid, r.membership_product_ids))
      OR public._exos_comm_host_id(r.community_id, p_uid) IS NOT NULL) THEN
      RETURN jsonb_build_object('blocked', false, 'gated', true);
    END IF;
  END LOOP;
  IF NOT v_any THEN RETURN jsonb_build_object('blocked', false, 'gated', false); END IF;
  RETURN jsonb_build_object(
    'blocked', true, 'gated', true,
    'reason', CASE WHEN v_first.members_only THEN 'members_only' ELSE 'early_access' END,
    'until', CASE WHEN v_first.members_only THEN NULL ELSE v_first.early_access_until END,
    'community_slug', v_first.slug, 'community_name', v_first.community_name, 'access_rule', v_first.access_rule,
    'message', CASE WHEN v_first.members_only
                    THEN 'Tickets for this event are for members of ' || v_first.community_name || '.'
                    ELSE 'Members of ' || v_first.community_name || ' get early access to this event.' END);
END $$;
REVOKE ALL ON FUNCTION public._exos_comm_gate(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- Notification budgets. NULL = ok, else why not.
CREATE OR REPLACE FUNCTION public._exos_comm_post_budget(p_community_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT CASE
    WHEN (SELECT count(*) FROM public.exos_community_posts p
           WHERE p.community_id = p_community_id AND p.notified_at > now() - interval '1 day') >= 3
      THEN 'members were already notified 3 times today'
    WHEN (SELECT count(*) FROM public.exos_community_posts p
           WHERE p.community_id = p_community_id AND p.notified_at > now() - interval '7 days') >= 10
      THEN 'members were already notified 10 times this week'
  END
$$;
REVOKE ALL ON FUNCTION public._exos_comm_post_budget(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Fan-out: mail + texts to members who opted in to that channel
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_comm_notify(p_community_id uuid, p_kind text, p_ref uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  c        public.exos_communities%ROWTYPE;
  v_obj    jsonb;
  v_payload jsonb;
  v_mail   int := 0;
  v_texts  int := 0;
  v_capped int := 0;
  v_sms    text := NULL;
  v_prov   text;
  v_tz     text := 'America/New_York';
  v_at     timestamptz := now();
  v_local  timestamp;
  v_line   text;
  v_body   text;
  v_camp   uuid;
  r        record;
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR c.status <> 'active' THEN RETURN jsonb_build_object('emailed', 0, 'texted', 0); END IF;

  IF p_kind = 'post' THEN
    SELECT jsonb_build_object('id', p.id, 'title', p.title, 'body', left(p.body, 600),
                              'members_only', p.visibility = 'members')
      INTO v_obj FROM public.exos_community_posts p WHERE p.id = p_ref AND p.community_id = c.id;
    SELECT coalesce(p.title, left(regexp_replace(p.body, '\s+', ' ', 'g'), 120)) INTO v_line
      FROM public.exos_community_posts p WHERE p.id = p_ref;
  ELSIF p_kind = 'event' THEN
    v_obj := public._exos_mail_event_json(p_ref);
    SELECT coalesce(nullif(e.timezone, ''), v_tz),
           'New event: ' || left(coalesce(e.name, 'Event'), 80) ||
           coalesce(', ' || to_char(e.starts_at AT TIME ZONE coalesce(nullif(e.timezone, ''), v_tz), 'Mon FMDD'), '')
      INTO v_tz, v_line FROM public.exos_events e WHERE e.id = p_ref;
    v_obj := v_obj || jsonb_build_object('members_only', EXISTS (
      SELECT 1 FROM public.exos_community_events ce WHERE ce.community_id = c.id AND ce.event_id = p_ref AND ce.members_only),
      'early_access_until', (SELECT ce.early_access_until FROM public.exos_community_events ce
                              WHERE ce.community_id = c.id AND ce.event_id = p_ref));
  ELSE
    RAISE EXCEPTION '_exos_comm_notify: bad kind' USING ERRCODE = '22023';
  END IF;
  IF v_obj IS NULL THEN RETURN jsonb_build_object('emailed', 0, 'texted', 0); END IF;

  v_payload := jsonb_build_object(
    'community', jsonb_build_object('id', c.id, 'name', c.name, 'slug', c.slug),
    'org_name', (SELECT o.name FROM public.exos_orgs o WHERE o.id = c.org_id),
    CASE WHEN p_kind = 'post' THEN 'post' ELSE 'event' END, v_obj);

  -- Email: members who chose it, with a confirmed address. Marketing mail:
  -- the account-level opt-out applies and the unsubscribe link is added.
  FOR r IN
    SELECT m.user_id, lower(u.email) AS email
      FROM public.exos_community_members m JOIN auth.users u ON u.id = m.user_id
     WHERE m.community_id = c.id AND m.status = 'active' AND m.notify_email
       AND coalesce(u.email, '') <> '' AND u.email_confirmed_at IS NOT NULL
  LOOP
    IF public.exos_mail_enqueue('community-' || p_kind, r.email, v_payload,
                                'community-' || p_kind || ':' || c.id || ':' || p_ref || ':' || r.user_id,
                                r.user_id, true, NULL) IS NOT NULL THEN
      v_mail := v_mail + 1;
    END IF;
  END LOOP;

  -- Texts: members who chose them AND are on the org's SMS list (their own
  -- opt-in with consent text; STOP there stops these too).
  IF EXISTS (SELECT 1 FROM public.exos_community_members m
              JOIN public.exos_sms_subscribers s ON s.org_id = c.org_id AND s.user_id = m.user_id AND s.opted_out_at IS NULL
             WHERE m.community_id = c.id AND m.status = 'active' AND m.notify_sms) THEN
    SELECT i.provider INTO v_prov FROM public.exos_org_integrations i
     WHERE i.org_id = c.org_id AND i.provider IN ('twilio', 'telnyx') AND i.status = 'connected'
     ORDER BY (i.provider = 'twilio') DESC LIMIT 1;
    IF v_prov IS NULL THEN
      v_sms := 'no texting provider connected';
    ELSIF (SELECT count(*) FROM public.exos_sms_campaigns WHERE org_id = c.org_id AND created_at > now() - interval '1 day'
              AND status <> 'cancelled') >= 5 THEN
      v_sms := 'the org already sent 5 text campaigns today';
    ELSE
      v_local := v_at AT TIME ZONE v_tz;
      IF v_local::time < time '09:00' THEN
        v_at := (date_trunc('day', v_local) + interval '9 hours') AT TIME ZONE v_tz;
      ELSIF v_local::time >= time '20:00' THEN
        v_at := (date_trunc('day', v_local) + interval '1 day 9 hours') AT TIME ZONE v_tz;
      END IF;
      v_body := left(left(c.name, 40) || ': ' || coalesce(v_line, 'News') || ' Reply STOP to opt out.', 480);
      INSERT INTO public.exos_sms_campaigns (org_id, event_id, audience, body, provider, send_after, community_id)
      VALUES (c.org_id, CASE WHEN p_kind = 'event' THEN p_ref END, 'community', v_body, v_prov, v_at, c.id)
      RETURNING id INTO v_camp;
      WITH a AS (
        SELECT DISTINCT s.phone,
               (SELECT count(*) FROM public.exos_sms_outbox o
                 WHERE o.org_id = c.org_id AND o.phone = s.phone
                   AND o.status IN ('queued', 'sending', 'sent', 'dry_run')
                   AND o.created_at > now() - interval '30 days') AS recent
          FROM public.exos_community_members m
          JOIN public.exos_sms_subscribers s ON s.org_id = c.org_id AND s.user_id = m.user_id AND s.opted_out_at IS NULL
         WHERE m.community_id = c.id AND m.status = 'active' AND m.notify_sms
      ), ins AS (
        INSERT INTO public.exos_sms_outbox (campaign_id, org_id, phone, body, send_after)
        SELECT v_camp, c.org_id, a.phone, v_body, v_at FROM a WHERE a.recent < 8
        ON CONFLICT DO NOTHING
        RETURNING 1
      )
      SELECT (SELECT count(*) FROM ins), (SELECT count(*) FROM a WHERE a.recent >= 8) INTO v_texts, v_capped;
      UPDATE public.exos_sms_campaigns SET queued_count = v_texts, skipped_cap = v_capped,
             status = CASE WHEN v_texts = 0 THEN 'sent' ELSE 'queued' END
       WHERE id = v_camp;
    END IF;
  END IF;
  RETURN jsonb_build_object('emailed', v_mail, 'texted', v_texts, 'text_capped', v_capped, 'text_note', v_sms);
END $$;
REVOKE ALL ON FUNCTION public._exos_comm_notify(uuid, text, uuid) FROM PUBLIC, anon, authenticated;

-- Federation fan-out: one delivery per distinct follower inbox. Only public,
-- active, federating communities; only when there are followers (which can
-- only exist while EXOS_FEDERATION=on, since Follow arrives through it).
CREATE OR REPLACE FUNCTION public._exos_ap_enqueue(p_community_id uuid, p_kind text, p_ref uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE; v_n int;
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR NOT c.federation_enabled OR c.visibility <> 'public' OR c.status <> 'active' THEN RETURN 0; END IF;
  INSERT INTO public.exos_ap_deliveries (org_id, community_id, kind, ref_id, dedupe_key, style, inbox_uri)
  SELECT c.org_id, c.id, p_kind, p_ref, p_kind || ':' || p_ref, x.style, x.inbox
    FROM (SELECT DISTINCT ON (coalesce(f.shared_inbox_uri, f.inbox_uri))
                 coalesce(f.shared_inbox_uri, f.inbox_uri) AS inbox,
                 CASE WHEN f.software IN ('lemmy', 'mbin', 'kbin', 'piefed') THEN 'activity' ELSE 'object' END AS style
            FROM public.exos_ap_followers f
           WHERE f.community_id = c.id AND f.status = 'active'
           ORDER BY coalesce(f.shared_inbox_uri, f.inbox_uri), coalesce(f.software IN ('lemmy', 'mbin', 'kbin', 'piefed'), false) DESC) x
  ON CONFLICT (dedupe_key, inbox_uri) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_ap_enqueue(uuid, text, uuid) FROM PUBLIC, anon, authenticated;

-- Announce an event of a community, once (announced_at), within the budget
-- of 5 a day per community. Called when it's added (if already published) and
-- when it gets published.
CREATE OR REPLACE FUNCTION public._exos_comm_announce_event(p_community_id uuid, p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE ce public.exos_community_events%ROWTYPE; v_res jsonb;
BEGIN
  SELECT * INTO ce FROM public.exos_community_events
   WHERE community_id = p_community_id AND event_id = p_event_id FOR UPDATE;
  IF NOT FOUND OR ce.announced_at IS NOT NULL THEN RETURN NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id AND e.status = 'published'
                    AND (e.starts_at IS NULL OR e.starts_at > now())) THEN
    RETURN NULL;
  END IF;
  IF (SELECT count(*) FROM public.exos_community_events x
       WHERE x.community_id = p_community_id AND x.announced_at > now() - interval '1 day') >= 5 THEN
    UPDATE public.exos_community_events SET announce_note = 'not announced: 5 event announcements a day'
     WHERE community_id = p_community_id AND event_id = p_event_id;
    RETURN jsonb_build_object('announced', false, 'note', '5 event announcements a day');
  END IF;
  UPDATE public.exos_community_events SET announced_at = now(), announce_note = NULL
   WHERE community_id = p_community_id AND event_id = p_event_id;
  v_res := public._exos_comm_notify(p_community_id, 'event', p_event_id);
  IF NOT ce.members_only THEN
    PERFORM public._exos_ap_enqueue(p_community_id, 'create_event', p_event_id);
  END IF;
  RETURN v_res || jsonb_build_object('announced', true);
END $$;
REVOKE ALL ON FUNCTION public._exos_comm_announce_event(uuid, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Organizer RPCs (owner / manager of the community's org)
-- ---------------------------------------------------------------------------
-- Create (p_id NULL) or update a community. Fields: slug (create only), name,
-- tagline, about, banner_url, city, region, country, join_mode, visibility,
-- federation_enabled, status.
CREATE OR REPLACE FUNCTION public.exos_community_save(p_org_id uuid, p_id uuid, p_fields jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  f jsonb := coalesce(p_fields, '{}'::jsonb);
  c public.exos_communities%ROWTYPE;
  v_slug text;
BEGIN
  IF jsonb_typeof(f) <> 'object' THEN RAISE EXCEPTION 'exos_community_save: fields must be an object' USING ERRCODE = '22023'; END IF;
  IF p_id IS NULL THEN
    IF NOT public._exos_comm_is_admin(p_org_id) THEN
      RAISE EXCEPTION 'exos_community_save: owner or manager only' USING ERRCODE = '42501';
    END IF;
    IF (SELECT count(*) FROM public.exos_communities WHERE org_id = p_org_id) >= 25 THEN
      RAISE EXCEPTION 'exos_community_save: at most 25 communities per organization' USING ERRCODE = '54000';
    END IF;
    v_slug := lower(btrim(coalesce(f->>'slug', '')));
    IF v_slug !~ '^[a-z0-9][a-z0-9_-]{1,38}[a-z0-9]$' OR v_slug ~ '^org[_-]'
       OR v_slug IN ('new', 'admin', 'api', 'ap', 'inbox', 'settings', 'directory', 'communities', 'www', 'exos') THEN
      RAISE EXCEPTION 'exos_community_save: pick a link name of 3-40 letters, numbers, - or _' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.exos_communities WHERE slug = v_slug OR ap_name = replace(v_slug, '-', '_')) THEN
      RAISE EXCEPTION 'exos_community_save: that link name is taken' USING ERRCODE = '23505';
    END IF;
    INSERT INTO public.exos_communities (org_id, slug, name, created_by)
    VALUES (p_org_id, v_slug, btrim(coalesce(f->>'name', v_slug)), auth.uid())
    RETURNING * INTO c;
  ELSE
    SELECT * INTO c FROM public.exos_communities WHERE id = p_id FOR UPDATE;
    IF NOT FOUND OR c.org_id IS DISTINCT FROM p_org_id OR NOT public._exos_comm_is_admin(c.org_id) THEN
      RAISE EXCEPTION 'exos_community_save: owner or manager only' USING ERRCODE = '42501';
    END IF;
  END IF;

  UPDATE public.exos_communities SET
    name       = CASE WHEN f ? 'name' THEN btrim(f->>'name') ELSE name END,
    tagline    = CASE WHEN f ? 'tagline' THEN nullif(btrim(f->>'tagline'), '') ELSE tagline END,
    about      = CASE WHEN f ? 'about' THEN nullif(btrim(f->>'about'), '') ELSE about END,
    banner_url = CASE WHEN f ? 'banner_url' THEN nullif(btrim(f->>'banner_url'), '') ELSE banner_url END,
    city       = CASE WHEN f ? 'city' THEN nullif(btrim(f->>'city'), '') ELSE city END,
    region     = CASE WHEN f ? 'region' THEN nullif(btrim(f->>'region'), '') ELSE region END,
    country    = CASE WHEN f ? 'country' THEN nullif(upper(btrim(f->>'country')), '') ELSE country END,
    join_mode  = CASE WHEN f ? 'join_mode' THEN f->>'join_mode' ELSE join_mode END,
    visibility = CASE WHEN f ? 'visibility' THEN f->>'visibility' ELSE visibility END,
    federation_enabled = CASE WHEN f ? 'federation_enabled' THEN (f->>'federation_enabled')::boolean ELSE federation_enabled END,
    status     = CASE WHEN f ? 'status' THEN f->>'status' ELSE status END
   WHERE id = c.id
  RETURNING * INTO c;

  -- Going unlisted / archived / not federating stops federation: followers are
  -- dropped (they'd get nothing anyway) and queued deliveries cancelled.
  IF NOT c.federation_enabled OR c.visibility <> 'public' OR c.status <> 'active' THEN
    UPDATE public.exos_ap_deliveries SET status = 'cancelled', lease_until = NULL
     WHERE community_id = c.id AND status IN ('queued', 'sending');
  END IF;
  RETURN to_jsonb(c);
EXCEPTION WHEN check_violation THEN
  RAISE EXCEPTION 'exos_community_save: %', SQLERRM USING ERRCODE = '22023';
END $$;
REVOKE ALL ON FUNCTION public.exos_community_save(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_save(uuid, uuid, jsonb) TO authenticated, service_role;

-- Everything the organizer panel shows for one community.
CREATE OR REPLACE FUNCTION public.exos_community_admin(p_community_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE;
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR NOT public._exos_comm_is_admin(c.org_id) THEN
    RAISE EXCEPTION 'exos_community_admin: owner or manager only' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'community', to_jsonb(c),
    'counts', jsonb_build_object(
      'members', (SELECT count(*) FROM public.exos_community_members WHERE community_id = c.id AND status = 'active'),
      'pending', (SELECT count(*) FROM public.exos_community_members WHERE community_id = c.id AND status = 'pending'),
      'banned',  (SELECT count(*) FROM public.exos_community_members WHERE community_id = c.id AND status = 'banned'),
      'email',   (SELECT count(*) FROM public.exos_community_members WHERE community_id = c.id AND status = 'active' AND notify_email),
      'sms',     (SELECT count(*) FROM public.exos_community_members WHERE community_id = c.id AND status = 'active' AND notify_sms),
      'fediverse_followers', (SELECT count(*) FROM public.exos_ap_followers WHERE community_id = c.id AND status = 'active')),
    'hosts', coalesce((SELECT jsonb_agg(jsonb_build_object('id', h.id, 'email', h.email, 'display_name', h.display_name,
                         'status', h.status, 'host_org_id', h.host_org_id, 'expires_at', h.expires_at,
                         'accepted_at', h.accepted_at) ORDER BY h.created_at)
                         FROM public.exos_community_hosts h WHERE h.community_id = c.id AND h.status <> 'revoked'), '[]'::jsonb),
    'invites', coalesce((SELECT jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'uses', i.uses, 'max_uses', i.max_uses,
                         'expires_at', i.expires_at) ORDER BY i.created_at DESC)
                         FROM public.exos_community_invites i
                        WHERE i.community_id = c.id AND i.revoked_at IS NULL AND i.expires_at > now() AND i.uses < i.max_uses), '[]'::jsonb),
    'events', coalesce((SELECT jsonb_agg(jsonb_build_object('event_id', e.id, 'name', e.name, 'starts_at', e.starts_at,
                         'status', e.status, 'members_only', ce.members_only, 'early_access_until', ce.early_access_until,
                         'access_rule', ce.access_rule, 'membership_product_ids', ce.membership_product_ids,
                         'announced_at', ce.announced_at, 'announce_note', ce.announce_note,
                         'host', (SELECT h.display_name FROM public.exos_community_hosts h WHERE h.id = ce.host_id))
                         ORDER BY e.starts_at DESC NULLS LAST)
                         FROM public.exos_community_events ce JOIN public.exos_events e ON e.id = ce.event_id
                        WHERE ce.community_id = c.id), '[]'::jsonb),
    'posts', coalesce((SELECT jsonb_agg(x ORDER BY x->>'created_at' DESC) FROM (
                         SELECT jsonb_build_object('id', p.id, 'title', p.title, 'body', p.body, 'visibility', p.visibility,
                           'status', p.status, 'notify', p.notify, 'notified_at', p.notified_at, 'notify_note', p.notify_note,
                           'created_at', p.created_at,
                           'host', (SELECT h.display_name FROM public.exos_community_hosts h WHERE h.id = p.host_id),
                           'open_reports', (SELECT count(*) FROM public.exos_community_reports r WHERE r.post_id = p.id AND r.status = 'open')) AS x
                           FROM public.exos_community_posts p WHERE p.community_id = c.id
                          ORDER BY p.created_at DESC LIMIT 50) q), '[]'::jsonb),
    'reports', coalesce((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'post_id', r.post_id, 'reason', r.reason, 'note', r.note,
                         'created_at', r.created_at,
                         'post_excerpt', (SELECT left(p.body, 200) FROM public.exos_community_posts p WHERE p.id = r.post_id))
                         ORDER BY r.created_at)
                         FROM public.exos_community_reports r WHERE r.community_id = c.id AND r.status = 'open'), '[]'::jsonb),
    'remote_replies', coalesce((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'post_id', x.post_id, 'event_id', x.event_id,
                         'actor_uri', x.actor_uri, 'actor_name', x.actor_name, 'actor_handle', x.actor_handle,
                         'content_text', x.content_text, 'url', x.url, 'received_at', x.received_at) ORDER BY x.received_at)
                         FROM (SELECT * FROM public.exos_ap_remote_replies
                                WHERE community_id = c.id AND status = 'pending' ORDER BY received_at LIMIT 100) x), '[]'::jsonb),
    'blocks', coalesce((SELECT jsonb_agg(b.pattern ORDER BY b.created_at) FROM public.exos_ap_blocks b WHERE b.community_id = c.id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_community_admin(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_admin(uuid) TO authenticated, service_role;

-- The member list (owner / manager). Emails are shown to them, as elsewhere.
CREATE OR REPLACE FUNCTION public.exos_community_member_list(p_community_id uuid, p_status text DEFAULT 'active',
                                                             p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE;
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR NOT public._exos_comm_is_admin(c.org_id) THEN
    RAISE EXCEPTION 'exos_community_member_list: owner or manager only' USING ERRCODE = '42501';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(x) FROM (
    SELECT jsonb_build_object('user_id', m.user_id, 'email', lower(u.email), 'status', m.status,
             'notify_email', m.notify_email, 'notify_sms', m.notify_sms, 'joined_at', m.joined_at,
             'requested_at', m.requested_at, 'ban_reason', m.ban_reason, 'banned_at', m.banned_at) AS x
      FROM public.exos_community_members m JOIN auth.users u ON u.id = m.user_id
     WHERE m.community_id = c.id AND m.status = coalesce(p_status, 'active')
     ORDER BY coalesce(m.joined_at, m.requested_at) DESC
     LIMIT least(greatest(coalesce(p_limit, 100), 1), 500) OFFSET greatest(coalesce(p_offset, 0), 0)) q), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.exos_community_member_list(uuid, text, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_member_list(uuid, text, integer, integer) TO authenticated, service_role;

-- Approve or decline a join request.
CREATE OR REPLACE FUNCTION public.exos_community_decide(p_community_id uuid, p_user_id uuid, p_approve boolean)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE; v_n int;
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR NOT public._exos_comm_is_admin(c.org_id) THEN
    RAISE EXCEPTION 'exos_community_decide: owner or manager only' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_community_members
     SET status = CASE WHEN p_approve THEN 'active' ELSE 'declined' END,
         joined_at = CASE WHEN p_approve THEN now() END, decided_by = auth.uid()
   WHERE community_id = c.id AND user_id = p_user_id AND status = 'pending';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RAISE EXCEPTION 'exos_community_decide: no pending request' USING ERRCODE = 'P0002'; END IF;
  RETURN CASE WHEN p_approve THEN 'active' ELSE 'declined' END;
END $$;
REVOKE ALL ON FUNCTION public.exos_community_decide(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_decide(uuid, uuid, boolean) TO authenticated, service_role;

-- Remove (can rejoin) or ban (can't) a member. Banning also works for someone
-- who never joined (pre-emptive), and revokes a host role in this community.
CREATE OR REPLACE FUNCTION public.exos_community_remove_member(p_community_id uuid, p_user_id uuid, p_ban boolean DEFAULT false,
                                                               p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE; v_n int;
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR NOT public._exos_comm_is_admin(c.org_id) THEN
    RAISE EXCEPTION 'exos_community_remove_member: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'exos_community_remove_member: you can''t remove yourself' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_ban, false) THEN
    INSERT INTO public.exos_community_members AS m (community_id, user_id, org_id, status, ban_reason, banned_at, decided_by,
                                                    notify_email, notify_sms)
    VALUES (c.id, p_user_id, c.org_id, 'banned', left(nullif(btrim(coalesce(p_reason, '')), ''), 300), now(), auth.uid(), false, false)
    ON CONFLICT (community_id, user_id) DO UPDATE
       SET status = 'banned', ban_reason = EXCLUDED.ban_reason, banned_at = now(), decided_by = auth.uid(),
           notify_email = false, notify_sms = false;
    UPDATE public.exos_community_hosts SET status = 'revoked', revoked_at = now()
     WHERE community_id = c.id AND user_id = p_user_id AND status <> 'revoked';
    RETURN 'banned';
  END IF;
  UPDATE public.exos_community_members SET status = 'removed', notify_email = false, notify_sms = false, decided_by = auth.uid()
   WHERE community_id = c.id AND user_id = p_user_id AND status IN ('active', 'pending');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RAISE EXCEPTION 'exos_community_remove_member: not a member' USING ERRCODE = 'P0002'; END IF;
  RETURN 'removed';
END $$;
REVOKE ALL ON FUNCTION public.exos_community_remove_member(uuid, uuid, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_remove_member(uuid, uuid, boolean, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_community_unban(p_community_id uuid, p_user_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE; v_n int;
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR NOT public._exos_comm_is_admin(c.org_id) THEN
    RAISE EXCEPTION 'exos_community_unban: owner or manager only' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_community_members SET status = 'removed', decided_by = auth.uid()
   WHERE community_id = c.id AND user_id = p_user_id AND status = 'banned';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_community_unban(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_unban(uuid, uuid) TO authenticated, service_role;

-- A member invite link (one person, or up to 500 uses). The token is returned
-- once; only its SHA-256 is kept.
CREATE OR REPLACE FUNCTION public.exos_community_invite(p_community_id uuid, p_email text DEFAULT NULL, p_max_uses integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE; v_token text; v_id uuid; v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR NOT public._exos_comm_is_admin(c.org_id) THEN
    RAISE EXCEPTION 'exos_community_invite: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF v_email IS NOT NULL AND v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RAISE EXCEPTION 'exos_community_invite: enter a valid email' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_community_invites WHERE community_id = c.id AND created_at > now() - interval '1 day') >= 100 THEN
    RAISE EXCEPTION 'exos_community_invite: at most 100 invites a day' USING ERRCODE = '54000';
  END IF;
  v_token := 'ecv_' || encode(extensions.gen_random_bytes(32), 'hex');
  INSERT INTO public.exos_community_invites (community_id, org_id, email, token_hash, max_uses, created_by)
  VALUES (c.id, c.org_id, v_email, public._exos_comm_token_hash(v_token),
          CASE WHEN v_email IS NOT NULL THEN 1 ELSE least(greatest(coalesce(p_max_uses, 1), 1), 500) END, auth.uid())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'token', v_token, 'path', '/c/' || c.slug || '?invite=' || v_token);
END $$;
REVOKE ALL ON FUNCTION public.exos_community_invite(uuid, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_invite(uuid, text, integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_community_revoke_invite(p_invite_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE i public.exos_community_invites%ROWTYPE;
BEGIN
  SELECT * INTO i FROM public.exos_community_invites WHERE id = p_invite_id;
  IF NOT FOUND OR NOT public._exos_comm_is_admin(i.org_id) THEN
    RAISE EXCEPTION 'exos_community_revoke_invite: owner or manager only' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_community_invites SET revoked_at = coalesce(revoked_at, now()) WHERE id = i.id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_community_revoke_invite(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_revoke_invite(uuid) TO authenticated, service_role;

-- Invite a host by email. They accept signed in with that email.
CREATE OR REPLACE FUNCTION public.exos_community_host_invite(p_community_id uuid, p_email text, p_display_name text,
                                                             p_host_org_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE; v_token text; v_id uuid; v_email text := lower(btrim(coalesce(p_email, '')));
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR NOT public._exos_comm_is_admin(c.org_id) THEN
    RAISE EXCEPTION 'exos_community_host_invite: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RAISE EXCEPTION 'exos_community_host_invite: enter a valid email' USING ERRCODE = '22023';
  END IF;
  IF char_length(btrim(coalesce(p_display_name, ''))) NOT BETWEEN 1 AND 80 THEN
    RAISE EXCEPTION 'exos_community_host_invite: give the host a name (up to 80 characters)' USING ERRCODE = '22023';
  END IF;
  IF p_host_org_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.exos_orgs WHERE id = p_host_org_id) THEN
    RAISE EXCEPTION 'exos_community_host_invite: organization not found' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_community_hosts WHERE community_id = c.id AND status <> 'revoked') >= 50 THEN
    RAISE EXCEPTION 'exos_community_host_invite: at most 50 hosts per community' USING ERRCODE = '54000';
  END IF;
  IF (SELECT count(*) FROM public.exos_community_hosts WHERE community_id = c.id AND created_at > now() - interval '1 day') >= 20 THEN
    RAISE EXCEPTION 'exos_community_host_invite: at most 20 host invites a day' USING ERRCODE = '54000';
  END IF;
  v_token := 'ech_' || encode(extensions.gen_random_bytes(32), 'hex');
  INSERT INTO public.exos_community_hosts (community_id, org_id, email, host_org_id, display_name, token_hash, invited_by)
  VALUES (c.id, c.org_id, v_email, p_host_org_id, btrim(p_display_name), public._exos_comm_token_hash(v_token), auth.uid())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'token', v_token, 'path', '/c/' || c.slug || '?host=' || v_token);
END $$;
REVOKE ALL ON FUNCTION public.exos_community_host_invite(uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_host_invite(uuid, text, text, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_community_host_revoke(p_host_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE h public.exos_community_hosts%ROWTYPE;
BEGIN
  SELECT * INTO h FROM public.exos_community_hosts WHERE id = p_host_id;
  IF NOT FOUND OR NOT (public._exos_comm_is_admin(h.org_id) OR (h.user_id = auth.uid() AND auth.uid() IS NOT NULL)) THEN
    RAISE EXCEPTION 'exos_community_host_revoke: owner or manager only' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_community_hosts SET status = 'revoked', revoked_at = now(), token_hash = NULL WHERE id = h.id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_community_host_revoke(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_host_revoke(uuid) TO authenticated, service_role;

-- Accept a host invite: signed in with the invited email (confirmed).
CREATE OR REPLACE FUNCTION public.exos_community_host_accept(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE h public.exos_community_hosts%ROWTYPE; v_uid uuid := auth.uid(); v_email text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'exos_community_host_accept: sign in first' USING ERRCODE = '42501'; END IF;
  SELECT * INTO h FROM public.exos_community_hosts
   WHERE token_hash = public._exos_comm_token_hash(p_token) AND status = 'invited' FOR UPDATE;
  IF NOT FOUND OR h.expires_at < now() THEN
    RAISE EXCEPTION 'exos_community_host_accept: this invite is not valid any more' USING ERRCODE = 'P0002';
  END IF;
  SELECT lower(email) INTO v_email FROM auth.users WHERE id = v_uid AND email_confirmed_at IS NOT NULL;
  IF v_email IS DISTINCT FROM h.email THEN
    RAISE EXCEPTION 'exos_community_host_accept: sign in with the email the invite was sent to' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_community_members WHERE community_id = h.community_id AND user_id = v_uid AND status = 'banned') THEN
    RAISE EXCEPTION 'exos_community_host_accept: this invite is not valid any more' USING ERRCODE = 'P0002';
  END IF;
  UPDATE public.exos_community_hosts SET status = 'revoked', revoked_at = now()
   WHERE community_id = h.community_id AND user_id = v_uid AND status = 'active' AND id <> h.id;
  UPDATE public.exos_community_hosts SET status = 'active', user_id = v_uid, accepted_at = now(), token_hash = NULL WHERE id = h.id;
  RETURN jsonb_build_object('community_id', h.community_id,
                            'slug', (SELECT slug FROM public.exos_communities WHERE id = h.community_id));
END $$;
REVOKE ALL ON FUNCTION public.exos_community_host_accept(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_host_accept(text) TO authenticated, service_role;

-- Add an event to a community. Owner / manager: their org's events. A host:
-- events of an org where they are owner / manager (their own), or drafts they
-- created in the community's org (exos_community_host_create_event).
CREATE OR REPLACE FUNCTION public.exos_community_add_event(p_community_id uuid, p_event_id uuid,
                                                           p_members_only boolean DEFAULT false,
                                                           p_early_access_until timestamptz DEFAULT NULL,
                                                           p_access_rule text DEFAULT 'community',
                                                           p_membership_product_ids uuid[] DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  c public.exos_communities%ROWTYPE; e public.exos_events%ROWTYPE;
  v_uid uuid := auth.uid(); v_host uuid; v_admin boolean; v_prods uuid[] := coalesce(p_membership_product_ids, '{}');
  v_res jsonb;
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR c.status <> 'active' THEN RAISE EXCEPTION 'exos_community_add_event: community not found' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = p_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'exos_community_add_event: event not found' USING ERRCODE = 'P0002'; END IF;
  v_admin := public._exos_comm_is_admin(c.org_id);
  v_host := public._exos_comm_host_id(c.id, v_uid);
  IF NOT ((v_admin AND e.org_id = c.org_id)
          OR (v_host IS NOT NULL AND (public.exos_has_org_role(e.org_id, ARRAY['owner','manager'])
                                      OR (e.org_id = c.org_id AND e.created_by = v_uid)))) THEN
    RAISE EXCEPTION 'exos_community_add_event: you can add your own events only' USING ERRCODE = '42501';
  END IF;
  IF coalesce(p_access_rule, 'community') NOT IN ('community', 'membership', 'either') THEN
    RAISE EXCEPTION 'exos_community_add_event: bad access rule' USING ERRCODE = '22023';
  END IF;
  -- Membership products must be the community org's (the seam is per org).
  IF cardinality(v_prods) > 0 THEN
    IF NOT v_admin THEN
      RAISE EXCEPTION 'exos_community_add_event: only the organizer can tie access to memberships' USING ERRCODE = '42501';
    END IF;
    IF to_regclass('public.exos_membership_products') IS NULL THEN
      RAISE EXCEPTION 'exos_community_add_event: memberships are not set up' USING ERRCODE = '22023';
    END IF;
    EXECUTE 'SELECT count(*) = cardinality($1) FROM public.exos_membership_products WHERE org_id = $2 AND id = ANY ($1)'
       INTO v_admin USING v_prods, c.org_id;
    IF NOT v_admin THEN RAISE EXCEPTION 'exos_community_add_event: pick your own membership products' USING ERRCODE = '22023'; END IF;
  ELSIF coalesce(p_access_rule, 'community') <> 'community' THEN
    RAISE EXCEPTION 'exos_community_add_event: pick the membership products' USING ERRCODE = '22023';
  END IF;
  IF p_early_access_until IS NOT NULL AND e.starts_at IS NOT NULL AND p_early_access_until > e.starts_at THEN
    RAISE EXCEPTION 'exos_community_add_event: early access has to end before the event starts' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_community_events WHERE community_id = c.id) >= 2000 THEN
    RAISE EXCEPTION 'exos_community_add_event: too many events in this community' USING ERRCODE = '54000';
  END IF;
  INSERT INTO public.exos_community_events AS ce (community_id, event_id, org_id, event_org_id, host_id, added_by, members_only,
                                                  early_access_until, access_rule, membership_product_ids)
  VALUES (c.id, e.id, c.org_id, e.org_id, v_host, v_uid, coalesce(p_members_only, false), p_early_access_until,
          coalesce(p_access_rule, 'community'), v_prods)
  ON CONFLICT (community_id, event_id) DO UPDATE
     SET members_only = EXCLUDED.members_only, early_access_until = EXCLUDED.early_access_until,
         access_rule = EXCLUDED.access_rule, membership_product_ids = EXCLUDED.membership_product_ids;
  v_res := public._exos_comm_announce_event(c.id, e.id);
  RETURN jsonb_build_object('added', true, 'announce', v_res);
END $$;
REVOKE ALL ON FUNCTION public.exos_community_add_event(uuid, uuid, boolean, timestamptz, text, uuid[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_add_event(uuid, uuid, boolean, timestamptz, text, uuid[]) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_community_remove_event(p_community_id uuid, p_event_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE ce public.exos_community_events%ROWTYPE; v_uid uuid := auth.uid();
BEGIN
  SELECT * INTO ce FROM public.exos_community_events WHERE community_id = p_community_id AND event_id = p_event_id;
  IF NOT FOUND THEN RETURN false; END IF;
  IF NOT (public._exos_comm_is_admin(ce.org_id)
          OR (ce.host_id IS NOT NULL AND ce.host_id = public._exos_comm_host_id(p_community_id, v_uid))) THEN
    RAISE EXCEPTION 'exos_community_remove_event: owner, manager or the host who added it' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.exos_community_events WHERE community_id = p_community_id AND event_id = p_event_id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_community_remove_event(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_remove_event(uuid, uuid) TO authenticated, service_role;

-- A host proposes an event in the community's org: a DRAFT the org's owner /
-- manager reviews, prices and publishes in the event editor. Hosts can't
-- publish, price or touch any other event of the org.
CREATE OR REPLACE FUNCTION public.exos_community_host_create_event(p_community_id uuid, p_name text, p_starts_at timestamptz,
                                                                   p_timezone text DEFAULT NULL, p_venue_name text DEFAULT NULL,
                                                                   p_venue_location text DEFAULT NULL, p_description text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE; v_uid uuid := auth.uid(); v_host uuid; v_id uuid;
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR c.status <> 'active' THEN RAISE EXCEPTION 'exos_community_host_create_event: community not found' USING ERRCODE = 'P0002'; END IF;
  v_host := public._exos_comm_host_id(c.id, v_uid);
  IF v_host IS NULL THEN
    RAISE EXCEPTION 'exos_community_host_create_event: hosts of this community only' USING ERRCODE = '42501';
  END IF;
  IF char_length(btrim(coalesce(p_name, ''))) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'exos_community_host_create_event: name the event (up to 120 characters)' USING ERRCODE = '22023';
  END IF;
  IF p_starts_at IS NULL OR p_starts_at < now() THEN
    RAISE EXCEPTION 'exos_community_host_create_event: pick a date in the future' USING ERRCODE = '22023';
  END IF;
  IF p_timezone IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = p_timezone) THEN
    RAISE EXCEPTION 'exos_community_host_create_event: unknown time zone' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_community_events ce JOIN public.exos_events e ON e.id = ce.event_id
       WHERE ce.host_id = v_host AND e.status = 'draft' AND ce.created_at > now() - interval '1 day') >= 5 THEN
    RAISE EXCEPTION 'exos_community_host_create_event: at most 5 proposed events a day' USING ERRCODE = '54000';
  END IF;
  INSERT INTO public.exos_events (org_id, name, status, starts_at, timezone, venue_name, venue_location, description, created_by)
  VALUES (c.org_id, btrim(p_name), 'draft', p_starts_at, p_timezone, left(nullif(btrim(coalesce(p_venue_name, '')), ''), 200),
          left(nullif(btrim(coalesce(p_venue_location, '')), ''), 300), left(nullif(btrim(coalesce(p_description, '')), ''), 5000), v_uid)
  RETURNING id INTO v_id;
  INSERT INTO public.exos_community_events (community_id, event_id, org_id, event_org_id, host_id, added_by)
  VALUES (c.id, v_id, c.org_id, c.org_id, v_host, v_uid);
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_community_host_create_event(uuid, text, timestamptz, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_host_create_event(uuid, text, timestamptz, text, text, text, text) TO authenticated, service_role;

-- Write a post (owner / manager / content of the org, or an active host).
CREATE OR REPLACE FUNCTION public.exos_community_post(p_community_id uuid, p_title text, p_body text,
                                                      p_visibility text DEFAULT 'public', p_notify boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  c public.exos_communities%ROWTYPE; v_uid uuid := auth.uid(); v_host uuid; v_id uuid;
  v_budget text; v_res jsonb := NULL; v_vis text := coalesce(p_visibility, 'public');
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id FOR UPDATE;
  IF NOT FOUND OR c.status <> 'active' THEN RAISE EXCEPTION 'exos_community_post: community not found' USING ERRCODE = 'P0002'; END IF;
  v_host := public._exos_comm_host_id(c.id, v_uid);
  IF v_uid IS NULL OR NOT (public.exos_has_org_role(c.org_id, ARRAY['owner','manager','content']) OR public.exos_is_admin()
                           OR v_host IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_community_post: the organizer and hosts post here' USING ERRCODE = '42501';
  END IF;
  IF v_vis NOT IN ('public', 'members') THEN RAISE EXCEPTION 'exos_community_post: bad visibility' USING ERRCODE = '22023'; END IF;
  IF char_length(btrim(coalesce(p_body, ''))) NOT BETWEEN 1 AND 5000 THEN
    RAISE EXCEPTION 'exos_community_post: write 1 to 5000 characters' USING ERRCODE = '22023';
  END IF;
  IF p_title IS NOT NULL AND char_length(btrim(p_title)) > 140 THEN
    RAISE EXCEPTION 'exos_community_post: titles are up to 140 characters' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_community_posts WHERE community_id = c.id AND author_uid = v_uid
         AND created_at > now() - interval '1 day') >= 10 THEN
    RAISE EXCEPTION 'exos_community_post: at most 10 posts a day' USING ERRCODE = '54000';
  END IF;
  IF (SELECT count(*) FROM public.exos_community_posts WHERE community_id = c.id AND created_at > now() - interval '1 day') >= 50 THEN
    RAISE EXCEPTION 'exos_community_post: this community has had 50 posts today' USING ERRCODE = '54000';
  END IF;
  INSERT INTO public.exos_community_posts (community_id, org_id, author_uid, host_id, title, body, visibility, notify)
  VALUES (c.id, c.org_id, v_uid, v_host, nullif(btrim(coalesce(p_title, '')), ''), btrim(p_body), v_vis, coalesce(p_notify, false))
  RETURNING id INTO v_id;
  IF coalesce(p_notify, false) THEN
    v_budget := public._exos_comm_post_budget(c.id);
    IF v_budget IS NULL THEN
      UPDATE public.exos_community_posts SET notified_at = now() WHERE id = v_id;
      v_res := public._exos_comm_notify(c.id, 'post', v_id);
    ELSE
      UPDATE public.exos_community_posts SET notify_note = 'not sent: ' || v_budget WHERE id = v_id;
    END IF;
  END IF;
  IF v_vis = 'public' THEN
    PERFORM public._exos_ap_enqueue(c.id, 'create_post', v_id);
  END IF;
  RETURN jsonb_build_object('id', v_id, 'notified', v_res, 'notify_note', v_budget);
END $$;
REVOKE ALL ON FUNCTION public.exos_community_post(uuid, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_post(uuid, text, text, text, boolean) TO authenticated, service_role;

-- Hide / remove / restore a post. Owner / manager; a host may hide or remove
-- their own post.
CREATE OR REPLACE FUNCTION public.exos_community_moderate_post(p_post_id uuid, p_action text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p public.exos_community_posts%ROWTYPE; v_new text; v_admin boolean;
BEGIN
  SELECT * INTO p FROM public.exos_community_posts WHERE id = p_post_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'exos_community_moderate_post: post not found' USING ERRCODE = 'P0002'; END IF;
  v_admin := public._exos_comm_is_admin(p.org_id);
  IF NOT (v_admin OR (p.author_uid = auth.uid() AND auth.uid() IS NOT NULL AND p_action IN ('hide', 'remove'))) THEN
    RAISE EXCEPTION 'exos_community_moderate_post: owner or manager only' USING ERRCODE = '42501';
  END IF;
  v_new := CASE p_action WHEN 'hide' THEN 'hidden' WHEN 'remove' THEN 'removed' WHEN 'restore' THEN 'published' END;
  IF v_new IS NULL THEN RAISE EXCEPTION 'exos_community_moderate_post: hide, remove or restore' USING ERRCODE = '22023'; END IF;
  UPDATE public.exos_community_posts SET status = v_new WHERE id = p.id;
  IF v_new <> 'published' AND p.status = 'published' AND p.visibility = 'public' THEN
    -- Not sent yet: drop it. Already out: send a Delete (Tombstone).
    UPDATE public.exos_ap_deliveries SET status = 'cancelled', lease_until = NULL
     WHERE dedupe_key = 'create_post:' || p.id AND status = 'queued';
    IF EXISTS (SELECT 1 FROM public.exos_ap_deliveries WHERE dedupe_key = 'create_post:' || p.id AND status IN ('sent', 'sending')) THEN
      PERFORM public._exos_ap_enqueue(p.community_id, 'delete_post', p.id);
    END IF;
  END IF;
  RETURN v_new;
END $$;
REVOKE ALL ON FUNCTION public.exos_community_moderate_post(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_moderate_post(uuid, text) TO authenticated, service_role;

-- Close a report: dismiss it, or hide / remove the post, or remove the post
-- and ban its author (a host's posts: revokes them as host).
CREATE OR REPLACE FUNCTION public.exos_community_resolve_report(p_report_id uuid, p_action text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.exos_community_reports%ROWTYPE; p public.exos_community_posts%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.exos_community_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND OR NOT public._exos_comm_is_admin(r.org_id) THEN
    RAISE EXCEPTION 'exos_community_resolve_report: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_action NOT IN ('dismiss', 'hide', 'remove', 'ban') THEN
    RAISE EXCEPTION 'exos_community_resolve_report: dismiss, hide, remove or ban' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO p FROM public.exos_community_posts WHERE id = r.post_id;
  IF p_action IN ('hide', 'remove', 'ban') THEN
    PERFORM public.exos_community_moderate_post(p.id, CASE WHEN p_action = 'hide' THEN 'hide' ELSE 'remove' END);
  END IF;
  IF p_action = 'ban' AND p.author_uid IS NOT NULL AND p.author_uid <> auth.uid()
     AND NOT EXISTS (SELECT 1 FROM public.exos_org_memberships m WHERE m.org_id = p.org_id AND m.user_id = p.author_uid
                        AND m.role IN ('owner','manager') AND m.disabled IS NOT TRUE) THEN
    PERFORM public.exos_community_remove_member(p.community_id, p.author_uid, true, 'post reported: ' || r.reason);
  END IF;
  -- Every open report on that post closes with the same action.
  UPDATE public.exos_community_reports
     SET status = CASE WHEN p_action = 'dismiss' THEN 'dismissed' ELSE 'resolved' END,
         action = p_action, resolved_by = auth.uid(), resolved_at = now()
   WHERE post_id = r.post_id AND (status = 'open' OR id = r.id);
  RETURN p_action;
END $$;
REVOKE ALL ON FUNCTION public.exos_community_resolve_report(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_resolve_report(uuid, text) TO authenticated, service_role;

-- Fediverse moderation: approve / reject a remote reply, block an actor or a
-- domain (also drops their follow and pending replies).
CREATE OR REPLACE FUNCTION public.exos_community_review_reply(p_reply_id uuid, p_approve boolean)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE x public.exos_ap_remote_replies%ROWTYPE;
BEGIN
  SELECT * INTO x FROM public.exos_ap_remote_replies WHERE id = p_reply_id FOR UPDATE;
  IF NOT FOUND OR NOT public._exos_comm_is_admin(x.org_id) THEN
    RAISE EXCEPTION 'exos_community_review_reply: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF x.status = 'deleted' THEN RETURN 'deleted'; END IF;
  UPDATE public.exos_ap_remote_replies
     SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END, reviewed_by = auth.uid(), reviewed_at = now()
   WHERE id = x.id;
  RETURN CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END;
END $$;
REVOKE ALL ON FUNCTION public.exos_community_review_reply(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_review_reply(uuid, boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._exos_ap_host_of(p_uri text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT lower(substring(p_uri FROM '^https://([^/:?#]+)'))
$$;
REVOKE ALL ON FUNCTION public._exos_ap_host_of(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._exos_ap_blocked(p_community_id uuid, p_actor_uri text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_ap_blocks b
                  WHERE b.community_id = p_community_id
                    AND (b.pattern = p_actor_uri
                         OR b.pattern = public._exos_ap_host_of(p_actor_uri)
                         OR public._exos_ap_host_of(p_actor_uri) LIKE '%.' || b.pattern))
$$;
REVOKE ALL ON FUNCTION public._exos_ap_blocked(uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_community_block_remote(p_community_id uuid, p_pattern text, p_block boolean DEFAULT true)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE; v_pat text := lower(btrim(coalesce(p_pattern, ''))); v_n int := 0;
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR NOT public._exos_comm_is_admin(c.org_id) THEN
    RAISE EXCEPTION 'exos_community_block_remote: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF char_length(v_pat) NOT BETWEEN 3 AND 500 OR v_pat !~ '^(https://[^[:space:]]+|[a-z0-9.-]+\.[a-z0-9-]+)$' THEN
    RAISE EXCEPTION 'exos_community_block_remote: an actor URL (https://…) or a domain' USING ERRCODE = '22023';
  END IF;
  IF NOT coalesce(p_block, true) THEN
    DELETE FROM public.exos_ap_blocks WHERE community_id = c.id AND pattern = v_pat;
    RETURN 0;
  END IF;
  INSERT INTO public.exos_ap_blocks (community_id, org_id, pattern, created_by)
  VALUES (c.id, c.org_id, v_pat, auth.uid()) ON CONFLICT DO NOTHING;
  UPDATE public.exos_ap_followers SET status = 'removed'
   WHERE community_id = c.id AND status = 'active' AND public._exos_ap_blocked(c.id, actor_uri);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE public.exos_ap_remote_replies SET status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now()
   WHERE community_id = c.id AND status = 'pending' AND public._exos_ap_blocked(c.id, actor_uri);
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_community_block_remote(uuid, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_block_remote(uuid, text, boolean) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. Member RPCs
-- ---------------------------------------------------------------------------
-- Join. p_notify_email / p_notify_sms are the channels the person chose, with
-- the consent text they saw (stored). Texts need an existing opt-in to the
-- org's texts (exos_sms_opt_in). Open: active at once. Approval: pending.
-- Invite: needs a valid invite token (an email invite only for that email).
CREATE OR REPLACE FUNCTION public.exos_community_join(p_community_id uuid, p_notify_email boolean DEFAULT false,
                                                      p_notify_sms boolean DEFAULT false, p_consent_text text DEFAULT NULL,
                                                      p_invite_token text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  c public.exos_communities%ROWTYPE; m public.exos_community_members%ROWTYPE; i public.exos_community_invites%ROWTYPE;
  v_uid uuid := auth.uid(); v_status text; v_text text := btrim(coalesce(p_consent_text, '')); v_email text;
  v_invite uuid := NULL;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'exos_community_join: sign in first' USING ERRCODE = '42501'; END IF;
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR c.status <> 'active' THEN RAISE EXCEPTION 'exos_community_join: community not found' USING ERRCODE = 'P0002'; END IF;
  SELECT * INTO m FROM public.exos_community_members WHERE community_id = c.id AND user_id = v_uid FOR UPDATE;
  IF FOUND AND m.status = 'banned' THEN
    RAISE EXCEPTION 'exos_community_join: you can''t join this community' USING ERRCODE = '42501';
  END IF;
  IF FOUND AND m.status IN ('active', 'pending') THEN
    RETURN jsonb_build_object('status', m.status);
  END IF;
  IF (SELECT count(*) FROM public.exos_community_members WHERE user_id = v_uid AND requested_at > now() - interval '1 day') >= 30 THEN
    RAISE EXCEPTION 'exos_community_join: too many joins today' USING ERRCODE = '54000';
  END IF;
  IF (coalesce(p_notify_email, false) OR coalesce(p_notify_sms, false)) AND char_length(v_text) NOT BETWEEN 20 AND 600 THEN
    RAISE EXCEPTION 'exos_community_join: missing consent text' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_notify_sms, false) AND NOT EXISTS (
       SELECT 1 FROM public.exos_sms_subscribers s WHERE s.org_id = c.org_id AND s.user_id = v_uid AND s.opted_out_at IS NULL) THEN
    RAISE EXCEPTION 'exos_community_join: sign up for this organizer''s texts first' USING ERRCODE = '22023';
  END IF;

  IF p_invite_token IS NOT NULL THEN
    SELECT * INTO i FROM public.exos_community_invites
     WHERE token_hash = public._exos_comm_token_hash(p_invite_token) AND community_id = c.id FOR UPDATE;
    IF NOT FOUND OR i.revoked_at IS NOT NULL OR i.expires_at < now() OR i.uses >= i.max_uses THEN
      RAISE EXCEPTION 'exos_community_join: this invite is not valid any more' USING ERRCODE = 'P0002';
    END IF;
    IF i.email IS NOT NULL THEN
      SELECT lower(email) INTO v_email FROM auth.users WHERE id = v_uid AND email_confirmed_at IS NOT NULL;
      IF v_email IS DISTINCT FROM i.email THEN
        RAISE EXCEPTION 'exos_community_join: sign in with the email the invite was sent to' USING ERRCODE = '42501';
      END IF;
    END IF;
    UPDATE public.exos_community_invites SET uses = uses + 1 WHERE id = i.id;
    v_invite := i.id;
    v_status := 'active';
  ELSIF c.join_mode = 'invite' THEN
    RAISE EXCEPTION 'exos_community_join: this community is invite only' USING ERRCODE = '42501';
  ELSIF c.join_mode = 'approval' THEN
    v_status := 'pending';
  ELSE
    v_status := 'active';
  END IF;

  INSERT INTO public.exos_community_members AS x (community_id, user_id, org_id, status, notify_email, notify_sms, consent_text,
                                                  consented_at, requested_at, joined_at, invite_id)
  VALUES (c.id, v_uid, c.org_id, v_status, coalesce(p_notify_email, false), coalesce(p_notify_sms, false), nullif(v_text, ''),
          CASE WHEN v_text <> '' THEN now() END, now(), CASE WHEN v_status = 'active' THEN now() END, v_invite)
  ON CONFLICT (community_id, user_id) DO UPDATE
     SET status = EXCLUDED.status, notify_email = EXCLUDED.notify_email, notify_sms = EXCLUDED.notify_sms,
         consent_text = EXCLUDED.consent_text, consented_at = EXCLUDED.consented_at, requested_at = now(),
         joined_at = EXCLUDED.joined_at, invite_id = EXCLUDED.invite_id, decided_by = NULL
   WHERE x.status NOT IN ('banned', 'active', 'pending');
  RETURN jsonb_build_object('status', v_status);
END $$;
REVOKE ALL ON FUNCTION public.exos_community_join(uuid, boolean, boolean, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_join(uuid, boolean, boolean, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_community_leave(p_community_id uuid)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH u AS (
    UPDATE public.exos_community_members SET status = 'left', notify_email = false, notify_sms = false
     WHERE community_id = p_community_id AND user_id = auth.uid() AND status IN ('active', 'pending')
    RETURNING 1)
  SELECT count(*) > 0 FROM u
$$;
REVOKE ALL ON FUNCTION public.exos_community_leave(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_leave(uuid) TO authenticated, service_role;

-- Change channels. Turning a channel on needs consent text again; off never does.
CREATE OR REPLACE FUNCTION public.exos_community_set_notify(p_community_id uuid, p_email boolean, p_sms boolean,
                                                            p_consent_text text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE m public.exos_community_members%ROWTYPE; v_text text := btrim(coalesce(p_consent_text, ''));
BEGIN
  SELECT * INTO m FROM public.exos_community_members WHERE community_id = p_community_id AND user_id = auth.uid() FOR UPDATE;
  IF NOT FOUND OR m.status NOT IN ('active', 'pending') THEN
    RAISE EXCEPTION 'exos_community_set_notify: join first' USING ERRCODE = 'P0002';
  END IF;
  IF ((coalesce(p_email, false) AND NOT m.notify_email) OR (coalesce(p_sms, false) AND NOT m.notify_sms))
     AND char_length(v_text) NOT BETWEEN 20 AND 600 THEN
    RAISE EXCEPTION 'exos_community_set_notify: missing consent text' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_sms, false) AND NOT m.notify_sms AND NOT EXISTS (
       SELECT 1 FROM public.exos_sms_subscribers s WHERE s.org_id = m.org_id AND s.user_id = m.user_id AND s.opted_out_at IS NULL) THEN
    RAISE EXCEPTION 'exos_community_set_notify: sign up for this organizer''s texts first' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_community_members
     SET notify_email = coalesce(p_email, false), notify_sms = coalesce(p_sms, false),
         consent_text = CASE WHEN v_text <> '' THEN v_text ELSE consent_text END,
         consented_at = CASE WHEN v_text <> '' THEN now() ELSE consented_at END
   WHERE community_id = m.community_id AND user_id = m.user_id;
  RETURN jsonb_build_object('notify_email', coalesce(p_email, false), 'notify_sms', coalesce(p_sms, false));
END $$;
REVOKE ALL ON FUNCTION public.exos_community_set_notify(uuid, boolean, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_set_notify(uuid, boolean, boolean, text) TO authenticated, service_role;

-- Report a post. Members and anyone signed in who can see it; once per post.
CREATE OR REPLACE FUNCTION public.exos_community_report(p_post_id uuid, p_reason text, p_note text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p public.exos_community_posts%ROWTYPE; v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'exos_community_report: sign in first' USING ERRCODE = '42501'; END IF;
  SELECT * INTO p FROM public.exos_community_posts WHERE id = p_post_id;
  IF NOT FOUND OR p.status <> 'published'
     OR (p.visibility = 'members' AND NOT public._exos_comm_insider(p.community_id, p.org_id, v_uid)) THEN
    RAISE EXCEPTION 'exos_community_report: post not found' USING ERRCODE = 'P0002';
  END IF;
  IF p_reason NOT IN ('spam', 'harassment', 'hate', 'sexual', 'violence', 'misleading', 'other') THEN
    RAISE EXCEPTION 'exos_community_report: pick a reason' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM public.exos_community_reports WHERE reporter_uid = v_uid AND created_at > now() - interval '1 day') >= 10 THEN
    RAISE EXCEPTION 'exos_community_report: too many reports today' USING ERRCODE = '54000';
  END IF;
  INSERT INTO public.exos_community_reports (post_id, community_id, org_id, reporter_uid, reason, note)
  VALUES (p.id, p.community_id, p.org_id, v_uid, p_reason, left(nullif(btrim(coalesce(p_note, '')), ''), 500))
  ON CONFLICT (post_id, reporter_uid) DO NOTHING;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_community_report(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_report(uuid, text, text) TO authenticated, service_role;

-- The communities the signed-in person is in, hosts, or runs.
CREATE OR REPLACE FUNCTION public.exos_my_communities()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(jsonb_agg(x ORDER BY x->>'name'), '[]'::jsonb) FROM (
    SELECT DISTINCT ON (c.id) jsonb_build_object('id', c.id, 'slug', c.slug, 'name', c.name, 'org_id', c.org_id,
             'status', (SELECT m.status FROM public.exos_community_members m WHERE m.community_id = c.id AND m.user_id = auth.uid()),
             'host', public._exos_comm_host_id(c.id, auth.uid()) IS NOT NULL,
             'admin', public.exos_has_org_role(c.org_id, ARRAY['owner','manager'])) AS x
      FROM public.exos_communities c
     WHERE auth.uid() IS NOT NULL AND c.status = 'active'
       AND (EXISTS (SELECT 1 FROM public.exos_community_members m WHERE m.community_id = c.id AND m.user_id = auth.uid()
                      AND m.status IN ('active', 'pending'))
            OR public._exos_comm_host_id(c.id, auth.uid()) IS NOT NULL
            OR public.exos_has_org_role(c.org_id, ARRAY['owner','manager','content']))
  ) q
$$;
REVOKE ALL ON FUNCTION public.exos_my_communities() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_my_communities() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. Public (anon) reads
-- ---------------------------------------------------------------------------
-- The community page. Unlisted communities answer by slug too (that's what
-- unlisted means); archived ones don't. Members-only posts only for insiders.
-- Member names are never public; the count is.
CREATE OR REPLACE FUNCTION public.exos_public_community(p_slug text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE; v_uid uuid := auth.uid(); v_in boolean; v_me jsonb := NULL;
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE slug = lower(btrim(coalesce(p_slug, ''))) AND status = 'active';
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_in := public._exos_comm_insider(c.id, c.org_id, v_uid);
  IF v_uid IS NOT NULL THEN
    SELECT jsonb_build_object('status', m.status, 'notify_email', m.notify_email, 'notify_sms', m.notify_sms)
      INTO v_me FROM public.exos_community_members m WHERE m.community_id = c.id AND m.user_id = v_uid;
    v_me := coalesce(v_me, '{}'::jsonb) || jsonb_build_object(
      'host', public._exos_comm_host_id(c.id, v_uid) IS NOT NULL,
      'admin', public.exos_has_org_role(c.org_id, ARRAY['owner','manager']),
      'sms_subscribed', EXISTS (SELECT 1 FROM public.exos_sms_subscribers s WHERE s.org_id = c.org_id AND s.user_id = v_uid
                                   AND s.opted_out_at IS NULL));
  END IF;
  RETURN jsonb_build_object(
    'id', c.id, 'slug', c.slug, 'ap_name', c.ap_name, 'name', c.name, 'tagline', c.tagline, 'about', c.about,
    'banner_url', c.banner_url, 'city', c.city, 'region', c.region, 'country', c.country, 'join_mode', c.join_mode,
    'visibility', c.visibility, 'federated', c.federation_enabled AND c.visibility = 'public',
    'org', (SELECT jsonb_build_object('id', o.id, 'name', o.name, 'slug', o.slug) FROM public.exos_orgs o WHERE o.id = c.org_id),
    'member_count', (SELECT count(*) FROM public.exos_community_members m WHERE m.community_id = c.id AND m.status = 'active'),
    'hosts', coalesce((SELECT jsonb_agg(jsonb_build_object('display_name', h.display_name,
                         'org', (SELECT jsonb_build_object('name', o.name, 'slug', o.slug) FROM public.exos_orgs o WHERE o.id = h.host_org_id))
                         ORDER BY h.accepted_at)
                         FROM public.exos_community_hosts h WHERE h.community_id = c.id AND h.status = 'active'), '[]'::jsonb),
    'upcoming', coalesce((SELECT jsonb_agg(x ORDER BY x->>'starts_at') FROM (
                         SELECT jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug, 'starts_at', e.starts_at,
                                  'timezone', e.timezone, 'venue_name', e.venue_name, 'venue_location', e.venue_location,
                                  'image_url', e.image_url, 'members_only', ce.members_only,
                                  'early_access_until', CASE WHEN ce.early_access_until > now() THEN ce.early_access_until END) AS x
                           FROM public.exos_community_events ce JOIN public.exos_events e ON e.id = ce.event_id
                          WHERE ce.community_id = c.id AND e.status = 'published'
                            AND coalesce(e.ends_at, e.starts_at, now()) >= now()
                          ORDER BY e.starts_at NULLS LAST LIMIT 50) q), '[]'::jsonb),
    'past', coalesce((SELECT jsonb_agg(x ORDER BY x->>'starts_at' DESC) FROM (
                         SELECT jsonb_build_object('id', e.id, 'name', e.name, 'slug', e.slug, 'starts_at', e.starts_at,
                                  'timezone', e.timezone, 'venue_name', e.venue_name, 'image_url', e.image_url) AS x
                           FROM public.exos_community_events ce JOIN public.exos_events e ON e.id = ce.event_id
                          WHERE ce.community_id = c.id AND e.status = 'published'
                            AND coalesce(e.ends_at, e.starts_at) < now()
                          ORDER BY e.starts_at DESC LIMIT 24) q), '[]'::jsonb),
    'posts', coalesce((SELECT jsonb_agg(x ORDER BY x->>'created_at' DESC) FROM (
                         SELECT jsonb_build_object('id', p.id, 'title', p.title, 'body', p.body, 'visibility', p.visibility,
                                  'created_at', p.created_at,
                                  'by', coalesce((SELECT h.display_name FROM public.exos_community_hosts h WHERE h.id = p.host_id),
                                                 (SELECT o.name FROM public.exos_orgs o WHERE o.id = c.org_id)),
                                  'replies', coalesce((SELECT jsonb_agg(jsonb_build_object('actor_name', r.actor_name,
                                                 'actor_handle', r.actor_handle, 'content_text', r.content_text, 'url', r.url,
                                                 'received_at', r.received_at) ORDER BY r.received_at)
                                               FROM public.exos_ap_remote_replies r WHERE r.post_id = p.id AND r.status = 'approved'), '[]'::jsonb)) AS x
                           FROM public.exos_community_posts p
                          WHERE p.community_id = c.id AND p.status = 'published' AND (p.visibility = 'public' OR v_in)
                          ORDER BY p.created_at DESC LIMIT 30) q), '[]'::jsonb),
    'me', v_me);
END $$;
REVOKE ALL ON FUNCTION public.exos_public_community(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_public_community(text) TO anon, authenticated, service_role;

-- The directory: public, active communities, by city (and a name search).
-- Also the city list with counts, for the city picker.
CREATE OR REPLACE FUNCTION public.exos_public_communities(p_city text DEFAULT NULL, p_query text DEFAULT NULL,
                                                          p_limit integer DEFAULT 24, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH base AS (
    SELECT c.* FROM public.exos_communities c
     WHERE c.status = 'active' AND c.visibility = 'public'
  ), hits AS (
    SELECT b.*, (SELECT count(*) FROM public.exos_community_members m WHERE m.community_id = b.id AND m.status = 'active') AS members,
           (SELECT min(e.starts_at) FROM public.exos_community_events ce JOIN public.exos_events e ON e.id = ce.event_id
             WHERE ce.community_id = b.id AND e.status = 'published' AND e.starts_at > now()) AS next_event_at
      FROM base b
     WHERE (nullif(btrim(coalesce(p_city, '')), '') IS NULL OR b.city_key = lower(btrim(p_city)))
       AND (nullif(btrim(coalesce(p_query, '')), '') IS NULL
            OR b.name ILIKE '%' || replace(replace(replace(left(btrim(p_query), 60), '\', '\\'), '%', '\%'), '_', '\_') || '%'
            OR b.tagline ILIKE '%' || replace(replace(replace(left(btrim(p_query), 60), '\', '\\'), '%', '\%'), '_', '\_') || '%')
  )
  SELECT jsonb_build_object(
    'cities', coalesce((SELECT jsonb_agg(jsonb_build_object('city', x.city, 'key', x.city_key, 'count', x.n) ORDER BY x.n DESC, x.city_key)
                          FROM (SELECT min(city) AS city, city_key, count(*) AS n FROM base WHERE city_key IS NOT NULL
                                 GROUP BY city_key ORDER BY count(*) DESC LIMIT 100) x), '[]'::jsonb),
    'total', (SELECT count(*) FROM hits),
    'items', coalesce((SELECT jsonb_agg(x) FROM (
               SELECT jsonb_build_object('slug', h.slug, 'name', h.name, 'tagline', h.tagline, 'banner_url', h.banner_url,
                        'city', h.city, 'region', h.region, 'country', h.country, 'join_mode', h.join_mode,
                        'member_count', h.members, 'next_event_at', h.next_event_at,
                        'org_name', (SELECT o.name FROM public.exos_orgs o WHERE o.id = h.org_id)) AS x
                 FROM hits h
                ORDER BY (h.next_event_at IS NULL), h.members DESC, h.name
                LIMIT least(greatest(coalesce(p_limit, 24), 1), 100) OFFSET greatest(coalesce(p_offset, 0), 0)) q), '[]'::jsonb))
$$;
REVOKE ALL ON FUNCTION public.exos_public_communities(text, text, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_public_communities(text, text, integer, integer) TO anon, authenticated, service_role;

-- The event page: which public communities list this event, and whether the
-- caller may buy right now (members-only / early access).
CREATE OR REPLACE FUNCTION public.exos_public_event_communities(p_event_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'communities', coalesce((SELECT jsonb_agg(jsonb_build_object('slug', c.slug, 'name', c.name, 'members_only', ce.members_only,
                        'early_access_until', CASE WHEN ce.early_access_until > now() THEN ce.early_access_until END,
                        'join_mode', c.join_mode) ORDER BY ce.created_at)
                       FROM public.exos_community_events ce JOIN public.exos_communities c ON c.id = ce.community_id
                      WHERE ce.event_id = p_event_id AND c.status = 'active'
                        AND (c.visibility = 'public' OR ce.members_only OR ce.early_access_until > now())), '[]'::jsonb),
    'access', public._exos_comm_gate(p_event_id, auth.uid()) - 'access_rule')
   WHERE EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = p_event_id AND e.status = 'published')
$$;
REVOKE ALL ON FUNCTION public.exos_public_event_communities(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_public_event_communities(uuid) TO anon, authenticated, service_role;

-- What an invite link is for (bearer token, ecv_/ech_ + 64 hex).
CREATE OR REPLACE FUNCTION public.exos_community_invite_preview(p_token text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT coalesce(
    (SELECT jsonb_build_object('kind', 'member', 'community', c.name, 'slug', c.slug,
              'valid', i.revoked_at IS NULL AND i.expires_at > now() AND i.uses < i.max_uses, 'for_email', i.email IS NOT NULL)
       FROM public.exos_community_invites i JOIN public.exos_communities c ON c.id = i.community_id
      WHERE p_token LIKE 'ecv\_%' AND i.token_hash = public._exos_comm_token_hash(p_token)),
    (SELECT jsonb_build_object('kind', 'host', 'community', c.name, 'slug', c.slug, 'display_name', h.display_name,
              'valid', h.status = 'invited' AND h.expires_at > now(), 'for_email', true)
       FROM public.exos_community_hosts h JOIN public.exos_communities c ON c.id = h.community_id
      WHERE p_token LIKE 'ech\_%' AND h.token_hash = public._exos_comm_token_hash(p_token)))
$$;
REVOKE ALL ON FUNCTION public.exos_community_invite_preview(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_invite_preview(text) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10. Members-only enforcement
-- ---------------------------------------------------------------------------
-- exos-checkout, before any hold or Stripe session (paid and free orders).
CREATE OR REPLACE FUNCTION public.exos_community_checkout_gate(p_event_id uuid, p_buyer uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public._exos_comm_gate(p_event_id, p_buyer)
$$;
REVOKE ALL ON FUNCTION public.exos_community_checkout_gate(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_community_checkout_gate(uuid, uuid) TO service_role;

-- Every ticket a signed-in person causes to be issued (free claims, RSVPs,
-- any client path): refused for a non-member. The org's door staff (comps,
-- guest lists, box office) and server-side inserts with no signed-in user
-- (checkout fulfillment, which exos-checkout gated before payment;
-- marketplace / feed orders the organizer set up) pass.
CREATE OR REPLACE FUNCTION public.exos_tg_ticket_community_gate()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := auth.uid(); v_gate jsonb;
BEGIN
  IF v_uid IS NULL THEN RETURN NEW; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_community_events ce WHERE ce.event_id = NEW.event_id
                   AND (ce.members_only OR ce.early_access_until > now())) THEN
    RETURN NEW;
  END IF;
  IF public.exos_has_org_role(NEW.org_id, ARRAY['owner','manager','scanner']) OR public.exos_is_admin() THEN RETURN NEW; END IF;
  v_gate := public._exos_comm_gate(NEW.event_id, v_uid);
  IF (v_gate->>'blocked')::boolean THEN
    RAISE EXCEPTION '%', v_gate->>'message' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_ticket_community_gate() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_community_gate ON public.exos_tickets;
CREATE TRIGGER exos_tickets_community_gate BEFORE INSERT ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_ticket_community_gate();

-- An event in a community gets published: announce it there.
CREATE OR REPLACE FUNCTION public.exos_tg_event_published_community()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  IF NEW.status = 'published' AND OLD.status IS DISTINCT FROM 'published' THEN
    FOR r IN SELECT community_id FROM public.exos_community_events WHERE event_id = NEW.id AND announced_at IS NULL LOOP
      BEGIN
        PERFORM public._exos_comm_announce_event(r.community_id, NEW.id);
      EXCEPTION WHEN others THEN
        -- Never fail a publish over an announcement.
        RAISE WARNING 'community announce failed for event %: %', NEW.id, SQLERRM;
      END;
    END LOOP;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_event_published_community() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_events_community_publish ON public.exos_events;
CREATE TRIGGER exos_events_community_publish AFTER UPDATE OF status ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_event_published_community();

-- ---------------------------------------------------------------------------
-- 11. Federation RPCs (service role: the exos-activitypub edge function)
-- ---------------------------------------------------------------------------
-- Resolve a WebFinger / actor name: a community (ap_name) or an org
-- ("org_" + slug with - as _), only while it has a federating community.
CREATE OR REPLACE FUNCTION public.exos_ap_lookup(p_name text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE; o public.exos_orgs%ROWTYPE; v_name text := lower(btrim(coalesce(p_name, '')));
BEGIN
  IF v_name !~ '^[a-z0-9_]{3,60}$' THEN RETURN NULL; END IF;
  IF v_name LIKE 'org\_%' THEN
    SELECT * INTO o FROM public.exos_orgs x
     WHERE replace(lower(x.slug), '-', '_') = substr(v_name, 5)
       AND EXISTS (SELECT 1 FROM public.exos_communities k WHERE k.org_id = x.id AND k.federation_enabled
                      AND k.visibility = 'public' AND k.status = 'active')
     LIMIT 1;
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN jsonb_build_object('kind', 'org', 'ap_name', v_name, 'org_id', o.id, 'name', o.name, 'slug', o.slug,
      'actor_id', (SELECT a.id FROM public.exos_ap_actors a WHERE a.kind = 'org' AND a.org_id = o.id),
      'public_key_pem', (SELECT a.public_key_pem FROM public.exos_ap_actors a WHERE a.kind = 'org' AND a.org_id = o.id));
  END IF;
  SELECT * INTO c FROM public.exos_communities
   WHERE ap_name = v_name AND federation_enabled AND visibility = 'public' AND status = 'active';
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('kind', 'community', 'ap_name', c.ap_name, 'community_id', c.id, 'org_id', c.org_id,
    'slug', c.slug, 'name', c.name, 'tagline', c.tagline, 'about', c.about, 'banner_url', c.banner_url,
    'city', c.city, 'join_mode', c.join_mode, 'created_at', c.created_at,
    'org', (SELECT jsonb_build_object('name', x.name, 'slug', x.slug) FROM public.exos_orgs x WHERE x.id = c.org_id),
    'followers', (SELECT count(*) FROM public.exos_ap_followers f WHERE f.community_id = c.id AND f.status = 'active'),
    'members', (SELECT count(*) FROM public.exos_community_members m WHERE m.community_id = c.id AND m.status = 'active'),
    'actor_id', (SELECT a.id FROM public.exos_ap_actors a WHERE a.community_id = c.id),
    'public_key_pem', (SELECT a.public_key_pem FROM public.exos_ap_actors a WHERE a.community_id = c.id));
END $$;
REVOKE ALL ON FUNCTION public.exos_ap_lookup(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_lookup(text) TO service_role;

-- Store a freshly generated key pair for an actor (first one wins; a loser of
-- the race gets the winner's public key back and its own private key is not
-- stored). The private key goes to Vault only.
CREATE OR REPLACE FUNCTION public.exos_ap_store_key(p_kind text, p_ref uuid, p_public_pem text, p_private_pem text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a public.exos_ap_actors%ROWTYPE; v_org uuid; v_secret uuid; v_id uuid := gen_random_uuid();
BEGIN
  IF p_kind NOT IN ('community', 'org') OR p_ref IS NULL THEN RAISE EXCEPTION 'exos_ap_store_key: bad actor' USING ERRCODE = '22023'; END IF;
  IF p_public_pem NOT LIKE '-----BEGIN PUBLIC KEY-----%' OR p_private_pem NOT LIKE '-----BEGIN PRIVATE KEY-----%' THEN
    RAISE EXCEPTION 'exos_ap_store_key: PEM (SPKI / PKCS#8) expected' USING ERRCODE = '22023';
  END IF;
  IF p_kind = 'community' THEN
    SELECT org_id INTO v_org FROM public.exos_communities WHERE id = p_ref;
  ELSE
    SELECT id INTO v_org FROM public.exos_orgs WHERE id = p_ref;
  END IF;
  IF v_org IS NULL THEN RAISE EXCEPTION 'exos_ap_store_key: actor not found' USING ERRCODE = 'P0002'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('exos_ap_key:' || p_kind || ':' || p_ref));
  SELECT * INTO a FROM public.exos_ap_actors
   WHERE (p_kind = 'community' AND community_id = p_ref) OR (p_kind = 'org' AND kind = 'org' AND org_id = p_ref);
  IF FOUND THEN RETURN jsonb_build_object('actor_id', a.id, 'public_key_pem', a.public_key_pem, 'created', false); END IF;
  v_secret := vault.create_secret(p_private_pem, 'exos_ap_key:' || v_id, 'Exos ActivityPub actor signing key (RSA, PKCS#8)');
  INSERT INTO public.exos_ap_actors (id, org_id, kind, community_id, public_key_pem, key_secret_id)
  VALUES (v_id, v_org, p_kind, CASE WHEN p_kind = 'community' THEN p_ref END, p_public_pem, v_secret);
  RETURN jsonb_build_object('actor_id', v_id, 'public_key_pem', p_public_pem, 'created', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_ap_store_key(text, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_store_key(text, uuid, text, text) TO service_role;

-- The private key, for signing a delivery. Service role only.
CREATE OR REPLACE FUNCTION public.exos_ap_signing_key(p_actor_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT d.decrypted_secret FROM public.exos_ap_actors a JOIN vault.decrypted_secrets d ON d.id = a.key_secret_id
   WHERE a.id = p_actor_id
$$;
REVOKE ALL ON FUNCTION public.exos_ap_signing_key(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_signing_key(uuid) TO service_role;

-- One object for the federation: a public post or event of a federating
-- community. NULL otherwise (removed posts answer 'gone' so a Tombstone can
-- be served).
CREATE OR REPLACE FUNCTION public.exos_ap_object(p_kind text, p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF p_kind = 'post' THEN
    SELECT jsonb_build_object('kind', 'post', 'id', p.id, 'title', p.title, 'body', p.body, 'created_at', p.created_at,
             'updated_at', p.updated_at, 'gone', p.status <> 'published',
             'community', jsonb_build_object('id', c.id, 'ap_name', c.ap_name, 'slug', c.slug, 'name', c.name),
             'org', jsonb_build_object('id', o.id, 'slug', o.slug, 'name', o.name),
             'host', (SELECT h.display_name FROM public.exos_community_hosts h WHERE h.id = p.host_id))
      INTO v
      FROM public.exos_community_posts p JOIN public.exos_communities c ON c.id = p.community_id
      JOIN public.exos_orgs o ON o.id = c.org_id
     WHERE p.id = p_id AND p.visibility = 'public' AND c.federation_enabled AND c.visibility = 'public' AND c.status = 'active';
  ELSIF p_kind = 'event' THEN
    SELECT jsonb_build_object('kind', 'event', 'id', e.id, 'name', e.name, 'slug', e.slug, 'description', left(e.description, 2000),
             'starts_at', e.starts_at, 'ends_at', e.ends_at, 'timezone', e.timezone, 'venue_name', e.venue_name,
             'venue_location', e.venue_location, 'image_url', e.image_url, 'created_at', ce.created_at,
             'updated_at', e.updated_at, 'gone', e.status <> 'published',
             'community', jsonb_build_object('id', c.id, 'ap_name', c.ap_name, 'slug', c.slug, 'name', c.name),
             'org', jsonb_build_object('id', o.id, 'slug', o.slug, 'name', o.name))
      INTO v
      FROM public.exos_community_events ce JOIN public.exos_communities c ON c.id = ce.community_id
      JOIN public.exos_events e ON e.id = ce.event_id JOIN public.exos_orgs o ON o.id = c.org_id
     WHERE ce.event_id = p_id AND NOT ce.members_only AND e.status IN ('published', 'cancelled')
       AND c.federation_enabled AND c.visibility = 'public' AND c.status = 'active'
     ORDER BY ce.created_at LIMIT 1;
  END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public.exos_ap_object(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_object(text, uuid) TO service_role;

-- The outbox: newest public posts and events (not members-only), 20 a page.
CREATE OR REPLACE FUNCTION public.exos_ap_outbox(p_community_id uuid, p_before timestamptz DEFAULT NULL, p_limit integer DEFAULT 20)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH items AS (
    SELECT 'post' AS kind, p.id, p.created_at AS at FROM public.exos_community_posts p
     WHERE p.community_id = p_community_id AND p.status = 'published' AND p.visibility = 'public'
    UNION ALL
    SELECT 'event', ce.event_id, ce.created_at FROM public.exos_community_events ce JOIN public.exos_events e ON e.id = ce.event_id
     WHERE ce.community_id = p_community_id AND NOT ce.members_only AND e.status = 'published'
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM items),
    'items', coalesce((SELECT jsonb_agg(public.exos_ap_object(i.kind, i.id) ORDER BY i.at DESC) FROM (
               SELECT * FROM items WHERE p_before IS NULL OR at < p_before ORDER BY at DESC
                LIMIT least(greatest(coalesce(p_limit, 20), 1), 50)) i), '[]'::jsonb))
   WHERE EXISTS (SELECT 1 FROM public.exos_communities c WHERE c.id = p_community_id AND c.federation_enabled
                    AND c.visibility = 'public' AND c.status = 'active')
$$;
REVOKE ALL ON FUNCTION public.exos_ap_outbox(uuid, timestamptz, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_outbox(uuid, timestamptz, integer) TO service_role;

-- Remote actor cache.
CREATE OR REPLACE FUNCTION public.exos_ap_remote_actor(p_actor_uri text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(r) FROM public.exos_ap_remote_actors r WHERE r.actor_uri = p_actor_uri AND r.fetched_at > now() - interval '1 day'
$$;
REVOKE ALL ON FUNCTION public.exos_ap_remote_actor(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_remote_actor(text) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_ap_remote_actor_put(p_actor_uri text, p_key_id text, p_public_key_pem text, p_inbox text,
                                                           p_shared_inbox text, p_handle text, p_name text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  INSERT INTO public.exos_ap_remote_actors (actor_uri, key_id, public_key_pem, inbox_uri, shared_inbox_uri, handle, name, fetched_at)
  VALUES (p_actor_uri, p_key_id, p_public_key_pem, p_inbox, p_shared_inbox, left(p_handle, 200), left(p_name, 120), now())
  ON CONFLICT (actor_uri) DO UPDATE
     SET key_id = EXCLUDED.key_id, public_key_pem = EXCLUDED.public_key_pem, inbox_uri = EXCLUDED.inbox_uri,
         shared_inbox_uri = EXCLUDED.shared_inbox_uri, handle = EXCLUDED.handle, name = EXCLUDED.name, fetched_at = now()
$$;
REVOKE ALL ON FUNCTION public.exos_ap_remote_actor_put(text, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_remote_actor_put(text, text, text, text, text, text, text) TO service_role;

-- Inbox: Follow. Accepted for any public federating community unless the
-- actor / domain is blocked; queues the Accept. At most 5,000 followers.
CREATE OR REPLACE FUNCTION public.exos_ap_follow(p_community_id uuid, p_actor_uri text, p_inbox text, p_shared_inbox text,
                                                 p_follow jsonb, p_software text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c public.exos_communities%ROWTYPE; v_follow_id text := left(p_follow->>'id', 500);
BEGIN
  SELECT * INTO c FROM public.exos_communities WHERE id = p_community_id;
  IF NOT FOUND OR NOT c.federation_enabled OR c.visibility <> 'public' OR c.status <> 'active' THEN RETURN 'not_found'; END IF;
  IF public._exos_ap_blocked(c.id, p_actor_uri) THEN RETURN 'blocked'; END IF;
  IF (SELECT count(*) FROM public.exos_ap_followers WHERE community_id = c.id AND status = 'active') >= 5000
     AND NOT EXISTS (SELECT 1 FROM public.exos_ap_followers WHERE community_id = c.id AND actor_uri = p_actor_uri AND status = 'active') THEN
    RETURN 'full';
  END IF;
  INSERT INTO public.exos_ap_followers AS f (community_id, org_id, actor_uri, inbox_uri, shared_inbox_uri, follow_activity_id, software, status)
  VALUES (c.id, c.org_id, p_actor_uri, p_inbox, p_shared_inbox, v_follow_id,
          CASE WHEN p_software ~ '^[a-z0-9._-]{1,40}$' THEN p_software END, 'active')
  ON CONFLICT (community_id, actor_uri) DO UPDATE
     SET inbox_uri = EXCLUDED.inbox_uri, shared_inbox_uri = EXCLUDED.shared_inbox_uri,
         follow_activity_id = EXCLUDED.follow_activity_id, software = coalesce(EXCLUDED.software, f.software), status = 'active';
  -- Accept goes to the follower's own inbox. A repeated Follow (new id) gets a new Accept.
  INSERT INTO public.exos_ap_deliveries (org_id, community_id, kind, ref_id, dedupe_key, payload, inbox_uri)
  VALUES (c.org_id, c.id, 'accept', NULL, 'accept:' || coalesce(v_follow_id, p_actor_uri),
          jsonb_build_object('id', v_follow_id, 'type', 'Follow', 'actor', p_actor_uri, 'object', p_follow->'object'), p_inbox)
  ON CONFLICT (dedupe_key, inbox_uri) DO NOTHING;
  RETURN 'accepted';
END $$;
REVOKE ALL ON FUNCTION public.exos_ap_follow(uuid, text, text, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_follow(uuid, text, text, text, jsonb, text) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_ap_unfollow(p_community_id uuid, p_actor_uri text)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH u AS (UPDATE public.exos_ap_followers SET status = 'removed'
              WHERE (p_community_id IS NULL OR community_id = p_community_id) AND actor_uri = p_actor_uri AND status = 'active'
             RETURNING 1)
  SELECT count(*) > 0 FROM u
$$;
REVOKE ALL ON FUNCTION public.exos_ap_unfollow(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_unfollow(uuid, text) TO service_role;

-- Inbox: a reply (Create Note with inReplyTo one of our objects). Goes to the
-- moderation queue. 20 an hour per remote actor; 500 pending per community.
CREATE OR REPLACE FUNCTION public.exos_ap_record_reply(p_kind text, p_target uuid, p_activity_id text, p_object_id text,
                                                       p_actor_uri text, p_actor_name text, p_actor_handle text,
                                                       p_content text, p_url text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_obj jsonb := public.exos_ap_object(p_kind, p_target); v_comm uuid; v_org uuid; v_text text;
BEGIN
  IF v_obj IS NULL OR (v_obj->>'gone')::boolean THEN RETURN 'not_found'; END IF;
  v_comm := (v_obj->'community'->>'id')::uuid;
  SELECT org_id INTO v_org FROM public.exos_communities WHERE id = v_comm;
  IF public._exos_ap_blocked(v_comm, p_actor_uri) THEN RETURN 'blocked'; END IF;
  v_text := left(btrim(coalesce(p_content, '')), 5000);
  IF v_text = '' THEN RETURN 'empty'; END IF;
  IF (SELECT count(*) FROM public.exos_ap_remote_replies WHERE actor_uri = p_actor_uri AND received_at > now() - interval '1 hour') >= 20 THEN
    RETURN 'rate_limited';
  END IF;
  IF (SELECT count(*) FROM public.exos_ap_remote_replies WHERE community_id = v_comm AND status = 'pending') >= 500 THEN
    RETURN 'queue_full';
  END IF;
  INSERT INTO public.exos_ap_remote_replies (community_id, org_id, post_id, event_id, activity_id, object_id, actor_uri,
                                             actor_name, actor_handle, content_text, url)
  VALUES (v_comm, v_org, CASE WHEN p_kind = 'post' THEN p_target END, CASE WHEN p_kind = 'event' THEN p_target END,
          left(p_activity_id, 500), p_object_id, p_actor_uri, left(p_actor_name, 120), left(p_actor_handle, 200), v_text,
          CASE WHEN p_url ~ '^https://' AND char_length(p_url) <= 500 THEN p_url END)
  ON CONFLICT (object_id) DO NOTHING;
  RETURN CASE WHEN FOUND THEN 'queued' ELSE 'duplicate' END;
END $$;
REVOKE ALL ON FUNCTION public.exos_ap_record_reply(text, uuid, text, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_record_reply(text, uuid, text, text, text, text, text, text, text) TO service_role;

-- Inbox: Delete of a reply (only by its own author) or of an actor.
CREATE OR REPLACE FUNCTION public.exos_ap_remote_delete(p_actor_uri text, p_object_id text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_n int := 0; v_m int := 0;
BEGIN
  IF p_object_id = p_actor_uri THEN
    UPDATE public.exos_ap_followers SET status = 'removed' WHERE actor_uri = p_actor_uri AND status = 'active';
    GET DIAGNOSTICS v_m = ROW_COUNT;
    UPDATE public.exos_ap_remote_replies SET status = 'deleted' WHERE actor_uri = p_actor_uri AND status <> 'deleted';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    DELETE FROM public.exos_ap_remote_actors WHERE actor_uri = p_actor_uri;
    RETURN v_n + v_m;
  END IF;
  UPDATE public.exos_ap_remote_replies SET status = 'deleted' WHERE object_id = p_object_id AND actor_uri = p_actor_uri AND status <> 'deleted';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_ap_remote_delete(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_remote_delete(text, text) TO service_role;

-- Delivery claim: due rows with a 2-minute lease. A delivery whose community
-- stopped federating is cancelled here. Returns what the sender needs: the
-- signing actor (the community's Group) and the community's names.
CREATE OR REPLACE FUNCTION public.exos_ap_claim(p_limit integer DEFAULT 25)
RETURNS TABLE (id uuid, kind text, ref_id uuid, style text, payload jsonb, inbox_uri text, attempts integer,
               community_id uuid, ap_name text, actor_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE public.exos_ap_deliveries d SET status = 'cancelled', lease_until = NULL
    FROM public.exos_communities c
   WHERE c.id = d.community_id AND d.status IN ('queued', 'sending')
     AND (NOT c.federation_enabled OR c.visibility <> 'public' OR c.status <> 'active');
  RETURN QUERY
  WITH due AS (
    SELECT d.id FROM public.exos_ap_deliveries d
     WHERE (d.status = 'queued' OR (d.status = 'sending' AND d.lease_until < now()))
       AND d.next_attempt_at <= now()
     ORDER BY d.next_attempt_at
     LIMIT least(greatest(coalesce(p_limit, 25), 1), 100)
     FOR UPDATE OF d SKIP LOCKED
  )
  UPDATE public.exos_ap_deliveries d
     SET status = 'sending', attempts = d.attempts + 1, lease_until = now() + interval '2 minutes'
    FROM due, public.exos_communities c
   WHERE d.id = due.id AND c.id = d.community_id
  RETURNING d.id, d.kind, d.ref_id, d.style, d.payload, d.inbox_uri, d.attempts, d.community_id, c.ap_name,
            (SELECT a.id FROM public.exos_ap_actors a WHERE a.community_id = d.community_id);
END $$;
REVOKE ALL ON FUNCTION public.exos_ap_claim(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_claim(integer) TO service_role;

-- Delivery result. Backoff: 1, 5, 30 min, 2, 6, 12, 24 h; dead after 8
-- attempts, or at once on a permanent failure (4xx other than 408 / 429, a
-- blocked URL, or nothing left to send).
CREATE OR REPLACE FUNCTION public.exos_ap_mark(p_id uuid, p_ok boolean, p_status integer DEFAULT NULL,
                                               p_error text DEFAULT NULL, p_permanent boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE d public.exos_ap_deliveries%ROWTYPE; v_next text;
BEGIN
  SELECT * INTO d FROM public.exos_ap_deliveries WHERE id = p_id AND status = 'sending' FOR UPDATE;
  IF NOT FOUND THEN RETURN 'ignored'; END IF;
  IF p_ok THEN
    v_next := 'sent';
  ELSIF coalesce(p_permanent, false) OR d.attempts >= 8
        OR (p_status BETWEEN 400 AND 499 AND p_status NOT IN (408, 429)) THEN
    v_next := 'dead';
  ELSE
    v_next := 'queued';
  END IF;
  UPDATE public.exos_ap_deliveries
     SET status = v_next, lease_until = NULL, last_status = p_status, last_error = left(p_error, 300),
         sent_at = CASE WHEN v_next = 'sent' THEN now() END,
         next_attempt_at = CASE WHEN v_next = 'queued' THEN now() + (CASE least(d.attempts, 7)
                                  WHEN 1 THEN interval '1 minute' WHEN 2 THEN interval '5 minutes'
                                  WHEN 3 THEN interval '30 minutes' WHEN 4 THEN interval '2 hours'
                                  WHEN 5 THEN interval '6 hours' WHEN 6 THEN interval '12 hours'
                                  ELSE interval '24 hours' END) ELSE d.next_attempt_at END
   WHERE id = d.id;
  -- A follower whose inbox is gone (410) is dropped.
  IF p_status = 410 THEN
    UPDATE public.exos_ap_followers SET status = 'removed'
     WHERE community_id = d.community_id AND (inbox_uri = d.inbox_uri OR shared_inbox_uri = d.inbox_uri) AND status = 'active';
  END IF;
  RETURN v_next;
END $$;
REVOKE ALL ON FUNCTION public.exos_ap_mark(uuid, boolean, integer, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_ap_mark(uuid, boolean, integer, text, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- 12. Delivery cron: created INACTIVE. The operator turns it on together with
--     EXOS_FEDERATION=on: SELECT cron.alter_job(jobid, active := true)
--       FROM cron.job WHERE jobname = 'exos-ap-deliver-1min';
--     A re-run keeps whatever the operator set.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_job bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND to_regprocedure('public._cron_invoke_edge_fn(text, jsonb)') IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos-ap-deliver-1min') THEN
      RETURN;
    END IF;
    v_job := cron.schedule('exos-ap-deliver-1min', '* * * * *', $cron$
      SELECT public._cron_invoke_edge_fn(
        coalesce(nullif(current_setting('app.exos_functions_url', true), ''),
                 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1') || '/exos-activitypub/deliver', '{}'::jsonb);
    $cron$);
    PERFORM cron.alter_job(v_job, active := false);
  END IF;
END $$;
