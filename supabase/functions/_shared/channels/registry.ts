// Every channel Exos knows, on one list (adapter.ts). `core` entries run on
// the ChannelAdapter interface; `legacy` ones state their capabilities while
// their code still lives in its own module (moved one per branch).

import { caps, registerAdapter, type ChannelAdapter } from "./adapter.ts";
import { pretixAdapter } from "./adapters/pretix.ts";
import { metaAdsAdapter } from "./adapters/metaAds.ts";
import { redditAdsAdapter } from "./adapters/redditAds.ts";
import { googleCustomerMatchAdapter } from "./adapters/googleCustomerMatch.ts";
import { xAdsAdapter } from "./adapters/xAds.ts";
import { instagramAdapter } from "./adapters/instagram.ts";
import { tiktokAdapter } from "./adapters/tiktok.ts";
import { meetupAdapter } from "./adapters/meetup.ts";
import { linkedinAdapter } from "./adapters/linkedin.ts";
import { googleBusinessAdapter } from "./adapters/googleBusiness.ts";

const legacy = (id: string, label: string, home: string, c: Parameters<typeof caps>[0]): ChannelAdapter =>
  ({ id, label, status: "legacy", home, caps: caps(c) });

export const ADAPTERS: readonly ChannelAdapter[] = [
  pretixAdapter,
  // The ads phase (mig 20261121190500): dry run only, every write on an explicit allowlist.
  metaAdsAdapter,
  redditAdsAdapter,
  googleCustomerMatchAdapter,
  xAdsAdapter,
  // The social posting / listing phase (mig 20261121203000): dry run only, every write on an explicit allowlist.
  instagramAdapter,
  tiktokAdapter,
  meetupAdapter,
  linkedinAdapter,
  googleBusinessAdapter,
  legacy("eventbrite", "Eventbrite", "exos-channel-sync + _shared/channels/eventbrite.ts", {
    role: "primary", createEvent: true, ticketTypes: true, setCapacity: true, readAttendees: true }),
  legacy("luma", "Luma", "exos-channel-sync + _shared/channels/luma.ts", {
    role: "primary", createEvent: true, ticketTypes: true, setCapacity: true, readAttendees: true }),
  legacy("hievents", "hi.events", "exos-integrations + _shared/backends/hievents.ts", { role: "primary", readAttendees: true }),
  legacy("dice", "DICE", "exos-dice-import + _shared/dice", { role: "primary", readAttendees: true }),
  legacy("stubhub", "StubHub", "exos-distribute + _shared/marketplace/stubhub", {
    requestEvent: true, matchEvent: true, list: true, delist: true, deliver: ["claim_url", "barcode", "pdf", "mobile_transfer"], saleWebhook: true }),
  legacy("seatgeek", "SeatGeek", "exos-distribute + _shared/marketplace/seatgeek", {
    matchEvent: true, list: true, delist: true, deliver: ["claim_url", "barcode", "pdf"] }),
  legacy("vivid", "Vivid Seats", "exos-distribute + _shared/marketplace/vivid", { matchEvent: true, list: true, delist: true }),
  legacy("gametime", "Gametime", "exos-distribute + _shared/marketplace/gametime", { list: true }),
  legacy("evo", "Ticket Evolution", "exos-distribute + _shared/marketplace/tevo", { matchEvent: true, list: true, delist: true }),
  legacy("discord", "Discord", "exos-discord + _shared/channels/discord.ts", { publishPost: true }),
  legacy("meta", "Meta (conversions)", "exos-conversions-drain + _shared/conversions", { sendConversion: true }),
  legacy("google_ads", "Google Ads (conversions)", "exos-conversions-drain + _shared/conversions", { sendConversion: true }),
];

let registered = false;
/** Registers every entry once (each is shape-checked: adapterProblems). */
export function ensureRegistry(): void {
  if (registered) return;
  for (const a of ADAPTERS) registerAdapter(a);
  registered = true;
}
