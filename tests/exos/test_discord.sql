-- ============================================================================
-- Discord promotion (mig 20261113130000). Self-contained (d15… ids), rolled
-- back.
--   DC0 shape: RLS on, no client grants on the three tables; definer +
--       search_path; organizer RPCs signed-in only, the edge function's
--       service role only, nothing for anon; the 'discord' OAuth provider
--   DC1 webhook URL check: discord.com / discordapp.com webhook paths only;
--       other hosts, subdomains, http, ports, user info, queries, fragments,
--       encodings, short tokens, bad ids all refused, and the refusal never
--       echoes the URL or token
--   DC2 roles and storage: owner / manager save it, finance / scanner /
--       outsider / the other org's owner / signed out 42501; the token is
--       only in Vault; status shows a hint, never the token; remove deletes
--       the Vault secret and fails queued posts
--   DC3 switches: writes owner only, the publish announcement owner /
--       manager; audit rows (discord.webhook_set, .webhook_remove,
--       .settings)
--   DC4 posts: published and not over, a webhook first; once per event per
--       kind (queued / sending / sent answer already; dry run and error
--       queue again); cross-org 42501 with nothing echoed; 10 a minute and
--       30 an hour per org (54000)
--   DC5 claim / mark: the token only to the service role; a wrong lease is
--       refused; a stale 'sending' becomes an error, never resent; retry
--       backs off, 5 tries; sent and dry run audited as discord.post with
--       the requester; an unpublished event errors at claim
--   DC6 the publish announcement: queued once on publish when the org
--       turned it on, never twice, never for a draft
--   DC7 Show on Discord: a linked server first; a sale doesn't re-sync, an
--       edit does (debounced); another server's scheduled event id is not
--       handed out; gone in Discord turns it off; 20 passes a minute per
--       org; discord.event_show
--   DC8 bot install: the 'discord' state (owner / manager), consume needs
--       the finish token and the starting user; one server per org (23505);
--       the role re-checked at link; discord.guild_link / .guild_unlink
--   DC9 every audit marker is in place
--   DC10 the circuit breaker: 300 calls a minute across orgs; a 401 on the
--       bot stops bot calls (not webhooks) until the token changes or the
--       operator clears it; a global 429 pauses bot calls; over 500 invalid
--       answers in 10 minutes from 5+ orgs stops every call (DC11); a server or webhook Discord
--       refused is skipped until relinked / replaced; "sync now" waits out
--       the backoff; the panels say so
--   DC11 tenants can't trip the shared breaker: an org's 10th invalid answer
--       in 10 minutes pauses that org (30 minutes, doubling, audited); its
--       answers stop counting; one org never trips 'all', whatever the
--       volume; re-saving a webhook or relinking doesn't reset the pause;
--       5 orgs over the threshold do trip it; it cools down after 15 minutes
-- Users: d1 owner A, d2 manager A, d3 finance A, d4 scanner A, d5 owner B,
--        d6 outsider.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('d1500000-0000-0000-0000-' || lpad(p, 12, '0'))::uuid
$$;
CREATE FUNCTION pg_temp.act(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.st(text) TO anon, authenticated;
-- A well-formed webhook token (68 characters, Discord's usual length).
CREATE FUNCTION pg_temp.tok(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT 'T' || p || repeat('aB9_-x', 11) || 'Zq'
$$;
GRANT EXECUTE ON FUNCTION pg_temp.tok(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.hook(p_id text, p_tok text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT 'https://discord.com/api/webhooks/' || p_id || '/' || p_tok
$$;
GRANT EXECUTE ON FUNCTION pg_temp.hook(text, text) TO anon, authenticated;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  (pg_temp.u('d1'), 'd15-oa@x.com', now()), (pg_temp.u('d2'), 'd15-ma@x.com', now()),
  (pg_temp.u('d3'), 'd15-fa@x.com', now()), (pg_temp.u('d4'), 'd15-sa@x.com', now()),
  (pg_temp.u('d5'), 'd15-ob@x.com', now()), (pg_temp.u('d6'), 'd15-x1@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  (pg_temp.u('1'), 'D15 Hall', 'd15-hall', pg_temp.u('d1')),
  (pg_temp.u('2'), 'D15 Elsewhere', 'd15-elsewhere', pg_temp.u('d5'));
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  (pg_temp.u('1'), pg_temp.u('d1'), 'owner'), (pg_temp.u('1'), pg_temp.u('d2'), 'manager'),
  (pg_temp.u('1'), pg_temp.u('d3'), 'finance'), (pg_temp.u('1'), pg_temp.u('d4'), 'scanner'),
  (pg_temp.u('2'), pg_temp.u('d5'), 'owner');
-- Org A: e1 published, e2 draft, e3 over, e4 secret location, e5 tba.
-- Org B: e9 published ("Hidden Gala").
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by,
                                venue_name, venue_location, venue_address) VALUES
  (pg_temp.u('e1'), pg_temp.u('1'), 'D15 Night', 'd15-night', 'published', now() + interval '10 days', 'America/New_York', 100, pg_temp.u('d1'),
   'Blue Room', 'Brooklyn', '{"street": "1 Main St", "city": "Brooklyn"}'),
  (pg_temp.u('e2'), pg_temp.u('1'), 'D15 Draft', 'd15-draft', 'draft', now() + interval '20 days', 'America/New_York', 100, pg_temp.u('d1'),
   NULL, NULL, NULL),
  (pg_temp.u('e3'), pg_temp.u('1'), 'D15 Past', 'd15-past', 'published', now() - interval '3 days', 'America/New_York', 100, pg_temp.u('d1'),
   NULL, NULL, NULL),
  (pg_temp.u('e9'), pg_temp.u('2'), 'D15 Hidden Gala', 'd15-hidden', 'published', now() + interval '10 days', 'America/New_York', 100, pg_temp.u('d5'),
   NULL, NULL, NULL);
-- (The location rules want a reveal row and settings these fixtures don't need.)
SET LOCAL session_replication_role = replica;
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by,
                                location_mode, venue_location, location_reveal_at) VALUES
  (pg_temp.u('e4'), pg_temp.u('1'), 'D15 Secret', 'd15-secret', 'published', now() + interval '12 days', 'America/New_York', 100, pg_temp.u('d1'),
   'secret_location', 'Bushwick', now() + interval '11 days');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, created_by, location_mode, tba_allow_sales)
VALUES (pg_temp.u('e5'), pg_temp.u('1'), 'D15 TBA', 'd15-tba', 'published', now() + interval '14 days', 'America/New_York', 100, pg_temp.u('d1'), 'tba', true);
SET LOCAL session_replication_role = origin;

-- DC0 ------------------------------------------------------------------------
DO $$
DECLARE f text; t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_discord_links', 'exos_discord_posts', 'exos_discord_event_syncs', 'exos_discord_platform'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'DC0 RLS on ' || t;
    FOREACH f IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      ASSERT NOT has_table_privilege(f, 'public.' || t, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'), 'DC0 ' || f || ' on ' || t;
    END LOOP;
  END LOOP;
  -- No column holds a token: only the Vault secret id.
  ASSERT NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name LIKE 'exos_discord%'
                       AND (column_name LIKE '%token%' OR column_name LIKE '%url%')), 'DC0 no token or URL column';
  FOREACH f IN ARRAY ARRAY[
      'public.exos_discord_status(uuid)', 'public.exos_discord_set_webhook(uuid,text)', 'public.exos_discord_remove_webhook(uuid)',
      'public.exos_discord_set_options(uuid,boolean,boolean)', 'public.exos_discord_unlink_guild(uuid)',
      'public.exos_discord_event_status(uuid)', 'public.exos_discord_set_show(uuid,boolean)',
      'public.exos_discord_request_post(uuid,text)'] LOOP
    ASSERT (SELECT prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp'] FROM pg_proc WHERE oid = f::regprocedure), 'DC0 definer ' || f;
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE'), 'DC0 signed in runs ' || f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'DC0 anon runs ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY[
      'public.exos_discord_post_claim(integer,uuid)', 'public.exos_discord_post_mark(uuid,uuid,text,text,text,jsonb,integer,boolean)',
      'public.exos_discord_sync_claim(integer,uuid,text)', 'public.exos_discord_sync_mark(uuid,uuid,bigint,jsonb)',
      'public.exos_discord_call_gate(text,text,uuid)', 'public.exos_discord_call_result(text,integer,integer,boolean,text,numeric,text,uuid)',
      'public.exos_discord_breaker_clear()', 'public._exos_discord_blocked(text,text,uuid)',
      'public.exos_discord_install_begin(uuid,uuid,text)', 'public.exos_discord_install_consume(text,uuid,text)',
      'public.exos_discord_guild_link(uuid,uuid,text,text)', 'public.exos_discord_webhook_parts(text)',
      'public._exos_discord_role(uuid,uuid)', 'public._exos_discord_event_json(uuid)', 'public.exos_tg_discord_event()'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE'),
      'DC0 client runs ' || f;
  END LOOP;
  ASSERT has_function_privilege('service_role', 'public.exos_discord_post_claim(integer,uuid)', 'EXECUTE'), 'DC0 the edge function claims';
  ASSERT (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'exos_oauth_states_provider_chk') LIKE '%discord%',
    'DC0 discord states';
  ASSERT position('''discord''' IN pg_get_functiondef('public.exos_oauth_state_begin(text,uuid,uuid,text,integer)'::regprocedure)) > 0,
    'DC0 begin accepts discord';
  RAISE NOTICE 'OK  DC0 RLS, no client table grants, no token column; organizer RPCs signed in, the rest service role; discord states';
END $$;

-- DC1 ------------------------------------------------------------------------
DO $$
DECLARE u text; tk text := pg_temp.tok('1'); r record;
BEGIN
  FOREACH u IN ARRAY ARRAY[
      'https://discord.com/api/webhooks/123456789012345678/' || tk,
      'https://discordapp.com/api/webhooks/123456789012345678/' || tk,
      'https://discord.com/api/v10/webhooks/123456789012345678/' || tk,
      'https://discord.com/api/v9/webhooks/12345678901234567/' || tk || '/',
      '  https://discord.com/api/webhooks/12345678901234567890/' || tk || '  '] LOOP
    SELECT * INTO r FROM public.exos_discord_webhook_parts(u);
    ASSERT r.webhook_id ~ '^[0-9]{17,20}$' AND r.token = tk, 'DC1 accepted: ' || u;
  END LOOP;
  FOREACH u IN ARRAY ARRAY[
      'http://discord.com/api/webhooks/123456789012345678/' || tk,
      'https://ptb.discord.com/api/webhooks/123456789012345678/' || tk,
      'https://canary.discordapp.com/api/webhooks/123456789012345678/' || tk,
      'https://discord.com.evil.example/api/webhooks/123456789012345678/' || tk,
      'https://evil.example/discord.com/api/webhooks/123456789012345678/' || tk,
      'https://evil.example/?u=https://discord.com/api/webhooks/123456789012345678/' || tk,
      'https://discord.com:8443/api/webhooks/123456789012345678/' || tk,
      'https://x@discord.com/api/webhooks/123456789012345678/' || tk,
      'https://discord.com/api/webhooks/123456789012345678/' || tk || '?wait=true',
      'https://discord.com/api/webhooks/123456789012345678/' || tk || '#x',
      'https://discord.com/api/webhooks/123456789012345678/' || tk || '/github',
      'https://discord.com/api/webhooks/123456789012345678/short',
      'https://discord.com/api/webhooks/1234/' || tk,
      'https://discord.com/api/webhooks/12345678901234567x/' || tk,
      'https://discord.com/api/webhooks/123456789012345678/' || replace(tk, 'Zq', '%2F'),
      'https://discord.com/api/webhooks/../123456789012345678/' || tk,
      'https://discord.com/api/channels/123456789012345678/messages',
      'https://discord.com/api/webhooks/123456789012345678/' || tk || ' https://evil.example',
      'HTTPS://DISCORD.COM/api/webhooks/123456789012345678/' || tk,
      'https://discord.com/api/webhooks/123456789012345678/' || repeat('a', 120),
      '', NULL] LOOP
    ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_webhook_parts(u)), 'DC1 refused: ' || coalesce(u, 'NULL');
  END LOOP;
  -- Through the RPC: the refusal doesn't carry what was pasted.
  PERFORM pg_temp.act(pg_temp.u('d1'));
  u := pg_temp.st(format('SELECT public.exos_discord_set_webhook(%L, %L)', pg_temp.u('1'),
                         'https://evil.example/api/webhooks/123456789012345678/' || tk));
  ASSERT u LIKE '22023%' AND position(tk IN u) = 0 AND position('evil' IN u) = 0 AND position('123456789012345678' IN u) = 0,
    'DC1 refusal echoes nothing: ' || u;
  PERFORM pg_temp.act(NULL);
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  RAISE NOTICE 'OK  DC1 webhook URL: discord.com / discordapp.com webhook paths only, 21 shapes refused, nothing echoed';
END $$;

-- DC2 ------------------------------------------------------------------------
DO $$
DECLARE s text; r jsonb; v_secret uuid;
BEGIN
  FOREACH s IN ARRAY ARRAY['d3', 'd4', 'd5', 'd6'] LOOP
    PERFORM pg_temp.act(pg_temp.u(s));
    ASSERT pg_temp.st(format('SELECT public.exos_discord_set_webhook(%L, %L)', pg_temp.u('1'),
                             pg_temp.hook('123456789012345678', pg_temp.tok('2')))) LIKE '42501%', 'DC2 refused ' || s;
    ASSERT pg_temp.st(format('SELECT public.exos_discord_status(%L)', pg_temp.u('1'))) LIKE '42501%', 'DC2 status refused ' || s;
  END LOOP;
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format('SELECT public.exos_discord_status(%L)', pg_temp.u('1'))) LIKE '42501%', 'DC2 signed out';
  ASSERT NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'exos_discord_webhook:' || pg_temp.u('1')), 'DC2 nothing saved';

  PERFORM pg_temp.act(pg_temp.u('d2'));
  r := public.exos_discord_set_webhook(pg_temp.u('1'), pg_temp.hook('123456789012345678', pg_temp.tok('2')));
  ASSERT r->>'hint' = '…5678' AND (r->>'replaced')::boolean = false, 'DC2 manager saves: ' || r::text;
  PERFORM pg_temp.act(pg_temp.u('d1'));
  r := public.exos_discord_set_webhook(pg_temp.u('1'), 'https://discordapp.com/api/webhooks/223456789012345679/' || pg_temp.tok('3'));
  ASSERT (r->>'replaced')::boolean, 'DC2 owner replaces';
  SELECT webhook_secret_id INTO v_secret FROM public.exos_discord_links WHERE org_id = pg_temp.u('1');
  ASSERT (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = v_secret) = pg_temp.tok('3'), 'DC2 token in Vault';
  ASSERT (SELECT count(*) FROM vault.secrets WHERE name = 'exos_discord_webhook:' || pg_temp.u('1')) = 1, 'DC2 one secret, updated';
  ASSERT (SELECT webhook_id FROM public.exos_discord_links WHERE org_id = pg_temp.u('1')) = '223456789012345679', 'DC2 id stored';
  r := public.exos_discord_status(pg_temp.u('1'));
  ASSERT (r->'webhook'->>'set')::boolean AND r->'webhook'->>'hint' = '…5679' AND position(pg_temp.tok('3') IN r::text) = 0
     AND position('223456789012345679' IN r::text) = 0, 'DC2 status: hint only: ' || r::text;
  -- The other org can't read or change org A's.
  PERFORM pg_temp.act(pg_temp.u('d5'));
  ASSERT pg_temp.st(format('SELECT public.exos_discord_remove_webhook(%L)', pg_temp.u('1'))) LIKE '42501%', 'DC2 B removes A''s';
  PERFORM pg_temp.act(NULL);
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  RAISE NOTICE 'OK  DC2 owner / manager save the webhook; others 42501; token only in Vault; status shows a hint';
END $$;
-- As the client role: the tables stay shut; the RPC works.
DO $$ BEGIN PERFORM pg_temp.act(pg_temp.u('d2')); END $$;
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  ASSERT pg_temp.st('SELECT * FROM public.exos_discord_links') LIKE '42501%', 'DC2 links table shut';
  ASSERT pg_temp.st('SELECT * FROM vault.decrypted_secrets') LIKE '42501%', 'DC2 Vault shut';
  ASSERT (public.exos_discord_status(pg_temp.u('1'))->>'can_manage')::boolean, 'DC2 status as authenticated';
  ASSERT pg_temp.st(format('SELECT * FROM public.exos_discord_post_claim(1, NULL)')) LIKE '42501%', 'DC2 claim not client-callable';
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$
BEGIN
  ASSERT pg_temp.st(format('SELECT public.exos_discord_status(%L)', pg_temp.u('1'))) LIKE '42501%', 'DC2 anon';
END $$;
RESET ROLE;

-- DC3 ------------------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('d2'));
  ASSERT pg_temp.st(format('SELECT public.exos_discord_set_options(%L, true, NULL)', pg_temp.u('1'))) LIKE '42501%only an owner%',
    'DC3 manager can''t turn writes on';
  r := public.exos_discord_set_options(pg_temp.u('1'), NULL, true);
  ASSERT (r->>'auto_post')::boolean AND NOT (r->>'writes_enabled')::boolean, 'DC3 manager turns the announcement on';
  PERFORM pg_temp.act(pg_temp.u('d3'));
  ASSERT pg_temp.st(format('SELECT public.exos_discord_set_options(%L, NULL, false)', pg_temp.u('1'))) LIKE '42501%', 'DC3 finance';
  PERFORM pg_temp.act(pg_temp.u('d1'));
  r := public.exos_discord_set_options(pg_temp.u('1'), true, NULL);
  ASSERT (r->>'writes_enabled')::boolean AND (r->>'auto_post')::boolean, 'DC3 owner turns writes on';
  r := public.exos_discord_set_options(pg_temp.u('1'), false, false);
  ASSERT NOT (r->>'writes_enabled')::boolean, 'DC3 off again';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('1') AND action = 'discord.webhook_set') = 2
     AND (SELECT count(*) FROM public.exos_org_audit WHERE org_id = pg_temp.u('1') AND action = 'discord.settings') = 3
     AND EXISTS (SELECT 1 FROM public.exos_org_audit WHERE org_id = pg_temp.u('1') AND action = 'discord.webhook_set'
                   AND actor_uid = pg_temp.u('d2') AND actor_role = 'manager'),
    'DC3 audit rows';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE action LIKE 'discord.%'
                       AND (changes::text LIKE '%' || pg_temp.tok('2') || '%' OR changes::text LIKE '%' || pg_temp.tok('3') || '%'
                            OR changes::text LIKE '%223456789012345679%')), 'DC3 no token or full id in the audit';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  DC3 writes switch owner only, announcement owner / manager; audited without the token';
