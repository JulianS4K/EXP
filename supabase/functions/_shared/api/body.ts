// Request bodies for exos-api's write routes. docs/api-reference.md.
//
// readCapped counts bytes as they arrive and stops (cancelling the stream)
// once past the limit, so a chunked body without a Content-Length is never
// read in full; req.text() / req.formData() read everything first.
// Form-encoded bodies are decoded from that capped text (formBody), never
// with req.formData().
//
// Pure TypeScript (web streams only), imported by vitest.

/** Write bodies are at most this many bytes. */
export const MAX_BODY_BYTES = 64 * 1024;

/** The body as text, or null once it is over `max` bytes (declared or actual). */
export async function readCapped(req: Request, max: number): Promise<string | null> {
  const declared = Number(req.headers.get('content-length') ?? '');
  if (Number.isFinite(declared) && declared > max) return null;
  if (!req.body) return '';
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => undefined);
      return null;
    }
    chunks.push(value);
  }
  const buf = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    buf.set(c, at);
    at += c.byteLength;
  }
  return new TextDecoder().decode(buf);
}

/**
 * A form-encoded body as an object: `artist[name]=x` and `name=x` both give
 * { name: 'x' }; `artist[genres][]=a&artist[genres][]=b` gives { genres: ['a', 'b'] }.
 * Keys of any other shape are dropped.
 */
export function formBody(text: string): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of new URLSearchParams(text)) {
    const m = /^(?:[a-z_]+\[)?([a-z_]+)\]?(\[\])?$/i.exec(k);
    if (!m) continue;
    if (m[2]) {
      const list = Array.isArray(out[m[1]]) ? out[m[1]] as unknown[] : [];
      list.push(v);
      out[m[1]] = list;
    } else {
      out[m[1]] = v;
    }
  }
  return out;
}
