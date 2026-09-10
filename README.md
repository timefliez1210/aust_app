# app — Mobile Customer Scan App

SvelteKit + Capacitor mobile app for iOS/Android. Customers scan their
furniture and get a moving quote; see [AGENTS.md](AGENTS.md) for the capture
architecture, routes, and constraints.

This directory is a git submodule of `aust_backend`
(`git@github.com:timefliez1210/aust_app.git`) — a change here needs a commit in
this submodule *and* a submodule-pointer commit in the parent repo.

## Developing

```sh
npm install
npm run dev              # vite dev server (web capture flow only — no ARKit)
```

## Type-checking

```sh
npm run check
```

## Building

```sh
npm run build
npm run preview           # preview the production web build
```

The web build only exercises the Android/web in-page capture flow. Native iOS
capture (`plugins/capacitor-depth-capture/`) requires the Capacitor iOS project
and a real device with LiDAR to test meaningfully — Xcode builds happen in CI
(Codemagic and `.github/workflows/mobile.yml`), not locally. See
[AGENTS.md](AGENTS.md) for current CI status.

## Native projects

The `ios/`/`android/` Capacitor projects are generated, not committed:

```sh
npx cap add ios
npx cap sync
```
