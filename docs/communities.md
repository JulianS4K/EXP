# Communities

A community is a page people join to hear about every event a group runs: a run club, a supper club, a party crew, a
venue's regulars. It sits next to the org storefront (`/o/:slug`) and the org follow: following an org is a quiet
bookmark, joining a community is an opt-in to its news.

- **Code:** migration `20261031200000_exos_communities.sql`; `src/views/Community.tsx` (`/c/:slug`),
  `src/views/Communities.tsx` (`/communities`), `src/components/OrgCommunitiesPanel.tsx` (Org settings →
  Communities), `src/lib/communities.ts` + `communitiesApi.ts`; mail renderers `community-post` / `community-event`
  in `supabase/functions/_shared/mail-templates.ts`; the members-only gate in `exos-checkout`.
- **Federation:** [federation.md](federation.md) (ActivityPub, off by default).
- **Tests:** `tests/exos/test_communities.sql` (run by `run_p0.sh`), `src/lib/communities.test.ts`,
  `src/lib/mailTemplates.test.ts`, `src/lib/activitypub.test.ts`.

## Who does what

| Role | Can |
|---|---|
| Org owner / manager | Create and edit communities (up to 25 per org), set the join mode, invite members and hosts, approve requests, remove / ban, list the org's events (members-only or early access), post, moderate posts, reports and fediverse replies, turn federation on |
| Org content role | Post |
| Host (invited by email) | Add events of an org where they are owner / manager (their own), propose a **draft** event in the community's org (the organizer prices and publishes it), post. Nothing else: no member list, no moderation, no other events of the org |
| Member | Read members-only posts, buy members-only / early-access tickets, choose channels, report posts, leave |
| Anyone | The public page (no member names, a count only), the directory |

Hosts are how "the run club meets at the bar" works: the bar's org owns the community; the run club's organizer is
a host who lists the run club's own events there. A host invite is a link (`?host=ech_…`, 14 days, single use, only
its SHA-256 stored) that must be accepted signed in with the invited, confirmed email. Banning someone revokes their
host role in that community.

## Joining

| Join mode | What happens |
|---|---|
| `open` | Member at once |
| `approval` | `pending` until an owner / manager approves (or declines) |
| `invite` | Needs an invite link (`?invite=ecv_…`): one person (bound to their email) or a shared link with 1–500 uses, 30 days. Only the SHA-256 is stored; the link is shown once |

Banned people can't rejoin or accept a host invite. Removed people (and people who left or were declined) can join
again under the current mode. 30 joins a day per account.

**Consent.** The join form asks how to hear about new events and posts: email and/or text. The exact consent text
shown is stored with the time (`exos_community_members.consent_text`, `consented_at`); turning a channel back on
later needs it again. Texts are only offered once the person is on the organizer's SMS list through the existing
opt-in (`exos_sms_opt_in`, with the TCPA text and STOP); the community doesn't collect phone numbers itself.

## What members hear

- **Every new event** in the community, once, when it's published (or when it's added, if it already is), through
  the channels each member chose. At most 5 event announcements a day per community (the rest are listed but not
  announced; the panel says so).
- **Posts** the organizer or a host marks "Email / text members": at most 3 a day and 10 a week per community. Other
  posts only show on the page.

Mail goes through `exos_mail_enqueue` as a marketing mail: confirmed email only, the account-wide opt-out
(`exos_mail_prefs`) is honored, the unsubscribe link and List-Unsubscribe header are added, and each mail also links
to the member's channel settings on the community page (`?settings=1`). Each (post or event, member) is queued at most
once (dedupe key).

Texts go through the SMS outbox: one campaign (`audience = 'community'`, `community_id`) per announcement, quiet hours
9:00–20:00 in the event's (else New York) time, the org's 8-a-month cap per number, the org's 5 campaigns a day,
"Reply STOP to opt out." added, and a number that sent STOP is skipped when queuing and again at send time. Texts are a
dry run until `EXOS_SMS_LIVE=on` (see the SMS section of the organizer guide).

## Posts and moderation

Posts are plain text (no HTML), up to 5,000 characters, with an optional title. `public` posts show on the page (and
federate when federation is on); `members` posts only to members, hosts and the org's staff. 10 posts a day per
author per community, 50 per community.

Anyone signed in who can see a post can report it once (spam, harassment, hate, sexual, violence, misleading, other;
10 reports a day per account). Owners and managers resolve a report: dismiss, hide, remove, or remove and ban the
author. Resolving closes every open report on that post. Hosts can hide or remove their own posts.

## Members-only events and early access

`exos_community_events` per (community, event):

- `members_only`: only members can get tickets.
- `early_access_until`: only members until then, everyone after (must end before the event starts).
- `access_rule`: `community` (community members), `membership` (holders of the listed products from
  the memberships migration (`20261030130500`, PR #70) when it is applied), or `either`. The membership check goes through the
  memberships migration's `_exos_member_best` if it exists (dynamic SQL); without it a `membership` rule lets nobody
  in (fails closed), and listing products is refused.

Enforced in two places:

1. `exos-checkout` calls `exos_community_checkout_gate(event, buyer)` before any hold or Stripe session, for paid and
   free orders. A guest checkout (no account) is never a member. 403 with `reason: community_members_only` /
   `community_early_access` and `community_slug`.
2. A `BEFORE INSERT` trigger on `exos_tickets` refuses any ticket issued while a signed-in non-member is the caller
   (free claims, RSVPs, any client path). The org's owner / manager / scanner (comps, guest lists, box office) and
   server-side inserts with no signed-in user (checkout fulfillment, which step 1 gated; marketplace and feed orders
   the organizer set up) pass.

Members-only events never federate.

## Directory

`/communities?city=<key>&q=<search>`: public, active communities (unlisted ones are left out but open by link),
filtered by city (case and spacing don't matter), searched by name or tagline, ordered by next event then size. The
city list comes with counts.

## RPCs

| Function | Who |
|---|---|
| `exos_public_community(slug)`, `exos_public_communities(city, query, limit, offset)`, `exos_public_event_communities(event)`, `exos_community_invite_preview(token)` | anon + signed in (H3 allowlist) |
| `exos_community_join`, `_leave`, `_set_notify`, `_report`, `_host_accept`, `exos_my_communities` | signed in, self |
| `exos_community_save`, `_admin`, `_member_list`, `_decide`, `_remove_member`, `_unban`, `_invite`, `_revoke_invite`, `_host_invite`, `_host_revoke`, `_moderate_post`, `_resolve_report`, `_review_reply`, `_block_remote` | owner / manager of the community's org (re-checked from the row) |
| `exos_community_add_event`, `_remove_event`, `_post`, `_host_create_event` | owner / manager (content: post), or an active host within the limits above |
| `exos_community_checkout_gate`, `exos_ap_*` | service role |

Tables are RLS-on with no client writes; staff (and a person for their own member / host row) can read. Token hashes
and reporter ids are not in the column grants.

## Not built yet

- Partner API routes (`communities:read`) and webhooks for joins.
- A members-only / early-access notice on the event page itself (the checkout error explains it today;
  `exos_public_event_communities` is ready for it).
- Member-to-member posting or comments by Exos members (only the organizer and hosts post; replies come from the
  fediverse, moderated).
- Image uploads for banners (a URL for now) and post attachments.
