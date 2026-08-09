# SyncCloud — Feature Roadmap

**Pending work only** — net-new capability first, then interface changes to surfaces that already
ship. Shipped items are *removed* from this file rather
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
and SyncCloud already answers it per file: `FileLocation` crosses path containment (pure string
math over the provider list) with materialization (one `lstat` for `SF_DATALESS` via
`MaterializationStatus`, the same one that draws the ☁ badge). That classifier ships, and with it
the per-file surfaces — the *Where it lives* inspector row and the `⌂` row badge. What is left is
the part that needs a **walk** rather than a lookup: the same question asked of a whole tree at
once, ranked and actionable, which is the lens below.

The third ask was not a sibling — it was the **prerequisite**, and it has landed. "What would I
lose" is rooted at *the Mac*, and the Mac was not a provider; a plain folder is now a source of its
own (`ProviderType.localFolder`, the `folderSources` list in Settings ▸ Sources, **Choose Folder…**
in every pane's source menu), so a pane, a scan, or a lens can be pointed at `~` or `~/Projects`.
Both items below assume it.

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

### 1b. The Backup lens — the report

**What:** A sixth **workspace** (`Workspace.backup`, with a matching `TidyLens.backup` behind it),
sitting after Storage in the bar. Note the shape this now takes: the two-level *Compare | Tidy* +
lens picker is gone — `Workspace` collapsed both levels into the flat toolbar bar — so "add a lens"
and "add a top-level tab" are the same act, and the cost is a bar segment rather than a structural
change to `ContentView`'s layout modes. Storage remains the precedent for a read-only analytical
workspace, and the shared 81pt `LensHeaderCard` rung applies unchanged.

**The bar-width consequence, which is the only real cost.** Five labelled segments already exceed
the window's 600pt `minWidth` once the traffic lights and utility pill are counted, and
`WorkspaceBarMetrics` sheds every label at once (`.full` → `.iconOnly`) when they do. A sixth
segment moves that threshold further out, so the bar spends more of its time icon-only — measured
on the current segments, labels drop below roughly 890pt at 100% text and 1110pt at 150%. That is a
real regression in a control every workspace depends on, and it is the thing to weigh against
Backup being a workspace rather than something reached from Storage. The glyph has to carry the
whole label at narrow widths, so it must be legible alone rather than decorative.

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

**And it brings the last of the ambient surfaces with it.** *"Back up this folder…"* belongs in the
pane row's context menu beside *Fix name…* and *Find duplicates of this*, on FOLDER rows — the two
per-file doors ship, and this is the third. It was deliberately left out of the ambient work
because the item has nowhere to go without the editor this section describes: it opens the rule
sheet pre-filled with the row's folder as the source, which is the same sheet the lens's *Back up ▾
▸ Back up automatically…* raises. Ship it in the same change as the editor rather than as a
disabled stub — a menu item that opens nothing is worse than an absent one.

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
it composes with the shipped folder sources to give a preset per project.

**Effort:** Low. **Risk:** Low.

---

## 3. Content-based diff: a strict-match mode and a persisted index

**Why:** Hashing exists and is wired in three places — `FileContentVerifier`, "Verify All" over
same-size/different-date pairs, and the `autoVerifySameSizeDuringScan` setting. But it is a
*confirmation pass over rows the date/size engine already produced*, not a comparison mode.

**The persisted index half has landed** — `ContentHashIndexStore` keys digests by path + mtime +
size on disk, so unchanged files are not re-read across launches (the deferred item that asked for
it is now closed). What remains here is the comparison mode itself.

**What:** A "strict content match" mode that compares by hash where dates and sizes disagree. Files
over 100 MB and cloud-only placeholders stay skipped (`DEFERRED_ENHANCEMENTS.md` #6).

**Impact:** Fewer false positives. The index item 4 depends on now exists.

**Effort:** Medium. **Risk:** Medium.

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
group needs that pin logic generalized. The v3.1 persisted hash index takes most of the recurring
cost out of this: the first two-tree pass pays for its reads once, and every later run re-reads
only what changed.

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

## 11. In-app diff viewer for text files

**Why:** Files can be opened in external apps but their contents cannot be compared inside
SyncCloud.

**What:** For a selected pair in the Differences list or the Info inspector, when both sides are
text (by extension or UTI), a read-only side-by-side or unified diff in a sheet. Integrate with the
existing Quick Look where useful.

**Impact:** Verify what actually changed before syncing.

**Effort:** Medium. **Risk:** Low.

---

## 12. Menu bar / status item

**Why:** Everything requires opening the main window, and there is no at-a-glance status.

**What:** An `NSStatusItem` whose icon reflects state (idle / scanning / error), with "Scan now",
"Last synced: …", "Open SyncCloud". Once item 1c exists it is the natural home for the headline —
*"10.6 GB not backed up · 3 jobs healthy"* — and for pausing scheduled jobs.

**Impact:** Better for power users, and it is where an unattended backup's health should be visible
without opening anything.

**Effort:** Low–Medium. **Risk:** Low.

---

## 13. Path-anchored and include-only rules

**Why:** `IgnoreRules` + the `ignorePatterns` setting give case-insensitive `*` / `?` globs that
match **any path component**, so `node_modules` hides it at any depth; patterns are NFC-normalized
on both sides so accented names match. Per-item ignores are a separate durable layer
(`IgnoredItemsStore`). What is missing is anchoring.

**What:** A path-anchored form (`build/**/*.o`, "only at the root") and an *include-only* mode
("compare only `*.pdf`").

**Impact:** Precision for people with a specific shape of tree; also sharpens item 1b's scan scope.

**Effort:** Low–Medium. **Risk:** Low.

---

## 14. ⌘K command palette

**Why:** The flat workspace bar made every workspace one click deep, and then folding Rename into a
conditional chip took one destination *off* the bar entirely. That is the right trade for a rare
finding, but it leaves nothing to aim at: a user who thinks "rename" has no target for the thought.
A palette is the general answer — and it is the only surface that can route to a control that is
not currently on screen.

**What:** One field over the window, indexing four kinds of thing:

| Kind | Examples | Does |
|---|---|---|
| Workspaces | Compare, Duplicates, Storage | switches, keeping the current source |
| Sources | iCloud, Projects, Backup SSD | re-aims the current workspace |
| Folders | recent and pinned paths | reveals in the source browser |
| Actions | Rescan · Undo last run · Add Folder… · New backup… | runs it, or opens its sheet |

"Rename" resolves as an action that opens Organize with the risky-names chip selected **whether or
not the chip is currently showing** — which is what closes the hole the fold opened.

**Surfaces to mock:** the overlay (query field, grouped results, selection, a keyboard-hint column);
the empty-query state showing recent and likely actions; an unavailable result — an unmounted source
— shown disabled *with its reason*, not hidden.

**The one implementation trap:** **this cannot be `.onKeyPress`.** That modifier is strictly
focus-scoped: with focus in a file table a sibling's handler never fires, and with no focus at all
nothing fires anywhere. A palette that works only when you have not clicked anything is worse than
none. It has to be a menu-item shortcut — which also documents it in the menu bar — or an `NSEvent`
local monitor.

**Effort:** Low–Medium. **Risk:** Low — read-only routing.

---

## 15. A rules view inside Organize

**Why:** Filing rules act on filing, and the one that matters most is *learned* from a filing move
just made. Clicking a file a rule placed and asking "which rule did that?" currently costs a
workspace change — and *Learned rule* is already a filter chip in Organize, so half the association
is there.

**What:** A persistent control in Organize's header, beside *File all N*, that swaps the right slot
for the rule list, editor and preview. Deliberately **not** a chip: the risky-names chip earns its
place by *disappearing* at zero, and rules do not — eight rules is a configuration, not a result,
and putting it in the chip row would teach that row two different meanings.

**Surfaces to mock:** the header control and its active state; the rule list in the lens slot; the
rule editor; the return path back to the queue.

**The trap:** Organize homes the left pane on the loose-files inbox, but rules file into
destinations all over the source. Opening the rules view has to **re-home the rail to the source
root** — otherwise you are editing a rule about `Documents/IRS` while the pane shows an unrelated
folder — and closing it must put the rail back, or the control is a one-way trip out of the queue
you were working.

**Effort:** Low–Medium. **Risk:** Low.

---

## 16. A Home workspace — the one-screen answer

**Why:** Every workspace is somewhere you go with a task already in mind. There is nowhere to land
*without* one, and after item 1c there will be state worth checking that no existing surface owns:
a held job, a stale scan, a rule that has been quietly filing for a month.

**Depends on 1c.** Build it earlier and it summarises two numbers, which is a worse first
impression than the cold start it replaces.

**What:** Four tiles over two lists.

| Tile | Reads | Goes down when |
|---|---|---|
| Not backed up | folders outside every source root with no job covering them | a job **completes** — never when one is created |
| Jobs | last run, next run, held count | a held job runs again |
| Reclaimable | Duplicates + Storage | duplicates are deleted |
| Not on this Mac | dataless files across all sources | files are downloaded |

Then **Needs you** (a held job, risky names, an unbacked folder — each with one action) and **Runs
without you** (jobs and rules with their last run).

**Surfaces to mock:** the tile row; both lists; a recent-activity column linking to the Activity
Log; and the stale state below.

**The trap that makes or breaks it:** a dashboard implies monitoring, and there is none — jobs only
run while the app runs, so quitting on Friday freezes every tile. A green Home backed by a nine-day
scan is the most convincing lie the app could tell. **Every tile carries its own age**, and stale is
a visible state: past a threshold the tile greys and reads *as of 9 days ago* instead of a number.

**One structural note:** Home has no source browser — it reads across every source at once. That
breaks the invariant that currently holds for all five workspaces ("the left side is always a file
browser"), so the layout family belongs on `Workspace` itself (`.twoSources` / `.sourceAndLens` /
`.global`) rather than being decided per view. It also costs a seventh bar segment — see the
width note in 1b.

**Effort:** Medium. **Risk:** Medium — every claim it makes.

---

## 18. A content fingerprint for PDFs — duplicates a byte hash cannot see

**Why:** Providers re-generate the PDF on every download, stamping a fresh document `/ID` into the
header. The same bill downloaded twice is therefore **byte-different with identical content**, and
`DuplicateFinder`'s content hash reports no match. Measured in one tree:

```
Home/Utilities/PG&E/2023/07. Jul 2023.pdf         402,394 bytes   md5 8689e3fb…
Home/Utilities/PG&E/2023/9829custbill07182023.pdf 402,394 bytes   md5 931c425b…
```

Same bill, same byte count, differing at byte 36; extracted text identical. Both sit in the *same
folder* — one renamed to the house convention, one the original that was never deleted. The August
pair is the same story. Tree-wide: **383 groups share a (name, size); 315 are byte-identical and 68
are not.** Those 68 are real duplicate sets the app currently misses.

This is a **fourth** blind spot, and worse than the three in `DEFERRED_ENHANCEMENTS.md` #6
(cloud-only, over the size cap, hard-linked) in one specific way: those three are *detected and
reported* — `DuplicateScanSkips` counts each reason and the results view says so. This one is
silent. The files hash successfully and simply do not match, so the scan reports a clean result
that is wrong, and no counter moves.

**What:** For PDFs, a fingerprint over the *content* rather than the file bytes — the extracted text
(PDFKit gives it without an external dependency), or the concatenated page content streams for
scans with no text layer. Grouped as a weaker claim than byte-identical, with its own vocabulary and
its own never-auto-trash rule, exactly as Deferred #6 argues a sampled hash would need. Cheap
pre-filter: only files that already share a (name, size) or a (size, page count) need the second
pass, which is 828 files out of 9,861 in the surveyed tree.

**Impact:** High, and it lands on the tree's largest single category — 80% of these files are PDFs.
It is also what would let the shipped rename pass do more than it currently can: that pass detects a
raw original and its renamed copy contending for one slot and refuses both, because you cannot
confidently delete the original after renaming a copy if the app cannot prove the two are the same
document.

**Effort:** Medium. **Risk:** Medium — it lands on the destructive review path, and a text-equal
claim is genuinely weaker than a byte-equal one. Scanned pages that OCR differently between two
downloads must not be called identical.

---

## 20. Restructure: ask whether the shape itself is right

**Why:** Organize answers *where does this file go*, one loose file at a time, and the rename pass
above answers *what is it called once it lands*. Neither can see a **series**. The same survey that
produced the filing profile found `Finance/US/Income Tax/<year>/` using **four different internal
schemes across thirteen years** for the same recurring annual event:

| Years | Shape |
|---|---|
| 2013–2014 | `Federal Tax/` · `State Tax (California)/` · `State Tax (North Carolina)/` |
| 2015 | `Common/` · `Federal Tax/` · `State Tax/` |
| 2016–2023 | `Forms/` · `Reference/` · `Refund/` · `Transcripts/` (＋ drifting extras) |
| 2024–2025 | `Deductions/` · `Income/` · `Tax Records/` · `Tax Returns/` |

Nothing there is a filing mistake — each year was filed sensibly at the time. Finding a W-2 simply
means first working out which era you are standing in. No per-file verdict can express that, because
the defect is not in any file.

**What:** A finding of Organize's scan that reads the filing profile, reports where the tree
disagrees with itself, and proposes a plan to fix it. **Not a sixth workspace, and not a *Structure*
tab beside *Files* either** — which is what this item proposed until 2026-08-07.

A sixth labelled segment costs **104 pt** of bar at the default text size (measured through
`WorkspaceBarMetrics.fullWidth` with the real labels at `.semibold`: 779 pt → 883 pt, and 99 / 111 pt
at the small and large sizes). Because the bar sheds every label at once, that takes the whole
779–883 pt band to glyphs, and items 1b and 16 are both ahead of this in the queue for that space.

The sub-tab was the same burial one level down: a tab you have to remember to visit, rendering
"Structure 0" on the days there is nothing — against a detector set that returns **eleven findings
across 2,798 folders** and, once they are acted on, nothing for months. So it takes the shape the
app already chose for risky names, whose argument is in `TidyView.organizeFocusChip` and applies here
more strongly: *a tab you have to remember to visit is a check nobody runs; reporting beats asking.*
A chip is louder than a tab because it is self-announcing — absent at zero, carrying its count when
it is not. Deliberate access is the palette (14), a Home tile (16), and a folder row's context menu.
Not a Tidy mode either — Tidy judges a compared pair; this judges one tree against its own habits.

**The groundwork has landed.** `OrganizeFocus` replaced Organize's `showingRiskyNames` Bool with a
selection, and the queue joined the finding as a chip, so adding structure findings is a third case
rather than a second Boolean that can disagree with the first. Five things this item must still do
that the names finding does not need, each a defect if built by analogy:

- **Do not gate the chip on the queue — but do decide what it does during a scan.** Organize's pills
  render only `if hasFilingResults`, and the focus chips deliberately sit outside that gate: zero
  loose files beside eleven findings is the state this feature exists for, because a tidy queue says
  nothing about the shape of the tree. The row *is* gated on `isSuggestingFiles`, though, because
  both existing lists are published on completion and are last scan's answer until then — and
  **structure findings are not**. They come from the profile with no disk read, so they are not stale
  during a filing scan and the shared gate would hide a chip that is still true. Either the gate
  becomes per-focus, or the row keeps one rule and this item accepts it deliberately; what it must
  not do is inherit the queue's staleness by accident.
- **Three states, not two.** No profile → no chip and no "checked" line. Profile and clean → a quiet
  `structure checked · 2,798 folders` on the row's trailing edge. Profile and findings → the chip.
  Absence must never be ambiguous between *clean* and *cannot run*, which is a gap the names finding
  has today.
- **Scope honesty.** The queue is scoped to `filingScanFolder` and the profile is tree-wide, so
  findings are filtered to the scanned scope's subtree and the trailing line names the folder count
  it actually checked. Otherwise the crumb claims findings that live outside it.
- **Finding identity survives a rescan.** *Never suggest this again* and an answered Question must
  decrement the chip and stay decremented — keyed on detector × folder path, stored beside
  `folderSemantics`.
- **Answers invalidate the check that asked them.** A Question's answer writes to the profile every
  detector reads, and an applied plan rewrites the tree. Both must bump a structure generation and
  recompute, or the lens re-suggests what it was just told — the replay family the v3.1 review named,
  and the same reason Refine became a generation-bumper.

**The hard part is silence, and it is a detector design problem.** 247 folder names appear under
more than one parent and 105 span different top-level areas, and **almost all of them are correct**:
`Statements/`, `Reference/` and `Transcripts/` are role folders that are supposed to recur, and
`Abhishek/` in fourteen places is the person axis working as designed. A detector that flags
repeated names produces hundreds of false positives and gets switched off in a day. So the detector
never compares names globally — it compares siblings inside one family (one parent, one role) under
two rules:

- **Axis values are not structure.** Children named for a year, a person, a jurisdiction or an inbox
  are dropped before two siblings are compared. They recur legitimately *and* differ legitimately.
  What survives is the folder's role vocabulary — the part that is supposed to agree.
- **Difference is not divergence.** A family diverges only when **two or more groups of siblings
  each vouch for a different shape**. One odd sibling out of thirteen is drift, not an era.

Run against the profile's 2,798 folders those two rules return **two divergent families in the whole
tree** — Income Tax (13 years, 4 eras) and `Immigration/Authorization/H-4` (4 periods, 2 eras, which
the survey had not spotted). The controls stayed quiet: `Travel/Trips/United States`, whose states
each hold different cities; `Chase/Archive`, whose accounts each ran for different years;
`Credit Accounts`, where two of four have a backlog folder and two do not. Divergence is one
detector of eight — the others cover a subtree mirrored under an inbox (`Health/Dental` vs
`Health/TODO/Dental`), a child whose name echoes its parent's (`PG&E/PGE`, 18 raw files, invisible to
the `TODO` rule), a loose folder beside a container that already owns the concept (`Home/ATT Bill`),
files parked above a year series, dead weight (52 pass-through, 434 single-file leaves), and the two
below that the 6 Aug reorganisation added.

### What reorganising `Immigration/` by hand taught this design

The H-4 finding above was **acted on for real on 2026-08-06** — 132 file moves, 4 folder renames, 39
empty-folder removals, per-action evidence, md5-verified, two removals reverted as mistakes. The log
is `immigration_reorg_2026-08-06.json` beside the profile, and it is the worked example of the plan
format. Five things it changed here, each of which the design had wrong or missing:

- **Tabulate siblings before theorising, across the whole family group.** The detector flagged H-4,
  but the *cause* only appeared once the three parallel families (H-1B, H-4, H-4 EAD — **fourteen
  eras sharing one vocabulary**) were laid out as a table: **each new filing lands flat and is only
  foldered later, so the newest era has never been foldered.** 2026–2029 was flat in all three at
  once. Divergence is not mysterious drift; it is a backlog with a predictable shape. The comparison
  unit is therefore the family *group* — fixing H-4 alone would have left it disagreeing with its two
  siblings. **New detector: the newest instance of a recurring series has no folders yet**, which is
  worth saying the month it happens rather than thirteen years later.
- **Neither the newest era nor the majority is the authority.** This item originally proposed
  defaulting to the newest. The real fix went both ways at once: H-1B is filed on **Form I-129, a
  petition**, H-4 on I-539 and H-4 EAD on I-765, **applications** — so one folder was renamed
  `Application → Petition` and two `Petition → Application`, from a fact that exists nowhere in the
  tree. A recency or majority default would have been confidently wrong in both directions. *Name it
  myself* has to sit among the schemes it found, not behind them.
- **Rename the folder; do not move the files.** Four `rename-dir` operations brought all fourteen
  eras into agreement, **carrying 58 files each and moving none**. Where siblings differ only in what
  a folder is *called*, a rename is atomic, preserves file identity and cannot half-finish. The plan
  must distinguish *files moved* from *files carried*, and prefer the rename whenever a mapping is
  one folder to one folder.
- **An empty folder is not uniformly debt.** A prune scoped to the branch rather than to what the
  move emptied removed two folders it should not have — `Supporting Documents/Resume` and
  `Supporting Docs/HPE/Payslips`, both already empty and both *category* names. An empty **date
  bucket** is debt; an empty **category** is a destination waiting for its next file. So the 76
  empties are split by the shape of the name and never offered as one number, and the removal step is
  scoped to folders the plan itself emptied.
- **New detector: a shadow axis value.** `Finance/US/Income Tax/IRS Docs - 2023` and `IRS Docs - 2024`
  sit beside the bare-year folders `2012`–`2025`, but the profile records no `year` axis for them, so
  they land in a different family and are never compared with the years they belong to. Same class as
  the inbox that is not called `TODO`.

**One detector is deliberately absent.** *Duplicated taxonomy* — `Work/Archive/MapR/Compensation/`
holding both `Forms/` and `Income Tax/`, each with the same three form folders — must not ship on
name evidence. Tested against the tree, matching siblings by child names is dominated by correct
parallels: Vanguard's Roth and Traditional IRAs, four Chase accounts each foldered by year,
`PFL - Shweta` beside `SDI - Shweta`. **Identical sibling structure is usually a sign of health.**
What separates MapR is that the same documents sit in both, so this is a content claim and it waits
on item 18.

**A proposal is a plan, and the plan is a manifest.** Restructure emits an ordered list of typed
operations — create folder, **rename folder**, move folder, move file, and only as a separate opt-in
step remove a folder this plan emptied. Each carries its own written justification, as the 6 Aug log
does. It never deletes a file. Six invariants make it safe to aim at thirteen years of tax documents,
and the last three are scars from that day's work:

1. Every file that will move is listed by full path **before** anything runs, and the number on the
   button is the length of that list.
2. **Apply is closed over the manifest.** A folder holding a file the scan never listed is skipped
   and reported, not swept along — and the rest of the plan still runs. "Never silently touch a file
   it did not list" has to be an enforced guard, not a promise in a doc.
3. **The inverse plan is written to disk before the first move**, so a run interrupted halfway is
   still reversible.
4. **Nothing is dropped to make the shape fit.** A folder the target scheme has no slot for —
   `Transcripts/` under the 2024–25 vocabulary — stays where it is and is listed as *kept*.
5. **Every claim is re-derived at the moment of the action.** A planning-time fact about a file is a
   fact about a *past* state of the disk. That guard is what stopped a file being retired as
   "byte-identical" on a size match that had never been hashed — and **he edits this tree while the
   work is open**: twenty files moved out from under one session and a whole subtree was relocated
   mid-run, so every destination is re-probed immediately before it is used.
6. **Never hand an operation a parent folder as a proxy for its contents, and verify with a number
   from a different code path.** Collapsing per-file deletes into "directories containing nothing
   kept" sent **69 files classified *keep*** to the Trash; separately, a verifier reported all 75
   moves as missing because it resolved paths against the wrong root, and what exposed it was an
   independent file count that reconciled exactly. A verifier that says everything is broken is
   usually itself broken.

**The app proposes; it does not decide.** It shows the schemes it found, offers *Name it myself*
beside them, and defaults to nothing when the family group disagrees about which is current. The
leverage is that the mapping is edited once and applies to every member. And where the tree is
genuinely ambiguous — `Health/Kaiser - PG&E` beside `Health/Medical/Kaiser` share an institution
anchor, but coverage through an employer versus care records is not a fact recorded anywhere — the
finding is a **Question with no Apply button**, whose answer is written into the profile's
`folderSemantics` and never asked again. Guessing there is worse than asking, and the Immigration
rename — where the authority was a form number — is the case that proves it.

**Impact:** High. It is the only item that acts on the shape of the tree rather than its contents,
and the flagship case has been accumulating for thirteen years.

**Effort:** High. **Risk:** High — this is the most destructive operation the app would offer:
dozens of moves across folders in daily use, and a wrong one is much harder to notice than a wrong
file copy. **Its prerequisite is met** — the filing profile and the filing memory both shipped, and
`FilingProfileStore` loads them at launch — so what remains gating it is the rename pass, whose
review-and-apply path it should share rather than growing a second one. That is the argument for
building it after the rename pass rather than before it. The counterweight is that **the whole flow
has now been run by hand on this tree** — the mistakes above are the ones it actually makes, not the
ones it might.

---

## 22. People: file by *whose* document it is

**Why:** Six people file into this tree — Abhishek, Shweta, their children Aditi and Divit, and
his parents Muktha and Girish — and each files the same way: a folder named for them under
whatever the category is. The engine has known *that* people exist since the filing profile
shipped, but only as `personTokens`, a flat lowercased bag in which `Mom` and `Muktha` were
unrelated strings. Three defects followed from that, and **phase 1 (below) has shipped**:

- The alias map (`Mom` → `Muktha`) was read from `folder-profile.json` and **discarded at decode**,
  so the cross-person veto read `Mom - passport.pdf` against a folder whose axis says `Muktha` as a
  *contradiction* and refused the correct folder.
- A token intersection reads **`Aditi Abhishek`** — the daughter's full name — as naming her father
  too, because `abhishek` is his given name and her surname. `girish` is worse: Dad's given name,
  Mom's surname, and Abhishek's surname all at once.
- The veto read the **filename only**, so a scan named `Scan 2026-08-02.pdf` had no protection at
  all, and the refine pass — the one that reaches the cloud model — never applied the veto.

**What shipped (phase 1).** `PersonRegistry` holds a roster of `Person` records and matches
**phrase-first, longest wins, consuming the span**: in "Aditi Abhishek" the surname is spent on
Aditi and never doubles as evidence for Abhishek. Strong (unique) versus shared tokens are
**computed from the roster**, so adding a seventh person re-derives the split. The registry loads
from `profiles/<id>/people.json`, or is seeded from the profile's person axis when that file is
absent — the seed alone fixes the alias misfire. Both the veto and the router's person-axis score
now resolve through it, ending the two-tokenizer disagreement between `FilingEngine.nameTokens` and
`FilingRouter.tokenize`. The router treats a person match as confirmation (+1.0) and a
contradiction as a penalty (−3.0), which is what picks between sibling person buckets that hold
identical documents; Settings ▸ Organize shows the roster read-only, including which words are
shared with whom.

**What remains.**

- ~~**Editing in the app**~~ — **shipped.** Settings ▸ Organize ▸ People adds, edits and removes
  people, with a live preview of what a draft would match; `PeopleStore` owns the write path and
  `people.json` is the one filing artifact the app writes.
- **Learning from filing** — a recurring name-shaped phrase in documents filed to one person's
  folders becomes a *suggestion* ("add *Shweta Ravindra Dani* as another name for Shweta?"), never
  an automatic write. Likewise an identifier a person's folders have received (a passport or member
  number) becomes evidence for scans carrying no readable name. **Half of this shipped**: a person
  the tree files for who is not on the roster is surfaced with an Add button, from the survey's own
  `axes.person` values.
