# Go-to-market: New York City first

How Exos wins its first market. The product plan is `docs/strategy.md`; this doc is about who we
sell to, what we say, and how we measure it.

## Why NYC first

- **The densest independent live scene in the US:** nightlife, DIY, comedy, jazz, indie music,
  and Latin and Caribbean parties, spread over hundreds of rooms with 50 to 1,500 capacity.
- **Discovery and sales happen on Instagram.** Promoters sell from a bio link and story swipe-ups,
  so a checkout that works inside Instagram's in-app browser (roadmap item 7a) is the wedge.
- **The incumbents leave gaps:**
  - Posh charges buyers fees.
  - DICE is curated, and tickets live in its app.
  - RA is electronic-only.
  - Eventbrite isn't built for nightlife door operations.
  - Ticketmaster and AXS don't want small rooms.
- **The law already favours all-in pricing.** New York has required the total price, fees
  included, to be shown upfront since 2022 (Arts and Cultural Affairs Law Article 25), and the
  FTC's live-event fee rule points the same way. Exos's all-in prices are compliant by design,
  not as a retrofit.
- **Basements and warehouses have no signal**, and offline door check-in solves that on day one.

## Who we sell to (in order)

1. **Independent promoters and collectives.** Recurring parties and monthly series in Brooklyn
   (Bushwick, Ridgewood, Williamsburg, Greenpoint), the Lower East Side and East Village, and
   Queens. They switch fastest: no contracts, one decision-maker, and they sell 10 to 60 events
   a year.
2. **Small venues (roughly 100 to 600 capacity)** where those promoters already play: music rooms,
   bars with back rooms, comedy clubs. Each one is a door for every promoter it books. They're
   also the Phase 3 POS customers.
3. **Comedy producers and showcases.** They run high-frequency, low-price shows where buyer fees
   hurt most.
4. **Later:** mid-size rooms (600 to 1,500), festivals and pop-ups, and cultural institutions.

**Not yet:** arenas and anything under an exclusive contract with a big ticketer; unlicensed
events (we only list events at venues that are licensed or permitted to host them); resale-only
sellers.

### Public-sector RFPs (a parallel track)

Fairs, colleges, parks departments and public venues buy ticketing through RFPs on 3–5 year terms.
Few are open at any time; the next wave is fairs (December to April) and colleges (January to March).
One win is years of events, but the bids have pass/fail lines that indie promoters never ask for.

- **Watch:** set bid alerts on state and city procurement portals and the bid aggregators for
  "ticketing" and "event ticketing" before each wave opens.
- **Pick, don't spray:** shortlist 1 or 2 bids a wave whose requirements we already meet or can meet
  in time, and read each one's pass/fail lines before writing anything.
- **Readiness:** PCI is done on the code side; the operator steps, insurance, a VPAT, a security
  packet, reserved seating and SOC 2 are listed in `KANBAN.md` "Public-sector RFP readiness". Un-park
  an item only when a target bid makes it pass/fail.
- **Reference:** the NYC indie events count as references in a bid, so the indie wedge comes first.

### Venue economics (NIVA, State of Live 2025, 2024 data)

