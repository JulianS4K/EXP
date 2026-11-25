# Phase 3: Research and market fit

Contents: goal · the five artefacts · subagents · questions · challenges · gate

**Goal:** know the market well enough to position, price, and not be
surprised. Pareto: the top five competitors, not fifty; one bottom-up size
estimate with explicit assumptions, not a purchased report.

## The five artefacts (all into `RESEARCH.md`, conclusions into `VENTURE.md`)

1. **Competitor table.** Name, platform, price model, rating, last update,
   top praise, top complaint, source link. Include the non-app alternatives:
   spreadsheet, notebook, "do nothing". Five rows, dated.
2. **Positioning statement.** `For <segment> who <need>, <product> is the
   <category> that <key benefit>. Unlike <main alternative>, it <difference>.`
   One differentiator. Two is none.
3. **Bottom-up sizing.** Reachable users in the segment × realistic
   activation × conversion to paid × price × 12 months. Every factor written
   with its source or labelled "assumption". Compare the result to the
   12-month target from phase 1.
4. **Pricing hypothesis.** Model (one-time, subscription, freemium, free with
   a paid tier), anchored to the competitor table and net of platform fees.
   Decide the hypothesis, not the final price.
5. **Risks.** Store policies for the category, data-privacy rules (GDPR, age
   limits, health or finance regulation), dependence on a platform API or a
   single channel. Each risk with a one-line mitigation or an "accept".

## Subagents (at most three, in parallel; `references/subagents.md`)

- `competitor-scanner` returns the table rows with links.
- `market-sizer` returns the factors it could find, each with a source.
- `policy-checker` returns the store and legal rules that bite this category.

Verify anything surprising yourself before it reaches `VENTURE.md`.

## Questions, broad to narrow

Open: which alternative do target users use today, and what do they say about
it? What would make one of them switch?

Narrow, with options:

- Which single differentiator do we bet on: speed, price, a niche nobody
  serves, a workflow integration, design, privacy?
- Which pricing model, given the table?
- Which risk do we accept, and which do we design around now?

## The angel's challenges

- "No competitors" means no market or a weak search. Look again.
- Incumbents ignore small niches; that is the solo founder's edge. Pick the
  niche they ignore, not the feature they lack.
- A product 10× better than the alternative still loses to one with
  distribution. Note how each competitor gets users; that is phase 5 input.
- If the bottom-up math only works with conversion rates above what the
  category shows, the math is the problem, not the ambition.

## Gate 3

`Go` when positioning, one differentiator, a pricing hypothesis and the
sizing math are written and the math reaches the 12-month target under
assumptions the founder accepts. `Pivot` when the math fails: change the
segment, the price, or the target, and log which. `Kill` when a risk is
unmitigable (a policy forbids the core feature, the only channel is closed).
