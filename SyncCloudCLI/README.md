# SyncCloud CLI (`synccloud`)

A `git`-style command line interface for SyncCloud. Use it to scan two directories for differences and sync changes without opening the macOS app.

## Requirements

- macOS 14+
- Swift 5.9+

## Build

From the repo root:

```bash
cd SyncCloudCLI
swift build
```

Run via SwiftPM:

```bash
swift run synccloud --help
```

Optional: build a release binary and put it on your PATH:

```bash
cd SyncCloudCLI
swift build -c release
cp .build/release/synccloud /usr/local/bin/
```

## Provider discovery

SyncCloud can use either:

- **A raw path** (like `~/OneDrive/Documents`)
- **A provider id / name** discovered from `~/Library/CloudStorage` (like `iCloud`, `OneDrive-<account>`, `GoogleDrive-<account>`, `Dropbox`)

List discovered providers:

```bash
synccloud providers
```

## Scan (compare)

Scan two folders and print differences:

```bash
synccloud scan -L ~/OneDrive/Documents -R ~/Data/Documents
```

Filter by direction:

```bash
synccloud scan -L ~/OneDrive/Documents -R ~/Data/Documents --direction to-right
synccloud scan -L ~/OneDrive/Documents -R ~/Data/Documents --direction to-left
```

JSON output (useful for scripting):

```bash
synccloud scan -L ~/OneDrive/Documents -R ~/Data/Documents --json
```

## Sync (apply changes)

Sync differences (prompts for confirmation unless `--yes` is passed):

```bash
synccloud sync -L ~/OneDrive/Documents -R ~/Data/Documents
```

Sync only left → right:

```bash
synccloud sync -L ~/OneDrive/Documents -R ~/Data/Documents --direction to-right --yes
```

Collision strategy (when the destination already exists):

```bash
synccloud sync -L ... -R ... --strategy replace     # default
synccloud sync -L ... -R ... --strategy skip
synccloud sync -L ... -R ... --strategy keep-both
```

## Command reference

```bash
synccloud --help
synccloud scan --help
synccloud sync --help
synccloud providers --help
```