END $$;

-- DC4 ------------------------------------------------------------------------
DO $$
DECLARE r jsonb; s text; i int;
BEGIN
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  PERFORM pg_temp.act(pg_temp.u('d2'));
  ASSERT pg_temp.st(format('SELECT public.exos_discord_request_post(%L, %L)', pg_temp.u('e2'), 'publish')) LIKE '22023%published%', 'DC4 draft';
  ASSERT pg_temp.st(format('SELECT public.exos_discord_request_post(%L, %L)', pg_temp.u('e3'), 'publish')) LIKE '22023%', 'DC4 over';
  ASSERT pg_temp.st(format('SELECT public.exos_discord_request_post(%L, %L)', pg_temp.u('e1'), 'blast')) LIKE '22023%', 'DC4 kind';
  r := public.exos_discord_request_post(pg_temp.u('e1'), 'publish');
  ASSERT r->>'status' = 'queued' AND NOT (r->>'already')::boolean, 'DC4 queued: ' || r::text;
  r := public.exos_discord_request_post(pg_temp.u('e1'), 'publish');
  ASSERT (r->>'already')::boolean AND r->>'status' = 'queued', 'DC4 twice: already';
  r := public.exos_discord_request_post(pg_temp.u('e1'), 'reminder');
  ASSERT NOT (r->>'already')::boolean, 'DC4 a reminder is its own kind';
  ASSERT (SELECT count(*) FROM public.exos_discord_posts WHERE event_id = pg_temp.u('e1')) = 2, 'DC4 two rows';
  -- Cross-org: B's owner on A's event, A's manager on B's event; nothing echoed.
  PERFORM pg_temp.act(pg_temp.u('d5'));
  s := pg_temp.st(format('SELECT public.exos_discord_request_post(%L, %L)', pg_temp.u('e1'), 'publish'));
  ASSERT s LIKE '42501%' AND position('D15' IN s) = 0, 'DC4 B on A: ' || s;
  ASSERT pg_temp.st(format('SELECT public.exos_discord_event_status(%L)', pg_temp.u('e1'))) LIKE '42501%', 'DC4 B reads A''s event';
  PERFORM pg_temp.act(pg_temp.u('d2'));
  s := pg_temp.st(format('SELECT public.exos_discord_request_post(%L, %L)', pg_temp.u('e9'), 'publish'));
  ASSERT s LIKE '42501%' AND position('Hidden' IN s) = 0, 'DC4 A on B: ' || s;
  ASSERT pg_temp.st(format('SELECT public.exos_discord_event_status(%L)', pg_temp.u('e9'))) LIKE '42501%', 'DC4 A reads B''s event';
  ASSERT pg_temp.st(format('SELECT public.exos_discord_event_status(%L)', pg_temp.u('ff'))) LIKE '42501%', 'DC4 unknown event, same answer';
  PERFORM pg_temp.act(pg_temp.u('d4'));
  ASSERT pg_temp.st(format('SELECT public.exos_discord_request_post(%L, %L)', pg_temp.u('e1'), 'publish')) LIKE '42501%', 'DC4 scanner';
  -- B has no webhook.
  PERFORM pg_temp.act(pg_temp.u('d5'));
  ASSERT pg_temp.st(format('SELECT public.exos_discord_request_post(%L, %L)', pg_temp.u('e9'), 'publish')) LIKE '22023%webhook%', 'DC4 no webhook';
  -- 10 requests a minute per org, counted before anything else.
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  PERFORM pg_temp.act(pg_temp.u('d1'));
  FOR i IN 1..10 LOOP
    PERFORM public.exos_discord_request_post(pg_temp.u('e1'), 'publish');
  END LOOP;
  ASSERT pg_temp.st(format('SELECT public.exos_discord_request_post(%L, %L)', pg_temp.u('e1'), 'publish')) LIKE '54000%', 'DC4 11th a minute';
  -- 30 posts an hour per org.
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, created_by)
  SELECT ('d1500000-0000-0000-0001-' || lpad(n::text, 12, '0'))::uuid, pg_temp.u('1'), 'D15 Bulk ' || n, 'd15-bulk-' || n, 'draft',
         now() + interval '30 days', pg_temp.u('d1')
    FROM generate_series(1, 14) n;
  INSERT INTO public.exos_discord_posts (org_id, event_id, kind, status, requested_at)
  SELECT pg_temp.u('1'), ('d1500000-0000-0000-0001-' || lpad(n::text, 12, '0'))::uuid, k, 'sent', now() - interval '5 minutes'
    FROM generate_series(1, 14) n CROSS JOIN (VALUES ('publish'), ('reminder')) v(k);
  -- 28 + the two of e1 = 30 in the hour; e4 can't be queued.
  s := pg_temp.st(format('SELECT public.exos_discord_request_post(%L, %L)', pg_temp.u('e4'), 'publish'));
  ASSERT s LIKE '54000%30 Discord posts an hour%', 'DC4 30 an hour: ' || s;
  -- An already-queued one still answers (no new post).
  ASSERT (public.exos_discord_request_post(pg_temp.u('e1'), 'publish')->>'already')::boolean, 'DC4 already, at the cap';
  DELETE FROM public.exos_discord_posts WHERE event_id::text LIKE 'd1500000-0000-0000-0001-%';
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  DC4 posts: published + webhook first; once per kind; cross-org 42501 with nothing echoed; 10 a minute, 30 an hour';
END $$;

