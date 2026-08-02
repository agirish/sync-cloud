# SyncCloud — Feature Roadmap

**Pending, net-new user-facing capability only.** Shipped items are *removed* from this file rather
than kept with a "shipped" note: git history is the record of what landed, and a backlog that
carries its own finished work stops being scannable — by the last pass, five of sixteen entries
existed mainly to say they were done. Status re-checked against the code on **2026-08-02**.

Distinct from `DEFERRED_ENHANCEMENTS.md` (hardening / coverage consciously punted) and `REFACTOR.md`
(internal shape that is correct but worth restructuring).

Numbers here are positional and change as the list does — **cite items by name, not by number.**

---

## 1. Backup: know what has only one copy, and keep a second

**Why:** Three separate user requests turn out to be one capability.

- *"List everything not on iCloud, so I know what I'd lose if this Mac fails."*
- *"Let me review the files on OneDrive / Dropbox that are cloud-only and not on this Mac."*
- *"Let me point Tidy and Compare at any folder, not just cloud providers."*

The first two are opposite ends of one axis — **how many places does this file actually exist?** —
and SyncCloud can already answer it per file without new machinery. Path containment is
`PathBoundary.contains` plus `CloudProvider.claimRoots` (what types a path-addressed CLI root
today). Materialization is one `lstat` for `SF_DATALESS` via `MaterializationStatus` (what already
draws the ☁ badge on pane rows). The two signals have simply never been crossed and reported.

The third ask is not a sibling — it is the **prerequisite**. "What would I lose" is rooted at *the
Mac*, and the Mac is not a provider: `leftProviderId` keys into a list `SettingsManager` builds by
enumerating `~/Library/CloudStorage` plus a hardcoded iCloud entry, so nothing can be pointed at `~`
or `~/Projects`.

This item **subsumes the former "scheduled / automatic sync" entry**, which sat open because a
scheduler with no specific job to do is a solution hunting a problem. The lens supplies the problem
— *this folder has one copy* — and a one-way backup is a far safer thing to automate than two-way
sync ever was.

### The three-state model

Every file classifies into exactly one state, from one walk of the tree:

| State | Meaning | Detection |
|---|---|---|
| **No copy in the cloud** | Only on this Mac — gone with the Mac | path is outside every enabled provider's claim roots, and no backup job covers it |
| **No copy on this Mac** | Only in a provider's cloud, not downloaded | `MaterializationStatus.isCloudOnly` |
| **A copy in both** | Inside a cloud root and materialized, or put there by a job | neither of the above |

### 1a. Folder sources — build first

**What:** Make a plain folder a first-class source by adding a fifth `CloudProvider.ProviderType`
case, `localFolder`. Because the whole app already talks to sources through one `CloudProvider`
type, *nothing downstream changes*: panes, Tidy, `FileDiffEngine`, `FileOperations`, undo, history,
automations and the CLI all keep working. The only type-gated behaviour in the diff path — the
Google Drive date-noise filter — keys off `.googleDrive` and is simply never triggered.

Two entry points, one mechanism: **Settings ▸ Providers ▸ Add Folder…** for deliberate setup, and
**Choose Folder…** at the foot of any pane's provider menu, which creates the source and selects it
in that pane in one gesture. Folder sources sort *after* the cloud accounts so the existing picker
is visually untouched. Persist as JSON (`folderSources`) in the app's defaults domain and merge into
`SettingsManager.mapProviders`.

**Touch list:** `CloudProvider.swift` (the enum case) · `SettingsManager.swift` (persist + merge +
`addFolderSource` / `removeFolderSource`) · `ProviderNameRules.swift` (new case joins the `.iCloud,
.googleDrive` branch — a local volume accepts what a local volume accepts) · `ProviderHue.swift`
(graphite pair, `folder.fill` instead of a brand logo) · `SettingsView.swift` (Add Folder… + Remove)
· `ProviderMenu.swift` (divider + Choose Folder…) · `FirstRunOverlay.swift` (glyph map).

**Four things that will bite:**

