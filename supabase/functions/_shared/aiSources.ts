// AI assistants as a sale source. One list shared by the SPA (which reads
// document.referrer on landing) and exos-checkout (which keeps the field
// through readAttribution), so a visit from ChatGPT, Perplexity or Claude can
// be counted in the organizer's Sources report. Only the assistant's name is
// kept, never the referring URL. No imports: Deno and vitest both load it.

export const AI_ASSISTANTS = [
  'ChatGPT', 'Claude', 'Perplexity', 'Gemini', 'Copilot', 'Meta AI', 'Mistral', 'Grok', 'DeepSeek', 'Exos MCP',
] as const;
export type AiAssistant = (typeof AI_ASSISTANTS)[number];

// Referrer host (or a parent domain of it) → assistant.
const REFERRER_HOSTS: ReadonlyArray<readonly [string, AiAssistant]> = [
  ['chatgpt.com', 'ChatGPT'],
  ['chat.openai.com', 'ChatGPT'],
  ['claude.ai', 'Claude'],
  ['perplexity.ai', 'Perplexity'],
  ['gemini.google.com', 'Gemini'],
  ['bard.google.com', 'Gemini'],
  ['copilot.microsoft.com', 'Copilot'],
  ['meta.ai', 'Meta AI'],
  ['chat.mistral.ai', 'Mistral'],
  ['grok.com', 'Grok'],
  ['chat.deepseek.com', 'DeepSeek'],
];

// utm_source values the assistants (and our MCP links) put on outbound links.
const UTM_SOURCES: Readonly<Record<string, AiAssistant>> = {
  'chatgpt.com': 'ChatGPT', chatgpt: 'ChatGPT', openai: 'ChatGPT',
  'claude.ai': 'Claude', claude: 'Claude',
  'perplexity.ai': 'Perplexity', perplexity: 'Perplexity',
  gemini: 'Gemini', 'gemini.google.com': 'Gemini',
  copilot: 'Copilot', 'copilot.microsoft.com': 'Copilot',
  'meta.ai': 'Meta AI', grok: 'Grok', 'grok.com': 'Grok', mistral: 'Mistral', deepseek: 'DeepSeek',
  ai_assistant: 'Exos MCP',
};

/** The assistant a referrer URL belongs to, or undefined. */
export function aiFromReferrer(referrer: unknown): AiAssistant | undefined {
  if (typeof referrer !== 'string' || !referrer) return undefined;
  let host: string;
  try {
    host = new URL(referrer).hostname.toLowerCase();
  } catch {
    return undefined;
  }
  for (const [h, name] of REFERRER_HOSTS) {
    if (host === h || host.endsWith('.' + h)) return name;
  }
  return undefined;
}

/** The assistant a utm_source names, or undefined. */
export function aiFromUtmSource(source: unknown): AiAssistant | undefined {
  return typeof source === 'string' ? UTM_SOURCES[source.trim().toLowerCase()] : undefined;
}

/** Keep only a known assistant name (anything else is dropped). */
export function sanitizeAiAssistant(v: unknown): AiAssistant | undefined {
  return typeof v === 'string' && (AI_ASSISTANTS as readonly string[]).includes(v) ? (v as AiAssistant) : undefined;
}

// AI crawlers and fetchers (published user-agent tokens), lower case. Answer
// engines quote what these read; training crawlers are listed too because the
// server-rendered page is the same either way.
export const AI_AGENT_UA_TOKENS = [
  'chatgpt-user', 'oai-searchbot', 'gptbot',
  'claude-user', 'claude-searchbot', 'claudebot', 'anthropic-ai',
  'perplexitybot', 'perplexity-user',
  'mistralai-user', 'duckassistbot', 'amazonbot', 'ccbot', 'cohere-ai', 'youbot',
] as const;

export function isAiAgent(userAgent: string | null | undefined): boolean {
  if (!userAgent) return false;
  const ua = userAgent.toLowerCase();
  return AI_AGENT_UA_TOKENS.some((t) => ua.includes(t));
}
