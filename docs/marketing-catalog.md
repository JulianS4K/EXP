# Ad catalogs and custom audiences

Two things organizers need to run paid ads beyond the pixel:

1. **Catalog feed**: their upcoming events as a product catalog, so Meta, TikTok and Google can run catalog
   (dynamic / retargeting) ads that show the exact event a person looked at.
2. **Audience export**: a hashed customer list of their consenting buyers, to build custom and lookalike audiences.

Both are **pull / download only**: Exos never pushes anything to an ad platform's API. Where to find them:
Settings → **Catalog feed** and **Audience export** (under Marketing & socials).

| | Code | Tests |
|---|---|---|
| Catalog feed | `supabase/functions/exos-catalog-feed/index.ts` (reads and serves), `supabase/functions/_shared/catalog/feed.ts` (pure builders), `src/components/CatalogFeedPanel.tsx` | `src/lib/catalog/feed.test.ts` |
| Audience export | mig `20260930101000_exos_audience_export.sql` (`exos_org_audience_export`, `exos_audience_exports`), `src/lib/audienceCsv.ts`, `src/components/AudienceExportPanel.tsx` | `tests/exos/test_audience_export.sql`, `src/lib/audienceCsv.test.ts` |

Status: the migration is **not applied** and the function is **not deployed** (see "Going live").

## Catalog feed

```
GET https://<project>.supabase.co/functions/v1/exos-catalog-feed/<org_slug>.csv                 Meta (CSV)
GET https://<project>.supabase.co/functions/v1/exos-catalog-feed/<org_slug>.csv?format=tiktok   TikTok (CSV)
GET https://<project>.supabase.co/functions/v1/exos-catalog-feed/<org_slug>.xml                 Google Merchant Center (RSS 2.0)
GET https://<project>.supabase.co/functions/v1/exos-catalog-feed/<org_slug>.xml?format=meta     Meta (RSS 2.0)
```

`format` defaults to `meta` for `.csv` and `google` for `.xml`. TikTok is CSV only and Google XML only; the wrong
pairing is a 400 that says which one to use.

### What's in it

One item per **published** event of the org that hasn't ended (no end time = over six hours after the start), has
at least one public ticket type, and has an https image. Hidden (code-unlocked) ticket types never count.

| Field | Meta CSV | TikTok CSV | Google RSS | Value |
|---|---|---|---|---|
| id | `id` | `sku_id` | `g:id` | The Exos event id. It is exactly what the pixels send as `content_ids` (ViewContent, InitiateCheckout, Purchase), so the platforms join ad events to items |
| title | `title` | `title` | `title` | The marketplace-clean title (`eventStandard.ts marketTitle`), at most 150 chars |
| description | `description` | `description` | `description` | Summary + description as plain text (no HTML), at most 5,000 chars; if empty, "<title> at <venue>, <city>, <date>. Tickets on Exos." (Meta wants it to differ from the title) |
| availability | `in stock` / `out of stock` / `preorder` | same | `in_stock` / `out_of_stock` / `preorder` + `g:availability_date` | In stock when a public tier is on sale with seats left; preorder when every open tier's sales start later (the date is the earliest start); otherwise out of stock (also when the event is at capacity) |
| condition | `new` | `new` | `g:condition` | Always `new` |
| price | `price` | `price` | `g:price` | "21.78 USD": the **lowest all-in price you can buy now**, i.e. the storefront's "from" price (`buyerTierPrice`: scheduled price in force + exclusive tax; Exos adds no buyer fee), over the tiers on sale; for a presale, over the upcoming tiers; else over all tiers |
| link | `link` | `link` | `link` | The event page (`/e/<slug>`, else `/event/<id>`) with `utm_source=<meta\|tiktok\|google>&utm_medium=paid_social&utm_campaign=catalog&utm_content=<event id>`, so catalog sales show in the Sources report |
| image | `image_link`, `additional_image_link` | same | `g:image_link`, `g:additional_image_link` | The cover image, else the first gallery image; the other gallery images as extras (up to 10). http images are dropped |
| brand | `brand` | `brand` | `g:brand` | The organizer's name |
| category | `product_type` | `product_type` | `g:product_type` | "Event Tickets > Concerts" (Nightlife, Comedy, Theater, Sports, Festivals, Events) |
| event fields | `custom_label_0`…`4` | same | `g:custom_label_0`…`4` | 0 local start date (`2026-11-06`), 1 venue, 2 city, 3 category, 4 `this_week` / `this_month` / `later`: filter product sets on these (e.g. "this week, Brooklyn") |
| — | — | — | `g:identifier_exists` = `no`, `g:expiration_date` | Tickets have no GTIN / MPN; the item expires at the event's end |