- **The Rename lens goes silent.** `startNameScan(root:provider:)` takes the source's own type, so a
  folder source checks names against "local filesystem" and finds *nothing* — an empty success state
  over a folder full of names OneDrive would reject. Fix: when the source is a folder, the Rename
  lens header gains a **Check against ▾** picker defaulting to OneDrive (the strictest). This is a
  better feature than what exists today — *"would this folder survive being put on OneDrive?"* is
  the real question — and it is roughly fifteen lines.
- **Shallow roots are already handled.** `claimRoots` refuses to let a root shallower than four path
  components claim anything, so a folder source at `~` (`/Users/<me>`, three components) claims
  nothing and `~/Documents` still resolves to iCloud for name rules. The guard was written for the
  "user points a provider at their home folder" case and covers this exactly. Worth a pinning test,
  not new code.
- **Reset All Settings wipes them.** `resetAllSettings()` calls `removePersistentDomain`.
  Defensible, but the confirmation copy currently promises only that "files on disk are untouched",
  which reads as reassurance while the folder list the user curated disappears.
- **Nested and overlapping sources are legitimate.** `~` and `~/Projects` as separate sources, or a
  folder inside a cloud root, all work — `inferredType`'s longest-root-wins rule resolves the
  overlap. Adding a path that already exists should *select* that source, not create a second.

**Delivers the third ask on its own**, before any of the rest exists.

**Effort:** Low–Medium. **Risk:** Low — one enum case, no new data path.

> **The app is not sandboxed.** `codesign -d --entitlements` on the installed build shows only
> `get-task-allow`, so a chosen path is just a path: no security-scoped bookmarks, no stale-bookmark
> resolution, no entitlement work. That is most of what would normally make this expensive.

### 1b. The Backup lens — the report

**What:** A sixth Tidy lens (`TidyLens.backup`, shown as **Backup**), sitting after Storage. Tidy is
already the single-source workspace with a source rail, a lens picker and the shared 81pt
`LensHeaderCard`; Storage is the precedent for a read-only analytical lens. A third top-level tab
would be a structural change to `ContentView`'s layout modes for one report.

**Folders, not files — the decision the feature lives or dies on.** A home folder holds hundreds of
thousands of files and listing them answers nothing. Report the **highest folder that is entirely
outside every provider root**, with its rolled-up size and file count, descending only into folders
that are *partly* covered. One row for `~/Projects`, not 3,241. That is
`StorageLensAnalyzer.rolledUpBytes`'s recursion with a containment predicate instead of a size one —
a pure function over an already-walked `FileNode` tree, unit-testable off an in-memory fixture, no
disk access.

**Scan scope.** A walk of `~` is the largest thing the app will ever do and most of what it finds is
junk. Three existing mechanisms cover it, so no new filtering machinery is needed: seed
`IgnoreRules` with a toggleable **Developer junk** preset (`node_modules`, `.build`, `DerivedData`,
`.venv`, `Pods`, `target`); skip `~/Library` and `/Applications` by default *with a visible
"excluded 3 locations" affordance*; floor the list so folders under 10 MB roll into a "…and 1,204
smaller folders" line. No hashing in v1 — containment is string math and the dataless check is one
`lstat`, so the scan is bounded by directory enumeration, not file I/O. The parallel walk, progress
line and Cancel button all transfer from the Storage lens.

**Effort:** Medium. **Risk:** Low — read-only, pure analyzer.

### 1c. Backup jobs — the remedy

**What:** A stored `BackupJob` — source folder, destination (provider + relative path), trigger,
deletion mode, exclusions. `AutomationRule` is the house pattern to copy: `Codable`, persisted as
JSON, edited in a sheet (`AutomationRuleEditor`), evaluated by a pure function.

Mechanically almost nothing is new. A run is a scan plus a one-way copy of everything missing or
newer — `FileDiffEngine` followed by the `FileSyncManager+BulkSync` path the "Copy N to …" button
already drives:

| Piece | Comes from |
|---|---|
| Deciding what to copy | `FileDiffEngine` — one-way, missing-or-newer |
| Copying it | `FileOperations` — atomic, backed-up, collision-aware |
| Undoing a run | `undoLastSyncRun` |
| Recording it | `SyncHistoryStore` |
| Announcing it | `OperationBanner` |
| Excluding junk | `IgnoreRules` |
| Launching at login | `SMAppService` + `LoginItemEchoGuard` — **already ships** |
| **the rule, the trigger, the guards** | **new** |

