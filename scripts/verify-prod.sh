#!/usr/bin/env bash
# Read-only check of Exos prod after scripts/rollout-prod.sh.
#
#   DB_URL='postgresql://postgres.<ref>:<password>@<pooler-host>:5432/postgres' \
#   SUPABASE_URL='https://<ref>.supabase.co' SUPABASE_ANON_KEY='eyJ…' \
#   bash scripts/verify-prod.sh [db|http|all]          # default: all
#
# db   needs DB_URL (same "Session pooler" string as rollout-prod.sh), or, on a
#      host that can't reach Postgres on 5432, SUPABASE_ACCESS_TOKEN alone: the
#      queries then go through the Management API over HTTPS (needs jq), still
#      read-only (see q / q_anon below).
# http needs SUPABASE_URL and SUPABASE_ANON_KEY (the public anon key).
#
# It only reads. Every SQL statement runs in a session with
# default_transaction_read_only=on (Postgres refuses any write) and a 30s
# statement_timeout. HTTP is OPTIONS (every function answers it before reading
# a body or touching the database) plus three GETs to exos-api with no API key,
# which it refuses with 401 before doing anything. No request carries a body.
#
# Checks (the table at the end is sorted by these numbers):
#   1 migrations  every MIGRATIONS entry in rollout-prod.sh, plus
#                 20261027090000_exos_api_scopes, is in
#                 supabase_migrations.schema_migrations by name; any other
#                 repo *exos* migration from 20261027 on that isn't recorded
#   2 objects     each of those migrations' CREATE TABLE / FUNCTION / VIEW
#                 objects exists (unless a later migration drops or renames it)
#   3 grants      anon can execute only the H3 allowlist's definer functions
#                 (parsed from tests/exos/test_rpc_hardening.sql); no exos
#                 table/view grants anon INSERT/UPDATE/DELETE; no exos sequence
#                 anon can use, read or update; RLS on for every exos_* table
#   4 crons       exos% jobs: active, last run; FAIL an active job whose last
#                 run failed, or one calling an edge function that answered 404
#                 (the cross-check needs `all`)
#   5 functions   each supabase/functions/* (not _shared): deployed and
#                 answering / 404 not deployed / 5xx boot error
#   6 smoke       exos_api_scope_names() matches _shared/api/scopes.ts; row
#                 counts of public views read as anon; exos-api GET /v1,
#                 /v1/me, /v1/events answer 401 without a key (no health route)
#   7 settings    exos_platform_settings rows for the keys the new code reads
#                 (missing = WARN, the default applies)
#
# Sections whose schema isn't there (no supabase_migrations, no cron: a local
# harness DB) are SKIPped, not failed. Exit 0 when nothing FAILed, 1 otherwise,
# 2 on bad usage.
set -uo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-all}"
case "$MODE" in db|http|all) ;; *) echo "usage: $0 [db|http|all]" >&2; exit 2 ;; esac

MIG=supabase/migrations
FUNCS=supabase/functions
SINCE=20261027000000
EXTRA_REQUIRED=(20261027090000_exos_api_scopes)
# Defaults for settings read straight from the table (not via a _setting_* call
# the scan below can read the default from).
STATIC_SETTINGS="free_tier_max_capacity=150
group_chat_retention_days=30
request_ip_source=cloudflare"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/verify-prod.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
RES="$TMP/results.tsv"; : >"$RES"
HTTP="$TMP/http.tsv";   : >"$HTTP"     # function<TAB>verdict(deployed|missing|boot|down)<TAB>code
SEP=$'\x1f'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
# add STATUS SECTION CHECK DETAIL
add() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(printf '%s' "$4" | tr '\t\n' '  ')" >>"$RES"; }
say() { printf '%s\n' "$*" >&2; }

REF=hzrizjeaxlqcxfrtczpq
API="https://api.supabase.com/v1/projects/$REF/database/query"

