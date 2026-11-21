// The rate-limit bucket for a Posh delivery (exos-posh-webhook). A token
// that belongs to a live hook is limited per hook (its hash). A token that
// doesn't is limited per caller NETWORK (IPv4 /24, IPv6 /48, hashed): keying
// unknown tokens by their own hash let anyone create one exos_rate_hits row
// per made-up token, without bound. The network is the platform's address
// header (clientIp: cf-connecting-ip, else x-real-ip, else the last
// X-Forwarded-For hop); with none, unknown tokens share one bucket. Pure, for
// the Deno tests.
import { clientIp } from "../guest.ts";
import { sha256Hex } from "./payload.ts";

/** Known hooks: deliveries a minute per URL. Unknown tokens: tries a minute per caller network. */
export const POSH_PER_MINUTE = 120;
export const POSH_UNKNOWN_PER_MINUTE = 30;

/** The caller's network: IPv4 /24, IPv6 /48, else the value as given ("unknown" when none). */
export function callerNetwork(ip: string): string {
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}$/.exec(ip);
  if (v4) return `${v4[1]}.${v4[2]}.${v4[3]}.0/24`;
  if (ip.includes(":")) {
    const head = ip.toLowerCase().replace(/^\[|\]$/g, "").split("::")[0].split(":").filter(Boolean);
    return `${head.slice(0, 3).map((h) => h.replace(/^0+(?=.)/, "")).join(":")}::/48`;
  }
  return ip || "unknown";
}

/** exos_rate_hit's bucket and limit for this delivery. */
export async function poshRateBucket(
  tokenHash: string, known: boolean, header: (name: string) => string | null,
): Promise<{ bucket: string; limit: number }> {
  if (known) return { bucket: `posh:${tokenHash.slice(0, 40)}`, limit: POSH_PER_MINUTE };
  const net = await sha256Hex(`posh-net:${callerNetwork(clientIp(header))}`);
  return { bucket: `posh-unknown:${net.slice(0, 40)}`, limit: POSH_UNKNOWN_PER_MINUTE };
}
