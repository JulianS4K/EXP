# The five venture files

Contents: overview · each file's format and rules · when to write · compaction

Created by `scripts/new_venture.sh` from `assets/`. Read `CLAUDE.md`,
`VENTURE.md`, `LOG.md` and `ERRORS.md` at every session start; read
`RESEARCH.md` when the phase needs evidence. `python3 -I scripts/check.py .`
validates structure and flags gardening work.

| File | Answers | Changes |
| --- | --- | --- |
| `CLAUDE.md` | How Claude works on this venture: role, standing rules, commands | Rarely |
| `VENTURE.md` | What the venture is, where it stands, what was decided and why | Per gate |
| `RESEARCH.md` | What is known, from where, since when | Per finding |
| `LOG.md` | What happened and why, newest first | Per session |
| `ERRORS.md` | What must not happen again | On every correction |

## CLAUDE.md: role and standing rules

The founder's standing instructions for this venture: the angel co-founder role,
conventions, the commands that verify work, boundaries (what needs the
founder's sign-off). Instructions only; facts about the venture live in
`VENTURE.md`. If it changes every session, the content belongs in `LOG.md`.

## VENTURE.md: the single source of truth

Required lines, in this order, because `check.py` and a cold session look
for them:

- `Stage: <1-10> <phase name>` on its own line near the top.
- `## One-liner`, `## Target user`, `## Problem`, `## Success in 12 months`.
- `## Budget`: hours per week, cash at risk, review date.
- `## Kill criteria`: up to three, each measurable with a date.
- `## Gates`: one line per gate taken: `Gate N — Go|Pivot|Kill|Park —
  <date> — <evidence in a clause>`. `check.py` requires a `Go` line for
  every gate before the current stage. A gate passed by the founder's
  override is written as `Go` with `founder override` as its evidence.
- `## Decisions`: `**<decision>** — <reason>, rules out <what>`. The
  architecture table from phase 4 goes here. A decision is recorded once,
  when it is made; a later session changes it only by adding a new line
  that names the one it replaces.
- `## Founder overrides`: `<date> — founder chose <X> over <Y>; concern:
  <one clause>`. Keep them; they are the venture's honest history.
- `## Not building`: `<capability> — until <trigger>`.
- `## Glossary`: `<term the users say> — <what it means here>`. The words
  for questions, copy and code.

Later phases add their sections (validation bar, positioning, pricing
hypothesis, channel plan, MVP scope, release checklist, metrics, unit
economics, money and obligations).

## RESEARCH.md: evidence

Every entry has a date and a source (link, "interview with <role>", "store
listing of <app>", "assumption"). Group by phase. Tables for competitors and
sizing. Three lines per interview or user test. An entry without a source is
an opinion and goes to the chat, not here.

## LOG.md: the timeline

Newest first, one section per date. Log decisions and their reasons, things
tried that failed and why, what is unfinished (`Open:`). The first `Open:`
line of the newest section is the next action; a cold session starts there.
Do not log files read, diffs, or tool output. One line per item where one
line will do.

## ERRORS.md: the quality gate

Read before work that resembles a past failure. Every entry:

```markdown
## Don't set the validation bar after seeing the data

Seen: 2026-11-02 — reported by founder
What happened: the signup rate was called "promising" at 1.2% with no bar set.
Rule: write the bar in VENTURE.md before the first visitor or interview.
```

Add an entry when the founder says something is wrong or not what they meant
(before fixing), and when you catch a repeat yourself (then tell the founder).
Generalise one level, no further. A repeat of an existing rule means the rule
needs sharper wording, not a second entry.

## When to write

- `LOG.md`: at every handoff: each gate, each session end, and whenever the
  context budget warns.
- `VENTURE.md`: at every gate and every recorded decision or override.
- `RESEARCH.md`: as findings arrive, including subagent results.
- `ERRORS.md`: at the moment of the correction.

## Compaction (lossless)

When a file passes about 200 lines or repeats itself, and never mid-step:

1. If tracked by git, commit pending changes first so the compaction is its
   own diff; otherwise copy the file to a temp directory.
2. List the facts that must survive: decisions and reasons, dates, numbers,
   names, links, rules, failed attempts, open items.
3. Merge duplicates, fold runs of `LOG.md` entries into one with a date range,
   close `Open:` items whose outcome is recorded, merge `ERRORS.md` rules that
   say the same thing (keep all `Seen:` dates and sharpen the wording), drop
   filler. Never soften a rule. Leave the `Stage:` line to the gates.
4. Walk the fact list against the result; anything missing goes back in.
5. Tell the founder per file: lines before and after, what was merged. One
   line in `LOG.md`: `Compacted <files>: <before> → <after> lines.`
