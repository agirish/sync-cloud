# SyncCloud CLI (`synccloud`)

A `git`-style command line interface for SyncCloud. Use it to scan two directories for differences and sync changes without opening the macOS app.

## Requirements

- macOS 26+
- Swift 6.0+ (Xcode 26+)

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

`scan` is the default command, so `synccloud -L … -R …` runs it. Hidden files are skipped
unless you pass `--show-hidden`; `--ignore <path>` (repeatable) leaves a path out.

JSON output (useful for scripting):

```bash
synccloud scan -L ~/OneDrive/Documents -R ~/Data/Documents --json
```

Some rows have no direction `sync` can stand behind — two files whose sizes differ with no newer
side, a folder against a file, a link — and `sync` leaves them for you to decide. `scan` prints
`[needs-decision]` in place of their direction; in JSON each row carries `needsDecision`, and a
held row also `heldBack` with the reason (`sizes-differ-without-a-newer-side`, `folder-versus-file`,
`source-is-symbolic-link`, `encloses-symbolic-link`). Decide them in the app, from the row's
right-click menu.

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

Check same-size pairs that differ only by date with a checksum first, or stop at the first failed
copy:

```bash
synccloud sync -L ... -R ... --verify
synccloud sync -L ... -R ... --fail-fast
```

## Restructure (report-only)

Report where a surveyed tree disagrees with its own habits. It reads the app's folder survey and
never moves anything:

```bash
synccloud restructure
synccloud restructure --json                   # full report, stable format
synccloud restructure --profiles-dir <dir>     # read another profiles directory
```

## Command reference

```bash
synccloud --help
synccloud scan --help
synccloud sync --help
synccloud providers --help
synccloud restructure --help
```

Exit codes: `0` success, `64` usage error, `1` partial sync failure — a file failed to copy, or
was skipped because it changed after the plan was shown (re-run `sync` to see the current plan).
Files skipped by `--strategy skip`, by a provider's name rule, or left for you to decide exit `0`;
the summary lists each with its reason.

