// Per-genre promotion playbook for the Promote page: where to advertise, what
// the creative should do, how to use posters and QR codes, and the ad-policy
// traps for this kind of event. Static and short on purpose.
//
// Sources (checked 2026-11-21):
//   * Discovery: Eventbrite's event statistics roundup says 48% of Gen Z
//     buyers find events on Instagram and about 30% on TikTok
//     (research_notes/Organizer and fan ticketing needs/fan_experience.md,
//     https://www.eventbrite.com/blog/event-statistics-ds00/; the 48% figure
//     was not confirmed by a second source). Edison Research 2024 (via a
//     third-party summary): 40% of US music followers use Instagram and 36%
//     TikTok for music discovery, 63% / 58% among 12-34s. Hence Meta /
//     Instagram and TikTok first for every category.
//   * Google Ads "Event ticket sales" policy: advertisers selling event
//     tickets must be certified by Google first (primary ticketers included).
//   * Alcohol: Meta, Snap and Pinterest ads for alcohol must target the legal
//     drinking age (21+ in the US); TikTok allows alcohol ads only where
//     permitted, with a responsible-drinking disclaimer and nobody who is or
//     looks under 25 on screen (each platform's advertising policies).
//   * Dating: Meta and Google treat ads that promote meeting people for
//     dating as dating ads (prior written permission on Meta, Google's dating
//     and companionship policy), so a "singles night" ad can be held back.
//   * Snap's advertising policies ban ads for strip clubs and burlesque.
//   * City rules (New York City's flyer rule, NYC Administrative Code
//     § 10-119) and ad geo defaults live with the city in
//     supabase/functions/_shared/discovery/cities.ts, so a new city is config.
// Growth research (operator, 2026-11-21) set the policy list; change it here.

import type { MarketCategory } from '../../supabase/functions/_shared/marketplace/eventStandard.ts';
import type { CityConfig } from '../../supabase/functions/_shared/discovery/cities.ts';

export interface Playbook {
  /** Ad platforms, best first. */
  platforms: Array<{ name: string; why: string }>;
  creative: string[];
  print: string[];
  /** Ad-policy notes for this kind of event. */
  policy: string[];
}

const META = { name: 'Meta (Instagram + Facebook)', why: 'Where most fans under 30 find events (about half of Gen Z). Reels and Stories, with the ad catalog for retargeting.' };
const TIKTOK = { name: 'TikTok', why: 'About 3 in 10 Gen Z fans discover events here. Short native clips, Spark Ads on a creator\'s post.' };
const GOOGLE = { name: 'Google Search', why: 'People already searching for the act, the venue or "things to do this weekend". Needs Google\'s event ticket certification first.' };

const POLICY = {
  alcohol: 'Alcohol in the ad (open bar, drink specials, tastings): target 21+ on Meta, Snap and Pinterest; on TikTok add a drink-responsibly line and show nobody under 25.',
  dating: 'A "singles night" or "meet someone" angle can trigger dating-ad rules on Meta and Google (approval first). Sell the party, not the dating.',
  snap: 'Snap bans ads for strip clubs and burlesque: skip Snap for those shows.',
  google: 'Google Ads: selling tickets needs Google\'s "Event ticket sales" certification before ads run.',
};

const QR_PRINT = [
  'One placement per spot below, so each poster\'s QR shows what it sold under Sources > Placement.',
  'QR at least 2 cm (1 in) wide, high contrast, with the date and "Tickets" next to it.',
];

export const PLAYBOOK: Readonly<Record<MarketCategory, Playbook>> = {
  concerts: {
    platforms: [META, TIKTOK, GOOGLE],
    creative: ['Lead with 5-10 seconds of the artist live or the track.', 'Name the act, the date and the venue in the first frame.', 'Retarget people who watched or visited with the ad catalog.'],
    print: ['Record stores, rehearsal spaces and venue boards near the show.', ...QR_PRINT],
    policy: [POLICY.google],
  },
  nightlife: {
    platforms: [META, TIKTOK],
    creative: ['Show the room full: crowd, lights, the DJ, in vertical video.', 'Put the lineup and set times on screen; post a countdown in Stories.'],
    print: ['Bars, record shops and late-night spots near the venue.', ...QR_PRINT],
    policy: [POLICY.alcohol, POLICY.dating, POLICY.snap],
  },
  comedy: {
    platforms: [META, TIKTOK, GOOGLE],
    creative: ['Cut a 15-30 second clip of the comic\'s best bit.', 'Name the headliner first; the show night second.'],
    print: ['Cafes, bars and bookstores near the room.', ...QR_PRINT],
    policy: [POLICY.google],
  },
  theater: {
    platforms: [META, GOOGLE, TIKTOK],
    creative: ['A rehearsal or a scene in 15 seconds; quote a review if there is one.', 'Show the run dates and that seats are going.'],
    print: ['Libraries, cafes and arts boards; programs at related shows.', ...QR_PRINT],
    policy: [POLICY.snap, POLICY.google],
  },
  festivals: {
    platforms: [META, TIKTOK, GOOGLE],
    creative: ['Lineup poster as a carousel, then artist-by-artist clips.', 'Last year\'s aftermovie beats any graphic.', 'Announce in waves: lineup, day splits, price steps.'],
    print: ['Wide poster runs in the neighborhoods your buyers live in.', ...QR_PRINT],
    policy: [POLICY.alcohol, POLICY.google],
  },
  sports: {
    platforms: [META, GOOGLE, TIKTOK],
    creative: ['Matchup and stakes in the first second; highlights over graphics.'],
    print: ['Gyms, sports bars and community centers.', ...QR_PRINT],
    policy: [POLICY.alcohol, POLICY.google],
  },
  food_drink: {
    platforms: [META, TIKTOK],
    creative: ['Close-up food and pour shots, sound on.', 'Say what\'s included and the price per person.'],
    print: ['Neighborhood cafes, markets and the venue\'s own windows.', ...QR_PRINT],
    policy: [POLICY.alcohol],
  },
  community: {
    platforms: [META, TIKTOK],
    creative: ['Show people at the table: the game, the group, the host.', 'Say who it\'s for ("new players welcome") and what to bring.'],
    print: ['Game stores, libraries, campus and community boards.', ...QR_PRINT],
    policy: [POLICY.dating],
  },
  business: {
    platforms: [META, GOOGLE],
    creative: ['Speakers and who attends, in one line each.', 'The one thing people leave with (intros, a talk, a skill).'],
    print: ['Coworking spaces, campus boards and partner offices.', ...QR_PRINT],
    policy: [POLICY.google],
  },
  other: {
    platforms: [META, TIKTOK, GOOGLE],
    creative: ['What happens there, in the first three seconds, in vertical video.', 'Date, place and price on screen.'],
    print: ['Places your crowd already goes near the venue.', ...QR_PRINT],
    policy: [POLICY.google],
  },
};

/**
 * The playbook for an event's category, with its city's rules and ad geo
 * defaults when the venue is in a configured city (cities.ts).
 */
export function playbookFor(category: MarketCategory, city: CityConfig | null = null): Playbook & { geo: string | null } {
  const pb = PLAYBOOK[category];
  if (!city) return { ...pb, geo: null };
  const g = city.adGeo;
  const geo = `Ads in ${city.name}: target about ${g.radiusMiles} miles around the venue${g.dma ? ` (DMA ${g.dma})` : ''}.`;
  const communities = city.communities.length ? [`Post in ${city.name} communities: ${city.communities.join(', ')}.`] : [];
  return { ...pb, print: [...pb.print, ...communities], policy: [...pb.policy, ...city.printRules], geo };
}
