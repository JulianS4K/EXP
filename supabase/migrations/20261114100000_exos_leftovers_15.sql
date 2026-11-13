-- ============================================================================
-- Migration 20261114100000 — Exos (Bridge / D4): wave-15 leftovers (Discord + kiosk)
-- Branch:   claude/exos-wave15-leftovers
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_discord_links (+reminder_hours: 24, 48 or NULL = off)
--           C: TABLE exos_discord_deletes (a Discord scheduled event to take down
--              because its Exos event was deleted: the server and event id
--              recorded before the delete). RLS on, no client grants.
--           C: FUNCTION exos_discord_set_reminder (authenticated; role checked
--              here); exos_discord_reminder_queue, exos_discord_delete_claim,
--              exos_discord_delete_mark, exos_discord_test_begin,
--              exos_discord_webhook_refused (service role only)
--           C: TRIGGER exos_events_zz_discord_del (exos_tg_discord_event_delete):
--              BEFORE DELETE on exos_events, records the scheduled event Exos made
--           W: FUNCTION exos_discord_status, exos_discord_event_status
--              (marker /* exos: discord reminder status */: + reminder_hours),
--              exos_discord_sync_mark (marker /* exos: discord delete race */:
--              a create that raced the event's delete queues its delete),
--              _exos_print_mint (marker /* exos: print kiosk limit */),
--              _exos_pos_kiosk_codes (marker /* exos: pos kiosk print limit */)
--           R: exos_events, exos_discord_posts, exos_discord_event_syncs,
--              exos_rate_hit, exos_rate_windows, _exos_discord_blocked,
--              _exos_discord_role, _exos_audit, vault.decrypted_secrets
-- Pre-reqs: 20261113130000 (Discord), 20261113100000 (kiosk),
--           20261105120000 (_exos_print_mint), 20261109100000 (_exos_audit).
--
-- Waves 13 and 14 follow-ups (docs/discord.md, docs/pos.md "Kiosk mode"):
--
--   1. Automatic reminder. An owner / manager picks 24 or 48 hours (off by
--      default). The existing exos-discord cron pass (exos-discord-2min, no
--      new job) calls exos_discord_reminder_queue first: it queues the
--      'reminder' announcement for a published event that starts within that
--      many hours and hasn't started, once per event (the posts table's
--      UNIQUE (event_id, kind): a reminder already asked for with the button,
--      even a dry run or a failed one, is never queued again). It counts
--      against the button's limits (10 requests a minute, 30 posts an hour per
--      org) and then goes through the same claim / mark: the breaker, the
--      org's pause, the webhook checks and the dry-run gate. No reminder when
--      the publish announcement itself went out inside the window (it would
--      repeat it).
--   2. Deleting an Exos event deletes its Discord event. A BEFORE DELETE
--      trigger records the server and the scheduled event id (the sync row is
--      cascade-deleted with the event) in exos_discord_deletes, only for an
--      event Exos made on the server the org is linked to now. The cron pass
--      then sends the allowlisted DELETE /guilds/{guild}/scheduled-events/{id}
--      (bound to that server), with the same breaker, pause, 20-a-minute and
--      dry-run gates as the scheduled-event pass. A cancelled event keeps the
--      cancel path. "Disconnect server" still leaves events there: a delete
--      for a server that's no longer linked is skipped.
--   3. "Send a test" for the channel webhook: exos_discord_test_begin checks
--      the role (owner / manager), the webhook, the breaker and the org's
--      pause, then 3 tests an hour per org, audits discord.webhook_test and
--      hands the token to the edge function only (service role). A dry run
--      unless writes are on.
--   4. Kiosk prints counted per kiosk session: _exos_print_mint's 60 a minute
--      is keyed on the kiosk session when _exos_pos_kiosk_codes sets
--      exos.pos_kiosk_session (as the card begin's /* exos: pos kiosk card
--      limit */), so a kiosk never uses up its starter's door-app prints.
--
-- Re-run safe (IF NOT EXISTS, CREATE OR REPLACE, guarded constraint, marker
-- checked patches). D4 authors; applying to prod is operator-gated. NOT applied.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := pg_get_functiondef(p_fn);
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> p_hits THEN
    RAISE EXCEPTION '%: expected % match(es) for patch "%", found %', p_fn, p_hits, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- ===========================================================================