# api_q SQL [PRELUDE]: Management API fallback when DB_URL is unset. Runs SQL in
# BEGIN READ ONLY; [PRELUDE] ... ROLLBACK and prints the rows of the last
# statement that returns rows, like psql -At -F "$SEP" (booleans t/f, NULL
# empty). Errors go to $TMP/psql.err, as psql's do.
# Rows come back as JSON objects, so two output columns with the same name
# collapse into one: give every column of a multi-column query its own alias.
api_q() {
  local out code
  out=$(jq -n --arg q "begin read only; set local statement_timeout = '30s'; ${2:-}
$1
; rollback;" '{query: $q}' \
        | curl -sS -X POST "$API" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
            -H "Content-Type: application/json" --data-binary @- -w $'\n%{http_code}' 2>"$TMP/psql.err")
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  if [[ "$code" != 2* ]]; then
    printf 'Management API HTTP %s: %s\n' "$code" "$(printf '%s' "$out" | jq -r '.message? // .' 2>/dev/null || printf '%s' "$out")" >>"$TMP/psql.err"
    return 1
  fi
  printf '%s' "$out" | jq -r --arg sep "$SEP" '.[] | [.[] |
      if . == null then "" elif . == true then "t" elif . == false then "f"
      elif type == "string" then . else tojson end] | join($sep)'
}

# q SQL: one read-only session, unaligned, field separator 0x1f.
# Without DB_URL: the API's default role inside BEGIN READ ONLY ... ROLLBACK, so
# Postgres refuses any write. (The API's read_only mode would use a role that
# can't execute the exos functions the smoke checks call.)
q() {
  if [ -z "${DB_URL:-}" ]; then api_q "$1"; return; fi
  psql "$DB_URL" -X -q -At -F "$SEP" -v ON_ERROR_STOP=1 \
    -c "set default_transaction_read_only = on" -c "set statement_timeout = '30s'" \
    -c "$1" 2>"$TMP/psql.err"
}
# q_anon SQL: the same, inside a read-only transaction as role anon.
# Without DB_URL: as q, plus SET LOCAL ROLE anon inside the transaction.
q_anon() {
  if [ -z "${DB_URL:-}" ]; then api_q "$1" "set local role anon;"; return; fi
  psql "$DB_URL" -X -q -At -F "$SEP" -v ON_ERROR_STOP=1 \
    -c "set default_transaction_read_only = on" -c "set statement_timeout = '30s'" \
    -c "begin read only" -c "set local role anon" -c "$1" -c "commit" 2>"$TMP/psql.err"
}
pgerr() { tr '\n' ' ' <"$TMP/psql.err" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-300; }
sql_lit() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
has_rel() { [ "$(q "select to_regclass($(sql_lit "$1")) is not null")" = t ]; }
join_csv() { paste -sd, - | sed 's/,/, /g'; }

# MIGRATIONS=( … ) from rollout-prod.sh, comments stripped.
rollout_migrations() {
  awk '/^MIGRATIONS=\(/{on=1; next} on && /^\)/{exit} on{sub(/#.*/, ""); if ($1 != "") print $1}' scripts/rollout-prod.sh
}
required_migrations() { { rollout_migrations; printf '%s\n' "${EXTRA_REQUIRED[@]}"; } | awk '!seen[$0]++'; }

# The H3 allowlist: the quoted names inside H3's `p.proname NOT IN ( … );`.
h3_allowlist() {
  awk '/^-- H3 /{h3=1} h3 && /proname NOT IN \(/{on=1} on{sub(/--.*/, ""); print} on && /\);/{exit}' \
      tests/exos/test_rpc_hardening.sql | grep -oE "'[a-z0-9_]+'" | tr -d "'" | sort -u
}

# Normalized SQL text of a migration: comments dropped, one line, lower case.
flat_sql() { sed -e 's/--.*$//' "$1" | tr '\n\t' '  ' | tr 'A-Z' 'a-z'; }

