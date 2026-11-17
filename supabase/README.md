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

## Prod history vs these files (checked 2026-11-17)

EXP is the home of every Exos migration; Terminal-2 is reference only. Prod's
`supabase_migrations.schema_migrations` records the **time of applying** as
`version` and the file name as `name`, so match prod rows to files here by
**name**, never by version alone (a version-only diff reports about 200
"missing" migrations that are all here).

Of prod's 221 Exos and Stripe rows:

| Prod rows | Count | Here |
|---|---|---|
| Same file name (or same version) | 193 | `supabase/migrations/` |
| Same migration, prod name without its timestamp or with another one | 22 | mapped below |
| Wave 7 (`20261108100000`–`130000`) | 4 | applied ahead of `main` by plan; files arrive with PR #110 |
| 2026-10-21 cron pause, step 1 | 1 | `20261021174000_exos_dead_crons_off.sql`, moved from Terminal-2 |
| 2026-10-21 cron pause, step 2 | 1 | `20261021174500_exos_all_crons_off.sql`, previously in no repo |

The two cron-pause files are **record only**: they keep the original SQL as a
comment and run `SELECT 1`, because re-running them would switch Exos jobs off
(the jobs were turned back on after the pause).

<details><summary>The 22 renamed rows</summary>

| Prod version | Prod name | File here |
|---|---|---|
| `20260522162344` | `exos_phase1_schema` | `20260520120000_exos_phase1_schema.sql` |
| `20260522165908` | `exos_phase2_tickets` | `20260520130000_exos_phase2_tickets.sql` |
| `20260601183748` | `sec_p3_document_exos_public_views_accepted` | `20260601120500_sec_p3_document_exos_public_views_accepted.sql` |
| `20260702052004` | `exos_barcode_secret_least_privilege` | `20260702123000_exos_barcode_secret_least_privilege.sql` |
| `20260702234014` | `exos_event_checkin_roster_rpc` | `20260702240000_exos_event_checkin_roster_rpc.sql` |
| `20260924213042` | `exos_p0_voucher_per_ticket` | `20260924205508_exos_p0_voucher_per_ticket.sql` |
| `20260924213102` | `exos_p0_hold_caps` | `20260924205916_exos_p0_hold_caps.sql` |
| `20260924213107` | `exos_p0_quota_aware_mints` | `20260924210103_exos_p0_quota_aware_mints.sql` |
| `20260924213336` | `exos_all_in_price_tax` | `20260924211840_exos_all_in_price_tax.sql` |
| `20260925163438` | `exos_scanner_no_buyer_email` | `20260925013000_exos_scanner_no_buyer_email.sql` |
| `20260925170722` | `exos_webhook_claim` | `20260925020000_exos_webhook_claim.sql` |
| `20260925170829` | `exos_p1_db_hardening` | `20260925021000_exos_p1_db_hardening.sql` |
| `20260926055156` | `exos_advisor_cleanup` | `20260926000000_exos_advisor_cleanup.sql` |
| `20260926055423` | `exos_waitlist_signin_account_deletion` | `20260926010000_exos_waitlist_signin_account_deletion.sql` |
| `20260926061803` | `exos_promoter_commissions` | `20260926020000_exos_promoter_commissions.sql` |
| `20260926062105` | `exos_referral_rewards` | `20260926030000_exos_referral_rewards.sql` |
| `20260926062357` | `exos_organizer_refunds` | `20260926040000_exos_organizer_refunds.sql` |
| `20260926062958` | `exos_tables_guest_lists` | `20260926050000_exos_tables_guest_lists.sql` |
| `20260926063252` | `exos_abandoned_checkout` | `20260926060000_exos_abandoned_checkout.sql` |
| `20260926063522` | `exos_price_disclosure` | `20260926070000_exos_price_disclosure.sql` |
| `20260926063534` | `exos_refund_tables_fix` | `20260926080000_exos_refund_tables_fix.sql` |
| `20260926193630` | `exos_accessible_tickets` | `20260926090000_exos_accessible_tickets.sql` |

</details>

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
