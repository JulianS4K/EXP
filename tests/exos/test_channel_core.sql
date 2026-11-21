-- ============================================================================
-- The shared channel core (mig 20261121162400).
--   CC1 grants: only the service role decrypts (exos_integration_secret);
--       the Vault seam, the write core, the copy, the legacy reader and the
--       backfill have no client or service-role EXECUTE; the audit writer and
--       the usage RPCs are service role; the usage summary signed in
--   CC2 the browser's write: owner / manager save through the shared core,
--       never get the secret back, each save / remove is one org audit row
--       holding no value; finance / scanner / another org refused; the
--       managed providers refused by save and remove and not listed
--   CC3 the copies: a DICE / Eventbrite / ad / Discord connect lands in the
--       store (Vault copy, copied_from), a reconnect updates it, a
--       disconnect drops it; the old readers still return the old secret
--   CC4 the data copy: rows written before the triggers are copied by the
--       backfill (re-run safe); with no copy, reads fall back to the old
--       table (source legacy:<table>)
--   CC5 exos_org_secrets.distribution: written plain, stored in Vault, the
--       column keeps a stub; a stub written back keeps the secret; NULL
--       removes it; the backfill moves an old plain value
--   CC6 exos_channel_audit: the writer scrubs secret-named keys, auth
--       strings and query values; owner / manager read their own org only;
--       no client writes
--   CC7 exos_channel_usage: a live reserve spends only under the threshold,
--       planned usage counts once per identical request and apart from live,
--       rolling windows (a day, a week, a year), the summary's roles; it refuses
--       REPEATABLE READ (a snapshot sum would overshoot)
--   CC8 nothing outlives its row: deleting the exos_org_secrets row drops the
--       Lysted copy (store row and Vault); an org delete leaves no store
--       row and no Vault copy (a managed copy, a plain Integrations secret,
--       the Lysted value); the retention sweep covers every org
-- Self-contained (cc1 prefix), rolled back.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('cc100000-0000-0000-0000-0000000000a1','cc1own@x.com',now()),
  ('cc100000-0000-0000-0000-0000000000a2','cc1man@x.com',now()),
  ('cc100000-0000-0000-0000-0000000000a3','cc1fin@x.com',now()),
  ('cc100000-0000-0000-0000-0000000000a4','cc1scan@x.com',now()),
  ('cc100000-0000-0000-0000-0000000000a5','cc1other@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('cc100000-0000-0000-0000-000000000001','Core Org','core-org-cc1','cc100000-0000-0000-0000-0000000000a1'),
  ('cc100000-0000-0000-0000-000000000002','Other Org','other-org-cc1','cc100000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('cc100000-0000-0000-0000-000000000001','cc100000-0000-0000-0000-0000000000a1','owner'),
  ('cc100000-0000-0000-0000-000000000001','cc100000-0000-0000-0000-0000000000a2','manager'),
  ('cc100000-0000-0000-0000-000000000001','cc100000-0000-0000-0000-0000000000a3','finance'),
  ('cc100000-0000-0000-0000-000000000001','cc100000-0000-0000-0000-0000000000a4','scanner'),
  ('cc100000-0000-0000-0000-000000000002','cc100000-0000-0000-0000-0000000000a5','owner');

CREATE FUNCTION pg_temp.act(p_uid text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p_uid, ''), true), set_config('app.jwt', '', true);
$$;
GRANT EXECUTE ON FUNCTION pg_temp.act(text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('cc100000-0000-0000-0000-0000000000' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.u(text) TO anon, authenticated, service_role;
CREATE FUNCTION pg_temp.org(p int DEFAULT 1) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('cc100000-0000-0000-0000-00000000000' || p)::uuid $$;
GRANT EXECUTE ON FUNCTION pg_temp.org(int) TO anon, authenticated, service_role;
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
GRANT EXECUTE ON FUNCTION pg_temp.refused(text, text) TO anon, authenticated, service_role;
-- What the service role reads (as the service role).
CREATE FUNCTION pg_temp.cred(p_org uuid, p_provider text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  SET LOCAL ROLE service_role;
  r := public.exos_integration_secret(p_org, p_provider);
  RESET ROLE;
  RETURN r;
END $$;
CREATE FUNCTION pg_temp.audits(p_action text) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.exos_org_audit WHERE org_id = pg_temp.org() AND action = p_action
$$;

-- CC1 ------------------------------------------------------------------------
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    ASSERT NOT has_function_privilege(r, 'public.exos_integration_secret(uuid,text)', 'EXECUTE'), 'CC1: ' || r || ' decrypts';
    ASSERT NOT has_function_privilege(r, 'public.exos_channel_audit_record(uuid,jsonb)', 'EXECUTE'), 'CC1: ' || r || ' writes the channel audit';
    ASSERT NOT has_function_privilege(r, 'public.exos_channel_usage_reserve(uuid,text,text,text,integer,integer,integer,boolean,text)', 'EXECUTE'), 'CC1: ' || r || ' spends usage';
    ASSERT NOT has_function_privilege(r, 'public.exos_channel_usage_read(uuid,text,text,text,integer)', 'EXECUTE'), 'CC1: ' || r || ' reads usage';
    ASSERT NOT has_function_privilege(r, 'public.exos_channel_usage_release(uuid,uuid)', 'EXECUTE'), 'CC1: ' || r || ' releases usage';
    ASSERT NOT has_table_privilege(r, 'public.exos_channel_usage', 'SELECT'), 'CC1: ' || r || ' reads the usage table';
    ASSERT NOT has_table_privilege(r, 'public.exos_channel_audit', 'INSERT'), 'CC1: ' || r || ' inserts audit rows';
    ASSERT NOT has_table_privilege(r, 'public.exos_channel_audit', 'UPDATE'), 'CC1: ' || r || ' updates audit rows';
    ASSERT NOT has_table_privilege(r, 'public.exos_channel_audit', 'DELETE'), 'CC1: ' || r || ' deletes audit rows';
  END LOOP;
  ASSERT has_function_privilege('service_role', 'public.exos_integration_secret(uuid,text)', 'EXECUTE'), 'CC1: service role decrypts';
  ASSERT has_function_privilege('service_role', 'public.exos_channel_audit_record(uuid,jsonb)', 'EXECUTE'), 'CC1: service role records';
  ASSERT has_function_privilege('authenticated', 'public.exos_channel_usage_summary(uuid)', 'EXECUTE'), 'CC1: the summary is signed in';
  ASSERT NOT has_function_privilege('anon', 'public.exos_channel_usage_summary(uuid)', 'EXECUTE'), 'CC1: anon has no summary';
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    ASSERT NOT has_function_privilege(r, 'public._exos_vault_get(uuid)', 'EXECUTE'), 'CC1: ' || r || ' reads Vault directly';
    ASSERT NOT has_function_privilege(r, 'public._exos_vault_put(uuid,text,text,text)', 'EXECUTE'), 'CC1: ' || r || ' writes Vault directly';
    ASSERT NOT has_function_privilege(r, 'public._exos_vault_drop(uuid,text)', 'EXECUTE'), 'CC1: ' || r || ' drops Vault secrets';
    ASSERT NOT has_function_privilege(r, 'public._exos_integration_put(uuid,text,text,jsonb,text,text,uuid,text,boolean,text)', 'EXECUTE'), 'CC1: ' || r || ' runs the write core';
    ASSERT NOT has_function_privilege(r, 'public._exos_cred_legacy(uuid,text)', 'EXECUTE'), 'CC1: ' || r || ' reads the old stores';
    ASSERT NOT has_function_privilege(r, 'public._exos_cred_copy(uuid,text)', 'EXECUTE'), 'CC1: ' || r || ' runs a copy';
    ASSERT NOT has_function_privilege(r, 'public._exos_cred_backfill()', 'EXECUTE'), 'CC1: ' || r || ' runs the backfill';
  END LOOP;
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_channel_audit'::regclass), 'CC1: audit RLS on';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_channel_usage'::regclass), 'CC1: usage RLS on';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_org_integrations', 'SELECT'), 'CC1: the store has no client read';
  RAISE NOTICE 'OK  CC1 only the service role decrypts; the core has no client grant';
END $$;

-- CC2 ------------------------------------------------------------------------
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
DO $$
DECLARE r jsonb;
BEGIN
  r := public.exos_save_integration(pg_temp.org(), 'pretix', '{"base_url":"https://pretix.eu","organizer":"demo"}', 'pretix-token-cc1-SECRET', 'Box office');
  ASSERT r ->> 'secret_hint' = '…CRET' AND (r ->> 'has_secret')::boolean, 'CC2: saved with a hint, got ' || r;
  ASSERT r::text NOT LIKE '%pretix-token-cc1%', 'CC2: the save never returns the secret';
  ASSERT pg_temp.refused($q$SELECT public.exos_integration_secret(pg_temp.org(), 'pretix')$q$, 'permission denied'), 'CC2: the owner can''t decrypt';
  ASSERT pg_temp.refused($q$SELECT public.exos_save_integration(pg_temp.org(), 'dice', '{}', 'tok_dice_0123456789abcdef')$q$, 'unknown provider'), 'CC2: dice is managed';
  ASSERT pg_temp.refused($q$SELECT public.exos_save_integration(pg_temp.org(), 'ads_meta', '{}', 'x123456789')$q$, 'unknown provider'), 'CC2: ad platforms are managed';
  ASSERT pg_temp.refused($q$SELECT public.exos_remove_integration(pg_temp.org(), 'eventbrite')$q$, 'disconnect it where'), 'CC2: remove refuses managed';
END $$;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a2');
DO $$
BEGIN
  PERFORM public.exos_save_integration(pg_temp.org(), 'twilio', '{"account_sid":"test-sid-cc1"}', 'twilio-auth-cc1-SECRET');
END $$;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a3');
DO $$
BEGIN
  ASSERT pg_temp.refused($q$SELECT public.exos_save_integration(pg_temp.org(), 'pretix', '{}', 'x')$q$, 'owner or manager only'), 'CC2: finance refused';
  ASSERT pg_temp.refused($q$SELECT public.exos_remove_integration(pg_temp.org(), 'pretix')$q$, 'owner or manager only'), 'CC2: finance can''t remove';
  -- Finance still lists (unchanged), without the managed copies.
  ASSERT (SELECT count(*) FROM public.exos_list_integrations(pg_temp.org())) = 2, 'CC2: finance lists the two';
END $$;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a4');
DO $$ BEGIN
  ASSERT pg_temp.refused($q$SELECT public.exos_save_integration(pg_temp.org(), 'pretix', '{}', 'x')$q$, 'owner or manager only'), 'CC2: scanner refused';
END $$;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a5');
DO $$ BEGIN
  ASSERT pg_temp.refused($q$SELECT public.exos_save_integration(pg_temp.org(), 'pretix', '{}', 'x')$q$, 'owner or manager only'), 'CC2: another org''s owner refused';
END $$;
RESET ROLE;
DO $$
DECLARE c jsonb; a record;
BEGIN
  c := pg_temp.cred(pg_temp.org(), 'pretix');
  ASSERT c ->> 'secret' = 'pretix-token-cc1-SECRET' AND c ->> 'source' = 'store' AND c -> 'config' ->> 'organizer' = 'demo',
         'CC2: the service role decrypts, got ' || coalesce(c::text, 'null');
  ASSERT (SELECT count(*) FROM vault.secrets WHERE name = 'exos_integration:' || pg_temp.org() || ':pretix') = 1, 'CC2: one Vault secret';
  ASSERT pg_temp.audits('integration.save') = 2, 'CC2: two saves, two audit rows';
  SELECT * INTO a FROM public.exos_org_audit WHERE org_id = pg_temp.org() AND action = 'integration.save' AND entity_id = 'pretix';
  ASSERT a.actor_uid = pg_temp.u('a1') AND a.changes ->> 'new_credential' = 'true' AND a.changes ->> 'settings' = 'base_url,organizer',
         'CC2: the audit row names the provider and the setting names, got ' || a.changes;
  ASSERT (SELECT bool_and(x::text NOT LIKE '%SECRET%') FROM public.exos_org_audit x WHERE x.org_id = pg_temp.org()), 'CC2: no secret in the audit log';
END $$;
-- A settings-only save keeps the secret.
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
SELECT public.exos_save_integration(pg_temp.org(), 'pretix', '{"base_url":"https://pretix.eu","organizer":"demo2"}', NULL);
SELECT public.exos_remove_integration(pg_temp.org(), 'twilio');
RESET ROLE;
DO $$
BEGIN
  ASSERT pg_temp.cred(pg_temp.org(), 'pretix') ->> 'secret' = 'pretix-token-cc1-SECRET', 'CC2: a settings-only save keeps the secret';
  ASSERT pg_temp.cred(pg_temp.org(), 'pretix') -> 'config' ->> 'organizer' = 'demo2', 'CC2: and takes the settings';
  ASSERT pg_temp.cred(pg_temp.org(), 'twilio') IS NULL, 'CC2: removed';
  ASSERT NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'exos_integration:' || pg_temp.org() || ':twilio'), 'CC2: its Vault secret went too';
  ASSERT pg_temp.audits('integration.remove') = 1, 'CC2: one remove row';
  ASSERT (SELECT changes ->> 'new_credential' FROM public.exos_org_audit WHERE org_id = pg_temp.org() AND action = 'integration.save'
           AND entity_id = 'pretix' ORDER BY id DESC LIMIT 1) = 'false', 'CC2: a settings-only save says so';
  ASSERT pg_temp.cred(pg_temp.org(), 'nonsense') IS NULL, 'CC2: an unknown provider reads nothing';
  RAISE NOTICE 'OK  CC2 owner / manager write through the core, audited, never read back; managed providers refused';
END $$;

-- CC3 ------------------------------------------------------------------------
SET LOCAL ROLE service_role;
SELECT public.exos_dice_connect(pg_temp.org(), pg_temp.u('a1'), 'tok_dice_0123456789abcdef', 'v1', 'D Promotions');
SELECT public._exos_eventbrite_store(pg_temp.org(), pg_temp.u('a1'), 'EBTOKEN0123456789', 'EB Account', 'private_token');
RESET ROLE;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
SELECT public.exos_set_ad_credential(pg_temp.org(), 'meta', '{"pixel_id":"1234567890"}', 'EAAmetaTOKENcc1abc', true, 'TEST123');
SELECT public.exos_discord_set_webhook(pg_temp.org(),
  'https://discord.com/api/webhooks/123456789012345678/T1' || repeat('aB9_-x', 11) || 'Zq');
RESET ROLE;
DO $$
DECLARE c jsonb; v_tok text;
BEGIN
  c := pg_temp.cred(pg_temp.org(), 'dice');
  ASSERT c ->> 'secret' = 'tok_dice_0123456789abcdef' AND c ->> 'source' = 'store' AND c -> 'config' ->> 'account_id' = 'v1',
         'CC3: the DICE token is in the store, got ' || coalesce(c::text, 'null');
  ASSERT (SELECT copied_from FROM public.exos_org_integrations WHERE org_id = pg_temp.org() AND provider = 'dice') = 'exos_dice_connections',
         'CC3: marked as a copy';
  ASSERT (SELECT secret_id FROM public.exos_org_integrations WHERE org_id = pg_temp.org() AND provider = 'dice')
         <> (SELECT secret_id FROM public.exos_dice_connections WHERE org_id = pg_temp.org()), 'CC3: a separate Vault copy';
  c := pg_temp.cred(pg_temp.org(), 'eventbrite');
  ASSERT c ->> 'secret' = 'EBTOKEN0123456789' AND c -> 'config' ->> 'auth_method' = 'private_token' AND c ->> 'account_name' = 'EB Account',
         'CC3: Eventbrite copied, got ' || coalesce(c::text, 'null');
  c := pg_temp.cred(pg_temp.org(), 'ads_meta');
  ASSERT c ->> 'secret' = 'EAAmetaTOKENcc1abc' AND c -> 'config' ->> 'pixel_id' = '1234567890'
         AND c -> 'config' ->> 'test_event_code' = 'TEST123' AND (c ->> 'writes_enabled')::boolean AND c ->> 'status' = 'connected',
         'CC3: the Meta token copied, got ' || coalesce(c::text, 'null');
  c := pg_temp.cred(pg_temp.org(), 'discord');
  ASSERT c ->> 'secret' = 'T1' || repeat('aB9_-x', 11) || 'Zq' AND c -> 'config' ->> 'webhook_id' = '123456789012345678'
         AND NOT (c ->> 'writes_enabled')::boolean, 'CC3: the Discord webhook token copied, got ' || coalesce(c::text, 'null');
  -- The old readers are untouched.
  SET LOCAL ROLE service_role;
  ASSERT public.exos_eventbrite_token(pg_temp.org(), pg_temp.u('a1')) = 'EBTOKEN0123456789', 'CC3: the old Eventbrite read';
  SELECT s.token INTO v_tok FROM public.exos_dice_sync_claim(pg_temp.org(), pg_temp.u('a1'), 'dashboard') s;
  ASSERT v_tok = 'tok_dice_0123456789abcdef', 'CC3: the old DICE claim still returns the token';
  RESET ROLE;
END $$;
-- Reconnect (another member: a new connect) and disconnect.
SET LOCAL ROLE service_role;
SELECT public.exos_dice_connect(pg_temp.org(), pg_temp.u('a2'), 'tok_dice_NEW_0123456789abcdef', 'v1', 'D Promotions');
SELECT public._exos_eventbrite_store(pg_temp.org(), pg_temp.u('a2'), 'EBTOKENnew0123456789', 'EB Account', 'oauth');
RESET ROLE;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
SELECT public.exos_set_ad_credential(pg_temp.org(), 'meta', '{"pixel_id":"1234567890"}', '', false, NULL);
RESET ROLE;
DO $$
BEGIN
  ASSERT pg_temp.cred(pg_temp.org(), 'dice') ->> 'secret' = 'tok_dice_NEW_0123456789abcdef', 'CC3: a DICE reconnect updates the copy';
  ASSERT pg_temp.cred(pg_temp.org(), 'eventbrite') ->> 'secret' = 'EBTOKENnew0123456789'
         AND pg_temp.cred(pg_temp.org(), 'eventbrite') -> 'config' ->> 'auth_method' = 'oauth', 'CC3: an Eventbrite reconnect updates it';
  ASSERT pg_temp.cred(pg_temp.org(), 'ads_meta') IS NULL, 'CC3: a cleared ad token drops the copy';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_integrations WHERE org_id = pg_temp.org() AND provider = 'ads_meta'), 'CC3: no ads row';
END $$;
SET LOCAL ROLE service_role;
SELECT public.exos_dice_disconnect(pg_temp.org(), pg_temp.u('a1'));
SELECT public.exos_eventbrite_disconnect(pg_temp.org(), pg_temp.u('a1'));
RESET ROLE;
DO $$
BEGIN
  ASSERT pg_temp.cred(pg_temp.org(), 'dice') IS NULL, 'CC3: a DICE disconnect drops the copy';
  ASSERT pg_temp.cred(pg_temp.org(), 'eventbrite') IS NULL, 'CC3: an Eventbrite disconnect drops the copy';
  ASSERT NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name IN ('exos_integration:' || pg_temp.org() || ':dice',
                                                                'exos_integration:' || pg_temp.org() || ':eventbrite')),
         'CC3: their Vault copies went too';
  ASSERT pg_temp.cred(pg_temp.org(2), 'discord') IS NULL, 'CC3: another org reads nothing of this one';
  RAISE NOTICE 'OK  CC3 connects copy into the store, reconnects update it, disconnects drop it; old reads unchanged';
