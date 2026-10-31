# SyncCloud — Roadmap

**One file, three parts.** Until 2026-10-18 this was three files; their contents were moved here
unchanged, except that references between them now name a part instead of a file.

| Part | Was | Holds |
|---|---|---|
| [**Backlog**](#backlog--features-across-every-surface) | `ROADMAP.md` | net-new capability and interface work across every surface |
| [**v4**](#v4--the-4x-line) | `ROADMAP.md` v4 | the 4.x Browse and navigation work — tabs, the ⌘K field, Finder borrowings, window chrome, the menu bar |
| [**v5**](#v5--organize) | `ROADMAP.md` v5 | Organize — Restructure, the document survey, and the rest of the Organize surface |

**How to cite.** Section numbers are per part and were carried over, not renumbered: write
**v4 §7** or **v5 §5.2**, and cite Backlog items by name. Code comments write
`ROADMAP v5 §5.2`. Commit messages, `docs/backports.md` and test fixtures written before the merge
say `ROADMAP_V5 §5.2` or `ROADMAP_V5.md` — read either as **v5 §5.2** of this file; `ROADMAP_V4`
likewise means the v4 part.

Shipped work is deleted rather than marked, because git history is the record. Distinct from
`DEFERRED_ENHANCEMENTS.md` (accepted limits) and `REFACTOR.md` (internal shape). The web roadmap
page — open work only, with mockups and the RD/CP/# item IDs — is
<https://claude.ai/code/artifact/3505ee14-3e80-4d17-a82d-d2b2e52a832f>.

---

# Backlog — features across every surface

**Pending work only** — net-new capability first, then interface changes to surfaces that already
ship. Shipped items are *removed* from this file rather
than kept with a "shipped" note: git history is the record of what landed, and a backlog that
carries its own finished work stops being scannable — by the last pass, five of sixteen entries
existed mainly to say they were done. Status re-checked against the code on **2026-08-02**.

Distinct from `DEFERRED_ENHANCEMENTS.md` (hardening / coverage consciously punted) and `REFACTOR.md`
(internal shape that is correct but worth restructuring). The v4 part holds the 4.x Browse and
navigation work — tabs, the ⌘K field, and the rest of what is worth taking from Finder — which is
scoped to one workspace and carries its own shared constraints, so it reads better as a file than as
an item here. The v5 part holds **Restructure** (item 20 below), which moved out of the 4.x file
on 2026-08-16 to become its own release: it is one project, it is the only planned work that moves
folders rather than files, and it needs a plan surface, an on-disk inverse and a background survey
before any of it lands.

**Four of this file's Interface items are scheduled into v4.2** and are cited by name from
v4 §9 rather than restated there — magnitude bars, the treemap ramp, the "Identical"
badge, and the stat pills as the filter. Their specifications stay here; a spec kept in two places
drifts in one of them.

Numbers here are positional and change as the list does — **cite items by name, not by number.**

---

## 1. Backup: know what has only one copy, and keep a second

**Why:** Three separate user requests turn out to be one capability.

- *"List everything not on iCloud, so I know what I'd lose if this Mac fails."*
- *"Let me review the files on OneDrive / Dropbox that are cloud-only and not on this Mac."*
- *"Let me point Tidy [now Organize] and Compare at any folder, not just cloud providers."*

The first two are opposite ends of one axis — **how many places does this file actually exist?** —
and SyncCloud already answers it per file: `FileLocation` crosses path containment (pure string
math over the provider list) with materialization (one `lstat` for `SF_DATALESS` via
`MaterializationStatus`, the same one that draws the ☁ badge). That classifier ships, and with it
the per-file surface — the *Where it lives* inspector row, which answers for a folder by containment
too (the `⌂` row badge that did that on the rows was removed in 5.4). What is left is
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

**What:** A fifth **workspace** (`Workspace.backup`, with a matching `WorkspaceLensKind.backup` behind it),
sitting after Edit in the bar. Note the shape this now takes: the two-level *Compare | Tidy* +
lens picker is gone — `Workspace` collapsed both levels into the flat toolbar bar — so "add a lens"
and "add a top-level tab" are the same act, and the cost is a bar segment rather than a structural
change to `ContentView`'s layout modes. The shared 81pt `LensHeaderCard` rung applies unchanged.

**Storage is no longer the precedent for a read-only analytical *workspace* — it is the precedent
for a read-only analytical *lens*.** It folded into Organize, which is the change that makes room
for this one. That reframes the question below: Backup as a workspace has to argue that it is a
different KIND of place, not merely a different report. The rule Organize now draws is "everything
the app concludes about a single tree"; Backup concludes something about a tree's *copies
elsewhere*, which is a genuinely different subject and is the strongest argument for a segment of
its own. If that argument fails, the fallback is the one Storage just took: a lens inside
Organize, at no bar cost at all.

**The bar-width consequence, which is the only real cost — and it has since been paid once.**
The labelled segments approach the window's `minWidth` once the traffic lights and utility pill are
counted, and `WorkspaceBarMetrics` sheds every label at once (`.full` → `.iconOnly`) when they
exceed it. An added segment moves that threshold further out, so the bar spends more of its time
icon-only.

**What this paragraph predicted, and what actually happened — twice.** It measured four segments at
**708pt** and five at **800** against a 760 floor, and concluded that a fifth means "either an
icon-only floor again or another raise". A fifth arrived — the Edit workspace, not Backup — and
the answer was *another raise*, plus one thing this analysis did not have: **deleting the bar's
group rule**, which handed back 13pt (the rule, its padding, and its own `segmentGap`). Measured
through `WorkspaceBarMetrics.styles` at the default text size with the ⌘K pill compact, five
segments needed **781** and the floor went to **810** (Large 833, Largest 853 — both above the
floor, so those two sizes shed).

**Then Storage folded into Organize and the fifth slot came back.** The bar is four segments again,
measured at **666.8 / 683.8 / 725.1 / 741.6** for Small / Default / Large / Largest, and the floor
came back down to **760** in the same commit. Every text size keeps its labels at the floor now,
which is the best state the bar has ever been in — and the notable side effect is that the
icon-only rung is currently unreachable by the shipping bar at any legal window width. It is kept,
not deleted, because this section is what would bring it back.

**So Backup's cost is a return to five, not a push to six.** That is the whole value of the fold to
this feature: five segments were priced at 781/833/853 with an 810 floor, and "Backup" is a
slightly narrower word than "Storage" was, so the numbers land at or just under those. Re-measure
through `WorkspaceBarMetrics.styles` rather than trusting that estimate — but the shape is known,
and it is a floor RAISE that already has a precedent rather than a second unbudgeted one. The glyph
has to carry the whole label at narrow widths, so it must be legible alone rather than decorative.

The six-segment wall is unchanged and is still the real limit: a sixth lands near **880**, and the
floor cannot keep chasing it — the window opens at ~85% of the screen, and a floor that is most of
a small display has stopped being a floor. Whatever comes after Backup is a lens.

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

*Item 23 (RD67) builds the first such job, iCloud → Dropbox one-way sync; read it before designing
another.*

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
| Undoing a run | `undoLastSyncRunAskingFirst` |
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

**Triggers:** every hour · daily at HH:MM · weekly · **when files change** (`FolderWatcher`, in
`Modules/Sync`) · manually.

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
- **Downloading a cloud-only file works beyond iCloud — measured.** `MaterializationStatus.download`
  uses `startDownloadingUbiquitousItem`, and on 2026-10-25 it fetched a real Google Drive placeholder
  (a 180-byte `.gdoc`) without throwing; `SF_DATALESS` cleared within a second. This line used to say
  there was no API outside iCloud; nothing had measured it. **Not yet measured:** Dropbox (no
  cloud-only file in the first 4,000 scanned) and OneDrive (only large files were cloud-only). When
  the call does throw, Download now reveals the file in Finder instead of only logging.
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

**What:** A "strict content match" mode that compares by hash where dates and sizes disagree.
Cloud-only placeholders stay skipped (`DEFERRED_ENHANCEMENTS.md` #6); files of any size are hashed.

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

## 6. CLI parity for the maintenance lenses

**Why:** The `synccloud` CLI does `scan`, `sync` and `providers` — the two-pane story only. Every
lens added since (To File, Duplicates, Renames, Restructure, Rules) is GUI-only — as is the
Storage workspace beside them, so none of it can be scripted,
scheduled with `launchd`, or run over ssh.

**What:** `synccloud duplicates --dry-run --json`, `synccloud file` (the To File lens — **not**
`organize`, which names the whole workspace and would put the lens/workspace ambiguity back into
the public surface the way `tidy` once did), `synccloud renames --check`,
`synccloud restructure --json` (report-only, like the lens), `synccloud storage --json`, and —
once item 1c exists — `synccloud backup --job <id>`. The engines
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

**What:** A cross-provider Duplicates mode that hashes two provider trees and groups across them, with a keeper heuristic
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
invariants wholesale. Gate it behind the folder watcher (`FolderWatcher`), a per-rule confirmation count, and a hard
"never auto-run a rule whose destination does not exist yet".

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
breaks the invariant that currently holds for all four workspaces ("the left side is always a file
browser"), so the layout family belongs on `Workspace` itself (`.twoSources` / `.sourceAndLens` /
`.global`) rather than being decided per view. It also costs a seventh bar segment — see the
width note in 1b.

**Effort:** Medium. **Risk:** Medium — every claim it makes.

---

## 18. A content fingerprint for PDFs — duplicates a byte hash cannot see

~~**The fingerprint itself**~~ — **shipped.** `ContentFingerprint` digests the sorted token
multiset of a PDF's extracted text and form-field values, plus its page count and page geometry;
`PDFTextExtractor` reads it with PDFKit; `DuplicateFinder` groups matches as `.sameText`, a weaker
claim than `.identical` with its own badge, its own note, and a standing exclusion from *Apply
recommended*. Digests are cached by (path, mtime, size) in their own index, beside the content-hash
one.

**What the corpus said — because four of this item's own assumptions did not survive it, and a
hazard it never named did the most damage.**

- **Recall is exact where it can be judged.** Over 10,569 real PDFs: 586 byte-identical pairs, 485
  of which both sides fingerprinted, and **0 disagreements**. The other 101 declined — an
  image-only scan makes no claim — and cost nothing, because a byte-identical pair is already
  grouped by the content hash.
- **It finds ~250 groups the byte hash cannot see** — 248, twice, from the shipped code over the
  same 10,569 files, with not one of those files changed between the runs. The measured premise
  held; the *numbers* in the original entry did not, because the tree has been reorganised since:
  232 groups share a (name, size) now, of which 183 are byte-identical and **49 are not**.
  Treat the total as approximate: about five groups move between differently-sized runs (see the
  determinism note below), always as a miss rather than a false match.
- **The proposed pre-filter was wrong and is not in the shipped pass.** "Only files that already
  share a (name, size) or a (size, page count) need the second pass" would miss the **132 of those
  251 groups** that span more than one byte size — more than half — because a re-stamp routinely
  changes the byte count too, and a compressed re-save changes it by an order of magnitude (a
  2.1 MB passport scan beside its 171 KB copy). Every fingerprintable document is read instead,
  which is affordable only because of the cache.
- **Sorting the tokens wins, but by three documents, not by the landslide the case for it assumed.**
  Hashing the token *sequence* finds 248 of the 253 groups the multiset finds over one frozen
  extraction. Reading the five groups only the multiset admits: three real (a state tax transcript
  filed twice, a compressed passport, a compressed birth certificate — re-renders that reordered
  the text), two not (a resume revision, and a report whose filename ends "- Sorted").
- **The token floor this item added is inert on this tree, and says so.** Its first justification —
  ten unrelated earnings summaries grouping on a lone page-number token — was itself an artifact of
  the racing reader above. Read serially those documents yield *zero* tokens and are declined at any
  floor, and ablation says the floor removes no group at all. It is kept as a bound on a shape a
  scanner can produce, not as a fix for one this corpus has.
- **Glyph soup is identity here, not noise.** `FilingSurvey.isDecodable` exists to keep
  `ToUnicode`-less nonsense out of a folder's anchors; porting that reflex would have dropped 11
  groups, ten of them real — including both halves of the `Form 1095-C` pair that is the clearest
  evidence in the tree of a duplicated taxonomy. Two downloads of one soupy document produce the
  same soup.
- **PDFKit's text extraction is not thread-safe**, which the replay caught and nothing else would
  have: six parses at a time, ~1% of documents extract different text run to run, and two runs of
  the same binary over the same files reported 226 groups and then 235. The queue is serial, and the
  same two runs then reported 251 and 251 — concurrency had been *splitting* real matches, not
  inventing them. A cold full-tree pass costs ~5.5 minutes instead of ~46 seconds, and nothing on
  any later scan. **A residue survives serialization**: a pair that groups when read alone can fail
  to group inside a full-tree run, ~5 groups in ~250, with two identical full runs either side of
  it. Recall against byte-identical pairs stayed 485/485 with 0 disagreements throughout, so the
  residue only ever costs a duplicate going unreported. It also cost this item's own floor its justification (see below), which is the
  general lesson: **a measurement taken through a racing reader is not a measurement.**

**What the claim is, and is not.** It proves the extracted text matches, which is not the same as
proving the documents do. Reading every group from one run, **9 were not the same document**: three
resume revisions whose edits were purely visual, five signed / redacted / stamped copies beside
their originals, and one report deliberately re-sorted. That is why the group is never in the batch
and why its note says to open them first.

**What remains.**

- **Scans with no text layer.** 853 of 10,569 documents (8%) say too little to fingerprint, and
  `DuplicateScanSkips.textUnreadable` now counts them rather than letting them vanish. The original
  entry proposed hashing "the concatenated page content streams" for these; that is untried, and the
  risk this item always named — two OCR passes of one scan differing — applies to any answer here.
- **The rename pass still refuses the case this was meant to unblock.** It detects a raw original
  and its renamed copy contending for one slot and declines both; it can now ask whether the two are
  the same document, and does not.
- **Restructure's *duplicated taxonomy* detector** (item 20) waited on this and can now be built on
  content overlap rather than name evidence.
- **A tag store keyed on the fingerprint**, so a find-by-person verdict survives a provider
  re-stamping the bytes.
- **"Compare copies" is offered for folder groups only**, and the same-text group is the one that
  would most benefit from it: its note asks you to open the documents before removing anything,
  precisely because the difference is *not* in the text and a 54pt page-1 thumbnail will not show a
  signature or a redaction three pages in. `DuplicateReviewCoordinator.compareCopies` already
  carries `keepIsDirectory` and relativises plain paths, so the pair case looks supported; it was
  left alone here because nothing in this change could drive the review panes to prove it.

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
disagrees with itself, and proposes a plan to fix it. **Not a fifth workspace, and not a *Structure*
tab beside *Files* either** — which is what this item proposed until 2026-08-07.

**Placement, as shipped:** a **rail item inside Organize**, not a chip and not a segment. The rail
replaced the finding chips when Organize became the umbrella (see the Interface section), and the
argument that settled it is the one this item cares about: *pointed invocation needs a place that
exists before any scan has run*, and a chip that materialises only after a finding has nowhere for
"restructure this folder" to land.

A **sixth** labelled segment costs **104 pt** of bar at the default text size (measured through
`WorkspaceBarMetrics.fullWidth` with the real labels at `.semibold`: 779 pt → 883 pt, and 99 / 111 pt
at the small and large sizes). Today's bar carries four, so the nearer step is the fifth — 708 pt →
800 pt, per the table under item 1b. Say which step a figure measures: renaming the ordinal to
"another" once left this paragraph quoting the five-to-six cost for a four-to-five move. Because the bar sheds every label at once, that takes the whole
779–883 pt band to glyphs, and items 1b and 16 are both ahead of this in the queue for that space.

The sub-tab was the same burial one level down: a tab you have to remember to visit, rendering
"Structure 0" on the days there is nothing — against a detector set that returns **eleven findings
across 2,798 folders** and, once they are acted on, nothing for months. So it takes the shape the
app already chose for risky names — now carried by the Organize rail's badge rule (`OrganizeLens`:
the item is permanent, the badge absent at zero) — and it applies here
more strongly: *a tab you have to remember to visit is a check nobody runs; reporting beats asking.*
A chip is louder than a tab because it is self-announcing — absent at zero, carrying its count when
it is not. Deliberate access is the palette (14), a Home tile (16), and a folder row's context menu.
Not a Compare handoff either — that judges a compared pair; this judges one tree against its own habits.

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
`Father/` in fourteen places is the person axis working as designed. A detector that flags
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
  `Supporting Docs/EMP/Payslips`, both already empty and both *category* names. An empty **date
  bucket** is debt; an empty **category** is a destination waiting for its next file. So the 76
  empties are split by the shape of the name and never offered as one number, and the removal step is
  scoped to folders the plan itself emptied.
- **New detector: a shadow axis value.** `Finance/US/Income Tax/IRS Docs - 2023` and `IRS Docs - 2024`
  sit beside the bare-year folders `2012`–`2025`, but the profile records no `year` axis for them, so
  they land in a different family and are never compared with the years they belong to. Same class as
  the inbox that is not called `TODO`.

**One detector is deliberately absent.** *Duplicated taxonomy* — `Work/Archive/Acme/Compensation/`
holding both `Forms/` and `Income Tax/`, each with the same three form folders — must not ship on
name evidence. Tested against the tree, matching siblings by child names is dominated by correct
parallels: Vanguard's Roth and Traditional IRAs, four Chase accounts each foldered by year,
`PFL - Mother` beside `SDI - Mother`. **Identical sibling structure is usually a sign of health.**
What separates Acme is that the same documents sit in both, so this is a content claim — and item 18
has now shipped the evidence it needs. The `.sameText` pass groups both halves of the `Form 1095-C`
pair across `Work/Archive/Acme/Compensation/Forms/` and `Finance/US/Income Tax/2016/Forms/`, which
is exactly the overlap this detector was waiting for; what remains is reading those groups as a
statement about the two *folders* rather than about the two files.

**Status: the first detector has shipped, report-only.** `StructureDivergence` reads the profile
and reports families of siblings shaped differently at different times, under the two rules
validated below. On the real 3,013-folder tree it returns **one** family — `Finance/US/Income Tax`,
three eras — with every control quiet. What has *not* shipped is everything below this line: the
plan, the manifest and any operation that touches a file. A finding names the disagreement; it does
not offer to fix it.

**The bug that run caught, and no fixture could.** The live profile **propagates axes down the whole
subtree** — `Income Tax/2013/Federal Tax` carries `year: 2013` exactly as its ancestors do — so a
"does this folder carry an axis?" test dropped every role folder, emptied every vocabulary, and the
detector reported nothing at all across 3,013 folders while twelve synthetic tests stayed green.
The rule is whether a child *introduced* the value. Every fixture had put the axis only on the
folder that owns it, which is why none of them could see it.

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

**Why:** Six people file into this tree — Father, Mother, their children Daughter and Son, and
his parents Granny and Elder — and each files the same way: a folder named for them under
whatever the category is. The engine has known *that* people exist since the filing profile
shipped, but only as `personTokens`, a flat lowercased bag in which `Mom` and `Granny` were
unrelated strings. Three defects followed from that, and **phase 1 (below) has shipped**:

- The alias map (`Mom` → `Granny`) was read from `folder-profile.json` and **discarded at decode**,
  so the cross-person veto read `Mom - passport.pdf` against a folder whose axis says `Granny` as a
  *contradiction* and refused the correct folder.
- A token intersection reads **`Daughter Father`** — the daughter's full name — as naming her father
  too, because `father` is his given name and her surname. `elder` is worse: Dad's given name,
  Mom's surname, and Father's surname all at once.
- The veto read the **filename only**, so a scan named `Scan 2026-08-02.pdf` had no protection at
  all, and the refine pass — the one that reaches the cloud model — never applied the veto.

**What shipped (phase 1).** `PersonRegistry` holds a roster of `Person` records and matches
**phrase-first, longest wins, consuming the span**: in "Daughter Father" the surname is spent on
Daughter and never doubles as evidence for Father. Strong (unique) versus shared tokens are
**computed from the roster**, so adding a seventh person re-derives the split. The registry loads
from `profiles/<id>/people.json`, or is seeded from the profile's person axis when that file is
absent — the seed alone fixes the alias misfire. Both the veto and the router's person-axis score
now resolve through it, ending the two-tokenizer disagreement between `FilingEngine.nameTokens` and
`FilingRouter.tokenize`. The router treats a person match as confirmation (+1.0) and a
contradiction as a penalty (−3.0), which is what picks between sibling person buckets that hold
identical documents; Settings ▸ People shows the roster read-only, including which words are
shared with whom.

**What remains.**

- ~~**Editing in the app**~~ — **shipped.** Settings ▸ People adds, edits and removes
  people, with a live preview of what a draft would match; `PeopleStore` owns the write path and
  `people.json` is the one filing artifact the app writes.
- ~~**Learning from filing**~~ — **shipped.** *Look for names* reads the filenames already in each
  person's folders and offers any form they use that is not recorded, with its count and an example
  file; *Not a name* is remembered in `people.json` so a refusal never returns. Identifiers a
  person's folders have received now attribute a scan whose name and text name nobody — the last
  tier of `attribute`, and never above a name anybody wrote. A person the tree files for who is not
  on the roster is surfaced with an Add button, from the survey's own `axes.person` values.

  **The suggestion rule is narrow on purpose, and the measurement is why.** Recurring word runs in
  a person's folders are almost all noise (`Credit Report Mother`, 9 files); vetoing broad words —
  the rule proposer's fix — is *backwards* here, because a family surname is broad precisely because
  the family is everywhere (`elder` is carried by 161 folders) while `oci` is narrow. So a run is
  offered only when every word in it is already somebody's name and it leads with what the household
  calls *this* person. Measured on the real tree: **0 suggestions** with the roster complete, and
  "Granny Elder" (7 files) the moment her record lacks it. Discovering an entirely new word — a
  spouse's surname nobody has typed — still takes a person, and the section says so.
- ~~**`personIs(<person>)` as a rule condition**~~ — **shipped**, together with the `{person}`
  destination token that was the point of it: `Immigration/OCI/{person}` files each family member's
  card into their own folder, so the household needs one rule rather than seven. The condition
  keys on the person's id, so a rule survives a rename and picks up a name variant added later; the
  offer made after filing into a person's folder proposes both, and never keys a person rule on
  that person's own name. Rule persistence became tolerant of unknown conditions in the same
  change (see below).
- ~~**Find by person — the read-only view**~~ — **shipped.** ⌘F's field offers a person scope when
  the query names exactly one of them (`PersonSearchOffer`); ↩ takes it and the find becomes a
  *gather*, ⇧↩ keeps the plain substring search, and a query naming nobody leaves the find exactly
  as it was. The answer is grouped by evidence: **in her folders**, from the person axis walked up
  from each document (`PersonFiles.person(forPath:)` — nearest ancestor wins, so `OCI/Mother/Daughter`
  is Daughter's), and **hers, filed elsewhere**, the candidate misfilings no browse produces.

  **The corpus set the attribution rule.** Accepting any name match gave Dad **204** files elsewhere
  against 3 in his own folders, because `elder` is his given name, his wife's surname and both
  sons'; requiring a phrase or a token unique to him takes that to **10**, and Father — whose
  unique set is empty — from 290 to 111. That gate sits beside `attribute(fileName:pageSample:)`
  rather than inside it: the filing path checks a shared word against the destination's own person
  axis, so its veto has counter-evidence, and **browsing has none**. The offer rule is deliberately
  looser than the attribution rule — `elder` names one person, so typing your father's name must
  offer him even though it cannot claim a file on its own.
- ~~**The page-text channel and the review queue**~~ — **shipped.** The rows stage 1 suppressed now
  arrive as questions rather than vanishing: a shared word in the filename, or page 1 naming
  somebody when the filename names nobody. `person-tags.json` holds his answers beside
  `people.json`, keyed by the PDF text fingerprint where the document has one — so a verdict
  survives the rename and move Organize exists to perform — and by path otherwise. Confirming never
  moves a file. A rejection is the half that had to persist: the channels are deterministic, so
  without a remembered "no" the same weak match returns on every gather forever.

  **All four channels were replayed over the 1,375 person-filed corpus documents before the queue
  was trusted with anything** (`PersonChannelReplayTests`), scored against the folder's own person
  axis:

  | channel | claimed | correct | precision | contradicts the tree |
  |---|---|---|---|---|
  | her folders | 1,375 | — | 100% by construction | — |
  | named in file · strong | 157 | 155 | **98.7%** | 2 |
  | named in file · weak | 36 | 35 | **97.2%** | 1 |
  | named on page · strong | 254 | 239 | **94.1%** | 15 |
  | named on page · weak | 31 | 27 | **87.1%** | 4 |
  | page, precedence dropped | 324 | 302 | 93.2% | 22 |

  **The limit matters more than the numbers, and the suite says so where they are printed.** Ground
  truth exists only for documents a folder already claims — which are precisely the ones the queue
  never holds, because a claimed document is attributed by the folder channel and never reaches
  review. These are an *upper bound* on the queue's rows, not an estimate of them. What the replay
  can honestly assert is the ordering — filename beats page, strong beats weak — and that is what it
  asserts; the counts are printed, not pinned, because the tree is his live `~/Documents`.

  **The page channel's problem turned out to be volume, not precision.** Asked of every document
  whose filename names nobody, page 1 named *somebody* on **4,568** of them — 2,011 for one person
  alone, and every sampled row was a joint household document: a swim-class invoice names the parent
  who pays, a bank nomination form names the spouse who is the nominee. That is testimony, not
  ownership. Requiring the page to name **exactly one person** takes it to **635** and keeps the case
  the channel exists for — her disability claim, his bank KYC form, scans whose own names say
  nothing. So page evidence only ever *queues*; it never claims a document the way a filename can.
  Note what that gate is not: `maiden` is unique to Mother and passes the strength gate easily, and it
  was on all 2,011 rows. Strength asks whether a word could mean somebody else; this asks whether the
  document is about one person or a household.

  Across the household the queue is **870 rows** — 420, 350 and 95 for the three people whose names
  are shared, and one or two each for everyone else. The view lists twelve and states the remainder.

  **A hazard that measured zero, and was therefore not built for.** The corpus stores page-1 anchors
  **sorted and de-duplicated**, so word order is gone before anything reads them back: real phrases
  cannot match, and phrases could in principle be *invented* out of alphabetical adjacency. A barrier
  token between anchors was written to prevent that and then deleted — across 1,304 documents
  carrying text it prevented exactly **zero**, and an inert mechanism carrying a paragraph of
  justification is worse than the hazard it does not address. The replay pins the zero instead and
  names the barrier as the fix if a roster change ever moves it.

  `person-tags.json` is decoded **tag by tag**, because a synthesized decoder meeting one unknown
  case is how the `personIs` rules were once silently wiped; an unrecognized verdict is carried and
  written back verbatim rather than guessed at, and the shape is pinned against literal JSON.
- **Person buckets that do not exist yet** — a *create the sibling* proposal, from the parent's
  evidence, the way a cold year bucket is already handled.
- **A person block in the classifier brief**, so a backend reads "Mother I Maiden" as Mother too.

**Measured, and not where I expected.** Every filed document is a labelled example, so both rules
were replayed over the 1,375 corpus documents whose folder carries a person axis. The obvious
metric — *false vetoes*, refusing the folder a document actually lives in — is **unchanged at 3**,
and all three are `Family/Daughter/Events/Baby Shower/`: documents named for the parents inside the
child's event folder, which no name intelligence resolves because the folder is Daughter's for a
reason the filename cannot state. What the registry fixes is **over-attribution: 36 → 0**.
`Granny Elder - Resume.pdf` names one person and the token rule reported two, because `elder` is
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

## 23. One-way sync, iCloud → Dropbox (RD67) — in progress for v6.3

**What:** automatic one-way sync of chosen folders from a parent in iCloud Drive (on this Mac,
iCloud Drive ▸ Documents) to a parent in Dropbox. Folders with the same name directly inside both
parents are the synced folders. Adds, edits, renames, moves and deletions follow; renames and moves
are followed by the provider-kept document ID and become moves inside Dropbox; nothing in Dropbox
is deleted outright (it goes to `Dropbox ▸ SyncCloud Removed`). Changes made while the app was
closed apply at the next launch. This is item 1c's backup job with Mirror deletions, a file-change
trigger and folder pairs, and it departs from 1c's "never delete unattended" for this job only.

**Design and decisions:** the reviewed design page, with mockups, the decisions CV–DN, the
build notes and what was measured on this Mac, is
<https://claude.ai/code/artifact/7abb7c02-721e-45ad-894c-dfaf04788370>. It is the spec; this entry
tracks what is left.

**On `main`:** the engine core (`53e3e480d`: record, matching order, diff, removal limit), the
folder watcher (`ce6490cc2`, item 5's work), hashing of any size (`624799987`, `7508cfebf`) and
the cloud-app status RD67 stops on (RD68, `c7a3a7839` and follow-ups).

**v6.3 waits for step 3** (his call EC, 2026-10-30): the cut is held until a manual Sync Now is
on `main`. Steps 1–2 come first; step 4 follows its week of hand use, so it may land after the cut.

**Left, in order:**
1. The sync's own replace and SyncCloud Removed: stage outside Dropbox, clone the old version, keep
   the Dropbox item (in progress).
2. Saved state: the record on disk, History entries written before applying, saved Needs-you rows,
   one writing process and one writing Mac (in progress).
3. A manual **Sync Now**: setup, first-run preview, Review and Choose a Version, Reverse in iCloud.
   Used by hand for a week before the trigger ships.
4. The watcher as the trigger, then unattended removals.

**Not measured:** whether macOS reports a shared Dropbox folder as shared (decision DL asks at setup
instead), and what Dropbox does when a file is replaced while its newer server version has not
reached this Mac (expected: a conflicted copy, which then waits for you).

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

**Now:** every duplicate row wears a green *Identical* badge in the leading slot (`LensWorkspaceView`, the
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

### Make the Duplicates stat pills the filter

**Now:** `LensWorkspaceView` renders the header tally as `StatPill(...)` — *N groups*, *N redundant*,
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
| 6 | CLI parity for the lenses | Low–Medium | High |
| 7 | Cross-provider duplicates | High | High |
| 8 | Export / import configuration | Low | Medium |
| 9 | Auto-running automations | Medium | Medium–High |
| 12 | Menu bar status item | Low–Medium | Medium |
| 13 | Path-anchored / include-only rules | Low–Medium | Medium |
| 16 | Home workspace | Medium | Medium (after 1c) |
| 18 | PDF content fingerprint | Medium | High |
| 20 | Restructure — is the shape itself right | High | **High** |
| 22 | People — what remains is person buckets and the classifier brief (search, tags and rules shipped) | Medium, staged | **High** |

### Interface

Cited by name; this list has no stable numbering.

| Item | Effort | Impact |
|------|--------|--------|
| Fold Change + Copy-to into a Direction lane | Medium | **Highest** — ~500 pt back to Name |
| Drop the "Identical" badge from the majority row | Small | High — the exceptions become findable |
| Make the Duplicates stat pills the filter | Small | Medium–High — removes a duplicate control |
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
groups that the hash-based Duplicates scan silently misses, and one thirteen-year folder series filed four different
ways. **17 and 21 are together the cheapest route to a good free tier** — between the tree's own
conventions and what its folders already contain, most routes are decidable by arithmetic, so fewer
files ever reach the paid refine pass.

**The cheapest three have all shipped now** — "Find duplicates of this", the rules view, and the
⌘K palette. The palette is the one that paid back the flat bar's only regression: folding Rename
off the bar left a destination with nothing to aim at, and ⌘K reaches every place — including a
control that is not currently on screen. What is left below is the expensive work.

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

You reach for that file when the *code* surprises you — "why does this skip cloud-only files?" —
and this one when you are deciding what to build next. Different question, different file.

**The real problem was duplication, and it is fixed.** In-place folder Merge carried a full
specification in both files. It moved here, because it was planned feature work rather than an
accepted limit, and a spec kept in two places drifts in one of them — and it has since shipped, so
`DEFERRED_ENHANCEMENTS.md` #1 is now the only record left of it outside git. The
remaining cross-links are one-directional and correct: item 7 → Deferred #6 (hashing's three blind
spots), item 3 → Deferred #9 (the hash cache, now persisted and closed — item 3 links to it for the
record of how the index was built, not for outstanding work).

---

# v4 — the 4.x line

**Scope:** the 4.x line after v4.0 ships. **v4.2 is a navigation release.** The toolbar's ⌘K pill
stops being a button and becomes a field you type into (**§7**), and Browse borrows what Finder has
that it does not (**§3**) — tabs gave a pane somewhere to park, and this release is about reaching a
place at all. Beside those sit window chrome that says which window is which (**§8**), a batch of
small repairs to how already-shipped surfaces read (**§9**), and the menu bar, which stopped growing
at v4.0 and never took the surfaces shipped since (**§10**). What v4.1 took is recorded as **§1**
(Browse tabs, shipped 2026-08-14, one behaviour still designed and unbuilt) and **§2** (pane-bar
titles, shipped 2026-08-16). `main` only, with one stated exception: §2's code exists on `v2.x` too,
and that item says what follows from it.

**Organize has moved out.** Restructure went first, on 2026-08-16; the rest of the Organize surface
followed on 2026-08-20, when the v5 part was rescoped from one project to one **workspace**.
What went with it: Organize's menu-bar row (was §10's sixth item, now v5 §11), the two
`LensWorkspaceView` polish items (were §9's, now v5 §12), and CLI parity for the Organize lenses
(v5 §13). **This file keeps everything else** — Browse and its tabs, the pane bar, the Finder
borrowings, the ⌘K field, window chrome, and the menu-bar work that is not Organize's. The two lines
are **concurrent, not sequential**: an item lives in whichever one owns its surface.

**Restructure has moved out, on 2026-08-16.** The storage-layer gaps behind Organize ▸ Restructure,
the plan surface the lens was shipped without, and the first background survey now live in
**the v5 part** — moved unchanged, together with the four decisions taken on 2026-08-16 and the
open questions that belong to them. §§4–6 below are a tombstone pointing there and **their numbers
are not reused**, for the same reason figures are appended rather than renumbered: every "§4.2
shipped" and "§5.5 step 6" written in the companions, the commit log or a sibling file still
resolves to the section it names. New work here is numbered from **§7**.

It went to **v5.0 rather than v4.3, and the reason is size, not breakage.** This is a deliberate
departure from the reasoning it replaces: the decisions block argued "v4.2, not v5.0" on the grounds
that nothing in Restructure breaks, removes or restructures a shipped behaviour, which is the bar
`CLAUDE.md` sets for a major — and by that rule it would be v4.3. But Apply moves folders on disk,
and needs an on-disk inverse, a ledger, six invariants and a re-derived profile after every landing.
Shipping that as a point release would be the misleading label. Recorded here so the departure reads
as a decision rather than an oversight when someone checks the rule against the tag.

Distinct from the Backlog part (the standing feature backlog across all surfaces),
`DEFERRED_ENHANCEMENTS.md` (accepted limits) and `REFACTOR.md` (internal shape). An item graduates
out of this file the way it does out of the Backlog part: deleted when it ships, because git history is
the record. §9's items are the exception and are **cited, not restated** — their specifications live
in the Backlog part's Interface section and a spec kept in two places drifts in one of them.

§§1–3 were designed and mocked on **2026-08-12**. **§§7–9 were cut on 2026-08-16**, and every
constraint, line number and measurement in them was read out of the code that day, at
`c604321e` — including the ones inherited from older text, two of which turned out to have gone
stale (§3's drag risk, and "recents" in §7).

An **illustrated companion** carries the drawings this file can only describe:
<https://claude.ai/code/artifact/23cda3a3-a408-430a-90fd-c0291bd3a94f>. **This file is the one that
ships** — if it disagrees with the companion, the companion is the stale one. §7's own eight-plate
mockup set, measured 1:1 against the shipping constants, is at
<https://claude.ai/code/artifact/887a5f77-e406-44ee-944a-5acf5239cf2f>.

---

## v4.2 — the decisions

Four questions were answered on 2026-08-16 and they settle what §§3 and 7 may claim. Everything
below them is written under these; nothing in them is open.

| Question | Decision | What it changes |
|---|---|---|
| **What ⌘K does once the pill is a field** | **It focuses the field**, identically to clicking it. | One palette, one surface. The 620pt full-window card stops existing rather than living on beside the inline field. The alternative — chord opens the card, click opens the field — is two palettes. |
| **What the field shows before you type** | **Recents and places, as ⌘K behaves today.** | The list is down on open, which is most of the value. It also makes persisting recents release-gating rather than a nicety — see §3's correction: `recentsByRoot` does not survive a quit today, so the list would be empty on the first open after every launch. |
| **Whether it collapses on every dismissal** | **Yes.** Escape and click-away both collapse to the 135pt pill and clear the query. | The rule `ExpandingSearchField` already uses everywhere else, so a live query can never hide behind a collapsed control. |
| **The status bar's chord** | ~~**⌘/ , matching Finder** — `shortcutsReference` gives it up and keeps **no chord at all**.~~ **Overtaken 2026-09-07: the bar shipped (roadmap RD6) with NO chord, and ⌘/ stays with the reference.** The decision was never wrong — it was made when the bar was expected to be Finder's window-wide strip. It shipped Browse-only, which changes what the chord would buy: a global key for a switch that is live on one workspace and greyed on three. Weighed against taking ⌘/ off a reference that has since grown to three columns and is the thing a user reaches for *while learning the chords*, no chord won. | ⌘/ is still `shortcutsReference` (`AppChord.swift:81`). The two rejected replacements below stand rejected for their own reasons, which do not depend on this. |

**Why ⇧⌘/ was wrong, and what it costs to have believed it.** ⇧⌘/ **is ⌘?** — shift-slash is the
question mark — and `SyncCloudApp.swift:596` already binds ⌘? to **Help ▸ SyncCloud Help**, with a
raw `.keyboardShortcut("?", modifiers: .command)`. The reassignment would have taken the chord away
from Help and given the reference nothing.

The reason it was missed is worth keeping, because it will recur: **`AppChord` is not the whole
chord set.** It is the one place a chord is *written down*, and the Help item is the single
declaration that does not go through it — so a grep of `AppChord.swift` returns "⌘/ is the only
slash chord" and that answer is true and useless. The check that finds it is
`grep -rn 'keyboardShortcut("' MacApp Modules/*/Sources`, which returns exactly one line, and that
line is the exception. **Before moving any chord, scan raw `keyboardShortcut` literals as well as
the registry.** Worth considering separately whether Help should be pulled into `AppChord` so the
registry is once again the whole answer.

**Why ⌥⌘/ was wrong too, and why it is the worse mistake of the two.** The second answer was ⌥⌘/,
on the grounds that "no chord in the app uses ⌥ at all". That is true, and it is true *because ⌥ is
banned* — the reveal is a look-release-press ⌥-hold, so an ⌥-chord fires from inside it and aliases
whatever badge the user is reading. The first cut shipped exactly that: a user reading the
magnifier's "⌘F" badge who pressed ⌘F while still holding ⌥ sent ⌥⌘F and folded every folder
instead of finding anything. `AppChord.foldAllDifferences` records it, `AppChord.tabBar` gives
Reopen Closed Tab **no chord at all** rather than an ⌥ one, and
`AppChordTests.noChordContainsOptionSoNothingFiresThroughTheReveal` guards the invariant over the
whole registry — so implementing ⌥⌘/ would have turned a shipped green test red.

It is the worse mistake because ⌥⌘/ would have reproduced the ⌥⌘F bug on the *worst possible*
chord: under this decision ⌘/ eventually becomes the status bar, so the keystroke a user is most
likely to press while reading the reveal is the one that would have opened the shortcuts reference
instead. (The reassignment has not happened — the status bar is v4.3 — but the reasoning is what
makes ⌥⌘/ wrong whenever it does.)
**An empty search result is not evidence that a modifier is free — check whether something forbids
it.** Absence proves nothing on its own; ⌥ read as spare for precisely the reason it is spare.

The decision follows `tabBar`'s precedent: rather than take a forbidden chord, the command keeps
none. `ShortcutsWindowCommand` (`MacApp/ShortcutsReference.swift:114`) is already a Help-menu item
titled "Keyboard Shortcuts"; dropping `.keyboardShortcut` leaves the item where a person looking for
it would look. If a chord is wanted back later it needs a modifier scanned against the ⌥ ban and the
raw `keyboardShortcut` literals both, not just against `AppChord.registry`.

**It does not cost "the key equivalent and nothing else", as an earlier draft of this note claimed.**
Three places advertise ⌘/ today, and implementing this has to touch all three or it ships a
documented chord that does nothing:

- `MacApp/HelpBook.swift:288` — a **user-facing Help article**: *"Open the full reference from Help ▸
  Keyboard Shortcuts, or press ⌘/."* The clause after the comma becomes false and has to go.
- `MacApp/ShortcutsReference.swift:58` — the reference's own row,
  `Item(keys: "⌘ /", action: "Show this shortcuts reference")`. A shortcuts reference listing a
  chord it no longer answers to is the worst version of this defect.
- `SyncCloudTests/ShortcutsReferenceTests.swift:86` — `#expect(listed.contains("⌘/"), "splitting the
  keys lost the chord whose key IS a slash")`. That row **is** the fixture: the test exists because
  `/` is both a key and the separator between alternative chords (`⌘ Z / ⇧⌘ Z`), so it guards a real
  splitting regression. Retiring the row does not just edit a test — it removes the only slash-keyed
  entry in the table, so either another one has to take its place or the guard lapses silently.
  Deleting the assertion along with the row is the tempting move and the wrong one.

Count the cost of a chord removal in *documentation and fixtures*, not only in the declaration site.

**⌥⌘V in §3 contradicts this ban, and lands harder than the case the ban was written for.** This
same file still plans **⌘C / ⌘V / ⌥⌘V** as the pasteboard's cross-cloud move — the table row, the §3
body and the ordered plan all carry it. ⌥⌘V is an ⌥-chord, so it fires from inside the look-release-
press reveal exactly as ⌥⌘F did: a user reading the "⌘V" badge who presses ⌘V while still holding ⌥
sends ⌥⌘V. The shipped precedent cost a fold of every folder, which is annoying and reversible;
**⌥⌘V would move files across clouds**, which is neither. None of the three pasteboard rows carries
an ⌥ caveat today, and
`AppChordTests.noChordContainsOptionSoNothingFiresThroughTheReveal` would turn red the moment ⌥⌘V
entered `AppChord.registry` — so this is not a subtle tension, it is a plan that cannot be
implemented as written.

**Not resolved here, deliberately.** Picking the replacement is a product decision about how
paste-as-move should be spelled, and the lesson from ⌥⌘/ is precisely that a chord chosen by
"what looks free" is how this happens. What the ban already settles is the *shape* of the answer:
`tabBar`'s precedent is that a command may ship with **no chord at all** rather than a forbidden
one, so a menu item under Edit with no key equivalent is a legitimate outcome and not a failure to
decide. Whoever takes §3 should choose between that, a non-⌥ modifier scanned against both
`AppChord.registry` and the raw `keyboardShortcut` literals, and a single ⌘V that resolves
copy-versus-move from context — and should not treat the ⌥⌘V in the rows below as settled.

**One more that followed from those:** with the card gone, anything that only the card could reach
goes with it. ~~Before §7 lands, walk the palette's route table and confirm every entry still has a
door — this is the release's one silent-removal risk.~~ **Walked 2026-08-19, and it is clean**
(`PaletteRouteDoorTests`). Every route kind and all seven actions still have a door, the landing
still leads with all four groups, and two same-leaf folders stay distinguishable at the 620pt
ceiling *and* the 320pt floor — 1256 differing pixels at 620, 1783 at 320.

Two things the walk had to be rebuilt twice to be able to see, both worth keeping: a fixture of
`Clients/Legal` against `Archive/Legal` renders **identically at 620 and at 320**, because neither
width truncates a path that short, so it could not have detected a collapse at either; and one
pinned against one recent differs by the words "Pinned"/"Recent" rather than by the path, so it
passes even with the path gone entirely. The fixture that works is two **recents** sharing a long
head and a leaf and differing in the **middle** — which is exactly what a middle-truncated detail
elides first. Confirmed by mutation: stop drawing the detail line and both widths go to **zero**
differing pixels.

---

## Context every item here inherits

| Fact | Where | Consequence for this file |
|---|---|---|
| **One window, deliberately.** `Window`, not `WindowGroup` — two `ContentView`s would share one `FileSyncManager`. No File ▸ New Window, no ⌘N. | `MacApp/SyncCloudApp.swift:460` | Tabs are the *only* way to hold two places at once. No "Move Tab to New Window", no "Merge All Windows" — do not add menu items pointing at a window the app cannot open. |
| **Browse is one pane at full width.** `paneColumn(isLeft: true)` and nothing beside it. | `MacApp/ContentView+SplitLayout.swift` (`browseLayout`) | A tab is a *location for that pane*, not a second pane. |
| **Two browse paths exist in the whole app** — `leftBrowsePath` / `rightBrowsePath`, swapped wholesale by ⇄. Browse is the left one full width; the Organize rail is the left one narrow; Compare is both. | `Modules/Sync/Sources/Sync/FileSyncManager+Navigation.swift:461` | **Two tab lists, left and right.** Every cross-workspace question follows from this. |
| **The pane header height is pinned at 81pt** so its bottom edge shares the 83.5 rule with Organize's `LensHeaderCard`; cards inset by half of a 5pt gutter. | `Modules/Design/Sources/Design/LiquidGlassStyle.swift:392,410` | Nothing may add a row to the header. New pane chrome is a new card in the gutter rhythm. |
| **There is one `PaneHeader` call site**, and the pane bar's preferences are app-wide `@AppStorage` (`paneBarArrangement`, `paneBarIconSize`). Compare's two panes, Browse's one and the Organize/Storage rail are all that same header. | `MacApp/ContentView.swift` (`paneColumn`) | Anything added to the pane bar is identical in every workspace with no plumbing. But `availableItems` already varies it: **Collapse** only on the Organize/Storage rail, **Preview** only in Columns. |
| **The rail clamps at 220pt**, the workspace at 340. | `MacApp/ContentView+SplitLayout.swift:148` | Any pane-level bar needs a shedding ladder down to 220pt. |
| **⌘1–⌘4 are the workspaces; ⌘[ / ⌘] are pane back/forward; ⌃⇥ is `switchPaneFocus`.** | `Modules/Design/Sources/Design/AppChord.swift` | No ⌘-digit is available. ⌃⇥ is dead in Browse (one pane), so it can be scoped there. |
| **View-menu switches are `Toggle("<Noun>")` with a checkmark** — Hidden Files, Preview, Info Inspector, Differences List — and each is `.disabled` when its focused value is `nil`. Flipping titles are reserved for *actions* with two directions (`FoldAllDifferencesCommand`). | `MacApp/ShortcutCommands.swift:494–535` | New view switches are nouns with a tick. No "Show X" / "Hide X" pairs. |
| **Row drag was removed.** `.draggable` competed with the tap gesture that drives column navigation, and cross-pane drag never started. | `Modules/FileExplorer/Sources/FileExplorer/PaneColumnsView.swift:885` | Anything needing file drag reopens that competition. Schedule it separately, with a proof that a click still opens a column. |

---

## 1. Browse tabs — **shipped**, bar one behaviour

Built on 2026-08-14 and landed on `main`. The design that was here — the 34pt strip above the pane
header, its three width rungs, the anatomy, the chords, the cross-workspace table, persistence, and
the reasoning behind each — is **deleted rather than archived**, per this file's own rule: git
history is the record, and a plan kept beside the thing it planned drifts from it. Read the code and
its tests instead; `MacApp/ContentView+PaneTabs.swift` carries the host-side reasoning and
`Modules/Sync/Sources/Sync/PaneTabs.swift` the model's.

What shipped beyond the original design, both from using it: **pinned tabs** (a pinned run is always
a prefix — drag cannot cross the pin line, Close Other Tabs keeps them, a reopened tab comes back
unpinned), and **Compare's two panes act as one** — either pane holding a second tab draws the strip
on both, and the 🔗 link mirrors an opened tab onto the sibling, pruned to the deepest folder the two
still share.

The accepted limits it landed with are recorded as **items 14–16 of `DEFERRED_ENHANCEMENTS.md`**,
which is where limits live rather than here. Dropping files on a tab was never in scope and is
already ranked in §3. The one piece of *design* left open here was deleted on 2026-09-07 under the
fourth-carry rule; what follows is the record of that, not a design.

### Mirroring tab *switches* on linked panes — **deleted 2026-09-07, never built** (roadmap RD8)

The design that stood here is gone, and the deletion is the record. It described giving mirrored
tabs a shared id so that switching a tab on one linked Compare pane switched its pair on the other;
today opening a tab mirrors, switching does not, so two panes that grew their tabs together diverge
at the first ⇧⌘].

**It was designed twice and carried three times without being built** — most recently on 2026-08-20,
deliberately and against this file's own recommendation to delete it. That carry set the test
itself: *"If it is carried a fourth time, delete it instead — the argument for keeping it was that
the problem is real in use, and a fourth carry would be evidence against that."* v4.3 came and went
without it. This is the fourth, so the rule is applied rather than re-argued.

Nothing shipped depended on it: `mirrorOpenInNewTab` is untouched and still mirrors an *opened* tab,
which is the half that was built and is in use. Two questions were what kept it open — what a switch
does when its paired tab's folder has gone, and what happens once a paired tab is closed — and they
are recorded here only so that anyone who re-proposes this knows the design was not abandoned for
want of thinking about it. **Do not restore this from history; if the unmirrored switch ever becomes
a real nuisance in use, that evidence is the reason to design it again, and it should be designed
against the app as it then stands.**

---

## 2. Pane bar: Icon and Text — **shipped**

Built on 2026-08-16 and landed on `main` for v4.1. The design that was here — the three modes, the
width table, the Text Only analysis, the prep list — is **deleted rather than archived**, per this
file's own rule and §1's precedent: git history is the record, and a plan kept beside the thing it
planned drifts from it. Read `PaneBarLabelMode` and `PaneBarTitleMetrics` in
`Modules/Dashboard/Sources/Dashboard/PaneBarArrangement.swift`, and `PaneBarTitleTests` for the
decisions each in one named test.

What shipped differs from what was planned in four ways, and these are kept because the *reasons*
do not live in the code:

- **Two modes, not Finder's three.** Text Only is dropped. With the glyph gone the word becomes the
  only carrier of state, which forces Hidden Files' title to swap with its eye and makes an item's
  width change on click. It also took `maxDepth` staying mode-blind with it. Additive if wanted.
- **§2's two headline numbers were both wrong, and could not both be right.** "20pt pill + 2pt +
  12pt title = 34pt" holds only at a **10pt** title (line height 12.0); "453 → 537pt" holds only at
  a **12pt** one, which makes the row 37pt and breaks the pinned 81pt header. And 453pt priced the
  *stored* 11-item arrangement — `onCollapse` is passed only on the single-source rail outside
  Browse, so Browse and both Compare panes draw **10** items. The bar that actually wears titles
  goes **414 → 451pt**, inside a 640pt Compare pane's ~508pt track with room to spare.
- **The View switch keeps its ground; its *vertical* padding is what went.** §2 said the ground
  should go when titled, and the reason turned out to be height rather than style: 3pt top and
  bottom made the switch 26pt against every other control's 20, so a title under it sat 6pt low and
  took the row to 40pt. Finder's toolbar equalises rather than removes — its segmented controls are
  not taller than its plain ones. Applied in **both** modes, because the switch out-topping its
  neighbours predates titles.
- **A text-size gate, which §2 did not anticipate at all.** A 10pt title sits below `FontSize.knee`,
  so it takes the *full* multiplier while `PaneNavMetrics.pill` is a fixed constant that does not
  scale: at Large the row wants 37pt and at Larger 38pt. Titles are therefore drawn at **Default and
  Small only**, and those two sizes fall back to Icon Only. Clamping the title was rejected — it
  would give the person who chose Larger the one label in the app that refuses to grow.

  **This paragraph was wrong when it was written, and is left standing as the record of it.** The
  gate's budget was 34pt — the retired provider capsule's height, not the header's own room — so the
  cliff was never at Large. It was at **110%**, the first step above the default, and by the time
  the font size became a 90–135 slider that was six of the ten sizes it reaches. Fixed on `main` on
  2026-08-29 by calibrating the budget against drawn ink: words through 115%, Icon Only from 120%.
  See `PaneBarTitleMetrics.rowBudget`.

The rule underneath the titles is worth keeping: **a title changes when the ACTION changes, not when
the STATE changes.** Scan → Stop swaps because the rung performs a different act; Hidden Files does
not, because its eye already carries the state and a word that changed with it would move every item
to its left on each click.

Its mockups, measured at true point size against the shipped constants, are at
<https://claude.ai/code/artifact/ff227e61-042f-49f2-92fc-ff359780fbd6>.

---

## 3. Finder borrowings

Promoted out of the appendix on 2026-08-16: this is half of v4.2's body, not a ranked list waiting
for a release to want it. Ordered by value against what Browse already has, and every "where it
stands" below was re-read at `c604321e` rather than carried forward.

| Item | Cost | State on `main` |
|---|---|---|
| ~~**Status bar** (⌘/) — item count, selection size, cloud-only count, scan freshness~~ | small | **Shipped 2026-09-07 as roadmap RD6**, Browse-only and with no chord. All four facts, shedding from the right. The placement question is answered below. |
| **↩ renames** | — | **Shipped 2026-08-20** (`88d95ed9`) — a pane key handler beside Space, sharing File ▸ Rename's own closure so the two cannot drift. Never a menu equivalent: a bare ↩ there would take the key that commits the destination picker, the ⌘K field and every sheet. |
| **⌘↑ enclosing folder, ⌘↓ open** | small | **Deferred to v4.3, 2026-08-20 — the chords are free, the meaning is not.** A pane has TWO positions and the two candidates move different ones: `handleFocus` (what the row menu calls "Open") **re-scopes the pane**, while `drill`/`popLast` walk the **column stack** the breadcrumb shows. Pairing them across axes — Open re-scoping while Up pops a column — makes two chords that look like opposites move different things, which is the confusion this codebase already has a history of. Columns is the default mode, so a stack-based pair works where most people are and is dead in Tree; a scope-based pair works in both and resets the breadcrumb rather than walking it. **Decide the axis first; the implementation is small either way.** |
| **Go to Folder** | small | **Shipped 2026-08-19** — `PalettePath`, no sheet. Cross-source paths refuse and name the source; switching to it is deferred to v4.3, see below. |
| **Pins + recents sidebar** | medium | **Built 2026-08-20 and held for v4.3 the same day** — `Dashboard/FolderSidebar.swift` ships inert (`FolderSidebarModel.isEnabled == false`); the chord, the menu item and the ⌘/ row are deleted, so v4.2 has no sidebar by any route. See below, and v4.3's item 6. |
| **⌘C / ⌘V / ⌥⌘V** ⚠️ | medium | No file pasteboard. All eight `NSPasteboard` sites copy a path *as text*. **⌥⌘V is barred by the ⌥ ban above — spelling unresolved.** |
| **Gallery view mode** | large | `PaneViewMode` has two cases; a third is free, thumbnails are the job. |
| **Group by kind / date** | large | Sort is per-pane `KeyPathComparator`; grouping does not exist. |
| **Drop files on a tab** | large | Needs row drag re-added. **The recorded reason for ranking it last is stale** — see below. |
| **Tags / coloured labels** | — | **Cut 2026-08-19.** Ranked *skip* on merit, scheduled anyway, and the objection was never answered. See below. |

### Two claims here had gone stale, and both change what an item costs

**The drag risk.** This list used to rank *drop files on a tab* last because it "reopens the
`.draggable` vs tap-gesture competition". `PaneColumnsView.swift:908` now records the opposite: the
competition was long blamed for the selection drift, drag was removed on that theory, **and the
drift remained**. `TapGesture`'s own strictness is the whole cause, and both the tap and the
mouse-down source commit by construction now. Re-adding drag therefore does not reopen a known bug
— it re-enters untested ground against a selection path that has since been rebuilt. Still the
largest item here, for a smaller and different reason than the one on record.

**"Recents" do not survive a quit.** `FolderJumpStore` persists **pins** — `pinnedByRoot`, under the
`folderJumpPinnedByRoot` default — but `recentsByRoot` is session-only, in memory, by design. That
collides with the decision above: a field that opens showing "the four folders you were last in"
shows **nothing at all on the first open after every launch**, which is exactly when it is most
useful. Persisting recents is a small addition to a store that already encodes and decodes pins, and
it is **a prerequisite for §7, not a follow-up**. It needs a length cap, an order, and an answer for
a folder that has since gone — the same three questions the tab strip already had to answer.

### The four small ones

- **A status bar — shipped 2026-09-07 as roadmap RD6, Browse-only and with no chord.** Item count,
  selection size, cloud-only count, scan freshness. Browse shows none of this: the selection summary lives in the Compare-only
  floating action bar, so browsing a single tree tells you nothing about what you have selected.
  Two inherited constraints — the View-menu entry is a `Toggle` with a noun and a tick, never a
  Show/Hide pair (`ShortcutCommands.swift:494–535`), and it sheds cleanly down to the 220pt rail
  clamp.

  **What it was deferred ON is placement, and Finder's answer does not transfer.** Finder has one
  window and one tree; Compare has two trees, and the window's bottom edge already belongs to the
  Differences list. Three shapes, each with a real cost:

  | Shape | What it buys | What it costs |
  |---|---|---|
  | **One strip per pane**, at each pane's bottom | never has to name which pane it means — it sits inside the one it describes, as the pane headers already do | vertical room in every pane, and a shedding rule per pane rather than per window |
  | **One window-wide strip** | Finder's literal shape, cheapest in pixels | in Compare it must name the pane it is describing, and it lands on the edge the Differences list owns |
  | **One strip following focus** | one row, no naming problem | the numbers change under you when focus moves, which is the one thing a status bar should not do |

  **Settled together with §8's one-line pane headers, as this said to** — and the answer is a fourth
  shape none of the three rows names: **the bar exists on Browse and nowhere else.** The one-line
  headers reached the finding that decides it. Each pane's header already carries that pane's own
  facts, so in Compare a shared strip is not choosing between three costs — it is choosing which
  pane to repeat and which to be silent about. Browse has one pane, so the question does not arise
  there, and a bar that appears where it can be honest beats a bar that appears everywhere and
  hedges on two thirds of the surfaces. It is built in `browseLayout` rather than in `paneColumn`
  (the one pane builder Browse, both Compare panes and the lens rail all share), which is what makes
  the scope structural rather than a flag someone can flip by accident.

  **A Compare bar is not ruled out; it is a different design.** It would be per pane, inside each
  column, and would have to argue with the one-line headers about the same vertical room all over
  again. Nothing shipped here decides it.

  **The measured note about the cloud-only count held exactly, and the answer was to pay it in the
  background.** `MaterializationStatus.isCloudOnly(atPath:)` answers one path at a time and
  `CloudOnlyBadgeCache` is a cache of what has been *drawn*, not a total, so a count over a
  ~40,000-node tree is a walk. `CloudOnlyCensus` runs that walk off the main actor after the rows
  are on screen, cancels and restarts on the pane's publish stamp, and the segment reads `—` until
  it lands rather than a number climbing towards the answer. It writes nothing into the badge memo:
  a bulk writer landing 40,000 entries would trip that cache's 8,192 capacity wipe and throw away
  the answers the visible rows are serving from.

  **One thing this entry did not anticipate: `lastScanDate` was the wrong clock.** It is the
  *comparison* scan's, so on Browse — which runs no comparison — it is either nil or a fact about
  two folders the user is not looking at. The bar reads a new per-pane stamp (`leftTreeReadAt`) set
  by the walk that produced the rows, and carried on the prefetch cache entry so a served tree keeps
  the age of the walk that built it rather than claiming to have been read at the moment it was
  handed over.
- **↩ renames.** The one chord people try first in any file list, and today it does nothing.
- **⌘↑ / ⌘↓ — deferred to v4.3, 2026-08-20.** Back and forward exist as ⌘[ / ⌘], and the
  breadcrumb is clickable, but "up one level" has no key — and back is not the same gesture: it
  retraces where you have been rather than climbing where you are. **What defers it is which of the
  pane's two positions the pair moves** — the table entry above carries the choice.
- **Go to Folder.** ~~Finder's ⇧⌘G as a behaviour rather than a surface: §7's field accepts a typed
  path, `~/` and `/` included, resolved against the pane's provider roots.~~ **Shipped 2026-08-19**
  (`PalettePath`). A query starting `/` or `~` resolves to one row: the folder, or a refusal saying
  which of three things went wrong — outside every source, in a source that is not mounted, or
  nothing there. (There were four; the fourth is the deferral below, and it shipped.) **The
  refusals are most of the feature**, because
  a path query used to match nothing at all and an empty list is the "nothing happened" this family
  of features exists to remove. A **file** path goes to its enclosing folder, the way ⇧⌘G accepts
  one — that is what a Finder copy puts on the clipboard.

  **The order of those checks is a stall guard rather than a style.** The existence check is a
  `stat` on the keystroke path, and a `stat` under an unreachable mount blocks — the hazard
  `FolderJumpStore.reachable` is arranged around — so everything answerable from the index is asked
  first and a path outside every source, or inside a sleeping one, is refused without the disk being
  touched.

  ~~**The one half deferred, and it is the interesting one: a path inside a source the pane is not
  currently showing.** It refuses and names the source ("In Dropbox — switch source first") rather
  than switching.~~ **Shipped 2026-09-06 as RD7.** The row is a destination now: it reads "Open in
  Dropbox", and ↩ points the aimed pane at that source and lands it on the typed folder.

  **The prediction held exactly — the reload ordering was the whole of the work**, and the
  mechanism named here is the one that was used. `onChange(of: leftProviderId)` fires on the *next*
  view update and re-homes the pane, so `adoptProviderForTab` arms `pendingTabProviderChanges`, the
  handler consumes it instead of resetting, and `refreshForTabSwitch` drives one reload of the moved
  pane. Three statements in one order — `focusOn`, then the armed provider write, then the reload —
  in `ContentView.switchSourceAndReveal`; the route is its own case, `PaletteRoute.folderInSource`,
  so the host's exhaustive `switch` had to name it. Both helpers stopped being `private` for that
  one caller, which is the whole of the change to the tabs file.

  **Two things it deliberately did not do.** The disk is still not asked on the keystroke path — a
  cross-source path is offered without knowing whether the folder is there, because probing a source
  the pane is not showing has no `foldersUnavailable` in front of it; the existence question moves
  to ↩, and "nothing at that path" refuses there with a log rather than switching the source and
  landing somewhere else. And the link toggle does not apply: only the aimed pane moves, because the
  sibling is on another source and a path relativized against this one's root means nothing there.

  **The other three refusals stay refusals**, each for a reason this one did not have: "Not in any
  source" is a fact about the configuration rather than a navigation, an unmounted source cannot be
  switched to at all, and "No folder at that path" is a claim about existence inside the aimed
  source.

  **Reviewed twice, 2026-08-19/20.** Deliverability was being decided against the owning provider's
  `isCurrent` flag while the reveal relativizes against `providerRoot` — two values that disagree
  whenever **sources nest**, which is ordinary: with `~/Documents` and `~/Documents/Clients` both
  configured and the pane aimed at the outer one, `PalettePath.owner` answers with the inner (it has
  to, or a deep path goes to the wrong source), so a folder the pane on screen can show perfectly
  well was refused with "In Clients — switch source first". Two sources pointed at the same folder
  do it too. It now asks the one value the route is applied with.

  *(The first write-up of that fix blamed the `enabledProviders` / `availableProviders` split —
  disable the source a pane is showing and it leaves the list while the pane keeps it. **That is not
  reachable**: `onChange(of: settings.enabledProviders)` re-points any pane whose provider was
  switched off. It survives only where `enabledProviders` goes empty, which `canDisable` refuses to
  do but a source disappearing afterwards can still produce. The fix was right and the reason was
  wrong; both are recorded because the wrong one reads plausibly.)* And the disk was asked **twice per keystroke and twice per arrow key** — `rows` is read once
  by `setQuery` and once by the SwiftUI body, so moving the highlight re-ran the probe against a
  query nobody had touched; a one-entry memo on the state takes that to one and none.

  Also visible now that paths resolve: **a query containing a slash matches no folder by name.**
  `rankedFolders` normalises the slashes in the *candidate* (`Clients/Legal` → `Clients Legal`) and
  not in the query, so `~/Documents/Clients/Legal` works and `Clients/Legal` finds nothing. Left
  alone deliberately — normalising the query changes how every folder query ranks, which is not this
  item's to decide — and recorded on
  `PalettePathTests.aRelativeNameIsNotAPathAndTheDiskIsNotAskedAboutIt`.

### The two mediums

- **Pins and recents, as a sidebar.** **Built 2026-08-20 — and held for v4.3 the same day, with
  him.** Browse only, 180pt, leading; click to switch (`focusOn`, so it re-scopes the pane rather
  than walking the column stack the breadcrumb shows), ⌘-click for a new tab, right-click to pin or
  unpin. Folders only, as required — no provider row.

  **What was built is two ungrouped lists; what "sidebar" promises on this platform is a place.**
  Finder's has named sections you can collapse and reorder, folders you drag *in* to make permanent,
  and rows you can drop a file onto to file it without going there. Shipping the first as the answer
  to the second spends the word "Sidebar" and ⌃⌘S on it — and a v4.3 that then reorganised the
  column would be changing what a chord means one release after teaching it. So it goes out whole in
  v4.3 or not at all; v4.2 ships it **unreachable**, not merely unticked.

  **The hold is one constant and four deletions**, all named at `FolderSidebarModel.isEnabled`:
  `appliesTo` answers `false` (so the column, the row refresh and the menu binding go together), and
  `AppChord.folderSidebar`, `ToggleFolderSidebarCommand`, its `View`-menu line and the ⌃⌘S row in
  `ShortcutsReference` are removed rather than disabled — a greyed item is still an item, and a
  registry chord still earns a ⌘/ row. `browseSidebarVisible` is deliberately left alone, so someone
  who ticked the item while it existed keeps their answer for when v4.3 asks again. The absence is
  asserted where each surface lives: `TheSidebarIsHeldForV43` (the rule),
  `WindowMenuTests.theSidebarSwitchIsGoneFromEveryMenu` (the running app's menu bar, both the title
  and the key equivalent) and `TheSidebarHasNoChordAndNoRow` (the registry and the ⌘/ panel).

  Three things the build added to the design, and they are v4.3's starting point rather than
  history — the code they describe is still there and still correct:

  - **Browse only, gated on the workspace and not on `layoutMode`.** The lens workspaces are
    single-source too, and their pane is the 220pt-clamped rail — no room for a 180pt column beside
    it. The menu item was `nil`-disabled everywhere else, like every other view switch — that item
    is now deleted with the rest of the surface, and the workspace gate is what v4.3 re-attaches to.
  - **A colliding leaf name is qualified, and a top-level one by the provider.** Two `Legal` folders
    is the case the ⌘K palette had to be rebuilt twice to see. **Found by rendering it**: the first
    cut qualified `Clients/Legal` and left a root-level `Legal` bare, because a top-level folder's
    parent path is the empty string — two rows reading "Legal" where only one says which.
  - **The rows are resolved, not recomputed in `body`.** `FolderJumpStore.reachable` `stat`s the
    root, and that is the call that blocks for seconds under a network mount that has gone. Once per
    ⌘K open is survivable; once per render of the workspace is not. Refreshed at the four moments
    the answer changes: appearing, the provider changing, the pane moving, and the store publishing.

  **⌃⌘S was the fourth chord to overflow the shortcuts reference**, and the first time a *single*
  row did it — `theReferenceFitsItsWindowWithoutScrolling` measured 743pt against a 720pt window.
  Raised to 780, then **brought back down to 740 when the row left again**: the panel measures 707pt
  without it, so 740 leaves 33pt, comparable to the 34 and 37 the last two raises left. That is the first time
  this window has ever gone *down*, and it is the same rule in the other direction — the number is
  what the rows measure, not a high-water mark. v4.3 will trip it again; the measurement above is
  what it will cost.
- **⌘C / ⌘V / ⌥⌘V.** **Shipped 2026-08-20**, minus the third chord — see below.
  `Dashboard/SystemClipboard.swift`. ⌘C in a pane now also writes file URLs to
  `NSPasteboard.general`, so ⌘V in Finder pastes the files; files copied in any other app paste into
  a pane. Four things the build settled:

  - **`NSFilePromiseProvider` is not involved, and §10's costing of it as "the Medium" was wrong.**
    A promise provider exists for content that does not exist yet. Every node in a pane is a real
    file at a real path, an online-only placeholder included — that is a dataless file the system
    materialises on read. Writing the URLs is sufficient and is what every other file browser does.
  - **One clipboard, decided by `changeCount`.** Two clipboards would be two behaviours. While the
    count recorded at the app's own ⌘C still matches the live one, the internal list wins — it is
    the only one carrying `isCut`, so it is the only path that can move. The moment anything else
    writes, the pasteboard is the answer.
  - **A pasteboard holding non-files pastes nothing**, rather than falling back to the app's stale
    list. Copying text elsewhere and then pressing ⌘V here must not write files nobody asked for.
    And a paste *from* another app is always a copy: the pasteboard carries no cut flag.
  - **The handler takes a pasteboard now**, injected like its `defaults`. An existing test caught
    why on the first run: with `.general` in play, `testPasteClipboardToNodeWithEmptyClipboardDoes
    Nothing` pasted the preceding test's file into its temp directory — the suite had begun
    clobbering the developer's real clipboard.

  **Paste-as-move still has no chord, and that is the `tabBar` outcome rather than an omission.**
  ⌥⌘V cannot ship (below), and ⌘X-then-⌘V already means move for the app's own clipboard, so the
  verb exists and only a second spelling of it is missing. Left for whoever wants it to choose a
  non-⌥ modifier scanned against both `AppChord.registry` and the raw `keyboardShortcut` literals.

  ⚠️ **The ⌥⌘V spelling is not available** — see the ⌥ ban above: an ⌥-chord
  fires from inside the keycap reveal, so a user reading the "⌘V" badge who presses ⌘V while still
  holding ⌥ would move files. The paste-as-move verb needs a different spelling (or none, following
  `tabBar`); everything else in this item stands.
  There is no file pasteboard in the app; every existing use copies a path as
  text. What earns writing one: with tabs, **this is the cross-cloud move** — copy in an iCloud tab,
  paste in a Dropbox one. It is the app's whole subject expressed in two chords people already know,
  and the only item in this release that adds a way to move data rather than a way to look at it. It
  therefore inherits the write-path guards the transfer code already carries, undo included, rather
  than inventing its own.

### The four large ones

In scope by decision, ranked last on merit. The Order below marks where to cut if the release runs
long.

- **Gallery view.** A third `PaneViewMode` case — the enum, the picker and the persistence all take
  it for nothing. Thumbnails are the entire job: generation, a cache that survives a quit, eviction,
  and a placeholder that does not flash. Argue it from the scans folders, the only trees here where
  a filename genuinely fails to identify the file.
- **Group by kind or date.** Sorting exists; grouping is a different shape — sections with headers,
  counts, collapse state, and a sort *within* each group. It touches every row-rendering path in the
  pane, which is why it is large despite sounding adjacent to something that works.
- **Drop files on a tab.** After ⌘C/⌘V, which establishes the move semantics this expresses as a
  gesture. Ships with the proof the removal was originally made to satisfy: that a click still opens
  a column.
- **Tags and coloured labels — CUT, 2026-08-19.** The standing argument: Organize's rules and the
  person registry already answer "what is this file about", and a parallel labelling system competes
  with them — two places to say the same thing, drifting apart. It stood unanswered through two
  roadmaps and was scheduled anyway; asked directly, the answer was to cut it.

  **The only version worth building was one this decision also declined.** Tags are for what the
  machinery *cannot* infer — a human judgement with no rule behind it — so they had to be visible to
  rules as a ninth `AutomationCondition` beside `folderNamed`, `kindIs`, `largerThanMB`,
  `untouchedForDays`, `contentContains`, `mentionsAll` and `personIs`: an **input** to the filing
  machinery rather than a rival to it. Without that integration this is a second filing system.

  **Cutting costs nothing today** — no tag code exists — and it removes a cost that would otherwise
  be paid after shipping, every time the two systems disagreed about the same file. Do not re-add
  this from the ranked table above without answering the objection first; being on a list is how it
  got scheduled the first time.

---

## 4, 5 and 6 — moved

**Moved to the v5 part on 2026-08-16, unchanged.** §4 *Restructure: a cached answer, and no way
to run one*; §5 *Restructure: propose the fix, not just the finding*; §6 *The first survey, run in
the background*. Their figures (21–34), the four decisions taken on 2026-08-16 and the open
questions belonging to them went across too.

**These numbers are not reused** — new work below starts at §7. The reason is the same one that
makes figures append-only: "§4.2 shipped" and "§5.5 step 6" are written in both companions, in
commit messages and in the audit notes, and renumbering would silently repoint every one of them.
Nothing in this file depends on any of the moved sections.

---

## 7. Go to, expanded in place — the ⌘K field — **shipped**

**Status, 2026-08-19.** All four of this section's items have shipped. Three landed between
`c77d96d3` and `ee46628f`; **Go to Folder closed it** — a typed `/…` or `~/…` resolves through the
existing `.folder` route (no new case: a typed path and a picked folder mean the same thing and
differ only in where the string came from), scored above every fuzzy tier because a typed path is a
statement of intent rather than a guess at one. A path it cannot deliver is **kept and marked with
the reason** rather than dropped, which is the same rule the unmounted-source and asleep-root rows
follow; §3's item carries the four reasons and the one half deferred to v4.3. The same commit renamed the menu item and the ⌘/ row to **Go
to**, which is what the control had been calling itself since the field shipped. The 620pt card is gone: `CommandPaletteView` was deleted
in `7e8fff03`, and the live list it also contained now lives in `PaletteResultsList.swift`. Read the
rest of this section as the record of a design that landed, not as a plan.

**Two things the build settled differently from the text below.** The field's real ceiling is
**340pt in a 960pt window** with the workspace bar's labels up, not the 440 this section assumed —
which is why the field's width and the bar's rung are now one decision against one reserve
(`WorkspaceBarMetrics`). And **⌘K on an already-open field selects the query rather than closing it**;
esc is the close.

**Why (as written before it shipped):** ⌘K is a button that opens a 620pt card over a dimmed window.
The card is a place you go to in order to go somewhere, and it hides the tree you are navigating
while you type the name of another folder in it. The pill in the title bar is already the control you
click; it should be the control you type into.

### Context

| Fact | Where | Consequence |
|---|---|---|
| **The card's real numbers**: 620pt wide, list capped at 420pt, field set at 19pt. | `CommandPaletteView.swift:47`, `:48`, `:148` — *file deleted in `7e8fff03`; cited as it read when the decision was taken* | The list cap survives unchanged; 620 becomes the *ceiling* of a clamp, not a fixed width; 19 cannot live in a 32pt-tall toolbar row. |
| **The pill's width is already measured through `NSFont` and already charged into the toolbar's reserve**, with a deliberate 14pt `labelSafetyMargin`. | `CommandPaletteBar.swift` | The ladder this needs exists and is already fed by measurement rather than a table. The expanded width joins the same reserve. |
| **A toolbar that does not fit does not truncate** — macOS folds the overflow behind a chevron. | same, and `WorkspaceBarMetrics` | Under-measuring has no symptom until the whole toolbar is behind a chevron. This is why the reserve arithmetic ships in the same commit as the field, never after it. |
| **The palette became an `NSPanel` because as an in-window overlay its keystrokes fell through** to the tables in the panes — characters landed in the pane's find field. | `CommandPalettePanel.swift` | That argument covers the *list*, which floats over the columns. It does not cover the *field*: the toolbar is AppKit's own strip, above the content. |
| **⌘K is `commandPalette`; ⌘F is `findInPane`.** | `AppChord.swift:61`, `:70` | Two different searches, and the split stays: ⌘K routes to a place, ⌘F searches inside one. |

### The shape

- **The pill becomes a `TextField`** in the existing `.primaryAction` toolbar item.
  `clamp(320, spare, 620)` wide, 13.5pt text, **trailing edge pinned** so nothing else in the row
  moves, 120ms to open. It grows leftward into the flexible spacer the toolbar already holds open.
  The ⌘K keycap becomes `esc`, then a clear glyph once there is a query.
- **The list hangs off the field's bottom edge** at the same width, aligned to it, square top
  corners and a rounded foot so the two read as one object. It keeps the 420pt cap and the existing
  grouping.
- **No scrim.** The window stays readable while you type — the whole point of not being a card.
- **The list stays a panel, and its polarity inverts.** Today the panel takes key; under this shape
  it must **refuse** key, or the toolbar field loses the caret mid-word. A transparent full-window
  panel behind it hit-tests for click-away and paints nothing — the same mechanism as today's scrim,
  minus the dim. Without it, a click meant to dismiss selects a file instead.
- **Go to Folder rides the same field** (§3): a typed path resolves against the pane's provider
  roots. **Shipped 2026-08-19** — and "roots" plural turned out to be the deferred half: a path
  under a source the pane is not showing is named rather than switched to.
- **The narrow case is not free — but it never reaches the floor.** Built and measured
  2026-08-18: at the 760pt window minimum the field opens at **359pt**, above its own 320pt floor,
  and at *every* text size, because the icon-only bar's width is glyphs and padding and does not
  scale with type. So the branch that opens the field under its floor is defensive rather than
  reachable, and **the floor's real job is deciding when the labels shed**, not clamping the field.
  What the narrow end actually costs is the invitation: the full placeholder needs ~390pt of field
  at the default text size, so the short rung is what absorbs the difference.
  `testTheNarrowestWindowStillClearsTheFieldsFloor` pins it, and starts failing the moment a fifth
  workspace lands, `reservedChrome` grows, or the window's minimum is lowered.

### The spikes, run 2026-08-18 — two answers, one correction, and one settled in the app itself

Run as a self-driving AppKit probe (`NSHostingController` window, `ToolbarSpacer(.flexible)`, a
`.primaryAction` item whose width is animated) on macOS 26.6.2. **Its toolbar is an approximation of
this app's** — four workspace segments without the rule, one or three utility buttons — so the
numbers below are the *shape* of the answer and not this app's constants. Re-measure in SyncCloud
before pinning any of them in a test.

**1. Yes, a toolbar item animates its width, and smoothly.** 135 → 440pt gave 61 intermediate frames
over a 500ms ease-out and 15 over a 120ms one, sampled at 8ms off the item's own backing `NSView`.
Nothing about macOS 26's grouped toolbar clamps or steps it.

**2. Yes, a non-key panel keeps the caret in the field and draws its selection normally.** With the
panel hung under the field: host stays key, panel reports `isKey=false`, first responder stays the
field editor, and synthesized keystrokes still land in the field (`"tax"` → `"taxes"` typed *with the
panel up*). The selection fill renders identically key and non-key — equal blue-pixel counts off
`cacheDisplay` — because the highlight is our own `fill(accent)` and not an AppKit emphasized
selection. **The polarity inversion in the shape above is sound.**

**3. The correction, and it is the one that moves the design: the width ceiling is far tighter than
the mockup assumed.** Sweeping the field's width until `NSToolbar.visibleItems` dropped below
`items` — the chevron, measured rather than feared:

| Window | Workspace bar | Widest field with nothing folded |
|---|---|---|
| 960pt | full labels | **340pt** |
| 960pt | glyphs only | **580pt** |
| 1280pt | full labels | 660pt |
| 1440pt | full labels | ≥700pt (sweep ceiling) |

So **440pt at a 960pt window folds two toolbar items behind the chevron** — the utilities silently
leave. `clamp(320, spare, 620)` cannot be honoured at 960 with the labels up. The fix that keeps the
shape is already built: **the workspace bar drops to its glyph rung while the field is open**, which
bought ~240pt in the probe. That makes the field's width and the bar's rung one decision, computed
together, and it is the same `WorkspaceBarMetrics` reserve rather than a second ladder beside it.

**The width rule, decided 2026-08-18: the field takes the spare, and the bar sheds only when it must.**
Not a new ladder — `WorkspaceBarMetrics.styles(contentWidth:labelWidths:searchLabelWidth:searchKeycapWidth:)`
is already the one place both toolbar controls' widths are added together, for the reason its own
comment gives: two controls sizing themselves against the same row from two decisions is how the
toolbar ends up behind the chevron with two green tests. The field's *open* width becomes another
input to that function, and the rung falls out of it:

- **Labels stay and the field takes whatever is left**, clamped to its ceiling. Above roughly 950pt
  of content width nothing in the row moves at all; the field reaches its 620pt ceiling at about
  1270.
- **Only if that leaves the field under its floor do the workspace labels shed**, which buys the
  field the ~230pt difference between `fullWidth` and `iconOnlyWidth`.
- Below roughly 710pt of content width **nothing moves either**, because the bar is already
  icon-only at rest — that is today's shipped threshold, unchanged.

So the visible shed-on-open is confined to a band of roughly 710–950pt. (Those three numbers are
arithmetic off this file's constants at the default text size — `reservedChrome`, and the 708pt the
labels need beside a compact pill. They are the shape of the rule, not its constants: the real ones
come out of `styles()` and the test that pins it, at every text size.)

**4. Settled in SyncCloud itself, 2026-08-18 — and it went the other way from the spike in one half.**
Run as a throwaway probe *in this app*: the `.primaryAction` item swapped for a field, focus asked
for after launch, and the readings taken off the real window.

**Read the confound first, because every early reading was void.** A second copy of SyncCloud
launched from a shell **cannot become active while the installed app is running** — same bundle id
— so `appActive=false`, `isKey=false`, and *nothing* about focus is measurable: the first pass duly
reported that a SwiftUI `TextField` could not be focused and that no window existed at 2.6s (the app
spends its first seconds reloading 23,798 content digests). Rebuilt with
`PRODUCT_BUNDLE_IDENTIFIER=com.abhishekgirish.SyncCloudFieldProbe` and polled for the window, it
activates and every question becomes answerable. A focus probe in a background app measures AppKit
refusing to focus a background window.

What the real toolbar holds, dumped from `NSToolbar.items`: a SwiftUI `TextField` in a toolbar item
does materialise as an AppKit control —
`ToolbarItemHostingView → AppKitPlatformViewHost<PlatformViewRepresentableAdaptor<PlatformTextFieldAdaptor>> → AppKitTextField`,
`isEditable = true`, `acceptsFirstResponder = true`. It is there and it is focusable. Then:

| | SwiftUI `TextField` | `NSTextField` in an `NSViewRepresentable` |
|---|---|---|
| `@FocusState`, view-owned | **does not take it** — responder stays the pane's list | — |
| `@FocusState`, owned by the scene root and passed down | **does not take it either** | — |
| `window.makeFirstResponder` | takes it (`_SystemTextFieldFieldEditor`, delegate `SwiftUI.AppKitTextField`) | **takes it** (`NSTextView`, delegate `NSTextField`) |
| a click | takes it | takes it |
| survives 20 forced re-renders | yes — **when SwiftUI's own focus state does not disagree** | yes |
| typing reaches the binding | yes (`"abc"`) | yes (`"abc"`) |
| ↑ ↓ ↩ esc | `.onKeyPress(.downArrow/.return/.escape)` all fire | `doCommandBy` gives `moveDown:`, `insertNewline:`, `cancelOperation:` |

**So the spike was right about `@FocusState` and wrong about the click** — in the real app a click
focuses the SwiftUI field perfectly well. The half that matters is the half that survived: **there
is no SwiftUI way to put the caret in a toolbar-hosted field**, and ⌘K — the whole reason this
control exists — is exactly that: focus claimed programmatically, with no click to ride in on.

**Decision: the field is an `NSViewRepresentable` over `NSTextField`, and its keys come from
`control(_:textView:doCommandBy:)`.** Two reasons, and the second is the one that would have bitten
later. A SwiftUI field would need an AppKit reach-in anyway to be focusable by ⌘K — walking the
toolbar item's view tree for a `SwiftUI.AppKitTextField`, which is SwiftUI's private shape and not
ours to depend on. And a SwiftUI field focused behind SwiftUI's back is **one re-render from losing
the caret**: with the scene-root `@FocusState` still reading `false`, the click-granted focus was
revoked inside two seconds and the typing that followed went nowhere, while the same click with the
view-owned state survived the whole churn. That is a defect that reproduces on a re-render this
app performs constantly, and it does not exist if AppKit owns the field.

### Decided 2026-08-18, with him, one question at a time

| Question | Decision | What follows |
|---|---|---|
| **How wide on a big window** | **620pt ceiling** — today's card width. | Unchanged from the shape above; the three candidates only differ above ~1150pt of window (at 960 every option gives ~330, at the 760 minimum ~359). **On the primary machine the ceiling is always binding**: all 29 `[palette] panel … frame=` lines in `~/sync-cloud.log` are 1697×983 or 1710×986, so the field opens at exactly 620 every time and the shed-on-open band never fires there. The width ladder is for other displays and other people, and cannot be judged by using it here. |
| **A click on the pane while the list is up** | ~~Dismisses, and stops there.~~ **Reversed 2026-08-19: it dismisses AND lands.** | The decision below was taken believing the swallow was a property of the panel; it was a property of it being *sized to the host*, which only the dim ever justified. Measured with the dim gone: `panel.frame == host.frame` and the content claimed a hit at the window's far corner. The panel is its list now, and the mouse monitor — which returns the event it dismisses on — does the rest. A window you can see through is a window you expect to click. |
| **A click on the Go-to FIELD while the list is up** | **Nothing** — it is the palette, not something behind it. | The correction to the row above, found reviewing it the same day. Sizing the panel to its list moved the field out from under the panel's frame, so `clickedWindow !== palette` became true for the control being typed into: touching the field to move the caret, or pressing its own clear button, closed the palette and wiped the query — the clear button could not be used at all. The rule takes the anchor rect it already has and spares it (`aClickOnTheGoToFieldDoesNotCloseTheThingItIsTypingInto`). **The palette's surface is two objects in two windows**, and any rule phrased as "which window was clicked" has to say so. |
| **After ↩ lands you somewhere** | ~~Collapse, and remember the query.~~ **Deferred past v4.2, 2026-08-19** — it collapses and clears. | The next open prefills it, selected. Not `ExpandingSearchField`'s collapse-and-clear — the one place this field deliberately departs from that idiom, because the query is the expensive part to retype and the folder you just left is the likeliest neighbour of the one you want next. |
| **How long it is remembered** | ~~Cleared on a source change, expired after 30 seconds.~~ **Deferred with the row above** — the two ship together or not at all. | Session-only — nothing new is persisted. **Evaluated lazily when the field opens**, by comparing a stored timestamp; no `Timer`, nothing running while the app idles. Inject the clock rather than reading `Date()` at the seam, or the expiry is untestable. **Thirty seconds rather than five minutes, and the number is load-bearing** — see the ↩ hazard below. |
| **The field disappearing while the list is up** | **The list is hidden; the palette stays open** — and it comes back if the field does. | Decided on review 2026-08-19. macOS folds a toolbar item behind the overflow chevron on a narrow window, and `goToFieldItemView` refuses a folded item's view (it answers in its own bounds and hands back a plausible rect at the window's corner). The anchor then answers nil and the panel stayed exactly where it was last placed — a list hanging under nothing. **Closing the palette was written first and backed out**: it claims more than the anchor can know. The case that decides it is full screen, where AppKit is understood to move a window's toolbar into a window of its own — `goToFieldItemView` requires the host, so it would answer nil for a field in plain sight and ⌘K would close itself. **That premise could not be verified**: a bare `swiftc` binary cannot enter full screen (`styleMask` never gains `.fullScreen`, measured), and no test host can. Hiding is never worse than what shipped whichever way it falls. **Open, and one keystroke to settle**: press ⌘K in a full-screen window and grep `~/sync-cloud.log` for `[palette] placed under field=` — a line means the anchor is fine and this can become a dismissal; the `is not in this window` warning instead means the strict guard is the problem. |
| **⌘K while it is already open** | **Selects the text**, so the next keystroke replaces it. | **This retires a shipped behaviour**: ⌘K currently *closes* the palette, through `CommandPalettePanelController.closesThePalette` and its local monitor. That rule and its test change rather than move — escape stays the only close, which it already was for everything except this chord. |
| **The placeholder, which no longer fits** | **Two measured rungs**, like everything else on this row. | Full: *Go to a place, a folder, a person, or an action…*; short: *Go to a folder, person, or action…*. At a 960pt window the field has ~249pt of text room against the full string's ~282pt, so without a rung it is a fragment. The short string goes in the same measured arithmetic as the pill's label, not a width guess. |
| **A remembered folder that has gone** | **It does not appear** — *when the root is reachable*. | Resolved when the list is drawn, and **filtered rather than deleted**: the stored entry survives, so a folder on a drive that was asleep at launch comes back when the drive does, while never being offered as a destination it cannot deliver. |
| **A folder whose ROOT is asleep** | **It appears, marked unavailable** — decided 2026-08-19, narrowing the row above; **every folder row, not only the remembered ones**. | The root is checked first (one stalled `stat` instead of a dozen), so an asleep drive takes out **every recent and every pin at once** — and the empty-query landing *is* that list, so ⌘K opens completely blank and "I have no recents" is indistinguishable from "my drive is not awake". That is a different claim from the row above, which is about one folder that has gone. Unavailable rows are how this palette already says an unmounted source exists (`PaletteSelection.initialIndex` skips them, ↩ refuses them), so nothing false is offered and no new empty state is needed. The scope was widened on review the same day: `folders` comes from the survey profile held in memory and answers a typed query whether or not the disk is awake, so marking only the landing meant ⌘K opened saying "Not available" and then offered the same tree as live destinations the moment anything was typed. One root, one answer. |

**The ↩ hazard the 30 seconds exists for** — kept because it is the argument that will be needed again when the memory is picked up, and because it names a live property of the shipped field (`⌘K ↩` means *go to my most recent folder*).

 `PaletteSelection.initialIndex` preselects the first
available row, so `⌘K ↩` today means *go to my most recent folder* — the fastest path the feature
has. A restored query puts that reflex over a list ranked by something the user did not just type,
and the field showing text they did not just enter is exactly what hides it. It is the same defect
`setQuery` already guards one level down ("an index into the PREVIOUS results names a different row
after a keystroke, so ↩ would run something the user never looked at").

Considered and **rejected**: dropping the preselection on a restored-query open. It removes the
hazard completely, but its cost falls on the *only* flow the restore exists for — searched, landed,
wanted the neighbour, `⌘K ↓ ↩` — and at a 30-second window it buys that with a keystroke on the good
path to fix a risk the short window has already taken out. **Row 0 stays selected.** If the reflex
ever does misfire in use, the fix is the guard, not a longer memory.

---

## 8. Window chrome: saying which window is which

- **Name the compared pair in the title bar.** **Shipped 2026-08-20** — `MacApp/WindowSubtitle.swift`.
  The Window menu now reads `SyncCloud (iCloud/Documents ⇄ Dropbox/Documents)`, and a lens names the
  one source it is working rather than a second pane that is not on screen.

  **What the bullet had backwards, measured rather than argued.** It said the pair should be "shown
  beside the tab strip **and** set as the real `window.subtitle`, which is what those two surfaces
  read" — implying `subtitle` is the mechanism and that a hidden titlebar makes an in-window copy
  necessary. AppKit composes the window-list entry from **both** properties, as
  `"<title> (<subtitle>)"`, so leaving the scene's own `Window("SyncCloud", …)` title alone and
  setting only the subtitle produces the line above.
  `WindowChromeBinderTests.theWindowListEntryComposesTitleAndSubtitle` is the measurement; the first
  draft set `title` instead, on the reasoning that a `.hiddenTitleBar` window draws no subtitle so
  nothing could be reading it, and that would have printed the pair twice in one entry.

  **The in-window line is deferred to v4.3 with the item below**, and not as a nicety. The toolbar is the only window-level
  chrome there is, and its width is a measured budget: `WorkspaceBarMetrics.reservedChrome` feeds
  `testTheNarrowestWindowStillClearsTheFieldsFloor`, which §7 already records as "starts failing the
  moment a fifth workspace lands, `reservedChrome` grows, or the window's minimum is lowered". A
  fifth toolbar item **is** `reservedChrome` growing. That is the same budget conversation as the
  item below and as v4.3's status bar, and settling it three times separately is how the ⌘K field
  ends up under its floor. **Take it with one-line pane headers, not before.**
- **One-line pane headers.** **Carried to v4.3 on 2026-08-20, after building it and measuring it.**
  It is v4.3 item 5. The prototype was not landed — there is nothing to revert — but the numbers
  below cost a session to get and are the whole reason the item moved, so they are recorded here
  rather than left in a chat log. Renders and the full argument:
  [the mockup artifact](https://claude.ai/code/artifact/1818e984-9352-4644-90b4-5536cbb56532).

  **Three of this bullet's own claims did not survive the build:**

  - **It gives back 23pt, not 44 — one file row, not three.** The folded header measures **58pt**
    against today's 81. The 44 assumed the provider capsule shrinks with the fold; nothing makes it.
    12pt padding + a 34pt capsule + 12pt padding = 58, at any width where it fits at all. Counted on
    a real render at a 900pt pane: **ten rows becomes eleven.**
  - **It cannot be "on every window".** At a 250pt pane — a normal Compare pane; the rail's floor is
    220 — the bar alone needs **159pt** of a 222pt track (`PaneBarLadder.width(forRung:)` at its
    terminal rung). Everything else gives way at once: the provider capsule collapses to a bare
    chevron with **no name**, and the breadcrumb to two bare separators with **no folders**. Today's
    two-row header at that same width still reads `iCloud › Documents › Reports`. The header's own
    rule — the name is the identity anchor, the logo yields first — is broken outright.
  - **The folded height does not hold still**: 58pt wide, **46pt** narrow, because the capsule's
    ladder drops the logo. That 12pt drift is exactly what pinning `headerHeight` eliminated (it
    measured 80/80/68 before the pin, breaking the shared line by 13pt at the narrow end).

  **And the 83.5 rule binds harder than "a test guards it".** The rail sits *directly beside*
  `LensHeaderCard` on every lens workspace, and that card carries two rows of real content — lens
  name and actions; scanned-folder chip, stat pills and count — so it cannot fold with the rail.
  Folding the rail breaks a line that is on screen, not merely a constant.

  Which leaves **Browse** as the only surface where the fold is safe: full width by construction and
  the one workspace with no lens card beside it. That is what v4.3 should build, if it builds this.
  One more measured detail for whoever does: between roughly 900 and 1200pt the fold costs the pane
  bar its **word labels** (`iconAndText` is the shipped default) because the breadcrumb takes the
  middle of the track; at 1200pt and above they come back and the fold costs nothing at all.

---

## 9. The polish batch — cited, not restated

Two items from the Backlog part's Interface section — both Storage's — scheduled here because each is
genuinely small, neither has a dependency, and both were re-checked against the code at `c604321e`
and are still unbuilt. (It was four; see the note below the table.) **Their specifications stay in the Backlog part** — a spec kept in two places drifts in
one of them — so what follows is only the citation and the evidence that the item still applies.

| Item | State | Where |
|---|---|---|
| **Magnitude bars behind the largest-files list** | **Shipped 2026-08-20** | `StorageMagnitude.swift`; the rules and a rendered measurement in `StorageMagnitudeTests` |
| **One sequential ramp for the treemap** | **Shipped 2026-08-20** | `TreemapView.ramp(_:count:)`; `TreemapRampTests` |

Three things the build settled that the specs above had wrong or unsaid:

- **The ramp does not delete the contrast problem, and this section said it would.** The reasoning
  was "the pale end lands on the small tiles, which carry no labels anyway" — but the fold floors
  the smallest visible tile at `labelMinWidth`, which is *exactly* the width at which a tile starts
  drawing its name, so the palest step is labelled. What was deleted is the fixed ten-entry
  `labelPalette` **table**; the pairing itself moved to `Color.onFillLabel` applied to the fill each
  tile actually took, which is shorter and correct for fills it has never seen.
- **The ramp is built from the user's hue, and `.none` had to be special-cased.** `.none` resolves
  to the *system* accent, which is a dynamic colour: sampling its components freezes it to whatever
  appearance was current. It substitutes blue.
- **Bars are on the size-ordered lists only.** `largest` and `reclaimCandidates` arrive largest-first;
  `stale` arrives oldest-first, and a bar rising and falling against that order reads as a ranking it
  has nothing to do with. The **share** figure is a fact about the file and appears on every row.
  The spec's "share-of-folder percentage" is against `report.totalBytes`, and it rounds **away** from
  zero — `<1%`, never `0%` for a file that is there.

**Two of this batch's four moved to v5 §12 on 2026-08-20** — *Drop the "Identical"
badge* and *Make the stat pills the filter*, both of which live in `LensWorkspaceView`, which is
Organize's screen and one v5.0 is already rebuilding. The constraint they carry moved with them:
*not every pill is a subset* — the reclaim figure, Organize's *reused* and Storage's freshness
marker are scan-level facts, not filters. **Storage's two stay here**, with the workspace they
belong to.

---

## 10. The menu bar — the surfaces that never reached it

**Why:** v4.0 built the machinery and it is good — `AppChord` as the one place a chord is written
down, focused values published through a single `ShortcutValuePublisher` so an overlay can silence
every chord at once. What has not happened is *growth*. The `.commands` block is byte-for-byte what
v4.0 shipped: tabs came and went into it, v4.1 shipped, the Go to field shipped, and not one menu
changed.

Full mockups of all eight menus, drawn against the code, are at
<https://claude.ai/code/artifact/23cda3a3-a408-430a-90fd-c0291bd3a94f>.

### Two corrections this section carries

- **The in-app clipboard already exists.** `FileSyncManager.clipboardNodes` / `clipboardIsCut`,
  `handleCopyToClipboard(_:isCut:)` and `pasteItems(_:toPath:isCut:)` are built, wired to the row
  menu, and spend through the same `copyItems`/`moveItems` as every transfer — grouped undo and
  banner included. It is `NSPasteboard` that has no file support (all 8 sites `setString(path)`). So
  menu items and chords for the clipboard that exists are **small**; Finder interop
  (`NSFilePromiseProvider`) is the medium at order step 10, and they are separate work.
- **⌥⌘V can never ship**, and neither can any ⌥ chord — `AppChordTests.noChordContainsOption` fails
  them, because an ⌥ chord is the one kind that fires through the ⌥-hold reveal. Nothing is lost: the
  clipboard already carries `isCut`, so **⌘X then ⌘V is move-here**, one chord fewer than Finder.

### The five items

**Organize's row moved to v5 §11 on 2026-08-20**, where the four v5.0 verbs that also
need menu homes are — including `Undo this reorganisation`, which must never be mistaken for ⌘Z.

| Item | Size | Read out of the code |
|---|---|---|
| **Edit ▸ Select All / Cut / Copy / Paste** | small | No `.keyboardShortcut` for a/x/c/v anywhere; `selectAll` appears only inside text-field editors. A file browser with no ⌘A. |
| **The transfer verbs get a menu home** | small | ⌘←/⌘→/⇧⌘←/⇧⌘→ exist only as a focus-scoped `onKeyPress` in `KeyboardCopyIntent.swift` — absent from `AppChord`, from the menus and from the ⌘/ reference. |
| **Auxiliary windows leave Help** | small | Activity Log, Sync History and Keyboard Shortcuts are Help items; the Window menu already exists (see §8's note about it listing "SyncCloud" twice). `.appInfo` is never replaced, so About likely renders twice. |
| **View ▸ Text Size** | small | `FontSize` scales the whole app and persists; Settings is the only route to it. ⌘+ / ⌘− / ⌘0 are free. |
| **The row menu's dozen verbs** | small | Open in New Tab, Quick Look, Reveal in Finder, Download, Copy to…, Move to…, Ignore in Comparison — working handlers, no menu-bar row. |

### Three constraints, and one that killed a chord

**Every new item reuses `DeleteSelectionCommand.chordBelongsToTextEditor`.** A menu key equivalent
outranks the field editor, so ⌘X/⌘C/⌘V — and §3's ⌘↑/⌘↓ — would take the caret's own keys away from
the pane search, the rename field and the differences search. That routing rule already exists for
⌘⌫; write it once, here at order step 5, and step 6's chords inherit it. **This is why this section
is ordered ahead of §3's chords** rather than after them.

**↩ renames cannot be a menu key equivalent.** The chord is right and the row belongs in File, but a
registered bare ↩ outranks every default button — it would take the key that commits the destination
picker, the palette, the rename field itself and every sheet. **Finder does not register it either**:
its File ▸ Rename carries no key, and the list view handles ↩ itself. The row goes in the menu
without a chord; the chord goes in the pane.

**Get Info stays off the menu bar.** It wants Finder's ⌘I, which is the Info Inspector here, and the
inspector already answers what Get Info answers without leaving the window. Finder's own panel stays
on the row menu.

One naming split to settle while in there: the same action is **Rescan** in the File menu and
**Refresh** on the row menu — one handler, `handleRefresh()`, two words. Rescan is the better of the
two; the row menu should take it.

---

## Order (v4)

**v4.2 is a navigation release, and §§3 and 7 are one piece of work rather than two.** The field is
what makes Go to Folder possible and what makes the recents question urgent; the chords were
independent of it and of each other. ↩ shipped; ⌘↑/⌘↓ and the status bar were deferred, each on a
question rather than on effort — see the v4.3 section below. **Both questions are answered now**:
⌘↑/⌘↓ shipped as RD5, and the status bar as RD6 on 2026-09-07, in v5.3 rather than v4.3.

**The build order.** **Decided 2026-08-19: 1–12 are v4.2; 13–15 become v4.3.** Three of the twelve
have already shipped, so what is actually left is nine.

1. ~~**Persist recents in `FolderJumpStore`** (§3's second correction).~~ **Done, 2026-08-19**
   (`55c7f92d`) — under `folderJumpRecentsByRoot`, with its cap, its order, and its answer for a
   folder that has since gone. The first open after a launch is no longer empty.
2. ~~**The two spikes** (§7).~~ **Done, 2026-08-18** — all four questions answered in §7, the
   fourth in this app rather than in a probe. The field is an `NSViewRepresentable` over
   `NSTextField`; SwiftUI has no way to focus a toolbar-hosted field, which is what ⌘K needs.
3. **The field, and its width in the reserve** (§7). One commit — the reserve arithmetic has no
   symptom when it is wrong until the toolbar is behind a chevron. ~~The route-table walk from the
   decisions block happens here, before the card is deleted.~~ **It did not** — the card went in
   `7e8fff03` with the walk still outstanding, so it is owed against the deleted card rather than
   ahead of it. **Done 2026-08-19 — clean**; see the decisions block above for the verdict and for
   the two fixtures that were too weak to detect the collapse they were written for.
4. ~~**Go to Folder** (§3).~~ **Done, 2026-08-19** — the field takes `/…` and `~/…` and routes to
   `.folder`. The parse is pure and in the router; the one `stat` is injected from the host, because
   a routing table that answers differently on two machines is not a table. Not quite free: the four
   refusals are most of it, and the ordering of their checks is a stall guard.
5. **The menu bar** (§10). Five small items — Organize's sixth moved to v5 §11. **Before the chords, and that is the dependency** —
   its Edit ▸ Select All / Cut / Copy / Paste is where the text-editor routing rule gets written,
   and ⌘↑ / ⌘↓ will need the same rule whenever v4.3 builds them. Ordered the other way round until 2026-08-19, with a
   note telling the implementer to reach forward for it; the note is gone because the order now
   says it.
6. ~~**The chords and the status bar** (§3).~~ **↩ done 2026-08-20 (`88d95ed9`); the rest moved to
   v4.3.** ↩ is a pane key handler beside Space, never a menu equivalent — it outranks the field
   editor and every default button, and Finder does not register it either. **⌘↑/⌘↓ and the status
   bar are deferred with a question each, and neither is a scheduling excuse** — both are recorded
   in §3 so the next attempt starts from the question rather than from the item. **That worked:
   both shipped in v5.3 from the recorded question rather than from a re-derivation** — ⌘↑/⌘↓ as
   RD5, the status bar as RD6 on 2026-09-07. ~~⌘/ stays with the shortcuts reference for as long as
   the status bar is not built.~~ **⌘/ stays with the reference permanently**: the bar shipped
   Browse-only and with no chord at all, so the trade the reassignment was for never came due — see
   the decisions table at the top.
7. **The polish batch** (§9). Two small items, no dependencies — the two Organize ones moved to
   v5 §12.
8. **Title-bar subtitle** (§8). Small, and the only item here that answers a question the app
   currently cannot answer at all.
9. ~~**Pins and recents sidebar** (§3). Reads the store step 1 made durable — already shipped, so
   this is unblocked.~~ **Built, then held for v4.3 on 2026-08-20** — struck rather than deleted
   because the code is on `main` and inert, not reverted. See §3 for the reason and v4.3's item 6
   for what turning it on commits whoever picks it up to.
10. **The pasteboard** (§3). ⌘C/⌘V to and from *Finder* + a paste-as-move whose chord is still to be
    chosen (**not ⌥⌘V** — the ⌥ ban above). Note §10's correction: the **in-app** clipboard already
    exists and works, so what is left here is `NSFilePromiseProvider`, not the whole feature.
11. ~~**§1's switch mirroring** — or delete it, having now run tabs for a release.~~ **Deleted on
    2026-09-07** (roadmap RD8). Carried to v4.3 on 2026-08-20 as its item 4, on the explicit
    condition that a fourth carry would settle it the other way; v4.3 shipped without it, so it
    was. See §1 for the record.
12. ~~**One-line pane headers** (§8). Medium, and it argues with a pinned constant and its test.~~
    **Carried to v4.3 on 2026-08-20**, as its item 5 — built, measured, and moved on the numbers
    rather than on the argument. It did not merely argue with the pinned constant; it lost. §8
    carries all of it. **With this, v4.2 is feature-complete.**
13. **Gallery view** (§3) — thumbnail infrastructure.
14. **Group by kind or date** (§3) — touches every row-rendering path.
15. **Drop files on a tab** (§3) — after 10, with the proof that a click still opens a column.

**Where it was cut, and why.** Steps 1–12 are a complete, nameable release: they are the half that
makes the app faster to move around in. 13–15 change what Browse can *display*, not how you get
anywhere, and any one of them is a release on its own — v4.0 was the largest the app has had at 284
commits and it was *one* structural change plus its consequences. **Decided 2026-08-19: 1–12 as
v4.2, 13–15 as v4.3**, with tags cut outright rather than deferred.

---

## v4.3 — what it holds, and why each thing is in it

**Assembled 2026-08-20 from what this file already defers**, not from a fresh survey: every entry
below is a pointer to a section above that carries the detail.

**This table is not the whole of v4.3, and it does not try to be.** The
[v4.3 plan](https://claude.ai/code/artifact/23cda3a3-a408-430a-90fd-c0291bd3a94f) carries **eight
more items** that came out of the round-2 visual review of the running build rather than out of this
file — five Storage-lens fixes, two Duplicates ones, and Compare's Path column retiring into
parent-directory headers. They are not repeated here because a spec kept in two places drifts in one
of them; what is repeated is only the six below, which this file defers and that page therefore has
to carry too. **Seventeen items in total: fourteen for v4.3, three beyond it.** If the two ever
disagree, the code is the tiebreak and both are wrong until re-read.

**Item 6 is the one that page does not carry yet, and it is why the count moved.** The sidebar was
taken *off* it on 2026-08-20 as one of the five items v4.2 absorbed — correctly, on the morning's
facts — and held back for v4.3 the same afternoon. Until the page is corrected this file is the only
place it is written down, which is the drift the split is supposed to avoid, arrived at from the
direction nobody guards: not two copies disagreeing, but one copy deleted because the other said the
work was done. The list is short on purpose. Things arrived here by three different routes and it
matters which:

- **Deferred on merit** — ranked last because they change what Browse can *display* rather than how
  you get anywhere. These were always v4.3's content.
- **Deferred on a question** — small work, blocked on a decision nobody has taken. These are the
  ones that rot: an item filed as "small" with an unanswered question behind it looks schedulable
  and is not.
- **Built, then held** — the newest route, and the only one whose code is already on `main`. Item 6
  was finished, reviewed and then switched off for v4.2 because what it shipped was a smaller thing
  than its name promised. These do not rot the way a deferred item does — they rot the other way, by
  looking done. An inert feature has no user to notice it decaying and no test to fail if the app
  moves around it, which is why its hold is asserted rather than assumed.

| | Item | Size | Why it is here |
|---|---|---|---|
| 1 | **⌘↑ / ⌘↓** (§3) | small | **On a question.** A pane has two positions and the two candidate meanings move different ones — see §3's entry for the axis choice. The implementation is small once the axis is decided. |
| 2 | ~~**The status bar** (§3)~~ | small | **Shipped 2026-09-07 (roadmap RD6).** The question is answered, and the answer is a fourth shape: Browse-only. §8's one-line headers settled it, exactly as this row said they would — see §3. The cloud-only count is indeed a walk, and it is paid in the background behind a `—`. |
| 3 | **Switching to the source a typed path is in** (§3) | small | **On a mechanism, not a question.** Go to Folder refuses a cross-source path and names the source; switching to it needs `adoptProviderForTab`'s counter to suppress the provider change's own `resetNavigation()`, or the pane lands at its root with the folder silently dropped. Expect the reload ordering to be the whole of the work. |
| 4 | ~~**Mirroring tab *switches* on linked panes** (§1)~~ | — | **Deleted 2026-09-07** (roadmap RD8), under the fourth-carry rule this row itself set: *"If it is carried a fourth time, delete it instead."* v4.3 shipped without it. The design and the two questions it never answered are described — not restored — in §1. |
| 5 | **One-line pane headers** (§8) | medium | **On a decision that has now been taken twice, and the second one is why it is here.** Built and measured 2026-08-20: 23pt back and one file row, not §8's 44pt and three; unusable below ~560pt; and folding the lens rail breaks the 83.5 line it shares with `LensHeaderCard`. **Browse-only is the only safe shape.** §8 carries every number. Take §8's in-window subtitle line with it — same width budget, and settling it twice is how the ⌘K field ends up under its floor. |
| 6 | **Browse's folder sidebar — switch it on, and make it Finder's** (§3) | medium | **Built and held.** The column, its rows, its refresh, its render tests and its host wiring are all on `main` and all inert (`FolderSidebarModel.isEnabled`); switching it on is that constant plus the four surfaces named beside it. **That part is an afternoon and it is not the item.** The item is the difference between two ungrouped lists and what a Mac user means by a sidebar: named sections that collapse and reorder, a folder dragged *in* to become permanent, and a row you can drop a file onto to file it without navigating there. **Shares 8's prerequisite** — dropping onto a row and dragging a folder in both need pane row drag re-added, so take these two together or take 8 first. |
| 7 | **Gallery view** (§3) | large | **On merit.** A third `PaneViewMode` case is free; thumbnails — generation, a cache that survives a quit, eviction, a placeholder that does not flash — are the whole job. Argue it from the scans folders, the only trees where a filename genuinely fails to identify the file. |
| 8 | **Group by kind or date** (§3) | large | **On merit.** Sorting exists; grouping is a different shape — sections, headers, counts, collapse state, and a sort *within* each group — and it touches every row-rendering path in the pane. |
| 9 | **Drop files on a tab** (§3) | large | **On merit, and it has a prerequisite.** Do it after v4.2's pasteboard, which sets the move semantics this expresses as a gesture. Needs row drag re-added, and the proof that a click still opens a column — the check the removal was originally made to satisfy. |

**Ordering.** 1–3 first: each is small, and two of them are one decision away from being finished
rather than started. Then 4, 5 and 6, the three mediums — 4 is the only one here with a *design*
still open, 5 is the only one that arrives with its measurements already taken, and 6 is the only one
whose code is already written and switched off. Then 7–9, which are independent of each other and of
everything above — except that **6 and 9 share a prerequisite**, and doing 9 first makes 6 cheaper.

**What is NOT here, and stays not here.** Tags was cut on 2026-08-19 rather than deferred — the
objection stood unanswered through two roadmaps and the integration that would have earned it a
place was declined. Do not re-add it from §3's table without answering the objection first; being
on a list is how it got scheduled the first time.

**A caution about size.** Three of these nine are large, and any one of them is a release on its own
by the measure this file already applies to v4.2. If v4.3 takes 1–6 plus *one* of 7–9, it is a
coherent release; taking all three of the larges is how a version number stops meaning anything.
**Item 6 is the one with a deadline of a sort**: it is the only thing on this list that a user could
have read about in a draft release note, and inert code is cheapest to finish while the person who
wrote it can still be asked why.

---

## Open questions (v4)

Two tab questions were answered by building it, and are struck rather than deleted because the
answer is the useful part: `View ▸ Tab Bar` ships **unticked** (one tab costs no row, and the strip
renders correctly at one tab if you do tick it), and its tick is **one app-wide preference**,
`browseTabBarVisible` — app-wide rather than per-surface like `paneViewModeBrowse`.

  That sentence cited `paneColumnShowsPreview` as the app-wide example, and stopped being true on
  2026-08-15: the preview column now has a Browse sibling, `paneColumnShowsPreviewBrowse`, because
  turning the preview off to compare two providers was taking it away from browsing too. The tab
  bar deliberately is *not* that — there is one strip and one answer. The decision here is
  unchanged; only the example it borrowed has moved.

- ~~Whether ⋯ takes a title in the titled bar.~~ **Answered by building it: no**, and aligned with
  the pill row rather than centred in it. Finder labels its *Action* menu, but that is a fixed
  contextual menu; our analogue is Finder's unlabelled `»`, whose contents depend on what happened
  to fit. Worth knowing how narrow the question was: titles shed as a whole rung *before* any item
  folds, so ⋯ appears on a titled bar only for someone who removed a control in the customize
  sheet.
- ~~Whether `v2.x` is still open when §2 is picked up.~~ **Answered: `main` only.** The v3/v4 line
  owns this; `v2.x` carries no Search, no Delete and no `ScanRungMode`, so it would have been a
  hand-port of a divergent bar rather than a cherry-pick.
- Whether a tab shows a scan/download spinner when work is running in a folder it is not showing.
- **§3 / §7: what cap and eviction rule do persisted recents want?** Session-only recents self-limit
  by ending. A durable list does not: it needs a length, an order, and an answer for a folder that no
  longer exists on disk — the same three questions `PaneTabChips` already had to answer, and the same
  trap, since a recent that quietly repoints is worse than one that disappears.
- **§3 / §8: what does the status bar say in Compare?** — **ANSWERED 2026-09-07: nothing, because
  there is no bar there.** The two items were decided together as this entry required, and the
  finding was that the question has no good answer rather than three costly ones: the per-pane
  header already carries each side's facts, so a shared strip must either repeat one pane or pick a
  winner silently. The bar shipped on Browse, the one surface with a single pane, and it is built in
  `browseLayout` rather than in the shared `paneColumn` so the scope is structural. A per-pane
  Compare bar remains possible and remains a different design — it would contest the same vertical
  room §8 spent, which is the argument this entry was pointing at all along. See §3.
- **§3: is tags actually wanted, or is it here because it was on a list?** — **ANSWERED,
  2026-08-19: it was here because it was on a list, and it is cut.** The objection stood
  unanswered through two roadmaps; asked directly, the answer was to cut it rather than build a
  second filing system. See §3.
- **§7: does anything reach a route only the 620pt card could show?** The decisions block makes this
  a walk of the palette's route table before the card is deleted, rather than a question — recorded
  here so it is not lost if that walk finds something that needs a door of its own.

---

# v5 — Organize

**Scope: one workspace.** v5.0 is the **Organize** release. Its spine is **Restructure** — the
storage-layer gaps behind a lens that already ships (§4), the plan surface it was deliberately
shipped without (§5), and the document survey the filing lenses read (§6) — and around that spine sit the rest of the Organize surface's unfinished work: reaching the
menu bar (§11), the two lens-workspace controls that never became what they look like (§12), and
command-line parity for the lenses (§13). §§4–5 run first, under the four decisions recorded below.
`main` only.

**Why one workspace and not one project.** Restructure alone would have left four small Organize
items scattered across the 4.x file and the Backlog part, each too small to schedule and each touching
the same two views Restructure rebuilds. Organize is also the only workspace where v5.0 changes
anything, so a release named for it is a release a user can be told about in one sentence: *the tab
that files your documents can now fix the shape of the tree they live in.*

**What stays on the 4.x line.** Browse and its tabs, the pane bar, the Finder borrowings, the ⌘K
Go-to field, window chrome, and the menu-bar work that is not Organize's. The v4 part is not
closed and is not a predecessor: the two lines are concurrent, and an item lives in whichever one
owns its surface.

**Moved out of the v4 part on 2026-08-16, unchanged.** It was v4.2's defining feature until
then; it is now its own release, because it is its own project. Everything below is the text as it
stood, with two exceptions, both deliberate and both visible: release references that said *4.2* now
say *5.0*, and the decisions block's "v4.2, not v5.0" bullet is struck with its reasoning kept —
that argument is reversed, and the reversal is explained where it sits rather than here.

**Section and figure numbers are carried over, not renumbered.** These are still §§4, 5 and 6, and
the figures are still 21–34. "§4.2 shipped" and "§5.5 step 6" appear in both companions, in commit
messages and in the audit notes; renumbering would silently repoint every one of them.
The v4 part keeps a tombstone at those numbers and starts its own new work at §7.

**New work in this file is numbered from §11**, and that is a rule rather than an accident. The 4.x
file now uses §§1–10, so starting here at §11 means **no section number is ever ambiguous between
the two roadmaps** — "§7" is always the 4.x Go-to field, "§11" is always Organize's menu-bar work.
Anything moved into this file from the 4.x one is renumbered on arrival and its old home keeps a
one-line pointer, for the same reason the §§4–6 tombstone exists.

**Why v5.0 and not v4.3.** `CLAUDE.md` earns a major with a breaking change, and by that rule this
would be v4.3: nothing here breaks, removes or restructures a shipped behaviour, and §5.5 is written
so no `schemaVersion` ever goes incompatible. **The major is earned by size instead** — Apply moves
folders on disk and needs an on-disk inverse, a ledger, six invariants and a re-derived profile after
every landing. This is a deliberate departure from that bar, taken on 2026-08-16, and it is recorded
in three places (here, the decisions block, and the v4 part's preamble) so that it reads as a
decision rather than an oversight when someone checks the rule against the tag.

Distinct from the Backlog part (the standing feature backlog across all surfaces),
the v4 part (the 4.x line), `DEFERRED_ENHANCEMENTS.md` (accepted limits) and `REFACTOR.md`
(internal shape). An item graduates out of this file the way it does out of those: deleted when it
ships, because git history is the record.

§§4–5 were designed and mocked on **2026-08-12**; **§6 was designed on 2026-08-13**, and its
constraints were read out of the code that day — the day part of §4.2 shipped, which is why §4.2
carries measurements rather than a plan.

An **illustrated companion** carries the figures this file can only describe —
**Building Organize**, <https://claude.ai/code/artifact/929eb3d2-d381-4fa5-b456-a0a9c9313cea>,
rebuilt on 2026-08-20 to match this file section for section. **This file is still the one that
ships**; if the two disagree, the companion is the stale one.

**The August 11 mockup set is superseded and has been marked so on its own page**
(<https://claude.ai/code/artifact/73b57ccc-56f2-4437-9f2f-a1e85c47a646>). It is kept as a record
rather than cited as a spec: four of its claims are now wrong — the mapping editor refusing merges,
a 12-or-13-folder flagship family, the 52/434 crowding counts, and "8 years vouch for it" — and its
banner lists them. What held up is listed there too.

**Reviewed for implementation-readiness on 2026-08-16 (evening)**, against the code, the live
profile and the 6 Aug manifest, with four decisions taken in that review; they are the block below,
and every §4–§6 item was re-cut under them. The companion was rebuilt on 2026-08-20
under those decisions and under the Organize rescope, so the disagreements that note used to list
are gone; the rule stands anyway, because the file moves first.

---

## Restructure in v5.0 — the decisions

Four questions the audit surfaced were answered on 2026-08-16, and they settle what §§4–6 may
claim. Everything below them is written under these; nothing in them is open.

| Question | Decision | What it changes |
|---|---|---|
| **Who is 5.0 for?** | **This machine.** Restructure ships against the hand-built profile that already exists here; the fresh-machine path is **§6, after the release**. | §6 is not on 5.0's path and nothing in §§4–5 waits on it. But §5.5's re-derivation (below) makes the *profile* half of §6 nearly free — see §6, "Two halves". |
| **Merges?** | **Designed in.** Two source folders onto one target inside a member is a first-class operation, with a collision policy and its own ledger line. | §5.4 stops refusing the case the flagship family needs; the mapping model, the manifest and the ledger all carry it. |
| **Who owns the profile after an Apply?** | **The app re-derives it from a fresh walk, carrying two judgement fields forward.** `buildTree` ＋ `FolderSurveyBuilder.build` after every landing; `acceptsNewFiles`/`noIntakeReason` and `naming` are copied from the previous profile for every path that survives, directly or through the manifest's rename map; the jurisdiction set is the distinct entry-level values of the previous profile (`US`, `IN`, **`Singapore`** — the header lists only two). The old file is never deleted: the new one is written under a fresh id and `profiles.json` is re-pointed, which is what `writeProfile` does today. | The finding is genuinely gone after Apply because the detector re-ran on a real profile. The create-only guard now protects *hand-built* files from *derived* ones by provenance, not existence. Costs accepted and written down in §5.5: the 80 cached cloud verdicts re-bill (the profile is in the fingerprint — and they name paths that moved, so invalidating them is correct), and the hand-authored doctrine sections go inactive (nothing decodes them; the file that carries them stays on disk). |
| **How far does Apply go in the release?** | **All of it, landed in stages** — renames first, then moves and merges, then the opt-in removal step — behind the six invariants, ⌘Z and an on-disk inverse. | §5.5 is release-gating, not a stretch. Export-only would leave the defining feature ending in a JSON file. |

**Two more that followed from those:**

- ~~**v4.2, not v5.0.**~~ **Reversed on 2026-08-16 when this work moved out of the v4 part:
  it is v5.0, and the major is earned by size rather than by breakage.** The original reasoning is
  kept because it is still true as far as it goes, and it is what makes the version *safe* to
  choose either way: nothing here breaks, removes or restructures a shipped behaviour — the lens
  gains a plan surface, the store gains a write it did not have, and every existing file still
  decodes. A major would be earned *by the compatibility rule* only through an incompatible
  `schemaVersion` on the profile, the corpus or the memory, and §5.5 is written so that never
  happens (the new profile is the *same* schema with a provenance field; the old one still loads).
  What changed is the other half of the argument: Apply moves folders on disk and needs an on-disk
  inverse, a ledger, six invariants and a re-derived profile after every landing, and shipping that
  as a point release would be the misleading label. **This is a deliberate departure from
  `CLAUDE.md`'s bar for a major**, recorded here so it reads as a decision rather than an oversight
  when someone checks the rule against the tag.
- **One app-owned store for everything Restructure remembers**, not four — see §5.0. Suppressions,
  Ask answers, drafted plans and the applied ledger all key on the same `kind × path` identity and
  all live in `restructure.json` beside the profile. §5.3 was going to be the store's first
  customer; the ledger is now, and it is release-gating.

**What makes it fundamentally useful, and not just correct** — worth stating because the audit
measured the shape detector at **one finding on the whole tree**: the value in 5.0 is spread across
five things, not one. (1) The flagship family finally converges, merges included. (2) **Backlog
becomes actionable, not just visible** — *set up 2025 like its siblings* creates the scaffold the
series expects and hands the flat files to To File; that is the operation you would use every year,
and it is non-destructive (§5.2). (3) The dead-weight and empty-folder counts turn into filtered
lists with a Trash path for the sub-class that has a rule (§5.2). (4) A landing that can be undone
after a quit, from a ledger, not only with ⌘Z (§5.5). (5) A profile that follows the tree, so the
lens is never describing a tree that no longer exists (§5.5). If those five hold, the release is
worth its name on a tree that has already been hand-tidied.

---
---

## 4. Restructure: a cached answer, and no way to run one

**Why:** the lens opens on its setup card and says its answer is cached (shipped `6c56768a`). It
cannot say *how* cached, and on a machine with no folder survey its card still has no trigger —
the app can now *derive* a profile (§4.2, shipped) but has no way to *run* the derivation (§6).
Both are storage-layer gaps behind a view that is already done.

### Context

| Fact | Where | Consequence |
|---|---|---|
| **The survey's `generated` stamp is write-only.** It is set on a private `Encodable` struct; `FilingMemory`, the type actually decoded at launch, has no such field. | `Modules/Sync/Sources/Sync/FilingSurveyStore.swift` | Nothing can read a date back today, which is why the card claims coverage only. |
| **And it means "last changed", not "last surveyed"** — the memory is written only when `memory != previousMemory`. | same, `write(corpus:memory:previousMemory:…)` | A survey run this morning on a settled tree leaves last month's stamp. Showing that would be worse than showing nothing. |
| **The corpus is written unconditionally, and is NOT hashed into the fingerprint** — which covers `folder-profile.json`, `filing-memory.json`, `people.json`. | `FilingProfileStore.fingerprint(id:in:)` | The corpus is the one artifact that moves on every survey *and* costs nothing to move. A per-survey timestamp in a hashed file changes `FilingVerdictKey` and re-bills every cached cloud classification. |
| **`resurveyFilingMemory` cannot bootstrap.** It opens with `guard let profileId = filingMemory?.profileId ?? filingFolderProfile?.profileId` and returns `.none` otherwise. | `Modules/Sync/Sources/Sync/FileSyncManager+FilingSurvey.swift` | The half the app owns cannot produce the half it does not, so a fresh machine has no way in. That is why §4.2 was a new builder rather than "just run the re-survey", and it is the guard §6 opens with. |
| **`isAxisValued` already falls back to `isBareYear` and `isInboxPath`** — its own doc says the fallbacks exist "for a profile that records no axes at all". | `Modules/Sync/Sources/Sync/StructureDivergence.swift` | A profile that records no axes at all is still enough to make **this lens** work, through those fallbacks; what it misses is exact — non-year axis values (`Family/Mom`, `Finance/US`) read as vocabulary, so two eras can look different when they differ only by whose folder they are. The derived profile does not need the fallback: it records `axes`, which is part of why Restructure cannot tell it from the hand-built one (§4.2). |
| **The folder profile has exactly one write path, and it refuses over an existing profile.** `writeProfile` throws `WriteRefusal.profileExists`, writes atomically, and re-points `profiles.json` only when nothing is active. `FilingSurveyStore` still never writes a profile. | `Modules/Sync/Sources/Sync/FilingProfileStore.swift` (`writeProfile`, shipped `d4280231`) | A derived profile can never land on top of a hand-built one, which is what a walk cannot re-derive: `naming`, `folderSemantics`, the `outbound-pack` refusals. There is deliberately no `overwrite:` parameter. **Revised by the decisions block:** from 5.0 the guard keys on *provenance* — a file the app derived is the app's to replace, a hand-built one still is not — and "replace" always means *write a new id and re-point*, never overwrite. §5.5 carries the mechanism. |
| **The builder needs a walk, not a survey** *(review)*. `FolderSurveyBuilder.build(tree:root:profileId:registry:jurisdictionValues:)` reads folder names, file names and counts; no PDF is opened. `FileSyncManager.buildTree(url:sortOption:fileManager:maxDepth:)` produces that walk today. | `FolderSurveyBuilder.swift:58`; `FileSyncManager+Scanning.swift:914` | Re-deriving a profile is seconds, and it is the same two calls whether the reason is an Apply (§5.5) or a fresh machine (§6). The hours in §6 are the *document* survey — the corpus and memory the router wants — which Restructure does not read. |

### 4.1 A truthful "last surveyed" — small

Display-only. Five files, ~150 lines.

1. `FilingCorpus` — add `public var surveyedAt: Date?`. Optional, so a corpus written earlier or by
   the offline builder still decodes.
2. `FileSyncManager+FilingSurvey` — stamp it before `FilingSurveyStore.write(…)`, and take `now` as
   a parameter (`docs/flaky-tests.md` mechanism 5: inject the instant, don't race the clock).
3. `FileSyncManager` — `@Published var filingSurveyedAt: Date?`, so the footnote updates the moment
   a re-survey finishes.
4. `MacApp/SyncCloudApp.swift` — read it in the block that already loads the profile, memory and
   fingerprint; `Sync` does not reach into a home directory.
5. `RestructureLens` — widen to `surveyNoteText(folderCount:surveyedAt:now:)`, plus a caution
   variant past a threshold. **Only the glyph takes the tint** — amber on 11pt body text is a
   contrast trap this repo has hit before.

**Test the pair that pulls both ways:** the stamp must move when a survey changes nothing, and the
fingerprint must *not* move with it.

**The threshold is unmeasured.** 30 days is a guess. Ship the plain variant first and pick the
number from real stamps.

### 4.2 Building a survey in the app — the derivation shipped

`FolderSurveyBuilder`, `FilingProfileStore`'s first write path and `JurisdictionCandidates` landed
in **`d4280231`** on 2026-08-13. The two items that remain are not a smaller version of what
shipped — they are an execution model and a dialog, and they are **§6**.

What shipping measured revises the plan those items were written under, so it is recorded here
rather than deleted with them. Every number below comes from walking the real tree and comparing
field by field against this machine's hand-built 3,013-folder profile (`~/Documents`); the
comparison itself is `FolderSurveyGroundTruthTests`, machine-pinned to that tree.

| The plan said | The measurement says |
|---|---|
| Leave `naming`, `anchors` and `axes` **empty** rather than guessing. | **`anchors` and `axes` are derived.** They are what the router consumes, and leaving them empty forfeited most of the value. Agreement: role .998, anchors .997 (the whole list, in order), `acceptsNewFiles` .998 with **39 of 39 inboxes refused and no false positives**, person .998, lifecycle .999, year and fiscalYear 1.000, jurisdiction 1.000 *once its values are supplied*. |
| A wrong `naming` would have the rename pass propose renames toward a convention nobody has. | Unchanged — `naming` is still never guessed — and now with a second reason: **nothing reads `FolderProfileEntry.naming`** outside test fixtures, so accuracy there would buy nothing even if it were free. |
| "the degradation asserted rather than described" — the same synthetic tree with and without axes. | **Restructure returns the identical finding from a derived profile as from the hand-built one.** `theLensSeesTheSameThingInADerivedProfileAsInAHandBuiltOne` pins the mechanism behind that — the lens reads no field a walk abstains from, so enriching a derived profile with `naming` changes nothing it returns. It does not pin the full claim, which is about two profiles whose `axes` differ by up to 0.2%, and `axes` is a field the lens does read; that remains measured rather than asserted. There is no degradation left for this lens to characterise, so the planned test is settled by removing its subject — but the *claim* still needed pinning, and for a while it had none: nothing outside `FolderSurveyBuilder`'s own tests fed a derived profile to anything, so the day this lens starts reading a field only the offline survey produces, nothing would have failed. What a walk still cannot re-derive is `naming`, `folderSemantics` and the jurisdiction vocabulary — and that, not a degraded profile, is what the store's refusal protects. |

Three rules came out **narrower** than the plan assumed. Each was swept rather than argued, and the
losing variant is written down beside the winner:

- **The inbox test asks the leaf, not the path.** Asking `isInboxPath` of the whole path scores
  .992 against .998, because `Finance/US/TODO/IRS/2023` is a year bucket. Its *permission* is a
  separate question, and `acceptsNewFiles` does still ask the whole path.
  (`FolderSurveyBuilder.role`, doc.)
- **The archive test asks the folder's own name**, with `axes.lifecycle` carrying the fact that
  propagates. Any-component matching costs the same .992. (same doc.)
- **The anchor cap is 10, not 14** — 10 → .997, 12 and 14 → .979. The literal is
  `FolderSurveyBuilder.anchorLimit`; the sweep behind it is in `d4280231`'s body, not in the source.

And two things the plan did not know it needed:

- **The anchor tokenizer is deliberately not `FilingRouter.tokenize`.** Running the whole pipeline
  through the router's tokenizer measures **.320 against .997**. The two exist for different jobs —
  the router's must agree byte for byte with the memory that wrote its index; this one feeds a
  human-readable list of what a folder is about — and `theRoutersTokenizerWouldBeMuchWorseHere`
  re-derives that gap on every run rather than quoting it, so nobody unifies them on the
  reasonable-looking grounds that both make tokens out of names.
- **Jurisdiction values cannot be derived.** The heuristic alone scores **.83**, and the gap is
  three inventions: it proposes `EMP`, `IT` and `PRD` as *places*. Without its 2–3-character bound
  the strongest candidate on this tree is **`TODO`**, under more parents than `US` — the inbox
  marker the whole filing path exists to refuse. So values are **proposed for confirmation, never
  adopted**, which is what puts them in §6's dialog. The rule also **misses**: `Singapore` is a real
  jurisdiction here (10 folders) and appears under only two parents, below the three-parent bar, so
  the dialog must let a value be **added** as well as ticked or the tree's third jurisdiction can
  never be recorded at all.

### 4.3 Shadow axis values — medium, and it is a report rather than a repair

`StructureDivergence` names this gap and explicitly does not claim it: a year-bearing folder name
that is not a *bare* year (`IRS Docs - 2023`) is treated as a role rather than as a year.

The pattern is on the real tree — `Finance/US/Income Tax` reports three shapes, one of which is
`IRS Docs - 2023, IRS Docs - 2024` beside bare years. Its own detector, not a wider `isBareYear`:
widening that would start swallowing real role names containing digits.

**Reframed by the 2026-08-16 audit, on two measurements.** This item used to say the shadow value
joins its parent's vocabulary and makes that parent's shape look unique — implying the Shape
detector is less accurate for it. Adding exactly that rule to `isAxisValued` and re-running the
whole detector over the live profile returns **the identical finding set**, one family before and
one after. So the value here is the *report* — naming `IRS Docs - 2023` as a year folder that should
be `2023` — not accuracy.

**And the rule has to be the narrow one.** **302 folders** carry a four-digit year in a name that is
not a bare year, and almost all are correct: `01. Jan 2019` monthly statement folders,
`2005 - 2006` Indian fiscal years. A detector keyed on *the name contains a year* fires 302 times,
which is precisely the failure `StructureDivergence`'s own doc was written to prevent. Scoped to
**a shadow year sitting beside bare-year siblings** it fires **5** times. Note also that its
proposed fix — `IRS Docs - 2023` → `2023`, where `2023` already exists — is a **merge**, which
§5.4 now defines: the two-file folder moves into the year and is emptied, and the year keeps its name.

**This is one of §5.2's eight detectors.** Build it once, there — it is listed here because it is
storage-side and needs neither the plan surface nor a scoped read.

---

## 5. Restructure: propose the fix, not just the finding

**Why:** the lens reports and stops. A finding names a disagreement and offers `Reveal`; acting on
one means Finder, by hand, for an afternoon. Backlog item 20 designed the plan surface and
deferred it behind six safety invariants — this is that surface, **scoped to the selected folder**,
plus the detectors it needs to be non-empty at a leaf. §4 is the storage underneath the same lens
and is independent of this.

The flagship case has been accumulating for thirteen years, and the whole flow was **run by hand
once** — `immigration_reorg_2026-08-06.json`: 132 file moves, 4 folder renames, 39 empty-folder
removals, 2 of them mistakes. That log is the worked example, and most of the constraints below are
scars from it.

**Be exact about which half of that day this surface claims.** Sorting the log's 179 operations by
whether a folder-name → folder-name mapping could have proposed them: **4 `rename-dir` yes**;
**108 file moves yes**, because they came from 44 source folders that moved wholesale and are
therefore folder-level operations; **24 file moves no** — they came from 5 folders whose files were
split by *content* (`Immigration/TODO` sent files to five different destinations), which is per-file
judgement and belongs to To File; **39 removals** only through §5.5's opt-in step. The plan surface
is the shape half. Saying so here is cheaper than discovering it on the first real run.

### Context

**Audited against the code and the live 3,013-folder profile on 2026-08-16, and re-read for
implementation-readiness the same evening.** The rows marked *audit* are ones that re-measuring
changed or added; the rows marked *review* were added by the readiness pass. Two of the audit rows
blocked items below until the decisions block settled them.

| Fact | Where | Consequence |
|---|---|---|
| **Restructure compares sibling *families*.** Under a scope pointed at a leaf the `inside` list is frequently empty and the lens falls back to showing the ancestor's findings, faintly — its own doc calls this out. | `RestructureLens.aboutAncestor` | The detectors that read **one subtree alone** (§5.2) are what make a scoped answer non-empty. Without them the plan surface has nothing to open at the depth people scope to. |
| **One detector of eight shipped.** Dead weight, backlog, mirrored inbox, echo names and shadow axes are designed and unbuilt. | `StructureDivergence` | A crowded branch gets the same answer as a tidy one: silence. Measured 2026-08-16, the whole lens returns **one finding, in one of sixteen top-level areas** — so the lens is thin because seven detectors are missing, not because it is unscoped, and that is the argument for §5.2 going first. §4.3 is one of the eight — build it as part of §5.2, not twice. |
| **`memberCount` sums the *vouched* schemes only** — a scheme of one is dropped as drift before the card is drawn. **And that is only one of two drop paths** *(audit)*: a sibling whose vocabulary is empty — a leaf, or one whose children are all axis values — is dropped *before clustering starts*, so it never becomes a scheme to grey. | `StructureFinding.memberCount`; `StructureDivergence.finding`, the `guard !words.isEmpty` | The card reads **11 folders** on a family of **17**: 11 vouched ＋ 5 unvouched drift ＋ 1 with no vocabulary at all (`CA State`, 3 files, 0 folders). **A folder with no shape is the one the plan most needs to house** — it is evidence for no era, so nothing else will claim it. |
| **`StructureFinding.id` is the family path** *(audit)*, and `RestructureLens` renders `ForEach(findings)`. | `StructureDivergence.swift`; `RestructureLens.body` | §5.2's whole point is that one family can produce a *Shape* **and** a *Series* **and** an *Ask* — three rows sharing one identity in one `ForEach`. **Put the kind in the identity before the second detector lands**, not after. The same composite key is what §5.3's answer store and *never suggest this again* both need, so it is one decision serving three items. |
| **Nothing in the app can rebuild a folder profile** *(audit)* — `writeProfile` throws `WriteRefusal.profileExists` and has deliberately no `overwrite:`; `resurveyFilingMemory` writes the corpus and the memory and never a profile; `structureFindings` is memoised and dropped only by `filingFolderProfile`'s `didSet`. | `FilingProfileStore.writeProfile`; `FileSyncManager+FilingSurvey`; `FileSyncManager.structureFindings` | **Was the blocking one; decided.** The detector reads `FolderProfile.folders`, keyed by relative path, and §5.5 renames exactly those paths. From 5.0 an Apply ends by re-deriving the profile from a fresh walk (decisions block; mechanism in §5.5), so the finding is gone because the tree was re-read. |
| **The corpus and the memory are keyed by relative path too** *(review)* — `FilingCorpus.documents` by document path, `FilingMemory.folders` by folder path; the memory is hashed into the fingerprint. | `FilingCorpus.swift`; `FilingMemory.swift`; `FilingProfileStore.fingerprint` | An Apply strands three artifacts, not one. Re-deriving fixes the profile; the corpus and memory get the **manifest replayed onto their keys** — a rename maps a prefix, a move maps a path — so no page is re-read for a file that only moved. The fingerprint moves either way; that is correct (§5.5). |
| **The primitives Apply needs already exist, and the rename pass is the worked example of using them** *(review)*: `enqueueFileOperation` (serialised, counted in `activeFileOperationsCount`), `safeMoveItem` (never overwrites), `generateUniqueURL` (keep-both), `registerMoveUndo` (one grouped ⌘Z per pass, **in-memory, gone at quit**), the `isVerifyAllRunning` write-exclusion guard, and the pattern of *re-listing the folder inside the operation and applying only steps the disk still asks for*. | `FileOperations+Primitives.swift:142,266`; `FileSyncManager+Undo.swift:189`; `FileSyncManager+FilingRename.swift:201` | "Shares the rename pass's review-and-apply path" means **these**, not its view. Two things it does not have and §5.5 adds: an inverse that survives a quit, and a verifier from a different code path. |
| **A folder rename on this tree is one filesystem operation carrying every file inside it** — the rename pass moves files; a `rename-dir` moves a directory with `safeMoveItem` and iCloud / Dropbox sync it as a rename. | `FileOperations+Primitives.swift:266` | The reason *prefer the rename* is not only tidiness: on an iCloud tree with evicted files a rename never forces a download, and a merge (per-file moves within one container) does not either. Nothing in §5.5 crosses a volume. |
| **`folderSemantics` is decoded by nothing** *(audit)* — the two matches in the Swift tree are both comments. `FolderProfile` decodes five fields; `conventions`, `axes`, `folderSemantics`, `structuralRules` and `canonicalPaths` are read by nobody, and the three live entries are hand-authored prose doctrine. | `FolderProfile`; `folder-profile.json` | §5.3 was specified to write its answer there. It cannot, and should not — see §5.3, which now carries its own store. |
| **The crowding counts came from a smaller tree** *(audit)*. | live profile, 2026-08-16 | Pass-through is **86**, not 52; single-file leaves **503**, not 434. Both figures print in the mockups as though they were the app's output — **derive them, never paste them**. |
| **The rename pass already owns a review-and-apply path** — per-folder plans, "as one undoable change", and a *left alone, for a stated reason* tail. | `RenamePassLens`, `onApply` | The plan shares it rather than growing a second one. Backlog item 20 makes that its scheduling constraint. |
| **The one paid control names its model, names its batch size, and raises a spend pre-flight with a real estimate.** Its branch is *is a key stored*, not *is cloud switched on*. **It is typed to `[FilingSuggestion]`** *(audit)* and gated on `filingCloudRefineAvailable` ＋ `canRefineFilingSuggestions`. | `LensWorkspaceView.refineButton` | §5.6 reuses the **pattern** — same slot, same words up to the ellipsis, same billing sentence, nothing new to design — but not the function. That is the difference between "small once §5.4 exists" and a day. |
| **Answers and applied plans both invalidate the check that asked them.** | v3.1 review; `Refine` is already a generation-bumper | §5.3 and §5.5 must bump a structure generation and recompute, or the lens re-suggests what it was just told. |

### 5.0 Identity and the store — small, and first

Two things every item after this one leans on, so they land before any of them.

**Identity.** `StructureFinding.id` becomes `kind × subject` — a `FindingKind` enum plus the path
of the most specific folder the finding is about, which for shape is the family and for the others
is narrower (the echoed child, the mirrored inbox, the backlog member). **Kind × family is not
unique for every kind** — echo-name can fire twice in one family, on two different sibling pairs —
so the subject, not the family, is the second half of the key; the family is still carried for the
§5.2 grouping rule. The enum is the **complete** set of ten, settled before the store serialises a
raw value: `shape`, `backlog`, `shadowAxis`, `echoName`, `mirroredInbox`, `deadWeight`,
`looseAboveSeries`, `looseBesideContainer`, `duplicatedTaxonomy`, `ask` — the 2026-08-20 recovered
detectors and §5.9 included, because adding a case later is cheap but re-keying a store is not
(raw values are append-only, never reused). `deadWeight` renders as the crowding strip rather than
as cards (§5.2), but keeps its kind: the empties-removal manifest's `kind` field and the
suppression key both need the identity. Today `id` is the family alone and `RestructureLens` does
`ForEach(findings)`, so the second detector to land collides with the first in one `ForEach`
(audit). The kind carries the **verb** the card shows (§5.1) and is the first half of every key
below.

**The store.** One per-profile, app-owned, atomically written file, `restructure.json`, next to
`people.json` — precedents `PeopleStore`, `PersonTagStore`, `StorageLensStore`,
`FilingVerdictCache`. Four sections, one key:

| Section | Keyed on | Written by | Read by |
|---|---|---|---|
| `suppressed` | kind × path | *Never suggest this again* on any card | the lens, before rendering; the rail badge |
| `answers` | kind × path → chosen option | §5.3's Ask sheet | the detector that asked, so it never asks twice |
| `drafts` | kind × family → mapping ＋ manifest | §5.4, when the sheet closes with a plan | §5.7's *Planned, not applied* card |
| `applied` | manifest id → manifest, inverse, `at`, outcome counts, the profile id it was applied under and the one it produced | §5.5, at the end of a landing | §5.7's *Applied* card; **`Undo this reorganisation`**; the log |

**Answers, drafts and suppressions all survive a re-survey** — the profile can be replaced under
them (§5.5) and their keys are paths, not profile ids. What they do *not* survive is the path
moving: an Apply replays its manifest onto this file's keys too, the same replay §5.5 runs on the
corpus and memory. **Not `folderSemantics`**: nothing decodes it, and the profile is not the app's
to edit in place.

**Proof:** a round-trip test per section; a test that a suppressed finding stays suppressed after
the profile is swapped for a derived one; a test that a rename in a manifest re-keys every section
that named the old path — and leaves one that named a sibling alone.

### 5.1 The scoped read — small

Display-only, no new machinery. Fig. 21.

- Each finding card gains a **kind tag carrying the verb** — *Shape* renames or merges folders,
  *Series* scaffolds and hands off, *Ask* asks — so the class of change is legible before the sheet
  opens.
- The card states its blast radius, derived from the draft where one exists and from the family's
  shape where none does: for a one-to-one family *a plan here is folder renames, no file would move*;
  for the flagship family, whose convergence needs merges, *N folders would be renamed and M merged,
  so files would move* — the honest sentence, and the one that makes someone open the sheet.
- **The count stops undercounting, on both drop paths** (see Context): the subtitle counts the
  family, the unvouched scheme renders greyed as drift, and **the shape-less sibling gets a row of
  its own** — *no shape of its own* is a different sentence from *disagrees with the others*, and
  this lens's whole discipline is that no state borrows another's words. On the flagship family that
  is 11 → 17, not 11 → 16.
- `Reveal` demotes to a link; `Plan…` takes the primary slot.
- **The rail badge counts only the kinds that carry a plan.** A badge you cannot drive to zero is a
  badge people stop reading, which is why *Ask* is excluded. **Cheaper than it looks:** the badge is
  already scoped and already excludes ancestor findings (`RailCounts.restructure`), so filtering by
  kind is the only new part.

**Proof:** the flagship family fixture (folder names only, lifted from the live profile into the
repo — 17 members, 24 child names) renders **17** in the subtitle, one greyed drift scheme, and one
*no shape of its own* row for `CA State`; the badge equals the count of plan-bearing kinds inside
the scope and ignores an Ask beside them; a scoped read at a leaf still shows the ancestor's
findings faintly, and a `Plan…` on the card, never a `Reveal` in the primary slot.

### 5.2 The remaining detectors, and the crowding strip — medium

Each is a finding kind before it is a plan, and each is worth landing on its own. Fig. 22.

Detectors, all specified in Backlog item 20: **backlog** (the newest instance of a recurring series
has no folders yet — worth saying the month it happens rather than thirteen years later),
**shadow axis** (= §4.3), **echo name** (`PG&E/PGE`), **mirrored inbox** (`Health/TODO/Dental` beside
`Health/Dental`), **dead weight** (pass-through folders and single-file leaves), **loose above a
series** (files parked in the parent of a year run that has folders for them) and **loose beside a
container** (`Home/ATT Bill` next to `Home/ATT/`). The last two were in Backlog item 20's list and
were dropped in every draft after it; they are measured below and one of them is the second-best
detector on this tree.

**Echo name is two rules, not one, and only one of them was ever written down.** Backlog item 20's
example — `PG&E/PGE` — is a **child echoing its parent**. The example this file has been carrying —
`Form W-2` beside `Form W2` — is **two siblings echoing each other**. They need different code and
they return different things: parent/child fires **4** times here, sibling/sibling **1**. Build
both; count them as one kind with two sub-rules, or the card cannot say which shape it found.

**What each actually returns here** — re-measured on **2026-08-28 through the built Swift
detectors** over the in-repo reference fixture, which retired the 2026-08-16/20 Python dry-runs
this table used to quote. Where a number moved, the old one and why are in the row; every count is
pinned by `StructureDetectorsTests.theReferenceTreeCountsArePinned`:

| Detector | Fires | Notes |
|---|---|---|
| **Backlog** | **11** | `Health/Dental/2025`, `Work/EMP/Compensation/Benefits/2026`, `Vehicles`- and account-shaped series, all plausible, all computable from `fileCount` and `subfolderCount`. *(Was 10 in the 08-16 dry-run; the built rule — newest bare year flat with files, at least one older shaped sibling — returns 11.)* **The firing bar and the scaffold bar differ on purpose**: one shaped sibling makes the flatness a finding, but the scaffold copies only a scheme **two** shaped members vouch for, so a lone member's idiosyncrasy (`Benefits/2024/Archive`) never becomes next year's convention — most real backlog cards therefore say *no shared shape to copy* and still hand the files to To File, which the measurement shows is the common case (10 of 11 here). Best value of the set. |
| **Echo name** | **5** | One kind, two sub-rules, counted together: **4 child-echoes-parent** (`TODO/IRS/IRS`, `ACI/ACI`, `Petition/Petition`, `Amazon/Amazon`) + **1 sibling pair** — the true merge hit, `Form W-2` beside `Form W2` under `Finance/US/Income Tax/2023/Forms`. *(The table used to say 1, counting only the sibling rule.)* **The sibling fix is a merge** — §5.4 defines it — so it lands with a two-row mapping and a plan of one merge, collisions kept both. Until stage two of §5.5 lands, the card offers Export and says Apply is coming, rather than a button that dead-ends. |
| **Mirrored inbox** | **0** | *(Was 1.)* The clean rule — a folder strictly inside an inbox whose de-inboxed path exists — fires on nothing here: the 6 Aug TODO drain cleared the class. The one candidate, the degenerate `Finance/US/TODO/IRS/IRS`, is a child restating its parent *inside* an inbox — **parent/child echo's observation, and the echo detector names it precisely**; bending the mirror rule to also claim it would fire on a path whose de-inboxed form exists nowhere. So the two-detectors-one-folder overlap this section describes below is now shape × loose-above on `Income Tax`, not mirror × echo. **Build it, validate it on the synthetic fixture, expect zero here.** |
| **Shadow axis** | **3** | *(Was 5.)* Under the narrow rule — exactly one embedded year, at least one bare-year sibling — the hits are `IRS Docs - 2023`, `IRS Docs - 2024`, and `Travel/…/Florida/2023 (Family)` (whose target year does not exist — a rename, not a merge). The complete candidate set was enumerated on 2026-08-28: everything else beside bare years is a **fiscal span** (`2014-2015` under SBI NRE, Honda payments, Acme benefits), which carries two years and is an era disagreement — the shape detector's business, not a shadow of either year. |
| **Dead weight** | **86 / 503 / 20** | Pass-through, single-file leaves, and **wholly empty** — unchanged, and now pinned by the fixture test. |
| **Loose above a series** | **11** | `Finance/US/Investments/Fidelity/Statements` — **22 loose files above 4 year folders** — plus `Finance/US/Credit Reports` (5 above 11), `Finance/US/Income Tax` itself (5 above 14), `Vehicles/FasTrak` (38 above 6). *(Was 10; the built thresholds are ≥3 year folders and ≥4 parked files — swept 2026-08-28: a floor of 1 file returns 38, of 2 returns 20, of 4 returns 11, and at 4 the one-stray-closure-letter hits above closed accounts' archives stop dominating.)* **The second-best detector on this tree after backlog**, and the closest thing here to an everyday one: a statement gets saved to the folder rather than into the year. Its fix is per-file, so it hands off to To File exactly as the scaffold does (§5.2's scaffold) rather than growing an Apply. |
| **Loose beside a container** | **2** | `School/US/Son/City Pre-K` beside `Pre-K/`, and `Work/EMP/Products/Nova PE` beside `Nova/`. **Three guards, each killing a measured junk class**: skip names whose tokens are all digits on both sides (`5.2.1` "inside" `5.1.1` — version numbers tokenise into subsets of each other); the loose one must be a **leaf with files** (`H-4 EAD` has four era subfolders and is a parallel family, not a stray); the container must have **subfolders** (`Archive/HDFC Savings` beside a flat `Archive/HDFC` is six accounts sharing a brand word with a pile of loose files, and "move the accounts into the pile" is the finding backwards). The name rule alone fires **38** here; with the shape guards it is 2 for 2. |

**Two detectors will name the same folder, and the list has to decide which one speaks.** Measured
(2026-08-28, through the built detectors): `Finance/US/Income Tax` is caught by **shape** *and* by
**loose above a series**. (The other pair this section used to cite — mirror × echo on
`Finance/US/TODO/IRS/IRS` — dissolved when the mirror rule went clean; only echo claims it now.
The rule below still stands, because any two detectors *may* coincide.) §5.0's `kind ×
path` identity makes both rows renderable, which is correct — they are different observations — but
two cards about one folder, one above the other, reads as a bug the first time it happens. **Rule:
render every kind, but sort a folder's rows together and let the first one carry the path as a
heading**, so the second reads as a second thing about the same place rather than a repeat. This is
cheaper than a precedence table and it never has to decide which observation is more important,
which is a judgement the tree cannot support.

The crowding strip is the answer to *"it sees a lot of folders"*: three counts above the findings,
each a filter into a list. **Crowding is a property of the scope, not a finding** — always non-zero
on a real tree — so it never takes a badge. The counts are **scope-dependent, but the cache is
not**: `LensWorkspaceView` already scopes the profile-wide memo at render time (a `filter` over
`structureFindings`), and that is the right shape for everything here. Every detector *and* the
per-folder crowding classification join the existing profile-keyed cache — computed once per
profile, dropped by `filingFolderProfile`'s `didSet` — and the strip's three numbers are a count of
that cached classification within the scope prefix, O(scope) at render. No second cache dimension,
no scoped invalidation to get wrong.

**Backlog is the one detector whose fix is cheap, safe and recurring — so it gets an Apply of its
own, and it is the highest-value addition of the review.** The finding today is *the newest year
has files and no folders*; the natural action is not a restructure but a **scaffold**: *Set up
`Health/Dental/2025` like its siblings* creates the folders the family's vouched vocabulary expects
(`Claims/`, `Statements/`, …) as `create-dir` operations and nothing else — no file moves, nothing
to undo but empty folders — and then **hands the flat files to To File scoped to that folder**,
which is the surface that already makes per-file judgements with a verdict, a shortlist and Undo.
Where the family has no vouched scheme (all drift), there is nothing to scaffold from and the card
says so. This is the operation a person would use *every year* rather than once a decade, it is
the "worth saying the month it happens" case from Backlog item 20 made actionable, and it is what
lets 5.0 be useful on a tree that has already been hand-tidied. It shares §5.4's manifest
(`create-dir` only) and §5.5's landing (no removal step), so it costs a card and a hand-off, not a
second machine.

**Only sub-classes with a stated rule get an Apply.** The 503 single-file leaves get a number and
nothing else: a folder can look like debt and be a destination waiting for its next file, and
nothing in its own shape separates the two. That is the same mistake that had
`Supporting Documents/Resume` and `Supporting Docs/EMP/Payslips` put back on 6 Aug. **Pass-through
folders (86) are also report-only in 5.0**: hoisting `A/B/…` to `A/…` is a move of everything
under `B` and a rename of every path in the profile, corpus and memory beneath it, for a defect
that costs one click in a column view. Say the number, offer the list, offer no button.

**The 20 wholly empty folders — decided.** They appear as the third filter of the crowding strip
and, unlike the other two, they get §5.5's removal sheet — the *same* sheet, with the same split:
an empty **date bucket** (`2019`, `2013-2014`, `01. Jan 2019`) is debt and is ticked; an empty
**category** is a destination and is listed unticked with its path printed inline. Nothing is
deleted; folders go to the Trash; ⌘Z and the ledger cover it like any landing. That is the 6 Aug
rule applied to the folders that day's scope-bug taught it on, and it is the cheapest real win in
this item.

**Proof:** each detector gets a synthetic fixture that fires and a control that does not, *and* is
run against the in-repo reference fixture lifted from the live profile with the numbers in the
table above pinned (`11`, `5`, `0`, `3`, `11`, `2`, `86 / 503 / 20`) — a detector whose count
moves on the fixture moves for a reason someone has to write down. The scaffold card's `create-dir` list equals the
vouched vocabulary minus what the newest member already has; the To File hand-off opens scoped to
that folder and to nothing wider.

### 5.3 Ask findings — medium

A finding with **no Apply button**, for a disagreement no fact in the tree settles —
`Health/Kaiser - PG&E` versus `Health/Medical/Kaiser`, coverage-through-an-employer versus care
records. Two answers and a *don't ask again*; the answer is remembered and never asked again,
including after a re-survey.

**The answer goes in its own store, not in the profile** — corrected by the audit. It was specified
to land in the profile's `folderSemantics`, and that cannot work twice over: **nothing decodes that
section** (`FolderProfile` reads five fields; `folderSemantics` has no Swift reader outside two
comments), and the profile's only write path refuses to write over an existing profile by design.
Its three live entries are hand-authored doctrine with a prose *why* and rules in English, which
machine-written answers should not be mixed into even if the file were writable.

So: **a small app-owned store, keyed on detector × folder path.** `PeopleStore`, `PersonTagStore`,
`StorageLensStore` and `FilingVerdictCache` are four existing precedents for exactly this — one
per-profile file, written atomically. That key is also the identity *never suggest this again* needs
(Backlog item 20) and the suppression key §5.5 needs, so it is one decision serving three items.

**It therefore no longer needs the profile write path**, and stops being the item that unlocks the
ones after it. What it still needs is the **generation bump**: `structureFindings` is memoised and
dropped only by `filingFolderProfile`'s `didSet`, so the cache gains a second trigger or the lens
re-asks what it was just told. Schedule it on its own merits — which are modest today, since this
tree holds one Ask-shaped disagreement.

**Not release-gating for 5.0.** The store it needs ships with §5.0 regardless (the ledger and the
suppressions are release-gating; the `answers` section is a second key in the same file). If the
sheet and the one detector that asks are not done when the rest is, 5.0 ships without them and
loses one finding on this tree. Fig. 32 stays as the design.

**The detection rule itself is undesigned** — said here so it is not discovered on the branch.
Everything above specifies what happens *after* a disagreement is found: the sheet, the store, the
answer's lifetime. What rule finds `Health/Kaiser - PG&E` versus `Health/Medical/Kaiser` in the
first place — anchor overlap between a folder and a non-sibling? a person/provider token shared
across branches? — has never been written down or measured, and the one example is the only known
instance. Design it against the live profile before building the sheet; it is in Open questions.

### 5.4 Choose → map → manifest, with Export — large

The whole plan surface, ending in a file that §5.5 then lands. Figs. 23–24 — **with one correction
to both: the mapping editor no longer refuses merges.**

**Merges are designed in — decided.** Laid out in full, **the flagship family cannot converge
without one, in either direction**: 2013's `Federal Tax` · `State Tax (California)` · `State Tax
(North Carolina)` has no one-to-one image in 2016–2022's `Forms` · `Reference` · `Refund` ·
`Transcripts`, and the reverse has none in 2013's. Nor is it hypothetical: the 6 Aug run **fed 3
destinations from two sources each**, and §5.2's one real echo-name hit (`Form W-2` / `Form W2`) is
a merge too. So it is an operation, and this is its definition:

- **The mapping is per family: *source child name → target child name*, one row per distinct
  source name across every member** (24 rows on the flagship family). It is edited once and applied
  to every member; per member the operations are *derived*, never typed:
  - one source → a target absent in that member: **`rename-dir`** (atomic, carries its files);
  - N sources → one target absent in that member: **rename the source with the most files, merge the
    rest into it** — the fewest moves that reach the shape;
  - N sources → a target already present in that member: **merge all N into it**;
  - a target with no source in that member: **nothing**, unless the plan is a §5.2 scaffold, in
    which case `create-dir`;
  - a source mapped to *keep*: **`keep`**, listed (invariant 4).
  - **Ordering inside a member is derived too**: a folder is vacated before its name is filled
    (`Forms → Tax Records` runs before `Federal Tax → Forms`), a two-way swap goes through a
    temporary name, and a case-only rename (`forms → Forms`) takes the two-step `safeMoveItem`
    already has for case-insensitive volumes. The 6 Aug log never needed any of these; the flagship
    mapping will, and a manifest that lists them in the wrong order fails at the second action.
- **A merge is `move-file` per file plus `move-dir` per subfolder into the target, followed by the
  source becoming eligible for the removal step** — never a `move-dir` of the source *onto* the
  target, which would nest it. Apply sees only primitives; the sheet groups them as *merge `Federal
  Tax` into `Forms` (12 files, 1 folder)*.
- **Collision policy.** A file whose name exists at the target is moved under a unique name by
  `generateUniqueURL` — **keep both, never overwrite, and count it**: the ledger has a line *N name
  collisions, both kept*. If the two are the same document that is a Duplicates question, not this
  surface's; it may say so, it may not decide. A *subfolder* whose name exists at the target merges
  one level down by the same rules; deeper than that the subfolder is `keep` and reported.
- **The ledger separates what a merge does from what a rename does**: *files moved* (merges) from
  *files carried* (renames), *folders renamed* from *folders emptied*. The "8 renames · 0 moved ·
  92 carried · 5 kept" that Fig. 24 draws for the flagship family **predates merges and is not the
  number** — derive it from the mapping; do not paste it.

**Whether the manifest can also be replayed against the profile — decided (re-derive; see the
decisions block and §5.5).** What is still this item's is that the manifest be *replayable* at all:
an ordered list of typed path operations, each with a `src` and `dst`, so that §5.5 can run it
forwards on the disk, run it onto the corpus, memory and store keys, and derive its inverse
mechanically.

1. **Choose the target shape — nothing pre-selected.** The schemes found, labelled by what they are
   (*the largest group*, *the most recent*), with **Name it myself among them, not behind them**.
   Neither recency nor majority is the authority: the 6 Aug fix went **both ways at once**, because
   H-1B is filed on Form I-129 (a *petition*) and H-4 / H-4 EAD on I-539 / I-765 (*applications*) —
   a fact that exists nowhere in the tree.
   **Derive *the most recent* from the members' year axis, never from scheme order** *(audit)*. On
   the flagship family the most recent *vouched* scheme is `IRS Docs - 2023, IRS Docs - 2024`, while
   the genuinely newest folders — 2023, 2024, 2025 — are all unvouched drift sharing no scheme at
   all. A label taken from scheme order points at neither. And when the newest members are drift,
   **say there is no current shape**: that is a true and useful answer, and it is the finding rather
   than a failure to produce one.
2. **Tabulate the family group first** where parallel families share a vocabulary. Fixing H-4 alone
   would have left it disagreeing with its two siblings; laid out as a table the cause was visible
   in one glance (each filing lands flat and is foldered later). *(2026-08-28: shipped as a
   pointer, not yet the table — the sheet names the sibling families sharing ≥3 mapping names
   (`RestructurePlanner.parallelFamilies`), which at that bar names H-1B beside H-4 and deliberately
   not the two-name overlaps, because `Statements`/`Reference` pairs recur correctly all over the
   tree. The side-by-side table belongs with §5.5, where planning several families in one sitting
   becomes real.)*
3. **The mapping editor** — one row per distinct source folder name across the family, target
   dropdown, **default keep**, never a guessed mapping. This is where the leverage is: edited once,
   applied to every member. Two sources onto one target is a **merge** and the row says so in the
   margin (*merges into `Forms` in 3 members*), so the cost of a choice is visible where it is made.
   **Size it honestly:** the flagship family has **24 distinct child names across 17 members**, not
   the nine the mockup draws, and several are near-duplicates a dropdown alone cannot resolve
   (`Payment` / `Payments`, `Forms` / `Tax Returns`). **The mapping is one level deep**: it names a
   member's direct children; whatever is inside a renamed folder is carried, and whatever is inside
   a merged one moves with it. It does not reach into `2016/Forms/W-2/`.
4. **The manifest** — the 6 Aug log's schema, extended, and versioned so a reader can tell them
   apart. Header: `schemaVersion: 2`, `profileId`, `manifestId`, `createdAt`, `family`, `kind`
   (§5.0's), `mapping` (the rows as edited), `note`. Then `actions`, ordered as they run: `create-dir`
   · `rename-dir` · `move-dir` · `move-file` · `keep` · and, only in the removal step's own manifest,
   `remove-empty-dir`. Each carries `src`, `dst`, `evidence` (its written justification), and where
   it applies `filesCarried` (renames) or `bytes` (file moves — **filled in at apply time**,
   invariant 5, never at plan time). `md5` was a fourth such field and is **no longer written** —
   see `RestructurePlan.Action.md5` for why, and note old ledgers still carry it. The ledger is a
   pure function of `actions`.
   **Prefer the rename whenever a mapping is one folder to one folder**: it is atomic, preserves
   file identity and cannot half-finish. The 6 Aug run brought fourteen eras into agreement with
   4 renames carrying 74 files between them — 58, 11, 1 and 4; read from the log on 2026-08-28,
   which is when "58 files each" was caught as the misquote it was — and moving none.
   **The inverse is derived, not authored**: reverse the list, swap `src`/`dst`, turn `create-dir`
   into `remove-empty-dir` and `remove-empty-dir` into `create-dir` — and a collision-renamed file's
   inverse restores its *original* name, which is why the collision has to be recorded as its own
   fact on the action, not folded into `dst`.
5. **`Export plan…`** writes the manifest beside the profile as `restructure-<date>-<family>.json` —
   reviewable in a text editor with nothing at risk — and **saves the draft to the store** (§5.0),
   which is what makes §5.7's *Planned, not applied* survive the sheet closing and the app quitting.
   This is the natural stopping point in the build order: everything above is worth landing before
   any Apply exists.

**Proof — the 6 Aug oracle.** Reduce that day's `Immigration/Authorization` fix to a fixture (folder
names and counts only) and to a mapping (`Application → Petition` under H-1B; `Petition →
Application` under H-4 and H-4 EAD); the derived manifest must be **exactly the log's four
`rename-dir` operations with their `filesCarried`, and no `move-file`**. Then the flagship family
under a mapping that converges 2013 onto the 2016 vocabulary: the manifest carries merges, the
ledger's *files moved* is non-zero, `keep` lists `Transcripts` where the target has no slot, and a
seeded name collision surfaces as a counted line rather than a lost file. Round-trip the manifest
through its `Codable`, and check the inverse of the inverse is the original.

### 5.5 Apply — large, and the only destructive item here

Built on the rename pass's primitives (Context): `enqueueFileOperation`, `safeMoveItem`,
`generateUniqueURL`, `registerMoveUndo`, and its rule of re-listing inside the operation and applying
only what the disk still asks for. **Landed in three stages, each shippable**: renames and
`create-dir` first — the flagship's H-4-shaped cases and every §5.2 scaffold need nothing else —
then moves and merges, then the removal step. All three are in 5.0 (decisions block).

**What one landing does, in order:**

1. Refuse to start while `isVerifyAllRunning`, while any `ScanLifecycle.isRunning` (a filing scan,
   a re-survey or the duplicate scan reads the paths this is about to move), or while
   `activeFileOperationsCount > 0`; and, once started, hold `activeFileOperationsCount` so none of
   those starts underneath it. The rename pass guards only the first; this guards all three because
   it moves *folders*.
2. Write the **inverse manifest to disk first** — into the store's `applied` section with outcome
   *in progress* — so a crash mid-run leaves a reversible record (invariant 3).
3. Run the actions through `enqueueFileOperation`, **re-probing every `src` and `dst` immediately
   before each one** (invariant 5): a folder holding a file the manifest never listed is skipped and
   reported, and the rest of the plan runs (invariant 2); a `dst` that has since been taken gets
   `generateUniqueURL` and a collision line, never an overwrite; `bytes` is recorded on
   each moved file *now*, from the disk. (`md5` was recorded here too until the digest was
   dropped — it cost a full read of every moved file and nothing ever verified it.)
4. **Verify from a different code path** (invariant 6): re-list every touched folder and reconcile
   file counts against what the manifest predicted — a verifier that agrees with the applier because
   it shares its arithmetic has proved nothing. A mismatch is reported on the card and in the log,
   and does not roll anything back on its own.
5. Register **one grouped ⌘Z** for the whole landing (`registerMoveUndo`, as the rename pass does),
   and finalise the ledger entry with counts and outcome. ⌘Z is this launch's undo; the ledger's
   inverse is every later one.

   > **Known limitation, written down 2026-08-28 (round-3 review):** session ⌘Z reverses the
   > *disk* only. The re-derived profile, replayed corpus keys and re-pointed `profiles.json`
   > stay as the landing left them, so every survey-driven surface reasons over the reorganised
   > shape until the next re-survey — and the ledger card stays "Applied" (its undo then refuses
   > honestly as all-drift). Converging ⌘Z with the ledger undo's re-point would make the two
   > indistinguishable, which §11 deliberately keeps apart; the cheap honest fix, if this bites,
   > is a banner after a session undo pointing at re-survey. (A *removal* landing registers no
   > ⌘Z at all and clears the stack instead — the previous landing's group was on top, and
   > replaying it into just-trashed folders was worse than no ⌘Z.)
6. **Re-derive the profile** — the decision. `buildTree` over the profile root, then
   `FolderSurveyBuilder.build` with the previous profile's registry and its *entry-level*
   jurisdiction values (`US`, `IN`, `Singapore`); then the **carry-over**: for every path that exists
   in both, or maps across through this manifest's renames, copy `acceptsNewFiles`,
   `noIntakeReason` and `naming` from the old entry. Write under a fresh profile id with
   `derivedBy: "SyncCloud <version>"` and `derivedFrom: <old id>`, re-point `profiles.json`, and
   **keep the old file** — it is what Undo re-points to, and it is the last hand-built copy. Then
   set `filingFolderProfile`, whose `didSet` drops `cachedStructureFindings` — the finding is gone
   because the tree was re-read.
7. **Replay the manifest onto the keys of the corpus, the memory and the store** — a `rename-dir`
   re-prefixes every key beneath it, a `move-file` re-keys one document, a merge re-keys each file
   it moved — **and write them under the NEW profile id's directory**, along with `people.json`,
   carried as-is. The per-profile artifacts live beside the profile they describe, and step 6 just
   minted a fresh directory; a replay that wrote them back under the old id would leave
   `profiles.json` pointing at a folder holding a profile and nothing else — suppressions, drafts
   and the roster all silently gone on the first Apply. No page is re-read for a file that only
   moved. The fingerprint moves; the **80 cached cloud verdicts** on this machine are invalidated,
   and that is correct — every one of them names a destination as a path, and the paths just
   changed.
8. Log one line per landing: manifest id, family, counts, verifier result, old and new profile ids.
   The log is where the truth of an apply gets found later; make it findable by grepping the
   manifest id.

**`Undo this reorganisation`** — the button §5.7's *Applied* card carries — runs the stored inverse
through the same eight steps: guards, re-probe, verify, and re-point `profiles.json` back to the
profile recorded as `derivedFrom`, which was kept for exactly this. It survives a quit because the
inverse is on disk, and it is honest about drift: a file that has moved on since is skipped and
reported like any other unlisted file. It is not ⌘Z; both exist, and the card says which it is.

The six invariants from Backlog item 20 are the acceptance criteria, three of them rendered on the
manifest where the decision happens (every moving file listed by full path first; the inverse plan
written to disk before the first operation; a folder holding an unlisted file skipped **and
reported**, with the rest of the plan still running) and three enforced (apply closed over the
manifest; every claim re-derived at the moment of the action, because he edits this tree while the
work is open; never hand an operation a parent folder as a proxy for its contents — that one sent
**69 files classified *keep*** to the Trash, and what caught the matching verifier bug was an
independent count from a different code path).

**Removal is a separate sheet, opt-in, scoped to folders the plan itself emptied**, and split by the
shape of the name: an empty **date bucket** is debt and is ticked; an empty **category** is a
destination and is not, with its paths printed inline because there are few enough to read. No file
is ever deleted; folders go to the Trash.

#### The gap this item used to be unable to close — and how the decision closes it

**Applying a plan made the lens's own input wrong.** The detector reads `FolderProfile.folders`,
keyed by relative path; this item renames and moves exactly those paths, and until 2026-08-16 three
independent paths confirmed there was no way back (`writeProfile` refuses over an existing profile,
the re-survey never writes one, `structureFindings` is memoised behind `filingFolderProfile`'s
`didSet`). Step 6 above is the answer: **re-derive from a fresh walk, carry two judgement fields
forward, write a new id, keep the old file.** Replaying the manifest onto the profile was the
alternative and it was rejected for one reason — replay is a model of the disk, and this tree is
edited while work is open; a walk *is* the disk.

**What that costs, accepted in the open** (measured on this machine's profile, 2026-08-16):

- ~0.2–0.3% of hand judgements per field are replaced by the walk's — roughly 6–9 folders each on
  `role`, `anchors`, `person`. `acceptsNewFiles` would have lost 6 (45 hand refusals against the 39
  inboxes the walk finds) — **that is why it is carried over**, with its `noIntakeReason`.
- `naming` on 2,534 entries would go — read by nothing outside tests today, **carried over anyway**,
  because the day the rename pass starts reading it must not be the day it silently stopped existing.
- The hand-authored doctrine sections (`folderSemantics` 3, `conventions` 3, `structuralRules` 4,
  `canonicalPaths` 5, the top-level `axes` prose) are **not** in the derived file. Nothing decodes
  them; the file that carries them stays on disk as `derivedFrom`; the active profile no longer
  carries prose. Accepted.
- The jurisdiction set is taken from the *entries*, not the header: the header says `US, IN`; the
  entries carry **`Singapore` on 10 folders**. Take the header and the tree loses an axis value.
- A new mutable write path where there was an immutable file. Provenance in the file, the old copy
  kept, Undo re-pointing back — those are the mitigations, and they are all in step 6.

**Silently keeping a stale answer was the one option that was never available**, because it is
indistinguishable on screen from an apply that did nothing; that is still true, and it is why
step 6 is not optional in stage one.

**Proof:** an apply against a temporary tree, seeded from the flagship fixture, in which a listed
file is deleted and an unlisted one added *between* plan and apply — the unlisted folder is skipped
and named, the rest lands, the ledger's counts match a `find` over the result; ⌘Z restores a
byte-identical tree (hash it, do not size it — 6 Aug); the on-disk inverse restores it after the
manager is thrown away and rebuilt; after the landing the derived profile has **no** finding for
the family, carries the old `noIntakeReason` for a surviving refused folder **and for one that was
renamed**, and records `Singapore`; the corpus key for a moved file changed and its stamp did not;
the fingerprint moved. And the guard: an apply started while a filing scan runs is refused with a
sentence, not queued.

### 5.6 Refine with Claude — small once §5.4 exists

**On the mapping, never on the apply.** The plan is derived mechanically from the mapping, so by
then there is no judgement left; the judgement is *what should these folders be called* — the one
question the tree cannot answer and a model can.

Reuses `LensWorkspaceView.refineButton`'s **pattern**: the invitation when no key is stored,
`Ask Opus about N folder names` when one is, and the existing spend pre-flight. Not the function —
it is typed to `[FilingSuggestion]` and gated on `filingCloudRefineAvailable` ＋
`canRefineFilingSuggestions`, so "reuse" here means the same slot, the same words and the same
billing sentence over a different payload. Three things it adds:

- **An itemised payload disclosure** — folder paths and candidate vocabularies always; *up to 5 file
  names per folder* as a **toggle** (that is the evidence that settled I-129 vs I-539); file
  contents never.
- **A row-by-row diff against the user's mapping**, each proposal carrying a written justification.
  **`declined` must be a first-class rendered outcome** — a model that answers every row is guessing
  on some of them. A proposal that *reverses* another is shown adjacent and labelled, or a reviewer
  reads it as a bug.
- **No path to the disk that skips the manifest.** Accepting a row edits the mapping; the plan is
  re-derived and reviewed exactly as before.

Deliberately last: a paid pass must not be the only way to get a good answer.

### 5.7 The two states this adds — no work of its own, but they need their own words

The lens's existing three states are distinct on purpose and **none borrows another's words** — *no
profile* means the detectors have nothing to read, *no findings* means they ran and the tree agrees,
a list means it does not. Two more arrive with the work above, and they ship with §5.1 and §5.5
respectively rather than as an item:

- **Planned, not applied.** The finding card carries the plan's ledger inline and its trigger reads
  `Review N operations`. A drafted plan survives the sheet closing **and a re-survey** — it lives in
  the store's `drafts`, keyed on `kind × family`, and an Apply of *another* plan replays its manifest
  onto that key like any other (§5.0). What it does not survive is its family ceasing to exist,
  which the card says.
- **Applied.** *N folders renamed, N files moved, N carried, N collisions kept*, plus `Undo this
  reorganisation` backed by the inverse in the ledger. **The finding is gone because the tree was
  re-read** — §5.5 step 6 re-derives the profile and `filingFolderProfile`'s `didSet` drops the
  cache — never because it was marked done. Those are different states and only one of them is
  true, and with the decision taken the true one is now buildable. If step 6 fails (the walk was
  refused, the write failed) the card says *applied; the survey could not be refreshed* and keeps
  the finding — a third sentence, not a borrowed one.
- **Undone.** A fourth, from the ledger: the inverse ran, the profile was re-pointed to
  `derivedFrom`, and the finding is back because it is true again. It shares the Applied card's
  shape with the verbs reversed and never pretends the tree was untouched: a file that had moved on
  and was skipped is named.

### 5.8 Where the code goes — so the first branch does not have to decide it

| Piece | Module / file | Notes |
|---|---|---|
| `FindingKind`, the composite `id`, the seven detectors | `Sync` — `StructureDivergence.swift` grows a sibling per detector (`StructureBacklog.swift`, `StructureDeadWeight.swift`, …) behind one `StructureDetectors.run(profile:scope:)` | `structureFindings` keeps its memo; the cache key gains the scope. Pure functions of the profile, like the one that ships. |
| `RestructureStore` (§5.0) | `Sync` — `RestructureStore.swift`, one file, `Codable`, atomic write, `schemaVersion` | Loaded where `PeopleStore` is loaded, in `MacApp/SyncCloudApp.swift`'s profile block. |
| `RestructureMapping`, `RestructureManifest`, `RestructureLedger` (§5.4) | `Sync` — `RestructurePlan.swift` | Mapping → manifest is a pure function; the ledger is a pure function of the manifest; the inverse is a pure function of the manifest. All three testable with no disk. |
| Apply, Undo, verify, re-derive, replay (§5.5) | `Sync` — `FileSyncManager+Restructure.swift`, beside `+FilingRename` | Uses the primitives named in Context; adds `FilingProfileStore.writeDerivedProfile(_:replacing:)` (new id, provenance, re-point, old kept) and `FolderProfile.derivedBy` / `derivedFrom` (optional, so every existing file decodes). |
| The cards, the plan sheet, the mapping editor, the removal sheet, the ledger card | `FileExplorer` — `RestructureLens.swift` (cards), `RestructurePlanSheet.swift`, `RestructureRemovalSheet.swift` | Same lens, same `OrganizeScope`; the sheet is modal over the lens. Extracted rules (`cleanTitle`, `revealTitle`, `surveyNoteText`) already show the pattern: pure static text rules, tested without a view. |
| Host wiring | `MacApp/ContentView…` — `onPlan`, `onApply`, `onUndo`, `onScaffold` beside `onReveal` | `MacApp` is compiled only by CI's second step and holds no unit tests of its own; keep every rule out of it and on the types. |
| Fixtures | `Modules/Sync/Tests/Sync/Fixtures/restructure-flagship.json`, `restructure-immigration-oracle.json` | Folder names and counts lifted from the live profile and the 6 Aug log; **no file names, no content**. In-repo, so CI runs them — the machine-pinned ground-truth suite is the wrong place for a release gate. |

---

### 5.9 Duplicated taxonomy — the eighth detector, and it is newly unblocked

**Held back deliberately, and the reason has now expired.** Backlog item 20 kept this one out of the
set because it must not ship on **name** evidence: matching siblings by their child names is
dominated by correct parallels on this tree — Vanguard's Roth and Traditional IRAs, four Chase
accounts each foldered by year, `PFL - Mother` beside `SDI - Mother`. **Identical sibling structure
is usually a sign of health.**

What separates the real case — `Work/Archive/Acme/Compensation/` holding both `Forms/` and
`Income Tax/`, each with the same three form folders — is that **the same documents sit in both**.
That is a content claim, and the evidence for it did not exist when the detector was deferred.
**It does now:** item 18 shipped the PDF content fingerprint, and its `.sameText` pass already groups
both halves of the `Form 1095-C` pair across `Work/Archive/Acme/Compensation/Forms/` and
`Finance/US/Income Tax/2016/Forms/`. Backlog item 20 records the unblocking; nothing has been built
on it.

What remains is **reading those groups as a statement about the two folders rather than about the
two files**: two folders are duplicated taxonomy when a material share of their contents are
`.sameText` partners of each other, not merely when their child names agree.

- **It is the one detector that needs the duplicate scan**, so it is the one that can be *stale* —
  every other detector here is a pure function of the profile in memory. It reports only when a
  duplicate scan has run over both folders, and says so when it has not.
- **Unmeasured here, deliberately.** The yield cannot be derived from `folder-profile.json` the way
  the other seven were; it needs a scan. **Do not put a number in a mockup for it** until one has
  run — that is the trap the crowding counts fell into.
- **Its fix is a merge**, so it inherits §5.4 whole.

**Schedule it last of the detectors**, after §5.2's seven, because it is the only one that can be
wrong for a reason outside itself.

*(2026-08-28: shipped as `StructureDuplicatedTaxonomy` — two profile-known, non-nested folders
with **≥3 distinct `.sameText` documents** spanning them, where that count is **≥half the smaller
folder's files** (the archive-absorbs-everything guard). Findings join `visibleStructureFindings`
beside the profile-pure set but are computed off `duplicateGroups`' own publish cycle, so a scan
finishing never invalidates the profile memo; with no scan the lens says the findings are absent,
not clean. Yield on this tree still unmeasured, as ordered — it needs a scan, and no number goes
anywhere until one has run. The card reports both branches; wiring its merge into §5.4's sheet
waits for the pair→mapping flow.)*

*(2026-08-28, proposal O18 — **the measurement was attempted and is BLOCKED, and the merge stays
unwired.** `DuplicatedTaxonomyMeasurementTests` is the scan: a real walk of the profile's root fed
to `DuplicateFinder.findGroups` with the persisted content-hash and content-fingerprint indexes,
then this detector over the groups, sweeping the share threshold. It cannot run from a terminal
without **Full Disk Access** — `~/Documents` is TCC-protected, and the walker returns an empty tree
with `stalled == false`, which downstream is indistinguishable from a tree with no duplicates. The
first version of that suite printed "0 findings" at every threshold on exactly that basis; it now
refuses to compute anything and says BLOCKED instead, because a permission result wearing a
measurement's clothes is the precise failure the standing order exists to prevent. **Still no
yield number here.**

What IS readable without walking anything is `content-fingerprint-index.json`, and reading the
*shapes* out of it (never the counts — those are the scan's to produce) changed what this detector
looks like it needs. Three shapes are now pinned in `StructureDuplicatedTaxonomyTests`, and two of
them are cases the rule gets **wrong**:

- **Combined statements.** One PDF covering a checking and a savings account, correctly filed
  under both. Every document of the smaller side is a `.sameText` partner of the larger, so the
  rule calls two correct branches a duplicated taxonomy. This is the *content* version of the
  name-parallel trap the detector was designed around — and it clears **every** value of the share
  threshold from a fifth to the whole folder, so **the open question below is answered in the
  negative: the share is not the discriminator, and no tuning of `minimumShare` separates these.**
- **An inbox staging folder.** `TODO` holding copies of what has just been filed. Fires, dissolves
  when the staging copies are cleared, and is not two taxonomies.
- **A petition packet** — pay statements copied into an immigration filing. The closest thing on
  the tree to the real case, and arguably still correct filing.

**Which is why the merge is not wired.** O18's plan was measurement then merge; on this evidence
`Plan…` on the top-ranked pair would offer to merge two bank accounts' folders. Whatever unblocks
this detector is a rule that can tell "the same document legitimately belongs in both" from "these
are two taxonomies", and that rule does not exist yet. `RestructurePlanRouting` continues to return
nil for `.duplicatedTaxonomy`, now for a measured reason rather than a pending one.)*

### 5.10 Getting to a finding on purpose — and from the command line

The lens is a **reporting** surface: it is found by opening Organize, and that is right, because a
check you have to remember to run is a check nobody runs. But Backlog item 20 also names three
**deliberate** routes into it, and none of them exists:

| Route | What it does | Where |
|---|---|---|
| **The palette** | `⌘K` → *Restructure this folder* — the aim is the folder you are standing in | Backlog item 14, and the palette shipped in 4.x |
| **A folder row's context menu** | *Check this folder's shape* on any row, in Browse or Compare | the row menu already carries a dozen verbs |
| **A Home tile** | the one-screen answer names Restructure when it has findings | Backlog item 16, unbuilt |

Only the first two are v5.0's; the Home tile arrives with the workspace that owns it and is listed
here so nobody builds a third route by accident.

*(2026-08-28: both routes shipped, under ONE name — the palette entry wears the row menu's exact
words, "Check This Folder's Shape", not the "Restructure this folder" drafted above. The palette
law wants a palette action to mirror a menu item, and two names for one verb across two surfaces
was the drift it exists to prevent; the row menu's verb won because it says what the click does.)*

**And from a terminal:** `synccloud restructure --json`, which is §13 — worth building *with* §5.2
rather than after it, for the reason given there.

## 6. The document survey, run in the background

**Two halves — and the first one shipped on 2026-08-20, while this file said it had not.**

This item spent every draft conflating two things a fresh machine lacks, and they are not the same
size:

| Half | What it is | Cost | State |
|---|---|---|---|
| **The folder profile** | a tree *walk* — names, counts, the roster, the confirmed jurisdiction values. **All Restructure reads.** | seconds; no document opened | **shipped** — see below |
| **The document survey** | the corpus and the memory, read from page one of ~11,000 files. What the **router** wants; Restructure never reads it. | hours, background, resumable | **not built — this is what §6 now is** |

**What shipped.** `FileSyncManager+FolderWalk.swift` — `deriveFolderProfile(root:)` walks, builds
through `FolderSurveyBuilder`, writes through the store's first-write path and reports what it did;
`proposePlaces(root:)` supplies the jurisdiction candidates with their evidence. Setup grew a
**Folders step** (`e52076eb`) that picks a root, offers those candidates as chips with **nothing
pre-ticked**, and runs the walk on a button. `FilingArtifacts.attach(to:)` was extracted so a profile
the user just wrote takes effect **without a relaunch**. The measurement that settled the chips is
worth keeping: used as-is the proposals agree with the hand-built profile on **83.2%** of folders and
every point of that gap is an invention (`EMP` an employer, `IT` a department, `PRD` a product
stage); handed only the *confirmed* values the same code is right about **100%**.

**So the sentence this section opened with for eight days is no longer true.** A machine that has
never been surveyed is no longer shut out of Restructure — it runs setup, confirms a few places, and
has a profile. What it still has no route to is **routing**: the corpus and memory behind every
count the filing lenses print.

**What that leaves for §6**, and it is all of the hard part: the pass itself. Everything below this
line — the PDFKit serial lane, the checkpoint that must never be mistaken for a corpus, pause and
resume across a quit, throttling behind the user's own work — is unchanged and unbuilt. The setup
dialog described next is **partly shipped**: its root picker and its Places chips exist; its
*document survey* half does not, and that is the sheet that still has to be designed.

**§5.5 step 6 shares this code.** Re-deriving the profile after a landing is the same walk with a
different trigger, so whichever of the two lands second inherits a path that has already run for
real.

**What it is:** an OS-indexer-shaped pass. The user agrees once, in a dialog, and then it runs in the
background — non-blocking, resumable across quits, throttled behind their own work. **It is
acceptable for this to take a long time; it is not acceptable for it to make the app feel slow.**
Every constraint below is that sentence taken literally.

### The setup dialog — Fig. 25, and what of it already exists

Asks only what a walk cannot compute, and nothing else:

- **The tree root.** What the profile records as the tree it describes. `FolderSurveyBuilder.build`
  takes it as a parameter, never touches it on disk and never parses it, so this is a plain folder
  choice with no inference behind it.
- **The household roster.** The person axis and the `person-bucket` role are read off
  `PersonRegistry`, and with no roster both are simply absent — no folder is misattributed for want
  of one, but none is attributed either. Reuses the People list Settings already ships
  (`PeopleSettingsTab` / `PeopleList`, `Modules/Settings/Sources/Settings/SettingsView.swift:2255`)
  and the `people.json` `PeopleStore` already writes. No second roster UI, no second file.
- **The jurisdiction values — inferred and confirmed.** `JurisdictionCandidates.propose` supplies
  the list *with its evidence*: the distinct parents each value appears under, and the number of
  folders it would change. The user ticks the real ones. **Nothing is pre-ticked** — the rule is
  tuned to offer `EMP` rather than to be right about it — and there is a free-text row to **add**
  one, because that is the only way `Singapore` can ever be recorded (§4.2).

Fig. 25 is that dialog as a sheet over Organize: the tree at the top and the household under it,
both stated rather than asked, each with a quiet *Change…* / *Edit…* — they are confirmations of
what the app already holds. Then the one thing it cannot decide alone, under the heading *Places*:
the proposals as tick chips, `US` and `IN` ticked and `EMP`, `IT` and `PRD` not, with an *Add…*
for the value the rule cannot reach. Pre-ticking is the point — the user is correcting a list, not
composing one, and the line beneath says what leaving one unticked costs, which is nothing but the
axis. Two buttons: *Not now*, and *Start in background*, which is the whole bargain in three words.

### What the code decides about how it runs

Read out of the code on **2026-08-13**.

| Fact | Where | Consequence |
|---|---|---|
| **Every PDFKit parse in the process takes one lane.** `PDFKitSerialAccess` is a single serial `DispatchQueue`, shared by Filing's page-1 reader and the duplicate scan's fingerprint. | `Modules/Sync/Sources/Sync/PDFKitSerialAccess.swift:18–20`; `MacApp/ContentSignalExtractor.swift:192` | **Raising the survey's concurrency buys nothing on the PDF half** — the extra workers queue. Budget it as serial and spend the effort on not reading anything twice. What makes serial affordable is the **early stop**: this reader stops at 600 characters of page 1 (`enoughFromOnePage`), and on a full-tree cold pass that is 78 s serial against 39 s six-at-a-time, where reading all five pages — as `v2.x` still does — is 198 s serial against 106 s. The concurrency is what is unavailable; the early stop is what pays for losing it. |
| **Driving PDFKit concurrently changes the text it returns.** Through this reader over a real 10,286-document tree, six at a time, **0.83% of documents came back with different text than a serial pass**, and concurrent passes disagreed with each other. One mortgage statement: 30 serial reads produced **one** text; adding 180 concurrent reads produced **18 distinct texts**, one of them 1,341 characters against 2,616, and **7 different first-400-character windows** among them. Two *serial* queues race the same way — **4.5–6.3% of documents flapped** with a second serial queue reading alongside, against 0% with the lane to itself. | `MacApp/ContentSignalExtractor.swift:166–191`; `PDFKitSerialAccess.swift:8–10` | The survey takes the lane; it never opens a queue of its own. A corpus built off unstable text is a corpus whose tokens differ between runs, under a verdict key that cannot see the question changed. Non-PDF work (Vision, plain text) stays on `ContentSignalExtractor.workQueue` and is where concurrency is still worth having. |
| **`FileSyncManager` is `@MainActor`.** | `Modules/Sync/Sources/Sync/FileSyncManager.swift:8` | The three expensive steps must be **hoisted off it** — `FilingSurvey.merge`, `FilingSurvey.buildMemory` and `FilingSurveyStore.write`, plus `FolderSurveyBuilder.build`, which is already pure of `FileManager`, `Date()` and defaults precisely so it can run detached. Only publication (`filingMemory`, `filingArtifactFingerprint`, the lifecycle's status) comes back to the actor. |
| **`surveyedRegion` is derived from the corpus, and `documentsToRead` scopes on it.** The region is every ancestor of every surveyed document, closed upwards; `documentsToRead` skips anything outside it. Empty means unscoped, which is the only sensible first run. | `Modules/Sync/Sources/Sync/FilingSurvey.swift:172–186`, `:205–213` | **The sharpest constraint here.** A checkpointed *partial* corpus makes the region cover only what has been read, so a resumed survey **skips the rest of the tree permanently** and reports "0 documents read" — indistinguishable from a settled tree. The same failure is already written down one file over for the empty-tree case (`FileSyncManager+FilingSurvey.swift:96–100`). So progress is checkpointed to a **separate file that `FilingSurveyStore.corpus(id:in:)` never reads**, and `filing-corpus.json` is written once, whole, at the end. `surveyedRegion` stays a pure function of a complete corpus. |
| **The memory is a full rebuild, every time, and its bytes are hashed into the fingerprint.** IDF is corpus-wide: a partial rebuild weighs a new folder's anchors on a different denominator from its neighbours'. And `write` skips an unchanged memory on purpose, because the memory is part of `FilingProfileStore.fingerprint(id:in:)`, which is part of every cached classification's key. | `FilingSurvey.swift:15–17`; `FilingSurveyStore.swift:41–46`; `FileSyncManager+FilingSurvey.swift:195` | **Write the memory once, at the end, from the full corpus.** A mid-survey write would not merely be wasted work: it moves `filingArtifactFingerprint` and throws away every cached verdict — once per checkpoint. |
| **Anti-clobber already has a backstop, and it is not the check.** `writeProfile` throws `WriteRefusal.profileExists` and re-points `profiles.json` only when nothing is active; `resurveyFilingMemory` refuses to run twice over itself. | `FilingProfileStore.swift` (`writeProfile`); `FileSyncManager+FilingSurvey.swift:63` | Refuse to **start** where a profile or a memory exists — a survey that runs for an hour and is refused at the store has wasted the hour. Mint a fresh profile id for the run. Keep the store's refusal anyway: it is what makes the check's absence a bug rather than a disaster. |
| **The signals to throttle on already exist.** `isVerifyAllRunning` and `activeFileOperationsCount` on the manager, and six `ScanLifecycle.isRunning` flags — duplicates, storage lens, names, filing, filing survey, automations dry run. | `FileSyncManager.swift:1565`, `:1624`, and `:367`, `:415`, `:448`, `:493`, `:504`, `:678` | Yield to all of them, and **pause rather than cancel** — the corpus is checkpointed, so resuming costs nothing and cancelling costs everything already read. Note what does *not* exist: `ScanLifecycle` has `isRunning`, `status` and `hasCompleted` and **no paused state**, so paused is either a status string or the one field this adds. Thermal and low-power are genuinely new surface — **nothing in the repo reads `ProcessInfo.thermalState` or `isLowPowerModeEnabled`** (grepped 2026-08-13, zero hits). |

Fig. 26 is the running state, and it is drawn from Organize with a lens open rather than from the
setup card: the pane navigates, the lens is usable, nothing is disabled and no sheet is up. The
survey reports where every other pass reports — a status line reading *Learning your folders*, a
count of documents read against the total, and *Pause · Stop*. Fig. 27 is the same frame with the
duplicate scan running: the count frozen at what it reached, the line replaced by *Paused while
Duplicates scans*, and *Resumes on its own · Resume now*. That pairing is the honest one to
illustrate — the survey and the duplicate scan are the two heavy readers of the same serial PDFKit
lane, so they would queue into each other and the user's scan is the one that must win. It yields to
`isVerifyAllRunning` and `activeFileOperationsCount` the same way. The two figures differ only in
that strip, deliberately — a paused survey must not look like a stalled one.

### What it costs, measured on the reference tree

A first survey is the unscoped one — with no corpus and no memory the region is empty and
`isInScope` admits everything, which is the only thing it could sensibly do — so it reads **page 1
of ~11,019 files**. That is `FilingSurvey.readableExtensions` (`pdf`, `txt`, `csv`, `jpg`, `jpeg`,
`png`) applied to the reference tree, and it is **93.1% of what the offline builder read**. The
other **816** are Office formats — `.docx`, `.pptx`, `.xlsx`, which go through a helper this app
does not carry — and that is the **largest single loss in a derived survey**: it leaves **143 of
2,306 learned folders with no content at all**. The list is deliberately no *wider* than the
generator's either; adding `.md` looked free and would have queued 1,700 markdown files into the
same IDF.

**~13.8% of reads yield nothing** and are stamped blank so they are never opened again. That blank
entry is not a wasted row; it is the only thing that stops the next survey paying for the same file.

Fig. 28 is the payoff, at one folder, before and after: on the left the shipping `noProfileState`
setup card, samples and all, with **no trigger** — *this tree has no folder survey yet, so there is
nothing to compare* — and on the right the same folder's findings list once the survey has landed.
Fig. 29 is the completion summary: folders profiled, documents read, documents that yielded nothing,
the jurisdiction values that were confirmed, and — stated plainly — the Office formats that were not
read and the folders left without content, because a summary that reports only what it managed reads
as complete when it is not.

### Size — large, and smaller than it was

Two new files in `Sync` (the run's state machine and its checkpoint, which is the file
`corpus(id:in:)` must never read), one sheet in `FileExplorer`, and wiring in `FileSyncManager`,
`RestructureLens` and `ScanLifecycle`. **None of it is derivation, and as of 2026-08-20 none of it
is the profile either** — both shipped. The state machine is the whole of the work: pause, resume
across a quit, and a checkpoint that cannot be mistaken for a corpus. Call it ~700 lines.

---


## 11. Organize reaches the menu bar — small

**Moved here from v4 §10 on 2026-08-20**, renumbered on arrival; the 4.x file keeps a
pointer and its remaining five menu-bar items, which are not Organize's.

**Why:** `⌘3` is the whole of Organize's menu presence. Five lens sections and four verbs that exist
only in a row's context menu — so every Organize action is mouse-only, unlisted in `⌘/`, and
invisible to anyone learning the app from its menus.

**What:** the verbs join **File**; the lens sections become one **View** submenu. **No top-level
Organize menu** — and the reason is worth keeping, because Compare has one: Compare's menu items are
bulk actions on the whole comparison, while Organize's are per-selection verbs on a row, and File is
where per-selection verbs already live. The precedent does not transfer.

**v5.0 adds four more verbs that need homes**, and they should be designed in with the rest rather
than bolted on: `Plan…` (§5.4), `Set up…` (§5.2's scaffold), `Answer…` (§5.3) and
**`Undo this reorganisation`** (§5.5). The last is the interesting one: it is *not* `⌘Z`, it must
never be mistaken for it, and a menu item beside Undo that does something Undo does not is exactly
how it would be. Put it in File, worded as its own sentence, never in Edit.

*(2026-08-28: overtaken in part by the code — `c75927be` gave Organize a top-level menu after this
was written, which supersedes "the verbs join File"; the constraint that survives is "never Edit,
never beside ⌘Z", and a test now pins Edit clean of it. `Undo This Reorganisation` shipped there,
selection-free, acting on the ledger's newest landing. `Plan…` and `Set up…` stay in-lens for now:
as menu verbs they need a selected-folder→finding resolver plus cross-surface sheet routing, and
they land with §5.3's `Answer…` so the selection plumbing is built once, not twice.)*

---

## 12. The two lens-workspace controls that are not what they look like — small

**Moved here from v4 §9 on 2026-08-20** — two of that batch's four items live in
`LensWorkspaceView`, which is Organize's own screen and one §5.1 is already editing. The other two
are Storage's and stayed. **Their specifications stay in the Backlog part's Interface section** — a spec
kept in two places drifts in one of them — so this is the citation and the evidence that both still
apply, re-checked at `e52076eb`.

| Item | Still unbuilt because |
|---|---|
| **Drop the "Identical" badge from the majority row** | the badge still fires on the majority case — `LensWorkspaceView.swift:67` `.identical → "checkmark.seal.fill"`, `:78` `SemanticColor.success` |
| **Make the stat pills the filter** | the pills are still inert and the real filter is still a separate `Picker("Filter", selection: $filter)` |

**Cite the symbol, not the line.** The 4.x file pinned the picker at `:2680`; it is at `:2738` today
and nothing moved but the code above it. A line number in a roadmap is a claim that rots on someone
else's commit.

**One constraint the stat-pill item must not lose:** *not every pill is a subset.* The reclaim
figure, Organize's **reused** count and Storage's freshness marker are **scan-level facts, not
filters**, and they must stay visibly inert — or the header teaches that clicking a pill sometimes
does nothing, which is worse than a header that never invited the click.

**Do these with §5.1**, not separately: it is the same file, the same review, and the same render-it-
and-look-at-it pass.

---

## 13. `synccloud` parity for the Organize lenses — medium

**Cited from Backlog item 6**, scoped to Organize's five *acting* lenses — To File, Duplicates,
Renames, Restructure and Rules. Storage is a sixth lens since the fold but is deliberately outside
this item: it produces a report rather than a change, so CLI parity for it means a different verb
(print an analysis) than the one this item is about (apply what a lens proposes). Its half, and
Backup's, stay in the Backlog part.

**Why:** the CLI does `scan`, `sync` and `providers` — the two-pane story, and nothing since. To
File, Duplicates, Renames, Restructure and Rules are GUI-only, so none of them can be scripted,
scheduled with `launchd`, or run over ssh.

| Command | Shape |
|---|---|
| `synccloud file` | the To File lens. **Not `organize`** — that names the whole workspace and would put the lens-versus-workspace ambiguity back into the public surface |
| `synccloud duplicates --dry-run --json` | report-only by default |
| `synccloud renames --check` | report-only |
| `synccloud restructure --json` | report-only, like the lens |

**The engines are already pure** — `DuplicateFinder`, `FilingEngine`, `NameNormalizer` and the
structure detectors are stateless over a walked tree — so this is command surface and output
shaping, not new logic.

**Where the CLI gets a profile:** exactly where the app does — the profiles directory's
`profiles.json` names the active id, and `folder-profile.json` under it is the input. No walk, no
app running, no new discovery logic; an explicit `--profiles-dir` override exists for pointing the
command at a fixture, which is how the detector suite and the CLI stay comparable.

**Build `restructure --json` with §5.2, and the argument is about testing rather than users.** The
detectors are pure functions of the profile, so a CLI that prints them is the only way to run the
whole set over a real tree without a Mac in front of you. **Every number in this file was produced
that way** — in a throwaway Python re-implementation of the detector's rules, which agreed with the
Swift on the day it was written and could silently drift from it any day after. A `--json`
subcommand retires that re-implementation and makes the next audit a diff instead of a rewrite.

**Everything here stops at report.** No `--apply`, no `--plan`, not in 5.0: §5.5's six invariants
are all about a person reading a manifest before anything moves, and a flag that skips the reading
skips the invariants.

---

## Order (v5)

**§§4–6 are not three projects:** they are the storage under one lens, the plan surface that lens
was shipped without, and the survey without which it has nothing to read — so they run in that
dependency's order. Carried over from the v4 part with its §3 and §1 steps removed; those items
stayed with the 4.x line and are not blocked on anything here, nor anything here on them.

**The build order.** 1–6 are the release; 7 and 8 ship if they are ready; 9 is after the tag.

1. **§5.0** — the kind in `StructureFinding.id` and `restructure.json` with its four sections.
   Small, and everything below keys on it; the stale *two divergent families* in
   `StructureDivergence`'s doc goes in the same commit.
2. **§5.1 + §5.2 + §12** — the scoped read, the crowding strip with all three filters, the
   detectors one at a time (**§4.3 is one of them**; so are the two recovered on 2026-08-20), and
   the **backlog scaffold** with its To File hand-off. §12's two controls are in the same file and
   the same review, so they ride along rather than being scheduled separately. Pure reporting off a
   profile already in memory, plus the one Apply that creates and never moves — which makes it the
   right first landing to prove `enqueueFileOperation`, the ledger and ⌘Z before anything
   destructive exists.
3. **§13's `synccloud restructure --json`** — with 2, not after it. It is what lets the detector set
   be run over a real tree without the app, and it retires the Python re-implementation every number
   in this file came from.
4. **§4.1, last surveyed** — small, self-contained, and the only item here that improves a screen
   v4.0 already ships. Schedulable against anything above or below it.
5. **§5.4 up to `Export plan…`** — the whole plan surface, merges included, with the 6 Aug oracle
   test green before the sheet is wired to anything that writes. Drafts persist from here.
6. **§5.5 in its three stages** — renames and `create-dir`, then moves and merges, then the removal
   step (which also takes the 20 pre-existing empties from §5.2's filter). Every stage ends with
   step 6 — re-derive — and step 7 — replay onto the corpus, memory and store; the first stage is
   the one that proves those two on the real tree. `Undo this reorganisation` ships with stage one.
   **§11 lands with this**, because four of the verbs it gives menu homes to do not exist until
   §5.4 and §5.5 do — and `Undo this reorganisation` is the one that most needs designing into the
   menus rather than beside them.
7. **§5.6, Claude on the mapping** — deliberately late; a paid pass must not be the only way to get
   a good answer. **§5.3, Ask findings** sits beside it: not release-gating, its store already
   exists, one finding on this tree.
8. **§5.9, duplicated taxonomy, and §5.10's two access routes.** The detector is last of the eight
   because it is the only one that can be wrong for a reason outside itself — it reads the duplicate
   scan, so it can be *stale*. The palette entry and the row-menu verb are an afternoon each and
   want §11's verbs to already exist.
9. **§6, the document survey** — after the tag. **Its profile half shipped on 2026-08-20** and is no
   longer part of this; what remains is the hours-long content pass the router wants, which nothing
   in 1–8 reads or waits on. §13's other commands (`file`, `duplicates`, `renames`) go here too, or
   earlier on their own merits.

**What "ready for implementation" means for each of 1–6**: the item names its files, its store
key, its proof, and the number it will print — and where the number was measured rather than
designed, the measurement is dated. An item that fails that bar goes back to this file before it
goes to a branch.

---

## Open questions (v5)

- **§6: stopgap or replacement?** Settled further again by the walk shipping on 2026-08-20. The
  derivation is not a degraded stopgap — role, anchors and axes agree at .997–1.000 and Restructure
  cannot tell the two profiles apart — and the jurisdiction vocabulary, the one thing that could not
  be mined, is now **asked** in setup: proposals used as-is agree on 83.2% of folders, confirmed
  proposals on 100%. What stays hand-built is `naming` and `folderSemantics`, which nothing decodes.
  **The open half is unchanged and still needs a second tree:** whether that is enough to stop
  maintaining the offline builder at all.
- ~~**§6: should the survey offer itself unprompted on a large unsurveyed tree?**~~ **Half of it is
  answered by where the walk landed.** Setup asks, once, with the three answers it cannot guess in
  front of the user — so a fresh machine no longer reaches Restructure with nothing and no
  explanation. What is still open is the *document* survey, and the recommendation stands unchanged
  for it: **offer it in the lens and in Organize's overview, never start it**, because an
  hours-long background pass the user did not ask for is exactly what the *"never make the app feel
  slow"* rule exists to protect.
- **§5.3: what rule detects an Ask-shaped disagreement?** The sheet, the store and the answer's
  lifetime are specified; the detector is not, and the one known instance (`Health/Kaiser - PG&E`
  vs `Health/Medical/Kaiser`) is not enough to derive a rule from. Needs a candidate rule dry-run
  against the live profile — with the silence bar the shape detector set — before the sheet is
  worth building.
  *(2026-08-28: the dry-run ran, and the answer is stronger than "not yet" — the one known
  instance NO LONGER EXISTS. `Health/Kaiser - PG&E` is gone from the reference tree; only
  `Health/Medical/Kaiser` remains, so the disagreement was resolved by hand sometime before the
  fixture was cut. The candidate rule probed — a letter-bearing compound name (`X - Y`) whose left
  part is another folder's full name in a different branch — fires 4 times on the tree, and every
  hit is a generic-token false positive (`TODO - May 2025` against three `TODO` inboxes,
  `Plan - EMP` against `Stock Options/Plan`, `DMV - Father` against `Keys/DMV`). Zero ground
  truth plus an all-noise candidate means no rule can be designed honestly today: 5.0 ships
  without the Ask detector, exactly the outcome §5.3 sanctioned, and now it loses zero findings
  on this tree rather than one. The `.ask` kind, the store's `answers` section and the identity
  all exist; the next real instance the tree grows is the design input this needs.)*
- ~~**§5.9: what share of shared content makes two folders duplicated taxonomy?**~~ **Answered
  2026-08-28, and the answer is that the share is the wrong question.** The three shapes this
  detector fires on across the reference tree (pinned in `StructureDuplicatedTaxonomyTests`; see
  §5.9's second dated note) include two false positives that clear **every** threshold from a
  fifth to the whole folder — a bank statement covering two accounts and correctly filed under
  both makes the smaller folder wholly shared. No value of `minimumShare` separates those from a
  real duplicated taxonomy, so tuning it cannot be the fix. Struck rather than deleted because
  the replacement question is the useful part: **what distinguishes "the same document
  legitimately belongs in both folders" from "these are two taxonomies of one thing"?** The
  yield number is still owed and still needs a scan — `DuplicatedTaxonomyMeasurementTests` is
  that scan, blocked on Full Disk Access.
- **§6: what should the Organize overview ledger count while a survey is running?** Making
  Restructure runnable changes `countedLenses` and `pendingPasses`
  (`Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift:418`, `:468`), and a lens that
  is *going to be* runnable in forty minutes is neither of the two states those were written for. A
  badge that appears mid-survey and a pass card that offers a button pointing at an unfinished
  answer are both worse than counting nothing until the survey lands.
- ~~**§5.4: merges.**~~ **Decided 2026-08-16: designed in** — see the decisions block and §5.4's
  definition. Struck rather than deleted because the measurement that forced it is the useful part:
  the flagship family cannot converge without one in either direction, the 6 Aug run performed
  three, and §5.2's one real echo-name hit is a merge.
- ~~**§5.4 / §5.5: can an applied manifest be replayed against the profile?**~~ **Decided
  2026-08-16: the profile is re-derived from a walk after every landing, two judgement fields
  carried over, old file kept, new id, `profiles.json` re-pointed** — §5.5 step 6, with the costs
  written down under it. Replay was rejected because a model of the disk drifts from a tree that is
  edited while work is open; the manifest *is* replayed, but onto the corpus, memory and store keys,
  where there is nothing to walk.
- ~~**§5.4: does a drafted plan survive a re-survey?**~~ **Decided: yes** — it lives in
  `restructure.json`'s `drafts`, keyed on `kind × family`, and the profile can be swapped under it.
  The mockups' *does not survive a re-survey* line is stale; §5.7 carries the new sentence.
- **§5.2: does the crowding strip render in the clean state?** *The tree agrees with itself* and
  *this scope has 86 pass-through folders* are both true at once; the mockups show both. **Leaning
  yes**: the seal answers *shape*, the strip answers *crowding*, and a strip that vanished on a clean
  tree would make the empties filter — the one with a Trash path — unreachable exactly when it is
  the only thing left to do. Decide by rendering it and reading it back, not by argument.
- ~~**§5.2: what happens to the 20 already-empty folders?**~~ **Decided: the third crowding filter,
  §5.5's removal sheet, the 6 Aug date-bucket / category split** — §5.2. Nothing is pre-ticked
  that has a category name; nothing is deleted; folders go to the Trash.
- **§5.5: what does the verifier do on a mismatch?** It reports and does not roll back on its own,
  because a verifier that says everything is broken is usually itself broken (invariant 6, from the
  day it happened). Whether a mismatch should *offer* the inverse on the card, one click away, is
  open — leaning yes, since the inverse is already on disk and offering it costs nothing but a
  button; deciding it needs the first real mismatch to look at.
- **§5.2: should the backlog scaffold create the folders, or only offer To File a plan of them?**
  Written above as *create then hand off*, because an empty scaffold is what the family's other
  members already look like and it is the cheapest possible landing to undo. The alternative — To
  File proposes the destinations without them existing yet — needs To File to create folders on
  accept, which it does not do today. Settle it when the hand-off is wired.