# CREATE / DROP / RENAME events of every exos migration in version order:
#   version<TAB>op<TAB>kind<TAB>schema.name
object_events() {
  local f v
  for f in "$MIG"/*exos*.sql; do
    v=$(basename "$f"); v=${v%%_*}
    flat_sql "$f" | grep -oE \
'create[[:space:]]+(or[[:space:]]+replace[[:space:]]+)?((unlogged|materialized)[[:space:]]+)?(table|function|view)[[:space:]]+(if[[:space:]]+not[[:space:]]+exists[[:space:]]+)?[a-z0-9_."]+|drop[[:space:]]+(table|function|view|materialized[[:space:]]+view)[[:space:]]+(if[[:space:]]+exists[[:space:]]+)?[a-z0-9_."]+|alter[[:space:]]+(table|view|function)[[:space:]]+(if[[:space:]]+exists[[:space:]]+)?[a-z0-9_."]+[[:space:]]+rename[[:space:]]+to' \
    | awk -v v="$v" '{
        op = $1; kind = ""; name = "";
        for (i = 2; i <= NF; i++) if ($i == "table" || $i == "function" || $i == "view") { kind = $i; break }
        if (op == "alter") { op = "drop"; name = $(i + 1); if (name == "if") name = $(i + 3) }
        else name = $NF;
        gsub(/"/, "", name);
        if (name !~ /\./) name = "public." name;
        if (name ~ /^pg_temp\./) next;
        print v "\t" op "\t" kind "\t" name }'
  done
}

# ---------------------------------------------------------------------------
# 5 functions (http): run before the DB sections so 4 crons can use it
# ---------------------------------------------------------------------------
function_names() { for d in "$FUNCS"/*/; do n=$(basename "$d"); [ "$n" = _shared ] || echo "$n"; done; }

# probe METHOD URL [auth]: prints "code<TAB>curl_exit"; body in $TMP/body.
probe() {
  local method=$1 url=$2 auth=${3:-} code rc
  local args=(-sS -o "$TMP/body" -w '%{http_code}' --connect-timeout 8 --max-time 20 -X "$method"
              -H "apikey: $SUPABASE_ANON_KEY" -H "Origin: https://verify-prod.invalid")
  [ "$method" = OPTIONS ] && args+=(-H "Access-Control-Request-Method: GET")
  [ -n "$auth" ] && args+=(-H "Authorization: Bearer $SUPABASE_ANON_KEY")
  : >"$TMP/body"
  code=$(curl "${args[@]}" "$url" 2>"$TMP/curl.err"); rc=$?
  printf '%s\t%s\n' "${code:-000}" "$rc"
}
body() { tr '\n' ' ' <"$TMP/body" | cut -c1-160; }

