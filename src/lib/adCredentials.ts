// Ad platform credentials for server-side conversions (mig 20260930100000).
//
// Owner / manager only, through two SECURITY DEFINER RPCs: the table itself
// has no client access. The access token is write-only: it's stored in
// Supabase Vault, the list says only whether one is saved (has_secret), and
// saving with a blank token field keeps the saved one. docs/marketing-conversions.md.

import { supabase } from './supabase';

export type AdPlatform = 'meta' | 'tiktok' | 'ga4' | 'google_ads' | 'reddit' | 'snap';

export interface AdPlatformField {
  key: string;
  label: string;
  placeholder: string;
  pattern: RegExp;
  required: boolean;
}

export interface AdPlatformInfo {
  id: AdPlatform;
  label: string;
  fields: AdPlatformField[];
  secretLabel: string;
  /** Where the organizer finds the ids and the token. */
  help: string;
  /** Not sent yet even when enabled (Google Ads: OAuth + verification pending). */
  plannedOnly?: boolean;
  /** Label of the optional test code field (null: the platform has none). */
  testLabel: string | null;
}

// Same id rules as SQL _exos_ad_config_ok.
export const AD_PLATFORMS: readonly AdPlatformInfo[] = [
  {
    id: 'meta', label: 'Meta (Facebook / Instagram)',
    fields: [{ key: 'pixel_id', label: 'Pixel (dataset) ID', placeholder: '123456789012345', pattern: /^[0-9]{5,20}$/, required: true }],
    secretLabel: 'Conversions API access token',
    help: 'Events Manager → your pixel → Settings → Conversions API → Generate access token.',
    testLabel: 'Test event code',
  },
  {
    id: 'tiktok', label: 'TikTok',
    fields: [{ key: 'pixel_code', label: 'Pixel code', placeholder: 'CXXXXXXXXXXXXXXXXXXX', pattern: /^[A-Z0-9]{10,40}$/, required: true }],
    secretLabel: 'Events API access token',
    help: 'TikTok Ads Manager → Events Manager → your pixel → Settings → Generate access token.',
    testLabel: 'Test event code',
  },
  {
    id: 'ga4', label: 'Google Analytics 4',
    fields: [{ key: 'measurement_id', label: 'Measurement ID', placeholder: 'G-XXXXXXXXXX', pattern: /^G-[A-Z0-9]{4,20}$/, required: true }],
    secretLabel: 'Measurement Protocol API secret',
    help: 'GA4 Admin → Data streams → your web stream → Measurement Protocol API secrets → Create.',
    testLabel: 'Debug mode (any value)',
  },
  {
    id: 'google_ads', label: 'Google Ads',
    fields: [
      { key: 'customer_id', label: 'Customer ID (10 digits)', placeholder: '1234567890', pattern: /^[0-9]{10}$/, required: true },
      { key: 'conversion_action_id', label: 'Conversion action ID', placeholder: '987654321', pattern: /^[0-9]{1,20}$/, required: true },
      { key: 'login_customer_id', label: 'Manager (MCC) ID, optional', placeholder: '1234567890', pattern: /^[0-9]{10}$/, required: false },
    ],
    secretLabel: 'OAuth refresh token',
    help: 'Uploads go through Google’s Data Manager API. Not sent yet: the Google sign-in step is still being built.',
    plannedOnly: true,
    testLabel: 'Validate only (any value)',
  },
  {
    id: 'reddit', label: 'Reddit',
    fields: [{ key: 'pixel_id', label: 'Pixel ID', placeholder: 'a2_xxxxxxxx', pattern: /^(a2|t2)_[A-Za-z0-9]{1,40}$/, required: true }],
    secretLabel: 'Conversions API access token',
    help: 'Reddit Ads → Events Manager → Conversions API → Generate access token.',
    testLabel: 'Test ID',
  },
  {
    id: 'snap', label: 'Snapchat',
    fields: [{ key: 'pixel_id', label: 'Pixel ID', placeholder: '00000000-0000-0000-0000-000000000000', pattern: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, required: true }],
    secretLabel: 'Conversions API token',
    help: 'Snap Ads Manager → Events Manager → your pixel → Conversions API → Generate token.',
    testLabel: 'Validate only (any value)',
  },
];

export interface AdCredential {
  platform: AdPlatform;
  config: Record<string, string>;
  hasSecret: boolean;
  enabled: boolean;
  testEventCode: string | null;
  updatedAt: string | null;
  sent30d: number;
  skipped30d: number;
  failed30d: number;
  pending: number;
  lastSentAt: string | null;
}

/** Field errors for a platform's ids ({} when valid). Empty optional fields are fine. */
export function validateAdConfig(info: AdPlatformInfo, config: Record<string, string>, enabling: boolean): Record<string, string> {
  const errs: Record<string, string> = {};
  for (const f of info.fields) {
    const v = (config[f.key] ?? '').trim();
    if (!v) {
      if (enabling && f.required) errs[f.key] = 'Required to turn it on';
      continue;
    }
    if (!f.pattern.test(v)) errs[f.key] = `Doesn’t look like a ${f.label.toLowerCase()}`;
  }
  return errs;
}

/** A valid test code: letters, digits, _ and -, up to 64. */
export const TEST_CODE_RE = /^[A-Za-z0-9_-]{1,64}$/;

export async function listAdCredentials(orgId: string): Promise<AdCredential[]> {
  const { data, error } = await supabase.rpc('exos_list_ad_credentials', { p_org_id: orgId });
  if (error) throw error;
  return ((data ?? []) as any[]).map((r) => ({
    platform: r.platform,
    config: r.config ?? {},
    hasSecret: !!r.has_secret,
    enabled: !!r.enabled,
    testEventCode: r.test_event_code ?? null,
    updatedAt: r.updated_at ?? null,
    sent30d: r.sent_30d ?? 0,
    skipped30d: r.skipped_30d ?? 0,
    failed30d: r.failed_30d ?? 0,
    pending: r.pending ?? 0,
    lastSentAt: r.last_sent_at ?? null,
  }));
}

/**
 * Save one platform. `secret`: undefined / '' keeps the saved token, a value
 * replaces it; `removeSecret` deletes it (and must go with enabled = false).
 */
export async function saveAdCredential(orgId: string, platform: AdPlatform, input: {
  config: Record<string, string>;
  secret?: string;
  removeSecret?: boolean;
  enabled: boolean;
  testEventCode?: string | null;
}): Promise<void> {
  const secret = input.removeSecret ? '' : (input.secret?.trim() ? input.secret.trim() : null);
  const { error } = await supabase.rpc('exos_set_ad_credential', {
    p_org_id: orgId,
    p_platform: platform,
    p_config: input.config,
    p_secret: secret,
    p_enabled: input.enabled,
    p_test_event_code: input.testEventCode?.trim() || null,
  });
  if (error) throw error;
}
