# Memento

**A safe, reversible photo and video organizer for macOS.**

Memento takes a messy, deeply nested pile of photos and videos (an old external drive, a decade of camera dumps, a folder of folders called `New Folder (3)`) and organizes it into clean, date- and event-based folders. It's built around one promise: **it never deletes your media.**

Memento reads your files without changing anything, shows you a proposed folder structure, and only touches disk after you approve the plan. Every move is verified with a checksum and logged in a journal, so any run can be undone.

---

## Table of contents

- [Highlights](#highlights)
- [Safety guarantees](#safety-guarantees)
- [How it works](#how-it-works)
- [Screens](#screens)
- [Folder structures](#folder-structures)
- [Duplicate handling](#duplicate-handling)
- [Placement modes](#placement-modes)
- [Grouping rules](#grouping-rules)
- [Requirements](#requirements)
- [Building and running](#building-and-running)
- [Running tests](#running-tests)
- [Project structure](#project-structure)
- [Architecture](#architecture)
- [Data storage](#data-storage)
- [Design system](#design-system)
- [Known limitations and roadmap](#known-limitations-and-roadmap)

---

## Highlights

- **Dry run by default.** Scanning and planning never write to your source folders.
- **Checksum-verified moves.** Each file is copied, both sides are SHA-256 hashed, and the source is released only if the hashes match.
- **Fully reversible.** Every operation goes into a durable, append-only journal. You can revert a whole run or roll back to any checkpoint.
- **Crash-safe.** A checkpoint is written every 30 seconds. If the app quits or a drive is unplugged mid-run, the Recovery screen shows exactly what happened and lets you resume or revert.
- **Smart duplicate detection.** Finds byte-identical copies, lower-resolution versions, and near-identical bursts. It knows that RAW+JPEG pairs and Live Photos are *not* duplicates.
- **Event grouping.** Splits your timeline into events using time gaps and GPS jumps, recognizes holidays, and can reuse meaningful source folder names.
- **People mode.** On-device face clustering with Vision. Name a person once and Memento recognizes them on later scans.
- **Private.** Everything runs on device. No network calls, no telemetry, and no third-party dependencies.

## Safety guarantees

These rules are enforced in the data layer, not just the UI:

| # | Rule | How it's enforced |
|---|------|-------------------|
| 1 | **Never delete media** | No code path deletes a photo or video. Duplicates are *moved* to `_Duplicates (quarantine)`, and you decide when to empty it. Trashing is done with `NSWorkspace.recycle`, never `FileManager.removeItem`. |
| 2 | **Verify before releasing the source** | Copy, then SHA-256 both sides, then remove the source. A mismatch aborts that file and logs it. (Same-volume moves are atomic renames and are still journalled.) |
| 3 | **Journal everything** | Each operation is appended to a JSONL journal with run ID, checkpoint, source and destination paths, hash, size, timestamp, and op type. |
| 4 | **Checkpoint every 30 s** | A crash, force-quit, sleep, or ejected drive loses at most 30 seconds of work. Interrupted runs open the Recovery screen on next launch. |
| 5 | **Refuse managed libraries** | `.photoslibrary` and `.lrlibrary` bundles are detected and skipped, with an explanation. |
| 6 | **Never overwrite** | Name collisions with different content get a ` (2)`, ` (3)` suffix. Collisions with identical content are treated as duplicates. |
| 7 | **Dry run is the default** | Nothing touches disk until you press **Apply** on a plan you've reviewed. |

## How it works

```
 Source ──► Scan ──► Plan ──► Review ──► Apply ──► History / Revert
  pick       read     propose   duplicates   verified,   undo any run
  folders    only     folders   & edge cases journalled  or checkpoint
```

1. **Choose sources.** Drop folders or drives onto the New Run screen, pick a destination, and choose a placement mode (Move, Copy, or Hardlink).
2. **Scan.** Memento indexes files, reads metadata (EXIF, video creation dates, GPS), hashes content (SHA-256 plus a perceptual hash), optionally detects faces, and groups items into events. Progress for each phase is shown live.
3. **Plan.** You get a proposed folder tree, collapsed by year. Select any folder to see why its items were grouped together, which source folders it merges, and any filename conflicts. You can rename, merge, or exclude folders before applying.
4. **Review.** Check duplicate sets and pick keepers. Assign dates or destinations to items with no date.
5. **Apply.** The executor carries out the plan with verification, checkpoints, pause/resume, and cancellation. It also keeps the Mac awake while running.
6. **Undo if needed.** In History you can revert an entire run, roll back to a checkpoint, or export the journal as CSV.

## Screens

The window has a sidebar and a main pane. A progress banner stays visible while a run is in flight, so you can keep browsing.

| Section | Screen | What it does |
|---------|--------|--------------|
| Library | **Timeline** | Your organized library grouped by month, with lazy-loaded thumbnails and duration pills on videos. |
| Library | **Folders** | Sortable table of organized folders: items, date range, place, size. |
| Library | **People** | Face clusters with inline naming. Naming a cluster never moves files by itself. |
| Library | **Places** | MapKit map of location clusters sized by item count, plus a list of top places. |
| Needs you | **Interrupted run** | Recovery screen: journal summary, verification of unconfirmed files, and Resume or Revert. |
| Needs you | **Needs review** | Workspace for undated items: set a date or destination and apply it to a selection. |
| Needs you | **Duplicates** | Duplicate sets grouped by kind, with the keeper highlighted, space saved, and a keeper rule. |
| Needs you | **Quarantine** | Quarantined copies (real files on disk), with Restore all or Move all to Trash. |
| Runs | **New run** | Source drop zone, destination, placement mode, and scan options. |
| Runs | **Scanning** | Per-phase progress bars, live counters, throughput, and Pause/Cancel. |
| Runs | **Plan** | Proposed tree plus an inspector with evidence tags and a plain-English explanation. |
| Runs | **History** | One card per run with status and counts, per-checkpoint revert, and CSV export. |
| Runs | **Rules** | Defaults editor: naming template, event thresholds, and safety settings. |

## Folder structures

Pick a structure per run. Year › Month is the default.

| Mode | Example output |
|------|----------------|
| **Year › Month** (default) | `2026/12-December/IMG_0001.HEIC` |
| **Year › Event** | `2026/Christmas/IMG_0001.HEIC` |
| **Event only** | `Christmas/IMG_0001.HEIC` |
| **People** | `Alex/2026/12-December/…`, with photos of no named person under `_Other photos/…` |
| **Place** | `Lisbon/IMG_0001.HEIC` |

In **People** mode, a group photo goes to the named person with the **largest face** in the frame, and unnamed faces are ignored. Inside each person's folder you can choose Year › Month, Year › Event, or Place. If you give two clusters the same name, they merge.

The folder naming template supports these tokens: `{yyyy} {mm} {dd} {event} {place} {person} {camera}`.

## Duplicate handling

| Kind | Detection | Default action |
|------|-----------|----------------|
| **Byte-identical** | Same SHA-256 | Keep the oldest copy and quarantine the rest |
| **Lower resolution** | Perceptual hash match, different dimensions | Keep the largest and quarantine the rest |
| **RAW + JPEG pair** | Same basename, one RAW extension | Not a duplicate; both are kept together |
| **Live Photo pair** | `.HEIC` + `.MOV` with the same basename | Not a duplicate; both are kept together |
| **Near-identical burst** | Perceptual hash match within ~2 s | All shots kept and flagged for your judgment |
| **Screenshot** | Screenshot / screen-recording detection | Excluded unless "Include screenshots" is on |

Quarantined files go to `<destination>/_Duplicates (quarantine)/`. Memento **never empties quarantine automatically.**

## Placement modes

| Mode | Behavior |
|------|----------|
| **Move** (default) | Fastest. Journalled and fully reversible. Same-volume moves are instant renames. |
| **Copy** | Safest, since originals are untouched. Checks free space on the destination and blocks the run if there isn't enough. |
| **Hardlink** | No bytes move, so it's near-instant. Only available when source and destination are on the same volume. |

## Grouping rules

All of these can be edited in **Rules** and are saved between launches.

| Rule | Default |
|------|---------|
| Split an event after a time gap of | 18 hours |
| Treat a location move as a new event over | 25 km |
| Minimum items per folder (smaller groups fold into a neighbor) | 8 |
| Recognize holidays (Christmas, Thanksgiving, …) | On |
| Reuse meaningful source folder names | Off |
| Face match distance (lower is stricter) | 0.6 |
| Date used for placement | Date taken (EXIF), or Date created |
| Media filter | Photos & videos / Photos only / Videos only |
| Include screenshots | Off |
| Follow symlinks | Off |
| Keep sidecar files | On |
| Read location | On |
| Scan nested subfolders | On |

Items with no usable date never get guessed into a folder. They wait in **Needs review** until you resolve them.

## Requirements

- macOS **26.5** or later (the current deployment target)
- **Xcode 26** or later
- Apple Silicon or Intel Mac

There are no third-party dependencies. Memento uses only system frameworks: SwiftUI, Foundation, ImageIO, AVFoundation, CoreLocation, MapKit, Vision, QuickLookThumbnailing, CommonCrypto, and SQLite3.

## Building and running

```bash
git clone <your-repo-url>
cd Memento
open Memento.xcodeproj
```

Then select the **Memento** scheme and press **⌘R**.

Or build from the command line:

```bash
xcodebuild -project Memento.xcodeproj -scheme Memento -configuration Debug build
```

The app is sandboxed with user-selected read/write file access, so you grant access to source and destination folders through the open panel or by dragging them in.

> **Tip:** Try your first run on a *copy* of some photos, or use **Copy** placement mode, until you're comfortable with how Memento organizes things.

## Running tests

The unit tests use the **Swift Testing** framework (`@Suite` / `@Test`). They cover the event grouper, plan builder, executor (verify-before-release, resume, revert, collision handling), scanner date handling, library store persistence, people assignment and clustering, and all six duplicate kinds. Filesystem tests use temporary fixture directories, never real user files.

```bash
xcodebuild test -project Memento.xcodeproj -scheme Memento -destination 'platform=macOS'
```

You can also press **⌘U** in Xcode.

> Test suites are marked `@MainActor` because the app target uses main-actor default isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).

## Project structure

```
Memento/
├── Memento.xcodeproj
├── Memento/
│   ├── MementoApp.swift            # App entry point
│   ├── MementoKit/                 # All non-UI logic (unit-testable)
│   │   ├── Scanner/                # MediaScanner: async directory walk
│   │   ├── MetadataReader/         # EXIF, video dates, GPS
│   │   ├── Hasher/                 # FileHasher (SHA-256 + dHash), DuplicateClassifier
│   │   ├── FaceClusterer/          # Vision face detection, clustering, PeopleAssigner
│   │   ├── EventGrouper/           # EventGrouper, HolidayCalendar, LocationNamer
│   │   ├── PlanBuilder/            # Events → proposed destination tree
│   │   ├── Executor/               # Verified, checkpointed, resumable execution
│   │   ├── Journal/                # Append-only JSONL journal + revert
│   │   ├── Library/                # SQLite library index
│   │   ├── Models/                 # MediaItem, MediaEvent, OrganizationPlan, RunRecord, GroupingRules
│   │   └── SleepBlocker.swift      # Keeps the Mac awake during long runs
│   ├── ViewModels/                 # @Observable view models (App, Scan, Plan, Timeline, …)
│   ├── Views/                      # SwiftUI screens, one folder per sidebar section
│   │   ├── AppShell.swift          # NavigationSplitView + progress banner
│   │   ├── Sidebar/ Source/ Scan/ Plan/ Duplicates/ NeedsReview/
│   │   ├── Timeline/ Folders/ People/ Places/ Quarantine/
│   │   ├── History/ Recovery/ Rules/ Shared/
│   │   └── ProgressBanner.swift
│   ├── DesignSystem/               # Colors, fonts, reusable components, ThumbnailLoader
│   └── Assets.xcassets
├── MementoTests/                   # Swift Testing unit tests
└── MementoUITests/                 # XCUIAutomation UI tests
```

## Architecture

- **MementoKit** holds all the logic, with no UI dependencies. Long-running components (`MediaScanner`, `MetadataReader`, `FileHasher`, `FaceClusterer`, `Executor`, `JournalStore`, `LibraryStore`) are **actors**. Pure algorithms (`EventGrouper`, `DuplicateClassifier`, `PlanBuilder`) are value types, which makes them easy to test.
- **Concurrency.** Hashing, metadata reading, and face detection run in bounded `TaskGroup`s sized to `ProcessInfo.activeProcessorCount`. Cancellation uses standard `Task` cancellation. Only progress snapshots cross back to the main actor.
- **View models.** These are `@Observable` classes (`AppViewModel`, `ScanViewModel`, `PlanViewModel`, `TimelineViewModel`, `RecoveryViewModel`, …). Views stay thin and read all their state from them.
- **Swift concurrency only.** The project doesn't use Combine.
- **Thumbnails.** These are generated lazily off the main thread with `QLThumbnailGenerator` and cached.
- **Pagination.** The Timeline loads items per month in pages from SQLite instead of holding the whole library in memory.

## Data storage

Everything lives in `~/Library/Containers/com.jessela.Memento/Data/Library/Application Support/Memento/` (inside the sandbox container):

| File | Contents |
|------|----------|
| `library.db` | SQLite index of organized items and their destination paths |
| `runs.json` | Run history (status, counts, checkpoints) |
| `rules.json` | Your saved grouping rules |
| `people.json` | Named people and their face prints, which seed clustering on later scans |
| `Journals/<runID>.jsonl` | Append-only, fsync'd operation journal for each run |
| `Journals/<runID>.plan.json` | Saved plan, used to resume an interrupted run |

## Design system

Memento uses a warm, rounded look rather than stock macOS gray:

| Token | Hex |
|-------|-----|
| Ground | `#f5ead8` |
| Surface | `#ebddc5` |
| Text | `#201e1d` |
| Terracotta accent | `#c67139` (tint `#fff2eb`, deep `#8c491a`) |
| Sage accent | `#7a8a5e` (tint `#f0fae1`, deep `#56633f`) |

Containers and cards use generous corner radii, and buttons, tags, inputs, and sidebar rows are pill-shaped. Headings are designed for **Caprasimo** and body text for **Figtree** (see limitations below). Colors, fonts, and shared components are in `Memento/DesignSystem/`.

## Known limitations and roadmap

- **Face matching accuracy** hasn't been tuned against a large real-world library yet. The `faceMatchDistance` default (0.6) may need adjusting.
- **Top-level Place mode** currently groups by each event's resolved location name. Smarter place clustering is planned.
- **Fonts.** Caprasimo and Figtree aren't bundled yet, so the app falls back to system fonts.
- **Empty-folder cleanup dialog.** The post-run cleanup sheet described in the design (Trash empty source folders) is still in progress.

---

*Memento never deletes your photos. It moves, verifies, and remembers, so you can always go back.*
