# Exos capability inventory (from the repo, as of main `ccdfe41`, 2026-09-28)

Scope: what Exos offers organizers and fans, what is planned, and what is missing, using only the repository at `/home/user/EXP`. "Sources" are repo paths (no URLs; this is an internal codebase). Status legend used throughout:

- **LIVE**: merged on main and applied to prod or shipped in the live bundle (per `KANBAN.md` "Prod state").
- **MERGED, NOT LIVE**: code and migration on main, but the migration is not applied or the function/bundle is not deployed.
- **DRY-RUN**: built, but it deliberately makes no third-party writes (marketplaces) or depends on dormant payments.
- **PLANNED**: in `KANBAN.md` / `docs/strategy.md` / `docs/competition.md`, not built.
- **ABSENT**: no code and no concrete plan found.

Overarching caveat: **paid checkout is dormant in prod.** `stripe-webhook`, `exos-checkout` and `exos-reconcile-checkouts` "have never been deployed", and the live bundle was built without `VITE_STRIPE_PUBLISHABLE_KEY`. Free events work fully; paid events can't be sold. Every money feature below is therefore at best "merged, awaiting payments go-live". — [KANBAN.md "Prod state"](/home/user/EXP/KANBAN.md); [docs/payments-go-live.md](/home/user/EXP/docs/payments-go-live.md); [docs/organizer-guide.md §2](/home/user/EXP/docs/organizer-guide.md)

## Prod state vs this repo

### Takeaway
Prod DB is caught up through the 2026-09-26 growth set (commissions, referral rewards, organizer refunds, tables/guest lists, abandoned checkout, price disclosure), but payments functions, `exos-refund`, accessible tickets and the whole marketplace layer (14 migrations from `20260926190000` to `20260928040000`) are not live. The repo does not agree with itself on which commit the live `/bridge/` bundle came from.

