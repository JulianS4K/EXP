-- ============================================================================
-- Group chat, masked SMS relay, mutual reveal (mig 20261031230000).
--   GC1  groups: owner / manager create and add; joining by policy; RLS: only
--        active members read messages; staff only through the logged
--        moderation read; anon has no grant
--   GC2  routing: a pool number per (member, group) on join; one person never
--        holds a number twice; a shared phone never shares a number between
--        two live groups (the routing key); an exhausted pool says so
--   GC3  inbound relay: (from, to) finds the group; the text lands in the chat
--        and fans out to the other opted-in members from THEIR own numbers,
--        "<first name>: text", links replaced; unknown senders / duplicates
--        ignored; app posts fan out too
--   GC4  STOP leaves that group's relay; STOPALL is global; START undoes; HELP
--        answers; the drain skips stopped recipients
--   GC5  daily cost cap per group: over the cap texts are skipped and the
--        chat says so once
--   GC6  limits: length, links, 10 a minute, idempotent client ref
--   GC7  block (both ways, app + SMS), mute, 3 reports hide a message
--   GC8  mutual reveal: only when both share the same kind with each other,
--        never one-sided, not before the event, not across a block; revoke
--        erases; every share / revoke / first view logged
--   GC9  cross-org isolation
--   GC10 close N days after the event; retention sweep purges and frees numbers
--   GC11 grants
--   GC12 the matched-seats seam: draft / revealed / dissolved, one row per ticket
-- Self-contained ids c3…; runs after the full run_p0.sh chain.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('c3000000-0000-0000-0000-0000000000a1','gc-own@x.com',now()),
  ('c3000000-0000-0000-0000-0000000000a2','gc-own2@x.com',now()),
  ('c3000000-0000-0000-0000-0000000000a3','gc-scan@x.com',now()),
  ('c3000000-0000-0000-0000-0000000000b1','gc-m1@x.com',now()),
  ('c3000000-0000-0000-0000-0000000000b2','gc-m2@x.com',now()),
  ('c3000000-0000-0000-0000-0000000000b3','gc-m3@x.com',now()),
  ('c3000000-0000-0000-0000-0000000000b4','gc-m4@x.com',now()),
  ('c3000000-0000-0000-0000-0000000000b5','gc-m5@x.com',now()),
  ('c3000000-0000-0000-0000-0000000000b9','gc-out@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('c3000000-0000-0000-0000-000000000001','GC Club','gc-club','c3000000-0000-0000-0000-0000000000a1'),
  ('c3000000-0000-0000-0000-000000000002','GC Other','gc-other','c3000000-0000-0000-0000-0000000000a2');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('c3000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-0000000000a1','owner'),
  ('c3000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-0000000000a3','scanner'),
  ('c3000000-0000-0000-0000-000000000002','c3000000-0000-0000-0000-0000000000a2','owner');
-- e1 ended yesterday (reveal open, chat open for 7 days); e2 is next week.
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,ends_at,timezone,total_tickets,created_by) VALUES
  ('c3000000-0000-0000-0000-0000000000e1','c3000000-0000-0000-0000-000000000001','GC Past','gc-past','published',
   now() - interval '30 hours', now() - interval '26 hours','America/New_York',100,'c3000000-0000-0000-0000-0000000000a1'),
  ('c3000000-0000-0000-0000-0000000000e2','c3000000-0000-0000-0000-000000000001','GC Next','gc-next','published',
   now() + interval '7 days', NULL,'America/New_York',100,'c3000000-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('c3000000-0000-0000-0000-0000000000d2','c3000000-0000-0000-0000-0000000000e2','GA',20,100,1,'public');
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,buyer_email,status,barcode_secret,price_paid,order_ref,channel_source) VALUES
  ('c3000000-0000-0000-0000-000000000c41','c3000000-0000-0000-0000-0000000000e2','c3000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-0000000000d2','GA',
   'c3000000-0000-0000-0000-0000000000b4','c3000000-0000-0000-0000-0000000000b4','gc-m4@x.com','active','k',20,'cs_gc4','stripe');