-- DC5 ------------------------------------------------------------------------
DO $$
DECLARE r record; m jsonb; v_lease uuid; v_id uuid; n int;
BEGIN
  -- The service role (the test's superuser stands in) claims e1's publish post.
  SELECT * INTO r FROM public.exos_discord_post_claim(5, NULL) c WHERE c.event_id = pg_temp.u('e1') AND c.kind = 'publish';
  ASSERT r.post_id IS NOT NULL AND r.payload->'webhook'->>'id' = '223456789012345679'
     AND r.payload->'webhook'->>'token' = pg_temp.tok('3') AND NOT (r.payload->>'writes_enabled')::boolean, 'DC5 claim payload';
  ASSERT r.payload->'event'->>'venue_name' = 'Blue Room' AND r.payload->'event'->>'org_name' = 'D15 Hall', 'DC5 event in the payload';
  ASSERT (SELECT status FROM public.exos_discord_posts WHERE id = r.post_id) = 'sending', 'DC5 sending';
  -- Not claimed twice while leased.
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_post_claim(5, r.post_id)), 'DC5 leased';
  -- A wrong lease is refused.
  m := public.exos_discord_post_mark(r.post_id, gen_random_uuid(), 'sent', '323456789012345670');
  ASSERT m->>'reason' = 'lease-lost', 'DC5 wrong lease';
  ASSERT pg_temp.st(format('SELECT public.exos_discord_post_mark(%L, %L, %L)', r.post_id, r.lease_id, 'bogus')) LIKE '22023%', 'DC5 bad state';
  m := public.exos_discord_post_mark(r.post_id, r.lease_id, 'dry_run', NULL, NULL, '{"steps": [{"op": "planned"}]}');
  ASSERT m->>'state' = 'dry_run', 'DC5 dry run';
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE action = 'discord.post' AND event_id = pg_temp.u('e1')
                   AND actor_uid = pg_temp.u('d2') AND (changes->>'dry_run')::boolean), 'DC5 dry run audited with the requester';
  -- A dry run can be asked again (it was never sent).
  PERFORM pg_temp.act(pg_temp.u('d1'));
  ASSERT NOT (public.exos_discord_request_post(pg_temp.u('e1'), 'publish')->>'already')::boolean, 'DC5 dry run queues again';
  PERFORM pg_temp.act(NULL);
  SELECT * INTO r FROM public.exos_discord_post_claim(5, NULL) c WHERE c.event_id = pg_temp.u('e1') AND c.kind = 'publish';
  -- Retry (429 / 5xx): queued again later.
  m := public.exos_discord_post_mark(r.post_id, r.lease_id, 'retry', NULL, 'HTTP_429', NULL, 40);
  ASSERT m->>'state' = 'queued' AND (SELECT next_try_at > now() + interval '30 seconds' FROM public.exos_discord_posts WHERE id = r.post_id),
    'DC5 retry backs off';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_post_claim(5, r.post_id)), 'DC5 not before its time';
  UPDATE public.exos_discord_posts SET next_try_at = now() WHERE id = r.post_id;
  SELECT * INTO r FROM public.exos_discord_post_claim(5, r.post_id);
  m := public.exos_discord_post_mark(r.post_id, r.lease_id, 'sent', '323456789012345670');
  ASSERT m->>'state' = 'sent' AND (SELECT message_id FROM public.exos_discord_posts WHERE id = r.post_id) = '323456789012345670', 'DC5 sent';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE action = 'discord.post' AND event_id = pg_temp.u('e1')) = 2
     AND EXISTS (SELECT 1 FROM public.exos_org_audit WHERE action = 'discord.post' AND event_id = pg_temp.u('e1')
                   AND NOT (changes->>'dry_run')::boolean AND actor_uid = pg_temp.u('d1')), 'DC5 sent audited';
  -- Sent: never again.
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  PERFORM pg_temp.act(pg_temp.u('d1'));
  ASSERT (public.exos_discord_request_post(pg_temp.u('e1'), 'publish')->>'already')::boolean, 'DC5 sent is final';
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT status FROM public.exos_discord_posts WHERE id = r.post_id) = 'sent', 'DC5 still sent';
  -- A pass that died while sending: an error, never resent by itself. (The
  -- reminder was claimed, still 'sending', by the first claim above.)
  SELECT id, lease_id INTO v_id, v_lease FROM public.exos_discord_posts WHERE event_id = pg_temp.u('e1') AND kind = 'reminder';
  ASSERT v_lease IS NOT NULL, 'DC5 the reminder is leased';
  UPDATE public.exos_discord_posts SET lease_until = now() - interval '1 second' WHERE id = v_id;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_post_claim(5, v_id)), 'DC5 stale not resent';
  ASSERT (SELECT status = 'error' AND last_error LIKE '%check the channel%' FROM public.exos_discord_posts WHERE id = v_id), 'DC5 stale is an error';
  ASSERT (public.exos_discord_post_mark(v_id, v_lease, 'sent', NULL)->>'reason') = 'lease-lost', 'DC5 late mark refused';
  -- Five tries, then an error.
  UPDATE public.exos_discord_posts SET status = 'queued', attempts = 4, next_try_at = now() WHERE id = v_id;
  SELECT * INTO r FROM public.exos_discord_post_claim(5, v_id);
  ASSERT (public.exos_discord_post_mark(v_id, r.lease_id, 'retry', NULL, 'HTTP_503')->>'state') = 'error', 'DC5 fifth try is the last';
  -- An event unpublished after queueing errors at claim.
  UPDATE public.exos_discord_posts SET status = 'queued', next_try_at = now() WHERE id = v_id;
  UPDATE public.exos_events SET status = 'draft' WHERE id = pg_temp.u('e1');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_post_claim(5, v_id)), 'DC5 draft not claimed';
  ASSERT (SELECT status FROM public.exos_discord_posts WHERE id = v_id) = 'error', 'DC5 draft errors';
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e1');
  -- Secret location and TBA: no address in the payload.
  ASSERT public._exos_discord_event_json(pg_temp.u('e4'))->>'venue_location' = 'Bushwick'
     AND public._exos_discord_event_json(pg_temp.u('e4'))->>'venue_name' IS NULL
     AND public._exos_discord_event_json(pg_temp.u('e5'))->>'venue_location' IS NULL, 'DC5 secret / tba locations';
  RAISE NOTICE 'OK  DC5 claim / mark: lease, retry backoff (5 tries), stale sending is an error, sent final, discord.post audited';
