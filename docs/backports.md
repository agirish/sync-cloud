# Backport tracker

What each maintenance line is **owed**, what it is **deliberately not** owed, and how much of the
surface **nobody has looked at**. One file, carried identically on all three lines, so a maintainer
sitting on `v2.x` can see what `v2.x` is missing without reading `main`'s history.

The rule this tracks is in [`CLAUDE.md`](../CLAUDE.md): land a change on the **oldest line that
carries the code**, then cherry-pick forward. Only breaking changes, removals and restructures are
`main`-only. "Applies" means *the code is there*, not that a user would notice.

## How to check one thing

Two stages, and the second is the one that gets skipped:

```sh
git ls-tree -r --name-only origin/v3.x -- <path>        # 1. is the FILE there at all?
git show origin/v3.x:<path> | grep -c '<symbol>'        # 2. is the SHAPE there?
```

A file can be present and the fix absent — that is the usual case, and stage 1 alone reads as
"already done". Note `grep -c` **exits 1 on zero**, so `grep -c … || echo 0` prints *two* lines and
a miss silently reads as a hit; test the count, not the exit status. (Written down because this
audit made that exact mistake and every "MISSING" came back "Y".)

---

## `v3.x` — owed

### 1. The `DeleteOutcome` family — OPEN, deliberately deferred

`Modules/Sync/Sources/Sync/DeleteOutcome.swift` is absent on this line and `deleteItems` still
answers an `Int`, so it cannot report whether an item reached the Trash or was destroyed
permanently. Three fixes on `main` and `v2.x` have no `v3.x` counterpart, and each is a ⌘Z promise
the line cannot keep on a Trash-less volume (exFAT, most SMB shares):

| Missing on `v3.x` | `v2.x` / `main` | What 3.x still does |
|---|---|---|
| merge undo guard (`anyPermanentlyDeleted`) | `f8648c0c` / `7a220e62` | offers ⌘Z after a permanent delete — and undoing the fold DELETES the copied files, with the originals gone |
| partial-batch `undoable:` flag | `83a05f22` / `8a505b5f` | offers an undo that never expires, so it comes to point at another operation |
| duplicate-review log branch | `d6791da0` / `b632223d` | logs "Trashed" for a copy destroyed permanently |

**Not the usual cherry-pick**, which is why it is written down rather than done: each fix reads
`DeleteOutcome`, so taking them means taking the type and a `deleteItems` signature change onto a
shipped maintenance line. That is a scope call. Expect the `MacApp/` caller to move in the same
commit — leaving it behind is exactly what broke `main` and `v2.x` on 2026-08-16, with green
package suites and a red app-target step.

**This has a deadline.** `v3.x` sits at `3.2-dev`. Cutting v3.2 before this lands ships the
⌘Z-after-permanent-delete promise again, in a release, knowingly.

### 2. The filing walkthrough's bare ⏎/→/esc key equivalents, and the review card's unguarded ⏎/⌫ — OPEN, owed to BOTH lines

Filed 2026-08-21, when the fix landed on `main` as `d25dafef`. The walkthrough's File and Skip
buttons carry `.keyboardShortcut(.return, modifiers: [])` / `(.rightArrow, modifiers: [])`, and
Cancel carries `.keyboardShortcut(.cancelAction)` — all window-level key equivalents, consulted
**before** the first responder. So with the walkthrough up, a ⏎ typed into the lens header's
search field moves the current file on disk, a → silently skips one with no back-step, a held ⏎
approves file after file (equivalents fire on key-repeat), and an esc meant to clear the field
discards the walkthrough's approvals. Confirmed present on both lines, symbol-level:
`git show origin/<line>:Modules/FileExplorer/Sources/FileExplorer/AutomationsLens.swift |
grep -c 'modifiers: \[\]'` answers `2` on `v3.x` and on `v2.x`.

