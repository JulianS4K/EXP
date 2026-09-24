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

## The pitch

> Your buyers see one price, the one they pay. You keep your fans' data. Doors keep scanning when
> the signal drops, and screenshots don't get in.

| Pain today | What Exos does |
|---|---|
| Fans balk at buyer fees at checkout | All-in price; the platform fee comes out of the payout |
| Checkout breaks inside Instagram | Checkout built for the Instagram and Facebook in-app browsers (item 7a) |
| Screenshot and forwarded-ticket fraud | Barcodes that rotate every 30 s and are signed per ticket |
| Door app dies in the basement | Offline roster that syncs when back online |
| Sold out, then no-shows | Waitlist auto-offers that hold the seat, plus face-value transfers |
| Promoter team payouts on spreadsheets | Promoter tracking links and attribution (Phase 1) |
| Slow payouts | Stripe Connect Express, paid straight to the organizer's account |

**Commercial offer, to validate with design partners:**

- Platform fee of 5% (the current default), paid by the organizer, with no buyer fees.
- The first 3 events, or first 90 days, fee-free for design partners.
- Exos staff at the door for the first event.
- A fee floor for free and RSVP events: free events stay free.

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
