# Backport tracker

What each maintenance line is **owed**, what it is **deliberately not** owed, and how much of the
surface **nobody has looked at**. One file, carried identically on all three lines, so a maintainer
sitting on `v2.x` can see what `v2.x` is missing without reading `main`'s history.

**The rule this tracks changed on 2026-08-26, and this file is now a RECORD rather than a to-do
list.** The standing direction is *no backporting* — land on `main`, given without a scope limit
(`e2b35dad`), and it governs new work generally rather than one batch. What these rows are for is
what a future audit needs if that direction ever changes, and what a maintainer sitting on `v2.x`
needs in order to know what their line actually carries. See [`CLAUDE.md`](../CLAUDE.md).

**So read the status word, not the word "owed".** Rows filed before the direction still say "owed"
in their bodies where they were written that way; the heading is authoritative:

| Status | Means |
|---|---|
| `RECORDED — not owed` | The line carries the defect. It is not being sent, by standing direction. The pick notes are kept because they are the expensive half to reconstruct. |
| `DEFERRED — scope call` | Not simply a direction call: the pick has a prerequisite or a coherence problem of its own, spelled out in the row. |
| `CLOSED` | Settled — sent, or checked and found not to apply. |

"Applies" means *the code is there*, not that a user would notice.

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

**Run stage 1 against `origin/main` too, and require it to find the file.** Both stages answer
"absent" with silence, so a `<path>` you spelled wrong — or that moved between modules since you
last looked — produces a perfect-looking absence on every line at once, and the check you thought
you ran did not run. Item 13 shipped exactly that, citing a `PaneTabStrip.swift` under `Dashboard`
when the strip lives under `FileExplorer`; the verdict happened to be right, which is the reason it
survived review. The positive control costs one command and is the only thing separating "this line
does not have it" from "nothing has it, including the tree I copied the path from".

One shell note, since these checks get pasted into a loop: **zsh does not word-split unquoted
parameter expansions**, so folding a path list into `P="a b c"` and passing `-- $P` sends git ONE
pathspec containing spaces, which matches nothing and reads as absence again. Write the paths out,
or use an array.

---

## `v3.x` — owed

### 1. The `DeleteOutcome` family — DEFERRED, scope call

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

### 2. The filing walkthrough's bare ⏎/→/esc key equivalents, and the review card's unguarded ⏎/⌫ — RECORDED, not owed

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

### 3. The folder-duplicate drift gate rebuilt on per-file snapshots — RECORDED, not owed (filed 2026-08-21)

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

### 4. The copy-undo's shallow folder identity — DEFERRED, scope call (rides item 1)

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

### 5. The classifier's cloud guard knows only iCloud — RECORDED, not owed (filed 2026-08-22)

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

### 6. The four performance items landed on `main` 2026-08-25 — RECORDED, not owed

Not an oversight and not a scope call about whether the code applies: it plainly does. All four touch
files carried on both maintenance lines, and none of them changes behaviour. **They landed on `main`
only by direction** — first for this batch, then generally (`e2b35dad`), which is the standing
direction the header describes and which rows 7–10 were filed under. Recorded here so the next audit
finds a decision rather than a gap.

| Landed on `main` | Files | Note for a later pick |
|---|---|---|
| `Sort the hash index off the actor…` | `ContentHashCache.swift` | Self-contained; moves one `sorted(by:)` from the actor-isolated `adopt` into its `nonisolated` caller |
| `Encode digests with a nibble table…` | new `HexEncoding.swift` + 7 call sites + `HexEncodingTests.swift` | Adds a file, so a pick needs the new file first. `FilingMemory.hash`'s rewrite as `digest.prefix(8)` is the one non-mechanical site |
| `Fold ignore patterns once per scan…` | `IgnoreRules.swift`, `FileSyncManager.swift` | `IgnoreRules.swift` is **byte-identical across all three lines**, so that half picks clean |
| `Carry the thumbnail across the actor hop as a CGImage…` | `DuplicateThumbnail.swift` | Self-contained |

**Expect conflicts, because the direction is backwards from the usual one.** These were written
against `main`, not against the oldest line, which is the shape the working agreement exists to
avoid. Measured 2026-08-25: `FileContentVerifier.swift` differs from `main` by 4 lines on both
maintenance lines, `FileNode.swift` by 13 on `v2.x` and 2 on `v3.x`; `IgnoreRules.swift` is identical
on all three.

None of the four is user-visible on its own — they are scan-time and scroll-time costs — so a line
that never receives them is slower, not wrong. That is the whole reason deferring them was reasonable.

### 7. Three visual-polish items landed on `main` 2026-08-25 — CLOSED, not owed (standing direction)

The sibling of item 6, from the same proposal document. Filed on 2026-08-25 as an open question,
because these three were landed `main`-only by consistency with item 6's instruction rather than by
one of their own, and unlike item 6's four they are user-visible.

**Asked and answered the same day: "No backporting."** Said without a scope limit, in reply to
exactly this question, so it governs new work generally and not just this batch — the maintenance
lines are not being fed right now. That makes the row below a record of what `main` has that the
other lines do not, kept for a future audit's benefit, rather than a to-do list. Item 6 above is
covered by the same answer.

**Do not re-raise this per batch.** The pick notes stay because they cost nothing and they are the
expensive half to reconstruct if the direction ever changes.

| Landed on `main` | Files | Note for a later pick |
|---|---|---|
| `Roll a count that changes instead of cutting to it` | `Pill.swift`, `StatPill.swift` | Self-contained; two `.contentTransition` + `.animation` pairs. Picks clean unless the pill fonts have drifted |
| `Slide the selection markers instead of blinking them` | `ContentView.swift`, `ContentView+Toolbar.swift`, `PaneTabStrip.swift` | **Check the surfaces exist first.** The workspace bar is v4 (`Workspace.allCases`, the four-workspace rail); a line without it can only take the `PaneTabStrip` half |
| `Let the first-run sheet answer the pointer` | `SetupSheet.swift` | **Depends on the radius scale below** — four sites read `Radius.chip`. Either pick that first or substitute the literal `6` |

The fourth item in the batch — `Give the app one radius scale and one overlay elevation` — is
**main-only by rule** and is filed under *Main-only by rule, so never owed* below, not here.

All three are visible to a user, unlike item 6's four: `v3.x` and `v2.x` keep counts that hard-cut,
markers that blink, and a first-run sheet whose controls do not respond to the pointer. That is a
real difference from item 6's "slower, not wrong" — it is why this was worth asking about once, and
it is what the maintenance lines are knowingly keeping.

### 8. Two more performance items landed on `main` 2026-08-26 — CLOSED, not owed (standing direction)

Same standing answer as item 7, so this is a record of what `main` has that the other lines do not,
not a question being re-raised. Both were landed `main`-only without asking, which is what
`e2b35dad` directs. Both apply — checked, not assumed: `v3.x` and `v2.x` each carry `isHiddenPath`
in its original two-line form, an `async applyFilters()` with the detached compute, the ten
`publishedLeftTreeVersion` sites the gate is modelled on, and the reconcile pass itself
(`let liveIds = Set(rawDifferences.map…`, one site on each line).

| Landed on `main` | Files | Note for a later pick |
|---|---|---|
| `Answer "is this hidden?" without allocating…` (`94893347`, corrected by `1e04b131`) | `FileSyncManager.swift`, `FileSyncManagerTests.swift` | Self-contained — one function body plus a new `@Suite`. `SyncCloudCLI` calls it too, so both surfaces get the win |
| `Stop rebuilding an id set and deep-comparing rows…` (`dc9e201b`, `e2ebe5a5`) | `FileSyncManager.swift`, `InFlightSyncStateTests.swift` | Pick the `didSet` counters and `computeFilteredState`'s unconditional `isSyncing` postcondition WITH it — the skip is unsound without that postcondition, and it is a separate hunk in a separate function |

Neither is user-visible on its own: a line that never receives them keeps a filter pass that
allocates per path component and ~5 ms of main-actor work per rebuild. Slower, not wrong — the same
standing as item 6's four.

### 9. The in-flight flag stamped row by row landed on `main` 2026-08-26 — CLOSED, not owed (standing direction)

Same standing answer as items 7 and 8. Recorded because it is the largest user-visible performance
gap of the three, not because the question is open.

`markSyncing`/`clearSyncing` wrote `differences[i].isSyncing` in a loop. `differences` is
`@Published`, so each element write copies the whole array and publishes — O(n·m) main-actor
copying and m `objectWillChange` sends for m rows of n. Measured at 29,000 rows with `m == n`
(what "Sync All" passes): **11,144 ms to mark and 11,107 ms to clear, against 7.9 ms and 7.1 ms**.

| Landed on `main` | Files | Note for a later pick |
|---|---|---|
| `Set the in-flight flag on every row with one write…` (`02429926`) | `FileSyncManager.swift`, `InFlightSyncStateTests.swift` | Applies verbatim — both lines carry the two loops byte-identical to `v4.4`'s. Independent of items 6–8: it touches neither `applyFilters()` nor `isHiddenPath`, so it can be picked alone. The four new tests pin the publish COUNT via `publishedDifferencesVersion`, which `dc9e201b` added — a line without that commit needs the counter or a different observable |

Unlike items 6–8 this one IS user-visible on its own: a line that never receives it keeps a
~22-second main-thread freeze around every bulk sync on a large comparison.

### 10. The filter gate's log line landed on `main` 2026-08-26 — CLOSED, not owed (standing direction)

Observability for item 8's second entry, so it is owed only where that is. Recorded so a line that
ever does take the reconcile skip picks the line that says whether the skip is working with it.

| Landed on `main` | Files | Note for a later pick |
|---|---|---|
| `Say in the log whether the filter gate is skipping anything` (`18fa4cea`) | `FileSyncManager.swift`, `FileSyncManager+Scanning.swift`, `InFlightSyncStateTests.swift` | **Pointless without item 8's reconcile skip** — on a line whose `applyFilters()` still reconciles unconditionally the ratio is `n of n` by construction. Pick the skip first or not at all |

Also recorded here rather than only in the source: the `@Published` O(n·m) publish in item 9 was the
**only** instance. All 100 `@Published` properties across `Modules`, `MacApp` and `SyncCloudCLI`
were scanned for a subscript write or a mutating call inside a loop over the same collection; the
rest are single writes guarded by a `firstIndex` (one COW per call, not per element), and
`duplicateGroups` writes in a loop but only for the one or two groups holding the path. That is a
**checked-and-not-owed for a whole family**, which is the expensive half to re-derive: an audit
reaching item 9 does not need to re-scan for siblings.

### 11. The park-thread budget for the gate flake landed on `main` 2026-08-26 — RECORDED, not owed

Test-only: no production file moved. `main` got a park-thread budget and a `.parksAThread` /
`.parksThreads(n)` trait in `Modules/Sync/Tests/Sync/TestSupport.swift`, declared by the 24 tests
whose gates block a cooperative-pool thread, plus `ParkBudgetTests` (the primitive's two halves, the
budget's, and two adoption scans). It takes a full `Modules/Sync` run from 5 red in 22 to 0 in 22.
See `docs/flaky-tests.md`, *"Every gate parks at once, on the pool their releases need"*.

**This line carries the defect.** `ParkGate` and `FirstStatGate` are in its `TestSupport.swift`
verbatim, and **9 of its test files** reference one of them:

```sh
git ls-tree -r --name-only origin/v3.x -- Modules/Sync/Tests/Sync |
  while read f; do git show origin/v3.x:$f | grep -ql 'ParkGate\|FirstStatGate' && echo $f; done | wc -l
```

**Not a cherry-pick, and the reason is not the one already written down.** The `TestSupport.swift`
half would apply, but a trait nothing declares does nothing, and *which* tests park — and how many
threads each parks — is a property of this line's own test tree. `main`'s two widest reservations
are `.parksThreads(6)` (`FileSyncManagerDuplicatesTests.cancelMidHashRepublishesNoNumericProgress`,
sized by `hashFiles`' six-wide window) and `.parksThreads(4)`
(`BulkSyncCancellationAndReservationTests`' rendezvous); neither number can be assumed on a line
whose hasher and bulk-sync differ. The mechanism's own entry already says the remedy has to be
*written* for a maintenance line rather than copied, on the grounds that `DuplicateBatchRedesignTests`
(the continuation-`Latch` precedent) is absent there — that premise turns out to be beside the point,
since the `Latch` is not the remedy at all for a synchronous seam, but the conclusion holds for this
better reason.

**And this line is owed the mechanism's section before it could be owed the fix.** `v3.x` has no
*"Every gate parks at once"* section — only a note in its own register saying the entry was never
brought forward. Anyone closing that gap should take the Fix section with it.

**How exposed each line is, honestly.** Measured 2026-08-11 and recorded in the mechanism's own
table, `v2.x` passed 4 of 4 full parallel runs at 109 suites — below the threshold, not immune to
it, since it carries the same gates and the same 10 s bound. `main` was at 262 suites when this was
fixed. Neither maintenance line has been re-measured since, so "below the threshold" is a
2026-08-11 fact rather than a current one.

### 12. The source root / landing folder split landed on `main` 2026-08-27 — RECORDED, not owed

A source's root widened from its documents folder to the **account folder**, and where a pane opens
became a separate root-relative `openAt`. `CloudProvider.path` is now `rootPath` + `openAt`, with
`landingPath` composing the two. That reaches the pane trees, the breadcrumb (whose first crumb is
the source picker — the provider capsule is retired), scanning, coverage, the CLI, the ⌘K index and
the Organize lenses.

**Not owed twice over.** It is a breaking model change, which this line does not take by rule, and
the standing direction is no backporting regardless.

**This line carries the old model, verified by shape and not just by file** (2026-08-27):

```sh
git show origin/v3.x:Modules/Sync/Sources/Sync/CloudProvider.swift | grep -c 'var rootPath'   # 0
git show origin/v3.x:Modules/Sync/Sources/Sync/CloudProvider.swift | grep -c 'var path'       # 1
git show origin/v3.x:Modules/Sync/Sources/Sync/PathBoundary.swift  | grep -c 'func join(root:' # 0
git show origin/v3.x:Modules/Sync/Sources/Sync/PathBoundary.swift  | grep -c 'func reanchor'   # 0
git ls-tree -r --name-only origin/v3.x -- Modules/Settings/Sources/Settings/RootsMigration.swift  # absent
```

`PathBoundary.swift` IS here — which is exactly the case the header of this file warns about, where
stage 1 alone reads as "already done". The type predates the split; the two members the split added
(`join(root:relative:)`, `reanchor(_:from:to:)`) are not in it.

**The half a maintainer on this line actually needs, and it is not a gap.** `main` and this line
share the `com.abhishekgirish.SyncCloud` defaults domain, so a machine that runs a v4.6-dev build
and then reinstalls this one is reading keys the newer build has written.

- **Location is safe by construction.** `RootsMigration` only ever *reads* `path_override_<id>` and
  writes `root_override_` / `openAt_override_` beside it. Nothing rewrites or removes the legacy
  key, so this line finds its Location exactly as it left it. That is deliberate and is stated in
  the migration's own doc; this line still reads `path_override_` (1 occurrence in
  `SettingsManager.swift`).
- **Stored positions are not.** The migration rebases the shared root-relative stores — `browseTabs`
  / `browseTabsRight`, `folderJumpPinnedByRoot` / `folderJumpRecentsByRoot`,
  `folderJumpFavoriteOrder`, `destinationRecentsByProvider`, `ignoredItems_v1_<a>|<b>` — so their
  values gain a `Documents` (or `My Drive/Documents`) prefix measured from the account root. Read
  back on this line, whose root IS the documents folder, `Documents/Family` names
  `…/Documents/Documents/Family`, which does not exist. Tabs and pins re-root gracefully — that is
  the existing degrade for a folder that disappeared — and a durable ignore entry simply stops
  matching, which un-ignores rows rather than over-ignoring them.
- **There is no reverse migration and none is planned.** Going back is a supported thing to *do*;
  coming back with your tab positions is not. Worth knowing before diagnosing "my tabs reset" on a
  machine that has tried a v4 build.

Nothing here is a defect on this line. It is filed so an audit that finds `root_override_` or
`rootsModelStamp` in a shared domain knows what wrote them.

### 13. Pane chrome and the scoped refresh landed on `main` 2026-08-27 — split verdict

Three commits landed together and **they do not share a verdict**, which is the point of filing them
as one item: two are unreachable here, one is a defect this line genuinely carries.

| Landed on `main` | Verdict for this line |
|---|---|
| `Give the source chip the size and the disclosure of a control` (`cd96b57d`) | **Main-only by absence** — rides item 12 |
| `Tell apart two tabs that would otherwise read the same` (`f6c02e84`) | **Main-only by absence** — no tab strip here |
| `Walk the pane that moved, not both of them` (`b84806d9`) | **RECORDED, not owed** — this line carries the defect |

**The chip is main-only because the thing it resizes does not exist here.** The source chip *is* the
roots split's replacement for the retired provider capsule, so item 12 disposes of this one too —
verified by shape rather than by file, since `PaneBreadcrumb.swift` itself is present on both lines
(2026-08-27):

```sh
for l in v3.x v2.x; do
  git show origin/$l:Modules/Dashboard/Sources/Dashboard/PaneBreadcrumb.swift |
    grep -c 'sourcePicker\|ProviderMenu\|rootCrumb'      # 0 on both — none of the three
done                                                     # positive control: 13 on origin/main
```

**The tab work is main-only at stage 1**, the rare case where the file check settles it — the whole
pane-tabs subsystem is absent from both lines, not just the file this commit edited (verified
2026-08-27):

```sh
for l in v3.x v2.x; do
  git ls-tree -r --name-only origin/$l -- \
    MacApp/ContentView+PaneTabs.swift \
    Modules/FileExplorer/Sources/FileExplorer/PaneTabStrip.swift \
    Modules/FileExplorer/Sources/FileExplorer/PaneTabStripLadder.swift \
    Modules/Sync/Sources/Sync/PaneTabs.swift \
    Modules/Sync/Sources/Sync/PaneTabsStore.swift \
    Modules/Sync/Sources/Sync/FileSyncManager+PaneTabs.swift
done
```

**Run it against `origin/main` first — it must print all six.** That is the step that would have caught
the mistake below, and it is worth making a habit of for any absence check here: a pathspec that
matches nothing prints nothing, which is indistinguishable from the absence you are trying to
demonstrate. (Pipe it through `wc -l` if you prefer a number: 6 on `main`, 0 on both lines.)

> **This paragraph first shipped citing `Modules/Dashboard/Sources/Dashboard/PaneTabStrip.swift`, a
> path that exists on NO line** — the strip lives under `Modules/FileExplorer`. The verdict was
> right and the evidence was worthless: a `git ls-tree` on a path that is absent everywhere returns
> nothing for a maintenance line exactly as it does for `main`, so the check could not have
> distinguished them. The header's stage-1/stage-2 warning assumes the stage-1 path is real; **spell
> a path wrong and stage 1 stops being a check at all** while still printing like one. Corrected in
> the following commit, and left recorded here because it is a cheaper lesson to read than to repeat.

Note the layering this exposes, which matters to anyone pricing the pick: the strip is a
`FileExplorer` view, its persistence is three `Sync` files, and only the chip-titling this commit
changed is in `MacApp`. A line taking the tab work takes all three modules.

**The refresh scoping is the one that applies, and it applies almost verbatim.** Both lines carry
`syncPathsFromHistory` byte-identical to the `v4.4` shape — including *the two comparisons the fix
reads its answer from*, which are already there deciding whether to write each pane's path and are
already throwing that answer away:

```swift
func syncPathsFromHistory() {
    if leftRelativePath != leftHistory.current { leftRelativePath = leftHistory.current }
    if rightRelativePath != rightHistory.current { rightRelativePath = rightHistory.current }
    refreshSubject.send()          // no payload — so the host honours it as "walk both panes"
}
```

**But the machinery it sends the answer *to* is absent, and that is most of the pick.** `main` gained
`PaneReloadScope` and a scoped `refreshTreesAndScan` with the tab strip, which neither line has:

```sh
git grep -l 'PaneReloadScope' origin/v3.x -- Modules MacApp        # 0 files (same on v2.x; 8 on main)
git grep -n 'func refreshTreesAndScan' origin/v3.x -- Modules      # …+Scanning.swift, NO `reloading:` param
```

So a pick is: the `PaneReloadScope` enum and its `movedPane(isLeft:)`, the `reloading:` parameter on
`refreshTreesAndScan` **together with its union rule** (a narrow request must widen to any wider
refresh already in flight, or a scoped refresh can strand a pane), the `refreshSubject` payload
change and its four `.send(.both)` sites, and `ContentView`'s `onReceive`. `refreshForTabSwitch`,
which is `main`'s other caller and the reason the machinery existed before this commit, has nothing
to apply to and should be left out.

**Do not pick the movement test without the invalidation carve-out.** On both maintenance lines
`resetNavigation` empties both pane trees via `invalidateComparisonState()`, and a source switch
hands the unmoved pane its own current path — so scoped on movement alone that pane's tree stays
`[]` and nothing refills it. A blank pane, from a switch on the other side. Both lines call
`invalidateComparisonState()` from `resetNavigation` the same way, so the hazard picks forward with
the fix. **`main` no longer has that hazard**, and the difference is a later commit, not a
divergence to reconcile here: `resetNavigation` became `retargetPane(isLeft:landing:)`, which drops
only the switched pane's tree, so `RefreshScopeTests`' pinning test now asserts the narrow scope
(`aProviderSwitchWalksOnlyThePaneThatSwitched`) rather than `.both`. A pick onto a maintenance line
takes the `.both` shape, not `main`'s — or takes the scoping commit too.

**How exposed each line actually is.** The cost is a redundant walk of the untouched pane's root on
every navigation — invisible while the prefetch cache is warm, a full second root walk once any file
operation, sort change or force refresh has dropped it. That is a property of tree size, not of
which line you are on, so both are exposed in proportion to the user's data rather than to the
version.

### 14. A source switch on one pane resetting the OTHER — landed on `main` 2026-08-27 — RECORDED, not owed

**Both lines carry this defect, in a worse form than `main` did.** Changing a pane's source reset
the pane the user had not touched: its tree dropped and re-walked (spinner over an unchanged root),
its open Columns stack flattened, its selection cleared, and its Back stack emptied.

`main` shipped `retargetPane(isLeft:landing:)` in place of `resetNavigation`, touching only the pane
whose source changed, plus the differences — which belong to the pair and still go. Verified present
on both lines 2026-08-27; the shape here is `resetNavigation()` with **no landings at all**, so the
untouched pane is not merely reset but sent to its root:

```sh
for l in v3.x v2.x; do
  git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Navigation.swift |
    sed -n '/func resetNavigation/,/^    }/p' | grep -c 'resetBrowsePath'   # 2 on both: both panes
done
```

**What a pick would need**, if the direction ever changes. Only one of the four pieces is here —
checked, because the primitive that looks most likely to be present is the one that is not
(2026-08-27):

| Piece | On the maintenance lines? |
|---|---|
| `resetBrowsePath(isLeft:)` | **present**, already side-scoped — the switch just calls it twice |
| `invalidatePaneTree(isLeft:)` | **absent** on both, everywhere: `git grep -c invalidatePaneTree origin/<line> -- Modules MacApp` is empty. `invalidateComparisonState` clears both trees inline, so the side-scoped tree drop has to be extracted first |
| `PaneReloadScope` and the scoped `refreshTreesAndScan` | **absent** — see item 13, the same prerequisite |
| the landings (`leftLanding:`/`rightLanding:`) | **absent** — `resetNavigation()` takes none; rides item 12's Open-at work |

So it rides items 12 and 13, and taking it alone would give the untouched pane its state back while
still re-walking its root on every switch — the visible half fixed, the cost left in. Two callers on
each line (`ContentView`'s two provider `onChange`s) plus `undoProviderPin`, which on `main` had to
grow its own re-home once the caller's reset stopped covering it; expect the same here.
### 15. Recents stops repeating the Locations rows — landed on `main` 2026-08-27 — CLOSED, not owed

Switching a pane to a source lands it on that source's `openAt`, and the landing was recorded as a
visit like any other — so with seven sources connected, six of the eight rows in the sidebar's
**Recents** section named folders the **Locations** rows directly above already take you to
(`Documents` under Dropbox, `Documents` under two OneDrive accounts, `My Drive` under two Drive
accounts). Measured on the live store that day: 6 of 7 stored recents were landings. The fix
subtracts each root's landing inside `FolderJumpStore.mostRecentAcrossRoots`, alongside the
favorites subtraction that was already there and for the same reason — and, critically, *before* the
cap, so the eight rows count only rows worth having.

**Unreachable on both lines, twice over** (verified 2026-08-27; the positive control is the `main`
column, which must be non-zero for every row before the zeros mean anything):

| checked | `main` | `v3.x` | `v2.x` |
|---|---|---|---|
| `Modules/Dashboard/Sources/Dashboard/FolderSidebar.swift` present | 1 | 0 | 0 |
| `mostRecentAcrossRoots` in `FolderJumpStore.swift` | 5 | 0 | 0 |
| `visitedAt` in `FolderJumpStore.swift` | 12 | 0 | 0 |
| `var openAt` in `CloudProvider.swift` | 1 | 0 | 0 |

One line per row of the table, in its order — a combined `grep -c 'a\|b'` prints their SUM (17
here) and would not match anything the table says:

```sh
for l in main v3.x v2.x; do
  git ls-tree -r --name-only origin/$l -- Modules/Dashboard/Sources/Dashboard/FolderSidebar.swift | wc -l
  git show origin/$l:Modules/Dashboard/Sources/Dashboard/FolderJumpStore.swift | grep -c 'mostRecentAcrossRoots'
  git show origin/$l:Modules/Dashboard/Sources/Dashboard/FolderJumpStore.swift | grep -c 'visitedAt'
  git show origin/$l:Modules/Sync/Sources/Sync/CloudProvider.swift | grep -c 'var openAt'
done
```

There is no Recents *section* on either line — the sidebar is v4.4 — and no landing folder for it to
subtract: `openAt` arrived with the roots split, item 12. `FolderJumpStore` itself IS on both lines
(it backs the pane's jump menu and ⌘K), but its recents are per root and undated there, so the
global list this rule filters does not exist to be filtered. **A line that took the sidebar would
have to take item 12 first, and then this comes with it.**

### 16. The tab strip's grey/accent ladder — landed on `main` 2026-08-27 — CLOSED, not owed

Every chip in a pane's tab strip now wears the grey slab that used to be the active tab's alone, and
the live chip takes the accent wash on top of it — `PaneSelectionWash`, literally the constant the
pane's selected ROWS use, so a tab and a row answer "which one is selected" in the same colour and
dim together (0.22 focused, 0.10 in the other pane). The 2pt accent rule stays and deliberately does
not dim: it is what still answers "which tab" in the pane whose border has stopped answering "which
pane". Two defects went with it — the hover wash was a `Capsule` over a 6pt rounded-rect chip, and
the strip's accent was `Color.accentColor`, the SYSTEM accent, so the rule drew blue inside a green
window.

**Unreachable on both lines: there is no tab strip there at all** (verified 2026-08-27; the `main`
column is the positive control, and must be non-zero for every row before the zeros mean anything):

| checked | `main` | `v3.x` | `v2.x` |
|---|---|---|---|
| `Modules/FileExplorer/Sources/FileExplorer/PaneTabStrip.swift` present | 1 | 0 | 0 |
| files mentioning `PaneTabStrip` anywhere under `Modules`/`MacApp` | 9 | 0 | 0 |
| `PaneSelectionWash` in `PaneListSelectionStyler.swift` | 2 | 2 | 2 |
| `paneActionBarSideActive` in `MacApp/ContentView+Toolbar.swift` | 3 | 2 | 2 |
| `shape: HoverAffordanceShape?` in `HoverAffordance.swift` | 1 | 1 | 1 |

One line per row, in the table's order — a combined `grep -c 'a\|b'` prints their SUM and would not
match anything the table says:

```sh
for l in main v3.x v2.x; do
  git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PaneTabStrip.swift | wc -l
  git grep -l 'PaneTabStrip' origin/$l -- Modules MacApp | wc -l
  git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PaneListSelectionStyler.swift | grep -c 'PaneSelectionWash'
  git show origin/$l:MacApp/ContentView+Toolbar.swift | grep -c 'paneActionBarSideActive'
  git show origin/$l:Modules/Design/Sources/Design/HoverAffordance.swift | grep -c 'shape: HoverAffordanceShape?'
done
```

**The last three rows are why this is worth a row rather than a shrug.** Both maintenance lines
carry `PaneSelectionWash`, `paneActionBarSideActive` and the hover-affordance shape override — every
ingredient — and neither carries a tab strip to spend them on. Tabs are v4: `PaneTabStrip` is
reachable from nine files on `main` and none on either line, so there is no surface here to restyle
and nothing to re-derive next time. `main`'s 3 for `paneActionBarSideActive` against 2 is this
commit's own addition, `paneWearsActiveAccent` — the one predicate the strip and the rows now share
so they cannot come to name different panes.

### 17. The destination picker's rows wore a capsule affordance — landed on `main` 2026-08-27 — RECORDED, not owed

**Unlike item 16, this one is fully present here.** The tab strip is v4-only, so its half of the
same defect was unreachable; `DestinationPicker.swift` is on all three lines and carries the bug
verbatim. All three of its row surfaces — the locations rail row, a column row, and a search result
row — draw a 6pt rounded-rect ground and hand `HoverAffordanceStyle` no `shape:` at all, so each
takes the variant default, which is a **capsule** for `.segment` *and* for `.filled`. A chosen row
therefore wears a rounded-rect accent fill under a pill: hovered, a wash whose ends pull 14pt in on
a 28pt row; selected, a hairline ring tracing that pill around the rectangle. The two outlines
disagree over 732 pixels of a 220×28 row, measured in `HoverAffordanceOutlineTests`.

**Two of the three were invisible to the audit's own grep.** `grep 'hoverAffordance(\.segment'` — the
instrument the audit started from — finds 18 of the 26 `.segment` call sites in the tree, because
eight spell the variant `isSelected ? .filled : .segment`. The rail row and the result row are two
of those eight. `grep 'hoverAffordance(' | grep '\.segment'` finds all 26; use that one here.

**Portable in principle, and not free** (verified 2026-08-27). `main` is measured **before** this
commit, so its column is a positive control for the DEFECT rather than for the fix: rows 1–5 must be
non-zero on `main` or the grep is looking in the wrong place and the other columns mean nothing.
The last row is the exception and is meant to read zero everywhere — it is the thing this commit
adds, listed so a later audit can see what a pick would have to bring with it:

| checked, in `DestinationPicker.swift` unless noted | `main` (pre-commit) | `v3.x` | `v2.x` |
|---|---|---|---|
| file present | 1 | 1 | 1 |
| `.segment` call sites (any spelling) | 3 | 3 | 3 |
| …handed an explicit `shape:` | 0 | 0 | 0 |
| 6pt rounded-rect grounds drawn | 7 | 7 | 7 |
| `shape:` parameter exists in `HoverAffordance.swift` | 1 | 1 | 1 |
| `Radius.chip` in `Design/GeometryScale.swift` | 1 | **0** | **0** |
| `HoverAffordanceOutline` in `HoverAffordance.swift` | 0 | 0 | 0 |

```sh
for l in main v3.x v2.x; do
  git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/DestinationPicker.swift | wc -l
  git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DestinationPicker.swift | grep 'hoverAffordance(' | grep -c '\.segment'
  git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DestinationPicker.swift | grep -A2 'hoverAffordance(' | grep -c 'shape:'
  git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DestinationPicker.swift | grep -cE 'RoundedRectangle\(cornerRadius: (Radius\.chip|6),'
  git show origin/$l:Modules/Design/Sources/Design/HoverAffordance.swift | grep -c 'shape: HoverAffordanceShape?'
  git show origin/$l:Modules/Design/Sources/Design/GeometryScale.swift | grep -c 'static let chip'
  git show origin/$l:Modules/Design/Sources/Design/HoverAffordance.swift | grep -c 'HoverAffordanceOutline'
done
```

**The last two rows are the cost, and they are why this is not a clean pick.** The `shape:` override
this needs has existed on both lines all along (row 5) — the one-line form of the fix would apply
here today. But the commit does not take the one-line form: it adds `HoverAffordanceOutline` to
`Design` and has each control name its outline ONCE, handing the same value to the ground it fills,
the hit area it declares and the style. That is the part that stops a fifth instance, and it is a
new public type on a line that has none (row 7). `Radius.chip` is `main`-only too (row 6) — the
lines spell the radius as a bare `6` seven times over — so a pick would either drag
`GeometryScale.swift` along or degrade to `.roundedRect(6)` literals, which is the very drift the
change exists to remove. **Not owed: the standing direction is no backporting.** If it is ever
authorised, take `HoverAffordanceOutline` and `GeometryScale` first, in that order, or the fix
arrives as three more copies of a number.

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

**The whole-volume source named `/` — sent to `v3.x` as `f86ee70b`, 2026-08-25.** Found owed by
the v4.4 release review: `FolderSource.defaultDisplayName`'s pre-fix fallback was verbatim on this
line, so a source over the startup disk read `/` in the pane header capsule, ⌘K and Settings. The
cherry-pick of `main`'s `08d652af` carried one adaptation — the test pinning that the name reaches
a pane TAB stays on `main`, because `PaneTab` does not exist here (the test file says so where the
test would have been). Not owed to `v2.x`: the file is absent there.

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

- **The folder sidebar's default Favorites, and its single-line Recents rows** (2026-08-27). Home
  and the startup disk joined `SidebarFavoritePlaces.standard`, and a recent row stopped drawing a
  second line. **Neither line carries the surface at all** — the folder sidebar is a v4.4 feature —
  so there is nothing on `v3.x` or `v2.x` for either change to apply to. Checked, conclusively, and
  it costs one command:
  ```sh
  for l in v2.x v3.x; do git ls-tree -r --name-only origin/$l -- \
    Modules/Dashboard/Sources/Dashboard/SidebarSources.swift \
    Modules/Dashboard/Sources/Dashboard/FolderSidebar.swift \
    MacApp/ContentView+FolderSidebar.swift; done   # prints nothing on both
  ```
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
- **The `Radius` / `Space` scales and `overlayShadow`** (2026-08-25). A restructure by definition:
  it introduces a design-system vocabulary and rewrites 80 call sites onto it, and 28 of those
  deliberately move by 1pt to collapse near-duplicate radii. Nothing is broken on a maintenance line
  without it — those lines simply keep the eleven hand-written radii, which is a tidiness cost, not
  a defect. Porting it would mean re-styling a shipped release to no user benefit. Symbols if this
  is ever revisited: `Radius`, `Space` and `View.overlayPanelShadow()` in
  `Modules/Design/Sources/Design/GeometryScale.swift`. Note that `v3.x` item 7's setup-sheet pick
  depends on `Radius.chip`, so taking that one means substituting the literal.
- **The Tint slider becoming the app's one hue-strength knob** (v4.4). The defect it fixes is
  genuinely present on both maintenance lines and was checked symbol by symbol, which is why this
  row is here rather than absent: `origin/v3.x` and `origin/v2.x` both carry
  `contentSurface`'s `hue.accentColor.opacity(clamp(tint) * 0.32)`, both carry
  `liquidGlassAppBackground(level:hue:)` with no tint parameter, and both carry the Settings slider
  (`Slider(value: $surfaceTint, in: 0.0...1.0)`) — so on those lines too, Tint 0 paints nothing
  while the window keeps the accent at full strength. It is still main-only, because the fix is a
  re-tune of what **every** install looks like at its stored setting, and a maintenance line takes
  no behaviour changes. A 2.x user who has never touched the slider would open a visibly different
  app after a patch release.
  The half that is *not* portable at all is the tab-strip wash: `PaneTabStrip.swift` is absent from
  both lines (`git ls-tree -r --name-only origin/v3.x -- …/PaneTabStrip.swift` returns nothing), so
  there is no stripe to fix there.
  Symbols to check if this is ever revisited: `LiquidGlass.tintFloor` and
  `LiquidGlass.backgroundHueStrength(forTint:)` in `Modules/Design/Sources/Design/LiquidGlassStyle
  .swift`. Checked 2026-08-25.
- **The large-folder budget family** (v4.4): `NodeBudget`, the pane walk's `paneNodeBudget`, the
  on-demand column graft, the partial-comparison banner, and `LargeWalkPreflight`'s ask-first
  gates. The defect they answer is genuinely present on both maintenance lines — both carry
  `FileSyncManager+Scanning.swift` with an unbounded deep walk (`NodeBudget` greps to zero on
  each), so a pane pointed at `~` or a whole volume still hangs there. Main-only by rule all the
  same: this is a feature-sized redesign — new public types, new UI (the banner, the preflight
  prompt, column captions), and a change to what every pane shows over a large source — not a
  patch a maintenance line can take without becoming a different app. A maintenance-line user's
  mitigation is the one they already have: point sources at folders, not at `~` or `/`. Recorded
  in both directions so the next audit of `06700fce`/`2481ac24`/`8ba64f29`/`b7d208e8` and their
  review fixes does not re-derive this. Filed 2026-08-25.
- **`contentContains` unified to one substring semantic** (`416ecd64`, 2026-08-25). The
  two-semantics defect is genuinely present on both maintenance lines — each carries the
  token-subset fallback (`isSubset(of: facts.contentTokens)` in `AutomationEvaluator.swift`
  greps to 1 on both), so on those lines too the Organize scan can move a file the Automations
  preview said would not match. Main-only by rule all the same: removing the fallback changes
  which files EXISTING rules move on a user's real tree, which is a behaviour change a
  maintenance line does not take. His call, made 2026-08-25, for the v4 line only.
- **The folder sidebar family** (v4.4, `cfe0dae8..3650a68e` and the review fixes after): a new
  feature end to end. The one shared file it touches is
  `Modules/Dashboard/Sources/Dashboard/FolderJumpStore.swift`, checked symbol-level when Stage B
  landed (recorded then only in `5391c685`'s commit body, which is what this row fixes):
  `visitedAt`, `favoriteOrder`, `recentVisitsAcrossRoots` and the sidebar's decode tolerance are
  all additions serving sidebar features neither line draws — nothing behind them is a fix those
  lines' own jump menus are missing. Filed 2026-08-25.
- **The "None" accent's white ground in light** (v4.5 draft). `LiquidGlass.noneLightVeil` and a
  light-only `Color.white` paint in `LiquidGlassBackground`, so "None" reads white rather than
  the material's gray — which sat within a couple of points of Graphite's neutral wash at low
  Tint. The ambiguity is arguably present on the lines too (both carry `.graphite` and a `.none`
  that paints nothing — `noneLightVeil` greps to zero on each), but this is the Tint-slider
  precedent above verbatim: a re-tune of what every install's stored setting looks like, and a
  maintenance line takes no behaviour changes. A user who chose None on 3.x would open a visibly
  whiter app after a patch release. Filed 2026-08-25.

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

### The folder-duplicate drift gate — RECORDED, not owed (filed 2026-08-21)

Owed here exactly as to `v3.x` — see item 3 under **`v3.x` — owed** for the three defects, the
symbol checks, and why it is a scope call rather than a cherry-pick. `v2.x` carries
`folderDriftedInPlace` and the existence-only directory verdict too, and its "provider" vocabulary
means the `MacApp/` half will need adaptation, not a pick.

### The copy-undo's shallow folder identity — DEFERRED, scope call (rides `v3.x` item 1)

Owed here exactly as to `v3.x` — see item 4 under **`v3.x` — owed**. `v2.x` carries the shallow
`case directory(modified:childCount:)` too (symbol-checked). Unlike `v3.x` this line has the
`DeleteOutcome` family, so the port is closer to a pick here — but the undo file has drifted, so
verify `deepSnapshot`'s seams before assuming.

### The classifier's cloud guard knows only iCloud — RECORDED, not owed (filed 2026-08-22)

Owed here exactly as to `v3.x`, and **this is the line to fix first** — see item 5 under
**`v3.x` — owed** for the mechanism, the symbol checks and the seam that has to come with it.
`v2.x` carries the byte-identical `isEvictediCloudFile` at `MacApp/ContentSignalExtractor.swift:122`
and the same seamless `MaterializationStatus.isCloudOnly(atPath:)`. No vocabulary adaptation is
needed: the change is inside a private function and touches no user-facing copy.

### Settled: the QuickLook scan's character-budget window — sent as `2f34f9b4`, 2026-08-25

Found owed by the v4.4 release review. `QuickLookOriginTests` read the pane's `FileTreeView` call
through `prefix(4_000)`; on `main` two new parameters pushed `onQuickLook:` past the window and the
suite went red blaming the wiring — `b7d208e8` replaced the window with the balanced
`argumentList(after:in:)`, and this line carried the identical window one signature-growth from the
same false red. Test-only, so it goes to every line carrying the file; `v3.x` does not carry it.
Verified with a full app-target run on this line (295 tests, 28 suites, green).

### The four performance items landed on `main` 2026-08-25 — RECORDED, not owed

Same entry as `v3.x` item 6 above, and owed on the same terms — see it for the commit list, the
per-file pick notes and the measured divergences. Deferred by his decision on 2026-08-25, not by a
judgement that the code does not apply: it does, on every one of the four files.

### Three visual-polish items landed on `main` 2026-08-25 — CLOSED, not owed (standing direction)

Same entry as `v3.x` item 7 above — see it for the commit list and the per-file pick notes.
**Closed by his standing "No backporting" of 2026-08-25**, given in reply to this exact question and
without a scope limit, so it covers new work generally. The notes below are a record of the gap, not
a plan to close it.

Two extra notes for this line specifically. The workspace bar the marker-slide half targets is a v4
surface, so check `Workspace.allCases` exists here before planning that pick at all. And the setup
sheet's hover conversion reads `Radius.chip` at four sites, which does not exist on this line —
substitute the literal `6` or take the radius scale first, and the radius scale is main-only by rule.

### Two more performance items landed on `main` 2026-08-26 — CLOSED, not owed (standing direction)

The `v2.x` half of item 8 above, and the same verdict. `v2.x` carries both prerequisites — the
original `isHiddenPath` expression and the reconcile pass in `applyFilters()` — so both would apply;
neither is being sent. Pick notes are in item 8; the second of the two must not be picked without
`computeFilteredState`'s unconditional `isSyncing` postcondition, which is what makes its skip sound.

### The in-flight flag stamped row by row landed on `main` 2026-08-26 — CLOSED, not owed (standing direction)

The `v2.x` half of item 9 above, and the same verdict. `v2.x` carries both loops byte-identical to
`v4.4`'s, so it applies verbatim; it is not being sent. Pick notes are in item 9. This is the one
item in the 2026-08-25/26 run that a `v2.x` user would actually notice — the rest are slower, not
wrong; this one freezes the window for about eleven seconds at each end of a bulk sync.

### The Reduce Motion `withAnimation` gap landed on `main` 2026-08-26 — CLOSED, not owed (standing direction)

Four animations that only a `withAnimation` was driving now honour the setting: the expanding
search field's reveal, Browse's folder sidebar, an Activity Log run's disclosure, the Differences
count pills.

**Applies to neither maintenance line as written, and the reason is worth recording rather than the
verdict.** The fix depends on `designAnimation`/`withDesignAnimation`, which are `main`-only — the
whole wrapper arrived in this release — so a pick would have to take the wrapper, its rule type and
both coverage scans first. What DOES exist on `v3.x` and `v2.x` is the underlying defect: check
`ExpandingSearchField`, `LogViewer`'s run disclosure and `DifferencesView`'s count pill on either
line and the raw `withAnimation` is there, ungated. A line that wanted this without the wrapper
would write `reduceMotion ? nil : …` at each site, which is four small edits and no new API.

Browse's folder sidebar is `main`-only regardless: the sidebar itself shipped in v4.4.

### The park-thread budget for the gate flake landed on `main` 2026-08-26 — RECORDED, not owed

Same item as `v3.x` #11, and the same verdict for the same reason: the trait is worthless without
per-test declarations, and which tests park how many threads is a property of this line's test tree,
not of `main`'s. `ParkGate` and `FirstStatGate` are both here, referenced by **9 test files**.

What differs from `v3.x`: this line already carries the mechanism's section (its number 10), so the
Fix section could be written into it directly — but it would then describe a remedy the line does
not have, which is worse than the gap. Take both or neither.

Its own measurement is the one the mechanism cites: 4 of 4 full parallel runs green at 109 suites on
2026-08-11, i.e. below the threshold rather than immune to it. Not re-measured since.

### The source root / landing folder split landed on `main` 2026-08-27 — RECORDED, not owed

Same item as `v3.x` #12, same verdict, same two reasons: a breaking model change this line does not
take by rule, and the standing direction is no backporting regardless. Verified the same way on
2026-08-27 — `CloudProvider` has `var path` and no `var rootPath`, `PathBoundary.swift` is present
but carries neither `join(root:)` nor `reanchor`, and `RootsMigration.swift` is absent.

The shared-defaults-domain consequence written out under `v3.x` #12 applies to this line
identically, and is the part worth reading: Location survives a round trip because the migration
never rewrites `path_override_`, while tab, pin, recent, destination and durable-ignore positions do
not, because their values are rebased onto the account root that this line has no notion of.

### A source switch on one pane resetting the OTHER — landed on `main` 2026-08-27 — RECORDED, not owed

Same item as `v3.x` #14, same verdict, same shape: `resetNavigation()` here takes no landings, so a
source switch on one pane sends the OTHER pane to its root — tree re-walked, Columns stack
flattened, selection cleared, Back stack emptied. Verified on `v2.x` 2026-08-27 with the same
`resetBrowsePath` count (2, both panes). Of the pieces a pick needs, only `resetBrowsePath(isLeft:)`
is here — `invalidatePaneTree(isLeft:)` and `PaneReloadScope` both grep to nothing — so it rides
items 12 and 13 exactly as on `v3.x`. Not owed: the standing direction is no backporting.

### Recents stops repeating the Locations rows — landed on `main` 2026-08-27 — CLOSED, not owed

Same item as `v3.x` #15, same verdict, and the same table settles it — this line's column is zero on
every row of it. No folder sidebar, so no Recents section; no `openAt`, so no landing to subtract.
`FolderJumpStore` is here and backs the pane's jump menu, but its recents are per root and carry no
`visitedAt`, which is what the global cross-source list is built from.

### The tab strip's grey/accent ladder — landed on `main` 2026-08-27 — CLOSED, not owed

Same item as `v3.x` #16, same verdict, and the same table settles it — this line's column matches
`v3.x`'s on every row. No `PaneTabStrip.swift` and not one file anywhere under `Modules` or `MacApp`
that names it: tabs are v4, so there is no strip here whose chips could take a ground. What this
line DOES carry is every ingredient — `PaneSelectionWash`, `paneActionBarSideActive`, and
`HoverAffordance`'s `shape:` override — which is the part worth recording, because a future audit
grepping for those will find them all present and could easily read that as "already here".

### The destination picker's rows wore a capsule affordance — landed on `main` 2026-08-27 — RECORDED, not owed

Same item as `v3.x` #17, same verdict, and **this line's column of that table is identical to
`v3.x`'s on every row** — the file is here, all three of its `.segment` row surfaces are here, none
of them is handed a `shape:`, and the seven 6pt rounded-rect grounds are here too. So the defect is
present and the one-line form of the fix would apply, because the `shape:` override has existed in
`HoverAffordance.swift` on this line all along.

Recorded rather than shrugged off for the reason item 16's entry gives about ingredients: a future
audit grepping this line for `shape: HoverAffordanceShape?` will find it present and could easily
read that as "already fixed here". It is not — the parameter is present and **unused at all three
call sites**. The one row that differs from `main` is `Radius.chip`, which is not here at all, so a
pick would have to bring `Design/GeometryScale.swift` or degrade to seven `6` literals; and
`HoverAffordanceOutline` is what the commit itself adds, so it is absent from every line including
`main` before it. Those two together are what make this more than a one-line pick. Not owed: the
standing direction is no backporting.

### Nothing else confirmed

Every safety family above is present on `v2.x`, and it is the line the `DeleteOutcome` family
landed on first. Apart from the park-thread budget and the source-root split recorded above —
neither of them owed — no other confirmed fix debt was found by the 2026-08-16 audit or this one.
(Named rather than "the entry just above": that phrasing pointed at whichever row happened to be
last, and adding one silently re-pointed it.)

### Checked and NOT applicable

- **Storage lens preservation.** `Modules/Sync/Sources/Sync/StorageLensStore.swift` does not exist
  on `v2.x` at all — the lens is a 3.x-and-later feature. Stage 1 answers this; there is nothing to
  port to.
- **The text-size percentage and the Readability tab.** Main-only by rule for the same reasons
  spelled out under `v3.x` above — a public type changing shape, a stored default changing with it,
  and a new Settings tab. Nothing here is a fix `v2.x` is missing.
- **The Tint slider becoming the app's one hue-strength knob.** Main-only by rule, for the reason
  written out under `v3.x` above — the wash formula and the untinted background *are* both here, so
  this is a decision rather than an absence, and the reasoning is worth reading before re-deriving
  it. Checked 2026-08-25.
- **The large-folder budget family and the folder sidebar** (v4.4). Main-only by rule for the
  reasons written out under `v3.x` above; the unbounded deep walk is present here too
  (`NodeBudget` greps to zero), and the same mitigation applies. Checked 2026-08-25.

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
— the pixel reads arrived later); the app-target gate and `layoutMetrics` reason (both lines DO carry a
`SyncCloudTests/` target — this entry first said they don't, which was false — but neither line's
app suites read pixels, so the gate has nothing to gate there, and the reason's only users are
main-only suites — note the
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

**The log tier (2026-08-23, the coverage review's second half), triaged the same way.** To all
three lines: the banner→log choke point (`FileSyncManager.banner` didSet; `OperationBanner`
carries the per-publish `id` the dedup needs on all three) with `BannerLogChokePointTests`; the
two cross-volume permanent-delete lines and the revert report in `FileOperations+Primitives.swift`
(all three lines carry the `replaceItem` rewrite, so the hunks anchor cleanly); the Verify All
lifecycle lines; the history-clear line at `SyncHistoryView.clearIfConfirmed` — at the CONFIRM,
not inside `SyncHistoryStore.clear()`, which reddened main's CI once (fixture cleanups vs
Logger's exact-count suite in the same package); the `TopPaneVisibility` and `FolderJumpStore`
encode-failure lines (the lines' jump store has only `persistPinned` — recents arrived later);
the scroll-probe pull-log gating behind `PaneScrollTrace.isEnabled` (`v2.x`'s OverscrollReturn is
NEWER than `v3.x`'s there — it has the `pullDuration` structure — so the gate was fitted per
line); the `[hitch]` armed-line demotion; the two cancelled-at-the-prompt promotions to `.info`;
and the Quit-Anyway rewording. To `v3.x` additionally: the `folderSources` encode guard in
`SettingsManager` (`v2.x` has no `folderSources` — plain-folder sources are a 3.x feature) and
the `[cycle]` armed-line demotion (`DisplayCycleTrace` is not on `v2.x`). Main-only, each
checked: `PaneTabsStore`'s encode-failure line (tabs are v4), and every
"Settings ▸ Organize"→"Intelligence" copy correction (the lines have no Intelligence tab; their
strings name the tab that really holds their key — do NOT backport these). Checked and
deliberately NOT changed anywhere: the per-item "Replaced … recoverable" `.info` breadcrumb (its
comment defends the level) and the Duplicates same-instance warning the review had called dead
(rewritten since into a documented fail-open guard).

**The adversarial-review fix pass (2026-08-23), triaged as it landed.** The review of the
coverage waves produced fixes on `main` (`4d233141..f2e0c26d`); the line-portable subset landed
on both lines the same day: the delegate-existential walk widening and ProviderMenu scan
hardening (v2.x keeps its reduced no-door variant, count ban only), the banner countdown routed
through its tested rule plus the ingredient-pair re-inline bans, the notifier pin's comment
stripping, the appearance-scan body scoping, the dry-run clear-abandonment test, the reducer
tabSwitched combo-count pin, the CLI sync-subcommand parse pins and Trash sweep, and the two
Design doc corrections. The lines' `MachinePinned` copies gained the `layoutMetrics` case (each
keeping its own sibling list), because their `LensHeaderCardTests` measure exact heights — that
reason, not `pixelSampling`, which their copies earn nowhere. To `v2.x` alone:
`PaneScanningPlaceholderRenderTests` marked `pixelSampling` — the one per-line divergence in that
family, unmarked here while main's byte-similar copy has carried the mark since it existed. To
`v3.x` additionally: the pixel/layout pins for the seven reader files this line shares with main
(`PaneHeaderSearch`, `DuplicateReveal`, `PaneColumnCarryOver`, `PaneSearchRow`, `HomeOnlyBadge`,
`StorageMagnitude`, `RiskyNameBadge`, plus the `FolderSourceMark`/`DetailsWhereItLives`
suite→per-test conversions). Main-only, each checked: the chord-scan splitter hardening (v4
surface), the gate-report trait binding and ground-truth `.enabled(if:)` (suites absent), the
restore-plan tests (v4), and the pixel pins for files the lines do not carry.

**The flake-fix pass (2026-08-23) is main-only, checked rather than assumed.** The merge-sampler
rendezvous (`MergeUndoGroupingAndGateTests`) and the pid-scoped test pasteboards
(`SystemClipboardTests`, `FileActionHandlerOperationTests.scratchPasteboard`) fix tests that exist
on `main` alone: neither suite is on either line, and the lines' `FileActionHandlerOperationTests`
predates the clipboard feature and constructs no pasteboard at all (grep for `NSPasteboard(name:`
comes back empty on both). The flaky-tests.md mechanism entries ("the control that stops an
absence being vacuous", "a named NSPasteboard is machine-global") stay main-only for the same
reason — each line's copy of that doc carries only the mechanisms with an instance on that line.

**The banner-suite eviction fix (2026-08-24) went to all three lines, oldest-first.**
`BannerLogChokePointTests` was byte-identical on every line (the log tier put it there), so its
defect was too: it asserted a cumulative level sequence over `Logger.shared.entries`, which the
newest-1000 trim evicts the front of during a parallel package run. Landed on `v2.x` first
(`52242ad4`), cherry-picked to `v3.x` (`c9c0beaf`) and `main` (`b895c3cd`). **The maintenance
lines needed one extra hunk**: `logLines(tag:during:)` did not exist in their
`Modules/Sync/Tests/Sync/TestSupport.swift` and was backported with the fix (their `Logger`
already carries `logFileURL` and `flushToDisk`, checked rather than assumed, and their
`TestSupport` gained `import Events` for it). `main` needed only the suite. `loggedLineOnDisk`
was NOT backported — nothing on the lines calls it; take it when something does. The mechanism's
\"growing window\" paragraph in `docs/flaky-tests.md` (`aa9620ff` here) went to both lines with
it (`6a9d8d64`, `ef4c555f`), since the instance it describes was on every line; the section that
hosts it is present on all three and only its NUMBER differs.

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

## 2026-10-17 — the `v5.x` line opens; `main` moves to 6.0-dev

`v5.x` was cut from the `v5.5` tag when `main` opened the v6 line. Nothing lies between the tag and
the cut, so `v5.x` starts with everything `main` shipped as v5.5 and owes nothing; from here, `main`'s
v6 work is a feature line under the no-backport standing direction, and its fixes are recorded here
as for the other lines. `v5.x`'s opening commit re-bumps it to `5.6-dev`/`506` and carries the
five-line documents (CLAUDE.md, the CI workflow, this record) — checked, nothing else in that range.

## 2026-08-28 — the `v4.x` line opens; v5.0 lands on `main`

`v4.x` was cut from the `v4.6` tag when the v5.0 Organize work landed on `main`. Recorded, not
owed: **none of the maintenance lines carries any of the v5.0 Organize system** (the
`RestructureStore`/planner/apply/undo family, the Restructure lens surfaces, `synccloud
restructure`, and the §12 Duplicates header rework) — a feature line under the no-backport
standing direction, not a fix. The two commits `main` carried between the `v4.6` tag and the cut
(`68c71c62`, the 4.7-dev re-bump, and `05d11f5f`, the fourth-branch doc fix) are superseded on
`v4.x` by its opening commit, which re-bumps to `4.7-dev`/`407` and carries the four-line
documents — checked, nothing else in that range.

### The Help book's v5.0 pass — checked, not owed

`MacApp/HelpBook.swift` grew the Organize section from six topics to nine and corrected seven
claims in articles the release did not add. **None of it is owed to a maintenance line, and the
second half is the interesting reason why.**

The three new articles — *Plan a new shape*, *Apply, and take it back*, *Set up a new year* —
describe machinery no maintenance line carries, so they have nothing to apply to. That much is the
same verdict as the feature above them.

**The corrections are corrections of v5.0's own consequences, so the sentences they replace are
still true on the lines without v5.0.** `what-is-synccloud`'s "every action can be undone with ⌘Z",
`undo-redo`'s "the one thing undo cannot reach", `staying-safe`'s "the one exception" and
`sync-history`'s "Every copy, move, and delete is recorded" all became wrong *because* `applyPlan`
started moving files outside `recordSyncHistory` and outliving its own ⌘Z. On `v4.x`, `v3.x` and
`v2.x` nothing does that, so each sentence is accurate there and backporting the fix would make
the copy wrong. Likewise `intelligence`: "Both routes" is the correct count on a line with two
paid routes, and only v5.0's mapping Refine makes it three.

What is left is cosmetic and covered by the standing direction anyway: Appearance's tip lost a
"used to sit at the bottom of this tab" note that has been archaeology since before `v4.2`, and
Storage's three consecutive magnitude-bar bullets became two. Neither is a fix.

Checked against `applyPlan` (no `recordSyncHistory` call site), `refineMapping` (the third route,
same caps and spend store), and `git log -S'case readability'` for the tab's age.

### The round-4 review fixes — checked, not owed

The round-4 review fixes ("Fix what the round-4 adversarial review found…") are the same family
as the feature above, checked and not owed: every touched file is v5-only except
`FileSyncManager+Undo.swift`, whose two new handler guards consult `restructureLandingInProgress`
— a flag (and a hazard) that exists only where Restructure landings do, so the maintenance lines
have nothing to guard.

### The Organize proposals O1–O18 — checked, not owed

Fourteen proposals against the v5.0 Organize build: the Trash route for §5.2's standing empties
(O1), `Plan…` on the merge kinds (O2), the visual pass (O3 before/after preview, O4 kind glyphs,
O5 era strip, O6 blast radius as counts, O9 grouped crowding lists), the landing's own progress
checklist (O7), the mapping editor's filter and similar-name aids (O8), a Finder-menu route into
both plan verbs (O10), the ledger's history and verifier line (O11), the survey-refresh button and
its staleness tint (O12, O13), the Help Book link out of the lens (O14), the yearly backlog
nudge (O15), the structure trend (O16), the family-group table with batch planning (O17), and
§5.9's attempted measurement (O18).

**Almost every one of them extends machinery that exists only on `main`.** `RestructureLens`,
`RestructurePlanSheet`, `RestructurePlanner`, `RestructureStore` and
`FileSyncManager+RestructureApply` are all v5-only files —
`git ls-tree -r --name-only origin/v4.x -- Modules/Sync/Sources/Sync/RestructurePlanner.swift`
prints nothing on all three maintenance lines. There is no crowding strip to grow a button on, no
plan sheet to seed, and no ledger whose counts a chip could restate. The five new files here
(`RestructurePaths`, `RestructurePlanRouting`, `RestructureVerbResolver`,
`RestructureVerbRequest`, `RestructurePairMergeSheet`) are v5-only by construction, and so are
`OrganizeHelpTopics`, `RestructureNudge` (O15) and `RestructureTrendChart` (O16).

M5 adds three more files that exist off `main`, and none of the three is owed either:

- `Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift` — **`v4.x` only.** O15's
  hunk is one optional input and the row that renders it, and the row's sentence is about
  backlog findings, which only `main` has a detector for.
- `Modules/Sync/Sources/Sync/StructureDuplicatedTaxonomy.swift` — **`main` only**; the change is
  O18's injected `minimumShare`, on a detector no maintenance line carries.
- `ROADMAP_V5.md` — carried on `v4.x` (it was the v5 plan while v5 was being built there) but
  not on `v3.x` or `v2.x`. O18's dated §5.9 note describes a measurement of a detector `v4.x`
  does not have; copying it there would document a feature that line cannot run.

Five other touched files exist off `main`. None is owed, and the reason differs per file:

- `MacApp/HelpBook.swift` — all three lines. It gains one Restructure paragraph and an `openAt:`
  anchor, and that paragraph describes the two sheets `Plan…` opens; both are v5-only, so the
  sentence would be false on a line that has neither.
- `MacApp/ContentView.swift` — all three lines. Two hunks: the `helpTopic` state that carries
  O14's anchor (meaningless without the anchors), and a `helpTopic = nil` when Help closes. The
  second reads like a general fix but is not one — there is nothing to clear on a line where
  nothing ever sets it.
- `Modules/Sync/Sources/Sync/FileSyncManager.swift` — all three lines. One stored property,
  `restructureApplyProgress`, typed `RestructureApplyProgress?` — a v5-only type. It does not
  compile on the maintenance lines.
- `MacApp/ShortcutCommands.swift` and
  `Modules/FileExplorer/Sources/FileExplorer/LensWorkspaceView.swift` — **`v4.x` only** (the older
  two predate the lens workspace and this Commands file entirely). Every hunk is O10's two menu
  items and the Restructure helpers below the `.restructure` branch, none of which `v4.x` carries.

Checked with `git ls-tree` per file against all three lines — which is also what corrected the
earlier version of this entry, which claimed the two `v4.x`-only files were shared by all three.
The per-file notes are the expensive half to reconstruct, which is why the "not owed" reasons are
written out rather than summarised: they are not the same reason.

### 2026-08-29 — the Duplicates and Renames lens redesign — SPLIT VERDICT, two rows genuinely owed

Landed on `main` as `ec68e687`, `ab495a8e`, `9c446094`, `57ce00e4`. **Unlike everything above it in
this section, this one is not "checked, not owed" throughout** — most of it is v5 lens UI, but two
of the files it touches are carried by all four lines and carry a defect there, so those two rows
are owed and are recorded as owed. Not picked: the standing direction is no backporting. What
follows is what a future audit would otherwise have to re-derive.

**OWED 1 — the folder-overlap gate measures against the smaller side.**
`Modules/Sync/Sources/Sync/DuplicateFinder.swift`, present on **all three** maintenance lines.
The folder pass buckets candidates by name and asks content to justify the bucket; the fraction it
computed was the shared count over the *copy's own* size, so a one-item folder whose single file
also lives in a 361-item folder scores **1.0** and is offered as a merge. That is the defect the
user hit in the app — two folders six levels apart under `Immigration`, proposed for merging when
one is wholly contained in the other. `main` now scores the **mutual** fraction (intersection over
the larger side), which scores that pair `1/361` and leaves genuine version-pairs at ~0.9.
Confirmed present, not assumed:

```sh
for l in v4.x v3.x v2.x; do git show origin/$l:Modules/Sync/Sources/Sync/DuplicateFinder.swift \
  | grep -c mutualFraction; done          # 0, 0, 0 — none of them has the fix
git show origin/v4.x:Modules/Sync/Sources/Sync/DuplicateFinder.swift | sed -n '806,822p'
```

That last prints the pre-fix shape verbatim: `ordered.dropFirst().map { sharedFraction(...) }`,
averaged, then gated on `options.overlapThreshold`. **The average is a second, separate defect in
the same lines** — it decides per bucket what it then applies per folder, so a genuine six-against-
six twin sharing its name with three one-file subsets fails *as a unit* (the user's `Form W-2`
set). `main` filters per copy. A line taking one of these should take both; taking the mutual
fraction alone would drop those twins instead of admitting them.

**OWED 2 — the duplicate thumbnail lifts under the pointer and does nothing.**
`Modules/FileExplorer/Sources/FileExplorer/DuplicateThumbnail.swift`, present on **all three**.
Each line scales the tile to 1.1 on hover with no tap handler anywhere in the file — an affordance
that reads as a control and is not one, with the only real keeper control a small radio in the row
beneath.

**`main`'s answer changed on 2026-08-29 (`066ea5e4`), and the check for this row changed with it.**
It briefly made the tile itself the picker; it now makes the whole COPY ROW the picker, with the
tile and the keeper radio as pictures of state. So the fix a maintenance line would take is no
longer "give the tile a tap handler" — it is the row-as-control shape, and the tile's dead lift is
then deleted rather than wired up.

**Do not carry the nested-control half of that commit across as a defect: it is `main`-only and was
born and buried there.** `SelectableKeeperRadio` is a `Button`, and on `main` it briefly sat inside
a copy row that had also become a `Button`. On `v4.x`, `v3.x` and `v2.x` the COPY row is not a
button, so that radio is their one legitimate control — the very thing OWED 2 says is too small a
target, not a second one.

Counting `.row` buttons will not tell you that: each maintenance line has exactly **one**, and it is
the collapsed HEADER (name, subtitle, reclaim figure, chevron) — the expand/collapse control every
line has always had. `main` has two, and the second is the copy row. So the count that answers this
row is 2-vs-1, and the discriminator is `keeperAction` in the command below, which no header uses.

**Two traps for whoever audits this next.** `onTapGesture` is now absent from `DuplicateThumbnail`
on all four lines — on `main` because the row is the control, on the others because nothing is — so
that grep reads "no gap" off a real one. And the card holding the fix is named
`DuplicateGroupCard.swift` on `main` and `v4.x` but **`TidyGroupCard.swift` on `v3.x` and `v2.x`**
(renamed by `b4ae305b`), so a sweep written against `main`'s path answers 0 for the older two
because the PATH is missing, not the code. Both checks below survive that:

```sh
# The defect — a tile that lifts under the pointer with no control of its own:
for l in v4.x v3.x v2.x; do echo -n "$l "; git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DuplicateThumbnail.swift \
  | grep -c 'scaleEffect(isHovering'; done                     # 1 1 1 — the dead lift, on every line
# The fix — in the CARD, whose name differs by line:
for l in main:Duplicate v4.x:Duplicate v3.x:Tidy v2.x:Tidy; do
  echo -n "${l%%:*} "; git show "origin/${l%%:*}:Modules/FileExplorer/Sources/FileExplorer/${l##*:}GroupCard.swift" \
    | grep -c 'keeperAction'; done                             # main 2; v4.x 0; v3.x 0; v2.x 0
```

**NOT owed — dropping the name-only match kind**, and the three files that only move because it
did (`SemanticColor.swift`'s doc sentence, `FileSyncManager+Duplicates.swift`'s review counting,
`DuplicateFinderGoldenTests`' fixture). All three lines carry `.nameOnly` (7 hits each), so this is
reachable there — but it is a **product decision and a breaking one**: it removes a public enum
case and stops reporting a finding the user has been shown for releases. Maintenance lines take no
breaking changes, and the user's reason for it was about v5's Duplicates lens being overwhelming,
not about the kind being wrong to compute. Grounded first in his own `content-hash-index.json`:
across `~/Documents`, 115 same-name folder sets share not one file (`2020` ×36, `2021` ×25, `2023`
×23, `Archive`, `Approval`, `Payslips`). Nothing is lost by the removal on `main` because that
branch never wrote `coveredRoots`, so genuinely shared documents still surface as identical FILE
groups — which is also why a maintenance line keeping the kind loses nothing either.

**NOT owed — the header card's rigid summary row, with one honest caveat.**
`Modules/Design/Sources/Design/LensHeaderCard.swift` is on all three lines and all three carry the
pre-fix `HStack(spacing: 8) { summary() }`; `ShrinkableRun.swift` exists on none of them. So the
*mechanism* is present everywhere: an incompressible row 2 makes the card draw wider than its
proposal, and a `.frame(maxWidth: .infinity)` ancestor then reports the drawn width. **Whether it
manifests depends on how wide that line's own lenses fill `summary`, and I did not measure that** —
on `main` it took Duplicates' pill run to spill the card past both pane edges at 492pt. Recorded as
not owed under the standing direction rather than as checked-and-absent, because those are
different claims and only the first one is established here. What would settle it: build the line
and lay out its widest lens header at the 760pt window floor.

**NOT owed — everything else**, which is the bulk of the 40 files. `LensWorkspaceView.swift`,
`DuplicateGroupCard.swift`, `DuplicateGroupColumns.swift`, `RenameCategories.swift` and
`RenamePassLens.swift` are **`v4.x` only** (`v3.x` and `v2.x` predate the lens workspace entirely),
and their hunks are the sectioned tile grid, the redesigned card, and the two-column renames card —
lens surfaces, not fixes. The eight new files (`ShrinkableRun`, `LensCardGrid`, `DuplicateSections`
and their tests) are `main`-only by construction. `MacApp/HelpBook.swift`, `README.md`,
`RELEASE_NOTES.md`, `docs/index.html` and `docs/releases.html` are on all three lines but every
hunk describes the removed kind or the redesigned lens, so copying them would document behaviour
those lines do not have — the same reason the Help book's v5.0 pass is not owed above.

Checked with `git ls-tree` per file against all three lines, and with `git show origin/<line>:<f>`
for the two owed rows rather than inferring absence from the file list — a file being present says
nothing about which version of it is present, which is the whole difference between the two
verdicts in this entry.

### 2026-08-29 — a renamed memory card, and the pane-collapse glyph — SPLIT VERDICT, one row owed

Two things reported off the running app in one message, and they land on the maintenance lines
very differently — which is the reason this entry exists rather than a one-line "v5 only".

**OWED (`v4.x`, and the model half on `v3.x`) — a source on a volume renamed in Finder is left
naming a mount point that never comes back.** `~/sync-cloud.log` has the whole sequence six minutes
apart: `11:52:05 User added folder source /Volumes/NO NAME`, `12:58:09 Error enumerating
/Volumes/NO NAME … no such file`, `12:58:11 User added folder source /Volumes/Camera SD`. The card
was renamed while the app was running; its mount point moved; the source did not. What the user
sees is not a source that is *asleep* — which is all the sidebar's dimming has ever meant — but a
permanently dead row, beside a second source for the same card.

`Modules/Sync/Sources/Sync/FolderSource.swift` is on `v4.x` and `v3.x` (absent on `v2.x`, which has
no folder sources at all), and neither line has anything watching for the rename:

```sh
for l in v4.x v3.x v2.x; do git ls-tree -r --name-only origin/$l -- Modules/Sync/Sources/Sync/FolderSource.swift; done
for l in v4.x v3.x v2.x; do git grep -c didRenameVolumeNotification origin/$l -- MacApp Modules; done   # no hits on any line
```

`main` adds `FolderSource.repathed(_:whenVolumeMovedFrom:to:)` and
`following(volumeRenameFrom:to:in:)`, `SettingsManager.followVolumeRename`,
`FolderJumpStore.followVolumeRename`, and one `NSWorkspace.didRenameVolumeNotification`
subscription in `ContentView`. **The Sync + Settings half applies to both lines unchanged.** The
`FolderJumpStore` half applies to all three (the file is on every line). The sidebar half does not:
`FolderSidebar.swift` and `ContentView+FolderSidebar.swift` are **`v4.x`-only**, so on `v3.x` the
rename-following is the whole fix and the way out of an already-dead row is Settings ▸ Sources,
which that line already has (`removeFolderSource` is present on `v4.x` and `v3.x`, absent on
`v2.x`).

**NOT owed — "Remove Source…" in the sidebar's context menu.** Same `v4.x`-only files, and on that
line it is reachable — but it is an *addition*, not the repair: it exists for the rename that
happens while SyncCloud is quit, which the notification cannot see. A line taking the rename-follow
above gets the reported defect fixed without it.

**NOT owed — the pane-collapse glyph, and the reason is that the clash does not exist there.**
`main` moves the pane's collapse button off `sidebar.left` (to `arrow.left.to.line`, via the new
`PaneBarItem.collapseSymbol`) because the window's own sidebar toggle wears `sidebar.left` too,
about forty points up the same edge. All three lines carry `case collapse` and two `sidebar.left`
hits in `DashboardViews.swift` — so the *glyph* is there — but only `v4.x` has the second one to
collide with:

```sh
for l in v4.x v3.x v2.x; do git show origin/$l:MacApp/ContentView+Toolbar.swift \
  | grep -c 'Label("Sidebar", systemImage: "sidebar.left")'; done    # 1, 0, 0
```

`v3.x` and `v2.x` have no window sidebar toggle at all (`sidebar.right` for Info is their only
`sidebar.*` toolbar glyph), so on those lines the mark is unambiguous and changing it would be
churn. **`v4.x` DOES have the clash and is therefore genuinely owed this one too** — recorded as
owed, not picked, under the standing direction.

**NOT owed — the Help book bullet and paragraph.** `MacApp/HelpBook.swift` is on all lines, but the
new copy describes behaviour those lines do not have; documenting it there would be worse than
silence, the same verdict the v5.0 Help pass got above.

### 2026-08-29 — ejecting a card forgets its sources, and an Eject verb — SPLIT VERDICT, one row owed

The second half of the same report. It rests on the same `FolderSource` volume rule as the entry
above, so the line-by-line availability is the same and is not restated; what differs is which of
the two halves each line can actually carry.

**OWED (`v4.x` and `v3.x`) — the auto-removal.** `SettingsManager.removeFolderSources(onVolume:)`
plus `FolderSource.isOnVolume/idsOnVolume` need only `FolderSource.swift` and `SettingsManager`,
both of which those two lines carry (`v2.x` has neither folder sources nor `removeFolderSource`, so
the whole feature is unreachable there). Nothing on any line watches for an unmount:

```sh
for l in v4.x v3.x v2.x; do git grep -c didUnmountNotification origin/$l -- MacApp Modules; done  # no hits
```

The notification wiring is `ContentView`'s, which every line has, so this is portable — with one
substitution: `MountedVolumeMemory.swift` is a new file and would have to come with it. It is what
decides whether an unmounted volume was a card or a network share, and **without it the feature is
actively dangerous rather than merely absent**: a share is ejectable too, so a Wi-Fi drop would
delete the sources on it. A line taking the removal takes the memory, or takes neither.

**NOT owed — "Eject" on the row, and the notice's Dismiss.** `FolderSidebar.swift` is `v4.x`-only
(`v3.x` and `v2.x` predate the folder sidebar entirely), so there is no row to put the verb on
below `v4.x`. On `v4.x` it IS reachable and is recorded as owed on the same footing as the
`Remove Source…` row in the entry above — an addition rather than the repair, and the two make more
sense taken together than apart. `SidebarNotice` exists only on `v4.x` for the same reason
(`git grep -c 'struct SidebarNotice'` → 1, 0, 0), so its `Dismiss` action goes wherever it goes.

**NOT owed — the Help copy.** `MacApp/HelpBook.swift` is on all lines and the new bullet and
paragraph describe behaviour they do not have. Same verdict, same reason, as every Help row above.

**A caveat the maintainer of any line should read before picking this.** The rule removes sources on
**any** local removable-or-ejectable volume, which includes an external SSD and a mounted disk
image, not only an SD card. That is what was asked for and it is deliberate — an eject is the user
saying they are done with the volume — but it means a backup drive that is ejected nightly loses its
source each time, name override and landing folder included. Nothing measures how often that
happens; it is stated here so a line taking this takes it knowingly.

### 2026-08-29 — the v5.0 pre-release review's three fixes — CHECKED, NOT OWED

The adversarial pass before the v5.0 cut closed three things. **None of the three is owed to any
maintenance line, and the reason is the same for all three: every one of them is a defect in code
that only `main` has.** Recorded so the next audit does not re-derive it.

- **The `restructure` CLI verb skipping `flushingLogToDisk`.** The verb is new in 5.0. No other line
  carries the command at all, so there is nothing there to be unwrapped:

  ```sh
  for l in v4.x v3.x v2.x; do git grep -c 'commandName: "restructure"' origin/$l -- SyncCloudCLI; done  # no hits
  ```

  The *wrapper* is older and every line's own commands already use it — the bug was one command
  added without it, not a fault in the ladder. The new test
  (`everyCommandExitsThroughTheLogFlushAndErrorLadder`) would pass unchanged on every line today,
  which makes it an addition worth having rather than a fix; it is not recorded as owed because a
  test for a rule nothing currently breaks is a judgement call for whoever maintains that line.
- **`kindVerb(.duplicatedTaxonomy)` promising a merge with no plan surface behind it.** The whole
  Restructure lens, `FindingKind` and the §5.9 detector arrived in 5.0.
- **`FindingKind.ask` documented as live while nothing produces one.** Same — the enum does not
  exist below `main`.

### 2026-08-29 — the pane bar's Icon-and-Text mode stopped at 110% text — OWED to `v4.x`

`PaneBarTitleMetrics.rowBudget` was **34**, inherited from the provider capsule that used to set the
pane header's row height, and it was never what the header has left over. Compared against a row
priced as `pill + gap + NSLayoutManager.defaultLineHeight` — a type-setting line box that
over-reports the drawn row — it refused the bar's words from **110%** text upward: the first step
above the default, and six of the ten percentages the size slider reaches. The doc beside it claimed
the cliff was at Large and Larger. Reported from a real window at 110%; every test used one of the
four *named presets* (90/100/125/135), which are the only sizes that existed when the gate was
written, so nothing asked about the six in between.

Fixed on `main` by calibrating the budget to **36**, which puts the line where the header's own 6pt
ink-clearance rule actually falls: words through 115%, Icon Only from 120% up. The gate itself, and
its `iconOnly` fallback, are unchanged and were always right.

**OWED to `v4.x`, and it is the same defect there, not a near-miss.** That line carries both halves —
the label mode with the identical constant, and the percentage slider that reaches the sizes it
mis-refuses:

```sh
for l in v4.x v3.x v2.x; do
  git show origin/$l:Modules/Dashboard/Sources/Dashboard/PaneBarArrangement.swift |
    grep -c 'rowBudget: CGFloat = 34'                                    # 1, 0, 0
  git show origin/$l:Modules/Design/Sources/Design/FontSize.swift |
    grep -c 'selectablePercents'                                         # 1, 0, 0
done
```

**NOT owed to `v3.x` or `v2.x` — neither carries the code.** `PaneBarLabelMode` does not exist below
`v4.x` (the pane bar has no words to withhold there), and neither does the percentage slider: those
lines still have the four named presets, so even the shape of the bug is absent.

**Per-file pick notes, if `v4.x` ever takes it.** Four files, and only the first is the fix:

- `Modules/Dashboard/Sources/Dashboard/PaneBarArrangement.swift` — `rowBudget` 34 → 36, plus the
  doc on it and on `PaneBarLabelMode`. **Re-measure before trusting the number there**, and note
  that `main` has since moved it again, to 36.5 — see the 2026-08-30 row below, which this one must
  now be picked *with* rather than before.

  **CORRECTED 2026-08-30.** This bullet used to give the reason as "`main` retired the provider
  capsule (`fd068fc4`) while `v4.x` still draws it — the capsule is the taller thing in that row, so
  the clearances the number was fitted to are not `v4.x`'s clearances". That is false. `v4.x` was
  cut from `v4.6` (`d3697df9`) on 2026-08-27, the same day `fd068fc4` landed, so it inherited the
  retirement — `git branch -r --contains fd068fc4` names `origin/v4.x`, and that line's own
  `rowBudget` doc reads "with the capsule gone the bar sets its own". The two headers are the same
  geometry, nine diff lines apart, none of them geometric.

  The advice survives the correction with a different reason: **`v4.x` has no instrument to
  calibrate against.** `theTitledHeaderClearsBothEdges` and `headerInkFloor` are absent from that
  line entirely, so the ink-clearance test is a prerequisite of the pick, not an optional check
  after it.
- `Modules/Dashboard/Tests/Dashboard/PaneBarTitleTests.swift` — the gate tests, rewritten to sweep
  `FontSize.selectablePercents` instead of the four presets. This is the half that would have caught
  it, and it is worth taking even if the constant turns out to differ.
- `Modules/Dashboard/Tests/Dashboard/PaneBarLadderTests.swift` — `theTitledHeaderClearsBothEdges`,
  and `theHeaderIsBalancedTopToBottom` reading the shared `headerInkFloor`. Machine-pinned
  (`.pixelSampling`), so it will not run on CI on that line either.
- `Modules/Dashboard/Sources/Dashboard/DashboardViews.swift` — comment only.

### 2026-08-30 — `LabelMetrics.lineHeight` was a point short of the line it measured — RECORDED, not owed (`v4.x` only)

`LabelMetrics.lineHeight` returned `NSLayoutManager.defaultLineHeight(for:)`, which is **1pt short**
of the box SwiftUI gives a single-line `Text` at 9.5–11.5pt and 15–16pt, and equal elsewhere. Its
one caller, `PaneBarTitleMetrics.rowHeight`, is a *reservation* — it becomes
`PaneHeader.tallestRungHeight`, the bar container's `minHeight`/`maxHeight` — so the error ran in
the unsafe direction: at five of the six text sizes that draw words, the titled rung reserved a box
its own words hung out of. Nothing clips a SwiftUI child at a `maxHeight`, so the only symptom was a
word reaching a point further into the 10pt rule between the bar and the breadcrumb, which had the
room. **No visible defect was found on `main` either** — this was latent, and the reason it was
invisible is a false claim in `LabelMetrics`' own file header: "`LabelMetricsTests` re-checks all of
them against the drawn view on every run", written while `lineHeight` had no test anywhere.

Fixed on `main` by measuring `NSAttributedString.size().height` — the same call the widths already
make. Swept 8–24pt in half-point steps at four weights: the attributed size matched the hosted
`Text` in all 132 pairs, `defaultLineHeight` missed 60 of them, every miss short by exactly 1pt.

**NOT owed to `v3.x` or `v2.x` — neither carries `lineHeight` at all.** The positive control first,
since a mis-spelled path answers "absent" on every line at once:

```sh
git ls-tree -r --name-only origin/main -- Modules/Design/Sources/Design/LabelMetrics.swift  # found
for l in v4.x v3.x v2.x; do
  git show origin/$l:Modules/Design/Sources/Design/LabelMetrics.swift | grep -c 'defaultLineHeight'
done                                                                   # 1, 0, 0
```

The file is present on all three; the member is not. Those two lines have no pane-bar titles to
price a row for, which is the same reason they are not owed the `rowBudget` row above.

**`v4.x` carries it, and picking THIS row alone would make that line worse — read this before
picking either.** `v4.x` is already owed the `rowBudget` row above (it still carries **34**, the
retired provider capsule's number). The two interact, in the direction that hurts:

| line | rows across 90–135% | budget | words through |
|---|---|---|---|
| `v4.x` today | 33 33 34 34 35 35 37 37 38 38 | 34 | 105% |
| `v4.x` + this row alone | 33 34 35 35 36 36 37 37 38 38 | 34 | **95%** |
| `v4.x` + both rows | 33 34 35 35 36 36 37 37 38 38 | re-measure | — |

Correcting the line height raises every row at 95–115% by a point, and against an already-too-low
budget that refuses two more text sizes. **So this row is not independently pickable: it goes after
the `rowBudget` row or not at all.**

And the budget it goes after cannot be `main`'s **36.5** on faith — but **not for the reason the
row above gives, which is wrong and is corrected there.** That row says `v4.x` still draws the
provider capsule; it does not. `fd068fc4` retired it on 2026-08-27 and `v4.x` was cut from `v4.6`
(`d3697df9`) the same day, so the line inherited the retirement, and its own `rowBudget` doc says so
in as many words — "with the capsule gone the bar sets its own". The two headers are the same
geometry: `LiquidGlass.headerHeight` is 81 on both, `tallestRungHeight` is pinned on both, and the
whole diff between the two `DashboardViews.swift` files is nine lines — one doc comment and the
collapse glyph.

```sh
git branch -r --contains fd068fc4                              # names origin/v4.x
git show origin/v4.x:Modules/Dashboard/Sources/Dashboard/PaneBarArrangement.swift |
  grep -c 'with the capsule gone'                              # 1
diff <(git show origin/main:Modules/Dashboard/Sources/Dashboard/DashboardViews.swift) \
     <(git show origin/v4.x:Modules/Dashboard/Sources/Dashboard/DashboardViews.swift) |
  grep -c '^[<>]'                                              # 9
```

So 36.5 may well port unchanged. **The reason to re-measure anyway is that `v4.x` has no instrument
to check it with**: `theTitledHeaderClearsBothEdges` and `headerInkFloor` do not exist on that line
at all (`grep -c` → 0), so the calibration test has to come across before the constant means
anything there. That is a prerequisite, not a caveat.

**Per-file pick notes, if `v4.x` ever takes both.** Five files; the first two are the fix:

- `Modules/Design/Sources/Design/LabelMetrics.swift` — `lineHeight` measures
  `NSAttributedString(string:attributes:).size().height` instead of
  `layoutManager.defaultLineHeight`, and the cache key stops carrying the **empty string**. That
  last part is not cosmetic: an empty attributed string has no font run, so `size()` answers for a
  default face — 14.0 at both 10pt and 11pt — and the moment the key becomes the thing measured, an
  empty sample is wrong. `layoutManager` (the shared `NSLayoutManager`) has no other user and goes.
  The file header's "all of them" claim goes with it.
- `Modules/Dashboard/Sources/Dashboard/PaneBarArrangement.swift` — `rowBudget` 36 → 36.5, and the
  docs on it and on `rowHeight`, both of which asserted the *opposite* of the truth ("over-reports
  the drawn row by up to 3pt"; "a reservation, and a generous one"). **Re-measure the budget on that
  line**, per the row above.
- `Modules/Design/Tests/DesignTests/LabelMetricsTests.swift` — three new cases, and this is the half
  worth taking even if the constants differ: `lineHeightMatchesTheDrawnLineBox` (the check that did
  not exist), `defaultLineHeightIsNotTheDrawnLineBoxButTheAttributedSizeIs`, and
  `aLineBoxDoesNotDependOnWhatIsInIt`. They need `everySelectableScale`, derived from
  `FontSize.selectablePercents` — present on `v4.x`, so it ports; the named presets alone cannot see
  this, because 95% and 105% are two of the five sizes affected and neither is a preset.
- `Modules/Dashboard/Tests/Dashboard/PaneBarLadderTests.swift` — `everyRungIsReservedAsTallAsTheBarItDraws`
  (the height counterpart of `everyRungIsPricedAsTheBarItDraws`, whose absence is what hid this) and
  `theEnvironmentDoesNotReachABarBuiltOffTheStruct` beside it, which pins why the first takes no
  text size. Machine-pinned (`.pixelSampling`), so it will not run on CI on that line either. The
  two calibration tables in the file's docs are `main`'s measurements and must be re-run, not
  copied.
- `Modules/Dashboard/Tests/Dashboard/PaneBarTitleTests.swift` — `theGateHasBothDirectionsWithMarginOnEach`,
  whose margin goes 1pt → 0.5pt with a control asserting the rows really are a point apart. The
  point that went was never real: the rows only looked 2pt apart because `defaultLineHeight` steps
  more coarsely than the type does.

Six `DashboardSnapshotTests` PNGs were re-recorded on `main` (12 files, light and dark). They are
machine-pinned reference images and must be re-recorded on any line that takes this, never copied.

### 2026-08-29 — the tab strip's corner and its active-tab rule — RECORDED, not owed (`v4.x` only)

Two geometry defects in `PaneTabStrip`, fixed together on `main`. **`v4.x` carries both, unchanged.
`v3.x` and `v2.x` carry neither, because neither line has the tab strip at all** — it arrived in the
v4 line, so there is nothing there to be wrong.

The positive control first, since a mis-spelled path answers "absent" on every line at once:

```sh
git ls-tree -r --name-only origin/main -- Modules/FileExplorer/Sources/FileExplorer/PaneTabStrip.swift  # found
for l in v4.x v3.x v2.x; do
  git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PaneTabStrip.swift
done                                     # v4.x only
```

And the shape, on the line that has the file. Read the COUNT — `grep -c` exits 1 on zero, so the
`|| echo 0` idiom this file warns about would print two lines here:

```sh
git show origin/v4.x:Modules/FileExplorer/Sources/FileExplorer/PaneTabStrip.swift \
  | grep -c 'padding(.horizontal, 3)'                                    # 1 — the rule's inset
git show origin/v4.x:Modules/FileExplorer/Sources/FileExplorer/PaneTabStrip.swift \
  | grep -c 'HoverAffordanceShape.roundedRect(Radius.chip)'              # 1 — the chip's radius
git show origin/v4.x:Modules/FileExplorer/Sources/FileExplorer/PaneTabStrip.swift \
  | grep -c 'LiquidGlass.cardGutter'                                     # 3 — the gutter, at both sites
```

**What is wrong there, so a maintainer can price it without re-deriving it.**

- **The chip cannot nest in the strip card on any corner.** The card is `Radius.card` (14), the
  horizontal gutter is `LiquidGlass.cardGutter` (5) and the vertical inset is `(34 - 26) / 2` (4).
  Concentricity wants the inner radius to be the outer less the gap, so the chip needs 9 across and
  10 down; it carries `Radius.chip`, 6, which is neither. Close enough to read as an attempt,
  far enough off to read as a miss.
- **The active tab's rule paints outside the chip it marks.** It is inset 3pt from the chip's frame,
  but a 6pt `.continuous` corner has already pulled the chip's paint in by 6.00pt at the bottom
  scanline (rendered at 8× and read back). So its last 3pt at each end lie over the card behind it.
  Nothing clips them: `chipGround` is a plain `ZStack` behind the chip with no `clipShape`.

**The pick, if the direction ever changes.** It is one commit and it is self-contained, but it is
four edits and a test-helper change, not a one-liner:

1. `PaneTabStripLadder` gains `stripGutter` (4), `chipRadius` (`Radius.well`) and `ruleInset`
   (`chipRadius + 2`), with the reasoning kept — the `+ 2` is measured, not chosen: `+ 1` clears the
   corner's paint by exactly 0.0pt, which is a test passing on its tolerance.
2. `PaneTabStrip.chipShape` reads `chipRadius`; the rule's `.padding(.horizontal, 3)` reads
   `ruleInset` and becomes a `Capsule`.
3. **Both** `LiquidGlass.cardGutter` sites move to `stripGutter` — the row's leading/trailing padding
   AND the width handed to `layout(available:)`. Moving one alone overstates the room the ladder has
   and squeezes the parked-tab count at the rail's 220pt.
4. `PaneTabStripRenderTests` reads pixels at x offsets computed from the gutter, so those follow; and
   `glyphPixels` needs its `rowInset` parameter, because a rounder corner reaches further into the
   rows near a chip's ends — at radius 10 it put 22 corner pixels into a band that asserts
   bareness, which is a red that looks like a chevron bug.

`Radius.chip` stays at 6 on every line. It is shared with pills, inline badges and
`DestinationPicker`'s rows, none of which sit inside a 14pt card; the strip needs its own radius,
and moving the token to suit the strip would be the wrong fix on any line.

### 2026-08-29 — Organize's header row 2: the survey receipt moves, the breakdown shortens

Row 2 of `LensHeaderCard` on the Organize lenses was the card's binding width constraint. Measured
on `main` at the default text size with a real backlog (641 renames, a 2,713-folder survey): row 2
wanted **867.2pt** of content against **654.1** for row 1 — and row 1 is the half with a measured
shedding model (`OrganizeRailMetrics`), row 2 has none. Five of its six tenants are `.fixedSize()`,
so the whole squeeze fell on the one that could yield, and the result was
`2713 folders c…` beside a button reading **Rename 641 files**, then a silent clip of the readout.

Two changes, both content rather than mechanism:

- **R1** — the *finished* folder-memory report leaves row 2 and becomes a `Section` header above the
  **Update folder memory** item in the Rescan menu (`FolderSurveyNote`). It was the widest tenant,
  the only compressible one, and the only one not about the list on screen. The *running* branch
  stays on row 2, which is where the "it looks like it did nothing" argument actually applies.
- **R2** — `RenameBacklogTally.headerBreakdown`, a header-only short form in the same vocabulary
  (`13 to name or reshuffle · 628 to pad`, 190.5pt against 268.5). `breakdown` is untouched, so the
  folder rows and the `RenamePassLens.summary` equality are unaffected.

**OWED to `v4.x`, both of them.** That line carries the defect verbatim — its `LensWorkspaceView`
has the same `else if let report = syncManager.filingSurveyReport` branch on row 2 and the same
`Text(tally.breakdown)` in the header, and it has `RenameBacklogTally`, `folderMemoryStatus` and the
**Update folder memory** menu item:

```sh
git show origin/v4.x:Modules/FileExplorer/Sources/FileExplorer/LensWorkspaceView.swift |
  grep -c 'else if let report = syncManager.filingSurveyReport'   # 1
```

Per-file pick notes for whoever takes it: `FolderSurveyNote.swift` is new and drops in whole;
`RenameBacklogTally.swift` is an additive property; `LensWorkspaceView.swift` is the real work
(three prose blocks were rewritten alongside the two behaviour edits, and the prose is what stops
the next reader re-deriving why the report is not on the row). The `OrganizeRailTests` changes
rewrite five existing survey tests rather than adding to them — their premise is removed by R1 —
so a pick that takes the source without the tests leaves five tests asserting the old arrangement.

**NOT owed to `v3.x` or `v2.x`.** Neither line has either type, so there is nothing to change:

```sh
for l in v3.x v2.x; do git grep -c 'struct RenameBacklogTally' origin/$l -- Modules; done   # no hits
for l in v3.x v2.x; do git grep -c 'folderMemoryStatus' origin/$l -- Modules; done          # no hits
```

**One thing R1 and R2 do NOT fix, on any line.** To File at an 800pt column with both the refine
offer and a heavy readout is over-subscribed on row 2 *before* a survey is counted — 309pt of pills
plus ~468 of actions exceed the 776pt available — so a running survey still costs the readout 66
pixels off its tail. Renames at 800 and To File at 1000 are clean at 0. No content edit can fix a
row that is over budget with the content already removed; only a measured row-2 width model can.
`theReadoutNoLongerCompetesWithTheSurvey` asserts it as a bound rather than as zero, deliberately.

## 2026-08-30 — the light-mode card hairline (`de98d4e7`)

**RECORDED — not owed.** `surfaceCard` and `bottomSectionCard(.cards)` passed
`lightBorder: explicit` to `DarkBoldCardChrome`, and on macOS 26 `needsExplicitChrome` is false for
native glass — so in a light appearance a content card drew no hairline and no shadow, leaving its
only visible bound the material's own darkening (a card reads 210–213 against a window ground of
237–239). `de98d4e7` passes `true` at both sites.

**All three lines carry it**, and the check is one command per line:

```sh
for l in v2.x v3.x v4.x; do
  git show origin/$l:Modules/Design/Sources/Design/LiquidGlassStyle.swift | grep -c 'lightBorder: explicit'
done      # 2, 2, 2 on 2026-08-30; main is 0 after the fix
```

The file is present on all three (stage 1 checked, and `main` returns 0 as the positive control, so
the pattern is real rather than a mis-spelled path).

**Whether a user would notice differs by line, and that is the interesting half.** The defect is
old, but what made it visible is new: it needs a card large enough and empty enough to read as a
grey slab, and the one that produced the report — Restructure's `LensSetupCard`, which fills the
workspace height with content in its top third — is v5-only. `git ls-tree -r --name-only
origin/v4.x -- Modules/FileExplorer/Sources/FileExplorer/LensSetupCard.swift` prints nothing on all
three lines. So the lines carry the missing hairline everywhere, and carry no surface on which it
has so far been worth seeing.

The pick is a two-line change with no dependencies — `lightBorder: explicit` → `lightBorder: true`
at both call sites — if the direction ever changes. What is NOT worth picking, and is recorded so
nobody re-derives it: three attempts to lighten the card's fill instead all failed against the
running app. `Glass.tint(.white.opacity(0.5))` took a card 211 → 198 (a tint densifies the material
rather than lightening it); a `controlBackgroundColor` ground under `.glassEffect` gave 213 where
235 was predicted; the same ground stacked over the glass did no better. `.glassEffect` dominates
its own subtree and nothing in the public API lightens it from outside.

### The light-appearance material switch (`a52c1c56`) — same status

The follow-up to the hairline row above, and the actual fix. `glassSurface` now takes the
`Material` family in a light appearance and keeps native `.glassEffect` only in dark, because
native Liquid Glass renders a card 28/255 BELOW the window ground it floats on and no public API
lightens it from outside. **RECORDED — not owed**, same standing direction.

The maintenance lines are in a different position from `main` here, and it is worth being precise
about why. All three predate the macOS 26 SDK's `.glassEffect` being reachable at all — their
`glassSurface` has the same `if #available(macOS 26.0, *)` fork, so a maintenance build compiled
against a Tahoe SDK takes the darkening branch exactly as `main` did:

```sh
for l in v2.x v3.x v4.x; do
  git show origin/$l:Modules/Design/Sources/Design/LiquidGlassStyle.swift | grep -c 'glassEffect'
done
```

So the defect applies, and the pick is small — hoist the `else` branch to cover light. What makes
it low-value rather than merely unsent is the same asymmetry as the hairline: the surface that made
it visible is `LensSetupCard`, which is v5-only.

**Do not re-derive the three failed approaches.** `Glass.tint(.white.opacity(0.5))` moves a card
211 → 198; a `controlBackgroundColor` ground under `.glassEffect` gives 213 where 235 is predicted;
the same ground stacked over the glass does no better. They are recorded in `GlassSurface`'s own
doc comment on `main` as well, because the next person to look at this will otherwise try the tint
first, as this session did.

### 2026-08-30 — the workspace bar's glyph sizes — RECORDED, not owed (`v4.x` and `v3.x`)

`WorkspaceBarMetrics.segmentChrome` assumed a 14pt glyph. The four workspace symbols do not draw at
14, and the difference is not visible from any padding literal — it takes laying each one out.
**`v4.x` and `v3.x` both carry the file and the assumption. `v2.x` does not have the file at all.**

The positive control first, since a mis-spelled path answers "absent" everywhere at once:

```sh
git ls-tree -r --name-only origin/main -- MacApp/WorkspaceBarMetrics.swift   # found
for l in v4.x v3.x v2.x; do
  git ls-tree -r --name-only origin/$l -- MacApp/WorkspaceBarMetrics.swift
done                                     # v4.x and v3.x; v2.x absent
for l in v4.x v3.x; do
  git show origin/$l:MacApp/WorkspaceBarMetrics.swift | grep -c '14 + 6 + 24'   # 1 on both
done
```

**The glyphs are not the same set on every line, so the numbers below are `main`'s and do not
transfer.** `main` and `v4.x` carry Browse/Compare/Organize/Storage; `v3.x` predates the flat bar's
current membership and carries Compare/Filing/Duplicates/Automations/Storage, with
`doc.on.doc` and `wand.and.stars` where `main` has `folder` and `folder.badge.gearshape`. A
maintainer picking this must re-measure their own line's symbols rather than copying these:

| symbol (`main`) | | glyph |
|---|---|---|
| `folder` | Browse | 16 × 13 |
| `arrow.left.arrow.right` | Compare | 14 × 17 |
| `folder.badge.gearshape` | Organize | 16 × 14 |
| `chart.pie` | Storage | 15 × 15 |

**What is wrong there.** Three things, one cause:

- **The selected pill changes height as it travels.** The marker is a `Capsule` sized to its own
  segment inside a `matchedGeometryEffect`, so a selection moving between Compare (25pt) and
  anything else (23pt) interpolates between two frames and the pill grows or shrinks mid-slide.
- **It nests concentrically for exactly one workspace.** A capsule inside a capsule is concentric
  only at a uniform inset; the horizontal one is 3pt and the vertical was 4pt for three of the four.
- **The width arithmetic under-measures the drawn bar by 5pt**, both rungs. That is the direction
  that folds the toolbar behind the overflow chevron, which is the failure the type exists to stop.

**The pick.** One line of view code and one constant: give the `Image` in `workspaceSegment` a
`.frame(width:height:)` of a named `glyphSide`, and derive `segmentChrome` and
`iconOnlySegmentWidth` from it. On `main` that is 17 — the tallest glyph, one point clear of the
widest, so nothing clips and the spare point is reserved rather than spent.

**And the part that is not mechanical, which is why this is worth a paragraph rather than a line.**
Correcting the constant moves the *computed* bar width by 12pt even though the *drawn* bar grows
only 5 — framing pads the three narrower glyphs out as well as fixing the assumption. On `main` that
moved the shedding thresholds from 708/689/755/773 to 720/701/767/785, and two things changed at the
760pt window floor: **Large sheds its labels**, and **Small's ⌘K pill drops its word**. Both are the
safe direction, but the first is a real loss, and any line taking this pick inherits that decision
along with its own numbers. Reclaiming it means finding ~12pt in `reservedChrome` (deliberately
generous, and unmeasured) or in the segments' 12pt horizontal padding — a design call, not an
arithmetic one, and deliberately not made here.

## 2026-08-31 — The compared PDFs keep their zoom across a mode switch (`09e485e6`)

**CLOSED — does not apply**, on the same evidence as the row below and worth one line rather than a
repeat of it: the commit touches `PairViewers.swift` and `CompareCopiesSheet.swift`, and neither file
exists on any maintenance line. The positive control is the same one — `FileTreeView.swift` is
present on all four, so an "absent" answer here is absence and not a mistyped path.

```sh
for l in main v4.x v3.x v2.x; do
  git ls-tree -r --name-only origin/$l -- \
    Modules/FileExplorer/Sources/FileExplorer/PairViewers.swift \
    Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift
done   # main prints both; v4.x, v3.x and v2.x print only FileTreeView
```

**The measurement is the part worth keeping**, because it closes a question rather than opening one.
The mode switch unmounts the PDF pair and re-opens both documents through the process-wide serial
lane, which was reported as a cost. It is not: eleven real PDFs — including a 310-page one and a
4.45 MB scanned board pack — open in **0.04–0.36 ms**, since PDFKit reads the trailer and the xref
rather than the content. The per-page re-open inside `PagePairRaster.render` is ~11 ms against
~190 ms of rendering. No document cache is owed to any line, here or anywhere else that opens a
`PDFDocument`.

What the remount really discards is the reader's zoom, which is now held by the surface the way the
page already was — and that surface is `main`-only.

## 2026-08-31 — Adversarial review of the Compare Copies fixes (`8fdb68d7`…`8701b644`)

**Six commits, and only one line of them applies to any maintenance line.** A second adversarial
pass over the previous night's fixes found ten issues — ⌥ being routed around by the page-reporting
observer, scroll observers stranded in the lifetime list, an image pair mounting its viewer over nil
rasters, a decodability guard no test could fail, two double-paid computations, a test scoped to the
whole file instead of the block it names, two silent failures with no log line, and prose behind the
behaviour. Every one of them is inside the Compare Copies surface, which exists on `main` alone.

**Checked, with the positive control first** — a mis-spelled path answers "absent" on every line at
once, and here the two answers genuinely differ, which is what makes the control worth running:

```sh
for l in main v4.x v3.x v2.x; do
  git ls-tree -r --name-only origin/$l -- \
    Modules/FileExplorer/Sources/FileExplorer/PairViewers.swift \
    Modules/FileExplorer/Tests/FileExplorer/PaneRowHeightStabilityTests.swift
done   # main prints both; v4.x, v3.x and v2.x print only the second
```

| Line | Compare Copies files | `PaneRowHeightStabilityTests.swift` | Status |
|---|---|---|---|
| `v4.x` | **none** | present, same defect | RECORDED — not owed (one line) |
| `v3.x` | **none** | present, same defect | RECORDED — not owed (one line) |
| `v2.x` | **none** | present, same defect | RECORDED — not owed (one line) |

The Compare Copies half is **CLOSED — does not apply**, for the reason the row below already
establishes: `v4.x` has the duplicates card but no compare surface, and `v3.x`/`v2.x` have neither.
There is nothing on those lines for `PairViewers`, `TypedViewerReadiness`, `PairContentKind`'s
decodable listing or `TextPairDiff` to be a fix *to*.

**The one thing that does apply is a diagnostic, not a defect.** `PaneRowHeightStabilityTests`
measures which pane width took the most layout rounds and then leaves it out of the failure message,
so the compiler's "written to, but never read" is the only thing reading it. All three lines carry
it identically:

```sh
for l in v4.x v3.x v2.x; do
  git show origin/$l:Modules/FileExplorer/Tests/FileExplorer/PaneRowHeightStabilityTests.swift |
    grep -c 'worstWidth'                      # 2 on each — declared and assigned, never read
done
```

The pick is one line — put `\(worstWidth)pt` into the `#expect` message beside `\(worst)`. Nothing
fails without it and nothing changes with it except what a maintainer reads when that test goes red,
which on a width-dependent row height is the first question they will have. Recorded rather than
sent, per the standing direction.

## 2026-08-30 — Compare Copies for file pairs (`90e0ac67`, `e2082929`, `51c37256`, `e5508bc6`, `ad64b742`)

> **The SHAs above are the second set.** This row first cited `bb27a528`, `8296889a` and
> `e4d76336` — commits from before the branch was squashed and force-pushed the same day, which no
> ref on `origin` reaches any more. They resolve to nothing on a fresh clone, in the file a future
> audit reads to find the work. Cite a SHA only after the push that fixes it, and re-check any SHA
> written down before a squash.
>
> **And the check is one command, worth running over this whole file** — it is the tool that would
> have caught the first set on the day, and nothing else here does.
>
> **It must ask all four lines, and the first draft of it asked only `main`.** That version reported
> fourteen unreachable SHAs; eleven of them were perfectly good commits on `v2.x` and `v3.x`, which
> is exactly what this file exists to record. A check that cries wolf over the rows it is meant to
> protect gets switched off, so the loop below tries every line before it complains:
>
> ```sh
> grep -o '`[0-9a-f]\{7,12\}`' docs/backports.md | tr -d '`' | sort -u | while read s; do
>   git cat-file -e "$s^{commit}" 2>/dev/null || { echo "GONE (not in this clone): $s"; continue; }
>   for l in main v4.x v3.x v2.x; do
>     git merge-base --is-ancestor "$s" origin/$l 2>/dev/null && continue 2
>   done
>   echo "UNREACHABLE: $s"
> done
> ```
>
> Three hits are expected and correct: `bb27a528`, `8296889a` and `e4d76336`, quoted two paragraphs
> above as the erased set. Anything else is a row to fix.
**RECORDED — not owed**, and unusually this is a feature rather than a defect: the Duplicates card
offered "Compare copies" only for FOLDER groups (`if group.isDirectory`), so a user comparing two
files had a 40pt thumbnail per row and nothing else. `main` now ungates it and opens an in-window
overlay — facts strip, two Quick Look panes, keeper toggle, verdict bar — backed by a new engine
verb, `resolveDuplicateCopy(_:keeper:)`, that trashes ONE copy of a group.

**Where each line actually stands, checked rather than assumed.** The positive control first,
because a mis-spelled path answers "absent" on every line at once:

```sh
for l in main v4.x v3.x v2.x; do
  git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/DuplicateGroupCard.swift
done          # main and v4.x print the path; v3.x and v2.x print nothing
```

| Line | Carries the card? | The gate | Status |
|---|---|---|---|
| `v4.x` | yes | `if group.isDirectory { compareControl }` — 1 hit, `compareControl` 2 hits | RECORDED — not owed |
| `v3.x` | **no such file** | — | CLOSED — does not apply |
| `v2.x` | **no such file** | — | CLOSED — does not apply |

`v3.x` and `v2.x` predate the card entirely: their whole duplicates UI is
`DuplicateSearch`/`DuplicateThumbnail` plus the app-target review coordinator
(`git ls-tree -r --name-only origin/v2.x | grep -i Duplicate`). There is no card to ungate and no
`compareControl` to reach, so the pick is not small on those lines — it is the card as well.

**The engine half is the interesting part, and it is genuinely portable.** All three maintenance
lines carry `FileSyncManager+Duplicates.swift` WITH `removeResolvedDuplicateCopy` (1 hit each), so
the in-memory update the new verb ends in already exists everywhere. What none of them has is a
single-copy TRASH inside the engine: the only one in those trees is
`DuplicateReviewCoordinator.trashRightCopy` in the app target, unreachable from `Modules/FileExplorer`.

```sh
for l in v4.x v3.x v2.x; do
  git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Duplicates.swift | grep -c 'removeResolvedDuplicateCopy'
done                                              # 1, 1, 1
```

**Two things a line taking this pick must not skip.** First, `assessDuplicatePair` is what makes the
verb safe, and both the pre-check AND the removal gate must consult it — a version that verifies
once, before `deleteItems`, is verifying before the serialized queue and before a user-paced
permanent-delete dialog, which are the two windows the gate exists for. Second, the live-group
lookup is BY PATH: `DuplicateGroup.id` is minted fresh every scan on every line, so a lookup by id
finds nothing a rescan later and fails open unless it is written fail-closed.

**And one thing not to port at all.** The surface's ⏎/esc handling is `.onKeyPress`, not
`.keyboardShortcut`, because an in-window overlay leaves the whole window mounted underneath it.
On a line without the overlay that reasoning does not transfer, and `BareKeyEquivalentScanTests`
exists on those lines too — read its exemption map before deciding, rather than copying `main`'s
answer to a different question.

**The later phases are one component, and they do NOT stand alone.** `main` also carries typed pair
viewers (`PDFPairView`, `ImagePairView`), a bitmap diff, the page strip, a bounded text reader and
a line diff, plus a second host on the Differences list (`DifferencesPairCompare`). All of it hangs
off `FilePairCompareView`, which is the surface above — so on a line without the surface there is
nothing to host any of it, and picking a piece of it alone would be picking a viewer with no
viewer. Same status, and the same reason it is one row rather than five:

| Piece | Depends on | Status |
|---|---|---|
| `PDFPairView` / `ImagePairView` | `FilePairCompareView` | RECORDED — not owed |
| `BitmapDiff` / `PagePairRaster` | `PDFKitSerialAccess` (present on all lines) | RECORDED — not owed |
| `BoundedTextRead` / `TextPairDiff` | nothing — both are pure and would apply anywhere | RECORDED — not owed |
| `DifferencesPairCompare` | `FilePairCompareView` + `DifferencesView` | RECORDED — not owed |

The two pure ones are the only genuinely independent pieces, and worth naming as such: a line
wanting a text diff for its own reasons could take `BoundedTextRead` and `TextPairDiff` alone —
they import only `Foundation` and `Sync`'s `FileSyncManager.formatBytes` and
`MaterializationStatus`, both of which every line carries.

---

## 2026-08-30 — the Trash-refusal family, and the third attempt (`4e94ddfe`, `14bc6bc3`, `91fa7d18`, `77e2bba6`)

**RECORDED — not owed**, and the whole family is absent from all three lines, not just the last
commit. `main` now answers `NSCocoaErrorDomain 513` from `trashItem` with a diagnosis, a named
path, a log line carrying the codes, and **three** attempts to move the item; every maintenance
line still answers it with Foundation's sentence and one attempt.

**What this is actually about, because the first two commits' rationale was wrong.** The refusal
was diagnosed as a missing Full Disk Access grant and the alert said so. It is not a permission
problem at all. Measured 2026-08-30 on `~/Documents` — iCloud-synced, so the Trash for these items
is `~/Library/Mobile Documents/.Trash`:

- **12 of 12** long-standing files were refused by `FileManager.trashItem` **and** by
  `NSWorkspace.recycle`. Both. The out-of-process fallback hits the same wall.
- The items are user-owned, mode `700`, no `chflags`, no deny ACL, writable parent, fully
  materialised (`stat -f %b` > 0, not evicted placeholders), and `access(2)` grants every
  permission the move needs.
- An **ad-hoc-signed `.app` bundle holding no privacy grants at all** creates and trashes files in
  the very folder that refuses them — so it is not TCC, and not the app's signing identity.
- A plain `rename(2)` of the same item into that same Trash directory **succeeds**.

So the denial lives in the Trash layer the two APIs share. Moving the item re-registers it, after
which the ordinary `trashItem` succeeds — which is what `trashAfterReregistering` does, and why it
is ordered last: it is the only one of the three attempts that touches the item.

**And the follow-up measurement matters more than the first, so do not port the original rationale.**
At 20:30 the same probe found **24 of 24 trashable**, across three subtrees, two of which had never
been touched. The refusal is therefore a TRANSIENT state in the file-provider layer that clears on
its own — not, as this row first said, a permanent property of items registered long ago. Age was
what it *correlated* with inside one window, not a cause. What cleared it was not established; the
app was quit and reinstalled at 19:32, which is a candidate and unverified. Two consequences for any
line reading this: the retry is worth having because it works while the state is in force (5 of 5),
and a line that cannot reproduce the refusal has not disproved it — it has probably just measured
outside the window.

**Where each line stands, checked rather than assumed.** Positive control first — every line
carries the file, so an absence below is the shape missing, not the path mis-spelled:

```sh
for l in main v4.x v3.x v2.x; do
  git ls-tree -r --name-only origin/$l -- Modules/Sync/Sources/Sync/FileOperations.swift
done          # all four print the path
for l in main v4.x v3.x v2.x; do
  git show origin/$l:Modules/Sync/Sources/Sync/FileOperations.swift |
    grep -c 'isPermissionRefusal'                       # main 4; v4.x, v3.x, v2.x all 0
done
```

| Line | `isPermissionRefusal` | `trashViaWorkspace` | `trashNotPermitted` | `trashAfterReregistering` | Status |
|---|---|---|---|---|---|
| `v4.x` | 0 | 0 | 0 | 0 | RECORDED — not owed |
| `v3.x` | 0 | 0 | 0 | 0 | RECORDED — not owed |
| `v2.x` | 0 | 0 | 0 | 0 | RECORDED — not owed |

**The pick splits into three parts, and only the last one is self-contained.**

| Part | Needs | Note for a line taking it |
|---|---|---|
| `isPermissionRefusal` + `trashFailureDiagnosis` | nothing — both are pure `NSError` walks | Portable as-is. The chain walk is the point: Foundation wraps the POSIX cause, and the codes are what tell a TCC denial from a deny-delete ACL. |
| `SyncError.trashNotPermitted` + the alert | `SyncError` (all lines carry it) | **Do not port the earlier wording.** `4e94ddfe`/`14bc6bc3` sent the reader to System Settings for a grant that was measured not to help. Only `77e2bba6`'s text is true. |
| `trashAfterReregistering` | `FileManaging.moveItem` + `trashItem` — both present on every line | The genuinely independent piece: pure Foundation, no AppKit, no `DeleteOutcome`. |

**`trashViaWorkspace` is the one to think twice about.** It is a seam wired from the app
(`MacApp/SyncCloudApp.swift`) because `NSWorkspace` is AppKit and `LayeringPinTests` forbids Sync
importing it. On the evidence above it also *does not fix the reported case* — `recycle` refused all
12 files. A line taking only `trashAfterReregistering` and skipping the workspace seam would get the
measured benefit without the AppKit boundary problem, and that is the recommended shape.

**And a note for whoever ports the tests.** `MockFileManager.trashErrorOnce` clears on the first
throw, so it cannot express "every attempt denied" — a retry then passes merely because the injected
failure ran out. `main` added `trashErrorAlways` and `trashRefusedUntilMovedIn` for exactly that, and
without them the re-registration test cannot fail. Two existing tests on `main` had to be rewritten
onto `trashErrorAlways` when the third attempt landed; a line porting this will hit the same two.

**`v3.x` caveat, as everywhere in this file:** it has none of the `DeleteOutcome` family (item 1),
so `deleteItems` there still answers an `Int` and cannot report trashed-vs-destroyed. The refusal
family above does not depend on `DeleteOutcome` and would apply on its own — but the ⌘Z promise the
alert implies is still one that line cannot keep on a Trash-less volume.

---

## 2026-08-30 — Compare from the panes, region callouts, page stepping (`dee80cf7`, `fa494bdc`, `bbaa7986`, `6975cf4f`, `504debf7`)

**RECORDED — not owed**, for the same structural reason the Compare Copies row above gives: every
piece hangs off `FilePairCompareView`, and no maintenance line has it. Recorded anyway, because the
per-file reasoning is the expensive half to reconstruct and two of these pieces are portable in a
way the rest are not.

**The positive control first**, because a mis-spelled path answers "absent" on every line at once —
`FileTreeView.swift` is on all four, so the pathspec is right:

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s ' "$l"
  git ls-tree -r --name-only origin/$l -- \
    Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift \
    Modules/FileExplorer/Sources/FileExplorer/PaneComparePairMenu.swift | tr '\n' ' '; echo
done   # every line prints FileTreeView; only main prints the second
```

Checked 2026-08-30: `PaneComparePairMenu`, `ChangedRegionCallouts`, `PageDifferenceStepper` and
`DifferencesPairCompare` are absent from `v4.x`, `v3.x` and `v2.x`; `FileTreeView` is on all four.

| Piece | Depends on | Status |
|---|---|---|
| The panes' two Compare items (`PaneComparePairMenu`, two `FileActionDelegate` requirements) | `DifferencePair` + `FilePairCompareView` | RECORDED — not owed |
| `ChangedRegionCallouts` + `BitmapDiff.regions` | `BitmapDiff` | RECORDED — not owed |
| `PageDifferenceStepper` | `PageDiffState` + `PagePairRaster` | RECORDED — not owed |
| esc on the blocked overlay | `DifferencesPairCompareOverlay` | RECORDED — not owed |
| `TextPairDiff.refusalNote` / `estimatedCost` | `TextPairDiff` | RECORDED — not owed, but see below |

**Two pieces are portable in a way the others are not, and it is worth saying which.**
`ChangedRegionCallouts.fittedRect` is pure aspect-fit arithmetic over two `CGSize`s and imports only
`CoreGraphics` — any line drawing an overlay on a `.aspectRatio(contentMode: .fit)` image could take
it alone. And `TextPairDiff.estimatedCost` is a plain multiset pass over two `[String]`s; a line that
took `BoundedTextRead` and `TextPairDiff` on their own — which the row above already names as the
one genuinely independent pair — **should take the cost cap with them**. The byte cap bounds memory
and says nothing about time, the Myers pass is one `CollectionDifference` call with no loop to check
`Task.isCancelled` in, and two 4 MB rotated logs are minutes of a pinned core. Porting the diff
without the cap ports the wedge.

**And one thing that is a deletion rather than an addition.** `PagePairRaster.stripLongEdge` (72px)
is gone from `main`. It was written for a cheap sweep of a whole document's pages, and the sweep
cannot be honest: a downsampled comparison can prove two pages DIFFER but cannot prove they are the
same, since a one-pixel mark averages below the tolerance. On a strip whose rule is that a dot is a
claim somebody checked — which is why a pending page draws no dot — that sweep must not fill it. A
line that ever adds a page strip will meet the same question; the answer is in
`PageDifferenceStepper`'s doc, and the constant's absence is deliberate rather than an oversight.

**The selection invariant is on every line, and it is the reason the entry point is a right-click.**
`PaneLogic.applySelectionWrite` clears the other pane on every non-empty selection write, so "both
panes have a file selected" is unreachable by construction — and its empty-write carve-out names the
cross-pane "Copy '…' from ⟨pane⟩" menu as the reason it exists. Any line adding a cross-pane
affordance should reach for a context menu for that reason rather than relaxing the invariant.

---

## 2026-08-31 — The CC13 review's remaining risks (R2 and the R7 bundle)

**RECORDED — not owed, and this row is unusually easy to check**: two of the five files touched
(`FileOperations.swift`, `FileSyncManager+Duplicates.swift`) are on all four lines, so the shape of
the tree says nothing here — but none of the machinery each fix repairs exists off `main`.

**The positive control first**, because a mis-spelled symbol answers "absent" everywhere at once.
`isPermissionRefusal` is the newest of the five and `FileOperations.swift` is on every line, so a
run that prints nothing but `main` is measuring the symbol, not the path:

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s ' "$l"
  for f in FileOperations FileSyncManager+Duplicates; do
    git show origin/$l:Modules/Sync/Sources/Sync/$f.swift 2>/dev/null |
      grep -c 'trashAfterReregistering\|assessDuplicatePair\|isPermissionRefusal' | tr '\n' ' '
  done; echo
done   # main prints non-zero; every maintenance line prints 0 0
```

Checked 2026-08-31: `trashAfterReregistering`, `trashViaWorkspace`, `isPermissionRefusal` and
`assessDuplicatePair` are absent from `v4.x`, `v3.x` and `v2.x` — the whole three-attempt Trash
fallback and the whole single-copy pair verdict are `main`-only. `BoundedTextRead.swift`,
`CompareCopiesSheet.swift` and `PDFKitSerialAccess.swift` are absent as files (`PDFKitSerialAccess`
is on `v4.x` alone).

| Piece | Depends on | Status |
|---|---|---|
| R2 — `PairKeeperStanding`, keeper withdrawn when the group keeps a third copy | `CompareCopiesSheet` | RECORDED — not owed |
| R2 in the engine — `DuplicatePairVerdict.keeperNotKept` | the pair verdict | RECORDED — not owed |
| `recycled(_:in:)` / `recycledSingle(_:using:)` — the answer read past a re-spelt key | `trashViaWorkspace` | RECORDED — not owed |
| `isMidCloudTransfer`, and the delete path declining the park under it | `trashAfterReregistering` | RECORDED — not owed, but see below |
| `assessDuplicatePair` reordered — vanished copy first, keeper walked last | the pair verdict | RECORDED — not owed, but see below |
| `BoundedTextRead` BOM decoding, `readingNotes`, the truncated-unit fix | `BoundedTextRead` | RECORDED — not owed |
| `clearRasters` and the `PDFView` lane-doc exception | `CompareCopiesSheet` / `PDFPairView` | RECORDED — not owed |

**One of these is a rule the maintenance lines already follow elsewhere, and that is worth saying.**
The keeper-last ordering is not new — `driftedFolderInGroup` states it, with the measurement
(~0.7 s per 40k-node walk, and a verdict that ages from the moment it is formed), and the GROUP
resolve has followed it since long before any of these lines were cut. What was wrong was only the
PAIR verdict, which is `main`-only. So a maintenance line reading this owes nothing — but if one
ever grows a second walked verdict, the rule to copy is `driftedFolderInGroup`'s, not this commit's.

**And one is a narrowing rather than a fix, recorded so it is not read as one.** Declining the park
while iCloud reports the item uploading or downloading covers iCloud alone: `ubiquitousItemIsUploading`
and `ubiquitousItemIsDownloading` are iCloud's own signals, and a Dropbox or Drive item mid-sync
answers false and is not covered. Nothing is claimed beyond what those two keys measure.

**That narrowing also has a shape any line copying it must copy whole**, and it is the one thing in
this row that could do harm if half-ported. The refusal belongs to the DELETE path only. The move
primitives' cross-volume source cleanup reaches the same re-registration retry through
`retriedSourceCleanupTrash`, and there a refusal returns `false` and sends the caller to
`removeItem` — so declining to park would trade a source that reaches the Trash for one destroyed
outright, which is strictly worse for exactly the item the refusal exists to protect. That is why
the probe is a property on the manager (`isMidCloudTransfer`) read by `deleteItems`, and not a
parameter on `trashAfterReregistering`: a `nonisolated static` cannot reach an instance property,
so the move path cannot inherit it by accident. `TrashPermissionRefusalTests` pins both halves.

---

## 2026-08-31 — The CC13 nits (N1, N3, N4, N6, N9)

**One is owed and four are not, and the split is the useful part of this row.** Four of the five
repair claims made about the Compare Copies surface, which is `main`-only; the fifth repairs the
**Activity Log**, which every line has carried since long before any of them were cut.

**The positive control first.** `CompareCopiesSheet.swift` is absent as a file from all three
maintenance lines, so a scan for anything inside it answers "absent" whether or not the symbol is
spelled right. `LogViewer.swift` is the control that proves the run is measuring content:

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s log-strict:%s  compare-surface:%s\n' "$l" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/LogViewer.swift 2>/dev/null |
        grep -c 'String(contentsOf: fileURL, encoding: .utf8)')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/CompareCopiesSheet.swift \
        >/dev/null 2>&1 && echo present || echo absent)"
done
```

Checked 2026-08-31: every maintenance line prints `log-strict:1  compare-surface:absent`. `main`
prints `log-strict:0` — the strict read is the thing this batch removed.

| Piece | Depends on | Status |
|---|---|---|
| N1 — page counts reach the facts strip; the summary hedges while a row is pending | `CompareCopiesSheet` | RECORDED — not owed |
| N1 — `everyResolvedRowAgrees` deleted, the host's duplicate `ComparePairFacts.make` collapsed | `ComparePairFacts` | RECORDED — not owed |
| N3 — `LogHistoryLoader.repairingUTF8`, and `.unreadable` narrowed to read failures | `LogHistoryLoader` | **RECORDED — genuinely owed, see below** |
| N4 — `releases.html` "Still to come in v5.1" → "Not in v5.1." | the v5.1 article | RECORDED — not owed |
| N6 — paging scoped to PDFs in Help, notes and the page | the pair viewer | RECORDED — not owed |
| N9 — the ContentView comment about what surviving Settings restores | `compareFilePair` | RECORDED — not owed |

**The one that is owed, stated so a maintenance line can act on it without reading `main`.**
`LogHistoryLoader.loadOlderThan` reads the log with `String(contentsOf:encoding:.utf8)`, which
throws on the first byte that is not valid UTF-8 — and the loader maps a throw that is not
`NSFileReadNoSuchFileError` to `.unreadable`. So **one torn byte replaces the entire
previous-session history with an error note**, on every line, today. The fix is two lines: read
`Data`, and decode with `String(decoding:as: UTF8.self)` — the standard library's repairing
initializer, one U+FFFD per malformed sequence and everything either side kept.

Three things a porter needs that the diff alone does not say:

- **Foundation's `String(data:encoding:)` is not a substitute.** Measured on this fixture: for
  UTF-8 it returns `nil` for a character cut short — the same refusal, one layer down. For UTF-16
  it is quieter and worse, returning a clean string with the cut-short tail silently missing.
- **Rotation is not the source, so do not "fix" the writer.** `trimTailIfOversized` cuts at a
  newline, and a newline is always a character boundary. The reachable causes are an append cut
  short by a crash and the CLI writing the same file; the log carries file PATHS, so non-ASCII
  bytes are routinely in flight.
- **`.unreadable` must not become dead code.** After the change it means only "could not be read",
  and its own doc said "read or decoded". Keep an IO-failure test as the positive control — a
  directory at the log's path stages it with no permission games.

**Not backported, per the standing direction** (`e2b35dad`, 2026-08-26). This row is the record a
future audit needs, not a to-do.

---

## 2026-08-31 — The Edit workspace (`d33aeb31`, `8a60bb0c`, `7d48d95e`, `9dc4c0a9`)

A fifth workspace, and the first surface in this app that rewrites the CONTENTS of a file rather
than moving whole files. **RECORDED — not owed**, per the standing direction (`e2b35dad`), and the
easiest row in this file to be confident about: none of it exists on `v4.x`, `v3.x` or `v2.x`, and
none of it is a fix to something they carry.

```sh
# Positive control first — the path must be found somewhere, or absence proves nothing.
git ls-tree -r --name-only origin/main -- Modules/FileExplorer/Sources/FileExplorer/EditorFileStore.swift
for l in v4.x v3.x v2.x; do
  echo "$l: $(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorFileStore.swift | wc -l) file(s)"
done   # expect main 1, every maintenance line 0
```

**Why this one is not a candidate even if the direction changed.** It is not a defect fix with a
narrow diff; it is ten new source files, a new external dependency the app *links*
(`swift-markdown` plus three pins), a fifth `Workspace` case — which is a persistence format and a
positional ⌘-digit — and a window floor raised 760 → 810. A maintenance line taking it would be
taking a feature, and the lines exist to carry fixes.

**Three pieces inside it are separable, and none of them applies either.** Worth naming so a future
audit does not have to re-derive that:

| Piece | Applies to a maintenance line? |
|---|---|
| `BoundedTextRead.TextEncoding` gains `CaseIterable` | No — the enum itself arrived on `main` after `v4.x` was cut |
| `PaneLogic.relativePath(of:under:)` | No — new member, no existing caller on any line |
| The window floor 760 → 810 | No — it pays for a fifth bar segment those lines do not have. `v4.x` is at 760 and `v3.x`/`v2.x` are still at **600**, which is its own gap and an older one — see the workspace-bar row above; this change does not close it |

**What the maintenance lines therefore cannot do**, stated the way item 1 states the `DeleteOutcome`
gap: they have no way to edit a file's contents at all. There is no Edit workspace, no ⌘S, no
in-app text surface — a user on `v4.x` who wants to change a line in a note leaves the app for it.
That is the shape of the gap, and it is a feature gap rather than a correctness one.

**A follow-up on the same workspace, `fadb6a03` — equally not owed, for the same reason.** The Edit
rail's rows were built with the `.inline` hover variant, which is documented for a dismiss glyph
inside a field and defaults to a CIRCLE — so hovering a file drew a grey disc in the middle of the
row instead of a wash across it, and the selected arm traced a capsule ring around a rounded
rectangle. The file it changes does not exist on any maintenance line.

**But the CLASS of defect is portable, and that is the part worth writing down.** Which
`HoverAffordanceVariant` a control should wear is decided per call site by hand — `HoverAffordanceTests`
pins each variant's own metrics and nothing checks the pairing — so a row wearing `.inline`, or any
`.segment`/`.filled` arm left on its default capsule over a non-capsule ground, is invisible to the
suite on every line. The twenty other `.inline` call sites **on `main`** were censused at the same
time and are all genuine dismiss or clear glyphs. **That census was not run against `v4.x`, `v3.x`
or `v2.x`** — those lines carry older call sites this one never saw, and a maintainer auditing hover
treatment there should run it rather than inherit this row's answer:

```sh
git grep -n 'hoverAffordance(' origin/v4.x -- '*.swift' | grep '\.inline'   # then read each one
```

**Autosave, `dcc0303c` — not owed, and it does not widen the shared surface.** The editor now writes
two seconds after the typing settles and flushes at every route out; the unsaved-changes prompts it
replaced were all editor-only. Worth checking rather than assuming, because the change touches
`SyncCloudApp`'s quit guard, which every line has: what it touches there is the `hasUnsavedDocument`
input, and that parameter arrived with the Edit workspace and exists on no maintenance line — their
`quitDecision` still takes two arguments.

```sh
git show origin/v4.x:MacApp/SyncCloudApp.swift | grep -c hasUnsavedDocument   # expect 0
```

The one idea in it a maintenance line could want independently is the **latch**: an alert raised
from a debounced retry has to record that it was already declined, or it returns on every restart of
the timer. Nothing on those lines raises an alert from a retry today, so there is nothing to port —
recorded because it is the kind of defect that is invisible until somebody adds one.

**The autosave follow-ups, `9d708f4b` and `7338070a` — same verdict, recorded compactly.** The
header shows pending as well as written (a status that only ever said "saved" is not evidence of
anything), the rail marks the unsaved file the way BBEdit marks its open documents, and `write` now
checks the read-back stat it was already taking: the file must be exactly as long as the bytes
handed to it, so the documented swap-then-stat race becomes a question instead of a buffer marked
clean against somebody else's file. All editor-only.

**One line in there is worth a maintenance line's attention even so**, because it is not about the
editor: the pattern of an unconditional shape with a clear fill as a layout RESERVATION. An `if let`
around it is the tidy-up that silently removes the reservation, and no rendered test on a
hard-framed container can catch it — both mutations were run and neither moved a pixel. Anywhere a
marker appears and disappears in a list row, on any line, the same trap is available.

**`46705cc9` — SPLIT VERDICT, and one part is genuinely owed.** Three fixes landed together; two
are editor-only and the third is not.

| Piece | Applies to a maintenance line? |
|---|---|
| "Reload from Disk" in the changed-on-disk alert | No — the alert arrived with the editor |
| `drawsAPaneList` for a collapsed lens rail | **YES, all three lines** — see below |
| `refreshAction`'s silent skip, and completing a stranded launch refresh | **YES, all three lines** |

**The silent skip is the one to send if the direction ever changes.** `refreshAction` returns
without starting anything when a pane names a source `enabledProviders` has not published yet, and
says nothing about it — at launch that is ordinary rather than exotic, because both pane ids are
`@AppStorage` restored before discovery finishes. Nothing else walks the tree either: the
provider-arrival handler returns early while the bootstrap guard is up, which is exactly the window
in question. The pane then draws whatever an earlier refresh left in it, under a breadcrumb that
names the right folder. Every line has this shape:

```sh
for l in v4.x v3.x v2.x; do
  echo "$l: $(git show origin/$l:MacApp/ContentView.swift | grep -c 'private func refreshAction')"
done   # expect 1 each — then read the guard: a bare `return` with no log is the defect
```

The fix is two parts and the ORDER is the load-bearing half: the bootstrap records that the refresh
did not start, and the arrival of the sources completes it **above** the bootstrap guard. Below it
the completion never runs, because the guard is up for precisely the window the flag is set in.

**The collapsed-rail half is owed in EFFECT rather than in code, and to all three lines.**
`drawsAPaneList` exists on none of them — it arrived with the Edit workspace — so there is nothing
to port literally. What they have is the defect: ⇧⌘N opens a naming row and ⇧⌘P toggles a preview
column while a single-source rail is collapsed to its spine, because both are gated on `layoutMode`,
which cannot tell a rail from a spine.

**Checked, because the first draft of this row said `v3.x` and `v2.x` predate the collapsible rail
and that is wrong.** All three carry `ContentLayout.singleCollapsed` and resolve it the same way —
`panesHiddenForCurrentTab ? .singleCollapsed : .singleExpanded` — at `v4.x:1405`, `v3.x:898` and
`v2.x:861`. A porter needs a `drawsAPaneList` of their own, or the same question asked inline at the
two chords; there is no patch to cherry-pick.

**Two corrections landed alongside it that DO touch shared code**, and both are recorded here
because a reader scanning for "did anything in this batch reach existing surfaces" would otherwise
have to read the whole diff:

- **`FileActionDelegate` gains `handleOpenInEditor` as a REQUIREMENT**, not a defaulted extension
  member. Every conformer on `main` answers it. A line taking any later change to that protocol
  needs to know the shape differs.
- **Nine source files and several suites had their window-floor prose corrected** 760 → 810, two of
  them (`SettingsLayout`, `SettingsView`) where the CONCLUSION flips: 810 less `hostMargin` is 762,
  which is two points MORE than the settings sheet wants, so the width clamp no longer bites at the
  floor. On a maintenance line the old sentences are still true, because the old floor is still
  theirs. **Do not port that prose** — it would make their comments describe a window they do not
  have.

## 2026-08-31 — Storage folds into Organize (`66bf9513`, `89910d6a`, `c6eef8fb`, `c0d96eeb`, `14f86c25`, `dc665a7d`)

Storage stops being a workspace and becomes Organize's sixth rail item. **RECORDED — not owed**,
per the standing direction (`e2b35dad`).

**Unlike the Edit-workspace row above, this one is genuinely APPLICABLE to `v4.x`, and the reason
it is still not owed is different.** The first draft of this entry claimed `OrganizeLens` does not
exist on any maintenance line. That was wrong, and the positive control below is what caught it —
run it rather than trusting the prose:

```sh
# Positive control first — the path must be found somewhere, or absence proves nothing.
git ls-tree -r --name-only origin/main -- Modules/FileExplorer/Sources/FileExplorer/OrganizeLens.swift
for l in v4.x v3.x v2.x; do
  echo "$l: $(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/OrganizeLens.swift | wc -l) file(s)"
done   # measured 2026-08-31: main 1, v4.x 1, v3.x 0, v2.x 0
```

**What each line actually carries**, measured rather than assumed:

| Line | `OrganizeLens` | Lens cases | `Workspace.storage` | Window floor |
|---|---|---|---|---|
| `main` (pre-fold) | yes | 5 | yes, 4th of 5 segments | 810 |
| `v4.x` | **yes** | **5, identical** | **yes, 4th of 4 segments** | **760** |
| `v3.x` | no | — | — | 600 |
| `v2.x` | no | — | — | 600 |

So `v4.x` is the same shape this change was made against: five lenses with Rules already exempt
from `carriesBadge` and `isScoped`, and a `Workspace.storage` case sitting in the bar. The fold
would apply there almost verbatim.

**It is still not owed, and the reason is the rule rather than the diff: this is a BREAKING
change, and `v4.x` never takes one.** Retiring `Workspace.storage` changes a persisted raw value
and renumbers a ⌘-digit — someone on `v4.x` who quit in Storage would reopen somewhere else, and
⌘4 would stop meaning what it meant. That is precisely the class of change the maintenance lines
exist to be free of. It is also a feature move, not a defect fix; nothing here repairs anything
`v4.x` gets wrong.

**`v3.x` and `v2.x` are a different answer again:** they predate the lens rail entirely, so there
is no sixth rail item to add. Not applicable rather than not owed.

**Four pieces inside it, and what each one would mean on `v4.x` if the direction ever changed:**

| Piece | Applies to `v4.x`? |
|---|---|
| `Workspace.storage` retired + `"Storage": .storage` in `retiredWorkspaceRawValues` | Structurally yes — **breaking**, per above. This is the piece that makes the whole batch ineligible |
| `OrganizeLens.storage` + the badge/scope split | Yes, and **non-breaking on its own** — it adds a rail item and separates `carriesBadge` from `isScoped`. Would be a coherent partial pick if a Storage lens were ever wanted there *beside* the tab |
| `StorageSectionBar` (the section capsule) | Only alongside the piece above; on `v4.x` the storage rail still has the header slot to itself, so the capsule would solve a problem that line does not have |
| `OrganizeOverviewState.receipt` + the overview card | Yes, and non-breaking — but it describes a lens `v4.x` would not have |

**The window floor 810 → 760 is the row to read twice.** `main` returning to 760 makes it *agree
with `v4.x` by coincidence*, not by anything ported: `v4.x` is at 760 because it has four segments
and never had a fifth, while `main` is at 760 because it went to 810 for Edit and came back when
Storage left. The 600 floor on `v3.x`/`v2.x` is untouched and is still its own older gap — see the
workspace-bar row above. **Do not port the floor prose in either direction**: on `v4.x` the 760
sentences are true for a different reason, and the derivation `main` now carries names segments
that line does not have.

**What the maintenance lines therefore cannot do:** `v4.x` can reach Storage, just not from
Organize — it is a tab, with its own rail, its own header slot, and no scope chip, so a scoped
storage analysis is not available there. `v3.x`/`v2.x` have no storage lens at all. All of it is a
navigation and capability gap, not a correctness one.

**One correction landed alongside it that touches shared prose**, recorded because a reader
scanning for "did anything reach existing surfaces" would otherwise read the whole diff: the
**window-floor prose was swept 810 → 760 across fourteen files**, two of them (`SettingsLayout`,
`SettingsView`) where the CONCLUSION flips back — 760 less `hostMargin` is 712, two points less
than the settings sheet wants, so the width clamp bites again. `v4.x` is at 760 and its settings
prose already says the clamp bites; nothing to port.

**Also corrected in passing, and equally not owed:** `OrganizePass`'s doc said the file pass
publishes "three" lenses where the code has said two since risky names became rows inside Renames.
Prose-only — `answersOneLens` counts `lenses`, so nothing depended on the number. **This one IS a
one-line prose fix that would apply cleanly to `v4.x`**, whose copy carries the same error; it is
recorded here rather than picked, per the standing direction.

## 2026-09-01 — the person axis is compared by spelling, not by identity (`33a2b379`) — not owed, and the cleanest pick in this file

`thePersonAndLifecycleAxesAgree` compared `axes["person"]` with a raw `==`. Every consumer of that
value resolves it through `PersonRegistry.person(forAxisValue:)`, whose matcher lowercases, so
`Daughter` and `daughter` are one person to the app and two to the test. On the live tree that was **477
of 5019 folders, all of them case alone** — 0.905 against a 0.99 floor, with the roster complete and
every attribution correct.

```sh
# Positive control first — the expression must be found somewhere, or absence proves nothing.
for l in main v4.x v3.x v2.x; do
  echo "$l: suiteFile=$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Tests/Sync/FolderSurveyGroundTruthTests.swift | wc -l)" \
       "rawCompare=$(git show origin/$l:Modules/Sync/Tests/Sync/FolderSurveyGroundTruthTests.swift 2>/dev/null | grep -c 'check(axis, a == b')"
done   # measured 2026-09-01: main suiteFile=1 rawCompare=0 (fixed); v4.x 1/1; v3.x and v2.x 0/0
```

**`v4.x` carries the suite and the bug.** `v3.x` and `v2.x` have neither — the ground-truth suite
arrived after they were cut.

**Not owed, per the standing direction — but this is the one row here that would pick cleanly.** It
is test-only, non-breaking, touches no shipping code, and the file it changes exists on `v4.x` at
the same path. Recorded rather than picked, and the reason to know it: **the suite is machine-pinned
and never runs on CI**, so `v4.x` will look green forever and go red the moment someone runs
`Modules/Sync` locally on a machine whose active profile was built from the profile's own tokens
rather than from `people.json` — which is this Mac. A maintainer meeting that red will read 0.905 as
data corruption, because that is exactly what it looks like.

**The expensive part is what the red invites you to do.** The recorded diagnosis for this failure
said one survey refresh would repair it. It would not: `resurveyFilingMemory` never touches the
folder profile, and the only paths that rebuild the person axis are `deriveFolderProfile`, which
writes a fresh profile with no `carryOver` and drops the filing memory (2309 folders here), and the
restructure landing, which moves files. A maintainer on `v4.x` acting on that red would pay one of
those prices to fix a spelling the app ignores. That is the whole reason this row exists.

## 2026-09-01 — two flake findings and a correction to `flaky-tests.md` (`7aa4fa82`) — not owed, but `v4.x` carries the wrong claim

Docs only, and the most *pickable* row in this file — which is exactly why it needs writing down
rather than quietly picking. `docs/flaky-tests.md` is carried on all four lines precisely so a
maintainer can read it without going through `main`, so a correction that lands only here leaves
the other copies asserting something known to be false.

**What `v4.x` carries, measured rather than assumed:**

```sh
# Grep for the CORRECTION, not for the wrong sentence. The wrong sentence still appears on
# `main` — quoted inside the correction that repeals it ("This section said …") — so counting
# it returns 1 on `main` and 1 on `v4.x` and cannot tell a repealed claim from a live one.
# That is the first control this row shipped, and it was useless; recorded because the same
# shape is worth avoiding elsewhere in this file.
for l in main v4.x v3.x v2.x; do
  echo "$l: corrected=$(git show origin/$l:docs/flaky-tests.md 2>/dev/null | grep -c 'Corrected 2026-09-01')" \
       "suite=$(git grep -l FolderSurveyGroundTruthTests origin/$l -- Modules/Sync/Tests 2>/dev/null | wc -l)"
done   # measured 2026-09-01: main corrected=1; v4.x corrected=0 suite=1; v3.x and v2.x both 0
```

| Finding | `v4.x` | `v3.x` / `v2.x` |
|---|---|---|
| **Mechanism 17's claim is wrong** — the rendezvous that replaced the sample floor is bounded by a 10 s wall-clock deadline, so it traded a throughput bet for a latency one | **Applies.** Carries `noUndoGroupIsEverOpenWhileTheMergeIsSuspended` **and** the sentence verbatim | Neither the test nor the claim |
| **Mechanism 20** — a `.machinePinned` suite leaving the denominator when the display sleeps mid-batch, making a deterministic failure look intermittent | **Applies.** Carries `FolderSurveyGroundTruthTests` and the same display gate | No ground-truth suite |
| **Mechanism 10's new live instance** (`RestructureApplyGuardTests`) | No — that suite is `main`-only | No |

**Not owed, per the standing direction, and the numbering is why picking it would be awkward
anyway.** The lines carry **19 / 19 / 11 / 12** mechanisms respectively, so "mechanism 17" and
"mechanism 20" name different things depending on where you are standing — which is the reason
CLAUDE.md says to cite these by title and never by number. A pick would have to renumber, and this
file's own convention is that its numbering is per-line.

**What a `v4.x` maintainer is therefore told, wrongly, until this is picked or re-derived:** that
`noUndoGroupIsEverOpenWhileTheMergeIsSuspended`'s load-dependence was fixed on 2026-08-23 and that
no amount of load can defeat the replacement. It can — observed on `main` 2026-08-31 in a full
`Modules/Sync` run at loadavg 20–42 beside another session's `xcodebuild`. If that test ever reds on
`v4.x` on its `sampledDuringTrash` premise with everything substantive green, this row is the
answer, and the section there will actively point away from it.

## 2026-08-31 — the Storage fold's review fixes (`c851b661`, `8836023a`) — not owed, with one caveat

An adversarial review of the fold above found one shipped bug and one gap. Both are **fixes to code
that only exists on `main`**, so neither is owed — but the caveat is worth reading, because one of
them adds API to a type the maintenance lines do have.

**The bug: a scope change left the previous root's report on screen.** `restoreStorageLens` refuses
while a report is in hand, so the scope trigger the fold added was declined and the chip said one
folder while the treemap showed another's proportions. Unreachable on any maintenance line — none
of them has a Storage lens inside Organize, so none has a scope that could contradict one.

**The caveat: `OrganizeAim.storageReportStandsUnder(scope:reportRoot:)` is new public API in
`Modules/Sync`, and `v4.x` has `OrganizeAim`.** So this is the one piece here that would *compile*
there. It is still not owed: it is additive, it has no caller on those lines, and a predicate with
no caller is the shape this repo has learned to distrust (see the tested-rule-with-no-caller
entries). Named so an audit does not read "Sync gained a function" and assume a gap.

```sh
# Positive control first — the symbol must be found somewhere, or absence proves nothing.
git grep -c storageReportStandsUnder origin/main -- Modules/Sync/Sources/Sync/OrganizeScope.swift
for l in v4.x v3.x v2.x; do
  echo "$l: $(git grep -c storageReportStandsUnder origin/$l -- Modules/Sync/Sources/Sync/OrganizeScope.swift 2>/dev/null || echo 0)"
done   # main 1; the maintenance lines 0, and nothing there would call it
```

| Piece | Applies to a maintenance line? |
|---|---|
| The clear-then-restore in `restoreStorageLensIfShowing` | No — `selectedOrganizeLens == .storage` names a lens those lines do not have |
| `OrganizeAim.storageReportStandsUnder` | Compiles on `v4.x`; **no caller there**, so picking it would add a tested rule nothing reads |
| The Analyze verb on the overview's stranded line | No — `OrganizeOverview` is v5-only |
| The receipt card's generic title, the cached formatters, three comment corrections | No — all inside fold-only code |

**`FolderSurveyGroundTruthTests` was red throughout this work and is not related to it.** The person
axis measures **0.905** against a 0.99 floor, reproduced identically at `origin/main` with none of
these changes. It is live-profile data rather than code: the re-derive bug that impoverished the
axis was fixed on 2026-08-29, but the profile on disk still carries what it wrote, and a survey
refresh rebuilds it from `people.json`. Recorded here because a future audit running the Sync suite
will meet it and should not spend time bisecting for it.

## 2026-08-31 — the mode capsules' glyph boxes did not grow with the text size (`1a1af60f`) — CLOSED, does not apply

`EditorModeBar` and `StorageSectionBar` each drew their SF Symbol as
`.scaledFont(.system(size: 10, weight: .medium))` inside a hard `.frame(width: 13, height: 13)`.
The glyph grew with Settings ▸ Text size; the box did not — so the glyph-only rung measured **85pt
(Editor) and 113pt (Storage) at Small, Default, Large and Largest alike** — and since `.frame` does
not clip, an enlarged glyph overflowed its box rather than being trimmed by it. Fixed by scaling
the box by the same factor the glyph uses, in a shared `CapsuleGlyph`.

**Neither control exists on any maintenance line, so there is nothing here to send.** This is the
rare row where stage 1 and stage 2 disagree in the useful direction: `StorageLensView.swift` *is*
present on all three lines, which is exactly the shape that reads as "already there" if the file
check is the only one run.

```sh
git ls-tree -r --name-only origin/main -- \
  Modules/FileExplorer/Sources/FileExplorer/EditorMode.swift \
  Modules/FileExplorer/Sources/FileExplorer/StorageLensView.swift    # positive control: both found

for l in v4.x v3.x v2.x; do
  git ls-tree -r --name-only origin/$l -- \
    Modules/FileExplorer/Sources/FileExplorer/EditorMode.swift       # absent on all three
  git ls-tree -r --name-only origin/$l -- \
    Modules/FileExplorer/Sources/FileExplorer/StorageLensView.swift  # PRESENT on all three
  git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/StorageLensView.swift |
    grep -c 'StorageSectionBar'                                      # 0 on all three
done
```

`EditorMode.swift` arrived with the Edit workspace and `StorageSectionBar` with the Storage fold,
both on `main` this week — the two sections immediately above. **What each line has instead differs,
and only one of them has a switcher at all:**

- **`v4.x`** draws Storage's switcher as a header **rail**, built from
  `RailItemLabel(title:systemImage:)` in `LensWorkspaceView.storageRailItem`. Its glyph is a
  `Label`'s `systemImage`, so there is no framed `Image` for a hard box to be wrong about.
- **`v3.x` and `v2.x`** have no switcher of any kind. `StorageSection` is there, but only as a
  collapse key (`@State collapsed`) and a heading over `listSection(_:entries:)` — the three lists
  are one scroll, which is what they were before the rail existed.

`grep -c 'frame(width: 13, height: 13)'` over `Modules/FileExplorer` returns zero on all three
lines, so the defect is absent in renamed form as well as by name.

**What the lines DO carry is the pattern, elsewhere.** A scan for a `.scaledFont` with a nearby
square `.frame` found roughly a dozen other sites on `main` — `OrganizeOverview` (×5),
`DifferencesView` (×3), `CloseButton`, `PersonView`, `EditorFileRailView`, `DestinationPicker`,
`SettingsView` (×2), `HelpBook`, `SetupSheet` — and several of those files are old enough to be on
every line. **They are not audited and this row does not claim they are defects**: a box generous
enough that a 1.35× glyph still fits is a reservation, and pinning it is correct. Measuring each
with `NSHostingView.fittingSize` across the four scales is what would settle it, and none of that
was done here. Recorded so a future audit knows the question was seen and left open, not answered.

**The transferable lesson, which is cheaper than the fix.** Both bars had a growth test —
`theCapsuleGrowsWithTheAppsTextSize` — and both stayed green for the life of the defect, because
each measured the **labelled** rung only. That rung's words are `Text`, so it scaled the whole
time. Both bars also had *ceiling* checks on the glyph rung (fits a 260pt document column / a 340pt
lens column), and a control pinned at one size passes any ceiling at the size it was tuned for. **A
rung the ceiling checks ask about is a rung the growth check has to ask about too.** Any line that
grows one of these controls should carry the pair, not the ceiling alone.

## 2026-08-31 — the editor's first mode is labelled "Source", not "Edit" (`56f619f5`) — CLOSED, does not apply

`EditorMode.title` for `.edit` returns **"Source"**, so the editor's mode capsule reads
Source / Preview / Split. The app has three controls reading "Edit" — the menu bar's, the workspace
bar's, and this segment — and this was the only one that could move: the menu is an AppKit
convention and `Workspace.title` had already weighed the workspace against it and taken the cost.
The segment is the tightest of the three anyway, because it sits *inside* the Edit workspace.

**Nothing is owed.** `Modules/FileExplorer/Sources/FileExplorer/EditorMode.swift` is absent on
`v4.x`, `v3.x` and `v2.x` — the file arrived with the Edit workspace, on `main` this week — so
there is no capsule on any maintenance line to relabel. Same absence the row immediately above
established for `1a1af60f`, and it is checked the same way; the positive control matters for the
same reason:

```sh
git ls-tree -r --name-only origin/main -- \
  Modules/FileExplorer/Sources/FileExplorer/EditorMode.swift    # positive control: found

for l in v4.x v3.x v2.x; do
  git ls-tree -r --name-only origin/$l -- \
    Modules/FileExplorer/Sources/FileExplorer/EditorMode.swift  # prints nothing on all three
done
```

The other seven files in the change are prose about that capsule — the Help article, the README,
`ContentView` and `EditorWorkspaceView` doc comments, `EditorLayoutTests`, and the **still-draft**
v5.2 sections of `RELEASE_NOTES.md` and `docs/releases.html`. None of it describes anything the
maintenance lines carry, so none of it applies either. The notes were corrected rather than left
standing because v5.2 is unreleased; had it been cut, the shipped text would have been left alone.

**What is worth carrying forward is the measurement, not the label.** The rename cost 15–20pt on
the labelled rung (183 · 192 · 220 · 231 → 198 · 208 · 239 · 251 across Small · Default · Large ·
Largest) and nothing on the glyph rung. That pushed the capsule over a boundary at the narrowest
window the app allows: at the 760pt floor with the sidebar at its 150pt minimum, the words now shed
at **135% alone**, where 251 + a 120pt name allowance is 371 against a 368pt column. Three points.
**It took two changes to get there** — this rename and `1a1af60f`'s glyph-box scaling, which landed
hours apart and neither of which crossed it alone. A line that ever takes both should re-measure
rather than assume the pair is free.

**The transferable lesson.** The guard that pins this is
`EditorLayoutTests.theWordsShedAtTheNarrowestWindowOnlyAtTheTopOfTheTextRange`, and it sweeps
`FontSize.selectablePercents` — every step the slider lands on from 90 to 135 — rather than
`FontSize.allCases`, which is the four *named* presets. The turnover is at **130**,
which is not a preset: a four-row table would have reported "Large fits, Largest does not" and left
the six steps between them unmeasured, including the one that actually matters. Any control whose
width is checked against a text size should be swept over the selectable set, not the named one.

## 2026-08-31 — two more glyph boxes that did not grow with the text size — OWED to `v4.x`, does not apply to `v3.x`/`v2.x`

The row above (`1a1af60f`) fixed `EditorModeBar` and `StorageSectionBar` and left a question open:
"roughly a dozen other sites on `main` pair a `.scaledFont` with a square `.frame`, several in files
old enough to be on every line… none were measured." **They have now been measured, and the answer
is two.** Of the fourteen sites that are a square box around a single SF Symbol, twelve are fine and
two are defects — and both of those exist verbatim on `v4.x`.

**The measurement that decided it is ink, not `fittingSize`.** `Image(systemName:)` reports its
symbol's layout box, side bearings included, which overstates drawn ink by 3–5pt at these sizes.
Six of the fourteen sites read as overflows under `fittingSize` and are clean when the pixels are
rendered and read back. Anyone re-running this sweep on a maintenance line should render, not
measure — a `fittingSize` table would report six defects here, four of them imaginary.

### What is owed

Both are on `main`, in the commits *Hoist the scaled glyph box into one rule* (the shared
`FontSize.scaledBox`), *Let the pass-lens column grow across as well as down*, and *Widen the
setup step's disc to hold the symbols it actually draws* — named rather than cited by SHA,
because a rebase renumbers and this file outlives the branch that wrote it.

1. **Organize's pass-lens column** — `passLensRow` framed its lens symbol `.frame(width: 14)` with
   no height, so the box grew *down* with the type ramp and not *across*: 14×12 at Small, 14×16 at
   Largest. Rendered, the widest lens symbols put **10.8pt² of ink outside the column at Large and
   21.0pt² at Largest**. Small and Default are clean, which is why it went unseen.
2. **The setup card's step mark** — a 22pt symbol in a hard `.frame(width: 30, height: 30)` behind a
   `Circle()`. **Wrong at the default text size**, not only away from it: `person.2` draws **15pt²**
   outside the disc and `folder.badge.gearshape` **13pt²**, at Default, Large and Largest alike.
   22pt is above `FontSize.knee`, so the ramp clamps it and the glyph never grows past Default —
   scaling a 30pt box would have left three of the four sizes exactly as broken. The diameter had to
   change; 34 is the smallest that holds all five step symbols clean.

The second is the one worth a maintainer's attention: it is a visible defect on the **first screen a
new user sees**, at the size everybody runs.

### Checked, and present

Stage 1 (the file) and stage 2 (the symbol) agree on all three lines, and stage 3 — the pinned frame
itself — is what confirms the defect rather than just the call site:

```sh
for l in v4.x v3.x v2.x; do
  echo "== $l"
  git ls-tree -r --name-only origin/$l -- \
    Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift MacApp/SetupSheet.swift
  git show origin/$l:MacApp/SetupSheet.swift 2>/dev/null |
    grep -A5 'private func stepHeader' | grep 'frame(width: 30'
done
```

- **`v4.x` — both files present, both defects present verbatim.** `passLensRow` carries the same
  `.frame(width: 14)` under the same `.system(size: 10, weight: .semibold)`; `stepHeader` carries the
  same `.frame(width: 30, height: 30)` under the same `.system(size: 22)`. The symbol sets match too,
  which is what makes the measurements transfer rather than merely the code shape: `SetupFlow.Step`
  is the identical five including `person.2` and `folder.badge.gearshape`, and `OrganizeLens` is five
  rather than `main`'s six (no `.storage`) but still includes `folder.badge.gearshape`, the offender.
  `FontSize.scaledPointSize` is present, so the fix would port without its dependency.
- **`v3.x` and `v2.x` — neither file exists.** Nothing is owed; there is no Organize overview and no
  setup sheet on either line.

Recorded rather than picked, per the standing direction.

### The transferable lesson, which is about the tests and not the boxes

`EditorLayoutTests` asked whether the mode capsule grew with the text size and went green over a
rung pinned at 85pt at all four sizes — because it asked it of the **labelled** rung, whose words
are `Text` and which scaled the whole time. A composed row's width is mostly text, and text scales;
asking a row whether it grew answers about the text and says nothing about the box beside it. **A
growth test has to measure a view whose width IS the pinned dimension.** That is why the fixes here
each introduce a named glyph view rather than editing a `.frame` in place — not for reuse, but so
there is something a test can address.

Two further habits came out of it, both of which the sites on `v4.x` would need if this is ever
picked. Containment is swept from `allCases` of the symbol enum rather than a hand-written list, so
a new lens or a sixth setup step is covered the day it is added. And it is swept over
`FontSize.selectablePercents` — all ten stops from 90 to 135 — not `FontSize.allCases`, which is the
four *named* presets: the row above records the Editor capsule's shedding boundary turning over at
**130**, which is not a preset, and a four-row table would have missed it.

## 2026-09-01 — Text and markup in the Edit workspace

`main` gained the in-window half of the Edit workspace's text and markup work: source lines through
the Markdown walk and front matter split off before parsing (`e102505b`), the task toggle and the
markup verbs as pure functions (`6ad2c9e2`), the document's status line (`c7968b42`), the text
view's new seams and AppKit's find bar (`f0135694`), the outline, the rail filter and the find
button (`6755c2c0`), and the Help and ⌘/ text that describes them (`baba5de4`).

**Nothing is owed to any maintenance line, and the reason is the same for all three: none of them
has an editor at all.** This is the cheap half of the audit and it is worth writing down, because
"the Edit workspace is v5-only" is exactly the kind of claim a future session would otherwise have
to re-establish from the branch table.

```sh
for l in v4.x v3.x v2.x; do
  echo "== $l"
  git ls-tree --name-only origin/$l Modules/FileExplorer/Sources/FileExplorer/ |
    grep -E 'Editor(WorkspaceView|Document|Rail)\.swift|Markdown(Blocks|Preview)\.swift'
  git show origin/$l:MacApp/Workspace.swift | grep -c 'case editor'
done
```

- **`v4.x`, `v3.x`, `v2.x` — no editor sources, and no `Workspace.editor` case.** The listing prints
  nothing and the count is `0` on each. Every file this batch created is new to `main`, and every
  file it changed except two exists on those lines only in a version that has no editor in it.

### The two shared files, checked rather than assumed

`MacApp/ShortcutsReference.swift` and `MacApp/HelpBook.swift` are carried on all four lines, so a
change to either is the kind that *looks* portable. Neither is.

- **The ⌘Z row is already right on the maintenance lines, and picking the correction would make it
  wrong.** `main`'s row read `Undo / redo the last file operation (not typing)` and now reads
  `Undo / redo — the last file operation, or your typing in Edit`, because the Edit workspace
  arrived with an undo stack for precisely the typing the parenthesis excluded. All three
  maintenance lines read `Undo / redo the last file operation` — **no parenthesis at all**, which is
  the complete and correct sentence on a line with no editor. Nothing to pick.
- **The Help topic does not exist there.** `editor-workspace` is a `main`-only topic; the bullets
  added to it have no home on a line without one.

Recorded rather than picked, per the standing direction.

### What is NOT here, and is not owed either

The menu-bar half of this work — a Text menu, a Markup menu, ⌘F routing to the open document, the
view-mode items, and chords for the markup verbs — **was deliberately not built**, on his
instruction of 2026-09-01: *"No changes to menu bar right now. We will decide this when we work on
menu bar."* One decision is settled in advance and belongs with that batch when it happens: **⌘I
becomes Italic when the editor's own document view has focus, and the Info inspector everywhere
else.** `TextEditingChord` is the wrong test for it — it asks whether the first responder
`is NSTextView`, which is true of every field editor in the window, so Italic would fire into the
Go-to field.

That is why the Markup context menu carries **no key equivalents** and the ⌘/ reference's new row
says `Right-click` rather than a chord: the keys belong to menu items that do not exist, and a
reference listing `⌘B` for a chord nothing registers would be the one place in the app that lies
about the keyboard.

## 2026-09-01 (later) — ⌘F routes, and the find bar gains its Replace row

`af233139`. Two things: `PlainTextEditor.showFindBar` sends
`NSTextFinder.Action.showReplaceInterface` rather than `.showFindInterface`, because the latter
builds the Replace field and then leaves it `isHidden` at y = -22 with no control in the bar to
reveal it — so the button promising "find and replace" opened a bar that could only find. And ⌘F
now routes: with the caret in the open document it opens that bar, and everywhere else it is the
pane search it has always been.

**Nothing is owed, and this time two of the three files involved DO exist on the maintenance
lines** — which is exactly the case where "not owed" has to be established rather than assumed.

```sh
for l in v4.x v3.x v2.x; do
  git show origin/$l:MacApp/ContentView+PaneSearch.swift 2>/dev/null | grep -c 'Find in Pane…'
  git show origin/$l:MacApp/ShortcutsReference.swift | grep -o 'Find a file or folder[^"]*'
done
```

- **`PlainTextEditor` and `EditorDocumentSurface` are `main`-only.** No maintenance line has an
  editor at all — established in the entry above — so the Replace-row fix has no site to be applied
  to. The whole of `EditorDocumentSurface` is new.
- **`v4.x` and `v3.x` carry `FindInPaneCommand`, and their version is already correct.** Both hold
  the item titled `Find in Pane…` and the reference row `Find a file or folder in this pane`.
  `main` retitled the item to `Find…` and amended the row to name both destinations — **because
  `main` has two**. On a line with no editor there is one destination, the old title names it
  exactly, and picking either change would replace a true sentence with a misleading one. This is
  the same shape as the ⌘Z row in the entry above: a correction that is only a correction where the
  thing being corrected for exists.
- **`v2.x` has no pane search at all.** `MacApp/ContentView+PaneSearch.swift` does not exist there,
  and `ShortcutsReference.swift` — which does — contains no find or search row and no `findInPane`
  anywhere on the line. Checked rather than inferred from the file's absence.

Recorded rather than picked, per the standing direction.

### One decision settled while this was built

**⌘R stays Rescan.** Replace was offered a chord of its own and he declined it, 2026-09-01. The
collision is real and worth writing down so the menu-bar batch does not re-open it: `⌘R` is
`AppChord.rescan`, app-wide, and routing it the way ⌘F is routed would leave a menu item titled
**Rescan** that opens Replace — while two items registering `⌘R` would let AppKit silently pick
one, the collision the emptied `.saveItem` group already exists to avoid. It is also unnecessary:
with the Replace row showing, ⌘F opens a bar carrying Replace and Replace All, so a second chord
would only move the caret between two fields that are both already on screen.

## 2026-09-01 (later still) — the editor's rail becomes two tabs

`4383f7f2`, `2d561935`. The rail stacked the folder's text files over the open document's outline,
with the outline capped at eight rows so the list above it would not vanish. They are two tabs now —
**Text Files** and **Outline** — each with the whole card, with the folder the files come from named
on a line under the tabs and ⌘N snapping the tab back to the files it opens its naming row in.

**Nothing is owed, and unlike the ⌘F entry above, this time the check is short**: every file the
first commit touches is either new or `main`-only, and the two that exist everywhere —
`MacApp/ContentView.swift` and `MacApp/HelpBook.swift` — were edited only in the parts that describe
the editor, which no maintenance line has.

```sh
for l in v4.x v3.x v2.x; do
  git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorFileRailView.swift >/dev/null 2>&1 \
    && echo "$l HAS the rail" || echo "$l: no rail file"
  git show origin/$l:MacApp/ContentView.swift | grep -c editorRailFilter    # the state it sits beside
  git show origin/$l:MacApp/HelpBook.swift | grep -c 'the rail grows an Outline\|funnel button'
done
```

- **`EditorRailTab.swift` is new, and `EditorFileRailView` / `EditorWorkspaceView` are `main`-only.**
  No maintenance line has an editor at all — established two entries above — so there is no rail on
  any of them to give tabs to.
- **`ContentView.swift` exists on all three and none of them carries the editor's rail state.**
  `editorRailFilter` and `editorTypedName`, which the new `editorRailTab` is held beside and for the
  same reason, are absent on every line; the property added here refers to a type those lines do not
  have.
- **`HelpBook.swift` exists on all three and none of them carries the sentences edited.** Neither
  "the rail grows an Outline" nor the funnel bullet is present, because the Edit topic they belong
  to is `main`-only. Checked directly rather than inferred from the missing workspace.

The notes and the releases page went with it, and both are `main`'s own: `docs/` is served from
`main`, and the v5.2 draft describes a release no maintenance line will ever cut.

Recorded rather than picked, per the standing direction.

## 2026-09-01 (later again) — the outline keeps its place

`d5172fa4`, `dfaf9811`. The rail's outline reopens where each document was left — resolved to the
nearest surviving heading when the remembered line has been edited away — unless that would leave
the heading the caret is in past the fold, in which case it opens there instead.

**Nothing is owed, and it is the same short check as the entry above**, for the same reason: the
editor is `main`-only, so there is no outline on any maintenance line to remember a place in. The
one new file is new, and the three shared files were touched only in editor-shaped parts of them.

```sh
for l in v4.x v3.x v2.x; do
  git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorFileRailView.swift \
    >/dev/null 2>&1 && echo "$l HAS the rail" || echo "$l: no rail file"
  git show origin/$l:MacApp/ContentView.swift | grep -c 'editorRailTab\|editorRailFilter'
  git show origin/$l:MacApp/HelpBook.swift | grep -c 'Outline is the headings'
done   # `grep -c` EXITS 1 ON ZERO, so the loop's own status says nothing — read the numbers
```

- **`EditorOutlineScroll.swift` is new**, and `EditorFileRailView` / `EditorWorkspaceView` are
  `main`-only: no maintenance line has an editor, established three entries above.
- **`ContentView.swift` carries none of the editor's rail state on any line** — not
  `editorRailFilter`, not `editorRailTab`, so not the anchors dictionary added beside them.
- **`HelpBook.swift` has no Outline sentence to amend on any line.** The clause added here sits
  inside the Edit topic, which is `main`-only.

Recorded rather than picked, per the standing direction.

## 2026-09-01 (later still) — wrapping, spell checking, live links, drawn images

`51233deb`, `fe3656d1`, `c768ca92`. Two switches on the editor's context menu; links that open and
`#heading` links that scroll; and an image on a line of its own drawn from a file already on this
disk.

**Nothing is owed.** Every file involved is either `main`-only or is one of the two shared documents
whose `main` wording is only correct because `main` has an editor:

- **`PlainTextEditor`, `MarkdownPreview`, `MarkdownBlocks`, `MarkdownOutline`,
  `EditorWorkspaceView`, `EditorTextSettings`, `MarkdownImageSource` — none exist on any
  maintenance line.** Established two entries above and unchanged: no line has an editor, and the
  Markdown renderer arrived with it.
- **`HelpBook`'s `editor-workspace` topic is `main`-only**, so its new bullets have nowhere to go.
- **`ShortcutsReference`'s Edit group is `main`-only too** — the group was added with the editor.
  Its amended row names a right-click menu that does not exist elsewhere.

### The one thing here that would be worth picking, if it applied

`MarkdownImageSource`'s cloud-only rule is the kind of decision that usually generalises: **drawing
a cloud-only file materialises it**, so a preview that renders whatever a document links to
downloads things onto somebody's disk because they opened a note. That rule is not owed anywhere
only because nothing else on any line renders a file's *linked contents* — the panes list files and
Quick Look shows what is already there. Worth writing down so a future surface that does render
linked content inherits the reasoning rather than rediscovering it in somebody's iCloud quota.

Recorded rather than picked, per the standing direction.

## 2026-09-01 (evening) — the editor's safety net, and a header that stopped shifting

`9f5f5595`, `41d15098`, `0848932a`. Per-file autosave, one undo stack per document, a header that
is the same height for every kind of text file, and the record of why there is no Show Invisibles.

**Nothing is owed. Every file is `main`-only or is `main`-only in the part that changed** — no
maintenance line has an editor, established three entries above and still true.

The one file worth naming is `MacApp/SyncCloudApp.swift`, which all four lines carry:
`applicationShouldTerminate` exists on every one of them. What changed there is the quit flush
learning to ask whether autosave is switched off for the open document — and `v4.x`, `v3.x` and
`v2.x` have no editor to flush, no `EditorAutosave`, and no policy to ask. The lines around the
change are not even present there.

### The defect worth knowing about even though it cannot travel

The quit flush wrote the open document **unconditionally**, which was right while autosave was
unconditional and became wrong the moment one file could opt out: ⌘Q wrote a file the user had
switched off, and wrote it BEFORE the unsaved-changes warning, so the question was asked after the
answer. Found by an adversarial review of the batch rather than by a test, and now covered by
`QuitFlushPolicyTests`.

**The transferable shape: a flush that predates a switch does not learn about the switch.** Any
unconditional write on a shutdown path is worth re-reading the day something gains permission to
say "not this one" — the write is correct in the ordinary case, which is exactly why nobody looks
at it again.

Recorded rather than picked, per the standing direction.

## 2026-09-02 — the document header, rebuilt

`2aab8749`. The editor's header second row becomes the file's kind and the Autosave switch; the
size joins the counts, encoding and line endings in the status line; and the save-state word appears
only in the states that need one.

**Nothing is owed.** `EditorSaveStatus`, `EditorStatusLine` and `EditorWorkspaceView` are `main`-only
— no maintenance line has an editor, established across the four entries above. `HelpBook`'s
`editor-workspace` topic is `main`-only too, so the reworded bullets have nowhere to go.

### The rule worth carrying forward, which is not about backporting

**A status word is worth its space only where it changes what the reader must do.** The header used
to end in one at all times — `saved` while nothing was happening, `unsaved` for the two seconds
after a keystroke — which labelled the two states that need no label and made the two that do look
like more of the same. Six states, and two of them speak.

`saved` in particular was reassurance the header gave whether or not anything had ever been
written; the codebase already knew this, in the comment that restored the dot after a session had
removed it, and the word survived that reasoning by a year. **When a surface says the same thing in
two notations, the one that costs nothing to be wrong is the one to drop.**

This shape generalises to any status line in the app: the pane's own footers, the Organize
overview's receipts, a lens's summary row. None is being changed here — the rule is recorded so
the next one written starts from it rather than from "always show the state".

Recorded rather than picked, per the standing direction.

---

## 2026-09-02 — Reaching the file-pair viewer (CC15.1–.4), and aligning two scans (CC14.4)

**RECORDED — not owed, and the tree says so in one command.** Every one of these repairs a way into
the file-pair viewer, or the viewer's own pixel comparison, and none of that machinery exists off
`main`.

**The positive control matters more than usual here**, because two of the files this batch touches
ARE on the maintenance lines — `PaneActionBar.swift` on all three and `AppChord.swift` on `v4.x` —
so a scan that only looked for changed filenames would report a gap that is not there:

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s ' "$l"
  for f in CompareCopiesSheet BitmapDiff PaneComparePairMenu; do
    git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/$f.swift >/dev/null 2>&1 \
      && printf '%s:present ' "$f" || printf '%s:absent ' "$f"
  done; echo
done   # main prints three present; every maintenance line prints three absent
```

Checked 2026-09-02: `CompareCopiesSheet`, `BitmapDiff` and `PaneComparePairMenu` are absent as files
from `v4.x`, `v3.x` and `v2.x`. `PaneActionBar` is present on all three and `AppChord` on `v4.x`.

| Piece | Depends on | Status |
|---|---|---|
| CC15.1 — `PaneLogic.compareOffer`, Compare offered for two files | the file-pair viewer | RECORDED — not owed, see below |
| CC15.3 — `AppChord.compareTwoFiles` (⇧⌘C), Compare menu item, ⌘/ row | the file-pair viewer | RECORDED — not owed |
| CC15.2 — `ComparePick`, the strip, the row marker, `PaneLogic.escapeAction` | the file-pair viewer | RECORDED — not owed |
| CC15.4 — "Compare with…" on every file row | `ComparePick` | RECORDED — not owed |
| CC14.4 — `PageRegistration`, `BitmapDiff.compareAligning` | `BitmapDiff` | RECORDED — not owed |

**CC15.1 is the one worth a sentence, because its file IS over there.** `PaneActionBar` exists on
all three lines and its Compare button behaves as it always did: offered for one selected folder,
running the two-folder scan. That is not a bug there. The defect CC15.1 fixes is a button that
could not act on a selection it was offered for — and it is offered for two files only where a
viewer exists to open them, which is `main` alone. Widening the predicate on a maintenance line
would create the dead button rather than remove one.

**CC14.4 carries a rule any future port must copy whole**, recorded because it is the half that
looks optional. The alignment is gated on the SHARPNESS of the correlation peak, not on how much
error the alignment removed. Scoring by improvement was tried first and measured: a real 0.5° skew
scored 0.183 while two deliberately unrelated pages scored 0.152 and 0.160 — overlapping
populations, so no threshold on that number can accept the first and refuse the others. A port that
keeps the estimator and simplifies the confidence has kept the part that works and dropped the part
that makes it safe: with the gate removed, two unrelated pages align by 2° and their changed
fraction FALLS from 0.195 to 0.161, which is nonsense wearing the appearance of agreement.

**Not backported, per the standing direction** (`e2b35dad`, 2026-08-26). This row is the record a
future audit needs, not a to-do.

---

## 2026-09-02 — the v5 speed batch: five performance commits (`6418032c`..`7555463e`)

**Mixed, and the split is not the one the filenames suggest.** Most of this batch repairs machinery
that only exists on `main` — the Edit workspace, the file-pair viewer, the Restructure planner — so
it cannot travel. But **four of the defects it fixes are live on maintenance lines**, one of them
the headline: the O(folders²) detector walk that cost 1.6 s of a 1.9 s workspace switch is **present
on `v4.x` today**.

### What applies, per line

| Defect fixed on `main` | v4.x | v3.x | v2.x | Status |
|---|---|---|---|---|
| `StructureDivergence.vocabulary` scans the whole profile per child — O(folders²) | **carries it** | file absent | file absent | RECORDED — not owed |
| Entering a lens re-homes the pane and runs a two-provider comparison no single-source workspace draws | **carries it** | no `presentLensRail` | no `presentLensRail` | RECORDED — not owed |
| `TopPaneVisibility.decodeOverrides` allocates a `JSONDecoder` on every read of the hot path | **carries it** | **carries it** | **carries it** | RECORDED — not owed |
| `StorageLensStore` re-reads and re-decodes every saved report on each restore trigger | **carries it** | **carries it** | file absent | RECORDED — not owed |
| Bounded line diff, compare-sheet lifetimes, page de-skew gating | — | — | — | CLOSED, does not apply |
| Editor keystroke fan-out, line-start table, detached autosave | — | — | — | CLOSED, does not apply |
| Restructure plan-sheet cache, landing digest, ledger writes | — | — | — | CLOSED, does not apply |
| Sidebar refresh coalescing and off-actor volume walk | no volume walk in its refresh | file absent | file absent | CLOSED, does not apply |
| `ShrinkableRun` layout cache; `SettingsManager` volume-source batching | file absent | file absent | absent | CLOSED, does not apply |

### The checks, with their positive controls

```sh
# stage 1 — is the FILE there? (main must print present, or the path is wrong)
for l in main v4.x v3.x v2.x; do
  git show origin/$l:Modules/Sync/Sources/Sync/StructureDivergence.swift >/dev/null 2>&1 \
    && echo "$l present" || echo "$l absent"
done   # main present · v4.x present · v3.x absent · v2.x absent

# stage 2 — is the SHAPE there? main must now print 0, having been fixed
for l in main v4.x; do
  printf '%s ' "$l"
  git show origin/$l:Modules/Sync/Sources/Sync/StructureDivergence.swift \
    | grep -c 'for (childPath, entry) in profile.folders'
done   # main 0 · v4.x 1  — v4.x still does the full-profile scan per child
```

**Two of these probes were wrong the first time, in the two ways this file warns about, so the
patterns above are the corrected ones.**

The first was the trap in "How to check one thing", arriving from the other side: probing for the
new memo with `overrides(in:` returned *absent on `main`* — where it demonstrably exists — because
the source spells it `overrides(in raw: String)`. The positive control is what caught it. Had `main`
not been in the loop, "absent on every maintenance line" would have been recorded as a finding
about those lines when it was a finding about the pattern. Probe `overridesMemo` instead.

The second was looser: grepping `FileSyncManager+Scanning.swift` for `comparing` reported a hit on
all four lines, which reads as "they already have the flag". They do not — the hit is the log line
*"Internal scan #N comparing X and Y"*, which has been there for years. The parameter
`comparing: Bool = true` is `main`-only. **A word that appears in prose is not a probe for a symbol
of the same name.**

### The one worth a sentence if the direction ever changes

`v4.x` carries the detector walk and would benefit most from it — the fix is ~30 lines threading a
map the runner already builds, and it is provably behaviour-preserving: `synccloud restructure
--json` over the real 5,020-folder profile is byte-identical before and after, at 1.78 s → 0.15 s.
The other three are smaller and each is self-contained. None of the four depends on anything else
in this batch, which is unusual and is the reason they are worth listing separately rather than
as "the speed batch".

**Not backported, per the standing direction** (`e2b35dad`, 2026-08-26). This row is the record a
future audit needs, not a to-do.

---

## 2026-09-03 — the v5.2 cut: notes, the version flip, and one front-page correction (`27c71ff3`..`56b6a8d6`)

**Nothing owed, and for once that is a conclusion rather than a default.** Three commits: the
release-notes coverage and audit (`27c71ff3`), the version cut itself (`84526458`), and a
correction to `docs/index.html` (`56b6a8d6`). Each is not-owed for a different reason, which is
why they are listed separately.

### What applies, per line

| Change on `main` | v4.x | v3.x | v2.x | Status |
|---|---|---|---|---|
| `RELEASE_NOTES.md` gains the `## v5.2` section | n/a — describes a release these lines do not have | n/a | n/a | CHECKED — not owed |
| `docs/releases.html` gains the v5.2 article, v5.1 trades `latest` for its theme | n/a — Pages serves `docs/` from `main` | n/a | n/a | CHECKED — not owed |
| `project.yml` / `Info.plist` → `5.2`, then `5.3-dev` / `503` | per-line by design (`4.7-dev` / `407`) | per-line (`3.2-dev` / `302`) | per-line (`2.10-dev` / `210`) | CHECKED — not owed |
| `versionMarker` in `SettingsLayoutTests` | tracks that line's own `project.yml` | same | same | CHECKED — not owed |
| `docs/index.html`: Storage is "a section of Organize", not "A workspace of its own" | **carries the old sentence, and it is TRUE there** | no Storage section at all | no Storage section at all | CHECKED — not owed |

### The one that needed checking rather than asserting

The front-page correction is the only row here that could plausibly have been owed, and the naive
reason for dismissing it — "`docs/` is `main`-only" — **is wrong as stated**. `docs/index.html` and
`docs/releases.html` are present on all four lines; what is `main`-only is the *publishing*, since
Pages serves `docs/` from `main`. So the file being carried is not the question. The question is
whether the sentence is false where it sits.

```sh
# stage 1 — the sentence, per line (main must now print 0: it is the fix)
for l in main v4.x v3.x v2.x; do
  printf '%-6s sentence=%s ' "$l" \
    "$(git show origin/$l:docs/index.html 2>/dev/null | grep -c 'A workspace of its own' || true)"
  printf 'storage-section=%s\n' \
    "$(git show origin/$l:docs/index.html 2>/dev/null | grep -c 'id="storage"' || true)"
done   # main 0/1 · v4.x 1/1 · v3.x 0/0 · v2.x 0/0

# stage 2 — is Storage actually a workspace there? The sentence is only wrong where it is not.
for l in main v4.x v3.x v2.x; do
  printf '%-6s case-storage=%s\n' "$l" \
    "$(git show origin/$l:MacApp/Workspace.swift 2>/dev/null | grep -c 'case storage' || true)"
done   # main 0 · v4.x 1 · v3.x 1 · v2.x 0
```

**`v4.x` carries the sentence and also carries `case storage`, so on that line Storage *is* a
workspace of its own and the sentence is correct.** Copying `main`'s wording there would introduce
the defect, not fix it. `v3.x` has `case storage` but its front page has no Storage section to be
wrong; `v2.x` has neither. The stale-on-`main` sentence was stale only because the fold happened
on `main`.

Both loops carry `|| true`: **`grep -c` exits 1 on zero**, and without it the first line printing
`0` kills the loop and the remaining lines are silently never checked — which on the first run here
made stage 2 look as though it had no output rather than never having run.

**Not backported, per the standing direction** (`e2b35dad`, 2026-08-26). These rows are the record
a future audit needs, not a to-do.

---

## 2026-09-06 — the v5.3 menu-bar batch: Text and Markup menus, View ▸ Text Size, File ▸ Download (roadmap RD1 + RD2)

**Nothing owed, and the reason differs by row.** Everything here is a menu item; what the item
reaches is what decides whether a maintenance line could carry it at all.

### What applies, per line

| Change on `main` | v4.x | v3.x | v2.x | Status |
|---|---|---|---|---|
| Text ▸ and Markup ▸ menus, `EditorVerbs`, ⌃⌘1/2/3, ⌘G/⌘E, ⌘B ⇧⌘X ⇧⌘K ⇧⌘L | no Edit workspace — `EditorDocumentSurface.swift` and `MarkupVerbs.swift` absent | absent | absent | CHECKED — not owed |
| ⌘I routed Italic-or-inspector (`InspectorOrItalic`, `EditorDocumentSurface.caretTextView`) | no editor for the Italic half; ⌘I is the inspector alone, correctly | same | same | CHECKED — not owed |
| Markup context menu draws the registered chords (`PlainTextEditor.Coordinator.markupMenu`) | no `PlainTextEditor` | absent | absent | CHECKED — not owed |
| View ▸ Text Size (`FontSize.bigger`/`.smaller`, `TextSizeCommands`) | **`FontSize.swift` present, with `selectablePercents`** — the code would apply | `FontSize.swift` present, no `selectablePercents` — the step rule has nothing to step | same as v3.x | RECORDED — not owed |
| File ▸ Download (`PaneRowVerbs.download`, `CloudDownloadRequest.requestDownload`) | **`PaneRowVerbs` present** — the menu row would apply; the row verb it shares a body with is there too | no `PaneRowVerbs` (the row verbs have no menu on that line) | same | RECORDED — not owed |
| ⌘/ reference in three columns (`balancedColumns`) | two-column reference, fewer rows — nothing overflows | same | same | CHECKED — not owed |
| `AppChord` glyph for the `-` key (`⌘−`), `ShortcutKeycapSpeech` for `+`/`−` | no chord uses either key | same | same | CHECKED — not owed |

### The checks, with their positive controls

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s surface=%s fontsize=%s paneRowVerbs=%s markupVerbs=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorDocumentSurface.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Design/Sources/Design/FontSize.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/ShortcutCommands.swift 2>/dev/null | grep -c 'struct PaneRowVerbs' || true)" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/MarkupVerbs.swift | wc -l | tr -d ' ')"
done   # main 1/1/2/1 · v4.x 0/1/2/0 · v3.x 0/1/0/0 · v2.x 0/1/0/0
for l in v4.x v3.x v2.x; do
  printf '%-6s selectablePercents=%s\n' "$l" \
    "$(git show origin/$l:Modules/Design/Sources/Design/FontSize.swift | grep -c 'selectablePercents' || true)"
done   # v4.x 1 · v3.x 0 · v2.x 0
```

`main` prints 1 in every file column, which is the positive control: the paths are spelled right,
so the zeros on the other lines are absences and not typos. `grep -c` exits 1 on zero, hence the
`|| true` — without it the first zero ends the loop.

### The two rows that would apply, and why they still are not sent

**View ▸ Text Size on `v4.x`** is the cleanest pick in this batch: `FontSize.bigger`/`.smaller`
are two computed properties over a list that line already has, `TextSizeCommands` is one `View`
reading `@AppStorage`, and the submenu is four lines in `.commands`. It needs the `⌘−` glyph and the
two speech entries, and its ⌘/ row would push that line's two-column reference — measure before
believing it fits. **File ▸ Download on `v4.x`** is the same shape as the other row verbs that line
already carries; its one dependency is `CloudDownloadRequest.requestDownload`, which is the row
menu's body extracted, so the pick would carry the small `FileTreeView` refactor with it (and
`CloudOnlyBadgeCache.cached` going public).

**Not backported, per the standing direction** (`e2b35dad`, 2026-08-26). These rows are the record
a future audit needs, not a to-do.

### Closed on audit, worth not re-deriving

**RD2's "Window ▸ Sync History is missing" is false on the running app.** SwiftUI lists every
`Window` scene in the Window menu automatically, and `WindowMenuTests` pins that Sync History appears
there exactly once. The proposal had read the source, where `SyncHistoryWindowCommand` sits unused.
Moving it beside Activity Log means `.commandsRemoved()` on the third scene, and the measurement in
`SyncCloudApp.swift` ("do not suppress all three") says that takes the main window's own opener with
it — `theMainWindowKeepsItsOpener` is the pin. Nothing changed for it in this batch, on any line.

## 2026-09-06 — iCloud rooted at iCloud Drive itself, and an iCloud row in Locations

**`RECORDED — not owed`, all three lines.** Two user-reported gaps, one cause: iCloud's source root
was `~/Documents`, so the breadcrumb could not go above Documents, and the Documents favorite —
the same folder as the root — claimed the provider and took its Locations row with it. The root is
now the iCloud Drive container (`~/Library/Mobile Documents/com~apple~CloudDocs`), landing at
`Documents`; `PathBoundary.LinkedFolders` carries the two hidden links macOS leaves there
(`Desktop`, `Documents`) so root-relative paths compose to the real `~/Documents` and `~/Desktop`
trees and every stored absolute path stays byte-identical; the tree walk lists the two links as the
real folders; `RootsMigration.moveICloudRoot` moves stored tabs, pins, recents, the Favorites
order, filing destinations and iCloud-anchored ignore sets down into `Documents` once, and keeps
`~/Documents` as a root override on a Mac whose iCloud Drive has no such link.

### What applies, per line

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s' "$l"
  for f in Modules/Sync/Sources/Sync/PathBoundary.swift \
           Modules/Settings/Sources/Settings/RootsMigration.swift \
           Modules/Dashboard/Sources/Dashboard/SidebarSources.swift; do
    printf ' %s=%s' "$(basename $f .swift)" "$(git ls-tree -r --name-only origin/$l -- $f | grep -c . || true)"
  done
  printf ' old-root=%s\n' \
    "$(git show origin/$l:Modules/Settings/Sources/Settings/SettingsManager.swift | grep -c '"~/Documents"' || true)"
done   # main 1/1/1/1 · v4.x 1/1/1/1 · v3.x 1/0/0/1 · v2.x 1/0/0/1  (before this landed)
```

- **`v4.x`** carries both defects exactly as `main` did: the Locations section (`SidebarSources`,
  v4.4), the root/landing split and its migration (`RootsMigration`, v4.1), and the `~/Documents`
  root. The pick is the whole batch — `PathBoundary` link table, walk substitution, discovery
  default, second migration, sidebar claims, and the four boundary sites converted from prefix
  math — and it is a **root move with a stored-state migration**, which is the one kind of change
  the maintenance lines were cut to avoid. Not owed.
- **`v3.x` and `v2.x`** have no Locations section and no root/landing split: iCloud's single path
  IS `~/Documents` there and the breadcrumb has nothing above it by design. The defect as reported
  does not exist on those lines; the feature does not apply. Checked, not owed.

**The one worth a sentence if the direction ever changes:** the second migration
(`iCloudRootMoveStamp`) assumes the first one's frozen mapping — `applyAtLaunch` maps iCloud at
`~/Documents` landing on itself, on purpose — so a pick of the second without the freeze rebases
iCloud's positions twice on any install that has not yet run the first.

---

## 2026-09-06 — two load-flaky tests repaired, and one gate that was never budgeted — `v4.x` carries half of it

Test-and-fixture only; nothing in `Modules/Sync/Sources` moved. Two repairs and one registry hole,
and they land on the maintenance lines differently, so the row is split.

```sh
# stage 1 — is the FILE there? (positive control on main included: both must print 1 there)
for l in main v4.x v3.x v2.x; do
  printf '%-6s guard=%s merge=%s budget=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Tests/Sync/RestructureApplyGuardTests.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Tests/Sync/MergeUndoGroupingAndGateTests.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Tests/Sync/ParkBudgetTests.swift | wc -l | tr -d ' ')"
done   # measured 2026-09-06: main 1/1/1 · v4.x 0/1/1 · v3.x 0/0/0 · v2.x 0/0/0

# stage 2 — is the SHAPE there? The polled rendezvous, and the two registry entries it needs.
for l in main v4.x; do
  printf '%-6s polled=%s gateReg=%s trashReg=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Tests/Sync/MergeUndoGroupingAndGateTests.swift | grep -c 'Date().addingTimeInterval(10)' || true)" \
    "$(git show origin/$l:Modules/Sync/Tests/Sync/ParkBudgetTests.swift | grep -c '"GateFileManager"' || true)" \
    "$(git show origin/$l:Modules/Sync/Tests/Sync/ParkBudgetTests.swift | grep -c 'SamplerObservedTrash' || true)"
done   # measured 2026-09-06: main 1/0/0 · v4.x 1/0/0 — identical, before this batch
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **The merge rendezvous stops polling** — `SamplerObservedTrash` puts one main-actor observation on `DispatchQueue.main` and waits on the semaphore *that observation* signals, and the premise's evidence becomes the reading itself rather than a flag set beside it | **Applies, identically.** Carries the suite, the polled 10 s rendezvous, and neither registry entry | Neither the suite nor `ParkBudgetTests` | RECORDED — not owed |
| **`SamplerObservedTrash` is registered as a thread-blocking gate and its test declares `.parksAThread`** | **Applies.** Same fixture, same `Task.detached` seam, no trait | No park budget on these lines at all | RECORDED — not owed |
| **`GateFileManager` registered, `.parksAThread` on both its tests, `awaitSignal` in place of the bespoke wait** | **No** — `RestructureApplyGuardTests` is `main`-only | No | CLOSED — checked, does not apply |
| **`docs/flaky-tests.md`**: mechanism 17 marked *Repaired 2026-09-06*, mechanism 10's live instance settled | **Applies.** That line already lacked the 2026-09-01 *correction*, so it now trails by two edits on the same section | Neither line has either section | RECORDED — not owed |

### The half that is genuinely owed in substance, if the direction ever changes

`v4.x` runs the **same** `noUndoGroupIsEverOpenWhileTheMergeIsSuspended`, over the same
`enqueueFileOperation` → `Task.detached` seam, with the same 10 s wall-clock rendezvous and the same
30 s sampling-loop deadline — and with no `.parksAThread` on it, exactly as `main` had. The measured
failure rate here was 0/26 for that test even at loadavg 200, so what that line carries is the
*latency bet*, not an observed red; the pick is a fixture rewrite in one file plus two lines in
`ParkBudgetTests`, and it does not touch `Modules/Sync/Sources`.

### What does NOT apply, and the check that says so rather than the assumption

The bigger of the two repairs — the unbudgeted `GateFileManager`, which went from **15 red in 26
runs to 0 in 26** — is `main`-only, because `RestructureApplyGuardTests` is. That is stage 1's `0`
for `guard` on every maintenance line, with `main` printing `1` as the positive control; without
that control a mistyped path would have produced the same three zeroes and read as the same verdict.

### The doc rows are the awkward ones, for the reason the 2026-09-01 row already gives

`docs/flaky-tests.md` is carried on all four lines so a maintainer need not read `main`'s history,
and the mechanism **numbering is per-line** — cite by title, never by number. `v4.x` now trails on
this section twice over: it still asserts the 2026-08-23 rendezvous defeats load ("no amount of load
can shrink it below the floor"), which 2026-09-01 repealed here and 2026-09-06 has now replaced. A
`v4.x` maintainer reading their own copy is told that this test's load-dependence was settled on
2026-08-23 and that nothing has been learned since — when in fact the section has been repealed
once and rewritten once, and the fixture their line runs is the one both edits are about.

**Not backported, per the standing direction** (`e2b35dad`, 2026-08-26). These rows are the record a
future audit needs, not a to-do.

---

## 2026-09-06 — the People tab: a dead *Look for names*, a relationship order, and reaching the files (`b553f3a9`..`2ff64fd5`)

Three commits on `main`. One is a real user-visible defect, and it is the only row here that would
matter to somebody on a maintenance line — because it is the only one whose *feature* exists there.

### What applies, per line

| Change | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`b553f3a9` — *Look for names* read the last Filing scan's provider root.** The button is offered whenever a profile is loaded, which is every launch; `look()` then bailed on a nil root and did nothing at all — no read, no log line, not even the "no new names" sentence | **Applies, in full and verbatim.** `guard let profile, let root = providerRoot else { return }` is line 2913 of that line's `SettingsView.swift`, and the button beside it is the same one | **Does not apply — the People tab does not exist on either line.** No `struct PeopleList`, no `PeopleStore.swift`, no `PeopleOverviewRow.swift`, no `PeopleNameScanner` | RECORDED — not owed |
| **`0664437e` — relationship order plus a hand-arranged one** (`PeopleOrder.swift`, `PeopleStore.move(id:up:)`, `"order": "custom"` in `people.json`) | Applies in the sense that its roster is sorted by display name and could be ordered better. New capability, not a defect | Does not apply — no roster store at all | RECORDED — not owed |
| **`2ff64fd5` — the tab becomes a list, gains Show Their Files / Show Folder, and stops saying "household"** | Applies. That line's tab is the pre-redesign column, and its Help and setup summary still say "household" | Does not apply — no People tab, and their `HelpBook.swift` has no People section | RECORDED — not owed |

### The checks, with their positive controls

Stage 1 found `SettingsView.swift` and `MacApp/HelpBook.swift` on **all four** lines, which is what
makes the zeroes below absence rather than a mistyped path — the control this file's own preamble
asks for, and the reason item 13 is cited there.

```sh
# stage 1 — the file is on every line, including the two answering "no"
for L in main v4.x v3.x v2.x; do
  git ls-tree -r --name-only origin/$L -- Modules/Settings/Sources/Settings/SettingsView.swift | wc -l
done                                        # 1 1 1 1  ← the positive control

# stage 2 — the SHAPE. `main` prints the fixed form, v4.x the defective one, the rest nothing
for L in main v4.x v3.x v2.x; do
  git show origin/$L:Modules/Settings/Sources/Settings/SettingsView.swift |
    grep -c 'providerRoot: URL?'            # main 0 · v4.x 1 · v3.x 0 · v2.x 0
done
for L in main v4.x v3.x v2.x; do
  git show origin/$L:Modules/Settings/Sources/Settings/SettingsView.swift |
    grep -c 'struct PeopleList'             # main 1 · v4.x 1 · v3.x 0 · v2.x 0
done
```

The two counts together are what separates "this line has the tab and the bug" from "this line has
neither": `providerRoot` alone reads as *fixed* on `v3.x`, which is the wrong conclusion for a line
that never had the feature. Count the subject as well as the defect.

### The one that would be worth sending, if the direction ever changes

`b553f3a9` — and it is the smallest of the three. On `v4.x` the whole pick is deleting one stored
property, dropping one argument at the construction site, and replacing the `guard` with a root
derived from `profile.root`; it touches no engine file and no other view. What it buys is a button
that currently does nothing on that line, in the ordinary case (open Settings without having run a
To File scan first), with no error and nothing logged — the "nothing happened" shape this repo keeps
finding. `main`'s own log carried exactly one `People: read` line in four weeks, which is the
measurement, and it is the same code on `v4.x`.

The other two are a redesign and a new capability, and neither is a defect.

### One measurement worth not re-deriving

`URL(fileURLWithPath:)` **expands a leading tilde itself**. The explicit
`(profile.root as NSString).expandingTildeInPath` in `lookRoot(for:)` is consistency with
`FileSyncManager+RestructureApply` and `duplicateScanCoversSurvey`, not correctness — removing it is
an equivalent program, and a mutation test over it comes back green for that reason rather than
because the test is weak. `PeopleLookRootTests` says so in prose so the next session does not read
that green as a hole and "fix" a test that is already right.

**Not backported, per the standing direction** (`e2b35dad`, 2026-08-26). These rows are the record a
future audit needs, not a to-do.

---

## 2026-09-06 — ⌘K switches to the source a typed path is in (roadmap RD7)

**`RECORDED — not owed`, all three lines.** Go to Folder's fourth refusal — a path inside a source
the pane is not showing, answered "In Dropbox — switch source first" — became a destination. The
row reads "Open in Dropbox" and ↩ points the aimed pane at that source and lands it on the folder.
The mechanism is the one ROADMAP_V4 §3 predicted: a new route case `PaletteRoute.folderInSource`,
and `ContentView.switchSourceAndReveal` doing `focusOn` → `adoptProviderForTab` (which arms
`pendingTabProviderChanges`, so `onChange(of: leftProviderId)` consumes the counter instead of
running `retargetPane()`) → `refreshForTabSwitch`. `adoptProviderForTab` and `refreshForTabSwitch`
stopped being `private` for that one caller; nothing else in the tabs file moved.

### What applies, per line

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s' "$l"
  printf ' CommandPalette=%s' \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/CommandPalette.swift | grep -c . || true)"
  printf ' PalettePath=%s' \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PalettePath.swift | grep -c . || true)"
  printf ' refusal=%s\n' \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/CommandPalette.swift 2>/dev/null | grep -c 'switch source first' || true)"
done   # main 1/1/1 (before this landed) · v4.x 1/1/3 · v3.x 0/0/0 · v2.x 0/0/0
```

The `refusal=` count is the shape check that stage 1 cannot make: `v4.x` has both files **and** the
refusal string three times (the branch, and two comments about it), which is the whole feature
present and the deferral still in place. `main`'s pre-landing count was the same, which is what
makes the comparison mean something.

- **`v4.x`** carries Go to Folder whole, including the refusal, so this applies in substance. The
  pick is small in the router (one route case, one row) and **not** small in the host: it needs
  `adoptProviderForTab`'s suppression contract and `refreshForTabSwitch`, both of which exist on
  that line, plus `PaneProviderChange` consuming the counter before the bootstrap guard. Feature
  work on a maintenance line, so not owed by standing direction rather than by difficulty.
- **`v3.x` and `v2.x`** have **no command palette at all** — neither `CommandPalette.swift` nor
  `PalettePath.swift` is on those lines — so there is no Go to Folder to improve and no refusal to
  retire. Checked, not owed, and it does not apply.

**The one worth a sentence if the direction ever changes:** the ordering is the whole of the
change, and it is invisible to a compiler. A pick that lands the route and writes the provider with
`aimProvider` (the `.provider` route's writer, which arms nothing) compiles, runs, and puts the
pane at the new source's landing folder with the typed folder silently dropped — the exact outcome
the refusal existed to avoid. `PaletteSourceSwitchTests.theSwitchNavigatesFirstThenAdoptsUnderSuppressionThenReloads`
is the scan that catches it, and it would have to travel with the pick.

---

## 2026-09-06 — the divergence diff (RD4) — **no maintenance line has any of it, and none can**

"Show What Changed…" on the changed-on-disk alert, the in-window diff overlay behind it, and the
header's amber stop line as a second door onto the same question. The whole batch stands on two
things neither of which exists off `main`: the **Edit workspace** (v5.2, 2026-09-03) and the
**Compare Copies text diff** (2026-08-30). `v4.x` was cut at `v4.6` on 2026-08-28, before both.

```sh
# stage 1 — is the FILE there? main is the positive control: it must print 1 across the row.
for l in main v4.x v3.x v2.x; do
  printf '%-6s alerts=%s stop=%s workspace=%s diff=%s diffview=%s bounded=%s compare=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/EditorAlerts.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/EditorAutosaveStop.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorWorkspaceView.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/TextPairDiff.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/TextPairDiffView.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/BoundedTextRead.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/CompareCopiesSheet.swift | wc -l | tr -d ' ')"
done
# measured 2026-09-06: main 1/1/1/1/1/1/1 · v4.x 0/0/0/0/0/0/0 · v3.x all 0 · v2.x all 0
```

**Stage 2 was not run, and that is the honest answer rather than a skipped step.** Stage 2 asks
whether the *shape* is there in a file that exists; every file this batch touches or depends on is
absent on all three maintenance lines, so there is nothing to grep inside. `main`'s row of `1`s is
what keeps three rows of zeroes from being a mistyped path.

| What landed on `main` | `v4.x` / `v3.x` / `v2.x` | Status |
|---|---|---|
| **`TextPairDiffPipeline`** — the read-refuse-prefilter-walk-notes ordering lifted out of `CompareCopiesSheet.refreshTextDiff`, so two surfaces share the stall guard instead of copying it | No `CompareCopiesSheet.swift`, no `TextPairDiff.swift`, no `BoundedTextRead.swift` — the refactor has nothing to refactor | CLOSED — checked, does not apply |
| **`EditorDivergenceDiffOverlay`** — the in-window buffer-against-disk diff, its two column captions, and its three-verb foot | No Edit workspace at all, and no line differ to draw in it | CLOSED — checked, does not apply |
| **The alert's fourth button** — `Show What Changed…` at position three, `divergenceAnswer` extended in lockstep, and the destructive styling now read from the answer rather than from the button's title | No `MacApp/EditorAlerts.swift`: the changed-on-disk question does not exist on these lines, because nothing on them edits a file | CLOSED — checked, does not apply |
| **`EditorAutosaveStop.offersDiff`** and the header's amber words as a control | No `MacApp/EditorAutosaveStop.swift`, no `EditorWorkspaceView.swift` | CLOSED — checked, does not apply |
| **`EditorDocumentFacts.count(_:_:)` made static** so the overlay's column phrases its word count by the same rule as the status line | No `EditorDocumentFacts.swift` | CLOSED — checked, does not apply |
| **Help copy** — two paragraphs under the Edit workspace topic describing the diff and the pill | `MacApp/HelpBook.swift` exists on the maintenance lines, but the Edit workspace topic these paragraphs sit in does not | CLOSED — checked, does not apply |

**Nothing here is owed in substance either.** This is not the usual "applies, but standing direction
says no" row: a maintenance line cannot carry a diff of an editor buffer when it has no editor. The
row is filed so a later audit does not have to re-derive that from the shape of the feature — and so
the *reason* is on record as a measurement rather than as an assumption.

## 2026-09-07 — File ▸ Print… and File ▸ Export as PDF… (roadmap RD9)

The open document rendered to paginated PDF — the preview's own arms in a `.page` medium, a block
paginator, a bytes door on `EditorFileStore`, and two File-menu items on `⌘P` and no chord. **It
rests on the Edit workspace (v5.2, 2026-09-03) and on `MarkdownPreview`, neither of which exists on
any maintenance line**, so almost none of it can apply — but "almost" is doing real work here, and
the two pieces that *could* stand alone are named below rather than swept into the same sentence.

```sh
# stage 1 — is the FILE there? main is the positive control: it must print 1 across the row.
for l in main v4.x v3.x v2.x; do
  printf '%-6s preview=%s store=%s workspace=%s chord=%s reference=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/MarkdownPreview.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorFileStore.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorWorkspaceView.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Design/Sources/Design/AppChord.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/ShortcutsReference.swift | wc -l | tr -d ' ')"
done
# measured 2026-09-07: main 1/1/1/1/1 · v4.x 0/0/0/1/1 · v3.x 0/0/0/0/1 · v2.x 0/0/0/0/1

# stage 2 — the SHAPE, for the two files that do exist off main. Is ⌘P already spoken for?
for l in v4.x v3.x v2.x; do
  printf '%-6s p-chords=%s\n' "$l" \
    "$(git show origin/$l:Modules/Design/Sources/Design/AppChord.swift 2>/dev/null | grep -c 'AppChord("p"')"
done
# v4.x: 1 — and it is `previewColumn = AppChord("p", [.shift, .command])`, the SHIFTED form.
# v3.x / v2.x: 0 — those lines have no AppChord type at all; their chords are still literals.
```

| What landed on `main` | `v4.x` / `v3.x` / `v2.x` | Status |
|---|---|---|
| **`DocumentPDF`** — the block measure, the page geometry from `NSPrintInfo`, the `ImageRenderer`-into-`CGPDFContext` render, and the CoreText path for plain text | No `MarkdownPreview.swift` and no Edit workspace: there is no preview to print and no document to print it from | CLOSED — checked, does not apply |
| **`MarkdownBlockView`** — the preview's per-block arms extracted so paper and screen draw from one body of code | Nothing to extract: the arms it was lifted out of do not exist on these lines | CLOSED — checked, does not apply |
| **`DocumentPagination`** — the block-boundary page breaks, and the one case where a cut is right | Pure arithmetic and it would *compile* anywhere, but nothing on these lines produces block heights to feed it | CLOSED — checked, does not apply |
| **`DocumentPrinting`** — `NSPrintOperation` via `PDFDocument`, because a hosting view drawn into a print context draws nothing | Same dependency chain | CLOSED — checked, does not apply |
| **`EditorFileStore.write(_ data: Data, toPath:)`** — a bytes door onto the staging, `F_FULLFSYNC`, swap and read-back the text save already had | No `EditorFileStore.swift` on any of the three | CLOSED — checked, does not apply |
| **`AppChord.printDocument`** (`⌘P`) and its registry entry | `v4.x` HAS `AppChord.swift`, and `⌘P` is free there — only the shifted `⇧⌘P` is taken. It would apply in the narrow sense of compiling. `v3.x` and `v2.x` have no `AppChord` type | RECORDED — not owed |
| **The `⌘/` reference row** — `⌘S / ⌘P`, paired because the row on its own took the reference to 770pt against a 740pt window | All three carry `ShortcutsReference.swift`, and none carries a `⌘S` row to pair with: Save arrived with the editor | CLOSED — checked, does not apply |
| **Help copy** — one bullet under the Edit workspace topic | `HelpBook.swift` exists on all three; the Edit topic it belongs to does not | CLOSED — checked, does not apply |

**The one row that is genuinely "not owed" rather than "does not apply" is the chord**, and sending
it alone would be worse than not sending it: a registered `⌘P` on a line with nothing to print is a
key equivalent that greys forever, or worse, one that fires an item that is not there. The chord is
half of a feature, and the other half cannot go.

**A measurement worth not re-deriving**, because it is the kind of thing a later session would spend
an afternoon rediscovering: **an `NSHostingView` handed to `NSPrintOperation` prints blank paper** —
right page count, correct pagination, no ink. SwiftUI renders into an arbitrary `CGContext` only
through `ImageRenderer`, which is why the pages are built into a PDF context first and the print
operation is `PDFDocument`'s. That constraint is not specific to this app or this branch.

Recorded rather than picked, per the standing direction.

## 2026-09-07 — the install skill's branch count

`73c55103`. The sweep step in `.claude/skills/install-sync-cloud/SKILL.md` said `origin` holds three
lines and its `git ls-remote` comment expected `{main,v2.x,v3.x}` — so the one command in this repo
that checks the remote for scaffolding would have called `v4.x` the stray. Now four, with the
sentence pointing at CLAUDE.md's branch table as the source of truth rather than repeating a number,
and the "fourth branch is scaffolding" line becomes a fifth that names `candidate-tap-deferral`.

**Owed to `v4.x` in the ordinary sense, and deliberately not picked; genuinely not owed to `v3.x` or
`v2.x`, which carry an OLDER wrong sentence rather than this one.** That distinction is the reason
this entry exists: a future audit reading "the skill is stale everywhere" would pick the wrong fix
onto two lines.

```sh
for l in v4.x v3.x v2.x; do
  git show origin/$l:.claude/skills/install-sync-cloud/SKILL.md | grep -c 'holds three lines'
  git show origin/$l:.claude/skills/install-sync-cloud/SKILL.md | grep -o 'only ever held'
done   # v4.x: 1 and nothing · v3.x and v2.x: 0 and "only ever held"
```

- **`v4.x` carries the exact sentence corrected here** — one occurrence of "holds three lines". On
  that line the sentence is *less* wrong than it is on `main`, because `v4.x` is itself one of the
  four and a session working there has no reason to look for a fifth. Recorded, not picked.
- **`v3.x` and `v2.x` carry the sentence this one replaced** — "`origin` … only ever held `main`",
  the version that predates the maintenance lines entirely. Picking `main`'s correction onto them
  would install a paragraph about `v4.x` into lines cut before it existed, and would leave the
  `roots` anecdote referring to a sweep those lines never ran.
- Nothing here is user-facing: the file is tooling for a session, not code the app runs.

Recorded rather than picked, per the standing direction.

## 2026-09-07 — the real-name and employer scrub — **CLOSED: sent to all four lines**

`9299c080` and `1f7551e1` on `main`, `cb7b79b9` on `v4.x`, `2c40dfa3` on `v3.x`, `051e05ed` on
`v2.x`. The repository is public and every line carried the household's real names — in shipped UI
text, in test corpora, in the roadmaps and on the Pages site — plus two real email addresses in
shipped source, an employer, its products, and the names of ~50 colleagues in the Restructure
fixtures.

**This is the exception to the standing no-backporting direction, and it was given explicitly.**
Recorded here precisely because it contradicts the rule the rest of this file tracks: a future audit
finding the same change on four lines should not read it as a lapse. Nothing was cherry-picked —
the lines have diverged too far for a pick to apply, so each was scrubbed directly and verified on
its own.

```sh
# The scrub is complete on a line when this prints nothing.
git grep -nwiI -e Aditi -e Divit -e Shweta -e Muktha -e Anuraag -e Abhishek -e Girish -e Dani \
  -e Ravindra -e Krishnamurthy -e HPE -e Cray -e MapR -e Hewlett origin/<line> \
 | grep -vE 'com\.abhishekgirish|/Users/abhishek|github\.com/agirish|repos/agirish'
```

- **What each line got differs, because each line carries a different surface.** `main` got the
  names, the emails and the fixture rewrite; `v4.x` the names, an email and the employer vocabulary
  (33 files of it); `v3.x` and `v2.x` names only — they carry no employer vocabulary and none of
  the Restructure fixtures, which postdate all three cuts.
- **The mapping is relationship words, not numbers, and that is forced by the code.**
  `PersonCandidates.isNameShaped` rejects any name containing a digit, so `Child1` would silently
  stop being recognised as a person. `parent`, `children` and `sibling` were excluded for a second
  reason — they are this codebase's own vocabulary, 717/907/791 uses.
- **Four probes were preserved in kind rather than in text**, and a future re-scrub must keep them
  that way: `Sonations` keeps `Son` a strict prefix; `NAPR` keeps an all-caps run ending `APR`;
  `EMP` stays a three-letter all-caps token so `JurisdictionCandidates` still reads it as an
  acronym; the `HewlettPackardEnterprise` replacement is the same 24 characters, so `SetupSheet`'s
  truncation example stays true of its own subject.
- **The fixture was renamed, not trimmed, and the reason is measurable.** Deleting the 694-folder
  `Work/` subtree moved six pinned counts — backlog 11→7, looseBesideContainer 2→1, dead weight
  86/503/20→63/362/16 — and lost two named oracle cases. A 1:1 token map preserves every name-based
  relationship the detectors key on, so the counts held exactly and no coverage was traded away.
- **Not touched, on any line:** `bundleIdPrefix: com.abhishekgirish`, which orphans every persisted
  setting and the installed app's defaults domain if it moves; the `/Users/abhishek` paths CI and
  the install skill resolve; and the `github.com/agirish` URLs.
- **Out of scope by nature:** the live roster in `~/Library/Application Support/SyncCloud` and the
  defaults domain. That is the app working as designed on one Mac, and `printsWhatEachPersonsViewHolds`
  still prints it locally — but `liveProfile` is in `SYNCCLOUD_SKIP_MACHINE_PINNED` on CI, and the
  public Actions log for `9299c080` contains zero occurrences of those names.
## 2026-09-07 — Browse's status bar (roadmap RD6)

The strip under Browse's pane — item count, selection, cloud-only census, listing freshness — plus
the two things it needed: a per-pane "when was this tree read" stamp on `FileSyncManager` that
survives a prefetch-cache hit, and `View ▸ Status Bar`.

**The pick genuinely APPLIES to `v4.x` in substance, and that is why it is measured rather than
waved through.** Almost every Editor-shaped row above it — RD9's printing included — closes as "does
not apply" for the same structural reason: the workspace it describes does not exist on the
maintenance lines, so there is nothing there to send it to. That reasoning does not reach this one.
Browse exists on `v4.x`. So does `browseLayout`, so does the tab-bar switch this sits beside, and so
does the prefetch cache the freshness stamp hangs off. (The scrub row above is the other kind again:
it applied *and* was sent, being a correctness fix about the repository rather than a feature.)

```sh
for l in main v4.x v3.x v2.x; do
  printf '%s statusline=%s browseLayout=%s tabBarCmd=%s walkStopped=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorStatusLine.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/ContentView+SplitLayout.swift | grep -c 'func browseLayout')" \
    "$(git show origin/$l:MacApp/SyncCloudApp.swift | grep -c 'ToggleTabBarCommand')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift | grep -c 'prefetchedTreeWalkStopped')"
done
# measured 2026-09-07:
#   main  1 / 1 / 1 / 2
#   v4.x  0 / 1 / 1 / 2   ← the host surface and both prerequisites are there
#   v3.x  0 / 0 / 0 / 0
#   v2.x  0 / 0 / 0 / 0
```

The positive control is `main`'s row: three of those four paths exist on every line, so a row of
zeroes on `v3.x` is an absence rather than a mistyped path.

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`PaneStatusFacts` + `PaneStatusBar`** — the four captions, the shedding ladder, the `ViewThatFits` rungs | Applies. `browseLayout` is there to hang it under, and `ScanFreshness` and `CloudOnlyBadgeCache` are both present | No `browseLayout` — Browse is not a workspace of its own on these lines | RECORDED — not owed |
| **`CloudOnlyCensus`** — the background `lstat` walk behind the cloud-only count | Applies. `MaterializationStatus.isCloudOnlyIfKnown` is on every line | Same absence: nothing would draw the number | RECORDED — not owed |
| **`leftTreeReadAt` / `rightTreeReadAt` + `prefetchedTreeReadAt`** — the read stamp that survives a cache hit | Applies, and this is the half worth naming separately: it is a `FileSyncManager` change, not a Browse one, and `prefetchedTreeWalkStopped` (which it is modelled on) is already there | `prefetchedTreeWalkStopped` is absent, so the store this parallels does not exist yet | RECORDED — not owed |
| **`View ▸ Status Bar`, and `PaneChromeCommands` grouping it with Tab Bar** | Applies. `ToggleTabBarCommand` is there; whether that line's View group has a spare child was NOT measured | No tab-bar switch to group with | RECORDED — not owed |

**Owed to `v4.x` in the ordinary sense, and deliberately not sent**, per the standing direction. The
pick would not be free even if it were authorised: the grouping change depends on `v4.x`'s own View
menu being at its ten-child limit, which this audit did not check, and a `ViewBuilder` that silently
drops an eleventh child is exactly the failure that has no test on that line.

## 2026-09-07 — Help ▸ Reading your documents, and the test that holds its claim

A Help article saying what the app does when it opens a file rather than reading its name, a
question-mark pointer at it from Settings ▸ Intelligence, and `NoTelemetryTests` — a source scan
pinning the app's network surface to exactly the three files behind Refine with Claude.

**This row is not like its neighbours, and the difference is worth stating first.** Most rows here
record a gap a user would have to go looking for. This one records that **three shipping lines read
their users' documents and say nothing about it** — the readers are all present off `main`, the
Help book is present off `main`, and no article on any of the three explains what is opened, what is
kept, or where it goes. That is a gap in what the app *tells people*, not in what it does.

```sh
# stage 1 — the surfaces. main is the positive control.
for l in main v4.x v3.x v2.x; do
  printf '%-6s helpbook=%s settings=%s signals=%s organizehelp=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/HelpBook.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Settings/Sources/Settings/SettingsView.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/ContentSignalExtractor.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/OrganizeHelpTopics.swift | wc -l | tr -d ' ')"
done
# measured 2026-09-07: main 1/1/1/1 · v4.x 1/1/1/0 · v3.x 1/1/1/0 · v2.x 1/1/1/0

# stage 2 — the SHAPE. Does the tab the pointer hangs on exist? Does the reader?
for l in v4.x v3.x v2.x; do
  printf '%-6s intelligenceTab=%s readContentsKey=%s helpPointerPrecedent=%s\n' "$l" \
    "$(git show origin/$l:Modules/Settings/Sources/Settings/SettingsView.swift | grep -c 'IntelligenceSettingsTab')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Filing.swift | grep -c 'readContentsDefaultsKey')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/RestructureLens.swift 2>/dev/null | grep -c 'questionmark.circle')"
done
# v4.x: 3 / 2 / 0 — the tab is there, the switch is there, no pointer precedent to copy
# v3.x: 0 / 2 / 0 — the reader is there; the Intelligence TAB is not, so the switch lives elsewhere
# v2.x: 0 / 2 / 0 — same

# stage 3 — the network surface differs per line, so the scan's allow-list is NOT portable.
for l in main v4.x v3.x v2.x; do
  printf '%-6s classifier=%s refiner=%s keycheck=%s | sourceCodeOnly=%s macAppDirectory=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/CloudFilingClassifier.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/CloudMappingRefiner.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Sources/Sync/AnthropicKeyCheck.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:SyncCloudTests/TestSupport.swift 2>/dev/null | grep -c 'func sourceCodeOnly')" \
    "$(git show origin/$l:SyncCloudTests/TestSupport.swift 2>/dev/null | grep -c 'func macAppDirectory')"
done
# main 1/1/1 · v4.x 1/0/1 · v3.x 1/0/1 · v2.x 1/0/1 — three files on main, TWO on every other line
# sourceCodeOnly / macAppDirectory: main 1/1 · v4.x 1/1 · v3.x 0/0 · v2.x 0/0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **The article** (`HelpBook` topic `on-device-reading`) | Applies in full. `HelpBook.swift` and `ContentSignalExtractor.swift` are both there, so the line reads documents and documents nothing about it. Its Help book already carries one "leaves this Mac" sentence, inside the *setup* topic's tip — a mention, not the page | Applies in substance. Both lines read documents too; neither says "leaves this Mac" anywhere in the book. The article's copy would need editing per line rather than copying: it names To File, Update folder memory and Duplicates, and which of those exist differs | RECORDED — not owed |
| **The Settings pointer** (`onOpenHelp`, `SettingsHelpTopics`, the `questionmark.circle` beside "Read file contents on-device") | Would apply — `IntelligenceSettingsTab` is there (3 hits) and the switch with it. **But the shape has no precedent on this line**: `RestructureLens.helpPointer`, which `main`'s pointer was copied from, does not exist on `v4.x`, so a pick would be introducing the pattern rather than following it | **Does not apply.** Neither line has an `IntelligenceSettingsTab` at all — the AI settings had not split out yet — so there is no section to hang the pointer on. Where the switch lives on those lines was not established by this audit | RECORDED — not owed (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`NoTelemetryTests`** — the allow-list scan | Would apply, **with its allow-list edited**: `CloudMappingRefiner.swift` does not exist on `v4.x`, so the three-file set is a two-file set and a verbatim pick fails its own "no longer reaches the network" assertion on the missing third. `sourceCodeOnly` and `macAppDirectory` are both present, so the machinery is there | **Prerequisites missing.** Neither line has `sourceCodeOnly` or `macAppDirectory` in `TestSupport.swift`, so the scan has nothing to read source with; both would have to be picked first. Allow-list is a two-file set here too | RECORDED — not owed |
| **`OnDeviceReadingHelpTopicTests`** — the cross-module pointer pin | Follows whatever the two rows above do; it asserts about a pointer and an article, so it is worth nothing without them | Same | RECORDED — not owed |

**The one measurement worth keeping, whatever happens to the direction.** The claim `main` now makes
is *scoped* — "the reading opens no network connection", plus the article naming Refine with Claude
itself — and that scoping is load-bearing rather than cautious. An unscoped "nothing leaves this
Mac" would be false on **every one of the four lines**: all four carry `CloudFilingClassifier` and
`AnthropicKeyCheck`, so all four can reach `api.anthropic.com`. Anyone picking this article to a
maintenance line must carry the last paragraph with it, or the pick ships a claim the code
contradicts. That is the opposite of the usual backport hazard, where the risk is picking too much.

---

## 2026-09-07 — the startup disk moves from Favorites to Locations' device band

`main` `1621f868` (SHA read after the push). One behaviour change — the startup disk left
`SidebarFavoritePlaces.standard`, so it is drawn as a `.device` row above any card and the Trash —
plus the stamped migration that makes it visible on an install that already has a stored list.

```sh
# stage 1 — does the sidebar this changes EXIST on the line at all?
for l in main v4.x v3.x v2.x; do
  printf '%-6s SidebarSources=%s favPlaces=%s standardHasDisk=%s bandWalk=%s ordered=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Dashboard/Sources/Dashboard/SidebarSources.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/SidebarSources.swift 2>/dev/null | grep -c 'enum SidebarFavoritePlaces')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/SidebarSources.swift 2>/dev/null | grep -c 'startupDiskPath\]')" \
    "$(git show origin/$l:MacApp/ContentView+FolderSidebar.swift 2>/dev/null | grep -c 'Band.cloud, .device, .trash')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/SidebarSources.swift 2>/dev/null | grep -c 'func orderedVolumes')"
done
# main 1/1/1/1/1 · v4.x 1/1/1/1/1 · v3.x 0/0/0/0/0 · v2.x 0/0/0/0/0
# The whole folder sidebar is a v4.2+ surface. v3.x and v2.x have no SidebarSources.swift at all —
# their Dashboard module goes BreadcrumbTrail → DashboardViews → Details* → FolderJumpStore, with
# no sidebar sources file between them.

# stage 2 — v4.x is the only line where the question is live. Are the migration's prerequisites there?
printf 'v4.x   migrationCallSite=%s paneBarMigration=%s appStorageKey=%s\n' \
  "$(git show origin/v4.x:MacApp/SyncCloudApp.swift | grep -c 'OrganizeScopeDefaults.migrate')" \
  "$(git show origin/v4.x:Modules/Dashboard/Sources/Dashboard/PaneBarArrangement.swift | grep -c 'enum PaneBarMigration')" \
  "$(git show origin/v4.x:MacApp/ContentView.swift | grep -c 'browseSidebarFavoritePlaces')"
# v4.x 1/1/1 — the launch migration block, the stamped-migration precedent, and the @AppStorage
# property are all present. A pick would land cleanly.
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **The disk out of `SidebarFavoritePlaces.standard`** | Applies in full and would land cleanly — `standard` is there with the same five entries and the same trailing `+ [SidebarSourceModel.startupDiskPath]`. It is a **preference change, not a fix**: nothing on `v4.x` is wrong, the disk simply sits in Favorites there. Weigh it as such if the direction ever changes | **Does not apply.** No `SidebarSources.swift`, no `SidebarFavoritePlaces`, no folder sidebar — the section shipped with v4.2 | RECORDED — not owed (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`SidebarFavoritePlaces.migrate` + `storageKey`/`salvageKey`** | Applies, and is **worthless without the row above** — it exists only to bring a stored list forward to a `standard` that changed. Prerequisites all present: the launch block in `SyncCloudApp.swift`, `PaneBarMigration` as the stamped precedent, and `ContentView`'s `@AppStorage`. Note the stamp key is per-line state: a user who runs `v4.x` and then `main` gets one migration, not two, because both write `browseSidebarFavoritePlacesMigration` | **Does not apply** — nothing to migrate | RECORDED — not owed (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`LocationsDeviceBandOrderTests`, `SidebarFavoritePlacesMigrationTests`, `FavoritePlacesKeyTests`** | Follow the two rows above. The end-to-end suite asserts through `ContentView.splitFolderSidebarPlaceRows`, which `v4.x` has with the same signature, so it would compile as picked | Same — no builder to assert against | RECORDED — not owed (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |

**The one thing worth knowing if this is ever picked.** The asked-for order — disk, then card, then
Trash — is produced by `orderedVolumes` (startup disk first) and the `[.cloud, .device, .trash]` band
walk, both of which `v4.x` already has, unchanged. So the pick is genuinely just the one-line
`standard` edit plus the migration; there is no ordering code to carry with it. On `v4.x` today those
two rules are already correct and simply have nothing to draw, because the disk is lifted into
Favorites before the device band is built.

---

## 2026-09-08 — the Activity Log's clock, and two references that baked in the machine's zone

`main` `eeeaade4`..`3f4baec4` (SHAs read after the push). Two facts, one cause. `LogEntryRow` shared a
`DateFormatter` built once for the process and never re-checked, so the Activity Log kept stamping
in whichever zone was current the first time a row drew; and `DashboardSnapshotTests`' two
`LogEntryRow` references had no way to pin a zone, so they baked in the recording machine's. This
Mac moved Pacific → `Asia/Kolkata` on 2026-09-05 and both log-row snapshots went red on a frozen
fixture with no code change behind them — `05:00:00.000` in the reference against `17:30:00.000`
live, and in the compact row the wider run shoved the message line sideways (10% of the canvas, a
perceptual precision of 0.46). CI never saw it: the suite is `machinePinned(.referenceImages)` and
`tests.yml` skips that marker.

```sh
# stage 1 + 2 in one pass — main is the positive control on every column
V=Modules/Dashboard/Sources/Dashboard/LogViewer.swift
T=Modules/Dashboard/Tests/Dashboard/DashboardSnapshotTests.swift
R=Modules/Dashboard/Tests/Dashboard/__Snapshots__/DashboardSnapshotTests/logRowsAllSeverities.severities-light.png
D=Modules/Design/Tests/DesignTests/SNAPSHOTS.md
for l in main v4.x v3.x v2.x; do
  printf '%-6s LogViewer=%s formatters=%s groupDup=%s snapTest=%s logRowsTests=%s refPNG=%s SNAPSHOTSmd=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- $V | wc -l | tr -d ' ')" \
    "$(git show origin/$l:$V 2>/dev/null | grep -c 'static let timeFormatter')" \
    "$(git show origin/$l:$V 2>/dev/null | grep -c 'private static func timeString(_ date: Date) -> String { timeFormatter')" \
    "$(git ls-tree -r --name-only origin/$l -- $T | wc -l | tr -d ' ')" \
    "$(git show origin/$l:$T 2>/dev/null | grep -c 'func logRowsAllSeverities')" \
    "$(git ls-tree -r --name-only origin/$l -- $R | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- $D | wc -l | tr -d ' ')"
done
# every line identical: LogViewer=1 formatters=2 groupDup=1 snapTest=1 logRowsTests=2 refPNG=1 SNAPSHOTSmd=1
# `formatters=2` is the duplicate: LogEntryRow's and LogOperationGroupRow's verbatim copy of it.

# and the references are the SAME BYTES on all four lines, so all four carry the Pacific recording
R=Modules/Dashboard/Tests/Dashboard/__Snapshots__/DashboardSnapshotTests
for f in logRowsAllSeverities.severities-{light,dark} logRowsAllSeveritiesCompact.severities-compact-{light,dark}; do
  for l in main v4.x v3.x v2.x; do git show origin/$l:$R/$f.png | shasum | cut -c1-12; done | sort -u | wc -l
done
# prints 1 four times — one distinct hash per image across all four lines
```

| What landed on `main` | `v4.x` / `v3.x` / `v2.x` | Status |
|---|---|---|
| **`LogEntryRow.timeZone` + `formatter(_:)` re-checking the zone** | Applies in full on all three, and would land cleanly: the same `LogViewer.swift`, the same `private static let timeFormatter` with no `timeZone` anywhere in the file. This is a real user-visible defect on every line — leave the Activity Log open across a Date & Time change or a flight and every stamp stays on the old zone for the rest of the session, silently | RECORDED — not owed |
| **`LogOperationGroupRow`'s duplicate formatter, deleted** | Applies — the verbatim copy is present on all three (`groupDup=1`). Only meaningful *with* the row above; on its own it is a tidy-up | RECORDED — not owed |
| **`DashboardSnapshotTests.pinnedZone` + the four re-recorded PNGs** | Applies, and is the row a maintainer would actually feel: the references are byte-identical to `main`'s old ones on all three lines, so **each line's `logRowsAllSeverities` pair is red on this Mac today for exactly this reason** — inferred from identical bytes, the identical test and the identical fixture, not from a run on those lines. The PNGs must be **re-recorded on the line**, never copied from `main`: they are machine-pinned, and the pin is per-line only by accident of the images matching | RECORDED — not owed |
| **`LogRowTimeZoneTests`** | Applies; it drives `LogEntryRow.formatter(_:)` and renders a `LogEntryRow`, both present on all three lines with the same shapes | RECORDED — not owed |
| **SNAPSHOTS.md's zone caveat + the four `SnapshotRendering.swift` doc bullets** | Present on all three lines (`SNAPSHOTSmd=1`), and the awkward doc case the 2026-09-01 row already describes: the guidance is true on those lines whether or not the code lands, and a maintainer reading it there would be reading advice about a seam their `LogEntryRow` does not have | DEFERRED — scope call |

**The thing worth not re-deriving.** The failure message for this is indistinguishable from a
rendering regression, which is what cost the time: "perceptual color precision 0.46" reads as a
colour change, and the first four hypotheses were all about `SemanticColor`, `Pill` and the
`Font` → `ScaledFont` move. The discriminator is one command, and it is cheap:

```sh
cd Modules/Dashboard && TZ=America/Los_Angeles swift test --filter 'logRowsAllSeverities'
```

Green under the recording machine's zone and red under the current one means the rendering is
fine and the reference is stale. `/etc/localtime`'s symlink mtime dates the move.

---

## 2026-09-08 — the last two zone-capturing formatters: Sync History, and the log file itself

`main` `<SHAs read after the push>`. The sweep that the section above started, finished. Two more
`static let DateFormatter`s captured the system zone at first use and never looked again:
`SyncHistoryRow.timeFormatter`, which is `LogEntryRow`'s defect in a second window, and
`LogEntry.timestampFormatter`, which is **not** the same case — it both writes `~/sync-cloud.log`
and parses history lines back out of it, so the decision there was about the file, not a column.

```sh
# stage 1 — both formatters, on every line, with the comments that named the zone as deliberate
H=Modules/Dashboard/Sources/Dashboard/SyncHistoryView.swift
L=Modules/Events/Sources/Events/Logger.swift
for l in main v4.x v3.x v2.x; do
  printf '%-6s SyncHistoryView=%s rowFmt=%s "stays local"=%s rowPrivate=%s | Logger=%s tsFmt=%s "continuity"=%s parse=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- $H | wc -l | tr -d ' ')" \
    "$(git show origin/$l:$H 2>/dev/null | grep -c 'static let timeFormatter')" \
    "$(git show origin/$l:$H 2>/dev/null | grep -c 'timezone deliberately stays local')" \
    "$(git show origin/$l:$H 2>/dev/null | grep -c 'private struct SyncHistoryRow')" \
    "$(git ls-tree -r --name-only origin/$l -- $L | wc -l | tr -d ' ')" \
    "$(git show origin/$l:$L 2>/dev/null | grep -c 'static let timestampFormatter')" \
    "$(git show origin/$l:$L 2>/dev/null | grep -c 'break continuity with them')" \
    "$(git show origin/$l:$L 2>/dev/null | grep -c 'static func parse')"
done
# every line identical: SyncHistoryView=1 rowFmt=1 "stays local"=1 rowPrivate=1 | Logger=1 tsFmt=1 "continuity"=1 parse=1

# and both formatter blocks are the SAME BYTES on all four lines
for l in main v4.x v3.x v2.x; do git show origin/$l:$H | grep -A11 'static let timeFormatter' | shasum; done | sort -u | wc -l
for l in main v4.x v3.x v2.x; do git show origin/$l:$L | grep -A8 'static let timestampFormatter' | shasum; done | sort -u | wc -l
# prints 1 and 1 — one distinct block each, across all four lines

# stage 2 — the prerequisites each half needs
for l in main v4.x v3.x v2.x; do
  printf '%-6s | minLevelBox=%s tools=%s uncheckedSendable=%s | parseOlderThan=%s sessionStartFilter=%s | logEntryRowFmt=%s restructureFmt=%s\n' "$l" \
    "$(git show origin/$l:$L 2>/dev/null | grep -c 'MinimumLevelBox')" \
    "$(git show origin/$l:Modules/Events/Package.swift 2>/dev/null | grep -o 'swift-tools-version: [0-9.]*')" \
    "$(git show origin/$l:$L 2>/dev/null | grep -c '@unchecked Sendable')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/LogViewer.swift 2>/dev/null | grep -c 'func parseOlderThan')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/LogViewer.swift 2>/dev/null | grep -c 'timestamp < sessionStart')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/LogViewer.swift 2>/dev/null | grep -c 'static func formatter')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/RestructureLens.swift 2>/dev/null | grep -c 'static func formatter')"
done
# main   minLevelBox=2 tools=swift-tools-version: 6.0 uncheckedSendable=4 | parseOlderThan=1 sessionStartFilter=1 | logEntryRowFmt=1 restructureFmt=1
# v4.x / v3.x / v2.x: identical EXCEPT the last two columns, which are 0/0 on all three.
```

| What landed on `main` | `v4.x` / `v3.x` / `v2.x` | Status |
|---|---|---|
| **`SyncHistoryRow.timeFormatter()` re-checking the zone** (+ the struct widened from `private` to internal so the accessor is reachable) | Applies in full on all three and would land cleanly — the same file, the same byte-identical formatter block, the same `private struct SyncHistoryRow`. Same user-visible defect as the Activity Log's: leave Sync History open across a Date & Time change and every stamp stays on the old zone for the rest of the session | RECORDED — not owed |
| **`LogTimestampFormatter`** — the lock-guarded box `LogEntry` renders and parses through | Applies in full, and the prerequisites are all there: `MinimumLevelBox` is the `NSLock` + `@unchecked Sendable` shape it copies (present on all three), Events is `swift-tools-version: 6.0` on all three, and `LogEntry.parse` is unchanged. **This is the one row where a pick would need reading before doing** — the reasoning is in the type's doc comment and it is a decision about the log FILE (following the system zone, and accepting that `parseOlderThan`'s `timestamp < sessionStart` split can double or hide a few rows for the rest of a session in which the zone moved), not the mechanical fix the row above is | RECORDED — not owed |
| **`SyncHistoryRowTimeZoneTests`, `LogTimestampZoneTests`** | Apply; both drive the new accessors and nothing else, and both compute their expectation from a fresh control formatter rather than from a frozen string, so neither bakes in a zone the way the log-row *references* did | RECORDED — not owed |
| **The doc comments' cross-references** | **Do not apply verbatim.** Both new comments cite `LogEntryRow.formatter(_:)` and `RestructureLens.formatter(_:)` as the precedents; `logEntryRowFmt=0 restructureFmt=0` on all three lines, so a verbatim pick lands comments naming symbols that line does not have. Either pick the two earlier fixes first (see the section above, and the 2026-08-29 Organize rows for `RestructureLens`) or edit the prose | RECORDED — not owed |

**The thing worth not re-deriving**, because it is the argument and not the diff. The old comment
said the Logger's zone stayed local "because the file's existing lines are local-time, and changing
it would break continuity with them" — and **that continuity does not exist.** `~/sync-cloud.log`
is tail-trimmed at ~5 MB, so it spans sessions, and each session captured whatever zone was current
when it started. This Mac's own log is the demonstration and it is reproducible on any line, since
none of them stamp an offset:

```sh
# the file spans the Pacific → Asia/Kolkata move, and the boundary is INVISIBLE
git log --format='%ad' --date=format:'%Y-%m-%dT%H:%M%z' | grep -- '-0700' | sort | tail -1   # 2026-09-03T07:13
git log --format='%ad' --date=format:'%Y-%m-%dT%H:%M%z' | grep -- '+0530' | sort | tail -1   # today
head -1 ~/sync-cloud.log   # 2026-07-28 — written in Pacific
tail -1 ~/sync-cloud.log   # today      — written in IST
```

There is no jump to find between them: the app was not running across the change (a 63-hour gap,
2026-09-03 07:42 → 2026-09-05 22:56), so the two zones sit either side of it with nothing marking
where one ends. Re-checking the zone does not put a second zone in the file — it moves an unmarked
boundary the file was going to get at the next launch anyway.

The other half of the argument, which is what rules out pinning: **nothing reads a parsed line's
instant for its own sake.** The Activity Log renders it back and buckets it by day, so
parse-then-render is the identity on the file's text exactly while the reader and the writer are on
the same zone — which is why zone-changed history has always *displayed* correctly despite being
parsed at the wrong instant. `LogEntryRow` re-checks as of the section above. Pinning the Logger
would put the reader and the renderer on different zones after a mid-session change and shift every
older-history row. A line's zone can only be made genuinely recoverable by stamping a UTC offset
into it, which is an on-disk format change with a migration for every line already written; that
was considered and rejected, and the reasoning is in `LogTimestampFormatter`'s doc comment where
anyone re-opening the question will find it.

---

## 2026-09-08 — a folder reached twice under one walk root, and the trash list that trusted it

`main` `65cc160b` (the walk + `FileNode.isCoveredElsewhere` + the consumers) and `b70f24d3`
(`redundantCopies` hardening). SHAs read after the push.

```sh
# stage 1 — does the CAUSE exist on the line? The substitution is what creates a second reach.
for l in main v4.x v3.x v2.x; do
  printf '%-6s substitution=%s LinkedFolders=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Scanning.swift 2>/dev/null | grep -c 'linkedFolders(atRoot:')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/PathBoundary.swift 2>/dev/null | grep -c 'LinkedFolders')"
done
# main 1/10 · v4.x 0/0 · v3.x 0/0 · v2.x 0/0
# The linked-folder substitution arrived with the v5.3 iCloud root move (`4150041a`, 2026-09-06) and
# exists ONLY on main. Without it the container's Desktop/Documents stay plain symlinks — sym=true —
# and every existing `isSymbolicLink` guard already skips them. The defect cannot occur elsewhere.

# stage 2 — the second commit is about a guard, so ask whether the guard is even the same shape.
for l in main v4.x v3.x v2.x; do
  printf '%-6s fallbackKeeperID=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/DuplicateFinder.swift 2>/dev/null | grep -c 'fallbackKeeperID')"
done
# main 2 · v4.x 2 · v3.x 0 · v2.x 0
# v3.x/v2.x predate it entirely — theirs is `copies.filter { !$0.isRecommendedKeeper }`, with no id
# test of any kind, so a same-path group would sail through even more easily than main's did.
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`65cc160b`** — `FileNode.isCoveredElsewhere`, the walk's `coveredTargets` rule, and the `StorageLensAnalyzer` / `DuplicateFinder` / `SelectionSummary` guards that read it | **Does not apply.** No `PathBoundary.LinkedFolders`, no substitution in `childURLs` — the walk never produces a second reach with a real path, so there is nothing for the flag to mark. Picking it would add a field nothing can ever set | **Does not apply**, same reason | CLOSED — does not apply |
| **`b70f24d3`** — `redundantCopies` compares against the keeper's id rather than a nil-when-flagged fallback | Applies cleanly and is a **latent** hardening: the weak filter is there verbatim, but nothing on the line can build a group holding one path twice (see the row above), so it defends against a shape that line cannot reach | **Does not apply as written** — `redundantCopies` there is `copies.filter { !$0.isRecommendedKeeper }` with no id test at all. The equivalent hardening would be a different edit on an older method, and it guards a shape those lines equally cannot produce | RECORDED — not owed (`v4.x`); CLOSED — does not apply as written (`v3.x`, `v2.x`) |

**The measurement worth keeping.** The defect is a *composition* of two things that are individually
correct: a substitution that makes linked folders read as the real folders (so stored paths resolve),
and an ancestor-chain cycle guard (so a link back into the current path terminates). Neither is
wrong; together they let one folder arrive twice with one id. Any line that later gains the
substitution gains the defect with it — so if `PathBoundary.LinkedFolders` is ever picked to a
maintenance line, `65cc160b` must go with it in the same batch, or that line starts over-reporting
Storage and offering the user's own Documents folder to the Trash.

## 2026-09-08 — landing a place in the folder it names, and re-rooting a pane that walks into a source

`main` `a73cbf23` (a sidebar shortcut lands in its folder, not at its owner's root) and `d1f8547d`
(a columns drill onto another source's own root re-roots the pane there). SHAs read after the push.

```sh
# stage 1 — the sidebar fix needs the ARMED provider write. Without it the fix cannot be expressed:
# the plain write runs retargetPane() on the next view update and discards the focusOn.
for l in main v4.x v3.x v2.x; do
  printf '%-6s adoptProviderForTab=%s insideItsOwner=%s\n' "$l" \
    "$(git show origin/$l:MacApp/ContentView+PaneTabs.swift 2>/dev/null | grep -c 'func adoptProviderForTab')" \
    "$(git show origin/$l:MacApp/ContentView+FolderSidebar.swift 2>/dev/null | grep -c 'openFolderSidebarShortcutInsideItsOwner')"
done
# main 1/2 · v4.x 1/2 · v3.x 0/0 · v2.x 0/0

# stage 2 — the walk-in needs five things, and the lines differ in WHICH they are missing.
for l in main v4.x v3.x v2.x; do
  printf '%-6s applyColumnNavigation=%s paneStack=%s isSameFolder=%s setProvider=%s localFolder=%s folderSources=%s\n' "$l" \
    "$(git show origin/$l:MacApp/ContentView.swift 2>/dev/null | grep -c 'func applyColumnNavigation')" \
    "$(git show origin/$l:MacApp/ContentView+PaneTabs.swift 2>/dev/null | grep -c 'func paneStack')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/SidebarSources.swift 2>/dev/null | grep -c 'func isSameFolder')" \
    "$(git show origin/$l:MacApp/ContentView+FolderSidebar.swift 2>/dev/null | grep -c 'func setFolderSidebarProvider')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/CloudProvider.swift 2>/dev/null | grep -c 'case localFolder')" \
    "$(git show origin/$l:Modules/Settings/Sources/Settings/SettingsManager.swift 2>/dev/null | grep -c 'func addFolderSource')"
done
# main 1/1/1/1/1/1 · v4.x 1/1/1/1/1/1 · v3.x 1/0/0/0/1/1 · v2.x 1/0/0/0/0/0
```

| What landed on `main` | `v4.x` | `v3.x` | `v2.x` | Status |
|---|---|---|---|---|
| **`a73cbf23`** — the `.inside` sidebar branch adopts the three-statement contract (`focusOn`, armed provider write, one reload) instead of a bare provider write plus `focusOn` | **Applies cleanly and the DEFECT IS THERE.** `openFolderSidebarShortcutInsideItsOwner` and `adoptProviderForTab` are both present, and the branch is the pre-fix shape — a click on Downloads lands at Home folder's root with the folder dropped, exactly as on `main` before this | **Does not apply.** Neither the sidebar's `.inside` branch nor `adoptProviderForTab` exists; there is no place for the fix to go and no defect to fix | **Does not apply**, same reason | RECORDED — owed and reproducible (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`d1f8547d`** — `PaneLogic.sourceRootedAt` plus the drill-only walk-in in `applyColumnNavigation` | **Applies cleanly.** Every prerequisite is present, and so is the shape that motivates it: folder sources exist, so a `~` or `/` source can contain a cloud root and a drill can land on one | **Applies only after rewriting.** `applyColumnNavigation` is there and folder sources exist, so the situation ARISES — but `paneProviderId` / `paneScope` / `paneStack` do not, and neither do `isSameFolder` or `setFolderSidebarProvider`. Picking it means hand-writing the `isLeft ? left : right` ternaries those helpers were extracted to prevent, which is the transposition defect `PaneSideChoice` exists for | **Does not apply — the situation cannot arise.** No folder sources and no `.localFolder` case at all, so every source is a discovered cloud account. Those roots do not nest (iCloud under `~/Library/Mobile Documents`, the rest under `~/Library/CloudStorage/`), so a drill can never land on another source's root. Only a hand-set root override could create one, which is not a shipped configuration | RECORDED — owed (`v4.x`); RECORDED — owed but needs rewriting (`v3.x`); CLOSED — cannot arise (`v2.x`) |

**The measurement worth keeping**, because it is what decides the `v3.x` row rather than the code diff.
The walk-in's *guard* — cloud accounts only, never a folder source — exists because a re-root resets
the pane's Back stack, so with `/` and `~` both added as sources an ordinary walk down the disk
would strand the user in Home folder with `/Users` unreachable. That guard is only meaningful on a
line that HAS folder sources. `v2.x` has none, which is why the whole feature is moot there rather
than merely unbuilt — and if folder sources are ever picked back to it, this commit stops being
"cannot arise" and becomes owed, guard included.

## 2026-09-08 — the document survey (roadmap RD11), its receipt, and the Refresh rename

Sixteen commits, `18832045`..`6048e958`, plus the rename that follows them: `b40709d4`
(the verb and the accessibility rule) and `a6c9b1b8` (the notes). SHAs read after the push.
The Help article that accompanies the feature already has its own row — **2026-09-07, Help ▸
Reading your documents** — and this section does not restate it.

**One check settles almost all of it**, because the survey does not stand alone: it reads a
`FilingCorpus`, scopes itself on a `FilingSurvey.surveyedRegion`, writes through
`FilingSurveyStore`, and draws itself as a card on `OrganizeOverview`. A line with none of those
has nowhere to put any of this.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s corpus=%s survey=%s store=%s resurvey=%s overview=%s pdfserial=%s memory=%s surveyedAt=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FilingCorpus.swift 2>/dev/null | grep -c 'struct FilingCorpus')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FilingSurvey.swift 2>/dev/null | grep -c 'FilingSurvey')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FilingSurveyStore.swift 2>/dev/null | grep -c 'memoryURL')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+FilingSurvey.swift 2>/dev/null | grep -c 'FilingSurveyReport')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift 2>/dev/null | grep -c 'struct OrganizeOverview')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/PDFKitSerialAccess.swift 2>/dev/null | grep -c 'PDFKitSerialAccess')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift 2>/dev/null | grep -c 'filingMemory')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift 2>/dev/null | grep -c 'filingSurveyedAt')"
done
# main 2/1/2/5/2/1/4/1 · v4.x 2/1/2/5/2/1/3/0 · v3.x all 0 · v2.x all 0

# the one extractor that IS everywhere — so "v3.x cannot read a document" would be the wrong reason
for l in main v4.x v3.x v2.x; do
  printf '%-6s ContentSignalExtractor=%s\n' "$l" \
    "$(git show origin/$l:MacApp/ContentSignalExtractor.swift 2>/dev/null | grep -c 'ContentSignalExtractor')"
done
# all four: 2
```

| What landed on `main` | `v4.x` | `v3.x` | `v2.x` | Status |
|---|---|---|---|---|
| **`18832045`, `5e020341`** — the corpus refuses a document that says it is not one (`kind`), and an unfinished survey gets `survey-progress.json`, deliberately not a `filing-corpus*` name | **Applies cleanly.** `FilingCorpus` and `FilingSurveyStore` are both there and the artifacts sit in the same `profiles/<id>/` directory, so the guard has something to guard and the checkpoint has somewhere to go. Worth sending on its own merits if the direction ever changes: the `kind` guard is what stops a hand-placed or half-written file being read as learned content | **Does not apply.** No `FilingCorpus`, no `FilingSurveyStore`, no `profiles/<id>/` filing artifacts at all — there is no corpus to mistake a checkpoint for | **Does not apply**, same reason | RECORDED — owed (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`ef4a0bea`, `bd80ab05`, `d2bc1c64`, `c671c708`** — `DocumentSurveyProgress`/`DocumentSurveyPause` as values the card draws, the pausable/resumable `DocumentSurveyRun` actor, the yield order, and `MachineConditionsMonitor` (screens asleep, thermal, low power) | **Applies in substance, and is the largest single piece.** Every dependency is present — `PDFKitSerialAccess` for the one serial lane, `filingSurveyLifecycle` for the scans it stands aside for, `LargeWalkPreflight` for the ask-first gate. The four files are new, so nothing conflicts; what needs care is the yield list, which must not name the survey's own lifecycle (that was the first critical finding on `main` and it would reproduce verbatim) | **Does not apply.** Nothing here to survey and no lifecycle to yield to | **Does not apply**, same reason | RECORDED — owed (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`d55cedd6`, `1d2e1004`, `4d1f7651`** — `FileSyncManager+DocumentSurvey`: plan, run, merge and write off the actor, and the two review fixes (a resumed index is distrusted against a plan it was not counted in; a failed write reports as a failure, not a success with a misleading summary) | **Applies cleanly, and the two fixes are the expensive half.** Both are about a survey reporting work it did not do — the exact failure class a three-hour pass must not have — and neither is discoverable from the diff of the commit that introduced the bug. Pick the three together or not at all | **Does not apply** | **Does not apply** | RECORDED — owed as a unit (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`da838810`, `2fac46f2`, `353063fc`, `d42836e0`, `610979cd`, `58d6763c`** — the card through every state, its way in from the overview, and the four review fixes (publish when a pause clears, carry `unavailable` across a resume, keep the receipt with the tree it describes, route the bar's motion through `designAnimation`) | **Applies in substance, needs re-fitting.** `OrganizeOverview` and `OrganizeOverviewSection` are both there and `designAnimation` exists in `Design`, so the card has a home and the motion rule has a call to make. What differs is the neighbourhood: `main`'s overview grew the Storage receipt and the survey card sits beside it, and `v4.x`'s has neither, so the placement is a judgement rather than a copy | **Does not apply** | **Does not apply** | RECORDED — owed but needs re-fitting (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`6048e958`** — a surveyed tree gets a receipt (`.settled`), derived from `filingMemory` + `filingSurveyedAt` on disk rather than from the in-session report, so it survives a relaunch | **Applies only after adding the stamp.** `filingMemory` is there; **`filingSurveyedAt` is not** — that is the one missing prerequisite the probe above finds, and without it the receipt can say what was learned but not when. Deriving it from the memory file's mtime was considered and rejected on `main`: any write touches it, so it would answer about the file rather than the survey | **Does not apply** | **Does not apply** | RECORDED — owed, prerequisite named (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`b40709d4`** — "Update folder memory" → **Refresh** on the button, **Refresh what's learned** in the Rescan menu; `rescanAccessibilityLabel` generalised from a `== "Rescan"` literal to a word count; the pass's log lines and report sentences moved with it | **Applies cleanly and is worth sending on its own** — more than the feature it came from. `v4.x` carries `OrganizePass.folderMemory` with the old title, the same `== "Rescan"` literal, and all six `Folder memory` strings the pass emits — four `Folder memory:` refusals, the up-to-date summary and the closing line — so the rename is a self-contained copy that needs none of the survey. The accessibility rule is the part that matters: under a bare verb the literal silently stops appending the lens, and `v4.x`'s own test asserts the OLD branch, so it would go green while VoiceOver announced an objectless button | **Does not apply.** No `OrganizePass`, no folder-memory pass, no strings to rename | **Does not apply**, same reason | RECORDED — owed, and the most sendable thing in this batch (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`a6c9b1b8`** — the notes for the receipt and the rename, in `RELEASE_NOTES.md` and `docs/releases.html` | **Does not apply as written.** The bullets describe a receipt and a rename `v4.x` does not have; if the code above is ever picked, the notes are written then, against that line's own tip | **Does not apply** | **Does not apply** | CLOSED — written per line, never copied |

**The check that decided every "does not apply" above, stated once**: `v3.x` and `v2.x` have no
filing corpus, no filing survey, no `FilingSurveyStore` and no `OrganizeOverview` — the probe
prints `0` for all four on both lines. This is not "the feature is unbuilt there"; it is that the
whole subsystem the survey reads, writes and draws into is absent, so there is no partial pick and
no defect to reproduce. **The largest known gap in `docs/backports.md` — `v3.x` has none of the
`DeleteOutcome` family — is unaffected by any of this.**

**One thing worth not re-deriving**, because it cost a whole review round on `main` and is invisible
in the diff: the survey's yield list must not contain its own `filingSurveyLifecycle`. It reads as
correct — "stand aside for a running scan" — and the survey marks itself running before it reads
its first document, so it stands aside for itself, forever, and the card sits at "paused" with no
reason a user could act on. It is caught by a test only if that test starts the lifecycle first.

---

## 2026-09-08 — Organize's overview becomes one card system, and Storage gets a card

Three commits, `d01f33ab`..`84bd54d9`. SHAs read after the push. Reported as a screenshot and a
list — *everything is different and not consistent; Storage doesn't even have a card; Restructure
has a colour card; the Refresh buttons don't line up; the buttons don't all have the blue
background pill; the heights of the cards don't match* — which is five observations of one cause:
five card anatomies had grown on one screen.

**`v4.x` has the screen and four of the five defects; `v3.x` and `v2.x` have no screen at all.**
The probe that settles both, with its positive control on `main`:

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s overview=%s storageLens=%s receipt=%s survey=%s lensCard=%s pill=%s\n' "$l" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift 2>/dev/null | grep -c 'struct OrganizeOverview')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/OrganizeLens.swift 2>/dev/null | grep -c 'case storage')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift 2>/dev/null | grep -c 'case receipt')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DocumentSurveyCard.swift 2>/dev/null | grep -c 'struct DocumentSurveyCard')" \
    "$(git show origin/$l:Modules/Design/Sources/Design/LensCard.swift 2>/dev/null | grep -c 'func lensCard')" \
    "$(git show origin/$l:Modules/Design/Sources/Design/Pill.swift 2>/dev/null | grep -c 'enum PillVariant')"
done
# main 2/1/1/1/1/1 · v4.x 2/0/0/0/1/1 · v3.x and v2.x 0/0/0/0/1/1

# WHICH defects reproduce on v4.x — the wash, the stripe, the wells, the mixed button dresses,
# and the two ledger builders. This is the row's real content: "it has the screen" is not the
# same claim as "it has the problem".
# One grep per claim, deliberately: `grep -c` with two `-e` patterns prints ONE combined count,
# so "2" would not say whether it found both marks or the same mark twice.
V=Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift
git show origin/v4.x:$V | grep -c 'accent.opacity(0.07)'              # 1 — the findings wash
git show origin/v4.x:$V | grep -c 'RoundedRectangle(cornerRadius: 1.5)'  # 1 — its 3pt stripe
git show origin/v4.x:$V | grep -c 'quaternary.opacity(0.35)'  # 2 — the wells lensCard() replaces
git ls-tree -r --name-only origin/v4.x -- Modules/FileExplorer/Sources/FileExplorer/OverviewCard.swift
# empty on all three maintenance lines; present on main — the positive control for the path
```

| What landed on `main` | `v4.x` | `v3.x` | `v2.x` | Status |
|---|---|---|---|---|
| **`d01f33ab`** — `OverviewCard`, the one anatomy (glyph, heading, body slot on the title's spine, trailing action cluster, small print under a rule), plus `OverviewCardAction`'s *rank not style* and `OverviewQuietRow` | **Applies cleanly, and this is the piece worth having on its own.** Both dependencies are present — `lensCard()` in `Design` and the C1 `Pill` — and the file is new, so nothing conflicts. It is a container with no knowledge of which lenses exist, so nothing in it needs re-fitting | **Does not apply.** No `OrganizeOverview` on this line; the container would have no screen to be a container for | **Does not apply**, same reason | RECORDED — not owed (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`5d1d2753`** — the overview and the survey card rebuilt on it, `actions(for:)` as the one place a card's verbs are decided, `strandedCards`/`strandedLines` partitioning `strandedUnscanned`, and the consistency suite | **Applies in substance, needs splitting.** Four of the five defects reproduce verbatim (the `accent.opacity(0.07)` wash, the 1.5-radius stripe, two `quaternary.opacity(0.35)` wells, and `checksTile`/`ledgerTile` as separate builders with only the latter stretched). The other two cannot: `v4.x` has no `case storage` on `OrganizeLens` and no `case receipt` on `OrganizeOverviewState`, so **the headline complaint — Storage has no card — does not exist there**, and neither does the receipt card or the survey's Refresh. A pick is the card-shape half only, and `strandedCards` would partition a list that on that line only ever holds pass-covered lenses | **Does not apply** | **Does not apply** | RECORDED — not owed, and would need splitting (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`84bd54d9`** — the five bullets in the v5.3 draft, in `RELEASE_NOTES.md` and `docs/releases.html` | **Does not apply as written.** Two of the five bullets describe a Storage card and a survey Refresh that line does not have; if the code above is ever picked, the notes are written then against that line's own tip | **Does not apply** | **Does not apply** | CLOSED — written per line, never copied |

**The distinction this row exists to record**, because it is the expensive half to reconstruct:
`v4.x` *has* the overview and *has* most of the visual defects, which makes it look like a
straightforward pick — and it is not, because the complaint that named the work ("Storage doesn't
even have a card") is about a lens that line does not carry. Anyone reading only the commit
subjects would send the whole thing and land a `strandedCards`/`strandedLines` split with nothing
to put in the first list. `v3.x` and `v2.x` need no judgement: `OrganizeOverview.swift` is absent,
so there is no partial pick and no defect to reproduce.

---

## 2026-09-08 — the two controls the card system had exempted (`cf3d561f`)

One commit, and it only makes sense as a follow-on to the row above: it closes the exemption that
row's redesign left behind, and it is built on the `OverviewCard` that row introduced.

**Only half of the defect exists on `v4.x`, and the half that does is the one nobody reported.**

```sh
V=Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift
for l in main v4.x v3.x v2.x; do
  printf '%-6s card=%s nudge=%s inbox=%s link=%s chevron=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/OverviewCard.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:$V 2>/dev/null | grep -c 'BacklogNudge')" \
    "$(git show origin/$l:$V 2>/dev/null | grep -c 'InboxShortcut')" \
    "$(git show origin/$l:$V 2>/dev/null | grep -c 'buttonStyle(.link)')" \
    "$(git show origin/$l:$V 2>/dev/null | grep -c 'chevron.right')"
done
# main   1/3/3/0/0   — the card exists, both notices are cards, no link and no chevron row left
# v4.x   0/0/3/0/1   — no OverviewCard, NO BACKLOG NUDGE AT ALL, but the chevron row is there
# v3.x   0/0/0/0/0   · v2.x 0/0/0/0/0 — no overview
```

| What landed on `main` | `v4.x` | `v3.x` | `v2.x` | Status |
|---|---|---|---|---|
| The nudge's *Set up…* stops being a bare `.link` inline in its sentence, and the nudge becomes a card | **Does not apply — there is no nudge.** `BacklogNudge` is absent from that line's overview entirely (§5.6's reminder came with the v5 line), so there is no bare link to fix and nothing to re-dress | **Does not apply** — no overview | **Does not apply** | CLOSED — does not apply on any line |
| The inbox shortcut stops being a whole-row click with a chevron and gets a button | **Applies in substance, and this is the part worth knowing about.** `InboxShortcut` is there and so is the `chevron.right` row, so the defect is real on that line — a control with no hint of its own hit area — and it was never reported because nobody looking at `v4.x` was looking at this page. **It cannot be picked as written**: the fix is "make it an `OverviewCard`", and `OverviewCard.swift` does not exist there. Sending it means sending the row above first | **Does not apply** | **Does not apply** | RECORDED — not owed; blocked on the card system (`v4.x`) |
| `OverviewCardDismiss`, and the title weight derived from the subtitle | **Does not apply on its own** — both are additions to a type that line does not have | **Does not apply** | **Does not apply** | CLOSED — carried by the row above, if that is ever sent |
| The two draft bullets in `RELEASE_NOTES.md` and `docs/releases.html` | **Does not apply as written** — they correct a claim about a page `v4.x` does not have in this shape | **Does not apply** | **Does not apply** | CLOSED — written per line, never copied |

**The one thing here a future audit should not have to re-derive**: `v4.x` has the inbox row's
defect and not the nudge's, which is the opposite of what the commit subject suggests and the
opposite of what the report that prompted the work was about. Anyone reading only the subject would
go looking for a `.link` on that line and find none, and conclude the whole thing does not apply —
missing the chevron row, which does.

---

## 2026-09-08 — the card system reviewed, and Restructure stops sampling its own backlog (`ead5e80d`)

One commit: six defects found by re-reading the two rows above, the new-year reminder folded onto
the card whose finding it names, and Restructure's card summarising its backlog instead of drawing
three findings off the front of an unsorted list.

**`v4.x` has one of the three defects in code and cannot take its fix.** That is the whole content
of this row, and neither half is guessable from the commit subject.

```sh
L=Modules/FileExplorer/Sources/FileExplorer/LensWorkspaceView.swift
for l in main v4.x v3.x v2.x; do
  printf '%-6s card=%s tally=%s kindLabel=%s carriesPlan=%s sample=%s nudge=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/OverviewCard.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/StructureBacklogTally.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/RestructureLens.swift 2>/dev/null | grep -c 'static func kindLabel')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/StructureDivergence.swift 2>/dev/null | grep -c 'var carriesPlan')" \
    "$(git show origin/$l:$L 2>/dev/null | grep -c 'map(\\.headline)')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift 2>/dev/null | grep -c 'BacklogNudge')"
done
# main 1/1/1/1/1/5 · v4.x 0/0/0/0/1/0 · v3.x and v2.x 0/0/0/0/0/0
```

**`sample=1` on `main` is a COMMENT, and the two lines have to be told apart by reading them** —
this file's own preamble warns about exactly this and the trap is live here:

```sh
git show origin/v4.x:$L | grep -B2 -A1 'map(\\.headline)'   # CODE: examples: scoped.prefix(…)
git show origin/main:$L  | grep -B1 -A1 'map(\\.headline)'  # a comment recording what was removed
```

| What landed on `main` | `v4.x` | `v3.x` | `v2.x` | Status |
|---|---|---|---|---|
| The six review defects — Open withdrawn during a scan, the receipt's disabled `Re-analyze`, the card that demoted itself mid-run, `strandedTitle`'s false claim, the cost line that came and went, the survey's Stop in the primary's slot | **Does not apply.** Every one is a defect *in the card system*, and `OverviewCard.swift` is absent on this line — the cards it fixes were never built here. Three of the six are regressions against behaviour `v4.x` still has correctly, by never having changed it | **Does not apply** — no overview | **Does not apply** | CLOSED — does not apply on any line |
| The reminder folded onto Restructure's card | **Does not apply — there is no reminder.** `BacklogNudge` is absent from that line's overview entirely (§5.6 came with v5) | **Does not apply** | **Does not apply** | CLOSED — does not apply |
| **`StructureBacklogTally`, and Restructure's card summarising instead of sampling** | **The defect is real and the fix is unpickable as written.** `examples: scoped.prefix(OrganizeOverview.exampleLimit).map(\.headline)` is live in that arm, so the card draws three findings off an unsorted list exactly as `main`'s did. But **`FindingKind` does not exist on this line** — `StructureDivergence.swift` is there and carries `StructureFinding`, and the kind taxonomy arrived with v5 — so there is no `kindLabel` to quote, no `carriesPlan` to order by, and nothing for a tally to count *by*. A pick would have to invent a breakdown axis, which is a design decision and not a backport | **Does not apply** | **Does not apply** | RECORDED — not owed; defect real, fix blocked on `FindingKind` (`v4.x`) |
| The three draft bullets in `RELEASE_NOTES.md` and `docs/releases.html` | **Does not apply as written** — they describe a card system and a reminder that line does not have | **Does not apply** | **Does not apply** | CLOSED — written per line, never copied |

**The thing not to re-derive**: `v4.x` looks like the natural home for the Restructure summary —
it has the overview, it has the arm, and it has the defect verbatim. It has no kind taxonomy, so
the summary this commit writes cannot be expressed there at all. Anyone who checks only for the
defect will conclude the pick is owed and easy; it is neither.

### 18. The column row's tap gesture, which ate roughly nine ⌘/⇧ clicks in ten — RECORDED, not owed (filed 2026-09-08)

Fixed on `main` as `2e26a50f`. **All three maintenance lines carry the defect**, and the shape
differs between them:

| Line | `simultaneousGesture(TapGesture` on the column row | Carries |
|---|---|---|
| `v4.x` | 2 | the count-1 drill gesture (`743d8bde`) AND the count-2 ⌘-double-click (`668ccaa2`) |
| `v3.x` | 1 | the count-1 drill gesture only — cut 2026-08-11, before `668ccaa2` |
| `v2.x` | 1 | same as `v3.x` — cut 2026-08-01 |

The tree row is clean on all three (0 hits), because `c04574f0` removed its gesture in July and
that predates every cut.

**What the user sees**: ⌘- and ⇧-click multi-select in a Columns pane barely works — measured at 3
of 28, 5 of 43 and 1 of 8 clicks landing. Plain clicks look fine, which is why it reads as a
modifier-key bug. The row's `TapGesture` claims the mouse-down and usually never completes, so the
click never reaches `NSTableView` and the table selects nothing. A plain click survives because it
has a second committer (the List's binding); a ⌘/⇧ click has only the table, which is the path being
starved.

**Not a clean cherry-pick, and the reason is worth writing down.** The fix deletes the gesture and
leans entirely on `columnSelection`'s setter to navigate. That setter must already carry
`navigation(for:depth:)` and its `DeferredColumnNavigation.isStillValid` staleness check, or
removing the gesture leaves clicking a folder doing nothing at all. Check stage 2 before assuming:

```sh
git show origin/v3.x:Modules/FileExplorer/Sources/FileExplorer/PaneColumnsView.swift \
  | grep -c 'DeferredColumnNavigation.isStillValid'      # 0 means the pick needs that first
```

Taking it also drops ⌘-double-click "Open in New Tab" on that line (it lived inside the gesture),
which stays reachable via the row context menu and ⌘T — a product call, not a mechanical one.

**How it was found, because the source misleads.** Three plausible causes were convicted by reading
the code and then exonerated by measurement: a hit-testing decoration, the deselect recognizer's
`delaysPrimaryMouseButtonEvents` default, and `PaneListSelectionStyler`. The discriminator is the
mouse-UP — a click `NSTableView` handles has its up consumed by the table's tracking loop, so a
dead click is one with a matched down/up pair. `MouseDownProbe` (`5c04a0ad`, gated on
`paneScrollTraceEnabled`) is what reports it; anyone re-doing this on a maintenance line wants that
commit first, or they will re-run the same three wrong answers.

### 19. The two spellings of a linked folder, which drew "Empty" over a full folder — NOT OWED, `main`-only (filed 2026-09-08)

**No maintenance line carries this, and the check is one command per line** — the whole
linked-folder table is v5 work, landed on `main` at `4150041a` (2026-09-06, "Root iCloud at iCloud
Drive itself") and never cut into a maintenance branch:

```sh
for l in v4.x v3.x v2.x; do
  echo -n "$l: "; git show origin/$l:Modules/Sync/Sources/Sync/PathBoundary.swift | grep -c 'typealias LinkedFolders'
done   # all three print 0
git merge-base --is-ancestor 4150041a origin/v4.x   # non-zero: the feature is not on that line
```

Those lines still have `PathBoundary.swift` and still compose lexically in all three places this
commit changed (`rootURL.appendingPathComponent(relPath)`, `pruned`'s `directory + "/" + component`,
`ignoreBasePath`) — so a grep for the *shape* of the defect hits on every line and says nothing.
**What makes the shape harmless there is that there is only ever one spelling**: with no table,
iCloud Drive's `Documents` is walked, named, composed and stored as
`…/com~apple~CloudDocs/Documents` everywhere, and lexical composition agrees with itself. The
defect needs two spellings to exist, and the table is what introduces the second one.

**What the user saw** (`main` only, and only with iCloud Desktop & Documents syncing on): with the
pane focused on iCloud's `Documents`, the root column listed correctly and **every column past it
read "Empty"** — over `~/Documents/Home`, which has 15 children. `loadTree` composed its walk root
lexically, so the walk began at `<iCloud Drive>/Documents` and named every node below it the link
way; the linked-folder substitution lives in `childURLs(of:)` and fires at the CONTAINER's listing,
which a walk starting below it never performs. Meanwhile `PaneChildrenIndex` was keyed from the
pane's `currentPath`, which goes through `PathBoundary.join` and comes back `~/Documents`. The root
column survived only because the index keys `treeRoot → tree.rows` directly.

**Two more doors onto the same defect, found while measuring the first** and fixed in the same
batch — neither is a symptom of the column bug, so a line that ever does take this must take all
three:

- `PaneBrowsePath.pruned` composed lexically where `columnDirectories` resolved the link, so the two
  disagreed about one path. Browsing `Documents › Home` from the iCloud Drive **root** — where the
  columns work — collapsed the whole stack back to the root on the next republish (measured:
  `["Documents", "Home"]` → `[]`). `currentDirectory` went with it, and that is what New Folder and
  paste target.
- `PaneLogic.ignoreBasePath` composed the base that ignore targets are stripped against. Focused on
  a linked folder, nothing stripped, and every "Ignore in comparison" landed in the **durable**
  per-pair store as a verbatim absolute path — pane-specific, invisible to the other side. Its own
  doc comment warns about exactly this outcome.

**The rule, so it is not re-derived per site:** a pane root joined with a pane-relative path goes
through `PathBoundary.join`; a first component under a tree root goes through
`PaneBrowsePath.step(from:into:atRoot:linked:)`. Lexical composition is correct only where the root
is already resolved — the filing profile's root, a scan root, a restructure root — and those sites
were checked and left alone.

### 20. The editor rail's empty caption, which called a folder of PDFs empty — CLOSED, does not apply (filed 2026-09-09)

**No maintenance line has an editor at all**, so there is no line for this to be owed to. The Edit
workspace is v5 work — it landed on `main` for v5.2 — and neither file this change touches exists
on any of the three:

```sh
for l in v4.x v3.x v2.x; do
  echo -n "$l: "
  git ls-tree -r --name-only origin/$l \
    -- Modules/FileExplorer/Sources/FileExplorer/EditorRail.swift \
       Modules/FileExplorer/Sources/FileExplorer/EditorFileRailView.swift | wc -l
done   # all three print 0
```

Recorded rather than left unwritten because the *absence* is the expensive half to reconstruct: a
future audit grepping for `fileEmptyCaption` finds nothing on three lines and cannot tell "never
had it" from "missed it". This row says which.

**What the user saw** (`main` only): the rail lists `PairContentKind.text` and nothing else, so a
folder holding only PDFs, scans or Word documents drew "No text files in this folder. The + button
makes one." — the same words an empty folder drew, and the whole rail otherwise blank. Standing in
a folder he had just filled, the app read as though it had lost it. The fix counts what the rail
declined to list and says so; the count excludes subfolders, because "none of the 4 files" over
three folders and one PDF would be a second wrong answer in place of the first.

---

## 2026-09-09 — Renames' breakdown moves to the blurb, and the detail slot gets a contract (`bb0adfde`)

The other half of the row above. Both arms that were putting a *summary* in the overview's
detail slot now carry it in the blurb, and the slot's rule — **rows you could act on, or nothing** —
is written on `OrganizeOverviewState.findings` where the slot is declared.

**`v4.x` has this defect in code too, and its fix is blocked on a different missing piece than the
Restructure one was.** Same shape as the row above, different prerequisite.

```sh
L=Modules/FileExplorer/Sources/FileExplorer/LensWorkspaceView.swift
for l in main v4.x v3.x v2.x; do
  printf '%-6s tally=%s headerBreakdown=%s risky=%s breakdownInFile=%s monoSlot=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/RenameBacklogTally.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/RenameBacklogTally.swift 2>/dev/null | grep -c 'var headerBreakdown')" \
    "$(git show origin/$l:$L 2>/dev/null | grep -c 'scopedRisky')" \
    "$(git show origin/$l:$L 2>/dev/null | grep -c 'tally.breakdown')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift 2>/dev/null | grep -c 'design: .monospaced')"
done
# main 1/1/5/2/1 · v4.x 1/0/5/3/1 · v3.x and v2.x 0/0/0/0/0
```

**`breakdownInFile` counts the whole file and must be read, not totalled** — the same trap the row
above names. `main`'s two are the Renames *header*'s tooltip and accessibility label, where the full
form is right (no width limit, and a screen reader is not short of room); the overview's use is
gone. `v4.x`'s three include line 3357, which IS the overview's detail slot:

```sh
git show origin/main:$L | grep -n -B1 'tally.breakdown'   # 1958 .help(…), 1966 .accessibilityLabel(…)
git show origin/v4.x:$L | grep -n    'tally.breakdown'    # 1801, 1802 header Text; 3357 THE DEFECT
```

| What landed on `main` | `v4.x` | `v3.x` | `v2.x` | Status |
|---|---|---|---|---|
| Renames' breakdown moves from the detail slot to the blurb | **The defect is real and the fix is unpickable as written.** Line 3357 puts the tally in the slot, and `design: .monospaced` is on that slot there too, so it renders exactly as `main`'s did — prose in a font meant for filenames. But **`headerBreakdown` does not exist on this line**: `RenameBacklogTally` is there and carries `breakdown` and `claim` only, and that line's own Renames header draws the full `breakdown` (1801–1802) because it has nothing shorter to draw. A pick would have to use `breakdown`, which appends "N left alone" under the words *Names worth changing* — a file the pass declined to rename is not one of those, and avoiding exactly that is why the shorter form exists | **Does not apply** — no `RenameBacklogTally`, no overview | **Does not apply** | RECORDED — not owed; defect real, fix blocked on `headerBreakdown` (`v4.x`) |
| The slot's contract on `OrganizeOverviewState.findings`, and `noLensPutsProseInTheExampleSlot` | **Does not apply on its own.** It is a rule about a slot two arms have been moved out of; asserted against `v4.x` as it stands it would fail, correctly, and pinning a rule the code does not follow is a red suite, not a guard | **Does not apply** | **Does not apply** | CLOSED — carried by the pick above, if that is ever made |
| The draft bullet in `RELEASE_NOTES.md` and `docs/releases.html` | **Does not apply as written** | **Does not apply** | **Does not apply** | CLOSED — written per line, never copied |

**Both halves of this pair are blocked on something small and different**: Restructure's on
`FindingKind`, Renames' on `RenameBacklogTally.headerBreakdown`. Neither is a large backport on its
own, and a session that picked either without its prerequisite would land a summary that reads
wrong rather than one that does not compile — which is the failure worth writing down, because the
compiler will not raise it.
---

## 2026-09-09 — the zone sweep closes: eleven formatters, one rule, and a scan that found the last two

`main` `<SHAs read after the push>`. The two sections above fixed three date columns one at a time.
An audit of the rest of the tree found **eight more**, so the rule stopped being copied and became a
type: `Design.ZoneRefreshedFormatter`, which all eleven call sites now share. `Events` keeps its own
lock-guarded version, deliberately — it is a leaf module that must not depend on Design, and its
formatter answers a question about the log FILE rather than a column.

**The two that a hand audit missed are the reason there is now a test instead of a grep.** The
manual pass keyed on `static let …[Ff]ormatter` and found nine. `LensWorkspaceView.receiptWeekday`
and `receiptDate` are the identical defect with names that say nothing about formatting, and only a
scan keyed on the CONSTRUCTOR saw them. `CapturedTimeZoneScanTests` is that scan, and it lives in
the app-target tests because no package can see another.

```sh
# stage 1 — which of the eight new sites each line carries
D=Modules/Dashboard/Sources/Dashboard; F=Modules/FileExplorer/Sources/FileExplorer
for l in main v4.x v3.x v2.x; do
  printf '%-6s logGroupHdr=%s details=%s colPreview=%s compareCopies=%s dupCard=%s fileTree=%s reviewCard=%s receipts=%s\n' "$l" \
    "$(git show origin/$l:$D/LogGrouping.swift 2>/dev/null | grep -c 'setLocalizedDateFormatFromTemplate')" \
    "$(git show origin/$l:$D/DetailsSidebar.swift 2>/dev/null | grep -c 'nonisolated private static let dateFormatter')" \
    "$(git show origin/$l:$F/ColumnPreviewColumn.swift 2>/dev/null | grep -c 'static let dateFormatter')" \
    "$(git show origin/$l:$F/CompareCopiesModels.swift 2>/dev/null | grep -c 'static let dateFormatter')" \
    "$(git show origin/$l:$F/DuplicateGroupCard.swift 2>/dev/null | grep -c 'static let dateFormatter')" \
    "$(git show origin/$l:$F/FileTreeView.swift 2>/dev/null | grep -c 'static let modifiedFormatter')" \
    "$(git show origin/$l:$F/ReviewCardModel.swift 2>/dev/null | grep -c 'static let dateFormatter')" \
    "$(git show origin/$l:$F/LensWorkspaceView.swift 2>/dev/null | grep -c 'static let receipt')"
done
# main 2/1/1/1/1/1/1/2 · v4.x 2/1/1/0/1/1/1/0 · v3.x and v2.x 2/1/1/0/0/1/1/0

# stage 2 — the shared type's prerequisites, which are present everywhere
for l in main v4.x v3.x v2.x; do
  printf '%-6s Design=%s Dashboard→Design=%s FileExplorer→Design=%s SyncCloudTests=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Design/Sources/Design | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/Dashboard/Package.swift 2>/dev/null | grep -c '"../Design"')" \
    "$(git show origin/$l:Modules/FileExplorer/Package.swift 2>/dev/null | grep -c '"../Design"')" \
    "$(git ls-tree -r --name-only origin/$l -- SyncCloudTests/TestSupport.swift | wc -l | tr -d ' ')"
done
# every line: Design present (33–47 files), both modules already depend on it, SyncCloudTests exists
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`Design.ZoneRefreshedFormatter`** — the shared type | Applies in full and lands cleanly: Design is there and both consumers already depend on it, so the type carries no new edge in the graph | Same — Design is smaller on these lines (33–35 files vs 47) but the dependency edges are identical | RECORDED — not owed |
| **The Activity Log's day header** (`LogGrouping.headerThisYear` / `headerOtherYear`, rendered in `calendar.timeZone`) | Applies, and it is **the row to take first if these are ever picked**: a header a full day out, on every line, with `Today`/`Yesterday` masking it so it only shows on sections two days old and older. Present on all three (`logGroupHdr=2`) | Same | RECORDED — not owed |
| **`DetailsSidebar`** — the one site reached off the main actor | Applies on all three (`details=1`), and is the row that must NOT be picked as a bare zone check: its formatter is `nonisolated` and read inside `loadMetadata`, so the compare-and-assign has to be under a lock. The shared type is what supplies that | Same | RECORDED — not owed |
| **`ColumnPreviewColumn`, `FileTreeView`, `ReviewCardModel`** | Apply on all three, unchanged shapes | Same | RECORDED — not owed |
| **`CompareCopiesModels`** | **Does not apply** — Compare Copies is a v5 surface; `compareCopies=0` on every maintenance line | Does not apply | CLOSED — does not apply |
| **`LensWorkspaceView.receiptWeekday` / `receiptDate`** | **Does not apply** — the Organize overview receipt shipped with the v5.3 document-survey work; `receipts=0` on every maintenance line | Does not apply | CLOSED — does not apply |
| **`DuplicateGroupCard`** + its `timeZone` injection and the snapshot pin | Applies on `v4.x` (`dupCard=1`). The card's references there carry the same latent trap `main`'s did and would need the pin picked with it | **Does not apply** — no `DuplicateGroupCard` on either line | RECORDED — not owed (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`CapturedTimeZoneScanTests`** — the repo-wide guard | Applies, **with its allow-list edited per line**: the list names four files by path and `CompareCopiesModels`/`LensWorkspaceView` aside, a line missing any allow-listed file fails the list's own anti-rot test rather than passing quietly. That is the intended behaviour, not a defect in the pick | Same, with more editing | RECORDED — not owed |

**The thing worth not re-deriving.** A hand audit of this defect will undercount, and it is worth
knowing *why* before repeating one. Every search that looks for the formatter by NAME misses the
sites whose formatters are not called "formatter" — here that was two of eleven, both on a
per-`body` path, both user-visible. The scan that finds all of them keys on `DateFormatter()`, the
constructor, and then has to exclude `ISO8601DateFormatter()`, which ends with the same fifteen
characters and is a different type with nothing to capture (it is pinned to a stated zone by
construction). Allow-listing that file would have been the wrong fix and would have quietly covered
any real formatter it later grew; matching on the identifier boundary is the right one.

**And the assertion trap that nearly shipped with it.** The first version of the day-header test
compared the header of a UTC bucket against a Kolkata one and asserted they differed. That passes
under the bug — the two buckets are different instants and render differently in any single zone —
and the mutation that puts the formatter back on the system zone went green straight through it. A
zone test has to pin the RENDERED value against a control built in the bucket's own zone. The two
zones the test settled on are the extremes of the real offset range (+14 and −12), which is what
makes it independent of the machine: rendering midnight-in-Z under the system zone C names the wrong
day whenever `offset(C) < offset(Z)`, and between those two Z values every possible C is covered.

## 2026-09-09 — the workspace switch stops throwing away what the reader set (`bed8e2ce`..`f88f42bd`)

`main` `bed8e2ce`..`f88f42bd`. `verticalSplit` lays the window out as a `switch` over
`contentLayout`, and each arm is a separate SwiftUI identity — so moving between Browse, Compare,
Organize and Edit tears the outgoing workspace's tree down and builds the incoming one from nothing.
Five things a reader had set went with it. None of this changes the mounting; each fix moves the
state to a host that outlives the switch.

**The finding that decides most of the rows below: the CAUSE is a v5 shape.** The four-workspace bar
is what makes a switch destroy a workspace, and `Workspace` has four cases on `main`, three on
`v4.x`, two on `v3.x` and none on `v2.x` (which has no workspace enum at all). So the same code can
carry the same state and still not have the same defect — a line with one workspace never leaves it.
Read the applicability column as "does this line's UI reach the teardown", not "does the file exist".

```sh
# which surfaces each line carries, and whether the switch that destroys them exists
F=Modules/FileExplorer/Sources/FileExplorer
for l in main v4.x v3.x v2.x; do
  printf '%-6s thumb=%s lens=%s diffs=%s tree=%s editorDoc=%s workspaceCases=%s\n' "$l" \
    "$(git show origin/$l:$F/DuplicateThumbnail.swift 2>/dev/null | grep -c 'imageCache')" \
    "$(git show origin/$l:$F/LensWorkspaceView.swift 2>/dev/null | grep -c 'searchQueries')" \
    "$(git show origin/$l:$F/DifferencesView.swift 2>/dev/null | grep -c 'collapsedSections')" \
    "$(git show origin/$l:$F/FileTreeView.swift 2>/dev/null | grep -c 'private var expanded: Set<String>')" \
    "$(git show origin/$l:$F/EditorDocument.swift 2>/dev/null | grep -c 'public let buffer')" \
    "$(git show origin/$l:MacApp/Workspace.swift 2>/dev/null | grep -cE '^    case (browse|compare|filing|editor) =')"
done
# main   thumb=6 lens=15 diffs=21 tree=1 editorDoc=1 workspaceCases=4
# v4.x   thumb=4 lens=14 diffs=15 tree=1 editorDoc=0 workspaceCases=3
# v3.x   thumb=4 lens=0  diffs=14 tree=1 editorDoc=0 workspaceCases=2
# v2.x   thumb=4 lens=0  diffs=14 tree=0 editorDoc=0 workspaceCases=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`DuplicateThumbnail.cached(…)`** — a synchronous peek at the static `NSCache`, so a returning tile paints the preview it already has instead of one frame of the file-type icon. Plus `key(…)` and `store(…)` as single expressions both ends share | Applies (`thumb=4`), and the defect is real there — the cache is `static` on every line, so the flash is a nil `@State` and not a reload | Applies on `v3.x`; the file is present on `v2.x` too. Lower value: fewer workspaces to switch between | RECORDED — not owed |
| **`EditorCaretAnchors`** + `PlainTextEditor.initialSelection` — the caret and scroll survive a switch | **Does not apply** — the Editor workspace shipped in v5.2; `editorDoc=0`, no `PlainTextEditor` on the line | Does not apply | CLOSED — does not apply |
| **`FileTreeView.hostExpanded`** — the Tree's open folders held per side by `ContentView` | Applies (`tree=1`) and the defect is reachable: three workspaces, and `paneColumn` is mounted by several arms there too. **The row that must not be picked as the storage change alone** — `FileTreeView.==` is hand-written, and moving the set to a binding without adding it to that comparison stops every disclosure triangle responding to clicks | Applies on `v3.x` (`tree=1`), with the same `==` caveat. **Does not apply** on `v2.x` — no such set (`tree=0`) | RECORDED — not owed (`v4.x`, `v3.x`); CLOSED — does not apply (`v2.x`) |
| **`LensWorkspaceSession`** — Organize's filter, parked queries, folds, tallies and session flags | Applies (`lens=14`). Note the pick is 16 declarations turned into forwarders, so it is wide but mechanical; the two `Binding` sites (the filter `Picker`, the rule-variant chooser) are the only edits that are not a declaration | **Does not apply** — no `LensWorkspaceView` on either line (`lens=0`) | RECORDED — not owed (`v4.x`); CLOSED — does not apply (`v3.x`, `v2.x`) |
| **`DifferencesSession`** — Compare's filter, search, sort and folded sections | Applies (`diffs=15`). **The row with a trap, and it is the whole reason this one took longer than Organize's**: `collapsedSections` and the `.failed` filter are retired by `.onChange` handlers that cannot fire while the view is unmounted, so today the REBUILD is the reset. Picking the storage move without `collapsedSectionsScanDate` and the two arrival guards reintroduces a fold that hides differences nobody has seen, and a `.failed` filter over a table with nothing failed in it | Applies on both (`diffs=14`), same trap. On `v2.x` there is no workspace enum, so the teardown never happens and the value is nil | RECORDED — not owed (`v4.x`, `v3.x`); CLOSED — does not apply (`v2.x`) |
| **Row selections deliberately NOT hoisted** (`selection`, `reviewSelection`) | n/a — nothing to pick | n/a | Recorded so a later pick does not "finish the job": an ID names a row in one comparison, and carrying one across a rescan points it at rows that no longer exist |

**What a repeat of this should measure first.** The obvious repro for the pane's open folders says
the bug is not there. The column stack lives on the manager and survives, and
`carryColumnsIntoTree` re-opens the one descending path it names on arrival — so expanding a folder,
then its child, then its child, and coming back, looks like it worked. Two SIBLING folders is the
test that shows it, because a single descending trail is the most a carry-over can restore.

**And the measurement that corrected the editor row.** A fresh `NSTextView` does not select `{0, 0}`
after `view.string = text`; it puts the caret at the END (11 for `"hello there"`), with the scroll
view independently still at the top. That is why the symptom reads as "back to the top" while the
caret sits invisibly at the bottom — and why a restore that skips a zero anchor as "nothing
recorded" hands the top-of-file reader their document back with the caret at the end.


## 2026-09-09 — the difference picture is drawn from the aligned pair (CC14.4 follow-up)

`BitmapDiff.compareAligning(_:_:wantsDifferenceImage:)` now takes its difference raster from the
same walk that produced the numbers, instead of running a second walk over the two pages as they
are. This settles the disagreement the function's own doc comment flagged when CC14.4 landed
(2026-09-02): the callouts came from the aligned pair and the glow from the unaligned one.

**Not owed anywhere, and for the strongest of the reasons — the file does not exist off `main`.**

```sh
# stage 1 — is the FILE there? main is the positive control: it must print 1 across its row.
for l in main v4.x v3.x v2.x; do
  printf '%-6s bitmapdiff=%s registration=%s sheet=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/BitmapDiff.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PageRegistration.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/CompareCopiesSheet.swift | wc -l | tr -d ' ')"
done
# measured 2026-09-09: main 1/1/1 · v4.x 0/0/0 · v3.x 0/0/0 · v2.x 0/0/0
```

**Stage 2 was not run, and that is the answer rather than a skipped step** — there is no
`BitmapDiff.swift` on any maintenance line to grep inside. The pixel comparison arrived with the
file-pair viewer, which is `main`-only; `v4.x` was cut at `v4.6` on 2026-08-28, before it.

| What landed on `main` | `v4.x` / `v3.x` / `v2.x` | Status |
|---|---|---|
| **`compareAligning` draws the picture from `aligned`** rather than from `right` — one walk instead of two, and the glow and the callouts stop being of different image pairs | No `BitmapDiff.swift`: no pixel difference, no de-skew, nothing to draw either way | CLOSED — checked, does not apply |
| **`thePictureAndTheFigureAreOfTheSamePair`** — counts the picture's above-tolerance pixels back and requires them to reproduce `changedFraction` exactly, with a guard that the fixture really aligned and a guard that the old shape would have failed | No `PageRegistrationTests.swift` | CLOSED — checked, does not apply |
| **The region count a de-skew inflates**, recorded at `ChangedRegionCallouts.maxDrawn` — a corrected pair fragments a solid glow into speckle (214 regions against 22 unaligned, measured on the shipped pipeline), so the caption says "too many to outline" and nothing is drawn. Documented, deliberately not fixed | No `ChangedRegionCallouts.swift` — measured 2026-09-09, `main` 1, the other three 0 | CLOSED — checked, does not apply |
| **Release note and Pages bullet** under the v5.3 draft | `RELEASE_NOTES.md` exists on all three, but v5.3 is `main`'s line alone; `docs/releases.html` is served from `main` only | CLOSED — checked, does not apply |

**Two measurements this leaves on record, because they are the expensive half to reconstruct and
they bound what any future work on the estimator can achieve.** Both at 1600x2070, Apple M4,
Release, machine quiet:

- **The change is a saving, not a cost.** One walk over the aligned pair against a walk plus a
  second walk for the picture: a little over **40% off the diff work**, and **~25 MB** less
  transient allocation. Quiet-machine reading, best of 20: 10.4 ms against 18.7 ms; the same build
  on a busy machine reads 14.3 against 26.3. The absolutes move with load and the proportion does
  not, so the proportion is the claim.
- **A perfect de-skew does not clean the page, so do not tune the estimator expecting one.**
  ``warped`` resamples the right page and leaves the left alone, and that asymmetry alone clears
  ``BitmapDiff.tolerance`` on every anti-aliased edge. On a pair with one paragraph rewritten: the
  true answer is 0.78% changed and ONE region; the estimate's alignment gives 3.42% and eight; an
  *exact* alignment gives the same 3.42% and eight; putting both sides through the same resample
  gives 0.94% and one. 2.87 of those 3.42 points is the one-sided resample, not the geometry.

Recorded rather than picked, per the standing direction — though here the direction never comes
into it, since there is no line to pick onto.

---

## 2026-09-09 — the privacy scan's exclusions read the checkout's own ancestry

`NoTelemetryTests.shippedSources` walks the **repository root** — it is the only repo-wide scan here
that does, which is why it is the only one that needs an exclusion list at all. It tested that list
against `url.standardizedFileURL.pathComponents`, the whole **absolute** path, so components *above*
the root voted too. CLAUDE.md requires every session to work in a worktree under
`<repo>/.claude/worktrees/<name>`; `.claude` is on the exclusion list; so in the only place anybody
is allowed to work, every file under the root matched, `shippedSources` came back **empty**, and
`theScanCanSeeTheSources`, `theScansAreNotVacuous` and `onlyTheRefinePathReachesTheNetwork` all
failed. The fix filters the components **below** `rootPath` instead, which keeps every exclusion's
intent — a `.build` or `.dd` copy, another branch's checkout under `.claude/worktrees` — without the
root's ancestry deciding the answer. Introduced by `01cf7a48`, whose row is the 2026-09-07 section
above.

**Why nothing surfaced it for two days.** The self-hosted runner checks out to
`~/actions-runner-synccloud-x64/_work/...`, which has no excluded component, so CI was green
throughout. This is the inverse of the usual reading — *green on CI, red on every developer machine*
— and the reason to write it down is that the next scan to walk the repo root will be tempted to
copy this exclusion list.

```sh
# stage 1 — is the suite there at all? main is the positive control.
# stage 2 — the SHAPE: does any Swift file on the line key on ".claude"?
for l in main v4.x v3.x v2.x; do
  printf '%-6s noTelemetry=%s belowRoot=%s dotClaudeInSwift=%s sourceCodeOnly=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- SyncCloudTests/NoTelemetryTests.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:SyncCloudTests/NoTelemetryTests.swift 2>/dev/null | grep -c 'componentsBelowRoot')" \
    "$(git grep -l '"\.claude"' origin/$l -- '*.swift' 2>/dev/null | wc -l | tr -d ' ')" \
    "$(git show origin/$l:SyncCloudTests/TestSupport.swift 2>/dev/null | grep -c 'func sourceCodeOnly')"
done
# measured 2026-09-09, before this landed:
# main   noTelemetry=1 belowRoot=0 dotClaudeInSwift=1 sourceCodeOnly=1
# v4.x   noTelemetry=0 belowRoot=0 dotClaudeInSwift=0 sourceCodeOnly=1
# v3.x   noTelemetry=0 belowRoot=0 dotClaudeInSwift=0 sourceCodeOnly=0
# v2.x   noTelemetry=0 belowRoot=0 dotClaudeInSwift=0 sourceCodeOnly=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`componentsBelowRoot`** — the exclusions read the path below the repository root, not the whole absolute path | **Does not apply.** `NoTelemetryTests.swift` does not exist on the line (`noTelemetry=0`), and no Swift file on it names `.claude` at all, so there is nothing carrying the defect to fix. The suite's own row in the 2026-09-07 section already stands at RECORDED — not owed; if it is ever picked, pick it **with** this fix, or the pick lands red in the worktree it is developed in | Same, and further from applying: `sourceCodeOnly` is missing too, so the suite has no way to read source there | CLOSED — does not apply |
| **The near-vacuous message** on `theScanCanSeeTheSources`, which now names the root it read and says an empty result means the walk excluded everything | Does not apply — same reason | Same | CLOSED — does not apply |

**The family was checked, and this is the only member.** Every other repo-wide source scan anchors
its walk under a named subdirectory (`Modules`, `MacApp`, `SyncCloudCLI`, or a module's `Sources/`)
and filters with **slash-anchored substrings** — `/Tests/`, `/.build/`, `/Sources/` — which an
ancestry cannot satisfy. Measured against this worktree's own root
(`/Users/abhishek/Projects/SyncCloud/.claude/worktrees/silly-raman-863c41`): of every filter any
scan uses, `.claude` was the single ancestry match, and `NoTelemetryTests` was the only file keying
on it.

**One latent sibling, recorded rather than changed.**
`PaneTabWiringTests`'s module sweep filters `!$0.pathComponents.contains("Tests")` over absolute
paths, so a checkout underneath any directory literally named `Tests` would empty `elsewhere` and
trip its `>= 250` floor — the same failure shape, the same misleading red. No such component exists
on this machine, and nothing has ever hit it, so it is written down here rather than fixed on
speculation. Its walk roots are `Modules` and `SyncCloudCLI`, never the repo root, which is what
keeps it out of reach today.

---

## 2026-09-09 — the card system's second review pass (`fdd16421`) — **nothing owed anywhere**

Five defects and two stale release-note claims, all of them in code that only `main` has. The row
exists so a future audit does not go looking: the answer is no on every line, and one of the five
is worth a sentence because a careless reader could "fix" `v4.x` into having it.

```sh
V=Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift
for l in main v4.x v3.x v2.x; do
  printf '%-6s card=%s nudgeRow=%s tally=%s guardedSlot=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/OverviewCard.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:$V 2>/dev/null | grep -c 'func nudgeRow')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/StructureBacklogTally.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:$V 2>/dev/null | grep -c 'examples.isEmpty')"
done
# main 1/1/1/1 · v4.x 0/0/0/1 · v3.x and v2.x 0/0/0/0
```

| What landed on `main` | `v4.x` | `v3.x` | `v2.x` | Status |
|---|---|---|---|---|
| **The 7pt empty content slot** — `VStack { if x }` where `if x { VStack }` was meant | **Does not apply, and `v4.x` has the CORRECT shape already.** Its `findingsSection` still reads `if !examples.isEmpty { VStack … }` (line 754), because this was a regression introduced on `main` by folding the nudge into its host card and fixed in the same pass. There is nothing here to send and nothing there to repair | **Does not apply** — no overview | **Does not apply** | CLOSED — self-inflicted on `main`; the other lines never had it |
| `nudgeVerbTitle`; `OverviewCard.dismiss`'s doc; `StructureBacklogTally`'s unreachable `"0"`; the test needle keyed on copy | **Does not apply.** No `nudgeRow`, no `OverviewCard`, no `StructureBacklogTally` — every subject is v5-only | **Does not apply** | **Does not apply** | CLOSED — does not apply on any line |
| The two corrected v5.3 draft claims | **Does not apply as written** | **Does not apply** | **Does not apply** | CLOSED — written per line, never copied |

**The one thing to carry forward**: `grep -c 'examples.isEmpty'` reads `1` on both `main` and
`v4.x` and means opposite things — the guarded form on `v4.x`, and on `main` the guarded form
restored after a pass where it was not. Read the line, do not count it. That is the third row in a
row where a count over this file misleads, which is starting to look like a property of the file
rather than an accident.

---

## 2026-09-09 — Recents becomes removable, and stops repeating the rest of the column

Two changes to the folder sidebar's Recents section: a **Remove from Recents** item on a recent's
context menu (`FolderJumpStore.forgetRecent`), and a rule that keeps a folder out of Recents when
Favorites or Locations already lists it (`FolderSidebarModel.rows(listedElsewhere:)`, fed by
`ContentView.folderSidebarListedElsewhere`). Two smaller corrections travelled with the second: the
per-section cap moved from the store to the row builder so it counts rows that are actually drawn,
and the source badge is read off the drafts rather than off the inputs.

**The section itself is v4.4 and later.** `FolderSidebar.swift` does not exist on `v3.x` or `v2.x`
at all, and neither carries `mostRecentAcrossRoots` — those lines have per-root recents behind the
pane header's jump menu and the ⌘K palette, and no cross-source column for any of this to be about.
`v4.x` carries the whole surface and therefore carries both defects.

```sh
# stage 1 — is the file there? stage 2 — is the SHAPE there? main is the positive control.
for l in main v4.x v3.x v2.x; do
  printf '%-6s sidebar=%s crossSource=%s forget=%s listed=%s cap=%s badge=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Dashboard/Sources/Dashboard/FolderSidebar.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/FolderJumpStore.swift 2>/dev/null | grep -c 'mostRecentAcrossRoots')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/FolderJumpStore.swift 2>/dev/null | grep -c 'func forgetRecent')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/FolderSidebar.swift 2>/dev/null | grep -c 'listedElsewhere')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/FolderSidebar.swift 2>/dev/null | grep -c 'recentsLimit')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/FolderSidebar.swift 2>/dev/null | grep -c 'Set(drafts.map')"
done
# measured 2026-09-09, before this landed:
# main   sidebar=1 crossSource=5 forget=0 listed=0 cap=0 badge=0
# v4.x   sidebar=1 crossSource=5 forget=0 listed=0 cap=0 badge=0
# v3.x   sidebar=0 crossSource=0 forget=0 listed=0 cap=0 badge=0
# v2.x   sidebar=0 crossSource=0 forget=0 listed=0 cap=0 badge=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`FolderJumpStore.forgetRecent`** and the **Remove from Recents** item on a recent's context menu | **Applies.** The section, its rows and their context menu are all there (`sidebar=1`), and the menu holds Add to / Remove from Favorites and nothing that removes a recent — a row you no longer want stays until eight newer visits push it out. Two files: the store member, and the item plus its `onForgetRecent` closure in `FolderSidebarView` | **Does not apply.** No `FolderSidebar.swift`, no Recents section, no row to right-click. The per-root recents these lines do have are read by the pane's jump menu and ⌘K, neither of which offers a removal either — but that is a feature gap, not this defect | RECORDED — not owed |
| **`listedElsewhere`** — a recent is dropped when Favorites' places or a Locations row already offers the folder | **Applies, and it is the visible half.** `v4.x` subtracts favorites and the landing folder (`crossSource=5`) and nothing else, so a Favorites place inside a source — Desktop, Documents, Downloads under a home-folder source — is drawn twice. Three pieces to pick together: the `rows(listedElsewhere:)` parameter, `ContentView.folderSidebarListedElsewhere`, and the `links:` argument threaded through `resolveFolderSidebarRows` so the iCloud `Documents` link is matched. `PathBoundary.relativize` is already on every line, so the arithmetic itself needs nothing | Does not apply — same reason | RECORDED — not owed |
| **The cap moved to `rows(recentsLimit:)`** so it counts drawn rows, not candidates | **Applies.** `v4.x` caps in `recentVisitsAcrossRoots` and then drops recents for a removed source in the builder, so a stale entry spends one of the eight and leaves the section short. Cannot be picked on its own: it is a two-sided change (`limit: .max` at the call site, the cap in the builder), and picking one half silently uncaps the section | Does not apply | RECORDED — not owed |
| **The source badge read off the drafts** rather than off the inputs | **Applies in principle, unreachable in practice on that line.** The old expression differs from the new one only when a recent is dropped after being counted, and on `v4.x` the only such drop is the removed-source one — rare, and it needs to be the account's *sole* contribution. Worth picking only alongside `listedElsewhere`, which is what makes it ordinary | Does not apply | RECORDED — not owed |

**Checked and not owed, the other direction.** `FolderJumpStore.recordVisit` is untouched: nothing
here changes what is *recorded*, only what is *drawn*, so the maintenance lines' stored recents stay
byte-compatible with `main`'s and the shared defaults domain is unaffected in both directions. That
was a deliberate choice rather than an omission — the places in Favorites and the rows in Locations
are the user's own list and the mounted volumes, neither of which the store can see, so a filter at
record time would have been keyed on a snapshot that goes stale the moment either changes.

## 2026-09-09 — the file preview follows the pane into Tree mode

Tree panes draw the Quick Look preview the Columns stack has had: `showsPreviewToggle` answers yes
for both modes, `ColumnPreview` grows a `treeRows:` entry point that walks the row projection down
the selected path, `FileTreeView` frames its outline to the pane minus the preview, and the preview
and its divider move into a shared `PanePreviewSidebar` so the two presentations cannot disagree
about the seam. The tree's width gate is its own rule (`showsTreePreview` /
`minimumTreeListWidth`), not the column one reused.

**Every line already has the surface this stands on**, which is unusual for a v5 feature and worth
recording: the preview column, `PaneViewMode`, and the `mode == .columns` gate that withheld it from
Tree are on all four. So the picks below are all technically *possible*; they are not owed, because
this is new work on the v5 line rather than a defect anywhere.

```sh
# stage 1 — is the preview there at all? stage 2 — is the Columns-only GATE the shape being changed?
for l in main v4.x v3.x v2.x; do
  printf '%-6s previewColumn=%s toggle=%s treeGate=%s columnsOnly=%s browseKey=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/ColumnPreviewColumn.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/Design/Sources/Design/PaneViewMode.swift 2>/dev/null | grep -c 'func showsPreviewToggle')" \
    "$(git show origin/$l:Modules/Design/Sources/Design/PaneViewMode.swift 2>/dev/null | grep -c 'showsTreePreview')" \
    "$(git show origin/$l:Modules/Design/Sources/Design/PaneViewMode.swift 2>/dev/null | grep -c 'mode == .columns')" \
    "$(git show origin/$l:Modules/Design/Sources/Design/PaneViewMode.swift 2>/dev/null | grep -c 'browsePreviewColumnDefaultsKey')"
done
# measured 2026-09-09, before this landed:
# main   previewColumn=1 toggle=1 treeGate=0 columnsOnly=1 browseKey=4
# v4.x   previewColumn=1 toggle=1 treeGate=0 columnsOnly=1 browseKey=4
# v3.x   previewColumn=1 toggle=1 treeGate=0 columnsOnly=1 browseKey=0
# v2.x   previewColumn=1 toggle=1 treeGate=0 columnsOnly=1 browseKey=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **The Tree preview itself** — `showsTreePreview` / `minimumTreeListWidth`, `ColumnPreview.item(selection:treeRows:)`, and `FileTreeView.treePresentation` | **Could be picked.** `columnsOnly=1` says the gate being flipped is there verbatim, and so is everything under it. Four files plus two new test suites; nothing it needs is missing | **Could be picked, with one extra decision.** `browseKey=0`: neither line splits Browse's preference from Compare's, so the preference this feature spreads across both modes is one key for every surface there. Decide what that should mean *before* picking, rather than discovering it | RECORDED — not owed. New v5 work, and the standing direction is no backporting |
| **`PanePreviewSidebar` / `PaneDividerHandle`** — the extraction that made one preview serve two presentations | Could be picked, and is worth nothing on its own: with no Tree preview there is one caller, which is what the code already was | Same | RECORDED — not owed |
| **View ▸ Preview Column → View ▸ Preview**, and the help and ⌘/ strings that named a column | Could be picked. All three lines carry the item under the old title | Same | RECORDED — not owed. Renaming it where the preview really is a column only would make those lines *less* accurate |

**Checked and not owed, the other direction.** The stored keys are untouched — `paneColumnShowsPreview`,
`paneColumnShowsPreviewBrowse` and `paneColumnPreviewWidth` keep their names, their meanings and
their defaults, and the tree reads the same preference the columns do rather than adding a fourth.
A maintenance-line build and a `main` build therefore still share one defaults domain without either
reinterpreting what the other wrote: an install that has turned the preview off sees it off in both,
and a preview dragged wide on one opens that wide on the other.

---

## 2026-09-09 — the squash recipe drops `git reset`, and step 3 prefers one commit — **nothing owed**

A working-agreement change, not code. `CLAUDE.md` step 3 used to squash a branch with
`git reset --soft` to the merge base; a standing direction on 2026-09-09 banned `git reset` in every
flavour and force-push with it, so the step now replays onto a fresh branch instead —
`git merge --squash` for the one-commit default, `git cherry-pick -n` groups when a second theme
really earns its place, and an equivalence diff to prove the rebuild lost nothing.

The row exists so a future audit does not go looking for a pick that cannot be made: the banned
recipe never reached the maintenance lines, and neither did the step that carried it.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s resetSoft=%s mergeSquash=%s squashMentions=%s\n' "$l" \
    "$(git show origin/$l:CLAUDE.md 2>/dev/null | grep -c 'reset --soft')" \
    "$(git show origin/$l:CLAUDE.md 2>/dev/null | grep -c 'merge --squash')" \
    "$(git show origin/$l:CLAUDE.md 2>/dev/null | grep -ci 'squash')"
done
# measured 2026-09-09, before this landed:
# main   resetSoft=3 mergeSquash=0 squashMentions=high
# v4.x   resetSoft=0 mergeSquash=0 squashMentions=1   ← and that 1 is a BRANCH NAME, not the step
# v3.x   resetSoft=0 mergeSquash=0 squashMentions=0
# v2.x   resetSoft=0 mergeSquash=0 squashMentions=0
```

| What landed on `main` | `v4.x` | `v3.x` | `v2.x` | Status |
|---|---|---|---|---|
| **Step 3 rewritten** — `reset --soft` out, `git merge --squash` / `cherry-pick -n` in, one commit preferred | **Cannot be picked, and nothing is missing.** `v4.x` carries an older *Session isolation* section with **no squash step at all** — work is committed on the worktree branch and landed as-is. There is no recipe there to correct | **Same** — no squash step | **Same** | RECORDED — not owed. There is no counterpart to replace |
| **The three measured failure modes of `git checkout <task> -- <paths>`** — final-state bleed, silent revert of a concurrent `main` change, leaked deletion | Does not apply: no line but `main` tells a session to build a commit that way | Does not apply | Does not apply | RECORDED — not owed |
| **The `git reset` / force-push ban itself** | **Applies everywhere, and is written down only on `main`.** The direction is about how *he* wants git driven, not about v5 code, so a session that ever works a maintenance line would read a `CLAUDE.md` that never mentions it | Same | Same | RECORDED — not owed under the standing no-backport direction. Named here because this is the one row where the gap is a real one rather than a non-applicable one |

**The one thing to carry forward**: `grep -ci squash` reads `1` on `v4.x` and means nothing —
the hit is `backup-roots-preReviewSquash2`, a branch name in the `roots` write-up, not a squash
step. Read the line, do not count it.

## 2026-09-09 — a PDF preview fits the whole page instead of the pane's width

Quick Look scales a PDF page to fit the preview's WIDTH and lets the height overflow, so the wider
the pane the less of the page was visible. Measured on a letter page in a 560pt-tall preview: at
388pt wide it fitted almost exactly, and at 820pt it rendered about 1060pt tall — the top third and
no way to reach the rest, because Quick Look draws in an out-of-process `NSRemoteView` whose scale
and scrolling are the extension's. PDFs therefore move to PDFKit in-process (`PDFPagePreview`,
`FitPagePDFView`, `PreviewRenderer`), fitted on whichever dimension is tighter and in
`singlePageContinuous` so a scroll walks the document. Everything else stays with Quick Look, which
was measured rather than assumed.

**This one is a DEFECT, and every line has it.** All three carry the preview column and its
`QuickLookPreview`, unchanged, so all three show a PDF the same wrong way. That is a stronger case
for a pick than the tree preview two rows up — which was a feature — and it is still not owed, for
the same reason: the standing direction is no backporting. Written down so the next audit sees a
user-visible defect rather than an enhancement.

```sh
# stage 1 — is the preview there? stage 2 — is the RENDERER the one with the defect, and is the fix absent?
for l in main v4.x v3.x v2.x; do
  printf '%-6s previewColumn=%s quickLook=%s pdfFit=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/ColumnPreviewColumn.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/ColumnPreviewColumn.swift 2>/dev/null | grep -c 'struct QuickLookPreview')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PDFPagePreview.swift | wc -l | tr -d ' ')"
done
# measured 2026-09-09, before this landed:
# main   previewColumn=1 quickLook=1 pdfFit=0
# v4.x   previewColumn=1 quickLook=1 pdfFit=0
# v3.x   previewColumn=1 quickLook=1 pdfFit=0
# v2.x   previewColumn=1 quickLook=1 pdfFit=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **The PDF renderer** — `PDFPagePreview`, `FitPagePDFView`, `PreviewRenderer`, and the switch in `ColumnPreviewColumn.preview` | **Applies, and the defect is present.** One new file plus a `contentType` on `ColumnPreviewItem` and a two-case switch; it needs nothing this line lacks, PDFKit being a system framework | Applies, same shape and same defect | RECORDED — not owed |
| **`ColumnPreviewItem.type(uti:path:)`** — the extension fallback, and its rejection of `dyn.…` placeholder types | Applies only alongside the renderer; on its own it computes a type nothing reads | Same | RECORDED — not owed |
| **`clearInheritedBackground`** — PDFKit's scroll view painting a white slab around the page | **Does not apply.** It is a defect in the new renderer, not in anything these lines have | Same | CLOSED — does not apply |

**Checked and not owed, the other direction.** Nothing here touches a stored preference or the
preview's sizing keys: `paneColumnPreviewWidth` and the two `paneColumnShowsPreview` keys keep their
names, meanings and defaults, so a maintenance-line build and a `main` build still share one defaults
domain. The change is entirely in which view draws a file and at what scale.

## 2026-09-15 — folder Merge on collision (RD23), and a Cancel that stops the copy in flight (RD24)

Two changes to the transfer path. **RD23** adds `CollisionResolution.merge`: a pane transfer that
lands a folder onto a real folder offers Merge as the default, counts what Replace and Merge would
each do (`folderMergePreview`), and merges child by child through the existing primitives and
`bulkCollisionResolver`. **RD24** routes every staging copy that has a Progress to watch through
`FileManager.observedCopyItem` — `copyfile(3)` with a callback — so Cancel abandons the item in
flight inside its `.tmp_` file, and adds a bytes line to the progress dialog for a slow pane copy.

**Every maintenance line carries the surface both changes are about, unchanged.** The collision enum
has its three cases, the bulk resolver and the conflict policy exist, the transfer loop checks Cancel
only between items, and the alert still warns that replacing a folder trashes its entire contents:

```sh
# stage 1 — is the file there? stage 2 — is the SHAPE there? main is the positive control.
for l in main v4.x v3.x v2.x; do
  printf '%-6s collision=%s mergeCase=%s bulkResolver=%s policy=%s observed=%s bulkIO=%s transferLoop=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Sources/Sync/CollisionResolution.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/CollisionResolution.swift 2>/dev/null | grep -c 'case merge')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift 2>/dev/null | grep -c 'public var bulkCollisionResolver')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Sources/Sync/ConflictPolicy.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Sources/Sync/ObservedCopy.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+BulkSync.swift 2>/dev/null | grep -c 'func performBulkSyncIO')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations.swift 2>/dev/null | grep -c 'if progress?.isCancelled == true { break }')"
done
# measured 2026-09-15, before this landed:
# main   collision=1 mergeCase=0 bulkResolver=1 policy=1 observed=0 bulkIO=1 transferLoop=2
# v4.x   collision=1 mergeCase=0 bulkResolver=1 policy=1 observed=0 bulkIO=1 transferLoop=2
# v3.x   collision=1 mergeCase=0 bulkResolver=1 policy=1 observed=0 bulkIO=1 transferLoop=2
# v2.x   collision=1 mergeCase=0 bulkResolver=1 policy=1 observed=0 bulkIO=1 transferLoop=2
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`CollisionResolution.merge`**, `FileCollision.offersMerge` / `mergePreview`, `isMergeableFolder` (no symlinks, no packages), the recursive merge in `transferItems`, and the four-button alert with its counted sentence | **Applies whole.** Same enum, same loop, same alert. Pick as one: the enum case makes every `switch` over it non-exhaustive (`transferItems`, `syncFile`, `syncAll`), so a partial pick does not build. The alert half lives in `MacApp/`, so the app target must be built, not only the package | Applies, same shape | RECORDED — not owed |
| **`FileManager.observedCopyItem`** and `CopyObserver`, the `FileManaging.copyItem(at:to:observer:)` requirement, and the `observer:` parameter on `safeCopyItem` / `safeMoveItem` / `performFileSyncIO` | **Applies.** Self-contained: one new file, a defaulted protocol requirement (every test double keeps compiling), and defaulted parameters. The folder-time correction is part of the file, and must travel with it — without it a copied folder holding a symlink comes back stamped with the time of the copy | Applies, same shape | RECORDED — not owed |
| **The two callers** — `transferItems` handing the observer and the bytes line, `performBulkSyncIO` treating a cancellation as neither success nor failure | Applies only alongside the primitive. The bulk half is the one that matters: without its `catch where isCancellation`, a cancelled copy is reported in the failure alert | Same | RECORDED — not owed |
| **`transferItems` refactored into `land` / `recordLanded`** | Not a behaviour change on its own — the identity-walk code moved verbatim so a merge's children could use it. Needed only as the carrier for the merge | Same | RECORDED — not owed |

**Checked and not owed, the other direction.** Nothing here is stored: no defaults key, no file
format, no change to `ConflictPolicy`'s raw values, so a `main` build and a maintenance-line build
still share one defaults domain. And one thing measured along the way that is **not** a defect in
this change and is on every line: `trashItem` on a file deletes the `.DS_Store` of the folder it
leaves, so every Replace — on all four lines — has always dropped the destination folder's Finder
view settings. Written down because a merge test expecting the destination's `.DS_Store` to survive
tripped on it, and the next audit should not re-diagnose it as a merge bug.

---

## Open in Edit leads the row menu, and the editor's text gate goes public (TE27)

`main` only, and **not owed anywhere** — not because the change is small, but because the surface it
edits does not exist on any maintenance line. The Edit workspace, its hand-off, its rail and the
`PairContentKind` the gate reads all arrived after `v4.6`, so there is no row menu on `v4.x`,
`v3.x` or `v2.x` with an editor item in it to reorder, and no module outside FileExplorer asking
what the editor opens:

```sh
# every count is 0 off main, and main is the positive control.
for l in main v4.x v3.x v2.x; do
  printf '%-6s openInEditorVerb=%s handOff=%s pairKind=%s editorRail=%s\n' "$l" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift 2>/dev/null | grep -c 'func openInEditor')" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/ContentView+Editor.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PairContentKind.swift 2>/dev/null | grep -c 'enum PairContentKind')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorRail.swift | wc -l | tr -d ' ')"
done
# measured 2026-09-16, before this landed:
# main   openInEditorVerb=1 handOff=1 pairKind=1 editorRail=1
# v4.x   openInEditorVerb=0 handOff=0 pairKind=0 editorRail=0
# v3.x   openInEditorVerb=0 handOff=0 pairKind=0 editorRail=0
# v2.x   openInEditorVerb=0 handOff=0 pairKind=0 editorRail=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **The reorder** — `SharedFileMenuItems.openInEditor` moves to the head of `FileContextMenu`'s single-file branch, above Get Info and Reveal in Finder | Nothing to pick: the branch on that line has no editor item, and the two it would move above are already first | Same | RECORDED — not owed |
| **`EditableText.isText(path:)`**, the one public way out of the package to the gate `PairContentKind.textExtensions` holds | Not owed on its own. It exists for TE29/TE30, which are `main`-only for the same reason | Same | RECORDED — not owed |


---

## An Edit button in the preview column (TE28)

`main` only, **not owed**, and the measurement is the one recorded for TE27 directly above — the
editor, its hand-off and `PairContentKind` are absent from all three maintenance lines, so a button
that hands a file to Edit has nothing to hand it to. The preview column itself exists on **all four**
lines, which is exactly why this row spells out that the missing half is the destination, not the
surface — the file this change edits is present everywhere and still has nothing to hand a file to:

```sh
# the surface exists off main; the thing it would open does not.
for l in main v4.x v3.x v2.x; do
  printf '%-6s previewColumn=%s editorHandOff=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/ColumnPreviewColumn.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/ContentView+Editor.swift | wc -l | tr -d ' ')"
done
# measured 2026-09-16, before this landed:
# main   previewColumn=1 editorHandOff=1
# v4.x   previewColumn=1 editorHandOff=0
# v3.x   previewColumn=1 editorHandOff=0
# v2.x   previewColumn=1 editorHandOff=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`ColumnPreviewColumn.onOpenInEditor`** (required, no default), forwarded through `PanePreviewSidebar` and wired at both mount sites | Not owed: nothing to hand a file to. Were it ever wanted, the column there carries the same no-default rule and the same six construction sites would need updating | Same — the column is present, the editor is not | RECORDED — not owed |
| **`offersEditor(source:path:)`** and the button on the identity block's name line | Not owed. It depends on `EditableText`, which depends on `PairContentKind` — and that enum is on no maintenance line at all, so the predicate cannot even compile there | Same | RECORDED — not owed |

**Checked and not owed, the other direction.** The `.cloudOnly` refusal is the half worth naming: a
maintenance line that somehow gained this button without it would ask the provider to download a
whole file to open it in an editor that is not there. Nothing is stored, and the preview column's
own download path is untouched — same notification, same pane token, same channel.

---

## Open in Edit in the Info inspector, and its action row stops squeezing (TE29)

**Two halves with different answers, which is why this row is careful.** The editor door is
`main`-only for the reason TE27/TE28 record. **The wrapping fix is not** — the squeezing row is on
every line and reads the same way there.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s detailsSidebar=%s actionRow=%s flowLayout=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Dashboard/Sources/Dashboard/DetailsSidebar.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/DetailsSidebar.swift 2>/dev/null | grep -c 'func metadataActions')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/AutomationsLens.swift 2>/dev/null | grep -c 'public struct FlowLayout')"
done
# measured 2026-09-16, before this landed:
# main   detailsSidebar=1 actionRow=1 flowLayout=1
# v4.x   detailsSidebar=1 actionRow=1 flowLayout=1
# v3.x   detailsSidebar=1 actionRow=1 flowLayout=0
# v2.x   detailsSidebar=1 actionRow=1 flowLayout=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`EditorHandOff`** (a per-path `isOffered` beside `open`), the parameter on both `DetailsSidebar` inits, `offersEditor(handOff:data:)`, the button, and the wiring in `ContentView.infoInspector` | Not owed — no editor to hand a file to, and `EditableText` is not there to answer `isOffered` | Same | RECORDED — not owed |
| **The action row wraps (`FlowLayout`) instead of squeezing** — a defect fix, not part of the feature | **APPLIES, and is a real defect there too.** At the inspector's default 270pt the three shipped buttons already render "Reve… / Cop… / Quic…" on every line. `FlowLayout` is public in FileExplorer on `v4.x`, so the pick is a two-line change (the layout swap plus the `import FileExplorer`) | **Applies, but costs more**: `FlowLayout` is not public there — `v3.x`/`v2.x` would need it exported, or a local copy, which is how this repo came to have three copies of it in the first place | RECORDED — **applies, NOT picked** (standing direction: `main` only) |

**Checked and not owed, the other direction.** The wrap changes no behaviour, only layout: same four
verbs, same actions, same `isStale` guard withholding the whole row while the card is a beat behind
the selection — which the new button inherits for free, since every button in the row names
`data.path` and for one turn that is still the previous file. Nothing stored, no defaults key.

**The one thing a future audit should not re-derive:** the squeeze was found by RENDERING the row at
270pt, not by reading it. The numbers are in the commit body and in
`DetailsEditorDoorTests.theRowWrapsRatherThanSqueezingAtTheInspectorsWidth`, which fails if the row
ever goes back to an `HStack`.

---

## File ▸ Open in Edit on ⌘O, the ⌘/ row, Help, and a Quick Look scan that stopped reading a window (TE30)

`main` only, **not owed** — the fourth door onto a hand-off that exists nowhere else. One half of
this batch is worth separating out, the way TE29's row did: **the `QuickLookOriginTests` slice fix
is test-only and applies wherever that scan exists**, but it only fails when something pushes the
resolver past 2,000 characters, which nothing off `main` does.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s rowVerbCommands=%s appChord=%s cmdO=%s editorHandOff=%s\n' "$l" \
    "$(git show origin/$l:MacApp/ShortcutCommands.swift 2>/dev/null | grep -c 'struct PaneRowVerbCommands')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Design/Sources/Design/AppChord.swift | wc -l | tr -d ' ')" \
    "$(git grep -c 'AppChord("o", .command)' origin/$l -- Modules MacApp 2>/dev/null | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/ContentView+Editor.swift | wc -l | tr -d ' ')"
done
# measured 2026-09-16, before this landed:
# main   rowVerbCommands=1 appChord=1 cmdO=0 editorHandOff=1
# v4.x   rowVerbCommands=1 appChord=1 cmdO=0 editorHandOff=0
# v3.x   rowVerbCommands=0 appChord=0 cmdO=0 editorHandOff=0
# v2.x   rowVerbCommands=0 appChord=0 cmdO=0 editorHandOff=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`AppChord.openInEditor` (⌘O)**, `PaneRowVerbAvailability`'s `isText` term, `PaneRowVerbs.openInEditor`, and the menu item leading `PaneRowVerbCommands` | Not owed. The File menu's row-verb group and `AppChord` are both there, and ⌘O is free there too — but the item would hand a file to an editor that line does not have | Neither the row-verb group nor `AppChord` exists | RECORDED — not owed |
| **The ⌘/ row** — ⌘O sharing ⌘N's, worded to fit one line | Not owed: no ⌘N row to share (no editor) | Same | RECORDED — not owed |
| **`QuickLookOriginTests` slices `shortcutPaneRowVerbs` to its closing brace** instead of a 2,000-character window | Applies if the scan is there, and is harmless to pick; nothing on that line pushes the resolver past the window, so it is not failing | Not checked — `PaneRowVerbCommands` is absent, so neither is the resolver the scan reads | RECORDED — not owed (no failure to fix) |

**Checked and not owed, the other direction.** Nothing stored. No defaults key. The menu item's
suspension is inherited from the whole `PaneRowVerbs` value (`effectivePaneRowVerbs` nils it all),
which is why no per-field suspension test was added: a nil `openInEditor` in the fixture survives
every test, correctly, because nothing reads the field while suspended.



**Checked and not owed, the other direction.** Nothing here is stored or observable outside the
window: no defaults key, no file format, no change to what the verb DOES when chosen — only where it
sits in a menu and who may ask its question. A `main` build and a maintenance-line build still share
one defaults domain. The three later doors this unblocks (preview column, Info inspector, File ▸
Open in Edit) will each be `main`-only on this same reasoning; the audit does not need a new
measurement for them, only this one.

## 2026-09-16 — two tests that pinned macOS 26's conventions, and the mechanism behind them

Test-only on `main`, and **one half genuinely applies to all three maintenance lines** — which is
the unusual part of this row, because nothing about the product changed. The machine moved to
**macOS 27.0 (26A428)** on 2026-09-15 and two framework conventions moved with it; the assertions
that had pinned them now fail on code that is behaving correctly.

The two halves have different answers, so measure them separately:

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s paneColumnsScroll=%s clipAssertion=%s pdfMounted=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Tests/FileExplorer/PaneColumnsScrollTests.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Tests/FileExplorer/PaneColumnsScrollTests.swift 2>/dev/null | grep -c '#expect(type(of: stack.contentView) == NSClipView.self')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Tests/FileExplorer/PDFPreviewMountedTests.swift | wc -l | tr -d ' ')"
done
# measured 2026-09-16, against origin, before this landed:
# main   paneColumnsScroll=1 clipAssertion=1 pdfMounted=1
# v4.x   paneColumnsScroll=1 clipAssertion=1 pdfMounted=0
# v3.x   paneColumnsScroll=1 clipAssertion=1 pdfMounted=0
# v2.x   paneColumnsScroll=1 clipAssertion=1 pdfMounted=0
```

| What landed on `main` | `v4.x` | `v3.x` | `v2.x` | Status |
|---|---|---|---|---|
| **The clip-view assertion**, `type(of: stack.contentView) == NSClipView.self` → provenance (`Bundle(for:)` against a class this module defines) plus a `constrainBoundsRect` over-travel probe | **Applies.** Line 164 of that file, identical text. Anyone running this suite on macOS 27 gets the same red, on a stack with nothing wrong with it | Applies, identical | Applies, identical | RECORDED — not owed |
| **The PDF scroll assertion**, which assumed PDFKit's unflipped bottom-up layout → far end measured off the laid-out views, asserted as "the last page is under the viewport" | Not owed: `PDFPreviewMountedTests.swift` does not exist on this line (the mounted PDF preview is `main`-only, landed 2026-09-09) | Same | Same | CLOSED — does not apply |
| **`docs/flaky-tests.md` mechanisms 21 and 22**, and their two `docs/flaky-triage.md` rows | Carried on all four lines, so the numbering is per-line and will differ. **Cite by title, never by number** | Same | Same | RECORDED — not owed |

**Checked and not owed, the other direction — and this is the row's real content.** No product file
changed: `git diff origin/main -- Modules/*/Sources MacApp` is empty for this work. The app's
behaviour was verified intact on macOS 27 before either test was touched, so there is no defect on
any line to send:

- The stack still scrolls natively — SwiftUI's own configuration (horizontal `.allowed`, vertical
  `.none`) is unchanged, and no product file in any of the seven packages defines an `NSClipView`
  subclass. The `BoundedElasticClipView` machinery the assertion guards against is still gone.
- The PDF preview still reaches the whole document. Measured on the mounted view: content 4008pt
  against a 792pt viewport, `goToLastPage` lands at originY **3211.03 of a 3216pt legal band** with
  page 5 under the viewport. Only the coordinate convention flipped.

So what a maintenance line is missing is **a test that can tell the truth on macOS 27**, not a fix.
If one of those lines is ever built or CI'd on 27, that red is this row, and the pick is the
provenance assertion — which is the expensive half to reconstruct, because the naive repair
(widening to accept `HostingClipView`) silently stops detecting the swap the test exists for.

## Snapshot compare aborts on macOS 27, and four EmptyState references move with the OS

Two changes, both **test-only**: `installPerceptualCompareShim()` in all four copies of
`SnapshotRendering.swift` (plus `SnapshotPerceptualCompareTests` in Design), so a snapshot that is
not byte-identical fails or passes as a test instead of killing the package with signal 6; and the
eight `DesignSnapshotTests` EmptyState references re-recorded on macOS 27, where the SF Symbol above
them reserves up to 1pt more room. See "A snapshot mismatch that aborts the process instead of
failing" in `docs/flaky-tests.md`.

```sh
# stage 1 — the helper and its pin. stage 2 — the SHAPE: does the helper install the shim, and are
# the EmptyState references the pre-27 set? main is the positive control (before this landed).
for l in main v4.x v3.x v2.x; do
  r=origin/$l
  printf '%-6s helpers=%s pin=%s shim=%s emptyStateRefs=%s\n' "$l" \
    "$(git ls-tree -r --name-only $r -- Modules | grep -c 'SnapshotRendering.swift')" \
    "$(git show $r:Modules/Design/Package.swift | sed -n 's/.*swift-snapshot-testing", exact: "\([0-9.]*\)".*/\1/p')" \
    "$(git show $r:Modules/Design/Tests/DesignTests/SnapshotRendering.swift | grep -c installPerceptualCompareShim)" \
    "$(git ls-tree -r $r -- Modules/Design/Tests/DesignTests/__Snapshots__/DesignSnapshotTests/ | grep emptyState | awk '{print $3}' | git hash-object --stdin | cut -c1-8)"
done
# measured 2026-09-16, before this landed:
# main   helpers=4 pin=1.19.4 shim=0 emptyStateRefs=d671f149
# v4.x   helpers=4 pin=1.19.4 shim=0 emptyStateRefs=d671f149
# v3.x   helpers=4 pin=1.19.4 shim=0 emptyStateRefs=d671f149
# v2.x   helpers=4 pin=1.19.4 shim=0 emptyStateRefs=d671f149
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **The shim**, in all four helpers | Applies: same four helpers, same 1.19.4 pin, no shim — so on macOS 27 any snapshot suite with a non-byte-identical image aborts its package. **Inferred from the files, not run** | Same | RECORDED — not owed (test-only; CI skips these suites on every line) |
| **`SnapshotPerceptualCompareTests`** | Would apply with the shim, and only with it: without, it aborts the package it is added to | Same | RECORDED — not owed |
| **The eight EmptyState references** | Same pre-27 blobs as `main` had, and `EmptyStateView.swift` is the same blob as `main`'s, so they are stale on 27 in the same way. **Inferred, not run** | Same references; `EmptyStateView.swift` differs from `main`'s, so a pick would need re-recording on that line, not copying `main`'s PNGs | RECORDED — not owed |

**Checked and not owed, the other direction.** Nothing in the app changes: every file touched is
under `Tests/` or `docs/`. No defaults key, no stored format, no product code path.

---

## Review of TE27–TE30: the preview name, two unpinned wirings, overclaiming copy, two silent exits

`main` only, **not owed** — every change edits a surface that exists only with the editor (the
preview's Edit button, the inspector's and File menu's hand-off wiring, `handOffToEditor`'s log
lines, and the copy describing all four). No maintenance-line measurement beyond TE27's is needed:
`MacApp/ContentView+Editor.swift` is absent from `v4.x`, `v3.x` and `v2.x`.

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **The preview's Edit button stacks under a long name** (`ViewThatFits`) instead of taking its line, and carries the accessibility label "Open in Edit" | Not owed: the button is TE28's and main-only | Same | RECORDED — not owed |
| **`OpenInEditorMenuTests.theInspectorAndTheFileMenuAreWiredToTheRealHandOff`** | Not owed: neither wiring exists there | Same | RECORDED — not owed |
| **`handOffToEditor` logs its two exits that wrote nothing** (already open; settle cancelled) | Not owed: no hand-off | Same | RECORDED — not owed |
| **Notes, Help and README copy** no longer claim a door "anywhere" / "wherever you are looking", nor "whatever the focused pane has selected" | Not owed | Same | RECORDED — not owed |

---

## A click in a file pane hands that list the keyboard (⇧↑ / ⇧↓ extend the selection)

**A platform change, so every line has the defect — and every line can take the fix.** On macOS 27 a
click on a SwiftUI `List` row selects it and leaves the window as first responder; every key after
it is delivered to the window and dropped. Measured 2026-09-16 in the app (`[fr] 300ms after a row
click: the WINDOW itself`) and in a bare four-list app with nothing of SyncCloud's in it, where all
four lists behaved the same. Nothing about that is line-specific, and the fix hangs on
`PaneBackgroundDeselect`'s recognizer install, which all four lines carry:

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s deselectCatcher=%s probe=%s paneListDeleteCmd=%s\n' "$l" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PaneBackgroundDeselect.swift 2>/dev/null | grep -c 'table.addGestureRecognizer(click)')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/MouseDownProbe.swift | wc -l | tr -d ' ')" \
    "$(git grep -c 'onDeleteCommand' origin/$l -- Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift Modules/FileExplorer/Sources/FileExplorer/PaneColumnsView.swift 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"
done
# measured 2026-09-16, before this landed:
# main   deselectCatcher=1 probe=1 paneListDeleteCmd=4
# v4.x   deselectCatcher=1 probe=0 paneListDeleteCmd=4
# v3.x   deselectCatcher=1 probe=0 paneListDeleteCmd=4
# v2.x   deselectCatcher=1 probe=0 paneListDeleteCmd=4
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| `PaneListKeyFocus` — the monitor, the registry, the claim | owed | owed | **gap**: new file, no dependencies beyond AppKit; picks clean |
| `PaneListKeyFocus.register(table)` in `PaneBackgroundDeselect.CatcherView.resolvePass` | owed | owed | **gap**: the install block it sits in is byte-identical on all four lines |
| `PaneListKeyFocusTests` | owed | owed | **gap**: uses `PaneSearchTreeRevealTests`' fixture — check it exists on the line before picking |
| `MouseDownProbe` `[key]` and `[fr]` lines | not owed | not owed | the probe itself is `main`-only; diagnostic, no user-facing behaviour |

**Waking `.onDeleteCommand` on those lines is the part to think about, not the pick.** Both pane lists
carry it on every line, and on macOS 27 it had become unreachable because nothing ever focused the
list. With focus, a bare ⌫ on a selection reaches `handleDelete`, which confirms unless
`confirmBeforeDelete` is off and moves to the Trash. Measured 2026-09-23 in the app: `keyCode 51`
logged with the pane's table as first responder, the confirmation shown, cancelled, nothing deleted. That is the pane's written intent, not new
behaviour — but on `v3.x`, which has none of the `DeleteOutcome` family, it is a keystroke that can
reach a removal the line cannot tell apart from a permanent one.

---

## Edit with fewer columns: the rail yields to the pane, "Just the text", and one click opens (TE36 + TE40 + TE41)

**Everything here hangs off the Editor workspace, and no maintenance line has one.** `Workspace.editor`
is absent on `v4.x` (and so on the older two), so the rail there is nothing to withhold, the pane has
no editor to dim rows for, and a spine rung that says "Show the text files" has no text files to
show. One check answers for the whole batch:

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s editorWorkspace=%s workspaceEditor=%s paneSearchDim=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorWorkspaceView.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/Workspace.swift 2>/dev/null | grep -c 'case editor')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PaneSearchRow.swift | wc -l | tr -d ' ')"
done
# measured 2026-09-16, before this landed:
# main   editorWorkspace=1 workspaceEditor=1 paneSearchDim=1
# v4.x   editorWorkspace=0 workspaceEditor=0 paneSearchDim=1
# v3.x   editorWorkspace=0 workspaceEditor=0 paneSearchDim=1
# v2.x   editorWorkspace=0 workspaceEditor=0 paneSearchDim=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **The shim**, in all four helpers | Applies: same four helpers, same 1.19.4 pin, no shim — so on macOS 27 any snapshot suite with a non-byte-identical image aborts its package. **Inferred from the files, not run** | Same | RECORDED — not owed (test-only; CI skips these suites on every line) |
| **`SnapshotPerceptualCompareTests`** | Would apply with the shim, and only with it: without, it aborts the package it is added to | Same | RECORDED — not owed |
| **The eight EmptyState references** | Same pre-27 blobs as `main` had, and `EmptyStateView.swift` is the same blob as `main`'s, so they are stale on 27 in the same way. **Inferred, not run** | Same references; `EmptyStateView.swift` differs from `main`'s, so a pick would need re-recording on that line, not copying `main`'s PNGs | RECORDED — not owed |

**Checked and not owed, the other direction.** Nothing in the app changes: every file touched is
under `Tests/` or `docs/`. No defaults key, no stored format, no product code path.
| **`TopPaneVisibility.editorRailIsDrawn(paneHidden:railHidden:)`** and the `editorRailHidden` defaults key; `EditorWorkspaceView.showsRail` / `railIsHidden` / `onToggleJustTheText` (all required, no defaults); `EditorLayoutMetrics.minDocumentOnlyWidth` for the expanded arm's clamp; the naming row extracted to `EditorNamingRow` with a second home atop the document column | Not owed — no editor workspace, no rail, no naming row | Same | RECORDED — not owed |
| **The header's "Just the text" glyph** and the spine's second rung (`ContentView.spineRungs`, gated on `.editor` AND the bit) | Not owed. The spine (`railSpine`) IS on `v4.x`, but the rung is gated on a workspace that line does not have, so the pick would be dead code | Same | RECORDED — not owed |
| **`FileActionDelegate.editorRefusal(forPath:isDirectory:size:)`** (protocol body, default `nil`), `PaneActionDelegate.servesEditor` joining `isEquivalent`, `FileRowView.editorRefusal` dimming at `PaneSearchDim.opacity` with the reason as tooltip, in both row presentations | Not owed. `riskyNameReason`'s pattern is there to ride, and `PaneSearchDim` is there, but every answer would be `nil`: `servesEditor` can never be true on a line with no `.editor` | Same; `v2.x` has no `PaneSearchDim` either | RECORDED — not owed |
| **One click opens** — `.onChange(of: syncManager.selectedLeftPaths)` → `openSelectedPaneFileInEditor` → `paneSelectionOpens` (pure rule) → `openInEditor` | Not owed — nothing to open into | Same | RECORDED — not owed |

**Checked and not owed, the other direction.** No defect fix rides along. The one change touching a
shared surface is `railSpine` growing a conditional second rung, and its container keeps the 34pt
strip and the one card, so the spine the other workspaces draw is unchanged — and on a line without
`.editor` the condition is unreachable.

**Boundaries a future audit should not re-derive:** cloud-only rows are deliberately NOT dimmed by
the delegate (the row's own lazy `lstat` knows; a click is refused by the editor with the same
"Not downloaded" caption one step later). Decision I (the bit persists, `@AppStorage`) and J (arrow
keys open, since they move the same selection) were taken as the plan's defaults. The one-click
suite, the spine suite and the refusal-delegate suite are app-target and run locally only.

---

## The differences list takes the keyboard too, and two ways hit-testing misleads

**A follow-on to `50136fe0`, and half of it is a defect that commit introduced.** With the panes able
to take focus and this table unable to, a click on a difference left first responder on the pane
clicked before it: measured 2026-09-25 in the app, ⇧↓ in the differences list wrote 2, 3, 4 then 5
items into the LEFT PANE's selection, against a table the click had never touched. Keys acting on the
surface the user is not looking at is worse than the keys doing nothing, which is what they did
before either surface could take focus.

**Three measurements, each of which killed an attempted fix, in the order they were made:**

1. **That table's clicks never reach a local `NSEvent` monitor** — no down, no up — so `noteMouseUp`
   never ran for them. Attaching a gesture recognizer to it changes that, measured by adding,
   removing and re-adding it with the same build failing and working in step. `ClickNormalizer` is
   that recognizer and does nothing else; it never recognizes.
2. **Its own coordinate space does not describe where it is drawn.** One click was simultaneously
   "a pane row twelve rows down" to hit-testing and "my row 0, 15pt from the top" to the table,
   whose `visibleRect` had a negative origin. Every fix built on those coordinates failed, one of
   them by claiming this table for clicks belonging to a pane.
3. **A PANE's table answers hit-tests for points outside its own viewport**, reaching over the
   differences list below it. This is what made the failure positional — the differences list's top
   rows resolved to pane rows and focused the pane, lower rows fell through and worked. The fix is
   `visibleRect(of:)`: a hit-test answer is believed only where the click is inside that list's
   viewport, and otherwise falls through to `target(covering:in:)`.

**`selectionDidChangeNotification` never fires for that table either** (measured), so the wash
repaints ride on other signals and no selection-based route is available.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s differencesStyler=%s tableIsCurrent=%s reviewNudge=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/DifferencesTableSelectionStyler.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DifferencesTableSelectionStyler.swift 2>/dev/null | grep -c 'override func tableIsCurrent')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DifferencesView.swift 2>/dev/null | grep -c 'reviewFocusNudge')"
done
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| `visibleRect(of:)` validation + `target(covering:in:)` in `PaneListKeyFocus` | owed | owed | **gap**, and inseparable from the row above it: a line taking the pane fix without this ships the wrong-surface defect |
| `ClickNormalizer`, installed from `DifferencesTableSelectionStyler.tableIsCurrent` | owed | owed | **gap**; check `tableIsCurrent` exists on the line first — it is the shared-resolver hook |
| `DifferencesKeyFocusTests` | owed | owed | **gap**; mounts the real `DifferencesView` via `ScratchDefaults` + `.oneMountedDifferencesTable` |
| The corrected `.onKeyPress(.space)` premise comment | not owed | not owed | it describes `PaneListKeyFocus`, which those lines do not have |

**What the harness cannot show, and why that is stated rather than hidden.** In a test window these
clicks reach the event stream and hit-testing behaves, so no test can prove the recognizer is
necessary; that rests on the app measurement above. The viewport rule IS pinned, by a test that
stages a lying hit-test — its first version passed with the rule deleted.

---

## Hardening the two key-focus commits (review of `50136fe0` and `3f6bccc7`)

**An adversarial re-read of both, 2026-09-25.** Six findings, all on `main` only — the feature itself
is `main` only, so a line that never takes the rows above has nothing to take here either.

| What the review changed | Why it was wrong |
|---|---|
| `ClickNormalizer`'s recognizer now RETAINS its delegate (associated object) | `delegate` is weak and `target` unowned, so the normalizer's only owner was the styler holding it. A released normalizer leaves a recognizer nothing refuses — free to recognize clicks and to send its action to freed memory, the hazard `PaneBackgroundDeselect` documents for its own |
| `install(on:)` is idempotent | SwiftUI rebuilds the styler; one install per instance stacked a recognizer per rebuild on one table |
| **Two ownership attempts are recorded as rejected** | Holding it in the styler stacked recognizers; making install idempotent AND uninstalling on window exit let two stylers share one normalizer, so the first to leave took the recognizer the other still needed — measured as a mounted list carrying none |
| `visibleRect(of:)` falls back to the table's own frame | It answered `.zero` for a table with no scroll view, and both routes test containment against it — such a list could never be claimed |
| The caret rule lives in ONE place | `target(forHit:)` repeated it; two copies of one rule are two places to keep in step |
| Right-clicks claim too (`watchedEvents` = left up + right down) | Every other Mac list leaves the keys on the row it opened a menu over. Not available for the differences list: its normalizer watches the primary button only |
| `MouseDownProbe`'s `[key]` line names navigation keys only | It printed the raw key code of EVERY keystroke, and the trace is armed by a `defaults write` a user may leave on through ordinary typing — `~/sync-cloud.log` would hold a record of what was typed |
| `[focus]` logs a claim that moves focus | The only other record was the probe's `[fr]` line, which needs the scroll trace armed — and the reports this code exists for arrive with it off |

**Known and deliberately not changed: nothing on screen says which list owns the keyboard.** The
panes wear an active/inactive wash driven by the app's own focused-pane state, not by first
responder, so the differences list can hold the keys while a pane still reads as active. Before these
commits no list held the keys at all, so the question did not arise; it is a design decision rather
than a defect, and it is the one thing a reader of this row should weigh next.

---

## The ⌘/ reference stops offering ⌘-double-click (TE35) — **checked, not owed anywhere**

The Tabs group's "⌘-double-click a folder — Open it in a new tab, in Columns" row came in with
`668ccaa2` (first shipped in v4.1) and outlived its gesture: `2e26a50f` took the column row's
`TapGesture`s off for v5.3, the count-2 ⌘-double-click among them (§18 above), and v5.3 shipped the
row anyway. `main` drops the row and adds `testNoRowAdvertisesACommandDoubleClick`, which is scoped to
⌘ so a row for the tab strip's plain double-click would still be allowed. Three doc comments that
still listed ⌘-double-click as a new-tab entry point were corrected with it.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s row=%s gesture=%s\n' "$l" \
    "$(git show origin/$l:MacApp/ShortcutsReference.swift | grep -c '⌘-double-click a folder')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PaneColumnsView.swift | grep -c 'TapGesture(count: 2)')"
done
# before this change: main row=1 gesture=0 · v4.x row=1 gesture=1 · v3.x row=0 gesture=0 · v2.x row=0 gesture=0
```

| Line | Row | Gesture | Status |
|---|---|---|---|
| `v4.x` | yes | **yes**, count-2 `simultaneousGesture` on the column row | **not owed**: the row is TRUE there. It becomes owed only if §18's gesture removal is ever picked to `v4.x`, and must travel in the same pick |
| `v3.x` | no | no | **not owed**: no Tabs group, no tabs, cut before `668ccaa2` |
| `v2.x` | no | no | **not owed**: same as `v3.x` |

The guard test is not owed on its own either: on `v4.x` it would fail against a row that is correct
there.

---

## ⌘N's new file shows in the pane, selected, and Export as PDF re-reads it too (TE44)

**The defect.** Since TE36 the open source pane is Edit's file list and the rail beside it is
withheld. ⌘N (`createTextFile`) and File ▸ Export as PDF refreshed only the rail, so with the pane
open the file was on disk — and for ⌘N, open — while the column it landed in went on listing the
folder as it was. Reported 2026-09-25 in the app: iCloud › Documents › Finance, ⌘N "Test", the log
said `Editor created …/Finance/Test.md`, the column still listed `IN` and `US`. The rail-only refresh
itself predates TE36 (v5.3's `createTextFile` is the same), but there the rail was drawn beside the
pane and listed the file.

**The fix.** Both writes now take the re-read every queued file operation gets —
`prepareForcedRescan()` then `refreshSubject.send(.both)` (`rereadPanesAfterEditorWrite`) — and ⌘N
owes the pane a selection of the new file, paid on the left-tree publish that lists it
(`settleOwedPaneSelection`, rule `owedPaneSelection`), through the pane's own selection setter. The
selection lands on the open document, so TE41's one-click open finds it already open: one
`Editor opened` line per create. (Both the whole-cache `.both` re-read and the write through the
pane's setter are superseded by the review of TE47, at the end of this file.)

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s createTextFile=%s workspaceEditor=%s paneSelectionOpens=%s prepareForcedRescan=%s\n' "$l" \
    "$(git show origin/$l:MacApp/ContentView+Editor.swift 2>/dev/null | grep -c 'func createTextFile')" \
    "$(git show origin/$l:MacApp/Workspace.swift 2>/dev/null | grep -c 'case editor')" \
    "$(git show origin/$l:MacApp/ContentView+Editor.swift 2>/dev/null | grep -c 'static func paneSelectionOpens')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift 2>/dev/null | grep -c 'public func prepareForcedRescan')"
done
# measured 2026-09-25, before this landed:
# main   createTextFile=1 workspaceEditor=1 paneSelectionOpens=1 prepareForcedRescan=1
# v4.x   createTextFile=0 workspaceEditor=0 paneSelectionOpens=0 prepareForcedRescan=1
# v3.x   createTextFile=0 workspaceEditor=0 paneSelectionOpens=0 prepareForcedRescan=1
# v2.x   createTextFile=0 workspaceEditor=0 paneSelectionOpens=0 prepareForcedRescan=1
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| `rereadPanesAfterEditorWrite` from `createTextFile` and `exportEditorDocumentAsPDF` | Not owed — no Edit workspace, no ⌘N file, no export from it | Same | CHECKED — not owed |
| The owed pane selection (`editorPaneSelectionOwed`, `owedPaneSelection`, `settleOwedPaneSelection`, the `leftPaneTree` observer); `paneSelectionBinding` no longer `private` | Not owed — its only writer is ⌘N in Edit | Same | CHECKED — not owed |
| `OutOfQueueWriteRereadTests` (Sync) | Would compile: `prepareForcedRescan` and `refreshTreesAndScan` are there. Not owed — it pins why an out-of-queue writer needs the preparation, and those lines have no such writer in Edit. Whether any other out-of-queue writer exists there was not checked | Same | RECORDED — not owed |

**Boundaries a future audit should not re-derive** (the last two superseded by TE47, below — the
pane now scrolls a selected document into view, and every open selects it): autosave and ⌘S deliberately do NOT re-read the
pane — they rewrite a file it already lists, and a two-pane walk per autosave is the cost the rail's
own changed-only guard exists to avoid. The pane does not scroll a new file into view: a folder long
enough to put it off-screen shows it selected but not visible (no scroll-to-selection exists outside
search reveals). The rail click and the hand-off do not write the pane's selection either — a
different cause (no selection write at all, no missing re-read), left alone.

---

## Edit's header says where the file lives, and is a card of its own (TE43)

**Everything here is on the Editor workspace's header, and no maintenance line has one.** Checked
2026-09-25 against `origin` before landing:

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s editorWorkspace=%s workspaceEditor=%s paneHeaderPinned=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorWorkspaceView.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/Workspace.swift 2>/dev/null | grep -c 'case editor')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/DashboardViews.swift 2>/dev/null | grep -c 'frame(height: LiquidGlass.headerHeight)')"
done
# main   editorWorkspace=1 workspaceEditor=1 paneHeaderPinned=1
# v4.x   editorWorkspace=0 workspaceEditor=0 paneHeaderPinned=1
# v3.x   editorWorkspace=0 workspaceEditor=0 paneHeaderPinned=1
# v2.x   editorWorkspace=0 workspaceEditor=0 paneHeaderPinned=1
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`EditorDocumentLocation`** + `EditorLocationLabel` (the value, its two readings, the fold-the-middle rungs, the doors as data); `EditorWorkspaceView.location` / `onLocationDoor` (required, no defaults) on the meta row after the autosave switch, at `layoutPriority(-1)` | Not owed — no editor workspace, no header to put it on | Same | RECORDED — not owed |
| **The header as its own card** (`headerCard`, pinned to `LiquidGlass.headerHeight`), the text in a second card in `.cards` and flush under a hairline in `.unified`; ⌘N's row moved into the text card | Not owed. The pin it shares (`PaneHeader` at `headerHeight`) IS on every line, but there is no document column beside it | Same | RECORDED — not owed |
| **`EditorHeaderLocation.location`** (built from `BreadcrumbTrail`), **`EditorLocationDoors`** (crumb → `navigatePane`, folder → `navigatePane` + the pane's own selection binding); `paneSelectionBinding` private → internal (**superseded** — see "The pane's selection follows the open document, and scrolls it into view (TE47)" and "Integrating the three review fixes": the folder door now OWES the selection (`selectInPane` → `owePaneSelection`, paid by `PaneLogic.payOwedSelection` as the app's own write, not through the binding), and `paneSelectionBinding` is `private` again) | Not owed — nothing calls them without the header | Same | RECORDED — not owed |
| Dashboard test target gains a `FileExplorer` dependency for `EditHeaderMatchesPaneHeaderTests` | Not owed — the test has no subject there | Same | RECORDED — not owed |

**Checked and not owed, the other direction.** No defect fix rides along: `navigatePane`,
`BreadcrumbTrail` and `PaneLogic.relativePath` are reused unchanged, and the one visibility change
(`paneSelectionBinding`) alters no behaviour. No defaults key, no stored format.

---

## New and Close in Edit's header (TE45 + TE46)

**Both hang off Edit's document header, and no maintenance line has an Editor workspace.** Checked
2026-09-25, before this landed:

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s editorWorkspace=%s workspaceEditor=%s newTextFileCmd=%s saveItemGroup=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorWorkspaceView.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/Workspace.swift 2>/dev/null | grep -c 'case editor')" \
    "$(git show origin/$l:MacApp/ShortcutCommands.swift 2>/dev/null | grep -c 'struct NewTextFileCommand')" \
    "$(git show origin/$l:MacApp/SyncCloudApp.swift 2>/dev/null | grep -c 'replacing: .saveItem')"
done
# main   editorWorkspace=1 workspaceEditor=1 newTextFileCmd=1 saveItemGroup=1
# v4.x   editorWorkspace=0 workspaceEditor=0 newTextFileCmd=0 saveItemGroup=1
# v3.x   editorWorkspace=0 workspaceEditor=0 newTextFileCmd=0 saveItemGroup=0
# v2.x   editorWorkspace=0 workspaceEditor=0 newTextFileCmd=0 saveItemGroup=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **TE45 — the header's ＋**: `EditorWorkspaceView.onNewTextFile` (required, no default), handed `shortcutNewTextFile` itself by `editorWorkspace(showsRail:)`; `newTextFileTitle(folderName:)` for its tooltip | Not owed — no editor, no header, no ⌘N | Same | RECORDED — not owed |
| **TE46 — the header's ×** (`EditorWorkspaceView.onCloseDocument`, required; `closeTitle(name:)`) **and File ▸ Close Document** (`CloseDocumentCommand` in the `.saveItem` group above Save, no key; `FocusedValues.closeDocument`; `ShortcutValuePublisher.closeDocument`, suspended with the rest) | Not owed. `v4.x` HAS the `.saveItem` group — emptied, `CommandGroup(replacing: .saveItem) { }` — but no Save in it and no editor document to close | Same; `v3.x`/`v2.x` do not replace the group at all | RECORDED — not owed |
| **`EditorDocumentClose`** — `isOffered` (Edit + a document, refused ones included), `paneSelection(afterClosing:selection:)` (clears a left-pane selection of exactly the closed file, so TE41's on-change open fires on the next click), `run` (settle → undo stack put away → `EditorDocument.close()` → selection → one log line) | Not owed — no `EditorDocument`, no TE41 one-click open | Same | RECORDED — not owed |

**Checked and not owed, the other direction.** No defect fix rides along. `EditorDocument.close()`
already existed on `main` with no caller; this is its first. The one shared surface touched is the
File menu's `.saveItem` group, and on `v4.x` that group stays empty — Close Tab keeps ⌘W on every
line.

**Measured, and left for a decision rather than fixed here:** the two glyphs cost the file name 48pt.
At the narrowest document column (260pt) a 55-character `.md` name went from 44–69pt of ink to
10–12pt (an ellipsis) across the four text sizes; at the 760pt window floor's column (~391pt) it keeps
134–153pt. Pinned in `EditorHeaderDoorsTests.theNameRowFitsWithALongNameAtEveryTextSize`.

---

## A context menu on the Edit rail's rows: Reveal in Browse, Get Info, Reveal in Finder, Quick Look (TE33)

**`main` gained a right-click menu on every row of Edit's Text Files rail**, in the order Reveal in
Browse · Get Info · Reveal in Finder · Quick Look, each acting on the ROW's path rather than the open
document's. Dim rows (too large, cloud-only) keep the whole menu. The header filename's one-item
Reveal in Browse is unchanged; the rail's item reaches the same host closure
(`onRevealInBrowse` → `revealInBrowse`), which moves the pane and the workspace and never the
document. Get Info goes to `showInfo(for:)` (the Info inspector, which sits beside every layout
arm including Edit's); Quick Look goes to the window's one panel through
`toggleQuickLook(_:followsPane: false)` — a rail row is not the pane's selection, so a pane click
must not retarget it. With the source pane open the rail is not drawn and the pane's own row menu
applies; decision E kept Reveal in Browse off that menu.

**Checked 2026-09-25, and not owed on any maintenance line** — the surface does not exist there:

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s railView=%s workspace=%s revealInBrowse=%s showInfo=%s toggleQuickLook=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorFileRailView.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorWorkspaceView.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/ContentView+Editor.swift 2>/dev/null | grep -c 'func revealInBrowse')" \
    "$(git show origin/$l:MacApp/ContentView.swift 2>/dev/null | grep -c 'func showInfo(for path: String)')" \
    "$(git show origin/$l:MacApp/ContentView.swift 2>/dev/null | grep -c 'func toggleQuickLook')"
done
# main   railView=1 workspace=1 revealInBrowse=1 showInfo=1 toggleQuickLook=1
# v4.x   railView=0 workspace=0 revealInBrowse=0 showInfo=1 toggleQuickLook=1   (same for v3.x, v2.x)
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| `EditorRailRowMenu` + `EditorRailRowActions`, attached in `EditorFileRailView.row(_:)` | no rail — no Edit workspace | same | CHECKED — not owed |
| `EditorWorkspaceView.onGetInfo` / `onQuickLook` (no defaults) and `railRowActions` (**superseded** — see "Edit's test fixtures shared, and the rail's acts passed whole": the host now builds `EditorRailRowActions` and hands it to the workspace as one argument with no default) | no `EditorWorkspaceView` | same | CHECKED — not owed |
| App wiring in `ContentView+Editor.swift` (`showInfo`, `toggleQuickLook`) | the two targets exist there, the construction site does not | same | CHECKED — not owed |
| `EditorRailRowMenuTests` (FileExplorer), `EditorRailRowMenuWiringTests` (app target) | nothing to test | same | CHECKED — not owed |

**Boundary a future audit should not re-derive:** Reveal in Browse lands on the row's FOLDER, not a
selected file — the header's verb has always done the same (`focusPaneOnFolder`), and TE33 reuses
that verb rather than growing a second one. A SwiftUI `.contextMenu` inside an `NSHostingView` exposes no
`NSMenu` to a test (measured: neither the host nor a subview carries one, and `menu(for:)` on a
synthesised right-click answers empty), which is why the row's attachment is pinned by a source
scan and the menu's order by hosting the menu body alone and reading its focus rings.
(**Superseded** — see "Review fixes to the Edit doors (hand-off, Reveal in Browse, differences rows)
— main only" and "Integrating the three review fixes": Reveal in Browse now takes the pane
breadcrumb's route for Browse's mode (`EditorRevealInBrowse.movePane`; `focusPaneOnFolder` is gone)
and lands with the row's FILE selected (`EditorRevealInBrowse.reveal`, TE47's owed selection); and
the menu IS readable — `NSHostingView.menu(for:)` answers it once the host is in a window, which is
how `EditorRailRowMenuTests` now reads it, so the source scan is gone.)

---

## Open in Edit on a differences row, once per side (TE31)

`main` only, **not owed** — the fifth door onto a hand-off that exists on no maintenance line. The
same split TE28 records: **the surface is on all four lines, the destination is on one.** Every line
has `DifferencesView`, the shared `inspectionMenuItems` builder and `DifferenceRowMenu.existingSides`
that the new item would join; none off `main` has the Edit workspace to hand a file to, nor
`EditableText` to ask whether a side is text:

```sh
# the surface exists off main; the thing it would open does not.
for l in main v4.x v3.x v2.x; do
  printf '%-6s differencesView=%s inspectionItems=%s perSideRowMenu=%s editorHandOff=%s editableText=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/DifferencesView.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DifferencesView.swift 2>/dev/null | grep -c 'func inspectionMenuItems')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DifferenceRowMenu.swift 2>/dev/null | grep -c 'func existingSides')" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/ContentView+Editor.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PairContentKind.swift 2>/dev/null | grep -c 'enum EditableText')"
done
# measured 2026-09-25, before this landed:
# main   differencesView=1 inspectionItems=1 perSideRowMenu=1 editorHandOff=1 editableText=1
# v4.x   differencesView=1 inspectionItems=1 perSideRowMenu=1 editorHandOff=0 editableText=0
# v3.x   differencesView=1 inspectionItems=1 perSideRowMenu=1 editorHandOff=0 editableText=0
# v2.x   differencesView=1 inspectionItems=1 perSideRowMenu=1 editorHandOff=0 editableText=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`DifferenceRowMenu.editableSides`** — `existingSides` narrowed by `EditableText.isText`, and emptied for a folder row on `enclosedItemCount` | Not owed: `EditableText` is absent, so it cannot compile there | Same | RECORDED — not owed |
| **`DifferencesView.onOpenInEditor`** (optional, `nil` hides the items, as `onQuickLook` does) and its wiring to `handOffToEditor($0, pane: .staysPut)` in `ContentView` | Not owed — no hand-off to wire it to | Same | RECORDED — not owed |
| **The hand-off that leaves the left pane where it is** — `EditorHandOffRun` (the hand-off moved out of `ContentView` into an act a test can run, `Pane.followsTheFile` / `.staysPut`), `.staysPut` for the differences list alone, and its log line `opened without moving the left pane`. Measured on `main` with a real `FileSyncManager` (`EditorHandOffRunTests`): the ordinary hand-off from Compare re-scopes the comparison, clears the session's Ignore in Comparison entries and sends a `.leftOnly` refresh; `.staysPut` does none of the three | Not owed — no hand-off at all | Same | RECORDED — not owed |
| **The menu items moved into `DifferenceInspectionMenu`**, a `View` of their own, so a test can host them and read the drawn order | Not owed. A restructure that exists to carry the new group; the items it moved draw identically (Get Info / Reveal / Quick Look / Copy Path, same labels, same order) | Same | RECORDED — not owed |

**Checked and not owed, the other direction.** Nothing stored, no defaults key, no change to what the
existing items do. Those lines also lack **Compare…** at the head of this menu (0 on all three for
`Label("Compare…"`), so "directly under Compare…" has no anchor there anyway — on those lines the
group would lead the menu, which is what a one-sided row does on `main`.

---

## Open in Edit on a duplicate copy's row menu (TE32)

`main` only, and **not owed anywhere** — the surface and the verb are both missing off `main`, in
different amounts per line. `v4.x` has `DuplicateGroupCard` but no row context menu on it (no
"Compare with keeper", no `isRowPickable` whole-row picker) and none of the editor: no
`handOffToEditor`, no `EditableText`. `v3.x` and `v2.x` have no `DuplicateGroupCard.swift` at all.

```sh
# main is the positive control; every other count is 0 except v4.x's card file.
F=Modules/FileExplorer/Sources/FileExplorer/DuplicateGroupCard.swift
for l in main v4.x v3.x v2.x; do
  printf '%-6s card=%s compareWithKeeper=%s rowPickable=%s contextMenu=%s handOff=%s editableText=%s\n' $l \
    "$(git ls-tree -r --name-only origin/$l -- $F | wc -l | tr -d ' ')" \
    "$(git show origin/$l:$F 2>/dev/null | grep -c 'Compare with keeper')" \
    "$(git show origin/$l:$F 2>/dev/null | grep -c 'func isRowPickable')" \
    "$(git show origin/$l:$F 2>/dev/null | grep -c '\.contextMenu')" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/ContentView+Editor.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PairContentKind.swift 2>/dev/null | grep -c 'enum EditableText')"
done
# measured 2026-09-25, before this landed:
# main   card=1 compareWithKeeper=1 rowPickable=1 contextMenu=2 handOff=1 editableText=1
# v4.x   card=1 compareWithKeeper=0 rowPickable=0 contextMenu=0 handOff=0 editableText=0
# v3.x   card=0 compareWithKeeper=0 rowPickable=0 contextMenu=0 handOff=0 editableText=0
# v2.x   card=0 compareWithKeeper=0 rowPickable=0 contextMenu=0 handOff=0 editableText=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **"Open in Edit" in the copy row's menu**, above "Compare with keeper", on every text row including the keeper's; `DuplicateGroupCard.onOpenInEditor` (no default) ← `LensWorkspaceView.onOpenInEditor` ← `handOffToEditor` | No row menu and no editor to hand to | No card | RECORDED — not owed |
| **The row menu is attached only when it has an item** (`RowMenu`, gated on `hasRowMenu`) — replaces a `.contextMenu` whose builder was empty on the keeper's row | No row menu to gate | No card | RECORDED — not owed |
| **The non-pickable row's hit shape is the whole row** (`.contentShape(Rectangle())`), so its menu answers a right-click anywhere along it. Measured: without it the keeper's menu answered only over its ink, and a sweep down the row's middle found nothing. On `main` before this, the only rows it touched with an item were the non-keeper rows of a group that allows no keeper choice | No row menu, so no right-click to miss | No card | RECORDED — not owed |

**Checked and not owed, the other direction.** Nothing here is stored or observable outside the
window — no defaults key, no file format, no change to what `handOffToEditor` does. The measurement
that makes the drawn test possible is worth keeping for the next audit: `NSHostingView.menu(for:)`
with a synthesized right-click answers the real `NSMenu` SwiftUI builds for the point, by item
title, and answers nil for a `.contextMenu` whose builder is empty (macOS 27).

---

## Edit's empty page keeps its header; the capsule sheds its words for the name; six doors in Help (TE34, and round-2 amendments to TE43 / TE45 / TE46)

`main` only, and **not owed anywhere** — Edit is `main`-only. No maintenance line has the workspace
view, the Edit Help topic or the ⌘O chord these describe, so there is nothing on them to amend.

```sh
# main is the positive control.
for l in main v4.x v3.x v2.x; do
  printf '%-6s workspace=%s help-editor=%s openInEditor=%s\n' $l \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorWorkspaceView.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/HelpBook.swift 2>/dev/null | grep -c 'editor-workspace')" \
    "$(git show origin/$l:Modules/Design/Sources/Design/AppChord.swift 2>/dev/null | grep -c 'static let openInEditor')"
done
# measured 2026-09-25, before this landed:
# main   workspace=1 help-editor=2 openInEditor=1
# v4.x   workspace=0 help-editor=0 openInEditor=0
# v3.x   workspace=0 help-editor=0 openInEditor=0
# v2.x   workspace=0 help-editor=0 openInEditor=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **The empty page keeps the header card** at `LiquidGlass.headerHeight`: "No document open", the ＋, "Just the text" while lit, and the pane's folder (`editorFolder`) as the location with its own level as words, not a door | No Edit workspace | No Edit workspace | RECORDED — not owed |
| **The ＋ looks greyed with no folder** (tertiary glyph) — `.disabled` alone drew it pixel-identical to a live one | No Edit workspace | No Edit workspace | RECORDED — not owed |
| **The mode capsule shows its words only when the whole file name fits beside them** (`nameRow`, `ViewThatFits` over two rows) | No Edit workspace | No Edit workspace | RECORDED — not owed |
| **The empty caption offers ⌘O and no longer ⌘N**; **Help counts six doors** and names the ways back (rail row menu, location, ＋, ×, Close Document); README names the two new ones | No Edit workspace or topic | Same | RECORDED — not owed |
| **The ⌘/ reference's height comments corrected** to the measured 734pt (6pt headroom) — comments only | `v4.x`'s reference is its own and was not re-measured here | Same | RECORDED — not owed |

**Checked and not owed, the other direction.** Nothing here is stored: no defaults key, no file
format. The location builder's new `paneFolder:` input reads `editorFolder`, which already existed.

---

## The pane's selection follows the open document, and scrolls it into view (TE47)

`main` only, **not owed** — the rule generalises TE44's owed selection, which exists only on `main`,
and every entry point it serves is an Edit door. **The two halves it is built from are older than
Edit, though, and that is the part worth recording:** the row scroll (`PaneColumnsView.revealRow`)
and the search reveal's trigger (`FileTreeView.searchRevealNonce`) are on `v4.x` and `v3.x` too,
the deepest-column reveal on every line, and the folder a pane's walk was read at
(`lastLoadedLeftFocusPath`, now readable as `paneTreeFolder(isLeft:)`) on every line. A maintenance
line would have the scroll to reuse and nothing to drive it with.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s editor=%s owedSel=%s searchRevealNonce=%s revealRow=%s revealDeepest=%s lastLoadedFocus=%s handOff=%s\n' $l \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/ContentView+Editor.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/ContentView+Editor.swift 2>/dev/null | grep -c 'static func owedPaneSelection')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift 2>/dev/null | grep -c 'public let searchRevealNonce')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PaneColumnsView.swift 2>/dev/null | grep -c 'private func revealRow')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PaneColumnsView.swift 2>/dev/null | grep -c 'private func revealDeepestColumn')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift 2>/dev/null | grep -c 'var lastLoadedLeftFocusPath')" \
    "$(git show origin/$l:MacApp/ContentView+Editor.swift 2>/dev/null | grep -c 'func handOffToEditor')"
done
# measured 2026-09-25 (origin/main 2b171445, TE44 not yet landed there — hence owedSel=0):
# main   editor=1 owedSel=0 searchRevealNonce=1 revealRow=1 revealDeepest=1 lastLoadedFocus=1 handOff=1
# v4.x   editor=0 owedSel=0 searchRevealNonce=1 revealRow=1 revealDeepest=1 lastLoadedFocus=1 handOff=0
# v3.x   editor=0 owedSel=0 searchRevealNonce=1 revealRow=1 revealDeepest=1 lastLoadedFocus=1 handOff=0
# v2.x   editor=0 owedSel=0 searchRevealNonce=0 revealRow=0 revealDeepest=1 lastLoadedFocus=1 handOff=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **One owed-selection rule** (`owedPaneSelection`, a `PaneSelectionDebt` carrying the document it was owed against; `owePaneSelection` its one door) and its callers: the rail's click (`openInEditor(path:selectsInPane: true)`), every hand-off, ⌘N, Reveal in Browse (header and rail menu), the header's "in <folder>" | Not owed — every caller is an Edit door | Same | CHECKED — not owed |
| **Never fighting the user** — a debt dropped when another document opens, the pane shows another folder, the pane holds a multi-selection, or selecting would open a file that is not the document; retired when the user selects anything else (`debtSurvives`); the reveal retired off its row (`revealSurvives`) | Not owed — no debt to guard | Same | CHECKED — not owed |
| **The one-click open ignores the app's own write** (`paneSelectionOpens(…paidSelection:)`, `editorPaneSelectionPaid`) — without it a programmatic select of a REFUSED document reloaded it and logged a second refusal, since a refusal is let through the already-open guard on purpose | Not owed — no one-click open (TE41) | Same | CHECKED — not owed |
| **`PaneRowReveal` and `FileTreeView.rowReveal`** — the Tree scrolls the row to centre (`scrollTreeRow`, shared with the search reveal), Columns scrolls the row's column (`revealRow`) and brings the deepest column into view (`revealDeepestColumn`), on the request and on the pane appearing, only while the row is the whole selection (`revealsRow`) | Would compile on `v4.x`/`v3.x` (the scrolls exist). Not owed — nothing there selects a row on the user's behalf outside search, which has its own reveal | `v2.x` lacks `revealRow` | RECORDED — not owed |
| **`FileSyncManager.paneTreeFolder(isLeft:)`** — public read of `lastLoadedFocusPath`, so a caller can tell a tree of the folder the pane just LEFT from the pane's own | Would compile on every line. Not owed — its only caller is the owed selection | Same | RECORDED — not owed |

**Checked and not owed, the other direction.** Nothing stored: no defaults key, no file format. The
pane's selection itself is unchanged in kind — written through `paneSelectionBinding`, the setter a
click uses (**superseded by the review below**: the app's write is `PaneLogic.payOwedSelection` now,
because that setter is a click's). Boundaries a future audit should not re-derive: the rule applies at the MOMENT of an
open, create, reveal or location click, never continuously, so returning to Browse with a document
open selects nothing; the pane's own click owes nothing (its row is already under the pointer, and a
reveal would scroll it to the middle); and from Compare's differences list the pane is not moved,
so the file is selected only if the pane already shows its folder. What the header's "in <folder>"
does to a comparison after such an open is measured in `EditorHandOffRunTests`: in Columns a browse
move inside the scope (no re-scope, ignores kept, no refresh); in Tree a re-root (re-scoped, session
ignores cleared, a `.leftOnly` refresh), because that is the pane breadcrumb's own route there.

## Review fixes to the Edit doors (hand-off, Reveal in Browse, differences rows) — main only

A review round on the TE31–TE47 batch. Every fix is to code that exists only on `main`; the one
piece that touches a type every line carries (`FileDifference`) adds two stored facts that nothing
off `main` would read.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s pairCompare=%s editableSides=%s handOffRun=%s revealInBrowse=%s paidMarker=%s leftInfoClear=%s\n' $l \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/DifferencesPairCompare.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DifferenceRowMenu.swift 2>/dev/null | grep -c 'static func editableSides')" \
    "$(git ls-tree -r --name-only origin/$l -- MacApp/EditorHandOffRun.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/ContentView+Editor.swift 2>/dev/null | grep -c 'func revealInBrowse')" \
    "$(git show origin/$l:MacApp/ContentView.swift 2>/dev/null | grep -c 'editorPaneSelectionPaid')" \
    "$(git show origin/$l:MacApp/ContentView.swift 2>/dev/null | grep -c 'onChange(of: syncManager.selectedLeftPaths) { _, _ in infoPath = nil }')"
done
# measured 2026-09-25 (origin/main dd1b24aa, before this change):
# main   pairCompare=1 editableSides=1 handOffRun=1 revealInBrowse=1 paidMarker=1 leftInfoClear=1
# v4.x   pairCompare=0 editableSides=0 handOffRun=0 revealInBrowse=0 paidMarker=0 leftInfoClear=1
# v3.x   pairCompare=0 editableSides=0 handOffRun=0 revealInBrowse=0 paidMarker=0 leftInfoClear=1
# v2.x   pairCompare=0 editableSides=0 handOffRun=0 revealInBrowse=0 paidMarker=0 leftInfoClear=1
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **`FileDifference.leftIsDirectory` / `rightIsDirectory`**, recorded by `FileDiffEngine` per side and swapped by `mirrored()`; "Open in Edit" (`DifferenceRowMenu.editableSides`) and Compare… (`DifferencesPairCompare.pair`) gate on them instead of `enclosedItemCount`, which is `nil` for an empty folder, a name-conflicted folder pair and a folder-vs-file row with an empty folder | Would compile. Not owed — neither reader exists there (no differences-row editor item, no pair viewer) | Same | RECORDED — not owed |
| **The hand-off asks the folder EDIT will show** (`leftPaneFolder(in: .editor)`, over a new `viewMode(in:isLeft:)` that `resolvedViewMode` now delegates to) | Not owed — no hand-off | Same | CHECKED — not owed |
| **Reveal in Browse takes the breadcrumb's route for Browse's mode** (`EditorRevealInBrowse.movePane` → `navigatePane`), nothing when Browse already shows the folder, one `.info` line naming the door (header / rail row); `focusPaneOnFolder` removed | Not owed — no Edit workspace | Same | CHECKED — not owed |
| **A hand-off puts ⌘N's naming row away** (`endNaming`), and `.staysPut` logs its decision rather than a premature "opened" | Not owed — no hand-off | Same | CHECKED — not owed |
| **Compare rescans after the editor wrote under it** (recorded, settled on arriving in Compare or at once while it is on screen — since the integration below, through `OwedComparison`) | Not owed — no editor writes files there | Same | CHECKED — not owed |
| **The app's paid selection keeps a Get Info target** (`leftSelectionClearsInfoTarget`; the left pane's clear moved into the selection handler, before the marker is consumed) | The unconditional clear is there, but nothing writes the left selection on the user's behalf after a delay — not owed | Same | CHECKED — not owed |

**Checked and not owed, the other direction.** Nothing stored: `FileDifference` is not persisted
(no `Codable`), so the two new fields change no format. The rail row menu's attachment test is now a
drawn read (`NSHostingView.menu(for:)` in a window) rather than a source scan — tests only.

---

## Review of TE47: the app's own write, a workspace-bound debt, a targeted re-read, a reveal answered once

`main` only, **not owed** — every change here is to TE44/TE47 machinery that exists only on `main`
(the table below says which pieces would compile elsewhere). Five review findings, each confirmed
before it was fixed:

1. **The payment went through the click's setter.** `settleOwedPaneSelection` wrote
   `paneSelectionBinding(isLeft: true)`, whose setter resolves a standing Compare-with pick on any
   single-path write (the pick survives a workspace switch), claims `lastSelectionSurface` for the
   panes, moves the keyboard's focus to the left pane, logs `[click]` and "a row was picked in the
   left pane", and clears the right pane's selection whatever it held. Arm "Compare with…" in Browse,
   open a document in Edit, and the pair overlay opened on it; select five files in Compare's right
   pane, open from Edit's rail, and they were gone. Now `PaneLogic.payOwedSelection`: the left
   selection (marked first, as before), and the right pane cleared only of a SINGLE selection (the
   one-pane invariant) — a set there drops the debt (`otherSelection` in the rule). **Superseded
   2026-09-26 by his decision** (integration section below): the right pane is cleared whatever it
   holds, and `otherSelection` is gone from the rule.
2. **A debt never expired.** ⌘N's debt waits for the re-read; switch workspace before it publishes
   and it paid in Compare or Browse later. `PaneSelectionDebt` carries the workspace it was owed in
   (read after the door's own switch — Reveal in Browse switches, then owes), a mismatch drops it,
   and a workspace switch settles at once so the drop is logged when it happens.
3. **The re-read after ⌘N / Export as PDF was a file operation's.** `prepareForcedRescan()` emptied
   the whole prefetch cache and `.both` down `refreshSubject` ran a full comparison scan — restarting
   one in flight — in any workspace, and an export saved outside both sources re-read both. Now
   `prepareReread(afterWritingAt:)` drops only the walks that list the folder
   (`dropPrefetchedTrees(holding:links:)`, links included, so the iCloud container's walk goes for a
   file in `~/Documents`), `ContentView.panesHolding` reloads only the pane(s) whose folder holds the
   file (none for neither), and `refreshAction(…comparing: selectedWorkspace == .compare)` owes the
   comparison outside Compare (then `comparisonAwaitsRescan`, as a lens entry does; since the
   integration below, `OwedComparison.skipped`). `refreshAction` is
   no longer `private` for this caller.
4. **The reveal re-scrolled on every appearance** while its row stayed selected. The pane now
   reports an answer (`FileTreeView.onRowRevealed`, passed through to `PaneColumnsView`) and the host
   retires it on the next turn (`retireAnsweredRowReveal`, rule `revealAfterAnswer`); a reveal
   issued while the pane is not on screen still waits for it to appear.
5. **Logging**: one `.info` `[pane-follow]` line per selection and per drop, with its reason
   (`DropReason`); the owed selection no longer reads as a click.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s dropAll=%s dropHolding=%s prepareReread=%s payOwed=%s bindingPick=%s onRowRevealed=%s\n' $l \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift 2>/dev/null | grep -c 'public func dropPrefetchedTrees()')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift 2>/dev/null | grep -c 'func dropPrefetchedTrees(holding')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift 2>/dev/null | grep -c 'func prepareReread(afterWritingAt')" \
    "$(git show origin/$l:MacApp/PaneLogic.swift 2>/dev/null | grep -c 'static func payOwedSelection')" \
    "$(git show origin/$l:MacApp/ContentView.swift 2>/dev/null | grep -c 'if let pick = comparePick, newSelection.count == 1')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift 2>/dev/null | grep -c 'onRowRevealed')"
done
# measured 2026-09-25, origin/main dd1b24aa, before this landed:
# main   dropAll=1 dropHolding=0 prepareReread=0 payOwed=0 bindingPick=1 onRowRevealed=0
# v4.x   dropAll=1 dropHolding=0 prepareReread=0 payOwed=0 bindingPick=0 onRowRevealed=0
# v3.x   dropAll=0 dropHolding=0 prepareReread=0 payOwed=0 bindingPick=0 onRowRevealed=0
# v2.x   dropAll=0 dropHolding=0 prepareReread=0 payOwed=0 bindingPick=0 onRowRevealed=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| `PaneLogic.payOwedSelection`; the rule's `workspace` guard (and an `otherSelection` guard, removed again 2026-09-26); `DropReason`; the settle on a workspace switch | Not owed — no owed selection (TE44/TE47 are `main`-only) | Same | CHECKED — not owed |
| `dropPrefetchedTrees(holding:links:)`, `FileSyncManager.folder(_:holds:links:)`, `prepareReread(afterWritingAt:)` (Sync) | Would compile on `v4.x` (`dropPrefetchedTrees()` and `PathBoundary.contains` are there). Not owed — its only caller is Edit's re-read; `v4.x`'s file operations keep the whole-cache drop, which is right for them | `v3.x`/`v2.x` lack `dropPrefetchedTrees()` itself | RECORDED — not owed |
| `rereadPanesAfterEditorWrite(_:)` targeted (`panesHolding`, comparing only in Compare) | Not owed — no Edit workspace | Same | CHECKED — not owed |
| `FileTreeView.onRowRevealed` / `PaneColumnsView.onRowRevealed`, `retireAnsweredRowReveal` | Not owed — no `PaneRowReveal` there | Same | CHECKED — not owed |
| `PaneRowRevealTests.everHolds` bounded by its marker (asserted) and drained turns, not a 30s pump | Not owed — the suite is TE47's | Same | CHECKED — not owed |

**Boundaries a future audit should not re-derive.** A selection in the right pane IS cleared by a
payment (the one-pane-selected invariant, as a click clears it) — as written here, a single one only;
since 2026-09-26, a set too (integration section below). Only a set in the LEFT pane is protected.
Payment never touches the selection sequencer: a click's deferred cross-pane clear still queued
behind it is newer intent and is left to win. A file saved outside both panes still drops the cached
walks that list its folder — cheap, and a later navigation there would otherwise be served the
pre-write walk — but re-reads neither pane.

---

## Review fixes to Edit's header (TE43 / TE45 / TE46 follow-ups)

`main` only, **not owed** on any line — every change is to Edit's header, its location doors or the
text view Edit mounts, and none of those exists on a maintenance line. Checked 2026-09-25:

```sh
for l in main v4.x v3.x v2.x; do
  echo "$l $(git ls-tree -r --name-only origin/$l -- \
    Modules/FileExplorer/Sources/FileExplorer/PlainTextEditor.swift \
    Modules/FileExplorer/Sources/FileExplorer/EditorWorkspaceView.swift \
    MacApp/EditorLocationDoors.swift | wc -l | tr -d ' ') of 3 files"
done
# main 3 of 3 files · v4.x 0 · v3.x 0 · v2.x 0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **The find bar no longer opens by itself** — `PlainTextEditor.makeCoordinator` seeds `lastFindRequest` from the standing `findRequest`, so a text view built after a Find press (after ×, a refused file, or Preview) does not replay it | Not owed — no editor text view | Same | CHECKED — not owed |
| **`EditorLocationDoors` logs at INFO** through an injected `log` (one line per press: browsed / re-rooted — with the re-scope and cleared ignores said — / already there, and both refusals) | Not owed — no doors | Same | RECORDED — not owed |
| **Under the pane's tab strip the document column leaves the strip's slot empty** (`EditorWorkspaceView.paneShowsTabStrip`, `PaneTabStripLadder.slotHeight(_:)`, host `editorPaneShowsTabStrip`) | Not owed — no document column beside the pane | Same | RECORDED — not owed |
| **The ＋, naming row and rail name the folder as the breadcrumb does** (`folderDisplayName`, `EditorHeaderLocation.folderName`) — "iCloud", not "com~apple~CloudDocs"; **a folder under another enabled source reads from that source's name**, as words (`otherSources`, `EditorDocumentLocation.otherSourceName`) | Not owed — no header | Same | RECORDED — not owed |
| **The crumb's folded "…" is a menu of the levels it hides** (`EditorDocumentLocation.Part.folded`) | Not owed — no header | Same | RECORDED — not owed |

**Checked and not owed, the other direction.** Nothing stored: no defaults key, no format.
`navigatePane`, `focusOn` and `PaneLogic.relativePath` are reused unchanged. One reviewer claim was
measured and **refuted**, recorded so it is not re-derived: a read-only or refused document drops
the autosave switch from the meta row, but the kind word ("Markdown" / "Plain text") keeps the row
at the switch's height — the header rows measured 35 / 38 / 44 / 46pt at the four text sizes for an
ordinary, a read-only and a refused `.md` and `.txt` alike, and the title's first ink row did not
move by a pixel. No reservation was added.

---

## Integrating the three review fixes: one owed comparison, the right pane always cleared — main only

The Edit-doors, pane-follow and header review fixes landed together (2026-09-26), and where they met
three things changed. All three are to machinery that exists only on `main`: **not owed**, measured
per line.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s owedComparison=%s payOwed=%s rightMarker=%s revealAct=%s awaits=%s\n' $l \
    "$(git show origin/$l:MacApp/ContentView.swift 2>/dev/null | grep -c 'struct OwedComparison')" \
    "$(git show origin/$l:MacApp/ContentView.swift 2>/dev/null | grep -c 'func payOwedComparisonIfNeeded')" \
    "$(git show origin/$l:MacApp/PaneLogic.swift 2>/dev/null | grep -c 'markRightCleared')" \
    "$(git show origin/$l:MacApp/EditorHandOffRun.swift 2>/dev/null | grep -c 'static func reveal(')" \
    "$(git show origin/$l:MacApp/ContentView.swift 2>/dev/null | grep -c 'comparisonAwaitsRescan')"
done
# measured 2026-09-26, origin/main dd1b24aa, before this landed:
# main   owedComparison=0 payOwed=0 rightMarker=0 revealAct=0 awaits=6
# v4.x   owedComparison=0 payOwed=0 rightMarker=0 revealAct=0 awaits=0
# v3.x   owedComparison=0 payOwed=0 rightMarker=0 revealAct=0 awaits=0
# v2.x   owedComparison=0 payOwed=0 rightMarker=0 revealAct=0 awaits=0
```

| What landed on `main` | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **One owed comparison** (`ContentView.OwedComparison`, paid only by `payOwedComparisonIfNeeded`, one `.info` line "Compare rescans: <why>"). Replaces the lens entry's `comparisonAwaitsRescan` and the doors review's `editorWritesSinceComparison`. Saves are unread writes (the pane holding them re-read, targeted, then compared — no longer the whole-cache forced rescan); ⌘N / Export as PDF outside Compare owe only the comparison, naming the file; any comparing refresh drops the written folders' cached walks before it settles the record | Not owed — `v4.x` has no lens-entry skip (`awaits=0`) and no editor that writes | Same | CHECKED — not owed |
| **The owed selection clears the right pane whatever it holds** (his decision, 2026-09-26): only a LEFT-pane set drops the debt; `otherSelection` is gone from the rule, and the drop line says "the left pane holds a selection of several items". The clear is marked (`markRightCleared` → `editorPaneRightClearPaid`) so it keeps a Get Info target, as the left write already did | Not owed — no owed selection | Same | CHECKED — not owed |
| **Reveal in Browse's order is one tested act** (`EditorRevealInBrowse.reveal`: move, switch, then owe), measured landing with the file selected in Browse on a real manager over a real folder, Columns and Tree; `paneSelectionBinding` is `private` (one caller) | Not owed — no Edit workspace | Same | CHECKED — not owed |

**Checked and not owed, the other direction.** Nothing persisted changed: the record is view
`@State`, and no log line a reader greps for was removed — "Compare rescans: the editor wrote … since
the last comparison" is kept word for word, and the lens entry's payment, silent before, now writes
"Compare rescans: the pane moved outside Compare without a comparison".

## A write outside both compared folders is not owed to Compare — main only

Follow-up to the integration above (2026-09-26). `OwedComparison.recordWrite` records a file the
editor wrote only when a compared folder holds it (`ContentView.panesHolding`, links included); one
anywhere else cannot change the comparison, and recorded it made the next comparing refresh drop
cached walks that comparison does not show. `noteEditorWrote` drops such a write's cached walks at
the write instead (`prepareReread`), so a pane moved to that folder later still reads it. The record
exists only on `main` (`owedComparison=0` on every maintenance line in the table above): **not
owed**, nothing persisted, no log line changed.

## Edit's test fixtures shared, and the rail's acts passed whole — main only

Test and quality cleanup after the review fixes (2026-09-26). One code change: `EditorWorkspaceView`
takes the rail row menu's acts as one `EditorRailRowActions`, built by the host (now `public`, its
three host acts still without defaults), in place of `onGetInfo`, `onQuickLook` and the optional
`onRevealRowInBrowse` it used to rebuild the struct from — the app passes the same three closures,
so nothing it does changes. The rest is tests: a `FileExplorerTestSupport` library in the
FileExplorer package (never linked by the app) carries one `EditorWorkspaceView.fixture`, the text
files the render suites open (removed when the test process exits), and the focus-ring walk fifteen
test files had copied; the header render helper reads its bitmap's bytes once and closes its window.
`EditorWorkspaceView` exists only on `main` (`workspace=0` on every maintenance line in TE33's
measurement above): **not owed**.

---

## The guided setup sheet (v5.4)

Recorded while the work sat unlanded in a worktree, because a record written now is the only one
that carries the per-file reasoning; reconstructing it from a squashed branch later is the
expensive half. **Not a to-do list** — [`CLAUDE.md`](../CLAUDE.md)'s standing direction is `main`
only.

| What is on `main`'s successor branch | `v4.x` | `v3.x` | `v2.x` | Status |
|---|---|---|---|---|
| **`SetupWalk` + `walkForSetup`, and the split of `deriveFolderProfile` into `writeWalkProfile` + `previewProfile`** — one read of the tree held for the life of the sheet, and a profile built in memory before anything is written | **Applies in substance.** `FolderSurveyBuilder`, `PersonCandidates` and `JurisdictionCandidates` are all there, and `build` is pure on that line too, so the preview has something to build and the split has something to split. What differs is the caller: `v4.x`'s setup form is the five-step one, which walks three times by design | **Does not apply.** No `FolderSurveyBuilder`, no filing profile | **Does not apply**, same reason | RECORDED — not owed (`main` only) |
| **`FolderReading`, `SetupLooseFileRouting`, `JurisdictionCandidates.isConfident`** — words for the profile's roles, name-only routing of the root's loose files, and the measured bar for pre-ticking a country | **Applies in substance for the first two** (`StructureDivergence` and `FilingRouter` are both present); `isConfident` applies as written. All three are new files with no call site on that line, so picking them would add code nothing runs | **Does not apply** | **Does not apply** | RECORDED — not owed |
| **The sheet itself** — `SetupFlow.Screen` recut to ten cases, `SetupModel`, `MacApp/Setup/` (chrome plus ten screens), and the retirement of the five-step form | **Does not apply as written.** It replaces a file `v4.x` carries in a different shape, and every test in `§5` of the plan would have to be settled against that line's own copy. A v4 user's setup is the form that shipped with v4 | **Does not apply.** No setup form at all | **Does not apply**, same reason | RECORDED — not owed |
| **`FilingArtifacts.attach` hands over `filingProfilesDirectory` before it reads a profile** | **Applies cleanly, and is the one thing here worth sending on its own merits if the direction ever changes.** It is a one-line reordering that fixes a real defect that line shares: on a Mac with no profile the directory was never handed over, so the walk that creates the first profile refused with `no profiles directory was configured` before reading a folder. `v4.x` has both `FilingArtifacts.attach` and a setup step that runs that walk, so the defect reproduces there verbatim | **Does not apply.** No `FilingArtifacts` | **Does not apply**, same reason | RECORDED — not owed, but the only defect fix in this batch (`v4.x`) |
| **`DocumentSurveyStrip`** — the reading line on every Organize lens | **Does not apply.** `v4.x` has no document survey to report (see the rows above), so there is no run for a strip to announce | **Does not apply** | **Does not apply** | RECORDED — not owed |
| **`ProviderOptionRows`, `GeneralRows`, `LaunchAtLoginRow`, `NotifyInBackgroundRow`, `OpenAtRefusal`** — Settings rows extracted so setup and Settings are one control | **Applies in substance**, and is behaviour-preserving on its own: it moves code without changing what any control does. Only worth picking as groundwork for the sheet, which is not owed | **Does not apply.** `SettingsView` is a different shape | **Does not apply** | RECORDED — not owed |

**Checked and not owed is the finding here**, not an omission: every row above was read against the
maintenance lines rather than assumed, and the one that would have been worth sending — the
`attach` reordering — is named as such so a future audit does not have to find it again.

## The setup art suite could pass on a blank page — `v4.x` carries the same harness

Test-only (2026-09-26). `SetupArtworkRenderTests` read its pixels from `ImageRenderer.nsImage`, a
buffer the renderer recycles; a page that drew nothing — an empty body, or art whose reveal never ran
— came back holding an earlier page of the same size, so each of the three Browse checks could pass
blank. It now renders into a context of its own, and `testABlankPageReadsAsBlankRightAfterAPaintedOne`
holds that. `docs/flaky-tests.md` gains the mechanism, "An `ImageRenderer` render with nothing to draw
hands back an earlier render's pixels" — cite it by title; the numbering is per-line.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-6s suite=%s ownImage=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- SyncCloudTests/SetupArtworkRenderTests.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:SyncCloudTests/SetupArtworkRenderTests.swift 2>/dev/null | grep -c 'renderer.nsImage')"
done
# measured 2026-09-26, against origin, before this landed:
# main suite=1 ownImage=1 · v4.x suite=1 ownImage=1 · v3.x suite=0 ownImage=0 · v2.x suite=0 ownImage=0
```

**`v4.x`: applies, RECORDED — not owed.** The same harness and the same three Browse checks, over six
pages (no `.edit`), so a v4 page whose art stops drawing can pass there too. No product file changed,
so no line has a defect to send — what `v4.x` lacks is a suite that can tell a blank page from a
painted one. **`v3.x` and `v2.x`: do not apply** — neither has the suite.

**2026-09-27 — the control's reveal gap, same verdict.** `testTheRendererSeesAShippedIllustration`
now also requires `DuplicatesArt`'s check mark, the one part only its `onAppear` reveal draws;
`painted > 500` alone held with every reveal suppressed (8,723 pixels). `v4.x` carries the same
control over the same `DuplicatesArt` gating (`git show origin/v4.x:MacApp/SetupArtwork.swift`), so
it applies there — RECORDED, not owed.

**2026-09-27 — the per-page reveal gap, same verdict.** Every illustration now starts its reveal
through `onReveal`, which a test-only `setupArtReveals` switch can hold back, and
`testEveryTourPageRevealsWhenItAppears` compares each page with its frame before `onAppear`, with
Reduce Motion off and on — the per-page floor caught a reveal that never ran on Welcome and Browse
only. The app's drawing is unchanged: every page renders byte-for-byte as before. `v4.x`'s six pages
reveal the same way (one `onAppear` each, `appeared` gating everywhere but Transfer) under the same
`painted > 300` floor, so the gap applies there — RECORDED, not owed.

## Columns polish: row room, sideways scroll, scroll memory, column widths — main only

Six changes to the Columns presentation (the artifact's CP1–CP8): the `⌂ on this Mac only` row badge
removed with its pipeline, file sizes withheld from Columns rows, names given the row's full width and
cut in the middle, the action bar's row positions read from each column's table, a pane's scroll
offsets kept while a workspace switch rebuilds it, and columns sized one at a time (Settings ▸
Readability ▸ Column widths).

**One of them is a defect fix, and it applies to every line.** A sideways swipe across the columns
re-laid out every visible row on every frame, because each column row reported its position through
a `.global` `GeometryReader` — reading a global frame subscribes the row to the stack's scroll
offset. Sampled during a real swipe on `main`: the main thread 47% busy, 11% after. All three
maintenance lines carry the same per-row reader:

```sh
for l in main v4.x v3.x v2.x; do
  f=Modules/FileExplorer/Sources/FileExplorer/PaneColumnsView.swift
  printf '%-5s file=%s globalRowProbe=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- $f | wc -l | tr -d ' ')" \
    "$(git show origin/$l:$f 2>/dev/null | grep -c 'proxy.frame(in: .global).maxY')"
done
# measured 2026-09-27, against origin, before this landed:
# main file=1 globalRowProbe=1 · v4.x file=1 globalRowProbe=1 · v3.x file=1 globalRowProbe=1 · v2.x file=1 globalRowProbe=1
```

**`v4.x`, `v3.x`, `v2.x`: apply, RECORDED — not owed.** The fix is `ColumnRowBottomsProbe` (since merged into `ColumnListProbe`) plus
`PaneBarPlacement.reresolveMovedEdge()`; it moves the bar's flip 4–6pt earlier (the row's cell, not
its text), which a pick would carry too.

**The rest are design changes, not defects, and are not owed anywhere:** the `⌂` badge (present on
`v4.x` and `v3.x`, absent on `v2.x`), the Columns file size, middle truncation, scroll memory and
per-column widths change what a line does rather than repair what it does wrong.

## Row menus stop walking the tree on every click (CP9) — main only

SwiftUI builds a row's context menu with the row, so every visible row's `FileContextMenu` body
runs on every click — in both panes, since each pane's menus take the other pane's selection too.
Each body walked the pane tree to resolve the selection, and on the two-pane surfaces walked the
other pane's tree again — twice on `main`, once on the maintenance lines, which have no cross-pane
Compare item. Sampled in the app while clicking through Columns: 277 of the
281 samples the menus cost were those walks. Rows outside the selection now answer from the row,
and `PaneSelectionResolver` walks once per selection for the rest. All three maintenance lines
carry both walks:

```sh
for l in main v4.x v3.x v2.x; do
  f=Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift
  printf '%-5s rowWalk=%s otherPaneWalk=%s\n' "$l" \
    "$(git show origin/$l:$f | grep -c 'let selectedNodes = Self.resolvedSelection(node: node, selection')" \
    "$(git show origin/$l:$f | grep -c 'otherTree.selectedNodes(at: otherSelection)')"
done
# measured 2026-09-27, against origin, before this landed: every line rowWalk=1 otherPaneWalk=1
```

**`v4.x`, `v3.x`, `v2.x`: apply, RECORDED — not owed.** A pick is `PaneSelectionResolver` and
`FileContextMenu.menuNodes`, with the "Copy '…' from ⟨pane⟩" item reading the resolver; those lines
have no `PaneComparePairMenu`, so there is no Compare item to route through it. It changes what no
menu offers.

## Refresh what's learned surveys the profile's own folder (P70) — `v4.x` carries it

Organize's *Refresh what's learned* handed `resurveyFilingMemory` the focused pane's landing folder,
and nothing compared it with the folder the profile was built from. The corpus and the memory are
keyed by paths relative to that folder, so a Refresh with any other source in the pane read every
learned document as gone: the merge dropped it, the other source's documents at known paths were
read in its place, and the memory's header recorded the other folder as its root. Measured in a
fixture: four learned documents became one, read from the wrong tree. It now surveys the profile's
recorded root whatever the pane shows, and refuses a profile that records none — a file without
`root` decodes as `~` — or a relative one, and a walk of that root that finds no documents at all
(an emptied `~/Documents`, which is what turning off iCloud's Desktop & Documents leaves behind).

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s resurvey=%s paneRoot=%s recordedRoot=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+FilingSurvey.swift 2>/dev/null | grep -c 'public func resurveyFilingMemory(root: URL')" \
    "$(git show origin/$l:MacApp/ContentView.swift | grep -c 'User requested a folder-memory re-survey of')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FolderProfile.swift 2>/dev/null | grep -c 'recordedRoot')"
done
# measured 2026-10-02, against origin, before this landed:
# main resurvey=1 paneRoot=1 recordedRoot=0 · v4.x resurvey=1 paneRoot=1 recordedRoot=0
# v3.x resurvey=0 paneRoot=0 recordedRoot=0 · v2.x resurvey=0 paneRoot=0 recordedRoot=0
```

**`v4.x`: applies, RECORDED — not owed.** The same `updateFolderMemoryAction` passes
`lensProviderAnchorExpanded`, the same pass merges by relative path and writes the pane's folder as
the memory's root, and `FolderProfile` decodes an absent `root` as `~`. A pick is the guard in
`resurveyFilingMemory` with `FolderProfile.recordedRoot`, and `FilingResurveyTests`' two new cases.
**`v3.x` and `v2.x`: do not apply** — neither has the re-survey.

## Compare through iCloud Drive's linked folders: the scan's path and the warm keying (P14, P15) — main only

Two ways Compare misspelled a folder that iCloud Drive links in from outside its container
(`Desktop`, `Documents`). Both come from the container root (`4150041a`, v5.3) and the pane focus
that resolves the link (`3c06773c`).

- **P14.** With a pane on iCloud Drive → Documents, the scan joined its path lexically
  (`…/com~apple~CloudDocs/Documents`) while the pane walked and cached the real `~/Documents`. The
  scan missed that cache and walked the link, which lists nothing, and `recordUnreadable` forgave the
  root as "a link to a directory" — so the left side read as authoritatively empty and every item on
  the right became "Folder missing on left". The scan's path now comes from the pane's `focusURL`,
  and `getFilesInDirectory` walks a root that is a link where it leads.
- **P15.** At the container itself, a warm scan keyed the linked folder's nodes — which carry real
  paths — by plain prefix, so they came out near-absolute (`Users/…/Documents/x`) against the disk
  walk's `Documents/x`, and the rows offered to copy the folder to `<other side>/Users/…`.
  `filesInfo(fromTree:basePath:links:)` now keys them through the link's name.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s linkTable=%s rootForgiven=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/PathBoundary.swift 2>/dev/null | grep -c 'discoveredLinkedFolders: LinkedFolders')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDiffEngine.swift | grep -c 'A link to a directory is not an unreadable directory')"
done
# measured 2026-10-02, against origin, before this landed:
# main linkTable=1 rootForgiven=1 · v4.x linkTable=0 rootForgiven=0
# v3.x linkTable=0 rootForgiven=0 · v2.x linkTable=0 rootForgiven=0
```

**`v4.x`, `v3.x`, `v2.x`: checked, not owed — neither applies.** No line has the link table, so a
pane and the scan both join lexically and no walk names a linked folder by its real path, which is
what P15 needs. And no line forgives a failed root, so a scan rooted at a link records that root as
unexplored (`""`) — a comparison reported as partial, not one reported as empty.

### P15, above the container: warm keys from the tree's shape — main only

P15's fix keyed the linked folders through the table at the base, which only names them when the
base IS the container. A base above it (`~/Library`) still keyed them near-absolute, and Home keyed
the container's copy onto `~/Documents`' own keys, so it vanished from the warm map while the disk
walk listed it. `filesInfo(fromTree:basePath:)` now builds each key from the names along the tree
path, and takes no table.

That reaches past iCloud. The walk's listing hands back symlink-resolved URLs for a folder reached
through a symlink, so the warm map also keyed everything two levels below an ordinary folder
symlink onto its target's keys, and everything under a pane focused inside a linked folder, or a
root spelled through a symlink (`/var/…`), near-absolute. Those agree with the disk walk now too.
Building keys from names also showed the disk walk stripped its leading `/` by Character, so a
top-level name opening with a combining mark kept the slash; both of its strips now go by scalar.

```sh
for l in main v4.x v3.x v2.x; do
  f=$(git show origin/$l:Modules/Sync/Sources/Sync/FileDiffEngine.swift)
  printf '%-5s linkTable=%s idStrips=%s shapeKeys=%s scalarStrip=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/PathBoundary.swift | grep -c 'discoveredLinkedFolders: LinkedFolders')" \
    "$(printf '%s' "$f" | grep -c 'relativePath.hasPrefix(basePath)')" \
    "$(printf '%s' "$f" | grep -c 'func leaf(of id: String)')" \
    "$(printf '%s' "$f" | grep -c 'unicodeScalars.first == "/"')"
done
# measured 2026-10-02, against origin, before this landed (idStrips counts the warm AND cold strip):
# main linkTable=1 idStrips=2 shapeKeys=0 scalarStrip=0 · v4.x linkTable=0 idStrips=2 shapeKeys=0 scalarStrip=0
# v3.x linkTable=0 idStrips=2 shapeKeys=0 scalarStrip=0 · v2.x linkTable=0 idStrips=2 shapeKeys=0 scalarStrip=0
```

**`v4.x`, `v3.x`, `v2.x`: owed — not picked, per the standing direction.** None has the link table,
but each lists through `contentsOfDirectory(at:)` and strips ids on the warm side, so on each a warm
and a cold Compare disagree two levels below a folder symlink and under any root reached through
one. A pick is `filesInfo(fromTree:basePath:)` with `FilesInfoKeyingTests`' symlink and agreement
cases. The combining-mark strip is **not owed**: each line strips both branches by Character, so
its warm and cold agree on such a name — both keep the slash.

## The install skill quits only the installed app — all three lines carry the old step

On 2026-10-02 a session's run of `.claude/skills/install-sync-cloud/SKILL.md` quit another
session's running worktree build, twice (07:30 and 07:44). Step 3's unanchored
`SyncCloud.app/Contents/MacOS/SyncCloud` matches every build's bundle, and `quit app "SyncCloud"`
went to the instance of the bundle id launched last, in both orders measured. Steps 8 and 9 read the
same pattern through `head -1`, so their pid could be the other build's, and step 7's any-bytes
check passed on another instance's log lines. Now one anchored pattern, a pid-addressed JXA quit,
and step 7 waits for the `launched` line.

```sh
for l in main v4.x v3.x v2.x; do
  s=$(git show origin/$l:.claude/skills/install-sync-cloud/SKILL.md)
  printf '%-5s quitByName=%s unanchored=%s anyBytes=%s\n' "$l" \
    "$(printf '%s\n' "$s" | grep -cF "osascript -e 'quit app \"SyncCloud\"'")" \
    "$(printf '%s\n' "$s" | grep -cF "'SyncCloud.app/Contents/MacOS/SyncCloud'")" \
    "$(printf '%s\n' "$s" | grep -cF '[ "$AFTER" -ne "$BEFORE" ]')"
done
# measured 2026-10-02, against origin, before this landed:
# main, v4.x, v3.x, v2.x — every line: quitByName=1 unanchored=6 anyBytes=2
```

**`v4.x`, `v3.x`, `v2.x`: apply, RECORDED — not owed.** All three carry steps 3, 7, 8 and 9 as
`main` had them. A pick's 3-way merge takes the change on each with no conflict and leaves `main`'s
step-4 signing text behind (`git merge-file`, 2026-10-02); a plain `git apply` refuses, because
the line after step 3's code — step 4's heading — reads differently there. It matters more than a
tooling row usually does: a session loads the skill from its own worktree, so a release cut on a
maintenance line — whose step 6 runs this skill — still quits other sessions' builds. Nothing
user-facing.

## The document survey and Restructure act only on the profile's recorded folder (after P70) — main only

P70 made Refresh survey the profile's recorded folder and refuse a profile that records none. Two
other passes that act under the profile still took their folder from somewhere else:

- **The first document survey** (Organize's card, and setup's "read documents") walked Organize's
  scope, or else the focused pane's current folder, and wrote the corpus and memory keyed by paths
  relative to it under the active profile. A reading started while the pane sat on another source
  spent hours on that tree, and the next Refresh read nearly all of it as gone; one started inside
  a subfolder keyed every document a level off until a Refresh re-keyed what it could match by
  size and date. It now walks the profile's recorded folder whatever it is asked about, the plan
  carries that folder to the run, and setup starts a reading only when the profile it wrote is in
  use.
- **Restructure's landings** (scaffold, apply, "make the survey catch up", ledger undo) asked
  `filingFolderProfile?.root == nil`, which only a missing profile answers, so a hand-built profile
  without `root` acted under `~`, and the re-derive wrote `"~"` into the profile it produced. All
  four now refuse a profile with no absolute recorded root, as Refresh does.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s planSurvey=%s landingGuard=%s setupReads=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+DocumentSurvey.swift 2>/dev/null | grep -c 'public func planDocumentSurvey(root')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Restructure.swift 2>/dev/null | grep -c 'filingFolderProfile?.root == nil')" \
    "$(git show origin/$l:MacApp/Setup/SetupModel.swift 2>/dev/null | grep -c 'if readDocuments { onStartSurvey(walk.root) }')"
done
# measured 2026-10-02, against origin, before this landed:
# main planSurvey=1 landingGuard=1 setupReads=1 · v4.x planSurvey=0 landingGuard=0 setupReads=0
# v3.x planSurvey=0 landingGuard=0 setupReads=0 · v2.x planSurvey=0 landingGuard=0 setupReads=0
```

**`v4.x`, `v3.x`, `v2.x`: checked, not owed — none applies.** No maintenance line has the document
survey, Restructure, or setup's reading. `v4.x` does decode a missing `root` as `~`, but its one
pass that acts under the profile is Refresh, recorded above (P70).

## A write where iCloud Drive's links lead drops the walks above the container too — main only

`prepareReread(afterWritingAt:)` — Edit's ⌘N, Export as PDF, and a save outside both compared
folders — drops the cached walks that list the written folder. "Lists" consulted the link table
only at a walk's own root, but the walk substitutes a link wherever it lists the container, so a
walk of `~/Library/Mobile Documents` — or of `~/Library`, when it gets that far — lists `~/Documents`
too. It survived a write there, and the pane above the container was served the tree from before
the write.
`FileSyncManager.folder(_:holds:links:)` now holds what a link at OR BELOW the folder leads to, which
moves `ContentView.panesHolding` and `OwedComparison.recordWrite` with it: a pane above the container
is re-read, and the write is owed to a Compare there. The drop reads the manager's own table
(`linkedFolders`) instead of the machine's, so a test's injected table reaches it.

Not covered, and documented at `folder(_:holds:links:)`: a folder symlink the table does not name.
A walk of `R` holding `R/link → T`, `T` outside `R`, lists `T`'s contents spelled `T/…` from two
levels below the link, and survives a write spelled that way (measured, a new file and a rewrite).

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s folderHolds=%s dropHolding=%s linkTable=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift | grep -c 'static func folder(_ folder: String, holds path: String')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift | grep -c 'func dropPrefetchedTrees(holding')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/PathBoundary.swift 2>/dev/null | grep -c 'discoveredLinkedFolders: LinkedFolders')"
done
# measured 2026-10-02, against origin, before this landed:
# main folderHolds=1 dropHolding=1 linkTable=1 · v4.x folderHolds=0 dropHolding=0 linkTable=0
# v3.x folderHolds=0 dropHolding=0 linkTable=0 · v2.x folderHolds=0 dropHolding=0 linkTable=0
```

**`v4.x`, `v3.x`, `v2.x`: checked, not owed — none applies.** No maintenance line has the targeted
drop or the link table: their file operations empty the whole cache, and no walk substitutes a link.

## A write where a folder symlink leads drops the walks that followed it — main only

Closes the residual the section above records. `prepareReread(afterWritingAt:)` drops the cached
walks that list the written folder, and an ordinary folder symlink was one way to list a folder
without the walk's key or the link table saying so: a walk of `R` holding `R/link → T`, `T` outside
`R`, lists `T`'s contents spelled `T/…` from two levels below the link, so a pane row, a document
opened from it and a file saved beside it all name `T`. The walk survived a new file and a rewrite
there, the pane was not re-read, and Compare was not owed the write. The walk now records the
resolved targets of the folder links it lists outside its root (`FileSyncManager.FollowedLinks`);
each cache entry keeps them (`prefetchedTreeLinkTargets`) and each pane its own walk's
(`leftTreeLinkTargets`, `rightTreeLinkTargets`), and `folder(_:holds:links:linkTargets:)` reads
them for the drop, `ContentView.panesHolding` and `OwedComparison` alike.

Not covered, and documented at `folder(_:holds:links:linkTargets:)`: a FILE symlink, both ways. A
walk listing `R/f.txt → T/f.txt` survives a rewrite spelled `T/f.txt`, and a walk of `T` survives one
spelled through the link (measured).

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s dropHolding=%s linkTargets=%s perKeyDrop=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift | grep -c 'func dropPrefetchedTrees(holding')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift | grep -c 'prefetchedTreeLinkTargets')" \
    "$(git grep -cE 'prefetchedTrees\[[^]]+\] = nil' origin/$l -- Modules/Sync/Sources | awk -F: '{s+=$NF} END {print s+0}')"
done
# measured 2026-10-02, against origin, before this landed:
# main dropHolding=1 linkTargets=0 perKeyDrop=1 · v4.x dropHolding=0 linkTargets=0 perKeyDrop=0
# v3.x dropHolding=0 linkTargets=0 perKeyDrop=0 · v2.x dropHolding=0 linkTargets=0 perKeyDrop=0
```

**`v4.x`, `v3.x`, `v2.x`: checked, not owed — none applies.** No maintenance line drops a single
cache entry: every invalidation there empties the whole cache, which a folder link cannot defeat.

## Compare only this folder below a folder link, or under a root reached through one — main only

`FileActionHandler.focusFolder` — a row's "Compare only this folder", the rail's Open, and the
comparison toolbar's "Compare this folder" — stripped the source root off the node's id, and three
kinds of id are not spelled under the root: two levels below a folder symlink the walk's listing
answers where the link leads (`R/link → T` lists `R/link/sub`, then `T/sub/deeper`); a root reached
through a link (`/var/…`) lists `/private/var/…` from its first level down; and above iCloud Drive's
container the linked `Documents` is listed as `~/Documents`. Each was refused with "Can't Focus
Folder", and no rescan could change that.
`FileSyncManager.paneRelativePath(of:isLeft:root:)` keeps the id's answer where it is spelled under
the root — the real route, and the only tie-break a node offers for a folder the tree holds twice —
and otherwise takes the names down the pane's raw tree onto the relative path of the folder that
tree was walked at.

Not covered, and measured the same day: Columns, the loadTree cache slice and the column graft
still match composed paths against ids. Columns opens a linked folder and its child, then the third
column reads nothing and the stack prunes back; under a root reached through a link, or in a pane
focused below one, it opens nothing past its first column. Closed by the section below.

```sh
for l in main v4.x v3.x v2.x; do
  f=$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/FileActionHandler.swift)
  printf '%-5s idStrip=%s relativize=%s byNames=%s linkTable=%s\n' "$l" \
    "$(printf '%s' "$f" | grep -cF 'node.id.hasPrefix(expandedRoot + "/")')" \
    "$(printf '%s' "$f" | grep -cF 'PathBoundary.relativize(node.id, under: expandedRoot)')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Navigation.swift | grep -c 'func paneRelativePath(of node')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/PathBoundary.swift 2>/dev/null | grep -c 'discoveredLinkedFolders: LinkedFolders')"
done
# measured 2026-10-02, against origin, before this landed:
# main idStrip=0 relativize=1 byNames=0 linkTable=1 · v4.x idStrip=1 relativize=0 byNames=0 linkTable=0
# v3.x idStrip=1 relativize=0 byNames=0 linkTable=0 · v2.x idStrip=1 relativize=0 byNames=0 linkTable=0
```

**`v4.x`, `v3.x`, `v2.x`: owed — not picked, per the standing direction.** Each strips the root by
prefix and lists through `contentsOfDirectory(at:)`, so on each the focus refuses a folder two levels
below a folder symlink and every folder under a root reached through one (read from the code, not
run there). The iCloud case does not apply: no line has the link table. A pick is
`paneRelativePath(of:isLeft:root:)` and `names(downTo:in:)` (now `TreeShape.names(downTo:in:)`, in
`TreeShape.swift`) with the line's prefix strip as the first branch, the call site, and
`PaneRelativePathTests` without its two iCloud cases, plus the two `FileActionHandlerTests` focus
cases.

## Columns below a folder link, under a root reached through one, and above iCloud Drive's container — main only

A column's directory is composed from the pane's root and the names clicked, and `PaneChildrenIndex`
keyed each directory by its id, which the walk spells where a link leads: two levels below a folder
symlink, from the first level under a root reached through one (`/var/…` lists `/private/var/…`, and a
pane focused below a link), and for iCloud Drive's `Documents` above its container. The third column
below a link read nothing and the stack pruned back; under a `/var` root nothing past the first
column resolved. The index now keys each directory by the path a column composes
(`PaneBrowsePath.step` through each row's name, the id itself where the walk spelled it so), which
also gives a folder the tree holds twice one key per route. The loadTree cache slice and the column
graft find a folder by the names down from the folder the tree was walked at (`TreeShape.position`),
with the id prefix kept as the fallback the outline asks through; the Tree/Columns carry translates
by names; ⌘↓ asks whether the deepest column lists the folder.

Cost, Release, `TreeWalkBenchmark.columnIndexBuild` (run it on system folders — a test helper walking
`~` stalls in a FileProvider listing): the index build is 18 ms against 16 over
`/System/Library/Frameworks` re-spelled so no id parts (55,136 directories), and 24 against 11 as
walked, where 30,803 lie below a link.

Not covered, read from the code and not run: the outline asks for an unread folder by its id, which
two levels below a folder link is neither under the root nor continuous from the top, so expanding
one there still fills nothing; and Edit's owed selection names a new file by the deepest column's
composed path while the pane lists it by the resolved id, so a file made below a link is not
selected.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s indexById=%s sliceByPrefix=%s graftByPrefix=%s carryBack=%s openChord=%s linkTable=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/PaneChildrenIndex.swift 2>/dev/null | grep -c 'map\[row.node.id\] = row.children')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Scanning.swift | grep -c 'static func subtree(atPath path: String, in tree')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/PaneColumnGraft.swift 2>/dev/null | grep -c 'path.hasPrefix(node.id + "/")')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift | grep -c 'static func carryBack(')" \
    "$(git show origin/$l:MacApp/PaneLogic.swift | grep -c 'static func openSelectedFolderStack(')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/PathBoundary.swift 2>/dev/null | grep -c 'discoveredLinkedFolders: LinkedFolders')"
done
# measured 2026-10-02, against origin, before this landed:
# main indexById=1 sliceByPrefix=1 graftByPrefix=2 carryBack=1 openChord=1 linkTable=1
# v4.x indexById=1 sliceByPrefix=1 graftByPrefix=2 carryBack=1 openChord=0 linkTable=0
# v3.x indexById=1 sliceByPrefix=1 graftByPrefix=0 carryBack=1 openChord=0 linkTable=0
# v2.x indexById=1 sliceByPrefix=1 graftByPrefix=0 carryBack=1 openChord=0 linkTable=0
```

**`v4.x`, `v3.x`, `v2.x`: RECORDED — not owed.** Each keys its Columns index by id and lists through
`contentsOfDirectory(at:)`, so each carries the defect below a folder link and under a root reached
through one (read from the code, not run there). With no link table on those lines, iCloud Drive's
`Documents` is an ordinary folder link, so a pane on the container breaks the same way two levels
into it. `v4.x` also grafts by id prefix; `v3.x` and `v2.x` have no graft, and no line has ⌘↓. A pick
is `TreeShape.swift`, the index's keying with `step`'s table argument dropped on a line without the
table, `subtree(atPath:under:in:)`, the two carry statics, and `ColumnsBelowALinkTests` without its
iCloud cases.

## Rows that escaped a folder's collapse, and paths split by Character — main only

Compare folds everything inside a folder missing on one side, or a folder that meets a file, into
that folder's row. Two ways a row stayed out, both older than the `v2.x` split:

- **A `/` found by Character.** A name that opens with a combining mark, or ends with a Prepend
  character (U+0600…), joins the `/` beside it into one Character. `topMostAncestor` searched for the
  Character `/`, so `F/◌́x` stood as its own row beside the missing `F`, and a child of an unreadable
  folder was reported missing. Five other places took a path apart the same way: the folded half of
  that suppression, the case-variant and near-name leaf comparisons, `nearNameKey`, and
  `remappedPath` — which also dropped the folder's Character count off the front, so after a Prepend
  character the `/` went too and a one-sided child was aimed beside its folder (`X؀ f.txt`). All six
  now go by scalar (`FoldersAbove`, `TreeShape.leaf`).
- **A near-name pair below a folder that pairs with nothing.** A near-name is claimed per whole
  path. Left `A` and `A ` against right `A`: `A ` pairs with nothing and is reported missing, but
  `A /f.txt` met `A/f.txt` on its own near-name — a both-sides row inside the missing folder, so
  syncing both handled `f.txt` twice, and the left `A` lacking `f.txt` was never reported. A
  near-name match now needs every folder above it to pair with the folder above the candidate
  (`foldersPair`). The same check stops a file pairing across two folder pairs that each matched
  exactly, which offered to copy one folder's `b` over the other's.

Differential, old engine against new over 16,000 generated map pairs: identical for plain names,
case variants and unreadable folders (4,000) and for near-names with no ambiguous folder (4,050);
every difference among ambiguous near-names (1,685 of 3,950) disappears with `foldersPair`
removed. Collapse broken in 5,598 of the old outputs, none of the new. Release, no case slower.

```sh
for l in main v4.x v3.x v2.x; do
  f=$(git show origin/$l:Modules/Sync/Sources/Sync/FileDiffEngine.swift)
  printf '%-5s charAncestor=%s remapDrop=%s foldedSplit=%s leafSplit=%s nearKeySplit=%s foldersPair=%s\n' "$l" \
    "$(printf '%s\n' "$f" | grep -c 'path\[index...\].firstIndex(of: "/")')" \
    "$(printf '%s\n' "$f" | grep -c 'path.dropFirst(best.prefix.count)')" \
    "$(printf '%s\n' "$f" | grep -c 'relativePath.split(separator: "/").dropLast()')" \
    "$(printf '%s\n' "$f" | grep -c 'split(separator: "/").last')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/ProviderNameRules.swift | grep -c 'let normalized = path$')" \
    "$(printf '%s\n' "$f" | grep -c 'func foldersPair')"
done
# measured 2026-10-02, against origin, before this landed:
# main, v4.x, v3.x, v2.x — every line: charAncestor=1 remapDrop=1 foldedSplit=1 leafSplit=3 nearKeySplit=1 foldersPair=0
# and on this change's own tree: 0 0 0 0 0 1
```

**`v4.x`, `v3.x`, `v2.x`: apply, RECORDED — not owed.** Every line carries all six sites and the
unchecked near-name match. A pick is the two source files with a scalar leaf helper in place of
`TreeShape.leaf` (main only), plus `SlashByScalarDiffTests`, the new `NameConflictDiffTests` cases
and `FileDiffEngineTests.aFileInAFolderTheWalkCouldNotReadDoesNotPairIntoAMissingFolder`, whose
`UnreadableAttributesFileManager` every line has.

## Compare stops re-reading what the pane just read (P44, P45, P46) — main only

Three costs on the way into a Compare. **P44:** a source or tab switch emptied the whole prefetch
cache, and the scan reads cached trees only when both sides hit, so the Compare after a switch walked
both folders from disk — at Home 4.2–5.8 s against 1.5–1.8 s at launch, and a different answer,
because the cold walk stops at the node budget somewhere else than the pane's walk did.
`dropPrefetchedTrees(keeping:)` now keeps the other pane's walk, which is the array that pane shows,
with its records. **P45:** the cold scan's detached walk hopped back to the main actor to read
`fileManager`, a `let`; it is read before detaching. **P46:** `computeDifferences` built a whole row
for every entry on one side only — a path composed without `isDirectory:`, so probed against the
file system, and a fresh id — ~200,000 on a Home scan, then collapsed them to a few dozen. It now
collapses on the keys first and builds rows for the survivors alone, with the type as the hint;
the output is byte-identical (4,000 seeded fixtures against the pre-change engine).

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s retarget=%s keeping=%s hop=%s unhinted=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Navigation.swift | grep -c 'func retargetPane(isLeft')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Navigation.swift | grep -c 'dropPrefetchedTrees(keeping:')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Scanning.swift | grep -c 'await MainActor.run { self.fileManager }')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDiffEngine.swift | grep -cE 'URL\.appendingPathComponent\((relativePath|remapped)\)\.path')"
done
# measured 2026-10-02, against origin, before this landed:
# main retarget=1 keeping=0 hop=1 unhinted=4 · v4.x retarget=1 keeping=0 hop=1 unhinted=4
# v3.x retarget=0 keeping=0 hop=1 unhinted=4 · v2.x retarget=0 keeping=0 hop=1 unhinted=4
```

**`v4.x`: owed, all three — not picked, per the standing direction.** Its `retargetPane` and
`applyTab` empty the whole cache and reload one pane, so the next Compare is cold (read from the
code, not run there). A pick is `dropPrefetchedTrees(keeping:)` with its two call sites, the hoisted
`fm`, and `computeDifferences`' step 3, which replaces the row-based `collapseMissingFolderContents`
and the re-aim map the line still has — with the three new test suites.

**`v3.x`, `v2.x`: P44 checked, not owed — it does not apply; P45 and P46 owed — not picked.** A
source switch there is `resetNavigation`, which drops both trees and reloads both panes, so both
are cached before the scan, and there are no pane tabs. The hop, the four unhinted compositions and
the row-based collapse are there; on `v2.x` (macOS 15) the P45 test's `Task.immediate` needs
`#available(macOS 26, *)`.

## Compare dated by the walks it compared; what a switch keeps and re-reads — main only

Five follow-ups from an adversarial review of P44–P46 (above). **Freshness:** a scan from cached
trees stamped the comparison with the moment it ran, and P44 made the scan after a source switch
read the other pane's kept walk — so the pill could say "just now" over an hours-old walk and never
give its hour-old warning. `lastScanReadAt`, the older walk's stamp, now dates the pill and the
not-scanned card; `lastScanDate` stays the scan's identity (the folds key on it). **Location
edit:** `invalidateComparisonState(reloading:)` emptied the whole cache before a one-pane reload —
P44's slowness on a third path; it keeps the other pane's walk. **Editor writes:** a comparing
refresh settled writes under a pane it did not walk, so that pane kept the pre-write tree and its
folder was compared cold; `refreshAction` walks it too, and `refreshForTabSwitch` goes through
`refreshAction` instead of copying it. **Unreadable walks:** a still pane whose walk could not list
its folder (access denied at the time) had that walk kept too, so once access came back the next
Compare compared against nothing; `dropPrefetchedTrees(keeping:)` no longer keeps one. **Logs:** the
scan says at Info whether it read cached walks (with their ages) or the disk.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s scopedInvalidate=%s owed=%s readAt=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Navigation.swift | grep -c 'func invalidateComparisonState(reloading scope')" \
    "$(git show origin/$l:MacApp/ContentView.swift | grep -c 'struct OwedComparison')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift | grep -c 'var prefetchedTreeReadAt')"
done
# measured 2026-10-03, against origin, before this landed:
# main scopedInvalidate=1 owed=1 readAt=1 · v4.x 1 0 0 · v3.x 0 0 0 · v2.x 0 0 0
```

**`v4.x`: the Location edit and the logs owed — not picked; the editor writes checked, not owed (no
`OwedComparison`).** Its warm scans date themselves by the scan too, but only after a navigation —
a switch empties its cache — and with no `prefetchedTreeReadAt` there is no walk stamp to date them
by: a pick of the freshness fix needs that bookkeeping first. The Location-edit pick needs
`dropPrefetchedTrees(keeping:)` from P44's pick.

**`v3.x`, `v2.x`: the logs owed — not picked; the Location edit and the editor writes checked, not
owed.** A Location edit there invalidates and reloads both panes, so both are cached before the
scan, and there is no `OwedComparison`. Freshness as on `v4.x`.

## A file and a folder whose names differ invisibly: the folder's contents in the row — main only

A near-name pair of a FILE and a FOLDER (`Notes ` against `Notes/`) is one `.nameConflict` row, but
it recorded neither a re-aim (that needs two folders) nor a type mismatch, so the folder's contents
stayed missing rows aimed at the other side's spelling: copying `Notes/a.txt` to the left made a
`Notes` folder beside the file `Notes `, the doppelganger the row exists to prevent, and a bulk sync
handled the subtree twice. The pair now records `typeMismatchDirs`, and the contents collapse into
the row as a type mismatch's do. Found in review of P46, older than it; the same pass added a
source check that every URL the engine composes is hinted, which `OneSidedRowPathTests`' byte
comparisons could not see.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s %s\n' "$l" "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDiffEngine.swift | grep -A1 'if leftFile.isDirectory && rightFile.isDirectory {' | grep -c 'nearNameDirPairs\[relativePath\] = rightKey')"
done
# measured 2026-10-03, before this landed: 1 on every line — the folder-pair branch, with no file/folder one beside it
```

**`v4.x`, `v3.x`, `v2.x`: owed — not picked, per the standing direction.** The branch is the same
on every line; a pick is the `else if` and the two comment lines, with
`NameConflictDiffTests.testAFileAgainstAFolderCarriesTheFoldersContents`. The hint check needs
P46's hinted compositions first.

## A folder whose cloud provider never answers no longer stalls Compare — main only

With OneDrive not running, listing either account's `.Trash` blocks for good: both are dataless
(`SF_DATALESS`), and listing a dataless folder asks its provider. The Home pane's walk reached one,
a cooperative-pool thread blocked in `getattrlistbulk`, `buildTree` never returned and the refresh
never compared; every Refresh leaked one more blocked thread until the other pane stopped loading.
A OneDrive pane hangs the same way, and so does the comparison's own disk walk, whose enumerator
blocks descending into the folder — both measured on `main`'s walks, killed at 25 s. A dataless folder is now listed off the pool through
`DatalessFolderReads`, for at most 5 s, then marked unexplored; one read per folder, so a later walk
skips one still unanswered; and `getFilesInDirectory` skips the enumerator's descent into one and
asks through the same reads. Every other folder is listed inline exactly as before — the pane walk
and the disk walk dumped byte-identical before and after over `~/Documents`, Dropbox and Google
Drive (17,121 / 13,770 / 54,345 lines each).

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s inlineListing=%s coldEnumerator=%s isDataless=%s datalessReads=%s\n' "$l" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Scanning.swift | grep -c 'realFm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: metadataKeys')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDiffEngine.swift | grep -c 'fileManager.enumerator(at: rootURL, includingPropertiesForKeys: keys')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileManaging.swift | grep -c 'func isDataless')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Sources/Sync/DatalessFolderReads.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-03, against origin, before this landed:
# main, v4.x, v3.x, v2.x — every line: inlineListing=1 coldEnumerator=1 isDataless=0 datalessReads=0
# and on this change's own tree: 1 1 3 1 (the requirement, its default, FileManager's)
```

**`v4.x`, `v3.x`, `v2.x`: apply, RECORDED — not owed.** Read from the code, not run there: every line
lists inside the pool's walk and lets the disk walk's enumerator descend anywhere. A pick is `DatalessFolderReads.swift`,
`FileManaging.isDataless(at:)`, the guard in the walk's listing — `childURLs(of:)` on those lines,
which has no `rawChildURLs` split — made `async` with its two callers, and the two guards in
`getFilesInDirectory`. `UnansweredFolderTests` needs `LogCapture` (on no maintenance line; drop the
two log assertions), and on `v3.x` and `v2.x` also `.parksAThread`, `MockFileManager.setStub` and
`maxEntries`, none of which they have.

## Expand in Edit's header, and a format bar above the text (TE48, TE52) — main only

Edit's "Just the text" was a ≡ inside the header's ＋ / Find capsule, with no menu item and no
key. It is now **Expand** (TE48): its own button between the mode capsule and the ×, arrows out and
the word Expand, reading Files and lit while it is on; Text ▸ Expand on ⌃⌘E (`AppChord.editorExpand`,
in the registry), offered where the header draws the button (`EditorExpandSwitch.isOffered`). Its
word shares the name row's width budget and goes before the capsule's, and in Frosted and Clear it
keeps `ChromeGlass.minimumCapsuleGap` (4pt) of glass from the × (`View.chromeGlassClearance(_:rowSpacing:)`).
What it does is the old toggle (`toggleJustTheText`, the `editorRailHidden` bit), now decided by
`editorIsExpanded` — the bit AND the pane folded — and logged from all three doors. The Markup verbs gained a **format bar** (TE52):
a strip in the text card above a writable Markdown document's source, in Source and Split's Source
half, built from `MarkupVerb.menuOrder` with the heading group as one menu, lit by
`MarkdownEdits.isApplied` — the verbs' own add-or-remove test, extracted from `wrap` and
`prefixLines` — and pressed through `EditorDocumentSurface.applyMarkup`, the Markup menu's function.
One deliberate verb change rides with it: Bold, Strikethrough and Inline Code no longer take a run
holding their delimiter again for one span (`**Warning** read the **docs**` used to come out turned
inside out); every other inline edit equals the old `wrap`, which `MarkupWrapEquivalenceTests` holds
case by case, as `MarkupPrefixLinesEquivalenceTests` already does for the line verbs.
Text ▸ Format Bar hides it (`editorShowsFormatBar`). The header stays at `LiquidGlass.headerHeight`.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s workspace=%s markupVerbs=%s textMenu=%s expandChord=%s formatBar=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorWorkspaceView.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/MarkupVerbs.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/ShortcutCommands.swift 2>/dev/null | grep -c 'CommandMenu("Text")')" \
    "$(git show origin/$l:Modules/Design/Sources/Design/AppChord.swift 2>/dev/null | grep -c 'editorExpand')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorFormatBar.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-03, against origin, before this landed:
# main  workspace=1 markupVerbs=1 textMenu=1 expandChord=0 formatBar=0
# v4.x, v3.x, v2.x — every line: workspace=0 markupVerbs=0 textMenu=0 expandChord=0 formatBar=0
# and on this change's own tree: 1 1 1 2 1 (the chord's declaration and its registry entry)
```

**`v4.x`, `v3.x`, `v2.x`: checked — not owed.** None of them has the Edit workspace (it arrived on
`main` 2026-08-31; see "The Edit workspace" above), so there is no header for Expand to sit in, no
Markup verbs for a bar to carry, and no Text menu for either item. Nothing to pick short of the
workspace itself.

## Lists carry on, links and images paste, the heading in the status line (TE54–TE57) — main only

Four edits to a writable Markdown file in Edit, each a narrow exception to "Edit writes only what
you typed", each asked of the preview's own parser first (`MarkdownSourceContext` — cmark-gfm
directly, configured as swift-markdown configures it, over the buffer up to the caret's line;
`FileExplorer` now names the `cmark-gfm` products it already linked through `Markdown`). **TE54:**
Return at the end of a list item adds the next opening (`MarkdownListEdits.returnEdit` — same
bullet, number + 1, `[ ]` after a task), the Return and the opening one undo step; Return on an
empty item takes the opening off and ends the list (`.endList`). Tab/⇧Tab move an item and the lines the parser gives it (`itemExtent`) by its content column,
and keep the result only if `MarkdownSourceContext.leaves` reads back the same blocks and words
with that item one level moved (a first sub-list item may be renumbered `1.`, the only number that
interrupts a paragraph); Text ▸ Continue Lists (`editorContinuesLists`) turns it off. **TE55:** a
lone http(s) address pasted over words makes `[words](url)` (`MarkdownPasteEdits.linkPaste`).
**TE56:** an image dropped from Finder or pasted is written into `<note folder>/Images/<note>-N.<ext>`
through `EditorFileStore.createNew` — a new door that stages, flushes and moves in with
`renamex_np(RENAME_EXCL)`, so it never replaces a file — and linked on its own line; the host re-reads
the panes and owes Compare through `rereadPanesAfterEditorWrite`. Paste and drop reach a new
`NSTextView` subclass, `EditorTextView`. **TE57:** `EditorStatusLine` leads with "in <heading> ▾", a
menu of `MarkdownOutline`'s entries sending the rail's `EditorScrollRequest`; its name truncates
before the counts go (`headingFloor`).

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s editor=%s statusLine=%s listEdits=%s textView=%s imageImport=%s continuesLists=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PlainTextEditor.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorStatusLine.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/MarkdownListEdits.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorTextView.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorImageImport.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorTextSettings.swift 2>/dev/null | grep -c 'continuesListsKey')"
done
# measured 2026-10-04, against origin, before this landed:
# main  editor=1 statusLine=1 listEdits=0 textView=0 imageImport=0 continuesLists=0
# v4.x, v3.x, v2.x — every line: editor=0 statusLine=0 listEdits=0 textView=0 imageImport=0 continuesLists=0
# and on this change's own tree: 1 1 1 1 1 1
```

**`v4.x`, `v3.x`, `v2.x`: checked — not owed.** None of them has the Edit workspace, so there is no
text view to carry a list in, nothing to paste a link or an image into, and no status line for the
heading. Nothing to pick short of the workspace itself.

**Revised by the review of 2026-10-04, main only, same verdict.** Return now asks the parser what
lies BELOW the line too (`MarkdownSourceContext.itemAtLineEnd`): the end of a line an item's words
carry on from is a plain Return, the end of a multi-line item carries on from its opening, an item
with children carries on as its first child (numbered `1.`), and `.endList` replaced `.clearMarker`
— an empty item mid-list ends the list with a blank line kept under the caret, and in a sub-list
the caret stays indented in the item above. Tab's check counts every item, so it moves next to an
empty one. Link paste keeps a selected line break and every marker outside the link, escapes `|`,
and leaves HTML and email autolinks alone. An image goes after the block it lands in, never inside
it (`MarkdownSourceContext.imageSpot`), and a pasted image FILE is copied in as a drop is. Nothing
here exists on `v4.x`, `v3.x` or `v2.x` either: checked by the same command, the same answer.

## The format bar spells its buttons out (TE63, TE64) — main only

The TE52 format bar drew bare glyphs. It now draws **Icon and Text** by default: a short word beside
every button but B, I and S (Code, Link, Bullets, Numbered, Tasks, Quote, Code Block, Rule —
`EditorFormatBar.word`), as long as the words fit. `EditorFormatBar.ladder(showsLabels:)` puts two
worded rungs (`labelledRungs`) ahead of the shipped ladder, so the words come off before any button
does and a narrow column — the narrowest Split half, and Split at most window widths — draws the bar
exactly as it shipped. A right-click on the bar (`EditorFormatBarMenu`) chooses **Icon and Text** or
**Icon Only**, stored as `editorFormatBarShowsLabels` (default on, decision Q = B; not tied to Row
spacing), or hides the bar through Text ▸ Format Bar's own setting. No verb, menu or chord changes.
A hidden bar comes back from Format Bar on the text's own right-click menu (writable Markdown only),
and from View ▸ Format Bar — added after it shipped, when the right-click Hide left no way back on
screen. The menu-bar switch moved from Text to View then, beside Status Bar (his call, 2026-10-04).

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s formatBar=%s labelsKey=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorFormatBar.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorTextSettings.swift 2>/dev/null | grep -c 'formatBarShowsLabelsKey')"
done
# measured 2026-10-04, against origin, before this landed:
# main  formatBar=1 labelsKey=0
# v4.x, v3.x, v2.x — every line: formatBar=0 labelsKey=0
# and on this change's own tree: formatBar=1 labelsKey=1
```

**`v4.x`, `v3.x`, `v2.x`: checked — not owed.** None of them has the format bar, which this only
changes, nor the Edit workspace it sits in (see the TE48/TE52 section above).

## A Table menu in Markup and on the format bar (TE65, TE66) — main only

Markup gained a **Table** submenu, drawn as one Table menu at the end of the format bar: Insert
Table, Make Table from Selection (tab- or comma-separated lines, CSV quoting read), Add Row
Above/Below, Add Column Left/Right, Delete Row, Delete Column and Format Table (`.tidy` in code). The verbs are
`MarkupVerb.table(TableVerb)`, appended to `menuOrder` so no existing tag moved, and the edits are
pure functions in `MarkdownTables` (`MarkdownTableEdits.swift`) reached through
`MarkdownEdits.apply`, so each is one ⌘Z. A table is GitHub's (header, matching delimiter row,
rows with pipes, outside fences). An edit keeps the table's style: an aligned table is re-padded,
a ragged one changes only in the touched row or column (decided 2026-10-04). Items that would do
nothing are disabled on the bar and in the right-click menu; from the menu bar they log why.
`edit(_:source:table:row:column:offsetInCell:)`, `tidy(source:table:)` and `isAligned(source:table:)`
need no selection, for editable Preview (TE67).

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s markupVerbs=%s tableEdits=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/MarkupVerbs.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/MarkdownTableEdits.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-04, against origin, before this landed:
# main  markupVerbs=1 tableEdits=0
# v4.x, v3.x, v2.x — every line: markupVerbs=0 tableEdits=0
# and on this change's own tree: markupVerbs=1 tableEdits=1
```

**`v4.x`, `v3.x`, `v2.x`: checked — not owed.** None of them has the Markup verbs or the Edit
workspace, so there is no menu for a Table submenu and no text view for it to edit.

## ⌘Z after a mode switch, after any undo, and after a checkbox tick reaches the screen and the document (TE67.0) — main only

Three defects in Edit's undo, one cause: the text lived in a storage each `NSTextView` made for
itself, while the undo stack was shared. Edit and Split mount the Source view from two `switch` arms
and Preview mounts none, so every mode switch built a new view, and an `NSTextView` registers undo
against its own storage — ⌘Z after a switch reverted the discarded view's text and moved nothing on
screen. On TextKit 2 an undo also sends no `textDidChange`, which the buffer followed alone, so after
ANY ⌘Z the document, autosave and the dirty dot kept the undone text until the next keystroke. And a
Preview checkbox tick wrote the buffer whole, with no undo. Now each document has ONE
`EditorSourceStorage`, kept by `EditorUndoStore` beside its stack (kept, refused and evicted
together); every Source view is the factory's view re-pointed at it (`PlainTextEditor.show`), the
buffer is published from the storage's own edits, and the tick goes through
`EditorSourceStorage.replace`, which registers its undo against the storage.
`EditorDocumentLoad`/`EditorDocumentClose` gained a fourth step, `document.buffer.follow(undoStore.source)`.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s undoStore=%s textView=%s sourceStorage=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorUndoStore.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PlainTextEditor.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorSourceStorage.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-04, against origin, before this landed:
# main  undoStore=1 textView=1 sourceStorage=0
# v4.x, v3.x, v2.x — every line: undoStore=0 textView=0 sourceStorage=0
# and on this change's own tree: 1 1 1
```

**`v4.x`, `v3.x`, `v2.x`: checked — not owed.** None of them has the Edit workspace (see "The Edit
workspace" above), so there is no text view, no editor undo stack and no preview to tick in.

## Edit writes LF only, converting a file on its first edit — main only

Measured 2026-10-05: every way Source wrote a line break — Return, Return in a list, the Code Block
and Horizontal Rule verbs, a paste or drop of several lines, Replace with a line break — wrote `\n`
into CRLF and lone-CR files, leaving them mixed (the status line read "Mixed"). The table verbs
followed CRLF but not CR. He chose LF only: a CRLF, CR or mixed file keeps its bytes until its
first edit, which converts every break to LF inside that edit's undo step, and everything written
after is LF, pasted text included. `EditorLineEndings` holds the rules; `EditorTextView` converts
before a key command, paste or image drop measures its edit, and its `shouldChangeText` is the net
under the rest; `EditorSourceStorage.replace` does the same for a Preview checkbox tick. `LineEndingPathsTests` pins every path against LF's own bytes.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s plainTextEditor=%s editorTextView=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PlainTextEditor.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorTextView.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-05, against origin, before this landed:
# main  plainTextEditor=1 editorTextView=1
# v4.x, v3.x, v2.x — every line: plainTextEditor=0 editorTextView=0
```

**`v4.x`, `v3.x`, `v2.x`: checked — not owed.** None of them has the Edit workspace, so there is no
text view writing line breaks.

## The format bar regrouped into capsules, a Table capsule in tables (TE68–TE76) — main only

The format bar became a capsule per group, in the order the Markup menu now follows too (decision
AA = C6): Body · Bold, Italic, Strikethrough · the three lists · Inline Code, Code Block, Block Quote
· Link…, Table, Divider. `menuOrder` was regrouped, the table run moved inside the last group, and
both menu builders draw the Table submenu where the run starts. "Horizontal Rule" is titled
**Divider** (the case keeps its name). The bar is a quarter larger (14pt glyphs, 25pt boxes) and
narrows group by group: words off, Body to ¶, each group folded into one button, then one merged
» beside B, I and S. With the caret in a table a Table capsule appears (Row, Column, Delete,
Format) and the verbs that rewrite whole lines are greyed. They are refused by
`MarkdownEdits.breaksTable(_:in:selection:)` in `apply` when either end of the selection is in a
table, and the menu bar logs why. The Body menu is a popover that draws each style as it looks.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s formatBar=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorFormatBar.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-05, against origin, before this landed:
# main  formatBar=1
# v4.x, v3.x, v2.x — every line: formatBar=0
```

**`v4.x`, `v3.x`, `v2.x`: checked — not owed.** None of them has the format bar or the Markup
verbs (see the TE48/TE52 and TE65/TE66 entries above), so there is nothing to regroup.

## Edit in Preview — typing in a Markdown file's Preview and Split, experimental (TE67.1–.5) — main only

Preview can be typed in, behind Text ▸ Edit in Preview (Experimental) and a pill in the Preview
column, for Markdown only — on by default since 2026-10-14 (it landed off). Each keystroke is translated into the smallest source
edit that renders as what was typed, verified by re-parsing, and refused otherwise
(`PreviewEditTranslator`, over the position model in `MarkdownProjection`); `PreviewEditSession`
writes it through `EditorSourceStorage.replace`, so it is on the document's undo stack and in Source
at once. In Split both halves are editable and each follows the other's scroll; tables are laid
out on tab stops and stay aligned as you type. Built on the shared source storage (TE67.0) and on
LF-only writing, both main only.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s sourceStorage=%s markupVerbs=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorSourceStorage.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/MarkupVerbs.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-05, against origin, before this landed:
# main  sourceStorage=1 markupVerbs=1
# v4.x, v3.x, v2.x — every line: sourceStorage=0 markupVerbs=0
```

**`v4.x`, `v3.x`, `v2.x`: checked — not owed.** None of them has the Edit workspace, its shared
source storage or the Markup verbs, so there is no Preview to type into.

## Edit notices a change to the open file from elsewhere when it happens (TE59) — main only

`EditorDiskWatch` watches the open document (a `kqueue` vnode source on the file and its folder,
`EditorFileWatcher`) and answers each change: nothing unsaved — reload quietly, history emptied;
unsaved typing — a banner (Compare, Keep Mine, Use the Disk's) and autosave stopped; moved or
renamed — followed; deleted — a banner (Close, Save Again). The editor's own writes compare against
the stamp they read back (`EditorDocument.diskStamp`, `backgroundWrites`). With it, three refresh
gaps the app's own operations left: a write that recreates a deleted file is shown in the panes
(`writeEditorDocument` → `showCreatedFileInPane`), Edit's rail and the watch both follow
`refreshSubject`'s epilogue (`refreshEditorAfterFileOperation`), and an image import re-reads the
rail. And one outside Edit: the destination picker's New Folder tells the host the moment it makes a
folder (`DestinationPicker.onFolderCreated`), so a transfer declined after it leaves the folder
listed.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s divergence=%s pickerNewFolder=%s onFolderCreated=%s\n' "$l" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorFileStore.swift 2>/dev/null | grep -c 'func divergence')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DestinationPicker.swift | grep -c 'createFolderAndCommit')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DestinationPicker.swift | grep -c 'onFolderCreated')"
done
# measured 2026-10-09, against origin, before this landed:
# main  divergence=1 pickerNewFolder=2 onFolderCreated=0
# v4.x, v3.x, v2.x — every line: divergence=0 pickerNewFolder=2 onFolderCreated=0
```

**`v4.x`, `v3.x`, `v2.x`: the watch and the editor's three gaps — checked, not owed.** None of them
has the Edit workspace's file store, so there is no open document to watch and no rail.

| Change | `v4.x` | `v3.x` / `v2.x` | Status |
|---|---|---|---|
| **The picker's New Folder, listed when the transfer after it is declined** (`DestinationPicker.onFolderCreated`, answered by `rereadPanesAfterEditorWrite(_:writer:)`) | The picker and its `createFolderAndCommit` are there; a declined transfer leaves the new folder unlisted until something re-reads its parent. The host half needs a targeted re-read — `main`'s `rereadPanesAfterEditorWrite` does not exist there; `refreshAction(reloading:)` of the pane holding the parent is the shape to use | Same | RECORDED — not owed |

## The re-survey fixture removes its temp root — `v4.x` carries the leak

Test hygiene only. `FilingResurveyTests.makeTree()` made a `Resurvey-<UUID>` root with
`makeCanonicalTempRoot` and returned only `root/Documents`, so no caller could remove it: every Sync
run left ~37 in `$TMPDIR` (395 there by 2026-10-15). It now returns the root as a fifth element,
and each of its callers — its own suite, `DocumentSurveyFolderTests`, `LargeWalkGuardTests` — follows
it with `defer { try? FileManager.default.removeItem(at: root) }`, the idiom
`makeCanonicalTempRoot`'s doc names.

```sh
for l in main v4.x v3.x v2.x; do printf '%-5s ' "$l"
  for f in FilingResurveyTests DocumentSurveyFolderTests LargeWalkGuardTests; do
    p=Modules/Sync/Tests/Sync/$f.swift
    git cat-file -e origin/$l:$p 2>/dev/null && printf '%s=%s ' $f "$(git show origin/$l:$p | grep -c 'makeTree()')" || printf '%s=absent ' $f
  done; echo; done
# measured 2026-10-15, against origin, before this landed (counts include the definition and doc mentions):
# main  FilingResurveyTests=32 DocumentSurveyFolderTests=4 LargeWalkGuardTests=1
# v4.x  FilingResurveyTests=25 DocumentSurveyFolderTests=absent LargeWalkGuardTests=1
# v3.x, v2.x — every file absent
```

| Line | Carries | Status |
|---|---|---|
| `v4.x` | `makeTree()` returns no root; its own callers and `LargeWalkGuardTests`' one leak a `Resurvey-*` folder per test case | RECORDED — not owed (test hygiene) |
| `v3.x` / `v2.x` | No re-survey suite | CLOSED — does not apply |

## One busy indicator per pane; Compare shown busy only past 0.75 s — main only

A pane reading its folder showed up to three indicators: the centred "Scanning Directory…" while it
had no rows, a spinner chip in the corner once it had some, and a spinner in every open empty
Columns column — the chip and the column spinners together for the whole gap between the shallow
first paint and the deep walk. Now the pane's walk has one, the corner chip (`PaneBusyIndicator`),
labelled, for the whole load and backed only when rows sit under it; a column spins only for a
listing it alone is waiting on (`PaneColumnsView.emptyCaption` answers nil, not `.loading`, during
the walk). Compare's card, count pill and the panes' Stop rung read `FileSyncManager.isScanShown`,
which rises only once a scan has run 0.75 s, instead of `isScanning` — most rescans take 120–400 ms
and flashed all three.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s centre=%s chip=%s columnSpinner=%s pillIsScanning=%s scanStartedAt=%s\n' "$l" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift | grep -c 'ProgressView("Scanning Directory')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift | grep -c '!tree.isEmpty && isLoading')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PaneColumnsView.swift | grep -c 'if isLoading { return .loading }')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DifferencesView.swift | grep -c 'if syncManager.isScanning {')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift | grep -c 'var scanStartedAt')"
done
# measured 2026-10-15, against origin, before this landed:
# main, v4.x — centre=1 chip=1 columnSpinner=1 pillIsScanning=1 scanStartedAt=1
# v3.x, v2.x — centre=1 chip=1 columnSpinner=0 pillIsScanning=1 scanStartedAt=0
```

**`v4.x`: applies whole, RECORDED — not owed.** Every piece is there in `main`'s shape. A pick is
`PaneBusyIndicator.swift`, the two `FileTreeView` sites, the `emptyCaption` line, `isScanShown` and
its wait in `FileSyncManager` and `executeScan`, and the three readers (`DifferencesView`'s pill,
`ContentView`'s card and rung).

**`v3.x`, `v2.x`: the pane half applies, RECORDED — not owed; the column and Compare halves are
checked, not owed in this shape.** Both carry the centred placeholder and the corner chip. Neither
has `emptyCaption` (`PaneColumnsView` is there, without the per-column spinner), so there is no
column half to take. Neither has `scanStartedAt` or `ScanRungMode`; the pill reads `isScanning` and
would flash the same way, so `isScanShown` would need its own start in `executeScan` there, and the
rung is a spinning arrow rather than Stop.

## Every listing asks a folder whose cloud app never answers through the dataless reads — main only

The dataless reads (`DatalessFolderReads`) guarded only the two walks. Everything else that lists a
folder — the shared `FileManaging.listing(of:)` / `childCount(of:)`, and four bare
`contentsOfDirectory` / enumerator sites — still blocked for good on a dataless folder whose app is
not running. Measured with a recording disk: the move undo's identity listing runs on the MAIN
thread (Rename, Move, Filing), the merge listings and the copy undo's deep walk on the cooperative
pool, the picker's column on the pool. `listing` and `childCount` now ask a dataless folder through
the reads (waiting at most the deadline, once per folder) and step around one met inside a recursive
walk; `waitForContents(of:)` lets an async caller ask without holding a thread. Routed through them:
the destination picker's columns and search, `ItemIdentity.snapshot` / `deepSnapshot`, the folder
merge (its error names the cause; its preview no longer asks, and gives up at a folder it cannot
read instead of counting around it), `liveFiles`, `PeopleNameScanner`, Edit's rail, the filing
card's peek and the Details sidebar's folder size. A folder that is not dataless costs one `stat`.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s datalessReads=%s merge=%s liveFiles=%s people=%s rail=%s deepIdentity=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Sources/Sync/DatalessFolderReads.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations.swift | grep -c 'func mergeChildren')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+FilingRename.swift 2>/dev/null | grep -c 'fm.listing(of: dir')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/PeopleNameScanner.swift 2>/dev/null | grep -c 'contentsOfDirectory')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorRail.swift 2>/dev/null | grep -c 'contentsOfDirectory')" \
    "$(git show origin/$l:Modules/Sync/Sources/Sync/ItemIdentity.swift | grep -c 'fm.listing(of: url, options: \[\])')"
done
# measured 2026-10-15, against origin, before this landed:
# main  datalessReads=1 merge=1 liveFiles=1 people=1 rail=1 deepIdentity=1
# v4.x  datalessReads=0 merge=0 liveFiles=1 people=1 rail=0 deepIdentity=1
# v3.x  datalessReads=0 merge=0 liveFiles=0 people=0 rail=0 deepIdentity=0
# v2.x  datalessReads=0 merge=0 liveFiles=0 people=0 rail=0 deepIdentity=0
```

**`v4.x`, `v3.x`, `v2.x`: RECORDED — not owed, and not pickable alone.** Read from the code, not
run there. None of the three has `DatalessFolderReads` or `isDataless(at:)`, so a pick must take
the row above first. Every line has `listing(of:)`, the picker and the shallow move-undo identity
(on the main actor there too); `v4.x` also has the deep identity, `liveFiles` and Look for Names;
none has the folder merge or Edit's rail. The listing guard and its tests (`UnansweredListingTests`)
then apply site by site; the FileExplorer and Dashboard tests need `FileExplorerTestSupport`'s
`UnansweredRealDisk`.

## The column preview opens its PDF through the PDFKit lane — main only

`PDFPagePreview` used to call `PDFDocument(url:)` on the main actor, in `makeNSView` and
`updateNSView`. That was a main-thread parse per selected PDF, and a parse outside
`PDFKitSerialAccess` that could overlap a duplicate scan's or a document survey's extraction, which
is the overlap the lane exists to prevent. The preview now opens its document through
`PDFKitSerialAccess.perform`, the way `PDFPairView` already did. The newest request wins, and a load
that lands after dismantle is dropped. `SendableDocument` is now one shared type.

A follow-up on `main` closed what review found in that first cut. The column's icon now stays behind
the page until the lane delivers it, where the pane used to go blank. A PDF that cannot be opened
or is password-protected keeps the icon with a caption, and says so in the log. An open withdrawn
before the lane reaches it is not parsed at all. The lane's doc now also names the one parse still
outside it, File ▸ Print's `PDFDocument(data:)`.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s pdfPagePreview=%s laneInPreview=%s lane=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PDFPagePreview.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PDFPagePreview.swift 2>/dev/null | grep -c 'PDFKitSerialAccess.perform')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Sources/Sync/PDFKitSerialAccess.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-16, against origin, before this landed:
# main  pdfPagePreview=1 laneInPreview=0 lane=1
# v4.x  pdfPagePreview=0 laneInPreview=0 lane=1
# v3.x  pdfPagePreview=0 laneInPreview=0 lane=0
# v2.x  pdfPagePreview=0 laneInPreview=0 lane=0
```

| Line | Carries | Status |
|---|---|---|
| `v4.x` | Has the lane, but its column preview shows PDFs through Quick Look, out of process, so no app parse happens there to route. Nor does it have `DocumentPrinting` (File ▸ Print), checked 2026-10-16 | CLOSED — does not apply |
| `v3.x` / `v2.x` | Neither the lane, `PDFPagePreview` nor `DocumentPrinting` | CLOSED — does not apply |

A future pick of the PDF renderer (see "2026-09-09 — a PDF preview fits the whole page instead of
the pane's width", RECORDED — not owed) should take this change with it. Otherwise the defect it
brings along is a main-thread parse outside the lane.

## File ▸ Print opens its rendered PDF through the PDFKit lane — main only

`DocumentPrinting.operation(for:)` used to open the PDF it had just rendered with
`PDFDocument(data:)` on the main actor, the last parse in the process outside `PDFKitSerialAccess`.
The parse now awaits `perform`; the render and the print operation stay on the main actor. ⌘P now
goes through `DocumentPrinting.prepare`, which hands the operation over once the lane has parsed it,
and drops a second press while the first is still waiting. The lane's doc no longer names a parse
that skips its turn.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s printing=%s lane=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/DocumentPrinting.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Sources/Sync/PDFKitSerialAccess.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-16, against origin, before this landed:
# main  printing=1 lane=1
# v4.x  printing=0 lane=1
# v3.x  printing=0 lane=0
# v2.x  printing=0 lane=0
```

| Line | Carries | Status |
|---|---|---|
| `v4.x` / `v3.x` / `v2.x` | No `DocumentPrinting` — File ▸ Print is not on any maintenance line | CLOSED — does not apply |

A future pick of File ▸ Print (RD9) should take this change with it, and needs the lane, which only
`v4.x` has.

## Edit opens a PDF read-only — main only

Edit used to open only text. A PDF that reached it through Open With ▸ Other… went through the
text reader's lossy decode and opened read-only as garbled text. Now ⌘O, the row menu's Open in
Edit, the preview column's button, a click in Edit's pane and the inspector offer PDFs too, behind
`EditableText.opensInEdit`. A PDF opens into `EditorPDFDocument`, a read-only model beside
`EditorDocument`, never a kind of it. The text document is emptied (`path == nil`), so no save path
can reach the PDF. The parse, the unlock and the facts go through `PDFKitSerialAccess`.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s editorDocument=%s editableText=%s pdfModel=%s lane=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorDocument.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PairContentKind.swift 2>/dev/null | grep -c 'enum EditableText')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Sources/Sync/PDFKitSerialAccess.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-17, against origin, before this landed:
# main  editorDocument=1 editableText=1 pdfModel=0 lane=1
# v5.x  editorDocument=1 editableText=1 pdfModel=0 lane=1
# v4.x  editorDocument=0 editableText=0 pdfModel=0 lane=1
# v3.x  editorDocument=0 editableText=0 pdfModel=0 lane=0
# v2.x  editorDocument=0 editableText=0 pdfModel=0 lane=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Edit, `EditableText`, the lane and `PDFOpenTicket` — and the defect: a PDF from Open With ▸ Other… opens read-only as garbled text | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace at all (`EditorDocument` is v5) | CLOSED — does not apply |

**`v5.x` pick notes.** One self-contained commit; every prerequisite is on the line (`PDFOpenTicket`
came with v5.5's preview review). Expect the same wiring pins to move (`editorOpenPath`,
`EditorOpenRoute.load`, `opensInEdit`), and `PDFKitSerialAccess`'s doc paragraph to need merging
with whatever that line's copy says about File ▸ Print.

## Edit's rail lists PDFs, with Pages and a PDF's bookmarks — main only

The rail's first tab is "Files" now, with a Text Files section and a PDFs section. While a PDF is
open the rail has a Pages tab of thumbnails, drawn one page at a time through `PDFKitSerialAccess`,
and Outline lists the PDF's bookmarks. The tabs carry words only, no glyphs, so three fit. A PDF
over the 4 MiB text cap is not dimmed. Everything it builds on (`EditorRailTab`,
`EditorPDFDocument`) exists only on `main`.

```sh
for l in main v4.x v3.x v2.x; do
  printf '%-5s railTab=%s pdfModel=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorRailTab.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-16, against origin, before this or 1a landed:
# main  railTab=1 pdfModel=0
# v4.x  railTab=0 pdfModel=0
# v3.x  railTab=0 pdfModel=0
# v2.x  railTab=0 pdfModel=0
```

| Line | Carries | Status |
|---|---|---|
| `v4.x` / `v3.x` / `v2.x` | No Edit rail and no PDF model (both are v5) | CLOSED — does not apply |
| `v5.x` | The Edit rail without PDFs, and no PDF model (measured `railTab=1 pdfModel=0`) | RECORDED — not owed (main only) |

## A checkbox tick reads one line; the dirty check compares units, not Unicode (P52, P54) — main only

A tick from the read-only Preview — Edit in Preview off, or a note over its 256 K limit — used to
copy the whole storage, walk it a Character at a time to the line, build a new text and diff the
two in full. `MarkdownEdits.taskToggle` now reads the storage's UTF-16 in place, only as far as the
line's end, and returns the one unit of the box that changes; the edit is the same, held to a
verbatim copy of the old code on 4,000 generated documents. `EditorDocument.isDirty` compared with
Swift's `!=`, which is canonical equivalence: a buffer whose bytes differ from the file's only in
how an accent is written read clean whenever the UTF-8 lengths matched, so ⌘S, autosave, the close
and quit prompts and a quiet reload from disk passed over it. It compares with `NSString.isEqual`
now, unit for unit.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s oldTick=%s oldDirty=%s\n' "$l" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/MarkdownEdits.swift 2>/dev/null | grep -c 'Range<String.Index>')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorDocument.swift 2>/dev/null | grep -c 'text != savedText')"
done
# measured 2026-10-17, against origin, before this landed:
# main  oldTick=1 oldDirty=1
# v5.x  oldTick=1 oldDirty=1
# v4.x, v3.x, v2.x — every line: oldTick=0 oldDirty=0 (neither file exists)
# and on this change's own tree: 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Both: the tick walks and rewrites the whole text, and `isDirty` uses `!=`. A pick is this one commit; `MarkdownEdits.swift`, `EditorDocument.swift` and `toggleTask` in `EditorWorkspaceView.swift` are as `v5.5` shipped them, so it should apply as it stands | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace, so no preview to tick in and no buffer to call dirty | CLOSED — does not apply |

## One header-over-content rule for Unified and Cards; the Unified focus ring on the outline — main only

Every workspace column with a header over content now follows one rule: its own card per section in
Cards, one outlined region with the content flush under a header hairline in Unified
(`columnSectionCard` / `columnRegionFrame` / `columnHeaderRule`). The Organize lenses (Storage
included) and Compare's Differences area were two outlined boxes in Unified, their Cards shape, so
a lens's content sat a gutter below the file list; the file pane gains the hairline Edit already
drew. Separately, the Unified focus ring (`ActivePaneMark`) lost a second `cardInset` that drew it
half a gutter inside the region's outline. Every line carries the two-box lens header and
Differences; the ring's inset arrived with the focused-pane mark.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s lensHeader=%s ringInset=%s editUnifiedRegion=%s diffSections=%s\n' "$l" \
 "$(git show origin/$l:Modules/Design/Sources/Design/LensHeaderCard.swift 2>/dev/null | grep -c 'bottomSectionCard(surfaceStyle')" \
 "$(git show origin/$l:MacApp/ActivePaneMark.swift 2>/dev/null | grep -c 'padding(LiquidGlass.cardInset)')" \
 "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorWorkspaceView.swift 2>/dev/null | grep -c 'overlay(alignment: .bottom) { Divider() }')" \
 "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DifferencesView.swift 2>/dev/null | grep -c 'bottomSectionCard(surfaceStyle')"; done
# measured 2026-10-17, against origin, before this landed:
# main  lensHeader=1 ringInset=1 editUnifiedRegion=1 diffSections=2
# v5.x  lensHeader=1 ringInset=1 editUnifiedRegion=1 diffSections=2
# v4.x  lensHeader=1 ringInset=1 editUnifiedRegion=0 diffSections=2
# v3.x  lensHeader=1 ringInset=0 editUnifiedRegion=0 diffSections=2
# v2.x  lensHeader=1 ringInset=0 editUnifiedRegion=0 diffSections=2
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | All four: two-box lens header and Differences in Unified, the inset ring, Edit's one-region column | RECORDED — not owed (main only) |
| `v4.x` | Two-box lens header and Differences, the inset ring; no Edit document column | RECORDED — not owed (main only) |
| `v3.x` / `v2.x` | Two-box lens header and Differences; no focus ring, no Edit | RECORDED — not owed (main only) |

**Pick notes.** `LensHeaderCardTests` moves its fixtures to `.cards` and gains the Unified test;
`GlassLevelTests` gains the column tests. On `v4.x` and older, `EditorWorkspaceView` does not exist —
drop that hunk; on `v3.x`/`v2.x` drop the `ActivePaneMark` hunk too.

## Unified is one box: one outline under the toolbar, hairlines between areas — main only

Unified now draws ONE outlined region round everything under the toolbar (`windowRegionFrame`, on
`mainContentView`), and the areas inside it — sidebar, panes, Organize's panel, Differences, Edit's
strip, rail and document, the Info inspector — sit flush and meet at a hairline (`unifiedSeam`).
Before, Unified drew a box per area with a gutter between, so Edit showed three boxes in a row and
Organize, Compare and any workspace with the sidebar open showed two or more. In Unified,
`bottomSectionCard` and `panesRegionFrame` now draw no outline and inset nothing, layout
arithmetic reserves `LiquidGlass.gutter(style)` (0 in Unified) instead of `cardGutter`, and the
Compare focus ring is square. Cards is unchanged. Every line carries the box-per-area shape.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s sidebarCard=%s spineCard=%s inspectorCard=%s panesRegion=%s windowRegion=%s\n' "$l" \
 "$(git show origin/$l:MacApp/ContentView+FolderSidebar.swift 2>/dev/null | grep -c 'bottomSectionCard(surfaceStyle')" \
 "$(git show origin/$l:MacApp/ContentView+SplitLayout.swift 2>/dev/null | grep -c 'bottomSectionCard(surfaceStyle')" \
 "$(git show origin/$l:MacApp/ContentView.swift 2>/dev/null | grep -c 'bottomSectionCard(surfaceStyle')" \
 "$(git grep -c 'panesRegionFrame(surfaceStyle' origin/$l -- MacApp 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')" \
 "$(git grep -c 'windowRegionFrame' origin/$l -- MacApp Modules 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')"; done
# measured 2026-10-17, against origin, before this landed:
# main  sidebarCard=1 spineCard=1 inspectorCard=5 panesRegion=4 windowRegion=0
# v5.x  sidebarCard=1 spineCard=1 inspectorCard=5 panesRegion=4 windowRegion=0
# v4.x  sidebarCard=1 spineCard=1 inspectorCard=5 panesRegion=3 windowRegion=0
# v3.x  sidebarCard=0 spineCard=1 inspectorCard=3 panesRegion=2 windowRegion=0
# v2.x  sidebarCard=0 spineCard=1 inspectorCard=3 panesRegion=2 windowRegion=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Box per area in Unified: sidebar, spine, inspector, bottom sections, Edit's rail and document | RECORDED — not owed (main only) |
| `v4.x` | The same, without Edit's document column (three `panesRegionFrame` sites, not four) | RECORDED — not owed (main only) |
| `v3.x` / `v2.x` | Box per area for the spine, inspector and bottom sections; no folder sidebar card, no Edit | RECORDED — not owed (main only) |

**Pick notes.** Needs the previous section's column helpers (`columnSectionCard` /
`columnRegionFrame`) first; nowhere but `main` has them. `GlassLevelTests` swaps the Unified
inset tests for the one-box tests; `LensHeaderCardTests` measures inside `windowRegionFrame`. On
`v4.x` and older drop the `EditorWorkspaceView` and `ContentView+Editor` hunks; on `v3.x`/`v2.x`
also the folder-sidebar seam and the `ActivePaneMark` hunk.

---

## An Organize lens's header leaves the pane's tab-strip slot empty — main only

With two tabs in the rail (or View ▸ Tab Bar on), the strip pushes the pane's toolbar card down by
`PaneTabStripLadder.slotHeight`, and the lens header card beside it stayed at the top of the column,
its bottom edge one strip slot above the pane's — in Unified and Cards alike. `LensWorkspaceView`
now takes `paneShowsTabStrip` and leaves that slot clear above `lensHeaderCard`, as Edit's document
column already did. The host passes the predicate Edit uses, renamed `editorPaneShowsTabStrip` →
`sourcePaneShowsTabStrip` now that two columns read it; it is false while the rail is collapsed.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s lens=%s slotHeight=%s lensSlot=%s\n' "$l" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/LensWorkspaceView.swift 2>/dev/null | grep -c 'lensHeaderCard(rows')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PaneTabStripLadder.swift 2>/dev/null | grep -c 'func slotHeight')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/LensWorkspaceView.swift 2>/dev/null | grep -c 'paneShowsTabStrip')"
done
# measured 2026-10-17, against origin, before this landed:
# main  lens=2 slotHeight=1 lensSlot=0
# v5.x  lens=2 slotHeight=1 lensSlot=0
# v4.x  lens=2 slotHeight=0 lensSlot=0
# v3.x, v2.x — lens=0 slotHeight=0 lensSlot=0 (no lens workspace, no strip)
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The gap, and everything the fix stands on: the strip, `slotHeight`, `editorPaneShowsTabStrip`. A pick is this one commit; the rename touches `ContentView+Editor.swift` and the Edit wiring test as well | RECORDED — owed, not picked (no backporting) |
| `v4.x` | The lens header and a tab strip, but no `slotHeight` — that came with Edit's own fix, which `v4.x` has no document column to need. A pick would have to bring the helper too | RECORDED — owed, needs `slotHeight` first |
| `v3.x` / `v2.x` | No lens workspace and no tab strip | CLOSED — does not apply |

---

## Find inside a PDF open in Edit, and ⇧⌘G — main only

⌘F with a PDF open in Edit opens a find bar of the app's own under the header (the header's
magnifying glass too); ⌘G and the new ⇧⌘G step through matches, ⌘E searches the reader's
selection, Esc clears. The search reads a `PDFDocument` of its own, one page per
`PDFKitSerialAccess` turn from the page on screen, wrapping, each turn behind a withdrawable ticket;
matches come back as page-space rects and are drawn over the reader from geometry alone. The
thumbnails' lane seam became the shared `EditorPDFLane`. ⇧⌘G is new for the text find bar as well.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfModel=%s findNext=%s findPrevious=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/Design/Sources/Design/AppChord.swift 2>/dev/null | grep -c 'static let findNext')" \
    "$(git show origin/$l:Modules/Design/Sources/Design/AppChord.swift 2>/dev/null | grep -c 'static let findPrevious')"
done
# measured 2026-10-17, against origin, before this landed:
# main  pdfModel=1 findNext=1 findPrevious=0
# v5.x  pdfModel=0 findNext=1 findPrevious=0
# v4.x, v3.x, v2.x — pdfModel=0 findNext=0 findPrevious=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | No PDF reader to search; the text find bar with ⌘G but no ⇧⌘G | RECORDED — not owed (main only) |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace and no find verbs | CLOSED — does not apply |

**Pick notes, should ⇧⌘G alone ever go to `v5.x`.** `AppChord.findPrevious` + its registry line,
`FindPreviousCommand` with the text branch of `FindMenuRoute.step`, the Text menu line, the ⌘/
reference row and `windowSize` (740 → 760, re-measure there), and the `TextMarkupMenuTests` order pin.

---

## Compare's differences and Duplicates offer Open in Edit for PDFs — main only

A difference row's menu (`DifferenceRowMenu.editableSides`) and a duplicate copy's
(`DuplicateGroupCard.offersOpenInEditor`) now gate on `EditableText.opensInEdit` rather than
`isText`, so a PDF on either surface opens read-only in Edit, as every other door already did. The
compare pair viewer (Differences overlay, Compare Copies) still has no Open in Edit of its own.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s opensInEdit=%s diffGateIsText=%s dupGateIsText=%s\n' "$l" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/PairContentKind.swift 2>/dev/null | grep -c 'func opensInEdit')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DifferenceRowMenu.swift 2>/dev/null | grep -c 'EditableText.isText(path: \$0.side.path)')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DuplicateGroupCard.swift 2>/dev/null | grep -c 'EditableText.isText(path: copy.path)')"
done
# measured 2026-10-17, against origin, before this landed:
# main  opensInEdit=1 diffGateIsText=1 dupGateIsText=1
# v5.x  opensInEdit=0 diffGateIsText=1 dupGateIsText=1
# v4.x, v3.x, v2.x — 0 0 0 (no Open in Edit on either surface)
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Both menus on `isText` — right there, since Edit on that line opens no PDF | CLOSED — does not apply |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace | CLOSED — does not apply |

---

## Edit's PDF tools write copies beside the original — main only

The PDF header has a Tools menu, and the Pages tab selects (click, ⌘-click, ⇧-click), drags into a
pending order and has a menu on a selection. Rotate, Delete, Reorder and Extract pages, Compress,
Clean Metadata, Protect with Password and Remove Password each write a NEW file, `<name>
(<what was done>).pdf`, through `EditorFileStore.createNew` — never over the original or anything
else. The engine is `agirish/pdf-toolkit` 0.1.1 (`PDFToolkitCore`), the app's second shipped
dependency, called inside `PDFKitSerialAccess`. It all stands on `EditorPDFDocument`, which only
`main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfModel=%s toolkit=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Package.swift 2>/dev/null | grep -c 'pdf-toolkit')"
done
# measured 2026-10-17, against origin, before this landed:
# main  pdfModel=1 toolkit=0
# v5.x  pdfModel=0 toolkit=0
# v4.x  pdfModel=0 toolkit=0
# v3.x  pdfModel=0 toolkit=0
# v2.x  pdfModel=0 toolkit=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | No PDF model in Edit (`pdfModel=0`), so nothing for the tools to stand on | RECORDED — not owed (main only) |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace that opens PDFs at all | CLOSED — does not apply |

---

## PDF Tools in the file panes' right-click menu — main only

A PDF row in any file pane (Browse, both Compare panes, Organize's, Edit's own) has a **PDF Tools**
submenu — Rotate All Pages, Compress…, Clean Metadata…, Protect with Password… / Remove
Password… — and several selected PDFs get a batch of the first three (`PanePDFToolsSubmenu`,
`EditorPDFBatch`). A single file runs through Edit's own `EditorPDFTools`, so it stands on the Edit
PDF tools above, which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfTools=%s paneTools=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFTools.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PanePDFTools.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-17, against origin, before this landed:
# main  pdfTools=1 paneTools=0
# v5.x  pdfTools=0 paneTools=0
# v4.x  pdfTools=0 paneTools=0
# v3.x  pdfTools=0 paneTools=0
# v2.x  pdfTools=0 paneTools=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | No `EditorPDFTools` (`pdfTools=0`), so nothing for the submenu to run | RECORDED — not owed (main only) |
| `v4.x` / `v3.x` / `v2.x` | No Edit PDF model or tools at all | CLOSED — does not apply |

**Follow-up, 2026-10-18: the batch banner's Reveal in Browse selects every copy in the first
copy's folder**, not the first alone, and may replace the selection the batch was run on (which
dropped the debt before, so Reveal selected nothing). It widens TE47's debt
(`PaneSelectionDebt.companions` / `replaces`) and `PaneRowReveal.selection`. `v5.x` has TE47
(`PaneSelectionDebt` is there) but no batch to owe several rows, so nothing there needs the wider
debt: **CHECKED — not owed**. The older lines have neither.

---

## The PDF reader's layouts, zoom menu, and ⌘+ ⌘− ⌘0 on a focused PDF (Phase 5a) — main only

Edit's PDF reader gains Single Page, Continuous, Two Pages and Two Pages, Continuous, with Cover
Page Separately, remembered under `editorPDFLayout` / `editorPDFCoverSeparately`; Fit Page and Fit
Width measure the spread; the page field, status line and Pages tab show the spread. Page / Width /
Actual folds into a zoom menu (presets 50–400%, − and + on that ladder), and the header sheds words
as the column narrows. While the pages have the keyboard, View ▸ Text Size's three items become
Zoom In / Zoom Out / Actual Size on the same chords (`PDFZoomVerbs`, `TextSizeMenuRoute`). All of it
stands on `EditorPDFDocument`, which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfModel=%s layout=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFLayout.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-17, against origin, before this landed:
# main  pdfModel=1 layout=0
# v5.x, v4.x, v3.x, v2.x — pdfModel=0 layout=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | No PDF reader in Edit (`pdfModel=0`); View ▸ Text Size as it was, which is right there | CLOSED — does not apply |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace that opens PDFs at all | CLOSED — does not apply |

---

## The menu bar over a PDF in Edit — File ▸ PDF Tools, the page controls, ⌘C and ⌘A — main only

File ▸ PDF Tools ▸ is the PDF header's Tools menu, drawn by the same `EditorPDFToolsMenuItems` from
the same `EditorPDFToolsMenuEntry.entries` — which now also carry Save Reordered Copy and Reset Page
Order while a dragged order is pending. With a PDF open, Text's ⌃⌘1/2/3 are Fit Page / Fit Width /
Actual Size (Zoom In and Zoom Out under them) and ⌃⌘L is Go to Page…. ⌘C and ⌘A over the reader
reach its own copy and select-all (`TextEditingChord.route`'s `readerAction`) instead of the file
clipboard, and ⌘A in the Pages grid selects its pages (`EditorPDFPagesSelectAll`) — the grid's own
`.onKeyPress` never ran, because the menu's ⌘A takes the key first. All of it stands on
`EditorPDFDocument`, which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfModel=%s pdfToolsMenu=%s readerRoute=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/ShortcutCommands.swift 2>/dev/null | grep -c 'struct PDFToolsCommand')" \
    "$(git show origin/$l:MacApp/TextEditingChord.swift 2>/dev/null | grep -c 'readerAction')"
done
# measured 2026-10-17, against origin, before this landed:
# main  pdfModel=1 pdfToolsMenu=0 readerRoute=0
# v5.x, v4.x, v3.x, v2.x — 0 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | No PDF reader in Edit (`pdfModel=0`): no tools, no page controls, and no `PDFView` for ⌘C to miss | RECORDED — not owed (main only) |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace that opens PDFs at all | CLOSED — does not apply |

---

## File ▸ PDF Tools on the pane's selected PDFs — main only

Outside a PDF open in Edit, File ▸ PDF Tools is a pane row's PDF Tools submenu for the focused
pane's selection — one PDF, or "PDF Tools · 3 files" for a batch — drawn by the row's own
`PanePDFToolsMenuItems` from the row's own `PanePDFToolOffer.forSelection`, and run through the
pane delegate's `handlePDFTool`. It stands on both the pane tools and File ▸ PDF Tools above, which
only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s paneTools=%s pdfToolsMenu=%s selectionTools=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PanePDFTools.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/ShortcutCommands.swift 2>/dev/null | grep -c 'struct PDFToolsCommand')" \
    "$(git show origin/$l:MacApp/ShortcutCommands.swift 2>/dev/null | grep -c 'struct PDFToolsMenuContent')"
done
# measured 2026-10-18, against origin, before this landed:
# main  paneTools=1 pdfToolsMenu=1 selectionTools=0
# v5.x, v4.x, v3.x, v2.x — 0 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | No pane PDF Tools and no File ▸ PDF Tools (`0 0`), so nothing to reach | RECORDED — not owed (main only) |
| `v4.x` / `v3.x` / `v2.x` | No Edit PDF tools at all | CLOSED — does not apply |

---

## Fill & Sign in the PDF reader (Phase 5b) — main only

A Fill & Sign button in Edit's PDF header turns on a toolbar of Text, Date, ✓ ✗ •, Signature and
Initials, placed on the pages over the reader and moved, resized and undone there
(`EditorPDFFillSign`, `EditorPDFFillOverlay`). Saved signatures live in this Mac's defaults under
`editorPDFSavedSignatures`. Save Filled Copy is a new `EditorPDFTool.fillAndSign` case, run through
`EditorPDFTools.run` into pdf-toolkit 0.1.1's `fillAndSignData`, writing "Name (signed).pdf" or
"(filled).pdf" beside the original. Unsaved items join `EditorPDFTools.mayLeave()`. The button sheds
its word on the header's narrow rungs (`Rung.wordsFillAndSign`). All of it stands on
`EditorPDFDocument` and `EditorPDFTools`, which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfModel=%s fillSign=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSign.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-18, against origin, before this landed:
# main  pdfModel=1 fillSign=0
# v5.x, v4.x, v3.x, v2.x — pdfModel=0 fillSign=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | No PDF reader in Edit (`pdfModel=0`), so no header or tools for Fill & Sign to join | CLOSED — does not apply |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace that opens PDFs at all | CLOSED — does not apply |

---

## File ▸ Fill & Sign and Save Filled Copy — main only

Under File ▸ PDF Tools, a **Fill & Sign** toggle (ticked while the toolbar is up, greyed with the
refusal as a line under it) and **Save Filled Copy** (live where the toolbar's is), drawn by
`EditorPDFFillSignMenuItems` over the open PDF's `EditorPDFFillSign` and `EditorPDFTools`, published
as `PDFFillSignVerbs` while Edit shows an open PDF. It stands on Fill & Sign above and on File ▸
PDF Tools, which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s fillSign=%s pdfToolsMenu=%s fillMenu=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSign.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:MacApp/ShortcutCommands.swift 2>/dev/null | grep -c 'struct PDFToolsCommand')" \
    "$(git show origin/$l:MacApp/ShortcutCommands.swift 2>/dev/null | grep -c 'struct PDFFillSignCommand')"
done
# measured 2026-10-18, against origin, before this landed:
# main  fillSign=1 pdfToolsMenu=1 fillMenu=0
# v5.x, v4.x, v3.x, v2.x — 0 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | No Fill & Sign and no File ▸ PDF Tools (`0 0`), so nothing for the items to drive | CLOSED — does not apply |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace that opens PDFs at all | CLOSED — does not apply |

---

## Fill & Sign fills a PDF's own form fields (Phase 5c) — main only

pdf-toolkit moves from `0.1.1` to `0.2.0` (`formFields(at:)`, `fillFormData(inputURL:values:items:)`;
both tracked `Package.resolved` files that resolve it, FileExplorer's and Dashboard's, regenerated).
A PDF's fields are read in the lane with the facts (`EditorPDFForm`), and Fill & Sign opens on a
Form Fields tool that tints them, types into them, ticks, chooses and Tabs through them as draft
state on `EditorPDFFillSign`, on the same ⌘Z stack and leave question as the placed items. Save
Filled Copy on a file with a form runs a new `EditorPDFTool.fillForm` into `fillFormData`, so the
copy's form stays fillable and placed items become annotations; a flat file keeps 5b's
`fillAndSignData`. The toolkit's refusals are said before the lane (`EditorPDFForm.problem`), and
`EditorPDFToolEngine.reason` maps every `PDFOperationError` in one exhaustive switch. The reader's
own widgets are made read-only in the lane (`EditorPDFForm.lockWidgets`): before this, a click in
Edit's reader typed straight into the on-screen document. All of it stands on Fill & Sign, which
only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s fillSign=%s toolkit=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSign.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Package.swift 2>/dev/null | grep -o 'pdf-toolkit", exact: "[0-9.]*"' | grep -o '[0-9][0-9.]*' || echo none)"
done
# measured 2026-10-18, against origin, before this landed:
# main  fillSign=1 toolkit=0.1.1
# v5.x, v4.x, v3.x, v2.x — fillSign=0 toolkit=none
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | No Fill & Sign and no pdf-toolkit (`0 none`), so no reader for forms to join and no engine to fill them | CLOSED — does not apply |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace that opens PDFs at all | CLOSED — does not apply |

---

## Edit's PDF open parses the file once — main only

`EditorPDFDocument.read` used to open the file, then hand its URL to
`PDFToolkit.encryptionState(of:)`, which opened it a second time in the shared PDFKit lane just to
say how it is protected. The state now comes off the document already open
(`EditorPDFDocument.encryption(of:)`, the toolkit's rule without its own open). It stands on
`EditorPDFDocument`, which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfModel=%s toolkitCall=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift 2>/dev/null | grep -c 'PDFToolkit.encryptionState(of: url)')"
done
# measured 2026-10-18, against origin, before this landed:
# main  pdfModel=1 toolkitCall=1
# v5.x, v4.x, v3.x, v2.x — pdfModel=0 toolkitCall=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No PDF reader in Edit (`pdfModel=0`), so no open to parse twice | CLOSED — does not apply |

**The pane menu's probe followed, same rule.** `EditorPDFToolEngine.probeInLane(_:)` opened the
file, then asked `PDFToolkit.encryptionState(of: input)`, a second open; it now calls
`EditorPDFDocument.encryption(of:)` on its own document. Same lines, same verdict: the engine
exists only on `main`.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s engine=%s toolkitCall=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFToolEngine.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorPDFToolEngine.swift 2>/dev/null | grep -c 'PDFToolkit.encryptionState(of: input)')"
done
# measured 2026-10-18, against origin, before this landed:
# main  engine=1 toolkitCall=1
# v5.x, v4.x, v3.x, v2.x — engine=0 toolkitCall=0
```

---

## Rotate and Delete Pages take a pending page order along — main only

In Edit's PDF reader, Rotate and Delete Pages run while a dragged page order is pending now write
ONE copy in that order with the change applied — "Name (reordered, rotated).pdf" — and the order is
done with once it lands (`EditorPDFTool.composing(_:arrangement:)`, `.arranged`). The tool runs on
the original first, its bytes are staged in a private temporary folder, and `reorderData` puts them
in the dragged order, all in one `PDFKitSerialAccess` turn. A combined run on a form warns
(`.formOrphaned`) where Rotate or Delete alone would not. Extract is unchanged: the pages typed are
its order. All of it stands on `EditorPDFTools`, which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfTools=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFTools.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-18, against origin, before this landed:
# main  pdfTools=1
# v5.x, v4.x, v3.x, v2.x — pdfTools=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No PDF tools in Edit (`pdfTools=0`), so no pending order to take along | CLOSED — does not apply |

---

## The PDF reader's floating page and zoom capsule, two header rows (Phase 6a) — main only

Edit's PDF header is now a text file's two rows at a text file's height: the name, Find, Fill & Sign
and Tools, then "PDF · Letter, 8.5 × 11 in · 42 KB · Text selectable". Page, zoom and the view menu
moved into a glass capsule over the canvas (`EditorPDFCapsule`), movable to eight places stored by
name under `editorPDFCapsulePlace`; find became a floating card; the PDF's status line is gone. All
of it reshapes `EditorPDFCard`, the reader `main` alone has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfCard=%s statusLine=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFCard.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorPDFCard.swift 2>/dev/null | grep -c 'struct EditorPDFStatusLine')"
done
# measured 2026-10-18, against origin, before this landed:
# main  pdfCard=1 statusLine=1
# v5.x, v4.x, v3.x, v2.x — pdfCard=0 statusLine=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No PDF reader in Edit (`pdfCard=0`), so no header or status line to rework | CLOSED — does not apply |

---

## Fill & Sign as a floating palette and a save pill (Phase 6b) — main only

Fill & Sign's full-width toolbar under the PDF header (`EditorPDFFillSignBar`) and its line of words
are gone. Its tools float over the canvas in a palette (`EditorPDFFillPalette`) with flyouts for
marks, signatures, size and ink, movable to the capsule's eight places and stored under
`editorPDFPalettePlace`; the unsaved count, Discard and Save Filled Copy are a pill at the top of the
canvas, with a note card under it for the form's caveats. Row 2 of the header no longer counts. All
of it reshapes the Fill & Sign `main` alone has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s fillSignBar=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSignBar.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-19, against origin, before this landed:
# main  fillSignBar=1
# v5.x, v4.x, v3.x, v2.x — fillSignBar=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No Fill & Sign in Edit (`fillSignBar=0`), so no toolbar to replace | CLOSED — does not apply |

---

## Recents, Revisited, Frequent — main only

An icon on the sidebar's Recents heading cycles it through **Recents**, **Revisited** (stayed in on
two or more calendar days, newest first) and **Frequent** (most stays, faded over 30 days). A stay is
`FolderJumpStore.stayThreshold` in the folder, a return inside `returnGap` continues it, and both
lists look back 90 days. It needs a new record (`staysByRoot`, under `folderJumpStaysByRoot`) fed
by a dwell check beside `recordVisit`, and a remembered setting (`browseSidebarRecentsMode`). A new
feature, so `main` alone by rule. `v5.x` and `v4.x` have the sidebar and simply lack the modes; the
new key is additive, so a maintenance build sharing the defaults domain ignores it and leaves it
intact.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s sidebar=%s revisited=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Dashboard/Sources/Dashboard/FolderSidebar.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/Dashboard/Sources/Dashboard/FolderJumpStore.swift 2>/dev/null | grep -c staysByRoot)"
done
# measured 2026-10-19, against origin, before this landed:
# main, v5.x, v4.x — sidebar=1 revisited=0
# v3.x, v2.x       — sidebar=0 revisited=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` | The sidebar's Recents, without the modes | RECORDED — not owed (new feature) |
| `v3.x` / `v2.x` | No folder sidebar (`sidebar=0`) | CLOSED — does not apply |

---

## Fixes from a review of the whole PDF reader — main only

The upright capsule keeps one width at every zoom, so Fit Width no longer loops at 99–100%. A file
evicted while open is not downloaded by Find, the Pages tab, a new revision or a batch's form
question. A tool run or Save Filled Copy refuses a file that changed on disk since the reader read
it. A file that goes from under the reader says what unsaved Fill & Sign work went with it. A reload
that changed the pages forgets Fill & Sign's undo steps. A form-less PDF that forbids commenting, and
a checkbox whose boxes carry separate values, are refused. The text probe also reads pages spread to
the end. A batch says which copies lost their restrictions. Saved signatures stay removed after a
reset. The page field reads any script's digits. All of it is in the PDF reader `main` alone has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfDocument=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-19, against origin, before this landed:
# main  pdfDocument=1
# v5.x, v4.x, v3.x, v2.x — pdfDocument=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No PDF reader in Edit (`pdfDocument=0`), so nothing to fix | CLOSED — does not apply |

---

## Find's highlights kept by page as each page lands — main only

The PDF find bar's highlights are kept by page as each page's matches land, rather than rebuilt from
every match on every pass of the reader's body. Behaviour-preserving; it speeds up the PDF Find
`main` alone has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfFind=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFind.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-19, against origin, before this landed:
# main  pdfFind=1
# v5.x, v4.x, v3.x, v2.x — pdfFind=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No PDF find in Edit (`pdfFind=0`), so nothing to speed up | CLOSED — does not apply |

---

## Save as PDF from a file row and File ▸ — main only

A Word, Excel, PowerPoint, RTF, Markdown or text row in any file pane has **Save as PDF** in the
section PDF Tools takes on a PDF row, and several such rows get **Save N as PDFs** first after
Refresh; File ▸ Save as PDF does the same for the focused pane's selection. Each PDF is written
beside its original under its name, numbered on a clash, never over anything (`PaneSaveAsPDF`,
`SaveAsPDFOffer`). Text and Markdown render through Edit's `DocumentPDF`; RTF through the text
system; Word, Excel and PowerPoint through Quick Look's `qlmanage -p -o` HTML drawn by WebKit
(`SaveAsPDFRender`). The banner and its stacking stand on the pane PDF Tools' card
(`PanePDFToolsPresenter`), which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s documentPDF=%s paneTools=%s saveAsPDF=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/DocumentPDF.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PanePDFTools.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/SaveAsPDF.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-19, against origin, before this landed:
# main  documentPDF=1 paneTools=1 saveAsPDF=0
# v5.x  documentPDF=1 paneTools=0 saveAsPDF=0
# v4.x, v3.x, v2.x — 0 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Edit's `DocumentPDF` (File ▸ Export as PDF… for an open note), but no row item, no Office engine and no pane PDF Tools card for the banner (`paneTools=0`) | RECORDED — not owed (main only) |
| `v4.x` / `v3.x` / `v2.x` | No `DocumentPDF` and no pane PDF Tools | CLOSED — does not apply |

---

## The PDF reader's smaller seams from its review — main only

A Cancel or leave while a tool's copy is being written takes the copy back; ⌘Q asks about a PDF
tool started from a pane; the find card keeps one width and a match under it is not "in sight";
a cloud-only PDF's thumbnails are asked for again once it is downloaded; refusals say what to do
next. All in Edit's PDF reader and the pane PDF Tools, which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfTools=%s paneTools=%s pdfRail=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFTools.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PanePDFTools.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFRail.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-19, against origin, before this landed:
# main  pdfTools=1 paneTools=1 pdfRail=1
# v5.x, v4.x, v3.x, v2.x — 0 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No PDF reader in Edit and no pane PDF Tools, so nothing to fix | CLOSED — does not apply |

---

## Fill & Sign's palette and save pill, from their review — main only

A reload that newly refuses the file drops what was placed and says so; a floating piece finds the
gap beside one piece and under another; the save pill sheds its words before it overflows; the
find card fits the narrowest column; flyouts at the right-hand corners open leftwards; a palette
that goes mid-drag takes the drag with it; an empty text box is not lost work. All in Fill & Sign,
which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s fillSign=%s fillPalette=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSign.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillPalette.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-19, against origin, before this landed:
# main  fillSign=1 fillPalette=1
# v5.x, v4.x, v3.x, v2.x — 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No Fill & Sign, so nothing to fix | CLOSED — does not apply |

---

## Signature Styles: faces, inks, pens and fonts in Fill & Sign — main only

A typed signature or initials takes one of seven of the Mac's handwriting faces, a drawn one a Fine,
Medium or Bold pen with its wobble smoothed, and placed text a Sans, Serif, Rounded, Mono or
Handwritten font; the palette's new Aa tool and an item's right-click menu restyle what is placed,
and a saved signature restyled changes in the store too. The Add Signature sheet chooses the ink,
on a pad that stays paper-white, and can make initials with the signature. Saved signatures keep
their `editorPDFSavedSignatures` key, read as Snell Roundhand and Medium; the sheet's last face, pen
and smoothing sit under `editorPDFSignatureFace`, `editorPDFSignaturePen` and
`editorPDFSignatureSmoothing`. pdf-toolkit moves to 0.3.0 for `FillSignText.font`. All of it
extends the Fill & Sign `main` alone has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s fillSign=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSign.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-19, against origin, before this landed:
# main  fillSign=1
# v5.x, v4.x, v3.x, v2.x — fillSign=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No Fill & Sign in Edit (`fillSign=0`), so nothing to restyle | CLOSED — does not apply |

---

## The PDF reader's whole-product review, 1a to 6b — main only

A run re-checks its file in its own lane turn, and Clean Metadata no longer downloads an evicted
file; Select All takes the page on screen; ⌘G scrolls a match out from under the palette; Reset All
Settings reaches the open reader and saved signatures; batches take back a copy cancelled mid-write
and name what failed; a restricted file's refusal names the menu SyncCloud has; a form's widgets are
locked without a catalog `/AcroForm`; the pages' right-click menu loses PDFKit's view controls; and
smaller Fill & Sign and wording fixes. All in Edit's PDF reader, Fill & Sign and the pane PDF Tools,
which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s pdfReader=%s pdfTools=%s paneTools=%s fillSign=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFPageView.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFTools.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PanePDFTools.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSign.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-20, against origin, before this landed:
# main  pdfReader=1 pdfTools=1 paneTools=1 fillSign=1
# v5.x, v4.x, v3.x, v2.x — 0 0 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No PDF reader in Edit, no Fill & Sign and no pane PDF Tools, so nothing to fix | CLOSED — does not apply |

---

## Edit's lit controls fill with the deepened accent — main only

Edit filled its lit controls with the raw accent under a white label — 2.66:1 measured on Green
against the 4.5:1 the rest of the app keeps with `LiquidGlassHue.accentFillColor`. The mode
capsule, the rail's tabs, the Autosave switch, the PDF header's lit actions, Fill & Sign's lit tool,
Save Filled Copy, Save Reordered Copy and the PDF tool sheets' default button now take the deepened
fill; the Body menu's hovered style deepens the system accent; Fill & Sign's rings and field washes
take the app's accent instead of `controlAccentColor`. `EditAccentFillScanTests` (Design; now
`AccentFillScanTests`, app-wide) keeps the raw accent out of Edit's fills.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  f=Modules/FileExplorer/Sources/FileExplorer; raw=0
  for x in EditorMode.swift EditorRailTab.swift EditorWorkspaceView.swift; do
    c=$(git show origin/$l:$f/$x 2>/dev/null | grep -cE 'fill\(accent\)|color: accent\)|AnyShapeStyle\(accent\) : AnyShapeStyle\(\.quaternary')
    raw=$((raw + ${c:-0}))
  done
  printf '%-5s editMode=%s rawFills=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- $f/EditorMode.swift | wc -l | tr -d ' ')" "$raw"
done
# measured 2026-10-20, against origin, before this landed:
# main  editMode=1 rawFills=5
# v5.x  editMode=1 rawFills=5
# v4.x, v3.x, v2.x — editMode=0 rawFills=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The mode capsule, rail tabs and Autosave switch on the raw accent (`rawFills=5`); `AccentFill` is there to take | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace (`editMode=0`), so nothing to fill | CLOSED — does not apply |

---

## Fill & Sign by keyboard alone and with VoiceOver — main only

File ▸ Fill & Sign Tool holds the palette's tools; with one chosen, Return places its item in the
middle of the page on screen; Tab walks a form's fields, then what is placed; the overlay is a
VoiceOver group of each field's widget and each placed item, with values, presses and actions;
saved drawn signatures are named by number and pen; deleting one asks first; Add Signature opens on
Type. All in Edit's Fill & Sign, which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s fillSign=%s overlay=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSign.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillOverlay.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-20, against origin, before this landed:
# main  fillSign=1 overlay=1
# v5.x, v4.x, v3.x, v2.x — 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No Fill & Sign in Edit (`fillSign=0`), so nothing to reach by keyboard | CLOSED — does not apply |

---

## Cover and Retype: Replace in Fill & Sign — main only

Fill & Sign's palette gains Replace (TE82–TE87): a click picks the line of words under the pointer,
or a drag the words across, and a right-click on selected words offers Replace Text…. A retype box
opens over them in their size, ink and — read off the page's content stream, not PDFKit — their
own face when the Mac has it; Save Corrected Copy draws the new words over a patch the colour of
the page, "(corrected)" beside the original, and the note card offers to make a corrected page a
picture through the toolkit's redaction. Replace is off on a PDF with a fillable form (decision AV).
pdf-toolkit moves to 0.4.0 for the patch item (`FillSignItem.Content.patch`). All of it extends the
Fill & Sign `main` alone has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s fillSign=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSign.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-20, against origin, before this landed:
# main  fillSign=1
# v5.x, v4.x, v3.x, v2.x — fillSign=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No Fill & Sign in Edit (`fillSign=0`), so nothing to add Replace to | CLOSED — does not apply |

---

## Filled buttons and Storage's switcher follow the app accent — main only

Outside Edit, 21 `.borderedProminent` buttons (Organize's runs, Duplicates' merges, Automations,
the lens setup cards, the Person and Rule editors' Save, empty states…) painted the SYSTEM accent,
and Compare Copies' and Differences' Keep tinted with the raw accent under a white label (2.66:1 on
Green). Every prominent button, and Edit's PDF tool sheets, now take `.accentedProminent(…)`
(`ProminentAccent.swift`): the deepened fill (4.57:1 on Green, read back light and dark), and the
untouched system accent at None. Storage's section switcher filled with the raw accent; it takes
`accentFillColor`. `AccentFillScanTests` (Design) scans the whole app.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  f=Modules/FileExplorer/Sources/FileExplorer/StorageLensView.swift; prom=0
  bar=$(git show origin/$l:$f 2>/dev/null | grep -A1 'StorageSectionBar(section: \$section' | grep -c 'accent: glassHue.accentColor')
  for x in $(git ls-tree -r --name-only origin/$l -- MacApp Modules | grep '\.swift$' | grep -v /Tests/); do
    c=$(git show origin/$l:$x | grep -c '\.buttonStyle(.borderedProminent)'); prom=$((prom + c))
  done
  printf '%-5s storageBarRaw=%s prominent=%s seam=%s\n' "$l" "$bar" "$prom" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/Design/Sources/Design/ProminentAccent.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-20, against origin, before this landed:
# main  storageBarRaw=1 prominent=25 seam=0
# v5.x  storageBarRaw=1 prominent=23 seam=0
# v4.x  storageBarRaw=0 prominent=25 seam=0
# v3.x  storageBarRaw=0 prominent=22 seam=0
# v2.x  storageBarRaw=0 prominent=21 seam=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Storage's switcher on the raw accent, and 23 prominent buttons on the system accent or the raw one | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Storage switcher; 21–25 prominent buttons on the system accent or the raw one | RECORDED — not owed |

---

## The person verdict, the Go-to row and Swipe's divider follow the app accent — main only

Two fills the prominent-button pass left: a person's "<Name>’s" answer and the Go-to palette's
selected row filled with the raw accent and picked their label with `Color.onFillLabel`, which on
light hues drew black-on-Green beside every white-on-deepened-Green control. Both now fill with the
deepened accent (`AccentFill.deepened`, i.e. `accentFillColor`) under a white label, read back light
and dark on Green. Compare Copies' Swipe divider and Difference's region outlines drew the SYSTEM
accent; `VisualPairModeView` is handed the app's. `AccentFillScanTests` no longer exempts a fill
paired with `onFillLabel`.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  f=Modules/FileExplorer/Sources/FileExplorer
  pv=$(git show origin/$l:$f/PersonView.swift 2>/dev/null | grep -c 'Capsule().fill(accent))'); pv=${pv:-0}
  pal=$(git show origin/$l:$f/PaletteResultsList.swift 2>/dev/null | grep -cE '^\s*\.fill\(accent\)$'); pal=${pal:-0}
  sw=$(git show origin/$l:$f/VisualPairModes.swift 2>/dev/null | grep -c 'Color.accentColor'); sw=${sw:-0}
  printf '%-5s personRaw=%s paletteRaw=%s swipeSystem=%s swipeFile=%s\n' "$l" "$pv" "$pal" "$sw" \
    "$(git ls-tree -r --name-only origin/$l -- $f/VisualPairModes.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-21, against origin, before this landed:
# main  personRaw=1 paletteRaw=1 swipeSystem=2 swipeFile=1
# v5.x  personRaw=1 paletteRaw=1 swipeSystem=2 swipeFile=1
# v4.x  personRaw=1 paletteRaw=1 swipeSystem=0 swipeFile=0
# v3.x, v2.x — all 0 (no person view, no Go-to list, no Swipe)
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Both raw-accent fills with flipping labels, and Swipe/Difference on the system accent | RECORDED — not owed |
| `v4.x` | Both raw-accent fills with flipping labels; no Swipe mode | RECORDED — not owed |
| `v3.x` / `v2.x` | None of the three surfaces | CLOSED — does not apply |

---

## Nothing draws SwiftUI's system accent — main only

`Color.accentColor` is the SYSTEM accent, so every view still drawing it ignored the hue picked in
Settings: Settings' size tiles (words, wash, border, bars), the text-size slider's detent labels,
Help (the open topic's fill, the article's eyebrow, tip and accent legend — C7 had left it on the
system accent), the document survey strip's wash, the setup sheet's swatch ring (now Settings'
neutral ring), and a neutral provider's name, documented as following the app accent. Untinted
`hoverAffordance`, `chromeHover`, `HoverChevron`, `chromeGlassGlyphButton` and `TextSizeStepper`
now read the stored hue where they are drawn (`StoredHueReader`); colour defaults that every caller
already overrides fall back to `LiquidGlassHue.stored()`. `AccentFillScanTests` rule 4 bans
`Color.accentColor` in app sources outside a named exemption list (`LiquidGlassHue.none`).

```sh
for l in main v5.x v4.x v3.x v2.x; do
  n=$(git grep -hE '(^|[^A-Za-z0-9_])Color\.accentColor|(^|[^]A-Za-z0-9_)?!])\.accentColor([^A-Za-z0-9_]|$)' \
      origin/$l -- 'MacApp/*.swift' 'Modules/*/Sources/*.swift' | grep -vE '^\s*//' | wc -l | tr -d ' ')
  printf '%-5s systemAccentLines=%s\n' "$l" "$n"
done
# measured 2026-10-21, against origin, before this landed (1 after: LiquidGlassHue.none):
# main  systemAccentLines=38
# v5.x  systemAccentLines=34
# v4.x  systemAccentLines=26
# v3.x  systemAccentLines=14
# v2.x  systemAccentLines=12
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | System-accent words, washes and defaults beside the app's hue, fewer the older the line | RECORDED — not owed |

## Nothing draws an unset `.tint` — main only

ShapeStyle `.tint` with no `.tint(…)` above it is the same SYSTEM accent, and nothing above the
guided setup set one, so its words and glyphs stayed the Mac's blue on a Coral sheet: the welcome
card's numbers, the tour pages' lit marks, the Why panels' examples, ticked and `+` chips, the
Learn, Workspaces and Summary glyphs, and the Structure tree's root folder. Each now names the hue's
raw accent (`SetupIllustration` and `SetupChip` are handed it). No root `.tint` was added, so the
setup sheet's switches stay as Settings' do. The compare-pick badge and the review table's
"Reviewing" marker, which relied on a `List`/`Table` row host passing a tint down, are handed the
accent too. `AccentFillScanTests` rule 5 bans the ShapeStyle `.tint` in app sources, with no
exemptions.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  n=$(git grep -hE '(^|[^]A-Za-z0-9_)?!])\.tint([^A-Za-z0-9_(]|$)|TintShapeStyle' \
      origin/$l -- 'MacApp/*.swift' 'Modules/*/Sources/*.swift' | grep -vE '^\s*//' | wc -l | tr -d ' ')
  printf '%-5s tintStyleLines=%s\n' "$l" "$n"
done
# measured 2026-10-21, against origin, before this landed (0 after):
# main  tintStyleLines=22
# v5.x  tintStyleLines=23
# v4.x  tintStyleLines=16
# v3.x  tintStyleLines=5
# v2.x  tintStyleLines=5
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | Words and art on `.tint` — the setup's or the first-run tour's, the review marker, and on `v5.x`/`v4.x` more besides; whether a root tints them there is not checked | RECORDED — not owed |

## Typewriter scrolling in Source (TE62) — main only

**Text ▸ Typewriter Scrolling** (`editorTypewriterScrolling`, off by default) holds Source's caret
line at mid-height. `EditorTextView.scrollRangeToVisible(_:)` centres a bare caret — no marked text,
not from the mouse, not while Split's Preview leads a follow — and hands every other range to
AppKit; Source's clip is now `EditorDocumentClipView`, whose bounds may run half a screen past the
end of the text while on and are AppKit's in every bound while off. Edit in Preview is unchanged. A
new feature, not a fix.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s textView=%s typewriter=%s\n' $l \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorTextView.swift | wc -l | tr -d ' ')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorTextSettings.swift 2>/dev/null | grep -c typewriterScrollingKey)"
done
# measured 2026-10-21, against origin, before this landed:
# main  textView=1 typewriter=0
# v5.x  textView=1 typewriter=0
# v4.x, v3.x, v2.x  textView=0 typewriter=0
```

**Every maintenance line: checked — not owed.** A new switch, not a defect; `v4.x` and older have
no `EditorTextView` to carry it.

---

## Edit's recent files and New Note — main only

With nothing open, Edit's page lists the last ten files Edit opened, text and PDF (TE58), with a New
Note button running `⌘N`'s closure; File ▸ Open Recent holds the same list, with Clear Menu. One
record in `ContentView.loadIntoEditor` (`EditorOpenRoute.recordOpen`) feeds a new store,
`EditorRecentFiles`, under the new key `editorRecentFiles` — 20 kept, 10 shown, missing files hidden
but kept, unreadable bytes kept under `editorRecentFiles.unreadable`. A new feature, so `main` alone
by rule. The key is additive: a maintenance build sharing the defaults domain ignores it.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s workspace=%s recents=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorWorkspaceView.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorRecentFiles.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-21, against origin, before this landed:
# main, v5.x       — workspace=1 recents=0
# v4.x, v3.x, v2.x — workspace=0 recents=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Edit's empty page as one sentence; no recent files | RECORDED — not owed (new feature) |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace (`workspace=0`) | CLOSED — does not apply |

---

## Search inside files: the Files list filter's Contents side (RD38) — main only

Edit's Files list filter gains **Names | Contents**. Contents reads the text files in the folder and
the folders inside it (`EditorContentSearch`, skipping files not downloaded by one `lstat`) and asks
Spotlight which PDFs, Word and PowerPoint files contain the word (`EditorContentSpotlight`); a result
opens at the match with Find holding the word. A new feature, so `main` only.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s railFilter=%s contentSearch=%s\n' "$l" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorFileRailView.swift 2>/dev/null | grep -c 'Filter by name')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorContentSearch.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-21, against origin, before this landed:
# main  railFilter=1 contentSearch=0
# v5.x  railFilter=1 contentSearch=0
# v4.x, v3.x, v2.x — 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The rail's name filter, and no search inside files | RECORDED — not owed (main only) |
| `v4.x` / `v3.x` / `v2.x` | No rail filter in Edit | CLOSED — does not apply |

---

## Help counts four standard places, not five — main only

Help's sidebar article said Restore Standard Places brings back "the five it starts with". There
are four — home, Desktop, Documents and Downloads (`SidebarFavoritePlaces.standard`) — since the
startup disk went back to Locations on 2026-09-07. `HelpBookTests.restoreStandardPlacesCountsTheStandardSet`
now counts them. The same commit's other Help and setup fixes describe v6.0 features only.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s five=%s\n' $l \
  "$(git show origin/$l:MacApp/HelpBook.swift 2>/dev/null | grep -c 'brings the five it starts with')"; done
# measured 2026-10-21, against origin, before this landed:
# main 1 · v5.x 1 · v4.x 1 · v3.x 0 · v2.x 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` | "the five it starts with" over a four-place standard set | RECORDED — not owed |
| `v3.x` / `v2.x` | No Restore Standard Places sentence | CLOSED — does not apply |

---

## Edit's lists and keys: ten small fixes (TE153–157, TE179–183) — main only

With Edit's file pane folded, ⌘X, ⌘C, ⌘V and ⌘A beep outside the text and the PDF instead of acting
on the hidden pane (`EditorFoldedPaneKeys`); ⌘A in the Pages grid still selects every page, and ⌘C
in Preview copies its selected words (`TextEditingChord.selectionCopier`). Esc in the Files,
Outline and Pages lists gives the keys back to the document, and Space Quick Looks the Files list's
row. The list's fold words say "Hide the file list"; the header name has a tooltip; the outline
follows the reader; the status line's Show Outline in File List works from any layout; a
double-click puts Split's divider back in the middle; an image import says what it saved; the
folder menu's overflow is a Show All button.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s folded=%s outlineInRail=%s statusRule=%s split=%s imageImport=%s railKeys=%s folderMenu=%s\n' $l \
    "$(git show origin/$l:MacApp/ContentView.swift 2>/dev/null | grep -c 'var editorPaneIsFolded')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorFileRailView.swift 2>/dev/null | grep -c 'scrollPosition(id:')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorStatusLine.swift 2>/dev/null | grep -c 'showsRail && railTab != .outline')" \
    "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorWorkspaceView.swift 2>/dev/null | grep -c 'private func splitHandle')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorImageImport.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorRailKeyboard.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorRailFolderMenu.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-22, against origin, before this landed:
# main  folded=1 outlineInRail=0 statusRule=1 split=1 imageImport=1 railKeys=1 folderMenu=1
# v5.x  folded=1 outlineInRail=2 statusRule=1 split=1 imageImport=1 railKeys=0 folderMenu=0
# v4.x, v3.x, v2.x — all 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | TE153 (the folded pane's clipboard keys, Preview's ⌘C), TE157, TE179 (its outline is inside the rail view), TE180, TE181, TE182 | RECORDED — not owed |
| `v5.x` | No list keys, strip or folder menu, so not TE154, TE155, TE156 or TE183 | CLOSED — does not apply |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace | CLOSED — does not apply |

---

## Fill & Sign small fixes: signing by keyboard, copy names, dates — main only

Signature fields join Tab's ring and sign on Space, Return or a VoiceOver press (TE164); the pill's
tooltip names its own button (TE165); the leave question counts as the pill does, with Save, Don't
Save and Cancel (TE166); the refusals offer Remove Password… (TE167); the palette's tooltips say
Return places (TE168); the typing box is drawn light (TE189); a copy of a copy is "Lease (signed)
2.pdf", not "(signed) (signed)" (TE190); the saved banner says when the copy leaves something out
(TE191); a placed date has a four-digit year (TE192); the Draw pad has Undo Stroke (TE193). All in
Edit's PDF tools and Fill & Sign, which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s fillSign=%s engine=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSign.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFToolEngine.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-22, against origin, before this landed:
# main  fillSign=1 engine=1
# v5.x, v4.x, v3.x, v2.x — 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No Fill & Sign or PDF tools in Edit (`fillSign=0`, `engine=0`) | CLOSED — does not apply |

---

## ⌘S on an unchanged document writes nothing (TE145) — main only

⌘S rewrote a clean file, giving it a new date and a sync client a reason to upload it again.
`saveEditorDocument` now returns after the divergence check when the buffer matches the file and no
autosave stop stands (`ContentView.saveHasNothingToWrite`); Save stays enabled.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s save=%s skip=%s\n' $l \
  "$(git show origin/$l:MacApp/ContentView+Editor.swift 2>/dev/null | grep -c 'func saveEditorDocument')" \
  "$(git show origin/$l:MacApp/ContentView+Editor.swift 2>/dev/null | grep -c 'saveHasNothingToWrite')"; done
# measured 2026-10-22, against origin, before this landed:
# main  save=1 skip=0
# v5.x  save=1 skip=0
# v4.x, v3.x, v2.x  save=0 skip=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | ⌘S rewrites a clean file | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace | CLOSED — does not apply |

---

## A deleted file's text is asked about on leaving (TE146) — main only

With the open file deleted and nothing typed, autosave had nothing to write, so Close, opening
another file, ⌘N and ⌘Q dropped the text on screen without a word, though it may have been the only
copy. `settleEditorDocument` and `applicationShouldTerminate` now ask (`EditorDiskWatch.mayBeTheOnlyCopy`);
Save is Save Again. A file in the Trash and still there is not asked about (decision BQ): the watch
notes where it went at the first look that sees it go. The same commit words every unsaved-changes
question "Save your changes to “x”?" with one cause line (TE148) and marks Don't Save destructive
(TE176).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s deletedBanner=%s onlyCopy=%s\n' $l \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorDiskWatch.swift 2>/dev/null | grep -c 'case deleted')" \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorDiskWatch.swift 2>/dev/null | grep -c 'mayBeTheOnlyCopy')"; done
# measured 2026-10-22, against origin, before this landed:
# main  deletedBanner=2 onlyCopy=0
# v5.x  deletedBanner=2 onlyCopy=0
# v4.x, v3.x, v2.x — no EditorDiskWatch
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Leaving a deleted file with nothing typed drops its text unasked | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No disk watch in Edit | CLOSED — does not apply |

---

## A save that couldn't be checked is checked again (TE147) — main only

A write that landed but whose read-back failed left the document with the old stamp, so the next
look raised "changed on disk while you were typing" about Edit's own save, and ⌘S asked which
version wins. The document now remembers the text such a write put on disk
(`EditorDocument.uncheckedWrite`); the disk watch, leaving and the quit check count a file holding
it as saved (`EditorFileStore.settleUncheckedWrite`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s unchecked=%s\n' $l \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorAutosave.swift 2>/dev/null | grep -c 'case savedUnchecked')"; done
# measured 2026-10-22, against origin, before this landed:
# main 1 · v5.x 0 · v4.x 0 · v3.x 0 · v2.x 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No "saved, but couldn't check" state (TE114 is `main` only) | CLOSED — does not apply |

---

## PDF reader small fixes: questions, words, find, bookmarks — main only

The PDF leave and quit questions, and Delete Saved Signature, take Esc and not Return (TE184,
TE203, decision BS); ⌘Q's says Quit (TE158); the find card and its neighbours slide (TE159); Unlock
says "Unlocking…" and tells a file that changed from a wrong password (TE160); the spinners say
"Reading the PDF…" (TE161, TE188); Clean Metadata says what a form PDF's copy keeps (TE162); find
treats a hyphen at a line end as optional (TE163); a cloud-only file offers Download (TE185); the
toolkit's refusals are in Edit's words (TE186); a bookmark goes to its place (TE187); ⌘E with nothing
selected beeps (TE204). All in Edit's PDF reader, which only `main` has.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s reader=%s paneTools=%s\n' "$l" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift | wc -l | tr -d ' ')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/PanePDFTools.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-22, against origin, before this landed:
# main  reader=1 paneTools=1
# v5.x, v4.x, v3.x, v2.x — 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No PDF reader or PDF tools in Edit (`reader=0`, `paneTools=0`) | CLOSED — does not apply |

---

## A tool's copy keeps page labels, viewer settings, language and attachments (TE201, TE202) — main only

Extract, Delete Pages, Compress, Remove Password, Clean Metadata, Fill & Sign without a form and a
saved page order wrote copies without the file's page labels, layout and opening view, language
and attached files. pdf-toolkit 0.5.0 carries them; each page keeps its own label. The sheets, the
reorder bar and Fill & Sign's note card name the tags, layers and colour output intent that still
go (`EditorPDFTools.droppedPartsNote`). Edit's PDF tools, and pdf-toolkit, are `main` only.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s toolkit=%s engine=%s\n' "$l" \
    "$(git show origin/$l:Modules/FileExplorer/Package.swift 2>/dev/null | grep -c 'pdf-toolkit')" \
    "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorPDFToolEngine.swift | wc -l | tr -d ' ')"
done
# measured 2026-10-22, against origin, before this landed:
# main  toolkit=4 engine=1
# v5.x, v4.x, v3.x, v2.x — 0 0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No pdf-toolkit and no PDF tools in Edit (`toolkit=0`, `engine=0`) | CLOSED — does not apply |

---

## View ▸ Preview is now View ▸ File Preview (TE170) — main only

The second rename of this item: it was View ▸ Preview Column until the preview followed the pane
into Tree mode (2026-09-09, the row above that says "not owed"). In Edit, with the file pane open
and a Markdown file showing, View ▸ Preview (⇧⌘P, the preview beside a pane's list) and Text ▸
Preview (⌃⌘2, the rendered document) were both live, under one name. The View item is now File
Preview, as the keyboard reference already called it. The pane bar's Preview button keeps its name.

```sh
for l in main v5.x v4.x v3.x v2.x; do
  printf '%-5s item=%s text=%s\n' "$l" \
    "$(git show origin/$l:MacApp/ShortcutCommands.swift 2>/dev/null | grep -A5 'struct TogglePreviewColumnCommand' | grep -o 'Toggle("[^"]*"' || echo none)" \
    "$(git show origin/$l:MacApp/ShortcutCommands.swift 2>/dev/null | grep -c 'struct EditorMenus')"
done
# measured 2026-10-22, against origin, before this landed:
# main  item=Toggle("Preview" text=1
# v5.x  item=Toggle("Preview" text=1
# v4.x  item=Toggle("Preview Column" text=0
# v3.x  item=none text=0
# v2.x  item=none text=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Both items named Preview, live together in Edit (`item=Toggle("Preview"`, `text=1`) | RECORDED — not owed. A one-word pick, plus Help's "⇧⌘P" sentence |
| `v4.x` | Preview Column, and no Text menu to clash with (`text=0`) | CLOSED — does not apply |
| `v3.x` / `v2.x` | No View menu item for the preview (`item=none`) | CLOSED — does not apply |

---

## Tooltips on every icon-only control, shown after 300 ms — main only

An audit found about half of the app's hoverable controls had no tooltip, six of them icon-only
(the Help and destination-picker clear ✕, the banner ✕, a Setup chip's ✕, the text diff's ▲▼, a
Differences section chevron), and every tooltip waited AppKit's 1.5 s. `main` registers
`NSInitialToolTipDelay` = 300 at launch (`ToolTipDelay`), adds tooltips across Setup, Settings,
Dashboard, Edit, PDF and the lenses, lets `EmptyStateView.Action` carry one, and scans for a glyph
button without one (`TooltipScanTests`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s delay=%s helpClear=%s bannerClose=%s\n' $l \
  "$(git show origin/$l:MacApp/SyncCloudApp.swift 2>/dev/null | grep -c 'NSInitialToolTipDelay')" \
  "$(git show origin/$l:MacApp/HelpBook.swift 2>/dev/null | grep -c 'xmark.circle.fill')" \
  "$(git show origin/$l:MacApp/OperationBannerView.swift 2>/dev/null | grep -c 'CloseButton')"; done
# measured 2026-10-22, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x  delay=0 helpClear=1 bannerClose=1
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | 1.5 s tooltip delay; the Help clear ✕ and banner ✕ with no tooltip. The other surfaces differ per line and were not checked one by one | RECORDED — not owed |

---

## The survey card's Resume now and Start over do what they say — main only

On the document survey's card, *Resume now* during an automatic pause (another scan, a file copy,
heat, Low Power Mode) cleared only the person's own Pause, so the survey stayed paused until the
cause cleared by itself; *Start over* on the interrupted card ran the start path, which adopts the
saved progress, so it resumed. `main` reads through every cause in force at the click until it
clears (`DocumentSurveyOverride`), and asks before *Start over*, then discards the progress
(`runDocumentSurvey(plan:startingOver:)`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s survey=%s startOverRunsOnStart=%s override=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/DocumentSurveyRun.swift 2>/dev/null | grep -c 'actor DocumentSurveyRun')" \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DocumentSurveyCard.swift 2>/dev/null | grep -c 'title: "Start over", run: onStart')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/DocumentSurveyYield.swift 2>/dev/null | grep -c 'struct DocumentSurveyOverride')"; done
# measured 2026-10-22, against origin, before this landed:
# main, v5.x         survey=1 startOverRunsOnStart=1 override=0
# v4.x, v3.x, v2.x   survey=0 startOverRunsOnStart=0 override=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Both dead buttons, the same code (`startOverRunsOnStart=1`, `override=0`) | RECORDED — owed |
| `v4.x` / `v3.x` / `v2.x` | No document survey (`survey=0`) | CLOSED — does not apply |

---

## The interrupted survey strip offers no dead Stop — main only

With a survey interrupted (progress on disk, nothing running), the reading strip on every Organize
lens offered *Stop*, which stops the run in flight — there is none, so it did nothing. The card in
the same state offers Resume and Start over. `main` drops it and holds the strip to the card's
verbs (`everyVerbIsOneTheCardOffers`); *Start over* stays on the card.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s strip=%s interruptedStop=%s\n' $l \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DocumentSurveyStrip.swift 2>/dev/null | grep -c 'struct DocumentSurveyStrip')" \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DocumentSurveyStrip.swift 2>/dev/null | grep -A6 'case .interrupted:' | grep -c '"Stop"')"; done
# measured 2026-10-22, against origin, before this landed:
# main, v5.x         strip=1 interruptedStop=1
# v4.x, v3.x, v2.x   strip=0 interruptedStop=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The dead Stop, the same code (`interruptedStop=1`) | RECORDED — owed |
| `v4.x` / `v3.x` / `v2.x` | No document survey strip (`strip=0`) | CLOSED — does not apply |

---

## Edit's folder menu lists a folder that is a link (TE205) — main only

The Files list's folder menu left out a link to a folder, which the file pane shows as a folder: the
survey kept only `hasDirectoryPath` entries, and a link lists with it false. `main` follows each
link the listing names (`DirectoryListing.symbolicLinkPaths`, read off the enumerator's prefetched
answer, so a plain entry costs no `stat`) and lists it when a folder is at the end.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s folderMenu=%s linkPaths=%s\n' $l \
  "$(git ls-tree -r --name-only origin/$l -- Modules/FileExplorer/Sources/FileExplorer/EditorRailFolderMenu.swift | wc -l | tr -d ' ')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/DirectoryListing.swift 2>/dev/null | grep -c 'symbolicLinkPaths')"; done
# measured 2026-10-22, against origin, before this landed:
# main               folderMenu=1 linkPaths=0
# v5.x, v4.x, v3.x, v2.x   folderMenu=0 linkPaths=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No folder menu (`folderMenu=0`) | CLOSED — does not apply |

---

## Every door asks about the file a link points to (TE206) — main only

The cloud-only check and Edit's 4.2 MB cap asked about a symlink itself, which is always local and
tiny. So opening or previewing a link to a cloud-only file downloaded it unasked, a link to a large
text file got past the cap, and selecting a link to a cloud-only PDF downloaded it, on the main
thread, to probe its protection for PDF Tools. `main` asks every door about the link's target
(`MaterializationStatus.linkTarget(of:)`). The pane preview's probe is on every line; Edit's text
reads, the Files tab, Markdown images and the Finder hand-off's fetch are on `main` and `v5.x`;
Edit's PDF reader and the PDF tools are `main` only.

```sh
F=Modules/FileExplorer/Sources/FileExplorer
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s preview=%s textRead=%s fetch=%s pdfReader=%s linkTarget=%s\n' $l \
  "$(git show origin/$l:$F/ColumnPreviewColumn.swift 2>/dev/null | grep -c 'isCloudOnly: MaterializationStatus.isCloudOnly(atPath: path)')" \
  "$(git show origin/$l:$F/BoundedTextRead.swift 2>/dev/null | grep -c 'if isCloudOnly(path) { return .cloudOnly }')" \
  "$(git show origin/$l:MacApp/ExternalOpen.swift 2>/dev/null | grep -c 'answer.give(isCloudOnly(path) == false)')" \
  "$(git ls-tree -r --name-only origin/$l -- $F/EditorPDFDocument.swift | wc -l | tr -d ' ')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/MaterializationStatus.swift 2>/dev/null | grep -c 'func linkTarget')"; done
# measured 2026-10-22, against origin, before this landed:
# main  preview=1 textRead=1 fetch=1 pdfReader=1 linkTarget=0
# v5.x  preview=1 textRead=1 fetch=1 pdfReader=0 linkTarget=0
# v4.x, v3.x, v2.x   preview=1 textRead=0 fetch=0 pdfReader=0 linkTarget=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The preview, Edit's text, Files tab, Markdown image and hand-off doors (`preview=1`, `textRead=1`, `fetch=1`); no PDF reader | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | The pane preview's door alone (`preview=1`, `textRead=0`) | RECORDED — not owed |

---

## Setup draws a reading that lands on Structure, and asks before removing a person — main only

Two Setup defects from the v6.1 review (ST2, ST5). Continue never waits for the reading, and only
arriving at Structure rebuilt its preview, so a reading that landed while Structure was on screen
left "Save and start reading" over "Nothing has been learned yet." `main` rebuilds the preview when
the reading lands. And on a re-run the People screen's ✕ deleted a roster person from
`people.json` — with the full names and aliases curated in Settings — in one click, where Settings
asks first; `main` asks Settings' own question (`PersonRemoval`), except for a name added in the
same run.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s setupModel=%s rebuilds=%s rosterAsks=%s oldSheetRemove=%s\n' $l \
  "$(git ls-tree -r --name-only origin/$l -- MacApp/Setup/SetupModel.swift | wc -l | tr -d ' ')" \
  "$(git show origin/$l:MacApp/Setup/SetupModel.swift 2>/dev/null | grep -c 'rebuildPreview()')" \
  "$(git show origin/$l:MacApp/Setup/SetupModel.swift 2>/dev/null | grep -c 'func requestRemovePerson')" \
  "$(git show origin/$l:MacApp/SetupSheet.swift 2>/dev/null | grep -c 'store.remove(id: person.id)')"; done
# measured 2026-10-23, against origin, after this landed (rosterAsks is the fix's own question):
# main         setupModel=1 rebuilds=4 rosterAsks=1 oldSheetRemove=0
# v5.x         setupModel=1 rebuilds=3 rosterAsks=0 oldSheetRemove=0
# v4.x         setupModel=0 rebuilds=0 rosterAsks=0 oldSheetRemove=1
# v3.x, v2.x   setupModel=0 rebuilds=0 rosterAsks=0 oldSheetRemove=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Both, the same code (`rebuilds=3`, `rosterAsks=0`) | RECORDED — not owed |
| `v4.x` | The one-click removal, in the older sheet (`oldSheetRemove=1`); no walk to land | RECORDED — not owed |
| `v3.x` / `v2.x` | No guided People screen with a roster | CLOSED — does not apply |

---

## Organize asks before undoing a reorganisation, keeps a closed plan, and can show hidden findings again — main only

Three Organize defects from the v6.1 review (LN1, LN2, LN3).

- **Undo this reorganisation** ran a landing's stored inverse — which can move hundreds of files and
  can't be redone — on one click of a text link or the Organize menu item, and a success said
  nothing. `main` routes both through `ReorganisationUndo.run`, which asks (`confirmChange`, naming
  what the landing did) and posts a banner on every outcome.
- **Keep separate** (Duplicates) and **Never suggest this again** (Restructure) hid a group or a
  finding for good, with no undo and nothing listing what was hidden. `main` registers one ⌘Z step
  with an undoable banner for each, and both lenses show "N … hidden · Show Them Again".
- **Closing the plan sheet** threw a hand-built mapping away: only Export saved the draft, against
  ROADMAP §5.4's "when the sheet closes with a plan". `main` keeps a changed plan as a draft on close.

```sh
F=Modules/FileExplorer/Sources/FileExplorer
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s undoReorg=%s neverSuggest=%s planSheet=%s keepSeparate=%s\n' $l \
  "$(git show origin/$l:$F/RestructureLens.swift 2>/dev/null | grep -c 'Button("Undo this reorganisation")')" \
  "$(git show origin/$l:$F/RestructureLens.swift 2>/dev/null | grep -c 'Never suggest this again')" \
  "$(git ls-tree -r --name-only origin/$l -- $F/RestructurePlanSheet.swift | wc -l | tr -d ' ')" \
  "$(git grep -c 'func keepDuplicateGroupSeparate' origin/$l -- Modules | wc -l | tr -d ' ')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         undoReorg=1 neverSuggest=2 planSheet=1 keepSeparate=1
# v4.x, v3.x, v2.x   undoReorg=0 neverSuggest=0 planSheet=0 keepSeparate=1
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | All three, the same code | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | Keep separate's one-way hide alone (`keepSeparate=1`); no Restructure | RECORDED — not owed |

---

## Duplicates no longer treats a skipped `.git` as absent (FR11) — main only

The finder skips `.git`, `node_modules` and `.build` while walking, and left them out of a folder's
identity too, so a repository and a ZIP of its working tree were "identical" and Apply recommended
could trash the repository. `main` keeps skipping them but lets them reach the parent as an entry
of unknown identity: such a folder is never asserted identical and never folded away as an
overlapping copy. OS noise (`ItemIdentity.deepIdentityIgnoredNames`) is still dropped outright.

```sh
S=Modules/Sync/Sources/Sync
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s skipAbsent=%s tooling=%s\n' $l \
  "$(git show origin/$l:$S/DuplicateFinder.swift 2>/dev/null | grep -cF 'if options.ignoredNames.contains(node.name) { return nil }')" \
  "$(git show origin/$l:$S/DuplicateFinder.swift 2>/dev/null | grep -cF '".git", ".build", "node_modules"')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   skipAbsent=1 tooling=1
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same skip, the same code (`skipAbsent=1`) | RECORDED — not owed |

---

## No folder group removes the folder holding another group's keeper (FR10) — main only

One Apply recommended acts on every group at once, and identical folder groups covered only their
REDUNDANT copies, so a later group could trash the folder that held an earlier group's keeper — or
a piece of it — and one batch could send every copy to the Trash. `main` treats a member that holds,
or sits inside, an earlier keeper as protected: it may be the keeper, never a copy to remove.

```sh
S=Modules/Sync/Sources/Sync
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s coverOnly=%s keeperRoots=%s\n' $l \
  "$(git show origin/$l:$S/DuplicateFinder.swift 2>/dev/null | grep -cF 'members = members.filter { !isCovered($0.path, by: coveredRoots) }')" \
  "$(git show origin/$l:$S/DuplicateFinder.swift 2>/dev/null | grep -cF 'keeperRoots.insert(keeper.path)')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   coverOnly=1 keeperRoots=1
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same pass, the same code (`coverOnly=1`) | RECORDED — not owed |

---

## Packages and links travel whole in Duplicates and Restructure (FR1, FR2) — main only

Duplicates grouped, trashed and merged files inside `.key`, `.pages`, `.app` and `.photoslibrary`
bundles, and a Restructure merge went one level down into two same-named packages, or through a
link to another provider's folder, file by file. `main` reads a package off the walk's type
identifier (`FileNode.isPackage`): Duplicates matches a package only whole and never folds away a
copy holding one, and Restructure's disk view lists packages and links that resolve as items moved
whole.

```sh
S=Modules/Sync/Sources/Sync
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s finderPkg=%s fromDisk=%s linkProbe=%s\n' $l \
  "$(git show origin/$l:$S/DuplicateFinder.swift 2>/dev/null | grep -cF 'isPackage')" \
  "$(git show origin/$l:$S/RestructurePlanner.swift 2>/dev/null | grep -cF 'static func fromDisk')" \
  "$(git show origin/$l:$S/RestructurePlanner.swift 2>/dev/null | grep -cF 'if isDirectory.boolValue { folders.append(name) } else { files.append(name) }')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         finderPkg=0 fromDisk=1 linkProbe=1
# v4.x, v3.x, v2.x   finderPkg=0 fromDisk=0 linkProbe=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Both: the finder and the Restructure disk view (`fromDisk=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | The finder half; no Restructure (`fromDisk=0`) | RECORDED — not owed |

---

## A Setup re-walk keeps the roster, verdicts and ledger (FR4) — main only

Re-running Setup's Learn and Save wrote a new walk profile and pointed the app at it, but nothing
copied `people.json`, `person-tags.json` or `restructure.json` across, so the roster read back as
the folder-name seed, the verdicts and the last landing's Undo vanished, and the next survey refresh
removed the old folder for good. `main` carries them on every walk that re-points (the ledger, the
verdicts and the Undo only when the walk covered the same root; another folder keeps its own, see
"Each Setup folder keeps its own Restructure history"), and `retireSupersededProfiles` keeps any
folder holding a curated file the active one lacks.

```sh
S=Modules/Sync/Sources/Sync
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s walkWrite=%s walkCarry=%s retire=%s\n' $l \
  "$(git show origin/$l:$S/FileSyncManager+FolderWalk.swift 2>/dev/null | grep -cF 'func writeWalkProfile')" \
  "$(git show origin/$l:$S/FileSyncManager+FolderWalk.swift 2>/dev/null | grep -cF 'carryProfileArtifacts')" \
  "$(git show origin/$l:$S/FilingProfileStore.swift 2>/dev/null | grep -cF 'func retireSupersededProfiles')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         walkWrite=1 walkCarry=0 retire=1
# v4.x, v3.x, v2.x   walkWrite=0 walkCarry=0 retire=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same walk and retire, the same code (`walkCarry=0`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No walk profile, no retire (`walkWrite=0`) | CLOSED — does not apply |

---

## Replace can't put away the folder an item is inside (FR30) — main only

Cutting `/T/Photos/Photos`, pasting it into `/T` and answering Replace trashed the outer folder with
everything else in it, and ⌘Z could not move it back. `validateFileOperation` now refuses a
destination that contains the source (`destinationContainsSource`), as Finder does.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s validate=%s holdsCheck=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations+Primitives.swift 2>/dev/null | grep -cF 'throw FileOperationError.nestingViolation')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations+Primitives.swift 2>/dev/null | grep -cF 'destinationContainsSource')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   validate=1 holdsCheck=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same validation, without the check (`holdsCheck=0`) | RECORDED — not owed |

---

## To File never files into a package (FR3) — main only

The filing engine profiled `Budget 2025.numbers` and its `Data/` folder as homes, so a loose PDF
could be batch-filed inside a document. `main` leaves packages out of the engine's candidates and the
classifier's folder list, and `performFiling` refuses a destination inside one (`destinationIsADocument`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s profiles=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FilingEngine.swift 2>/dev/null | grep -cF 'guard node.isDirectory, !options.ignoredNames.contains(node.name) else { return }')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   profiles=1
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same profile walk (`profiles=1`) | RECORDED — not owed |

---

## Undoing New Folder leaves a folder that isn't empty (FR24) — main only

The create-folder undo trashed its folder without looking inside, so Restructure's ⌘Z trashed an item
it had just reported leaving in place, and a plain New Folder undo took whatever had been put in it
since. `main` removes the folder only when it holds no files (OS noise aside) and says so otherwise.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s createUndo=%s filesHeld=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift 2>/dev/null | grep -cF 'func registerCreateFolderUndo')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift 2>/dev/null | grep -cF 'func filesHeld')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   createUndo=1 filesHeld=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same undo (`createUndo=1`) | RECORDED — not owed |

---

## Undoing a move that landed twice on one name puts each file home (FR23) — main only

Moving `/A/f.txt` and `/B/f.txt` into `/D` with Replace left both undo records describing B's file,
so ⌘Z put B's content at `/A` and left `/B` empty. `main` redirects the earlier record to where the
replace kept its file, and hands the later one what `/D` held before the batch.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s moveSnap=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift 2>/dev/null | grep -cF 'movedIdentity: ItemIdentity.snapshot(')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   moveSnap=2
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The registration-time snapshot (`moveSnap=2`) | RECORDED — not owed |

---

## A merge refuses a copy holding a folder it couldn't read (FR12) — main only

An unread subfolder came back with no children, every flatten read it as empty, and the merge trashed
the copy holding it. `main` refuses the merge (`planMerge`'s `unreadDirs`), and the finder never
folds such a copy away.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s mergeFlatten=%s unread=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Duplicates.swift 2>/dev/null | grep -cF 'flattenFilesWithRelativePaths(rTree)')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Duplicates.swift 2>/dev/null | grep -cF 'unreadDirs')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   mergeFlatten=1 unread=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same merge (`mergeFlatten=1`) | RECORDED — not owed |

---

## A save keeps a version that arrived while it was writing (FR48, FR49) — main only

Edit's save deleted the swap's backup unexamined, so a newer version installed between the check and
the swap was lost for good; New File checked the name and then wrote through the same replace. `main`
keeps a displaced version that is neither the one written against nor its own last write, as
`<name> (other version)`, and creates new files exclusively.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s backupDelete=%s newFile=%s\n' $l \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorFileStore.swift 2>/dev/null | grep -cF 'if let backup { try? fileManager.removeItem(at: backup) }')" \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorFileStore.swift 2>/dev/null | grep -cF 'try write("", toPath: path)')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         backupDelete=1 newFile=1
# v4.x, v3.x, v2.x   backupDelete=0 newFile=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same save and New File (`backupDelete=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Edit file store (`backupDelete=0`) | CLOSED — does not apply |

---

## PDF copies say what macOS 26 drops (FR53) — main only

On macOS 26 PDFKit drops the catalog on every write; the toolkit carries page labels, viewer
settings, language and attachments back onto an unencrypted copy, but never tags, layers or output
intent, and nothing onto an encrypted one. Yet Rotate, Protect, Fill Form and a form's Clean Metadata
said they keep everything. `main` counts them as dropping the three named parts below macOS 27, and
Protect's sheet adds that the other four go too.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s keepsClaim=%s\n' $l \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorPDFToolEngine.swift 2>/dev/null | grep -cF 'case .rotate, .protect, .fillForm: return false')"; done
# measured 2026-10-23, against origin, before this landed:
# main               keepsClaim=1
# v5.x, v4.x, v3.x, v2.x   keepsClaim=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No catalog-parts note (`keepsClaim=0`) | CLOSED — does not apply |

---

## Copy/Move to the other pane lands where that pane opens (FR37, FR38) — main only

The pane transfer re-rooted a path by account root with a bare prefix test, so Dropbox `Documents/…`
landed at the Google Drive account root outside `My Drive`, and every row under iCloud's linked
`Documents` was refused as outside the pane. `main` relativizes link-aware, re-anchors between the
panes' landing folders, and joins link-aware, as linked navigation already does.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s prefixMath=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations.swift 2>/dev/null | grep -cF 'relativePath = String(node.id.dropFirst(fromRootWithSlash.count))')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   prefixMath=1
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same prefix math (`prefixMath=1`) | RECORDED — not owed |

---

## A Restructure landing journals each step as it runs (FR16) — main only

A landing cut off mid-run left a half-applied tree whose Undo is refused, pointing at a log that named
nothing. `main` appends each performed action to `restructure-landing-<manifest>.jsonl` in the profile
folder as it runs, removes it once the record is finalised, and names it in the refusal.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s logClaim=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+RestructureApply.swift 2>/dev/null | grep -cF 'The log from that run')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         logClaim=1
# v4.x, v3.x, v2.x   logClaim=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same landing (`logClaim=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Restructure (`logClaim=0`) | CLOSED — does not apply |

---

## The last check before removal refuses a copy holding another group's keeper (FR10, again) — main only

The scan protects a folder holding another group's keeper, but only against the keepers it chose.
Picking a different keeper by hand let another group's removal hold it, and one Apply recommended
could again remove every copy. `main`'s removal gate refuses any copy that is, or holds, a listed
group's current keeper.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s setKeeper=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Duplicates.swift 2>/dev/null | grep -cF 'public func setKeeper')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   setKeeper=1
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The keeper pick, without even the scan-time protection | RECORDED — not owed |

---

## Restructure's pair route never merges a package (FR2, again) — main only

A mirrored inbox can name packages themselves — `TODO/Return.pages` beside `Return.pages` — and the
pair route merged one document's insides into the other's. `main`'s disk view gives a package
asked about by its own path no listing, so the pair is refused.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s pairMerge=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/RestructurePlanner.swift 2>/dev/null | grep -cF 'static func pairMergeManifest')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         pairMerge=1
# v4.x, v3.x, v2.x   pairMerge=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same pair route (`pairMerge=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Restructure (`pairMerge=0`) | CLOSED — does not apply |

---

## Setup keeps a reading and a failed Save in view, two clears and Remove ask, and five names are fixed — main only

Eight Setup, Settings and app-shell defects from the v6.1 review (ST1, ST3, ST6, ST8, ST9, ST13,
SH1, SH6/SH7).

- **Setup.** Over a finished reading Learn's primary was "Learn again", so Back to Learn had no way
  on that kept the reading; `main` makes it Continue, with Learn again beside it (ST1). A failed
  Save moved on and was recorded as a failed reading — tree discarded, "Couldn't read that folder"
  on screens already left; `main` stays on Structure and says the write failed there (ST3).
  Summary's Learn closed setup onto Settings ▸ Organize, which cannot learn; `main` goes back to the
  Learn screen (ST6).
- **Settings.** Spend Clear (Intelligence) and the Organize lens's Clear History reset both caps'
  counts, and Remove deleted the Keychain key, each on one click; `main` asks first, Cancel as the
  default (ST8). "Reset setup…" said setup opens on the next launch and that no file is touched; it
  opens at once and deletes the setup draft (ST9). The Sources switches had no VoiceOver name (ST13).
- **Shell.** The spend-cap alert and the missing-key message pointed at "Settings → Organize"; the
  caps and the key are under Intelligence (SH1). The seam's swap button and the Info inspector's ✕
  had no accessibility name (SH6, SH7).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s learnAgainPrimary=%s saveFailsWalk=%s summaryToTab=%s spendAsks=%s keyRemove=%s nextLaunch=%s organizeArrow=%s inspectorName=%s swapName=%s switchName=%s\n' $l \
  "$(git show origin/$l:MacApp/SetupSheet.swift 2>/dev/null | grep -c '"Learn again" : "Learn"')" \
  "$(git show origin/$l:MacApp/Setup/SetupModel.swift 2>/dev/null | grep -c '^ *walkState = .failed(failure.description)')" \
  "$(git show origin/$l:MacApp/Setup/SummaryScreen.swift 2>/dev/null | grep -c 'learnedSummary, tab: .filing')" \
  "$(git grep -l 'FilingSpendStore.clearIfConfirmed' origin/$l -- Modules MacApp 2>/dev/null | wc -l | tr -d ' ')" \
  "$(git show origin/$l:Modules/Settings/Sources/Settings/CloudKeyRow.swift 2>/dev/null | grep -c 'Button("Remove", action: removeKey)')" \
  "$(git show origin/$l:Modules/Settings/Sources/Settings/SettingsView.swift 2>/dev/null | grep -c 'opens again on the next launch')" \
  "$(git grep -l 'Settings → Organize' origin/$l -- MacApp 2>/dev/null | wc -l | tr -d ' ')" \
  "$(git show origin/$l:MacApp/ContentView.swift 2>/dev/null | grep -c 'accessibilityLabel("Hide the inspector")')" \
  "$(git grep -l 'accessibilityLabel("Swap panes")' origin/$l -- MacApp 2>/dev/null | wc -l | tr -d ' ')" \
  "$(git show origin/$l:Modules/Settings/Sources/Settings/SettingsView.swift 2>/dev/null | grep -c 'accessibilityLabel(provider.displayName)')"; done
# measured 2026-10-23, against origin, after this landed — spendAsks, inspectorName, swapName and
# switchName grep for what the fix added, so 0 is a line that still carries the defect:
# main   learnAgainPrimary=0 saveFailsWalk=0 summaryToTab=0 spendAsks=4 keyRemove=0 nextLaunch=0 organizeArrow=0 inspectorName=1 swapName=1 switchName=1
# v5.x   learnAgainPrimary=1 saveFailsWalk=1 summaryToTab=1 spendAsks=0 keyRemove=1 nextLaunch=1 organizeArrow=2 inspectorName=0 swapName=0 switchName=0
# v4.x   learnAgainPrimary=0 saveFailsWalk=0 summaryToTab=0 spendAsks=0 keyRemove=1 nextLaunch=0 organizeArrow=2 inspectorName=0 swapName=0 switchName=0
# v3.x   learnAgainPrimary=0 saveFailsWalk=0 summaryToTab=0 spendAsks=0 keyRemove=1 nextLaunch=0 organizeArrow=2 inspectorName=0 swapName=0 switchName=0
# v2.x   learnAgainPrimary=0 saveFailsWalk=0 summaryToTab=0 spendAsks=0 keyRemove=1 nextLaunch=0 organizeArrow=0 inspectorName=0 swapName=0 switchName=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | All eight, the same code (`nextLaunch=1`: the probe's phrase is the caption's; its alert says "next launch" too, and it has no tooltip saying so) | RECORDED — not owed |
| `v4.x` / `v3.x` | The Settings and shell five (ST8, ST13, SH1, SH6/SH7); no guided Learn, Structure or Summary | RECORDED — not owed |
| `v2.x` | ST8, ST13 and SH6/SH7; no "Settings → Organize" pointer (`organizeArrow=0`) and no guided setup | RECORDED — not owed |

---

## Organize's rules and Storage say what they hold, and Compare's pages and keeper read without colour — main only

Ten defects from the v6.1 review (LN4, LN5, LN6, LN7, LN13, LN20, LN22, LN23, DS2, DS3).

- **The rule editor** discarded edits silently on Esc; `main` asks when the rule differs from the
  one it opened with. **Rule cards** showed a "Person is" chip as the stored id ("daughter"); they
  name the person.
- **Storage's Overview headline** counted its lists, which are capped at 20 rows ("20 large · 20
  untouched", reclaimable summing 20 candidates); the analyzer now counts the whole tree before it
  caps, and the headline reads those ("N files · N untouched"). "Not opened or changed" says
  "Not changed", since only the modification date is checked.
- **Buttons that act at once** dropped their "…": Copy/Move Remaining N, Export plan(s), Save for
  later, Fix name (row menu) and Organize ▸ Fix Name. **File N** confirms with the plain alert
  rather than the red Trash one.
- **Compare's page strip** gives each state its own shape and draws from `SemanticColor`; an
  overlap group draws nothing where it drew a disabled "Keep this instead".
- **Warning and success sentences** at four sites take `ChromeInk.bodyText`, and the Restructure
  billing disclosure is 11pt secondary rather than 10pt tertiary.

```sh
F=Modules/FileExplorer/Sources/FileExplorer
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s ruleEsc=%s personChip=%s storageLens=%s storageCap=%s opened=%s ellipses=%s fileAllRed=%s stripHue=%s keepGrey=%s\n' $l \
  "$(git show origin/$l:$F/AutomationRuleEditor.swift 2>/dev/null | grep -c 'Button("Cancel", action: onCancel)')" \
  "$(git show origin/$l:$F/AutomationsLens.swift 2>/dev/null | grep -c 'case .personIs(let id): return id.isEmpty')" \
  "$(git ls-tree -r --name-only origin/$l -- Modules/Sync/Sources/Sync/StorageLens.swift | wc -l | tr -d ' ')" \
  "$(git show origin/$l:$F/LensWorkspaceView.swift 2>/dev/null | grep -c 'report.largest.count) large')" \
  "$(git show origin/$l:$F/StorageLensView.swift 2>/dev/null | grep -c 'Not opened or changed in a long while')" \
  "$(git grep -h -e 'Remaining \\(pendingCount)…' -e '"Export plan…"' -e 'plans…"' -e '"Save for later…"' -e '"Fix name…"' -e '"Fix Name…"' origin/$l -- $F MacApp/ShortcutCommands.swift | grep -v '^[[:space:]]*//' | wc -l | tr -d ' ')" \
  "$(git show origin/$l:$F/LensWorkspaceView.swift 2>/dev/null | grep -A1 'confirmDestructive(' | grep -c 'into their suggested homes')" \
  "$(git show origin/$l:$F/VisualPairModes.swift 2>/dev/null | grep -c 'case .changed: return .orange')" \
  "$(git show origin/$l:$F/CompareCopiesSheet.swift 2>/dev/null | grep -c 'disabled(marker == .inert)')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x  ruleEsc=1 personChip=1 storageLens=1 storageCap=1 opened=1 ellipses=5 fileAllRed=1 stripHue=1 keepGrey=1
# v4.x        ruleEsc=1 personChip=1 storageLens=1 storageCap=0 opened=1 ellipses=3 fileAllRed=1 stripHue=0 keepGrey=0
# v3.x        ruleEsc=1 personChip=0 storageLens=1 storageCap=0 opened=1 ellipses=2 fileAllRed=0 stripHue=0 keepGrey=0
# v2.x        ruleEsc=1 personChip=0 storageLens=1 storageCap=0 opened=1 ellipses=1 fileAllRed=0 stripHue=0 keepGrey=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | All of it, the same code | RECORDED — not owed |
| `v4.x` | The silent Esc, the id chip, "opened", three of the ellipses and the red File N; nothing counts the capped lists (`storageCap=0`), and no Compare sheet or page strip | RECORDED — not owed |
| `v3.x` / `v2.x` | The silent Esc, "opened" and fewer ellipses (`ellipses=2`, `1`); no person condition, no red File N (`fileAllRed=0`) | RECORDED — not owed |

---

## Edit's status line, format bar, Preview links and rail dot; PDF batch and palette — main only

Seven Edit defects from the v6.1 review (ED2, ED3, ED4, ED5, ED10, PD3, PD6).

- **The status line** kept the last file's words, encoding and line endings, and its caret, beside a
  newly opened file until the 150 ms count landed. `main` shows the counts only beside the file they
  were counted for (`EditorStatusLine.shownFacts`) and seeds Line/Col as the file arrives.
- **A folded format-bar group** never greyed: folded Lists in a table opened a menu of greyed items.
  `main` greys it when none of its items would act (`EditorFormatBar.isFoldOffered`).
- **Voice Control**: the bar's words (Bullets, Tasks, Quote) were not names it answered to. `main`
  adds them through `EditorSpokenNames`, as the header's chips do.
- **Editable Preview's links** were system blue — the run's `NSColor.linkColor`, and the text view's
  own `linkTextAttributes` — where read-only Preview draws the window's hue. `main` uses the hue for both.
- **The rail's unsaved dot** told VoiceOver "Unsaved" for a stopped autosave too. `main` uses the
  header's rule (`EditorSaveStatus.dotName`).
- **A PDF batch's Rotate** ran on an owner-restricted file and failed with a line naming the file
  twice. `main` skips it before the run (`Skip.restrictedByOwner`).
- **Fill & Sign's Ink and Marks** said only their names to VoiceOver. `main` adds the colour and the
  mark as values.

```sh
F=Modules/FileExplorer/Sources/FileExplorer
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s statusFacts=%s foldMenu=%s barWords=%s linkColor=%s railUnsaved=%s batch=%s palette=%s spokenNames=%s\n' $l \
  "$(git show origin/$l:$F/EditorStatusLine.swift 2>/dev/null | grep -c 'let facts: EditorDocumentFacts$')" \
  "$(git show origin/$l:$F/EditorFormatBar.swift 2>/dev/null | grep -c 'private func foldMenu')" \
  "$(git show origin/$l:$F/EditorFormatBar.swift 2>/dev/null | grep -c 'static func word(_ verb')" \
  "$(git show origin/$l:$F/PreviewEditSession.swift 2>/dev/null | grep -c 'value: NSColor.linkColor')" \
  "$(git show origin/$l:$F/EditorFileRailView.swift 2>/dev/null | grep -c 'accessibilityLabel("Unsaved")')" \
  "$(git ls-tree -r --name-only origin/$l -- $F/EditorPDFBatch.swift | wc -l | tr -d ' ')" \
  "$(git ls-tree -r --name-only origin/$l -- $F/EditorPDFFillPalette.swift | wc -l | tr -d ' ')" \
  "$(git grep -l 'enum EditorSpokenNames' origin/$l -- $F 2>/dev/null | wc -l | tr -d ' ')"; done
# statusFacts, linkColor and railUnsaved are the defects; the rest say what a line has to carry them.
# linkColor reads the code that colours a link, not the doc comment that still names NSColor.linkColor.
# measured 2026-10-23, against origin, before this landed:
# main               statusFacts=1 foldMenu=1 barWords=1 linkColor=1 railUnsaved=1 batch=1 palette=1 spokenNames=1
# v5.x               statusFacts=1 foldMenu=1 barWords=1 linkColor=1 railUnsaved=1 batch=0 palette=0 spokenNames=0
# v4.x, v3.x, v2.x   all 0 — no Edit workspace
# measured 2026-10-23, against origin, after it landed (main 6bfdee166):
# main               statusFacts=0 foldMenu=1 barWords=1 linkColor=0 railUnsaved=0 batch=1 palette=1 spokenNames=1
# v5.x, v4.x, v3.x, v2.x   as before
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The five text and Markdown defects; the same code for four, but no `EditorSpokenNames` (`spokenNames=0`), so the Voice Control words would bring that type with them. No PDF batch or Fill & Sign palette | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace | CLOSED — does not apply |

---

## Count titles inflect for one, a bulk move says Moving, and ⌘. cancels the progress dialog — main only

Two defects from the v6.1 review (DS8, DS9). Undo names and progress titles said "1 Items" — Edit ▸
Undo read "Undo Delete 1 Items" — printed the count ungrouped ("Deleting 7363 Items" over "3,336 of
7,363"), and a bulk move was titled "Syncing N files". `main` builds them with `CountedNoun.phrase`
and titles a bulk move "Moving". The progress dialog had no key: `main` binds ⌘.
(`AppChord.cancelOperation`) to its Cancel, deliberately not Esc.

```sh
S=Modules/Sync/Sources/Sync
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s itemsTitles=%s syncingForMove=%s dialogKey=%s dialog=%s\n' $l \
  "$(git grep -h -E '\\\((total|transferred\.count|successfullyTrashed\.count|moves\.count)\) Items"' origin/$l -- $S | wc -l | tr -d ' ')" \
  "$(git show origin/$l:$S/FileSyncManager+BulkSync.swift 2>/dev/null | grep -cF "Syncing \\(total) files")" \
  "$(git show origin/$l:Modules/Design/Sources/Design/ProgressDialog.swift 2>/dev/null | grep -c 'keyboardShortcut')" \
  "$(git ls-tree -r --name-only origin/$l -- Modules/Design/Sources/Design/ProgressDialog.swift | wc -l | tr -d ' ')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   itemsTitles=6 syncingForMove=1 dialogKey=0 dialog=1
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | Both, the same code (`itemsTitles=6`, `dialogKey=0`) | RECORDED — not owed |

---

## Browse answers Undo Last Run in its own window, asks before clearing the log, and tips only what needs it — main only

Five Browse defects from the v6.1 review (BR2, BR3, BR4, BR6, BR13).

- **Undo Last Run** in Sync History, with nothing it may reverse (after a relaunch, say), put its
  reason in the main window's banner, so the click looked dead. `main` shows it as an alert in the
  Sync History window (`undoLastSyncRunAskingFirst`, `lastSyncRunUndoRefusal`).
- **Customize Pane Bar** drew a fake "iCloud" capsule at the head of the bar for every pane. `main`
  keeps a blank drop zone there and says "from the leading edge".
- **Clear Log** emptied the Activity Log and truncated the file on disk in one click, from the
  Activity Log and from Settings ▸ Advanced, under three names. `main` asks first on both
  (`Logger.clearIfConfirmed`) and calls it "Clear Log" everywhere.
- **Crumb tooltips** promised "⌥-click to bring both panes here" in every one-pane workspace. `main`
  passes no both-panes action there, and the tooltip names only the destination.
- **Truncated names** had no tooltip. `main` shows the full name only when the row cut it.

```sh
D=Modules/Dashboard/Sources/Dashboard
T=Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s historyAsks=%s fakeICloud=%s viewerClear=%s settingsClear=%s onePaneTip=%s rowView=%s nameTip=%s\n' $l \
  "$(git show origin/$l:MacApp/SyncCloudApp.swift 2>/dev/null | grep -c 'undoLastSyncRunAskingFirst')" \
  "$(git show origin/$l:$D/PaneBarCustomizeSheet.swift 2>/dev/null | grep -c 'Text("iCloud")')" \
  "$(git show origin/$l:$D/LogViewer.swift 2>/dev/null | grep -c 'logger.clearLogs()')" \
  "$(git show origin/$l:Modules/Settings/Sources/Settings/SettingsView.swift 2>/dev/null | grep -c 'Logger.shared.clearLogs()')" \
  "$(git show origin/$l:$D/PaneBreadcrumb.swift 2>/dev/null | grep -c 'hasSecondPane: onNavigateBoth != nil')" \
  "$(git show origin/$l:$T 2>/dev/null | grep -c 'struct FileRowView')" \
  "$(git show origin/$l:$T 2>/dev/null | grep -c 'rowHelp(name:')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   historyAsks=0 fakeICloud=1 viewerClear=1 settingsClear=1 onePaneTip=0 rowView=1 nameTip=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` | All five, the same code | RECORDED — not owed |
| `v3.x` / `v2.x` | All five; their real bar still has the provider capsule (fd068fc49 is not on them), so the sheet's "iCloud" stands for something real, misnamed off iCloud | RECORDED — not owed |

---

## The shortcuts window grows with the text, scan ages say "just now" and speak in words, and decoration is silent — main only

Four design-system defects from the v6.1 review (SH12, DS6, DS7, DS15), and the ↩ speech gap the
same commit closed.

- **Keyboard Shortcuts** was a fixed 1240×760 with a 165pt keys column, so above Default the
  rows outgrew it and it scrolled, and longer chords wrapped. `main` sizes the window and the
  column from the text size (`ShortcutsReferenceView.windowSize(scale:)`), and the fit test runs
  at every stop. `v3.x` / `v2.x` have a fixed 480×420 one-column window instead, with the same
  defect in a different shape.
- **Scan ages** read "0s ago" for the first 30 seconds, then "23h ago" followed by "1 day ago".
  `main` says "just now", then stays compact through "1d ago".
- **VoiceOver** was handed the compact age ("scanned 29m ago"), which it can read as metres.
  `main` speaks it in words (`ScanFreshness.spokenRelative`).
- **Provider marks and empty-state icons** were read aloud at some sites, and empty-state titles
  were not headings. `main` hides the mark once, inside `ProviderLogo`, hides the empty state's
  icon, and gives its title the header trait.
- **↩ had no spoken name.** `main` draws Return as ↩ wherever it shows a keycap, and gave ↩ the
  name "Return" in `ShortcutKeycapSpeech` beside ⏎. `v5.x` / `v4.x` draw `ShortcutKeycap("↩")` at
  one site (`GoToResultsPanel`) and their table names only ⏎, so VoiceOver reads the glyph there.

```sh
D=Modules/Design/Sources/Design
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s fixedWindow=%s scaledWindow=%s logoHidden=%s emptyHeader=%s zeroSecs=%s dayWords=%s spokenWords=%s returnDrawn=%s returnSpoken=%s\n' $l \
  "$(git show origin/$l:MacApp/ShortcutsReference.swift 2>/dev/null | grep -c '\.frame(width: Self.windowSize.width')" \
  "$(git show origin/$l:MacApp/ShortcutsReference.swift 2>/dev/null | grep -c 'static func windowSize(scale:')" \
  "$(git show origin/$l:$D/ProviderLogo.swift 2>/dev/null | grep -c 'accessibilityHidden(true)')" \
  "$(git show origin/$l:$D/EmptyStateView.swift 2>/dev/null | grep -c 'isHeader')" \
  "$(git show origin/$l:$D/ScanFreshness.swift 2>/dev/null | grep -c 'return "0s ago"')" \
  "$(git show origin/$l:$D/ScanFreshness.swift 2>/dev/null | grep -c '"1 day ago" :')" \
  "$(git show origin/$l:$D/ScanFreshness.swift 2>/dev/null | grep -c 'func spokenRelative')" \
  "$(git grep -l 'eycap("↩")' origin/$l -- MacApp 'Modules/*/Sources/*' | wc -l | tr -d ' ')" \
  "$(git show origin/$l:$D/ShortcutKeycap.swift 2>/dev/null | grep -c '("↩", "Return")')"; done
# zeroSecs and dayWords match code, not prose: main's comments still quote "0s ago" and "1 day ago".
# returnDrawn counts source files drawing a ↩ keycap; returnSpoken is whether ↩ has a spoken name.
# re-measured 2026-10-24, against origin, after this landed (main caec21a1a):
# main    fixedWindow=0 scaledWindow=1 logoHidden=1 emptyHeader=1 zeroSecs=0 dayWords=0 spokenWords=1 returnDrawn=11 returnSpoken=1
# v5.x    fixedWindow=1 scaledWindow=0 logoHidden=0 emptyHeader=0 zeroSecs=1 dayWords=1 spokenWords=0 returnDrawn=1 returnSpoken=0
# v4.x    fixedWindow=1 scaledWindow=0 logoHidden=0 emptyHeader=0 zeroSecs=1 dayWords=1 spokenWords=0 returnDrawn=1 returnSpoken=0
# v3.x    fixedWindow=0 scaledWindow=0 logoHidden=0 emptyHeader=0 zeroSecs=1 dayWords=1 spokenWords=0 returnDrawn=0 returnSpoken=0
# v2.x    fixedWindow=0 scaledWindow=0 logoHidden=0 emptyHeader=0 zeroSecs=1 dayWords=1 spokenWords=0 returnDrawn=0 returnSpoken=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` | All five, the same code; ↩ unspoken at its one keycap | RECORDED — not owed |
| `v3.x` / `v2.x` | The first four; the shortcuts window is the older fixed 480×420 one, which scrolls above Default for the same reason. No ↩ keycap, so nothing to speak | RECORDED — not owed |

---

## Browse's tree, menus, Info card and Move/Copy recents; Organize's walkthrough keys and dates — main only

Eight layout and behaviour defects from the v6.1 review (BR7, BR14, BR15, BR17, BR20, LN18, LN19,
LN21). The copy fixes in the same sweep carry no row.

- **Tree view** expanded an empty folder and an unreadable one onto nothing alike. `main` shows one
  dimmed child row with the columns' words, "Empty" or "Can’t be read"
  (`PaneOutlineRows.placeholder`).
- **Sort By**: the tree's background menu had five buttons with no tick, and the columns' had none.
  `main` draws one shared picker with a tick in both (`SharedFileMenuItems.sortBy`).
- **Copy Path** was not on the file row's menu. `main` adds it under Quick Look.
- **Info sidebar** labels sat in a fixed 80pt column, so "Where it lives:" (85.3pt at 13pt) wrapped
  at the default size. `main` lays the rows in a `Grid` sized to the widest label, at the app's
  text size (`DetailsMetadataGrid`).
- **Move/Copy recents** showed only the folder name. `main` gives every row its full path as a
  tooltip and a parent line where names repeat (`DestinationPicker.recentDetail`).
- **Restructure's member column** cut the list off at two lines with no tooltip. `main` adds one.
- **Restructure's Applied/Undone stamps** used a fixed "HH:mm" and "d MMM yyyy". `main` follows the
  reader's clock and region.
- **One-at-a-time walkthroughs** skipped on → (Rules) and ⌫ (Compare's review). `main` takes ⌫
  in both and → in Rules alone: in Compare → means the right pane, and a skip cannot be taken back.

```sh
F=Modules/FileExplorer/Sources/FileExplorer
D=Modules/Dashboard/Sources/Dashboard
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s treeEmpty=%s sortTick=%s rowCopyPath=%s info80=%s recentParent=%s memberTip=%s rulesDelete=%s reviewArrow=%s fixedClock=%s\n' $l \
  "$(git show origin/$l:$F/PaneOutlineRows.swift 2>/dev/null | grep -c 'static func placeholder(for row: PaneRow')" \
  "$(git show origin/$l:$F/FileTreeView.swift 2>/dev/null | grep -c 'static func sortBy')" \
  "$(git show origin/$l:$F/FileTreeView.swift 2>/dev/null | grep -c 'SharedFileMenuItems.copyPath(singleNode.id)')" \
  "$(git show origin/$l:$D/DetailsSidebar.swift 2>/dev/null | grep -c 'frame(width: 80, alignment: .trailing)')" \
  "$(git show origin/$l:$F/DestinationPicker.swift 2>/dev/null | grep -c 'static func recentDetail')" \
  "$(git show origin/$l:$F/RestructureLens.swift 2>/dev/null | grep -c '\.help(members)')" \
  "$(git show origin/$l:$F/AutomationsLens.swift 2>/dev/null | grep -c 'keys: \[.rightArrow, .delete\]')" \
  "$(git show origin/$l:$F/ReviewCardView.swift 2>/dev/null | grep -c 'keys: \[.delete, .rightArrow\]')" \
  "$(git show origin/$l:$F/RestructureLens.swift 2>/dev/null | grep -c 'fixed("HH:mm")')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         treeEmpty=0 sortTick=0 rowCopyPath=0 info80=1 recentParent=0 memberTip=0 rulesDelete=0 reviewArrow=0 fixedClock=1
# v4.x, v3.x, v2.x   treeEmpty=0 sortTick=0 rowCopyPath=0 info80=1 recentParent=0 memberTip=0 rulesDelete=0 reviewArrow=0 fixedClock=0
# and on this branch: treeEmpty=1 sortTick=1 rowCopyPath=1 info80=0 recentParent=1 memberTip=2 rulesDelete=1 reviewArrow=1 fixedClock=0
# reviewArrow is 0 on main again: Compare's review went back to ⌫ alone (2026-10-24), which is
# what every maintenance line has, so the walkthrough difference left is Rules' ⌫ (rulesDelete).
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | All eight, the same code | RECORDED — not owed |
| `v4.x` | All but the stamps: its Restructure has no Applied/Undone ledger (`fixedClock=0`) | RECORDED — not owed |
| `v3.x` | The Browse five and the Rules ⌫; no Restructure lens | RECORDED — not owed |
| `v2.x` | As `v3.x` but for the Info card: its tree is an `OutlineGroup` (no `PaneOutlineRows.swift`), with the same empty expansion; its card has no “Where it lives:” row, its widest label (“Permissions:”) fits the 80pt column, and its labels do not follow the text size, so nothing wraps (`info80=1` is the column, not the defect) | RECORDED — not owed |

---

## Edit's retype hint follows Text Size, Compress says why Save is greyed, and four smaller fixes — main only

Five Edit behaviour and layout defects from the v6.1 review (PD4, PD5, PD9, PD14, ED13); the copy
fixes landed with them (ED6, ED7, ED9, ED11, ED12, ED14, ED15, PD1, PD7, PD8, PD11) are not tracked.

- **Replace's retype hint** drew in fixed 10 and 11 points whatever View ▸ Text Size said, and its
  "Same font" / "Stand-in" chip in bare system green and orange on their own wash — 1.95:1 and
  2.02:1 on the light window ground (white). `main` resolves its fonts through
  `ScaledFont.nsFont(scale:)`, the text size handed down from `EditorPDFPageView`, and draws the
  chip's words in the label's ink, the hue kept to the wash (`ChromeInk.bodyText` read 4.49:1 on a
  0.96 sheet).
- **Compress ▸ To a size** greyed Save with nothing said for 0, a word or an empty field. `main`
  says why in red under the field (`EditorPDFCompression.targetCaption`), from the rule the button
  greys by, in one file's sheet and a batch's.
- **Right-click ▸ Replace Text…** on a form showed the two-sentence refusal as one wide menu row.
  `main` shows a short one (`EditorPDFFillSign.replaceMenuReason`); the palette keeps the long one.
- **VoiceOver** offered "Edit Text" on a correction the right-click menu calls Retype. `main` names
  it Retype.
- **The Body menu's styles** were drawn on a ramp of their own (21, 17, 14.5 bold). `main` reads
  Preview's (`MarkdownBlockView.headingSize`, semibold).

```sh
F=Modules/FileExplorer/Sources/FileExplorer
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s hintFixed=%s chipInk=%s compressSilent=%s replaceRow=%s voEditText=%s pickerRamp=%s replace=%s\n' $l \
  "$(git show origin/$l:$F/EditorPDFReplace.swift 2>/dev/null | grep -c 'NSFont.systemFont(ofSize: 10, weight: .semibold)')" \
  "$(git show origin/$l:$F/EditorPDFReplace.swift 2>/dev/null | grep -c 'foregroundColor: lines.sameFont ? NSColor.systemGreen')" \
  "$(git show origin/$l:$F/EditorPDFToolSheets.swift 2>/dev/null | grep -c 'Text("Tries lower quality until the file fits.")')" \
  "$(git show origin/$l:$F/EditorPDFPageView.swift 2>/dev/null | grep -c 'case (let file?, _): reason = file')" \
  "$(git show origin/$l:$F/EditorPDFFillOverlay.swift 2>/dev/null | grep -c 'NSAccessibilityCustomAction(name: "Edit Text")')" \
  "$(git show origin/$l:$F/EditorFormatBar.swift 2>/dev/null | grep -c 'case .heading(1): return (21, .bold)')" \
  "$(git ls-tree -r --name-only origin/$l -- $F/EditorPDFReplace.swift | wc -l | tr -d ' ')"; done
# The first six are the defects; replace says whether a line has Replace at all.
# measured 2026-10-23, against origin, before this landed (main 29c9b0d60):
# main               hintFixed=1 chipInk=1 compressSilent=1 replaceRow=1 voEditText=1 pickerRamp=1 replace=1
# v5.x               hintFixed=0 chipInk=0 compressSilent=0 replaceRow=0 voEditText=0 pickerRamp=1 replace=0
# v4.x, v3.x, v2.x   all 0 — no Edit workspace
# measured 2026-10-23, against this change's tree:
# main               hintFixed=0 chipInk=0 compressSilent=0 replaceRow=0 voEditText=0 pickerRamp=0 replace=1
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The Body menu's own ramp only (`pickerRamp=1`); no Replace, Compress sheet or Fill & Sign overlay | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Edit workspace | CLOSED — does not apply |

---

## A PDF whose path is found empty is looked at twice before Fill & Sign's work goes (FR52) — main only

The PDF watch dropped every placed item, typed field value, picture and undo step at the first look
that found the path empty — and a sync client or app that renames the original aside before
installing the new revision leaves it empty for longer than the 250 ms settle. `main` notes the
first empty look, keeps the work, and looks again a settle later (an event-prompted look, so an
activation look cannot stand in for the wait); a file back by then is the ordinary reload, which
keeps the items while the pages match. Only a path still empty lets the work go.

```sh
F=Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s secondLook=%s emptyPath=%s fillDrop=%s\n' $l \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF 'foundGoneOnce')" \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF 'guard let now = EditorFileStore.stamp(ofPath: path) else {')" \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF 'fill.detach()')"; done
# measured 2026-10-23; main read from the p2-edit worktree before landing:
# main  secondLook=7 emptyPath=1 fillDrop=3      (origin/main before this: secondLook=0)
# v5.x, v4.x, v3.x, v2.x  secondLook=0 emptyPath=0 fillDrop=0 — no EditorPDFDocument.swift
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No PDF in Edit at all, so no Fill & Sign work to drop | CLOSED — does not apply |

---

## A save made while autosave's write is out takes that write as the editor's own (FR50) — main only

Between autosave's swap and its main-actor commit, the file on disk is newer than the document's
stamp, and it is the editor's own. ⌘S, the flush before another file opens and the flush at ⌘Q
compared against the old stamp, raised "changed on disk", and Use Disk Version or Don't Save then
dropped what was typed after the snapshot, with its undo history. `main` has a synchronous save
that finds the file diverged while a write is out wait for that write to be done with the disk,
commit what it installed (`EditorAutosave.settleLandedWrite`), and compare again — so only a real
change is asked about. `EditorAutosave.attempt` carries it for the leave and quit flushes;
`saveEditorDocument` for ⌘S.

```sh
A=Modules/FileExplorer/Sources/FileExplorer/EditorAutosave.swift
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s settles=%s background=%s cmdS=%s\n' $l \
  "$(git show origin/$l:$A 2>/dev/null | grep -cF 'settleLandedWrite')" \
  "$(git show origin/$l:$A 2>/dev/null | grep -cF 'Task.detached(priority: .utility)')" \
  "$(git show origin/$l:MacApp/ContentView+Editor.swift 2>/dev/null | grep -cF 'if EditorAutosave.settleLandedWrite(into: editorDocument) {')"; done
# measured 2026-10-23; main read from the p2-edit worktree before landing:
# main  settles=4 background=1 cmdS=1      (origin/main before this: settles=0 cmdS=0)
# v5.x  settles=0 background=1 cmdS=0
# v4.x, v3.x, v2.x  settles=0 background=0 cmdS=0 — no EditorAutosave.swift
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The background write and the same window, unsettled | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No autosave at all, so no background write to meet | CLOSED — does not apply |

---

## Typing turned away while an autosave write was out is written when it commits (FR51) — main only

The host writes one snapshot at a time and turns the debounce away while one is out. Typing that
paused while a slow write (iCloud, an external disk) was still out had its debounce fire into that
refusal, and with the version and the path unchanged nothing restarted the wait: the last sentence
sat unsaved with nothing scheduled, so a crash lost it (quit and switching files still flushed).
`main` keys the debounce on the document's stamp as well (`EditorAutosave.Key`), so every commit
starts the wait again; a document the commit left clean schedules nothing.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s stampKeyed=%s oldKey=%s turnsAway=%s\n' $l \
  "$(git show origin/$l:MacApp/EditorAutosaveDriver.swift 2>/dev/null | grep -cF 'stamp: document.stamp)) {')" \
  "$(git show origin/$l:MacApp/EditorAutosaveDriver.swift 2>/dev/null | grep -cF 'EditorAutosave.Key(version: buffer.textVersion, path: document.path))')" \
  "$(git show origin/$l:MacApp/ContentView+Editor.swift 2>/dev/null | grep -cF 'guard !editorIsWritingInBackground else { return }')"; done
# measured 2026-10-23; main read from the p2-edit worktree before landing:
# main  stampKeyed=1 oldKey=0 turnsAway=1      (origin/main before this: stampKeyed=0 oldKey=1)
# v5.x  stampKeyed=0 oldKey=1 turnsAway=1
# v4.x, v3.x, v2.x  stampKeyed=0 oldKey=0 turnsAway=0 — no autosave
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same driver key and the same turned-away debounce | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No autosave at all | CLOSED — does not apply |

---

## The CLI resolves `-L`/`-R` by exact id first and shows both roots before it asks (FR42) — main only

`-L Dropbox` took the first provider whose id OR display name matched, so two folder sources with the
same default name, or a provider renamed to another's id, sent `sync --yes` into the wrong tree — and
`sync`'s plan never named the roots it was about to write. `main` lets an exact id win, refuses a
display name more than one provider carries (naming each id), and prints both roots in the plan.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s firstMatch=%s planRoots=%s\n' $l \
  "$(git show origin/$l:SyncCloudCLI/Sources/SyncCloudCLICore/ProviderResolution.swift 2>/dev/null | grep -cF '$0.id == value || $0.displayName == value')" \
  "$(git show origin/$l:SyncCloudCLI/Sources/SyncCloudCLICore/CommandRunner.swift 2>/dev/null | grep -cF 'printOut("  Left : \(leftURL.path) [\(leftProvider.displayName)]")')"; done
# measured 2026-10-23, against origin, before this landed (planRoots=1 is `scan`'s own line):
# main, v5.x, v4.x, v3.x, v2.x   firstMatch=1 planRoots=1
# after, in the worktree:        firstMatch=0 planRoots=2
# re-measured 2026-10-24 on main: planRoots=3 — `sync`'s "Nothing to sync automatically" prints the
# roots too
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The first-match resolution and the rootless plan (`firstMatch=1`) | RECORDED — not owed |

---

## Different sizes with no newer side are held out of bulk runs, not copied left-wins (FR39) — main only

Two files whose dates match within the tolerance (or where a side has no date) but whose sizes
differ defaulted "left as truth", and "Copy N to →" or `synccloud sync` replaced the right file — at
the 5 s and 60 s tolerances, any pair edited inside that window. `main` keeps the row, says the
dates match and the sizes differ, and marks it `FileDifference.heldBack`: `syncAll` and the CLI's
`sync` leave it out and say so. A single row copied on its own still goes ahead.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s leftTruth=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDiffEngine.swift 2>/dev/null | grep -cF 'default to left as truth')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   leftTruth=1
# after, in the worktree:        leftTruth=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The left-wins default, taken by every bulk run (`leftTruth=1`) | RECORDED — not owed |

---

## A folder against a file is held, and no longer called "newer" by the folder's date (FR40) — main only

A folder-versus-file row judged "newer" by the folder's own date, which does not move when what is
inside changes: a package edited yesterday with a 2024 folder date read as older than a single file
from last month, and the row offered to replace the package. `main` keeps the old suggested direction
for a single deliberate copy, drops the "newer" claim from the note, and holds the row out of bulk
runs (`FileDifference.HeldBack.folderVersusFile`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s newerMismatch=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDiffEngine.swift 2>/dev/null | grep -cF 'item is newer (type mismatch)')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   newerMismatch=2
# after, in the worktree:        newerMismatch=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The folder-date comparison, taken in bulk (`newerMismatch=2`) | RECORDED — not owed |

---

## A row that copies from a symbolic link is refused, not copied as a link (FR8) — main only

The scan reads a link as what it points to — a linked folder missing on the other side showed as
"Folder missing" with its item count — but the copy writes the link itself (`COPYFILE_NOFOLLOW_SRC`).
Copy finished instantly with one link back at the original, the next scan called the pair in sync,
and edits in "the copy" changed the originals. `main` records the link on `FileDiffEngine.FileInfo`
(both scan branches), notes it on the row, holds it out of bulk runs, and `syncFile` refuses it. A
folder missing on one side with a link inside that points out of it (absolute, dangling, or relative
and landing outside the folder) is held out of bulk runs too, its note naming the link
(`enclosesSymbolicLink`); copied on its own it goes ahead. A relative link that stays inside the
folder, as in an app bundle or a venv, holds nothing.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s followsLinks=%s linkFact=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDiffEngine.swift 2>/dev/null | grep -cF 'symlinked entries participate')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDiffEngine.swift 2>/dev/null | grep -cF 'public let isSymbolicLink: Bool')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x, v4.x, v3.x, v2.x   followsLinks=1 linkFact=0
# after, in the worktree:        followsLinks=1 linkFact=1
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The link-following scan with a link-writing copy (`followsLinks=1`, `linkFact=0`) | RECORDED — not owed |

---

## Read scan routes only against its own provider (FR44) — main only

Read scan routed a card through the cached router index and provider root without checking they
belonged to the card's provider. After a To File scan of another provider was cancelled mid-run, the
old cards stayed on screen over the new provider's cache, so Read scan could put a card on a folder in
the other account and "File here" would move it there. `main` refuses unless the cached root is the
card's `providerRoot`, the guard `tryAnotherFolder` already had.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s readScan=%s guarded=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+FilingRoute.swift 2>/dev/null | grep -cF 'public func readScan(for suggestion: FilingSuggestion)')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+FilingRoute.swift 2>/dev/null | grep -cF 'let root = filingLastProviderRoot, root == suggestion.providerRoot else { return false }')"; done
# measured 2026-10-23, against origin, before this landed (the working tree reads guarded=1):
# main, v5.x, v4.x   readScan=1 guarded=0
# v3.x, v2.x         readScan=0 guarded=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` | The same unguarded Read scan (`readScan=1`) | RECORDED — not owed |
| `v3.x` / `v2.x` | No Read scan (`readScan=0`) | CLOSED — does not apply |

---

## A date stamp day-first could have written is not read month-first (FR46) — main only

The rename pass read a year-last stamp whose first two pairs were both 12 or less as month-first, so
`Statement_05062023.pdf` (5 June, written day-first) was renamed into May; `05-06-2023` the same. Both
doc comments claimed `DDMMYYYY` was refused outright, true only for a day over 12. `main` refuses a
stamp both conventions could have written (`isAmbiguousDayMonth`), keeps one whose pairs are equal,
and leaves `YYYYMMDD` alone; the pass then gives the file no slot.

```sh
F=Modules/Sync/Sources/Sync/FileNameDate.swift
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s mmddyyyy=%s delimited=%s refused=%s\n' $l \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF '} else if isMonth(m1), isDay(d1), isYear(y1) {')" \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF '} else if widths == [2, 2, 4], isMonth(a), isDay(b), isYear(c) {')" \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF 'static func isAmbiguousDayMonth')"; done
# measured 2026-10-23, against origin, before this landed (the working tree reads refused=1):
# main, v5.x, v4.x   mmddyyyy=1 delimited=1 refused=0
# v3.x, v2.x         mmddyyyy=0 delimited=0 refused=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` | The same month-first reading (`mmddyyyy=1 delimited=1`) | RECORDED — not owed |
| `v3.x` / `v2.x` | No date mining in names (`mmddyyyy=0`) | CLOSED — does not apply |

---

## To File moves only the file the scan found (FR45) — main only

`performFiling` checked only that something sat at the card's path, so a file re-downloaded or saved
over that name after the scan was moved into the folder chosen for the original. `main` records each
card's `ItemIdentity` once the scan's first pass builds it (`FilingSuggestion.sourceIdentity`, carried
through every rebuild, content reading's re-suggest included) and refuses a file that has drifted since, with "This file changed since the scan…"
(`sourceChangedSinceScan`), the rule Automations' apply already follows.

```sh
F=Modules/Sync/Sources/Sync/FileSyncManager+Filing.swift
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s existsOnly=%s identity=%s\n' $l \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF 'guard fm.fileExists(atPath: src.path) else { return .failed(reason: nil) }')" \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF 'throw FileOperationError.sourceChangedSinceScan')"; done
# measured 2026-10-23, against origin, before this landed (the working tree reads identity=1):
# main, v5.x, v4.x, v3.x, v2.x   existsOnly=1 identity=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same existence-only check (`existsOnly=1`) | RECORDED — not owed |

---

## A model's new folder name is checked before it is created (FR47) — main only

`destination(from:)` refused only empty, `.`, `..` and file-looking segments, so a model-proposed
`Taxes: 2025` was created (Finder shows the `:` as `/`) and `Acme Inc.` was created on Dropbox and
OneDrive, which do not sync a trailing period. `main` holds every new segment to `validateItemName`
and the destination provider's `ProviderNameRules` (the scan's `nameProvider`, kept as
`filingLastNameProvider` for Refine and Try another) and drops a candidate that fails; existing
folders are not judged.

```sh
F=Modules/Sync/Sources/Sync/FilingEngine.swift
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s resolver=%s checked=%s\n' $l \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF 'static func destination(from verdict: FilingVerdict, providerRoot: String,')" \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF 'if FileSyncManager.validateItemName(seg) != nil { return nil }')"; done
# measured 2026-10-23, against origin, before this landed (the working tree reads checked=1):
# main, v5.x, v4.x, v3.x, v2.x   resolver=1 checked=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same resolver (`resolver=1`) | RECORDED — not owed |

---

## A download counter alone no longer makes a versions group (FR14) — main only

The versions pass took a browser's download counter " (n)" as a version marker, so `invoice.pdf`,
`invoice (1).pdf` and `invoice (2).pdf` — three months' bills with different bytes — became a "Keep
newest, Trash older" group. `main` will not stand a versions group up when the only markers in it are
counters (`hasNonCounterVersionMarker`); a " copy", "-v2" or "final" beside them still does, and a
counter re-download with the same bytes is still an identical group.

```sh
F=Modules/Sync/Sources/Sync/DuplicateFinder.swift
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s counterMarker=%s counterOnlyRefused=%s\n' $l \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF '#"\s*\(\d+\)$"#,')" \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF 'static func hasNonCounterVersionMarker')"; done
# measured 2026-10-23, against origin, before this landed (the working tree reads counterOnlyRefused=1):
# main, v5.x, v4.x, v3.x, v2.x   counterMarker=1 counterOnlyRefused=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same counter marker (`counterMarker=1`) | RECORDED — not owed |

---

## "Trash right copy" refuses a copy holding what the left lacks (FR13) — main only

Compare copies is offered for every group, overlapping ones included, and its "Trash right copy"
checked only that the pair was unchanged since the scan, so an overlapping right folder "12 unique
here" went to the Trash with those twelve inside, under a dialog that said only "The left copy is
kept." `main` refuses before asking when the scan's `uniqueItemCount` or the two baselines say the
right copy holds items the left lacks, names them, and points to Merge into keeper
(`uniqueItemsRefusal`).

```sh
F=MacApp/DuplicateReviewCoordinator.swift
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s trashRight=%s uniqueRefused=%s\n' $l \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF 'func trashRightCopy(_ review: DuplicateCompareContext)')" \
  "$(git show origin/$l:$F 2>/dev/null | grep -cF 'static func uniqueItemsRefusal')"; done
# measured 2026-10-23, against origin, before this landed (the working tree reads uniqueRefused=1):
# main, v5.x, v4.x, v3.x, v2.x   trashRight=1 uniqueRefused=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same unchecked trash (`trashRight=1`) | RECORDED — not owed |

---

## A folder holding only the user's dot-files is not removed as empty (FR18) — main only

The removal step's "still empty" skipped every file whose name began with ".", so a folder holding
only `.env`, `.gitignore` or an office lock file went to the Trash, and Undo recreated it empty.
`main` ignores only OS noise (`ItemIdentity.deepIdentityIgnoredNames`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s dotSkip=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+RestructureApply.swift 2>/dev/null | grep -cF 'if !isDir && !url.lastPathComponent.hasPrefix(".") { files += 1 }')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         dotSkip=1
# v4.x, v3.x, v2.x   dotSkip=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same removal step (`dotSkip=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Restructure (`dotSkip=0`) | CLOSED — does not apply |

---

## A rename refused as drift refuses the merges planned into it (FR19) — main only

When a rename's destination appeared before the landing, the rename was skipped "rather than merged
unreviewed" and the merges planned into that destination landed there anyway. `main` skips every
later action that moves into, out of, or creates beneath the refused destination, with a sentence.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s renameSkip=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+RestructureApply.swift 2>/dev/null | grep -cF 'was skipped rather than merged unreviewed')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         renameSkip=1
# v4.x, v3.x, v2.x   renameSkip=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same rename skip (`renameSkip=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Restructure (`renameSkip=0`) | CLOSED — does not apply |

---

## Undo puts a merged file back even after its emptied folder was trashed (FR20) — main only

A merge empties its source folder; a person tidies it away; the ledger Undo's move-back into it then
failed, the rename-back after it succeeded, and the merged files rode it into a folder they never
lived in under a record marked undone. `main`'s inverse recreates the folder each item came out of.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s undoCall=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+RestructureApply.swift 2>/dev/null | grep -cF 'vetoUnlistedSourceFolders: false)')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         undoCall=1
# v4.x, v3.x, v2.x   undoCall=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same ledger Undo (`undoCall=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Restructure (`undoCall=0`) | CLOSED — does not apply |

---

## A quit during the re-derive keeps the landing's Undo (FR17) — main only

The re-derive re-pointed `profiles.json` at the new profile folder, then spent seconds replaying the
corpus before the roster, verdicts and ledger reached that folder and the record named it as
produced. A quit in that wait relaunched onto a folder offering no Undo, and ⌘Q did not ask: it counted only
queued file operations. `main` carries them, and the undo chain, before the re-point, and its quit
guard counts a landing in progress. With no record then naming the folder left behind, the retire
sweep keeps any folder holding a survey corpus or memory the active one lacks, or a stopped survey's
progress while the active one has neither progress nor a corpus.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s rederive=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+RestructureApply.swift 2>/dev/null | grep -cF 'private func rederiveProfile(')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         rederive=1
# v4.x, v3.x, v2.x   rederive=0
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s quitCount=%s\n' $l \
  "$(git show origin/$l:MacApp/SyncCloudApp.swift 2>/dev/null | grep -cF 'let activeOperations = manager?.activeFileOperationsCount ?? 0')"; done
# main, v5.x, v4.x, v3.x, v2.x   quitCount=1 — every line has the guard; only rederive=1 lines land
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same re-derive (`rederive=1`) and quit guard | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Restructure (`rederive=0`) | CLOSED — does not apply |

---

## People edits during a re-derive land in the folder the app reads (FR5, again) — main only

The re-derive copied the roster, person verdicts and Restructure's answers into the new profile
folder, then kept the stores open on the old folder through seconds of corpus replay. An edit made in
that window was written to the old folder and read by nothing afterwards. `main` opens the stores on
the new folder as soon as it is active.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s rederive=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+RestructureApply.swift 2>/dev/null | grep -cF 'private func rederiveProfile(')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         rederive=1
# v4.x, v3.x, v2.x   rederive=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same re-derive (`rederive=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Restructure (`rederive=0`) | CLOSED — does not apply |

---

## A stopped document survey keeps its resume point through a landing (FR6) — main only

`survey-progress.json` lives in the profile folder, and neither a landing nor a survey refresh
carried it to the folder it minted, so a stopped survey restarted from 0 and the retire sweep later
deleted the old folder holding it. `main` carries it, rekeyed through the landing like the corpus.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s checkpoint=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/DocumentSurveyCheckpoint.swift 2>/dev/null | grep -cF 'public static let filename = "survey-progress.json"')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         checkpoint=1
# v4.x, v3.x, v2.x   checkpoint=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same checkpoint and re-derive (`checkpoint=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No document survey (`checkpoint=0`) | CLOSED — does not apply |

---

## Edits made after a landing survive its Undo (FR7) — main only

Undo re-pointed the survey at the folder the landing started from and re-opened every store there,
so people added, verdicts given, findings suppressed, drafts saved and scaffolds landed after the
landing stayed in the produced folder, read by nothing. `main` carries them back onto that folder,
Restructure's keys rekeyed through the renames the undo performed.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s ledgerUndo=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+RestructureApply.swift 2>/dev/null | grep -cF 'public func undoReorganisation(')"; done
# measured 2026-10-23, against origin, before this landed:
# main, v5.x         ledgerUndo=1
# v4.x, v3.x, v2.x   ledgerUndo=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same ledger Undo (`ledgerUndo=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Restructure (`ledgerUndo=0`) | CLOSED — does not apply |

---

## A sync's Replace takes the source's permissions and creation date (FR32) — main only

`replaceItemAt`'s default merge kept the old destination's permissions and creation date, so a
script made executable at the source stayed non-executable after every sync. `main` installs a
Replace with `.usingNewMetadataOnly` through `FileManaging.installReplacement`; Edit's in-place save
keeps the original's metadata through the plain `replaceItem`, as before.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s mergedMeta=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileManaging.swift 2>/dev/null | grep -cF 'options: [.withoutDeletingBackupItem]')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads 0 here):
# main, v5.x, v4.x, v3.x, v2.x   mergedMeta=1
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same merged-metadata Replace (`mergedMeta=1`) | RECORDED — not owed |

---

## A move onto another volume takes the staged, Trash-first path (FR33) — main only

Foundation's `moveItem` copies and unlinks by itself across volumes rather than throwing EXDEV, so
the staged copy that watches Cancel and puts the original in the Trash never ran for a move to an
external disk: the original was deleted outright. `main` compares the two volumes before asking
`moveItem` (`isCrossVolumeMove`) and routes a cross-volume move through the staged path.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s upFront=%s moveFirst=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations+Primitives.swift 2>/dev/null | grep -cF 'func isCrossVolumeMove')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations+Primitives.swift 2>/dev/null | grep -cF 'Fallback for cross-volume moves (EXDEV)')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads upFront=1):
# main, v5.x, v4.x, v3.x, v2.x   upFront=0 moveFirst=1
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same moveItem-first move (`upFront=0`) | RECORDED — not owed |

---

## A Finder-locked file can be copied, and a failed attempt leaves no staging copy (FR31) — main only

A copy carries the source's `uchg`/`uappnd` onto its `.tmp_` staging copy, which can then be neither
installed nor removed, so a locked file never copied and each attempt left a hidden full-size copy.
`main` lifts the lock on the staged copy only, locks the installed copy again, removes a staging
item's inner locks when it must sweep one, refuses moving a locked item up front
(`itemIsLocked`), and lets the orphan sweep Trash a locked `.tmp_`.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s plainCleanup=%s lockedCase=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations+Primitives.swift 2>/dev/null | grep -cF 'defer { try? fileManager.removeItem(at: tempURL) }')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations+Primitives.swift 2>/dev/null | grep -cF 'case itemIsLocked')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads plainCleanup=0 lockedCase=1):
# main, v5.x, v4.x, v3.x, v2.x   plainCleanup=2 lockedCase=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same lock-carrying staging (`plainCleanup=2`) | RECORDED — not owed |

---

## A folder copy asks a dataless folder's cloud app first (FR34) — main only

A copy's recursive walk lists every folder it reaches, and listing a dataless folder whose provider
is not running blocks for good — with no deadline, Cancel unheard, and every later operation queued
behind it. `main` walks a folder before staging it, asks each dataless folder through
`DatalessFolderReads` (bounded), and refuses the copy as `folderNotAnswered` when one does not answer.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s check=%s reads=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations+Primitives.swift 2>/dev/null | grep -cF 'func requireContentsOnThisMac')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/DatalessFolderReads.swift 2>/dev/null | grep -cF 'public final class DatalessFolderReads')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads check=1):
# main, v5.x         check=0 reads=1
# v4.x, v3.x, v2.x   check=0 reads=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The bounded reads, but an unchecked copy walk (`check=0 reads=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No dataless-folder handling at all (`reads=0`) | RECORDED — not owed |

---

## A redo does not replace what it did not put there (FR25) — main only

The copy-redo and move-redo called `safeCopyItem`/`safeMoveItem` straight onto the destination, so a
file saved there by another app between ⌘Z and ⌘⇧Z went to the Trash unasked (the copy-redo's
comment claimed the user was asked). `main` records what each undo left at the destination and
refuses a redo, with a banner, when something else is there now (`redoDestinationVerdict`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s copyRedo=%s guard=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift 2>/dev/null | grep -cF 'func registerCopyRedo')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift 2>/dev/null | grep -cF 'func redoDestinationVerdict')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads guard=1):
# main, v5.x, v4.x, v3.x, v2.x   copyRedo=1 guard=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same unguarded redos (`guard=0`) | RECORDED — not owed |

---

## "Undo Last Run" reverses only the run it showed (FR26) — main only

A run armed its pairing after awaiting its identity walks, so a rename or ⌘Z during that tail was
paired with the run's records; and a second same-named run finishing behind the modal
confirmation re-armed the pairing, so Undo reversed a run the alert never listed. `main` arms the
pairing in the registration's own turn and gives each arming a token that the confirmation
(`undoLastSyncRunAskingFirst`) checks again after the modal, refusing on a mismatch.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s token=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager.swift 2>/dev/null | grep -cF 'lastRecordedRunToken')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads token=5):
# main, v5.x, v4.x, v3.x, v2.x   token=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same late, token-less pairing (`token=0`) | RECORDED — not owed |

---

## A reload during the form question does not pass the changed check (FR54) — main only

A PDF tool's run fixed the tool and its page numbers before the form-loss question, then re-checked
the file against the live `shownStamp` — which a reload landing while the question was up had
already moved to the new revision, so Extract or a pending reorder ran on it with the old page
numbers. `main` captures the stamp once when the run starts and checks against that.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s run=%s captured=%s\n' $l \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorPDFTools.swift 2>/dev/null | grep -cF 'func run(_ asked: EditorPDFTool')" \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorPDFTools.swift 2>/dev/null | grep -cF 'let shownStamp = self.shownStamp')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads run=1 captured=1):
# main                    run=1 captured=0
# v5.x, v4.x, v3.x, v2.x  run=0 captured=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No PDF tools in Edit (`run=0`) | CLOSED — does not apply |

---

## A refused Keychain save keeps the old key and the typed one (FR58) — main only

Saving the Anthropic API key deleted the Keychain item and then added the new one, so a Keychain
that allowed the delete and refused the add left no key at all — and Settings cleared the field
the new key was typed in whatever the status, so both were gone. `main` replaces the item in place
(`SecItemUpdate`, `SecItemAdd` only when there is none) and keeps the typed key in the field when
the store did not land (`CloudKeyRow.afterSave`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s save=%s deleteThenAdd=%s update=%s\n' $l \
  "$(git show origin/$l:Modules/Settings/Sources/Settings/CloudKeyRow.swift 2>/dev/null | grep -cF 'private func saveTypedKey')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/AnthropicKeychain.swift 2>/dev/null | grep -cF 'store.delete(query)   // idempotent replace')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/AnthropicKeychain.swift 2>/dev/null | grep -cF 'store.update(baseQuery()')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads deleteThenAdd=0 update=1):
# main, v5.x, v4.x, v3.x, v2.x   save=1 deleteThenAdd=1 update=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same delete-then-add and cleared field (`deleteThenAdd=1`) | RECORDED — not owed |

---

## A link under a Cover and Retype patch is said to stay live (FR56) — main only

The toolkit puts a page's links back on every page Fill & Sign redraws, so a correction typed over
a web address or an email still opened the old one, and the note card said only that the covered
words stay searchable. Removing the link would mean rewriting the copy with PDFKit, which drops the
catalog parts the toolkit carries, so `main` says it instead: a pick records whether a link reaches
under its patch (`overLink`), and that page's note adds "A link under the patch still opens where
it did." A page made a picture loses its links, and its note does not say it.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s correction=%s linkNote=%s\n' $l \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorPDFReplace.swift 2>/dev/null | grep -cF 'public struct EditorPDFCorrection:')" \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSign.swift 2>/dev/null | grep -cF 'linkUnderPatchNote')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads correction=1 linkNote=2):
# main                    correction=1 linkNote=0
# v5.x, v4.x, v3.x, v2.x  correction=0 linkNote=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No Cover and Retype (`correction=0`) | CLOSED — does not apply |

---

## A flat Fill & Sign save says it flattens the file's comments (FR57) — main only

Fill & Sign without a form redraws every page and draws its annotations in, so the file's own
review comments — sticky notes, highlights, drawings — came out as ink, and a closed sticky note's
text was not in the copy at all, with nothing said. `main` reads the comments with the facts
(`EditorPDFComments`) and the flat path's note card says they will be flattened, and, when there is
a sticky note, that its text won't be kept.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s formNotes=%s comments=%s\n' $l \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSign.swift 2>/dev/null | grep -cF 'public var formNotes')" \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/EditorPDFDocument.swift 2>/dev/null | grep -cF 'struct EditorPDFComments')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads formNotes=1 comments=1):
# main                    formNotes=1 comments=0
# v5.x, v4.x, v3.x, v2.x  formNotes=0 comments=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No Fill & Sign (`formNotes=0`) | CLOSED — does not apply |

---

## Filing into the file's own folder through a link is a no-op (FR9) — main only

`namesSameDirectory` folds case but resolves no links, so a destination reached through a folder
link to the file's own folder read as another folder: the move found the file itself through the
link and renamed it in place to "name 2" under a "Filed" banner. `main` compares the apply step's
and the automation preview's paths again after resolving links (`resolvesToSameDirectory`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s same=%s resolved=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/PathBoundary.swift 2>/dev/null | grep -cF 'func namesSameDirectory')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/PathBoundary.swift 2>/dev/null | grep -cF 'func resolvesToSameDirectory')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads resolved=1):
# main, v5.x, v4.x, v3.x, v2.x   same=1 resolved=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same link-blind comparison (`resolved=0`) | RECORDED — not owed |

---

## `synccloud sync` exits non-zero when a file changed after the plan (FR43) — main only

A row skipped because one end changed while the prompt waited was reported but exited `0`, so a
script that deletes sources after a clean exit would delete a file that never copied. `main` exits
`1` (the partial-failure code) for that skip, with its own stderr line; collision, name-rule and
needs-decision skips stay at `0`. The README's exit-code line says so.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s stale=%s exits=%s\n' $l \
  "$(git show origin/$l:SyncCloudCLI/Sources/SyncCloudCLICore/CollisionHandling.swift 2>/dev/null | grep -cF 'case changedSincePlan')" \
  "$(git show origin/$l:SyncCloudCLI/Sources/SyncCloudCLICore/CollisionHandling.swift 2>/dev/null | grep -cF 'tally.failed > 0 || !staleSkips.isEmpty')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads exits=1):
# main, v5.x, v4.x   stale=1 exits=0
# v3.x, v2.x         stale=0 exits=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` | The same stale-row skip, exiting `0` (`exits=0`) | RECORDED — not owed |
| `v3.x` / `v2.x` | No stale-row re-check, so no such skip (`stale=0`) | CLOSED — does not apply |

---

## A case-variant subfolder merges one level down (FR22) — main only

The merge's subfolder occupancy matched by exact case, so `Payment/Receipts/` merging into a
target holding `receipts/` was planned "Carried whole" and the apply, finding the other spelling
on a case-insensitive volume, skipped it as "appeared since the plan". `main` folds case there, as
the member-level test does, and merges one level down into the spelling on disk (`occupant(named:in:)`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s merge=%s folded=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/RestructurePlanner.swift 2>/dev/null | grep -cF 'func emitMerge')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/RestructurePlanner.swift 2>/dev/null | grep -cF 'func occupant(named')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads folded=1):
# main, v5.x         merge=1 folded=0
# v4.x, v3.x, v2.x   merge=0 folded=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same exact-case occupancy (`folded=0`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Restructure merge (`merge=0`) | CLOSED — does not apply |

---

## Restructure's listings ask a cloud-only folder for a bounded time (FR21) — main only

The plan view listed with `contentsOfDirectory` on the main actor, and a landing's emptiness walk
and unlisted-file veto with plain enumerators inside the file queue — none through
`DatalessFolderReads`, so a cloud-only folder whose app had stopped hung the plan sheet or wedged a
landing. The veto also read an unreadable folder as empty. `main` asks first
(`waitForContentsBlocking`, or `listing(of:)` for the veto) and treats an unanswered folder as
unreadable: the plan refuses, whether the folder is a merge's source or its destination, the folder
is kept, the veto skips it.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s planner=%s blocking=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/RestructurePlanner.swift 2>/dev/null | grep -cF 'struct RestructureTreeView')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/DirectoryListing.swift 2>/dev/null | grep -cF 'func waitForContentsBlocking')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads blocking=1):
# main, v5.x         planner=1 blocking=0
# v4.x, v3.x, v2.x   planner=0 blocking=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same unbounded Restructure listings (`blocking=0`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Restructure (`planner=0`) | CLOSED — does not apply |

---

## A landing keeps its journal until its record is on disk (FR16, follow-up) — main only

The landing removed its journal right after finalising its ledger record, even when that write
failed; the next launch then refused Undo with "No list of the steps that ran was found." `main`
makes `updateApplied` report whether the record was written and keeps the journal when it was not.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s journal=%s kept=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+RestructureApply.swift 2>/dev/null | grep -cF 'final class RestructureLandingJournal')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+RestructureApply.swift 2>/dev/null | grep -cF 'if finalised {')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads kept=1):
# main                     journal=1 kept=0
# v5.x, v4.x, v3.x, v2.x   journal=0 kept=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No landing journal (`journal=0`) | CLOSED — does not apply |

---

## The content-hash cache keys on the file number and status-change time (FR59) — main only

Verify trusted a persisted, 30-day digest keyed by path, mtime and size, so an edit that restores
the date and keeps the size (`exiftool -P`, `touch -r`, `rsync -t`) read as identical, and Duplicates'
persisted document fingerprints had the same key, so a same-size copy over a document under its dates
was called "same text". `main` adds `st_ino` and `st_ctime` — which no tool can restore — to both
keys; an entry stored without them can never match a real file's key again and ages out.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s persist=%s ctime=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/ContentHashCache.swift 2>/dev/null | grep -cF 'func enablePersistence')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/ContentHashCache.swift 2>/dev/null | grep -cF 'statusChanged')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads ctime=6):
# main, v5.x, v4.x, v3.x   persist=1 ctime=0
# v2.x                     persist=0 ctime=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` | The same persisted (path, mtime, size) key (`ctime=0`) | RECORDED — not owed |
| `v2.x` | An in-memory cache only (`persist=0`): the same blind spot, for one session | RECORDED — not owed |

---

## "Undo Last Run" says what this run's undo does (FR29) — main only

The confirmation always ended "Files move back to where they were; deleted items are restored from
the Trash", which misdescribes undoing a copy run: the copies go to the Trash. `main` builds the
sentence from the run's own actions (`SyncRunUndoPreview.reversalNote`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s sentence=%s note=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/SyncRunUndoPreview.swift 2>/dev/null | grep -cF 'Files move back to where they were')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/SyncRunUndoPreview.swift 2>/dev/null | grep -cF 'var reversalNote')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads sentence=0 note=1):
# main, v5.x, v4.x, v3.x, v2.x   sentence=1 note=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same fixed sentence (`sentence=1`) | RECORDED — not owed |

---

## An undo restores only what it put in the Trash (FR27) — main only

Every undo that restores from the Trash — a delete's, and the backup a copy or move replaced — moved
whatever sat at the recorded Trash path. Empty the Trash, trash a different file of the same name,
and macOS hands it the freed name: ⌘Z moved that unrelated file into place. `main` records each
backup's identity when its undo registers and refuses a restore whose Trash item differs, with a
banner naming it (`trashBackupVerdict`). A backup nothing could be read of at registration restores
as before; one unreadable at ⌘Z refuses before the copy is trashed or the item moved back.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s restore=%s verdict=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift 2>/dev/null | grep -cF 'func registerRestoreItems(stateResolver')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift 2>/dev/null | grep -cF 'func trashBackupVerdict')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads verdict=1):
# main, v5.x, v4.x, v3.x, v2.x   restore=1 verdict=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same path-only Trash restores (`verdict=0`) | RECORDED — not owed |

---

## A dangling link is not "vanished" to an undo (FR28) — main only

The copy-undo and move-undo asked `fileExists`, which follows links, whether their item had gone. A
moved relative link usually dangles, so ⌘Z reported it "no longer on disk", never moved it back, and
then failed to restore the displaced original over it under a banner blaming the Trash. `main` asks
without following (`entryExists`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s vanish=%s noFollow=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift 2>/dev/null | grep -cF 'is no longer on disk')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift 2>/dev/null | grep -cF 'func entryExists(at url: URL')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads noFollow=1):
# main, v5.x, v4.x, v3.x, v2.x   vanish=3 noFollow=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same link-following checks (`noFollow=0`) | RECORDED — not owed |

---

## ⌘Z of a locked file's copy puts that copy in the Trash — main only

A copy of a file locked in Finder carries the lock, and the kernel refuses to Trash a locked item,
so the copy-undo read the refusal as "busy" and asked for a retry that could never work. `main`
lifts the lock the copy carried from its source off that copy alone (`liftCopiedLock`), and refuses
with its own banner a lock someone put on the copy since.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s lockedCopy=%s lift=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations+Primitives.swift 2>/dev/null | grep -cF 'restoreLock(lock, on: destinationURL')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift 2>/dev/null | grep -cF 'func liftCopiedLock')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads lockedCopy=4 lift=1):
# main, v5.x, v4.x, v3.x, v2.x   lockedCopy=0 lift=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No locked-file copy at all (`lockedCopy=0`), so no locked copy to undo | CLOSED — does not apply |

---

## A merge-move's ⌘Z puts back the original source folder (FR35) — main only

A move's merge put the emptied source folder in the Trash outside the undo record, so ⌘Z made a new
empty folder for the children (the original's tags, icon and dates lost, its shell left in the
Trash). `main` records the trashed folder as a move to its Trash location, ahead of its children,
so the undo restores it — identity-checked, deep with OS noise ignored like every Trash backup, so a
look at it in Finder does not refuse it, and by its own file number, so another empty folder trashed
under its freed name is not taken for it — before moving them back (`undoItems(_:restoringFirst:)`).
Its redo trashes the folder again only under the merge's own rule, nothing left in it but a
`.DS_Store` (`mergeLeftNothing`): a child whose redo was refused keeps the folder in place.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s mergeTrash=%s restoreFirst=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations.swift 2>/dev/null | grep -cF 'the emptied folder went to the Trash')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations.swift 2>/dev/null | grep -cF 'restoringFirst folders')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads restoreFirst=1):
# main, v5.x         mergeTrash=1 restoreFirst=0
# v4.x, v3.x, v2.x   mergeTrash=0 restoreFirst=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same merge, trashing its source outside the undo (`mergeTrash=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No folder merge at all (`mergeTrash=0`) | CLOSED — does not apply |

---

## A move that leaves its original parked says so (FR36) — main only

A move whose source cleanup parked the original under `.synccloud-trash-retry-<UUID>` and could not
put it back returned success: the Moved banner showed while the hidden duplicate stayed in the
source folder, reported only in the log. `main` collects the strand for the operation that ran the
move (`ParkedSourceLeftovers`) and presents `SyncError.movedButOriginalParked`, naming the leftover.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s retry=%s sink=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations.swift 2>/dev/null | grep -cF 'func retriedSourceCleanupTrash')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileOperations.swift 2>/dev/null | grep -cF 'final class ParkedSourceLeftovers')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads sink=1):
# main, v5.x         retry=1 sink=0
# v4.x, v3.x, v2.x   retry=0 sink=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same silent strand (`retry=1 sink=0`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No park-and-retry in the move cleanup (`retry=0`) | CLOSED — does not apply |

---

## "Copy to match dates" matches dates (FR41) — main only

The run after Verify All copied each byte-identical pair over whole — a re-upload, a backup of an
identical file in the Trash, the right side's tags replaced — and could write a left-side link over
a real file. `main` sets the right file's modification date to the left's for a pair Verify proved
identical (`matchDatesOfProvenPairs`, undoable), keeps the copy only for an unproven pair, and
leaves held rows and links on either side out.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s bulk=%s dates=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+BulkSync.swift 2>/dev/null | grep -cF 'func bulkCopyDifferencesLeftToRight')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+BulkSync.swift 2>/dev/null | grep -cF 'func matchDatesOfProvenPairs')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads dates=1):
# main, v5.x, v4.x, v3.x, v2.x   bulk=1 dates=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same whole-file copy over identical pairs (`dates=0`) | RECORDED — not owed |

---

## The Compare header neither counts nor copies a held row — main only

The header's Copy counts still included rows held out of bulk runs (`FileDifference.heldBack`), and
with exactly one row targeted it went through `syncFile` and copied a held row. `main` gives the
counts and the button one rule (`DifferenceActionTargets.transferItems`), and ⌘→ and the bulk
context menu the same exclusion (`DifferencesShortcutRules.transferItems`) — except a held row
selected alone, which ⌘→ still copies.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s heldBack=%s rule=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDifference.swift 2>/dev/null | grep -cF 'public let heldBack')" \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DifferencesQuery.swift 2>/dev/null | grep -cF 'func transferItems(_ direction')"; done
# measured 2026-10-23, against origin, before this landed (the fix reads heldBack=1 rule=1):
# main, v5.x, v4.x, v3.x, v2.x   heldBack=0 rule=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No held rows at all (`heldBack=0`) | CLOSED — does not apply |

---

## Each Setup folder keeps its own Restructure history (FR4, follow-up) — main only

FR4's carry copied `restructure.json` and `person-tags.json` on every Setup walk, so a walk of
another folder inherited the first folder's path-keyed suppressions, answers, drafts and person
verdicts (a suggestion hidden at `Tax/Forms` in one folder stayed hidden at `Tax/Forms` in the next).
`main` records the folder left in `profiles/restructure-roots.json` (`RestructureRootMap`), starts
the new folder's own ledger and verdict file or takes its earlier ones up again with its Undo —
unless a landing in an overlapping folder has reshaped the tree since, which the card then says —
and
`retireSupersededProfiles` keeps every folder the map names and the profiles its landings name. The
roster, `people.json`, still follows every walk.

```sh
S=Modules/Sync/Sources/Sync
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s walkWrite=%s walkCarry=%s rootMap=%s\n' $l \
  "$(git show origin/$l:$S/FileSyncManager+FolderWalk.swift 2>/dev/null | grep -cF 'func writeWalkProfile')" \
  "$(git show origin/$l:$S/FileSyncManager+FolderWalk.swift 2>/dev/null | grep -cF 'static func carryCuratedState')" \
  "$(git show origin/$l:$S/RestructureRootMap.swift 2>/dev/null | grep -cF 'public enum RestructureRootMap')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads rootMap=1):
# main               walkWrite=1 walkCarry=1 rootMap=0
# v5.x               walkWrite=1 walkCarry=0 rootMap=0
# v4.x, v3.x, v2.x   walkWrite=0 walkCarry=0 rootMap=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The walk with no carry at all (`walkCarry=0`): nothing crosses folders; FR4's row records what it lacks | CLOSED — does not apply |
| `v4.x` / `v3.x` / `v2.x` | No walk profile (`walkWrite=0`) | CLOSED — does not apply |

---

## Restructure never plans inside a package, and the survey never surveys one (review R3) — main only

The survey descended into packages, so a `.band`, a `.pages` or a Photos library had its insides
surveyed as folders, and Restructure's disk view refused only a path that was itself a package — a
finding about `Song.band/Media` could be planned, moving a document's insides. `main` counts a
package as one document in its folder (`FolderSurveyBuilder.partition`, `isSurveyedFolder`) and the
disk view lists no path with a package anywhere above it.

```sh
S=Modules/Sync/Sources/Sync
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s fromDisk=%s survey=%s surveyPkg=%s\n' $l \
  "$(git show origin/$l:$S/RestructurePlanner.swift 2>/dev/null | grep -cF 'public static func fromDisk')" \
  "$(git show origin/$l:$S/FolderSurveyBuilder.swift 2>/dev/null | grep -cF 'static func partition')" \
  "$(git show origin/$l:$S/FolderSurveyBuilder.swift 2>/dev/null | grep -cF '!node.isPackage')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads surveyPkg=2):
# main, v5.x   fromDisk=1 survey=1 surveyPkg=0
# v4.x         fromDisk=0 survey=1 surveyPkg=0
# v3.x, v2.x   fromDisk=0 survey=0 surveyPkg=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Both: a survey that descends into packages and the disk view (`fromDisk=1`) | RECORDED — not owed |
| `v4.x` | The survey half; no Restructure (`fromDisk=0`), so nothing plans a move inside one | RECORDED — not owed |
| `v3.x` / `v2.x` | No folder survey (`survey=0`) | CLOSED — does not apply |

---

## A plan over cloud-only folders waits once, not once per folder (review R8) — main only

The plan view asks a cloud-only folder for its contents for a bounded time (FR21), but each such
folder waited out the deadline the first time it went unanswered, on the main actor, one after
another — a family of folders whose cloud app had stopped held the plan sheet several seconds per
folder. `main`'s disk view (`RestructureTreeView.fromDisk`) lists every later cloud-only folder as
unknown at once after the first goes unanswered; the plan is refused either way.

```sh
S=Modules/Sync/Sources/Sync
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s fromDisk=%s askFirst=%s stall=%s\n' $l \
  "$(git show origin/$l:$S/RestructurePlanner.swift 2>/dev/null | grep -cF 'public static func fromDisk')" \
  "$(git show origin/$l:$S/RestructurePlanner.swift 2>/dev/null | grep -cF 'waitForContentsBlocking(of: url)')" \
  "$(git show origin/$l:$S/RestructurePlanner.swift 2>/dev/null | grep -cF 'stall.unanswered')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads stall=2):
# main               fromDisk=1 askFirst=1 stall=0
# v5.x               fromDisk=1 askFirst=0 stall=0
# v4.x, v3.x, v2.x   fromDisk=0 askFirst=0 stall=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The disk view with no bounded ask at all (`askFirst=0`): it hangs rather than waits; FR21's row records that | CLOSED — does not apply |
| `v4.x` / `v3.x` / `v2.x` | No Restructure (`fromDisk=0`) | CLOSED — does not apply |

---

## Setup's Save waits for a landing to finish (review R5) — main only

Setup's Save could write a walk profile while a reorganization was landing. The landing's re-derive
then published its own profile at the end of its corpus replay, over the one just saved, and the
walk's carry copied files the landing was still writing. `main` refuses the walk's write while a
landing is in progress (`FolderWalkFailure.landingInProgress`) and says so on the Structure screen.

```sh
S=Modules/Sync/Sources/Sync
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s walkWrite=%s landing=%s walkGuard=%s\n' $l \
  "$(git show origin/$l:$S/FileSyncManager+FolderWalk.swift 2>/dev/null | grep -cF 'func writeWalkProfile')" \
  "$(git show origin/$l:$S/FileSyncManager+RestructureApply.swift 2>/dev/null | grep -cF 'restructureLandingInProgress = true')" \
  "$(git show origin/$l:$S/FileSyncManager+FolderWalk.swift 2>/dev/null | grep -cF 'case landingInProgress')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads walkGuard=1):
# main, v5.x         walkWrite=1 landing=3 walkGuard=0
# v4.x, v3.x, v2.x   walkWrite=0 landing=0 walkGuard=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | Both the walk and the landing (`walkWrite=1 landing=3`), unguarded | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No walk profile (`walkWrite=0`) | CLOSED — does not apply |

---

## A dotted file the plan never read stops a merge out of its folder (review R10) — main only

The landing's unlisted-file rule skipped every dotted name, so a merge drained a folder around a
`.env` or `.gitignore` the plan had never read and left it behind, split from the files it belongs
with. `main` ignores only OS noise there (`ItemIdentity.deepIdentityIgnoredNames`), as FR18 did for
the emptiness walk, and refuses the drain otherwise.

```sh
S=Modules/Sync/Sources/Sync
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s veto=%s dotted=%s\n' $l \
  "$(git show origin/$l:$S/FileSyncManager+RestructureApply.swift 2>/dev/null | grep -cF 'func sourceFolderVeto')" \
  "$(git show origin/$l:$S/FileSyncManager+RestructureApply.swift 2>/dev/null | grep -cF 'listed.filter { !$0.hasPrefix(".") }')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads dotted=0):
# main, v5.x         veto=1 dotted=1
# v4.x, v3.x, v2.x   veto=0 dotted=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` | The same dotted-name filter (`dotted=1`) | RECORDED — not owed |
| `v4.x` / `v3.x` / `v2.x` | No Restructure landing (`veto=0`) | CLOSED — does not apply |

---

## The last check's keeper refusal is one lookup, and says what it refused (FR10, again) — main only

The removal gate's FR10 check asked every listed keeper about every copy — O(copies × keepers) on
the main actor, 2.1 s for 1,000 groups and 35.6 s for 3,000 — and filed its refusal as drift, so the
banner and log said a copy "changed since it was scanned" when the keepers had moved under it.
`main` builds every keeper's ancestor set once (`pathsHoldingKeepers`) and gives the refusal its
own kind (`.holdsKeeper`), banner and log line.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s gate=%s holds=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Duplicates.swift 2>/dev/null | grep -cF 'it holds the copy another group keeps')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+Duplicates.swift 2>/dev/null | grep -cF 'case holdsKeeper')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads holds>=1):
# main               gate=1 holds=0
# v5.x, v4.x, v3.x, v2.x   gate=0 holds=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No FR10 check in the gate at all (`gate=0`) | CLOSED — does not apply |

---

## Trash right copy refuses a copy another group's decision holds — main only

The Compare review's "Trash right copy" checked neither that the right folder sits inside a folder
another group keeps (`isProtectedFromRemoval`) nor that it is, or holds, a group's current keeper,
so it could trash what the recommended removal never offers — a keeper picked by hand on the card
included. `main` refuses both before asking and again at the removal gate, in the Compare Copies
pair's wording (`refuseRemovalIfHeld`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s trashRight=%s held=%s\n' $l \
  "$(git show origin/$l:MacApp/DuplicateReviewCoordinator.swift 2>/dev/null | grep -cF 'func trashRightCopy')" \
  "$(git show origin/$l:MacApp/DuplicateReviewCoordinator.swift 2>/dev/null | grep -cF 'refuseRemovalIfHeld')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads held=2):
# main, v5.x, v4.x, v3.x, v2.x   trashRight=1 held=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same button, with neither check (`held=0`) | RECORDED — not owed |

---

## The duplicate scan reads nothing under `.git`, `node_modules` or `.build` — main only

The grouping stops at an ignored name, but the scan still hashed, fingerprinted and link-checked
everything below one — a repository's objects read for digests nothing could group, every PDF in
`node_modules` parsed, and their hard links counted in the "outside duplicate detection" note.
`main` drops those subtrees from the files it measures (`flattenFiles(_:skipping:)`).

```sh
S=Modules/Sync/Sources/Sync
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s collectSkips=%s pruned=%s\n' $l \
  "$(git show origin/$l:$S/DuplicateFinder.swift 2>/dev/null | grep -cF 'if options.ignoredNames.contains(node.name)')" \
  "$(git show origin/$l:$S/FileSyncManager+Duplicates.swift 2>/dev/null | grep -cF 'flattenFiles(tree, skipping: options.ignoredNames)')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads pruned=1):
# main, v5.x, v4.x, v3.x, v2.x   collectSkips=1 pruned=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | The same reads under ignored names (`pruned=0`) | RECORDED — not owed |

---

## Matched dates land to the nanosecond (FR41, follow-up) — main only

"Copy to match dates" set the right file's date with `setAttributes`, which rounds to the
microsecond: at the "Exact match" tolerance most matched pairs still differed by up to 6e-7 s and
came back on the next scan, and Redo after an Undo found nearly every file "changed since" and left
it alone. `main` writes the date with `utimensat` to the nanosecond
(`FileManaging.setModificationDate`), for the match, its Undo and its Redo, and the Undo log says
how many files changed since and how many could not be re-dated.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s dates=%s exact=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+BulkSync.swift 2>/dev/null | grep -cF 'func matchDatesOfProvenPairs')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileManaging.swift 2>/dev/null | grep -cF 'func setModificationDate')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads exact=3):
# main                     dates=1 exact=0
# v5.x, v4.x, v3.x, v2.x   dates=0 exact=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No date match at all (`dates=0`) | CLOSED — does not apply |

---

## A partial date match keeps its Undo (FR41, follow-up) — main only

When "Copy to match dates" matched some pairs and left others out (changed since Verify All,
failed, or held), it still registered one undo step for the dates it set, but its warning banner
offered no Undo. `main` keeps the banner's Undo whenever a date was matched.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s dates=%s partialUndo=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+BulkSync.swift 2>/dev/null | grep -cF 'func matchDatesOfProvenPairs')" \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileSyncManager+BulkSync.swift 2>/dev/null | grep -cF 'undoable: !outcome.matched.isEmpty')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads partialUndo=1):
# main                     dates=1 partialUndo=0
# v5.x, v4.x, v3.x, v2.x   dates=0 partialUndo=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No date match at all (`dates=0`) | CLOSED — does not apply |

---

## A held row is decided from its own menu (FR39/FR40, follow-up) — main only

A held row's note said "choose which to keep", but Compare offered no way to keep the file its
guess pointed away from: bulk runs leave it out, and ⌘← / ⌘→ and the Review card copy only the
suggested way. `main` gives a held row's right-click menu a Copy to … item for each direction its
sides allow (`DifferenceRowMenu.heldCopyDirections`, `FileDifference.redirected(to:)`) — none for a
row copying from a link, which stays refused — and the left-out banners name that menu for the
rows that need a decision and say plainly that a link is left out.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s heldBack=%s rowCopy=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDifference.swift 2>/dev/null | grep -cF 'public let heldBack')" \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DifferenceRowMenu.swift 2>/dev/null | grep -cF 'func heldCopyDirections')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads rowCopy=1):
# main                     heldBack=1 rowCopy=0
# v5.x, v4.x, v3.x, v2.x   heldBack=0 rowCopy=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No held rows at all (`heldBack=0`) | CLOSED — does not apply |

---

## Compare says how many held rows a run left out (FR39/FR40, follow-up) — main only

The header, ⌘→ and the bulk menu filtered held rows out before `syncAll`, so "Copy 3 →" over five
rows with two held reported "Copied 3 items" and the two went unexplained, and a set that was all
held showed no button and no reason. `main` hands the held rows to `syncAll`, which leaves them out
and names them in its banner, and the header reads "N need your decision" beside its buttons
(`DifferenceActionTargets.heldText`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s heldBack=%s heldReadout=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDifference.swift 2>/dev/null | grep -cF 'public let heldBack')" \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DifferencesQuery.swift 2>/dev/null | grep -cF 'var heldText: String?')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads heldReadout=1):
# main                     heldBack=1 heldReadout=0
# v5.x, v4.x, v3.x, v2.x   heldBack=0 heldReadout=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No held rows at all (`heldBack=0`) | CLOSED — does not apply |

---

## Review shows a held row's note, and Copy Remaining leaves a lone one out (FR39/FR40, follow-up) — main only

The Review card presented a held row's guess as a plain copy, with none of the note Compare's list
shows, and "Copy Remaining" with exactly one pending held row copied it through `syncFile` while two
or more were left out by `syncAll`. `main` leads the card's warning with the row's note and sends a
lone held row through `syncAll` too (`CopyRemainingRoute`).

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s heldBack=%s route=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDifference.swift 2>/dev/null | grep -cF 'public let heldBack')" \
  "$(git show origin/$l:Modules/FileExplorer/Sources/FileExplorer/DifferencesQuery.swift 2>/dev/null | grep -cF 'enum CopyRemainingRoute')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads route=1):
# main                     heldBack=1 route=0
# v5.x, v4.x, v3.x, v2.x   heldBack=0 route=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No held rows at all (`heldBack=0`) | CLOSED — does not apply |

---

## `scan` marks the rows `sync` leaves for a decision (FR39/FR40/FR8, follow-up) — main only

`scan` printed a held row's guessed direction as if `sync` would take it, and `scan --json` had no
field to tell a held row from a planned one. `main` prints `[needs-decision]` in place of the
direction and gives every JSON row `needsDecision`, and a held one `heldBack` with its reason.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s heldBack=%s jsonHeld=%s\n' $l \
  "$(git show origin/$l:Modules/Sync/Sources/Sync/FileDifference.swift 2>/dev/null | grep -cF 'public let heldBack')" \
  "$(git show origin/$l:SyncCloudCLI/Sources/SyncCloudCLICore/CommandRunner.swift 2>/dev/null | grep -cF 'let needsDecision: Bool')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads jsonHeld=1):
# main                     heldBack=1 jsonHeld=0
# v5.x, v4.x, v3.x, v2.x   heldBack=0 jsonHeld=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No held rows at all (`heldBack=0`) | CLOSED — does not apply |

---

## The CLI's ambiguity refusal names the folders it would scan (FR42, follow-up) — main only

A `-L`/`-R` display name two providers share is refused naming each candidate, but it listed each
one's account root while the CLI scans its landing folder, so for a provider opening below its
root the listing named folders the run would never read. `main` lists each `landingPath`.

```sh
for l in main v5.x v4.x v3.x v2.x; do printf '%-5s byName=%s listsLanding=%s\n' $l \
  "$(git show origin/$l:SyncCloudCLI/Sources/SyncCloudCLICore/ProviderResolution.swift 2>/dev/null | grep -cF 'matches \(candidates.count) providers by')" \
  "$(git show origin/$l:SyncCloudCLI/Sources/SyncCloudCLICore/ProviderResolution.swift 2>/dev/null | grep -cF '($0.landingPath))')"; done
# measured 2026-10-24, against origin, before this landed (the fix reads listsLanding=1):
# main                     byName=1 listsLanding=0
# v5.x, v4.x, v3.x, v2.x   byName=0 listsLanding=0
```

| Line | Carries | Status |
|---|---|---|
| `v5.x` / `v4.x` / `v3.x` / `v2.x` | No ambiguity refusal (`byName=0`) | CLOSED — does not apply |
