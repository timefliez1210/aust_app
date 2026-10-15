# app/ — Mobile Customer Scan App

SvelteKit + Capacitor mobile app for iOS/Android. Customers capture their
furniture, fill in the move details, and get an offer.

**Capture is room by room, and the measuring is Apple's.** On LiDAR iPhones each
room is scanned with Apple RoomPlan, which returns every piece of furniture with
a box fitted to the scanned geometry (a measurement, not a per-category lookup).
On every other device the customer enters items by hand: dimensions, a volume,
or just a photo. Both paths end on the same review screen. Item names are
optional throughout; the backend names unlabelled items from their photo.

The previous capture (our own ARKit room-mesh subtraction in
`capacitor-depth-capture`, silent YOLO, a per-object photo flow, `/scan/resume`)
was deleted on 2026-10-15: both its UX and its boxes were poor. It lives in git
history up to `5eb4218`. Don't rebuild a custom mesh pipeline; if RoomPlan's
boxes turn out wrong for some category, correct them in `roomplan.ts`.

## Capture (`/scan`)

| Device | Adding a room | Item volume |
|--------|---------------|-------------|
| iPhone with LiDAR, iOS 16+ (`RoomCaptureSession.isSupported`) | "Raum scannen" → Apple's `RoomCaptureView` full-screen (plugin adds Abbrechen / Fertig / Übernehmen) → movable objects land in the room | RoomPlan box L×B×H × 1.2 packing factor. Manual items here **must** have dimensions or m³ (see Constraints) |
| Everything else (non-Pro iPhone, Android, web) | Name the room → add items by hand | Typed L×B×H × 1.2, a typed m³ as given, or photo only → backend VLM estimates |

- One review screen for both: room cards with their items (tap to edit, rename,
  change size, add a photo, delete), "+ Gegenstand", "Scannen / Erneut scannen"
  per room, then Umzugskartons and the running total, then "Weiter" to `/scan/form`.
- **Rescanning a room replaces its scanned items and keeps manual ones** (`source: 'scan' | 'manual'`).
- **Umzugskartons**: one count for the whole home, sent as a single item
  `"<n> Umzugskartons"`, 0.1 m³ each, capped at 120 (12 m³ backend item limit).
- Fixtures RoomPlan finds (sink, toilet, bathtub, fireplace, stairs) are dropped.
  Other categories get a German name (`CATEGORY_LABELS` in `src/lib/plugins/roomplan.ts`).
- Items outside 0.005–12 m³, or with neither size nor photo, are marked "Prüfen"
  and block "Weiter": the backend would otherwise reject the device volumes.
- Capture state is in memory only (`capture` store); it survives navigation, not an app kill.
- Browser dev: `localStorage.setItem('roomplan-demo', '1')` makes the web
  plugin pretend to support scanning and return a fixed living room.

## Submission contract (unchanged by the rebuild)

```
capture store → /scan/form (contact + addresses + services)
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
| `/scan` | Capture: rooms → items (RoomPlan scan or manual), moving boxes, total |
| `/scan/form` | Inquiry form — item summary w/ device volumes, contact, addresses, services |
| `/scan/processing` | Polls inquiry status until offer_ready / failure / timeout |
| `/auth` | Email OTP login (`/api/v1/customer/auth/request` + `/verify`) |
| `/offers`, `/offers/[id]` | Offer list / detail with accept, reject, PDF download |
| `/tutorial` | First-run onboarding slides |

## Key files

| File/dir | Purpose |
|----------|---------|
| `plugins/capacitor-roomplan/` | Capacitor plugin, iOS only (`ios/Plugin/RoomPlanPlugin.swift`): `isSupported`, `scanRoom({roomName})` → `{cancelled, objects: [{category, dimsM, confidence}]}`. Web impl = demo stub; no Android dir (Android never calls it). `dist/` is committed |
| `src/lib/plugins/roomplan.ts` | Plugin registration, category → German name, fixture filter, packing factor, box volume, backend volume limits |
| `src/lib/components/ItemSheet.svelte`, `Sheet.svelte` | Item add/edit bottom sheet; generic bottom sheet |
| `scripts/ios-deployment-target.sh` | Raises the generated iOS project to 16.0 — run between `cap add ios` and `cap sync ios` |
| `src/lib/api/client.ts` | Fetch wrapper (Bearer token, FormData, blob download, German errors) |
| `src/lib/stores/capture.svelte.ts` | Rooms → items (`volumeM3`/`dimsM`, possibly empty `label`, `source`), `boxes`; `items` flattens everything for the form |
| `src/lib/stores/auth.svelte.ts` | OTP auth session (localStorage) |
| `src/lib/components/` | `NavBar` (iOS nav bar), `BottomNav` (iOS tab bar) |
| `src/lib/haptics.ts` | Capacitor haptics helpers (no-op on web) |
| `src/app.css` | iOS design system: CSS vars (light/dark), `.ios-card`, `.ios-row`, `.btn-filled`, `.ios-switch`, … |
| `codemagic.yaml` | CI: injects Android CAMERA permission, TestFlight/APK |

## Design language

Native-iOS look: system font stack (SF on device), grouped-inset cards with
hairline separators, blurred nav/tab bars, iOS switches, dark mode via
`prefers-color-scheme`. Icons are `lucide-svelte` (no icon font, no network
fonts). Brand: navy `#022448` (tint), orange `#fc6018` (accent).

## Build & deploy

```bash
npm run build && npm run check      # web build + typecheck
cd plugins/capacitor-roomplan && npx tsc   # plugin JS build (dist/ is committed)
npx cap add ios && ./scripts/ios-deployment-target.sh && npx cap sync   # native projects are generated, not committed
```

CI (Codemagic) builds both platforms. Swift changes compile in CI only — there
is no local Xcode on the dev machine. **Minimum iOS is 16** (RoomPlan): Capacitor
generates the app at 15 and derives `CapApp-SPM/Package.swift` from the Xcode
project, so both CI paths run `scripts/ios-deployment-target.sh` before
`cap sync ios`; without it the 16.0 plugin package fails the build.
RoomPlan capture has not yet been tried on a physical device.

There is also a GitHub Actions workflow (`.github/workflows/mobile.yml`) with
`web`, `android` and `ios` jobs. As of the current submodule commit, `web` and
`android` are green; `ios` fails on `Import signing certificate` because the
`IOS_CERTIFICATE_PASSWORD` secret is wrong — only whoever owns the repo secrets
can fix that.

## Constraints

- Item names may be empty end to end (capture → store → manifest → backend). Never add a client-side "name required" check.
- On LiDAR devices every item needs a volume. One item without `device_volume_m3` sends the *whole* submission to server-side photo estimation and discards every scanned measurement (backend: all-or-nothing `device_volume_items`).
- Photos are downscaled to 1600 px when picked and compressed again (800 px, JPEG 0.75) in `/scan/form` before upload.
- Per-item on-device volumes are validated server-side (0.005–12 m³); one implausible
  item ⇒ the whole submission falls back to server-side estimation.
- German for all user-facing strings. No PII in local storage beyond session token + profile.

## Parent context

`app/` is a git submodule (`git@github.com:timefliez1210/aust_app.git`) with its
own history — a change here needs a commit inside this submodule *and* a
submodule-pointer commit in the parent repo (`aust_backend`) to take effect there.

Root: [AGENTS.md](../AGENTS.md)
Backend submissions handler: [crates/api/AGENTS.md](../crates/api/AGENTS.md)
Vision pipeline: [services/vision/AGENTS.md](../services/vision/AGENTS.md)