- ~~**`personIs(<person>)` as a rule condition**~~ — **shipped**, together with the `{person}`
  destination token that was the point of it: `Immigration/OCI/{person}` files each family member's
  card into their own folder, so the household needs one rule rather than seven. The condition
  keys on the person's id, so a rule survives a rename and picks up a name variant added later; the
  offer made after filing into a person's folder proposes both, and never keys a person rule on
  that person's own name. Rule persistence became tolerant of unknown conditions in the same
  change (see below).
- **Person buckets that do not exist yet** — a *create the sibling* proposal, from the parent's
  evidence, the way a cold year bucket is already handled.
- **A person block in the classifier brief**, so a backend reads "Shweta R Dani" as Shweta too.

**Measured, and not where I expected.** Every filed document is a labelled example, so both rules
were replayed over the 1,375 corpus documents whose folder carries a person axis. The obvious
metric — *false vetoes*, refusing the folder a document actually lives in — is **unchanged at 3**,
and all three are `Family/Aditi/Events/Baby Shower/`: documents named for the parents inside the
child's event folder, which no name intelligence resolves because the folder is Aditi's for a
reason the filename cannot state. What the registry fixes is **over-attribution: 36 → 0**.
`Muktha Girish - Resume.pdf` names one person and the token rule reported two, because `girish` is
her surname and his given name. Each of those 36 is a document the veto would have let into the
wrong person's folder — the protection failing *open*, which is the failure invisible in use — and
36 files scoring against a family member they have nothing to do with. `RealFilingProfileTests`
holds both numbers.