**Split the manual job from the trigger.** A job you press a button to run is most of the value and
none of the danger: it exercises the stored source, destination, exclusions, dry-run preview and
every guard while somebody is watching. The trigger then becomes a small addition to something
already proven, rather than the first outing for a whole new write path that fires at 02:00. Run the
manual form against real folders for a week before the trigger ships.

**Triggers:** every hour · daily at HH:MM · weekly · **when files change** (needs the watcher, item
5) · manually.

**Effort:** Medium (the job) + Medium (the triggers). **Risk:** Medium, then **High** — this is the
only thing in the app that writes files with nobody watching.

### Invariants for unattended writes

Each of these exists because of a specific way automated backup tools destroy data. They are
invariants, **not settings**:

- **Never delete unattended** — even in Mirror mode. Removals are queued, surfaced, and a human
  clicks. Automation copies.
- **Add-only is the default; Mirror must be chosen.** Mirror propagates source damage into the
  backup, which is how a backup stops being one. The editor says so where the choice is made.
- **A missing destination holds the job — it never re-creates it.** An unmounted `/Volumes/Backup`
  still *looks* writable: macOS will let a run create a folder at an empty mount point and put 14 GB
  on the boot disk, which the next mount then hides. A run verifies the destination root exists
  **and** carries a marker file written at setup. No marker, no run — the job goes to *Held* and
  says why.
- **Refuse a destination inside the source** (`~/Projects` → `~/Projects/backup` copies its own
  output forever). `PathBoundary.contains` answers this in both directions; refuse at pick time, not
  at run time.
- **Refuse two jobs sharing one destination** — collisions the user never described and cannot
  untangle.
- **Every run is one undo group and one history record**, with no exception for automatic runs. An
  unattended run is exactly the kind you most want to reverse, because you were not there to stop
  it.
- **A failed or skipped run says so where it will be seen** — the job row goes red and carries the
  count (*Held — 3 runs skipped*), and skipped runs get their own history row. Silent failure is
  what makes backups worthless: a history that records only what happened cannot tell you about the
  four nights your backup did not.
- **Never run two jobs at once, or one during a user operation.** The in-flight machinery exists —
  bulk sync tracks its own writes and the sweeper excludes them.

### Saying only what can be proved

The failure mode that matters is not a missed file, it is a **false reassurance**. A file can be
safe in ways SyncCloud cannot see — Time Machine, Backblaze, an external clone, or the same bytes in
a cloud folder under another name.

- The at-risk zone's subtitle names the blind spot outright. Never "unprotected" or "unsafe".
- **Disabled providers still count as coverage.** Their folder is on disk whether or not it is being
  compared against; treating a disabled account as absent manufactures risk that is not there.
- **A job counts only once it has run.** Creating a backup for `~/Projects` must not move it out of
  the unprotected zone — the files are not anywhere else yet. Coverage is claimed from the *last
  successful run*; a job that has never completed shows *Never run* while its folder stays in the
  count. Backwards, this congratulates the user for a backup that does not exist.
- **And only up to when it ran.** A job that succeeded two hours ago says nothing about the file
  saved ten minutes ago, so the row reads *7 files pending*, not a green tick. The pending count is
  free — the job must diff to know what to copy, and `FileDiffEngine` produces exactly that list.

### UI shape (enough to mock up)

**Lens header** (`LensHeaderCard`) — row 1: lens tabs · `＋ New backup…` · `↻ Rescan` · search
toggle. Row 2 pills: `🏠 Home folder` · `⚠ 10.6 GB not backed up` · `↻ 30.6 GB on a schedule` · `☁
14.6 GB not on this Mac`, trailing `scanned 2 min ago · 486,103 files`.

**Content card, three zones in order:**

