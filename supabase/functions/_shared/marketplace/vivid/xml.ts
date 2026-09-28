// A small XML reader for the Vivid Seats v1 order responses (the Broker
// Portal answers v1 calls in XML). Pure, no dependencies: Deno and vitest.
//
// It reads elements, text, CDATA and the five standard entities (plus
// numeric ones); attributes, comments, processing instructions and DOCTYPEs
// are skipped. That covers the documented shapes: an order is an element
// with an <orderId> child, whatever the wrapper is called, and <seats> holds
// <seat> elements. Anything malformed throws.

export interface XmlElement {
  name: string;
  children: XmlElement[];
  text: string;
}

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };

function decode(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, ent: string) => {
    if (ent[0] === '#') {
      const code = ent[1] === 'x' || ent[1] === 'X' ? Number.parseInt(ent.slice(2), 16) : Number.parseInt(ent.slice(1), 10);
      return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : m;
    }
    return ENTITIES[ent.toLowerCase()] ?? m;
  });
}

export class XmlError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'XmlError';
  }
}

/** Parses a document; returns its root element. */
export function parseXml(src: string): XmlElement {
  const root: XmlElement = { name: '#document', children: [], text: '' };
  const stack: XmlElement[] = [root];
  let i = 0;
  const n = src.length;
  while (i < n) {
    const lt = src.indexOf('<', i);
    const textEnd = lt < 0 ? n : lt;
    if (textEnd > i) stack[stack.length - 1].text += decode(src.slice(i, textEnd));
    if (lt < 0) break;
    if (src.startsWith('<!--', lt)) {
      const end = src.indexOf('-->', lt + 4);
      if (end < 0) throw new XmlError('unterminated comment');
      i = end + 3;
    } else if (src.startsWith('<![CDATA[', lt)) {
      const end = src.indexOf(']]>', lt + 9);
      if (end < 0) throw new XmlError('unterminated CDATA');
      stack[stack.length - 1].text += src.slice(lt + 9, end);
      i = end + 3;
    } else if (src.startsWith('<?', lt)) {
      const end = src.indexOf('?>', lt + 2);
      if (end < 0) throw new XmlError('unterminated processing instruction');
      i = end + 2;
    } else if (src.startsWith('<!', lt)) {
      const end = src.indexOf('>', lt + 2);
      if (end < 0) throw new XmlError('unterminated declaration');
      i = end + 1;
    } else if (src[lt + 1] === '/') {
      const end = src.indexOf('>', lt + 2);
      if (end < 0) throw new XmlError('unterminated end tag');
      const name = src.slice(lt + 2, end).trim();
      const open = stack.pop();
      if (!open || open === root || open.name !== name) throw new XmlError(`unexpected </${name}>`);
      i = end + 1;
    } else {
      const end = src.indexOf('>', lt + 1);
      if (end < 0) throw new XmlError('unterminated start tag');
      const inner = src.slice(lt + 1, end);
      const selfClosing = inner.endsWith('/');
      const m = /^([A-Za-z_][\w.:-]*)/.exec(inner);
      if (!m) throw new XmlError(`bad tag <${inner.slice(0, 40)}>`);
      const el: XmlElement = { name: m[1], children: [], text: '' };
      stack[stack.length - 1].children.push(el);
      if (!selfClosing) stack.push(el);
      i = end + 1;
    }
  }
  if (stack.length !== 1) throw new XmlError(`unclosed <${stack[stack.length - 1].name}>`);
  const els = root.children;
  if (els.length !== 1) throw new XmlError(els.length ? 'more than one root element' : 'no root element');
  return els[0];
}

const localName = (name: string) => name.slice(name.indexOf(':') + 1);

/** The first direct child with this (local) name, case-insensitive. */
export function child(el: XmlElement, name: string): XmlElement | undefined {
  const want = name.toLowerCase();
  return el.children.find((c) => localName(c.name).toLowerCase() === want);
}

/**
 * An element as a plain value: text-only -> the trimmed text; with children
 * -> an object (a repeated name becomes an array); empty -> ''.
 */
export function xmlValue(el: XmlElement): unknown {
  if (!el.children.length) return el.text.trim();
  const out: Record<string, unknown> = {};
  for (const c of el.children) {
    const k = localName(c.name);
    const v = xmlValue(c);
    if (k in out) out[k] = Array.isArray(out[k]) ? [...(out[k] as unknown[]), v] : [out[k], v];
    else out[k] = v;
  }
  return out;
}

/** Every element (depth-first, the root included) that has a direct child named `childName`. */
export function elementsWithChild(el: XmlElement, childName: string): XmlElement[] {
  const out: XmlElement[] = [];
  const walk = (e: XmlElement) => {
    if (child(e, childName)) {
      out.push(e);
      return; // an order doesn't nest orders
    }
    e.children.forEach(walk);
  };
  walk(el);
  return out;
}
