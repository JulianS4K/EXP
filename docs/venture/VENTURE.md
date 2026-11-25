# Exos

Stage: 1 Idea

Set up 2026-11-25 from the existing docs and prod data. Exos was built
before any recorded validation (see Founder overrides). Walking the gates
against what exists, Gate 1 was the first one the evidence did not pass:
budget, kill criteria and the 12-month target were not written anywhere.
The founder set them on 2026-11-25. Fields still marked *(proposed)* are
drafts from the docs that the founder has not changed.

## One-liner

*(proposed, from docs/gtm-nyc.md)* Exos helps independent NYC promoters and
collectives sell tickets wherever their fans already are (Instagram, Google,
AI assistants, their own storefront) and run the door, without fees added to
the buyer's price.

## Target user

*(proposed, from docs/gtm-nyc.md "Who we sell to", item 1)* Independent
promoters and collectives running recurring parties and monthly series in
Brooklyn (Bushwick, Ridgewood, Williamsburg, Greenpoint), the Lower East
Side, the East Village and Queens, selling 10 to 60 events a year, mostly
from an Instagram bio link.

## Problem

No promoter has been quoted yet. The closest evidence is secondhand: NIVA's
State of Live 2025 survey of independent venues ranks "marketing and
bringing in an audience" as the top challenge (RESEARCH.md). The gtm doc's
claimed pains (Posh's buyer fees, DICE's curation and app lock-in,
Eventbrite's weak door tools) come from competitor research, not from
promoters.

## Why now

- New York has required all-in prices, fees included, since 2022 (Arts and
  Cultural Affairs Law Article 25), and the FTC's live-event fee rule points
  the same way. Exos shows all-in prices by design (docs/gtm-nyc.md).
- Sales have moved to Instagram bio links and in-app browsers
  (docs/gtm-nyc.md; *assumption* until measured).

## Founder edge

*(proposed; founder to confirm)* The S4K broker business and its
Terminal-2 data platform (event mapping, marketplace access), and a
finished product with door check-in, all-in pricing and multi-channel
distribution.

## Success in 12 months

By 2027-11-25: 25 active NYC organizers (at least one paid event in the
last 30 days), and 60% or more of them running a second event within 60
days (founder, 2026-11-25). The north star is monthly GMV from repeat NYC
organizers.

## Budget

Part-time: up to about 15 hours a week · under $10k cash at risk · review
2027-05-31 (founder, 2026-11-25).

## Kill criteria

Agreed by the founder 2026-11-25.

1. Fewer than 6 of 10 NYC promoters interviewed changed or complained about
   their ticketing setup in the last 6 months, by 2026-12-23.
2. Fewer than 3 design-partner organizers have run a real paid event on Exos
   by 2027-02-28.
3. Fewer than 10 active NYC organizers by 2027-05-31, or repeat rate under
   40% by then.

## Gates

<!-- Gate N — Go|Pivot|Kill|Park — YYYY-MM-DD — evidence in a clause -->

## Decisions

- **NYC first, independent promoters before venues** — densest independent
  scene, Instagram-led sales, all-in-price law (docs/gtm-nyc.md). Rules out
  arenas and exclusive-contract rooms for now.
- **All-in prices; buyers never pay an Exos fee** — matches New York law and
  is the pitch against Posh (docs/fees.md). Rules out buyer-side fees.
- **Distribution, not resale** — marketplace channels carry only the
  organizer's own primary inventory, opt-in, at their price (docs/gtm-nyc.md,
  NIVA's resale concern). Rules out resale-only sellers.
- **Organizer fee** — live on main: 3% of each order, first 6 months free,
  no fee on events of 150 capacity or less
  (supabase/functions/_shared/platformFee.ts). In the open stack (#137 and
  up): 2%, no fee under 150 capacity.

- **New product scope pauses until Gate 2 is `Go`** (founder, 2026-11-25)
  — Exos was built without validation, so the next evidence has to come
  from promoters, not from more features. Security, reliability and
  go-live work continue. Rules out new features until then.

## Founder overrides

- 2026-05-20 to 2026-11-25 — founder chose to build the product (221
  migrations live, 44 edge functions) before any recorded validation;
  concern: no evidence yet that NYC promoters will switch. Recorded
  retroactively 2026-11-25.

## Not building

- Arenas and rooms under an exclusive contract with a big ticketer — until
  the NYC indie wedge hits its exit criteria (docs/strategy.md Phase 1).
- Unlicensed events — permanently.
- Resale-only sellers — permanently (distribution, not resale).

## Glossary

- promoter / collective — the person or crew that throws the party; our
  first buyer.
- door — entry check-in at the event, including the offline list.
- all-in price — the price the buyer sees, fees and tax included.
- bio link — the ticket link in an Instagram profile, where most sales
  start.
