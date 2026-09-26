import { Link } from 'react-router-dom';
import LegalPage from '../components/LegalPage';
import { LEGAL } from '../lib/legal';

// DRAFT for counsel review (see lib/legal.ts).
export default function Terms() {
  const mail = <a className="text-brand-primary" href={`mailto:${LEGAL.contactEmail}`}>{LEGAL.contactEmail}</a>;
  return (
    <LegalPage
      title="TERMS OF"
      accent="SERVICE"
      intro={
        <p>
          These terms govern your use of Exos, a platform run by {LEGAL.entity} (“Exos”, “we”) that lets organizers
          sell and manage tickets and lets fans buy, claim, transfer and use them. By creating an account or using a
          ticket you agree to these terms and to our <Link className="text-brand-primary" to="/privacy">Privacy Policy</Link>.
        </p>
      }
      sections={[
        {
          title: 'Who does what',
          body: (
            <p>
              Each event is run by its organizer, not by Exos. The organizer sets the event details, prices, ticket
              limits, entry rules and refund policy, and is responsible for putting on the event. Exos provides the
              ticketing, transfer and entry tools.
            </p>
          ),
        },
        {
          title: 'Your account',
          body: (
            <ul>
              <li>Give accurate information and confirm your email. Some actions (holding tickets, free claims, waitlists) need a confirmed email.</li>
              <li>Keep your sign-in secure. You’re responsible for activity on your account.</li>
              <li>You can delete your account from your profile. Tickets for upcoming events must be used or transferred first.</li>
            </ul>
          ),
        },
        {
          title: 'Tickets',
          body: (
            <ul>
              <li>A ticket is a revocable licence to attend the event under the organizer’s and venue’s rules. The venue may refuse entry, for example for age, safety or conduct.</li>
              <li>Each ticket admits one person once. The in-app barcode rotates, so screenshots and copies won’t scan.</li>
              <li>Tickets that are refunded, charged back or obtained by fraud are cancelled and won’t scan.</li>
              <li>Purchase limits, presale codes and hidden ticket types apply as the organizer sets them. Getting around them (multiple accounts, bots) can lead to cancellation.</li>
            </ul>
          ),
        },
        {
          title: 'Transfers and waitlists',
          body: (
            <ul>
              <li>Transfer tickets only through Exos. Once the recipient accepts, the ticket is theirs and yours stops working.</li>
              <li>Joining a waitlist doesn’t guarantee a ticket. If a spot opens you’ll be sent an offer for a limited time.</li>
            </ul>
          ),
        },
        {
          title: 'Prices, payment and refunds',
          body: (
            <ul>
              <li>The price shown is the total you pay for each ticket, including any tax.</li>
              <li>When paid tickets are available, payments are processed by Stripe under its terms.</li>
              <li>Refunds follow the organizer’s policy. If an event is cancelled, the organizer is responsible for refunds. Exos issues refunds when the organizer instructs, or where the law requires.</li>
            </ul>
          ),
        },
        {
          title: 'Organizers and promoters',
          body: (
            <ul>
              <li>Organizers must list events accurately, hold the rights and permits needed to run them, follow applicable law (including consumer, tax and accessibility rules), and honour their stated refund policy.</li>
              <li>Organizers may use attendee data only to run and communicate about their events, and only in line with the law and our Privacy Policy.</li>
              <li>Promoters and door staff act for the organizer and must follow its instructions and these terms.</li>
              <li>You give Exos permission to display the content you upload (event images, descriptions, logos) to run and promote the platform.</li>
            </ul>
          ),
        },
        {
          title: 'Things you must not do',
          body: (
            <ul>
              <li>Use bots, scripts or scraping to buy, claim, hold or monitor tickets.</li>
              <li>Sell counterfeit tickets, or resell tickets outside Exos where the organizer or the law forbids it.</li>
              <li>Interfere with the platform, probe it for weaknesses, or access other people’s data.</li>
              <li>Use Exos for anything unlawful, harassing or misleading.</li>
            </ul>
          ),
        },
        {
          title: 'Suspension and termination',
          body: <p>We may suspend or close accounts, or cancel tickets, that break these terms or put users or events at risk. Where we can, we’ll tell you why.</p>,
        },
        {
          title: 'Disclaimers and liability',
          body: (
            <p>
              Exos is provided “as is”. We aren’t responsible for the event itself, including its content, changes or
              cancellation, which are the organizer’s responsibility. To the extent the law allows, our total liability to
              you for any claim is limited to the fees Exos received from you for the tickets involved, and we aren’t
              liable for indirect or consequential losses. Nothing here limits rights you have under consumer law.
            </p>
          ),
        },
        {
          title: 'Governing law',
          body: <p>These terms are governed by the laws of {LEGAL.governingLaw}, and disputes will be heard in its courts, unless the law where you live says otherwise.</p>,
        },
        {
          title: 'Changes and contact',
          body: <p>We may update these terms and will post the new version here with a new date. Continuing to use Exos means you accept the changes. Contact: {mail}.</p>,
        },
      ]}
    />
  );
}
