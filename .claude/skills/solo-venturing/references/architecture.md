# Phase 4: Architecture decisions

Contents: goal · app type · decision table · checks · subagent · challenges · gate · hand-off

**Goal:** the fewest technical decisions that let one person ship *and
operate* the app. Boring technology, managed services, nothing the founder
would be paged for at 3 a.m. One session.

## App type (decide first; it sets the gatekeeper, the payment route and the release work)

| Type | Gatekeeper | Payment route | Fits when |
| --- | --- | --- | --- |
| Mobile store app | Store review | Store billing | The job happens away from a desk, or needs camera, location, notifications |
| Web app or SaaS | None; the founder's own domain | Own checkout or a merchant of record | The job happens at a desk, the buyer is a business, or iteration speed matters most |
| Desktop app | Code signing and notarisation; optionally a store | Licence keys or a merchant of record; store billing in a store | Files, hardware or offline work are the core |
| Browser extension | Extension store review | Own checkout | The job lives inside pages the user already has open |
| Developer tool, API or CLI | Package registries | Usage or seat billing | The founder is the user and the segment reads documentation |

A web app is the cheapest type to ship and change; a store app gets a
distribution channel and a payment system at the price of review and fees.
When two types fit, pick the one with the shorter path to the first paying
user. Phase 8 reads this row to choose its checklist.

## Decision table (each row one question; each answer into `VENTURE.md` with its reason)

| Decision | Default for a solo founder | Ask when |
| --- | --- | --- |
| Platform first | One platform of the chosen type: where the target users are *and* the founder is strongest | Users split evenly across platforms |
| Stack | The founder's strongest; native for one platform | Founder has no stack yet, or cross-platform is a day-one requirement |
| Backend | The earliest of: none (on-device) → managed (CloudKit, Supabase, Firebase) → custom server | The core loop needs sharing, sync across users, or server-side logic |
| Auth | None, or the platform's sign-in | Accounts are required by the core loop, not by habit |
| Data and privacy | Collect the minimum; store where the platform does; account deletion and data export from day one | Any health, finance, children's or location data |
| Payments | In a store: the store's billing, wrapped by a subscription service if there is a subscription. On the web: a merchant of record, which also handles sales tax, unless the founder already runs their own checkout | Pricing model from phase 3 is unusual |
| Analytics and crashes | One privacy-friendly analytics tool, one crash reporter, at most 10 events | Never skip; pick in one question |
| AI features | A single provider, cost per active user computed, a fallback when it fails | The core loop depends on model output |
| Cost ceiling | A monthly number the founder is willing to burn at zero revenue | Always ask; it rules out options |

Write the **"Not building" list**: every capability deferred, with the trigger
that would bring it back (users ask, revenue passes X, platform requires it).

## Checks to settle now (cheap now, expensive later)

Offline behaviour · minimum OS or browser version · internationalisation (at
least string externalisation) · account deletion (stores require it) ·
privacy manifest or data-safety form inputs · export compliance for
encryption · push notifications yes/no · backups and how a restore is tested
· how a bug is reported from inside the app.

## Subagent

`stack-checker` verifies current platform requirements (minimum OS, store
rules for the category, API limits) with sources. Do not rely on memory for
store policy; it changes.

## The angel's challenges

- Two platforms on day one doubles the work and halves the learning rate.
- A backend you don't need is a bill, a privacy surface and a pager.
- The stack you know beats the stack that's trending. Learning a new stack is
  a project, not a feature.
- Every integration is a failure mode you will debug alone. Count them.
- If the prototype in phase 6 can run on fake data, none of this blocks it.

## Gate 4

`Go` when the app type is chosen, the decision table is filled, the monthly
cost estimate is written, and the "Not building" list exists. There is no `Kill` here; a cost ceiling
that nothing fits under sends the venture back to phase 3 pricing (`Pivot`).

## Hand-off

Scaffold the project with the founder's own coding setup and skills. Fill the
*Commands* table in `CLAUDE.md` (install, run, test, lint) as soon as they
exist, so later sessions can verify their work without asking.