CSV is RFC 4180 (UTF-8, CRLF, fields with commas, quotes or line breaks quoted, quotes doubled); XML text is escaped
and characters XML 1.0 forbids are removed.

### How it reads data

- The function reads **only the public views** (`exos_public_orgs`, `exos_public_events`, `exos_public_tiers`) with the
  **anon key**, so it can only serve what the event page already shows. The service role is used only for the rate
  limiter (`exos_rate_hit`).
- 30 calls a minute per network; if the limiter errors, calls are refused (503). Responses are
  `Cache-Control: public, max-age=900`, like the Google events feed.
- `?report=1` with `Authorization: Bearer <service role key>` lists the org's events that were left out and why
  (no image, no public tiers, over).
- Up to 500 events per org. Unknown org → 404; unexpected errors return "something went wrong" and the detail goes
  to the function log, redacted.

### Connecting it

- **Meta** (Commerce Manager → Catalog → Data sources → Data feed → Scheduled feed): paste the `.csv` URL, pick a
  daily or hourly schedule, currency from the feed. Link the catalog to the org's pixel (Events Manager) so
  `content_ids` match; then run Advantage+ catalog ads.
- **TikTok** (Catalog Manager → Add products → Data feed → Scheduled): paste the `?format=tiktok` URL; link the
  TikTok pixel to the catalog.
- **Google Merchant Center** (Products → Add product source → File → "Add a link to a file"): paste the `.xml` URL.
  **Caveat:** Google's "Unsupported Shopping content" policy lists future event tickets (concerts, sports) as not
  allowed in Shopping ads *or* free listings, so expect item disapprovals there. The feed is still the standard GMC
  RSS format that other tools import (for example Performance Max asset feeds or third-party feed managers), and
  Exos events reach Google Search / Maps through the separate events feed (`docs/google-events.md`). YouTube ads run
  through Google Ads, so the same caveat applies.

### Unverified

- Whether Meta and TikTok approve event-ticket items in every market (their commerce policies change; a rejected
  item shows the reason in Commerce Manager / Catalog Manager).
- TikTok's handling of the optional columns (`additional_image_link`, `product_type`, `custom_label_*`); the nine
  required ones are verified.

## Audience export

`exos_org_audience_export(p_org_id uuid, p_event_id uuid default null)` → one jsonb
`{count, generated_at, rows: [{email_sha256, phone_sha256, phone_digits_sha256}]}` (a single value, so PostgREST's
max-rows cap can't cut a long list). The panel turns it into the platform's CSV and downloads it.

### Who is on the list

Buyers with a fulfilled (or partly refunded) order from the org (or from `p_event_id`) who granted advertising consent
at checkout (`exos_checkout_sessions.consent_marketing = 'granted'`, the advertising category of the cookie banner),
and whose **latest** consent choice at the org's checkouts isn't `denied` (a later "no" removes an earlier "yes").
Following an org does **not** count: it opts a buyer into the org's emails only, and uploading to an ad platform is a
separate purpose (operator decision 2026-09-30).
Always left out: anyone who unsubscribed from marketing email (`exos_mail_prefs.marketing_opt_out`, matched by account
and by the account's email, so a guest order with an opted-out address is dropped too), deleted accounts (the
`deleted+…@deleted.invalid` tombstone), and pending / expired / failed orders.

### Only hashes

- Email: `sha256(lower(trim(email)))`, hex. For a guest the session's email; for a signed-in buyer the session's
  email, else the account's.
- Phone: only signed-in buyers with a phone on their account (checkout collects none). Digits with the country code,
  leading zeros dropped, 8 to 15 digits; `phone_sha256` = sha256("+15551234567") for Google and TikTok,
  `phone_digits_sha256` = sha256("15551234567") for Meta. The harness checks Meta's own published example
  ((650)555-1212 → `e323ec62…3176`).
- No raw email or phone ever leaves the database; the client also refuses a response with anything but 64-char hex.

### Guard rails

- Owner / manager of the org only (finance, scanners and platform admins without a role get 42501).
- 3 exports a minute per org (`exos_rate_hit`) and 20 a day per org.
- Every export is logged in `exos_audience_exports` (org, event, who, row count, when; no hashes), readable by the
  org's owners / managers.

### File formats

| Platform | Header row | Phone column |
|---|---|---|
| Meta (Ads Manager → Audiences → Custom audience → Customer list) | `email,phone` | `phone_digits_sha256` |
| Google Ads Customer Match (Tools → Audience manager → Customer list → upload) | `Email,Phone` | `phone_sha256` |
| TikTok (Assets → Audiences → Custom audience → Customer file → multi-ID) | `email_sha256,phone_sha256` | `phone_sha256` |

A row without a phone leaves the cell empty. Platforms need a minimum matched size before an audience serves
(TikTok documents 1,000 entries per file).

Normalization is the common one (trim + lower-case). Google also documents removing dots in gmail.com addresses and
TikTok removing "+tag" suffixes before hashing; Exos doesn't, so a few of those addresses may not match (never a
wrong match).

