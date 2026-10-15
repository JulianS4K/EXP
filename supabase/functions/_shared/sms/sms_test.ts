import { assertEquals } from "jsr:@std/assert@1";
import { safeEqual, sendSms, telnyxInbound, telnyxVerified, twilioSignature } from "./providers.ts";

Deno.test("Twilio signature matches Twilio's documented example", async () => {
  // https://www.twilio.com/docs/usage/security#validating-requests
  const sig = await twilioSignature("https://mycompany.com/myapp.php?foo=1&bar=2", {
    CallSid: "CA1234567890ABCDE", Caller: "+12349013030", Digits: "1234", From: "+12349013030", To: "+18005551212",
  }, "12345");
  assertEquals(sig, "0/KCTR6DLpKmkAf8muzZqo1nDgQ=");
  assertEquals(safeEqual(sig, "0/KCTR6DLpKmkAf8muzZqo1nDgQ="), true);
  assertEquals(safeEqual(sig, "x"), false);
});

Deno.test("Telnyx Ed25519 verification", async () => {
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  const pub = btoa(String.fromCharCode(...raw));
  const ts = String(Math.floor(Date.now() / 1000));
  const body = JSON.stringify({ data: { event_type: "message.received", payload: { from: { phone_number: "+12125550101" }, text: "STOP" } } });
  const sig = new Uint8Array(await crypto.subtle.sign("Ed25519", kp.privateKey, new TextEncoder().encode(`${ts}|${body}`)));
  const s64 = btoa(String.fromCharCode(...sig));
  assertEquals(await telnyxVerified(body, s64, ts, pub), true);
  assertEquals(await telnyxVerified(body + " ", s64, ts, pub), false);
  assertEquals(await telnyxVerified(body, s64, String(Number(ts) - 3600), pub), false);
  assertEquals(telnyxInbound(JSON.parse(body)), { from: "+12125550101", text: "STOP" });
  assertEquals(telnyxInbound({ data: { event_type: "message.sent" } }), null);
});

Deno.test("send: Twilio form post with the org's sender; bad input never calls out", async () => {
  const calls: { url: string; init?: RequestInit }[] = [];
  const f = ((url: string, init?: RequestInit) => {
    calls.push({ url, init });
    return Promise.resolve(new Response(JSON.stringify({ sid: "SM1" }), { status: 201 }));
  }) as typeof fetch;
  const tw = { provider: "twilio" as const, config: { account_sid: "AC" + "a".repeat(32), from: "+12125550199" }, secret: "tok" };
  assertEquals(await sendSms(f, tw, "+12125550101", "Hi Reply STOP"), { ok: true, id: "SM1" });
  assertEquals(String(calls[0].init?.body).includes("From=%2B12125550199"), true);
  assertEquals((await sendSms(f, tw, "212", "x")).ok, false);
  assertEquals((await sendSms(f, { ...tw, config: { account_sid: "nope" } }, "+12125550101", "x")).ok, false);
  assertEquals(calls.length, 1);
  const busy = (() => Promise.resolve(new Response("{}", { status: 429 }))) as unknown as typeof fetch;
  const r = await sendSms(busy, tw, "+12125550101", "x");
  assertEquals(r.ok === false && r.retry, true);
});
