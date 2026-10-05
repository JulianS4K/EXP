// Public event page blocks for the store content (mig 20260929120000):
// lineup, FAQ accordion, gallery strip, video embed and "Good to know".
// Each renders nothing when the organizer left it empty.

import { RichText } from '../lib/richText';
import {
  ageLabel, refundPolicyText, roleLabel, videoEmbedUrl,
  type FaqEntry, type GalleryImage, type LineupEntry, type MinAge, type RefundPolicy,
} from '../lib/storeContent';

const H2 = 'disp text-3xl tracking-tight mb-6 border-l-4 border-brand-primary pl-4';

export function EventLineup({ lineup }: { lineup?: LineupEntry[] }) {
  if (!lineup?.length) return null;
  return (
    <section aria-labelledby="lineup-heading" className="mb-14">
      <h2 id="lineup-heading" className={H2}>LINEUP</h2>
      <ol className="divide-y divide-white/10 border border-white/10 bg-[#111]">
        {lineup.map((act, i) => (
          <li key={`${act.name}-${i}`} className="p-5 flex gap-5">
            <span className="type text-[11px] text-brand-primary uppercase tracking-widest w-14 shrink-0 pt-1">
              {act.setAt ?? ''}
            </span>
            <div className="min-w-0">
              <p className={act.role === 'headliner' ? 'disp text-2xl tracking-tight text-white' : 'disp text-xl tracking-tight text-white/80'}>
                {act.name}
                <span className="type text-[10px] text-white/40 uppercase tracking-widest ml-3 align-middle">{roleLabel(act.role)}</span>
              </p>
              {act.bio && <p className="type text-sm text-white/60 leading-relaxed mt-1 whitespace-pre-line">{act.bio}</p>}
            </div>
          </li>
        ))}
      </ol>
    </section>
  );
}

export function EventFaq({ faq }: { faq?: FaqEntry[] }) {
  if (!faq?.length) return null;
  return (
    <section aria-labelledby="faq-heading" className="mb-14">
      <h2 id="faq-heading" className={H2}>FAQ</h2>
      <div className="border border-white/10 divide-y divide-white/10 bg-[#111]">
        {faq.map((f, i) => (
          <details key={i} className="group">
            <summary className="cursor-pointer list-none p-5 flex items-center justify-between gap-4 text-white font-medium">
              <span>{f.q}</span>
              <span className="text-brand-primary text-xl leading-none transition-transform group-open:rotate-45" aria-hidden="true">+</span>
            </summary>
            <div className="px-5 pb-5 type text-sm text-white/60 leading-relaxed">
              <RichText source={f.a} className="space-y-3" />
            </div>
          </details>
        ))}
      </div>
    </section>
  );
}

export function EventGallery({ gallery, title }: { gallery?: GalleryImage[]; title: string }) {
  if (!gallery?.length) return null;
  return (
    <section aria-label="Gallery" className="mb-14">
      <div className="flex gap-3 overflow-x-auto snap-x pb-2">
        {gallery.map((g, i) => (
          <a key={`${g.url}-${i}`} href={g.url} target="_blank" rel="noopener noreferrer" className="snap-start shrink-0">
            <img
              src={g.url}
              alt={g.alt || `${title}, photo ${i + 1}`}
              loading="lazy"
              referrerPolicy="no-referrer"
              className="h-48 w-auto max-w-[20rem] object-cover border border-white/10"
            />
          </a>
        ))}
      </div>
    </section>
  );
}

export function EventVideo({ url, title }: { url?: string; title: string }) {
  const src = videoEmbedUrl(url);
  if (!src || !url) return null;
  return (
    <section aria-label="Video" className="mb-14">
      <div className="aspect-video border border-white/10 bg-black">
        <iframe
          src={src}
          title={`${title} video`}
          className="w-full h-full"
          loading="lazy"
          referrerPolicy="strict-origin-when-cross-origin"
          allow="encrypted-media; picture-in-picture; fullscreen"
          allowFullScreen
        />
      </div>
      <a href={url} target="_blank" rel="noopener noreferrer" className="type text-[11px] text-white/40 uppercase tracking-widest hover:text-brand-primary mt-2 inline-block">
        watch on {/vimeo\.com/.test(url) ? 'Vimeo' : 'YouTube'}
      </a>
    </section>
  );
}

export function EventGoodToKnow({
  minAge, refundPolicy, policyNotes, whatToBring,
}: { minAge?: MinAge | null; refundPolicy?: RefundPolicy | null; policyNotes?: string; whatToBring?: string }) {
  const refund = refundPolicy ? refundPolicyText(refundPolicy) : '';
  const bring = whatToBring?.trim();
  if (minAge == null && !refund && !policyNotes && !bring) return null;
  return (
    <section aria-labelledby="good-to-know-heading" className="mb-14 border border-white/10 bg-[#111] p-6 md:p-8">
      <h2 id="good-to-know-heading" className="disp text-2xl tracking-wide text-white mb-4">Good to know</h2>
      <ul className="space-y-2 type text-sm text-white/80">
        {minAge != null && (
          <li className="flex items-center gap-2">
            <span className="w-1.5 h-1.5 bg-brand-primary shrink-0" aria-hidden="true" />
            {minAge > 0 ? `Ages ${ageLabel(minAge)}. Bring a valid photo ID.` : 'All ages welcome.'}
          </li>
        )}
        {refund && (
          <li className="flex items-center gap-2">
            <span className="w-1.5 h-1.5 bg-brand-primary shrink-0" aria-hidden="true" /> {refund}
          </li>
        )}
      </ul>
      {bring && (
        <p className="type text-sm text-white/80 leading-relaxed whitespace-pre-line mt-4">
          <span className="text-white font-bold">What to bring: </span>{bring}
        </p>
      )}
      {policyNotes && <p className="type text-sm text-white/70 leading-relaxed whitespace-pre-line mt-4">{policyNotes}</p>}
    </section>
  );
}
