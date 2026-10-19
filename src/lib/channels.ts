// Channels (mig 20261019090000): one Exos event sold 1-1 on Eventbrite (and
// Luma, once it is switched on), with a primary ticketing system for the QR
// codes the event is shared on other markets with. (Luma's API needs Luma
// Plus, so it is off unless VITE_EXOS_LUMA=on.) Exos is the source: the
// sync (exos-channel-sync) creates the event there and keeps its details,
// ticket types and prices in step; sales from every platform come off one
// shared count. Pure parsing up top; the RPC / edge calls below.

import { supabase } from './supabase';
import { LUMA_ENABLED } from './integrations';

export type Channel = 'eventbrite' | 'luma';
export type PrimarySource = 'exos' | Channel;

export const CHANNEL_LABEL: Record<PrimarySource, string> = { exos: 'Exos', eventbrite: 'Eventbrite', luma: 'Luma' };

/** The platforms an organizer can pick right now (Luma stays hidden until switched on). */
export const CHANNELS: Channel[] = LUMA_ENABLED ? ['eventbrite', 'luma'] : ['eventbrite'];

export interface ChannelChoice {
  primary: PrimarySource;
  also: Channel[];
}

/** The primary must sell the event: picking Eventbrite or Luma as primary also sells there. */
export function normalizeChoice(c: ChannelChoice): ChannelChoice {
  const also = [...new Set(c.also.filter((x) => CHANNELS.includes(x)))];
  const primary = c.primary === 'exos' || CHANNELS.includes(c.primary) ? c.primary : 'exos';
  if (primary !== 'exos' && !also.includes(primary)) also.push(primary);
  return { primary, also };
}

export interface Connections {
  eventbrite: boolean;
  luma: boolean;
  writes: Record<Channel, boolean>;
  canSwitch: boolean;
}

export function parseConnections(d: any): Connections {
  return {
    eventbrite: d?.eventbrite === true,
    luma: d?.luma === true && LUMA_ENABLED,
    writes: { eventbrite: d?.writes?.eventbrite === true, luma: d?.writes?.luma === true },
    canSwitch: d?.can_switch === true,
  };
}

export interface Mirror {
  provider: Channel;
  mode: 'create' | 'link';
  externalId: string | null;
  externalUrl: string | null;
  status: 'pending' | 'synced' | 'dry_run' | 'error';
  inStep: boolean;
  syncedAt: Date | null;
  plannedAt: Date | null;
  lastError: string | null;
  planSteps: number | null;
}

export interface ChannelStatus {
  primary: PrimarySource;
  canManage: boolean;
  canSwitch: boolean;
  connected: Record<Channel, boolean>;
  writes: Record<Channel, boolean>;
  mirrors: Mirror[];
  compsQueued: number;
}

const date = (v: unknown) => (typeof v === 'string' ? new Date(v) : null);

export function parseChannelStatus(d: any): ChannelStatus {
  const primary: PrimarySource = d?.primary_source === 'eventbrite' || d?.primary_source === 'luma' ? d.primary_source : 'exos';
  return {
    primary,
    canManage: d?.can_manage === true,
    canSwitch: d?.can_switch === true,
    connected: { eventbrite: d?.connected?.eventbrite === true, luma: d?.connected?.luma === true && LUMA_ENABLED },
    writes: { eventbrite: d?.writes?.eventbrite === true, luma: d?.writes?.luma === true },
    mirrors: (Array.isArray(d?.mirrors) ? d.mirrors : [])
      .filter((m: any) => m?.provider === 'eventbrite' || (m?.provider === 'luma' && (LUMA_ENABLED || primary === 'luma')))
      .map((m: any): Mirror => ({
        provider: m.provider,
        mode: m.mode === 'link' ? 'link' : 'create',
        externalId: m.external_id ?? null,
        externalUrl: typeof m.external_url === 'string' && m.external_url.startsWith('https://') ? m.external_url : null,
        status: ['synced', 'dry_run', 'error'].includes(m.status) ? m.status : 'pending',
        inStep: m.in_step === true,
        syncedAt: date(m.synced_at),
        plannedAt: date(m.planned_at),
        lastError: m.last_error ?? null,
        planSteps: typeof m.plan_steps === 'number' ? m.plan_steps : null,
      })),
    compsQueued: Number(d?.comps_queued) || 0,
  };
}

/** One line for the organizer about a mirror. */
export function mirrorLine(m: Mirror, writesOn: boolean): string {
  if (m.status === 'error') return m.lastError ?? 'The last sync failed; it retries on its own.';
  if (m.status === 'dry_run' || !writesOn) {
    return `Ready, not sent: writes to ${CHANNEL_LABEL[m.provider]} are off${m.planSteps ? ` (${m.planSteps} change${m.planSteps === 1 ? '' : 's'} planned)` : ''}.`;
  }
  if (m.status === 'pending') return m.mode === 'link' ? 'Linking…' : 'Creating it there on the next sync (within 2 minutes).';
  return m.inStep ? 'In step with Exos.' : 'Changes waiting for the next sync.';
}