END $$;

-- CC4 ------------------------------------------------------------------------
-- Rows from before the migration: written with the copy triggers off.
ALTER TABLE public.exos_dice_connections DISABLE TRIGGER exos_dice_connections_cred_mirror;
ALTER TABLE public.exos_dice_connections DISABLE TRIGGER exos_dice_connections_cred_mirror_upd;
ALTER TABLE public.exos_org_ad_credentials DISABLE TRIGGER exos_org_ad_credentials_cred_mirror;
SET LOCAL ROLE service_role;
SELECT public.exos_dice_connect(pg_temp.org(2), pg_temp.u('a5'), 'tok_dice_OLD_0123456789abcdef', 'v9', 'Old DICE');
RESET ROLE;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a5');
SET LOCAL ROLE authenticated;
SELECT public.exos_set_ad_credential(pg_temp.org(2), 'tiktok', '{"pixel_code":"ABCDEFGHIJ12"}', 'tiktokOLDtoken99', false, NULL);
RESET ROLE;
ALTER TABLE public.exos_dice_connections ENABLE TRIGGER exos_dice_connections_cred_mirror;
ALTER TABLE public.exos_dice_connections ENABLE TRIGGER exos_dice_connections_cred_mirror_upd;
ALTER TABLE public.exos_org_ad_credentials ENABLE TRIGGER exos_org_ad_credentials_cred_mirror;
DO $$
DECLARE b jsonb;
BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_integrations WHERE org_id = pg_temp.org(2)), 'CC4: nothing copied yet';
  -- Reads fall back to the old tables.
  ASSERT pg_temp.cred(pg_temp.org(2), 'dice') ->> 'source' = 'legacy:exos_dice_connections'
         AND pg_temp.cred(pg_temp.org(2), 'dice') ->> 'secret' = 'tok_dice_OLD_0123456789abcdef', 'CC4: the DICE read falls back';
  ASSERT pg_temp.cred(pg_temp.org(2), 'ads_tiktok') ->> 'source' = 'legacy:exos_org_ad_credentials'
         AND pg_temp.cred(pg_temp.org(2), 'ads_tiktok') ->> 'secret' = 'tiktokOLDtoken99'
         AND NOT (pg_temp.cred(pg_temp.org(2), 'ads_tiktok') ->> 'writes_enabled')::boolean, 'CC4: the ad read falls back';
  b := public._exos_cred_backfill();
  ASSERT (b ->> 'dice:copied')::int >= 1 AND (b ->> 'ads_tiktok:copied')::int >= 1, 'CC4: the backfill copies, got ' || b;
  ASSERT pg_temp.cred(pg_temp.org(2), 'dice') ->> 'source' = 'store'
         AND pg_temp.cred(pg_temp.org(2), 'dice') ->> 'secret' = 'tok_dice_OLD_0123456789abcdef', 'CC4: now from the store';
  ASSERT pg_temp.cred(pg_temp.org(2), 'ads_tiktok') ->> 'secret' = 'tiktokOLDtoken99', 'CC4: the ad token copied';
  b := public._exos_cred_backfill();
  ASSERT (SELECT count(*) FROM vault.secrets WHERE name = 'exos_integration:' || pg_temp.org(2) || ':dice') = 1, 'CC4: re-run: still one copy';
  -- A copy that goes missing falls back again (never a stale "nothing").
  DELETE FROM public.exos_org_integrations WHERE org_id = pg_temp.org(2) AND provider = 'dice';
  ASSERT pg_temp.cred(pg_temp.org(2), 'dice') ->> 'source' = 'legacy:exos_dice_connections', 'CC4: a missing copy falls back';
  -- A disabled store row reads nothing (no fallback past an explicit off).
  UPDATE public.exos_org_integrations SET status = 'disabled' WHERE org_id = pg_temp.org(2) AND provider = 'ads_tiktok';
  ASSERT pg_temp.cred(pg_temp.org(2), 'ads_tiktok') IS NULL, 'CC4: disabled is off';
  RAISE NOTICE 'OK  CC4 the backfill copies the old stores (re-run safe); reads fall back while a copy is missing';
