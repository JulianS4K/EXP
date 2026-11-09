# Matched seats

Buyers buy a seat, not a known table. At a cutoff Exos groups the holders
into tables or crews, staff review and adjust, and shortly before the event
each member learns where to go, when, and the other members' first names.
Think Timeleft dinners or 222 nights out.

Migration `20261031210000_exos_matched_seats.sql`, edge function
`exos-match`, matcher `src/lib/matching.ts` (copied byte for byte to
`supabase/functions/_shared/matching.ts`; `matchingParity.test.ts` fails if
they drift), harness `tests/exos/test_matched_seats.sql`.

## For organizers

Event report → Door → **Matched seats**. Per ticket type:

| Setting | Meaning |
|---|---|
| Smallest / ideal / largest group | `group_min ≤ group_target ≤ group_max` (1 to 50) |
| Number of groups | Fixed count, or blank to derive it from sales and the ideal size |
| Match, hours before | The cutoff. The cron (or **Match now**) groups everyone then |
| Reveal, hours before | When members get their spot. No earlier than the cutoff |
| Too-small groups | **Merge**: fold them into other groups, keep what can't move. **Refund**: what can't move is left over and refunded |
| Quiz | On / off, the interests to choose from, the languages |
| Keep quiz answers | Days after the event before answers are deleted (1 to 90) |
| Spots | Restaurants, bars or meeting points, each with a seat capacity, an address, a note for guests and an optional own time |

Sizes and the cutoff are fixed once groups exist; the reveal time, quiz
options and retention can still change.

After matching the panel shows each group (first names, quiz answers, order
refs, a fit score). Staff can **swap** two people, **move** someone, **place**
a leftover, **remove** someone (with an optional block so they are never
grouped with the others again), **lock** the review so a re-run can't change
it, **reshuffle** (a new seed) while nothing is locked, and **reveal now**.
**Refund paid leftovers** calls the existing `exos-refund` per order
(nonce `match:<tier>:<session>`), so money only moves through the normal
refund path. Reports from members show up under **Reports**.

## For buyers

On the event page a matched ticket type says how big the groups are and when
the reveal is. Signed-in buyers can fill the optional quiz before checkout;
everyone can fill or change it on the ticket until groups form, and delete it.

The quiz is deliberately small: first name the group sees, age band (never a
birthdate), language, up to five interests from the organizer's list, solo or
with friends, and a party code. Tickets in one order always sit together; a
party code joins friends who bought separately (unless that would seat a
blocked pair together).

Before reveal the ticket says only "you're in a group of N". At reveal time
the ticket shows the spot, address, note, time and first names, and each
member gets an email; members who opted in to the organizer's texts also get
an SMS (through `exos_sms_outbox`; dry run unless `EXOS_SMS_LIVE=on`).

After the meeting time, for 30 days, members can mark **meet again**. A pick
is shown to both only when it is mutual. Members can also **report** someone
to the organizer and **block** them: a member's block applies to every
organizer's matching on Exos; a staff block to that organizer's.

## How matching works

`matchGroups` in `src/lib/matching.ts`, deterministic for a seed:

1. Parties: union of "same order" and "same party code". A party bigger than
   the largest group is left over (`party_too_big`).
2. Group count from the setting or `round(total / target)`, kept within what
   min and max allow; each group is assigned the spot with the most seats
   left, skipping spots that can't seat the smallest group.
3. Parties, shuffled by the seed then biggest first, go to the group with the
   best score among those where they fit (group max, spot capacity, no
   blocked pair). Score: fill toward the ideal size, same language (+3 /
   -3), near age band, shared interests (Jaccard), and a small penalty for
   putting two friend groups at one table.
4. Groups below the minimum are dissolved into the others where possible;
   the rest are merged (policy merge) or left over as `undersubscribed`
   (policy refund).

`exos_match_apply` stores the result only after re-checking in SQL: every
ticket is an active ticket of the tier and appears once, no group above max,
no spot over capacity, one order never split, no blocked pair together. It
locks the config row, so the cron and "Match now" can't both write. Tickets
sold after the inputs were read become leftovers (`late`).

## Schedule

`exos-match-5min` (pg_cron → `exos-match/cron`) is created **inactive**. Each
run matches tiers past their cutoff, reveals tiers past their reveal time
(and notifies people placed after an earlier reveal), and sweeps quiz answers
past retention. Turn it on with `cron.alter_job(<jobid>, active := true)`
after deploying `exos-match` (`--no-verify-jwt`; the cron path checks
`CRON_SECRET`, `/run` checks the caller's JWT). Operator-gated.

## The `exos_social_groups` seam

Groups live in `exos_social_groups (id, org_id, event_id, kind, tier_id,
spot_id, label, status, meet_at, …)` with members in
`exos_social_group_members (id, group_id, org_id, event_id, kind, ticket_id,
user_id, display_name, role, status, …)`. Matched seats use
`kind = 'matched_seats'`; another feature (a group chat with masked numbers,
say) can attach to these groups by `group_id`, or add its own kind (any
lower_snake word). A member's `org_id`, `event_id` and `kind` are filled
from its group by trigger; one active seat per ticket per kind. Groups are
kept after the quiz answers are swept.

## Not built yet

- A partner API route for groups (none of the existing scopes fit; add
  `groups:read` when a partner needs it).
- SMS reveal texts ignore the marketing quiet hours (they're transactional
  and sent at the organizer's reveal time) and the 30-day marketing cap.
- Free leftover tickets are listed but not released automatically; staff
  void them from the attendee list.