1. **Automatic backups** — *"Jobs that keep a copy elsewhere. One-way, add-only, every run
   undoable."* Rows: `~/Projects ▸ iCloud/Backups/Projects`, meta line `Every hour · Add only · last
   run 41 min ago · 14.6 GB`, right-hand status (`● Up to date` / `● 7 files pending` / `● Held — 3
   runs skipped`), and a `⋯` menu. A held job renders in the risk tint with a **Fix…** button — as
   prominent as the healthy ones, because a backup that silently stopped is worse than none.
2. **Not backed up** — *"No cloud copy and no job — gone if this Mac is. Time Machine and other
   backups are invisible here."* Rows: monospaced path, sub-line (*"Nothing inside is in a cloud
   folder"* or *"4 of 9 folders inside are on iCloud"*), file count, size, **Back up ▾** (→ *Copy
   now…* / *Back up automatically…* / *Compare with…* / *Never flag this folder*).
3. **No copy on this Mac** — *"Only in a provider's cloud — needs network to open, and skipped by
   duplicate detection."* Rows: provider tag, path, *"Not opened since Mar 2021"*, size,
   **Download**. Footer offers *Group by folder* and *Download all (14.6 GB)*.

**Rule editor sheet** — fields: *Back up* (folder picker, pre-filled from the row) · *To* (provider
+ relative path) · *When* (trigger) · *Deletions* (segmented **Add only** | Mirror) · checkboxes
*Skip while on battery*, *Skip developer junk*. Below: the add-only explainer, a dry-run preview
(`First run will copy 3,241 files · 14.6 GB` / `Free space at destination after 142 GB`), and
buttons *Cancel* / *Create, don't run yet* / *Create & run now*. Choosing Mirror swaps the explainer
for the risk-tinted warning and adds a `Would remove at destination · 0 items` line.

**Bulk download confirmation** — total size, **free space after** (the line that earns the dialog),
and a per-provider breakdown, because the constraint is usually one account rather than the total.

**Run banner** — in progress (`412 of 3,241 files · 2.1 GB of 14.6 GB · about 6 min left`, Cancel),
complete (`Backed up Projects — 3,241 files, 14.6 GB`, Undo), partial (`3,238 copied, 3 skipped`,
red, *Show them*). The bulk-sync path already aggregates per-file failures rather than aborting the
batch; that shape just has to survive into an unattended run's summary instead of being swallowed
because nobody was watching.

### Where else the answer belongs

The lens answers in bulk, but one wonders about a single file far more often than one audits the
whole Mac. Two small additions, both reusing what is already on screen:

- **Info inspector** (`DetailsSidebar`) gains a *Where it lives* row: `This Mac · iCloud` / `This
  Mac only` / `OneDrive only`.
- **Pane rows** gain the mirror of the existing ☁ badge: a `⌂` *on this Mac only* mark, the same
  lazy per-row pattern `FileRowView` already uses — and costing no syscall at all, since it is pure
  path math. It stays quiet where it would be noise: inside a cloud provider's own pane every row is
  covered by definition, so it never appears. It shows exactly when the source is a folder, which is
  the only time the question is live.

**Effort:** Low. **Risk:** Low.

### Explicitly out of scope

- **Version history.** A job keeps a current copy, not snapshots. Add-only being the default is the
  cheap 80% — the backup keeps things deleted here, whether or not that was intended. Real
  versioning is a different product, and the empty state must say so rather than let "Backup" imply
  Time Machine.
- **Unattended deletion.** Permanent, not a v1 shortcut.
- **Proving a copy exists elsewhere.** Hashing local-only files against the provider trees would
  upgrade *"no copy in the cloud folder tree"* to *"no copy of these bytes anywhere"*. That is
  cross-provider duplicate detection (item 7), a whole engine. Without it the lens is still right,
  just more cautious than it could be.
- **A background helper.** Jobs run while the app runs. Launch-at-login already ships, which covers
  most of it; the properly always-on answer is item 6's CLI driven by a `launchd` agent, and the
  rule format should be designed so that agent consumes the same JSON.

### Open questions

- **Does Home ship as a built-in source?** Auto-adding it on first launch makes the lens
  discoverable with no setup, but puts a half-million-file scan one click from someone who only
  wanted to diff two Dropbox folders. Lean: offer it from the lens's empty state ("Scan my Home
  folder"), do not add it silently at launch.
- **Downloading a cloud-only file is only solved for iCloud.** `MaterializationStatus.download` uses
  `startDownloadingUbiquitousItem`; for Dropbox, OneDrive and Drive there is no public consumer API.
  The documented route is a coordinated read (`NSFileCoordinator.coordinate(readingItemAt:)`), which
  for a File Provider item triggers materialization and blocks until content lands — **plausible and
  unverified**, and this codebase proves filesystem-semantics claims on a fixture before shipping
  them. Until then the row action for non-iCloud providers is *Reveal in Finder*, which always
  works.
- **Time Machine could upgrade the claim.** `tmutil destinationinfo` and `CSBackupIsItemExcluded`
  can say whether Time Machine is configured and whether a path is excluded. If that holds up, a
  fourth state appears — *"on this Mac and on Time Machine, last backup 4 hours ago"* — the headline
  becomes trustworthy rather than carefully hedged, and the zone can stop disclaiming in its own
  subtitle. Needs an empirical spike before it is promised in copy.

---

## 2. Sync presets (saved folder pairs)

**Why:** Users repeatedly pick the same left/right provider and paths, and there is no way to name
or quick-switch a pair. Scoping a comparison to a subfolder already works — drilling in sets
`leftRelativePath` / `rightRelativePath`, with per-tab focus and navigation history — it just is not
*saved*. So "compare only `Documents/Work`" is a thing you can do and cannot keep.

**What:** Save the current left + right provider and relative paths as a named preset; load it from
a pane header's provider menu or the toolbar. Persist as JSON alongside the other stores. This
absorbs what used to be listed separately as "selective sync": naming a scoped context and switching
between several *is* presets, and there is no second feature there.

**Impact:** Faster recurring work ("Documents: iCloud ↔ OneDrive", "Work: Drive ↔ Backup SSD"), and
it composes with folder sources (item 1a) to give a preset per project.

**Effort:** Low. **Risk:** Low.

---

## 3. Content-based diff: a strict-match mode and a persisted index

**Why:** Hashing exists and is wired in three places — `FileContentVerifier`, "Verify All" over
same-size/different-date pairs, and the `autoVerifySameSizeDuringScan` setting. But it is a
*confirmation pass over rows the date/size engine already produced*, not a comparison mode, and
there is no persisted index (`ContentHashCache` is session-scoped — see `DEFERRED_ENHANCEMENTS.md`
#9).

**What:** A "strict content match" mode that compares by hash where dates and sizes disagree, plus
an on-disk index keyed by path + mtime + size so unchanged files are never re-read. Files over 100
MB and cloud-only placeholders stay skipped (`DEFERRED_ENHANCEMENTS.md` #6).

**Impact:** Fewer false positives, and the index is the prerequisite for item 4.

**Effort:** Medium–High. **Risk:** Medium.

---

## 4. `bothModified` conflict detection

**Why:** Collisions at copy time already offer Keep Both / Replace / Skip with a standing
`ConflictPolicy`, and `.nameConflict` covers same-name/different-spelling pairs. What is missing is
*detection*: the engine has no baseline of what both sides looked like at the last sync, so it
cannot tell "they diverged" from "one side is newer".

**What:** A `bothModified` case on `FileDifference.DifferenceType`, surfaced as **Conflict** in the
differences list, resolved by Copy to Left / Copy to Right / Keep Both.

**Depends on:** item 3's content index, plus a last-synced record — which the shipped Sync History
now provides.

**Effort:** Medium. **Risk:** Medium.

---

## 5. Folder watching → auto-rescan

**Why:** The app only learns about filesystem changes when asked. There is no watcher anywhere in
the codebase — no `FSEvents`, no `DispatchSource`, no `NSFilePresenter` — so a comparison left open
goes quietly stale, and cloud providers change these folders constantly without the user doing
anything.

**What:** An `FSEventStream` on the focused roots, coalesced (a provider sync burst is many events),
feeding `prepareForcedRescan()` — which already exists as the supported "this is stale, supersede
whatever is in flight" entry point. Ship it as a passive freshness signal first (`ScanFreshness` is
already there), with auto-rescan as the opt-in step, since a rescan mid-review would move rows under
the user.

**Impact:** The comparison stops lying. It is also **the "when files change" trigger for item 1c**,
which is the strongest reason to build it.

**Effort:** Medium. **Risk:** Medium — it interacts directly with the freshness machinery catalogued
in `REFACTOR.md` item 8; do that first or accept a seventh counter.

---

## 6. CLI parity for the maintenance lenses

**Why:** The `synccloud` CLI does `scan`, `sync` and `providers` — the two-pane story only. Every
lens added since (Duplicates, Organize, Rename, Storage) is GUI-only, so none of it can be scripted,
scheduled with `launchd`, or run over ssh.

**What:** `synccloud tidy --dry-run --json`, `synccloud organize`, `synccloud names --check`,
`synccloud storage --json`, and — once item 1c exists — `synccloud backup --job <id>`. The engines
are already pure and app-independent (`DuplicateFinder`, `FilingEngine`, `NameNormalizer`,
`StorageLensAnalyzer` are stateless statics over a walked tree), so this is command surface and
output shaping, not new logic. Read-only/dry-run first; anything that moves files goes behind an
explicit confirm flag, matching `sync`'s existing `--yes`.

**Impact:** Makes the whole app automatable — and `launchd` + `synccloud backup` is the honest
always-on answer for item 1c, which nothing in-app can give.

**Effort:** Low–Medium. **Risk:** Low — the engines are already tested in isolation.

---

## 7. Cross-provider duplicate detection

**Why:** `DuplicateFinder` walks *one* provider tree by design — "duplicate groups never span
providers" is an invariant the Compare handoff relies on. But the single most likely place to be
storing the same 4 GB twice is iCloud *and* OneDrive.

**What:** A Tidy mode that hashes two provider trees and groups across them, with a keeper heuristic
that understands "keep the copy on the provider you chose" rather than "keep the shallowest path".
The Compare duplicate-review handoff pins both panes to one provider today, so a cross-provider
group needs that pin logic generalized.

**Impact:** The largest reclaimable-space win the app can offer, and one nothing else on the Mac
does well. It also upgrades item 1b's claim from *"no copy in the cloud folder tree"* to *"no copy
of these bytes anywhere"*.

**Effort:** High. **Risk:** Medium–High — it breaks a stated invariant and lands on the destructive
review path.

---

## 8. Export / import of automations and settings

**Why:** Automation rules are the user's authored asset — taught by correction over months — and
they live only in `UserDefaults` on one machine. Nothing exports *configuration* (the one exporter
that exists covers sync history); a new Mac starts from nothing, and a defaults domain is one bad
write from empty.

**What:** "Export automations…" / "Import…" writing a versioned JSON bundle (rules, ignore patterns,
provider name/path overrides, folder sources, conflict policy, backup jobs). `AutomationRule` is
already `Codable` and persisted as JSON, and `SyncHistoryExporter` is the house pattern to copy —
pure, total, unit-pinned serialization. Import must be additive with a preview of what would change,
never a silent replace.

**Impact:** Portability, backup of the configuration itself, and a way to share a good rule set.

**Effort:** Low. **Risk:** Low.

---

## 9. Automations that run without being asked

**Why:** Automations are deliberately confirm-only — "nothing ever moves without that confirmation."
That is the right default, and it also means the feature named "automation" still needs a human
every time.

**What:** Per-rule "run automatically" for rules the user has confirmed by hand N times, scoped to
one watched folder (a Downloads-style inbox), always undoable as one grouped operation, always
announced by a banner and a history record. Every condition is a local, deterministic signal — no
classifier is ever consulted on the automation path — so an auto-run rule is predictable in a way a
suggestion is not.

**Impact:** Turns Organize from a chore you remember into one you do not.

**Effort:** Medium. **Risk:** Medium — it moves files unattended, so it inherits item 1c's
invariants wholesale. Gate it behind item 5's watcher, a per-rule confirmation count, and a hard
"never auto-run a rule whose destination does not exist yet".

---

## 10. In-place folder Merge as a collision choice

**Why:** Already specified in detail as `DEFERRED_ENHANCEMENTS.md` #1, and it is the one collision
answer users expect from Finder-adjacent tooling that SyncCloud cannot give: replacing a folder
today swaps it wholesale, discarding destination-only children (recoverably, and with a warning).

**What:** A `.merge` case on `CollisionResolution` (which today carries only `replace` / `keepBoth`
/ `skip`), a recursive per-child collision path, and its own apply-to-all semantics. See
`DEFERRED_ENHANCEMENTS.md` #1 for the full pickup notes.

**Impact:** Removes the sharpest edge left in the transfer path.

**Effort:** Medium. **Risk:** Medium — new data path.

---

## 11. Search inside the pane trees

**Why:** Every *list* has search — the Differences table (`DifferenceSearch` with token chips),
Duplicates (`DuplicateSearch`), the Activity Log (`LogSearch`), the Settings header — all through
one `ExpandingSearchField`. The two pane **trees** still have none, and they are the hardest and
most useful half.

**What:** Search the trees by name, expanding the path to reveal each hit and showing which side(s)
it is on. Harder than the lists because a hit must expand its ancestors and the panes are
`NSTableView`-backed.

**Impact:** Much faster navigation in large trees.

**Effort:** Low–Medium. **Risk:** Low.

---

## 12. In-app diff viewer for text files

**Why:** Files can be opened in external apps but their contents cannot be compared inside
SyncCloud.

**What:** For a selected pair in the Differences list or the Info inspector, when both sides are
text (by extension or UTI), a read-only side-by-side or unified diff in a sheet. Integrate with the
existing Quick Look where useful.

**Impact:** Verify what actually changed before syncing.

**Effort:** Medium. **Risk:** Low.

---

## 13. Menu bar / status item

**Why:** Everything requires opening the main window, and there is no at-a-glance status.

**What:** An `NSStatusItem` whose icon reflects state (idle / scanning / error), with "Scan now",
"Last synced: …", "Open SyncCloud". Once item 1c exists it is the natural home for the headline —
*"10.6 GB not backed up · 3 jobs healthy"* — and for pausing scheduled jobs.

**Impact:** Better for power users, and it is where an unattended backup's health should be visible
without opening anything.

**Effort:** Low–Medium. **Risk:** Low.

---

## 14. Path-anchored and include-only rules

**Why:** `IgnoreRules` + the `ignorePatterns` setting give case-insensitive `*` / `?` globs that
match **any path component**, so `node_modules` hides it at any depth; patterns are NFC-normalized
on both sides so accented names match. Per-item ignores are a separate durable layer
(`IgnoredItemsStore`). What is missing is anchoring.

**What:** A path-anchored form (`build/**/*.o`, "only at the root") and an *include-only* mode
("compare only `*.pdf`").

**Impact:** Precision for people with a specific shape of tree; also sharpens item 1b's scan scope.

**Effort:** Low–Medium. **Risk:** Low.

---

## Summary

| # | Item | Effort | Impact |
|---|------|--------|--------|
| 1 | **Backup** — folder sources, the lens, jobs | Low→High, staged | **Highest** |
| 2 | Sync presets | Low | High |
| 3 | Strict content match + persisted index | Medium–High | Medium–High |
| 4 | `bothModified` detection | Medium | High |
| 5 | Folder watching → auto-rescan | Medium | High |
| 6 | CLI parity for the lenses | Low–Medium | High |
| 7 | Cross-provider duplicates | High | High |
| 8 | Export / import configuration | Low | Medium |
| 9 | Auto-running automations | Medium | Medium–High |
| 10 | Folder Merge on collision | Medium | Medium |
| 11 | Search inside the pane trees | Low–Medium | Medium |
| 12 | In-app diff viewer | Medium | Medium |
| 13 | Menu bar status item | Low–Medium | Medium |
| 14 | Path-anchored / include-only rules | Low–Medium | Medium |

**Where the value is.** Item 1 is the largest single addition on this list, and its first stage
(**folder sources**) is cheap, self-contained and unblocks the rest — start there. Items **2** and
**6** remain the best small wins; **5** is worth pulling forward because it serves both the stale
comparison and item 1c's best trigger. Biggest single payoff and biggest risk: **7**.
