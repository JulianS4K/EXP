-- ============================================================================
-- Migration 20261109110000 — Exos: security hygiene (advisor sweep 2026-11-09)
--
-- Branch:   claude/exos-hygiene
-- Touches:  D: TABLE exos_paste_probe (a leftover test table)
--           W: grants on exos_* sequences (anon loses USAGE / SELECT / UPDATE)
--           W: grants on _exos_site_error(jsonb), _exos_door_code_loose(text)
--              (PUBLIC / anon lose EXECUTE; authenticated + service_role keep it)
--           W: every exos_* RLS policy with a bare auth.uid() / auth.jwt() /
--              auth.role() / auth.email() call (ALTER POLICY, the call wrapped
--              as (SELECT auth.<fn>()); nothing else in the policy changes)
--           W: FUNCTION _exos_match_user_key(uuid, text, uuid) (marker
--              'exos: parked guest key'; IMMUTABLE -> STABLE, it now reads)
--           W: FUNCTION _exos_match_reveal(uuid) (marker 'exos: parked guest
--              reveal')
--           W: FUNCTION exos_group_seat_view(text) (marker 'exos: seat view
--              hides unpublished ids')
-- Pre-reqs: 20261014090000, 20261016130000, 20261031210000, 20261105100000,
--           20261108120000, 20260929130000 (_exos_ticket_parked)
--
-- 1. exos_paste_probe: dropped (no CASCADE: anything depending on it fails
--    the apply instead of going with it).
-- 2. exos_run_channel_splits_each(integer) is NOT pinned, on purpose. It's a
--    PROCEDURE that COMMITs after each event, and a procedure with a SET
--    clause can't COMMIT ("invalid transaction termination"; checked on PG 16).
--    Pinning it would make the hourly exos-channel-split cron fail on its
--    first due event. It is SECURITY INVOKER, only its owner can CALL it, and
--    every name in it is schema-qualified, so a caller's search_path can't
--    redirect it. The advisor's function_search_path_mutable finding for it
--    is accepted (docs/security.md "Hygiene 2026-11-09").
-- 3. Sequences: Supabase's default privileges (FOR ROLE postgres, IN SCHEMA
--    public) give anon, authenticated and service_role USAGE, SELECT and
--    UPDATE on every new sequence, so anon could setval() an id sequence.
--    Revoked here from anon (and PUBLIC) on every exos_* sequence anon can
--    use, read or update; the advisor named exos_tevo_remote_ids_remote_id_seq,
--    exos_audience_exports_id_seq, exos_order_fees_id_seq and
--    exos_fan_exports_id_seq. A sequence whose table anon may INSERT into
--    (none today) is left alone with a WARNING, since its default needs USAGE.
--    Default privileges are NOT changed: they are per schema and role, and
--    public is shared with Terminal-2, so a change would also strip the grants
--    from Terminal-2's future sequences. Instead tests/exos/test_security_hygiene.sql
--    (S3, with the harness now carrying Supabase's sequence default privileges)
--    and scripts/verify-prod.sh ("anon on exos sequences") fail on an exos_*
--    sequence anon can use.
-- 4. RLS: a bare auth.uid() in a policy runs once per row; (SELECT auth.uid())
--    runs once per statement (advisor auth_rls_initplan). Each matching
--    policy's USING / WITH CHECK is rewritten by text on its pg_get_expr form
--    (search_path empty, so every name in it is schema-qualified), wrapping
--    only bare calls, and set with ALTER POLICY, which keeps the name,
--    command, roles, permissive flag and comment by construction (DROP +
--    CREATE would have to rebuild them). A policy with no bare call is
--    skipped, so a replay changes nothing. Only policies on public.exos_*
--    tables (storage.objects' exos_media_* and bridge_event_xref are left to
--    their owners). multiple_permissive_policies is not touched.
-- 5. _exos_site_error(jsonb) and _exos_door_code_loose(text) are plain
--    (invoker) helpers. Their only callers are definer functions
--    (exos_set_org_site, exos_door_code_lookup) and the index
--    exos_guest_list_entries_loose_code_idx; nobody but definer functions and
--    the service role writes exos_guest_list_entries (authenticated may only
--    SELECT it, anon nothing), and an index expression's function needs
--    EXECUTE by the writing role, so service_role keeps an explicit grant.
-- 6. Matched seats: a guest's ticket is parked on the org owner with a pending
--    claim-by-email transfer (guest checkout, comps, marketplace orders;
--    _exos_ticket_parked), so its owner_id is the organizer and
--    _exos_match_user_key's 'email:' fallback never fired: the guest was
--    grouped, blocked and mailed as the organizer. A parked ticket is now
--    keyed 'email:<claim email>', its reveal mail goes to that email, and it
--    gets no SMS (the organizer's opt-in isn't the guest's).
-- 7. exos_group_seat_view(token): event_id and tier_id are null unless the
--    event is published (the event block already was).
--
-- Re-run safe: DROP IF EXISTS, REVOKE / GRANT, policies already wrapped are
-- skipped, marker patches skip when their marker is present. Prod apply needs
-- operator OK. No cron.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.exos_patch_n(p_sig text, p_marker text, p_old text, p_new text, p_hits int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE EXCEPTION '%: not present', p_sig;
  END IF;
  v_def := replace(pg_get_functiondef(p_fn), chr(13), '');
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

-- ---------------------------------------------------------------------------
-- 1. The leftover test table.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS public.exos_paste_probe;

-- ---------------------------------------------------------------------------
-- 3. anon off every exos_* sequence.
-- ---------------------------------------------------------------------------
DO $seq$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS seq,
           (SELECT d.refobjid::regclass FROM pg_depend d
             WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
               AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i') LIMIT 1) AS tbl
      FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
     WHERE s.nspname = 'public' AND c.relkind = 'S' AND c.relname LIKE 'exos\_%'
       AND (has_sequence_privilege('anon', c.oid, 'USAGE')
            OR has_sequence_privilege('anon', c.oid, 'SELECT')
            OR has_sequence_privilege('anon', c.oid, 'UPDATE'))
     ORDER BY c.relname
  LOOP
    IF r.tbl IS NOT NULL AND has_table_privilege('anon', r.tbl, 'INSERT') THEN
      RAISE WARNING 'exos hygiene: % kept for anon (anon inserts into %)', r.seq, r.tbl;
      CONTINUE;
    END IF;
    EXECUTE format('REVOKE ALL ON SEQUENCE %s FROM PUBLIC, anon', r.seq);
  END LOOP;
END $seq$;

-- ---------------------------------------------------------------------------
-- 5. Two helpers: no anon / PUBLIC EXECUTE.
-- ---------------------------------------------------------------------------
DO $fn$
BEGIN
  IF to_regprocedure('public._exos_site_error(jsonb)') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public._exos_site_error(jsonb) FROM PUBLIC, anon;
    GRANT EXECUTE ON FUNCTION public._exos_site_error(jsonb) TO authenticated, service_role;
  END IF;
  IF to_regprocedure('public._exos_door_code_loose(text)') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public._exos_door_code_loose(text) FROM PUBLIC, anon;
    GRANT EXECUTE ON FUNCTION public._exos_door_code_loose(text) TO authenticated, service_role;
  END IF;
END $fn$;

-- ---------------------------------------------------------------------------
-- 4. RLS: wrap bare auth.* calls so they run once per statement.
-- ---------------------------------------------------------------------------
-- p: a policy expression as pg_get_expr prints it. Calls already wrapped
-- print as "( SELECT auth.uid() AS uid)": they're set aside, the bare ones
-- wrapped, and the set-aside ones put back, so nothing is wrapped twice.
CREATE OR REPLACE FUNCTION pg_temp.exos_wrap_auth(p text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE f text; v text := p;
BEGIN
  IF v IS NULL THEN RETURN NULL; END IF;
  FOREACH f IN ARRAY ARRAY['uid', 'jwt', 'role', 'email'] LOOP
    v := replace(v, '( SELECT auth.' || f || '() AS ' || f || ')', chr(1) || f || chr(2));
    v := regexp_replace(v, '(^|[^A-Za-z0-9_."$])auth\.' || f || '\(\)', '\1(SELECT auth.' || f || '())', 'g');
    v := replace(v, chr(1) || f || chr(2), '( SELECT auth.' || f || '() AS ' || f || ')');
  END LOOP;
  RETURN v;
END $$;

DO $pol$
DECLARE
  r      record;
  v_path text := current_setting('search_path');
  v_q    text;
  v_w    text;
  v_n    int := 0;
BEGIN
  -- Empty search_path: pg_get_expr qualifies every name, so the text means
  -- the same objects when ALTER POLICY parses it back.
  PERFORM set_config('search_path', '', true);
  FOR r IN
    SELECT p.polname, p.polrelid,
           pg_get_expr(p.polqual, p.polrelid) AS qual,
           pg_get_expr(p.polwithcheck, p.polrelid) AS chk
      FROM pg_catalog.pg_policy p
      JOIN pg_catalog.pg_class c ON c.oid = p.polrelid
      JOIN pg_catalog.pg_namespace s ON s.oid = c.relnamespace
     WHERE s.nspname = 'public' AND c.relname LIKE 'exos\_%'
     ORDER BY c.relname, p.polname
  LOOP
    v_q := pg_temp.exos_wrap_auth(r.qual);
    v_w := pg_temp.exos_wrap_auth(r.chk);
    CONTINUE WHEN v_q IS NOT DISTINCT FROM r.qual AND v_w IS NOT DISTINCT FROM r.chk;
    EXECUTE format('ALTER POLICY %I ON %s', r.polname, r.polrelid::regclass)
         || CASE WHEN v_q IS DISTINCT FROM r.qual THEN format(' USING (%s)', v_q) ELSE '' END
         || CASE WHEN v_w IS DISTINCT FROM r.chk THEN format(' WITH CHECK (%s)', v_w) ELSE '' END;
    v_n := v_n + 1;
  END LOOP;
  PERFORM set_config('search_path', v_path, true);
  RAISE NOTICE 'exos hygiene: % polic(ies) wrapped', v_n;
END $pol$;

-- ---------------------------------------------------------------------------
-- 6. Matched seats: a parked guest ticket is the guest's.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public._exos_match_user_key(uuid,text,uuid)',
  '/* exos: parked guest key */',
  $o$ IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(p_owner::text, $o$,
  $n$ STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  /* exos: parked guest key */ -- mig 20261109110000: a ticket parked on the org
  -- for a guest's claim (guest checkout, comps, marketplace orders) is keyed by
  -- the claim email, not as the org owner holding it.
  SELECT coalesce((SELECT 'email:' || lower(btrim(ptr.receiver_email))
                     FROM public.exos_tickets pt
                     JOIN public.exos_transfers ptr ON ptr.id = pt.pending_transfer_id
                    WHERE pt.id = p_ticket AND public._exos_ticket_parked(pt, ptr)),
                  p_owner::text, $n$, 1);

SELECT pg_temp.exos_patch_n('public._exos_match_reveal(uuid)',
  '/* exos: parked guest reveal */',
  $o$    SELECT m.id AS member_id, m.group_id, t.owner_id, t.buyer_email, u.email AS owner_email,
           g.meet_at, s.name AS spot_name, s.address, s.details
      FROM public.exos_social_group_members m
      JOIN public.exos_social_groups g ON g.id = m.group_id
      JOIN public.exos_tickets t ON t.id = m.ticket_id
      LEFT JOIN auth.users u ON u.id = t.owner_id
$o$,
  $n$    SELECT m.id AS member_id, m.group_id,
           /* exos: parked guest reveal */ -- mig 20261109110000: a ticket parked on
           -- the org for a guest's claim is mailed to the claim email and never
           -- texted (owner_id is the organizer, whose opt-in isn't the guest's).
           CASE WHEN pk.email IS NULL THEN t.owner_id END AS owner_id, t.buyer_email,
           coalesce(pk.email, u.email) AS owner_email,
           g.meet_at, s.name AS spot_name, s.address, s.details
      FROM public.exos_social_group_members m
      JOIN public.exos_social_groups g ON g.id = m.group_id
      JOIN public.exos_tickets t ON t.id = m.ticket_id
      LEFT JOIN LATERAL (SELECT lower(btrim(ptr.receiver_email)) AS email
                           FROM public.exos_transfers ptr
                          WHERE ptr.id = t.pending_transfer_id AND public._exos_ticket_parked(t, ptr)) pk ON true
      LEFT JOIN auth.users u ON u.id = t.owner_id
$n$, 1);

-- ---------------------------------------------------------------------------
-- 7. A seat link to an unpublished event names no event or ticket type.
-- ---------------------------------------------------------------------------
SELECT pg_temp.exos_patch_n('public.exos_group_seat_view(text)',
  '/* exos: seat view hides unpublished ids */',
  $o$    'event_id', g.event_id,
    'tier_id', g.tier_id,
$o$,
  $n$    /* exos: seat view hides unpublished ids */ -- mig 20261109110000
    'event_id', CASE WHEN e.id IS NOT NULL THEN g.event_id END,
    'tier_id', CASE WHEN e.id IS NOT NULL THEN g.tier_id END,
$n$, 1);
