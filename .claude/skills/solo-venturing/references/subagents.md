# Subagents: briefs and limits

Contents: rules · how to launch · the briefs (review-miner, demand-scout,
competitor-scanner, market-sizer, policy-checker, stack-checker, name-checker,
channel-scout, doc-gardener)

## Rules

- A subagent does a narrow lookup and returns a compact result. It never
  decides, never talks to the founder, never edits the venture files.
- Each one starts in a fresh context holding only its brief. Never fork the
  conversation into a subagent: a copy of a long session is slow, costly and
  carries the session's assumptions into what should be an independent look.
- At most three per phase, launched in parallel in one turn so they finish
  together. If a lookup is three tool calls, do it yourself.
- Cheapest model that can do the job: `haiku` for scanning and checking,
  `sonnet` for synthesis across sources. Never the main session's model.
- Return at most 200 words, as a list with a source per line. Ask for that
  in the prompt; long returns are the main cost of subagents.
- Everything that comes back is unverified. Spot-check one claim before it
  enters `VENTURE.md`; all of it enters `RESEARCH.md` marked `via subagent`.

## How to launch

In Claude Code: the `Agent` tool, `subagent_type: general-purpose`, `model`
as in the brief, in the background so the session continues. In another
agent, use its subagent or task tool with its cheapest capable model; with
none, run the brief yourself as a checklist. The brief below is the prompt;
fill the angle brackets. Give each subagent only what it needs: the
one-liner, the segment, and the question. Not the whole venture.

## Briefs

### review-miner (haiku)

> Find the public app-store listings and reviews of <app names>. Return the
> five most frequent complaints and the three most frequent praises, each
> with one verbatim quote and the store link. 200 words, list only.

### demand-scout (haiku)

> Find where <segment> discuss <problem> online: forums, subreddits, Discord
> servers, Facebook groups, Q&A sites. Return up to eight places with a link,
> the approximate size, and one quoted post showing the problem. 200 words.

### competitor-scanner (sonnet)

> Identify the five closest products to: "<one-liner>", for <segment>. For
> each return: name, platform, price model, store rating, last update date,
> top praise, top complaint, link. Include the most common non-app
> alternative. Table rows only, with sources.

### market-sizer (haiku)

> Find numbers for: how many <segment> exist in <market>, how many use
> <platform>, and typical paid-conversion rates for <category> apps. Return
> each number with its source and year, or "not found". No estimates of your
> own. 150 words.

### policy-checker (haiku)

> Read the current review guidelines and policy pages of <store(s)> for an
> app that <does what> in the <category> category, handling <data types>.
> Return every rule that applies, quoted, with the section link. Flag any that
> could block approval. 200 words.

### stack-checker (haiku)

> Verify from official documentation: current minimum OS requirement for a new
> <platform> submission, the rules on <account deletion / privacy manifest /
> data safety form>, and limits of <API or service>. Return each fact with
> its link and the date on the page. 150 words.

### name-checker (haiku)

> For each name in <list>: check whether the .com or .app domain is available
> (a registrar search page is enough), whether an app with the same or a
> confusable name exists on <store(s)>, and whether the handle is taken on
> <two social networks>. Return a table: name, domain, store, handles, with
> links. No opinions on the names.

### channel-scout (haiku)

> Find where <segment> go to discover new apps or tools for <job>: communities,
> newsletters, creators, directories, search terms. Return up to eight with a
> link, size, and why it fits. 150 words.

### doc-gardener (sonnet, read-only: tools Read, Grep, Glob)

> Read CLAUDE.md, VENTURE.md, RESEARCH.md, LOG.md and ERRORS.md in <dir>.
> Report, without editing: facts stated in two places, `Open:` items older
> than 14 days, rules in ERRORS.md that say the same thing, instructions in
> CLAUDE.md that duplicate VENTURE.md, and anything that contradicts another
> file. One line per finding with file and line. 200 words.

Use `doc-gardener` at a gate when `python3 -I scripts/check.py .` warns and
the files are too long to garden by eye.