**Impact:** High. Misfiling one family member's document into another's is the error least likely
to be noticed and most annoying to undo, and person is the *only* signal that separates sibling
folders holding identical kinds of document.

**Effort:** Medium, staged. **Risk:** Low — every part is additive and gated on a registry being
loaded; with none, the engine behaves exactly as it did.

---

## Interface — visual polish and information design

Everything below changes how something **already shipped** reads. Not capability, but planned work
with the same claim on time as the list above — and several entries are cheaper than anything in
it. Re-checked against the code on **2026-08-05**, after the v3.1 cut; each names its evidence so
a mock-up can be drawn from the real thing rather than from memory. The two entries whose
surfaces v3.1 changed — the stat pills and the pane headers — carry their updates inline.

Six proposals from the same pass have already landed and are deliberately absent: scan freshness on
the differences count pill, folder sections in that table, "Copy" spelled out on the transfer
buttons, selectable and collapsible section headers, and the Settings rail with its live accent
preview.

---

### Fold Change and Copy-to into one Direction lane

**Now:** `DifferencesView` renders `TableColumn("Change")` and `TableColumn("Copy to")` separately.
Change is a full sentence — "Missing on right (Dropbox)" — repeated down the whole column, and
Copy-to then repeats the provider name. Together roughly 700 pt to encode one bit per row: which
side is short. Meanwhile Name, the only column carrying real entropy, is the one truncating. The
row's leading colour stripe already states the same fact a third time.

