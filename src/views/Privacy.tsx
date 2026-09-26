import { Link } from 'react-router-dom';
import LegalPage from '../components/LegalPage';
import { LEGAL } from '../lib/legal';

// DRAFT for counsel review (see lib/legal.ts). Keep it in step with what the
// product collects: a new data flow means a new line here.
export default function Privacy() {
  const mail = <a className="text-brand-primary" href={`mailto:${LEGAL.contactEmail}`}>{LEGAL.contactEmail}</a>;
  return (
    <LegalPage
      title="PRIVACY"
      accent="POLICY"
      intro={
        <p>
          {LEGAL.entity} (“Exos”, “we”) runs a ticketing platform for live events. This policy explains what
          personal information we collect when you buy, claim, transfer or scan tickets, or run events on Exos,
          how we use it, who we share it with, and the choices you have. We don’t sell your personal information.
        </p>
      }
      sections={[
        {
          title: 'What we collect',
          body: (
            <ul>
              <li><strong>Account:</strong> your email address, and the display name you choose.</li>
              <li><strong>Tickets and orders:</strong> the event, ticket type, price, order reference, any attendee names you add, and your promo or access code if you used one.</li>
              <li><strong>Entry:</strong> when and where your ticket was scanned at the door.</li>
              <li><strong>Transfers and waitlists:</strong> the email of anyone you send a ticket to, and your place on an event’s waitlist.</li>
              <li><strong>Organizers and promoters:</strong> organization details, team members, social handles you add, and (once payments are live) payout details held by our payment processor.</li>
              <li><strong>Technical data:</strong> the log data our hosting providers record (such as IP address and browser), and items your browser stores to keep you signed in and, for door staff, to scan offline.</li>
              <li><strong>Marketing pixels:</strong> an event’s organizer may add Meta, Google or TikTok pixels to its public pages. They load only if you accept them in the cookie banner.</li>
            </ul>
          ),
        },
        {
          title: 'How we use it',
          body: (
            <ul>
              <li>To issue your tickets, let you in at the door, and handle transfers, waitlists and refunds.</li>
              <li>To send transactional email: tickets, transfers, reminders, and changes or cancellations to events you hold tickets for.</li>
              <li>To give organizers their sales, attendance and promoter reports.</li>
              <li>To prevent fraud and abuse, including duplicate entry and automated buying.</li>
              <li>To meet legal, tax and accounting obligations.</li>
            </ul>
          ),
        },
        {
          title: 'Who we share it with',
          body: (
            <ul>
              <li><strong>The event’s organizer</strong> receives the order and attendee details for its own events. Door staff see whether a ticket is valid, not your email address.</li>
              <li><strong>Service providers</strong> who run parts of Exos for us: database and hosting (Supabase, Render), email delivery (Resend), payments (Stripe, once payments are live) and maps (Google Maps). They may use the data only to provide their service.</li>
              <li><strong>Marketing pixels</strong> an organizer has added, and only after you consent.</li>
              <li><strong>Authorities</strong> when the law requires it, or to protect people’s safety or the security of the platform.</li>
            </ul>
          ),
        },
        {
          title: 'How long we keep it',
          body: (
            <p>
              We keep your account information until you delete your account. Order and ticket records are kept after
              that for the organizer’s accounting, with your name and email removed. Logs held by our hosting providers
              are kept for their standard retention periods.
            </p>
          ),
        },
        {
          title: 'Your choices and rights',
          body: (
            <>
              <ul>
                <li><strong>Delete your account</strong> at any time from your <Link className="text-brand-primary" to="/profile">profile</Link> (“delete my account”).</li>
                <li><strong>Marketing pixels:</strong> decline them in the cookie banner. We never load them before you accept.</li>
                <li><strong>Access or correction:</strong> email {mail} and we’ll respond within the time the law requires.</li>
              </ul>
              <p>Depending on where you live (including California and the EU/UK), you may have further rights, such as to object to certain processing. Email us to use them.</p>
            </>
          ),
        },
        {
          title: 'Security',
          body: (
            <p>
              Ticket barcodes change every 30 seconds and are signed, so a screenshot can’t be reused. Access to
              order data is limited by role inside each organization. No system is perfectly secure; if we learn
              of a breach that affects you, we’ll tell you as the law requires.
            </p>
          ),
        },
        {
          title: 'Children',
          body: <p>Exos isn’t directed to children under 13, and we don’t knowingly collect their information. Organizers set age limits for their events.</p>,
        },
        {
          title: 'Changes and contact',
          body: <p>We’ll post changes here and update the date above. Questions or requests: {mail}.</p>,
        },
      ]}
    />
  );
}
