# Phases 6 and 7: Prototype, build and internal test

Contents: Phase 6 Prototype (fidelity ladder, test protocol, gate) ·
Phase 7 Build (MVP scope, build loop, when something breaks, testing floor,
versioning, internal test, gate)

## Phase 6: Prototype

**Goal:** the core loop in front of five target users before production code.
The question a prototype answers is "do they get it, and do they want it",
nothing else.

### Fidelity ladder (climb only as far as the question needs)

1. Paper or whiteboard screens, talked through.
2. Clickable mock (Figma, or a throwaway build with hard-coded data).
3. Working prototype with fake data, throwaway code.

A throwaway is throwaway: it lives outside the production repo and is deleted
after the gate, so nothing in it becomes "the first version".

### Test protocol (hand to the founder)

- Five people from the segment, recruited through the phase 5 channel or the
  interview list from phase 2.
- Task-based: "You just got home and want to …". Watch, don't explain. Note
  where they hesitate and what they say unprompted.
- Three measures per session: completed the core task unaided (yes/no), said
  what they'd pay or when they'd come back (quote), the point of confusion.
- Three lines per session into `RESEARCH.md`.

Run the founder's design-review skill on the prototype before the sessions
if one is installed.

### Gate 6

`Go` when four of five complete the core task unaided and the value lands in
their words. One iteration is allowed; a core loop that fails twice is a
`Pivot` back to phase 1 (the job) or phase 3 (the segment).

## Phase 7: Build and internal test

**Goal:** a shippable core loop, not the full product.

### MVP scope (write it in `VENTURE.md` before the first commit)

In: the core loop · onboarding to the first success · the monetisation hook
(paywall or purchase, even if free during beta) · account deletion if there
are accounts · settings and a way to report a bug. Everything else: the "Not
building" list with its trigger.

### Build loop, per feature

1. **Requirements:** what is true when this is done, in one to three lines.
2. **Strategy:** what you'll touch, what could break.
3. **Execute.**
4. **Verify the effect:** run the tests for what changed, then use the feature
   on a real device or simulator yourself. A green test run is not the
   feature working.
5. **Integrate:** land it, one line in `LOG.md` with the reason behind any
   decision.

If the founder has an engineering workflow skill installed, it owns this
loop and the testing detail; follow it and keep the venture files as the
product record.

### When something breaks

Reproduce it, shrink the reproduction, state one hypothesis, add the
logging that would prove it wrong, fix, then verify on the reproduction. Do
not change code for a failure that has not been reproduced, and do not touch
files the hypothesis does not name. A bug the founder reported goes into
`ERRORS.md` if a rule would have prevented it.

### Testing floor

- Logic under the UI (validation, state, data, API) tested as it is built.
- UI tests after the founder signs off on the UI, not before: every redesign
  would rewrite them.
- A test that cannot fail proves nothing: for each requirement, one test that
  would go red if it were violated.
- One real end-to-end ride on a device or in a browser before every
  internal build.
- No code without a caller that exists today.

### Versioning

Start at `0.1.0`, stay below `1.0` until the founder calls it ready. Build
numbers from the clock at build time (`YYYY.MMDD.HHmm`, UTC), never typed.

### Internal test

Internal or closed testing track (TestFlight, Play internal testing, a
password-protected web build) with five to ten testers from the segment. One
feedback form, one line per report in `RESEARCH.md`. Fix order: crashes,
then confusion, then wishes. Wishes go to "Not building" unless three testers
share one.

### The angel's challenges

- Scope creep kills more solo apps than bugs. "While I'm at it" is the enemy;
  write it down and move on.
- Ship the 80% of value that lives in 20% of the features.
- If the founder is building what no tester asked for, stop and read
  `RESEARCH.md` together.

### Gate 7

`Go` when the core loop works end to end on a real device or browser, the
tests pass, testers complete the core task, and there is no known crash. `Park` when the
founder's time runs out before that; write what remains in `LOG.md` so the
return is cheap.