-- 1. The automatic reminder
-- ===========================================================================
ALTER TABLE public.exos_discord_links ADD COLUMN IF NOT EXISTS reminder_hours integer;
DO $c$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_discord_links_reminder_chk') THEN
    ALTER TABLE public.exos_discord_links ADD CONSTRAINT exos_discord_links_reminder_chk
      CHECK (reminder_hours IS NULL OR reminder_hours IN (24, 48));
  END IF;
END $c$;
COMMENT ON COLUMN public.exos_discord_links.reminder_hours IS
  'Post the reminder announcement this many hours before each published event starts (24 or 48); NULL = off. mig 20261114100000.';

-- Owner / manager: the automatic reminder, 24 or 48 hours before the start,
-- or NULL for off. 10 changes a minute per user (the webhook's limit).
CREATE OR REPLACE FUNCTION public.exos_discord_set_reminder(p_org_id uuid, p_hours integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_old integer;
BEGIN
  IF public._exos_discord_role(p_org_id, v_uid) IS NULL THEN
    RAISE EXCEPTION 'exos_discord_set_reminder: owner or manager only' USING ERRCODE = '42501';
  END IF;
  IF p_hours IS NOT NULL AND p_hours NOT IN (24, 48) THEN
    RAISE EXCEPTION 'exos_discord_set_reminder: 24 or 48 hours, or off' USING ERRCODE = '22023';
  END IF;
  IF NOT public.exos_rate_hit('discord_cfg:' || v_uid::text, 10) THEN
    RAISE EXCEPTION 'exos_discord_set_reminder: too many changes, try again in a minute' USING ERRCODE = '54000';
  END IF;
  INSERT INTO public.exos_discord_links (org_id) VALUES (p_org_id) ON CONFLICT (org_id) DO NOTHING;
  SELECT reminder_hours INTO v_old FROM public.exos_discord_links WHERE org_id = p_org_id FOR UPDATE;
  IF v_old IS NOT DISTINCT FROM p_hours THEN
    RETURN jsonb_build_object('reminder_hours', p_hours, 'changed', false);
  END IF;
  UPDATE public.exos_discord_links SET reminder_hours = p_hours WHERE org_id = p_org_id;
  /* exos: audit discord.reminder_set */
  PERFORM public._exos_audit(p_org_id, 'discord.reminder_set', 'discord_link', p_org_id::text, NULL,
    jsonb_build_object('reminder_hours', jsonb_build_array(v_old, p_hours)), NULL, NULL, NULL, v_uid, NULL, 'dashboard');
  RETURN jsonb_build_object('reminder_hours', p_hours, 'changed', true);
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_set_reminder(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_discord_set_reminder(uuid, integer) TO authenticated, service_role;

-- The cron pass, before it claims posts: queue the reminder of each published
-- event that starts within its org's reminder_hours and hasn't started. Once
-- per event (UNIQUE (event_id, kind); a reminder the org already asked for,
-- whatever its state, is left alone). The button's limits: an org that asked
-- for 30 posts in the last hour, or 10 this minute, waits for a later pass.
-- Not when the publish announcement was asked for inside the window (it went
-- out a moment ago). Returns how many it queued.
CREATE OR REPLACE FUNCTION public.exos_discord_reminder_queue(p_limit integer DEFAULT 50)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r      record;
  v_n    integer := 0;
  v_full uuid[] := '{}';
BEGIN
  FOR r IN
    SELECT e.id AS event_id, e.org_id
      FROM public.exos_discord_links l
      JOIN public.exos_events e ON e.org_id = l.org_id
     WHERE l.reminder_hours IS NOT NULL AND l.webhook_id IS NOT NULL AND l.webhook_broken_at IS NULL
       AND e.status = 'published'
       AND e.starts_at > now() AND e.starts_at <= now() + make_interval(hours => l.reminder_hours)
       AND NOT EXISTS (SELECT 1 FROM public.exos_discord_posts p WHERE p.event_id = e.id AND p.kind = 'reminder')
       AND NOT EXISTS (SELECT 1 FROM public.exos_discord_posts p
                        WHERE p.event_id = e.id AND p.kind = 'publish' AND p.status IN ('queued', 'sending', 'sent')
                          AND p.requested_at >= e.starts_at - make_interval(hours => l.reminder_hours))
     ORDER BY e.starts_at
     LIMIT greatest(1, least(coalesce(p_limit, 50), 200))
  LOOP
    CONTINUE WHEN r.org_id = ANY (v_full);
    IF (SELECT count(*) FROM public.exos_discord_posts x
         WHERE x.org_id = r.org_id AND x.requested_at > now() - interval '1 hour') >= 30
       OR NOT public.exos_rate_hit('discord_post:' || r.org_id::text, 10) THEN
      v_full := v_full || r.org_id;
      CONTINUE;
    END IF;
    INSERT INTO public.exos_discord_posts (org_id, event_id, kind, requested_by)
    VALUES (r.org_id, r.event_id, 'reminder', NULL)
    ON CONFLICT (event_id, kind) DO NOTHING;
    IF FOUND THEN
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_reminder_queue(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_reminder_queue(integer) TO service_role;

-- ===========================================================================
-- 2. Deleting an Exos event deletes its Discord event
-- ===========================================================================
-- org_id and event_id carry no foreign key: the row is written while the
-- event (or, through a cascade, the whole org) is being deleted.
CREATE TABLE IF NOT EXISTS public.exos_discord_deletes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL,
  event_id     uuid NOT NULL,
  guild_id     text NOT NULL CONSTRAINT exos_discord_deletes_guild_chk CHECK (guild_id ~ '^[0-9]{17,20}$'),
  external_id  text NOT NULL CONSTRAINT exos_discord_deletes_ext_chk CHECK (external_id ~ '^[0-9]{17,20}$'),
  ends_at      timestamptz,
  status       text NOT NULL DEFAULT 'queued'
                 CONSTRAINT exos_discord_deletes_status_chk CHECK (status IN ('queued', 'done', 'dry_run', 'error', 'skipped')),
  requested_by uuid,
  attempts     integer NOT NULL DEFAULT 0,
  next_try_at  timestamptz NOT NULL DEFAULT now(),
  lease_id     uuid,
  lease_until  timestamptz,
  plan         jsonb CHECK (plan IS NULL OR length(plan::text) <= 8000),
  last_error   text CHECK (last_error IS NULL OR length(last_error) <= 300),
  done_at      timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_discord_deletes_once UNIQUE (guild_id, external_id)
);
CREATE INDEX IF NOT EXISTS exos_discord_deletes_due_idx ON public.exos_discord_deletes (next_try_at) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS exos_discord_deletes_org_idx ON public.exos_discord_deletes (org_id, created_at DESC);
ALTER TABLE public.exos_discord_deletes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_discord_deletes FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_discord_deletes TO service_role;
DROP TRIGGER IF EXISTS exos_discord_deletes_touch ON public.exos_discord_deletes;
CREATE TRIGGER exos_discord_deletes_touch BEFORE UPDATE ON public.exos_discord_deletes
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
COMMENT ON TABLE public.exos_discord_deletes IS
  'A Discord scheduled event to delete because its Exos event was deleted (server + event id kept from the sync row). Service role only. mig 20261114100000.';

-- Before an Exos event is deleted (its sync row goes with it): keep the
-- scheduled event Exos made, if it is on the server the org is linked to
-- now. A server that was disconnected keeps its events (docs/discord.md).
-- Named zz_ so it runs after any other BEFORE DELETE trigger.
CREATE OR REPLACE FUNCTION public.exos_tg_discord_event_delete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.exos_discord_deletes (org_id, event_id, guild_id, external_id, ends_at, requested_by)
  SELECT s.org_id, s.event_id, s.guild_id, s.external_id, coalesce(OLD.ends_at, OLD.starts_at + interval '3 hours'), auth.uid()
    FROM public.exos_discord_event_syncs s
    JOIN public.exos_discord_links l ON l.org_id = s.org_id AND l.guild_id = s.guild_id
   WHERE s.event_id = OLD.id AND s.external_id IS NOT NULL AND s.guild_id IS NOT NULL
  ON CONFLICT (guild_id, external_id) DO NOTHING;
  RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_discord_event_delete() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_events_zz_discord_del ON public.exos_events;
CREATE TRIGGER exos_events_zz_discord_del BEFORE DELETE ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_discord_event_delete();

-- A create that raced the delete: the pass made the scheduled event, but its
-- Exos event (and the sync row) was deleted meanwhile. Queue its delete.
SELECT pg_temp.exos_patch_n('public.exos_discord_sync_mark(uuid,uuid,bigint,jsonb)',
  '/* exos: discord delete race */',
  $o$  IF s.event_id IS NULL OR p_lease IS NULL OR s.lease_id IS DISTINCT FROM p_lease THEN$o$,
  $n$  /* exos: discord delete race */ -- mig 20261114100000: the event was deleted while this pass created its Discord event
  IF s.event_id IS NULL AND p_lease IS NOT NULL AND v_state = 'synced' AND v_ext ~ '^[0-9]{17,20}$' AND v_guild ~ '^[0-9]{17,20}$'
     AND NOT EXISTS (SELECT 1 FROM public.exos_events x WHERE x.id = p_event_id) THEN
    INSERT INTO public.exos_discord_deletes (org_id, event_id, guild_id, external_id, ends_at)
    SELECT l.org_id, p_event_id, v_guild, v_ext, now() + interval '1 day'
      FROM public.exos_discord_links l WHERE l.guild_id = v_guild
    ON CONFLICT (guild_id, external_id) DO NOTHING;
  END IF;
  IF s.event_id IS NULL OR p_lease IS NULL OR s.lease_id IS DISTINCT FROM p_lease THEN$n$, 1);

-- Deletes due, each with a 2-minute lease (a DELETE is safe to repeat: a
-- crashed pass's row comes back once its lease runs out). Nothing while the
-- breaker or a global 429 stops bot calls. Per row: a server no longer
-- linked (disconnected, or relinked elsewhere) is skipped, as is an event
-- Discord ended over a day ago; a server that refused the bot is an error
-- (delete it in Discord); a paused org waits; 20 a minute per org (shared
-- with the scheduled-event pass).
CREATE OR REPLACE FUNCTION public.exos_discord_delete_claim(p_limit integer DEFAULT 10, p_token_fp text DEFAULT NULL)
RETURNS TABLE (delete_id uuid, org_id uuid, lease_id uuid, payload jsonb)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
#variable_conflict use_column
DECLARE
  r   record;
  v_l uuid;
BEGIN
  IF public._exos_discord_blocked('bot', p_token_fp) IS NOT NULL THEN
    RETURN;
  END IF;
  FOR r IN
    SELECT d.id, d.org_id, d.guild_id, d.external_id, d.ends_at, l.guild_id AS link_guild, l.guild_broken_at,
           l.invalid_paused_until, coalesce(l.writes_enabled, false) AS link_writes
      FROM public.exos_discord_deletes d
      LEFT JOIN public.exos_discord_links l ON l.org_id = d.org_id
     WHERE d.status = 'queued' AND d.next_try_at <= now() AND (d.lease_until IS NULL OR d.lease_until < now())
     ORDER BY d.next_try_at
     LIMIT greatest(1, least(coalesce(p_limit, 10), 50))
     FOR UPDATE OF d SKIP LOCKED
  LOOP
    IF r.link_guild IS DISTINCT FROM r.guild_id THEN
      UPDATE public.exos_discord_deletes SET status = 'skipped', lease_id = NULL, lease_until = NULL,
             last_error = 'the Discord server was disconnected; the event stays there' WHERE id = r.id;
      CONTINUE;
    END IF;
    IF r.ends_at < now() - interval '1 day' THEN
      UPDATE public.exos_discord_deletes SET status = 'skipped', lease_id = NULL, lease_until = NULL,
             last_error = 'the event was over; Discord ended it' WHERE id = r.id;
      CONTINUE;
    END IF;
    IF r.guild_broken_at IS NOT NULL THEN
      UPDATE public.exos_discord_deletes SET status = 'error', lease_id = NULL, lease_until = NULL,
             last_error = 'the Exos bot lost access to the server; delete the event in Discord' WHERE id = r.id;
      CONTINUE;
    END IF;
    IF r.invalid_paused_until > now() THEN
      UPDATE public.exos_discord_deletes SET next_try_at = r.invalid_paused_until WHERE id = r.id;
      CONTINUE;
    END IF;
    IF NOT public.exos_rate_hit('discord_sync:' || r.org_id::text, 20) THEN
      UPDATE public.exos_discord_deletes SET next_try_at = now() + interval '1 minute' WHERE id = r.id;
      CONTINUE;
    END IF;
    v_l := gen_random_uuid();
    UPDATE public.exos_discord_deletes SET lease_id = v_l, lease_until = now() + interval '2 minutes', attempts = attempts + 1
     WHERE id = r.id;
    delete_id := r.id; org_id := r.org_id; lease_id := v_l;
    payload := jsonb_build_object('guild_id', r.guild_id, 'external_id', r.external_id, 'writes_enabled', r.link_writes);
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_delete_claim(integer, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_delete_claim(integer, text) TO service_role;

-- Record a delete. p_result: {state: done | dry_run | retry | error, plan,
-- error, retry_seconds, link_broken}. Refused without the lease. retry backs
-- off (at most 8 tries, then an error); done and dry_run are final and
-- audited as discord.event_delete with the person who deleted the event.
-- link_broken: the server refused the bot, so the org's link to it is
-- skipped until it's linked again (as the scheduled-event pass does).
CREATE OR REPLACE FUNCTION public.exos_discord_delete_mark(p_delete_id uuid, p_lease uuid, p_result jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  d       public.exos_discord_deletes%ROWTYPE;
  v_state text := p_result ->> 'state';
  v_broke boolean := coalesce((p_result ->> 'link_broken')::boolean, false);
  v_err   text := left(coalesce(nullif(btrim(p_result ->> 'error'), ''), 'Discord refused the delete'), 300);
BEGIN
  SELECT * INTO d FROM public.exos_discord_deletes WHERE id = p_delete_id FOR UPDATE;
  IF d.id IS NULL OR p_lease IS NULL OR d.lease_id IS DISTINCT FROM p_lease OR d.status <> 'queued' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'lease-lost');
  END IF;
  IF v_state IS NULL OR v_state NOT IN ('done', 'dry_run', 'retry', 'error') THEN
    RAISE EXCEPTION 'exos_discord_delete_mark: bad state' USING ERRCODE = '22023';
  END IF;
  IF v_state = 'retry' AND d.attempts >= 8 THEN
    v_state := 'error';
  END IF;
  UPDATE public.exos_discord_deletes
     SET status      = CASE v_state WHEN 'retry' THEN 'queued' ELSE v_state END,
         plan        = CASE WHEN jsonb_typeof(p_result -> 'plan') = 'object' AND length((p_result -> 'plan')::text) <= 8000
                            THEN p_result -> 'plan' ELSE plan END,
         next_try_at = CASE WHEN v_state = 'retry'
                            THEN now() + make_interval(secs => least(greatest(coalesce((p_result ->> 'retry_seconds')::int, 60), 30), 3600))
                            ELSE next_try_at END,
         last_error  = CASE WHEN v_state IN ('retry', 'error') THEN v_err END,
         done_at     = CASE WHEN v_state IN ('done', 'dry_run') THEN now() ELSE done_at END,
         lease_id = NULL, lease_until = NULL
   WHERE id = p_delete_id;
  IF v_broke THEN
    UPDATE public.exos_discord_links
       SET guild_broken_at = now(), guild_broken_reason = left(v_err, 200)
     WHERE org_id = d.org_id AND guild_id = d.guild_id;
  END IF;
  IF v_state IN ('done', 'dry_run') THEN
    /* exos: audit discord.event_delete */
    PERFORM public._exos_audit(d.org_id, 'discord.event_delete', 'event', d.event_id::text, d.event_id,
      jsonb_build_object('dry_run', v_state = 'dry_run', 'discord_event', '…' || right(d.external_id, 4)),
      NULL, NULL, NULL, d.requested_by, NULL, 'system');
  END IF;
  RETURN jsonb_build_object('ok', true, 'state', CASE v_state WHEN 'retry' THEN 'queued' ELSE v_state END);
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_delete_mark(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_delete_mark(uuid, uuid, jsonb) TO service_role;

-- ===========================================================================
-- 3. "Send a test" (the channel webhook)
-- ===========================================================================
-- exos-discord /test, with the signed-in user it read from the JWT. In this
-- order, before anything goes to Discord: the role (owner / manager), a
-- webhook that Discord hasn't refused, the breaker and the org's pause, then
-- 3 tests an hour per org (every test counts, a dry run too). Audited
-- discord.webhook_test (p_env_writes: EXOS_DISCORD_WRITES=on, so the row says
-- whether it was a dry run). Returns the webhook id and token: the service
-- role only, never the browser.
CREATE OR REPLACE FUNCTION public.exos_discord_test_begin(p_org_id uuid, p_user_id uuid, p_env_writes boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  l       public.exos_discord_links%ROWTYPE;
  v_block jsonb;
  v_n     bigint;
  v_live  boolean;
BEGIN
  IF public._exos_discord_role(p_org_id, p_user_id) IS NULL THEN
    RAISE EXCEPTION 'exos_discord_test_begin: owner or manager only' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO l FROM public.exos_discord_links WHERE org_id = p_org_id FOR UPDATE;
  IF l.webhook_id IS NULL THEN
    RAISE EXCEPTION 'exos_discord_test_begin: save a Discord webhook first' USING ERRCODE = '22023';
  END IF;
  IF l.webhook_broken_at IS NOT NULL THEN
    RAISE EXCEPTION 'exos_discord_test_begin: Discord refused this webhook; paste a new one' USING ERRCODE = '22023';
  END IF;
  v_block := public._exos_discord_blocked('webhook', NULL, p_org_id);
  IF v_block IS NOT NULL THEN
    RAISE EXCEPTION 'exos_discord_test_begin: Discord is paused for this organization; try again later' USING ERRCODE = '54000';
  END IF;
  SELECT coalesce(sum(hits), 0) INTO v_n FROM public.exos_rate_windows
   WHERE bucket = 'discord_test:' || p_org_id::text AND window_start > now() - interval '1 hour';
  IF v_n >= 3 THEN
    RAISE EXCEPTION 'exos_discord_test_begin: 3 test messages an hour is the limit; try again later' USING ERRCODE = '54000';
  END IF;
  PERFORM public.exos_rate_hit('discord_test:' || p_org_id::text, 2147483647);
  v_live := coalesce(l.writes_enabled, false) AND coalesce(p_env_writes, false);
  /* exos: audit discord.webhook_test */
  PERFORM public._exos_audit(p_org_id, 'discord.webhook_test', 'discord_webhook', p_org_id::text, NULL,
    jsonb_build_object('dry_run', NOT v_live, 'webhook', '…' || right(l.webhook_id, 4)), NULL, NULL, NULL, p_user_id, NULL, 'dashboard');
  RETURN jsonb_build_object(
    'webhook', jsonb_build_object('id', l.webhook_id,
                 'token', (SELECT s.decrypted_secret FROM vault.decrypted_secrets s WHERE s.id = l.webhook_secret_id)),
    'writes_enabled', coalesce(l.writes_enabled, false),
    'org_name', (SELECT o.name FROM public.exos_orgs o WHERE o.id = p_org_id),
    'tests_left', greatest(2 - v_n, 0));
END $$;
REVOKE ALL ON FUNCTION public.exos_discord_test_begin(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_test_begin(uuid, uuid, boolean) TO service_role;

-- Discord refused the webhook on a test (deleted, or a wrong URL): skip it
-- until a new one is saved, if it is still the one the test used.
CREATE OR REPLACE FUNCTION public.exos_discord_webhook_refused(p_org_id uuid, p_webhook_id text, p_reason text DEFAULT NULL)
RETURNS boolean
LANGUAGE sql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  UPDATE public.exos_discord_links
     SET webhook_broken_at = now(),
         webhook_broken_reason = left(coalesce(nullif(btrim(p_reason), ''), 'Discord refused the webhook'), 200)
   WHERE org_id = p_org_id AND webhook_id IS NOT NULL AND webhook_id = p_webhook_id
  RETURNING true
$$;
REVOKE ALL ON FUNCTION public.exos_discord_webhook_refused(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_discord_webhook_refused(uuid, text, text) TO service_role;

-- The panels show the reminder setting.
SELECT pg_temp.exos_patch_n('public.exos_discord_status(uuid)',
  '/* exos: discord reminder status */',
  $o$    'auto_post', coalesce(l.auto_post, false),$o$,
  $n$    'auto_post', coalesce(l.auto_post, false),
    /* exos: discord reminder status */ 'reminder_hours', l.reminder_hours,$n$, 1);

SELECT pg_temp.exos_patch_n('public.exos_discord_event_status(uuid)',
  '/* exos: discord reminder status */',
  $o$    'writes_enabled', coalesce(l.writes_enabled, false),$o$,
  $n$    'writes_enabled', coalesce(l.writes_enabled, false),
    /* exos: discord reminder status */ 'reminder_hours', l.reminder_hours,$n$, 1);

-- ===========================================================================
-- 4. Kiosk prints counted per kiosk session
-- ===========================================================================
-- _exos_print_mint's 60 a minute: on the kiosk session while a kiosk core
-- set exos.pos_kiosk_session (only _exos_pos_kiosk_codes, for this one call),
-- otherwise on the member as before.
SELECT pg_temp.exos_patch_n('public._exos_print_mint(uuid,uuid,uuid[],text,uuid,boolean)',
  '/* exos: print kiosk limit */',
  $o$  IF NOT public.exos_rate_hit('print:' || coalesce(p_actor::text, p_org::text), 60) THEN$o$,
  $n$  /* exos: print kiosk limit */ -- mig 20261114100000: a kiosk's prints count on its own session
  IF NOT public.exos_rate_hit('print:' || coalesce('kiosk:' || nullif(current_setting('exos.pos_kiosk_session', true), ''),
                                                   p_actor::text, p_org::text), 60) THEN$n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_pos_kiosk_codes(text,uuid)',
  '/* exos: pos kiosk print limit */',
  $o$  RETURN public._exos_print_mint(o.org_id, (s ->> 'actor')::uuid, v_ids, 'pos', NULL, true);$o$,
  $n$  /* exos: pos kiosk print limit */ -- mig 20261114100000: the print limit counts on this kiosk session
  PERFORM set_config('exos.pos_kiosk_session', (s ->> 'session_id'), true);
  DECLARE v_minted jsonb;
  BEGIN
    v_minted := public._exos_print_mint(o.org_id, (s ->> 'actor')::uuid, v_ids, 'pos', NULL, true);
    PERFORM set_config('exos.pos_kiosk_session', '', true);
    RETURN v_minted;
  END;$n$, 1);

-- ROLLBACK (manual): drop the trigger exos_events_zz_discord_del and
-- exos_tg_discord_event_delete; drop exos_discord_set_reminder,
-- exos_discord_reminder_queue, exos_discord_delete_claim / _mark,
-- exos_discord_test_begin, exos_discord_webhook_refused and the table
-- exos_discord_deletes; drop exos_discord_links.reminder_hours (and its
-- check); re-run 20261113130000's definitions of exos_discord_status,
-- exos_discord_event_status, exos_discord_sync_mark, and 20261105120000's
-- _exos_print_mint and 20261113100000's _exos_pos_kiosk_codes (markers go with them).
