// exos-api: the fan API, /v1/me/… (mig 20261105110000, docs/api/me.json,
// _shared/api/me.ts). The token's own user: their tickets (with the live
// rotating barcode), orders, transfers, memberships, passes, refund requests,
// wallet passes and profile.
//
// Every route is ONE call to exos_api_me(token hash, kind, action, target,
// args): the SQL re-resolves the token (an org API key has no user and is
// refused), checks me:read / me:write, and runs the app's own signed-in RPC
// as that user, so transfer locks, claim keys, refund windows and rate limits
// hold exactly as in the app. No business rule lives here.
//
// Wallet routes build the pass the way exos-wallet does (same certificates,
// same web service URL, so Apple devices keep talking to exos-wallet): Apple
// EXOS_WALLET_APPLE_PASS_TYPE_ID, _TEAM_ID, _CERT, _PRIVATE_KEY, _WWDR_CERT,
// optional EXOS_WALLET_PUBLIC_URL; Google EXOS_WALLET_GOOGLE_ISSUER_ID,
// _SERVICE_ACCOUNT_KEY, optional _ORIGINS. Unset: 503 "wallet not configured".

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { ApiRoute } from "../_shared/api/routes.ts";
import { pageEnvelope, type Page } from "../_shared/api/paging.ts";
import {
  marketingView, ME_ROUTES, MeBodyError, meReadArgs, meWriteArgs, walletRefusalStatus,
} from "../_shared/api/me.ts";
import { type AppleIdentity, buildApplePassJson, buildPkpass, PKPASS_MIME } from "../_shared/wallet/apple.ts";
import { hashAuthToken, newAuthToken } from "../_shared/wallet/codes.ts";
import { createRs256Signer, googleSaveLink, type Rs256Signer } from "../_shared/wallet/google.ts";
import type { WalletPayload } from "../_shared/wallet/payload.ts";
import { createPkcs7Signer, type PassSigner } from "../_shared/wallet/pkcs7.ts";
import { buildSeasonPassAppleJson, type SeasonPassPayload, seasonPassSaveUrl } from "../_shared/wallet/seasonPass.ts";
import { Answer, CoreError } from "./core.ts";

export interface MeCtx {
  sb: SupabaseClient;
  /** SHA-256 hex of the bearer token, and its kind; exos_api_me re-resolves them. */
  tokenHash: string;
  kind: "api_key" | "pat" | "oauth";
  params: Record<string, string>;
  q: URLSearchParams;
  page: Page;
  body: Record<string, unknown>;
}

export const ME_ROUTE_IDS = new Set(Object.keys(ME_ROUTES));

const CREATED = new Set(["create-my-transfers", "create-my-order-transfers", "create-my-refund-request",
  "create-my-order-refund-request", "create-my-token"]);

export async function handleMe(route: ApiRoute, c: MeCtx): Promise<unknown> {
  const spec = ME_ROUTES[route.id];
  if (!spec) throw new CoreError(404, "not found");
  const target = spec.target ? c.params[spec.target] ?? null : null;
  let args: Record<string, unknown>;
  try {
    args = route.method === "GET" || route.method === "DELETE" ? meReadArgs(route.id, c.q) : meWriteArgs(route.id, c.body);
  } catch (e) {
    if (e instanceof MeBodyError) throw new CoreError(400, e.message);
    throw e;
  }
  if (spec.passKind) args.kind = spec.passKind;
  if (spec.wallet) return await wallet(c, spec.action, target!, spec.wallet, args);
  if (route.paged) {
    args.limit = c.page.perPage;
    args.offset = c.page.from;
  }
  const out = await me(c, spec.action, target, args) as Record<string, unknown> | null;
  if (route.paged) {
    const rows = Array.isArray(out?.rows) ? out!.rows as unknown[] : [];
    return pageEnvelope(rows, c.page, typeof out?.total === "number" ? out.total : rows.length);
  }
  if (route.id === "get-my-marketing-preferences" || route.id === "set-my-marketing-preferences") {
    return { data: marketingView(out) };
  }
  return CREATED.has(route.id) ? new Answer(201, { data: out }) : { data: out };
}

async function me(c: MeCtx, action: string, target: string | null, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await c.sb.rpc("exos_api_me", {
    p_hash: c.tokenHash, p_kind: c.kind, p_action: action, p_target: target, p_args: args,
  });
  if (error) throw error;
  return data;
}

// -- Wallet ------------------------------------------------------------------------

interface AppleSetup {
  identity: AppleIdentity;
  signer: PassSigner;
}
interface GoogleSetup {
  issuerId: string;
  origins: string[];
  signer: Rs256Signer;
}
let appleSetup: Promise<AppleSetup | null> | null = null;
let googleSetup: Promise<GoogleSetup | null> | null = null;

