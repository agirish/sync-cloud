# SyncCloud — Top 10 Feature Roadmap

A prioritized list of high-impact features to add to SyncCloud, based on the current codebase (two-pane file sync, provider sidebar, diff-by-date/size, copy/move/delete, undo, bulk sync).

---

## 1. **Content-based diff (checksum/hash)**

**Why:** Differences are currently based only on modification date and size. Files with identical content but different timestamps (e.g. after copy) show as "different"; edited files with same size/date can be missed.

**What:** Add optional content hashing (e.g. SHA-256 or quick hash for large files) in `FileDiffEngine`. Compare by hash when dates/sizes disagree or when "Strict content match" is enabled in settings. Cache hashes in a small SQLite or JSON index keyed by path + mtime/size to avoid re-reading unchanged files.

**Impact:** More reliable sync decisions and fewer false positives/negatives.

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

---

## 5. **Include/exclude rules (glob patterns)**

**Why:** Only ad-hoc "ignore paths" exist. No way to sync only `*.pdf` or exclude `node_modules`, `.git`, etc.

**What:** In Settings, add "Sync rules": include/exclude patterns (e.g. `*.pdf`, `**/node_modules`, `.git/**`). In `FileDiffEngine` or tree building, filter nodes by these rules so that differences and tree views only consider matching files. Reuse or mirror `.gitignore`-style parsing for familiarity.

**Impact:** Flexible control over what gets compared and synced (e.g. only documents, exclude build artifacts).

---

## 6. **Conflict resolution when both sides changed**

**Why:** When the same path exists on both sides with different mtimes, the engine picks "newer wins" or type-based default. There’s no explicit "both modified" state or user choice (keep left, keep right, keep both with rename).

**What:** In `FileDifference`, add a `DifferenceType` such as `bothModified` when both sides have the file and content hash (once implemented) or date/size indicate independent changes. In the Differences list and UI, show "Conflict" and offer: Copy to Left, Copy to Right, Keep Both (copy to one side with a renamed copy, e.g. `file (conflict).ext`). Optionally a simple merge/diff view for text files.

**Impact:** Safer sync when the same file is edited in two places.

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

---

## Summary table

| # | Feature                    | Effort (rough) | Impact |
|---|----------------------------|----------------|--------|
| 1 | Content-based diff         | Medium–High     | High   |
| 2 | Scheduled / automatic sync | Medium         | High   |
| 3 | Sync presets               | Low            | High   |
| 4 | Sync history / audit log   | Medium         | Medium–High |
| 5 | Include/exclude rules      | Medium         | High   |
| 6 | Conflict resolution        | Medium         | High   |
| 7 | In-app diff viewer         | Medium         | Medium |
| 8 | Search across panes        | Low–Medium     | Medium |
| 9 | Menu bar status item       | Low–Medium     | Medium |
| 10| Selective sync (partial)   | Low–Medium     | Medium |

Implementing **3 (Presets)** and **8 (Search)** first gives quick wins; **1 (Content diff)** and **2 (Scheduled sync)** form the foundation for a more reliable and hands-off product.
