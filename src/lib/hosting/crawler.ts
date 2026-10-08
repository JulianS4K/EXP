// Link-unfurl / SEO crawlers that don't run JavaScript. Only these get the
// server-side preview tags (seo.ts); humans get the plain SPA shell, so they
// never pay for the extra lookup. Ported from Terminal-2 core/seo.py.

import { isAiAgent } from '../../../supabase/functions/_shared/aiSources.ts';

const CRAWLER_UA_TOKENS = [
  'facebookexternalhit', // Facebook / Messenger
  'facebookcatalog',
  'meta-externalagent', // Meta's newer unfurl agent
  'twitterbot', // X / Twitter
  'slackbot',
  'whatsapp',
  'discordbot',
  'telegrambot',
  'linkedinbot',
  'pinterest',
  'redditbot',
  'googlebot',
  'google-inspectiontool',
  'bingbot',
  'applebot', // Apple / Siri / Spotlight + iMessage
  'tiktok', // TikTok in-app browser + bytespider unfurl
  'bytespider',
  'embedly', // generic unfurl service used by many apps
  'vkshare',
  'skypeuripreview',
];

/**
 * `ai`: also treat AI crawlers and fetchers (ChatGPT, Claude, Perplexity…)
 * as crawlers. Off until launch (server.ts EXOS_AI_DISCOVERY), so until then
 * they keep getting the plain shell.
 */
export function isLinkCrawler(userAgent: string | null | undefined, opts: { ai?: boolean } = {}): boolean {
  if (!userAgent) return false;
  const ua = userAgent.toLowerCase();
  return CRAWLER_UA_TOKENS.some((t) => ua.includes(t)) || (opts.ai === true && isAiAgent(ua));
}
