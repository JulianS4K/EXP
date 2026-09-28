// exos-wallet — Apple Wallet and Google Wallet ticket passes (docs/wallet.md).
//
// Owner routes (the holder's Supabase JWT, checked in code with auth.getUser;
// ownership is checked again in SQL by exos_wallet_issue_pass):
//   POST /exos-wallet/pass     { ticket_id, kind: "apple" }  -> .pkpass bytes
//   POST /exos-wallet/pass     { ticket_id, kind: "google" } -> { save_url }
//   POST /exos-wallet/reissue  { ticket_id }                  -> new door code,
//        the old one stops working (e.g. a screenshot of the pass got around)
// Apple PassKit web service (webServiceURL = <function URL>/apple): register /
//   unregister a device, list updated serials, fetch the latest pass, log.
//   Authorization: "ApplePass <authenticationToken>", checked against the
//   SHA-256 hash in exos_wallet_passes.
// Cron (x-cron-secret): POST /exos-wallet/push — sends Apple update pushes and
//   re-stores Google objects for passes the database marked push-pending
//   (a void, transfer, check-in or reissue). Dry run unless configured.
//
// Deploy with --no-verify-jwt: Apple's devices call the web service with no
// Supabase JWT, so the gateway check must be off; every route authenticates
// itself (JWT / ApplePass token / cron secret).
//
// Env (never logged): SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY,
// CRON_SECRET; Apple: EXOS_WALLET_APPLE_PASS_TYPE_ID, EXOS_WALLET_APPLE_TEAM_ID,
// EXOS_WALLET_APPLE_CERT, EXOS_WALLET_APPLE_PRIVATE_KEY,
// EXOS_WALLET_APPLE_WWDR_CERT, optional EXOS_WALLET_APPLE_PUSH=live,
// EXOS_WALLET_PUBLIC_URL; Google: EXOS_WALLET_GOOGLE_ISSUER_ID,
// EXOS_WALLET_GOOGLE_SERVICE_ACCOUNT_KEY, optional EXOS_WALLET_GOOGLE_ORIGINS.
// Missing Apple / Google settings -> that wallet answers 503 "wallet not
// configured"; nothing is ever signed with made-up keys.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { reportError } from "../_shared/log.ts";
import { type AppleIdentity, buildApplePassJson, buildPkpass, PKPASS_MIME } from "../_shared/wallet/apple.ts";
import { apnsPusher, dryRunPusher, type PassPusher } from "../_shared/wallet/apns.ts";
import { hashAuthToken, newAuthToken, parseApplePassAuth } from "../_shared/wallet/codes.ts";
import {
  buildEventTicketObject,
  createRs256Signer,
  googleAccessToken,
  googleSaveLink,
  type Rs256Signer,
  upsertResource,
} from "../_shared/wallet/google.ts";
import type { WalletPayload } from "../_shared/wallet/payload.ts";
import { createPkcs7Signer, type PassSigner } from "../_shared/wallet/pkcs7.ts";
import { httpDate, notModified, routeWallet } from "../_shared/wallet/routes.ts";

const FN = "exos-wallet";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const env = (k: string): string | undefined => {
  const v = Deno.env.get(k);
  return v && v.trim() ? v : undefined;
};

// ── Configuration (cached per isolate; a setup failure logs no material) ───

interface AppleSetup {
  identity: AppleIdentity;
  signer: PassSigner;
  pusher: PassPusher;
}
interface GoogleSetup {
  issuerId: string;
  origins: string[];
  signer: Rs256Signer;
}

let appleSetup: Promise<AppleSetup | null> | null = null;
let googleSetup: Promise<GoogleSetup | null> | null = null;

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
      const base = (env("EXOS_WALLET_PUBLIC_URL") ?? `${env("SUPABASE_URL") ?? ""}/functions/v1/${FN}`).replace(/\/+$/, "");
      if (!base.startsWith("https://")) {
        console.error(`${FN}: apple web service URL must be https; wallet disabled`);
        return null;
      }
      return {
        identity: { passTypeIdentifier, teamIdentifier, webServiceURL: `${base}/apple` },
        signer,
        pusher: makeApnsPusher(certPem, keyPem),
      };
    } catch (e) {
      // WalletKeyError messages are fixed strings; nothing from the PEMs.
      console.error(`${FN}: apple signing setup failed (${e instanceof Error ? e.message : "error"}); wallet disabled`);
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
      console.error(`${FN}: google signing setup failed (${e instanceof Error ? e.message : "error"}); wallet disabled`);
      return null;
    }
  })();
  return googleSetup;
}

/**
 * APNs needs the Pass Type ID certificate as a TLS client certificate. Live
 * only when the operator asks (EXOS_WALLET_APPLE_PUSH=live) AND the runtime
 * can make such a client (Deno.createHttpClient with cert/key); otherwise a
 * dry run that leaves the passes push-pending.
 */