**Not a clean cherry-pick**, which is why it is written down rather than done in the landing
session. `main`'s fix restructures the card into `FilingWalkthroughCard` (focusable anchor +
`.onKeyPress`, `.down`-phase only), and `AutomationsLens.swift` has drifted on both lines
(`TidyView` vs `LensWorkspaceView` doc anchors, no `personIs`/`unrecognized` cases, `v2.x`'s
provider/source vocabulary split — the card's caption reads `\(provider)`). The two new suites
travel with the fix and need per-line adaptation too: `FilingWalkthroughCardKeyTests` borrows its
window harness from `DifferencesTableBindingTests`, which is **present on both lines** — the file
AND its `host(_:)` harness, `git show origin/<line>:…/DifferencesTableBindingTests.swift | grep -n
'func host('` answers line 104 on `v3.x` and on `v2.x`, and the `LayoutPumpWait.pump` it relies on
is present too (the floor scan landed per line). An earlier revision of this entry claimed the
harness file was absent on both lines, overstating the port's cost; the claim had not been checked
— re-verified 2026-08-21. `BareKeyEquivalentScanTests`' count floor (`files.count > 150`) still
needs re-deriving against each line's smaller source tree. `.onKeyPress` itself and the
`AutomationDryRunRow` initializer shape (`destinationAnchor`) are present on both lines — checked,
so the port compiles in principle.

**The port must take the fix's FIXED shape, not its first cut.** `d25dafef`'s original
`.onKeyPress(keys:phases:)` handlers never inspected `press.modifiers`, so ⌘⏎/⇧⏎ FILED the current
item and ⌥→/⌃→ irreversibly SKIPPED it (measured through a real responder chain in
`FilingWalkthroughCardKeyTests.aModifiedKeyDecidesNothing`). The modifier filter, the `.down`-phase
esc handler, and the retirement log lines in `FilingWalkthrough.cancel(because:)` are all part of
what the lines are owed; cherry-picking the walkthrough restructure without them re-ships the
modifier-blind regression onto a maintenance line.

**No `onKeyPress` overload filters modifiers, and none suppresses key-repeat.** An earlier revision
of this entry said the `keys:phases:` overload "unlike the single-key one, delivers modified
presses". That is false, it was never measured, and it was the most expensive sentence in this
file: a maintainer reading it concludes their line's single-key `.onKeyPress(.return)` is already
safe and skips the half of this debt that moves bytes. Settled 2026-08-21 on the suites'
real-window `sendEvent` harness — the single-key overload behaves identically to `keys:phases:` in
both respects, and differs in exactly one: it does not fire on `.up`. Raw readings, invocations per
event: `return` plain / ⌘ / ⇧ / ⌥ / ⌃ / capsLock / `isARepeat` → **all fire**; three repeats → 3
invocations; `keyUp` → none.

The reading that produced the false version came from ⌘esc, ⌃esc and ⌘. being **swallowed by
AppKit as `cancelOperation:` before the responder chain** — those reach NEITHER overload, while
`escape` plain / ⇧ / ⌥ / fn / capsLock all do, and ⌘-space does too. That is a per-key routing
effect, not a property of an overload. Anything that must not run for a chord guards on
`KeyPress.isPlainKeystroke` whichever overload it is written with; only `keys:phases:` can also
refuse auto-repeat. `Modules/Design/Sources/Design/IntentModifiers.swift` says the same thing at
its `isPlainKeystroke` doc, and this file contradicted it in the same tree.

**`ReviewCardView` is owed BOTH halves, and the byte-moving one used to be missing from this
entry** — it named only "⌫ modifier filter". Verified at
`git show origin/<line>:Modules/FileExplorer/Sources/FileExplorer/ReviewCardView.swift`, identical
on `v3.x` and `v2.x`:

```swift
.onKeyPress(.return) {                                  // ← line 99 on both lines
    if !isActing && !isVerifying { onPrimary(item) }
    return .handled
}
.onKeyPress(keys: [.delete], phases: .down) { _ in      // ← line 107 on both lines
    if !isActing { onSkip(item) }
    return .handled
}
```

So both maintenance lines currently ship, on the card whose ⏎ runs a real copy or move:

- **⌘⏎ / ⇧⏎ / ⌥⏎ / ⌃⏎ each run the primary copy or move.** ⌘⏎ and ⇧⏎ measured on `main`'s card
  under this exact spelling — two modified presses, two `onPrimary` calls; ⌥ and ⌃ from the
  overload measurement above, where every intent modifier is delivered.
- **A held ⏎ launches 4 copies of one row** before `isActing` closes — it closes only when the
  host's async outcome lands, so auto-repeat gets there first. The ⌫ handler is `.down`-only and
  so does not repeat, but it takes `_ in` and inspects nothing, so ⌘⌫ (Finder's "delete
  immediately") and ⌥⌫ (delete word) each SKIP a row no back-step can revisit.
- **The keypad's Enter is dead**, silently, with the hint row advertising ⏎: keyCode 76 sends
  U+0003, and a handler keyed on `.return` matches U+000D only.
- **Neither key is gated on `focused`.** With Full Keyboard Access on, the card's Skip / Quick Look
  / Verify buttons are focusable, and `.onKeyPress` fires for a key delivered anywhere in its
  SUBTREE — measured 2026-08-21 by driving a `@FocusState` onto a descendant: the ancestor handler
  ran with `focused == false`. So a ⏎ aimed at a focused Skip button runs the copy. This was true
  on `main` too until 2026-08-21; `main` has it now and the lines do not.

**The review-card half cannot cherry-pick clean either, and for a different reason than the
walkthrough half above: it depends on two files neither line has.**
`KeyPress.isPlainKeystroke` lives in `Modules/Design/Sources/Design/IntentModifiers.swift`
and `KeyEquivalent.keypadEnter` in `Modules/Design/Sources/Design/KeypadEnter.swift`; both are
**absent from `v3.x` and `v2.x`** — `git show origin/<line>:<path>` fails, and `git grep -l
keypadEnter origin/<line> -- Modules` finds nothing. Take those two files first, then the card.
Do not substitute `press.modifiers.isEmpty` for the guard: `.numericPad` + `.function` ride on
every keypad Enter and `.capsLock` on every event while the lock is engaged, so that spelling
refuses the keycap the fix exists to accept and kills the keys outright for anyone with Caps Lock
on. `ReviewCardKeyTests` travels with the port and needs the same per-line adaptation as the
walkthrough's two suites.

**Separately, and verified while checking the above: `v2.x`'s `ReviewCardView` has no
`.accessibilityHint` and its `ReviewCardModel` has no `keyHintSpeech` at all** (`grep -c` answers
0 on `v2.x`, 1 on `v3.x`). So on `v2.x` a VoiceOver user gets the card's label and no statement of
what any of its keys do. Small, self-contained, and independent of everything above.

### 3. The folder-duplicate drift gate rebuilt on per-file snapshots — OPEN, filed 2026-08-21

Fixed on `main`, 2026-08-21, as two commits — *Judge folder duplicate drift per file, against a
snapshot the scan records* (engine) and *Give the Compare review's directory gate the shared
folder re-walk* (review); both maintenance lines
carry all three defects, symbol-checked (`folderDriftedInPlace` present on both; the Compare gate's
`guard !isDirectory else { return true }` present on both):

- `folderDriftedInPlace` compares the scan's ignored-names-skipping rollup against a RAW re-walk,
  so any folder holding a `.DS_Store` (or a symlink) is **permanently refused** — "changed since it
  was scanned", reproduced by every rescan — and `applyRecommendedDuplicates` silently drops such
  groups. The same constant offset can mask a real loss.
- Count+bytes equality cannot see a **same-length rewrite**, so a "redundant" folder holding the
  only copy of the edit is trashed.
- The Compare review's directory verdict is **existence-only** (`duplicateCopyMatchesScan`), under
  a comment claiming "the engine's own folder gap is tracked separately" — stale on both lines,
  since both carry `folderDriftedInPlace`. The review is the folder-ONLY flow.

**Not the usual cherry-pick.** The fix adds `FolderContentSnapshot` to `DuplicateCopy` and fields
to `DuplicateCompareContext`, records snapshots in `DuplicateFinder.findGroups`, and makes
`driftedFolderInGroup` async — a public-shape change in the Sync package plus a `MacApp/` caller
moving with it (the 2026-08-16 lesson: grep `MacApp/` after any public signature change). On
`v2.x` the vocabulary split ("provider"/"source") means the coordinator will not pick clean.
The first (P1-4) defect is user-visible on any Finder-touched folder, which argues for taking it;
the scope argues for doing it deliberately. Symbols to check when settling: `FolderContentSnapshot`,
`folderContentsMatchScan`, `contentSnapshot` on `DuplicateCopy`.

### 4. The copy-undo's shallow folder identity — OPEN, owed to BOTH lines

Filed 2026-08-21, when the deep identity landed on `main` (*Give the copy-undo a deep folder
identity so ⌘Z cannot trash an edited copy*). Both lines carry the defect, symbol-checked:
`ItemIdentity.swift` on `v3.x` and `v2.x` has only the shallow `case directory(modified:childCount:)`
— own mtime plus immediate child count — so an edit deep inside a copied folder leaves the identity
`.unchanged` and ⌘Z of the copy trashes the only instance of the edit. `main`'s fix adds
`.directoryTree(contentDigest:)` backed by a recursive stat-only walk (`deepSnapshot`).

**A scope call, not a pick, for the same reason as item 1**: the undo file is where the
`DeleteOutcome` family lives, and `v3.x` is already recorded above as deliberately deferring that
family — a deep identity that refuses an undo cannot say *why* honestly on a line that cannot tell
a trashed item from a permanently deleted one. Settle item 1 first; this rides the same file.
Symbols to check when settling: `deepSnapshot`, `.directoryTree` in `ItemIdentity.swift`.

### 5. The classifier's cloud guard knows only iCloud — OPEN, owed to BOTH lines, filed 2026-08-22

Both lines download cloud-only Dropbox, OneDrive, Google Drive and Box files behind the user's back
during filing classification. `MacApp/ContentSignalExtractor.swift` guards `extractTextSync` with its
own `private static func isEvictediCloudFile` (`v3.x:74`, `v2.x:122`, byte-identical), which is
spelled purely from iCloud's `isUbiquitousItem` / `ubiquitousItemDownloadingStatus`. A dataless file
under `~/Library/CloudStorage` is not a ubiquitous item, so the guard answers "not evicted", the
extractor opens it, and **opening it is what makes the provider fetch it**. `main` replaced the copy
with `FilingSurvey.isAvailable`, which tests `SF_DATALESS` first — the provider-agnostic signal every
File Provider sets — and keeps the iCloud check only for the `.downloaded`-but-stale case.

**The blocker previously assumed here is not real, and that is the point of this entry.**
`FilingSurvey.swift` is indeed absent on both lines, so this cannot be a cherry-pick — but the
predicate the fix actually depends on is already present on both:
`MaterializationStatus.isCloudOnly(atPath:)` (`MaterializationStatus.swift`, all three lines), and
`ContentSignalExtractor.swift` already carries `import Sync`. The fix is one added line inside the
existing private function:

```swift
if MaterializationStatus.isCloudOnly(atPath: url.path) { return true }
```

**What is genuinely missing is the test seam, and it should be ported with the fix.** `SF_DATALESS`
is an `SF_` flag that `chflags` refuses to anyone but root, so a dataless file cannot be staged and
the only honest test substitutes the syscall. `main` added `MaterializationStatus.StatFlags` (a
`@Sendable (String) -> UInt32?`) plus a defaulted `statFlags:` parameter for exactly this, and
`Modules/Sync/Tests/Sync/FilingSurveyAvailabilityTests.swift` drives it. Both maintenance lines have
`isCloudOnly(atPath:)` with **no** seam, so a fix landed without it would be untestable in the
direction that matters. Adding a defaulted parameter is additive and source-compatible — allowed on
a maintenance line.

Oldest-first: land on `v2.x`, cherry-pick to `v3.x`. Verify with `xcodebuild test` on the app
target, not `build` — `MacApp/` is in no SPM package. Symbols to check when settling:
`isEvictediCloudFile`, `MaterializationStatus.StatFlags`, `realStatFlags`.

### Checked and NOT owed

Verified present on `v3.x` on 2026-08-20, so a future audit need not re-raise them:

| Family | symbol checked |
|---|---|
| cloud accounts wiped by an unreadable `CloudStorage` | `CloudStorageAccounts` |
| automation rules lost to one unreadable value | `unreadableFields` |
| spend record zeroed by an unreadable payload | `unreadable` in `FilingSpend.swift` |
| storage snapshots amended away | `unreadable` in `StorageLensStore.swift` |
| undo/redo moving an item it cannot identify | `liveLocation` |
| the `poll`/`pump` wait floors | `static func poll` |

### Settled after being filed as owed

**`theFloorIsOnlyLoweredByItsOwnTests` — present on all three lines.** Checked 2026-08-21; this
stood above as owed item 2 until then, on the strength of a `v2.x`-only sighting. The scan that
keeps every real wait on `LayoutPumpWait`'s default floor landed once per line, in its own commit
each — `2f5ca5b5` on `v2.x`, `2cd1eb22` on `main`, `4846ac32` on `v3.x`. `git branch -r --contains`
names exactly one line apiece, which is why three separate landings read as none at all from a
single line's history. Nothing is owed.

**The permit sets differ by line, and that is correct rather than drift.** The guard is a substring
scan for `floor: `, so it has to name the files allowed to lower one. `v3.x` and `main` permit
three — `LayoutPumpWaitTests.swift`, `LayoutPumpWaitPollTests.swift` and
`ShortcutRevealTrackerTests.swift`; `v2.x` permits one, because the other two are **absent** on that
line. Do not level them up to match: the scan asserts `permittedSeen == permitted`, so naming a file
that does not exist turns the guard red rather than strengthening it. The old entry called this out
before the fact — it predicted `ShortcutRevealTrackerTests` would need a permit entry, and a permit
entry is precisely what landed.

Non-vacuity holds on every line too, which is the half worth re-checking if these files move: the
walk requires `scanned` > 100 on `v2.x` and > 200 on the other two, against 315 / 357 / 522 test
files respectively, and each permitted file really does carry a `floor: ` for the scan to see.

### Main-only by rule, so never owed

Recorded so a future audit does not spend an hour deciding these again. Each is a restructure or a
new feature, which `CLAUDE.md` puts on `main` alone — not a fix that a maintenance line is missing.

- **The app-wide text size becoming a percentage.** `FontSize` stopped being a four-case enum and
  became a value wrapping an `Int` percentage (90–135). That is a public type changing shape, and
  the stored `fontSize` default changed with it — `"small"/"medium"/"large"/"extraLarge"` to a
  number, migrated at launch. Porting it would mean a maintenance line rewriting a user's stored
  preference for no fix. Symbol to check if this is ever revisited: `migrateLegacyValue` in
  `Modules/Design/Sources/Design/FontSize.swift`.
- **The Readability tab.** A new `SettingsTab` case, a new rail row, and Size & spacing moving out
  of Appearance — a feature and a restructure together. It also lowered `SettingsSheetMetrics
  .baseSize` (704 → 624), which changes the sheet every tab is drawn in.
- **`SizePreset` / `SizePresetRow` / `SizeSpacingPreview`.** New types with no counterpart to fix
  on either line.

- **`flaky-tests.md`'s "The control that stops an absence being vacuous is itself load-dependent".**
  The mechanism is real on any line, but the only test that has ever produced it —
  `MergeUndoGroupingAndGateTests.noUndoGroupIsEverOpenWhileTheMergeIsSuspended` — exists on `main`
  alone, and `flaky-triage.md`, which carries its signature row, is a `main`-only file. A section
  describing a test a maintenance line does not have is a section its reader cannot act on. The
  companion finding from the same CI run *was* portable and is on all three lines: the
  expiry-discarding `waitUntil` recorded under "Fixed pumps and fixed sleeps", whose test and helper
  are byte-identical everywhere. Checked 2026-08-22.

The one part of this work that *would* have been portable — a bug fix inside `scaledPointSize` —
does not exist: the curve was not touched.

### The v4.2 adversarial review — checked, and none of it is owed

Settled 2026-08-20, after a review of the seventy commits since `v4.1`. Nine findings; every one of
them lands on code that no maintenance line carries, so nothing here is a backport candidate. Stated
per finding rather than as a blanket "v4 feature work", because two of the nine *look* portable:

| Finding | Why `main` alone |
|---|---|
| the setup form's disclosure, outline, focus and copy | `MacApp/SetupSheet.swift` is ABSENT on both lines |
| `PersonCandidates` dead code and stale ordering doc | `Modules/Sync/Sources/Sync/PersonCandidates.swift` is ABSENT on both |
| `mayRepoint` and four stale `writeProfile` claims | `mayRepoint` is v4.2's; the claims it falsified are its own |
| `FontSize.migrateLegacyValue`'s hijacked doc block | the percentage `FontSize` is main-only by the entry above |
| `ReadabilitySettingsTab` taking `ProvidersSettingsTab`'s doc | the Readability tab is main-only by the entry above |

The two that needed checking rather than reasoning about:

- **⌘/ registered on nothing.** `cd87b08e` removed `ShortcutsWindowCommand`'s only call site while
  taking the auxiliary windows out of the Help menu, and nothing re-registered the chord. That
  commit is inside the v4.2 range, and both maintenance lines still call it — checked directly:
  `git show origin/v2.x:MacApp/SyncCloudApp.swift | grep -c 'ShortcutsWindowCommand()'` answers `1`,
  and so does `v3.x`. ⌘/ works on both lines; the regression is `main`'s alone.
- **↩ / Space firing under the destination picker.** ↩ (`paneRename`) arrived in `88d95ed9`, in
  range. Space's half looked portable — `MacApp/ContentView+PaneSearch.swift` is present on `v3.x` —
  but `paneQuickLook` is not in it: `git show origin/v3.x:MacApp/ContentView+PaneSearch.swift | grep
  'func paneQuickLook'` finds nothing, and the file is absent from `v2.x` entirely. The guard also
  reads `showCommandPalette`, which neither line has. Symbol to check if this is revisited:
  `paneChordsSuspended` in `MacApp/ShortcutCommands.swift`.


---

## `v2.x` — owed

### The filing walkthrough's bare key equivalents, and the review card's unguarded ⏎/⌫

Owed here exactly as to `v3.x` — see item 2 under `v3.x` above for both defects, the symbol checks
(every one answered on `v2.x` too, and `ReviewCardView.swift`'s two handlers are byte-identical
between the lines) and why it is an adaptation rather than a pick. Two extra costs on this line:

- the provider/source vocabulary split — the walkthrough card's caption interpolates the provider
  name, so the port must keep this line's wording;
- `v2.x`'s `ReviewCardView` has **no `.accessibilityHint`** and its `ReviewCardModel` has no
  `keyHintSpeech` at all (`grep -c` answers 0 here, 1 on `v3.x`), so the review card announces its
  label and nothing about its keys. Independent of the key fix and much smaller; take it while the
  file is open.

### The folder-duplicate drift gate — OPEN, filed 2026-08-21

Owed here exactly as to `v3.x` — see item 3 under **`v3.x` — owed** for the three defects, the
symbol checks, and why it is a scope call rather than a cherry-pick. `v2.x` carries
`folderDriftedInPlace` and the existence-only directory verdict too, and its "provider" vocabulary
means the `MacApp/` half will need adaptation, not a pick.

### The copy-undo's shallow folder identity — OPEN, filed 2026-08-21

Owed here exactly as to `v3.x` — see item 4 under **`v3.x` — owed**. `v2.x` carries the shallow
`case directory(modified:childCount:)` too (symbol-checked). Unlike `v3.x` this line has the
`DeleteOutcome` family, so the port is closer to a pick here — but the undo file has drifted, so
verify `deepSnapshot`'s seams before assuming.

### The classifier's cloud guard knows only iCloud — OPEN, filed 2026-08-22

Owed here exactly as to `v3.x`, and **this is the line to fix first** — see item 5 under
**`v3.x` — owed** for the mechanism, the symbol checks and the seam that has to come with it.
`v2.x` carries the byte-identical `isEvictediCloudFile` at `MacApp/ContentSignalExtractor.swift:122`
and the same seamless `MaterializationStatus.isCloudOnly(atPath:)`. No vocabulary adaptation is
needed: the change is inside a private function and touches no user-facing copy.

### Nothing else confirmed

Every safety family above is present on `v2.x`, and it is the line the `DeleteOutcome` family
landed on first. Apart from the entry just above, no other confirmed fix debt was found by
the 2026-08-16 audit or this one.

### Checked and NOT applicable

- **Storage lens preservation.** `Modules/Sync/Sources/Sync/StorageLensStore.swift` does not exist
  on `v2.x` at all — the lens is a 3.x-and-later feature. Stage 1 answers this; there is nothing to
  port to.
- **The text-size percentage and the Readability tab.** Main-only by rule for the same reasons
  spelled out under `v3.x` above — a public type changing shape, a stored default changing with it,
  and a new Settings tab. Nothing here is a fix `v2.x` is missing.

---

## v4.2's four shipped items — triaged 2026-08-20

Done **after** the fact rather than before it, which is the wrong order and is recorded that way:
all four landed on `main` first, and this is the audit that should have preceded them. Symbol-level
on both lines, not file-level — `ls-tree` says the file is there, only `git show origin/<line>:<f> |
grep <symbol>` says the shape is.

| Item | Verdict | The check that decided it |
|---|---|---|
| **Magnitude bars** (Storage rows) | **owed, both lines** | `struct StorageEntryRow`, `case largest, stale, reclaim`, `hoverAffordance`, `report.totalBytes` all present; the lens is reachable — `TidyView.swift` renders `StorageLensView` on both |
| **Sequential treemap ramp** | **owed, both lines** | `TreemapView.swift` carries the *identical* `palette[index % count]` and `labelPalette` this replaces, and `Color.onFillLabel` is there to replace them with |
| **Window subtitle** | **owed, both lines** | `paneLocation(isLeft:drawsColumns:)`, `layoutMode`, `resolvedViewMode(isLeft:)` and `windowStyle(.hiddenTitleBar)` all present |
| **Pins and recents sidebar** | **not owed** | `FolderJumpStore.reachable` and `recentPaths` do not exist on either line, and neither has tabs at all (`PaneTabs*` absent) — so the store's API is different *and* ⌘-click-for-a-new-tab has nowhere to go |
| **The system pasteboard** | **not owed as written** | `clipboardNodes` and `handleCopyToClipboard` are both there, which makes this look portable — but `FileSyncManager.copyItems(nodes:toPath:)`, which the paste path calls, **is not**. The cherry-pick does not compile. Porting it means writing that entry point on each line, which is a rewrite rather than a pick |

**Two of the five look portable and are not, and both needed the symbol check rather than a
reasoned guess.** The sidebar's store API and the pasteboard's copy entry point are the kind of
absence a file-level survey reports as present.

**What the three owed ones cost to land**, because "owed" is not "clean":

- The treemap on both lines has **no fold** — no `TreemapView.fold`, no `labelMinWidth` — so the
  ramp's own doc had to lose the sentence about the fold flooring the smallest tile, and the body
  keeps this line's direct `nodes` iteration. The ramp itself ports unchanged.
- `StorageLensView` here has **no section rail**, so `listSection` keeps its two-argument shape and
  is handed the section's unfiltered list explicitly rather than through `StorageSection.entries(in:)`,
  which is `main`'s. The yardstick rule is identical; only the plumbing to it differs.
- `StorageSection` was **`private`** on these lines and is now internal, so `StorageMagnitude.showsBar`
  can name it. Widening within a module changes nothing visible from outside it.
- The render probe cannot narrow the page to one list without a rail, so it isolates a list by
  **emptying the others** in the fixture — and the fixture's treemap had to go empty too, because a
  page that always draws one has full-width chromatic ink that the bar-edge scan reads as a bar.

## The coverage review's test landings — triaged 2026-08-22

The 2026-08-21 test/log coverage review produced two waves of test landings (P0: data-loss-class
gaps and duplicate removals; P1: unpinned wiring). Every piece was triaged for both lines at
landing time — nothing from these waves is deferred.

**Landed on all three lines** (byte-identical, or deriving from the line's own sources):

- `SyncHistoryStore.defaultFileURL` guard test; the automation rule-removal and dry-run
  start/cancel/clear suites; four duplicate-test removals (each deletion re-verified against the
  line's own superset suite before landing there).
- `OperationNotifier` injectable seams with request + call-site pins, and `OperationBannerView`'s
  extracted `showsUndo`/`showsCountdown` rules — both files were byte-identical across lines
  (v2.x's banner differs by one cosmetic keycap line that the change does not touch).
- The `FileActionDelegate` two-direction wiring anchor and the `ProviderMenu` pins. The anchor
  parses the line's own protocol and sources, so it adapts per line (v2.x's protocol has 18
  requirements to main's 30+ — the non-vacuity floor is deliberately below every line's count).
  `ProviderMenu`'s third pin is adapted on `v2.x` (no Choose Folder… door there, and the line says
  "providers"): see `Adapt the ProviderMenu pins to the 2.x menu` on that line, which carries a
  tripwire to restore the fuller pin if the door is ever backported.

**Main-only by rule, so never owed:**

- The text-editing chord routing (route-through-predicate refactor + the registry-derived
  colliding-chord scan): `MacApp/TextEditingChord.swift` exists on neither maintenance line — the
  ⌘A/⌘X/⌘C/⌘V/transfer menu chords are v4.2+ work.
- `BrowseTabRestorePlan` and its suite: browse tabs are v4.2+; `MacApp/ContentView+PaneTabs.swift`
  is absent on both lines.

**The P2 wave (2026-08-22, same session), triaged the same way.** To all three lines: the Design
raw-value pins and the `AppAppearance.pin` seam + tests (files identical or case sets identical),
the pane-republish skip-fix (identical), and — adapted per line — the condition roll-call and the
review-event totality loop. The adaptation is the point, not a compromise: both suites derive the
"every case" set from the line's OWN enum, so each line's hand list matches its own case set
(`v2.x`/`v3.x` have neither `personIs` nor `unrecognized`, and no `.tabChangedSource`) and a case
added on any line fails that line's scan until listed. Main-only by rule: the `SetupArt.Art`
render-all loop (`MacApp/SetupArtwork.swift` exists on neither line — cherry-pick's rename
detection maps it onto `FirstRunOverlay.swift`, which is a different view; discard that half).

**The P3 wave (2026-08-23, CI-gating structure and the CLI shell), triaged the same way.** To
all three lines: the CLI shell's first test target (`SyncCloudCommand.swift` is byte-identical on
all three; `flushingLogToDisk` opened to internal everywhere) and the Core default-seam test. To
`v3.x` additionally: the `machinePinned` marks for `FolderSourceMarkTests` and
`DetailsWhereItLivesTests`, whose copies there read pixels byte-identically to `main`. Main-only,
each checked rather than assumed: the other six suite marks and the per-test pin conversion (the
suites do not exist on the lines); the `LensHeaderCard` marks (the lines' copies read ZERO pixels
— the pixel reads arrived later); the app-target gate and `layoutMetrics` reason (no
`SyncCloudTests` on the lines, and the reason's only users are main-only suites — note the
`MachinePinned.swift` sibling-list header now differs between main and the lines, so a future
cherry-pick touching that file will conflict on the note: resolve by keeping each line's own
sibling list); and the liveProfile gate-report companions (all three reported suites are
main-only).

**Both parked defect fixes LANDED on all three lines, 2026-08-23.** The `SettingsManager`
salvage (`readSetting`, mirroring folderSources' `.unreadable` preservation) covers five keys on
`main`/`v3.x` and four on `v2.x`, which never carried `folderNameRuleProvider` — checked by key
grep, not assumed. The `PaneBarArrangement` write-back fix (unknown tokens carried through
`encoded`) went to all three lines too: the earlier "pane-bar suites are main-only" reading was
about the TEST suites — the arrangement type and customize sheet, defect included, are on every
line (the file-level check that catches exactly this is what this document exists for). Per-line
adaptations: `v2.x` has no `PaneBarMigration` (it arrived with the search control in 3.x), so its
write-back suite pins the sheet path alone and uses that line's own case names.

## The unaudited surface, honestly

Neither line has been audited commit-by-commit. These are the sizes as of 2026-08-20, narrowing from
raw divergence to plausible debt:

| | `v3.x` (vs `main`) | `v2.x` (vs `v3.x`) |
|---|---|---|
| commits not on this line (`git cherry`) | 504 | 135 |
| …touching ≥1 `.swift` this line carries | 326 | — |
| …touching `Sources/Sync` or `Sources/Settings` it carries | 129 | 51 |
| …and fix-shaped by subject | **96** | **35** |

**A fix-shaped subject touching a shared file is a candidate, not a debt**, and most of these are
not debt. The bulk of `v3.x`'s 96 are "fix N findings from a review of *X*" where *X* is v4 feature
work — the filing router, the household, the Organize restructure — that does not exist on `v3.x`,
so the fix has nothing to apply to. **Read the diff, not the subject**; that distinction is the
whole cost of this audit and the reason the number is not a to-do list.

Regenerate the table with:

```sh
git cherry origin/v3.x origin/main | grep -c '^+'
git ls-tree -r --name-only origin/v3.x > /tmp/v3files
# then: for each candidate, does it touch a file in /tmp/v3files?
```

---

## Recording a decision

Add a row here when a candidate is settled, in either direction — **"checked and not owed" is worth
as much as "owed"**, because the expensive part of this audit was re-deriving that a family was
already present. State the symbol that was checked, not just the verdict; a bare "done" is what
sends the next person back to `git log`.

Move an item out of "owed" only when `git branch -r --contains <sha>` names the line.
