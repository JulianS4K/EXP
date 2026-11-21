#!/usr/bin/env bash
# Concurrency check for exos_api_write's Idempotency-Key claim (mig
# 20261119130000: the claim takes no conflict target, so a twin on either
# unique index, the key's (api_key_id, idempotency_key) or the credential's,
# waits and replays). Before that fix 58 of 200 same-key pairs on the key path
# failed with 23505. Run against a DB built by run_p0.sh (CI does):
#   bash tests/exos/race_idem.sh exos_p0_test
# Expect: for each pair, one event, both answers the same id, no error; on
# the key path and on the personal-token path.
set -euo pipefail
DB="${1:-exos_p0_test}"
H="${PGHOST:-/tmp/pgrun}"; PORT="${PGPORT:-5433}"; U="${PGUSER:-postgres}"
P="psql -h $H -p $PORT -U $U -d $DB -v ON_ERROR_STOP=1 -qAt"
PAIRS="${PAIRS:-100}"
O=1d000000-0000-0000-0000-000000000001; A=1d000000-0000-0000-0000-0000000000a1
K=1d000000-0000-0000-0000-0000000000f1; T=1d000000-0000-0000-0000-0000000000c1
OUT="$(mktemp -d)"
cleanup() {
  $P -c "DELETE FROM exos_api_writes WHERE org_id='$O'; DELETE FROM exos_ticket_tiers WHERE event_id IN (SELECT id FROM exos_events WHERE org_id='$O');
         DELETE FROM exos_events WHERE org_id='$O'; DELETE FROM exos_personal_tokens WHERE org_id='$O';
         DELETE FROM exos_api_keys WHERE org_id='$O'; DELETE FROM exos_org_memberships WHERE org_id='$O';
         DELETE FROM exos_orgs WHERE id='$O'; DELETE FROM auth.users WHERE id='$A';" >/dev/null
  rm -rf "$OUT"
}
cleanup || true
OUT="$(mktemp -d)"
trap cleanup EXIT
$P -c "CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS \$\$
         SELECT coalesce(nullif(current_setting('app.uid', true), ''),
                         nullif(current_setting('request.jwt.claim.sub', true), ''),
                         nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid \$\$;" >/dev/null
$P -c "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES ('$A','race-idem@x.com',now());
       INSERT INTO exos_orgs(id,name,slug,owner_uid) VALUES ('$O','Race idem','race-idem','$A');
       INSERT INTO exos_org_memberships(org_id,user_id,role) VALUES ('$O','$A','owner');
       INSERT INTO exos_api_keys(id,org_id,name,key_prefix,key_hash,scopes,created_by)
         VALUES ('$K','$O','race','sk_live_raceid','raceidemhash',ARRAY['events:write'],'$A');
       INSERT INTO exos_personal_tokens(id,user_id,org_id,name,key_prefix,key_hash,scopes)
         VALUES ('$T','$A','$O','race','exos_pat_rid',encode(sha256('exos_pat_race_idem'::bytea),'hex'),ARRAY['events:write']);" >/dev/null

# One write: path (key / pat), pair number, twin.
one() {
  local path="$1" i="$2" twin="$3" call
  if [ "$path" = key ]; then
    call="exos_api_write('$K','event.create',NULL,'{\"event\":{\"name\":\"race-idem-$path-$i\"}}','race-idem-$path-$i')"
  else
    call="exos_api_write(NULL,'event.create',NULL,'{\"event\":{\"name\":\"race-idem-$path-$i\"}}','race-idem-$path-$i',
                         encode(sha256('exos_pat_race_idem'::bytea),'hex'),'pat')"
  fi
  # Both twins wait for the same instant, then write.
  $P -c "SELECT pg_sleep_until('$START')" -c "SELECT $call ->> 'id'" > "$OUT/$path-$i-$twin" 2>&1 || echo "FAILED" >> "$OUT/$path-$i-$twin"
}
fail=0
START=
for path in key pat; do
  # 20 pairs (40 sessions) at a time, under max_connections; each batch starts together.
  for i in $(seq 1 "$PAIRS"); do
    if [ $(((i - 1) % 20)) -eq 0 ]; then START=$($P -c "SELECT (clock_timestamp() + interval '1.5 seconds')::text"); fi
    one "$path" "$i" a & one "$path" "$i" b &
    if [ $((i % 20)) -eq 0 ]; then wait; fi
  done
  wait
  for i in $(seq 1 "$PAIRS"); do
    a=$(cat "$OUT/$path-$i-a"); b=$(cat "$OUT/$path-$i-b")
    if [ "$a" != "$b" ] || grep -q "ERROR\|FAILED" "$OUT/$path-$i-a" "$OUT/$path-$i-b"; then
      echo "  $path pair $i: '$a' vs '$b'"; fail=$((fail + 1))
    fi
  done
  n=$($P -c "SELECT count(*) FROM exos_events WHERE org_id='$O' AND name LIKE 'race-idem-$path-%'")
  echo "  -> $path: $n events for $PAIRS pairs (want $PAIRS)"
  [ "$n" = "$PAIRS" ] || fail=$((fail + 1))
done
if [ "$fail" -ne 0 ]; then echo "race_idem: FAILED ($fail)"; exit 1; fi
echo "race_idem: ok"
