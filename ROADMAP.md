# SyncCloud — Feature Roadmap

A prioritized list of high-impact features to add to SyncCloud, based on the current codebase (two-pane file sync, provider sidebar, diff-by-date/size, copy/move/delete, undo, bulk sync).

Items 1–10 are the original list. **Status was re-checked against the code on 2026-07-25** — four
of them have shipped in whole or in part since, and the per-item notes below say what actually
landed and what is left. Items 11–16 were added by that same pass.

Distinct from `DEFERRED_ENHANCEMENTS.md` (hardening/coverage consciously punted) and `REFACTOR.md`
(internal shape): this is **net-new user-facing capability**.

---

## 1. **Content-based diff (checksum/hash)**

**Why:** Differences are currently based only on modification date and size. Files with identical content but different timestamps (e.g. after copy) show as "different"; edited files with same size/date can be missed.

**What:** Add optional content hashing (e.g. SHA-256 or quick hash for large files) in `FileDiffEngine`. Compare by hash when dates/sizes disagree or when "Strict content match" is enabled in settings. Cache hashes in a small SQLite or JSON index keyed by path + mtime/size to avoid re-reading unchanged files.

**Impact:** More reliable sync decisions and fewer false positives/negatives.

**Status (2026-07-25): partially shipped.** SHA-256 hashing exists and is wired in three places —
`FileContentVerifier`, "Verify All" over same-size/different-date pairs, and the
`autoVerifySameSizeDuringScan` setting that runs it during a scan. What is still open is the part
this item was really about: hashing is a *confirmation pass over rows the date/size engine already
produced*, not a comparison mode, and there is no persisted index (`ContentHashCache` is
session-scoped — see `DEFERRED_ENHANCEMENTS.md` #9). Files over 100 MB and cloud-only placeholders
are skipped (`DEFERRED_ENHANCEMENTS.md` #6). **Remaining:** a "strict content match" mode plus the
on-disk index.

---

## 2. **Scheduled / automatic sync**

**Why:** Users must open the app and click Scan to sync. No background or scheduled sync.

**What:** Use `BGAppRefreshTask` or a lightweight timer (e.g. `Timer` when app is in foreground or in background with appropriate entitlements). In Settings, add "Sync interval" (e.g. every 15 min, 1 hr, or manual only) and optional "Sync when folders change" using `DispatchSource` file-system events for the two roots. Run `refreshTreesAndScan` and optionally auto-apply "Copy to Left/Right" for configured pairs.

**Impact:** True "set and forget" sync between e.g. OneDrive and iCloud.

---

## 3. **Sync presets (saved folder pairs)**

**Why:** Users repeatedly pick the same left/right provider and paths. No way to name or quick-switch pairs.

**What:** In Settings (or a dedicated "Presets" section), allow saving current left + right provider and relative paths as a named preset. In the provider sidebar or toolbar, add a dropdown or list to load a preset (sets `leftProviderId`, `rightProviderId`, and focal paths). Persist presets in `UserDefaults` or a small JSON file.

**Impact:** Faster workflow for recurring sync tasks (e.g. "Documents: iCloud ↔ OneDrive").

---

## 4. **Sync history / audit log**

**Why:** Only in-memory operation banners indicate what was synced. No persistent record of what was copied/moved and when.

**What:** Extend the Events/Logger layer (or add a separate "SyncHistory" store) to record each sync action: timestamp, path, action (copy/move), direction (left→right / right→left), and optional checksum. Expose in a "Sync History" window or bottom tab: filterable list with date range and export (CSV/JSON). Optionally "Undo last sync run" by reversing last N operations.

**Impact:** Accountability and easier recovery from mistakes.

**Status (2026-07-25): shipped.** `SyncHistoryStore` + `SyncHistoryRecord` persist every run,
`SyncHistoryView` is the filterable window, `SyncHistoryFilter` does the date/kind filtering,
`SyncHistoryExporter` writes CSV and JSON, and `undoLastSyncRun` reverses the last run. The
Activity Log (`LogViewer`) covers the diagnostic half, paging older sessions out of
`~/sync-cloud.log`. Nothing left from this item as written.

---

## 5. **Include/exclude rules (glob patterns)**

**Why:** Only ad-hoc "ignore paths" exist. No way to sync only `*.pdf` or exclude `node_modules`, `.git`, etc.

**What:** In Settings, add "Sync rules": include/exclude patterns (e.g. `*.pdf`, `**/node_modules`, `.git/**`). In `FileDiffEngine` or tree building, filter nodes by these rules so that differences and tree views only consider matching files. Reuse or mirror `.gitignore`-style parsing for familiarity.

**Impact:** Flexible control over what gets compared and synced (e.g. only documents, exclude build artifacts).

**Status (2026-07-25): shipped, with one gap.** `IgnoreRules` + the `ignorePatterns` setting give
case-insensitive `*` / `?` globs that match **any path component**, so `node_modules` hides it at
any depth and everything inside; patterns are NFC-normalized on both sides so accented names match.
Per-item ignores are a separate, durable layer (`IgnoredItemsStore`, remembered per provider pair).
**Remaining:** patterns are component-scoped only — there is no path-anchored form
(`build/**/*.o`, "only at the root"), and no *include-only* mode ("sync only `*.pdf`").

---

## 6. **Conflict resolution when both sides changed**

**Why:** When the same path exists on both sides with different mtimes, the engine picks "newer wins" or type-based default. There’s no explicit "both modified" state or user choice (keep left, keep right, keep both with rename).

**What:** In `FileDifference`, add a `DifferenceType` such as `bothModified` when both sides have the file and content hash (once implemented) or date/size indicate independent changes. In the Differences list and UI, show "Conflict" and offer: Copy to Left, Copy to Right, Keep Both (copy to one side with a renamed copy, e.g. `file (conflict).ext`). Optionally a simple merge/diff view for text files.

**Impact:** Safer sync when the same file is edited in two places.

**Status (2026-07-25): the resolution half shipped, the detection half did not.** Collisions at
copy time offer Keep Both / Replace / Skip, with a standing default (`ConflictPolicy`, Settings →
Sync → Conflicts) that resolves *file* collisions without prompting while folder collisions always
prompt — replacing a folder discards destination-only contents, which is never automated away
(`DEFERRED_ENHANCEMENTS.md` #1). `.nameConflict` covers same-name/different-spelling pairs.
**Remaining:** there is still no `bothModified` difference type — the engine has no baseline of
"what both sides looked like at last sync", so it cannot tell "they diverged" from "one side is
newer". That needs #1's content index plus a last-synced record (which #4's history now
provides). This is the real prerequisite chain: 1 → 4 → 6.

---

## 7. **In-app diff viewer for text files**

**Why:** Users can open files in external apps but cannot compare file contents inside SyncCloud.

**What:** For selected files in the Differences list or Details tab, if both sides are text (by extension or UTI), show a read-only side-by-side or unified diff (e.g. using `Difference` or a small diff library). Integrate with the existing Quick Look where useful; add a "Compare contents" button that opens the diff view in a sheet or new window.

**Impact:** Quick verification of what actually changed before syncing.

---

## 8. **Search across both panes**

**Why:** Large trees are hard to navigate; there’s no way to find a file by name (or content) across left and right.

**What:** Add a toolbar search field (or Cmd+F). On input, search both `leftTree` and `rightTree` (and optionally `differences`) by file name (substring or fuzzy). Show a dropdown or panel with matching paths and which side(s) they’re on; selecting a result focuses that pane and expands the path. Optional: integrate Spotlight or content search for a second phase.

**Impact:** Much faster navigation in large directory structures.

**Status (2026-07-25): partially shipped.** Every *list* now has search — the Differences table
(`DifferenceSearch` with token chips), Tidy's duplicates (`DuplicateSearch`), the Activity Log
(`LogSearch`), plus the Settings header search — all through one `ExpandingSearchField`.
**Remaining:** the two pane **trees** still have none. That is the harder half (a hit must expand
the path to reveal it, and the panes are `NSTableView`-backed), and it is what this item asked
for.

---

## 9. **Menu bar / status item (quick sync)**

**Why:** Sync requires opening the main window. No at-a-glance status or one-click sync from the menu bar.

**What:** Add a menu bar extra (NSStatusItem): icon reflecting sync status (idle / syncing / error). Menu: "Sync now", "Last synced: …", "Open SyncCloud", "Pause scheduled sync". Reuse existing `FileSyncManager` and refresh logic; optional small preferences for "Show in menu bar" and which preset to run for "Sync now".

**Impact:** Better for power users and scheduled sync (see #2).

---

## 10. **Selective sync (partial sync)**

**Why:** Users might want to sync only certain subfolders of a provider (e.g. only `Documents/Work`, not `Documents/Personal`).

**What:** In provider or preset configuration, allow choosing "Sync root" as a subfolder of the provider root (e.g. `Documents/Work`). Treat that as the effective root for that pane in the comparison and diff. Optionally allow multiple roots per provider (e.g. two presets: one for Work, one for Personal) or a list of "included subpaths" so only those branches are scanned and synced.

**Impact:** Smaller, faster scans and clearer separation of sync contexts.

**Status (2026-07-25): partially shipped.** A provider's root path is editable in Settings, and
drilling into a subfolder scopes the comparison to it (`leftRelativePath` / `rightRelativePath`,
with per-tab focus and navigation history). So "compare only `Documents/Work`" works today — it is
just not *saved*. **Remaining:** naming a scoped context and switching between several, which is
exactly item #3 (Presets). Fold the two together.

---

## 11. **Folder watching → auto-rescan**

**Why:** The app only learns about filesystem changes when the user asks it to. There is no
watcher anywhere in the codebase (no `FSEvents`, no `DispatchSource`, no `NSFilePresenter`), so a
comparison left open goes quietly stale — and cloud providers change these folders constantly,
without the user doing anything.

**What:** An `FSEventStream` on the two focused roots, coalesced (a provider sync burst is many
events), feeding the existing refresh path — `prepareForcedRescan()` already exists as the
supported "this is stale, supersede whatever is in flight" entry point. Show it as a passive
freshness signal first (the `ScanFreshness` badge is already there) with auto-rescan as the opt-in
step, since a rescan mid-review would move rows under the user.

**Impact:** The comparison stops lying. This is also the smaller half of #2 (scheduled sync) and
the honest prerequisite for it — a scheduler that fires on a timer while the tree is stale is
worse than no scheduler.

**Effort:** Medium. **Risk:** Medium — it interacts directly with the freshness machinery
catalogued in `REFACTOR.md` item 8; do that item first or accept a seventh counter.

---

## 12. **CLI parity for the maintenance lenses**

**Why:** The `synccloud` CLI does `scan`, `sync`, and `providers` — the two-pane story only. Every
lens added since (duplicates, Organize/Filing, name normalization, storage) is GUI-only, so none of
it can be scripted, scheduled with `launchd`, or run over ssh.

**What:** `synccloud tidy --dry-run --json`, `synccloud organize`, `synccloud names --check`,
`synccloud storage --json`. The engines are already pure and app-independent (`DuplicateFinder`,
`FilingEngine`, `NameNormalizer`, `StorageLensAnalyzer` are all stateless statics over a walked
tree), so this is command surface and output shaping, not new logic. Read-only/dry-run first; anything that
moves files goes behind an explicit confirm flag, matching `sync`'s existing `--yes`.

**Impact:** Makes the whole app automatable, and delivers most of #2's practical value
(`launchd` + `synccloud sync --yes`) without any in-app scheduler.

**Effort:** Low–Medium. **Risk:** Low (the engines are already tested in isolation).

---

## 13. **Cross-provider duplicate detection**

**Why:** `DuplicateFinder` walks *one* provider tree by design — "duplicate groups never span
providers" is an invariant the Compare handoff relies on. But the single most likely place to be
storing the same 4 GB twice is iCloud *and* OneDrive.

**What:** A Tidy mode that hashes two provider trees and groups across them, with a keeper
heuristic that understands "keep the copy on the provider you chose" rather than "keep the
shallowest path". Needs care: the Compare duplicate-review handoff pins both panes to one provider
today, so a cross-provider group would need the pin logic generalized.

**Impact:** The largest reclaimable-space win the app can offer, and one nothing else on the Mac
does well.

**Effort:** High. **Risk:** Medium–High — it breaks a stated invariant and lands on the destructive
review path.

---

## 14. **Export / import of automations and settings**

**Why:** Automation rules are the user's authored asset — taught by correction over months — and
they live only in `UserDefaults` on one machine. Nothing in the app exports *configuration* (the
one exporter that exists covers sync history); a new Mac starts from nothing, and a defaults domain
is one bad write from empty.

**What:** "Export automations…" / "Import…" writing a versioned JSON bundle (rules, ignore
patterns, provider name/path overrides, conflict policy). `AutomationRule` is already `Codable` and
persisted as JSON, so the model work is done — and `SyncHistoryExporter` is the house pattern to
copy (pure, total, unit-pinned serialization; the only export the app has today, and it covers
history, not configuration). Import must be additive with a preview of what would change — never a
silent replace.

**Impact:** Portability, backup, and a way to share a good rule set.

**Effort:** Low. **Risk:** Low.

---

## 15. **Automations that run without being asked (opt-in)**

**Why:** Automations are deliberately confirm-only — "nothing ever moves without that
confirmation." That is the right default, and it also means the feature named "automation" still
needs a human every time.

**What:** Per-rule "run automatically" for rules the user has confirmed by hand N times, scoped to
one watched folder (a Downloads-style inbox), always undoable as one grouped operation, always
announced by a banner and a history record. Every condition is already a local, deterministic
signal — no classifier is ever consulted on the automation path — so an auto-run rule is
predictable in a way a suggestion is not.

**Impact:** Turns Organize from a chore you remember into one you don't.

**Effort:** Medium. **Risk:** Medium — it moves files unattended. Gate it behind #11's watcher, a
per-rule confirmation count, and a hard "never auto-run a rule whose destination doesn't exist yet"
rule.

---

## 16. **In-place folder Merge as a collision choice**

**Why:** Already specified in detail as `DEFERRED_ENHANCEMENTS.md` #1, and it is the one collision
answer users expect from Finder-adjacent tooling that SyncCloud cannot give: replacing a folder
today swaps it wholesale, discarding destination-only children (recoverably, and with a warning).

**What:** See `DEFERRED_ENHANCEMENTS.md` #1 for the full pickup notes — a `.merge` case on
`CollisionResolution`, a recursive per-child collision path, and its own apply-to-all semantics.

**Impact:** Removes the sharpest edge left in the transfer path.

**Effort:** Medium. **Risk:** Medium (new data path). Listed here as well as in Deferred because it
is genuinely a *feature* people ask for, not only hardening.

---

## Summary table

| # | Feature                    | Effort (rough) | Impact | Status (2026-07-25) |
|---|----------------------------|----------------|--------|---------------------|
| 1 | Content-based diff         | Medium–High    | High   | Partial — hashing + Verify shipped; no strict-match mode, no persisted index |
| 2 | Scheduled / automatic sync | Medium         | High   | Open — see 11 (watching) and 12 (CLI), both cheaper first steps |
| 3 | Sync presets               | Low            | High   | Open — fold with 10 |
| 4 | Sync history / audit log   | Medium         | Medium–High | **Shipped** |
| 5 | Include/exclude rules      | Medium         | High   | **Shipped** — no path-anchored globs, no include-only mode |
| 6 | Conflict resolution        | Medium         | High   | Partial — resolution shipped; `bothModified` detection needs 1 + 4 |
| 7 | In-app diff viewer         | Medium         | Medium | Open |
| 8 | Search across panes        | Low–Medium     | Medium | Partial — every list has search; the pane trees don't |
| 9 | Menu bar status item       | Low–Medium     | Medium | Open |
| 10| Selective sync (partial)   | Low–Medium     | Medium | Partial — scoping works, saving it doesn't (= 3) |
| 11| Folder watching → auto-rescan | Medium      | High   | Open (new) |
| 12| CLI parity for the lenses  | Low–Medium     | High   | Open (new) |
| 13| Cross-provider duplicates  | High           | High   | Open (new) |
| 14| Export/import automations  | Low            | Medium | Open (new) |
| 15| Auto-running automations   | Medium         | Medium–High | Open (new) |
| 16| Folder Merge on collision  | Medium         | Medium | Open (new; = Deferred #1) |

**Where the value is now.** The original read — presets and search as quick wins, content diff and
scheduled sync as the foundation — still holds for what is left, with one correction: **#2 should
not be built directly.** A timer over a tree the app never notices changing is the wrong shape;
**#11 (watching)** makes the comparison honest and **#12 (CLI)** delivers scheduling through
`launchd` for a fraction of the work. Cheapest real wins today: **14** (low effort, protects the
user's own authored data), then **12**. Biggest single payoff, and the biggest risk: **13**.