END $$;

-- DC6 ------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.act(pg_temp.u('d1'));
  PERFORM public.exos_discord_set_options(pg_temp.u('1'), NULL, true);
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e2');
  ASSERT (SELECT count(*) FROM public.exos_discord_posts WHERE event_id = pg_temp.u('e2') AND kind = 'publish' AND status = 'queued'
            AND requested_by = pg_temp.u('d1')) = 1, 'DC6 queued on publish';
  UPDATE public.exos_events SET status = 'draft' WHERE id = pg_temp.u('e2');
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e2');
  ASSERT (SELECT count(*) FROM public.exos_discord_posts WHERE event_id = pg_temp.u('e2')) = 1, 'DC6 once';
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, created_by) VALUES
    (pg_temp.u('e6'), pg_temp.u('1'), 'D15 Born Published', 'd15-born', 'published', now() + interval '5 days', pg_temp.u('d1')),
    (pg_temp.u('e7'), pg_temp.u('1'), 'D15 Born Draft', 'd15-born-draft', 'draft', now() + interval '5 days', pg_temp.u('d1'));
  ASSERT EXISTS (SELECT 1 FROM public.exos_discord_posts WHERE event_id = pg_temp.u('e6')), 'DC6 created published';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_posts WHERE event_id = pg_temp.u('e7')), 'DC6 not for a draft';
  -- Org B (no webhook, no switch): nothing.
  UPDATE public.exos_events SET status = 'draft' WHERE id = pg_temp.u('e9');
  UPDATE public.exos_events SET status = 'published' WHERE id = pg_temp.u('e9');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_posts WHERE event_id = pg_temp.u('e9')), 'DC6 not for B';
  PERFORM public.exos_discord_set_options(pg_temp.u('1'), NULL, false);
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  DC6 the publish announcement: queued once on publish, not for drafts or another org';
END $$;

