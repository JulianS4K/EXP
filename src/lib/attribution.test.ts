import { describe, expect, it } from 'vitest';
import { attributionFromSearch, captureAttribution, withAttribution } from './attribution';
import { aiFromReferrer, aiFromUtmSource, isAiAgent } from '../../supabase/functions/_shared/aiSources.ts';

describe('AI assistant referrals', () => {
  it('names the assistant from the referrer host, subdomains included', () => {
    expect(aiFromReferrer('https://chatgpt.com/c/abc')).toBe('ChatGPT');
    expect(aiFromReferrer('https://www.perplexity.ai/search?q=x')).toBe('Perplexity');
    expect(aiFromReferrer('https://claude.ai/chat/1')).toBe('Claude');
    expect(aiFromReferrer('https://gemini.google.com/app')).toBe('Gemini');
    expect(aiFromReferrer('https://www.google.com/')).toBeUndefined();
    expect(aiFromReferrer('https://notchatgpt.com/')).toBeUndefined();
    expect(aiFromReferrer('not a url')).toBeUndefined();
    expect(aiFromReferrer('')).toBeUndefined();
  });

  it('maps the utm_source values assistants put on links', () => {
    expect(aiFromUtmSource('chatgpt.com')).toBe('ChatGPT');
    expect(aiFromUtmSource(' Perplexity ')).toBe('Perplexity');
    expect(aiFromUtmSource('ai_assistant')).toBe('Exos MCP');
    expect(aiFromUtmSource('instagram')).toBeUndefined();
  });

  it('keeps only known names from a URL or body', () => {
    expect(attributionFromSearch('?ai_ref=ChatGPT').ai_ref).toBe('ChatGPT');
    expect(attributionFromSearch('?ai_ref=%3Cb%3E').ai_ref).toBeUndefined();
  });

  it('recognizes AI crawlers and fetchers by user agent', () => {
    expect(isAiAgent('Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot')).toBe(true);
    expect(isAiAgent('Mozilla/5.0 (compatible; PerplexityBot/1.0; +https://perplexity.ai/perplexitybot)')).toBe(true);
    expect(isAiAgent('Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)')).toBe(true);
    expect(isAiAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) Safari/604.1')).toBe(false);
    expect(isAiAgent(null)).toBe(false);
  });
});

describe('captureAttribution', () => {
  // (No sessionStorage under vitest: this covers the URL + referrer read.)
  it('records the assistant from the referrer', () => {
    expect(captureAttribution('ev1', '?utm_source=x', 'https://chatgpt.com/c/1')).toEqual({ utm_source: 'x', ai_ref: 'ChatGPT' });
    expect(captureAttribution('ev2', '?ai_ref=Claude', 'https://chatgpt.com/')).toEqual({ ai_ref: 'Claude' });
    expect(captureAttribution('ev3', '', 'https://www.google.com/')).toEqual({});
  });

  it("doesn't pass the assistant on to shared links", () => {
    const url = withAttribution('https://x.example/e/1', { utm_source: 'chatgpt.com', ai_ref: 'ChatGPT' });
    expect(url).toContain('utm_source=chatgpt.com');
    expect(url).not.toContain('ai_ref');
  });
});
