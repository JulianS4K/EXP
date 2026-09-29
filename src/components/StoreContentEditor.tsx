// The "Store page" section of the event form (mig 20260929120000), shared by
// CreateEvent and EditEvent so the two can't drift: one-line summary, the
// markdown "About" with a preview, lineup, FAQ, gallery, video, age limit and
// the refund / good-to-know block. Pure form state (lib/storeContent
// StoreDraft); the parent saves it with the rest of the event.

import { useState, type ChangeEvent } from 'react';
import { Loader2, Plus, Trash2, Upload } from 'lucide-react';
import { RichText } from '../lib/richText';
import { uploadEventImage } from '../lib/storage';
import { useToast } from '../context/ToastContext';
import {
  DESCRIPTION_MD_MAX, FAQ_A_MAX, FAQ_MAX, FAQ_Q_MAX, GALLERY_ALT_MAX, GALLERY_MAX, LINEUP_BIO_MAX, LINEUP_MAX,
  LINEUP_NAME_MAX, LINEUP_ROLES, MIN_AGES, POLICY_NOTES_MAX, REFUND_POLICIES, SUMMARY_MAX, isVideoUrl,
  type LineupRole, type StoreDraft,
} from '../lib/storeContent';

const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

const LABEL = 'type text-[11px] text-white/60 uppercase tracking-widest ml-1';
const HINT = 'type text-[9px] text-white/30 uppercase tracking-widest ml-1';
const INPUT = 'w-full bg-black border border-white/20 py-3 px-4 text-white text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-primary/60 focus:border-brand-primary';
const ADD = 'inline-flex items-center gap-1 text-[10px] font-bold text-brand-primary uppercase tracking-widest hover:opacity-80 disabled:opacity-30';
const REMOVE = 'p-2 text-white/40 hover:text-red-400 shrink-0';