-- DC7 ------------------------------------------------------------------------
DO $$
DECLARE r record; m jsonb; k int; v_seq bigint;
BEGIN
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  PERFORM pg_temp.act(pg_temp.u('d2'));
  ASSERT pg_temp.st(format('SELECT public.exos_discord_set_show(%L, true)', pg_temp.u('e1'))) LIKE '22023%bot%', 'DC7 server first';
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_discord_guild_link(pg_temp.u('1'), pg_temp.u('d1'), '423456789012345671', 'D15 Server');
  PERFORM pg_temp.act(pg_temp.u('d4'));
  ASSERT pg_temp.st(format('SELECT public.exos_discord_set_show(%L, true)', pg_temp.u('e1'))) LIKE '42501%', 'DC7 scanner';
  PERFORM pg_temp.act(pg_temp.u('d5'));
  ASSERT pg_temp.st(format('SELECT public.exos_discord_set_show(%L, true)', pg_temp.u('e1'))) LIKE '42501%', 'DC7 B on A';
  PERFORM pg_temp.act(pg_temp.u('d2'));
  ASSERT (public.exos_discord_set_show(pg_temp.u('e1'), true)->>'changed')::boolean, 'DC7 manager shows e1';
  ASSERT NOT (public.exos_discord_set_show(pg_temp.u('e1'), true)->>'changed')::boolean, 'DC7 same again: no change';
  ASSERT (public.exos_discord_event_status(pg_temp.u('e1'))->>'show')::boolean, 'DC7 status shows it';
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE action = 'discord.event_show' AND event_id = pg_temp.u('e1')), 'DC7 audited';
  PERFORM pg_temp.act(NULL);

  SELECT * INTO r FROM public.exos_discord_sync_claim(5, NULL) c WHERE c.event_id = pg_temp.u('e1');
  ASSERT r.lease_id IS NOT NULL AND r.payload->>'guild_id' = '423456789012345671' AND r.payload->'sync'->>'external_id' IS NULL
     AND (r.payload->'sync'->>'show')::boolean, 'DC7 claim';
  ASSERT (public.exos_discord_sync_mark(pg_temp.u('e1'), gen_random_uuid(), r.change_seq, '{"state": "synced"}')->>'reason') = 'lease-lost',
    'DC7 wrong lease';
  m := public.exos_discord_sync_mark(pg_temp.u('e1'), r.lease_id, r.change_seq,
         jsonb_build_object('state', 'synced', 'external_id', '523456789012345672', 'guild_id', '423456789012345671', 'hash', 'h1'));
  ASSERT (SELECT external_id = '523456789012345672' AND status = 'synced' AND synced_seq = change_seq
            FROM public.exos_discord_event_syncs WHERE event_id = pg_temp.u('e1')), 'DC7 synced';
  -- A sale doesn't re-sync; an edit does, after 15 seconds.
  SELECT change_seq INTO v_seq FROM public.exos_discord_event_syncs WHERE event_id = pg_temp.u('e1');
  UPDATE public.exos_events SET tickets_sold = tickets_sold + 1 WHERE id = pg_temp.u('e1');
  ASSERT (SELECT change_seq FROM public.exos_discord_event_syncs WHERE event_id = pg_temp.u('e1')) = v_seq, 'DC7 a sale: no work';
  UPDATE public.exos_events SET name = 'D15 Night (late show)' WHERE id = pg_temp.u('e1');
  ASSERT (SELECT change_seq = v_seq + 1 AND next_try_at > now() FROM public.exos_discord_event_syncs WHERE event_id = pg_temp.u('e1')),
    'DC7 an edit: due after it settles';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_sync_claim(5, NULL) c WHERE c.event_id = pg_temp.u('e1')), 'DC7 debounced';
  UPDATE public.exos_discord_event_syncs SET next_try_at = now() WHERE event_id = pg_temp.u('e1');
  SELECT * INTO r FROM public.exos_discord_sync_claim(5, NULL) c WHERE c.event_id = pg_temp.u('e1');
  ASSERT r.payload->'sync'->>'external_id' = '523456789012345672' AND r.payload->'event'->>'name' = 'D15 Night (late show)', 'DC7 edit claimed';
  -- Deleted by someone in Discord: off, not put back.
  m := public.exos_discord_sync_mark(pg_temp.u('e1'), r.lease_id, r.change_seq,
         '{"state": "error", "gone": true, "error": "the Discord event was deleted in Discord"}');
  ASSERT (SELECT NOT show AND status = 'removed' AND external_id IS NULL FROM public.exos_discord_event_syncs WHERE event_id = pg_temp.u('e1')),
    'DC7 gone turns it off';
  -- Another server's id is never handed out (re-shown after a server change).
  UPDATE public.exos_discord_event_syncs SET show = true, status = 'synced', external_id = '623456789012345673',
         guild_id = '999999999999999999', change_seq = change_seq + 1, next_try_at = now() WHERE event_id = pg_temp.u('e1');
  SELECT * INTO r FROM public.exos_discord_sync_claim(5, pg_temp.u('e1'));
  ASSERT r.payload->'sync'->>'external_id' IS NULL, 'DC7 another server''s event id not handed out';
  m := public.exos_discord_sync_mark(pg_temp.u('e1'), r.lease_id, r.change_seq, '{"state": "dry_run", "plan": {"steps": []}}');
  ASSERT (SELECT status = 'dry_run' AND synced_seq = change_seq FROM public.exos_discord_event_syncs WHERE event_id = pg_temp.u('e1')),
    'DC7 a dry run waits for the next change';
  -- Turning writes on re-runs it.
  PERFORM pg_temp.act(pg_temp.u('d1'));
  PERFORM public.exos_discord_set_options(pg_temp.u('1'), true, NULL);
  ASSERT (SELECT synced_seq < change_seq FROM public.exos_discord_event_syncs WHERE event_id = pg_temp.u('e1')), 'DC7 writes on: due';
  PERFORM public.exos_discord_set_options(pg_temp.u('1'), false, NULL);
  PERFORM pg_temp.act(NULL);
  -- 20 passes a minute per org; the rest wait.
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, created_by)
  SELECT ('d1500000-0000-0000-0002-' || lpad(n::text, 12, '0'))::uuid, pg_temp.u('1'), 'D15 Many ' || n, 'd15-many-' || n, 'published',
         now() + interval '30 days', pg_temp.u('d1')
    FROM generate_series(1, 24) n;
  INSERT INTO public.exos_discord_event_syncs (event_id, org_id, show)
  SELECT ('d1500000-0000-0000-0002-' || lpad(n::text, 12, '0'))::uuid, pg_temp.u('1'), true FROM generate_series(1, 24) n;
  SELECT count(*) INTO k FROM public.exos_discord_sync_claim(50, NULL);
  ASSERT k = 20, 'DC7 20 a minute per org, got ' || k;
  ASSERT (SELECT count(*) FROM public.exos_discord_event_syncs WHERE org_id = pg_temp.u('1') AND next_try_at > now() + interval '30 seconds') >= 4,
    'DC7 the rest wait a minute';
  DELETE FROM public.exos_discord_event_syncs WHERE event_id::text LIKE 'd1500000-0000-0000-0002-%';
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  RAISE NOTICE 'OK  DC7 Show on Discord: server first, roles, a sale no work, an edit debounced, gone turns off, another server''s id withheld, 20 a minute';
END $$;

