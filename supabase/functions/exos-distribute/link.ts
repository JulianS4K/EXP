// Pass 0 of exos-distribute: link published, upcoming Exos events to their
// marketplace events (exos_channel_event_links, mig 20260926191000).
//
// For each channel the organizer ticked (distribution_networks):
//   * decisions stand: linked / created / rejected rows, and review rows
//     (waiting on staff), are never touched here
//   * the channel's read-only catalog search + decideMatch(); 'unmatched'
//     rows are searched again after RECHECK_HOURS
// Only channels in the registry with catalog access take part (StubHub today).
// Nothing here writes to a marketplace.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  exosEventRef,
  isChannelId,
  type ChannelId,
  type ExosEventRowForChannels,
  type MarketplaceChannel,
} from "../_shared/marketplace/channel.ts";
import { decideMatch, type ScoredCandidate } from "../_shared/marketplace/match.ts";

const EVENTS_PER_RUN = 50;
const RECHECK_HOURS = 24;
const FINAL = new Set(["linked", "created", "rejected", "review"]);

interface EventRow extends ExosEventRowForChannels {
  org_id: string;
  distribution_networks: string[] | null;
}

interface LinkRow {
  event_id: string;
  channel: string;
  status: string;
  checked_at: string | null;
}

function candidateJson(s: ScoredCandidate) {
  const c = s.candidate;
  return {
    external_event_id: c.externalEventId,
    name: c.name,
    starts_at: c.startsAt ?? c.startsLocal ?? null,
    venue: [c.venueName, c.venueCity].filter(Boolean).join(", ") || null,
    url: c.url ?? null,
    score: s.score,
    reasons: s.reasons,
  };
}

export async function linkEvents(sb: SupabaseClient, channels: Map<ChannelId, MarketplaceChannel>, now = new Date()) {
  const { data: events, error } = await sb
    .from("exos_events")
    .select("id, org_id, name, starts_at, occurs_at_local, venue_name, venue_location, venue_address, distribution_networks")
    .eq("status", "published")
    .gt("starts_at", now.toISOString())
    .not("distribution_networks", "is", null)
    .order("starts_at", { ascending: true })
    .limit(EVENTS_PER_RUN);
  if (error) throw new Error(`read events: ${error.message}`);
  const rows = (events ?? []) as EventRow[];
  if (!rows.length) return { events: 0, linked: 0, review: 0, unmatched: 0, errors: 0 };

  const ids = rows.map((r) => r.id);
  const { data: links, error: lErr } = await sb.from("exos_channel_event_links")
    .select("event_id, channel, status, checked_at").in("event_id", ids);
  if (lErr) throw new Error(`read links: ${lErr.message}`);
  const linkBy = new Map(((links ?? []) as LinkRow[]).map((l) => [`${l.event_id}:${l.channel}`, l]));

  const counts = { events: rows.length, linked: 0, review: 0, unmatched: 0, errors: 0 };
  const recheckBefore = now.getTime() - RECHECK_HOURS * 3_600_000;

  for (const ev of rows) {
    const ref = exosEventRef(ev);
    if (!ref) continue;
    for (const net of ev.distribution_networks ?? []) {
      if (!isChannelId(net)) continue;
      const ch = channels.get(net);
      if (!ch) continue;
      const prior = linkBy.get(`${ev.id}:${net}`);
      if (prior && FINAL.has(prior.status)) continue;
      if (prior?.checked_at && Date.parse(prior.checked_at) > recheckBefore) continue;

      const base = { event_id: ev.id, org_id: ev.org_id, channel: net, checked_at: now.toISOString(), updated_at: now.toISOString() };
      if (!ch.findEvents) continue; // no catalog access for this channel (yet)
      let row: Record<string, unknown>;
      try {
        const d = decideMatch(ref, await ch.findEvents(ref));
        const top = d.candidates.slice(0, 5).map(candidateJson);
        row = d.decision === "link"
          ? { ...base, status: "linked", external_event_id: d.best.candidate.externalEventId, method: "auto_match", confidence: d.best.score, candidates: top }
          : d.decision === "review"
          ? { ...base, status: "review", external_event_id: null, method: "auto_match", confidence: d.best.score, candidates: top }
          : { ...base, status: "unmatched", external_event_id: null, method: "auto_match", confidence: null, candidates: top.length ? top : null };
      } catch (e) {
        counts.errors++;
        console.error("exos-distribute: catalog search failed", net, ev.id, String(e));
        continue;
      }

      let { error: upErr } = await sb.from("exos_channel_event_links").upsert(row, { onConflict: "event_id,channel" });
      if (upErr && upErr.code === "23505" && row.status === "linked") {
        // That marketplace event is already linked to another Exos event
        // (e.g. a duplicate listing of the same show): a human decides.
        row = { ...row, status: "review", external_event_id: null };
        ({ error: upErr } = await sb.from("exos_channel_event_links").upsert(row, { onConflict: "event_id,channel" }));
      }
      if (upErr) {
        counts.errors++;
        console.error("exos-distribute: link write failed", net, ev.id, upErr.message);
        continue;
      }
      counts[row.status as "linked" | "review" | "unmatched"]++;
    }
  }
  return counts;
}