**Change:** one narrow Direction lane — the existing `DifferenceGlyph` plus both provider names,
absent side struck through: `iCloud ──▸ D̶r̶o̶p̶b̶o̶x̶`. The sentence survives as the tooltip and the
VoiceOver label, both of which already exist as `difference.description`.

**Also fold in:** `Size` currently mixes "101 KB" with "1,033 items" in one right-aligned column.
Folder item counts belong as a muted suffix on the name, leaving Size comparable down the column.

**Impact:** ~500 pt back to Name, and direction becomes shape and position rather than prose. The
largest single interface win left.

**Effort:** Medium. **Risk:** Medium — `changeSortRank` and `copyToSortRank` are live column sort
keys; a merged column still needs a sort story.

---

### Drop the "Identical" badge from the majority row

**Now:** every duplicate row wears a green *Identical* badge in the leading slot (`TidyView`, the
`.identical` case). On a real scan that fires on the overwhelming majority — the *Overlapping* and
*needs review* cases, the only ones needing a human decision, wear identical weight and are lost in
the run.

**Change:** drop the badge on the majority case. Give the freed leading space to the file-type icon
and a copy count ("3 copies"); keep a badge — plus a severity stripe and a faint wash — only for the
exceptions, and let them say what they want ("needs a choice") rather than naming their category.
The green pill moves to the reclaim figure at the trailing edge, which is what the row is about.

