# iFileList

A macOS app that lists every file on your Mac in one searchable list.

## Requirements

- macOS 15 or later
- Xcode 16 or later to build

## Installation

Builds are available under the [Releases](https://github.com/mrozip/iFileList/releases) section.

## Building

Open `iFileList.xcodeproj` in Xcode and run the **iFileList** scheme, or build from the command line:

```sh
xcodebuild -project iFileList.xcodeproj -scheme iFileList -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/iFileList.app
```

On a fresh Mac, `xcodebuild` may first ask you to run `sudo xcodebuild -runFirstLaunch`.

### Building a DMG

```sh
scripts/make-dmg.sh
```

This builds a universal Release copy and writes `build/iFileList-<version>.dmg`, with an Applications shortcut to drag the app onto.

Without a Developer ID the app is ad-hoc signed, so other Macs block the first launch. To open it there, use **Open Anyway** in **System Settings › Privacy & Security**. To sign and notarize it instead:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary scripts/make-dmg.sh
```

`NOTARY_PROFILE` names credentials saved with `xcrun notarytool store-credentials`.

## Full Disk Access

1. On first launch, click **Open System Settings**.
2. Turn on iFileList under **Privacy & Security › Full Disk Access**.
3. Reopen the app when prompted.

## Searching

Searching by filename or path is supported.

## Settings

Open **iFileList › Settings…** (⌘,) to choose what is indexed. The startup disk is always indexed.

- **Index external drives**: USB, Thunderbolt, mounted disk images.
- **Index network drives**: Mounted network shares. Requires a full rescan (⌘R) or restart.
- **Excluded from Index**: Files and folders to exclude from indexing.

## Keyboard shortcuts

Most common Finder shortcuts are available.

| Shortcut | Action |
| --- | --- |
| ⌘F | Focus the search field |
| ⇧⌘F | Filter by folder |
| ⌥⌘F | Clear filters |
| Return or ⌘O | Open the selected files |
| ⌘R | Rescan all volumes |
| ⌘, | Open Settings |

## Project layout

```text
iFileList/                    The app: SwiftUI window, AppKit file table, file actions
Packages/FileIndexKit/        Indexing engine, as a Swift package
  Sources/FileIndexKit/
    Scanning/                 Directory reading, parallel scanner, volumes, FSEvents
    Persistence/              SQLite cache
    Index/                    In-memory index, name matching, search and sorting
    IndexCoordinator.swift    Ties scanning, the cache and live updates together
  Tests/FileIndexKitTests/    Unit and end-to-end tests
```

## Tests

```sh
swift test --package-path Packages/FileIndexKit
```

The end-to-end tests scan a temporary folder and follow real FSEvents changes to it.

An opt-in benchmark scans your startup disk (skipping `/Users`) and reports timings:

```sh
IFL_BENCHMARK=1 swift test --package-path Packages/FileIndexKit -c release --filter BootVolumeBenchmark
```
