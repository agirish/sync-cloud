# SyncCloud

A macOS application for synchronizing documents between two directories. This app helps you keep your documents in sync by identifying differences and allowing you to copy files to maintain consistency.

## Features

- **Directory Comparison**: Compare two directories to find differences in file content
- **Smart Detection**: Identifies files that are:
  - Missing in destination directory
  - Missing in source directory  
  - Have different modification dates
- **One-Click Sync**: Copy individual files with a single click
- **Modern UI**: Clean, native macOS interface with SwiftUI
- **File Browser**: Browse and select directories through the native file picker

## Default Directories

The app defaults to:
- **Source**: `~/OneDrive/Documents`
- **Destination**: `~/Data/Documents`

You can change these paths using the text fields or browse buttons.

## How to Use

1. **Set Directories**: Enter or browse to select your source and destination directories
2. **Scan for Differences**: Click "Scan for Differences" to analyze the directories
3. **Review Results**: View the list of files that need synchronization
4. **Sync Files**: Click "Sync" next to individual files to copy them

## Requirements

- macOS 14.0 or later
- Xcode 15.0 or later (for building)

## Building the Project

1. Open `SyncCloud.xcodeproj` in Xcode
2. Select your target device (Mac)
3. Build and run the project (⌘+R)

## File Structure

```
SyncCloud/
├── MacApp/
│   ├── SyncCloudApp.swift          # Main app entry point
│   ├── ContentView.swift           # Main UI view
│   ├── DocumentSyncManager.swift   # Core sync logic
│   ├── Info.plist                  # App configuration
│   └── Entitlements.plist          # App permissions
└── README.md                       # This file
```

## Permissions

The app requires file system access to:
- Read files from source and destination directories
- Write files to destination directories
- Access user-selected directories

These permissions are configured in the `Entitlements.plist` file.

## License

This project is provided as-is for educational and personal use. 