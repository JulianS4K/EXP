# supabase/

Exos still runs on the **shared** Supabase project it has always used, alongside
Terminal-2's broker data. The code moved out of Terminal-2; the database has not.

## Where each thing lives until the database split

The DB is still shared with Terminal-2's broker data, but **all Exos
server-side source now lives here**: edge functions since 2026-09-26, and
migrations + SQL harnesses since 2026-09-26 as well. Terminal-2 no longer
carries copies.

| Thing | Authoritative home (edit + apply/deploy from) | Notes |
|---|---|---|
| Exos edge functions: `exos-*` + `stripe-webhook` | **This repo**, `supabase/functions/` | Deploy to the shared project |
| `_shared/cron-auth.ts` | **This repo** (the Exos copy) | Terminal-2 keeps its own for its broker functions |
| `_shared/pricing.ts` | **This repo** | Must match `src/lib/pricing.ts`; `pricingParity.test.ts` checks it |
| `*exos*` migrations | **This repo**, `supabase/migrations/` | Apply to the shared project; see the rules below |
| SQL harnesses | **This repo**, `tests/exos/` | CI runs them (`exos-sql` job, incl. the barcode-secret RLS test) |
| Built SPA bundle | `Terminal-2/static/bridge/` (served by `vibepass-storefront-test`) | build it here (`dist/`), copy it over |

Applying a migration or deploying a function still goes to the **same shared
project** and still needs explicit operator permission.

### Migration rules while the DB is shared

1. **Filenames contain `exos`** (CI enforces it). Terminal-2's prod drift
   check (`bin/sync-check.sh`) treats applied migrations with `exos` in the
   name as owned here, so they don't show up as drift there.
2. **Timestamps are shared with Terminal-2.** Both repos write the same
   `supabase_migrations.schema_migrations` history, and its `version` is the
   primary key. Before choosing a prefix, check Terminal-2's
   `supabase/migrations/` (and prod's history) for the same 14 digits. A
   collision can't corrupt anything, since the apply fails on the PK, but it
   has to be renamed.
3. **Cross-cutting sweeps stay in Terminal-2.** Eighteen Terminal-2
   migrations (security / RLS / index sweeps across the whole schema, e.g.
   `*_sec_p*`, `*_rls_initplan_optimization`, `*_fk_indexes_unindexed`) also
   touch `exos_*` objects. They're already applied and stay there as
   history, so replaying this directory alone doesn't reproduce prod
   exactly (see Caveats).
4. **A text patch must match prod's function body, not the harness's.**
   Many migrations patch a function in place by search-and-replace on
   `pg_get_functiondef` (`pg_temp.exos_patch_n`), which raises when the search
   text isn't found. Because of rule 3, prod's body can differ from the one
   `tests/exos` builds. Example: prod runs the hardened `exos_claim_transfer`
   from `20260924200848`, which the harness doesn't replay. So
   `20261104100000`'s lock patches found nothing to match and stopped the
   2026-11-05 prod rollout. Before shipping a patch, read the target with
   `select pg_get_functiondef('public.<fn>(<args>)'::regprocedure)` on prod
   (read-only) and check that the search text appears the expected number of
   times. When prod may already contain the change, guard the patch the way
   `20261104100000` does: skip it when the end state is already present. Don't
   loosen the match count to make it pass.
   Since 2026-11-09 the harness builds bodies the way prod was built (see
   "The SQL harness" below), so `20260924200848`'s claim body is there and a
   patch that only matched the old harness fails locally too. A patch must
   also *run* on prod's body: one that adds a query aliasing a table with the
   name of a plpgsql variable in the target (`t`, `r`, `tr`, ...) is ambiguous
   at run time. `20261105100000` did that to `exos_claim_transfer` and broke
   every claim until `20261108130000`. Pick an alias the target doesn't
   declare.

## The SQL harness (`tests/exos/run_p0.sh`)

It applies **every** `*exos*` migration in timestamp order, from
`20260520120000_exos_phase1_schema` on, the way prod was built. Before
2026-11-09 it started from a hand-stubbed schema (`tests/exos/prereq.sql`,
still used by `run.sh` / `run_money_path.sh`) and skipped the 34 migrations
up to `20260924200848`. Only what Supabase itself provides is stubbed:
roles, `auth`, `pgcrypto` (`prereq_lifecycle.sql`), storage, the realtime
publication, `cron_should_fire`, the default privileges on sequences (`prereq_supabase.sql`) and vault
(`prereq_vault.sql`). A few migrations need a shim around them, set in
`apply()` in `run_p0.sh`; none of them is edited:

| Migration | Shim | Why |
|---|---|---|
| `20260702144637_exos_reconcile_checkouts_cron` | `shim_cron.sql` before, `DROP SCHEMA cron` after | Calls `cron.schedule` unguarded; every later migration guards on `pg_extension` and some tests check `to_regclass('cron.job')`, so pg_cron exists for this file only |
| `20260703130000_exos_event_artist_links` | drop `exos_public_events` before, `shim_artist_links_view.sql` after | Its view puts `artist_links` mid-list, which can't replace the phase-1 view; prod has it appended last (`20260911133000` relies on that) |
| `20260601120500_sec_p3_…` | `ALTER … scanned_by DROP NOT NULL` before | Terminal-2's `20260526020000_fix_checkins_scanned_by_nullable`, the one Terminal-2 migration that changes an `exos_*` column (rule 3), at its place |
| `20260929080000_exos_rpc_hardening` | `prereq_rpc_hardening.sql` before | Prod's `exos_queue_mail` / `exos_queue_ticket_issued` / `exos_create_org` as of 2026-09-28 carry prod-only edits the chain doesn't build |
| `20261109110000_exos_security_hygiene` | `shim_security_hygiene.sql` before | Prod's leftovers it cleans up (`exos_paste_probe`, anon EXECUTE on two helpers), and a snapshot of the `exos_*` policies for `test_security_hygiene.sql` |

The replay loop re-runs every migration from `20260924215000` on (the first
written to be re-run safe). The 34 older ones are applied but not replayed:
27 of them can't run twice as written (`CREATE POLICY` without `DROP … IF
EXISTS`, view columns reordered, return types changed since), and replaying
the rest puts back older bodies of five functions. None of them will ever be
pending in prod again. `scripts/check-migrations.sh` (CI) checks that every
`*exos*` migration is in the apply loop and each from `20260924215000` on is
also in the replay loop.

Still not reproduced: Terminal-2's other sweeps over `exos_*` objects (policy
rewrites in `*_rls_initplan_optimization`, indexes, grants and revokes,
`ALTER FUNCTION … SET search_path`). They don't change what a function body
says, which is what text patches match.

When the DB split happens (plan step 4 below), the remaining step is data:
a new project, a data copy, and repointing the functions and the SPA.

## Caveats

- These are only the migrations with `exos` in the filename. Some Terminal-2
  security sweeps (e.g. `*_sec_p*`, `*_rls_initplan_optimization`,
  `*_flip_safe_definer_views_security_invoker`) also touch `exos_*` objects, so
  replaying this directory from zero **does not** reproduce the production
  schema exactly. Take a baseline `pg_dump --schema-only` of the `exos_*`
  objects when splitting off a dedicated project.
- `exos_*` tables live in `public`, not in their own schema. Their RLS uses the
  shared Supabase Auth.

The full split (new project, data copy, repointing the functions and the SPA)
is step 4 of Terminal-2's `docs/archive/2026-07-02-bridge-extraction-plan.md`
and hasn't been done yet.