END $$;

-- CC5 ------------------------------------------------------------------------
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
INSERT INTO public.exos_org_secrets (org_id, distribution) VALUES (pg_temp.org(), '{"lystedSellerId":"SELLER-cc1-42","enabled":true}')
  ON CONFLICT (org_id) DO UPDATE SET distribution = EXCLUDED.distribution;
DO $$
BEGIN
  ASSERT (SELECT distribution FROM public.exos_org_secrets WHERE org_id = pg_temp.org()) = '{"in_vault":true,"enabled":true}'::jsonb,
         'CC5: the owner reads back a stub only';
END $$;
UPDATE public.exos_org_secrets SET distribution = '{"in_vault":true,"enabled":false}' WHERE org_id = pg_temp.org();
RESET ROLE;
DO $$
DECLARE c jsonb;
BEGIN
  c := pg_temp.cred(pg_temp.org(), 'lysted');
  ASSERT c ->> 'secret' LIKE '%SELLER-cc1-42%' AND c ->> 'source' = 'store', 'CC5: the value is in Vault, got ' || coalesce(c::text, 'null');
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_secrets WHERE distribution::text LIKE '%SELLER-cc1%'), 'CC5: no plain value left';
  ASSERT (SELECT distribution FROM public.exos_org_secrets WHERE org_id = pg_temp.org()) = '{"in_vault":true,"enabled":false}'::jsonb,
         'CC5: a stub written back is kept as a stub';