**Impact:** the exceptions become findable by scanning instead of by filtering, and a row's visual
weight starts tracking how much attention it deserves.

**Effort:** Small. **Risk:** Low.

---

### Make the Tidy stat pills the filter

**Now:** `TidyView` renders the header tally as `StatPill(...)` — *N groups*, *N redundant*,
*N need review*, *N skipped* — capsule-shaped, semantically coloured, and completely inert. The
real filter is a separate `All ⌄` menu at the far right of the same row. The pill reading "263 need
review" is exactly the control someone reaches for to see those 263.

**Change:** make the pills the filter. Click one, the list narrows, that pill takes a selected
state, the rest dim. Two want different handling: the reclaimable figure is not a subset, so it
sheds its capsule and becomes plain trailing text; and *skipped* is the one nobody can act on —
give it a tooltip saying **why** those were skipped, since "skipped" with no reason is an
unanswered question sitting in the header.

**v3.1 added two more pills to these rows, and neither is a subset either**: Organize's *reused*
(what the verdict cache saved — a scan-level fact like *skipped*, already carrying its own
explanatory tooltip) and Storage's freshness marker on a restored report (not a count at all).
Whatever selected/dimmed treatment the filtering pills get, these two must stay visibly inert or
the header teaches that clicking pills sometimes does nothing.

