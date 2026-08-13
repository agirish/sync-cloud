# Visual snapshot tests

Image snapshot tests (pointfree-co/swift-snapshot-testing, test-target-only dependency) pin the
visual surfaces that regressed silently in past review rounds. Suites live in four packages:

- `Modules/Design` — `DesignSnapshotTests`: TokenChipsRow (active / superseded-dimmed / yellow
  tint), StatusBadge, EmptyStateView (pre-scan + filtered-empty + C5 compact + long-path
  middle truncation), ProgressDialog, the action bar's three weights + divider (enabled and
  disabled)
- `Modules/FileExplorer` — `FileExplorerSnapshotTests`: StatPill variants, treemap tiles
  (AccentLabel light-hue pairing on the amber tile), DuplicateGroupCard (collapsed versions group +
  expanded identical-folders group with note), ConditionChip wrapping in FlowLayout
- `Modules/Dashboard` — `DashboardSnapshotTests`: PaneHeader (fresh / stale freshness pill /
  the 400 pt and 250 pt degradation ladder: pill hides, logo drops, name truncates, nav
  cluster steps down to .mini), LogViewer severity rows (comfortable + the compact
  single-line collapse)
- `Modules/Settings` — `SettingsSnapshotTests`: the Appearance tab's accent section (swatch row +
  live preview strip + caption) at four hues spanning the `AccentFill` deepening range. The
  colour pairing itself is pinned by painted-pixel assertions in `AccentPreviewTests`, not by
  the image — see the snapshot test's doc comment for what the reference does and does not catch.

Each scenario renders offscreen through `NSHostingView` in a borderless `NSWindow` at a FIXED
size, once per appearance (`…-light.png` / `…-dark.png`), and is compared with
`precision: 0.99, perceptualPrecision: 0.98` so anti-aliasing jitter cannot flake while real
color/layout changes still fail. References are committed under `__Snapshots__/` next to each
test file. The tiny render helper (`SnapshotRendering.swift`) is deliberately duplicated
verbatim in all four test targets — keep the copies in sync.

## Re-recording

After an intentional visual change, re-record the affected suite and commit the new PNGs:

```sh
cd Modules/<Package>
SNAPSHOT_TESTING_RECORD=all swift test --filter <Suite>SnapshotTests   # exits "failed": recording always reports
swift test --filter <Suite>SnapshotTests                               # must pass against the fresh references
```

Eyeball the regenerated PNGs (`open` the paths the recording run prints) before committing —
a recording run happily blesses a broken layout.

These suites are marked `.machinePinned(.referenceImages)`, which is inert unless
`SYNCCLOUD_SKIP_MACHINE_PINNED` is set (CI sets it; your shell should not). If a recording run
reports zero tests and writes no PNGs, check that the variable is unset — a skipped suite
records nothing, silently.

## Determinism caveat — single machine only

These references were validated deterministic on ONE machine (two in-place runs plus a run
after `swift package clean`, byte-identical results). CI portability was NOT attempted, and the
images are expected to differ across machines/OS versions because they bake in:

- font rasterization and the installed SF Symbols version (macOS release dependent)
- the display backing scale of the recording machine (2x Retina)
- the system accent color, wherever a view resolves `Color.accentColor` / `controlAccentColor`
- locale/timezone in formatted dates (fixture dates are frozen, but `DateFormatter` output
  is still machine-locale dependent)
- inactive-window control rendering: the offscreen window is never key, so system controls
  (prominent buttons, progress bars) render in their gray inactive style — consistent
  offscreen, but not what a screenshot of the live app shows. `ActionBarButtonStyle` is the
  deliberate exception and `ActionBarFocusIndependenceTests` turns this caveat into a rig: it
  renders a weight here precisely *because* the window is never key, and asserts the fill
  survives it.

To run these on another machine or in CI, re-record there first (or delete `__Snapshots__` and
let record mode regenerate). Never mix references recorded on different machines.

## Writing new snapshot tests

- fixed frame sizes only; never let content dictate an unstable size
- freeze every `Date` input (`Date(timeIntervalSince1970:)`); if a view compares against "now",
  choose an offset whose display bucket is far wider than test latency (e.g. 15 min → "15m ago")
- nothing async in the tree: no QuickLook thumbnails, no network images
- keep suites `@MainActor @Suite(.serialized)` — AppKit rendering is main-thread-only