-- DC8 ------------------------------------------------------------------------
DO $$
DECLARE v_state text := repeat('ab', 32); v_fin text := repeat('cd', 32); r record; s text;
BEGIN
  ASSERT pg_temp.st(format('SELECT public.exos_discord_install_begin(%L, %L, %L)', pg_temp.u('1'), pg_temp.u('d4'), v_state)) LIKE '42501%',
    'DC8 scanner can''t start';
  PERFORM public.exos_discord_install_begin(pg_temp.u('1'), pg_temp.u('d2'), v_state);
  ASSERT (SELECT provider FROM public.exos_oauth_states WHERE state_hash = v_state) = 'discord', 'DC8 a discord state';
  ASSERT public.exos_oauth_state_return(v_state, 'discord-code-1234', v_fin) = pg_temp.u('1'), 'DC8 callback parks the code';
  -- Not a Google Ads / Eventbrite state.
  ASSERT (SELECT count(*) FROM public.exos_eventbrite_oauth_consume(v_state, pg_temp.u('d2'), v_fin) c WHERE c.org_id IS NOT NULL) = 0,
    'DC8 eventbrite consume refuses it';
  -- Another user (even with the token): refused, burned.
  SELECT * INTO r FROM public.exos_discord_install_consume(v_state, pg_temp.u('d1'), v_fin);
  ASSERT r.org_id IS NULL AND r.refused = 'other_user', 'DC8 other user';
  SELECT * INTO r FROM public.exos_discord_install_consume(v_state, pg_temp.u('d2'), v_fin);
  ASSERT r.org_id IS NULL AND r.refused = 'expired', 'DC8 burned';
  -- The starter without the token: refused.
  v_state := repeat('ef', 32);
  PERFORM public.exos_discord_install_begin(pg_temp.u('1'), pg_temp.u('d2'), v_state);
  PERFORM public.exos_oauth_state_return(v_state, 'discord-code-5678', v_fin);
  SELECT * INTO r FROM public.exos_discord_install_consume(v_state, pg_temp.u('d2'), repeat('00', 32));
  ASSERT r.refused = 'token', 'DC8 token';
  -- The right user with the token: the code.
  v_state := repeat('12', 32);
  PERFORM public.exos_discord_install_begin(pg_temp.u('1'), pg_temp.u('d2'), v_state);
  PERFORM public.exos_oauth_state_return(v_state, 'discord-code-9999', v_fin);
  SELECT * INTO r FROM public.exos_discord_install_consume(v_state, pg_temp.u('d2'), v_fin);
  ASSERT r.org_id = pg_temp.u('1') AND r.code = 'discord-code-9999' AND r.refused IS NULL, 'DC8 consumed';

  -- Link: role re-checked; one server per org.
  ASSERT pg_temp.st(format('SELECT public.exos_discord_guild_link(%L, %L, %L, %L)', pg_temp.u('1'), pg_temp.u('d3'), '423456789012345671', 'x'))
    LIKE '42501%', 'DC8 finance can''t link';
  ASSERT pg_temp.st(format('SELECT public.exos_discord_guild_link(%L, %L, %L, %L)', pg_temp.u('1'), pg_temp.u('d1'), '42', 'x'))
    LIKE '22023%', 'DC8 bad id';
  s := pg_temp.st(format('SELECT public.exos_discord_guild_link(%L, %L, %L, %L)', pg_temp.u('2'), pg_temp.u('d5'), '423456789012345671', 'B''s'));
  ASSERT s LIKE '23505%another Exos organization%' AND position('D15' IN s) = 0, 'DC8 one org per server: ' || s;
  ASSERT (public.exos_discord_guild_link(pg_temp.u('2'), pg_temp.u('d5'), '723456789012345674', E'B\nServer')->>'guild_name') = 'BServer',
    'DC8 B links its own (control characters dropped)';
  ASSERT (SELECT count(*) FROM public.exos_org_audit WHERE action = 'discord.guild_link') = 2, 'DC8 guild_link audited';
  -- Unlink: manager; B can't unlink A's.
  PERFORM pg_temp.act(pg_temp.u('d5'));
  ASSERT pg_temp.st(format('SELECT public.exos_discord_unlink_guild(%L)', pg_temp.u('1'))) LIKE '42501%', 'DC8 B unlinks A';
  PERFORM pg_temp.act(pg_temp.u('d2'));
  ASSERT public.exos_discord_unlink_guild(pg_temp.u('1')), 'DC8 manager unlinks';
  ASSERT NOT public.exos_discord_unlink_guild(pg_temp.u('1')), 'DC8 nothing left to unlink';
  ASSERT NOT (public.exos_discord_status(pg_temp.u('1'))->'guild'->>'linked')::boolean, 'DC8 status: not linked';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_sync_claim(5, NULL) c WHERE c.org_id = pg_temp.u('1')), 'DC8 no passes without a server';
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE action = 'discord.guild_unlink' AND org_id = pg_temp.u('1')), 'DC8 unlink audited';
  -- Now A's old server is free for B to... no: B already has one; but another org could link it.
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  DC8 bot install: discord state, finish token + starting user, one org per server, role re-checked, link / unlink audited';
END $$;

-- DC2 (end): removing the webhook deletes the Vault secret and fails queued posts.
DO $$
BEGIN
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  UPDATE public.exos_discord_posts SET status = 'queued' WHERE event_id = pg_temp.u('e2');
  PERFORM pg_temp.act(pg_temp.u('d2'));
  ASSERT public.exos_discord_remove_webhook(pg_temp.u('1')), 'DC2 removed';
  ASSERT NOT public.exos_discord_remove_webhook(pg_temp.u('1')), 'DC2 nothing to remove';
  ASSERT NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'exos_discord_webhook:' || pg_temp.u('1')), 'DC2 Vault secret gone';
  ASSERT (SELECT status FROM public.exos_discord_posts WHERE event_id = pg_temp.u('e2')) = 'error', 'DC2 queued post failed';
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE action = 'discord.webhook_remove' AND org_id = pg_temp.u('1')), 'DC2 remove audited';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK  DC2 remove: the Vault secret deleted, queued posts failed, audited';
END $$;