**Impact:** removes a duplicate control, and makes the obvious click the working one.

**Effort:** Small. **Risk:** Low.

---

### Magnitude bars behind the largest-files list

**Now:** the Storage lens's *largest files* rows set 222.5 MB and 53.6 MB in the same weight at the
same position, so a four-fold difference reads as nothing until the digits are compared. The
section is titled *the biggest individual files* — magnitude is its entire point.

**Change:** a faint bar behind each row scaled to the largest file, plus a share-of-folder
percentage. Same rows, same data, but the shape of the distribution — one huge file and a long flat
tail — becomes visible without reading a number. While there, drop the two always-visible row
glyphs to hover-reveal: they already use `hoverAffordance`, so this only finishes what that style
started.

**Effort:** Small. **Risk:** Low — read-only lens, pure presentation. Cheapest item on this list.

---

### One sequential ramp for the Storage treemap

**Now:** `TreemapView` is a single proportional row on a rotating ten-hue palette assigned **by
index**, so blue-for-Work and teal-for-Claude mean nothing and the eye keeps looking for a legend
that cannot exist. The palette's light entries force per-tile label-colour arithmetic to stay
readable — real code spent defending an arbitrary decision — and the smallest areas clip to a few
points saying nothing at all.

**Change:** one sequential ramp, deep to pale, ordered by size, so **colour is the ranking**.
Everything under ~5% folds into *Other* with a hover breakdown, which removes the sliver tiles
rather than trying to label them.

