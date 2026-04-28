# FitTrack

A personal iOS workout tracker built around a CrossFit-style class structure
(warm-up + 4 strength stations × 8 min). Imports class WOD PDFs, logs sets
live, surfaces stats from Apple Watch HIIT sessions, tracks InBody scans, and
ships a Hevy-style Live Activity on the lock screen + Dynamic Island while
you're training.

## Requirements

- macOS with Xcode 17+ (iOS 17 SDK)
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An Apple developer account (free tier is fine for sideloading)

## Build

```bash
# Clone, then from the repo root:
xcodegen generate           # regenerates FitTrack.xcodeproj from project.yml
open FitTrack.xcodeproj     # build & run in Xcode
```

CLI build:

```bash
xcodebuild -scheme FitTrack -destination 'generic/platform=iOS' -configuration Debug build
```

## Project layout

```
FitTrack/
  FitTrackApp.swift       # @main app entry
  Info.plist              # bundle keys, NSSupportsLiveActivities, HK usage strings
  FitTrack.entitlements   # HealthKit
  Models/                 # Core Data model + ParsedWorkout + ActivityAttributes
  Services/               # Active session, HealthKit, PDF parsing, scheduling, etc.
  Views/                  # SwiftUI screens (Workout / Progress / Body / Settings)
  Utilities/              # Theme, app strings
  Resources/              # static assets (sample PDFs, etc.)
  Assets.xcassets         # icon + colors

FitTrackWidgets/          # Widget extension target — Live Activity for active workouts
project.yml               # xcodegen project definition (source of truth)
```

## Features

- Import multi-PDF workout schedules (Apple Intelligence on-device LLM with
  regex fallback)
- Live workout logger with PREVIOUS-set lookup, skip, mini-pill minimize
- Lock-screen + Dynamic Island Live Activity while training
- Apple Watch HIIT integration: per-session HR trace, station bands, AVG/MAX HR
- InBody scan tracker with OCR import + scrubbable trend charts
- Progress dashboard with per-exercise PR cards + monthly calendar

## Versioning

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `project.yml`. Each
release also gets a prepended entry in `FitTrack/Services/Changelog.swift`,
which surfaces in Settings → About → Changelog.
