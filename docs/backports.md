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