http_checks() {
  if [ -z "${SUPABASE_URL:-}" ] || [ -z "${SUPABASE_ANON_KEY:-}" ]; then
    add FAIL "5 functions" "config" "set SUPABASE_URL and SUPABASE_ANON_KEY for the HTTP checks"
    return
  fi
  local base="${SUPABASE_URL%/}/functions/v1" n code rc b
  say "http: probing $base"
  IFS=$'\t' read -r code rc < <(probe OPTIONS "$base/exos-api" auth)
  if [ "$rc" != 0 ] || [ "$code" = 000 ]; then
    add FAIL "5 functions" "reachability" "no HTTP answer from $base (curl exit $rc: $(tr '\n' ' ' <"$TMP/curl.err" | cut -c1-200)); function and exos-api checks skipped"
    for n in $(function_names); do printf '%s\tdown\t000\n' "$n" >>"$HTTP"; done
    add SKIP "6 smoke" "exos-api GET /v1 without a key" "SUPABASE_URL unreachable"
    return
  fi
  for n in $(function_names); do
    IFS=$'\t' read -r code rc < <(probe OPTIONS "$base/$n" auth)
    b=$(body)
    if [ "$rc" != 0 ] || [ "$code" = 000 ]; then
      add FAIL "5 functions" "$n" "no answer (curl exit $rc: $(tr '\n' ' ' <"$TMP/curl.err" | cut -c1-160))"
      printf '%s\tdown\t000\n' "$n" >>"$HTTP"
    elif [ "$code" = 404 ] && printf '%s' "$b" | grep -qiE 'NOT_FOUND|function was not found'; then
      add FAIL "5 functions" "$n" "404 not deployed: $b"
      printf '%s\tmissing\t%s\n' "$n" "$code" >>"$HTTP"
    elif [ "$code" -ge 500 ] 2>/dev/null; then
      if [ "$code" = 546 ] || printf '%s' "$b" | grep -qiE 'BOOT_ERROR|WORKER_ERROR|WORKER_LIMIT|failed to (boot|start)|InvalidWorker'; then
        add FAIL "5 functions" "$n" "$code boot error: $b"
        printf '%s\tboot\t%s\n' "$n" "$code" >>"$HTTP"
      elif printf '%s' "$b" | grep -qiE 'not configured|misconfigured|unset|switched off|unavailable'; then
        add WARN "5 functions" "$n" "$code deployed, not configured: $b"
        printf '%s\tdeployed\t%s\n' "$n" "$code" >>"$HTTP"
      else
        add FAIL "5 functions" "$n" "$code server error: $b"
        printf '%s\tboot\t%s\n' "$n" "$code" >>"$HTTP"
      fi
    else
      add PASS "5 functions" "$n" "deployed, OPTIONS -> $code"
      printf '%s\tdeployed\t%s\n' "$n" "$code" >>"$HTTP"
    fi
  done

  # 6 smoke: exos-api has no health/index route; without a bearer key every
  # /v1 path is refused with 401 before any database call.
  local p
  for p in /v1 /v1/me /v1/events; do
    IFS=$'\t' read -r code rc < <(probe GET "$base/exos-api$p")
    b=$(body)
    if [ "$code" = 401 ]; then
      add PASS "6 smoke" "exos-api GET $p (no key)" "401 $b"
    elif [ "$rc" != 0 ] || [ "$code" = 000 ]; then
      add FAIL "6 smoke" "exos-api GET $p (no key)" "no answer (curl exit $rc)"
    else
      add FAIL "6 smoke" "exos-api GET $p (no key)" "expected 401, got $code: $b"
    fi
  done
}

