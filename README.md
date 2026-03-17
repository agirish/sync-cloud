# SyncCloud

A macOS application (GUI) and a command line tool (CLI) for comparing and synchronizing two directories. SyncCloud identifies differences and helps you copy files to keep folders consistent.

## Features

- **Two-pane comparison (GUI)**: Browse left/right trees and review differences
- **Smart detection**: Finds items that are missing on one side, or differ by date/size
- **Sync actions**: Copy individual items (and bulk-sync in the GUI)
- **Cloud provider discovery**: Detects common providers from `~/Library/CloudStorage`
- **CLI for power users**: A `git`-style `synccloud` command for scan/sync workflows

## Versions

- **GUI (macOS app)**: SwiftUI application in `MacApp/` (built with Xcode)
- **CLI (`synccloud`)**: Swift command line tool in `SyncCloudCLI/` (built with SwiftPM)

## CLI quick start

See the full CLI docs in `SyncCloudCLI/README.md`.

```bash
cd SyncCloudCLI
swift build

# Discover providers (optional)
swift run synccloud providers

# Scan two folders
swift run synccloud scan -L ~/OneDrive/Documents -R ~/Data/Documents

# Sync (prompts unless --yes)
swift run synccloud sync -L ~/OneDrive/Documents -R ~/Data/Documents --direction to-right --yes
```

## GUI quick start (macOS app)

1. **Set Directories**: Enter or browse to select your source and destination directories
2. **Scan for Differences**: Click "Scan for Differences" to analyze the directories
3. **Review Results**: View the list of files that need synchronization
4. **Sync Files**: Click "Sync" next to individual files to copy them

## Requirements

- macOS 14.0 or later
- Xcode 15.0 or later (for building the GUI app)
- Swift 5.9+ (for building the CLI)

## Building (GUI app)

1. Open `SyncCloud.xcodeproj` in Xcode
2. Select your target device (Mac)
3. Build and run the project (⌘+R)

## File Structure

```
SyncCloud/
├── MacApp/
│   ├── SyncCloudApp.swift          # Main app entry point
│   ├── ContentView.swift           # Main UI view
│   ├── Info.plist                  # App configuration
│   └── Entitlements.plist          # App permissions
├── Modules/                        # Shared modules (Sync, Settings, Events, ...)
├── SyncCloudCLI/                   # SwiftPM CLI tool (synccloud)
└── README.md                       # This file
```

## Permissions

The GUI app requires file system access to:
- Read files from source and destination directories
- Write files to destination directories
- Access user-selected directories

These permissions are configured in the `Entitlements.plist` file.

## License

This project is provided as-is for educational and personal use. 