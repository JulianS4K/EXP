# Errors

A quality gate, not a diary. Read before work that resembles a past failure.
Every entry names the rule that prevents a repeat. Add one whenever the
founder reports something wrong or unexpected, and whenever a mistake repeats;
then tell the founder.

## Check a product fact against the code before writing it down

Seen: 2026-11-25 — caught in review
What happened: a Growth note and an earlier summary gave the fee as 2% above
150 capacity; main still charges 3% (the 2% change sits in unmerged PRs).
Rule: read `supabase/functions/_shared/platformFee.ts` (or the doc that owns
the fact) and say which version is live before quoting a fee or limit.