# ---------------------------------------------------------------------------
# DB sections
# ---------------------------------------------------------------------------
db_checks() {
  if [ -z "${DB_URL:-}" ] && [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
    add FAIL "1 migrations" "config" "set DB_URL (or SUPABASE_ACCESS_TOKEN for the Management API) for the database checks"; return
  fi
  [ -n "${DB_URL:-}" ] || say "db: no DB_URL, querying through the Management API ($API)"
  if [ "$(q 'select 1')" != 1 ]; then
    add FAIL "1 migrations" "connect" "can't run a query: $(pgerr)"; return
  fi
  local required; required=$(required_migrations)
  say "db: connected ($(q "select current_database()||' as '||current_user"))"

  # 1 migrations ------------------------------------------------------------
  if has_rel supabase_migrations.schema_migrations; then
    q "select name from supabase_migrations.schema_migrations where name is not null" >"$TMP/recorded"
    local m missing_extra=""
    while read -r m; do
      if grep -qxF -e "$m" -e "${m#*_}" "$TMP/recorded"; then
        add PASS "1 migrations" "$m" "recorded"
      else
        add FAIL "1 migrations" "$m" "not in supabase_migrations.schema_migrations (by name)"
      fi
    done <<<"$required"
    local f v
    for f in "$MIG"/*exos*.sql; do
      m=$(basename "$f" .sql); v=${m%%_*}
      [[ "$v" =~ ^[0-9]{14}$ ]] && [ "$v" -ge "$SINCE" ] || continue
      grep -qxF "$m" <<<"$required" && continue
      grep -qxF -e "$m" -e "${m#*_}" "$TMP/recorded" || missing_extra="$missing_extra $m"
    done
    if [ -z "$missing_extra" ]; then
      add PASS "1 migrations" "other *exos* since ${SINCE:0:8}" "every repo migration from ${SINCE:0:8} on is recorded"
    else
      add WARN "1 migrations" "other *exos* since ${SINCE:0:8}" "in the repo, not recorded, not in rollout-prod.sh:$missing_extra"
    fi
  else
    add SKIP "1 migrations" "schema_migrations" "no supabase_migrations.schema_migrations here (local harness DB?)"
  fi

  # 2 objects ---------------------------------------------------------------
  object_events >"$TMP/events"
  # Final state per name across all exos migrations, then the objects each
  # required migration creates whose final state is still "created".
  awk -F'\t' '{last[$4] = $2} END {for (n in last) if (last[n] == "drop") print n}' "$TMP/events" | sort >"$TMP/dropped"
  local vers values=""
  vers=$(sed 's/_.*//' <<<"$required")
  awk -F'\t' 'FILENAME == ARGV[1] {want[$1]; next} ($1 in want) && $2 == "create" {print $1 "\t" $3 "\t" $4}' \
      <(printf '%s\n' "$vers") "$TMP/events" | sort -u >"$TMP/created"
  # Names are [a-z0-9_.] only (the grep above), so they need no quoting.
  values=$(awk -F'\t' 'FILENAME == ARGV[1] {gone[$1]; next} !($3 in gone) {
             d = index($3, "."); printf ",(\x27%s\x27,\x27%s\x27,\x27%s\x27,\x27%s\x27)", $1, $2, substr($3, 1, d - 1), substr($3, d + 1) }' \
           "$TMP/dropped" "$TMP/created")
  if [ -z "$values" ]; then
    add WARN "2 objects" "derive" "no CREATE TABLE/FUNCTION/VIEW found in the required migrations"
  else
    if ! q "with o(v, kind, sch, name) as (values ${values#,})
            select v, count(*) as total, count(*) filter (where not ok) as bad,
                   coalesce(string_agg(kind || ' ' || sch || '.' || name, ', ' order by name) filter (where not ok), '') as missing
              from (select o.*, case when kind = 'function'
                                     then exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                                                   where s.nspname = o.sch and p.proname = o.name)
                                     else to_regclass(quote_ident(o.sch) || '.' || quote_ident(o.name)) is not null end ok
                      from o) x
             group by v order by v" >"$TMP/objects"; then
      add FAIL "2 objects" "query" "$(pgerr)"
    else
      local total bad list m
      while IFS="$SEP" read -r v total bad list; do
        m=$(grep -m1 "^$v" <<<"$required")
        if [ "$bad" = 0 ]; then add PASS "2 objects" "$m" "$total/$total tables, functions, views present"
        else add FAIL "2 objects" "$m" "$bad of $total missing: $list"; fi
      done <"$TMP/objects"
      while read -r m; do
        grep -q "^${m%%_*}$SEP" "$TMP/objects" || add INFO "2 objects" "$m" "creates no table, function or view (nothing to check)"
      done <<<"$required"
    fi
  fi

  # 3 grants ----------------------------------------------------------------
  local allow allow_sql extra
  allow=$(h3_allowlist)
  if [ -z "$allow" ]; then
    add FAIL "3 grants" "anon definer functions" "couldn't parse the H3 allowlist from tests/exos/test_rpc_hardening.sql"
  else
    allow_sql=$(while read -r n; do sql_lit "$n"; echo; done <<<"$allow" | paste -sd, -)
    # Same predicate as H3: public, %exos%, SECURITY DEFINER, not the harness helpers.
    if extra=$(q "select coalesce(string_agg(distinct p.proname, ', ' order by p.proname), '')
                    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                   where s.nspname = 'public' and p.proname like '%exos%' and p.prosecdef
                     and p.proname not like 'exos\\_test\\_%'
                     and has_function_privilege('anon', p.oid, 'EXECUTE')
                     and p.proname not in ($allow_sql)"); then
      if [ -z "$extra" ]; then
        add PASS "3 grants" "anon definer functions" "every anon-executable exos definer function is in the H3 allowlist ($(wc -l <<<"$allow" | tr -d ' ') names)"
      else
        add FAIL "3 grants" "anon definer functions" "anon can execute, not in H3 allowlist: $extra"
      fi
    else add FAIL "3 grants" "anon definer functions" "$(pgerr)"; fi
  fi
  local w
  if w=$(q "select coalesce(string_agg(c.relname || '(' || concat_ws('/',
                case when has_table_privilege('anon', c.oid, 'INSERT') or has_any_column_privilege('anon', c.oid, 'INSERT') then 'INSERT' end,
                case when has_table_privilege('anon', c.oid, 'UPDATE') or has_any_column_privilege('anon', c.oid, 'UPDATE') then 'UPDATE' end,
                case when has_table_privilege('anon', c.oid, 'DELETE') then 'DELETE' end) || ')', ', ' order by c.relname), '')
              from pg_class c join pg_namespace s on s.oid = c.relnamespace
             where s.nspname = 'public' and c.relname like 'exos%' and c.relkind in ('r','p','v','m','f')
               and (has_table_privilege('anon', c.oid, 'INSERT') or has_table_privilege('anon', c.oid, 'UPDATE')
                    or has_table_privilege('anon', c.oid, 'DELETE')
                    or has_any_column_privilege('anon', c.oid, 'INSERT') or has_any_column_privilege('anon', c.oid, 'UPDATE'))"); then
    if [ -z "$w" ]; then add PASS "3 grants" "anon writes on exos tables" "no exos table or view grants anon INSERT/UPDATE/DELETE"
    else add FAIL "3 grants" "anon writes on exos tables" "$w"; fi
  else add FAIL "3 grants" "anon writes on exos tables" "$(pgerr)"; fi
  # Supabase's default privileges give anon USAGE / SELECT / UPDATE on every new
  # sequence in public (shared with Terminal-2, so they stay); each Exos
  # migration revokes anon's on its own (mig 20261109110000 did the older ones).
  if w=$(q "select coalesce(string_agg(c.relname, ', ' order by c.relname), '')
              from pg_class c join pg_namespace s on s.oid = c.relnamespace
             where s.nspname = 'public' and c.relname like 'exos\\_%' and c.relkind = 'S'
               and (has_sequence_privilege('anon', c.oid, 'USAGE') or has_sequence_privilege('anon', c.oid, 'SELECT')
                    or has_sequence_privilege('anon', c.oid, 'UPDATE'))"); then
    if [ -z "$w" ]; then add PASS "3 grants" "anon on exos sequences" "no exos sequence anon can use, read or update"
    else add FAIL "3 grants" "anon on exos sequences" "anon can use / read / update: $w"; fi
  else add FAIL "3 grants" "anon on exos sequences" "$(pgerr)"; fi
  local norls ntab
  ntab=$(q "select count(*) from pg_class c join pg_namespace s on s.oid = c.relnamespace
             where s.nspname = 'public' and c.relname like 'exos\\_%' and c.relkind in ('r','p')")
  if norls=$(q "select coalesce(string_agg(c.relname, ', ' order by c.relname), '')
                  from pg_class c join pg_namespace s on s.oid = c.relnamespace
                 where s.nspname = 'public' and c.relname like 'exos\\_%' and c.relkind in ('r','p')
                   and not c.relrowsecurity"); then
    if [ -z "$norls" ]; then add PASS "3 grants" "RLS on exos_* tables" "on for all $ntab tables"
    else add FAIL "3 grants" "RLS on exos_* tables" "RLS off: $norls"; fi
  else add FAIL "3 grants" "RLS on exos_* tables" "$(pgerr)"; fi

  # 4 crons -----------------------------------------------------------------
  if has_rel cron.job; then
    # One pass over the run history (it is big: Terminal-2's jobs log there too).
    local last_cte="select null::bigint jobid, null::text status, null::timestamptz start_time where false"
    has_rel cron.job_run_details && last_cte="select distinct on (jobid) jobid, status, start_time from cron.job_run_details
                                               where jobid in (select jobid from cron.job where jobname like 'exos%')
                                               order by jobid, start_time desc"
    q "with last as ($last_cte)
       select j.jobname, j.active, j.schedule,
              coalesce(l.status || ' ' || to_char(l.start_time, 'YYYY-MM-DD HH24:MI'), ''),
              regexp_replace(j.command, '\\s+', ' ', 'g')
         from cron.job j left join last l on l.jobid = j.jobid
        where j.jobname like 'exos%' order by j.jobname" >"$TMP/crons" \
      || { add FAIL "4 crons" "query" "$(pgerr)"; : >"$TMP/crons"; }
    if [ ! -s "$TMP/crons" ]; then add WARN "4 crons" "exos% jobs" "no exos% jobs in cron.job"; fi
    local job active sched last cmd fns fn st verdict nactive=0
    while IFS="$SEP" read -r job active sched last cmd; do
      [ -n "$job" ] || continue
      [ "$active" = t ] && nactive=$((nactive + 1))
      fns=""
      for fn in $(function_names | awk '{print length, $0}' | sort -rn | cut -d' ' -f2); do
        printf '%s' "$cmd" | grep -qE "[/'\"]$fn([/'\"?]|$)" && fns="$fns $fn"
      done
      fns=${fns# }
      st="active=$active, schedule '$sched', last run: ${last:-none}${fns:+, calls $fns}"
      if [ "$active" = t ] && [ "${last%% *}" = failed ]; then
        add FAIL "4 crons" "$job" "$st (active and its last run failed)"; continue
      fi
      local bad_fn=""
      for fn in $fns; do
        verdict=$(awk -F'\t' -v n="$fn" '$1 == n {print $2}' "$HTTP")
        [ "$verdict" = missing ] && bad_fn="$bad_fn $fn"
      done
      if [ -n "$bad_fn" ]; then
        add "$([ "$active" = t ] && echo FAIL || echo WARN)" "4 crons" "$job" "$st; edge function not deployed:$bad_fn"
      elif [ -n "$fns" ] && [ ! -s "$HTTP" ]; then
        add INFO "4 crons" "$job" "$st (deployment not cross-checked: run with all)"
      else
        add INFO "4 crons" "$job" "$st"
      fi
    done <"$TMP/crons"
    [ -s "$TMP/crons" ] && add INFO "4 crons" "summary" "$(grep -c . "$TMP/crons") exos% jobs, $nactive active"
  else
    add SKIP "4 crons" "cron.job" "no cron schema here (local harness DB?)"
  fi

  # 6 smoke (db) ------------------------------------------------------------
  local scopes repo_scopes
  if scopes=$(q "select array_to_string(public.exos_api_scope_names(), ',')"); then
    repo_scopes=$(awk '/export const SCOPES = \[/{on=1; next} on && /\]/{exit} on' "$FUNCS/_shared/api/scopes.ts" \
                  | grep -oE "'[a-z:]+'" | tr -d "'" | paste -sd, -)
    if [ -z "$scopes" ]; then add FAIL "6 smoke" "exos_api_scope_names()" "returned nothing"
    elif [ "$scopes" = "$repo_scopes" ]; then add PASS "6 smoke" "exos_api_scope_names()" "$(tr ',' '\n' <<<"$scopes" | wc -l | tr -d ' ') scopes, same as _shared/api/scopes.ts"
    else add WARN "6 smoke" "exos_api_scope_names()" "differs from _shared/api/scopes.ts: db=$scopes repo=$repo_scopes"; fi
  else add FAIL "6 smoke" "exos_api_scope_names()" "$(pgerr)"; fi
  local view cnt can_anon
  can_anon=$(q "select pg_has_role(current_user, 'anon', 'MEMBER')" || echo f)
  for view in exos_public_events exos_public_tiers exos_public_event_sales exos_public_link_outs exos_public_fee_rules; do
    if ! has_rel "public.$view"; then add FAIL "6 smoke" "$view" "view missing"; continue; fi
    if [ "$can_anon" = t ]; then
      if cnt=$(q_anon "select count(*) from public.$view"); then add PASS "6 smoke" "$view" "$cnt rows (read as anon)"
      else add FAIL "6 smoke" "$view" "anon can't read it: $(pgerr)"; fi
    else
      if cnt=$(q "select count(*) from public.$view"); then add WARN "6 smoke" "$view" "$cnt rows (read as $(q 'select current_user'): can't SET ROLE anon to test the grant)"
      else add FAIL "6 smoke" "$view" "$(pgerr)"; fi
    fi
  done

  # 7 settings --------------------------------------------------------------
  if ! has_rel public.exos_platform_settings; then
    add FAIL "7 settings" "exos_platform_settings" "table missing"
  else
    # key=default from every _setting_*('key', default …) call in the migrations
    # since $SINCE, plus the keys read straight from the table.
    local f2 key def val
    for f2 in "$MIG"/*exos*.sql; do
      v=$(basename "$f2"); v=${v%%_*}; [ "$v" -ge "$SINCE" ] 2>/dev/null || continue
      grep -oE "setting_[a-z]+\('[a-z_]+',[[:space:]]*[^,)]+" "$f2" | sed -E "s/^setting_[a-z]+\('([a-z_]+)',[[:space:]]*/\1=/"
    done >"$TMP/settings"
    printf '%s\n' "$STATIC_SETTINGS" >>"$TMP/settings"
    awk -F= '!seen[$1]++' "$TMP/settings" | sort >"$TMP/settings.u"
    q "select key, value::text from public.exos_platform_settings" >"$TMP/settings.db" || add FAIL "7 settings" "query" "$(pgerr)"
    while IFS='=' read -r key def; do
      val=$(awk -F"$SEP" -v k="$key" '$1 == k {print $2}' "$TMP/settings.db")
      if [ -n "$val" ]; then add PASS "7 settings" "$key" "set to $val (default $def)"
      else add WARN "7 settings" "$key" "no row: the default $def applies"; fi
    done <"$TMP/settings.u"
  fi
}

# ---------------------------------------------------------------------------
command -v curl >/dev/null || [ "$MODE" = db ] || { echo "verify-prod: needs curl" >&2; exit 2; }
if [ "$MODE" != http ]; then
  if [ -n "${DB_URL:-}" ]; then command -v psql >/dev/null || { echo "verify-prod: needs psql" >&2; exit 2; }
  else command -v jq >/dev/null && command -v curl >/dev/null || { echo "verify-prod: the Management API path needs jq and curl" >&2; exit 2; }; fi
fi
[ "$MODE" = db ] || http_checks
[ "$MODE" = http ] || db_checks

# Table, sorted by section; non-PASS details are printed in full below it.
sort -s -t$'\t' -k2,2 "$RES" >"$TMP/sorted"
printf '\n%-5s %-12s %-46s %s\n' STATUS SECTION CHECK DETAIL
printf '%s\n' "------------------------------------------------------------------------------------------------------------------------"
while IFS=$'\t' read -r st sec chk det; do
  [ "${#det}" -gt 110 ] && det="${det:0:107}..."
  printf '%-6s %-12s %-46s %s\n' "$st" "$sec" "$chk" "$det"
done <"$TMP/sorted"
if grep -qvE '^(PASS|INFO)'$'\t' "$TMP/sorted"; then
  printf '\nDetails (everything not PASS / INFO):\n'
  grep -vE '^(PASS|INFO)'$'\t' "$TMP/sorted" | while IFS=$'\t' read -r st sec chk det; do
    printf '  %s  %s  %s\n      %s\n' "$st" "$sec" "$chk" "$det"
  done
fi
pass=$(grep -c '^PASS' "$TMP/sorted"); warn=$(grep -c '^WARN' "$TMP/sorted")
fail=$(grep -c '^FAIL' "$TMP/sorted"); skip=$(grep -c '^SKIP' "$TMP/sorted")
printf '\nmode=%s  PASS %s  WARN %s  FAIL %s  SKIP %s\n' "$MODE" "$pass" "$warn" "$fail" "$skip"
if [ "$fail" -gt 0 ]; then echo "result: FAIL (exit 1)"; exit 1; fi
echo "result: OK (exit 0)"; exit 0
