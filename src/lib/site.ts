// Venue site pages (mig 20261016130000): the org storefront's sections, in
// order. Shape rules mirror _exos_site_error; rendering escapes everything
// (text goes through the store page's safe markdown).

import { supabase } from './supabase';
import { callFn } from './integrations';

export type SectionType = 'hero' | 'events' | 'about' | 'text' | 'faq' | 'gallery' | 'links' | 'newsletter';

export interface SiteItem { [k: string]: string }
export interface SiteSection {
  type: SectionType;
  title?: string;
  subtitle?: string;
  body?: string;
  image?: string;
  button_label?: string;
  button_url?: string;
  items?: SiteItem[];
}
export interface Site { sections: SiteSection[] }

export const SECTION_TYPES: { type: SectionType; label: string; hint: string }[] = [
  { type: 'hero', label: 'Banner', hint: 'Big title, subtitle, image and a button at the top.' },
  { type: 'events', label: 'Upcoming events', hint: 'Where the event grid goes.' },
  { type: 'about', label: 'About', hint: 'Who you are, in a paragraph or two.' },
  { type: 'text', label: 'Text', hint: 'Any heading + text (markdown: **bold**, links, lists).' },
  { type: 'faq', label: 'FAQ', hint: 'Questions and answers.' },
  { type: 'gallery', label: 'Photos', hint: 'Image links (https).' },
  { type: 'links', label: 'Links', hint: 'Buttons to your socials, merch, anything.' },
  { type: 'newsletter', label: 'Text list sign-up', hint: 'Fans sign up for your texts.' },
];

const HTTPS = /^https:\/\/[^\s<>"]+$/;
const KNOWN = new Set(SECTION_TYPES.map((s) => s.type));

export function siteError(site: Site | null): string | null {
  if (!site) return null;
  if (!Array.isArray(site.sections)) return 'Sections must be a list.';
  if (site.sections.length > 20) return 'At most 20 sections.';
  if (JSON.stringify(site).length > 30000) return 'The site is too big.';
  for (const [i, s] of site.sections.entries()) {
    const n = i + 1;
    if (!KNOWN.has(s.type)) return `Section ${n}: unknown type.`;
    for (const [k, v] of Object.entries(s)) {
      if (k === 'type') continue;
      if (k === 'items') {
        if (!Array.isArray(v) || v.length > 30) return `Section ${n}: at most 30 items.`;
        for (const it of v as SiteItem[]) {
          for (const [ik, iv] of Object.entries(it)) {
            if (typeof iv !== 'string' || iv.length > 2000) return `Section ${n}: item text too long.`;
            if ((ik === 'url' || ik === 'image') && !HTTPS.test(iv)) return `Section ${n}: links must start with https://`;
          }
        }
      } else if (typeof v !== 'string' || v.length > 4000) {
        return `Section ${n}: ${k} must be text under 4000 characters.`;
      } else if ((k === 'image' || k === 'button_url') && v && !HTTPS.test(v)) {
        return `Section ${n}: ${k === 'image' ? 'image' : 'button link'} must start with https://`;
      }
    }
  }
  return null;
}

/** Drop empty strings / items so the saved site stays small and valid. */
export function cleanSite(site: Site): Site {
  return {
    sections: site.sections.map((s) => {
      const out: SiteSection = { type: s.type };
      for (const [k, v] of Object.entries(s)) {
        if (k === 'type') continue;
        if (k === 'items') {
          const items = (v as SiteItem[]).map((it) => Object.fromEntries(Object.entries(it).map(([a, b]) => [a, b.trim()]).filter(([, b]) => b)))
            .filter((it) => Object.keys(it).length > 0);
          if (items.length) out.items = items;
        } else if (typeof v === 'string' && v.trim()) {
          (out as unknown as Record<string, string>)[k] = v.trim();
        }
      }
      return out;
    }),
  };
}

export function parseSite(raw: unknown): Site | null {
  if (!raw || typeof raw !== 'object' || !Array.isArray((raw as Site).sections)) return null;
  const sections = (raw as Site).sections.filter((s) => s && KNOWN.has(s.type));
  return sections.length ? { sections } : null;
}

/** Sections before / after the event grid (hero is the header, not a block). */
export function splitAroundEvents(site: Site | null): { hero: SiteSection | null; before: SiteSection[]; after: SiteSection[] } {
  const all = site?.sections ?? [];
  const hero = all.find((s) => s.type === 'hero') ?? null;
  const rest = all.filter((s) => s.type !== 'hero');
  const at = rest.findIndex((s) => s.type === 'events');
  if (at < 0) return { hero, before: [], after: rest };
  return { hero, before: rest.slice(0, at), after: rest.slice(at + 1) };
}

export function starterSite(orgName: string): Site {
  return {
    sections: [
      { type: 'hero', title: orgName, subtitle: '' },
      { type: 'events', title: 'Upcoming' },
      { type: 'about', title: 'About', body: '' },
      { type: 'faq', title: 'FAQ', items: [{ q: 'Age limit?', a: '' }] },
    ],
  };
}

export async function saveSite(orgId: string, site: Site | null): Promise<void> {
  const { error } = await supabase.rpc('exos_set_org_site', { p_org_id: orgId, p_site: site ? cleanSite(site) : null });
  if (error) throw new Error(error.message.replace(/^exos_\w+: /, ''));
}

export interface OrgDomain { domain: string; status: 'pending' | 'verified' | 'failed'; txtName: string; txtValue: string; lastError: string | null }

export async function listDomains(orgId: string): Promise<OrgDomain[]> {
  const { data, error } = await supabase.rpc('exos_list_org_domains', { p_org_id: orgId });
  if (error) throw error;
  return (Array.isArray(data) ? data : []).map((d: any) => ({
    domain: d.domain, status: d.status, txtName: d.txt_name, txtValue: d.txt_value, lastError: d.last_error ?? null,
  }));
}

export async function addDomain(orgId: string, domain: string): Promise<void> {
  const { error } = await supabase.rpc('exos_add_org_domain', { p_org_id: orgId, p_domain: domain });
  if (error) throw new Error(error.message.replace(/^exos_\w+: /, ''));
}

export async function removeDomain(orgId: string, domain: string): Promise<void> {
  const { error } = await supabase.rpc('exos_remove_org_domain', { p_org_id: orgId, p_domain: domain });
  if (error) throw new Error(error.message.replace(/^exos_\w+: /, ''));
}

export const verifyDomain = (orgId: string, domain: string) =>
  callFn<{ ok: boolean; error: string | null }>('/verify-domain', { org: orgId, domain });