## Going live (operator)

1. Apply `20260930101000_exos_audience_export.sql` (needs permission). Pre-reqs: `20260929131000`,
   `20260926060000`, `20260520140000`; it uses `exos_rate_hit` from `20260929060000` when present.
2. Deploy `supabase functions deploy exos-catalog-feed --no-verify-jwt` (needs permission) with `EXOS_APP_BASE_URL`
   (https) set; `SUPABASE_ANON_KEY` is provided by the platform. Check with
   `curl -sI …/exos-catalog-feed/<slug>.csv` and the `?report=1` view.
3. Build and ship the SPA bundle for the Settings panels.
4. Privacy policy (`/privacy`): say that organizers may upload hashed contact details of consenting buyers to ad
   platforms (the export's consent note tells organizers the same).

## Sources (checked 2026-09-30)

Direct fetches of the platforms' help pages were blocked from the build environment; the field lists below were
confirmed through search results quoting these pages.

- Meta catalog fields (required: id, title, description, availability, condition, price, link, image_link, brand;
  CSV, TSV, RSS/Atom XML accepted): Meta Commerce Manager "data feed" field specs, as summarized by
  [AdTribes](https://adtribes.io/facebook-product-feed-specifications/) and
  [Channable](https://helpcenter.channable.com/hc/en-us/articles/360017116939).
- TikTok catalog (nine required fields, `sku_id`, price as "29.99 USD"):
  [Catalog product parameters](https://ads.tiktok.com/help/article/catalog-product-parameters).
- Google Merchant Center RSS 2.0 with `xmlns:g="http://base.google.com/ns/1.0"`:
  [RSS 2.0 specification](https://support.google.com/merchants/answer/14987622),
  [Create a product file](https://support.google.com/merchants/answer/12631822).
- Google Shopping and event tickets: [Unsupported Shopping content](https://support.google.com/merchants/answer/6150006).
- Meta hashing and phone normalization (digits with country code, no symbols or leading zeros, unsalted SHA-256):
  [Customer information parameters](https://developers.facebook.com/docs/marketing-api/conversions-api/parameters/customer-information-parameters).
- Google Customer Match headers (Email, Phone, First Name, Last Name, Country, Zip) and hashed phone in E.164 with
  "+": [Format your customer data file](https://support.google.com/google-ads/answer/7659867),
  [Create a Customer Match list](https://support.google.com/google-ads/answer/10589050).
- TikTok customer files (`Email_SHA256` / `Phone_SHA256`, phone in E.164, multi-ID files, 1,000-entry minimum):
  [Supported IDs and formats](https://ads.tiktok.com/help/article/list-of-supported-ids-and-formats-for-a-customer-file),
  [Customer file guidelines](https://ads.tiktok.com/help/article/customer-file-faq).
