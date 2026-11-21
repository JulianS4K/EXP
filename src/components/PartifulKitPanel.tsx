// Partiful kit on the Promote page's Discovery listings row (operator
// 2026-11-21). The organizer makes the invite page by hand on their own
// Partiful account; this gives them the steps, copy-ready fields, the cover
// image as a square and a story, and the tracked Exos ticket link
// (lib/discovery/partiful.ts). Nothing is sent to or read from Partiful.

import { useMemo, useState } from 'react';
import { Copy, Download } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { publicUrl } from '../lib/utils';
import type { DiscoveryEvent, DiscoveryRow } from '../lib/discovery/channels';
import { partifulKit } from '../lib/discovery/partiful';
import { composeSquareCover, downloadBlob } from '../lib/coverImages';
import { composeStoryPoster } from '../lib/poster';

export default function PartifulKitPanel({ event, row }: { event: DiscoveryEvent | null; row: DiscoveryRow }) {
  const { toast } = useToast();
  const [busy, setBusy] = useState<'square' | 'story' | null>(null);
  const appBase = useMemo(() => publicUrl('/').replace(/\/+$/, ''), []);
  const kit = useMemo(() => (event ? partifulKit(event, Array.isArray(event.tiers) ? event.tiers : [], appBase) : null), [event, appBase]);
  if (!event || !kit) return null;
  const stem = event.slug || event.id;

  const copy = async (text: string, what = 'Copied.') => {
    try {
      await navigator.clipboard.writeText(text);
      toast({ kind: 'success', message: what });
    } catch {
      toast({ kind: 'error', message: 'Copy failed; select the text instead.' });
    }
  };
  const square = async () => {
    if (!kit.image) return;
    setBusy('square');
    const blob = await composeSquareCover(kit.image);
    setBusy(null);
    if (blob) downloadBlob(blob, `partiful-${stem}-square.png`);
    else toast({ kind: 'error', message: 'Could not make the square image here: download the cover from its link.' });
  };
  const story = async () => {
    setBusy('story');
    const venue = kit.fields.find((f) => f.key === 'where')?.value;
    const when = kit.fields.find((f) => f.key === 'when')?.value;
    const blob = await composeStoryPoster({ title: kit.title, url: kit.ticketLink, imageUrl: kit.image, dateLabel: when, venue });
    setBusy(null);
    if (blob) downloadBlob(blob, `partiful-${stem}-story.png`);
    else toast({ kind: 'error', message: 'Could not make the story image here.' });
  };

  return (
    <div className="mt-3 space-y-3">
      {row.info?.steps && (
        <ol className="list-decimal list-inside text-xs text-white/60 space-y-0.5 max-w-prose">
          {row.info.steps.map((s) => <li key={s}>{s}</li>)}
        </ol>
      )}
      <details className="border border-white/10 rounded p-3">
        <summary className="text-xs font-bold cursor-pointer">Partiful kit (copy into your Partiful event)</summary>
        <dl className="grid grid-cols-1 sm:grid-cols-[9rem_1fr] gap-x-4 gap-y-1 text-xs mt-3">
          {kit.fields.map((x) => (
            <div key={x.key} className="contents">
              <dt className="text-white/50 font-bold uppercase tracking-wider pt-0.5">{x.label}</dt>
              <dd className="flex items-start gap-2 min-w-0">
                <span className={`break-all ${x.key === 'description' ? 'whitespace-pre-line' : ''}`}>{x.value}</span>
                <button type="button" onClick={() => copy(x.value)} aria-label={`Copy ${x.label}`} className="text-white/50 hover:text-white shrink-0">
                  <Copy size={12} />
                </button>
              </dd>
            </div>
          ))}
        </dl>
        <div className="flex flex-wrap gap-2 mt-3">
          <button type="button" onClick={() => copy(kit.text, 'Partiful details copied.')}
            className="inline-flex items-center gap-1 px-3 py-1.5 rounded border border-white/20 text-xs font-bold">
            <Copy size={12} aria-hidden="true" /> Copy all
          </button>
          {kit.image && (
            <button type="button" disabled={busy !== null} onClick={() => void square()}
              className="inline-flex items-center gap-1 px-3 py-1.5 rounded border border-white/20 text-xs font-bold disabled:opacity-50">
              <Download size={12} aria-hidden="true" /> Square cover (1080x1080)
            </button>
          )}
          <button type="button" disabled={busy !== null} onClick={() => void story()}
            className="inline-flex items-center gap-1 px-3 py-1.5 rounded border border-white/20 text-xs font-bold disabled:opacity-50">
            <Download size={12} aria-hidden="true" /> Story image (1080x1920)
          </button>
        </div>
      </details>
    </div>
  );
}