-- DC10 -----------------------------------------------------------------------
DO $$
DECLARE r jsonb; k int; v_fp text := repeat('ab', 16); v_fp2 text := repeat('cd', 16); c record;
BEGIN
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  -- Org A again: webhook + server, one shown event due.
  PERFORM pg_temp.act(pg_temp.u('d1'));
  PERFORM public.exos_discord_set_webhook(pg_temp.u('1'), pg_temp.hook('123456789012345678', pg_temp.tok('9')));
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_discord_guild_link(pg_temp.u('1'), pg_temp.u('d1'), '823456789012345676', 'D15 Again');
  UPDATE public.exos_discord_event_syncs SET show = true, status = 'pending', change_seq = change_seq + 1, next_try_at = now(),
         lease_id = NULL, lease_until = NULL WHERE event_id = pg_temp.u('e1');
  ASSERT (public.exos_discord_call_gate('bot', v_fp)->>'ok')::boolean, 'DC10 gate open';
  ASSERT pg_temp.st($q$SELECT public.exos_discord_call_gate('dm', NULL)$q$) LIKE '22023%', 'DC10 kinds';

  -- 300 calls a minute across every org.
  INSERT INTO public.exos_rate_windows (bucket, window_start, hits) VALUES ('discord_platform', date_trunc('minute', now()), 300)
  ON CONFLICT (bucket, window_start) DO UPDATE SET hits = 300;
  r := public.exos_discord_call_gate('webhook', NULL);
  ASSERT NOT (r->>'ok')::boolean AND r->>'reason' = 'platform_cap' AND (r->>'retry_after')::int = 60, 'DC10 platform cap: ' || r::text;
  DELETE FROM public.exos_rate_windows WHERE bucket = 'discord_platform';

  -- A 401 on the bot: bot calls stop, webhooks don't; the claim hands out nothing.
  r := public.exos_discord_call_result('bot', 401, 0, false, NULL, NULL, v_fp);
  ASSERT r->>'tripped' = 'bot' AND (r->>'invalid')::boolean, 'DC10 401 trips: ' || r::text;
  ASSERT public.exos_discord_call_gate('bot', v_fp)->>'reason' = 'breaker', 'DC10 bot calls stop';
  ASSERT (public.exos_discord_call_gate('webhook', NULL)->>'ok')::boolean, 'DC10 webhooks unaffected';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_sync_claim(5, NULL, v_fp)), 'DC10 no bot passes';
  PERFORM pg_temp.act(pg_temp.u('d1'));
  ASSERT (public.exos_discord_status(pg_temp.u('1'))->>'paused')::boolean, 'DC10 the panel says paused';
  PERFORM pg_temp.act(NULL);
  -- A new token clears it.
  SELECT * INTO c FROM public.exos_discord_sync_claim(5, NULL, v_fp2) x WHERE x.event_id = pg_temp.u('e1');
  ASSERT c.lease_id IS NOT NULL, 'DC10 a new token: passes again';
  ASSERT (SELECT breaker_scope FROM public.exos_discord_platform) IS NULL, 'DC10 cleared by the new token';
  -- The server refused the bot: that link is skipped until linked again.
  r := public.exos_discord_sync_mark(pg_temp.u('e1'), c.lease_id, c.change_seq,
         '{"state": "error", "link_broken": true, "guild_id": "823456789012345676", "error": "Discord: the Exos bot lost access"}');
  ASSERT (SELECT guild_broken_at IS NOT NULL FROM public.exos_discord_links WHERE org_id = pg_temp.u('1')), 'DC10 link marked broken';
  UPDATE public.exos_discord_event_syncs SET next_try_at = now() WHERE event_id = pg_temp.u('e1');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_sync_claim(5, NULL, v_fp2) x WHERE x.org_id = pg_temp.u('1')), 'DC10 broken link skipped';
  PERFORM pg_temp.act(pg_temp.u('d1'));
  ASSERT (public.exos_discord_status(pg_temp.u('1'))->'guild'->>'broken')::boolean, 'DC10 the panel says reconnect';
  ASSERT (public.exos_discord_event_status(pg_temp.u('e1'))->>'guild_broken')::boolean, 'DC10 the event panel too';
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_discord_guild_link(pg_temp.u('1'), pg_temp.u('d1'), '823456789012345676', 'D15 Again');
  ASSERT (SELECT guild_broken_at IS NULL FROM public.exos_discord_links WHERE org_id = pg_temp.u('1')), 'DC10 relinking clears it';
  -- "Sync now" waits out the backoff.
  UPDATE public.exos_discord_event_syncs SET next_try_at = now() + interval '5 minutes' WHERE event_id = pg_temp.u('e1');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_sync_claim(5, pg_temp.u('e1'), v_fp2)), 'DC10 sync now respects next_try_at';
  UPDATE public.exos_discord_event_syncs SET next_try_at = now() WHERE event_id = pg_temp.u('e1');

  -- A global 429: bot calls pause for retry_after; webhooks go on.
  PERFORM public.exos_discord_call_result('bot', 429, NULL, true, 'global', 42, v_fp2);
  r := public.exos_discord_call_gate('bot', v_fp2);
  ASSERT r->>'reason' = 'paused' AND (r->>'retry_after')::int BETWEEN 40 AND 43, 'DC10 global 429 pauses: ' || r::text;
  ASSERT (public.exos_discord_call_gate('webhook', NULL)->>'ok')::boolean, 'DC10 webhooks go on';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_sync_claim(5, NULL, v_fp2)), 'DC10 no passes while paused';
  -- A per-route 429 doesn't pause anything; a shared 429 isn't counted as invalid.
  PERFORM public.exos_discord_breaker_clear();
  PERFORM public.exos_discord_call_result('bot', 429, NULL, false, 'user', 3, v_fp2);
  ASSERT (public.exos_discord_call_gate('bot', v_fp2)->>'ok')::boolean, 'DC10 route 429: no pause';
  ASSERT NOT (public.exos_discord_call_result('bot', 429, NULL, false, 'shared', 3, v_fp2)->>'invalid')::boolean, 'DC10 shared 429 not invalid';

  -- (Over 500 invalid answers from 5+ orgs: DC11.) A breaker set by hand stops posts too, until cleared.
  UPDATE public.exos_discord_platform SET breaker_scope = 'all', breaker_at = now(), breaker_reason = 'test';
  ASSERT public.exos_discord_call_gate('webhook', NULL)->>'reason' = 'breaker' AND public.exos_discord_call_gate('bot', v_fp)->>'reason' = 'breaker',
    'DC10 every call stops';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_sync_claim(5, NULL, v_fp)), 'DC10 a new token does not clear it';
  PERFORM pg_temp.act(pg_temp.u('d1'));
  PERFORM public.exos_discord_request_post(pg_temp.u('e1'), 'reminder');
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_discord_posts SET status = 'queued', next_try_at = now(), attempts = 0 WHERE event_id = pg_temp.u('e1') AND kind = 'reminder';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_post_claim(5, NULL)), 'DC10 no posts while tripped';
  ASSERT public.exos_discord_breaker_clear(), 'DC10 the operator clears it';
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';

  -- A webhook Discord refused: marked broken (the one the post used), later posts error, a new URL clears it.
  SELECT * INTO c FROM public.exos_discord_post_claim(5, NULL) x WHERE x.event_id = pg_temp.u('e1') AND x.kind = 'reminder';
  ASSERT c.post_id IS NOT NULL, 'DC10 claimed after clearing';
  r := public.exos_discord_post_mark(c.post_id, c.lease_id, 'error', NULL, 'Discord: the webhook was deleted', NULL, NULL, true);
  ASSERT (SELECT webhook_broken_at IS NOT NULL FROM public.exos_discord_links WHERE org_id = pg_temp.u('1')), 'DC10 webhook marked broken';
  PERFORM pg_temp.act(pg_temp.u('d1'));
  ASSERT (public.exos_discord_status(pg_temp.u('1'))->'webhook'->>'broken')::boolean, 'DC10 the panel says paste a new one';
  PERFORM pg_temp.act(NULL);
  UPDATE public.exos_discord_posts SET status = 'queued', next_try_at = now() WHERE id = c.post_id;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_post_claim(5, c.post_id)), 'DC10 broken webhook: not claimed';
  ASSERT (SELECT status = 'error' AND last_error LIKE '%paste a new one%' FROM public.exos_discord_posts WHERE id = c.post_id), 'DC10 it errors';
  PERFORM pg_temp.act(pg_temp.u('d1'));
  PERFORM public.exos_discord_set_webhook(pg_temp.u('1'), pg_temp.hook('923456789012345677', pg_temp.tok('8')));
  PERFORM pg_temp.act(NULL);
  ASSERT (SELECT webhook_broken_at IS NULL FROM public.exos_discord_links WHERE org_id = pg_temp.u('1')), 'DC10 a new URL clears it';
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  RAISE NOTICE 'OK  DC10 breaker: platform cap, 401 stops bot calls (new token clears), global 429 pause, a set breaker stops all, broken links / webhooks skipped, sync now waits';
END $$;