**Impact:** the ramp's light end lands on the small tiles, which carry no labels anyway — so the
contrast problem dissolves instead of being solved. Also a step toward a real nested treemap rather
than a detour: same rule, one hue, luminance by size.

**Effort:** Small. **Risk:** Low.

---

### Name the compared pair in the title bar

**Now:** the title bar is hidden, so the window carries a tab strip on the left, three icon buttons
on the right, and no title. `window.subtitle` is never set anywhere in `MacApp`. Two windows side by
side are indistinguishable, Mission Control shows two identical thumbnails, and the Window menu
lists "SyncCloud" twice.

**Change:** a subtitle naming the pair — `iCloud/Documents ⇄ Dropbox/Documents` — shown beside the
tab strip **and** set as the real `window.subtitle`, which is what Mission Control and the Window
menu read. On a single-source workspace it names that source instead.

**Mock-up note:** truncate from the middle as the window narrows, matching the pane breadcrumb.

**Impact:** one line of state that already exists, answering a question the app currently cannot
answer at all.

**Effort:** Small. **Risk:** Low.

---

### One-line pane headers

**Now:** `PaneHeader` (`DashboardViews.swift`) is a `VStack(spacing: 8)` of two rows — provider
capsule plus the pane bar above, breadcrumb below — repeated in both panes. Roughly 120 pt before
a single file appears. Scan freshness has already left for the differences count pill, which
removed one duplicated pill but not the duplicated band. Since this was first written the bar has
become **user-arrangeable** (`PaneBarArrangement`, up to 16 items) and v3.1 added the **search
pill**, so "the nav cluster" is no longer a fixed five buttons but whatever the user kept.

**Change:** fold each pane to one line — provider chip, breadcrumb, link glyph — and reveal the
bar on hover or keyboard focus, the way the Storage lens's row glyphs already behave. Two
constraints that did not exist when this was proposed: the fold must respect the user's own
arrangement rather than a hardcoded cluster, and an **expanded ⌘F search field cannot hide on
hover-out** — a field the user is typing into is not chrome.

**Mock-up note:** draw both panes, left hovered and right at rest. The `.mini` control rung at the
250 pt pane clamp is the constraint that decides whether this works at all.

**Impact:** ~44 pt back, which is three more file rows per pane, on every window, permanently.

**Effort:** Medium. **Risk:** Low–Medium — the header height is pinned by `PaneHeaderHeightTests`
against `LiquidGlass.headerHeight`, and `LensHeaderCard` shares that line from the other side.

---

### A review sheet before a bulk duplicate trash

**Now:** *Apply N recommended* raises a native confirm that gets the safety story right — group
count, copies, reclaim total, undoable with ⌘Z — but it is one paragraph standing in for hundreds
of keeper decisions, and the button says "Apply", which sounds settled before anything has been
shown.

**Change:** rename it *Review N recommended…* and make the confirm a sheet: reclaim total up top,
then the handful of groups where the keeper was genuinely ambiguous — same size, same content,
different folder — hoisted for a glance, with the unanimous majority collapsed behind a count. A
per-row *swap* flips which copy is the keeper without leaving the sheet. Confirming stays one click
for anyone who does not want to look.

**Impact:** the existing alert answers "is this safe?". This answers "is this **right**?", which is
the question hundreds of keeper picks actually raise.

**Effort:** Medium. **Risk:** Low — it only adds a step ahead of an operation that already exists.

---

## Summary

### Capability