### Cited Findings
- Applied to prod 2026-09-24/25: P0 set (refund ledger, voucher per ticket, hold caps, quota-aware mints), all-in pricing `20260924211840`, fulfill-all-or-nothing, checkout attribution, event geo, promoters, fan referrals, presale vouchers, trial-run fixes. — [KANBAN.md "Prod state" + "Stabilization 2026-09-25"](/home/user/EXP/KANBAN.md)
- Applied 2026-09-26 (operator-approved, md5-verified): `20260926000000` advisor cleanup, `010000` waitlist sign-in/account deletion, `020000` promoter commissions, `030000` referral rewards, `040000` organizer refunds, `050000` tables + guest lists, `060000` abandoned-checkout reminder (cron `exos_send_checkout_reminders` hourly at :17 is live), `070000` price-disclosure record, `080000` refund/tables fix. — [KANBAN.md](/home/user/EXP/KANBAN.md)
- Not deployed: `exos-refund`, and the edited `exos-checkout` / `stripe-webhook` / `exos-mail-drain` (the drain needs `EXOS_APP_URL` before reminder mails go out). — [KANBAN.md](/home/user/EXP/KANBAN.md)
- Authored, not applied: `20260926090000_exos_accessible_tickets`; "ticking 'Accessible ticket type' or filling Accessibility in Create Event fails the save" without it. — [KANBAN.md](/home/user/EXP/KANBAN.md)
- `20260925013000` (door staff don't see buyer emails) is authored and must only be applied after a newer bundle is deployed. — [KANBAN.md "Stabilization"](/home/user/EXP/KANBAN.md)
- Marketplace migrations on main but not mentioned as applied anywhere in the prod-state section: `20260926190000` stubhub_event_request, `191000` channel_event_links, `192000` marketplace_orders, `193000` channel_allocations, `194000` listing_plan_account_flags, `20260927010000` claim_any_account, `020000` seatgeek label, `030000` marketplace_sync, `040000` gametime, `050000` marketplace_standard, `20260928010000` pools, `020000` gotickets, `030000` vivid, `040000` scarcity = 14 files. Claim-into-any-account explicitly says "Prod rollout ... Operator-gated" (unchecked). — [supabase/migrations/](/home/user/EXP/supabase/migrations); [KANBAN.md "Claim into any account"](/home/user/EXP/KANBAN.md)
- Live bundle: KANBAN says "built from EXP `2a11143` (ease-of-use pass), shipped in Terminal-2 #1005 (merged 2026-09-26)". `2f898ba` ("Exos: P0 fixes, growth build, ease of use, accessible tickets, hosting (#4, includes #3)") is the merge commit that follows it on main; the brief's claim that the live bundle is from `2f898ba` is not stated in the repo. — [KANBAN.md line 19](/home/user/EXP/KANBAN.md); `git log`
- Hosting: `exos-web` Render service auto-deploys from `main` behind `https://vibepass-storefront-test.onrender.com/bridge/`; Terminal-2's `static/bridge/` remains a fallback "until the cutover is confirmed". — [docs/hosting.md](/home/user/EXP/docs/hosting.md)
- `docs/social.md` still says "today's bundle is from 07-27 and has no SSR markers" (stale relative to KANBAN). — [docs/social.md](/home/user/EXP/docs/social.md)

### Inferences
- If `exos-web` has actually cut over, main (including marketplace UI) may be what's served, but the repo does not confirm the cutover; treat the live bundle as `2a11143`/`2f898ba`-era and the marketplace layer as not live.
- `docs/competition.md` (snapshot 2026-09-26) and `docs/organizer-guide.md` predate the 2026-09-26 growth build; several "N" cells there (commissions, refunds, tables, abandoned checkout) are now built.

### Gaps
- No statement in the repo of whether `exos-web` cutover happened, or of the exact prod migration list after 2026-09-26.

## (A) Organizer / promoter / venue capabilities

### Takeaway
Exos has a deep primary-ticketing core (orgs with roles, tiers, scheduled prices, quotas, holds, vouchers/presales, add-ons, tax, waitlist, comps, series, rotating-HMAC door app with offline mode, analytics/CSV) and a freshly built growth layer (promoter commissions, referral rewards, organizer refunds, tables/guest lists, abandoned checkout, price-disclosure record). The big gaps are payments being off, no box office/POS, no SMS, no reserved seat maps, no settlement, and a marketplace layer that is entirely dry-run.

### Cited Findings

**Org setup and team**
- LIVE: five-step onboarding wizard (org, brand/logo/colors, first event); org storefront `/o/:slug`; roles owner / manager / finance / scanner / content; invites by link. — [docs/organizer-guide.md §1](/home/user/EXP/docs/organizer-guide.md); `src/views/OrganizerOnboarding.tsx`, `OrgMembers.tsx`, `OrgStorefront.tsx`
- MERGED, NOT LIVE: invites and reserved voucher codes are "first come, first served" (any verified account with the link joins; inviter gets a receipt). — [KANBAN.md "Claim into any account"](/home/user/EXP/KANBAN.md); mig `20260927010000`
- LIVE (historical "Done"): white-label theming per org; embed widget `/embed/event/:id`; slug vanity URLs. — [KANBAN.md "Done"](/home/user/EXP/KANBAN.md)
- MERGED: Stripe Embedded Checkout inside the venue's own site ("white label level 3"), `ui_mode: 'embedded'` in `exos-checkout`. — commit `ce0d055`; [supabase/functions/exos-checkout/index.ts](/home/user/EXP/supabase/functions/exos-checkout/index.ts); `src/components/EmbeddedCheckoutMount.tsx`, `src/views/EmbedEvent.tsx`
- PLANNED (post-launch): white label level 2, organizer's own domain (`tickets.venue.com`), "hide Powered by Exos" as paid. — [KANBAN.md "Post-launch"](/home/user/EXP/KANBAN.md)

**Event creation, tiers and pricing**
- LIVE: create/edit event (date, doors, start/end, venue, performers, artist links), tiers with price, capacity, sales window, hidden/public; per-event currency. — [docs/organizer-guide.md §3](/home/user/EXP/docs/organizer-guide.md); `src/views/CreateEvent.tsx`, `EditEvent.tsx`; migs `20260703130000_exos_event_artist_links`, `20260709120100_exos_org_country_currency`
- LIVE: scheduled (time-based) price steps, early-bird → regular → last-minute, with a "price rises on…" nudge; charged server-side at the scheduled price (parity-tested). Sold-%-based steps are a follow-up. — mig `20260703122000_exos_tier_price_schedule`; `src/lib/pricing.ts`, `supabase/functions/_shared/pricing.ts`, `src/lib/pricingParity.test.ts`; `src/components/TierPricingPanel.tsx`; [KANBAN.md Competitor gap backlog](/home/user/EXP/KANBAN.md)
- LIVE (DB): all-in pricing, operator decision 2026-09-24. "Every buyer-facing price is all-in... Buyers pay no service fee"; exclusive tax is folded into each line. Follow-ups: "buyers will see $X" preview in tier editor; counsel review. — [KANBAN.md "All-in pricing"](/home/user/EXP/KANBAN.md); mig `20260924211840_exos_all_in_price_tax`
- LIVE: shared capacity quotas (e.g. GA + VIP from one 300-person pool), but "There's no screen for this yet; support sets it up in SQL." — [docs/organizer-guide.md §3](/home/user/EXP/docs/organizer-guide.md); mig `20260702123030_exos_quotas`
- LIVE: purchase limits per order / per account, enforced at hold time; one live cart hold per buyer per event, 30-min TTL. — mig `20260924205916_exos_p0_hold_caps`; [KANBAN.md Audit](/home/user/EXP/KANBAN.md)
- LIVE: add-ons (claimed atomically at fulfilment). — mig `20260616190000_exos_addons`, `20260924215000`; `src/components/AddonsEditor.tsx`
- LIVE: event series (clone event + tiers per date). Timed-entry/slot picker absent ("P (clones events; no slot picker)"). — mig `20260911133000_exos_event_series`; `src/views/CreateSeries.tsx`; [docs/competition.md](/home/user/EXP/docs/competition.md)
- MERGED/partial: table packages (tier `kind`, party_size, min_spend_cents, section_label, table bookings, assignment). — mig `20260926050000_exos_tables_guest_lists` (applied); `src/components/TableTierFields.tsx`, `TableAssignmentsPanel.tsx`, `TableTierInfo.tsx`
- ABSENT / PLANNED: reserved seating maps and seat picker ("Largest single build"); cabaret/section seating (#12 in competition build order); season packages / memberships; timed-entry slots. — [KANBAN.md Competitor gap backlog](/home/user/EXP/KANBAN.md); [docs/competition.md](/home/user/EXP/docs/competition.md)

**Vouchers, presales, discounts**
- LIVE: vouchers (one use = one ticket; pin a price, restrict to a tier, reserve for an email, expire, sell past sold-out); presale codes from organizer UI (e.g. PRESALE), case-insensitive; hidden tiers only buyable with a tier-restricted voucher. — [docs/organizer-guide.md §3](/home/user/EXP/docs/organizer-guide.md); migs `20260616210000_exos_vouchers`, `20260925012000_exos_presale_vouchers`, `20260925000000_exos_voucher_unlocked_tier`; `src/components/VouchersEditor.tsx`
- ABSENT (known bug/planned): percent / fixed discount codes "don't work" — `exos_discount_codes` is never redeemed by checkout; editors hidden behind `SHOW_DISCOUNT_CODES`. Fix planned (add `percent_off` / `amount_off` to vouchers). — [KANBAN.md "Ease of use 2026-09-26"](/home/user/EXP/KANBAN.md)

**Fees, payments, payouts**
- DRY-RUN/dormant: Stripe Connect **Express** onboarding; **destination charges** with `application_fee_amount`; platform fee `EXOS_PLATFORM_FEE_BPS` default 500 (5%), paid by the organizer out of payout, no buyer fee. — [docs/payments-go-live.md §0–1](/home/user/EXP/docs/payments-go-live.md); `supabase/functions/exos-connect-onboard/`
- Payout timing: the repo says "Stripe Connect Express already pays out on a rolling basis, so fast payouts are ours to lose" and "Payouts go straight to the organizer's account"; no custom payout schedule is configured in `exos-connect-onboard`. — [docs/competition.md "Openings"](/home/user/EXP/docs/competition.md); [docs/gtm-nyc.md pitch](/home/user/EXP/docs/gtm-nyc.md)
- Commercial offer (to validate): 5% organizer-paid fee, first 3 events / 90 days fee-free for design partners, fee floor so free events stay free, Exos staff at the first door. — [docs/gtm-nyc.md](/home/user/EXP/docs/gtm-nyc.md)
- LIVE (DB) / function not deployed: organizer money refunds (full/partial, per ticket or order, "refund everyone" for a cancelled event), roles owner/manager/finance; `exos-refund` edge function not deployed. — mig `20260926040000_exos_organizer_refunds`; `src/components/RefundPanel.tsx`; [KANBAN.md](/home/user/EXP/KANBAN.md)
- LIVE: refund/dispute ledger — full refund voids tickets and frees seats; partial keeps them valid; auto-refunds reverse the transfer and application fee (organizer bears them); a lost dispute voids tickets. — [docs/organizer-guide.md §6](/home/user/EXP/docs/organizer-guide.md); [KANBAN.md Audit](/home/user/EXP/KANBAN.md)
- LIVE: tax rules per tier and invoicing with numbering. — migs `20260616230000_exos_tax`, `20260616240000_exos_invoicing`, `20260911050000_exos_invoice_counters_rls`; `src/components/TaxRulesEditor.tsx`, `src/lib/invoices.ts`
- LIVE (DB): price-disclosure record per order (all-in unit price shown, line totals, buyer fees = 0, amount Stripe charged, `charge_mismatch` flag), exportable, for NY ACAL §25.07 / FTC rule. — mig `20260926070000_exos_price_disclosure`; `src/components/PriceDisclosureExport.tsx`
- PLANNED: per-event organizer fees (facility fee line items); more payment methods (bank transfer); BNPL; ticket insurance. — [KANBAN.md "To Do (hi.events + pretix)" and Competitor gap backlog](/home/user/EXP/KANBAN.md)

**Promoters, affiliates, referrals**
- LIVE: promoter records, private portal `/p/:token`, leaderboard `/orgs/:orgId/promoters`, pause/rotate links; per-event campaign codes; no-login promoter kit `/promoter/:eventId/:code` (buy-now link builder, story poster, tracked links for IG/TikTok/WhatsApp/SMS/email); link-in-bio `/l/:orgSlug/:code`; checkout links `/checkout?products=…&coupon=…` (Meta Shops format). — migs `20260924233000_exos_promoters`, `20260924223000_exos_checkout_attribution`; [docs/social.md](/home/user/EXP/docs/social.md); [KANBAN.md 7d–7f](/home/user/EXP/KANBAN.md); `src/views/PromoterPortal.tsx`, `PromoterKit.tsx`, `PromoterBio.tsx`, `OrgPromoters.tsx`
- LIVE (DB): promoter commissions — per-promoter % (bps) and/or flat per ticket, per-event overrides, accrual per attributed ticket, full reversal/clawback on void/refund, payout ledger. **Payouts are recorded, not sent**: "records money the organizer paid outside Exos (method is free text: 'Venmo', 'cash')... No money moves; Stripe Connect transfers are a follow-up." — mig `20260926020000_exos_promoter_commissions`; `src/components/PromoterCommissionPanel.tsx`, `PromoterEarningsPanel.tsx`
- LIVE (DB): fan referral codes per holder per event, counted (paid or free, self-referral ignored), and referral rewards ("every N referred tickets earns a single-use voucher": free, % off, or amount off; per-fan cap; off until an organizer saves a rule). — migs `20260924234500_exos_fan_referrals`, `20260926030000_exos_referral_rewards`; `src/components/ReferralRewardsPanel.tsx`, `ReferralProgress.tsx`
- Auto-tagging of organizer/promoter @handles in shares; organizers can switch off. — [docs/social.md](/home/user/EXP/docs/social.md); `src/lib/socialTags.ts`
- PLANNED (GTM): promoter-brings-organizer fee credits. — [docs/gtm-nyc.md "Motion"](/home/user/EXP/docs/gtm-nyc.md)

**Guest lists, comps, tables at the door**
- LIVE: comp batches to a list of emails with an org-wide comp budget (respects capacity/quotas/holds); issue-to-email with claim link. — migs `20260911132000_exos_comp_batch`, `20260523230000_exos_issue_to_email`; `src/components/CompIssuancePanel.tsx`
- LIVE (DB): guest lists (promoter-fed from their portal, staff-editable), guest door mode with check-in, offline. — mig `20260926050000`; `src/components/GuestListPanel.tsx`, `GuestListDoor.tsx`, `PromoterGuestListForm.tsx`
- ABSENT: bottle-service ordering / min-spend settlement beyond the table tier fields; group sales workflow. — [KANBAN.md Competitor gap backlog](/home/user/EXP/KANBAN.md)

**Door / check-in**
- LIVE: `/checkin/:eventId` camera scanner; rotating HMAC QR (30 s buckets, per-ticket secret rotated on transfer); server-side check of every scan (wrong event, used, refunded, mid-transfer, cancelled event refused and logged); refused-scan audit; realtime check-ins; offline mode with downloaded roster that syncs and flags server rejections; 3-hour test window where test scans don't consume the ticket; door name search. — [docs/organizer-guide.md §5](/home/user/EXP/docs/organizer-guide.md); migs `20260523120000_exos_realtime_checkins`, `20260702120000_exos_checkin_harden_doors_gate`, `20260925010000`; `src/views/OrganizerCheckIn.tsx`, `src/components/ScanRejectAudit.tsx`, `src/lib/barcode.ts`, `src/lib/doorSearch.ts`
- Open weakness: offline registry of barcode secrets lives in plaintext localStorage for 7 days (wiped on sign-out). — [KANBAN.md Audit "Frontend"](/home/user/EXP/KANBAN.md)
- ABSENT / PLANNED: box office / tap-to-pay door sales (Phase 3, Stripe Terminal); RFID / hardware access control; bar/merch POS and end-of-night settlement (guarantee vs door split). — [docs/strategy.md Phase 3](/home/user/EXP/docs/strategy.md); [docs/competition.md](/home/user/EXP/docs/competition.md)

**Analytics, reports, data**
- LIVE: per-event analytics (funnel, sales by day in event tz, by tier/promoter/channel with scan-in, net revenue incl. add-ons and partial refunds), Summary/Attendees CSV, scan report, sales chart. — mig `20260911130000_exos_event_analytics` (superseded later); `src/components/EventAnalyticsPanel.tsx`, `SalesChart.tsx`, `ScanReport.tsx`; `src/views/OrganizerEventReport.tsx`; [KANBAN.md Stage 3](/home/user/EXP/KANBAN.md)
- LIVE: public read-only REST API (`exos-api`, all GET, org-scoped by key, 120 req/min): events, event+tiers, attendees, orders, invoices; signed outbound webhooks (`exos-webhook-drain`) exist but "Prod has no webhooks yet". — [supabase/functions/exos-api/index.ts](/home/user/EXP/supabase/functions/exos-api/index.ts); mig `20260616200000_exos_public_api_webhooks`; [KANBAN.md Audit](/home/user/EXP/KANBAN.md); `src/components/DeveloperSettings.tsx`
- Data ownership: pitch "You keep your fans' data"; neutrality guardrail that Terminal-2 broker lanes "never read `exos_*` buyer or order data", with a planned DB split to make the wall physical. — [docs/gtm-nyc.md](/home/user/EXP/docs/gtm-nyc.md); [docs/strategy.md "Guardrails"](/home/user/EXP/docs/strategy.md)
- PLANNED: XLSX export; write API (event create/update); MailChimp/Salesforce/Zapier connectors; CRM segments. — [KANBAN.md](/home/user/EXP/KANBAN.md)

**Marketing and communications**
- LIVE: follow organizers + `exos_announce_to_followers`; announcements to holders (email + in-app, retractable); reschedule notices; cancel/update notices; automatic T-24h/T-2h reminders + manual send-now (6 h cooldown). Delivery rides `exos-mail-drain` and needs `RESEND_API_KEY`. — migs `20260520140000_exos_org_follows`, `20260523200000_exos_growth_primitives`, `20260703121000`, `20260703124000`, `20260911051000`; [KANBAN.md "Done"](/home/user/EXP/KANBAN.md)
- LIVE (DB, cron live) but mail not flowing: abandoned-checkout reminder, one mail per buyer per event with a cart-refill link, org opt-out, unsubscribe; needs `EXOS_APP_URL` on the drain (and paid checkout to produce abandoned sessions). — mig `20260926060000_exos_abandoned_checkout`; [KANBAN.md](/home/user/EXP/KANBAN.md)
- LIVE: org pixels (Meta, GA4, TikTok), consent-gated, one org per page, never on `/checkin`. ABSENT: server-side Meta CAPI / TikTok Events API (privacy decision). — `src/lib/pixels.ts`; [docs/social.md](/home/user/EXP/docs/social.md)
- LIVE: SEO JSON-LD, canonical, sitemap (served via Terminal-2 `core/exos_seo.py` / now `src/lib/hosting/seo.ts`); link previews with all-in "from" price. PLANNED: prerendered pages and neighborhood landing pages ("this week in Bushwick"). — [KANBAN.md 7](/home/user/EXP/KANBAN.md); [docs/hosting.md](/home/user/EXP/docs/hosting.md)
- ABSENT / PLANNED: SMS (needs Twilio + 10DLC); auto-posting to Instagram; Instagram/Facebook Shop. — [docs/social.md "Missing"](/home/user/EXP/docs/social.md); [docs/competition.md build #7](/home/user/EXP/docs/competition.md)

**Marketplace distribution (StubHub, SeatGeek, Gametime, GoTickets, Vivid)**
- DRY-RUN (merged on main, not applied/deployed): one Exos listing standard mapped to five marketplaces; Marketplaces grid in the event editor (row per ticket type, column per marketplace); publishing queues events (StubHub event request/creation; others match by name/venue/date); listings as blocks of at most max-per-order with internal GA seat numbers; delisting on untick/unpublish/cancel; sales ingested by webhook/polling and fulfilled as Exos claim-link transfers; listed as mobile transfer, else electronic transfer. — [docs/marketplace/README.md](/home/user/EXP/docs/marketplace/README.md); [KANBAN.md SeatGeek / Gametime / GoTickets / Vivid / "One Exos listing standard"](/home/user/EXP/KANBAN.md); `supabase/functions/exos-distribute`, `exos-marketplace-sales`; `src/lib/marketplace/`
- DRY-RUN: small pools (each marketplace holds 2 × max per order, topped up after each sale; Exos sells the rest), scarcity mode (stagnant pools shrink; near sellout quiet pools shrink) and a fixed 3-hour pre-doors cutoff that sends every pool to 0 so day-of sales are Exos's. Scenario sim: 19 scenarios, "Integrity held everywhere". — migs `20260928010000`, `20260928040000`; [docs/marketplace/scarcity-sim.md](/home/user/EXP/docs/marketplace/scarcity-sim.md); [KANBAN.md](/home/user/EXP/KANBAN.md)
- Blocked on operator: API tokens and a recorded `WriteAuthorization` per marketplace; live sender not built; Gametime FTP upload not built; confirmations pending with each vendor. `exos-distribute` (Automatiq/Lysted) "must stay undeployed". — [CLAUDE.md](/home/user/EXP/CLAUDE.md); [KANBAN.md item 8](/home/user/EXP/KANBAN.md)
- DRY-RUN: account limit flags — accounts holding more of an event's tickets than max-per-account (typically from several marketplace orders) are flagged, not blocked; owners/managers review with a note; promoters can note from the portal. — mig `20260926194000`; `src/views/OrgLimitFlags.tsx`, `src/components/PromoterLimitFlags.tsx`
- PLANNED: Bandsintown discovery feed (read-only pull by Bandsintown) and Last.fm demand data; per-event full-broadcast mode; per-event cutoff override. — [KANBAN.md "Bandsintown + Last.fm", "Small marketplace pools"](/home/user/EXP/KANBAN.md)

**Accessibility (organizer side)**
- MERGED, NOT LIVE: accessible ticket types with a note; event access info (fixed venue-feature list, notes, access contact); staff see holders' and guests' access needs in report, CSV and at the door (offline too). — mig `20260926090000_exos_accessible_tickets`; `src/components/Accessibility.tsx`, `TicketAccessNeeds.tsx`, `AccessRequestsPanel.tsx`; [KANBAN.md "Accessible tickets"](/home/user/EXP/KANBAN.md)

**Other planned (organizer)**
- Merch: store link button (planned), Printful-backed merch add-ons (planned, write-gated). — [KANBAN.md "Merch"](/home/user/EXP/KANBAN.md)
- Instant ticket return (organizer opt-in refund % and window; seat to waitlist). — [KANBAN.md "Post-launch"](/home/user/EXP/KANBAN.md)
- Booking/holds calendar and artist settlement; plugin loader; DB split; multi-city. — [KANBAN.md](/home/user/EXP/KANBAN.md); [docs/strategy.md Phases 3–5](/home/user/EXP/docs/strategy.md)

### Inferences
- The organizer core is strongest on inventory integrity and door ops; the newest growth features exist in the DB but can't earn money until payments and `exos-refund` deploy.
- Promoter commissions stop short of Posh Kickback parity because Exos does not pay promoters (no Connect transfers).
- Marketplace distribution is the most elaborate recent build but is 100% dry-run and would only matter for sell-out-risk events.

### Gaps
- No evidence of a quota editor screen, sold-%-based price steps, or an organizer-facing "buyers will see $X" preview (all listed as follow-ups).
- Payout timing beyond "rolling basis" (e.g. days) is not specified in the repo.

## (B) Fan / buyer capabilities

### Takeaway
Fans get a web-first (no app) experience: all-in prices with no buyer fee, discovery (feed with search/genre pills, map, saves, follows), checkout built for Instagram/Facebook in-app browsers, a browser "wallet pass" with a rotating signed QR, free transfers and claim links, a seat-holding waitlist, reminders, referrals and English/Spanish on buyer surfaces. Missing: guest checkout (sign-in and a confirmed email are required), native Apple/Google Wallet passes, face-value resale, SMS, native app and social graph.

### Cited Findings

**Discovery**
- LIVE: Home feed with text search on title/location/category, genre pills from real categories, day filter; "from $X" all-in prices on cards. — [src/views/Home.tsx](/home/user/EXP/src/views/Home.tsx); [KANBAN.md "All-in pricing"](/home/user/EXP/KANBAN.md)
- LIVE: saved events (heart), follow organizers, org storefront, organizer profile. — mig `20260703120000_exos_event_saves`, `20260520140000_exos_org_follows`; `src/components/SaveEventButton.tsx`; `src/views/OrgStorefront.tsx`, `OrganizerProfile.tsx`
- MERGED (keys needed, "Not applied or deployed" per KANBAN 7): `/map` page of all events + event-page pins (Google Maps). Directions link and embedded venue map (with key) on event pages. — [docs/maps.md](/home/user/EXP/docs/maps.md); `src/views/EventsMap.tsx`, `src/components/VenueMap.tsx`; [KANBAN.md 7](/home/user/EXP/KANBAN.md). Note: KANBAN says mig `20260924230000` (event geo) was applied 2026-09-25, while section 7 says "Not applied or deployed" (older text).
- PLANNED: personalized "Suggested for you" via music identity (Spotify/Last.fm/Bandsintown), friends & social graph, event-day hub. — [KANBAN.md "To Do (existing kanban, deferred)", Competitor gap backlog](/home/user/EXP/KANBAN.md)

**Checkout**
- Requires sign-in: `exos-checkout` returns 401 without an authenticated user; buying or holding needs a **confirmed email**; free claims also need a confirmed email (anti-bot). No guest checkout found. — [supabase/functions/exos-checkout/index.ts L37–44](/home/user/EXP/supabase/functions/exos-checkout/index.ts); [docs/organizer-guide.md §1](/home/user/EXP/docs/organizer-guide.md); [KANBAN.md "Stabilization"](/home/user/EXP/KANBAN.md)
- DORMANT: Stripe-hosted Checkout (and Embedded Checkout); Apple Pay / Google Pay rely on Stripe Checkout in a real browser; inside Instagram/Facebook/TikTok webviews a banner offers "open in browser for Apple Pay", and the sign-in modal hides Google/Microsoft (keeps Apple + email). Not device-tested. — `src/lib/inAppBrowser.ts`, `src/components/InAppBrowserBanner.tsx`; [KANBAN.md 7](/home/user/EXP/KANBAN.md)
- LIVE (DB): all-in display = amount charged, tax folded in, no buyer fees; server-validated vouchers; hidden tier unlock; checkout links pre-fill cart. — [KANBAN.md "All-in pricing"](/home/user/EXP/KANBAN.md); `src/lib/checkoutLink.ts`
- LIVE: free RSVP claims; holders can release a free ticket (per release policy) back to the waitlist. — migs `20260605132500_exos_claim_free_tickets`, `20260911131000_exos_rsvp_release`
- PLANNED: group buy / Venmo split (post-launch); BNPL; insurance; virtual queue / verified fan. — [KANBAN.md](/home/user/EXP/KANBAN.md)

**Tickets, passes, barcodes**
- LIVE: My Tickets, ticket detail, `/wallet/pass/:ticketId` fullscreen browser pass with rotating QR and screen wake-lock; add to calendar; countdown; attendee name on ticket. — `src/views/MyTickets.tsx`, `TicketDetail.tsx`, `WalletPass.tsx`; `src/components/AddToCalendar.tsx`; mig `20260911060000_exos_ticket_attendee_name`
- ABSENT (planned): native Apple `.pkpass` / Google Wallet passes (needs signing certs); "[~]" scaffold only. — [KANBAN.md "Ease of use" and Competitor gap backlog](/home/user/EXP/KANBAN.md); [docs/social.md](/home/user/EXP/docs/social.md)
- PWA shell exists (service worker, manifest); no native app ("No app project exists in any repo"). — `src/components/PwaShell.tsx`, `src/lib/registerSW.ts`; [docs/social.md](/home/user/EXP/docs/social.md)

**Transfers, claims, resale**
- LIVE: free transfers by email; recipient claims, barcode reissued, old code dies; one pending transfer per ticket; cancel withdraws unsent mail. — [docs/organizer-guide.md §6](/home/user/EXP/docs/organizer-guide.md); `src/views/TransferTicket.tsx`, `ClaimTicket.tsx`
- MERGED, NOT LIVE: claim into any verified account (first claim wins, regardless of the email sent to), with sender receipts ("transfer sent"/"transfer accepted"). — mig `20260927010000_exos_claim_any_account`; [KANBAN.md](/home/user/EXP/KANBAN.md)
- ABSENT / PLANNED: face-value resale exchange ("#1 strategic gap", Phase 2; check NY Art. 25); instant ticket return (post-launch, organizer opt-in). — [KANBAN.md Competitor gap backlog](/home/user/EXP/KANBAN.md); [docs/strategy.md Phase 2](/home/user/EXP/docs/strategy.md)

**Waitlist, reminders, updates**
- LIVE: waitlist (signed-out join fixed by `20260926010000`) with FIFO auto-offer: a 48-hour code, group sizes respected, offered seats reserved. Not auto-charge. — [docs/organizer-guide.md §4](/home/user/EXP/docs/organizer-guide.md); migs `20260616180000`, `20260616220000`, `20260924205508`; `src/components/WaitlistCTA.tsx`
- LIVE (email needs Resend key): T-24h/T-2h reminders, announcements thread on ticket, reschedule "was X → now Y", in-app notifications. — `src/components/OrganizerUpdates.tsx`, `RescheduleNotice.tsx`; `src/views/Notifications.tsx`; mig `20260709120000_exos_notification_reads`
- Refunds from the fan side: fans have no self-serve refund; refunds are organizer-initiated (see A). Mail unsubscribe / marketing opt-out exists. — `src/views/MailUnsubscribe.tsx`; mig `20260926060000`

**Accessibility (fan side)**
- MERGED, NOT LIVE: accessible badge on ticket types; event access info public on the event page; holders state access needs on their pass (fixed categories), dropped on transfer. — mig `20260926090000`; [KANBAN.md "Accessible tickets"](/home/user/EXP/KANBAN.md)

**Social**
- LIVE: "I'm going" shares (story poster, share sheet, X, Facebook, WhatsApp, copy link), passing promoter credit; fan referral count ("3 friends coming") and reward progress; link previews. — [docs/social.md](/home/user/EXP/docs/social.md); `src/components/ShareModal.tsx`, `ReferralProgress.tsx`
- ABSENT: friend graph, "friends attending", groups; SMS invites. — [KANBAN.md deferred](/home/user/EXP/KANBAN.md); [docs/social.md](/home/user/EXP/docs/social.md)
- PLANNED: "I was there" proof-of-attendance collectible (explicitly not NFT tickets). — [KANBAN.md "Post-launch"](/home/user/EXP/KANBAN.md)

**Language, privacy, account**
- LIVE: English + Spanish dictionaries covering buyer surfaces (navbar, event page, claim card, waitlist, add-ons...); organizer strings "incrementally". — [src/lib/i18n/dict.ts](/home/user/EXP/src/lib/i18n/dict.ts); `src/components/LanguageSwitcher.tsx`
- LIVE: profiles private by default; consent banner for pixels; account deletion. — [KANBAN.md "Stabilization"](/home/user/EXP/KANBAN.md); `src/components/ConsentBanner.tsx`, `DeleteAccountPanel.tsx`

### Inferences
- Exos' fan pitch rests on "no app, no buyer fee, screenshot-proof code"; the lack of guest checkout and native wallet passes are friction points against that pitch, especially inside Instagram webviews where sign-in is required.

### Gaps
- No guest checkout plan found in KANBAN; whether sign-in-to-buy is a deliberate product decision isn't stated beyond anti-bot / confirmed-email rationale.

## Positioning and competition (what the repo says)

### Takeaway
Exos positions as an all-in-price, web-first, fraud-resistant ticketing tool for NYC independent promoters and 100–600-cap venues, aiming to become a "Toast + Otter" operating system for venues (POS + multi-channel distribution). Posh is named the highest threat; the repo's own ranked build list (commissions, referral rewards, refund button, tables/guest lists, wallet passes, SMS, abandoned checkout, fee-compliance record, resale, door sales, cabaret seating) has since been largely built through item 9 except wallet passes and SMS.

### Cited Findings
- Vision: "Exos becomes the operating system for venues and events. Toast is the model on the venue floor... Otter is the model for distribution." Phases 0 go-live, 1 NYC indie wedge, 2 face-value resale + pricing intelligence (read-only from Terminal-2), 3 venue POS, 4 channel hub, 5 platform. — [docs/strategy.md](/home/user/EXP/docs/strategy.md); [KANBAN.md Phases table](/home/user/EXP/KANBAN.md)
- Phase status: 0 "in progress"; 1 partial (in-app browser, Maps, checkout links, promoter kit, sharing done; next prerendered SEO, CRM, wallet passes); 2–5 not started. — [KANBAN.md Phases](/home/user/EXP/KANBAN.md)
- Targets: independent NYC promoters/collectives first, then 100–600-cap venues, comedy producers; not arenas, unlicensed events or resale-only sellers. Pitch: "Your buyers see one price, the one they pay. You keep your fans' data. Doors keep scanning when the signal drops, and screenshots don't get in." — [docs/gtm-nyc.md](/home/user/EXP/docs/gtm-nyc.md)
- Competitive field (snapshot 2026-09-26, figures "reported" from search snippets): Posh (10% + $0.99 buyer fee, +5% instant payout; highest threat), DICE (~13%; app-only), Eventbrite, Shotgun, Partiful, RA, Tixr, Ticket Tailor, Humanitix, Punchup, Tablelist/Discotech/SevenRooms, KYD, Luma, Opendate, TicketWeb/AXS/Eventim/Etix, TickPick Organizer. — [docs/competition.md](/home/user/EXP/docs/competition.md)
- "Where Exos already wins": all-in pricing; rotating signed barcodes in the browser; offline door check-in; inventory that can't oversell ("pretty much pretix-grade"); web checkout built for Instagram's in-app browser. — [docs/competition.md](/home/user/EXP/docs/competition.md)
- "Where Exos is behind" (as of 09-26): paid checkout not live; promoter commissions; tables/guest lists; door sales; SMS; face-value resale; wallet passes; organizer money refunds. — [docs/competition.md](/home/user/EXP/docs/competition.md)
- "Openings nobody has closed": provable fee compliance; fast payouts without a 5% charge; GA + tables + cabaret seating in one tool; wallet passes that keep the rotating code; human support on event nights; promoter settlement. — [docs/competition.md](/home/user/EXP/docs/competition.md)
- Legal backdrop cited: NY ACAL §25.07 and FTC fee rule (from 2025-05-12); Posh fee-disclosure ($1.2M) and TCPA ($900K) settlements; Tablelist hidden-fee suit. — [docs/competition.md](/home/user/EXP/docs/competition.md)
- Older "Competitor gap backlog" (TM/AXS/SeatGeek/OpenDate, 2026-07-03): shipped scheduled pricing and reminders; open: reserved seating, marketing automation/CRM, timed entry, season packages, box office, booking/settlement, group sales, RFID; fan: resale (#1), insurance, BNPL, smart queue, deal score, event-day hub, native wallet (partial), upgrades/gifting. — [KANBAN.md](/home/user/EXP/KANBAN.md)
- Guardrails: upstream marketplaces read-only without operator authorization; neutrality from the broker data platform Terminal-2 sharing the DB; money paths need SQL harness coverage. — [docs/strategy.md](/home/user/EXP/docs/strategy.md); [CLAUDE.md](/home/user/EXP/CLAUDE.md)
- GTM metrics (day 90): 25 active organizers, 60% repeat rate, IG webview conversion within 10% of desktop, scan < 2 s, chargebacks < 0.3%, signup-to-published-paid-event < 15 min, support first response < 10 min. — [docs/gtm-nyc.md](/home/user/EXP/docs/gtm-nyc.md)

### Inferences
- Tension in positioning: the neutrality guardrail and the "organizer controls official face-value resale" story sit alongside a newly built dry-run pipeline that pushes Exos inventory onto StubHub, SeatGeek, Vivid, Gametime and GoTickets. The scarcity/cutoff design (Exos keeps day-of sales, small pools) frames marketplaces as an extra channel, not the resale answer.
- Many competition.md gaps were closed in code within ~2 days of the snapshot, but none are revenue-live until payments go live.

### Gaps
- Competitor fees in `docs/competition.md` are self-described as unverified search-snippet figures.
- No customer/design-partner evidence (signed organizers, events run) appears in the repo.