What independent stages report about their own books
([report PDF](https://static1.squarespace.com/static/5e91157c96fe495a4baf48f2/t/68e58e39bce25b729b47932e/1759874617679/2025-NIVA-State-of-Live-Report.pdf)):

- **64% were unprofitable** in 2024 (22% struggling to stay open); New York's state figure is 81%.
- **Revenue:** tickets and cover 46%, alcohol and other drinks 25%, donations and grants 10%, other 8%, food 6%,
  sponsorships 4%, merch 2%. Ticketing is "the backbone of the business model".
- **Costs:** artist and booking fees 31%, staff 26%, rent and facility 9%, drinks 7%, insurance 4%.
- **Top challenges, by how often named:** 1. marketing and bringing in an audience; 2. artist fees; 3. staffing;
  4. inflation; 5. monopolies; 6. insurance; 7. scalpers and predatory resale; 8. rent; 9. PRO fees;
  10. falling alcohol sales.
- **Volume:** 94% sell tickets or charge a cover, 91% run year-round, the average venue has shows 143 days a year,
  and 41% have shows 4 or more nights a week.
- NIVA names forced transferability, unchecked resale and unfair platform practices as threats to ticketing, and
  asks for control over how tickets are priced, delivered and sold.

What follows for us:

- **Lead with the audience, not fees.** Getting people in the room is problem #1; one listing that reaches every
  place fans look (storefront, Instagram, Google, AI assistants, listings, and resale channels where the
  organizer opts in) is the answer. All-in pricing and the door back it up.
- **Resale is #7 on their list.** Marketplace channels are pitched only as the organizer's own primary inventory,
  opt-in, at their price, never as resale. Transfer rules and rotating barcodes are the control they ask for.
- **A venue is worth several promoters.** Illustration, not data: 143 nights × 200 tickets × $20 is about $570K
  a year in tickets; at 3% that is about $17K a year to Exos per venue, after the first 6 months.
- **Bar revenue is squeezed, not gone** (25% of revenue, #10 of 10). Bar, merch and per-head spend (Phase 3 POS)
  are a follow-on, not the opening pitch.

## The pitch

> Fill the room: list once and your show is everywhere fans look, at one price, the one they pay. You keep your
> fans' data. Doors keep scanning when the signal drops, and screenshots don't get in.

| Pain today | What Exos does |
|---|---|
| Getting people in the room (venues' #1 challenge) | One listing to the storefront, Instagram checkout, Google, AI assistants, the discovery listings queue, and opt-in channels over 150 capacity |
| Fans balk at buyer fees at checkout | All-in price; the platform fee comes out of the payout |
| Checkout breaks inside Instagram | Checkout built for the Instagram and Facebook in-app browsers (item 7a) |
| Screenshot and forwarded-ticket fraud | Barcodes that rotate every 30 s and are signed per ticket |
| Door app dies in the basement | Offline roster that syncs when back online |
| Sold out, then no-shows | Waitlist auto-offers that hold the seat, plus face-value transfers |
| Promoter team payouts on spreadsheets | Promoter tracking links and attribution (Phase 1) |
| Slow payouts | Stripe Connect Express, paid straight to the organizer's account |

**Commercial offer** (as built: `supabase/functions/_shared/platformFee.ts`, `docs/organizer-guide.md`):

- **No buyer fees.** The Exos fee is **3%**, net to Exos, paid by the organizer out of the payout. Card processing
  (Stripe's 2.9% + 30¢) passes through to the organizer, as with any card sale. A $40 ticket pays out $37.34.
- **First 6 months free** for every new org: no Exos fee, only card processing.
- **Free tier:** events with a max capacity of 150 or less never pay an Exos fee (and are never listed on resale
  channels). This is the DIY and small-room wedge.
- **Marketplace sales** (events over 150 that opt in): 3% of what the marketplace pays; a $40 ticket pays out
  $38.80.
- Exos staff at the door for the first event.

**What venues get beyond ticketing** (built in the open build-phase PRs #65–#80, not merged or applied yet):
holds with levels and a booking calendar, offers and deal math, settlements and P&L, season passes, flex packs and
memberships, timed entry and reserved seating, promoter payouts, phone-number RSVP, and Venmo / PayPal / Cash App
checkout. Pitch these to venues only once they're live.

## Motion

Founder-led and in person. This market runs on relationships.

1. **Build the list.** Take the top 150 NYC organizers by listing volume from public listings on
   Posh, RA, DICE and Eventbrite, plus Instagram. Tag each one by neighborhood, genre, frequency
   and current platform.
2. **Recruit 5 design partners.** Pick recurring monthly parties with 200 to 500 attendees and a
   promoter who's active on Instagram. Onboard them by hand, work their doors, and collect weekly
   feedback.
3. **Venue anchor.** Sign 1 or 2 small venues where the design partners play. When an organizer
   plays that venue, the venue recommends Exos to them.
4. **Promoter referral loop.** Every Exos event page credits the organizer. Promoters who bring
   another organizer get fee credits.
5. **Scene presence.** Sponsor a few recurring parties' door operations: branded wristbands,
   Exos-run check-in. Have staff at the nightlife and venue-operator meetups.
6. **Content and SEO (item 7c).** Weekly "this week in Bushwick / LES / Ridgewood" pages generated
   from Exos listings. These rank for local searches and bring buyers to organizers.

## 90-day plan

| Weeks | Goal | Depends on |
|---|---|---|
| 0 to 2 | Payments live; 5 design partners signed; 10 test events end to end | Phase 0 go-live (`docs/payments-go-live.md`) |
| 3 to 6 | Design partners' real events on Exos; Instagram in-app checkout shipped; 1 venue anchor | Phase 1 item 7a; P1 security headers |
| 7 to 10 | 15 organizers; promoter links; Maps and SEO pages live | Phase 1 items 7b and 7c |
| 11 to 13 | 25 organizers; referral loop; first comedy and venue accounts | Phase 1 CRM, wallet passes |

## Metrics

**North star:** monthly GMV from repeat NYC organizers.

| Metric | Target by day 90 |
|---|---|
| Active organizers (at least 1 paid event in the last 30 days) | 25 |
| Repeat rate (2nd event within 60 days) | 60% or more |
| Checkout conversion inside the Instagram webview | within 10% of desktop |
| Share of GMV from Instagram and Facebook traffic | tracked, expected 40% or more |
| Door scan throughput | under 2 s per scan, including offline |
| Chargeback rate | under 0.3% |
| Time from sign-up to a published paid event | under 15 minutes |
| Support first response during event hours | under 10 minutes |

## Readiness before the first paid NYC event

- [ ] Payments live, and the 11 test cases in `docs/payments-go-live.md` pass in live mode.
- [ ] **New York sales tax opinion.**
  - Admissions to live dramatic or musical performances are generally treated differently from
    cabaret and nightclub admissions, and some events may be taxable.
  - Configure tax rules per tier accordingly (all-in display already folds exclusive tax in).
  - Get counsel sign-off on fee and price display under Article 25 and the FTC rule.
- [ ] Terms of service, privacy policy, refund policy template for organizers, and a Stripe
  dispute playbook.
- [ ] Support channel staffed during event nights (Thursday to Sunday, 6 pm to 3 am).
- [ ] Door kit: a phone or tablet per entrance with the offline roster downloaded, and a one-page
  door staff guide (`docs/organizer-guide.md` §5).

## Risks

- **Posh counter-moves** (fee cuts, all-in pricing). Our defence is door ops, fraud-resistant
  barcodes, and the venue POS roadmap. Posh doesn't run the bar.
- **Instagram webview changes break checkout.** Keep an "open in browser" escape hatch, test on
  every iOS and Instagram release, and watch webview conversion daily.
- **Neutrality questions** about sharing a database with a broker's data platform. Answer with the
  guardrail in `docs/strategy.md`, and move the DB split earlier if a venue requires it.
- **Chargebacks at nightlife events.** Keep cancellation and refund records tight, and put
  evidence in the dispute playbook (the scan log proves attendance).

## Expanding past NYC

Open the next city only when NYC hits its day-90 targets and repeat rate holds for 2 consecutive
months. The candidates are cities with similar scenes and Instagram-driven sales: Los Angeles,
Miami, Chicago, and then London (which needs VAT, GBP and UK consumer law work).
