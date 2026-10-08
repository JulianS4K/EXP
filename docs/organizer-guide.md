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
  *adds* tax, the storefront shows the price including that tax. Buyers pay no service fee. Your
  first 6 months are free: no Exos fee, only card processing on Exos sales. After that, Exos
  takes 3% of every sale from your payout, and card processing is yours, as with any card sale:
  a 40.00 ticket sold on Exos pays you 37.34 (3% plus Stripe's 2.9% + 30¢). On a marketplace the
  card was charged there, so a 40.00 ticket pays you 38.80 (marketplace prices are raised to cover
  their own seller fee).
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

**Store page** (the "Store page" section of create and edit). Everything in it is optional and
shows on your event page:

- **Summary:** one line (160 characters) under the title. Search results and link previews use it.
- **About:** the long description. It takes simple formatting: `**bold**`, `*italic*`,
  `[link](https://…)`, `- ` lists, `## ` headings and `> ` quotes. Use **Preview** to check it.
  Links must be `https://` or `mailto:`. Raw HTML shows as plain text, and images go in the gallery.
- **Lineup:** each act's name, role (headliner, support, DJ, host), set time and a short bio.
- **FAQ:** questions and answers, shown as a list buyers can expand.
- **Gallery:** up to 12 extra photos (upload them or paste `https://` links). The cover image
  stays the main one.
- **Video:** a YouTube or Vimeo link. It plays on the event page in privacy-enhanced mode.
- **Age limit** (all ages, 16+, 18+, 21+) shows as a badge. Marketplace listings and Google use it
  too.
- **Refund policy** and **Good to know** (dress code, bag policy, re-entry) show together near
  the bottom. The refund policy is what you tell buyers. Refunds themselves are still yours to
  issue from the event dashboard.

*This section appears once the store-page database update is live. Until then the form shows the
plain description box.*

**Attending** (the "Attending" section of create and edit):

- **In person, online or hybrid.** An online event doesn't need a venue (it shows as "Online"),
  gets no map, and the event page says ticket holders get the join link on their ticket.
- **Join link** (online and hybrid): the stream, Zoom or Discord address, plus optional joining
  instructions. It is private:
  - only people holding a valid ticket see it, on their ticket in the app;
  - it moves with the ticket when it's transferred, and a refunded or voided ticket loses it;
  - it never goes in an email or on the event page.
  - Switching the event to in person hides the link but keeps it, so switching back restores it.
    To remove it, empty the field while the event is online.
  - **Show the link** holds it back until 1 day, 2 hours, 1 hour or 15 minutes before the start, or
    the start itself. You and your staff always see it, so you can test it.
- **What to bring:** a short note ("Photo ID. Bags no bigger than 12 × 12 in.") on the event page,
  the ticket and the reminder email.
- **Hide from search engines:** keeps the event out of Google, the sitemap, the Google events feed,
  the ad catalog and AI-assistant search. Anyone with the link can still open it and buy, so it
  isn't a password. Use it for private parties and tests.

*This section appears once its database update (`20261005090000`) is live.*

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
- Tracking pixels (Settings → Marketing & socials): Meta, GA4, TikTok, Reddit, Snap and X. They
  only load after the visitor consents: GA4 needs analytics consent, the others advertising
  consent, and browsers that send Global Privacy Control get no advertising pixels unless the
  visitor turns them on. Settings checks each id's format before saving. X needs one event id per
  conversion (view content, checkout, purchase) from X Events Manager.
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
- **Sources report** (Marketing tab; owner, manager and finance): paid orders, tickets and gross
  grouped by UTM source / medium / campaign, promoter code and the ad platform the buyer clicked
  through from (Google, Meta, TikTok, Reddit, Snap, X, Microsoft, read from the click id), with
  everything else under "Direct / unknown". Switch the grouping to one dimension at a time, and
  export the full breakdown as CSV. Tag your ad links with `utm_source`, `utm_medium` and
  `utm_campaign` so they show up here. Free claims aren't in it.
- **Comps:** tickets to a list of emails, with an optional org-wide **comp budget**. People without
  an account get a claim-by-email link. Comps respect capacity, shared quotas and seats held in
  other people's carts; a full tier shows up as "sold-out" for that recipient.
- **Waitlist:**
  - When seats free up, the next people in line automatically get a code valid for 48 hours.
  - A group of 3 waits until 3 seats are free, and nobody behind them jumps ahead.
  - **Offered seats are reserved.** Other buyers can't take them while the code is live.
- **Announcements** to ticket holders. **Reschedule** (holders are emailed the new date; see
  [Changing the date](#changing-the-date)).
  **Reminders:** automatic 24 h and 2 h before start, plus a manual "send now" limited to once
  every 6 hours.
- **Release policy:** whether holders can give back a *free* ticket themselves, and up to how many
  hours before the start. Freed seats go to the waitlist.

### Changing the date

Move an event from **Edit event** (change the start and save) or from **Reschedule** on the event
dashboard's settings tab. Every ticket holder is emailed the old and new date and time (in the
event's time zone); their tickets stay valid.

- **When you're asked about refunds.** If tickets are out and the event moves to another day (in its
  own time zone) or its start moves by more than 3 hours, the save asks **"Offer refunds to ticket
  holders?"**. It's checked by default; untick it to only send the new date. A smaller move (say
  8 pm to 9 pm the same night) just saves and emails holders. A plain save can't skip this: the
  database refuses a big date change on a sold event unless it goes through the reschedule step.
- **The deadline.** Holders can ask for a refund until the deadline. It defaults to two weeks from
  the change or a day before the new start, whichever comes first (until the start if that's less
  than a day away). You can change it; it has to be in the future and no later than the new start.
- **What buyers get.** Refunds are self-serve and automatic, with no approval step:
  - A ticket paid through Exos checkout: its price back, tax included, on the card that paid.
    Add-ons (parking, merch) are refunded only with the order's last ticket.
  - A free ticket or comp: **Release my ticket** (it's voided, the seat goes back on sale).
  - A ticket bought on a resale marketplace (StubHub, SeatGeek, ...): the email says refunds go
    through that marketplace. Exos doesn't refund those.
  - A ticket someone was given: only the person who paid can refund it, since the money goes back
    to their card. The refund voids the ticket, and the holder's email says so.
  - Not eligible: tickets already checked in, bought after the change, or on an event you've
    since cancelled (cancelling refunds everyone from the refund panel).
- **How they ask.** Signed in, from **My Tickets**. Without an account, from the link in their email
  (one per ticket; it works only for that ticket and stops working if you change the date again).
- **Who pays.** Refunds come out of the event's money, like refunds you issue yourself: Stripe pulls
  the ticket's share back from your connected account and Exos returns its fee in proportion
  (unless the platform is set to keep it, `EXOS_REFUND_KEEP_PLATFORM_FEE`).
- **Tracking it.** **Date changes and refunds** on the event dashboard, next to the refund panel,
  lists every date change and, for the latest one, how many refunds were asked for, how much went
  back, free tickets given back, and how many tickets can still ask.
- **Moving it again** closes the earlier offer. Offer refunds again on the new change if you want
  holders to keep the option.

## 5. At the door (`/checkin/:eventId`)

- Staff with the **scanner** role scan the attendee's live QR code. It changes every 30 seconds
  and is signed per ticket, so screenshots and forwarded codes stop working quickly.
- The server checks every scan: wrong event, already used, refunded or mid-transfer are all
  refused and logged.
- **Offline mode:** download the roster before doors open. The device can then admit tickets
  without a connection and syncs when it's back online.
  - Anything the server rejects on sync is flagged to staff (see **Offline conflicts** below).
  - **Sign out of shared devices after the event.** Signing out clears the cached roster.
- Doors can't be scanned before the event's doors time. An owner or manager can open a 3-hour
  test window for rehearsals. Test scans check the ticket ("Test scan OK") but don't use it up, so
  the holder still gets in at doors.

### Check in by name

Staff can check someone in without scanning: find them in the door list and tap **Check in by
name**. It's for a dead phone, a ticket nobody has claimed yet, or anyone else staff can see on the
list. It works for every active ticket of the event, claimed or not.

- **Who may do it** is set per event in **Edit event → Venue & seating → Check in by name at the
  door**:
  - **All door staff** (the default): owners, managers, and scanners assigned to the event.
  - **Owners and managers only**: scanners see **Ask a manager** instead of the button.
  - **Off (QR code only)**: nobody sees the button. An owner or manager can still type a full pass
    ID as a manual override, with a reason.
- Search a **name**, an **email**, or the last 6 characters of the pass ID. Tap **Check in by
  name** on the right row. The door shows the name and ticket type. Add a note if you like (for
  example "checked ID"), then tap **Check in**.
- **Tickets nobody has claimed yet.** Some tickets go to an email address with no Exos account:
  marketplace sales (StubHub and the rest), guest checkout, and comps or box-office tickets sent by
  email. Until the buyer claims the link, the ticket is held on your org. The list shows the buyer's
  name (when the order had one), a small "Not claimed yet" note, and a masked email like
  `j***@gmail.com`. Door devices never get the full address. Checking one in cancels the claim
  link, so nobody can claim the ticket after the buyer is inside. The ticket stays on your org,
  marked used.
- A ticket its holder is sending to a friend (a transfer waiting to be claimed) can't be checked in
  by name: it may already belong to the friend. The holder cancels the transfer, or the friend
  claims it and shows their code.
- Used, refunded, wrong-event tickets and doors not open yet are refused the same as a scan.
- It works offline too. The check-in is queued and uploaded when the device is back online. If the
  server refuses it then (for example, the ticket was used at another door), the refusal is flagged
  the same way as other offline conflicts.
- The scan report counts check-ins by name, and lists each one with verification `name` and the
  note.

### Check-in lists and re-entry

**Re-entry is off unless you turn it on.** By default every ticket gets in once, at any door, and a
second scan says **Already used**. Nothing on this page is required: an event with no lists works
exactly like that.

Add lists in **Edit event → Venue & seating → Check-in lists** when the door needs more than that:

- **A list is a gate or an area**, for example *Main door*, *VIP deck* or *Late entrance*. Give it
  a name and pick the ticket types it admits (all of them, or some). A ticket type that isn't on the
  list is refused at that list's door: "This ticket type isn't on this check-in list".
- **Opens / Closes** (optional) limit when the list admits people, in the event's time zone.
  Outside that window entries are refused ("isn't open right now").
- **Allow re-entry** (off by default). When it's on, staff scan people **out** when they leave and
  back **in** when they return:
  - The scanner shows an **Entry / Exit** switch for that list. Use Exit when someone leaves.
  - A second entry without an exit in between is refused: **Already inside**. Scan them out first.
  - Each list keeps its own in / out state, so a guest inside the main room can still enter the
    VIP deck once.
  - Exits are refused on a list without re-entry, and when the device isn't scanning for a list.
- **Ticket counts don't change.** The first entry marks a ticket used, as always; leaving and coming
  back doesn't. "Checked in", sold and no-show numbers still count tickets that came in, not people
  inside right now. The scan report also shows re-entries and exits.
- **On the door device** each scanner picks its list at the top of the scanner (the choice is
  remembered on that device). "Any ticket, no list" admits every ticket once, as without lists.
- Check in by name follows the same list: wrong ticket type, closed window and "Already inside" are
  refused the same as a scan. With Exit selected, the button reads **Check out by name**.
- Deleting a list doesn't remove its past check-ins; the scan report keeps the list's name.

### Offline conflicts and sync health

- A scan admitted while the device was offline is uploaded later. If the server refuses it then
  (the ticket was refunded, was transferred after the list was downloaded, the list doesn't admit
  that ticket type, doors weren't open, or the upload came more than 48 hours after the event
  ended), the person is still **recorded as attended**, marked as an **offline conflict** with the
  reason. The ticket itself isn't changed, so a transferred ticket's new holder can still get in.
  A true double entry ("Already used" at another door) is only logged as a refusal.
- The scanner's **Sync health** panel shows how old the offline list is, how many scans are waiting
  to upload and since when, the last successful upload, how far the device's clock is from the
  server's, and the conflicts from the last uploads. **Re-download** and **Upload now** are there
  too.
- If the server says the signed-in account may no longer upload (for example it was removed as
  door staff), the device stops retrying and says **Not authorized to upload N scans**. The scans
  stay on the device: hand it to a manager, or sign in as door staff for the event and tap
  **Upload now**. Signing out while scans are waiting asks for confirmation first.
- The offline list is encrypted on the device with a key that can't be copied off it. Browsers that
  can't do that (some private windows, very old browsers) keep it unencrypted and the scanner says
  so. Signing out deletes the list and the key.
- The **scan report** lists offline conflicts separately, with the reason, the list and the device.
- While online, the door refreshes its list every minute with only what changed since the last
  refresh, and downloads the whole list every 10 minutes (or when you tap **Download for offline**).

### End-of-night door summary

The event report's **Overview** has an **End-of-night door summary** (owners and managers also get a
**Door summary** button on the scanner). It shows:
- checked in out of sold, the show-up rate and no-shows;
- first and last entry, the busiest 15 minutes, and entries per hour in the event's time zone;
- the breakdown by ticket type, list, staff member and how people got in (QR code, by name, manual);
- what needs a look: manual overrides and their reasons, offline admissions refused on upload, and
  scans refused at the door by reason;
- on events with a re-entry list, how many people are inside now.

**Copy** puts it on the clipboard as plain text, for a message to the team or the venue. **CSV**
downloads the same numbers. It has no buyer names or emails. Owners, managers, finance and the event's
door staff can see it.

## 6. After a sale

- **Refunds** are issued in Stripe:
  - A **partial** refund keeps the tickets valid.
  - A **full** refund voids them and returns the seats.
  - Automatic refunds (for example, an order that sold out between checkout and payment) come out of
    the organizer's balance, not the platform's.
- **Disputes** void the tickets.
- **Transfers:** a holder sends a ticket to an email address. The recipient claims it, the barcode
  is reissued, and the sender's old code stops working. Only one transfer can be pending per ticket.

## 7. Money and payouts

Owners, managers and finance see money; other roles don't get these screens (and the database refuses
them anyway).

