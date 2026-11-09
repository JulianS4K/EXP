# Checkout questions

Organizers ask buyers questions at checkout: "T-shirt size?", "Dietary needs?", "Company name", "I agree to the
venue's photo policy". The answers are kept on each order and each ticket. The organizer sees them in the event report
and the attendee export, door staff see a ticket's answers when it scans, and the partner API returns them. DICE's
equivalent is `Ticket.fanSurveyAnswers { fanSurveyQuestion { title } value }` (KANBAN "DICE gaps" 2).

| Piece | Where |
|---|---|
| Schema, rules, recording, grants | `supabase/migrations/20261106110000_exos_checkout_questions.sql` |
| SQL tests | `tests/exos/test_checkout_questions.sql` (CQ1-CQ12, run by `tests/exos/run_p0.sh`) |
| Answer rules (TS, shared) | `supabase/functions/_shared/questions.ts`; parity with the SQL in `src/lib/checkoutQuestions.test.ts` |
| SPA data + helpers | `src/lib/checkoutQuestions.ts` |
| Buyer form | `src/components/CheckoutQuestionsForm.tsx` (event page, embed, phone RSVP, door) |
| Builder | `src/components/QuestionBuilder.tsx` (event editor) |
| Answers table + CSV | `src/components/QuestionAnswersPanel.tsx` (event report, Attendees tab); answer columns in the attendee CSV |
| Door | `src/components/TicketAnswersCard.tsx` (scan result) |
| Partner API | `supabase/functions/exos-api/questions.ts`; reference `docs/api/questions.json` (/developers) |

Design references: pretix's `Question` / `QuestionAnswer` and hi.events' questions that belong to an order or a
product (both AGPL; nothing copied). From them: required vs optional, per order vs per attendee, a question limited to
some ticket types, hidden questions (staff only), archived questions keeping their answers, and an answer that
snapshots the question's wording.

## Questions

`exos_event_questions`, one row per question of an event:

| Field | Meaning |
|---|---|
| `label`, `help_text` | What buyers read (1-200 / up to 500 characters) |
| `kind` | `text`, `long_text`, `single_choice`, `multiple_choice`, `checkbox` ("I agree"), `number`, `date`, `phone`, `email` |
| `options` | Choice kinds only: 2 to 50 distinct options |
| `required` | Must be answered; a required checkbox must be ticked |
| `scope` | `order` (asked once) or `ticket` (asked for every ticket; a table ticket type is asked once per seat) |
| `tier_ids` | Only for these ticket types (NULL: all). An order-wide question limited to VIP is asked when the order has a VIP ticket |
| `max_length` | text: 1-2000 (default 500); long_text: 1-5000 (default 2000) |
| `min_choices`, `max_choices` | multiple_choice |
| `min_value`, `max_value` | number |
| `hidden` | Not asked at checkout; staff fill it at the door. Answers are kept and shown |
| `archived_at` | "Deleted": no longer asked, every answer kept, restorable |

