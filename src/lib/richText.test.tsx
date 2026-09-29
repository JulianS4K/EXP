import { describe, expect, it } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';
import { RichText, mdToPlain, safeHref } from './richText';

const html = (md: string) => renderToStaticMarkup(<RichText source={md} className="x" />);

describe('RichText', () => {
  it('renders the allowlisted blocks', () => {
    const out = html('# Big\n\n### Small\n\nOne\ntwo\n\n- a\n- b\n\n3. c\n4. d\n\n> quoted\n\n---');
    expect(out).toBe(
      '<div class="x">'
      + '<h3 class="disp text-lg uppercase tracking-wide text-white pt-2">Big</h3>'
      + '<h4 class="font-bold text-white pt-1">Small</h4>'
      + '<p>One<br/>two</p>'
      + '<ul class="list-disc pl-6 space-y-1"><li>a</li><li>b</li></ul>'
      + '<ol start="3" class="list-decimal pl-6 space-y-1"><li>c</li><li>d</li></ol>'
      + '<blockquote class="border-l-2 border-white/20 pl-4 text-white/60 space-y-3"><p>quoted</p></blockquote>'
      + '<hr class="border-white/10"/>'
      + '</div>',
    );
  });

  it('renders bold, italic and safe links', () => {
    const out = html('**Four rooms**, _one_ *night*. [Tickets](https://exos.example.com/e/x) or mail [us](mailto:hi@x.com).');
    expect(out).toContain('<strong class="font-bold text-white">Four rooms</strong>');
    expect(out).toContain('<em>one</em>');
    expect(out).toContain('<em>night</em>');
    expect(out).toContain('href="https://exos.example.com/e/x" target="_blank" rel="noopener nofollow ugc"');
    expect(out).toContain('href="mailto:hi@x.com"');
  });

  it('autolinks bare https URLs without the trailing punctuation', () => {
    const out = html('Info: https://example.com/a?b=1.');
    expect(out).toContain('>https://example.com/a?b=1</a>.');
  });

  it('never links javascript:, data: or http: URLs', () => {
    for (const bad of ['javascript:alert(1)', 'JaVaScRiPt:alert(1)', 'data:text/html,<b>x</b>', 'http://x.com', ' javascript:alert(1)', 'https://x.com/"onmouseover="alert(1)']) {
      const out = html(`[click](${bad})`);
      expect(out).not.toContain('<a');
      expect(out).toContain('click');
    }
  });

  it('renders raw HTML as text', () => {
    const out = html('<script>alert(1)</script>\n\n<img src=x onerror=alert(1)> <a href="javascript:x">y</a>');
    expect(out).not.toContain('<script');
    expect(out).not.toContain('<img');
    expect(out).not.toContain('<a ');
    expect(out).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
    expect(out).toContain('&lt;img src=x onerror=alert(1)&gt;');
  });

  it('leaves snake_case and lone asterisks alone', () => {
    expect(html('my_file_name and 2 * 3 * 4')).toBe('<div class="x"><p>my_file_name and 2 * 3 * 4</p></div>');
  });

  it('honours backslash escapes', () => {
    expect(html('\\*not italic\\*')).toBe('<div class="x"><p>*not italic*</p></div>');
  });

  it('renders nothing for empty source', () => {
    expect(html('   \n\n')).toBe('');
  });
});

describe('safeHref', () => {
  it('allows https and mailto only', () => {
    expect(safeHref('https://x.com/a')).toBe('https://x.com/a');
    expect(safeHref('mailto:a@b.co')).toBe('mailto:a@b.co');
    expect(safeHref('http://x.com')).toBeNull();
    expect(safeHref('javascript:alert(1)')).toBeNull();
    expect(safeHref('//x.com')).toBeNull();
    expect(safeHref('https://')).toBeNull();
  });
});

describe('mdToPlain', () => {
  it('drops markup, keeps structure', () => {
    expect(mdToPlain('## The night\n\n**Four rooms**, one [lineup](https://x.com/l).\n\n- Coat check\n- Water\n\n1. First'))
      .toBe('The night\n\nFour rooms, one lineup (https://x.com/l).\n\n- Coat check\n- Water\n\n1. First');
  });
  it('keeps link text that is already the URL, strips mailto:', () => {
    expect(mdToPlain('See https://x.com. Mail [me](mailto:a@b.co)')).toBe('See https://x.com. Mail me (a@b.co)');
  });
  it('drops unsafe links to their label, keeps raw HTML as text', () => {
    expect(mdToPlain('[x](javascript:alert(1))')).toBe('x');
    expect(mdToPlain('<b>hi</b>')).toBe('<b>hi</b>');
  });
  it('handles empty input', () => {
    expect(mdToPlain(null)).toBe('');
    expect(mdToPlain('')).toBe('');
    expect(mdToPlain('---')).toBe('');
  });
});
