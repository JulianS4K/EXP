// /orgs/:orgId/promoters — the organizer's street team (mig 20260924233000).
//
// Add a promoter (name → code), send them their private kit link, and see a
// leaderboard of tickets + gross per promoter. Every free and paid ticket
// bought through a promoter's links carries their code.

import { useEffect, useState, type FormEvent } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Copy, Pause, Play, RefreshCw, Trophy, UserPlus } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { useAuth } from '../context/AuthContext';
import { getOrganization } from '../lib/orgs';
import { publicUrl, formatCurrency } from '../lib/utils';
import {
  codeFromName, linkInBioPath, listPromoters, orgPromoterStats, setPromoterStatus, upsertPromoter,
  type Promoter, type PromoterStat,
} from '../lib/promoters';

export default function OrgPromoters() {
  const { orgId } = useParams();
  const { user } = useAuth();
  const { toast } = useToast();
  const [promoters, setPromoters] = useState<Promoter[]>([]);
  const [stats, setStats] = useState<Map<string, PromoterStat>>(new Map());
  const [loading, setLoading] = useState(true);
  const [name, setName] = useState('');
  const [code, setCode] = useState('');
  const [codeTouched, setCodeTouched] = useState(false);
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [orgSlug, setOrgSlug] = useState<string | null>(null);
  useEffect(() => {
    if (orgId) getOrganization(orgId).then((o) => setOrgSlug(o?.slug ?? null)).catch(() => {});
  }, [orgId]);

  const load = async () => {
    if (!orgId) return;
    try {
      const [ps, st] = await Promise.all([listPromoters(orgId), orgPromoterStats(orgId).catch(() => [] as PromoterStat[])]);
      setPromoters(ps);
      setStats(new Map(st.map((s) => [s.promoterId, s])));
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not load promoters.' });
    } finally {
      setLoading(false);
    }
  };
  useEffect(() => { void load(); }, [orgId]);

  const kitUrl = (p: Promoter) => publicUrl(`p/${p.kitToken}`);
  const copy = async (value: string, label: string) => {
    try { await navigator.clipboard.writeText(value); toast({ kind: 'success', message: label }); }
    catch { toast({ kind: 'error', message: 'Could not copy. Long-press the link to copy it.' }); }
  };

  const add = async (e: FormEvent) => {
    e.preventDefault();
    if (!orgId) return;
    const c = code || codeFromName(name);
    if (!name.trim() || !c) { toast({ kind: 'error', message: 'Give the promoter a name.' }); return; }
    setBusy(true);
    try {
      await upsertPromoter(orgId, { code: c, name: name.trim(), email: email.trim() || undefined });
      setName(''); setCode(''); setCodeTouched(false); setEmail('');
      toast({ kind: 'success', message: `Added ${name.trim()}. Copy their kit link to send it.` });
      await load();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not add the promoter.' });
    } finally {
      setBusy(false);
    }
  };

  const toggle = async (p: Promoter, rotate = false) => {
    try {
      await setPromoterStatus(p.id, rotate ? p.status : p.status === 'active' ? 'paused' : 'active', rotate);
      toast({ kind: 'success', message: rotate ? 'New kit link made. The old one no longer works.' : p.status === 'active' ? 'Paused. Their kit link is closed; past sales still count.' : 'Reactivated.' });
      await load();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not update the promoter.' });
    }
  };

  if (!user) return <div className="max-w-3xl mx-auto p-20 text-center type text-white/50 uppercase tracking-widest text-xs">Sign in to manage promoters.</div>;

  const ranked = [...promoters].sort((a, b) => (stats.get(b.id)?.tickets ?? 0) - (stats.get(a.id)?.tickets ?? 0));
  const field = 'bg-black border border-white/20 px-3 py-2 text-sm text-white focus:outline-none focus:border-brand-primary';

  return (
    <div className="max-w-4xl mx-auto px-4 py-12">
      <Link to={`/orgs/${orgId}/promote`} className="type flex items-center text-white/40 hover:text-brand-primary mb-8 uppercase tracking-widest text-[10px]">
        <ArrowLeft className="w-4 h-4 mr-2" /> Back to Promote
      </Link>
      <h1 className="disp text-4xl uppercase tracking-wide text-white mb-2">Promoters</h1>
      <p className="text-sm text-white/60 mb-8">
        Each promoter gets a code and a private kit link. Every ticket bought through their links, free or paid, is credited to them,
        and their kit shows their own sales. Fans who share after buying pass the credit along.
      </p>

      <form onSubmit={add} className="bg-[#111] border border-white/10 p-6 mb-8 grid gap-2 sm:grid-cols-4">
        <input className={`${field} sm:col-span-2`} placeholder="Name (e.g. DJ Kay)" aria-label="Promoter name" value={name}
          onChange={(e) => { setName(e.target.value); if (!codeTouched) setCode(codeFromName(e.target.value)); }} />
        <input className={field} placeholder="code" aria-label="Promoter code" value={code}
          onChange={(e) => { setCodeTouched(true); setCode(codeFromName(e.target.value)); }} />
        <input className={field} placeholder="Email (optional)" aria-label="Promoter email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
        <button disabled={busy} className="sm:col-span-4 inline-flex items-center justify-center gap-2 bg-brand-primary text-black px-4 py-2 text-sm font-black uppercase disabled:opacity-50">
          <UserPlus className="w-4 h-4" /> Add promoter
        </button>
        <p className="sm:col-span-4 text-[11px] text-white/40">
          Using a code that's already on shared links (a campaign name from an event's Promote page)? Enter it as the code and those sales count too.
        </p>
      </form>

      <h2 className="disp text-lg uppercase tracking-wide text-white mb-3 flex items-center gap-2"><Trophy className="w-4 h-4 text-brand-primary" /> Leaderboard</h2>
      {loading ? (
        <p className="type text-[11px] uppercase tracking-widest text-white/40">Loading…</p>
      ) : ranked.length === 0 ? (
        <p className="text-[11px] text-white/40 italic">No promoters yet.</p>
      ) : (
        <div className="space-y-2">
          {ranked.map((p, i) => {
            const s = stats.get(p.id);
            return (
              <div key={p.id} className={`flex flex-wrap items-center gap-3 bg-[#111] border border-white/10 px-4 py-3 ${p.status === 'paused' ? 'opacity-60' : ''}`}>
                <span className="disp text-xl w-8 text-white/40">{i + 1}</span>
                <div className="min-w-0 flex-1">
                  <p className="font-black text-white truncate">{p.name} <span className="type text-[10px] text-white/40 ml-2">{p.code}</span></p>
                  <p className="type text-[10px] uppercase tracking-widest text-white/50">
                    {s?.tickets ?? 0} tickets · {formatCurrency(s?.gross ?? 0)}{p.status === 'paused' ? ' · paused' : ''}
                  </p>
                </div>
                <button onClick={() => copy(kitUrl(p), `Kit link for ${p.name} copied.`)} disabled={p.status === 'paused'} className="inline-flex items-center gap-1 text-[11px] font-black uppercase text-brand-primary disabled:opacity-40" aria-label={`Copy kit link for ${p.name}`}>
                  <Copy className="w-3 h-3" /> Kit link
                </button>
                {orgSlug && (
                  <button onClick={() => copy(publicUrl(linkInBioPath(orgSlug, p.code)), `Link in bio for ${p.name} copied.`)} disabled={p.status === 'paused'} className="inline-flex items-center gap-1 text-[11px] font-black uppercase text-white/60 hover:text-white disabled:opacity-40" aria-label={`Copy link in bio for ${p.name}`}>
                    <Copy className="w-3 h-3" /> Bio link
                  </button>
                )}
                <button onClick={() => toggle(p)} className="p-2 text-white/40 hover:text-white" aria-label={p.status === 'active' ? `Pause ${p.name}` : `Reactivate ${p.name}`}>
                  {p.status === 'active' ? <Pause className="w-4 h-4" /> : <Play className="w-4 h-4" />}
                </button>
                <button onClick={() => toggle(p, true)} className="p-2 text-white/40 hover:text-white" aria-label={`New kit link for ${p.name}`} title="Make a new kit link (the old one stops working)">
                  <RefreshCw className="w-4 h-4" />
                </button>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
