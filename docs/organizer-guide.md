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
  *adds* tax, the storefront shows the price including that tax. Buyers pay no service fee.
  **Free tier:** an event with a max capacity of 150 or less (its overall cap, else its capped
  ticket types, a table counting its party size) pays no Exos fee at all, ever; only card
  processing. It is also never listed on resale marketplaces or S4K. An event that sells past 150
  anyway (a voucher that sells past sold-out, comps, the box office) leaves the free tier: the order
  that crosses 150 and every one after pay the normal fee. Bigger events: your
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
- **Resale (Edit event → Marketplaces → Resale):** resale marketplaces (StubHub, SeatGeek, Vivid,
  Gametime, TickPick, GoTickets, Ticket Evolution) and the S4K network are only for events over the
  free tier (max capacity over 150), and only once an owner or manager **opts in for that event**:
  read the text, tick the box, **Opt in to resale**. Exos records who opted in, when, the text's
  version and the max capacity then. **Withdraw** takes it off at once: listings come down, their
  seats come back to your checkout. If the max capacity later drops to 150 or less the opt-in ends
  by itself, and you opt in again if it goes back over. Until then marketplaces you tick wait.
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
  the bottom. The refund policy is what you tell buyers, and it sets when they can **ask for a
  refund** from their ticket: never ("all sales final"), up to 7 days or 24 hours before the start,
  or until the start (also the rule when no policy is set). Only the person who paid can ask, and
  not for a comp, a marketplace ticket or one already scanned in. Requests land in **Refund
  requests** on the event report: **Refund** sends the usual Stripe refund (the ticket stops
  working) and **Decline** sends the buyer your note. Nothing is refunded without you.

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
- **Sold elsewhere** (Overview tab; owner, manager and finance): tickets you sold outside Exos, so one
  report covers every channel. Exos lists them beside its own numbers and never adds them in: they
  are not in "Tickets sold", revenue, payouts or check-ins. The tile under "Tickets sold" shows the
  "+N sold elsewhere" count, and so does the dashboard. Other staff can't see these counts, and the
  public event page only ever gets the total for a published event.
  - **Add a count:** where it sold ("Box office", "Consignment"), tickets, gross, currency, and
    optionally capacity and a note. Saving the same name again replaces its numbers; it doesn't add
    to them.
  - **Import a sales CSV:** pick the export from DICE, RA, Posh, Shotgun, Ticketmaster, AXS or any
    other platform. Exos guesses the platform and which column is the ticket type, tickets sold,
    gross (or price each), capacity, currency, event and order status. Change any of them, check the
    preview, and import. The file can have one row per ticket type or one row per order: rows are
    added up per ticket type. Rows marked refunded or cancelled are left out. If the file covers
    several events, choose which one is this event. Any error lists its line, and nothing is saved
    until the file is clean (2 MB and 2,000 rows at most).
  - **Importing again replaces** that platform's numbers. It never adds them twice, so re-importing
    the same file changes nothing. Delete an entry to undo a wrong file.
  - At most 20 entries per event and 50 ticket types per import. Amounts in different currencies
    are totalled separately.
  - Integrations can do all this through the API (`/developers` → Sales counts, `finance:write`).
  - This is separate from **Import attendees** (below), which brings in people for the door and has
    no amounts.
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

### Your website

**Org settings → Website**:

- **Sections**: your storefront (`/o/<your slug>`) is built from sections you pick and order: a banner (title,
  subtitle, image, button), the upcoming events grid, about, text, FAQ, photos, link buttons and a text-list
  sign-up. Text takes simple markdown; links must be https.
- **Your own domain**: add `tickets.yourvenue.com`, set the CNAME and TXT records shown, then **Check**. Once
  verified (and the platform operator has added it for HTTPS), your domain opens your storefront.
- **Widgets** for any other site (WordPress, Squarespace, Webflow): an event list, a month-by-month calendar, and per
  event (Promote page) a buy button or a ticket box with checkout on your own page.

### Promo links