END $$;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a1');
SET LOCAL ROLE authenticated;
UPDATE public.exos_org_secrets SET distribution = NULL WHERE org_id = pg_temp.org();
RESET ROLE;
-- A plain value from before the trigger: the backfill moves it.
ALTER TABLE public.exos_org_secrets DISABLE TRIGGER exos_org_secrets_distribution_vault;
INSERT INTO public.exos_org_secrets (org_id, distribution) VALUES (pg_temp.org(2), '{"lystedSellerId":"OLD-SELLER-7"}');
ALTER TABLE public.exos_org_secrets ENABLE TRIGGER exos_org_secrets_distribution_vault;
DO $$
DECLARE b jsonb;
BEGIN
  ASSERT pg_temp.cred(pg_temp.org(), 'lysted') IS NULL, 'CC5: NULL removes it';
  ASSERT pg_temp.cred(pg_temp.org(2), 'lysted') ->> 'source' = 'legacy:exos_org_secrets.distribution', 'CC5: an old plain value is read';
  b := public._exos_cred_backfill();
  ASSERT (b ->> 'lysted:moved')::int = 1, 'CC5: the backfill moves it, got ' || b;
  ASSERT pg_temp.cred(pg_temp.org(2), 'lysted') ->> 'secret' LIKE '%OLD-SELLER-7%'
         AND pg_temp.cred(pg_temp.org(2), 'lysted') ->> 'source' = 'store', 'CC5: into Vault';
  ASSERT (SELECT distribution FROM public.exos_org_secrets WHERE org_id = pg_temp.org(2)) = '{"in_vault":true}'::jsonb, 'CC5: stub left';
  ASSERT (public._exos_cred_backfill() ->> 'lysted:moved')::int = 0, 'CC5: re-run moves nothing';
  RAISE NOTICE 'OK  CC5 distribution goes to Vault; the column keeps a stub';
