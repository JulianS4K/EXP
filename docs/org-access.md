# Organizer-controlled access

Three operator decisions (2026-11-04), migration `20261104180000_exos_org_access.sql`:

1. **API permissions are the organizer's.** The owner sets which API scopes each role's keys and tokens may carry.
2. **A promoter goes through the venue.** When a venue already runs on Exos, another organization can't put an
   event or a hold there on its own: it sends a booking request, and the venue decides.
3. **Partner presale: both options.** Partners are refused during a member presale (the default), or allowed.

Tests: `tests/exos/test_org_access.sql` (OA1-OA10), `src/lib/orgAccess.test.ts`. API reference:
`docs/api/org-access.json` (/developers, "Access").

## 1. API permissions per role

Settings → **API permissions** is a role × scope table. The owner ticks boxes; the other members see it read-only.

- **Ceiling.** Each role has a fixed most-it-can-ever-get (`exos_role_scope_ceiling`, mirrored by
  `ROLE_SCOPE_CEILING` in `supabase/functions/_shared/api/orgAccess.ts`), taken from what the role can do in the
  dashboard. Boxes above it are greyed out and the SQL refuses them (`role_scope_ceiling`, 403 in the API):

  | Role | Ceiling |
  |---|---|
  | owner | every scope (the owner's set is fixed) |
  | manager | everything but `org:admin` |
  | finance | `events:read`, `orders:read`, `refunds:write`, `fans:read`, `tickets:read`, `booking:read`, `finance:read`, `finance:write`, `commerce:read` |
  | content | `events:read`, `events:write`, `booking:read` (never orders, finance or refunds) |
  | scanner (door) | `events:read`, `tickets:read`, `checkin:write` |

- **Defaults.** With nothing saved for a role, today's rules stay: personal / OAuth tokens get
  `exos_role_token_scopes(role)` (docs/developer-platform.md), and org API keys keep their creator's dashboard reach
  (the ceiling). So an existing finance member's key that refunds keeps refunding until the owner says otherwise.
- **One setting for both.** Once the owner saves a role's set, it holds for that role's tokens **and** keys.
- **At request time.** exos-api and exos-mcp resolve a key through `exos_api_key_auth` and a token through
  `exos_api_token_auth`; both narrow the stored scopes to the creator's (or user's) live role's set in the org, and
  the SQL API write functions check the same. Lowering a role takes effect on every existing key and token at its
  next request; ticking a box again gives back what each key was created with, never more.
- **At creation.** A member can't create (or widen) a key or token beyond their role's set.
- User scopes (`me:*`, the fan API) are about the token's own user and are not org-configurable.

API: `GET /v1/role-api-scopes`, `PUT /v1/role-api-scopes/:role` (`org:admin`, a key made by the owner).

## 2. Venues, booking requests and co-hosted events

**How venues are modelled.** A venue (`exos_venues`, from booking #67) belongs to one organization, with rooms.
`relationship` is `owned` (the org runs it), or `rented` / `partner` (a promoter's own record of a room it books).
Events link one by `exos_events.exos_venue_id`; `venue_name` / `venue_location` / `venue_address` are free-text
labels with no owner and are not gated. Ownership is self-declared: Exos doesn't verify that an `owned` venue is
really the org's.

**The gate.** Another org's `owned` venue refuses, with `venue_approval_required` (the API answers 403 with
`venue_id` and `request_endpoint: POST /v1/venue-requests`):

- an event linked to it (dashboard, API, an event made from a template, a duplicate);
- a hold night there (dashboard and `POST /v1/holds`);
- an event template naming it.

A promoter's own `rented` / `partner` record of the venue counts too once **the promoter** links it
(`listed_venue_id`). Exos never links a record for anyone: since any org can call a venue `owned`, a name match is
only a suggestion (Venue requests → Sent, or `GET /v1/venues/:id/listing-suggestions`), listing every candidate with
its `verified` flag (set only by a platform admin through `exos_admin_set_venue_verified`, never by an org, its API
keys or the service role; shown, never required; any other change of the venue's name, address, relationship or
org clears it, including one through the API). Only venues that take requests are suggested or can be linked, as in the directory. The promoter picks one (`PUT
/v1/venues/:id/listed-venue`, `exos_venue_link`); a link it made can only be removed by a platform admin, so it can't
be dropped to get around the gate. A squatter declaring a same-named "owned" venue gates nobody's records. A venue
org can stop taking requests per venue (`accepts_requests`).

**The request.** The promoter finds the venue (Venue requests → Sent → search, or `GET /v1/venue-directory?q=`)
and asks for a date, optionally a room and start time (`POST /v1/venue-requests`). One pending request per
venue, room and date; 50 pending and 30 a day per org. The venue's owners and managers see it under Venue
requests → Received (content staff see the table) and:

- **approve** as a **hold** on their calendar, or as a hold converted into a **draft event** of their own at the
  venue (`POST /v1/venue-requests/:id/approve`, `create: hold | event`);
- or **decline** with a reason. The promoter may **withdraw** while it is pending.

**The grant.** Approving names what the promoter may do on that one event (`exos_event_partner_grants`):
`events:read`, `events:write` (name, description, summary, image, video), `tickets:read` (sold and checked in per
ticket type, no attendees) and `finance:read` (gross per ticket type). Default: `events:read`, `events:write`,
`tickets:read`. Money (`gross_cents`) needs `finance:read` in the grant **and** in the promoter's key (exos-api
passes the key's effective scopes to the SQL). With `create: hold`, the grant starts when the venue converts the hold. The venue changes or
revokes it at any time (Venue requests → Shared events, `PATCH` / `DELETE /v1/partner-grants/:id`); a revoked grant
stops the promoter's next request (404). The promoter works on it through `/v1/cohosted-events`; each route needs
its scope both in the promoter's key and in the grant (`grant_scope_required` otherwise). Edits need a key whose
creator is an owner or manager of the promoter org now, and each is logged with that member
(`exos_cohost_event_edits`, readable by both orgs).

**Money.** The event is the venue org's: it sells, refunds and pays out exactly like its other events, and
settles with the promoter through offers and settlements (#71). A grant never carries refunds.

## 3. Partner presale

Distribution partners (docs/partner-sales.md) were refused a ticket type in a running member presale
(SIM-PARTNER-13). That is now the default, `block`; `allow` lets them sell it during the presale.

- Organization setting: Settings → "Partners during member presales" (owner), `PUT /v1/partner-presale`.
- Per event: the event editor, below the partner switches (owners and managers), `PUT
  /v1/events/:id/partner-presale` with `block`, `allow` or `inherit`.
- Exos's own checkout is unchanged either way: a buyer on the event page still needs a membership during the
  presale (`exos_member_checkout`). A partner's buyer isn't a known member, so gets no member price.
