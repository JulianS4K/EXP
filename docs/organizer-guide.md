# Organizer guide

What an organizer does in Exos, step by step, and what happens behind each step. Use it for
support, for demos, and as a script for end-to-end testing. Paths are relative to `/bridge/`.

## 1. Get set up (`/onboarding`)

A five-step wizard:

1. **Welcome.**
2. **Org:** name the venue or promoter brand. The creator becomes the **owner**.
3. **Brand:** logo and colors for the public storefront at `/o/:slug`.
4. **Event:** the first listing.
5. **Done.**

Needs a signed-in account. Buying or holding tickets also needs a **confirmed email**.

**Team** (`/orgs/:orgId/members`): invite by email with a role.

| Role | Can |
|---|---|
| owner | everything, including payments and the comp budget |
| manager | events, comps, waitlist, reminders, releases |
| finance | analytics and money reports |
| scanner | door check-in and the offline roster |
| content | copy and media |

## 2. Get paid (`/orgs/:orgId/settings`)

**Connect Stripe** opens Stripe's Express onboarding. Payouts go straight to the organizer's
account; the platform keeps its fee (5% by default). The button appears only once payments are
switched on platform-wide (`docs/payments-go-live.md`). Until then, **free events work fully and
paid events can't be sold.**

## 3. Create and run an event

**Create** (`/create-event`) and **edit** (`/edit-event/:eventId`):

- Date, doors, start and end times, and the venue.
- Performers and artist links.
- **Tiers:** price, capacity (0 = unlimited), sales window, hidden or public.
- **All-in pricing:** buyers always see the full price they'll pay. If a tier has a tax rule that
  *adds* tax, the storefront shows the price including that tax. Buyers pay no service fee; the
  platform fee comes out of your payout.
- **Scheduled prices** (early-bird → regular → last-minute). Buyers are charged the price that's
  live when they check out, which is the one the storefront shows.
- **Vouchers:**
  - **One use = one ticket**, so a 3-use code covers one order of 3 or three orders of 1.
  - A voucher can pin a price, restrict itself to one tier, be reserved for one email, expire,
    and **sell past sold-out**. Vouchers replace the old storefront discount-code box, which was
    removed because checkout never applied it.
  - **Hidden tiers** can only be bought with a voucher restricted to that tier.
- **Add-ons**, **tax rules**, and **purchase limits** (per order / per account). Limits apply when
  seats are reserved, not just at payment.
- **Shared capacity (quotas):** one pool several tiers draw from, e.g. a 300-person room split
  into GA and VIP. *There's no screen for this yet; support sets it up in SQL.*

**Recurring and timed-entry events** (`/dashboard/event/:eventId/series`): clone an event, with its
tiers and discount codes, into a series of dates.

**Promote** (`/dashboard/event/:eventId/promote`, `/orgs/:orgId/promote`):

- **Promoters** (`/orgs/:orgId/promoters`).
  - Add each promoter once and send them their private portal link. It shows their tickets and
    sales and has their kit.
  - Pause a promoter, or make a new link if one leaks.
  - The leaderboard ranks everyone.
- **Per-event campaigns.** Name a campaign and that becomes a promoter code.
  - Send each promoter their **kit link** (`/promoter/:eventId/:code`, no login needed). It gives
    them a buy-now link with the cart pre-filled, a story poster, and tracked links for Instagram,
    TikTok, WhatsApp and text.
  - Every ticket sold through their links, free or paid, shows under their code in the Sales
    report.
  - Fans who share after buying pass the promoter's credit along.

- Share links and the venue embed (`/embed/event/:eventId`).
- Tracking pixels, which only load after the visitor consents.
  - They only see your public pages: the event page, your storefront and your profile.
  - They never see buyers' tickets, accounts or the door scanner, and never another
    organizer's pages.
  - **Google Analytics 4:** in your GA4 property, open Admin → Data streams → Enhanced
    measurement and turn off "Page changes based on browser history events". Otherwise GA4
    logs page views for the pages it isn't meant to see before Exos drops it.
- *The embed and the pixels need the Terminal-2 security-header fix to be deployed (see
  `KANBAN.md`).*
- **Instagram and Facebook.** Buyers who tap your bio link can buy inside the app.
  - Google sign-in doesn't work in those in-app browsers, so buyers use email or Apple.
  - A banner offers to open the page in their browser if they want Apple Pay.

## 4. While it's on sale (`/dashboard/event/:eventId`)

- **Analytics:** sold, used, no-show and released counts; sales by day in the event's timezone;
  breakdowns by tier, promoter and channel; scan and reject rollups. CSV export.
- **Comps:** tickets to a list of emails, with an optional org-wide **comp budget**. People without
  an account get a claim-by-email link. Comps respect capacity, shared quotas and seats held in
  other people's carts; a full tier shows up as "sold-out" for that recipient.
- **Waitlist:**
  - When seats free up, the next people in line automatically get a code valid for 48 hours.
  - A group of 3 waits until 3 seats are free, and nobody behind them jumps ahead.
  - **Offered seats are reserved.** Other buyers can't take them while the code is live.
- **Announcements** to ticket holders. **Reschedule** (holders are notified of the changed fields).
  **Reminders:** automatic 24 h and 2 h before start, plus a manual "send now" limited to once
  every 6 hours.
- **Release policy:** whether holders can give back a *free* ticket themselves, and up to how many
  hours before the start. Freed seats go to the waitlist.

## 5. At the door (`/checkin/:eventId`)

- Staff with the **scanner** role scan the attendee's live QR code. It changes every 30 seconds
  and is signed per ticket, so screenshots and forwarded codes stop working quickly.
- The server checks every scan: wrong event, already used, refunded or mid-transfer are all
  refused and logged.
- **Offline mode:** download the roster before doors open. The device can then admit tickets
  without a connection and syncs when it's back online.
  - Anything the server rejects on sync is flagged to staff.
  - **Sign out of shared devices after the event.** Signing out clears the cached roster.
- Doors can't be scanned before the event's doors time. An owner or manager can open a 3-hour
  test window for rehearsals.

## 6. After a sale

- **Refunds** are issued in Stripe:
  - A **partial** refund keeps the tickets valid.
  - A **full** refund voids them and returns the seats.
  - Automatic refunds (for example, an order that sold out between checkout and payment) come out of
    the organizer's balance, not the platform's.
- **Disputes** void the tickets.
- **Transfers:** a holder sends a ticket to an email address. The recipient claims it, the barcode
  is reissued, and the sender's old code stops working. Only one transfer can be pending per ticket.

## Not built yet (tracked in `KANBAN.md`)

- A screen for managing quotas.
- A map on the storefront page. Event pages already have directions, and a map when the key is set.
- SEO landing pages.
- Marketplace distribution (see the roadmap and the read-only rule).