END $$;

-- CC6 ------------------------------------------------------------------------
SET LOCAL ROLE service_role;
DO $$
DECLARE n int;
BEGIN
  n := public.exos_channel_audit_record(pg_temp.org(), $j$[
    {"channel": "luma", "op": "event.create", "method": "post", "path": "/v1/event/create?api_key=LEAKED&x=1", "live": false,
     "request": {"headers": {"Authorization": "Bearer abcdef123456", "Accept": "json"},
                 "body": {"name": "Show", "client_secret": "cs_live", "nested": [{"token": "t"}, "Bearer zzzzzzzzzz"]}},
     "response": {"stand_in": true}, "status": 200, "ok": true,
     "warnings": [{"rule": "luma_sends", "action": "cap"}]},
    {"channel": "BAD CHANNEL", "op": "x", "method": "GET", "path": "/"},
    {"channel": "pretix", "op": "test_credential", "method": "GET", "path": "/api/v1/organizers/demo/", "live": true, "status": 200, "ok": true},
    {"channel": "lysted", "op": "scrub", "method": "POST", "path": "/v1/eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.sig/x?SECRETBARE&page=2#access_token=FRAG",
     "live": false, "error": "upstream said: Bearer leakyleakyleaky and api_key=LEAK2",
     "warnings": [{"reason": "token=WARNLEAK in a reason", "private_key": "PK-LEAK"}],
     "request": {"body": {"key": "K-LEAK", "private_key": "P-LEAK", "access_key": "A-LEAK", "pass": "PW1", "pwd": "PW2", "jwt": "J-LEAK",
                          "note": "see sk_live_abcdefghijkl and ghp_abcdefghijklmnopqrstuvwxyz0123", "keep": "monkey=1 stays",
                          "targeting": {"zips": [{"key": "US:10001"}, {"key": "2490299"}, {"key": 3847}], "regions": [{"key": "sk_live_abcdefghijklmnop"}]}}}}
  ]$j$::jsonb);
  ASSERT n = 3, 'CC6: three good steps written, the bad one skipped, got ' || n;
  n := public.exos_channel_audit_record(pg_temp.org(2), jsonb_build_array(
    jsonb_build_object('channel', 'luma', 'op', 'event.create', 'method', 'POST', 'path', '/v1/event/create', 'live', false)));
  ASSERT public.exos_channel_audit_record(gen_random_uuid(), '[{"channel":"luma","op":"x","method":"GET","path":"/"}]') = 0,
         'CC6: an unknown org records nothing';