**Event report → Marketing → Promo links**: one link per place you post it (an Instagram story, an SMS blast, a
partner's newsletter). Each link has a name, a channel, a **limit** (tickets), an optional discount and an expiry.
It opens your event with the code already applied; when the limit is reached or it expires, the code stops working.
Visits and redemptions show per link, and sales are attributed to the channel under *Sales by source*.

### Discovery listings

**Promote page → Discovery listings** shows every place fans can find the event, with a status per channel
(mig `20261029130000_exos_discovery_publishing.sql`; channel list in
`supabase/functions/_shared/discovery/channels.ts`, mirrored by the `exos_discovery_channels` seed).

- **Automatic (feeds):** Google Search & Maps (`exos-google-feed`, see [`google-events.md`](google-events.md)),
  calendar feeds (`exos-calendar`, [`calendar.md`](calendar.md)) and ad catalogs (`exos-catalog-feed`,
  [`marketing-catalog.md`](marketing-catalog.md)). The status is **Live** when the event is in that feed and
  **Not listed** with the feed's own reason otherwise ("hidden from search by the organizer", "no time zone", "no https
  image"…). Nothing is stored: Google uses `feedBlocker`, the catalog `catalogBlocker`, and the calendar asks
  `exos_calendar_public_feed` whether the event is in the org's `.ics`. Live means *in the feed*: Google reads it only
  once Exos is in its events ticketing program, and ad platforms only once the organizer adds the catalog URL.
- **Calendars and listings sites (manual):** DoNYC, Time Out New York, CitySpark local calendars, Resident Advisor,
  Oh My Rockness, Edmtrain, Meetup, Songkick, Bandsintown. **Queue for submission** puts the event in the operator's
  queue; a person submits it on the channel's form and records **Submitted**, **Live** (with the listing's URL) or
  **Rejected** (with the reason). A live listing can later be marked **Removed**; rejected or removed ones can be queued
  again. Withdraw takes a queued event back out. Only upcoming published events can be queued.