const env = (k: string): string | undefined => {
  const v = Deno.env.get(k);
  return v && v.trim() ? v : undefined;
};

function apple(): Promise<AppleSetup | null> {
  appleSetup ??= (async () => {
    const passTypeIdentifier = env("EXOS_WALLET_APPLE_PASS_TYPE_ID");
    const teamIdentifier = env("EXOS_WALLET_APPLE_TEAM_ID");
    const certPem = env("EXOS_WALLET_APPLE_CERT");
    const keyPem = env("EXOS_WALLET_APPLE_PRIVATE_KEY");
    const wwdrPem = env("EXOS_WALLET_APPLE_WWDR_CERT");
    if (!passTypeIdentifier || !teamIdentifier || !certPem || !keyPem || !wwdrPem) return null;
    try {
      const signer = await createPkcs7Signer({ certPem, keyPem, wwdrPem });
      // The pass's web service is exos-wallet's, as for a pass from the app.
      const base = (env("EXOS_WALLET_PUBLIC_URL") ?? `${env("SUPABASE_URL") ?? ""}/functions/v1/exos-wallet`).replace(/\/+$/, "");
      if (!base.startsWith("https://")) return null;
      return { identity: { passTypeIdentifier, teamIdentifier, webServiceURL: `${base}/apple` }, signer };
    } catch (e) {
      console.error(`exos-api: apple signing setup failed (${e instanceof Error ? e.message : "error"}); wallet disabled`);
      return null;
    }
  })();
  return appleSetup;
}

function google(): Promise<GoogleSetup | null> {
  googleSetup ??= (async () => {
    const issuerId = env("EXOS_WALLET_GOOGLE_ISSUER_ID");
    const sa = env("EXOS_WALLET_GOOGLE_SERVICE_ACCOUNT_KEY");
    if (!issuerId || !sa || !/^[0-9]+$/.test(issuerId)) return null;
    try {
      const signer = await createRs256Signer(sa);
      const origins = (env("EXOS_WALLET_GOOGLE_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
      return { issuerId, origins, signer };
    } catch (e) {
      console.error(`exos-api: google signing setup failed (${e instanceof Error ? e.message : "error"}); wallet disabled`);
      return null;
    }
  })();
  return googleSetup;
}

async function wallet(
  c: MeCtx, action: string, target: string, kind: "apple" | "google", args: Record<string, unknown>,
): Promise<unknown> {
  const a = kind === "apple" ? await apple() : null;
  const g = kind === "google" ? await google() : null;
  if (!a && !g) throw new CoreError(503, "wallet not configured");

  if (action === "wallet.season_pass") {
    const res = await me(c, action, target, { kind: args.kind }) as Record<string, unknown> | null;
    if (!res?.ok) throw new CoreError(walletRefusalStatus(res?.reason), String(res?.reason ?? "wallet_pass_unavailable"));
    const p = res.payload as SeasonPassPayload;
    if (a) {
      const { bytes } = await buildPkpass(buildSeasonPassAppleJson(p, a.identity), a.signer);
      return pkpass(bytes, p.serial);
    }
    return { data: { save_url: await seasonPassSaveUrl(p, g!.issuerId, g!.signer, g!.origins), serial: p.serial } };
  }

  // A ticket: a fresh Apple authenticationToken each download (only its hash
  // is kept), exactly as exos-wallet POST /pass.
  const token = a ? newAuthToken() : null;
  const issued = await me(c, action, target, {
    kind, token_hash: token ? await hashAuthToken(token) : null, pass_type: a ? a.identity.passTypeIdentifier : null,
  }) as Record<string, unknown> | null;
  if (!issued?.ok) throw new CoreError(409, String(issued?.reason ?? "not-available"));
  const { data: payload, error } = await c.sb.rpc("exos_wallet_pass_payload", { p_serial: issued.serial });
  if (error || !payload) throw error ?? new CoreError(500, "could not build the pass");
  if (a && token) {
    const { bytes } = await buildPkpass(buildApplePassJson(payload as WalletPayload, a.identity, token), a.signer);
    return pkpass(bytes, String(issued.serial));
  }
  const saveUrl = await googleSaveLink(payload as WalletPayload, { issuerId: g!.issuerId, origins: g!.origins }, g!.signer, fetch);
  return { data: { save_url: saveUrl, serial: issued.serial } };
}

function pkpass(bytes: Uint8Array, serial: string): Response {
  return new Response(bytes as unknown as BodyInit, {
    status: 200,
    headers: {
      "Content-Type": PKPASS_MIME,
      "Content-Disposition": `attachment; filename="exos-${serial.replace(/[^A-Za-z0-9_-]/g, "")}.pkpass"`,
      "Cache-Control": "no-store",
    },
  });
}