END $$;
RESET ROLE;
DO $$
DECLARE a record;
BEGIN
  SELECT * INTO a FROM public.exos_channel_audit WHERE org_id = pg_temp.org() AND channel = 'luma';
  ASSERT a.method = 'POST' AND NOT a.live AND a.path = '/v1/event/create?api_key=…&x=…', 'CC6: query values dropped, got ' || a.path;
  ASSERT a.request::text NOT LIKE '%abcdef123456%' AND a.request::text NOT LIKE '%cs_live%' AND a.request::text NOT LIKE '%zzzzzzzzzz%'
         AND a.request -> 'body' ->> 'name' = 'Show' AND a.request -> 'headers' ->> 'Accept' = 'json', 'CC6: secrets scrubbed, got ' || a.request;
  ASSERT a.warnings -> 0 ->> 'rule' = 'luma_sends', 'CC6: warnings kept';
  SELECT * INTO a FROM public.exos_channel_audit WHERE org_id = pg_temp.org() AND channel = 'lysted';
  ASSERT a.path = '/v1/[redacted]/x?…&page=…', 'CC6: a JWT path segment, a bare parameter and the fragment dropped, got ' || a.path;
  ASSERT a.error NOT LIKE '%leakyleakyleaky%' AND a.error NOT LIKE '%LEAK2%' AND a.error LIKE 'upstream said:%', 'CC6: error scrubbed, got ' || a.error;
  ASSERT a.warnings::text NOT LIKE '%WARNLEAK%' AND a.warnings::text NOT LIKE '%PK-LEAK%', 'CC6: warnings scrubbed, got ' || a.warnings;
  ASSERT a.request::text !~ '(K-LEAK|P-LEAK|A-LEAK|PW1|PW2|J-LEAK|sk_live_abcdefghijkl|ghp_abcdef)', 'CC6: secret keys and tokens out, got ' || a.request;
  ASSERT a.request #> '{body,targeting,zips}' = '[{"key": "US:10001"}, {"key": "2490299"}, {"key": 3847}]'::jsonb
         AND a.request #>> '{body,targeting,regions,0,key}' = '[redacted]',
         'CC6: a bare "key" keeps a targeting key and drops anything else, got ' || (a.request #> '{body,targeting}');
  ASSERT a.request -> 'body' ->> 'keep' = 'monkey=1 stays', 'CC6: ordinary text kept, got ' || a.request;
  DELETE FROM public.exos_channel_audit WHERE id = a.id;
END $$;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a2');
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_channel_audit) = 2, 'CC6: the manager reads the org''s two';
  ASSERT pg_temp.refused($q$INSERT INTO public.exos_channel_audit (org_id, channel, op, method, path, live) VALUES (pg_temp.org(), 'luma', 'x', 'GET', '/', true)$q$,
         'permission denied'), 'CC6: no client insert';
END $$;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a1');
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_channel_audit) = 2, 'CC6: the owner too'; END $$;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a3');
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_channel_audit) = 0, 'CC6: finance reads none'; END $$;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a4');
DO $$ BEGIN ASSERT (SELECT count(*) FROM public.exos_channel_audit) = 0, 'CC6: a scanner reads none'; END $$;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a5');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_channel_audit) = 1
         AND (SELECT org_id FROM public.exos_channel_audit LIMIT 1) = pg_temp.org(2), 'CC6: the other org reads only its own';
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN
  ASSERT pg_temp.refused($q$SELECT count(*) FROM public.exos_channel_audit$q$, 'permission denied'), 'CC6: anon reads nothing';
  RAISE NOTICE 'OK  CC6 the channel audit: scrubbed on write, owner / manager read their own org, no client writes';
END $$;
RESET ROLE;

