# Languages (English and Spanish) and the review checklist

Exos speaks English and Spanish. This page owns how that works, what is translated today, and the human review that
Spanish money and legal wording needs before launch. Status in the facts registry: `spanish`, Not shipped
(`docs/ai-facts.md`): built on `claude/exos-spanish`, migration `20261114130000_exos_event_i18n` not applied.

Why Spanish first: the NYC Latin and Caribbean party segment, and California / Texas fairs where buyers and door staff
are Spanish-first (`docs/strategy.md`, `docs/competition.md`).

## How it works

- **Strings.** `src/lib/i18n/dict.ts` holds the dictionary: flat dot keys, `{name}` placeholders, English the fallback.
  Surfaces have their own files merged into it: `checkout.ts` (buy box, checkout, sending a ticket, wallet buttons),
  `door.ts` (scanner, refusal reasons, check-in by name, offline banners), `pos.ts` (the door till). A key added to
  English must be added to Spanish: TypeScript refuses the build otherwise, and `src/lib/i18n/dict.test.ts` checks
  every buyer, door and POS key has non-blank Spanish with the same placeholders.
- **Which language.** `context/LanguageContext.tsx`: the switcher's choice (kept in `localStorage`), else the device
  (`navigator.language` starting with `es`), else English. It sets `<html lang>`, which screen readers use. Signed in,
  the choice is also saved on the account (`user_metadata.lang`) for mail. A component rendered without the provider
  (an embed, a unit test) is English.
- **The order's language.** Checkout sends the page's language (`lib/checkout.ts` `recordBody`); `exos-checkout`
  records it on the order (`exos_checkout_sessions.lang`) and opens Stripe's page in Spanish (`locale: 'es'`).
- **Mail.** About twenty SQL functions queue buyer mail in English. None is changed: a trigger on `exos_mail` stamps
  `lang` on buyer mail (the recipient's latest order language, else their account's, else English; organizer mail
  gets none). `exos-mail-drain` then sends Spanish when it has it:
  - payload mail (`_shared/mail-templates.ts` `RENDERERS_ES`): cancelled, updated, refund issued, after the event;
  - SQL-built mail (`_shared/mail-es.ts`): order confirmation and receipt, claim links, order failed, transfers, the
    door's mail. All or nothing: if the subject or any sentence is unknown, the English row goes as queued, so a
    mail is never half Spanish. The stored row stays English (dedupes that compare subjects keep working).
  - Everything else (reminders, waitlist, rescheduled, abandoned checkout) is English for now.
- **Event fields.** `exos_events.i18n` = `{"es": {"title"?, "description"?}}`. Owners and managers set it in the
  editor (Edit event → Spanish version); it rides the event's own grants and RLS. The database refuses anything else
  (`_exos_event_i18n_ok`: only `es`, only the two fields, non-blank, title ≤ 200 without control characters,
  description ≤ 20,000). The public reads it on published events only (`exos_public_events`). The event page shows
  the Spanish title / description to a Spanish visitor, field by field, else the default; the Google events feed
  does the same with `?lang=es` (`inLanguage: "es"`). The calendar and listing feeds are English.

## What is in Spanish today

| Surface | Status |
|---|---|
| Navbar, event page, buy box, all-in price line, fees, add-ons, waitlist, promo / gift card / donation, checkout questions and their errors, guest checkout | Spanish |
| Tickets, ticket pass, Alerts, claim page, sending a ticket, wallet buttons | Spanish |
| Stripe's checkout page | Spanish (Stripe's own) |
| Buyer mail: confirmation + receipt, claim links, order failed, transfers, door sales, cancelled, updated, refund, after the event | Spanish, after review |
| Door scanner: results, refusal reasons, by-name check-in, offline banners, scan log | Spanish |
| Door till (Sell tab): sale, cash, card status, drawer | Spanish; reader and kiosk setup English |
| Organizer dashboard, editor, reports | English (the editor has the Spanish fields) |
| Server error messages (e.g. "sold out" from checkout) | English, shown as sent |

## Review checklist (before launch)

Nothing below ships as a machine translation alone. A Spanish speaker (US Spanish, NYC / CA / TX readers) checks each
item and initials it here. `REVIEW_KEYS` in `src/lib/i18n/dict.ts` lists the dictionary keys; the test fails if one
disappears.

- [ ] **Refund policy** (`page.refund.*`): "No hay reembolsos", "hasta 7 días antes", etc. Legal wording.
- [ ] **All-in price and fees** (`checkout.allIn*`, `checkout.feesIncluded`, `checkout.priceRises`, `checkout.limits`):
  "precio final" for all-in; "cargos" for fees. Must say nothing is added at checkout.
- [ ] **Stored value** (`checkout.giftCode`, `checkout.giftHave`, `checkout.giftApplied`, `checkout.donationNote`):
  gift card wording, what the card covers, donations after tax.
- [ ] **Guest checkout promise** (`guest.paidBody`, `guest.freeBody`) and **sending a ticket** (`transfer.warning`,
  `transfer.shareBody`): permanent, who gets it.
- [ ] **Door** (`door.voided`): refunded ticket, not admitted.
- [ ] **Door till money** (`pos.inclTax`, `pos.card.*`, `pos.cardOff`): tax, declined / refunded card.
- [ ] **Terms checkbox:** checkout has none today (organizers' "I agree" questions are written by them, in their
  language); the sign-up modal's terms line is still English. Translate with Legal when it moves.
- [ ] **Mail, money parts** (`_shared/mail-es.ts` and `RENDERERS_ES`, marked `REVIEW` in the code): the receipt
  ("Pagado", "Referencia del pedido", "Precio final… no se agregó nada al pagar"), refund timing ("de 5 a 10
  días"), order failed ("Te estamos reembolsando el pago completo"), the cancelled-event refund lines.
- [ ] Read one of each mail in a real inbox (Gmail, iOS Mail) with a long event name.

## Adding a string or a language

- New UI text: add the key to the right file in both languages, use `t('key', { vars })`. Keep placeholders the same.
- New buyer mail built in SQL: add its sentences to `_shared/mail-es.ts` and a fixture to `src/lib/mailEs.test.ts`;
  until then it goes in English (never half translated).
- A third language: add it to `Lang`, `DICTS`, the switcher, the `lang` CHECKs (`exos_checkout_sessions`,
  `exos_mail`) and `_exos_event_i18n_ok`. Same review.
