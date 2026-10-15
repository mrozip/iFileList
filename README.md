# iFileList

A macOS app that lists every file on your Mac in one searchable list.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘F | Focus the search field |
| Return or ⌘↓ | Open the selected files |
| ⌘R | Rescan all volumes |

## Requirements

- macOS 15 or later
- Xcode 16 or later to build

## Building and running

Open `iFileList.xcodeproj` in Xcode and run the **iFileList** scheme, or build from the command line:

```sh
xcodebuild -project iFileList.xcodeproj -scheme iFileList -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/iFileList.app
```

On a fresh Mac, `xcodebuild` may first ask you to run `sudo xcodebuild -runFirstLaunch`.

## Full Disk Access

1. On first launch, click **Open System Settings**.
2. Turn on iFileList under **Privacy & Security › Full Disk Access**.
3. Reopen the app when prompted.

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
