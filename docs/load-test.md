# Load test: big on-sales and the waiting room

RFPs ask how Exos holds up when 10,000+ buyers arrive at once (Mt SAC, Ohio Expo). This page records how
we measure it, what one local run showed, and what that run can't tell you. The script is
`scripts/loadtest.mjs` (`npm run loadtest`); the waiting room it exercises is described in
[`organizer-guide.md`](organizer-guide.md) "Waiting room for big on-sales" and
[`security.md`](security.md) "Waiting room".

## Method

Each **virtual user (VU)** is one buyer's browser, run as async code in one Node process:

1. arrives at a random moment of a 20-second ramp (the on-sale lands halfway, so half the crowd is early
   and gets a random place in the draw, half is late and joins at the back);
2. reads the event page: the event and its ticket types (`exos_public_events`, `exos_public_tiers`);
3. joins the waiting room (`exos_wroom_join`: token mint, rate limited per network; every VU has its own
   address);
4. polls `exos_wroom_status` at the pace the server suggests (30 s far back, 15 s, then 5 s near the
   front; the lobby wakes up spread over 15 s after the on-sale), with ±25 % jitter, in real time;
5. once admitted, runs **exos-checkout's SQL before Stripe**, one request each, as the service role:
   `exos_wroom_require`, the tier read, `exos_public_event_sale`, `exos_assert_purchase_limit_email`,
   `exos_tier_current_price`, `exos_create_guest_hold` (2 tickets, the queue token in `x-exos-queue`)
   and `exos_event_fee_terms`. **Payment is stubbed**: nothing calls Stripe; the holds just expire.

Every request is one transaction on a shared pool of 40 connections with the role, JWT claims and
headers set as GUCs, which is what PostgREST does. Latency is measured from asking for a connection to
the commit, so it includes waiting for the pool, as a buyer behind PostgREST would. A step lasts at most
120 s; VUs still in line at the end are counted as `in_line`, not as errors.

Rows: `event_read` (each of the two page reads), `token_mint`, `poll`, `checkout_sql` (the six non-hold
checkout calls), `hold` (the guest hold alone) and `checkout_pre_stripe` (all seven, end to end).

## The machine

| | |
|---|---|
| Where | The build sandbox: one VM, the load generator and the database on the same 4 vCPUs |
| CPU / memory | 4 × Intel Xeon @ 2.10 GHz, 16 GB |
| Database | PostgreSQL 16.15, local socket, stock settings (`max_connections` 100, `shared_buffers` 128 MB), built by `tests/exos/run_p0.sh` (every Exos migration) |
| Client | Node 22.22, `pg` 8.23.1 |
| Event | One event, one ticket type of 1,000,000 (capacity never runs out), admission 10 minutes |
| Run | 2026-11-17 |

## Results

### The room paced at 1,200 a minute (20 checkouts a second)

`npm run loadtest -- --steps 100,1000,5000,10000 --rate 1200 --max-step 120`, on the final code (one buyer per
turn, the per-network and room caps), plus a second 10,000 run:

