#!/usr/bin/env bash
# Token lineage races (mig 20261105160000): a mint through /v1/me and a revoke
# of the token making it, in real parallel sessions. Timing-based, so run by
# hand against a DB built by run_p0.sh:
#   bash tests/exos/race_token_lineage.sh exos_p0_test
# Expect:
#   race 1 the revoke is in flight (uncommitted) when the mint starts: the mint
#          waits on the parent's row, then sees it revoked and is refused
#          (invalid or revoked token); no live child
#   race 2 the mint is in flight when the revoke starts: the revoke waits for
#          the mint to commit, then its cascade revokes the new child
#          (revoked_reason parent); no live child
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
O=e7d00000-0000-0000-0000-000000000001; A=e7d00000-0000-0000-0000-0000000000a1
TOK=e7d00000-0000-0000-0000-00000000f001
SECRET=race-token-lineage-parent-secret-0001
cleanup() {
  $P -c "DELETE FROM exos_personal_tokens WHERE user_id='$A'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id='$A';" >/dev/null
}
cleanup
trap cleanup EXIT
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','owner@race-tl.test',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race TL','race-tl','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');" >/dev/null
HASH=$($P -c "SELECT encode(extensions.digest('$SECRET','sha256'),'hex')")
fresh_parent() {
  $P -c "DELETE FROM exos_personal_tokens WHERE user_id='$A';
         INSERT INTO exos_personal_tokens(id,user_id,org_id,name,key_prefix,key_hash,scopes,expires_at)
           VALUES ('$TOK','$A','$O','race parent','exos_pat_race','$HASH',ARRAY['me:read','me:write'],now() + interval '30 days');" >/dev/null
}
MINT="SELECT set_config('app.uid','$A',false);
      SELECT public.exos_api_me('$HASH','pat','token.create',NULL,'{\"scopes\":[\"me:read\"],\"expires_days\":30}'::jsonb);"
live_children() { $P -c "SELECT count(*) FROM exos_personal_tokens WHERE parent_token_id='$TOK' AND revoked_at IS NULL"; }
fail=0

# race 1: revoke first, held open; the mint starts while it is uncommitted.
fresh_parent
$P -c "BEGIN; UPDATE exos_personal_tokens SET revoked_at=now(), revoked_reason='user' WHERE id='$TOK';
       SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
out=$($P -c "$MINT" 2>&1 || true)
wait
if [[ "$out" == *"invalid or revoked token"* && "$(live_children)" == 0 ]]; then
  echo "OK   race 1 mint during an uncommitted revoke: refused, no live child"
else
  echo "FAIL race 1: $out / live children $(live_children)"; fail=1
fi

# race 2: mint first, held open; the revoke starts while it is uncommitted.
fresh_parent
$P -c "BEGIN; SELECT set_config('app.uid','$A',false);
       SELECT public.exos_api_me('$HASH','pat','token.create',NULL,'{\"scopes\":[\"me:read\"],\"expires_days\":30}'::jsonb);
       SELECT pg_sleep(2); COMMIT;" >/dev/null &
sleep 0.5
$P -c "UPDATE exos_personal_tokens SET revoked_at=now(), revoked_reason='user' WHERE id='$TOK'" >/dev/null
wait
cascaded=$($P -c "SELECT count(*) FROM exos_personal_tokens WHERE parent_token_id='$TOK' AND revoked_reason='parent'")
if [[ "$(live_children)" == 0 && "$cascaded" == 1 ]]; then
  echo "OK   race 2 revoke during an uncommitted mint: waits, cascade revokes the child"
else
  echo "FAIL race 2: live children $(live_children), cascaded $cascaded"; fail=1
fi
exit $fail