/** The Eventbrite event id (digits) or Luma event id (evt-…) out of a pasted link or id. */
export function externalIdFrom(provider: Channel, input: string): string | null {
  const s = input.trim();
  if (provider === 'luma') return s.match(/\bevt-[A-Za-z0-9]{4,40}\b/)?.[0] ?? null;
  if (/^[0-9]{1,24}$/.test(s)) return s;
  const m = s.match(/eventbrite\.[a-z.]+\/(?:e|myevent)\/(?:[^/?#]*-)?([0-9]{6,24})/i) ?? s.match(/[?&]eid=([0-9]{6,24})/);
  return m ? m[1] : null;
}

// ── Calls ───────────────────────────────────────────────────────────────

const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};
const rpcMsg = (e: { message?: string }) => new Error((e.message ?? 'Not saved.').replace(/^exos_\w+: /, ''));

export async function fetchConnections(orgId: string): Promise<Connections> {
  const { data, error } = await supabase.rpc('exos_channel_connections', { p_org_id: orgId });
  if (error) throw rpcMsg(error);
  return parseConnections(data);
}

export async function fetchChannelStatus(eventId: string): Promise<ChannelStatus> {
  const { data, error } = await supabase.rpc('exos_channel_status', { p_event_id: eventId });
  if (error) throw rpcMsg(error);
  return parseChannelStatus(data);
}

export async function setChannel(eventId: string, provider: Channel, externalId?: string | null): Promise<void> {
  const { error } = await supabase.rpc('exos_channel_set', {
    p_event_id: eventId, p_provider: provider, p_mode: externalId ? 'link' : 'create', p_external_id: externalId ?? null,
  });
  if (error) throw rpcMsg(error);
}

export async function removeChannel(eventId: string, provider: Channel): Promise<void> {
  const { error } = await supabase.rpc('exos_channel_remove', { p_event_id: eventId, p_provider: provider });
  if (error) throw rpcMsg(error);
}

export async function setPrimary(eventId: string, primary: PrimarySource): Promise<void> {
  const { error } = await supabase.rpc('exos_set_resale_options', { p_event_id: eventId, p_listing_qty: null, p_primary_source: primary, p_rebalance: null });
  if (error) throw rpcMsg(error);
}

export async function setLumaWrites(orgId: string, on: boolean): Promise<void> {
  const { error } = await supabase.rpc('exos_integration_set_writes', { p_org_id: orgId, p_provider: 'luma', p_on: on });
  if (error) throw rpcMsg(error);
}

/** Apply the create-event choice to a new event: each platform, then the primary. */
export async function applyChoice(eventId: string, choice: ChannelChoice): Promise<void> {
  const c = normalizeChoice(choice);
  for (const p of c.also) await setChannel(eventId, p);
  if (c.primary !== 'exos') await setPrimary(eventId, c.primary);
  if (c.also.length) await pushChannels(eventId).catch(() => undefined);   // the cron picks it up anyway
}

/** "Sync now": run the event's mirrors (exos-channel-sync /push). */
export async function pushChannels(eventId: string): Promise<{ passes?: number }> {
  const url = (env.VITE_SUPABASE_URL ?? '').replace(/\/+$/, '');
  if (!url) throw new Error('Channels are not configured.');
  const { data } = await supabase.auth.getSession();
  const jwt = data.session?.access_token;
  if (!jwt) throw new Error('Sign in first.');
  let res: Response;
  try {
    res = await fetch(`${url}/functions/v1/exos-channel-sync/push`, {
      method: 'POST',
      headers: { ...(env.VITE_SUPABASE_ANON_KEY ? { apikey: env.VITE_SUPABASE_ANON_KEY } : {}), Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ event: eventId }),
    });
  } catch {
    throw new Error("Couldn't reach Exos. Check the connection.");
  }
  const out = await res.json().catch(() => null);
  if (!res.ok) throw new Error(typeof out?.error === 'string' ? out.error : res.status === 404 ? 'The channel sync is not deployed yet.' : `Request failed (${res.status}).`);
  return out ?? {};
}

export async function queueLumaComps(eventId: string, tierId: string, emails: string[], sendEmail: boolean) {
  const { data, error } = await supabase.rpc('exos_channel_queue_comps', {
    p_event_id: eventId, p_tier_id: tierId, p_guests: emails.map((email) => ({ email })), p_send_email: sendEmail,
  });
  if (error) throw rpcMsg(error);
  return data as { queued: number; invalid: number; already: number };
}