| # | Item | Effort | Impact |
|---|------|--------|--------|
| 1 | **Backup** — the lens and jobs (folder sources shipped) | Medium→High, staged | **Highest** |
| 2 | Sync presets | Low | High |
| 3 | Strict content match (its persisted index shipped in v3.1) | Medium | Medium–High |
| 4 | `bothModified` detection | Medium | High |
| 5 | Folder watching → auto-rescan | Medium | High |
| 6 | CLI parity for the lenses | Low–Medium | High |
| 7 | Cross-provider duplicates | High | High |
| 8 | Export / import configuration | Low | Medium |
| 9 | Auto-running automations | Medium | Medium–High |
| 10 | Folder Merge on collision | Medium | Medium |
| 11 | In-app diff viewer | Medium | Medium |
| 12 | Menu bar status item | Low–Medium | Medium |
| 13 | Path-anchored / include-only rules | Low–Medium | Medium |
| 14 | ⌘K command palette | Low–Medium | Medium–High |
| 15 | Rules view inside Organize | Low–Medium | Medium |
| 16 | Home workspace | Medium | Medium (after 1c) |
| 18 | PDF content fingerprint | Medium | High |
| 20 | Restructure — is the shape itself right | High | **High** |
| 22 | People — editing, learning, and `personIs` rules (phase 1 shipped) | Medium, staged | **High** |

### Interface

Cited by name; this list has no stable numbering.

| Item | Effort | Impact |
|------|--------|--------|
| Fold Change + Copy-to into a Direction lane | Medium | **Highest** — ~500 pt back to Name |
| Drop the "Identical" badge from the majority row | Small | High — the exceptions become findable |
| Make the Tidy stat pills the filter | Small | Medium–High — removes a duplicate control |
| Magnitude bars behind the largest-files list | Small | Medium–High — best value per unit of work |
| One sequential ramp for the treemap | Small | Medium |
| Name the compared pair in the title bar | Small | Medium |
| One-line pane headers | Medium | Medium — ~44 pt on every window |
| A review sheet before a bulk duplicate trash | Medium | Medium |

**Where the value is.** Item 1 is the largest single addition on this list. Its first stage,
**folder sources**, has shipped and unblocks the rest — the lens is what to build next. Items **2** and
**6** remain the best small wins; **5** is worth pulling forward because it serves both the stale
comparison and item 1c's best trigger. Biggest single payoff and biggest risk: **7**.

**The Organize arc (17–21) is one arc, and the order inside it is forced.** 21 goes second, right
after 17: it needs the profile, nothing else needs it, and held-out on 7,558 real filed documents it
more than doubles top-1 routing accuracy over the profile alone (28.9% → 58.2%) for Low–Medium
effort. **The rename pass has shipped** without waiting on 18, by refusing rather than guessing: where a raw
original and its already-renamed copy both want one slot, it reports the collision and touches
neither. That leaves 18 worth building for the *duplicate* verdict it was always about, not as a
precondition. 17 sits under the rest, because it is what told the rename pass which convention each
destination folder uses — and what tells 20 which folders are inboxes, which names are axis values,
and which duplication is deliberate. **20 comes last**, both because it is the only one that moves
folders rather than files and because it now has a review-and-apply path to inherit rather than
one to invent.

Taken together they are the first work aimed at the *backlog* rather than at the scan: one surveyed
tree carries 524 loose files at its root, 682 files with a duplicate marker in the name, 68 duplicate
groups that hash-based Tidy silently misses, and one thirteen-year folder series filed four different
ways. **17 and 21 are together the cheapest route to a good free tier** — between the tree's own
conventions and what its folders already contain, most routes are decidable by arithmetic, so fewer
files ever reach the paid refine pass.

**The cheapest two, both independent of item 1:** **15** (the rules view, which moves an existing
list into a slot that already exists) and **14** (the ⌘K palette), which is the one that pays
back the flat bar's only regression — folding Rename off the bar left a destination with nothing
to aim at. The third — "Find duplicates of this" — has shipped.

**Watch the bar.** Items 1b and 16 (Home) each add a segment. Five labelled segments already
overflow the 600pt floor, and `WorkspaceBarMetrics` sheds all labels at once when they do; at
seven the bar is icon-only at most real window sizes. If both ship, re-measure before assuming the
labels survive.

---

## Why `DEFERRED_ENHANCEMENTS.md` is still its own file

Asked and settled on **2026-08-02: keep it separate.** The two files look similar — both are lists
of things not done — but they answer different questions and are read at different moments.

- **This file is intended work.** It is a plan you plan against and work down. Every entry is
  something we mean to build; an entry sitting here for a year is a signal.
- **That file is accepted limits.** A cap, a skip, a guard the code deliberately keeps, each with
  the reasoning that made it a decision. An entry sitting there for a year is the system working.

The tell is that several deferred entries are explicitly *low value and may never be worth doing* —
the atomic-replace exotic corners need three simultaneous I/O failures; the concurrent log-trim race
costs one line in a diagnostic file. Those are correct to record and wrong to schedule. Folding them
in would break both files at once: this one would stop being a plan you can work down, and eleven
carefully-argued trades would read as neglected backlog.

You reach for that file when the *code* surprises you — "why does this skip files over 100 MB?" —
and this one when you are deciding what to build next. Different question, different file.

**The real problem was duplication, and it is fixed.** In-place folder Merge carried a full
specification in both files. It lives here now (item 10), because it is planned feature work rather
than an accepted limit, and a spec kept in two places drifts in one of them.
`DEFERRED_ENHANCEMENTS.md` #1 keeps only the record of why it sat there first, and points here. The
remaining cross-links are one-directional and correct: item 7 → Deferred #6 (hashing's three blind
spots), item 3 → Deferred #9 (the hash cache, now persisted and closed — item 3 links to it for the
record of how the index was built, not for outstanding work).