| VUs | Op | Requests | p50 ms | p95 ms | p99 ms | Errors |
|---|---|---|---|---|---|---|
| 100 | event_read | 200 | 3.1 | 5.7 | 8.6 | 0 % |
| 100 | token_mint | 100 | 2.8 | 6.3 | 8.5 | 0 % |
| 100 | poll | 106 | 1.7 | 4.2 | 6.3 | 0 % |
| 100 | hold | 100 | 5.5 | 7.6 | 9.6 | 0 % |
| 100 | checkout_pre_stripe | 100 | 14.0 | 19.6 | 25.1 | 0 % |
| 1,000 | event_read | 2,000 | 2.7 | 4.7 | 6.3 | 0 % |
| 1,000 | token_mint | 1,000 | 2.4 | 4.5 | 8.4 | 0 % |
| 1,000 | poll | 4,168 | 1.3 | 2.6 | 5.3 | 0 % |
| 1,000 | hold | 1,000 | 10.0 | 19.9 | 28.7 | 0 % |
| 1,000 | checkout_pre_stripe | 1,000 | 17.3 | 29.0 | 36.4 | 0 % |
| 5,000 | event_read | 10,000 | 2.9 | 13.2 | 31.2 | 0 % |
| 5,000 | token_mint | 5,000 | 3.5 | 21.1 | 44.8 | 0 % |
| 5,000 | poll | 45,004 | 2.3 | 8.1 | 12.8 | 0 % |
| 5,000 | hold | 2,325 | 21.2 | 58.4 | 86.5 | 0 % |
| 5,000 | checkout_pre_stripe | 2,325 | 33.2 | 74.5 | 105.2 | 0 % |
| 10,000 | event_read | 20,000 | 73.6 | 2,400 | 2,718 | 0 % |
| 10,000 | token_mint | 10,000 | 97.6 | 2,820 | 2,891 | 0 % |
| 10,000 | poll | 72,106 | 3.9 | 2,245 | 2,741 | 0 % |
| 10,000 | hold | 2,323 | 29.2 | 958.6 | 1,725 | 0 % |
| 10,000 | checkout_pre_stripe | 2,323 | 43.5 | 9,361 | 13,466 | 0 % |
| 10,000 (run 2) | event_read | 20,000 | 182.9 | 1,473 | 1,534 | 0 % |
| 10,000 (run 2) | token_mint | 10,000 | 199.1 | 1,529 | 1,598 | 0 % |
| 10,000 (run 2) | poll | 73,475 | 4.1 | 700.3 | 1,485 | 0 % |
| 10,000 (run 2) | hold | 2,325 | 27.2 | 549.1 | 1,464 | 0 % |
| 10,000 (run 2) | checkout_pre_stripe | 2,325 | 44.0 | 4,670 | 7,776 | 0 % |

Every VU got a token and a place; no request failed. At 5,000 and 10,000 VUs the room let in 20 a
second as set (about 2,325 holds in the step) and the rest were still in line, with a correct place,
when the step ended.

**Headline.** 5,000 buyers arriving in 20 seconds: event page p95 13 ms, queue join p95 21 ms, queue
poll p95 8 ms, hold p95 58 ms, checkout SQL before Stripe p95 75 ms, 0 errors. 10,000 buyers in 20
seconds: 0 errors, poll p50 4 ms and hold p50 29 ms, but p95 of 1.5-2.8 s on the page read, the join
and the poll across two runs. That is the arrival burst (500 new buyers a second, each a page read, a
join and a poll) saturating this 4-vCPU box, which also runs the 10,000 VUs: every request waits for
one of the 40 connections. An earlier 10,000 run, before the one-buyer-per-turn and cap checks,
measured p95 288 ms (page), 303 ms (join), 82 ms (poll), 167 ms (hold) and 0.8 s (checkout SQL); the
gap between runs on this shared sandbox is as large as the gap between versions, so treat the 10,000
p95s as "about 0.3 to 3 s at the arrival peak on 4 vCPUs", to be measured on the real instance.

### The room set faster than checkout can go (3,000 a minute)

`npm run loadtest -- --steps 5000,10000 --rate 3000 --max-step 120` (run before the one-buyer-per-turn and cap checks)

| VUs | Op | Requests | p50 ms | p95 ms | p99 ms | Errors |
|---|---|---|---|---|---|---|
| 5,000 | event_read | 10,000 | 2.9 | 17.9 | 71.6 | 0 % |
| 5,000 | poll | 36,251 | 62.6 | 4,869.5 | 14,905.3 | 0 % |
| 5,000 | hold | 5,000 | 1,951.3 | 18,291.6 | 25,770.2 | 0 % |
| 5,000 | checkout_pre_stripe | 5,000 | 6,029.6 | 40,254.0 | 50,781.0 | 0 % |
| 10,000 | event_read | 20,000 | 24.5 | 1,379.7 | 1,643.7 | 0 % |
| 10,000 | poll | 64,633 | 2,501.3 | 11,387.8 | 17,638.0 | 0 % |
| 10,000 | hold | 6,440 | 5,080.5 | 32,036.5 | 46,286.6 | 0 % |
| 10,000 | checkout_pre_stripe | 6,440 | 30,102.2 | 91,872.0 | 101,560.6 | 0 % |