export default function StoreContentEditor({
  value, onChange, idPrefix, uploaderUid,
}: {
  value: StoreDraft;
  onChange: (next: StoreDraft) => void;
  idPrefix: string;
  // Signed-in uploader: enables "Upload" for gallery images (else URLs only).
  uploaderUid?: string;
}) {
  const { toast } = useToast();
  const [preview, setPreview] = useState(false);
  const [uploading, setUploading] = useState(false);
  const set = <K extends keyof StoreDraft>(k: K, v: StoreDraft[K]) => onChange({ ...value, [k]: v });
  const setRow = <K extends 'lineup' | 'faq' | 'gallery'>(k: K, i: number, patch: Partial<StoreDraft[K][number]>) =>
    set(k, value[k].map((r, j) => (j === i ? { ...r, ...patch } : r)) as StoreDraft[K]);
  const dropRow = (k: 'lineup' | 'faq' | 'gallery', i: number) =>
    set(k, value[k].filter((_, j) => j !== i) as never);

  const uploadGalleryImage = async (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (!file || !uploaderUid) return;
    if (!file.type.startsWith('image/')) {
      toast({ kind: 'error', message: 'Please choose an image file.' });
      return;
    }
    if (file.size > MAX_IMAGE_BYTES) {
      toast({ kind: 'error', title: 'Image too large', message: 'Please choose an image under 5 MB.' });
      return;
    }
    setUploading(true);
    try {
      const { url } = await uploadEventImage(uploaderUid, file);
      onChange({ ...value, gallery: [...value.gallery, { url, alt: '' }] });
    } catch (err) {
      console.error('Gallery upload failed', err);
      toast({ kind: 'error', message: 'Could not upload the image.' });
    } finally {
      setUploading(false);
    }
  };

  const videoBad = !!value.videoUrl.trim() && !isVideoUrl(value.videoUrl.trim());

  return (
    <div className="space-y-8">
      {/* Summary */}
      <div className="space-y-2">
        <label htmlFor={`${idPrefix}-summary`} className={LABEL}>
          Summary <span className="text-white/25 normal-case tracking-normal">(one line, shown under the title and in search results)</span>
        </label>
        <input
          id={`${idPrefix}-summary`}
          type="text"
          maxLength={SUMMARY_MAX}
          placeholder="e.g. Techno till sunrise in a Bushwick warehouse."
          className={INPUT}
          value={value.summary}
          onChange={(e) => set('summary', e.target.value)}
        />
        <p className={HINT}>{value.summary.length} / {SUMMARY_MAX}</p>
      </div>

      {/* About (markdown) */}
      <div className="space-y-2">
        <div className="flex items-center justify-between">
          <label htmlFor={`${idPrefix}-about`} className={LABEL}>About</label>
          <button type="button" className={ADD} onClick={() => setPreview(!preview)} aria-pressed={preview}>
            {preview ? 'Edit' : 'Preview'}
          </button>
        </div>
        {preview ? (
          <div className="min-h-[10rem] border border-white/10 bg-black py-4 px-6 text-sm text-white/70 leading-relaxed">
            {value.descriptionMd.trim()
              ? <RichText source={value.descriptionMd} />
              : <p className="text-white/30">Nothing to preview yet.</p>}
          </div>
        ) : (
          <textarea
            id={`${idPrefix}-about`}
            rows={8}
            maxLength={DESCRIPTION_MD_MAX}
            placeholder={'What should people know?\n\n## The night\n**Four rooms**, one lineup. Tickets at [our site](https://…)\n\n- Coat check\n- Free water'}
            className={`${INPUT} py-4 px-6 font-medium resize-y`}
            value={value.descriptionMd}
            onChange={(e) => set('descriptionMd', e.target.value)}
          />
        )}
        <p className={HINT}>
          **bold**, *italic*, [link](https://…), - lists, ## headings · {value.descriptionMd.length} / {DESCRIPTION_MD_MAX}
        </p>
      </div>

      {/* Lineup */}
      <fieldset className="space-y-3">
        <legend className={`${LABEL} mb-1`}>Lineup <span className="text-white/25 normal-case tracking-normal">(optional, with set times)</span></legend>
        {value.lineup.map((row, i) => (
          <div key={i} className="border border-white/10 p-3 space-y-2">
            <div className="flex flex-wrap gap-2">
              <input
                aria-label={`Act ${i + 1} name`}
                type="text"
                maxLength={LINEUP_NAME_MAX}
                placeholder="Name"
                className={`${INPUT} flex-1 min-w-[10rem]`}
                value={row.name}
                onChange={(e) => setRow('lineup', i, { name: e.target.value })}
              />
              <select
                aria-label={`Act ${i + 1} role`}
                className={`${INPUT} w-auto`}
                value={row.role}
                onChange={(e) => setRow('lineup', i, { role: e.target.value as LineupRole })}
              >
                {LINEUP_ROLES.map((r) => <option key={r.id} value={r.id}>{r.label}</option>)}
              </select>
              <input
                aria-label={`Act ${i + 1} set time`}
                type="time"
                className={`${INPUT} w-auto`}
                value={row.setAt ?? ''}
                onChange={(e) => setRow('lineup', i, { setAt: e.target.value || undefined })}
              />
              <button type="button" className={REMOVE} aria-label={`Remove act ${i + 1}`} onClick={() => dropRow('lineup', i)}>
                <Trash2 className="w-4 h-4" />
              </button>
            </div>
            <textarea
              aria-label={`Act ${i + 1} bio`}
              rows={2}
              maxLength={LINEUP_BIO_MAX}
              placeholder="Short bio (optional)"
              className={`${INPUT} resize-y`}
              value={row.bio ?? ''}
              onChange={(e) => setRow('lineup', i, { bio: e.target.value })}
            />
          </div>
        ))}
        <button
          type="button"
          className={ADD}
          disabled={value.lineup.length >= LINEUP_MAX}
          onClick={() => set('lineup', [...value.lineup, { name: '', role: value.lineup.length ? 'support' : 'headliner' }])}
        >
          <Plus className="w-3 h-3" /> Add act
        </button>
      </fieldset>

      {/* FAQ */}
      <fieldset className="space-y-3">
        <legend className={`${LABEL} mb-1`}>FAQ <span className="text-white/25 normal-case tracking-normal">(optional)</span></legend>
        {value.faq.map((row, i) => (
          <div key={i} className="border border-white/10 p-3 space-y-2">
            <div className="flex gap-2">
              <input
                aria-label={`Question ${i + 1}`}
                type="text"
                maxLength={FAQ_Q_MAX}
                placeholder="Question, e.g. Is there parking?"
                className={`${INPUT} flex-1`}
                value={row.q}
                onChange={(e) => setRow('faq', i, { q: e.target.value })}
              />
              <button type="button" className={REMOVE} aria-label={`Remove question ${i + 1}`} onClick={() => dropRow('faq', i)}>
                <Trash2 className="w-4 h-4" />
              </button>
            </div>
            <textarea
              aria-label={`Answer ${i + 1}`}
              rows={2}
              maxLength={FAQ_A_MAX}
              placeholder="Answer"
              className={`${INPUT} resize-y`}
              value={row.a}
              onChange={(e) => setRow('faq', i, { a: e.target.value })}
            />
          </div>
        ))}
        <button
          type="button"
          className={ADD}
          disabled={value.faq.length >= FAQ_MAX}
          onClick={() => set('faq', [...value.faq, { q: '', a: '' }])}
        >
          <Plus className="w-3 h-3" /> Add question
        </button>
      </fieldset>

      {/* Gallery */}
      <fieldset className="space-y-3">
        <legend className={`${LABEL} mb-1`}>Gallery <span className="text-white/25 normal-case tracking-normal">(optional, up to {GALLERY_MAX} images)</span></legend>
        {value.gallery.map((row, i) => (
          <div key={i} className="flex flex-wrap items-center gap-2">
            {/^https:\/\//.test(row.url) && <img src={row.url} alt="" className="w-12 h-12 object-cover border border-white/10" />}
            <input
              aria-label={`Image ${i + 1} link`}
              type="url"
              placeholder="https://…"
              className={`${INPUT} flex-1 min-w-[12rem]`}
              value={row.url}
              onChange={(e) => setRow('gallery', i, { url: e.target.value })}
            />
            <input
              aria-label={`Image ${i + 1} description`}
              type="text"
              maxLength={GALLERY_ALT_MAX}
              placeholder="Describe the image"
              className={`${INPUT} flex-1 min-w-[10rem]`}
              value={row.alt ?? ''}
              onChange={(e) => setRow('gallery', i, { alt: e.target.value })}
            />
            <button type="button" className={REMOVE} aria-label={`Remove image ${i + 1}`} onClick={() => dropRow('gallery', i)}>
              <Trash2 className="w-4 h-4" />
            </button>
          </div>
        ))}
        <div className="flex items-center gap-6">
          <button
            type="button"
            className={ADD}
            disabled={value.gallery.length >= GALLERY_MAX}
            onClick={() => set('gallery', [...value.gallery, { url: '', alt: '' }])}
          >
            <Plus className="w-3 h-3" /> Add image link
          </button>
          {uploaderUid && value.gallery.length < GALLERY_MAX && (
            <label className={`${ADD} cursor-pointer`}>
              {uploading ? <Loader2 className="w-3 h-3 animate-spin" /> : <Upload className="w-3 h-3" />} Upload image
              <input type="file" accept="image/*" className="sr-only" disabled={uploading} onChange={uploadGalleryImage} />
            </label>
          )}
        </div>
      </fieldset>

      {/* Video */}
      <div className="space-y-2">
        <label htmlFor={`${idPrefix}-video`} className={LABEL}>
          Video <span className="text-white/25 normal-case tracking-normal">(YouTube or Vimeo link, optional)</span>
        </label>
        <input
          id={`${idPrefix}-video`}
          type="url"
          maxLength={500}
          placeholder="https://www.youtube.com/watch?v=…"
          className={INPUT}
          aria-invalid={videoBad}
          value={value.videoUrl}
          onChange={(e) => set('videoUrl', e.target.value)}
        />
        {videoBad && <p className="text-xs text-red-400 ml-1">Use a youtube.com, youtu.be or vimeo.com https:// link.</p>}
      </div>

      {/* Age + policies */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div className="space-y-2">
          <label htmlFor={`${idPrefix}-age`} className={LABEL}>Age limit</label>
          <select
            id={`${idPrefix}-age`}
            className={INPUT}
            value={value.minAge}
            onChange={(e) => set('minAge', e.target.value as StoreDraft['minAge'])}
          >
            <option value="">Not stated</option>
            {MIN_AGES.map((a) => <option key={a.id} value={String(a.id)}>{a.label}</option>)}
          </select>
        </div>
        <div className="space-y-2">
          <label htmlFor={`${idPrefix}-refund`} className={LABEL}>Refund policy</label>
          <select
            id={`${idPrefix}-refund`}
            className={INPUT}
            value={value.refundPolicy}
            onChange={(e) => set('refundPolicy', e.target.value as StoreDraft['refundPolicy'])}
          >
            <option value="">Not stated</option>
            {REFUND_POLICIES.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
          </select>
        </div>
      </div>
      <div className="space-y-2">
        <label htmlFor={`${idPrefix}-notes`} className={LABEL}>
          Good to know <span className="text-white/25 normal-case tracking-normal">(dress code, bag policy, re-entry, optional)</span>
        </label>
        <textarea
          id={`${idPrefix}-notes`}
          rows={3}
          maxLength={POLICY_NOTES_MAX}
          placeholder="e.g. No re-entry. Clear bags only. ID checked at the door."
          className={`${INPUT} resize-y`}
          value={value.policyNotes}
          onChange={(e) => set('policyNotes', e.target.value)}
        />
        <p className={HINT}>{value.policyNotes.length} / {POLICY_NOTES_MAX}</p>
      </div>
    </div>
  );
}
