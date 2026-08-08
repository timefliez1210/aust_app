# app/ — Mobile Customer Scan App

SvelteKit + Capacitor mobile app for iOS/Android. Customers scan their furniture
item-by-item; volume comes from on-device LiDAR where available, otherwise from
the backend VLM pipeline.

**Capture is volume-first.** What the customer must produce is a *measurement*;
the item's name is optional at every step and may be submitted empty — the
backend names unlabelled items from their photo (`fill_missing_labels` in
`crates/api/src/routes/submissions.rs`). Detection (YOLO) runs **silently** — it
is never drawn, and its only job is to pre-fill the optional name field.

**Measurement is guided, not timed.** The native flow shows the customer what it
is measuring (a wireframe box drawn on the object, with L/B/H pinned to the
matching edges), tells them the one thing to do next, and ends by itself once the
box has been seen from enough angles and stopped changing. Progress is *viewing-angle
coverage*, never elapsed rotation. Every screen has a manual escape hatch, because
LiDAR cannot see glass, mirrors or black leather and a stuck customer is worse
than an approximate number.

## Capture architecture (per platform)

| Platform | Flow | Volume |
|----------|------|--------|
| iPhone Pro (LiDAR) | Native ARKit session (plugin hides WebView): object in the reticle → tap **Messen** → guided sweep: live wireframe box + L/B/H tags, one instruction at a time ("langsam nach links um das Objekt gehen"), auto-finishes on coverage + stability → review card: measured volume + optional name → *Sichern* / *Erneut messen*. **Manuell** at any point | **On-device**: depth region-growing → world-space point cloud → gravity-aligned OBB (`VolumeAccumulator` in the Swift plugin). Sent as `device_volume_m3` per item |
| iPhone non-Pro | Same native session; no depth, so the sweep just collects 8 photos around the object and the review card says the backend will estimate | Backend (VLM), or manual entry |
| Android / web | In-page guided capture (`/scan` web mode): 3–4 photos from different angles, then an optional name in the review sheet. "Maße stattdessen eintragen" opens the same manual sheet | Backend (VLM), or manual entry |

Manual entry (native sheet and web sheet) takes an optional name plus **either**
L × W × H in cm (packing factor applied, same as the measured path) **or** a
volume in m³ taken as given. It keeps one photo so the item can still be named
server-side, and lands in the manifest as `device_volume_m3` like any measurement.

```
Capture → /scan/form (contact + addresses + services)
        → POST /api/v1/submit/mobile/ar   (multipart: images, depth_maps,
              item_manifest [optional labels, frame counts, device volumes], poses, intrinsics)
        → backend (crates/api/src/routes/submissions.rs):
              all items have device_volume_m3 → method "ar_device", no server vision
                  unnamed items → VLM naming-only pass over their representative
                  frame (VlmEstimator::label_objects), fallback "Möbelstück"
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
| `plugins/capacitor-depth-capture/` | Capacitor plugin. iOS: ARKit + silent YOLO (CoreML) + native overlay UI (reticle, measure button, guided-sweep HUD, AR wireframe box, review card, manual sheet) + `VolumeAccumulator` (on-device m³). Web impl is a dev stub — Android capture lives in the scan page itself |
| `src/lib/api/client.ts` | Fetch wrapper (Bearer token, FormData, blob download, German errors) |
| `src/lib/stores/capture.svelte.ts` | Scanned items incl. `volumeM3`/`dimsM` and a possibly empty `label`; `deviceVolumeM3` total |
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

- The native sweep captures a frame per **new 15° viewing-angle bucket** (≤16/item), not per render tick. Depth is fused every frame; only the JPEG encode is gated.
- The OBB is re-fit on a background queue ~4×/s and the cloud is capped at 40k points. `VolumeAccumulator` is lock-guarded: ingest runs on the render thread, `measure()` must not.
- Completion is coverage + stability (≥5 buckets, ≥6 frames, last 4 volumes within 10%) — never a degree count. "Übernehmen" lets the customer take a partial measurement.
- Orbit direction is resolved by projecting the target standpoint through `camera.viewMatrix(for: .portrait)` and reading the sign of x. Do not derive it from quaternion axes — that arrow comes out mirrored.
- Depth segmentation seeds from the **frame centre** — the reticle is load-bearing UI, not decoration.
- Item names may be empty end to end (plugin → store → manifest → backend). Never add a client-side "name required" check.
- YOLO output is never drawn. If you find yourself adding detection boxes back to the overlay, the answer is a better measurement affordance, not more labels.
- Frames are canvas-compressed client-side before the multipart upload (~100 KB each).
- Per-item on-device volumes are validated server-side (0.005–12 m³); one implausible
  item ⇒ the whole submission falls back to server-side estimation.
- German for all user-facing strings. No PII in local storage beyond session token + profile.

## Parent context

Root: [AGENTS.md](../AGENTS.md)
Backend submissions handler: [crates/api/AGENTS.md](../crates/api/AGENTS.md)
Vision pipeline: [services/vision/AGENTS.md](../services/vision/AGENTS.md)