-- The platform pool: three numbers.
INSERT INTO public.exos_sms_relay_numbers(id,provider,phone,created_at) VALUES
  ('c3000000-0000-0000-0000-0000000000f1','twilio','+13325550001', now() - interval '3 minutes'),
  ('c3000000-0000-0000-0000-0000000000f2','twilio','+13325550002', now() - interval '2 minutes'),
  ('c3000000-0000-0000-0000-0000000000f3','telnyx','+13325550003', now() - interval '1 minute');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('c3000000-0000-0000-0000-' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated;
CREATE FUNCTION pg_temp.refused(p_sql text, p_like text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  IF SQLERRM NOT LIKE '%' || p_like || '%' THEN
    RAISE EXCEPTION 'expected "%", got % "%"', p_like, SQLSTATE, SQLERRM;
  END IF;
  RETURN true;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.refused(text, text) TO anon, authenticated;
CREATE TEMP TABLE consent AS SELECT 'Text me this group''s messages from an Exos number. Msg frequency varies. Msg & data rates may apply. Reply STOP to cancel, HELP for help.'::text AS t;
GRANT SELECT ON consent TO authenticated;
CREATE TEMP TABLE ids (k text PRIMARY KEY, v uuid);
GRANT ALL ON ids TO authenticated;

-- GC1 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a3');
SELECT set_config('gc.scan', pg_temp.refused($$SELECT public.exos_group_create(pg_temp.u('000000000001'), 'Table 4')$$, 'owner or manager')::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a1');
INSERT INTO ids VALUES ('g1', public.exos_group_create(pg_temp.u('000000000001'), 'Table 4', 'matched_table', pg_temp.u('0000000000e1')));
INSERT INTO ids VALUES ('g2', public.exos_group_create(pg_temp.u('000000000001'), 'Next week crew', 'event_attendees', pg_temp.u('0000000000e2')));
SELECT set_config('gc.badcap', pg_temp.refused($$SELECT public.exos_group_create(pg_temp.u('000000000001'), 'X', 'custom', pg_temp.u('0000000000e1'), NULL, 7, 9999)$$, 'daily text cap')::text, true);
SELECT set_config('gc.noevent', pg_temp.refused($$SELECT public.exos_group_create(pg_temp.u('000000000001'), 'X', 'custom')$$, 'pick one of your events')::text, true);
SELECT public.exos_group_add_member((SELECT v FROM ids WHERE k='g1'), pg_temp.u('0000000000b1'));
SELECT public.exos_group_add_member((SELECT v FROM ids WHERE k='g1'), pg_temp.u('0000000000b2'));
SELECT public.exos_group_add_member((SELECT v FROM ids WHERE k='g1'), pg_temp.u('0000000000b3'));
SELECT public.exos_group_add_member((SELECT v FROM ids WHERE k='g1'), pg_temp.u('0000000000b5'));
SELECT public.exos_group_add_member((SELECT v FROM ids WHERE k='g2'), pg_temp.u('0000000000b1'));
-- Invite-only: an outsider can't join g1. Ticket holders: b4 joins g2, b9 can't.
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b9');
SELECT set_config('gc.inv', pg_temp.refused($$SELECT public.exos_group_join((SELECT v FROM ids WHERE k='g1'))$$, 'invite only')::text, true);
SELECT set_config('gc.tix', pg_temp.refused($$SELECT public.exos_group_join((SELECT v FROM ids WHERE k='g2'))$$, 'ticket holders')::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b4');
SELECT public.exos_group_join((SELECT v FROM ids WHERE k='g2'));
-- Names (first names go on relayed texts).
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b1');
SELECT public.exos_group_set_name((SELECT v FROM ids WHERE k='g1'), 'Mo  Sender');
SELECT public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'Hi table four!', 'ref-1');
SELECT set_config('gc.m1sees', (SELECT count(*) FROM public.exos_group_messages WHERE group_id = (SELECT v FROM ids WHERE k='g1'))::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b2');
SELECT public.exos_group_set_name((SELECT v FROM ids WHERE k='g1'), 'Ana');
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b3');
SELECT public.exos_group_set_name((SELECT v FROM ids WHERE k='g1'), 'Cal');
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b9');
SELECT set_config('gc.outmsg', (SELECT count(*) FROM public.exos_group_messages)::text, true);
SELECT set_config('gc.outgrp', (SELECT count(*) FROM public.exos_social_groups WHERE org_id = pg_temp.u('000000000001'))::text, true);
SELECT set_config('gc.outmem', (SELECT count(*) FROM public.exos_social_group_members WHERE org_id = pg_temp.u('000000000001'))::text, true);
SELECT set_config('gc.outpost', pg_temp.refused($$SELECT public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'let me in')$$, 'not in this group')::text, true);
SELECT set_config('gc.outstate', pg_temp.refused($$SELECT public.exos_group_state((SELECT v FROM ids WHERE k='g1'))$$, 'not a member')::text, true);
-- Staff: no RLS read; the moderation read needs a reason and is logged.
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a1');
SELECT set_config('gc.staffrls', (SELECT count(*) FROM public.exos_group_messages)::text, true);
SELECT set_config('gc.staffgrp', (SELECT count(*) FROM public.exos_social_groups WHERE org_id = pg_temp.u('000000000001'))::text, true);
SELECT set_config('gc.noreason', pg_temp.refused($$SELECT public.exos_group_moderation_read((SELECT v FROM ids WHERE k='g1'), 'hm')$$, 'reason')::text, true);
SELECT set_config('gc.modread', jsonb_array_length(public.exos_group_moderation_read((SELECT v FROM ids WHERE k='g1'), 'checking a complaint'))::text, true);
RESET ROLE;
SET LOCAL ROLE anon;
SELECT set_config('gc.anon', pg_temp.refused($$SELECT count(*) FROM public.exos_group_messages$$, 'permission denied')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('gc.scan')::boolean AND current_setting('gc.badcap')::boolean AND current_setting('gc.noevent')::boolean, 'GC1: create refusals';
  ASSERT current_setting('gc.inv')::boolean AND current_setting('gc.tix')::boolean, 'GC1: join policies';
  ASSERT EXISTS (SELECT 1 FROM public.exos_social_group_members m JOIN ids ON ids.k='g2' AND ids.v = m.group_id
                  WHERE m.user_id = pg_temp.u('0000000000b4') AND m.status = 'active'), 'GC1: ticket holder joined';
  ASSERT current_setting('gc.m1sees')::int = 1, 'GC1: a member reads';
  ASSERT current_setting('gc.outmsg')::int = 0 AND current_setting('gc.outgrp')::int = 0 AND current_setting('gc.outmem')::int = 0,
         'GC1: an outsider reads nothing';
  ASSERT current_setting('gc.outpost')::boolean AND current_setting('gc.outstate')::boolean, 'GC1: an outsider can''t post';
  ASSERT current_setting('gc.staffrls')::int = 0 AND current_setting('gc.staffgrp')::int = 2, 'GC1: staff see groups, not messages';
  ASSERT current_setting('gc.noreason')::boolean AND current_setting('gc.modread')::int = 1, 'GC1: moderation read';
  ASSERT (SELECT count(*) FROM public.exos_group_moderation_log WHERE action = 'read' AND reason = 'checking a complaint'
            AND actor_id = pg_temp.u('0000000000a1')) = 1, 'GC1: read logged';
  ASSERT current_setting('gc.anon')::boolean, 'GC1: anon has no grant';
  ASSERT (SELECT org_id FROM public.exos_group_messages LIMIT 1) = pg_temp.u('000000000001'), 'GC1: org_id from the group';
  RAISE NOTICE 'OK  GC1 groups, joining, RLS, logged moderation read';
END $$;

-- GC2 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b1');
SELECT set_config('gc.o1', public.exos_group_sms_opt_in((SELECT v FROM ids WHERE k='g1'), '(212) 555-0101', (SELECT t FROM consent))::text, true);
SELECT set_config('gc.o1b', public.exos_group_sms_opt_in((SELECT v FROM ids WHERE k='g2'), '2125550101', (SELECT t FROM consent))::text, true);
SELECT set_config('gc.nocons', pg_temp.refused($$SELECT public.exos_group_sms_opt_in((SELECT v FROM ids WHERE k='g1'), '2125550101', 'ok text me anything you like')$$, 'consent')::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b2');
SELECT public.exos_group_sms_opt_in((SELECT v FROM ids WHERE k='g1'), '2125550102', (SELECT t FROM consent));
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b3');
SELECT public.exos_group_sms_opt_in((SELECT v FROM ids WHERE k='g1'), '2125550103', (SELECT t FROM consent));
-- b4 shares b1's phone (one household phone, two accounts) and opts in to g2.
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b4');
SELECT public.exos_group_sms_opt_in((SELECT v FROM ids WHERE k='g2'), '2125550101', (SELECT t FROM consent));
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a1');
INSERT INTO ids VALUES ('g3', public.exos_group_create(pg_temp.u('000000000001'), 'Third', 'community', pg_temp.u('0000000000e1')));
INSERT INTO ids VALUES ('g4', public.exos_group_create(pg_temp.u('000000000001'), 'Fourth', 'community', pg_temp.u('0000000000e1')));
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b1');
SELECT public.exos_group_join((SELECT v FROM ids WHERE k='g3'));
SELECT public.exos_group_join((SELECT v FROM ids WHERE k='g4'));
SELECT set_config('gc.full', pg_temp.refused($$SELECT public.exos_group_sms_opt_in((SELECT v FROM ids WHERE k='g4'), '2125550101', (SELECT t FROM consent))$$, 'no text number is free')::text, true);
SELECT set_config('gc.st4', public.exos_group_state((SELECT v FROM ids WHERE k='g4'))::text, true);
SELECT set_config('gc.st1', public.exos_group_state((SELECT v FROM ids WHERE k='g1'))::text, true);
RESET ROLE;
DO $$
DECLARE dup boolean := false;
BEGIN
  ASSERT current_setting('gc.nocons')::boolean, 'GC2: consent required';
  ASSERT (SELECT count(*) FROM public.exos_sms_relay_assignments WHERE released_at IS NULL) = 8, 'GC2: one assignment per member and group';
  ASSERT current_setting('gc.o1')::jsonb->>'relay_number' <> current_setting('gc.o1b')::jsonb->>'relay_number',
         'GC2: b1 has different numbers in g1 and g2';
  ASSERT NOT EXISTS (SELECT phone, number_id FROM public.exos_sms_relay_assignments
                      WHERE released_at IS NULL AND phone IS NOT NULL AND number_id IS NOT NULL
                      GROUP BY 1, 2 HAVING count(*) > 1), 'GC2: routing key unique (shared phone)';
  ASSERT NOT EXISTS (SELECT user_id, number_id FROM public.exos_sms_relay_assignments
                      WHERE released_at IS NULL AND number_id IS NOT NULL GROUP BY 1, 2 HAVING count(*) > 1), 'GC2: per person';
  ASSERT current_setting('gc.full')::boolean AND current_setting('gc.st4')::jsonb#>>'{me,relay_number}' IS NULL, 'GC2: pool exhausted';
  ASSERT current_setting('gc.st1')::jsonb#>>'{me,sms_phone_hint}' = '…0101'
         AND (current_setting('gc.st1')::jsonb#>>'{me,sms_on}')::boolean
         AND current_setting('gc.st1')::text NOT LIKE '%2125550102%', 'GC2: state shows my hint, nobody''s number';
  ASSERT (SELECT count(*) FROM public.exos_sms_relay_consents WHERE action = 'opt_in' AND consent_text LIKE '%STOP%') = 5, 'GC2: consent log';
  ASSERT (SELECT count(*) FROM public.exos_sms_relay_outbox WHERE kind = 'confirm') = 5, 'GC2: confirmations queued';
  BEGIN
    INSERT INTO public.exos_sms_relay_assignments (group_id, user_id, number_id, phone)
    SELECT (SELECT v FROM ids WHERE k='g3'), pg_temp.u('0000000000b2'), a.number_id, a.phone
      FROM public.exos_sms_relay_assignments a JOIN ids ON ids.k='g1' AND ids.v = a.group_id WHERE a.user_id = pg_temp.u('0000000000b1');
  EXCEPTION WHEN unique_violation THEN dup := true;
  END;
  ASSERT dup, 'GC2: the routing index refuses a second group on the same (phone, number)';
  RAISE NOTICE 'OK  GC2 routing uniqueness';
END $$;

-- GC3 ----------------------------------------------------------------------
DO $$
DECLARE
  g1 uuid := (SELECT v FROM ids WHERE k='g1');
  n1 text := (SELECT n.phone FROM public.exos_sms_relay_assignments a JOIN public.exos_sms_relay_numbers n ON n.id = a.number_id
               WHERE a.group_id = g1 AND a.user_id = pg_temp.u('0000000000b1') AND a.released_at IS NULL);
  p1 text := (SELECT n.provider FROM public.exos_sms_relay_numbers n WHERE n.phone = n1);
  r jsonb;
BEGIN
  r := public.exos_sms_relay_inbound(p1, '+12125550101', n1, 'hey all see https://evil.example/x ok', NULL, 'SM-1');
  ASSERT r->>'action' = 'relayed' AND (r->>'group_id')::uuid = g1 AND (r->>'queued')::int = 2, 'GC3: relayed ' || r::text;
  ASSERT (SELECT source FROM public.exos_group_messages WHERE id = (r->>'message_id')::uuid) = 'sms', 'GC3: in the chat';
  ASSERT (SELECT count(*) FROM public.exos_sms_relay_outbox o JOIN public.exos_sms_relay_assignments a ON a.id = o.assignment_id
           WHERE o.message_id = (r->>'message_id')::uuid AND o.number_id = a.number_id AND o.to_phone = a.phone
             AND o.body = 'Mo: hey all see [link in app] ok') = 2, 'GC3: each from their own number, formatted';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_outbox WHERE message_id = (r->>'message_id')::uuid
                      AND recipient_user_id = pg_temp.u('0000000000b1')), 'GC3: not back to the sender';
  ASSERT (SELECT bool_and(((send_after AT TIME ZONE 'America/New_York')::time >= time '09:00'
                           AND (send_after AT TIME ZONE 'America/New_York')::time < time '20:00') OR send_after <= now())
            FROM public.exos_sms_relay_outbox WHERE kind = 'relay'), 'GC3: quiet hours';
  ASSERT public.exos_sms_relay_inbound(p1, '+12125550101', n1, 'again', NULL, 'SM-1')->>'action' = 'duplicate', 'GC3: provider ref dedupe';
  ASSERT public.exos_sms_relay_inbound(p1, '+19175550199', n1, 'who dis', NULL, 'SM-2')->>'action' = 'unknown_sender', 'GC3: stranger';
  ASSERT public.exos_sms_relay_inbound(CASE p1 WHEN 'twilio' THEN 'telnyx' ELSE 'twilio' END, '+12125550101', n1, 'x', NULL, 'SM-3')->>'action'
         = 'unknown_number', 'GC3: provider must own the number';
  -- b4 (same phone as b1) texting b4's g2 number lands in g2.
  r := public.exos_sms_relay_inbound(
         (SELECT n.provider FROM public.exos_sms_relay_assignments a JOIN public.exos_sms_relay_numbers n ON n.id = a.number_id
           WHERE a.user_id = pg_temp.u('0000000000b4') AND a.released_at IS NULL),
         '+12125550101',
         (SELECT n.phone FROM public.exos_sms_relay_assignments a JOIN public.exos_sms_relay_numbers n ON n.id = a.number_id
           WHERE a.user_id = pg_temp.u('0000000000b4') AND a.released_at IS NULL), 'g2 hello', NULL, 'SM-4');
  ASSERT (r->>'group_id')::uuid = (SELECT v FROM ids WHERE k='g2')
         AND (SELECT sender_id FROM public.exos_group_messages WHERE id = (r->>'message_id')::uuid) = pg_temp.u('0000000000b4'), 'GC3: shared phone routes by number';
  RAISE NOTICE 'OK  GC3 inbound relay and fan-out';
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b2');
SELECT set_config('gc.p2', public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'from the app')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT (current_setting('gc.p2')::jsonb->>'sms_queued')::int = 2, 'GC3: an app post fans out to b1 and b3';
  ASSERT (SELECT count(*) FROM public.exos_sms_relay_outbox WHERE message_id = (current_setting('gc.p2')::jsonb->>'message_id')::uuid
           AND body = 'Ana: from the app') = 2, 'GC3: app post body';
END $$;

-- GC4 ----------------------------------------------------------------------
DO $$
DECLARE
  g1 uuid := (SELECT v FROM ids WHERE k='g1');
  a3 public.exos_sms_relay_assignments%ROWTYPE;
  a2 public.exos_sms_relay_assignments%ROWTYPE;
  n3 public.exos_sms_relay_numbers%ROWTYPE;
  n2 public.exos_sms_relay_numbers%ROWTYPE;
  r jsonb;
  c int := 0;
  rec record;
BEGIN
  SELECT * INTO a3 FROM public.exos_sms_relay_assignments WHERE group_id = g1 AND user_id = pg_temp.u('0000000000b3') AND released_at IS NULL;
  SELECT * INTO n3 FROM public.exos_sms_relay_numbers WHERE id = a3.number_id;
  SELECT * INTO a2 FROM public.exos_sms_relay_assignments WHERE group_id = g1 AND user_id = pg_temp.u('0000000000b2') AND released_at IS NULL;
  SELECT * INTO n2 FROM public.exos_sms_relay_numbers WHERE id = a2.number_id;

  r := public.exos_sms_relay_inbound(n3.provider, a3.phone, n3.phone, 'STOP', 'stop', 'SM-10');
  ASSERT r->>'action' = 'stopped', 'GC4: stop ' || r::text;
  ASSERT (SELECT sms_stopped_at IS NOT NULL FROM public.exos_sms_relay_assignments WHERE id = a3.id), 'GC4: stopped';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_outbox WHERE assignment_id = a3.id AND status = 'queued' AND kind <> 'reply'),
         'GC4: queued texts to b3 skipped';
  ASSERT EXISTS (SELECT 1 FROM public.exos_sms_relay_outbox WHERE to_phone = a3.phone AND kind = 'reply' AND body LIKE '%START%'), 'GC4: STOP confirmed';
  ASSERT (SELECT count(*) FROM public.exos_sms_relay_consents WHERE phone = a3.phone AND action = 'stop' AND source = 'sms') = 1, 'GC4: logged';
  -- Inbound from a stopped member isn't relayed.
  ASSERT public.exos_sms_relay_inbound(n3.provider, a3.phone, n3.phone, 'still here', NULL, 'SM-11')->>'action' = 'stopped_sender', 'GC4: stopped sender';
  r := public.exos_sms_relay_inbound(n3.provider, a3.phone, n3.phone, 'START', 'start', 'SM-12');
  ASSERT r->>'action' = 'started' AND (SELECT sms_stopped_at IS NULL FROM public.exos_sms_relay_assignments WHERE id = a3.id), 'GC4: start';
  -- HELP answers with STOP / HELP wording.
  ASSERT public.exos_sms_relay_inbound(n3.provider, a3.phone, n3.phone, 'help', 'help', 'SM-13')->>'action' = 'help', 'GC4: help';
  ASSERT EXISTS (SELECT 1 FROM public.exos_sms_relay_outbox WHERE to_phone = a3.phone AND kind = 'reply'
                  AND body LIKE 'Exos group chat: texts to this number go to "Table 4"%STOPALL%'), 'GC4: help text';
  ASSERT public.exos_sms_relay_inbound(n3.provider, '+19175550199', n3.phone, 'HELP', 'help', 'SM-14')->>'action' = 'help', 'GC4: help for anyone';
  -- STOPALL from b2's phone: global.
  r := public.exos_sms_relay_inbound(n2.provider, a2.phone, n2.phone, 'stop all', 'stop_all', 'SM-15');
  ASSERT r->>'action' = 'stopped_all' AND EXISTS (SELECT 1 FROM public.exos_sms_relay_stops WHERE phone = a2.phone), 'GC4: stopall';
  -- A new message doesn't go to b2 (global stop) but goes to b3 (started again).
  r := public.exos_sms_relay_inbound((SELECT provider FROM public.exos_sms_relay_numbers n JOIN public.exos_sms_relay_assignments a ON a.number_id = n.id
                                       WHERE a.group_id = g1 AND a.user_id = pg_temp.u('0000000000b1') AND a.released_at IS NULL),
                                     '+12125550101',
                                     (SELECT n.phone FROM public.exos_sms_relay_numbers n JOIN public.exos_sms_relay_assignments a ON a.number_id = n.id
                                       WHERE a.group_id = g1 AND a.user_id = pg_temp.u('0000000000b1') AND a.released_at IS NULL),
                                     'after stops', NULL, 'SM-16');
  ASSERT (r->>'queued')::int = 1 AND EXISTS (SELECT 1 FROM public.exos_sms_relay_outbox WHERE message_id = (r->>'message_id')::uuid
                                              AND recipient_user_id = pg_temp.u('0000000000b3')), 'GC4: only b3 ' || r::text;
  -- Bad keyword from the edge function is refused.
  BEGIN
    PERFORM public.exos_sms_relay_inbound('twilio', a3.phone, n3.phone, 'x', 'unsubscribe', NULL);
    RAISE EXCEPTION 'GC4: bad keyword accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  -- Drain: everything due gets claimed; a relay row to a stopped phone is skipped at claim time.
  UPDATE public.exos_sms_relay_outbox SET send_after = now() - interval '1 second' WHERE status = 'queued';
  INSERT INTO public.exos_sms_relay_outbox (org_id, group_id, kind, assignment_id, recipient_user_id, number_id, to_phone, body, segments)
  VALUES (a2.org_id, g1, 'relay', a2.id, a2.user_id, a2.number_id, a2.phone, 'Mo: late', 1);
  FOR rec IN SELECT * FROM public.exos_sms_relay_claim(200) LOOP
    ASSERT rec.to_phone <> a2.phone OR EXISTS (SELECT 1 FROM public.exos_sms_relay_outbox o WHERE o.id = rec.id AND o.kind = 'reply'),
           'GC4: claim skipped the stopped phone';
    PERFORM public.exos_sms_relay_mark(rec.id, 'dry_run');
    c := c + 1;
  END LOOP;
  ASSERT c > 0 AND EXISTS (SELECT 1 FROM public.exos_sms_relay_outbox WHERE body = 'Mo: late' AND status = 'skipped'), 'GC4: drain';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_outbox WHERE status IN ('queued', 'sending')), 'GC4: all handled';
  RAISE NOTICE 'OK  GC4 STOP / STOPALL / START / HELP';
END $$;

-- GC5 ----------------------------------------------------------------------
DO $$
DECLARE
  g1 uuid := (SELECT v FROM ids WHERE k='g1');
  used int := (SELECT coalesce(sum(segments), 0) FROM public.exos_sms_relay_outbox
                WHERE group_id = g1 AND created_at > now() - interval '24 hours' AND status <> 'skipped');
BEGIN
  UPDATE public.exos_social_groups SET daily_sms_cap = used + 1 WHERE id = g1;
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b2');
SELECT set_config('gc.cap1', public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'one more')::text, true);
SELECT set_config('gc.cap2', public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'and another')::text, true);
RESET ROLE;
DO $$
DECLARE g1 uuid := (SELECT v FROM ids WHERE k='g1');
BEGIN
  -- Recipients now b1, b3: the first fits one text, the rest are over the cap.
  ASSERT (current_setting('gc.cap1')::jsonb->>'sms_queued')::int = 1 AND (current_setting('gc.cap1')::jsonb->>'sms_capped')::int = 1,
         'GC5: cap ' || current_setting('gc.cap1');
  ASSERT (current_setting('gc.cap2')::jsonb->>'sms_queued')::int = 0, 'GC5: capped';
  ASSERT (SELECT count(*) FROM public.exos_sms_relay_outbox WHERE group_id = g1 AND error = 'group daily cap') = 3, 'GC5: skipped rows';
  ASSERT (SELECT count(*) FROM public.exos_group_messages WHERE group_id = g1 AND source = 'system' AND body LIKE 'Texts are paused%') = 1,
         'GC5: one notice';
  ASSERT (SELECT coalesce(sum(segments), 0) FROM public.exos_sms_relay_outbox
           WHERE group_id = g1 AND created_at > now() - interval '24 hours' AND status <> 'skipped')
         <= (SELECT daily_sms_cap FROM public.exos_social_groups WHERE id = g1), 'GC5: never over';
  UPDATE public.exos_social_groups SET daily_sms_cap = 300 WHERE id = g1;
  RAISE NOTICE 'OK  GC5 daily cost cap';
END $$;

-- GC6 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b5');
SELECT set_config('gc.long', pg_temp.refused($$SELECT public.exos_group_post((SELECT v FROM ids WHERE k='g1'), repeat('x', 1001))$$, '1,000 characters')::text, true);
SELECT set_config('gc.links', pg_temp.refused($$SELECT public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'a http://a.b b https://c.d c www.e.f d http://g.h')$$, '3 links')::text, true);
SELECT set_config('gc.empty', pg_temp.refused($$SELECT public.exos_group_post((SELECT v FROM ids WHERE k='g1'), '   ')$$, '1 to 1,000')::text, true);
SELECT set_config('gc.ref1', public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'same', 'dup-ref')::text, true);
SELECT set_config('gc.ref2', public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'same', 'dup-ref')::text, true);
DO $$
BEGIN
  FOR i IN 1..9 LOOP
    PERFORM public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'msg ' || i);
  END LOOP;
