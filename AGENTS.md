# app/ — Mobile Customer Scan App

SvelteKit + Capacitor mobile app for iOS/Android. Customers scan their furniture
item-by-item; volume comes from on-device LiDAR where available, otherwise from
the backend VLM pipeline.

## Capture architecture (per platform)

| Platform | Flow | Volume |
|----------|------|--------|
| iPhone Pro (LiDAR) | Native ARKit session (plugin hides WebView): YOLO live detection → tap to confirm (or draw box + name manually) → 28° arc sweep captures ~8 frames + depth maps | **On-device**: depth region-growing → world-space point cloud → gravity-aligned OBB (`VolumeAccumulator` in the Swift plugin). Sent as `device_volume_m3` per item |
| iPhone non-Pro | Same native ARKit flow, no depth maps | Backend (VLM) |
| Android / web | In-page guided capture (`/scan` web mode): label each item, 3–4 photos from different angles | Backend (VLM) |

```
Capture → /scan/form (contact + addresses + services)
        → POST /api/v1/submit/mobile/ar   (multipart: images, depth_maps,
              item_manifest [labels, frame counts, device volumes], poses, intrinsics)
        → backend (crates/api/src/routes/submissions.rs):
              all items have device_volume_m3 → method "ar_device", no server vision
              else vision_service.backend = "vlm" → catalogue-grounded VLM (1 frame/item)
              else → legacy Modal GPU pipeline
        → estimated → auto-offer → Telegram approval → offer_sent
        → /scan/processing polls /api/v1/customer/inquiries/{id}
```

## Routes (`src/routes/`)

| Route | Purpose |
|-------|---------|
| `/` | Home — hero scan CTA, latest inquiry status, offers shortcut, prep tips |
| `/scan` | Capture: native ARKit session (iOS) or in-page camera flow (Android/web) |
| `/scan/form` | Inquiry form — item summary w/ device volumes, contact, addresses, services |
| `/scan/processing` | Polls inquiry status until offer_ready / failure / timeout |
| `/scan/resume` | Continue an interrupted capture session |
| `/auth` | Email OTP login (`/api/v1/customer/auth/request` + `/verify`) |
| `/offers`, `/offers/[id]` | Offer list / detail with accept, reject, PDF download |
| `/tutorial` | First-run onboarding slides |

## Key files

| File/dir | Purpose |
|----------|---------|
| `plugins/capacitor-depth-capture/` | Capacitor plugin. iOS: ARKit + YOLO (CoreML) + native overlay UI + `VolumeAccumulator` (on-device m³). Web impl is a dev stub — Android capture lives in the scan page itself |
| `src/lib/api/client.ts` | Fetch wrapper (Bearer token, FormData, blob download, German errors) |
| `src/lib/stores/capture.svelte.ts` | Scanned items incl. `volumeM3`/`dimsM`; `deviceVolumeM3` total |
| `src/lib/stores/auth.svelte.ts` | OTP auth session (localStorage) |
| `src/lib/components/` | `NavBar` (iOS nav bar), `BottomNav` (iOS tab bar) |
| `src/lib/haptics.ts` | Capacitor haptics helpers (no-op on web) |
| `src/app.css` | iOS design system: CSS vars (light/dark), `.ios-card`, `.ios-row`, `.btn-filled`, `.ios-switch`, … |
| `codemagic.yaml` | CI: exports `yolo11n.pt` → CoreML, injects Android CAMERA permission, TestFlight/APK |

## Design language

Native-iOS look: system font stack (SF on device), grouped-inset cards with
hairline separators, blurred nav/tab bars, iOS switches, dark mode via
`prefers-color-scheme`. Icons are `lucide-svelte` (no icon font, no network
fonts). Brand: navy `#022448` (tint), orange `#fc6018` (accent).

## Build & deploy

```bash
npm run build && npm run check      # web build + typecheck
cd plugins/capacitor-depth-capture && npx tsc   # plugin build
npx cap add ios && npx cap sync     # native projects are generated, not committed
```

CI (Codemagic) builds both platforms; the iOS workflow exports the YOLO CoreML
model (`yolo11n`) and wires it into the Xcode project. Swift changes compile in
CI only — there is no local Xcode on the dev machine.

## Constraints

- Native iOS scan captures a frame every ~3.5° of sweep (~8 frames/item), not every render tick.
- Frames are canvas-compressed client-side before the multipart upload (~100 KB each).
- Per-item on-device volumes are validated server-side (0.005–12 m³); one implausible
  item ⇒ the whole submission falls back to server-side estimation.
- German for all user-facing strings. No PII in local storage beyond session token + profile.

## Parent context

Root: [AGENTS.md](../AGENTS.md)
Backend submissions handler: [crates/api/AGENTS.md](../crates/api/AGENTS.md)
Vision pipeline: [services/vision/AGENTS.md](../services/vision/AGENTS.md)
