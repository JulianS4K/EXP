-- ============================================================================
-- Migration 20261105160000 — Exos: token lineage (2026-11-05)
-- ============================================================================
-- Security fix for tokens minted through the API (mig 20261105110000:
-- exos_api_me 'token.create', exos-api POST /v1/me/personal-access-tokens).
-- A personal access token or an account token holding me:write could mint a
-- new token with at most its own scopes, its expiry clamped to its own. Two
-- gaps:
--
-- 1. Nothing linked the new token to the one that made it. Someone holding a
--    leaked token could mint a child; the owner revoked the leaked token; the
--    child kept working. Now each API-minted token records its parent
--    (parent_token_id), and revoking a token revokes its live children at
--    once (revoked_reason 'parent', one pat.revoked audit row each with
--    detail.cascade_from).
-- 2. A parent that never expires could mint a child that never expires
--    (expires_days: null). A token minted through the API now always
--    expires: expires_days is 30, 90 (default) or 365, never null; the clamp
--    to the parent's expiry stays.
--
-- And a token minted through the API can't mint further (42501): only a
-- token made in the dashboard (parent_token_id NULL) mints, so a leak is at
-- most one level deep and every child is one revoke away. Revoking stays
-- allowed for every token: token.revoke is unchanged (a token may revoke its
-- own user's other tokens, the owner's own power).
--
-- The pat.created audit row of an API mint carries detail.parent_token_id
-- and detail.via = 'api' (set on the row the create function wrote, in the
-- same transaction; exos_create_personal_token / exos_create_account_token
-- are unchanged).
--
-- Touches:  A: COLUMN exos_personal_tokens.parent_token_id,
--              exos_account_tokens.parent_token_id (nullable self-FK, ON
--              DELETE SET NULL; no client column grant: the dashboard
--              doesn't read it)
--           W: CHECK on revoked_reason of both tables (+ 'parent')
--           N: FUNCTION _exos_tg_pat_revoke_children,
--              _exos_tg_account_token_revoke_children (trigger functions,
--              no EXECUTE for anyone) and TRIGGER exos_personal_tokens_revoke_children,
--              exos_account_tokens_revoke_children (AFTER UPDATE OF revoked_at)
--           W: FUNCTION exos_api_me (patched in place, marker-checked; same
--              signature, same grants: service role only)
-- Callers:  exos-api /v1/me/personal-access-tokens (exos_api_me); every
--           revoke path fires the cascade: exos_revoke_personal_token,
--           exos_revoke_account_token, _exos_pat_revoke_self,
--           _exos_account_token_revoke_self, the offboarding trigger
--           (left_org).
-- Pre-reqs: 20261031130500 (exos_personal_tokens, _exos_token_audit),
--           20261105110000 (exos_account_tokens, exos_api_me).
-- Re-run safe: ADD COLUMN IF NOT EXISTS, CHECK dropped and re-added,
-- CREATE OR REPLACE, marker-checked patches (pg_temp.exos_patch_n). D4
-- authors; not applied.
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

-- ===========================================================================
-- 1. The parent: the token that minted this one through the API.
-- ===========================================================================
-- A personal token's parent is a personal token, an account token's an
-- account token (exos_api_me mints the maker's own kind). NULL: made in the
-- dashboard. No row is ever deleted except with its user (or a personal
-- token's org), which takes the children with it, so SET NULL only keeps a
-- stray delete from failing.
ALTER TABLE public.exos_personal_tokens
  ADD COLUMN IF NOT EXISTS parent_token_id uuid REFERENCES public.exos_personal_tokens (id) ON DELETE SET NULL;
ALTER TABLE public.exos_account_tokens
  ADD COLUMN IF NOT EXISTS parent_token_id uuid REFERENCES public.exos_account_tokens (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS exos_personal_tokens_parent_idx ON public.exos_personal_tokens (parent_token_id)
  WHERE parent_token_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_account_tokens_parent_idx ON public.exos_account_tokens (parent_token_id)
  WHERE parent_token_id IS NOT NULL;
COMMENT ON COLUMN public.exos_personal_tokens.parent_token_id IS
  'The personal token that minted this one through exos-api (exos_api_me token.create); NULL: made in the dashboard. Revoking the parent revokes this one (revoked_reason parent); a token with a parent can''t mint. mig 20261105160000.';
COMMENT ON COLUMN public.exos_account_tokens.parent_token_id IS
  'The account token that minted this one through exos-api (exos_api_me token.create); NULL: made in the dashboard. Revoking the parent revokes this one (revoked_reason parent); a token with a parent can''t mint. mig 20261105160000.';
-- Client grants stay as they were: SELECT on the listed columns only (no
-- parent_token_id, no key_hash). Re-revoked in case a column grant drifted.
REVOKE SELECT (parent_token_id) ON public.exos_personal_tokens FROM PUBLIC, anon, authenticated;
REVOKE SELECT (parent_token_id) ON public.exos_account_tokens FROM PUBLIC, anon, authenticated;

-- ===========================================================================
-- 2. revoked_reason 'parent'.
-- ===========================================================================
DO $$
DECLARE c record;
BEGIN
  FOR c IN SELECT conrelid::regclass AS tbl, conname FROM pg_constraint
            WHERE conrelid IN ('public.exos_personal_tokens'::regclass, 'public.exos_account_tokens'::regclass)
              AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%revoked_reason%' LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', c.tbl, c.conname);
  END LOOP;
END $$;
ALTER TABLE public.exos_personal_tokens ADD CONSTRAINT exos_personal_tokens_revoked_reason_check
  CHECK (revoked_reason IS NULL OR revoked_reason IN ('user', 'left_org', 'api', 'parent'));
ALTER TABLE public.exos_account_tokens ADD CONSTRAINT exos_account_tokens_revoked_reason_check
  CHECK (revoked_reason IS NULL OR revoked_reason IN ('user', 'api', 'parent'));

-- ===========================================================================
-- 3. Revoking a token revokes its live children.
-- ===========================================================================
-- Fires on every revoke path (the dashboard, exos-api's own-token revoke and
-- DELETE …/current, offboarding). A child's own revoke re-fires it for its
-- children; there are none, as a child can't mint (section 4).
CREATE OR REPLACE FUNCTION public._exos_tg_pat_revoke_children()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  FOR r IN UPDATE public.exos_personal_tokens SET revoked_at = now(), revoked_reason = 'parent'
            WHERE parent_token_id = NEW.id AND revoked_at IS NULL
           RETURNING id, user_id, org_id LOOP
    PERFORM public._exos_token_audit('pat.revoked', auth.uid(), r.user_id, r.org_id, NULL, r.id::text,
                                     jsonb_build_object('cascade_from', NEW.id));
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_pat_revoke_children() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_personal_tokens_revoke_children ON public.exos_personal_tokens;
CREATE TRIGGER exos_personal_tokens_revoke_children AFTER UPDATE OF revoked_at ON public.exos_personal_tokens
  FOR EACH ROW WHEN (OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL)
  EXECUTE FUNCTION public._exos_tg_pat_revoke_children();

CREATE OR REPLACE FUNCTION public._exos_tg_account_token_revoke_children()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record;
BEGIN
  FOR r IN UPDATE public.exos_account_tokens SET revoked_at = now(), revoked_reason = 'parent'
            WHERE parent_token_id = NEW.id AND revoked_at IS NULL
           RETURNING id, user_id LOOP
    PERFORM public._exos_token_audit('pat.revoked', auth.uid(), r.user_id, NULL, NULL, r.id::text,
                                     jsonb_build_object('account', true, 'cascade_from', NEW.id));
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public._exos_tg_account_token_revoke_children() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_account_tokens_revoke_children ON public.exos_account_tokens;
CREATE TRIGGER exos_account_tokens_revoke_children AFTER UPDATE OF revoked_at ON public.exos_account_tokens
  FOR EACH ROW WHEN (OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL)
  EXECUTE FUNCTION public._exos_tg_account_token_revoke_children();

-- ===========================================================================
-- 4. exos_api_me 'token.create' (mig 20261105110000's body; no later
--    migration patched it): no chains, always expires, records the parent.
-- ===========================================================================
-- 4a. A token minted through the API can't mint.
SELECT pg_temp.exos_patch_n('public.exos_api_me(text,text,text,text,jsonb)',
  '/* exos: api tokens can''t mint */',
  $o$      IF jsonb_typeof(a->'scopes') IS DISTINCT FROM 'array' OR jsonb_array_length(a->'scopes') NOT BETWEEN 1 AND 40 THEN$o$,
  $n$      /* exos: api tokens can't mint */
      IF EXISTS (SELECT 1 FROM public.exos_personal_tokens p
                  WHERE p.id = (v_cred->>'credential_id')::uuid AND p.parent_token_id IS NOT NULL)
         OR EXISTS (SELECT 1 FROM public.exos_account_tokens t
                     WHERE t.id = (v_cred->>'credential_id')::uuid AND t.parent_token_id IS NOT NULL) THEN
        RAISE EXCEPTION 'exos_api_me: a token minted through the API can''t mint tokens; make one in Profile → Developer'
          USING ERRCODE = '42501';
      END IF;
      IF jsonb_typeof(a->'scopes') IS DISTINCT FROM 'array' OR jsonb_array_length(a->'scopes') NOT BETWEEN 1 AND 40 THEN$n$, 1);

-- 4b. expires_days is 30, 90 (default) or 365; null (never) is refused.
SELECT pg_temp.exos_patch_n('public.exos_api_me(text,text,text,text,jsonb)',
  '/* exos: api tokens expire */',
  $o$      IF a ? 'expires_days' AND jsonb_typeof(a->'expires_days') NOT IN ('number', 'null') THEN
        RAISE EXCEPTION 'exos_api_me: expires_days must be 30, 90, 365 or null' USING ERRCODE = '22023';
      END IF;$o$,
  $n$      IF a ? 'expires_days' AND jsonb_typeof(a->'expires_days') IS DISTINCT FROM 'number' /* exos: api tokens expire */ THEN
        RAISE EXCEPTION 'exos_api_me: expires_days must be 30, 90 or 365 (a token minted through the API always expires)'
          USING ERRCODE = '22023';
      END IF;$n$, 1);

-- 4c. Record the parent (and clamp, as before: least() skips a NULL
--     parent expiry), and name it on the pat.created row.
SELECT pg_temp.exos_patch_n('public.exos_api_me(text,text,text,text,jsonb)',
  '/* exos: api token parent */',
  $o$        v_out := public.exos_create_account_token(a->>'name', v_req, v_days);
        IF v_exp IS NOT NULL THEN
          UPDATE public.exos_account_tokens SET expires_at = least(coalesce(expires_at, v_exp), v_exp)
           WHERE id = (v_out->>'id')::uuid RETURNING expires_at INTO v_exp;
        END IF;
      ELSE
        v_out := public.exos_create_personal_token((v_cred->>'org_id')::uuid, a->>'name', v_req, v_days);
        IF v_exp IS NOT NULL THEN
          UPDATE public.exos_personal_tokens SET expires_at = least(coalesce(expires_at, v_exp), v_exp)
           WHERE id = (v_out->>'id')::uuid RETURNING expires_at INTO v_exp;
        END IF;
      END IF;$o$,
  $n$        v_out := public.exos_create_account_token(a->>'name', v_req, v_days);
        /* exos: api token parent */
        UPDATE public.exos_account_tokens
           SET parent_token_id = (v_cred->>'credential_id')::uuid, expires_at = least(expires_at, v_exp)
         WHERE id = (v_out->>'id')::uuid RETURNING expires_at INTO v_exp;
      ELSE
        v_out := public.exos_create_personal_token((v_cred->>'org_id')::uuid, a->>'name', v_req, v_days);
        UPDATE public.exos_personal_tokens
           SET parent_token_id = (v_cred->>'credential_id')::uuid, expires_at = least(expires_at, v_exp)
         WHERE id = (v_out->>'id')::uuid RETURNING expires_at INTO v_exp;
      END IF;
      -- The pat.created row the create function just wrote names the parent.
      UPDATE public.exos_token_audit
         SET detail = coalesce(detail, '{}'::jsonb)
                      || jsonb_build_object('parent_token_id', v_cred->>'credential_id', 'via', 'api')
       WHERE action = 'pat.created' AND credential_id = v_out->>'id';$n$, 1);
