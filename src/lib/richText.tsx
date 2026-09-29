// Store-page markdown → React (exos_events.description_md, mig 20260929120000).
//
// The grammar lives in supabase/functions/_shared/richText.ts so the edge
// functions' mdToPlain and this renderer can't drift. Here the parsed tree
// becomes React elements from a fixed allowlist (p, br, strong, em, a, ul, ol,
// li, h3, h4, blockquote, hr). No dangerouslySetInnerHTML: any HTML in the
// source is text, and React escapes it.

import type { ReactNode } from 'react';
import { parseMarkdown, type Block, type Inline } from '../../supabase/functions/_shared/richText.ts';

export { mdToPlain, parseMarkdown, safeHref, DESCRIPTION_MD_MAX, DESCRIPTION_PLAIN_MAX } from '../../supabase/functions/_shared/richText.ts';

function renderInline(nodes: Inline[]): ReactNode[] {
  return nodes.map((n, k) => {
    switch (n.t) {
      case 'text': return n.v;
      case 'br': return <br key={k} />;
      case 'strong': return <strong key={k} className="font-bold text-white">{renderInline(n.c)}</strong>;
      case 'em': return <em key={k}>{renderInline(n.c)}</em>;
      case 'link':
        return (
          <a key={k} href={n.href} target="_blank" rel="noopener nofollow ugc"
             className="text-brand-primary underline underline-offset-2 hover:opacity-80 break-words">
            {renderInline(n.c)}
          </a>
        );
    }
  });
}

function renderBlock(b: Block, k: number): ReactNode {
  switch (b.t) {
    case 'p': return <p key={k}>{renderInline(b.c)}</p>;
    case 'h3': return <h3 key={k} className="disp text-lg uppercase tracking-wide text-white pt-2">{renderInline(b.c)}</h3>;
    case 'h4': return <h4 key={k} className="font-bold text-white pt-1">{renderInline(b.c)}</h4>;
    case 'ul':
      return <ul key={k} className="list-disc pl-6 space-y-1">{b.items.map((it, j) => <li key={j}>{renderInline(it)}</li>)}</ul>;
    case 'ol':
      return (
        <ol key={k} start={b.start} className="list-decimal pl-6 space-y-1">
          {b.items.map((it, j) => <li key={j}>{renderInline(it)}</li>)}
        </ol>
      );
    case 'quote':
      return <blockquote key={k} className="border-l-2 border-white/20 pl-4 text-white/60 space-y-3">{b.c.map(renderBlock)}</blockquote>;
    case 'hr': return <hr key={k} className="border-white/10" />;
  }
}

/** Renders store-page markdown. Empty source renders nothing. */
export function RichText({ source, className }: { source: string | null | undefined; className?: string }) {
  const blocks = parseMarkdown(source);
  if (!blocks.length) return null;
  return <div className={className ?? 'space-y-4'}>{blocks.map(renderBlock)}</div>;
}
