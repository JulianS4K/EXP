// Renders an org's site sections on the storefront (mig 20261016130000).
// Everything is text: markdown through the store page's safe renderer, links
// https only (checked on save and again here).

import { RichText } from '../lib/richText';
import type { SiteSection } from '../lib/site';
import SmsOptIn from './SmsOptIn';

const safe = (u?: string) => (u && /^https:\/\/[^\s<>"]+$/.test(u) ? u : undefined);

function Heading({ text, accent }: { text?: string; accent: string }) {
  return text ? (
    <h2 className="disp text-3xl tracking-tight uppercase mb-4" style={{ transform: 'skewX(-4deg)', color: undefined }}>
      <span style={{ borderBottom: `3px solid ${accent}` }}>{text}</span>
    </h2>
  ) : null;
}

export default function SiteSections({ sections, accent, orgId }: { sections: SiteSection[]; accent: string; orgId: string }) {
  return (
    <>
      {sections.map((s, i) => (
        <section key={i} className="max-w-6xl mx-auto px-4 sm:px-6 py-10 border-b border-white/5">
          {s.type === 'about' || s.type === 'text' ? (
            <>
              <Heading text={s.title} accent={accent} />
              <RichText source={s.body} className="type text-sm text-white/70 space-y-3 max-w-2xl" />
            </>
          ) : s.type === 'faq' ? (
            <>
              <Heading text={s.title || 'FAQ'} accent={accent} />
              <dl className="space-y-4 max-w-2xl">
                {(s.items ?? []).map((it, j) => (
                  <div key={j}>
                    <dt className="disp text-lg">{it.q}</dt>
                    <dd className="type text-sm text-white/65 mt-1">{it.a}</dd>
                  </div>
                ))}
              </dl>
            </>
          ) : s.type === 'gallery' ? (
            <>
              <Heading text={s.title} accent={accent} />
              <div className="grid grid-cols-2 md:grid-cols-3 gap-2">
                {(s.items ?? []).map((it, j) => safe(it.image) && (
                  <img key={j} src={safe(it.image)} alt={it.caption ?? ''} loading="lazy" className="w-full aspect-square object-cover" />
                ))}
              </div>
            </>
          ) : s.type === 'links' ? (
            <>
              <Heading text={s.title} accent={accent} />
              <div className="flex flex-wrap gap-3">
                {(s.items ?? []).map((it, j) => safe(it.url) && (
                  <a key={j} href={safe(it.url)} target="_blank" rel="noopener noreferrer"
                    className="disp px-5 py-2 text-lg tracking-wide text-black" style={{ background: accent }}>
                    {it.label || 'Link'}
                  </a>
                ))}
              </div>
            </>
          ) : s.type === 'newsletter' ? (
            <>
              <Heading text={s.title || 'Get texts about our next events'} accent={accent} />
              {s.body && <p className="type text-sm text-white/60 mb-2">{s.body}</p>}
              <div className="max-w-md"><SmsOptIn orgId={orgId} /></div>
            </>
          ) : null}
        </section>
      ))}
    </>
  );
}