- **Free-tier cap:** an event whose max capacity (`exos_event_max_capacity`) is at or under the free-tier cutoff
  (`exos_platform_settings` `free_tier_max_capacity`, 150 when the row is missing) can use **at most 5 manual
  channels**. A channel counts once queued and not withdrawn (rejected and removed ones still count; queueing them again
  doesn't add one); feeds never count. The 6th is refused with a message saying so; withdrawing a queued one frees the
  slot. An event with no capacity set at all counts as small.
- **Manual minutes (discovery pilot):** when recording submitted, live or rejected, the operator enters the minutes
  that step took (0-600, optional). They add up per record; `exos_discovery_minutes(org, since, until)` totals them per
  event (with the minutes per channel) and per org, with minutes per event. The operator screen shows the totals; the
  Promote page shows the event's total.
- Some channels only take the organizer's own account (RA, Meetup, Songkick, Bandsintown): the organizer submits and
  records **I submitted it** / **It's live** on the same screen.
- Each channel's "How to submit" link was looked up on 2026-10-29; links marked *not verified* point at the site, not
  a submission page.
- **Tracking:** the ticket link given to each channel is the event page with `utm_source=<channel id>`,
  `utm_medium=listing`, `utm_campaign=discovery`, so its sales show under *Sales by source*. Every ticket link
  discovery shows or copies comes from one function, `discoveryTicketLink` (`_shared/discovery/copy.ts`), so imported
  link-out events (buy button on the organizer's own Eventbrite, Luma or Posh checkout) can point it at that checkout.

| Channel | Kind | Region | Submission path (verified?) |
|---|---|---|---|
| Google Search & Maps | feed | global | `exos-google-feed` (Google program not joined) |
| Calendar feeds | feed | global | `exos-calendar` org / venue `.ics` |
| Ad catalogs (Meta, TikTok, Google Merchant) | feed | global | `exos-catalog-feed` (organizer adds the URL) |
| DoNYC | manual | NYC | donyc.com/p/how-to-nyc: register, then email for event-editing rights (yes) |
| Time Out New York | manual | NYC | timeout.com/newyork/get-listed: email the section editor (yes) |
| CitySpark calendars | manual | US | CitySpark help "How to submit an event"; one submission reaches every CitySpark calendar in the area (yes) |
| Resident Advisor | manual | global | support.ra.co "Submitting events", promoter account (yes) |
| Oh My Rockness | manual | NYC | ohmyrockness.com, no form found (no) |
| Edmtrain | manual | US | edmtrain.com "Add Event" (sign-in) (no) |
| Meetup | manual | global | the organizer's own group (no) |
| Songkick | manual | global | Songkick help: "Add an event" footer link (yes) |
| Bandsintown | manual | global | Bandsintown for Artists "Add an event", per artist (yes) |

**Why Edmtrain and Meetup aren't automatic:** Edmtrain's public API is read-only (event and location listings with a
client key) and takes no submissions. Meetup's GraphQL API has `createEvent`, but only for an organizer of the group
with Meetup Pro and an approved OAuth client, and it would be a new third-party write. The read-only rule
(`CLAUDE.md`) allows writes only to the organizer's own Eventbrite and Luma, so a Meetup adapter needs the operator's
decision first; until then both are manual.

**Operator queue** (`/admin/listings`, platform admins only, `exos_is_admin`): queued / submitted / live / rejected
tabs across every org, filterable by channel. Each item has the copy-ready details (title, date and time in venue
time, venue, address, all-in price range, the channel's tracking link, image, plain-text description) with copy
buttons, a link to the channel's submission page, and the actions above.

Access: owners and managers queue, withdraw and record results; finance can see the statuses; scanners can't.
RPCs: `exos_discovery_event_channels`, `exos_discovery_queue`, `exos_discovery_withdraw`,
`exos_discovery_set_status` (with minutes), `exos_discovery_queue_list` (admin), `exos_discovery_minutes`. Tests: `tests/exos/test_discovery_publishing.sql`,
`src/lib/discovery/*.test.ts`.

### Tracking links and the weekly channel report

**Promo links → Make a link per channel** lists one tracking link per channel (Instagram, Facebook, TikTok, X,
email, text, WhatsApp, partner sites, flyer / QR, Meta and Google ads), with an optional campaign name. A
tracking link is the event page tagged with `utm_source` / `utm_medium`: no code, no limit, and guests can buy
without signing in (a promo link's code needs an account). Use a promo link when you want a deal or a cap.

**Event report → Overview → Channels** shows every ticket by where it sold, for the last full week (Monday to
Sunday, UTC) and to date (mig `20261029120000`, `exos_event_channel_report`). Owner, manager and finance only.

| Channel | Where the count comes from | Gross / fees / net |
|---|---|---|
| Your Exos links | Paid orders: the promo link's channel, else the `utm_source` (aliases merged: `ig` → Instagram), else the promoter code, the AI assistant, the ad click id (gclid → Google, fbclid → Meta); otherwise **Direct / unknown**. Free claims: the `utm_source` they came with, else the promoter | Gross is what the buyer paid less refunds. Channel fees = card processing; the Exos fee is its own column (none in your free months). Older orders without the fee split: fees "not reported" |
| Box office | Tickets staff minted with a price | Gross = price, no fees |
| Marketplaces (StubHub, SeatGeek, Vivid, …) | Marketplace orders (cancelled ones left out) | The listed price, the marketplace's fee and the payout, as the marketplace reports them (some report only the payout) |
| Eventbrite, Luma, pretix, hi.events | The attendees their syncs bring to the door list; without a sync, the sold count from the ticket-type link (no dates, so "to date" only) | Not reported: those syncs don't read prices or fees |
| Comps (not sales) | Comp batches, free staff issues, referral rewards, guest-list entries (+ plus-ones) | — |
| Imported lists (not sales) | CSV door imports (Posh and others): other-platform attendees; the file has no prices | — |

Exos never estimates a platform's fee: where a channel doesn't report one, the cell says **not reported** and net
stays blank. Totals add the figures that were reported and say how many tickets were left out. Fee rules you pass
on or absorb (`exos_order_fees`) aren't in the report yet; they join when that change lands.

**The Monday email** (`org-channel-report`) has the same numbers for every event that started in the last 7 days
or starts in the next 60: per event, each channel's tickets this week and to date with gross, fees and net, plus
totals. It goes to the owner and managers; anyone can unsubscribe from the footer (it's a follow-up mail), and the
owner can turn it off for the org at **`/orgs/:orgId/channels`** (Dashboard → Channels), which also shows any
earlier week. It replaces that week's *Your week on Exos* summary for the people it reaches. **Weekly text:** with
Twilio or Telnyx connected, the owner can add a mobile number for a short summary with a link, sent from your own
number between 9:00 and 20:00 New York time; replying STOP turns it off for good: that number can't be saved
again until it texts START to your number. (Not built yet: confirming the number with a code when it's saved.)
Because anyone can put anything in a link's `utm_source`, the email and the text only use Exos' fixed channel
names: promoter codes show as *Promoters*, and any source Exos doesn't know shows as *Other* (the Channels card
shows its cleaned name beside it). Each org gets one report per week however
often the job runs. The operator turns the job on (see `docs/email.md`).

### Text messages

Fans opt in from their ticket ("Get texts about … next events"), with the consent words stored. To send:

1. Connect **Twilio** or **Telnyx** in Org settings → Integrations with your own number (you register it for
   business texting: 10DLC or toll-free). Point the number's incoming-message webhook at the address shown there
   so STOP replies are recorded.
2. **Event report → Marketing → Text messages**: write it, pick this event's ticket holders or everyone on your list,
   send now or schedule.

Exos adds your org's name and "Reply STOP to opt out" to every text, sends only 9:00 to 20:00 (event time), at most
8 texts per person per month, and never to someone who replied STOP. On a fresh install sending stays off (dry run)
until the operator switches it on.

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

### Tickets sold somewhere else (Exos Door)

The door works for events you sell on Eventbrite, Posh, DICE, Shotgun, RA or anywhere else, for free.
Open **Exos Door** at `/door` (it installs as its own app on your phone's home screen).
- **New door for an event sold elsewhere** creates a door-only event: a draft that never goes on sale on
  Exos.
- **Import attendees:** export the attendee list from the other platform as CSV and choose the file.
  - Exos guesses the platform and which column holds the name, email, ticket type and barcode. Change any
    of them before you import.
  - Importing the same file again adds nobody twice.
  - You can also import from the event report, under **Tables & guest lists**.
- **At the door:** the **Guest list** tab has a code box. Scan the barcode on the attendee's ticket with
  the camera, or with a USB / Bluetooth barcode scanner (it types the code and presses Enter), or type it.
  - If the code is on an imported list, the guest is checked in.
  - In the **Tickets** tab, a code from another platform is handed to the guest list automatically.
- **It works offline** like the rest of the door: download the lists first.
- **Live sync from Eventbrite** (instead of re-importing): in `/door`, open **Eventbrite sync** on the event.
  - An owner or manager clicks **Connect Eventbrite**, signs in on Eventbrite and allows Exos, then picks
    the Eventbrite event (also in **Org settings → Integrations**). Where this Exos server has no Eventbrite
    app set up yet, paste the Eventbrite **private token** once instead (Eventbrite: Account settings →
    Developer links → API keys). **Disconnect** deletes Exos's copy of the token; to also remove Exos on
    Eventbrite's side, remove the app in your Eventbrite account settings.
  - New buyers reach the door within a couple of minutes on the event day (every 30 minutes before that).
    **Sync now** pulls the latest right away; any door staff can tap it.
  - A ticket refunded or cancelled on Eventbrite stops working: the door says "not valid" for the scan and
    the name.
  - Exos only reads from Eventbrite. Check-ins are not sent back to it, and nothing there changes.
  - Posh: connect its webhooks instead (*Selling on Posh too*, below); its buyers then arrive on their own.
  - DICE and the others: import their CSV (they have no API we can use yet).
- **The trade-off:** an imported code isn't one of Exos's rotating signed codes. Anyone holding a copy of it
  gets in once, as with the other platform's own app.

### Selling on Eventbrite too (one event, every platform)

Create the event once, in Exos, and sell it on Eventbrite as well, with one shared count of tickets.

- **Create event → Ticketing**: pick the **primary ticketing system** (Exos or Eventbrite) and tick **Also sell
  on**. The primary is whose QR codes the event goes out with when it is shared on other markets (the last listing
  set is sold there), and where comps go (Eventbrite can't add guests through its API, so comps stay Exos tickets).
- Exos then **creates the event on Eventbrite** with the same name, date, venue, description and ticket types with
  prices, and publishes it when you publish. Change something in Exos and it is changed there on the next sync
  (every 2 minutes, or **Sync now** under Edit event → Also sell on). Edit in Exos, not on Eventbrite: a change made
  directly there is replaced by the next change in Exos.
- **One count**: Eventbrite's sales come off the Exos ticket types, and Eventbrite's capacity is kept at what Exos
  has free (less one order's worth, the buffer for the sync's lag). Its buyers are on the door list with their QR codes.
- Already have the event on Eventbrite? Under **Also sell on**, paste its link instead: Exos takes it over and adds
  any ticket types it is missing.
- Cancelling in Exos cancels it on Eventbrite (Eventbrite refuses once it has orders: cancel and refund there).
- **Sending is off until you switch it on**: the org owner turns on Eventbrite writes in the door app, and the
  server setting must allow it. Until then Exos records what it would send, and nothing changes on Eventbrite.
- Table ticket types and ones in a shared capacity group stay on Exos.
- Luma works the same way and is built in, but it is switched off for now (its API needs Luma Plus).
- **Last call (Edit event → Last call):** when the event has 10 tickets or fewer left (your number; 0 turns it
  off), only the **primary** keeps selling, so the last tickets go through one checkout and nothing oversells:
  marketplace and S4K seats come back, and Eventbrite or Luma (when it isn't the primary) is set to sold out,
  though its sales and refunds still count. If the primary is Eventbrite or Luma, the Exos page shows sold out
  with a link to buy there. The event dashboard says **Last call: selling only on …** while it is on.
  Eventbrite can't set a ticket class to 0: one with no sales shows an error asking you to hide or end it there.

### Selling on Posh too (webhooks + a capped Posh tier)

Posh has no API for organizers, so Exos can't read or change a Posh event. What Posh does have is webhooks, so Posh
gets a **capped tier**: you decide how many tickets Posh may sell, Exos keeps those seats off its own sales, and
Posh tells Exos about every sale.

- **Connect once: Org settings → Posh → Make the webhook URL.** Copy it (it is shown once). In Posh open
  **Organization Settings → API Webhooks** and add it for **Order Created** and **Pending Order Created**. If Posh
  lets you give each its own URL, you can add `/pending` to the end of the one for Pending Order Created.
  Lost the URL or worried it leaked? **New URL** makes another; the old one stops working at once.
- **Link each Posh event to its Exos event** (Org settings → Posh): paste the Posh event's link
  (`posh.vip/e/…`), its id or its exact name, and pick the Exos event. Orders whose Posh event isn't linked wait
  under **Unmatched Posh orders**; **Assign** one to its event and that Posh event is linked for the next orders.
- **Set the Posh cap: Edit event → Posh.** Pick the ticket type and how many of it Posh may sell, then **set the
  same capacity on Posh by hand**. Those seats come off what Exos, Eventbrite and Luma can sell. The cap can only
  grow by seats that are free right now, and can't go below what Posh has already sold. Table ticket types and
  ones in a shared capacity group can't be capped for Posh. Posh is primary ticketing, not resale: the resale
  rules (the 250-capacity minimum, the pools) don't apply.
- **Sales**: a completed Posh order takes its tickets out of the Posh cap and shows in the event's counts and on
  Edit event → Posh. A **pending** order (one waiting for your approval on Posh) is listed but takes no seat and
  isn't on the door list; when you approve it on Posh, Posh's Order Created for it confirms it.
- **Oversell**: if Posh sells more than the cap (its capacity there was set higher), Exos flags it on the event
  ("Oversold: Posh sold N past its cap") until you tap **I've seen it**, notes it on those buyers' door entries, and
  takes the extra seats from what Exos has free so it stops selling them. If nothing is free, it says how many
  have no seat. Fix it by lowering the capacity on Posh or raising the cap.
- **The door**: Posh buyers are on a **Posh** guest list for the event, with the ticket codes from the webhook (scan
  them like an imported code), or by name with their party when the webhook carries no code.
- **Refunds**: Posh sends no webhook for a refund. After refunding on Posh, **Cancel** the order under Edit event →
  Posh: its seats go back to the Posh cap and its door entries stop working.
- **What isn't verified yet**: Posh doesn't publish its webhook format, and Exos hasn't seen a real delivery.
  Exos reads the usual field names (order id, event id / link / name, buyer name and email, quantity, ticket codes)
  and drops anything it can't place. Check the first real order: if a field is missing (no codes at the door, the
  wrong quantity, unmatched when it shouldn't be), tell support; the delivery is kept for 30 days so it can be
  replayed once the parser is fixed. Posh documents no signature, so the secret URL is the only check: keep it
  private. Details: `docs/marketplace/posh.md`.

### Selling a block for DICE, Shotgun, RA or your box office (fixed block)

Selling mainly on a platform Exos can't connect to? Give Exos a fixed block of tickets to sell, and keep the rest
there.

- **On the other platform**, lower the public capacity by the block (for example 1000 to 900 for a block of 100).
  Exos can't change anything there, so this step is yours.
- **Edit event → Selling a block for another platform → Sell a block**: name the platform (and paste its event
  page if you like), enter the block for each ticket type, and pick when unsold tickets go back (empty = 24 hours
  before doors). The block is the ticket type's capacity, and every ticket type needs one (no unlimited types on a
  block event). You can change the blocks and the time until the release; a block can't go below what it sold.
- **Exos sells the block** on its event page, your tracking links and discovery, and on marketplaces only if the
  block qualifies for resale: the block counts as the event's size, so a block of 150 or less is the free tier (no
  Exos fee, never resold), and a bigger one resells only once you opt in.
- **Last call** works on the block: near the end of it, marketplaces hand their seats back and Exos keeps selling
  the rest itself (Exos is the seller of its block).
- **At the release time** (or **Release now**) Exos stops selling the block and shows, per ticket type, how many to
  put back on sale on the other platform; the owner and managers also get it by email. Tickets still in a
  checkout or on a marketplace at that moment are counted separately: any that don't sell show on the event
  dashboard as "came back since", to put back as well. A release can't be undone, and the block can't be turned
  off after it.
- **At the door**, tickets sold on Exos are on the door list as usual; import the other platform's attendee
  export for the rest (*Tickets sold somewhere else*).
- The event dashboard shows the block sold / left and the release time, then the counts once released.

### Selling on another platform (pretix, hi.events, Luma, Eventbrite)

You can keep your ticket shop where it is and use Exos for the event page, marketing and the door.

- **Edit event → Where tickets are sold**: pick Exos, Eventbrite, pretix, hi.events or Luma and paste the link to your
  ticket page there. (An event you listed with *List an event you sell elsewhere* keeps the link it was imported
  with; list it again to change it.) The buy button then sends fans to that shop, and Exos doesn't take payment for the event
  (it can't be switched once tickets have sold on Exos).
- **The door**: connect the platform once in **Org settings → Integrations**, then link the event:
  - **pretix**: an API token from a team that can only view orders, your pretix address (pretix.eu or your own
    server) and organizer short name. Paste the event's shop link. Paid orders come in with their QR codes;
    cancelled, expired or unpaid ones are refused at the door.
  - **hi.events**: your hi.events address, then a check-in list's share link (Check-in lists → share). No password
    is stored. Rotating QR codes can't be checked by Exos; those guests are found by name.
  - **Luma**: an API key for your calendar (Luma → calendar settings → Developer; Luma Plus, one key per
    calendar). Paste the event's Luma link; the event has to be on that calendar. Approved guests' Luma QR codes
    scan at the door; pending, invited, waitlisted and declined guests show as not admitted.
  - **Eventbrite**: as above (*Tickets sold somewhere else*).
- Guests sync every 2 minutes from two days before the event (every 30 minutes before that) into a guest list
  named after the platform. **Sync now** on the panel pulls immediately. Nothing is written back.

### List an event you sell elsewhere (Eventbrite, Luma, Posh)

Already selling on one platform? Exos can list the event without selling it: Exos runs the event page, your
organizer page, discovery (Google, calendars, catalog feeds, tracking links) and sends every buyer to **your own
checkout**. Exos sells nothing for these events and charges nothing.

- **Dashboard → List an event you sell elsewhere.**
  - **From your Eventbrite account** (connect it first in *Tickets sold somewhere else*): Exos shows your live and
    upcoming Eventbrite events. Tick one or many (up to 25 at a time) and **List on Exos**. Each one becomes a
    published Exos event with its name, dates, time zone, venue, description, image, category, price range and link.
    Listing the same Eventbrite event again updates it; it never makes a second event, and your own edits to the
    page (name, text, image, venue) are kept.
  - **Paste a link:** an Eventbrite, Luma or Posh event page.
    - *Eventbrite*: Exos reads it through Eventbrite's API with your connected account (it works for any public
      event your account can see) and lists it.
    - *Luma and Posh*: Exos doesn't read their pages yet. Type the details (name, start, venue, price range, image)
      and Exos saves a **draft**; check it in Edit event and publish it.
  - Importing straight from a connected Luma account isn't built yet (Exos's Luma client reads one event's guests,
    not a calendar's list of events); paste the Luma link instead.
- **The event page** shows the price range and ticket types as listed on the platform, and a **Buy on Eventbrite /
  Luma / Posh** button. There is no Exos checkout, no free claims, comps, holds, codes, waitlist, resale or
  marketplaces for it, and no Exos fee. Exos enforces this in the database, not just on the page.
- **Kept up to date:** Exos re-checks Eventbrite events on a schedule (every 30 minutes in the last two days, every
  2 hours in the last two weeks, else twice a day) and **Check Eventbrite now** in Edit event re-checks at once:
  - sold out on Eventbrite → the page and the feeds say sold out;
  - moved → the Exos event moves (Google is told it was rescheduled);
  - cancelled → the Exos event is cancelled and leaves the feeds;
  - over → it stops being checked.
  Luma and Posh listings aren't re-checked: if one sells out, moves or is cancelled, update or cancel it yourself.
- With Eventbrite connected, the listed event's Eventbrite attendees also sync to its door list (read only), so you
  can scan them with the Exos door app.

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