-- CC7 ------------------------------------------------------------------------
SET LOCAL ROLE service_role;
DO $$
DECLARE r jsonb; v_week int := 7 * 86400; v_id uuid;
BEGIN
  -- Luma: 15 a week per calendar (the lower bound).
  r := public.exos_channel_usage_reserve(pg_temp.org(), 'luma', 'cal-1', 'sends', 10, v_week, 15, true);
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'live_used')::int = 10 AND (r ->> 'remaining')::int = 5, 'CC7: 10 of 15 spent, got ' || r;
  r := public.exos_channel_usage_reserve(pg_temp.org(), 'luma', 'cal-1', 'sends', 6, v_week, 15, true);
  ASSERT NOT (r ->> 'ok')::boolean AND (r ->> 'live_used')::int = 10 AND (r ->> 'remaining')::int = 5, 'CC7: 6 more refused, got ' || r;
  r := public.exos_channel_usage_reserve(pg_temp.org(), 'luma', 'cal-1', 'sends', 5, v_week, 15, true);
  ASSERT (r ->> 'ok')::boolean AND (r ->> 'remaining')::int = 0, 'CC7: the last 5 fit';
  v_id := (r ->> 'id')::uuid;
  ASSERT public.exos_channel_usage_release(pg_temp.org(), v_id), 'CC7: a refused send gives its reservation back';
  ASSERT NOT public.exos_channel_usage_release(pg_temp.org(2), v_id), 'CC7: only once, and only the org''s own';
  -- Another calendar is another budget.
  r := public.exos_channel_usage_reserve(pg_temp.org(), 'luma', 'cal-2', 'sends', 15, v_week, 15, true);
  ASSERT (r ->> 'ok')::boolean, 'CC7: a second calendar has its own 15';
  -- Planned: counted apart, once per identical request.
  r := public.exos_channel_usage_reserve(pg_temp.org(), 'luma', 'cal-1', 'sends', 4, v_week, 15, false, 'aaaaaaaaaaaaaaaa');
  r := public.exos_channel_usage_reserve(pg_temp.org(), 'luma', 'cal-1', 'sends', 4, v_week, 15, false, 'aaaaaaaaaaaaaaaa');
  ASSERT (r ->> 'planned_used')::int = 4 AND (r ->> 'live_used')::int = 10, 'CC7: a repeated plan counts once, apart from live, got ' || r;
  ASSERT (r ->> 'ok')::boolean, 'CC7: 4 would fit next to 10';
  r := public.exos_channel_usage_reserve(pg_temp.org(), 'luma', 'cal-1', 'sends', 9, v_week, 15, false, 'bbbbbbbbbbbbbbbb');
  ASSERT NOT (r ->> 'ok')::boolean AND (r ->> 'planned_used')::int = 13, 'CC7: 9 more would not fit, still recorded, got ' || r;
  ASSERT pg_temp.refused($q$SELECT public.exos_channel_usage_reserve(pg_temp.org(), 'Luma!', '', 'sends', 1, 0, NULL, true)$q$, 'bad arguments'),
         'CC7: a bad platform refused';
  ASSERT pg_temp.refused($q$SELECT public.exos_channel_usage_reserve(pg_temp.org(), 'luma', '', 'sends', 0, 0, NULL, true)$q$, 'bad arguments'),
         'CC7: n must be positive';
END $$;
RESET ROLE;
-- Rolling windows: move rows back in time (the table owner).
INSERT INTO public.exos_channel_usage (org_id, platform, scope_key, metric, n, live, at) VALUES
  (pg_temp.org(), 'eventbrite', '', 'emails', 100, true, now() - interval '25 hours'),
  (pg_temp.org(), 'eventbrite', '', 'emails', 50, true, now() - interval '2 hours'),
  (pg_temp.org(), 'pretix', '', 'tickets', 300, true, now() - interval '200 days'),
  (pg_temp.org(), 'pretix', '', 'tickets', 120, true, now() - interval '3 days'),
  (pg_temp.org(), 'pretix', '', 'tickets', 999, true, now() - interval '370 days'),
  (pg_temp.org(), 'luma', 'cal-1', 'sends', 15, true, now() - interval '8 days');
SET LOCAL ROLE service_role;
DO $$
DECLARE r jsonb;
BEGIN
  ASSERT (public.exos_channel_usage_read(pg_temp.org(), 'eventbrite', '', 'emails', 86400) ->> 'live')::int = 50, 'CC7: the last day';
  ASSERT (public.exos_channel_usage_read(pg_temp.org(), 'eventbrite', '', 'emails', 7 * 86400) ->> 'live')::int = 150, 'CC7: the last week';
  ASSERT (public.exos_channel_usage_read(pg_temp.org(), 'pretix', '', 'tickets', 365 * 86400) ->> 'live')::int = 420, 'CC7: the last year';
  ASSERT (public.exos_channel_usage_read(pg_temp.org(), 'pretix', '', 'tickets', 0) ->> 'live')::int = 1419, 'CC7: all time';
  ASSERT (public.exos_channel_usage_read(pg_temp.org(), 'luma', 'cal-1', 'sends', 7 * 86400) ->> 'live')::int = 10,
         'CC7: last week''s sends no longer count';
  r := public.exos_channel_usage_reserve(pg_temp.org(), 'pretix', '', 'tickets', 81, 365 * 86400, 500, true);
  ASSERT NOT (r ->> 'ok')::boolean, 'CC7: 420 + 81 > 500 in the rolling year';
  ASSERT (public.exos_channel_usage_read(pg_temp.org(2), 'luma', 'cal-1', 'sends', 0) ->> 'live')::int = 0, 'CC7: per org';
END $$;
RESET ROLE;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a2');
SET LOCAL ROLE authenticated;
DO $$
DECLARE s jsonb; x jsonb;
BEGIN
  s := public.exos_channel_usage_summary(pg_temp.org());
  SELECT e INTO x FROM jsonb_array_elements(s) e WHERE e ->> 'platform' = 'luma' AND e ->> 'scope_key' = 'cal-1';
  ASSERT (x ->> 'live_week')::int = 10 AND (x ->> 'planned_week')::int = 13 AND (x ->> 'live_year')::int = 25,
         'CC7: the summary splits live and planned, got ' || x;
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s) e WHERE (e ->> 'live_year')::int >= 999), 'CC7: older than a year left out';
END $$;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a3');
DO $$ BEGIN
  ASSERT pg_temp.refused($q$SELECT public.exos_channel_usage_summary(pg_temp.org())$q$, 'owner or manager only'), 'CC7: finance refused';
END $$;
SELECT pg_temp.act('cc100000-0000-0000-0000-0000000000a5');
DO $$ BEGIN
  ASSERT pg_temp.refused($q$SELECT public.exos_channel_usage_summary(pg_temp.org())$q$, 'owner or manager only'), 'CC7: another org refused';
  RAISE NOTICE 'OK  CC7 usage: live spends under the limit, planned apart and deduped, rolling windows, summary roles';