function makeApnsPusher(certPem: string, keyPem: string): PassPusher {
  if (env("EXOS_WALLET_APPLE_PUSH") !== "live") return dryRunPusher;
  // deno-lint-ignore no-explicit-any
  const create = (Deno as any).createHttpClient as ((o: Record<string, unknown>) => unknown) | undefined;
  if (typeof create !== "function") {
    console.error(`${FN}: runtime has no Deno.createHttpClient; apple pushes stay a dry run`);
    return dryRunPusher;
  }
  try {
    const client = create({ cert: certPem, key: keyPem, http2: true, http1: false });
    return apnsPusher((url, init) => fetch(url, { ...(init ?? {}), client } as RequestInit));
  } catch {
    console.error(`${FN}: could not create the APNs client; apple pushes stay a dry run`);
    return dryRunPusher;
  }
}

// ── HTTP helpers ─────────────────────────────────────────────────────────

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS, ...extra } });
}
const empty = (status: number, extra: Record<string, string> = {}) => new Response(null, { status, headers: extra });
const notConfigured = () => json({ error: "wallet not configured" }, 503);

function service(): SupabaseClient {
  return createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
}

async function pkpassResponse(p: WalletPayload, a: AppleSetup, token: string, extra: Record<string, string> = {}): Promise<Response> {
  const passJson = buildApplePassJson(p, a.identity, token);
  const { bytes } = await buildPkpass(passJson, a.signer);
  return new Response(bytes as unknown as BodyInit, {
    status: 200,
    headers: {
      "Content-Type": PKPASS_MIME,
      "Content-Disposition": `attachment; filename="exos-${p.serial}.pkpass"`,
      "Last-Modified": httpDate(p.updated_at),
      "Cache-Control": "no-store",
      ...CORS,
      ...extra,
    },
  });
}

// ── Owner: get a pass ────────────────────────────────────────────────────

async function issue(req: Request): Promise<Response> {
  // deno-lint-ignore no-explicit-any
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  const ticketId = typeof body?.ticket_id === "string" ? body.ticket_id : "";
  const kind = body?.kind;
  if (!UUID_RE.test(ticketId)) return json({ error: "ticket_id required" }, 400);
  if (kind !== "apple" && kind !== "google") return json({ error: "kind must be apple or google" }, 400);

  const a = kind === "apple" ? await apple() : null;
  const g = kind === "google" ? await google() : null;
  if (!a && !g) return notConfigured();

  const sbUser = userClient(req);
  const { data: { user } } = await sbUser.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  const token = a ? newAuthToken() : null;
  const { data: issued, error } = await sbUser.rpc("exos_wallet_issue_pass", {
    p_ticket_id: ticketId,
    p_kind: kind,
    p_token_hash: token ? await hashAuthToken(token) : null,
    p_pass_type: a ? a.identity.passTypeIdentifier : null,
  });
  if (error) {
    if (error.code === "42501") return json({ error: "not your ticket" }, 403);
    await reportError(FN, error, { phase: "issue" });
    return json({ error: "could not issue the pass" }, 500);
  }
  if (!issued?.ok) return json({ error: issued?.reason ?? "not-available" }, 409);

  const { data: payload, error: pErr } = await service().rpc("exos_wallet_pass_payload", { p_serial: issued.serial });
  if (pErr || !payload) {
    await reportError(FN, pErr ?? new Error("no payload"), { phase: "payload" });
    return json({ error: "could not build the pass" }, 500);
  }

  try {
    if (a && token) return await pkpassResponse(payload as WalletPayload, a, token);
    const saveUrl = await googleSaveLink(payload as WalletPayload, { issuerId: g!.issuerId, origins: g!.origins }, g!.signer, fetch);
    return json({ save_url: saveUrl, serial: issued.serial });
  } catch (e) {
    await reportError(FN, e, { phase: `build-${kind}` });
    return json({ error: "could not build the pass" }, 502);
  }
}

async function reissue(req: Request): Promise<Response> {
  // deno-lint-ignore no-explicit-any
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  const ticketId = typeof body?.ticket_id === "string" ? body.ticket_id : "";
  if (!UUID_RE.test(ticketId)) return json({ error: "ticket_id required" }, 400);
  const sbUser = userClient(req);
  const { data: { user } } = await sbUser.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);
  const { data, error } = await sbUser.rpc("exos_wallet_reissue", { p_ticket_id: ticketId });
  if (error) {
    if (error.code === "42501") return json({ error: "not your ticket" }, 403);
    await reportError(FN, error, { phase: "reissue" });
    return json({ error: "could not reissue" }, 500);
  }
  return json(data, data?.ok ? 200 : 409);
}

function userClient(req: Request): SupabaseClient {
  return createClient(env("SUPABASE_URL")!, env("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    auth: { persistSession: false },
  });
}

// ── Cron: deliver pending updates ────────────────────────────────────────

interface Queued {
  serial: string;
  pass_type: string | null;
  status: string;
  google: boolean;
  push_tokens: string[];
}

