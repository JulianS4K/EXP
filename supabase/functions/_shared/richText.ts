// Store-page markdown (exos_events.description_md, mig 20260929120000).
//
// A deliberately small subset, parsed into a tiny tree. Nothing here emits
// HTML: the app renders the tree to React elements (src/lib/richText.tsx)
// and server consumers take the plain text (mdToPlain). Raw HTML in the
// source stays literal text.
//
//   blocks:  paragraphs (single newlines are line breaks), # / ## headings
//            (h3), ### and deeper (h4), "- " / "* " / "+ " lists, "1. " lists,
//            "> " quotes, --- rules
//   inline:  **bold**, *italic* / _italic_, [label](https://… or mailto:…),
//            bare https:// links, backslash escapes
//
// Links are https or mailto only; anything else (javascript:, data:, http:)
// keeps its label as plain text. No images (the gallery holds those).
//
// Pure: no Deno or Node imports, so the SPA imports it directly (like
// marketplace/eventStandard.ts).

export type Inline =
  | { t: 'text'; v: string }
  | { t: 'br' }
  | { t: 'strong'; c: Inline[] }
  | { t: 'em'; c: Inline[] }
  | { t: 'link'; href: string; c: Inline[] };

export type Block =
  | { t: 'p'; c: Inline[] }
  | { t: 'h3'; c: Inline[] }
  | { t: 'h4'; c: Inline[] }
  | { t: 'ul'; items: Inline[][] }
  | { t: 'ol'; items: Inline[][]; start: number }
  | { t: 'quote'; c: Block[] }
  | { t: 'hr' };

export const DESCRIPTION_MD_MAX = 20000;
// exos_events.description stays the plain fallback every legacy reader uses.
export const DESCRIPTION_PLAIN_MAX = 2000;

const MAX_DEPTH = 6;
const ESCAPABLE = /[\\`*_{}[\]()#+\-.!>|~]/;
const UL_RE = /^\s{0,3}[-*+]\s+(.*)$/;
const OL_RE = /^\s{0,3}(\d{1,9})[.)]\s+(.*)$/;
const HEADING_RE = /^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/;
const HR_RE = /^\s{0,3}([-*_])(\s*\1){2,}\s*$/;
const QUOTE_RE = /^\s{0,3}>\s?(.*)$/;

/** https or mailto, with nothing that could break out of an attribute; else null. */
export function safeHref(raw: string): string | null {
  const url = raw.trim();
  // deno-lint-ignore no-control-regex
  if (/[\s<>"'`\u0000-\u001f\u007f]/.test(url)) return null;
  if (/^https:\/\/[^/?#]+/i.test(url)) return url;
  if (/^mailto:[^@]+@[^@]+$/i.test(url)) return url;
  return null;
}

const isWordChar = (ch: string | undefined) => !!ch && /[\p{L}\p{N}]/u.test(ch);

function pushText(out: Inline[], v: string): void {
  if (!v) return;
  const last = out[out.length - 1];
  if (last && last.t === 'text') last.v += v;
  else out.push({ t: 'text', v });
}

// Closing marker for an emphasis run opened at `from`: not preceded by a
// space, and for "_" not inside a word (snake_case stays literal).
function findClose(s: string, marker: string, from: number): number {
  let j = s.indexOf(marker, from);
  while (j !== -1) {
    const prev = s[j - 1];
    const next = s[j + marker.length];
    const ok = prev !== ' ' && prev !== '\n' && prev !== '\\'
      && (marker[0] !== '_' || !isWordChar(next))
      && (marker.length > 1 || s[j + 1] !== marker);
    if (ok && j > from) return j;
    j = s.indexOf(marker, j + marker.length);
  }
  return -1;
}

// The ")" that ends a link target, allowing balanced parentheses inside it.
function closingParen(s: string, from: number): number {
  let depth = 0;
  for (let j = from; j < s.length; j += 1) {
    if (s[j] === '\n') return -1;
    if (s[j] === '(') depth += 1;
    else if (s[j] === ')') {
      if (depth === 0) return j;
      depth -= 1;
    }
  }
  return -1;
}

export function parseInline(s: string, depth = 0, inLink = false): Inline[] {
  const out: Inline[] = [];
  let i = 0;
  while (i < s.length) {
    const ch = s[i];
    if (ch === '\\' && i + 1 < s.length && ESCAPABLE.test(s[i + 1])) {
      pushText(out, s[i + 1]);
      i += 2;
      continue;
    }
    if (ch === '\n') {
      out.push({ t: 'br' });
      i += 1;
      continue;
    }
    if (depth < MAX_DEPTH && (s.startsWith('**', i) || s.startsWith('__', i))) {
      const m = s.slice(i, i + 2);
      const opensOk = s[i + 2] !== undefined && s[i + 2] !== ' ' && (m === '**' || !isWordChar(s[i - 1]));
      const j = opensOk ? findClose(s, m, i + 2) : -1;
      if (j !== -1) {
        out.push({ t: 'strong', c: parseInline(s.slice(i + 2, j), depth + 1, inLink) });
        i = j + 2;
        continue;
      }
    }
    if (depth < MAX_DEPTH && (ch === '*' || ch === '_')) {
      const opensOk = s[i + 1] !== undefined && s[i + 1] !== ' ' && s[i + 1] !== ch
        && (ch === '*' || !isWordChar(s[i - 1]));
      const j = opensOk ? findClose(s, ch, i + 1) : -1;
      if (j !== -1) {
        out.push({ t: 'em', c: parseInline(s.slice(i + 1, j), depth + 1, inLink) });
        i = j + 1;
        continue;
      }
    }
    if (ch === '[' && !inLink) {
      const close = s.indexOf('](', i + 1);
      const end = close === -1 ? -1 : closingParen(s, close + 2);
      if (close !== -1 && end !== -1 && !s.slice(i + 1, close).includes('\n')) {
        const label = s.slice(i + 1, close);
        const href = safeHref(s.slice(close + 2, end));
        const c = parseInline(label, depth + 1, true);
        if (href) out.push({ t: 'link', href, c });
        else for (const n of c) {
          if (n.t === 'text') pushText(out, n.v);
          else out.push(n);
        }
        i = end + 1;
        continue;
      }
    }
    if (!inLink && (ch === 'h' || ch === 'H') && /^https:\/\//i.test(s.slice(i, i + 8)) && !isWordChar(s[i - 1])) {
      const m = /^https:\/\/[^\s<>"'`]+/i.exec(s.slice(i));
      if (m) {
        // Trailing punctuation belongs to the sentence, not the URL.
        const url = m[0].replace(/[.,;:!?)\]]+$/, '');
        const href = safeHref(url);
        if (href && url.length > 'https://'.length) {
          out.push({ t: 'link', href, c: [{ t: 'text', v: url }] });
          i += url.length;
          continue;
        }
      }
    }
    pushText(out, ch);
    i += 1;
  }
  return out;
}