END $$;
RESET ROLE;
-- CC8 ------------------------------------------------------------------------
-- (a) the exos_org_secrets row deleted: the Lysted copy goes with it.
INSERT INTO public.exos_org_secrets (org_id, distribution) VALUES (pg_temp.org(), '{"lystedSellerId":"SELLER-cc8-a"}')
  ON CONFLICT (org_id) DO UPDATE SET distribution = EXCLUDED.distribution;
DO $$ BEGIN
  ASSERT pg_temp.cred(pg_temp.org(), 'lysted') ->> 'secret' LIKE '%SELLER-cc8-a%', 'CC8: stored';
END $$;
DELETE FROM public.exos_org_secrets WHERE org_id = pg_temp.org();
DO $$ BEGIN
  ASSERT pg_temp.cred(pg_temp.org(), 'lysted') IS NULL, 'CC8: a deleted secrets row leaves no Lysted credential';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_integrations WHERE org_id = pg_temp.org() AND provider = 'lysted'), 'CC8: no store row';
  ASSERT NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'exos_integration:' || pg_temp.org() || ':lysted'), 'CC8: no Vault copy';
  ASSERT NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE decrypted_secret LIKE '%SELLER-cc8-a%'), 'CC8: the value is gone';
END $$;
-- (b) an org delete: a managed copy (DICE), a plain Integrations secret and the Lysted value.
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('cc100000-0000-0000-0000-000000000003','Gone Org','gone-org-cc8','cc100000-0000-0000-0000-0000000000a5');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('cc100000-0000-0000-0000-000000000003','cc100000-0000-0000-0000-0000000000a5','owner');
SET LOCAL ROLE service_role;
SELECT public.exos_dice_connect(pg_temp.org(3), pg_temp.u('a5'), 'tok_dice_cc8_gone_0123456789', 'v8', 'Gone Promotions');
RESET ROLE;
SELECT public._exos_integration_put(pg_temp.org(3), 'pretix', 'PRETIX-cc8-gone-token', '{}'::jsonb, NULL, 'unverified');
INSERT INTO public.exos_org_secrets (org_id, distribution) VALUES (pg_temp.org(3), '{"lystedSellerId":"SELLER-cc8-b"}');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM public.exos_org_integrations WHERE org_id = pg_temp.org(3)) = 3, 'CC8: three store rows';
  ASSERT (SELECT count(*) FROM vault.secrets WHERE name LIKE 'exos_integration:' || pg_temp.org(3) || ':%') = 3, 'CC8: three Vault copies';
END $$;
DELETE FROM public.exos_orgs WHERE id = pg_temp.org(3);
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_org_integrations WHERE org_id = pg_temp.org(3)), 'CC8: no store row left';
  ASSERT NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name LIKE 'exos_integration:' || pg_temp.org(3) || ':%'), 'CC8: no Vault copy left';
  ASSERT NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets
                      WHERE decrypted_secret LIKE '%PRETIX-cc8-gone%' OR decrypted_secret LIKE '%SELLER-cc8-b%'), 'CC8: the values are gone';
  ASSERT pg_temp.cred(pg_temp.org(3), 'pretix') IS NULL AND pg_temp.cred(pg_temp.org(3), 'lysted') IS NULL, 'CC8: nothing to read';
END $$;
-- The retention sweep: every org's old rows, not only the writer's.
INSERT INTO public.exos_channel_audit (org_id, channel, op, method, path, live, at)
  VALUES (pg_temp.org(2), 'luma', 'old', 'GET', '/', true, now() - interval '31 days'),
         (pg_temp.org(2), 'luma', 'recent', 'GET', '/', true, now() - interval '29 days');
SET LOCAL ROLE service_role;
DO $$
DECLARE r jsonb;
BEGIN
  -- A write by ANOTHER org trims org 2's expired row.
  PERFORM public.exos_channel_audit_record(pg_temp.org(), '[{"channel":"luma","op":"x","method":"GET","path":"/"}]');
  RESET ROLE;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_channel_audit WHERE op = 'old'), 'CC8: any write trims every org''s expired rows';
  ASSERT EXISTS (SELECT 1 FROM public.exos_channel_audit WHERE op = 'recent'), 'CC8: 29 days kept';
  INSERT INTO public.exos_channel_audit (org_id, channel, op, method, path, live, at)
    VALUES (pg_temp.org(2), 'luma', 'old2', 'GET', '/', true, now() - interval '40 days');
  SET LOCAL ROLE service_role;
  r := public.exos_channel_retention_sweep();
  RESET ROLE;
  ASSERT (r ->> 'audit')::int = 1 AND NOT EXISTS (SELECT 1 FROM public.exos_channel_audit WHERE op = 'old2'), 'CC8: the sweep, got ' || r;
END $$;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  ASSERT pg_temp.refused($q$SELECT public.exos_channel_retention_sweep()$q$, 'permission denied'), 'CC8: no client sweep';
  RAISE NOTICE 'OK  CC8 no credential outlives its row (secrets row, org delete); retention covers every org';
END $$;
RESET ROLE;

ROLLBACK;

-- CC7b: REPEATABLE READ is refused (its snapshot sum would let parallel
-- reserves overshoot). Its own transaction: the level is set at BEGIN.
BEGIN ISOLATION LEVEL REPEATABLE READ;
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_channel_usage_reserve(gen_random_uuid(), 'luma', 'cal-rr', 'sends', 1, 60, 15, true);
    RAISE EXCEPTION 'CC7b: a REPEATABLE READ reserve went through';
  EXCEPTION WHEN feature_not_supported THEN
    ASSERT SQLERRM LIKE '%needs READ COMMITTED%', 'CC7b: ' || SQLERRM;
  END;
  RAISE NOTICE 'OK  CC7b usage reserve refuses REPEATABLE READ';
END $$;
ROLLBACK;
