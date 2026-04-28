# app/ — Mobile Customer Photo App

SvelteKit + Capacitor mobile app for iOS/Android. Customers take photos of their rooms/furniture; images are uploaded to the backend for ML volume estimation.

## Architecture

```
Photo capture (Capacitor Camera)
        │
        ▼
  Upload to S3 (presigned URL or direct)
        │
        ▼
  POST /api/v1/submissions/photo  (backend submissions.rs)
        │
        ▼
  Backend → vision pipeline → estimation → offer_ready
```

## Routes (`src/routes/`)

| Route | Purpose |
|-------|---------|
| `/` | Landing / splash |
| `/scan` | Photo capture flow — room selection, camera UI, review |
| `/scan/form` | Post-photo inquiry form (name, address, phone, moving date, services) |
| `/scan/processing` | Submission in progress spinner |
| `/scan/resume` | Continue existing inquiry by email |
| `/auth` | Customer login / OTP verification |
| `/offers` | List offers linked to the customer |
| `/tutorial` | First-time onboarding / how-to-use |

## Key Files

| File/dir | Purpose |
|----------|---------|
| `src/lib/api.ts` | Backend API client (fetch wrapper, photo upload, form submission) |
| `src/lib/stores/` | Svelte stores — scan state, auth session, upload progress |
| `src/lib/components/` | Reusable UI (CameraOverlay, RoomSelector, PhotoGrid) |
| `src/lib/plugins/` | Capacitor plugin wrappers (Camera, Preferences, Network) |
| `capacitor.config.ts` | Capacitor config — app ID, server URL, logging |
| `fastlane/` | iOS/Android build + deploy automation |

## Backend Integration

- **Photo submission**: `POST /api/v1/submissions/photo` — multipart with images + JSON form data. See `crates/api/src/routes/submissions.rs`.
- **Customer auth**: `POST /api/v1/customer/auth/request-otp` + `/verify-otp` (from `crates/api/src/routes/customer.rs`).
- **Offer list**: `GET /api/v1/customer/offers` — requires `CustomerSession` JWT.

## Build & Deploy

```bash
cd app
npm run build              # SvelteKit static build
npx cap sync               # Copy web assets to native platforms
npx cap open android       # Android Studio
npx cap open ios           # Xcode
```

**Via Fastlane**:
```bash
cd fastlane
fastlane ios beta          # TestFlight
fastlane android beta      # Play Console internal testing
```

## Constraints

- Offline photo capture: images are queued locally and uploaded when network returns.
- Max 5 photos per room, 3 rooms per submission (enforced in UI + backend).
- Camera quality: `high` for iOS, `jpegQuality: 90` for Android.
- No PII in local storage — use Capacitor `Preferences` for session tokens only.

## Parent Context

Root: [AGENTS.md](../AGENTS.md)
Backend submissions handler: [crates/api/AGENTS.md](../crates/api/AGENTS.md)
Vision pipeline: [services/vision/AGENTS.md](../services/vision/AGENTS.md)