-- DC11 -----------------------------------------------------------------------
DO $$
DECLARE r jsonb; i int; v_until timestamptz; v_org uuid;
BEGIN
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  PERFORM public.exos_discord_breaker_clear();
  -- Org B has a link row (its server from DC8). Org A floods invalid answers.
  FOR i IN 1..9 LOOP
    r := public.exos_discord_call_result('webhook', 403, 50013, false, NULL, NULL, NULL, pg_temp.u('1'));
  END LOOP;
  ASSERT (r->>'org_invalid_10min')::int = 9 AND r->>'org_paused_until' IS NULL, 'DC11 nine: not yet: ' || r::text;
  r := public.exos_discord_call_result('webhook', 403, 50013, false, NULL, NULL, NULL, pg_temp.u('1'));
  v_until := (r->>'org_paused_until')::timestamptz;
  ASSERT v_until BETWEEN now() + interval '29 minutes' AND now() + interval '31 minutes', 'DC11 the 10th pauses the org 30 minutes: ' || r::text;
  ASSERT EXISTS (SELECT 1 FROM public.exos_org_audit WHERE org_id = pg_temp.u('1') AND action = 'discord.org_paused'), 'DC11 audited';
  -- Its calls stop; another org's don't; its claims hand out nothing.
  r := public.exos_discord_call_gate('webhook', NULL, pg_temp.u('1'));
  ASSERT r->>'reason' = 'org_paused' AND (r->>'retry_after')::int > 1700, 'DC11 org A refused: ' || r::text;
  ASSERT (public.exos_discord_call_gate('webhook', NULL, pg_temp.u('2'))->>'ok')::boolean, 'DC11 org B goes on';
  UPDATE public.exos_discord_event_syncs SET change_seq = change_seq + 1, next_try_at = now(), lease_id = NULL, lease_until = NULL
   WHERE event_id = pg_temp.u('e1');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_sync_claim(5, NULL, repeat('cd', 16)) x WHERE x.org_id = pg_temp.u('1')), 'DC11 no passes for A';
  UPDATE public.exos_discord_posts SET status = 'queued', next_try_at = now() WHERE event_id = pg_temp.u('e1') AND kind = 'reminder';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_discord_post_claim(5, NULL) x WHERE x.org_id = pg_temp.u('1')), 'DC11 no posts for A';
  ASSERT (SELECT next_try_at >= v_until - interval '1 second' FROM public.exos_discord_posts WHERE event_id = pg_temp.u('e1') AND kind = 'reminder'),
    'DC11 the post waits for the pause';
  PERFORM pg_temp.act(pg_temp.u('d1'));
  ASSERT (public.exos_discord_status(pg_temp.u('1'))->>'org_paused_until')::timestamptz = v_until, 'DC11 the panel says until when';
  -- Re-saving the webhook or relinking the server doesn't reset it.
  PERFORM public.exos_discord_set_webhook(pg_temp.u('1'), pg_temp.hook('923456789012345677', pg_temp.tok('7')));
  PERFORM pg_temp.act(NULL);
  PERFORM public.exos_discord_guild_link(pg_temp.u('1'), pg_temp.u('d1'), '823456789012345676', 'D15 Again');
  ASSERT (SELECT invalid_paused_until = v_until AND invalid_pause_count = 1 FROM public.exos_discord_links WHERE org_id = pg_temp.u('1')),
    'DC11 re-saving / relinking keeps the pause';
  -- A paused org's answers don't count, and one org never trips 'all', whatever the volume.
  INSERT INTO public.exos_rate_windows (bucket, window_start, hits) VALUES ('discord_invalid', date_trunc('minute', now()), 5000)
  ON CONFLICT (bucket, window_start) DO UPDATE SET hits = 5000;
  r := public.exos_discord_call_result('webhook', 403, 50013, false, NULL, NULL, NULL, pg_temp.u('1'));
  ASSERT (r->>'invalid_10min')::int = 0 AND r->>'tripped' IS NULL, 'DC11 a paused org counts for nothing: ' || r::text;
  r := public.exos_discord_call_result('bot', 403, 50001, false, NULL, NULL, NULL, pg_temp.u('2'));
  ASSERT (r->>'invalid_10min')::int > 500 AND (r->>'orgs_10min')::int = 1 AND r->>'tripped' IS NULL, 'DC11 one org never trips it: ' || r::text;
  ASSERT (SELECT breaker_scope FROM public.exos_discord_platform) IS NULL, 'DC11 still open';
  -- A repeat pause doubles (within a day of the last one).
  UPDATE public.exos_discord_links SET invalid_paused_until = now() - interval '1 minute' WHERE org_id = pg_temp.u('1');
  DELETE FROM public.exos_rate_windows WHERE bucket = 'discord_invalid:' || pg_temp.u('1')::text;
  FOR i IN 1..10 LOOP
    r := public.exos_discord_call_result('webhook', 401, NULL, false, NULL, NULL, NULL, pg_temp.u('1'));
  END LOOP;
  ASSERT (r->>'org_paused_until')::timestamptz BETWEEN now() + interval '59 minutes' AND now() + interval '61 minutes'
     AND (SELECT invalid_pause_count FROM public.exos_discord_links WHERE org_id = pg_temp.u('1')) = 2, 'DC11 the second pause is an hour: ' || r::text;
  -- Five orgs over the threshold trip it.
  FOR i IN 3..6 LOOP
    v_org := pg_temp.u(i::text);
    INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES (v_org, 'D15 Org ' || i, 'd15-org-' || i, pg_temp.u('d5'));
    INSERT INTO public.exos_discord_links (org_id) VALUES (v_org);
    INSERT INTO public.exos_rate_windows (bucket, window_start, hits) VALUES ('discord_invalid:' || v_org::text, date_trunc('minute', now()), 3);
  END LOOP;
  r := public.exos_discord_call_result('webhook', 403, 50013, false, NULL, NULL, NULL, pg_temp.u('2'));
  ASSERT (r->>'orgs_10min')::int = 5 AND r->>'tripped' = 'all', 'DC11 five orgs trip it: ' || r::text;
  ASSERT public.exos_discord_call_gate('webhook', NULL, pg_temp.u('2'))->>'reason' = 'breaker', 'DC11 every call stops';
  -- It cools down by itself after 15 minutes.
  UPDATE public.exos_discord_platform SET breaker_at = now() - interval '16 minutes';
  ASSERT (public.exos_discord_call_gate('webhook', NULL, pg_temp.u('2'))->>'ok')::boolean, 'DC11 cooled down';
  ASSERT (SELECT breaker_scope FROM public.exos_discord_platform) IS NULL, 'DC11 cleared';
  -- The bot-token breaker doesn't cool down.
  PERFORM public.exos_discord_call_result('bot', 401, NULL, false, NULL, NULL, repeat('ef', 16), NULL);
  UPDATE public.exos_discord_platform SET breaker_at = now() - interval '2 hours';
  ASSERT public.exos_discord_call_gate('bot', repeat('ef', 16), pg_temp.u('2'))->>'reason' = 'breaker', 'DC11 the 401 breaker stays';
  PERFORM public.exos_discord_breaker_clear();
  DELETE FROM public.exos_rate_windows WHERE bucket LIKE 'discord%';
  RAISE NOTICE 'OK  DC11 per-org pause (10 in 10 min, 30 min doubling, audited, kept on re-save), one org never trips, 5 orgs do, 15-minute cooldown';
END $$;

-- DC9 ------------------------------------------------------------------------
DO $$
DECLARE m text;
BEGIN
  FOREACH m IN ARRAY ARRAY['discord.webhook_set', 'discord.webhook_remove', 'discord.settings', 'discord.guild_link',
                           'discord.guild_unlink', 'discord.event_show', 'discord.post', 'discord.org_paused'] LOOP
    ASSERT (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
              AND position('/* exos: audit ' || m || ' */' in pg_get_functiondef(p.oid)) > 0) = 1, 'DC9 marker ' || m;
  END LOOP;
  RAISE NOTICE 'OK  DC9 eight audit markers';
END $$;

ROLLBACK;
