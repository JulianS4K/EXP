import type { ReactNode } from 'react';
import { ArrowLeft } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { LEGAL } from '../lib/legal';

export interface LegalSection {
  title: string;
  body: ReactNode;
}

export default function LegalPage({ title, accent, intro, sections }: {
  title: string;
  accent: string;
  intro: ReactNode;
  sections: LegalSection[];
}) {
  const navigate = useNavigate();
  return (
    <div className="max-w-3xl mx-auto px-4 py-14 md:py-20">
      <button
        onClick={() => navigate(-1)}
        className="type inline-flex items-center text-white/40 hover:text-brand-primary mb-10 transition-colors uppercase tracking-[0.3em] text-[11px]"
      >
        <ArrowLeft className="w-4 h-4 mr-2" />
        Back
      </button>
      <p className="type text-brand-primary text-xs tracking-[0.3em] uppercase mb-4">// legal</p>
      <h1 className="disp text-5xl md:text-7xl leading-[0.9]" style={{ transform: 'skewX(-4deg)' }}>
        {title}<br />
        <span className="text-brand-primary">{accent}</span>
      </h1>
      <p className="type text-white/40 text-[11px] uppercase tracking-widest mt-6">Last updated {LEGAL.lastUpdated}</p>
      <div className="type text-white/60 leading-relaxed mt-8 text-[15px] space-y-3">{intro}</div>
      {sections.map((s, i) => (
        <section key={s.title} className="mt-10">
          <h2 className="disp text-2xl md:text-3xl mb-3 text-white" style={{ transform: 'skewX(-4deg)' }}>
            {i + 1}. {s.title}
          </h2>
          <div className="type text-white/60 leading-relaxed text-[15px] space-y-3 [&_ul]:list-disc [&_ul]:pl-5 [&_ul]:space-y-1">
            {s.body}
          </div>
        </section>
      ))}
    </div>
  );
}