Nothing failed, but admitting 50 a second is more than one event's hold path does on this machine
(about 30 a second, see below): admitted buyers pile up behind the hold, take the pool's connections,
and every other request waits for one. **The admit rate is the knob**: set it below what checkout can
take and everything else stays fast.

## What the run found

- **The hold path is the ceiling, not the queue.** Holds for one event serialize on the ticket type's
  row lock and the guest-hold ceiling lock, and inside them `exos_event_house_available` and the guest
  ceiling sum every live hold of the event: with 5,000 live holds one guest hold took 37 ms
  (`exos_event_house_available` alone 30 ms). That puts one event at roughly 25-35 holds a second here,
  falling as holds pile up. Making those counts incremental (a counter row, as `sold` is) is the change
  that raises the ceiling; it touches the shared checkout functions, so it is a separate change.
- **Polls are cheap when they are polite.** The first 10,000 run, before two pacing changes, had poll
  p95 above 1.8 s: early arrivals all asked again one second after the on-sale, and people far back
  polled every 15 s. Spreading the lobby's wake-up over 15 s and polling every 30 s while the wait is
  over 5 minutes cut poll p95 to 82 ms at the same load.
- **Suggested default:** 200 a minute is safe for any event; up to about 1,200 a minute (20 a second)
  kept every path under a second at p95 here. Re-measure on the real instance before quoting a higher
  rate.

## Honest limits of a local run

- One VM runs both the load and the database, on 4 vCPUs: the generator competes with Postgres.
- No PostgREST, no Supabase API gateway, no TLS, no network latency, no edge-function cold starts: the
  numbers are the database's share of each request. A real request adds the network round trip and the
  gateway, typically tens of milliseconds.
- `exos-checkout` itself (Deno) was not served: its SQL was replayed in the same order. Its other work
  (body parsing, the Stripe call, which is stubbed) is not measured.
- Stock Postgres settings and 40 pooled connections; Supabase instances have tuned settings and a
  pool sized by compute (Supavisor), so absolute numbers will differ in both directions.
- One event and one ticket type, a guest buyer every time; no seated types, add-ons, vouchers or price
  steps.
- The browser side (page weight, CDN) is not part of it.

## Running it again

Locally, against a database built by the harness:

```bash
bash tests/exos/run_p0.sh exos_loadtest        # every migration, then the suites (rolled back)
npm run loadtest -- --db exos_loadtest --steps 100,1000,5000,10000 --rate 1200 --out results.json
```

Flags: `--steps`, `--pool` (default 40), `--ramp` (seconds, default 20), `--rate` (admits a minute,
default 3,000), `--poll-scale` (1 = real time), `--max-step` (seconds, default 90), `--out`. The fixture
(one org, one event, one ticket type) is created on first run; holds and queue rows are cleared after.

**Against a Supabase staging branch** (the operator creates it; never the shared prod project, which the
script refuses by its project ref):

1. Create a branch of the project and let it apply the migrations (the branch replays `supabase/migrations`).
2. Take the branch's **direct** Postgres connection string (Session mode on port 5432 also works; the
   script uses session GUCs inside each transaction, so transaction-mode pooling on 6543 works too).
3. Run from a machine near the branch's region, not from a laptop on Wi-Fi:

   ```bash
   LOADTEST_TARGET=staging LOADTEST_DATABASE_URL='postgresql://postgres:…@db.<branch-ref>.supabase.co:5432/postgres' \
     npm run loadtest -- --steps 100,1000,5000,10000 --rate 1200 --pool 40 --out staging.json
   ```

   Set `--pool` to the branch's PostgREST pool size to model it, or higher to find the database's limit.
4. To include the edge function and the gateway, deploy `exos-checkout` to the branch with Stripe in
   test mode and point a copy of the VU's checkout step at it over HTTPS (with `EXOS_REDIRECT_ORIGINS`
   set); keep Stripe in test mode, and stop before the hosted page.
5. Delete the branch when done. The script never runs in CI.
