# Native sharing (for the Exos app)

How fans and promoters will share events to Instagram and Facebook Stories from the Exos app,
and how the app plugs into the web code that's already built. The web half is live. The app
half is a spec for whoever builds the iOS and Android shells.

## Why the app needs to do this

Meta only lets **native apps** hand an image to the Stories composer:
- Android uses the `com.instagram.share.ADD_TO_STORY` intent.
- iOS uses `instagram-stories://share` plus the pasteboard.

A website can't do either, and since January 2023 both need our **Facebook App ID**. Without
it, users see "The app you shared from doesn't currently support sharing to Stories".

On the web, `src/lib/poster.ts` does the next best thing today:
- It builds a 1080×1920 poster.
- It opens the phone's share sheet, where Instagram appears.
- It falls back to downloading the poster and opening `https://www.instagram.com/create/story`.

## Who shares, and what the link carries

`src/lib/shareLinks.ts` builds every shared link.

| Sharer | Where | Link carries |
|---|---|---|
| **Fan** ("I'm going") | ticket page, event page | `utm_source=<platform>`, `utm_medium=fan_share`, plus the promoter code they arrived with, if any, so the promoter who brought them is credited for the friends they bring |
| **Promoter** | Promote page → Promoter kit; public kit page `/promoter/:eventId/:code` | `promoter=<code>`, `utm_source=<platform>`, `utm_medium` (story / bio / social / messaging), `utm_campaign` |

**Promoters also get a buy-now link:** `/checkout?event=…&products=<tierId>:<qty>,<addonId>:<qty>&coupon=…&promoter=…`
(`src/lib/checkoutLink.ts`).
- It opens the event with the cart already filled in.
- The `products` and `coupon` format is Meta's Shops checkout-URL contract, so the same page can
  later be a Facebook or Instagram Shop's checkout URL.

**How the code reaches the Sales report:**
- It survives sign-in (`src/lib/attribution.ts` keeps it for the visit).
- It rides into `exos-checkout`, which stores it on the checkout session (mig `20260924223000`).
- Fulfillment stamps it on every ticket, so paid sales land in the per-promoter Sales report the
  same way free claims do.

## The bridge contract (version 1)

When the app wraps the SPA in a webview, it injects `window.ExosNative` before the page loads.
The types are in `src/lib/nativeShare.ts`:

```ts
window.ExosNative = {
  version: 1,
  canShare(target: 'instagram_story' | 'facebook_story' | 'instagram_feed'): Promise<boolean>,
  share(payload: {
    target: 'instagram_story' | 'facebook_story' | 'instagram_feed';
    backgroundImage?: string;       // data:image/png|jpeg;base64,…  9:16, ≥ 720×1280
    stickerImage?: string;          // data:image/png|jpeg;base64,…  ~640×480
    backgroundTopColor?: string;    // #RRGGBB, used when there's no background image
    backgroundBottomColor?: string; // #RRGGBB
    contentUrl: string;             // the attributed https link
  }): Promise<'shared' | 'cancelled' | 'unavailable'>,
};
```

**How the SPA uses the bridge:**
- It calls `canShare`, validates the payload (`validateNativePayload`), then calls `share`.
- `'unavailable'`, a thrown error, or a missing or other-version bridge all make it fall back
  to the web path.
- `'cancelled'` does nothing.

**The app must:**
1. **Hold the Facebook App ID.** It's native config, never sent from the web.
2. **Put `contentUrl` on the clipboard** before opening Instagram. Meta's API has no link field;
   the user adds a link sticker and pastes.
3. **Hand the images over**, decoded from the data URLs:
   - **Android:** write each image to the app's cache and expose it through a `FileProvider`
     content URI. For a background, build `Intent("com.instagram.share.ADD_TO_STORY")` with
     `setDataAndType(uri, "image/png")` and `putExtra("source_application", FB_APP_ID)`. A
     sticker goes in `putExtra("interactive_asset_uri", uri)`, and the colors in
     `top_background_color` / `bottom_background_color`.
     - Call `grantUriPermission("com.instagram.android", uri, FLAG_GRANT_READ_URI_PERMISSION)`.
     - Check `resolveActivity` before `startActivityForResult`.
     - Facebook Stories has its own intent and extras; follow Meta's Facebook "Sharing to
       Stories" doc rather than reusing the Instagram ones.
   - **iOS:** add `instagram-stories` (and `facebook-stories`) to `LSApplicationQueriesSchemes`.
     Set pasteboard items `com.instagram.sharedSticker.backgroundImage` / `.stickerImage` /
     `.backgroundTopColor` / `.backgroundBottomColor`, with a 5-minute
     `UIPasteboardOptionExpirationDate`. Then open
     `instagram-stories://share?source_application=FB_APP_ID`. Check `canOpenURL` first and return
     `'unavailable'` if it's false.
   - **Feed** (`instagram_feed`): Android sends `ACTION_SEND` with `EXTRA_STREAM`; iOS uses
     `UIDocumentInteractionController` with the `com.instagram.exclusivegram` UTI (`.igo`).
     Instagram prefers a JPEG, and the web sends a 1080×1920 PNG, so crop or letterbox it
     natively.
4. **Return** `'shared'` once Instagram opened, `'cancelled'` if the user backed out, and
   `'unavailable'` if the target app isn't installed.

**Limits to respect:**
- **Background:** at least 720×1280, 9:16 or 9:18.
- **Video backgrounds:** up to 20 s and 1080p, under 50 MB (not used yet).
- **Sticker:** about 640×480.
- The SPA refuses data URLs over about 12 MB.

## Open items

- **A Meta app and its App ID** (operator). Needed before any native Stories share works.
- **A sticker layer.** The SPA only sends the poster as the background today. A 640×480 event
  sticker over the org's brand colors would let users move and resize it.
- **Shop checkout.** Registering `/checkout` as a Facebook or Instagram Shop's checkout URL needs
  two things first:
  - a catalog of our tiers;
  - a check that Meta's commerce policies allow event tickets.

  A catalog pushed through Meta's write APIs counts as a third-party inventory write under the
  read-only rule (`CLAUDE.md`), so it needs operator sign-off. A pull feed that Meta fetches from
  us doesn't.
