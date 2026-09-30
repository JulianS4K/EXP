-- Supabase Vault stub for the SQL harness (prod: the supabase_vault
-- extension, which the shared project has installed; _cron_invoke_edge_fn
-- reads CRON_SECRET from it). Same names and signatures the migrations call:
--   vault.create_secret(new_secret, new_name, new_description, new_key_id) -> uuid
--   vault.update_secret(secret_id, new_secret, new_name, new_description, new_key_id)
--   vault.secrets (table), vault.decrypted_secrets (view, decrypted_secret)
-- The stub stores the secret in plain text; only what the grants allow is
-- under test (no client role may touch the schema), not the encryption.
-- Re-run safe.
CREATE SCHEMA IF NOT EXISTS vault;
CREATE TABLE IF NOT EXISTS vault.secrets (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text UNIQUE,
  description text NOT NULL DEFAULT '',
  secret      text NOT NULL,
  key_id      uuid,
  nonce       bytea,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE VIEW vault.decrypted_secrets AS
  SELECT id, name, description, secret, secret AS decrypted_secret, key_id, nonce, created_at, updated_at
    FROM vault.secrets;

CREATE OR REPLACE FUNCTION vault.create_secret(
  new_secret text, new_name text DEFAULT NULL, new_description text DEFAULT '', new_key_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO vault.secrets (secret, name, description, key_id)
  VALUES (new_secret, new_name, coalesce(new_description, ''), new_key_id)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION vault.update_secret(
  secret_id uuid, new_secret text DEFAULT NULL, new_name text DEFAULT NULL,
  new_description text DEFAULT NULL, new_key_id uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  UPDATE vault.secrets
     SET secret = coalesce(new_secret, secret), name = coalesce(new_name, name),
         description = coalesce(new_description, description), key_id = coalesce(new_key_id, key_id),
         updated_at = now()
   WHERE id = secret_id;
END $$;

REVOKE ALL ON SCHEMA vault FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA vault FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA vault FROM PUBLIC, anon, authenticated;