At most 50 questions per event that aren't archived. Writes go through `exos_save_event_question` /
`exos_archive_event_question` / `exos_reorder_event_questions` (owner or manager of the event's org) and the API; the
table has no client write grant.

### Show only if… (mig 20261107110000)

A question can depend on another: `parent_question_id` plus `parent_values`, the parent's answers that show it.
"Your guest's name" is asked only when "Bringing a guest?" is answered Yes.

- The parent is a `single_choice`, `multiple_choice` or `checkbox` question of the same event that isn't archived.
  The values are its options (any picked one of a multiple choice shows the child); for a checkbox, `["true"]`
  (ticked).
- A per-order question depends only on a per-order question. A per-ticket question may depend on a per-order
  question (shown on every ticket when the order's answer matches) or a per-ticket one (the same ticket's answer).
- No loops, at most 10 levels. A parent with questions depending on it can't be archived, change its kind or scope,
  or drop an option they use: change them first.
- A hidden question is never required, and whatever was sent for it is dropped. A shown one follows every usual
  rule. A parent the buyer isn't asked (hidden, archived, another ticket type) hides the child.
- The rule is `_exos_question_hidden` in SQL and `hiddenQuestions` in `_shared/questions.ts`;
  `tests/exos/test_dice_gaps_6.sql` (DG6-CASES) and `src/lib/conditionalQuestions.test.ts` run the same cases
  through both. The free-claim guard counts only questions every buyer is asked.

### Changing a question after sales

- Renaming keeps every answer with the label the buyer saw (`exos_question_answers.label`); the report shows today's
  label next to it.
- The kind and the scope can't change once a question has answers: archive it and add a new one.
- Removing an option keeps the answers that chose it.
- Making a question required changes nothing for orders already placed: answers are checked when they are recorded.
- Deleting archives.

## Answers

`exos_question_answers`, one row per answer: the order (`order_ref`, the tickets' `order_ref`: the checkout session
id, a free claim's ref, `rsvp:<id>`, `po:<id>`), the ticket (`ticket_index`, 1-based in mint order, and `ticket_id`
once minted) for per-ticket answers, the question with its `label` and `kind` at purchase, the normalised `value`
(text, a number, `true`, or a list of options in the options' order), `display` (the same as text: `Yes`, `Vegan,
Halal`), `source` (`checkout`, `free_claim`, `rsvp`, `door`, `api`) and the buyer.

Rules (the same in `_exos_validate_answers_core` and `_shared/questions.ts`): an unknown, hidden or archived question is
refused, as is an order question answered per ticket (or the reverse), a question for another ticket type, more ticket
entries than tickets, a choice that isn't an option, text over its length, too many or too few choices, a number out
of range or with more than 6 decimals, a date that isn't a real `YYYY-MM-DD` (1900-2100), a phone without 7 to 15
digits, an email without `@` and a dot. Text is trimmed; blank, `false` and `[]` mean "not answered".

### When they are recorded

Answers are stored before the tickets exist, so nothing depends on the browser. exos-checkout checks the body's
`answers` with the shared rules before it creates a hold or a payment, then stores them on the pending order
(`exos_record_checkout_answers`, which checks again) right after the order row is written, for every path: Stripe
(hosted and embedded), PayPal, a gift card that pays it all, and a guest's free claim. A trigger on `exos_tickets`
(`exos_tickets_question_answers`) gives the n-th ticket minted for an order the answers of ticket n, so a buyer who
pays and comes back hours later, a late webhook, and the proof-of-email release (which moves the same tickets to the
buyer) all keep them. The buyer can read an order's answers once its tickets are theirs (`buyer_uid`).

| Entry point | How |
|---|---|
| Paid checkout | `exos-checkout` body `answers: { order: {...}, tickets: [{...}] }` |
| Free claim (signed in) | `exos_claim_free_tickets_answered`; the plain `exos_claim_free_tickets` refuses an event with required questions |
| Phone RSVP | `exos-rsvp` "info" returns the questions, "start" takes `answers` (one entry per guest incl. plus-ones); a refusal expires the RSVP |
| Organizer reservations (API) | `answers` on POST /v1/events/:id/organizer-reservations/:token/complete; checked, never required |
| The door | `exos_door_set_ticket_answers` (door staff of the event; per-ticket questions, hidden ones included, nothing required) |

Not covered: POS walk-up mints (`exos-pos` doesn't mint tickets yet: its `mint_walkup` answers 501); comps, box-office
and member-pass issues (staff can add answers at the door); partner (`/public/...`) reservations.

Only the order's own tickets take its answers: the trigger requires the ticket's buyer to be the order's buyer, or
the ticket to be parked on the org owner for an order with no buyer (guest, RSVP, reservation) or for that buyer's own
checkout session (an unconfirmed account). `exos_claim_free_tickets`, the answered claim and
`exos_record_checkout_answers` refuse an order ref whose answers belong to someone else. A validation error names only
the validated event's own questions, and never an unknown question.

Answers of a checkout that never paid stay unattached (`attached_at` NULL) and are left out of the report and the API.

## Who sees what

| Who | Reads |
|---|---|
| Owner, manager, finance | Every answer of the org (RLS), the answers table (`exos_event_question_answers`) and the CSVs |
| The buyer | Their own answers |
| Door staff (owner, manager, a scanner of the event) | Per-ticket answers of that event ("needs wheelchair access") |
| Anyone | The questions of a published event (`exos_public_event_questions`, H3 allowlist); never answers |

## API

docs/api/questions.json: questions CRUD on `/v1/events/:id/questions` and `/v1/questions/:id` (events:read /
events:write; DELETE archives), `PUT /v1/events/:id/questions/order`, the answers table on
`GET /v1/events/:id/question-answers` (orders:read, paged), `GET /v1/orders/:id/answers` (orders:read) and
`GET /v1/tickets/:id/answers` (tickets:read). Every ticket in the attendees, order and ticket answers carries
`answers`: its own per-ticket answers, and its order's only for a credential with orders:read. The credential's scopes
decide, never its user's or creator's role (`_shared/api/questionAnswers.ts`). A tickets:read-only door or
check-in integration sees per-ticket answers only. DICE mapping: `fanSurveyQuestion.title` = `label`, `value` = `display`.
