# app/ — Mobile Customer Scan App

SvelteKit + Capacitor mobile app for iOS/Android. Customers scan their furniture;
volume comes from on-device LiDAR where available, otherwise from the backend
VLM pipeline.

**Capture is volume-first.** What the customer must produce is a *measurement*;
the item's name is optional at every step and may be submitted empty — the
backend names unlabelled items from their photo (`fill_missing_labels` in
`crates/api/src/routes/submissions.rs`). Detection (YOLO) runs **silently** — it
is never drawn, and its only job is to pre-fill the optional name field.

**iOS capture is room-first, not object-first.** The customer sweeps the whole
room once; objects appear in a live list as they are found, and are reviewed,
named, merged/split or deleted afterwards — there is no per-object reticle-and-
measure ritual and no orbit/rotation tracking. See "iOS capture: room-mesh
subtraction" below. Android/web still capture one object at a time as a few
photos, sent for backend estimation.

## Capture architecture (per platform)

| Platform | Flow | Volume |
|----------|------|--------|
| iPhone Pro (LiDAR, `supportsSceneReconstruction(.mesh)`) | Native ARKit session (plugin hides WebView): tap **Erfassung starten** → walk the room while a background pass re-reads the fused scene mesh every 1.5 s and objects appear in a live list with a running item/volume count → **Fertig** freezes the list → results screen: tap a row to see its box drawn in AR with L/B/H, rename, merge two rows, split one, delete, or add a manual entry → **Absenden** | **On-device**: scene mesh with the room subtracted out → connected components → gravity-aligned OBB per island (`RoomScanner` in the Swift plugin). Sent as `device_volume_m3` per item |
| iPhone non-Pro | Same native session, `canMeasure = false`: the sweep button is disabled and the flow goes straight to manual entry per item, with a suggested name from the silent YOLO guess | Manual entry only (client-side, no backend estimation needed) |
| Android / web | In-page guided capture (`/scan` web mode): 3–4 photos from different angles per item, then an optional name in the review sheet. "Maße stattdessen eintragen" opens the same manual sheet | Backend (VLM), or manual entry |

Manual entry (native sheet and web sheet) takes an optional name plus **either**
L × W × H in cm (packing factor applied, same as the measured path) **or** a
volume in m³ taken as given. On iOS a manual entry has no mesh behind it — it
survives room rescans untouched but can't be merged or split. It keeps one photo
so the item can still be named server-side, and lands in the manifest as
`device_volume_m3` like any measurement.

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
| `plugins/capacitor-depth-capture/` | Capacitor plugin. iOS (`ios/Plugin/`): `DepthCapturePlugin.swift` — ARKit session, silent YOLO (CoreML), native overlay UI (intro/sweep/results/manual states, AR box rendering, merge/split/rename/delete); `RoomScanner.swift` — pure room-mesh-subtraction → clustering → OBB-fit logic, run off the main thread. Web impl is a dev stub — Android capture lives in the scan page itself |
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

There is also a GitHub Actions workflow (`.github/workflows/mobile.yml`) with
`web`, `android` and `ios` jobs. As of the current submodule commit, `web` and
`android` are green; `ios` fails on `Import signing certificate` because the
`IOS_CERTIFICATE_PASSWORD` secret is wrong — only whoever owns the repo secrets
can fix that. The room-mesh capture rewrite (`RoomScanner.swift`) has not been
tested on a physical device.

## iOS capture: room-mesh subtraction (`RoomScanner.swift`)

Replaced per-frame region growing in commit `cdebdf0` (2026-09-05). The old flow
had to decide "what is this object" from one depth frame at a time and could
only be told when to *stop* growing — hence a seed, a gate, an object lock, and
an accumulating pile of rules about floors and thin poles; a pedestal fan still
measured as its base disc. `RoomScanner` poses the question the other way round:

- ARKit fuses one scene mesh (`.meshWithClassification`) over the whole sweep.
  Every 1.5 s the plugin re-reads the current mesh anchors on a background queue
  and calls `RoomScanner.objects(from:planeAnchors:)`, which is pure and touches
  nothing session-related.
- Structure faces (wall/floor/ceiling/window/door classification, **not**
  `.table`/`.seat` — those are furniture) are dropped, plus any face within 6 cm
  of a detected wall/floor/ceiling plane or below the lowest horizontal plane —
  two independent rejections, since ARKit's per-face classification is often
  `.none` on a freshly seen surface while plane proximity needs no classifier.
- Surviving vertices are deduplicated onto a 3 cm grid, then clustered at 7 cm
  by 26-neighbour connected components — whatever the subtraction left behind is
  already separated in space, so this just reads off the separation. Each
  cluster ≥30 points and 0.02–15 m³ becomes a `RoomObject`.
- The box is a gravity-aligned OBB: height straight from the Y range (1st–99th
  percentile), footprint from a minimum-area rectangle over the convex hull via
  rotating calipers (not PCA — PCA is density-weighted and drags the orientation
  toward whichever side the customer walked past twice).
- A rescan **adopts** the new object list: it carries a previously-typed label
  across when a new object's box center sits within 25 cm of an old one's, and
  it never touches manual entries (`hasGeometry == false`), which have no mesh
  and would otherwise vanish on the next pass.
- **Merge** (`RoomScanner.merged`) refits a box over both objects' unioned
  points — for a table and the lamp on it, or a sofa whose chaise meshed as its
  own island. **Split** (`RoomScanner.split`) first tries re-clustering the
  object's own points at a finer 4 cm voxel (a fusion is usually two things
  joined by one thin bridge); only if that still yields one island does it fall
  back to cutting across the box's long axis. Both are UI-only — no mesh re-read.
- One frame is attached per object afterwards (`assignRepresentativeFrames`):
  whichever captured photo has the object's box center in front of the camera
  and nearest, so the backend can name it. There is no more per-object frame
  cap or viewing-angle bucketing — `arcDegrees` is always sent as `0` now (both
  iOS and the web capture page) and is dead weight in `ItemScan`/`StoredItem`.
- `canMeasure` gates the sweep button on `supportsSceneReconstruction(.mesh)`;
  without it (LiDAR-less phones) the flow skips straight to manual entry.

## Constraints

- Item names may be empty end to end (plugin → store → manifest → backend). Never add a client-side "name required" check.
- YOLO output is never drawn. If you find yourself adding detection boxes back to the overlay, the answer is a better measurement affordance, not more labels.
- Frames are canvas-compressed client-side (JPEG quality 0.85) before the multipart upload.
- Per-item on-device volumes are validated server-side (0.005–12 m³); one implausible
  item ⇒ the whole submission falls back to server-side estimation.
- German for all user-facing strings. No PII in local storage beyond session token + profile.
- `RoomScanner`'s functions (`objects`, `cluster`, `fit`, `merged`, `split`) take plain point arrays and touch no ARKit session — the only part of the plugin reviewable without a device, since Swift otherwise only compiles in CI.

## Parent context

`app/` is a git submodule (`git@github.com:timefliez1210/aust_app.git`) with its
own history — a change here needs a commit inside this submodule *and* a
submodule-pointer commit in the parent repo (`aust_backend`) to take effect there.

Root: [AGENTS.md](../AGENTS.md)
Backend submissions handler: [crates/api/AGENTS.md](../crates/api/AGENTS.md)
Vision pipeline: [services/vision/AGENTS.md](../services/vision/AGENTS.md)
