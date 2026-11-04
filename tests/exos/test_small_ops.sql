-- ============================================================================
-- Small operations fixes (mig 20261104200000):
--   SO1  grants and RLS on the new tables and functions
--   SO2  per-partner caps: no cap = today; a tier cap; an event cap; holds +
--        valid sales count, cancelled / expired / voided don't; dry run;
--        organizer reservations unaffected; the partner's ticket types
--   SO3  caps: validation, who may set / read, cross-org isolation
--   SO4  invite approval: off for orgs that existed, on for new ones
--   SO5  a typo'd invite claimed by a stranger: pending, no access, the
--        inviter is mailed the claimer's account email; reject deletes it
--   SO6  who decides: owner any role, manager below manager, nobody their
--        own; approval grants access
--   SO7  clients can't approve by editing the membership row
--   SO8  an existing member who claims keeps their access until approved;
--        rejection keeps their old role
--   SO9  approval off: a claim joins at once (today's behaviour); the switch
--        is owner-only
--   SO10 drawer recount: who, when, reason, audit row, variance, replay,
--        3 recounts, 7 days, final settlement, RLS
-- Self-contained (BEGIN / ROLLBACK), prefix c5a. Org …01: owner a1, manager
-- a2, scanner a3, finance a4. Org …02: owner b1. Claimers: c1 (a stranger who
-- got a typo'd invite), c2, c3 (already org 1's scanner).
-- Race: tests/exos/race_sim_partner.sh (by hand).
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('c5a00000-0000-0000-0000-0000000000a1', 'c5a-owner@x.com', now()),
  ('c5a00000-0000-0000-0000-0000000000a2', 'c5a-manager@x.com', now()),
  ('c5a00000-0000-0000-0000-0000000000a3', 'c5a-scanner@x.com', now()),
  ('c5a00000-0000-0000-0000-0000000000a4', 'c5a-finance@x.com', now()),
  ('c5a00000-0000-0000-0000-0000000000b1', 'c5a-other@x.com', now()),
  ('c5a00000-0000-0000-0000-0000000000c1', 'stranger@x.com', now()),
  ('c5a00000-0000-0000-0000-0000000000c2', 'c5a-door@x.com', now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('c5a00000-0000-0000-0000-000000000001', 'C5A Org', 'c5a-org', 'c5a00000-0000-0000-0000-0000000000a1'),
  ('c5a00000-0000-0000-0000-000000000002', 'C5A Other', 'c5a-other', 'c5a00000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('c5a00000-0000-0000-0000-000000000001', 'c5a00000-0000-0000-0000-0000000000a1', 'owner'),
  ('c5a00000-0000-0000-0000-000000000001', 'c5a00000-0000-0000-0000-0000000000a2', 'manager'),
  ('c5a00000-0000-0000-0000-000000000001', 'c5a00000-0000-0000-0000-0000000000a3', 'scanner'),
  ('c5a00000-0000-0000-0000-000000000001', 'c5a00000-0000-0000-0000-0000000000a4', 'finance'),
  ('c5a00000-0000-0000-0000-000000000002', 'c5a00000-0000-0000-0000-0000000000b1', 'owner');
INSERT INTO public.exos_events (id, org_id, name, slug, status, starts_at, timezone, total_tickets, tickets_sold, currency, created_by) VALUES
  ('c5a00000-0000-0000-0000-0000000000e1', 'c5a00000-0000-0000-0000-000000000001', 'C5A Show', 'c5a-show', 'published',
   now() + interval '3 days', 'America/New_York', 0, 0, 'usd', 'c5a00000-0000-0000-0000-0000000000a1'),
  ('c5a00000-0000-0000-0000-0000000000e2', 'c5a00000-0000-0000-0000-000000000001', 'C5A Bar Night', 'c5a-bar', 'published',
   now() + interval '1 hour', 'America/New_York', 100, 0, 'usd', 'c5a00000-0000-0000-0000-0000000000a1'),
  ('c5a00000-0000-0000-0000-0000000000e9', 'c5a00000-0000-0000-0000-000000000002', 'C5A Elsewhere', 'c5a-else', 'published',
   now() + interval '3 days', 'America/New_York', 0, 0, 'usd', 'c5a00000-0000-0000-0000-0000000000b1');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sort_order) VALUES
  ('c5a00000-0000-0000-0000-0000000000d1', 'c5a00000-0000-0000-0000-0000000000e1', 'GA', 25, 60, 0, 'public', 1),
  ('c5a00000-0000-0000-0000-0000000000d2', 'c5a00000-0000-0000-0000-0000000000e1', 'VIP', 40, 20, 0, 'public', 2),
  ('c5a00000-0000-0000-0000-0000000000d9', 'c5a00000-0000-0000-0000-0000000000e9', 'Other GA', 20, 50, 0, 'public', 1);
INSERT INTO public.exos_tier_distribution (tier_id, event_id, org_id, enabled) VALUES
  ('c5a00000-0000-0000-0000-0000000000d1', 'c5a00000-0000-0000-0000-0000000000e1', 'c5a00000-0000-0000-0000-000000000001', true),
  ('c5a00000-0000-0000-0000-0000000000d2', 'c5a00000-0000-0000-0000-0000000000e1', 'c5a00000-0000-0000-0000-000000000001', true),
  ('c5a00000-0000-0000-0000-0000000000d9', 'c5a00000-0000-0000-0000-0000000000e9', 'c5a00000-0000-0000-0000-000000000002', true);
INSERT INTO public.exos_api_keys (id, org_id, name, key_prefix, key_hash, scopes, created_by) VALUES
  ('c5a00000-0000-0000-0000-0000000000f1', 'c5a00000-0000-0000-0000-000000000001', 'box office', 'sk_live_c5a1', 'c5ahash1',
   ARRAY['events:write','tickets:write'], 'c5a00000-0000-0000-0000-0000000000a1');

CREATE TEMP TABLE c5 (k text PRIMARY KEY, v text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('c5a00000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.org(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('c5a00000-0000-0000-0000-0000000000' || p)::uuid $$;
CREATE FUNCTION pg_temp.v(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT v FROM c5 WHERE k = p_k $$;
-- The SQLSTATE a statement fails with ('ok' when it doesn't).
CREATE FUNCTION pg_temp.st(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
-- SQLSTATE, message and detail.
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_d text;
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_d = PG_EXCEPTION_DETAIL;
  RETURN SQLSTATE || ' ' || SQLERRM || ' | ' || coalesce(v_d, '');
END $$;
CREATE FUNCTION pg_temp.act(p_uid uuid, p_email text DEFAULT NULL) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid::text, ''), true),
         set_config('app.jwt', CASE WHEN p_email IS NULL THEN '' ELSE jsonb_build_object('email', p_email)::text END, true);
$$;
CREATE FUNCTION pg_temp.line(p_tier text, p_qty int) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array(jsonb_build_object('ticket_type_id', pg_temp.u(p_tier), 'quantity', p_qty)) $$;
CREATE FUNCTION pg_temp.reserve(p_partner text, p_lines jsonb, p_dry boolean DEFAULT false) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public._exos_partner_reserve('c5a00000-0000-0000-0000-000000000001', pg_temp.u('e1'),
           pg_temp.v(p_partner)::uuid, NULL, p_lines, '{}', false, p_dry) $$;
CREATE FUNCTION pg_temp.rst(p_partner text, p_lines jsonb, p_dry boolean DEFAULT false) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.reserve(p_partner, p_lines, p_dry);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
CREATE FUNCTION pg_temp.caps(p_caps jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public._exos_partner_caps_set('c5a00000-0000-0000-0000-000000000001', pg_temp.u('e1'), p_caps,
                                       'c5a00000-0000-0000-0000-0000000000a1') $$;
CREATE FUNCTION pg_temp.cap_row(p_partner text, p_tier text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x FROM jsonb_array_elements(public._exos_partner_caps_json(pg_temp.u('e1'))) x
   WHERE x->>'partner_id' = pg_temp.v(p_partner)
     AND (x->>'tier_id') IS NOT DISTINCT FROM CASE WHEN p_tier IS NULL THEN NULL ELSE pg_temp.u(p_tier)::text END $$;

-- Partners of org 1 (A: inventory + comps, B: inventory) and of org 2 (Z).
DO $$
DECLARE v jsonb;
BEGIN
  v := public._exos_dist_partner_create(pg_temp.org('01'), 'StubHub', 'stubhub', ARRAY['inventory','comps'], pg_temp.u('a1'), NULL);
  INSERT INTO c5 VALUES ('pA', v->>'id');
  v := public._exos_dist_partner_create(pg_temp.org('01'), 'Vivid', 'vivid', ARRAY['inventory'], pg_temp.u('a1'), NULL);
  INSERT INTO c5 VALUES ('pB', v->>'id');
  v := public._exos_dist_partner_create(pg_temp.org('02'), 'Other', 'other', ARRAY['inventory'], pg_temp.u('b1'), NULL);
  INSERT INTO c5 VALUES ('pZ', v->>'id');
END $$;

-- ── SO1 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE t text; f text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_partner_caps', 'exos_pos_drawer_recounts'] LOOP
    ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass), 'SO1: RLS on ' || t;
    ASSERT NOT has_table_privilege('anon', 'public.' || t, 'SELECT'), 'SO1: anon reads ' || t;
    ASSERT has_table_privilege('authenticated', 'public.' || t, 'SELECT'), 'SO1: staff read ' || t;
    ASSERT NOT has_table_privilege('authenticated', 'public.' || t, 'INSERT')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
       AND NOT has_table_privilege('authenticated', 'public.' || t, 'DELETE'), 'SO1: clients write ' || t;
  END LOOP;
  -- Internal: service role only.
  FOREACH f IN ARRAY ARRAY['public._exos_partner_cap_used(uuid,uuid,uuid)', 'public._exos_partner_cap_left(uuid,uuid)',
                           'public._exos_partner_cap_check(uuid,uuid,jsonb)', 'public._exos_partner_caps_json(uuid)',
                           'public._exos_partner_caps_set(uuid,uuid,jsonb,uuid)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND NOT has_function_privilege('authenticated', f, 'EXECUTE')
       AND has_function_privilege('service_role', f, 'EXECUTE'), 'SO1: internal ' || f;
  END LOOP;
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_member_decider(uuid,uuid,text)', 'EXECUTE'), 'SO1: decider';
  ASSERT NOT has_function_privilege('authenticated', 'public._exos_tg_membership_approval()', 'EXECUTE'), 'SO1: trigger fn';
  -- Signed in: authenticated, never anon.
  FOREACH f IN ARRAY ARRAY['public.exos_partner_caps(uuid)', 'public.exos_set_partner_caps(uuid,jsonb)',
                           'public.exos_org_pending_members(uuid)', 'public.exos_org_member_approve(uuid,uuid)',
                           'public.exos_org_member_reject(uuid,uuid)', 'public.exos_set_invite_approval(uuid,boolean)',
                           'public.exos_pos_recount_drawer(uuid,integer,text,jsonb)'] LOOP
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE') AND has_function_privilege('authenticated', f, 'EXECUTE'),
      'SO1: signed-in ' || f;
    ASSERT (SELECT prosecdef AND proconfig::text LIKE '%search_path=public, pg_temp%' FROM pg_proc WHERE oid = f::regprocedure),
      'SO1: secdef + search_path ' || f;
  END LOOP;
  RAISE NOTICE 'OK SO1 RLS + read-only grants on caps and recounts; internal fns service-only; wrappers signed-in only';
END $$;

-- ── SO2 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE r jsonb; e text; v_tok text;
BEGIN
  -- No cap: today's behaviour (any partner may take what is left).
  r := pg_temp.reserve('pA', pg_temp.line('d1', 10));
  INSERT INTO c5 VALUES ('rA1', r->>'token');
  ASSERT public._exos_partner_cap_left(pg_temp.v('pA')::uuid, pg_temp.u('d1')) IS NULL, 'SO2: no cap = NULL left';
  -- A GA cap of 12 for A: 10 held, 2 left.
  PERFORM pg_temp.caps(jsonb_build_array(jsonb_build_object('partner_id', pg_temp.v('pA'), 'tier_id', pg_temp.u('d1'), 'max_tickets', 12)));
  ASSERT (pg_temp.cap_row('pA', 'd1')->>'used')::int = 10 AND (pg_temp.cap_row('pA', 'd1')->>'left')::int = 2,
    'SO2: used / left ' || pg_temp.cap_row('pA', 'd1')::text;
  e := pg_temp.err(format('SELECT pg_temp.reserve(%L, pg_temp.line(%L, 3))', 'pA', 'd1'));
  ASSERT e LIKE 'EXCAP partner_cap_reached:%' AND e LIKE '%"left": 2%', 'SO2: over the tier cap, got ' || e;
  -- A dry run (a quote) is refused the same way.
  ASSERT pg_temp.rst('pA', pg_temp.line('d1', 3), true) = 'EXCAP', 'SO2: dry run over the cap';
  -- B is not capped by A's cap; VIP is not capped by A's GA cap.
  ASSERT pg_temp.rst('pB', pg_temp.line('d1', 3)) = 'ok', 'SO2: B unaffected';
  ASSERT pg_temp.rst('pA', pg_temp.line('d2', 5)) = 'ok', 'SO2: A on VIP unaffected';
  r := pg_temp.reserve('pA', pg_temp.line('d1', 2));
  INSERT INTO c5 VALUES ('rA2', r->>'token');
  ASSERT pg_temp.rst('pA', pg_temp.line('d1', 1)) = 'EXCAP', 'SO2: exactly at the cap';
  -- A cancelled reservation gives its share back.
  PERFORM public._exos_partner_reservation_cancel(pg_temp.org('01'), pg_temp.v('pA')::uuid, pg_temp.v('rA2'));
  ASSERT (pg_temp.cap_row('pA', 'd1')->>'left')::int = 2, 'SO2: cancel frees';
  -- So does an expired one (the hold lapsed; the sweep hasn't run).
  UPDATE public.exos_cart_holds SET expires_at = now() - interval '1 second'
   WHERE partner_reservation_id = (SELECT id FROM public.exos_partner_reservations WHERE token = pg_temp.v('rA1'));
  ASSERT (pg_temp.cap_row('pA', 'd1')->>'left')::int = 12, 'SO2: expired holds free ' || pg_temp.cap_row('pA', 'd1')::text;
  -- Completed sales count while the tickets are valid; a voided one frees.
  r := pg_temp.reserve('pA', pg_temp.line('d1', 4));
  r := public._exos_partner_reservation_complete(pg_temp.org('01'), pg_temp.v('pA')::uuid, r->>'token', '{}', 'https://x.test');
  ASSERT (pg_temp.cap_row('pA', 'd1')->>'used')::int = 4, 'SO2: sold counts ' || pg_temp.cap_row('pA', 'd1')::text;
  UPDATE public.exos_tickets SET status = 'voided'
   WHERE id = (SELECT ticket_ids[1] FROM public.exos_partner_reservations WHERE id = (r->'order'->>'id')::uuid);
  ASSERT (pg_temp.cap_row('pA', 'd1')->>'used')::int = 3, 'SO2: a voided sale frees its place';
  -- The partner's ticket types show what its cap leaves.
  r := public._exos_partner_ticket_types(pg_temp.org('01'), pg_temp.v('pA')::uuid, pg_temp.u('e1'));
  ASSERT (SELECT (x->>'available')::int FROM jsonb_array_elements(r) x WHERE x->>'id' = pg_temp.u('d1')::text) = 9,
    'SO2: capped available ' || r::text;
  ASSERT (SELECT (x->>'available')::int FROM jsonb_array_elements(r) x WHERE x->>'id' = pg_temp.u('d2')::text)
       = public.exos_effective_available(pg_temp.u('d2')), 'SO2: uncapped tier shows the pool';
  -- An event-wide cap for B (5 across GA + VIP); B already holds 3 GA.
  PERFORM pg_temp.caps(jsonb_build_array(jsonb_build_object('partner_id', pg_temp.v('pB'), 'max_tickets', 5)));
  ASSERT pg_temp.rst('pB', pg_temp.line('d2', 3)) = 'EXCAP', 'SO2: over the event cap';
  ASSERT pg_temp.rst('pB', jsonb_build_array(jsonb_build_object('ticket_type_id', pg_temp.u('d1'), 'quantity', 1),
                                             jsonb_build_object('ticket_type_id', pg_temp.u('d2'), 'quantity', 1))) = 'ok',
    'SO2: two types within the event cap';
  ASSERT pg_temp.rst('pB', pg_temp.line('d2', 1)) = 'EXCAP', 'SO2: event cap reached';
  r := public._exos_partner_ticket_types(pg_temp.org('01'), pg_temp.v('pB')::uuid, pg_temp.u('e1'));
  ASSERT (SELECT bool_and((x->>'available')::int = 0 AND (x->>'sold_out')::boolean) FROM jsonb_array_elements(r) x),
    'SO2: event cap shows sold out to B ' || r::text;
  -- Organizer reservations (box office) ignore partner caps.
  r := public._exos_partner_reserve(pg_temp.org('01'), pg_temp.u('e1'), NULL, pg_temp.u('f1'), pg_temp.line('d1', 20), '{}', false, false);
  ASSERT r->>'status' = 'active', 'SO2: organizer reservation';
  -- Removing a cap (null) restores today's behaviour.
  PERFORM pg_temp.caps(jsonb_build_array(jsonb_build_object('partner_id', pg_temp.v('pB'), 'max_tickets', NULL)));
  ASSERT pg_temp.rst('pB', pg_temp.line('d2', 3)) = 'ok', 'SO2: cap removed';
  -- A cap of 0 stops the partner.
  PERFORM pg_temp.caps(jsonb_build_array(jsonb_build_object('partner_id', pg_temp.v('pB'), 'tier_id', pg_temp.u('d2'), 'max_tickets', 0)));
  ASSERT pg_temp.rst('pB', pg_temp.line('d2', 1)) = 'EXCAP', 'SO2: cap 0';
  RAISE NOTICE 'OK SO2 caps: tier + event caps, holds + valid sales counted, cancel / expiry / void free, dry run, box office unaffected, ticket types capped';
END $$;

-- ── SO3 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE s text; n int;
BEGIN
  -- Validation.
  s := pg_temp.st(format($q$SELECT pg_temp.caps('[{"partner_id": %s, "tier_id": %s, "max_tickets": 5}]')$q$,
         to_jsonb(pg_temp.v('pA')), to_jsonb(pg_temp.u('d9'))));
  ASSERT s = '22023', 'SO3: a tier of another event ' || s;
  s := pg_temp.st(format($q$SELECT pg_temp.caps('[{"partner_id": %s, "max_tickets": 5}]')$q$, to_jsonb(pg_temp.v('pZ'))));
  ASSERT s = '22023', 'SO3: another org''s partner ' || s;
  s := pg_temp.st(format($q$SELECT pg_temp.caps('[{"partner_id": %s, "max_tickets": -1}]')$q$, to_jsonb(pg_temp.v('pA'))));
  ASSERT s = '22023', 'SO3: negative ' || s;
  s := pg_temp.st(format($q$SELECT pg_temp.caps('[{"partner_id": %s, "max_tickets": 2.5}]')$q$, to_jsonb(pg_temp.v('pA'))));
  ASSERT s = '22023', 'SO3: fraction ' || s;
  s := pg_temp.st(format($q$SELECT pg_temp.caps('[{"partner_id": %s}]')$q$, to_jsonb(pg_temp.v('pA'))));
  ASSERT s = '22023', 'SO3: missing max_tickets ' || s;
  ASSERT pg_temp.st($q$SELECT pg_temp.caps('[]')$q$) = '22023', 'SO3: empty list';
  ASSERT pg_temp.st(format($q$SELECT public._exos_partner_caps_set(%L, %L, '[{"partner_id": null, "max_tickets": 1}]', NULL)$q$,
           pg_temp.org('02'), pg_temp.u('e1'))) = 'P0002', 'SO3: another org''s event';
  -- Who: owner and manager set; finance, scanner, another org's owner can't.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  PERFORM public.exos_set_partner_caps(pg_temp.u('e1'),
    jsonb_build_array(jsonb_build_object('partner_id', pg_temp.v('pA'), 'tier_id', pg_temp.u('d2'), 'max_tickets', 30)));
  ASSERT (SELECT count(*) FROM jsonb_array_elements(public.exos_partner_caps(pg_temp.u('e1')))) = 3, 'SO3: manager reads';
  PERFORM pg_temp.act(pg_temp.u('a4'));
  ASSERT pg_temp.st(format('SELECT public.exos_partner_caps(%L)', pg_temp.u('e1'))) = '42501', 'SO3: finance reads';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format($q$SELECT public.exos_set_partner_caps(%L, '[]')$q$, pg_temp.u('e1'))) = '42501', 'SO3: scanner sets';
  PERFORM pg_temp.act(pg_temp.u('b1'));
  ASSERT pg_temp.st(format('SELECT public.exos_partner_caps(%L)', pg_temp.u('e1'))) = '42501', 'SO3: other org reads';
  -- RLS: another org's owner sees no rows; org 1's manager sees them.
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM public.exos_partner_caps;
  ASSERT n = 0, 'SO3: other org sees caps';
  RESET ROLE;
  PERFORM pg_temp.act(pg_temp.u('a2'));
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM public.exos_partner_caps;
  RESET ROLE;
  ASSERT n = 3, 'SO3: manager sees caps ' || n;
  PERFORM pg_temp.act(NULL);
  -- Revoking a partner leaves its caps harmless (it can't reserve); a
  -- deleted partner takes them along.
  RAISE NOTICE 'OK SO3 caps validation (tier / partner of another org, bad numbers), owner + manager only, RLS by org';
END $$;

-- ── SO4: invites. Prod's invite table and claim function (the offline chain
-- has neither), then this migration again so its claim patch applies. ──────
CREATE TABLE public.exos_org_invites (
  token       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  email       text NOT NULL,
  role        text NOT NULL CHECK (role IN ('manager','finance','scanner','content')),
  created_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed','cancelled','expired')),
  expires_at  timestamptz,
  claimed_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  claimed_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.exos_org_memberships ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
CREATE TRIGGER c5a_memberships_touch BEFORE UPDATE ON public.exos_org_memberships
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
-- exos_claim_invite as prod has it (20260520120000 + 20260925021000 + 20260927010000).
CREATE OR REPLACE FUNCTION public.exos_claim_invite(p_token uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_inv   public.exos_org_invites%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_claim_invite: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_inv FROM public.exos_org_invites WHERE token = p_token;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_claim_invite: invite not found';
  END IF;
  IF v_inv.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_claim_invite: invite is %', v_inv.status;
  END IF;
  -- p1: every invite expires (14 days when none was set, 30 days at most).
  IF least(coalesce(v_inv.expires_at, v_inv.created_at + interval '14 days'),
           v_inv.created_at + interval '30 days') < now() THEN
    UPDATE public.exos_org_invites SET status = 'expired' WHERE token = p_token;
    RAISE EXCEPTION 'exos_claim_invite: invite expired';
  END IF;
  -- any verified account with the link joins, first come first served
  -- (mig 20260927010000); the inviter gets a receipt naming it.
  -- Email-verified gate (the analogue of the old Firestore email_verified rule).
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_claim_invite: email not verified';
  END IF;

  INSERT INTO public.exos_org_memberships (org_id, user_id, role, added_by)
  VALUES (v_inv.org_id, v_uid, v_inv.role, v_uid)
  ON CONFLICT (org_id, user_id) DO UPDATE SET role = EXCLUDED.role, disabled = false
    -- p1: a stale invite never changes a membership edited after it was sent,
    -- and an invite never demotes an owner.
    WHERE exos_org_memberships.role <> 'owner'
      AND exos_org_memberships.updated_at < v_inv.created_at;

  UPDATE public.exos_org_invites
  SET status = 'completed', claimed_by = v_uid, claimed_at = now()
  WHERE token = p_token;

  -- invite accepted receipt (mig 20260927010000)
  DECLARE
    v_joiner text;
    v_to     text;
    v_org    text;
  BEGIN
    IF to_regclass('public.exos_profiles') IS NOT NULL THEN
      EXECUTE 'SELECT nullif(btrim(display_name), '''') FROM public.exos_profiles WHERE id = $1'
         INTO v_joiner USING v_uid;
    END IF;
    SELECT lower(u.email) INTO v_to FROM auth.users u WHERE u.id = v_inv.created_by;
    SELECT o.name INTO v_org FROM public.exos_orgs o WHERE o.id = v_inv.org_id;
    IF coalesce(v_to, '') <> '' THEN
      INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
      VALUES ('invite-accepted', v_to,
              left('Your invite to ' || coalesce(v_org, 'your organization') || ' was accepted', 200),
              '<p>Your invite to join <strong>' || public.exos_mail_escape(coalesce(v_org, 'your organization')) ||
              '</strong> as ' || public.exos_mail_escape(v_inv.role) || ', sent to ' || public.exos_mail_escape(v_inv.email) ||
              ' on ' || to_char(v_inv.created_at AT TIME ZONE 'UTC', 'Mon FMDD, YYYY') ||
              ', was accepted on ' || to_char(now() AT TIME ZONE 'UTC', 'Mon FMDD, YYYY "at" HH24:MI "UTC"') ||
              ' by <strong>' ||
              CASE WHEN v_joiner IS NOT NULL
                   THEN public.exos_mail_escape(v_joiner) || '</strong> (' || public.exos_mail_escape(v_email) || ')'
                   ELSE public.exos_mail_escape(v_email) || '</strong>' END ||
              '.</p><p>If that isn''t who you meant, remove them under Members.</p>',
              v_uid, 'pending');
    END IF;
  END;

  RETURN v_inv.org_id;
END $function$;
REVOKE EXECUTE ON FUNCTION public.exos_claim_invite(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_claim_invite(uuid) TO authenticated;

-- An org that existed before this migration: drop the column so the
-- migration adds it again over a row that is already there.
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('c5a00000-0000-0000-0000-000000000003', 'C5A Old', 'c5a-old', 'c5a00000-0000-0000-0000-0000000000b1');
ALTER TABLE public.exos_orgs DROP COLUMN invite_approval;
\set QUIET on
SET client_min_messages = warning;
\ir ../../supabase/migrations/20261104200000_exos_small_ops.sql
-- And once more: every patch is marker-checked (replay safe).
\ir ../../supabase/migrations/20261104200000_exos_small_ops.sql
RESET client_min_messages;
DO $$
BEGIN
  ASSERT position('/* exos: invite approval */' in pg_get_functiondef('public.exos_claim_invite(uuid)'::regprocedure)) > 0
     AND position('/* exos: invite approval mail */' in pg_get_functiondef('public.exos_claim_invite(uuid)'::regprocedure)) > 0,
    'SO4: claim patched';
  ASSERT (SELECT NOT invite_approval FROM public.exos_orgs WHERE id = pg_temp.org('03')), 'SO4: an existing org is off';
  INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
    ('c5a00000-0000-0000-0000-000000000004', 'C5A New', 'c5a-new', 'c5a00000-0000-0000-0000-0000000000b1');
  ASSERT (SELECT invite_approval FROM public.exos_orgs WHERE id = pg_temp.org('04')), 'SO4: a new org is on';
  -- The orgs of this file were made before the re-add: switch org 1 on.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  ASSERT public.exos_set_invite_approval(pg_temp.org('01'), true), 'SO4: owner switches it on';
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_set_invite_approval(%L, false)', pg_temp.org('01'))) = '42501',
    'SO4: a manager can''t switch it';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK SO4 invite_approval: off for an org that existed, on for a new one; owner-only switch; claim patched (twice, replay safe)';
END $$;

-- ── SO5 ─────────────────────────────────────────────────────────────────────
-- The owner meant mgr@x.com and typed mrg@x.com; the mail reached a stranger.
INSERT INTO public.exos_org_invites (token, org_id, email, role, created_by, expires_at) VALUES
  ('c5a00000-0000-0000-0000-000000000101', 'c5a00000-0000-0000-0000-000000000001', 'mrg@x.com', 'manager',
   'c5a00000-0000-0000-0000-0000000000a1', now() + interval '14 days'),
  ('c5a00000-0000-0000-0000-000000000102', 'c5a00000-0000-0000-0000-000000000001', 'c5a-door@x.com', 'scanner',
   'c5a00000-0000-0000-0000-0000000000a1', now() + interval '14 days'),
  ('c5a00000-0000-0000-0000-000000000103', 'c5a00000-0000-0000-0000-000000000001', 'c5a-scanner@x.com', 'manager',
   'c5a00000-0000-0000-0000-0000000000a1', now() + interval '14 days'),
  ('c5a00000-0000-0000-0000-000000000104', 'c5a00000-0000-0000-0000-000000000001', 'c5a-scanner@x.com', 'finance',
   'c5a00000-0000-0000-0000-0000000000a1', now() + interval '14 days'),
  ('c5a00000-0000-0000-0000-000000000109', 'c5a00000-0000-0000-0000-000000000002', 'c5a-door@x.com', 'scanner',
   'c5a00000-0000-0000-0000-0000000000b1', now() + interval '14 days');
DO $$
DECLARE m record; r jsonb; n int; mail record;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('c1'), 'stranger@x.com');
  ASSERT public.exos_claim_invite('c5a00000-0000-0000-0000-000000000101') = pg_temp.org('01'), 'SO5: claim answers the org';
  SELECT * INTO m FROM public.exos_org_memberships WHERE org_id = pg_temp.org('01') AND user_id = pg_temp.u('c1');
  ASSERT m.status = 'pending_approval' AND m.disabled AND m.pending_role = 'manager'
     AND m.pending_invite = 'c5a00000-0000-0000-0000-000000000101', 'SO5: pending ' || row_to_json(m)::text;
  -- No access of any kind while pending.
  ASSERT NOT public.exos_has_org_role(pg_temp.org('01'), ARRAY['owner','manager','finance','scanner','content']),
    'SO5: a pending member has a role';
  ASSERT pg_temp.st(format('SELECT public.exos_partner_caps(%L)', pg_temp.u('e1'))) = '42501', 'SO5: pending reads caps';
  ASSERT pg_temp.st(format('SELECT public.exos_org_pending_members(%L)', pg_temp.org('01'))) = '42501', 'SO5: pending lists';
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM public.exos_partner_caps;
  RESET ROLE;
  ASSERT n = 0, 'SO5: pending member reads org rows';
  -- The inviter's mail: waiting, the claimer's account email, the link.
  SELECT * INTO mail FROM public.exos_mail WHERE template = 'invite-accepted' AND to_email = 'c5a-owner@x.com'
   ORDER BY created_at DESC LIMIT 1;
  ASSERT mail.subject LIKE 'Approve or reject:%' AND mail.html LIKE '%stranger@x.com%' AND mail.html LIKE '%mrg@x.com%'
     AND mail.html LIKE '%no new access until you approve%'
     AND mail.html LIKE '%{{app_url}}/orgs/' || pg_temp.org('01') || '/members%', 'SO5: mail ' || coalesce(mail.html, 'none');
  -- The owner's list shows the typo next to the account that claimed it.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  r := public.exos_org_pending_members(pg_temp.org('01'));
  ASSERT jsonb_array_length(r) = 1 AND r->0->>'account_email' = 'stranger@x.com' AND r->0->>'invited_email' = 'mrg@x.com'
     AND NOT (r->0->>'email_matches')::boolean AND (r->0->>'new_member')::boolean AND r->0->>'role' = 'manager'
     AND (r->0->>'can_decide')::boolean AND r->0->>'invited_by_email' = 'c5a-owner@x.com', 'SO5: list ' || r::text;
  -- Rejected: the membership is gone; the link is used up.
  r := public.exos_org_member_reject(pg_temp.org('01'), pg_temp.u('c1'));
  ASSERT (r->>'removed')::boolean, 'SO5: reject';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_memberships WHERE org_id = pg_temp.org('01') AND user_id = pg_temp.u('c1')),
    'SO5: membership deleted';
  PERFORM pg_temp.act(pg_temp.u('c1'), 'stranger@x.com');
  ASSERT pg_temp.st($q$SELECT public.exos_claim_invite('c5a00000-0000-0000-0000-000000000101')$q$) <> 'ok', 'SO5: reclaim';
  ASSERT pg_temp.st(format('SELECT public.exos_org_member_approve(%L, %L)', pg_temp.org('01'), pg_temp.u('c1'))) = '42501',
    'SO5: approve after reject (not staff)';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK SO5 typo''d invite: the stranger is pending with no access; the owner sees their account email; reject deletes the membership';
END $$;

-- ── SO6 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE m record; r jsonb;
BEGIN
  -- A scanner invite claimed by the right person.
  PERFORM pg_temp.act(pg_temp.u('c2'), 'c5a-door@x.com');
  PERFORM public.exos_claim_invite('c5a00000-0000-0000-0000-000000000102');
  -- Nobody approves themselves; scanners and finance don't decide.
  ASSERT pg_temp.st(format('SELECT public.exos_org_member_approve(%L, %L)', pg_temp.org('01'), pg_temp.u('c2'))) = '42501',
    'SO6: self-approval';
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT pg_temp.st(format('SELECT public.exos_org_member_approve(%L, %L)', pg_temp.org('01'), pg_temp.u('c2'))) = '42501',
    'SO6: scanner approves';
  PERFORM pg_temp.act(pg_temp.u('a4'));
  ASSERT pg_temp.st(format('SELECT public.exos_org_member_reject(%L, %L)', pg_temp.org('01'), pg_temp.u('c2'))) = '42501',
    'SO6: finance rejects';
  -- Another org's owner can't see or decide.
  PERFORM pg_temp.act(pg_temp.u('b1'));
  ASSERT pg_temp.st(format('SELECT public.exos_org_member_approve(%L, %L)', pg_temp.org('01'), pg_temp.u('c2'))) = '42501',
    'SO6: other org approves';
  ASSERT pg_temp.st(format('SELECT public.exos_org_pending_members(%L)', pg_temp.org('01'))) = '42501', 'SO6: other org lists';
  -- A manager approves a scanner.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  r := public.exos_org_pending_members(pg_temp.org('01'));
  ASSERT (r->0->>'email_matches')::boolean AND (r->0->>'can_decide')::boolean, 'SO6: manager list ' || r::text;
  r := public.exos_org_member_approve(pg_temp.org('01'), pg_temp.u('c2'));
  ASSERT r->>'role' = 'scanner' AND r->>'status' = 'active', 'SO6: approve ' || r::text;
  SELECT * INTO m FROM public.exos_org_memberships WHERE org_id = pg_temp.org('01') AND user_id = pg_temp.u('c2');
  ASSERT NOT m.disabled AND m.pending_role IS NULL AND m.approved_by = pg_temp.u('a2') AND m.approved_at IS NOT NULL,
    'SO6: approved row ' || row_to_json(m)::text;
  ASSERT pg_temp.st(format('SELECT public.exos_org_member_approve(%L, %L)', pg_temp.org('01'), pg_temp.u('c2'))) = 'P0002',
    'SO6: nothing left to approve';
  PERFORM pg_temp.act(pg_temp.u('c2'));
  ASSERT public.exos_has_org_role(pg_temp.org('01'), ARRAY['scanner']), 'SO6: approval grants access';
  -- A manager can't approve a manager (SO8 has the owner do it). The
  -- scanner's row was written in this transaction (same now()): date the
  -- invite after it, or the stale-invite rule leaves the row alone.
  UPDATE public.exos_org_invites SET created_at = now() + interval '1 second'
   WHERE token IN ('c5a00000-0000-0000-0000-000000000103', 'c5a00000-0000-0000-0000-000000000104');
  PERFORM pg_temp.act(pg_temp.u('a3'), 'c5a-scanner@x.com');
  PERFORM public.exos_claim_invite('c5a00000-0000-0000-0000-000000000103');
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format('SELECT public.exos_org_member_approve(%L, %L)', pg_temp.org('01'), pg_temp.u('a3'))) = '42501',
    'SO6: manager approves a manager';
  ASSERT NOT (public.exos_org_pending_members(pg_temp.org('01'))->0->>'can_decide')::boolean, 'SO6: can_decide for a manager role';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK SO6 deciders: owner any role, manager below manager, never yourself, not scanner / finance / other orgs; approval grants access';
END $$;

-- ── SO7 ─────────────────────────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE ON public.exos_org_memberships TO authenticated;   -- as prod's table grants (rolled back)
DO $$
DECLARE s text;
BEGIN
  INSERT INTO public.exos_org_invites (token, org_id, email, role, created_by, expires_at) VALUES
    ('c5a00000-0000-0000-0000-000000000105', pg_temp.org('01'), 'x@x.com', 'content', pg_temp.u('a1'), now() + interval '1 day');
  PERFORM pg_temp.act(pg_temp.u('c1'), 'stranger@x.com');
  PERFORM public.exos_claim_invite('c5a00000-0000-0000-0000-000000000105');
  PERFORM pg_temp.act(pg_temp.u('a1'));
  SET LOCAL ROLE authenticated;
  s := pg_temp.err(format('UPDATE public.exos_org_memberships SET disabled = false WHERE org_id = %L AND user_id = %L',
         pg_temp.org('01'), pg_temp.u('c1')));
  ASSERT s LIKE '22023%waiting for approval%', 'SO7: enable a pending member ' || s;
  s := pg_temp.err(format($q$UPDATE public.exos_org_memberships SET status = 'active', disabled = false WHERE org_id = %L AND user_id = %L$q$,
         pg_temp.org('01'), pg_temp.u('c1')));
  ASSERT s LIKE '42501%approve or reject%', 'SO7: flip status ' || s;
  s := pg_temp.err(format($q$INSERT INTO public.exos_org_memberships (org_id, user_id, role, status, disabled, pending_role)
                             VALUES (%L, %L, 'scanner', 'pending_approval', true, 'manager')$q$, pg_temp.org('01'), pg_temp.u('b1')));
  ASSERT s LIKE '42501%', 'SO7: insert a pending row ' || s;
  -- Changing the role of a pending row moves the requested role.
  UPDATE public.exos_org_memberships SET role = 'scanner' WHERE org_id = pg_temp.org('01') AND user_id = pg_temp.u('c1');
  RESET ROLE;
  ASSERT (SELECT pending_role = 'scanner' AND disabled FROM public.exos_org_memberships
           WHERE org_id = pg_temp.org('01') AND user_id = pg_temp.u('c1')), 'SO7: role change follows';
  -- The pending member can't approve themselves by editing either.
  PERFORM pg_temp.act(pg_temp.u('c1'));
  SET LOCAL ROLE authenticated;
  s := pg_temp.err(format($q$UPDATE public.exos_org_memberships SET approved_by = %L WHERE user_id = %L$q$, pg_temp.u('c1'), pg_temp.u('c1')));
  RESET ROLE;
  ASSERT s LIKE '42501%', 'SO7: self edit ' || s;
  PERFORM pg_temp.act(pg_temp.u('a1'));
  PERFORM public.exos_org_member_reject(pg_temp.org('01'), pg_temp.u('c1'));
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK SO7 a pending row can''t be enabled, flipped or forged from the client; a role change moves the request';
END $$;
REVOKE SELECT, INSERT, UPDATE ON public.exos_org_memberships FROM authenticated;

-- ── SO8 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE m record; r jsonb;
BEGIN
  -- a3 (scanner) claimed a manager invite in SO6: still a working scanner.
  SELECT * INTO m FROM public.exos_org_memberships WHERE org_id = pg_temp.org('01') AND user_id = pg_temp.u('a3');
  ASSERT m.status = 'active' AND NOT m.disabled AND m.role = 'scanner' AND m.pending_role = 'manager', 'SO8: ' || row_to_json(m)::text;
  PERFORM pg_temp.act(pg_temp.u('a3'));
  ASSERT public.exos_has_org_role(pg_temp.org('01'), ARRAY['scanner'])
     AND NOT public.exos_has_org_role(pg_temp.org('01'), ARRAY['manager']), 'SO8: scanner until approved';
  PERFORM pg_temp.act(pg_temp.u('a1'));
  r := public.exos_org_pending_members(pg_temp.org('01'));
  ASSERT r->0->>'current_role' = 'scanner' AND NOT (r->0->>'new_member')::boolean, 'SO8: list ' || r::text;
  r := public.exos_org_member_approve(pg_temp.org('01'), pg_temp.u('a3'));
  ASSERT r->>'role' = 'manager', 'SO8: owner approves a manager';
  -- Back to scanner, then a finance invite that is rejected: keeps scanner.
  UPDATE public.exos_org_memberships SET role = 'scanner'
   WHERE org_id = pg_temp.org('01') AND user_id = pg_temp.u('a3');
  PERFORM pg_temp.act(pg_temp.u('a3'), 'c5a-scanner@x.com');
  PERFORM public.exos_claim_invite('c5a00000-0000-0000-0000-000000000104');
  PERFORM pg_temp.act(pg_temp.u('a1'));
  r := public.exos_org_member_reject(pg_temp.org('01'), pg_temp.u('a3'));
  ASSERT NOT (r->>'removed')::boolean, 'SO8: an existing member is not removed';
  SELECT * INTO m FROM public.exos_org_memberships WHERE org_id = pg_temp.org('01') AND user_id = pg_temp.u('a3');
  ASSERT m.role = 'scanner' AND NOT m.disabled AND m.pending_role IS NULL, 'SO8: kept ' || row_to_json(m)::text;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK SO8 an existing member keeps their access while the new role waits; reject keeps the old role';
END $$;

-- ── SO9 ─────────────────────────────────────────────────────────────────────
DO $$
DECLARE m record;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('b1'));
  PERFORM public.exos_set_invite_approval(pg_temp.org('02'), false);
  PERFORM pg_temp.act(pg_temp.u('c2'), 'c5a-door@x.com');
  PERFORM public.exos_claim_invite('c5a00000-0000-0000-0000-000000000109');
  SELECT * INTO m FROM public.exos_org_memberships WHERE org_id = pg_temp.org('02') AND user_id = pg_temp.u('c2');
  ASSERT m.status = 'active' AND NOT m.disabled AND m.role = 'scanner' AND m.pending_role IS NULL, 'SO9: ' || row_to_json(m)::text;
  ASSERT public.exos_has_org_role(pg_temp.org('02'), ARRAY['scanner']), 'SO9: joined at once';
  ASSERT (SELECT subject NOT LIKE 'Approve%' FROM public.exos_mail WHERE to_email = 'c5a-other@x.com'
           AND template = 'invite-accepted' ORDER BY created_at DESC LIMIT 1), 'SO9: the old receipt';
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK SO9 approval off: the claim joins at once with the old receipt';
END $$;

-- ── SO10: drawer recount ────────────────────────────────────────────────────
INSERT INTO public.exos_event_staff (event_id, user_id, org_id) VALUES
  ('c5a00000-0000-0000-0000-0000000000e2', 'c5a00000-0000-0000-0000-0000000000a3', 'c5a00000-0000-0000-0000-000000000001');
DO $$
DECLARE r jsonb; s text; v_d uuid := 'c5a00000-0000-0000-0000-000000000dd1'; v_open uuid := 'c5a00000-0000-0000-0000-000000000dd2'; n int;
BEGIN
  PERFORM pg_temp.act(pg_temp.u('a3'));
  INSERT INTO public.exos_pos_drawer_sessions (id, event_id, open_float_cents) VALUES
    (v_d, pg_temp.u('e2'), 10000), (v_open, pg_temp.u('e2'), 5000);
  -- The scanner closed it $10 short (the bill was under the tray).
  r := public.exos_pos_close_drawer(v_d, 9000, '{"2000": 4, "1000": 1}'::jsonb, 'short');
  ASSERT (r->>'variance_cents')::int = -1000, 'SO10: close ' || r::text;
  -- Who: not the scanner who closed it, not finance, not another org.
  s := pg_temp.st(format($q$SELECT public.exos_pos_recount_drawer(%L, 10000, 'found under the tray')$q$, v_d));
  ASSERT s = '42501', 'SO10: scanner recounts ' || s;
  PERFORM pg_temp.act(pg_temp.u('a4'));
  ASSERT pg_temp.st(format($q$SELECT public.exos_pos_recount_drawer(%L, 10000, 'found under the tray')$q$, v_d)) = '42501', 'SO10: finance';
  PERFORM pg_temp.act(pg_temp.u('b1'));
  ASSERT pg_temp.st(format($q$SELECT public.exos_pos_recount_drawer(%L, 10000, 'found under the tray')$q$, v_d)) = '42501', 'SO10: other org';
  PERFORM pg_temp.act(NULL);
  ASSERT pg_temp.st(format($q$SELECT public.exos_pos_recount_drawer(%L, 10000, 'found under the tray')$q$, v_d)) = '42501', 'SO10: signed out';
  -- What: closed drawers only, a reason, counts that add up.
  PERFORM pg_temp.act(pg_temp.u('a2'));
  ASSERT pg_temp.st(format($q$SELECT public.exos_pos_recount_drawer(%L, 5000, 'not closed yet')$q$, v_open)) = '22023', 'SO10: open drawer';
  ASSERT pg_temp.st(format($q$SELECT public.exos_pos_recount_drawer(%L, 10000, '  ')$q$, v_d)) = '22023', 'SO10: no reason';
  ASSERT pg_temp.st(format($q$SELECT public.exos_pos_recount_drawer(%L, 10000, NULL)$q$, v_d)) = '22023', 'SO10: null reason';
  ASSERT pg_temp.st(format($q$SELECT public.exos_pos_recount_drawer(%L, -1, 'negative count')$q$, v_d)) = '22023', 'SO10: negative';
  ASSERT pg_temp.st(format($q$SELECT public.exos_pos_recount_drawer(%L, 10000, 'bad counts', '{"2000": 4}')$q$, v_d)) = '22023',
    'SO10: counts must add up';
  -- The manager recounts: the first count is kept, the variance recomputed.
  r := public.exos_pos_recount_drawer(v_d, 10000, 'found $10 under the tray', '{"2000": 5}'::jsonb);
  ASSERT (r->>'recount_no')::int = 1 AND (r->>'variance_cents')::int = 0 AND (r->>'previous_counted_cents')::int = 9000
     AND (r->>'expected_cents')::int = 10000 AND (r->>'recounts_left')::int = 2 AND NOT (r->>'replay')::boolean, 'SO10: recount ' || r::text;
  ASSERT (SELECT counted_cents = 10000 AND variance_cents = 0 AND counts = '{"2000": 5}'::jsonb AND status = 'closed'
            AND closed_by = pg_temp.u('a3') AND note = 'short'
            FROM public.exos_pos_drawer_sessions WHERE id = v_d), 'SO10: session updated, close kept';
  ASSERT (SELECT previous_counted_cents = 9000 AND previous_variance_cents = -1000 AND previous_counts = '{"2000": 4, "1000": 1}'::jsonb
            AND previous_counted_by = pg_temp.u('a3') AND recounted_by = pg_temp.u('a2') AND org_id = pg_temp.org('01')
            AND reason = 'found $10 under the tray'
            FROM public.exos_pos_drawer_recounts WHERE session_id = v_d AND recount_no = 1), 'SO10: audit row';
  -- A double tap answers the same recount.
  r := public.exos_pos_recount_drawer(v_d, 10000, 'found $10 under the tray', '{"2000": 5}'::jsonb);
  ASSERT (r->>'replay')::boolean AND (r->>'recount_no')::int = 1, 'SO10: replay ' || r::text;
  ASSERT (SELECT count(*) FROM public.exos_pos_drawer_recounts WHERE session_id = v_d) = 1, 'SO10: one row';
  -- At most 3.
  PERFORM pg_temp.act(pg_temp.u('a1'));
  r := public.exos_pos_recount_drawer(v_d, 9500, 'recounted with the manager');
  ASSERT (r->>'variance_cents')::int = -500 AND (r->>'previous_counted_cents')::int = 10000, 'SO10: recount 2 ' || r::text;
  ASSERT (SELECT previous_counted_by FROM public.exos_pos_drawer_recounts WHERE session_id = v_d AND recount_no = 2) = pg_temp.u('a2'),
    'SO10: recount 2 replaces the manager''s count';
  r := public.exos_pos_recount_drawer(v_d, 10000, 'third and last count');
  ASSERT (r->>'recounts_left')::int = 0, 'SO10: recount 3';
  ASSERT pg_temp.st(format($q$SELECT public.exos_pos_recount_drawer(%L, 10100, 'a fourth one')$q$, v_d)) = '55000', 'SO10: 4th';
  -- 7 days after close: refused.
  PERFORM pg_temp.act(pg_temp.u('a3'));
  r := public.exos_pos_close_drawer(v_open, 5000);
  UPDATE public.exos_pos_drawer_sessions SET closed_at = now() - interval '8 days' WHERE id = v_open;
  PERFORM pg_temp.act(pg_temp.u('a1'));
  ASSERT pg_temp.st(format($q$SELECT public.exos_pos_recount_drawer(%L, 5100, 'late recount')$q$, v_open)) = '55000', 'SO10: 7 days';
  UPDATE public.exos_pos_drawer_sessions SET closed_at = now() - interval '6 days' WHERE id = v_open;
  -- A final settlement freezes the drawers.
  INSERT INTO public.exos_pos_settlements (org_id, event_id, status, summary) VALUES (pg_temp.org('01'), pg_temp.u('e2'), 'final', '{}');
  ASSERT pg_temp.st(format($q$SELECT public.exos_pos_recount_drawer(%L, 5100, 'after the settlement')$q$, v_open)) = '55000', 'SO10: final';
  -- RLS: owner / manager / finance of the org read the audit rows.
  PERFORM pg_temp.act(pg_temp.u('a4'));
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM public.exos_pos_drawer_recounts;
  RESET ROLE;
  ASSERT n = 3, 'SO10: finance reads ' || n;
  PERFORM pg_temp.act(pg_temp.u('a3'));
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM public.exos_pos_drawer_recounts;
  RESET ROLE;
  ASSERT n = 0, 'SO10: scanner reads ' || n;
  PERFORM pg_temp.act(pg_temp.u('b1'));
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM public.exos_pos_drawer_recounts;
  RESET ROLE;
  ASSERT n = 0, 'SO10: other org reads ' || n;
  PERFORM pg_temp.act(NULL);
  RAISE NOTICE 'OK SO10 recount: owner / manager only, closed drawers, reason, counts add up, audit row, variance, replay, 3 max, 7 days, final settlement, RLS';
END $$;

ROLLBACK;
\echo test_small_ops: all passed
