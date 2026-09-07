# PlantPlant 🪴

A native iOS app for managing your house plants — watering & care reminders, rooms,
archive, and a full change log. Built with **SwiftUI + SwiftData**, targeting **iOS 26**,
with a **Liquid Glass** look and **dark mode** by default.

## Features

- **Plants** — add / edit / delete with name, scientific name, photo, room, acquired date,
  sunlight need, how dry the soil should get, notes, and per-care-type reminders.
- **Care types** — watering, fertilizing, misting, repotting and photo, each independently
  enabled with its own interval (1–730 days). Defaults 7 / 30 / 3 / 365 / 30 days.
- **Seasonal watering** — per-plant month sets that override the base watering interval, so a
  plant can drink weekly in summer and fortnightly in winter.
- **Overview** — sort by deadline or by name, search (diacritic-insensitive, over both names),
  and care-type chips on plants with something due.
- **Reminders tab** — a Reminders-app-style checklist grouped into Overdue / Today / Tomorrow /
  This Week / Later, each row tinted in its care-type colour; tap to mark done, swipe to snooze,
  or clear everything overdue and due today at once from the toolbar button.
- **Rooms** — define, rename, reorder, and delete rooms in Settings. A room with active plants
  refuses to delete.
- **Archive** — archive old plants (kept with history) and restore or delete them later.
- **Journal** — every completion, snooze, photo change, edit, archive and restore is logged,
  grouped by day, with edits recorded as readable diffs and photos attached.
- **Photo gallery** — a full-screen swipeable history of every photo a plant has had.
- **Local notifications** — reminders fire at the configured time (default **16:00**, set in
  Settings) on the due day, with same-day tasks merged into one notification. An optional
  **second reminder time** repeats the same day at another hour. A single-task reminder carries
  **Mark done** and a **Snooze…** action that takes a typed number of days.
- **Export** — Settings → Data writes the whole library to one `plantplant.export` JSON file
  (photos inline, downscaled to 2000 px), for handing to the web app.
- **Home screen widget** — "Needs Water" (small + medium), showing plants due today via a
  shared SwiftData store. **Currently disabled** — see the note in `project.yml`: App Groups
  and app extensions need a paid Apple Developer Program membership.

## Project layout

```
project.yml                      # XcodeGen project definition
PlantPlant/
  App/                           # App entry + root tab view
  Models/                        # SwiftData @Model types + shared container (shared w/ widget)
  Services/                      # CareService, NotificationManager, SampleData
    Export/                      # DataExporter + the plantplant.export writer
  Views/                         # Plants, Reminders, Settings, Archive, Components
  Resources/                     # Assets.xcassets, Localizable.xcstrings, entitlements
PlantPlantTests/                 # Swift Testing suites: care logic + export
PlantPlantWidget/                # WidgetKit extension (Needs Water) — target disabled
```

## Getting started

### Prerequisites (one-time)

The machine had only the SDK installed, so before the first build you must accept the
license and install the iOS 26 simulator runtime:

```bash
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS      # installs the iOS 26 simulator runtime (multi-GB)
```

(`xcodegen` is already required to generate the project: `brew install xcodegen`.)

### Generate & run

```bash
cd plantplant
xcodegen generate
open PlantPlant.xcodeproj
```

In Xcode: select your **Development Team** for both the `PlantPlant` and
`PlantPlantWidgetExtension` targets (Signing & Capabilities), pick an iOS 26 simulator, and
Run. To build from the command line once the runtime is installed:

```bash
xcodebuild -project PlantPlant.xcodeproj -scheme PlantPlant \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### Tests

The suites use **Swift Testing**, not XCTest, so `xcodebuild`'s own summary line reports
"Executed 0 tests" — read the `✔`/`✘` lines instead:

```bash
xcodebuild test -project PlantPlant.xcodeproj -scheme PlantPlant \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E '✔|✘'
```

## Configuration notes

- **Bundle IDs** are `com.kittmedia.plantplant` and `com.kittmedia.plantplant.widget`, with
  app group `group.com.kittmedia.plantplant`. Change them to your own (in `project.yml`, both
  `.entitlements` files, and `AppGroup.identifier` in `Models/SharedModelContainer.swift`),
  then re-run `xcodegen`. The App Group entitlement and the widget target are commented out in
  `project.yml` so the app builds under free personal-team signing; restore both with a paid
  account.
- **Swift language mode** is set to 5.0 in `project.yml` for a smooth first build; bump to
  6.0 if you want strict concurrency checking.
- **Notification budget.** iOS keeps at most 64 pending requests per app and silently drops the
  rest. `NotificationManager.pendingLimit` / `.reminderLimit` divide that between day reminders
  (soonest first) and the midnight badge rollovers; a second reminder time doubles the reminder
  side, so raise them together or not at all.
- **Dark mode** is forced via `.preferredColorScheme(.dark)` in `PlantPlantApp`. All colors
  live in the asset catalog with light + dark variants, so enabling light mode later is just
  removing that one modifier.
- The **app icon** ships light, dark and tinted 1024×1024 variants in
  `Assets.xcassets/AppIcon.appiconset`, generated from the two SVGs at the repo root.