END $$;
SELECT set_config('gc.rate', pg_temp.refused($$SELECT public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'eleventh')$$, '10 messages a minute')::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('gc.long')::boolean AND current_setting('gc.links')::boolean AND current_setting('gc.empty')::boolean, 'GC6: caps';
  ASSERT (current_setting('gc.ref2')::jsonb->>'duplicate')::boolean
         AND current_setting('gc.ref1')::jsonb->>'message_id' = current_setting('gc.ref2')::jsonb->>'message_id', 'GC6: idempotent';
  ASSERT current_setting('gc.rate')::boolean, 'GC6: rate limit';
  ASSERT (SELECT count(*) FROM public.exos_group_messages WHERE sender_id = pg_temp.u('0000000000b5')) = 10, 'GC6: ten stored';
  RAISE NOTICE 'OK  GC6 length, links, rate limit, idempotency';
END $$;

-- GC7 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b1');
SELECT public.exos_group_block((SELECT v FROM ids WHERE k='g1'), pg_temp.u('0000000000b2'), true);
SELECT set_config('gc.b1sees2', (SELECT count(*) FROM public.exos_group_messages WHERE sender_id = pg_temp.u('0000000000b2'))::text, true);
SELECT set_config('gc.b1seesall', (SELECT count(*) FROM public.exos_group_messages WHERE group_id = (SELECT v FROM ids WHERE k='g1'))::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b2');
SELECT set_config('gc.b2sees1', (SELECT count(*) FROM public.exos_group_messages WHERE sender_id = pg_temp.u('0000000000b1'))::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b3');
SELECT set_config('gc.b3sees2', (SELECT count(*) FROM public.exos_group_messages WHERE sender_id = pg_temp.u('0000000000b2'))::text, true);
SELECT public.exos_group_mute((SELECT v FROM ids WHERE k='g1'), now() + interval '8 hours');
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b2');
SELECT set_config('gc.blk', public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'can b1 hear me')::text, true);
-- Three reports hide b5's message.
INSERT INTO ids SELECT 'rep', id FROM public.exos_group_messages WHERE sender_id = pg_temp.u('0000000000b5') AND body = 'msg 1';
SELECT public.exos_group_report((SELECT v FROM ids WHERE k='rep'), 'spam');
SELECT set_config('gc.ownrep', pg_temp.refused($$SELECT public.exos_group_report((SELECT id FROM public.exos_group_messages WHERE body = 'can b1 hear me'), 'x')$$, 'your own')::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b3');
SELECT public.exos_group_report((SELECT v FROM ids WHERE k='rep'), 'spam');
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b1');
SELECT set_config('gc.rep3', public.exos_group_report((SELECT v FROM ids WHERE k='rep'), 'spam')::text, true);
SELECT set_config('gc.hiddenvis', (SELECT count(*) FROM public.exos_group_messages WHERE id = (SELECT v FROM ids WHERE k='rep'))::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a1');
SELECT set_config('gc.reports', jsonb_array_length(public.exos_group_reports_open(pg_temp.u('000000000001')))::text, true);
SELECT public.exos_group_moderate((SELECT v FROM ids WHERE k='g1'), 'silence_member', 'spamming the table', NULL, pg_temp.u('0000000000b5'), 2);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b5');
SELECT set_config('gc.silenced', pg_temp.refused($$SELECT public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'hello?')$$, 'paused your messages')::text, true);
RESET ROLE;
DO $$
DECLARE blk jsonb := current_setting('gc.blk')::jsonb;
BEGIN
  ASSERT current_setting('gc.b1sees2')::int = 0 AND current_setting('gc.b1seesall')::int > 0, 'GC7: b1 doesn''t see b2';
  ASSERT current_setting('gc.b2sees1')::int = 0, 'GC7: b2 doesn''t see b1';
  ASSERT current_setting('gc.b3sees2')::int > 0, 'GC7: others still see b2';
  -- b1 blocked, b3 muted: nobody gets b2's text.
  ASSERT (blk->>'sms_queued')::int = 0, 'GC7: no SMS across a block or to a muted member ' || blk::text;
  ASSERT current_setting('gc.ownrep')::boolean, 'GC7: can''t report yourself';
  ASSERT (current_setting('gc.rep3')::jsonb->>'hidden')::boolean AND current_setting('gc.hiddenvis')::int = 0, 'GC7: hidden after 3';
  ASSERT current_setting('gc.reports')::int = 3, 'GC7: staff see the reports';
  ASSERT EXISTS (SELECT 1 FROM public.exos_group_moderation_log WHERE action = 'auto_hide')
     AND EXISTS (SELECT 1 FROM public.exos_group_moderation_log WHERE action = 'review_reports')
     AND EXISTS (SELECT 1 FROM public.exos_group_moderation_log WHERE action = 'silence_member' AND target_user_id = pg_temp.u('0000000000b5')),
         'GC7: logged';
  ASSERT current_setting('gc.silenced')::boolean, 'GC7: silenced';
  RAISE NOTICE 'OK  GC7 block, mute, report, silence';
END $$;

-- GC8 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b1');
SELECT set_config('gc.early', pg_temp.refused($$SELECT public.exos_group_share_contact((SELECT v FROM ids WHERE k='g2'), 'phone')$$, 'after the event')::text, true);
SELECT public.exos_group_share_contact((SELECT v FROM ids WHERE k='g1'), 'phone', pg_temp.u('0000000000b3'));
SELECT set_config('gc.badig', pg_temp.refused($$SELECT public.exos_group_share_contact((SELECT v FROM ids WHERE k='g1'), 'instagram', NULL, 'not a handle!')$$, 'Instagram handle')::text, true);
SELECT set_config('gc.blkshare', pg_temp.refused($$SELECT public.exos_group_share_contact((SELECT v FROM ids WHERE k='g1'), 'phone', pg_temp.u('0000000000b2'))$$, 'pick someone')::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b3');
SELECT set_config('gc.v0', public.exos_group_contacts((SELECT v FROM ids WHERE k='g1'))::text, true);
SELECT public.exos_group_share_contact((SELECT v FROM ids WHERE k='g1'), 'phone', NULL, '+1 646 555 0133');
SELECT public.exos_group_share_contact((SELECT v FROM ids WHERE k='g1'), 'instagram', pg_temp.u('0000000000b1'), '@cal.parties');
SELECT set_config('gc.v3', public.exos_group_contacts((SELECT v FROM ids WHERE k='g1'))::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b1');
SELECT set_config('gc.v1', public.exos_group_contacts((SELECT v FROM ids WHERE k='g1'))::text, true);
SELECT public.exos_group_share_contact((SELECT v FROM ids WHERE k='g1'), 'instagram', NULL, '@mo.s');
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b2');
SELECT public.exos_group_share_contact((SELECT v FROM ids WHERE k='g1'), 'phone');
SELECT public.exos_group_share_contact((SELECT v FROM ids WHERE k='g1'), 'instagram', NULL, 'ana.b');
SELECT set_config('gc.v2', public.exos_group_contacts((SELECT v FROM ids WHERE k='g1'))::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b5');
SELECT set_config('gc.v5', public.exos_group_contacts((SELECT v FROM ids WHERE k='g1'))::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b1');
SELECT set_config('gc.rv', public.exos_group_revoke_contact((SELECT v FROM ids WHERE k='g1'), 'phone', pg_temp.u('0000000000b3'))::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b3');
SELECT set_config('gc.v3b', public.exos_group_contacts((SELECT v FROM ids WHERE k='g1'))::text, true);
RESET ROLE;
DO $$
DECLARE v1 jsonb := current_setting('gc.v1')::jsonb; v3 jsonb := current_setting('gc.v3')::jsonb;
BEGIN
  ASSERT current_setting('gc.early')::boolean AND current_setting('gc.badig')::boolean AND current_setting('gc.blkshare')::boolean, 'GC8: refusals';
  ASSERT jsonb_array_length(current_setting('gc.v0')::jsonb->'revealed') = 0, 'GC8: one-sided share not shown';
  ASSERT current_setting('gc.v0')::text NOT LIKE '%2125550101%', 'GC8: no leak before mutual';
  -- b3 shared phone with the group, b1 shared phone with b3: both see each other's phone.
  ASSERT v3->'revealed' @> '[{"kind":"phone","value":"+12125550101"}]', 'GC8: b3 sees b1''s phone ' || v3::text;
  ASSERT v1->'revealed' @> '[{"kind":"phone","value":"+16465550133"}]', 'GC8: b1 sees b3''s phone ' || v1::text;
  ASSERT NOT (v1->'revealed' @> '[{"kind":"instagram"}]'), 'GC8: instagram needs instagram back';
  -- b2 shared with the group, but b1 blocked b2; b2 sees b3's (b3 -> group, b2 -> group).
  ASSERT NOT (current_setting('gc.v2')::jsonb->'revealed' @> '[{"kind":"instagram","value":"mo.s"}]'), 'GC8: not across a block';
  ASSERT current_setting('gc.v2')::jsonb->'revealed' @> '[{"kind":"phone","value":"+16465550133"}]', 'GC8: group-to-group';
  ASSERT jsonb_array_length(current_setting('gc.v5')::jsonb->'revealed') = 0, 'GC8: b5 shared nothing, sees nothing';
  ASSERT current_setting('gc.rv')::boolean AND NOT (current_setting('gc.v3b')::jsonb->'revealed' @> '[{"value":"+12125550101"}]'),
         'GC8: revoke hides it';
  ASSERT (SELECT value FROM public.exos_group_contact_shares WHERE from_user = pg_temp.u('0000000000b1') AND kind = 'phone'
            AND to_user = pg_temp.u('0000000000b3')) IS NULL, 'GC8: revoke erases the value';
  ASSERT (SELECT count(*) FROM public.exos_group_contact_log WHERE actor_id = pg_temp.u('0000000000b1') AND action IN ('share', 'revoke')) = 3
     AND EXISTS (SELECT 1 FROM public.exos_group_contact_log WHERE actor_id = pg_temp.u('0000000000b3') AND action = 'view'
                  AND other_id = pg_temp.u('0000000000b1')), 'GC8: audit log';
  RAISE NOTICE 'OK  GC8 mutual reveal';
END $$;

-- GC9 ----------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a2');
SELECT set_config('gc.x1', pg_temp.refused($$SELECT public.exos_group_moderation_read((SELECT v FROM ids WHERE k='g1'), 'just curious here')$$, 'owner or manager')::text, true);
SELECT set_config('gc.x2', pg_temp.refused($$SELECT public.exos_group_add_member((SELECT v FROM ids WHERE k='g1'), pg_temp.u('0000000000a2'))$$, 'owner or manager')::text, true);
SELECT set_config('gc.x3', pg_temp.refused($$SELECT public.exos_org_groups(pg_temp.u('000000000001'))$$, 'owner or manager')::text, true);
SELECT set_config('gc.x4', pg_temp.refused($$SELECT public.exos_group_reports_open(pg_temp.u('000000000001'))$$, 'owner or manager')::text, true);
SELECT set_config('gc.x5', pg_temp.refused($$SELECT public.exos_group_moderate((SELECT v FROM ids WHERE k='g1'), 'close_group', 'not mine')$$, 'owner or manager')::text, true);
SELECT set_config('gc.x6', (SELECT count(*) FROM public.exos_social_groups WHERE org_id = pg_temp.u('000000000001'))::text, true);
SELECT set_config('gc.x7', pg_temp.refused($$SELECT public.exos_group_create(pg_temp.u('000000000002'), 'Theirs', 'custom', pg_temp.u('0000000000e1'))$$, 'pick one of your events')::text, true);
SELECT set_config('gc.x8', pg_temp.refused($$SELECT public.exos_group_contacts((SELECT v FROM ids WHERE k='g1'))$$, 'not a member')::text, true);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a1');
SELECT set_config('gc.own', jsonb_array_length(public.exos_org_groups(pg_temp.u('000000000001')))::text, true);
RESET ROLE;
DO $$
BEGIN
  ASSERT current_setting('gc.x1')::boolean AND current_setting('gc.x2')::boolean AND current_setting('gc.x3')::boolean
     AND current_setting('gc.x4')::boolean AND current_setting('gc.x5')::boolean AND current_setting('gc.x7')::boolean
     AND current_setting('gc.x8')::boolean, 'GC9: another org''s owner is refused';
  ASSERT current_setting('gc.x6')::int = 0, 'GC9: and reads no groups';
  ASSERT current_setting('gc.own')::int = 4, 'GC9: the owner lists them';
  RAISE NOTICE 'OK  GC9 cross-org isolation';
END $$;

-- GC10 ---------------------------------------------------------------------
-- N = 0: g1 closed (the event ended 26 hours ago).
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000a1');
SELECT public.exos_group_update_settings((SELECT v FROM ids WHERE k='g1'), NULL, 0);
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b3');
SELECT set_config('gc.closedpost', pg_temp.refused($$SELECT public.exos_group_post((SELECT v FROM ids WHERE k='g1'), 'anyone?')$$, 'closed')::text, true);
RESET ROLE;
DO $$
DECLARE
  g1 uuid := (SELECT v FROM ids WHERE k='g1');
  a1 public.exos_sms_relay_assignments%ROWTYPE;
  n1 public.exos_sms_relay_numbers%ROWTYPE;
  r  jsonb;
BEGIN
  ASSERT current_setting('gc.closedpost')::boolean, 'GC10: closed for posts';
  SELECT * INTO a1 FROM public.exos_sms_relay_assignments WHERE group_id = g1 AND user_id = pg_temp.u('0000000000b1') AND released_at IS NULL;
  SELECT * INTO n1 FROM public.exos_sms_relay_numbers WHERE id = a1.number_id;
  ASSERT public.exos_sms_relay_inbound(n1.provider, a1.phone, n1.phone, 'hello?', NULL, 'SM-30')->>'action' = 'closed', 'GC10: closed for texts';
  r := public.exos_group_retention_sweep();
  ASSERT (r->>'closed')::int >= 1, 'GC10: sweep marks closed ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_assignments WHERE group_id = g1 AND released_at IS NULL), 'GC10: numbers freed';
  ASSERT EXISTS (SELECT 1 FROM public.exos_group_messages WHERE group_id = g1), 'GC10: messages kept during retention';
  UPDATE public.exos_social_groups SET closed_at = now() - interval '31 days' WHERE id = g1;
  r := public.exos_group_retention_sweep();
  ASSERT (r->>'purged_groups')::int = 1 AND (r->>'deleted_messages')::int > 0, 'GC10: purge ' || r::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_group_messages WHERE group_id = g1)
     AND NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_outbox WHERE group_id = g1)
     AND NOT EXISTS (SELECT 1 FROM public.exos_group_contact_shares WHERE group_id = g1 AND value IS NOT NULL), 'GC10: purged';
  ASSERT EXISTS (SELECT 1 FROM public.exos_sms_relay_consents WHERE group_id = g1 AND action = 'released'), 'GC10: consent log kept';
  -- b1's freed g1 number can now serve b1's fourth group.
  ASSERT public._exos_relay_pick_number(pg_temp.u('0000000000b1'), '+12125550101') = n1.id, 'GC10: the number is reusable';
  RAISE NOTICE 'OK  GC10 close after N days, retention sweep';
END $$;

-- GC12 ---------------------------------------------------------------------
-- The matched-seats seam: rows written the way 20261031210000 writes them
-- (a draft group, one member row per ticket, the same person on two tickets).
-- No chat and no numbers until revealed; revealed: one number per person,
-- listed once, texts once; dissolved: numbers released.
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,sold,visibility) VALUES
  ('c3000000-0000-0000-0000-0000000000d3','c3000000-0000-0000-0000-0000000000e2','Matched',20,100,3,'public');
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref,channel_source) VALUES
  ('c3000000-0000-0000-0000-000000000c51','c3000000-0000-0000-0000-0000000000e2','c3000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-0000000000d3','Matched','c3000000-0000-0000-0000-0000000000b3','c3000000-0000-0000-0000-0000000000b3','active','k',20,'cs_gc51','stripe'),
  ('c3000000-0000-0000-0000-000000000c52','c3000000-0000-0000-0000-0000000000e2','c3000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-0000000000d3','Matched','c3000000-0000-0000-0000-0000000000b3','c3000000-0000-0000-0000-0000000000b3','active','k',20,'cs_gc52','stripe'),
  ('c3000000-0000-0000-0000-000000000c53','c3000000-0000-0000-0000-0000000000e2','c3000000-0000-0000-0000-000000000001','c3000000-0000-0000-0000-0000000000d3','Matched','c3000000-0000-0000-0000-0000000000b5','c3000000-0000-0000-0000-0000000000b5','active','k',20,'cs_gc53','stripe');
INSERT INTO public.exos_social_groups (id, org_id, event_id, kind, tier_id, label, status)
VALUES ('c3000000-0000-0000-0000-0000000000a9', pg_temp.u('000000000001'), pg_temp.u('0000000000e2'), 'matched_seats', pg_temp.u('0000000000d3'), 'Group 1', 'draft');
INSERT INTO public.exos_social_group_members (group_id, ticket_id, user_id, display_name) VALUES
  (pg_temp.u('0000000000a9'), pg_temp.u('000000000c51'), pg_temp.u('0000000000b3'), 'Cal'),
  (pg_temp.u('0000000000a9'), pg_temp.u('000000000c52'), pg_temp.u('0000000000b3'), 'Cal'),
  (pg_temp.u('0000000000a9'), pg_temp.u('000000000c53'), pg_temp.u('0000000000b5'), 'Bea');
DO $$
DECLARE g uuid := pg_temp.u('0000000000a9');
BEGIN
  ASSERT (SELECT bool_and(org_id = pg_temp.u('000000000001') AND event_id = pg_temp.u('0000000000e2') AND kind = 'matched_seats')
            FROM public.exos_social_group_members WHERE group_id = g), 'GC12: member rows filled from the group';
  ASSERT NOT public._exos_group_open(g), 'GC12: a draft table has no chat';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_assignments WHERE group_id = g), 'GC12: no numbers before the reveal';
  UPDATE public.exos_social_groups SET status = 'revealed', revealed_at = now() WHERE id = g;
  ASSERT public._exos_group_open(g), 'GC12: revealed opens the chat';
  ASSERT (SELECT count(*) FROM public.exos_sms_relay_assignments WHERE group_id = g AND released_at IS NULL) = 2,
         'GC12: one number per person (b3 holds two tickets)';
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act('c3000000-0000-0000-0000-0000000000b3');
SELECT set_config('gc.ms', public.exos_group_state(pg_temp.u('0000000000a9'))::text, true);
SELECT set_config('gc.msp', public.exos_group_post(pg_temp.u('0000000000a9'), 'hi table')::text, true);
SELECT set_config('gc.msmine', (SELECT count(*) FROM jsonb_array_elements(public.exos_my_groups()) x
                                  WHERE x->>'id' = 'c3000000-0000-0000-0000-0000000000a9')::text, true);
RESET ROLE;
DO $$
DECLARE g uuid := pg_temp.u('0000000000a9');
BEGIN
  ASSERT jsonb_array_length(current_setting('gc.ms')::jsonb->'members') = 2, 'GC12: listed once each ' || current_setting('gc.ms');
  ASSERT current_setting('gc.ms')::jsonb->>'title' = 'Group 1', 'GC12: the label is the name';
  ASSERT current_setting('gc.msp')::jsonb->>'message_id' IS NOT NULL AND current_setting('gc.msmine')::int = 1, 'GC12: chat works';
  -- One of b3's two rows leaving keeps b3 in; both leaving releases b3's number.
  UPDATE public.exos_social_group_members SET status = 'left' WHERE ticket_id = pg_temp.u('000000000c51');
  ASSERT EXISTS (SELECT 1 FROM public.exos_sms_relay_assignments WHERE group_id = g AND user_id = pg_temp.u('0000000000b3') AND released_at IS NULL),
         'GC12: still in on the other ticket';
  UPDATE public.exos_social_group_members SET status = 'removed' WHERE ticket_id = pg_temp.u('000000000c52');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_assignments WHERE group_id = g AND user_id = pg_temp.u('0000000000b3') AND released_at IS NULL),
         'GC12: released with the last row';
  UPDATE public.exos_social_groups SET status = 'dissolved' WHERE id = g;
  ASSERT NOT public._exos_group_open(g) AND NOT EXISTS (SELECT 1 FROM public.exos_sms_relay_assignments WHERE group_id = g AND released_at IS NULL),
         'GC12: dissolved closes and releases';
  RAISE NOTICE 'OK  GC12 matched-seats seam (draft, reveal, two tickets, dissolve)';
END $$;

-- GC11 ---------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.exos_sms_relay_inbound(text,text,text,text,text,text)', 'public.exos_sms_relay_claim(integer)',
    'public.exos_sms_relay_mark(uuid,text,text,text)', 'public.exos_group_retention_sweep()',
    'public._exos_group_add_member(uuid,uuid,text)', 'public._exos_group_fanout(uuid)',
    'public._exos_group_insert_message(uuid,uuid,text,text,text,text)', 'public._exos_relay_pick_number(uuid,text,uuid)'] LOOP
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE'), 'GC11: ' || f;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.exos_group_post(uuid,text,text)', 'public.exos_group_join(uuid)', 'public.exos_group_contacts(uuid)',
    'public.exos_group_sms_opt_in(uuid,text,text)', 'public.exos_group_moderation_read(uuid,text,timestamp with time zone,integer)'] LOOP
    ASSERT has_function_privilege('authenticated', f, 'EXECUTE') AND NOT has_function_privilege('anon', f, 'EXECUTE'), 'GC11: ' || f;
  END LOOP;
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_sms_relay_assignments', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_group_contact_shares', 'SELECT')
     AND NOT has_table_privilege('authenticated', 'public.exos_group_messages', 'INSERT')
     AND NOT has_table_privilege('anon', 'public.exos_social_groups', 'SELECT'), 'GC11: table grants';
  ASSERT (SELECT bool_and(relrowsecurity) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname IN
          ('exos_social_groups', 'exos_social_group_members', 'exos_group_messages', 'exos_group_reports', 'exos_group_blocks',
           'exos_group_moderation_log', 'exos_sms_relay_numbers', 'exos_sms_relay_assignments', 'exos_sms_relay_outbox',
           'exos_sms_relay_consents', 'exos_sms_relay_stops', 'exos_group_contact_shares', 'exos_group_contact_log')), 'GC11: RLS on';
  ASSERT public.exos_relay_format('  Jo-Ann  Smith ', E'hi\n\nthere www.x.com/y') = 'Jo-Ann: hi there [link in app]', 'GC11: format';
  ASSERT public.exos_relay_format('', 'x') = 'Member: x' AND length(public.exos_relay_format('Al', repeat('y', 400))) = 306, 'GC11: format caps';
  RAISE NOTICE 'OK  GC11 grants, RLS, formatting';
END $$;

ROLLBACK;
