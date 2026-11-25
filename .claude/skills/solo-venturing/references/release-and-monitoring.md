# Phases 8 and 9: Release, distribution and monitoring

Contents: Phase 8 checklist (seller, legal, listing, technical, by app type,
launch week), gate · Phase 9 metrics, weekly ritual, decision loop, gate

## Phase 8: Release and distribution

**Goal:** live or submitted, able to take money, with a launch week planned
day by day. Launch is a process, not an event.

### Checklist (all green before release; copy into `VENTURE.md` and tick)

Use the common blocks plus the block for the app type chosen in phase 4.

Seller setup

- The seller is decided (private person, sole trader, company) and the store
  or payment provider account is in that name, with tax and payout forms
  complete. Stores can take days to verify these; start early.
- One real payment made and paid out, or bought once in the sandbox where a
  real one is not possible before release.
- Contact details the stores or the law require the seller to publish are
  ones the founder is willing to make public.

Legal and policy

- Privacy policy URL live; terms if there are payments or accounts; any
  legal notice the founder's country requires on a commercial site.
- Privacy declarations (store privacy labels, data-safety form, cookie
  notice) match what the product actually collects; verify against the
  analytics event list.
- Account deletion reachable inside the product if there are accounts.
- Age rating, export-compliance answer, consent flow if EU users and tracking.

Listing and landing

- Name, subtitle, keywords, description from phase 5; five screenshots with
  headlines; icon; category; support URL and email.
- Landing page says who it is for and what it costs, and its call to action
  reaches the product in one step.

Technical

- Release build installed clean on a device or browser profile that never
  had the debug build.
- Crash or error reporting and the at-most-ten analytics events live in the
  release build; verify one event arrives.
- Kill switch or remote flag for any risky feature (AI, payments, third-party
  API).
- Version and build number recorded in `VENTURE.md`.
- Rollback plan: what to do if the first day shows a crash or error spike.

By app type

- **Store app:** build signed; demo account and review notes for the
  reviewer; phased or staged rollout on where the store offers it; a buffer
  of one to two weeks for a rejection.
- **Web app or SaaS:** own domain with HTTPS; transactional email arriving
  in an inbox, not in spam; database backups on and one restore tested;
  uptime check alerting the founder; signup to first success tried from a
  phone.
- **Desktop app:** signed and notarised for each operating system;
  auto-update tested from the previous version; licence activation works
  offline or says clearly why not.
- **Browser extension:** each permission justified in the listing; tested in
  a clean profile; review buffer as for store apps.
- **Developer tool, API or CLI:** a quickstart that works when pasted;
  install tested on a clean machine; versioning and a changelog; rate limits
  and a status page if there is a service behind it.

Launch week

- One channel (phase 5), day-by-day actions for seven days, posts drafted
  with a writing skill if the founder has one installed.
- A date that leaves room for a rejection or a failed deploy; both are normal.
- Not on a Friday.

### Subagent

`policy-checker` re-reads the current store guidelines and seller
requirements for the app's category before submission; policies change and
memory is stale.

### Gate 8

`Go` when every item is green and the product is live or submitted. There is
no `Kill` here; a rejection loops inside the phase with the reason in
`ERRORS.md` if it was avoidable.

## Phase 9: Monitoring and iteration

**Goal:** numbers flowing, a weekly ritual, and a decided next loop.

### Five metrics (pick five, write them in `VENTURE.md` with a target)

Installs or signups · activation (core task completed in the first session)
· retention (day 1, day 7, day 30) · conversion to paid · net revenue ·
crash-free sessions or error rate · rating and review count · support
volume. Retention before acquisition: a leaky product makes every channel
more expensive.

### Weekly ritual (30 minutes, logged in `LOG.md`)

Read the five numbers. Read every review and support message. Decide one
thing for the week: a fix, a channel action, or nothing. Talk to one churned
user if any can be reached.

### Decision loop

At two weeks and at six weeks after launch, evaluate against the phase 1
success definition and kill criteria. At six weeks, first do the sum an
investor would do: paying users × price, minus store or processor fees,
against the monthly cost to run the product. Say whether the product covers
its costs today, and at what number of paying users it would.

- `Go`: the channel works, retention holds, and the sum above has a path to
  covering costs. Double down on the channel before adding features.
- `Pivot`: retention holds but acquisition fails, or the reverse. Change the
  one that fails; return to phase 5 or phase 6.
- `Kill`: both fail and the kill criteria are met. Sunset plan: notify users,
  refund policy, data export, store removal date. A clean kill is a founder's
  asset.
- `Park`: the venture pays for itself at zero effort; keep it, stop investing.

### The angel's challenges

- Most apps die of no distribution, not of bad code. Check the channel number
  before the feature list.
- Every review is a free interview. Answer each one.
- Adding features to fix retention rarely works; fixing the first session does.

### Gate 9

`Go` when the five metrics flow, the weekly ritual has run at least twice,
and the six-week decision is `Go`. The venture then enters phase 10, where
the product is run as a business (`references/business.md`); the weekly
ritual continues there.