async function push(req: Request): Promise<Response> {
  const denied = requireCronSecret(req);
  if (denied) return denied;
  const a = await apple();
  const g = await google();
  if (!a && !g) return notConfigured();
  const sb = service();
  const { data: q, error } = await sb.rpc("exos_wallet_push_queue", { p_limit: 100 });
  if (error) {
    await reportError(FN, error, { phase: "push-queue" });
    return json({ error: "queue read failed" }, 500);
  }
  const passes: Queued[] = q?.passes ?? [];
  const done: string[] = [];
  const gone: string[] = [];
  let planned = 0, sent = 0, failed = 0, googleUpdated = 0;
  let gToken: string | null = null;

  for (const p of passes) {
    let delivered = true;
    if (p.push_tokens.length) {
      if (!a || !a.pusher.live || !p.pass_type) {
        planned += p.push_tokens.length;
        delivered = false;
      } else {
        const r = await a.pusher.push(p.pass_type, p.push_tokens);
        sent += r.sent;
        failed += r.failed;
        gone.push(...r.unregistered);
        if (r.failed) delivered = false;
      }
    }
    if (p.google) {
      if (!g) delivered = false;
      else {
        try {
          const { data: payload } = await sb.rpc("exos_wallet_pass_payload", { p_serial: p.serial });
          if (!payload) throw new Error("no payload");
          gToken ??= await googleAccessToken(g.signer, fetch);
          await upsertResource(fetch, gToken, "eventTicketObject", buildEventTicketObject(payload as WalletPayload, g.issuerId));
          googleUpdated++;
        } catch (e) {
          delivered = false;
          await reportError(FN, e, { phase: "push-google" });
        }
      }
    }
    if (delivered) done.push(p.serial);
  }
  if (gone.length) await sb.rpc("exos_wallet_drop_push_tokens", { p_tokens: gone });
  if (done.length) await sb.rpc("exos_wallet_push_done", { p_serials: done, p_queued_at: q.queued_at });
  return json({
    passes: passes.length,
    apple: { live: !!a?.pusher.live, sent, failed, planned_not_sent: planned, unregistered: gone.length },
    google: { updated: googleUpdated },
    cleared: done.length,
  });
}

// ── Apple PassKit web service ────────────────────────────────────────────

Deno.serve(async (req: Request): Promise<Response> => {
  const url = new URL(req.url);
  const route = routeWallet(req.method, url.pathname);
  try {
    switch (route.kind) {
      case "options":
        return new Response(null, { status: 204, headers: CORS });
      case "issue":
        return await issue(req);
      case "reissue":
        return await reissue(req);
      case "push":
        return await push(req);
      case "not-found":
        return json({ error: "not found" }, 404);
    }

    // Everything below is the Apple web service.
    const a = await apple();
    if (!a) return notConfigured();
    const sb = service();

    if (route.kind === "log") {
      // Device-side errors. Log a bounded summary, never request headers.
      try {
        const body = await req.json();
        const logs: unknown[] = Array.isArray(body?.logs) ? body.logs.slice(0, 10) : [];
        for (const l of logs) console.log(`${FN}: device log: ${String(l).slice(0, 300)}`);
      } catch { /* ignore malformed logs */ }
      return empty(200);
    }

    if (route.kind === "serials") {
      const { data, error } = await sb.rpc("exos_wallet_updated_serials", {
        p_device: route.device,
        p_pass_type: route.passType,
        p_since: url.searchParams.get("passesUpdatedSince"),
      });
      if (error) throw error;
      const serials: string[] = data?.serials ?? [];
      if (!serials.length) return empty(204);
      return json({ serialNumbers: serials, lastUpdated: data.last_updated });
    }

    const token = parseApplePassAuth(req.headers.get("Authorization"));
    if (!token) return empty(401);

    if (route.kind === "register") {
      let pushToken = "";
      try {
        const body = await req.json();
        pushToken = typeof body?.pushToken === "string" ? body.pushToken : "";
      } catch { /* handled below */ }
      if (!pushToken) return empty(400);
      const { data, error } = await sb.rpc("exos_wallet_register_device", {
        p_device: route.device, p_pass_type: route.passType, p_serial: route.serial,
        p_token: token, p_push_token: pushToken,
      });
      if (error) throw error;
      return empty(data === "created" ? 201 : data === "exists" ? 200 : data === "invalid" ? 400 : 401);
    }

    if (route.kind === "unregister") {
      const { data, error } = await sb.rpc("exos_wallet_unregister_device", {
        p_device: route.device, p_pass_type: route.passType, p_serial: route.serial, p_token: token,
      });
      if (error) throw error;
      return empty(data === "deleted" ? 200 : 401);
    }

    // route.kind === "latest"
    const { data: payload, error } = await sb.rpc("exos_wallet_fetch_pass", {
      p_pass_type: route.passType, p_serial: route.serial, p_token: token,
    });
    if (error) throw error;
    if (!payload) return empty(401);
    const p = payload as WalletPayload;
    if (notModified(p.updated_at, req.headers.get("If-Modified-Since"))) return empty(304);
    // Same token: the device keeps authenticating with the one it holds.
    return await pkpassResponse(p, a, token);
  } catch (e) {
    await reportError(FN, e, { route: route.kind });
    return json({ error: "internal error" }, 500);
  }
});