export function parseMarkdown(src: string | null | undefined, depth = 0): Block[] {
  const lines = String(src ?? '').replace(/\r\n?/g, '\n').split('\n');
  const blocks: Block[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i += 1; continue; }
    if (HR_RE.test(line)) { blocks.push({ t: 'hr' }); i += 1; continue; }
    const h = HEADING_RE.exec(line);
    if (h) {
      blocks.push({ t: h[1].length <= 2 ? 'h3' : 'h4', c: parseInline(h[2]) });
      i += 1;
      continue;
    }
    if (QUOTE_RE.test(line)) {
      const inner: string[] = [];
      while (i < lines.length && QUOTE_RE.test(lines[i])) {
        inner.push(QUOTE_RE.exec(lines[i])![1]);
        i += 1;
      }
      blocks.push(depth < 2 ? { t: 'quote', c: parseMarkdown(inner.join('\n'), depth + 1) }
                            : { t: 'p', c: parseInline(inner.join('\n')) });
      continue;
    }
    const ol = OL_RE.exec(line);
    if (UL_RE.test(line) || ol) {
      const re = ol ? OL_RE : UL_RE;
      const items: string[] = [];
      while (i < lines.length && lines[i].trim()) {
        const m = re.exec(lines[i]);
        if (m) items.push(ol ? m[2] : m[1]);
        else if (/^\s+\S/.test(lines[i]) && items.length) items[items.length - 1] += '\n' + lines[i].trim();
        else break;
        i += 1;
      }
      const parsed = items.map((it) => parseInline(it));
      blocks.push(ol ? { t: 'ol', items: parsed, start: Number(ol[1]) || 1 } : { t: 'ul', items: parsed });
      continue;
    }
    const para: string[] = [];
    while (i < lines.length && lines[i].trim() && !HR_RE.test(lines[i]) && !HEADING_RE.test(lines[i])
           && !QUOTE_RE.test(lines[i]) && !UL_RE.test(lines[i]) && !OL_RE.test(lines[i])) {
      para.push(lines[i].trim());
      i += 1;
    }
    blocks.push({ t: 'p', c: parseInline(para.join('\n')) });
  }
  return blocks;
}

function inlineText(c: Inline[]): string {
  return c.map((n) => {
    switch (n.t) {
      case 'text': return n.v;
      case 'br': return '\n';
      case 'strong':
      case 'em': return inlineText(n.c);
      case 'link': {
        const label = inlineText(n.c);
        const target = n.href.replace(/^mailto:/i, '');
        return label === n.href || label === target ? label : `${label} (${target})`;
      }
    }
  }).join('');
}

function blockText(b: Block): string {
  switch (b.t) {
    case 'p':
    case 'h3':
    case 'h4': return inlineText(b.c);
    case 'ul': return b.items.map((it) => `- ${inlineText(it)}`).join('\n');
    case 'ol': return b.items.map((it, k) => `${b.start + k}. ${inlineText(it)}`).join('\n');
    case 'quote': return b.c.map(blockText).filter(Boolean).join('\n\n');
    case 'hr': return '';
  }
}

/**
 * Plain text for description_md: markup dropped, paragraphs kept as blank
 * lines, list items as "- " lines, links as "label (url)". This is what goes
 * in exos_events.description, feeds, calendars and meta tags.
 */
export function mdToPlain(src: string | null | undefined): string {
  return parseMarkdown(src).map(blockText).filter((s) => s.trim()).join('\n\n').trim();
}