- **Per event** (`/dashboard/event/:eventId`, Overview → **Money**): a settlement summary.
  - **Exos checkout:** tickets sold, gross, tax (included in the price), refunds, the Exos fee, card
    fees, your net (gross less the application fee, which is the Exos fee plus the card-fee estimate),
    and your net after refunds (a refund returns the fees in proportion). Card fees show Stripe's
    **actual** fee once it's recorded for an order, otherwise the **estimate** taken at checkout; the
    label says which (or both, when the orders are mixed).
  - **Marketplaces:** tickets, proceeds (after the marketplace's own fee), the Exos fee, your net, and
    how much of it has been paid out. Cancelled orders aren't counted.
  - **Promoter commissions** accrued for the event, and the organizer net for all channels before and
    after them.
  - **Orders CSV:** one row per order (Exos checkouts, then marketplace orders) with the same columns.
  - Exos checkout money is paid out **by Stripe, directly to your connected account**, on Stripe's
    schedule. Exos never holds it.
  - Orders from before fee recording started have no fee split; the summary says how many and leaves
    them out of the fee and net totals.
- **Per org** (`/orgs/:orgId/payouts`, the **Payouts** button on the dashboard or the tab in org
  settings): what Exos pays you for **marketplace** sales, after the marketplace pays us
  (`docs/payouts.md`). Each payout shows its status (planned, sending, sent, failed, cancelled), the
  orders it covers and any clawbacks (a cancelled order that was already paid, taken off a later
  payout). **Export CSV** gives one row per payout line. Accounting-software export (QuickBooks, Xero)
  isn't built.
- Both screens are read-only. If your database doesn't have the money views yet, the Money section and
  the Payouts page stay hidden or say they aren't available.

### Receipts, invoices and credit notes

- Every paid order gets an invoice numbered per organization (`INV-000001`, …). Buyers see it as a
  **receipt** in My Tickets → Receipts, and can print it or save it as a PDF. Free orders get none.
- A refund, full or partial, gets a **credit note** (`CN-000001`, …) with its share of the tax. The
  original receipt never changes; it lists its credit notes and the balance.
- **Settings → Legal & invoices** (owner, manager, finance): the legal name, address, tax ID and footer
  printed as the seller. Fill them in before you sell; each receipt keeps the details it was issued with.
- **Money → Receipts** on the event report lists each order's invoice number and links to it; the Orders
  CSV has an `invoice_number` column. Details: `docs/invoices.md`.

## Not built yet (tracked in `KANBAN.md`)

- A screen for managing quotas.
- A map on the storefront page. Event pages already have directions, and a map when the key is set.
- SEO landing pages.
- Marketplace distribution (see the roadmap and the read-only rule).
