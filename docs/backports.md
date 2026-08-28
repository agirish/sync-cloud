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

## 2026-08-28 — the `v4.x` line opens; v5.0 lands on `main`

`v4.x` was cut from the `v4.6` tag when the v5.0 Organize work landed on `main`. Recorded, not
owed: **none of the maintenance lines carries any of the v5.0 Organize system** (the
`RestructureStore`/planner/apply/undo family, the Restructure lens surfaces, `synccloud
restructure`, and the §12 Duplicates header rework) — a feature line under the no-backport
standing direction, not a fix. The two commits `main` carried between the `v4.6` tag and the cut
(`68c71c62`, the 4.7-dev re-bump, and `05d11f5f`, the fourth-branch doc fix) are superseded on
`v4.x` by its opening commit, which re-bumps to `4.7-dev`/`407` and carries the four-line
documents — checked, nothing else in that range.
