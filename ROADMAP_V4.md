# SyncCloud — v4.x roadmap

**Scope:** interface work on the **Browse** workspace for the 4.x line, starting with Finder-style
tabs. `main` only — 4.x is the v3 line's successor and `v2.x` carries none of it.

Distinct from `ROADMAP.md` (the standing feature backlog across all surfaces),
`DEFERRED_ENHANCEMENTS.md` (accepted limits) and `REFACTOR.md` (internal shape). An item graduates
out of this file the way it does out of `ROADMAP.md`: deleted when it ships, because git history is
the record.

Designed and mocked on **2026-08-12**; every constraint below was read out of the code that day.
Mockups (16 figures, both appearances): <https://claude.ai/code/artifact/929eb3d2-d381-4fa5-b456-a0a9c9313cea>

---

## Context every item here inherits

| Fact | Where | Consequence for this file |
|---|---|---|
| **One window, deliberately.** `Window`, not `WindowGroup` — two `ContentView`s would share one `FileSyncManager`. No File ▸ New Window, no ⌘N. | `MacApp/SyncCloudApp.swift:460` | Tabs are the *only* way to hold two places at once. No "Move Tab to New Window", no "Merge All Windows" — do not add menu items pointing at a window the app cannot open. |
| **Browse is one pane at full width.** `paneColumn(isLeft: true)` and nothing beside it. | `MacApp/ContentView+SplitLayout.swift` (`browseLayout`) | A tab is a *location for that pane*, not a second pane. |
| **Two browse paths exist in the whole app** — `leftBrowsePath` / `rightBrowsePath`, swapped wholesale by ⇄. Browse is the left one full width; the Organize rail is the left one narrow; Compare is both. | `Modules/Sync/Sources/Sync/FileSyncManager+Navigation.swift:461` | **Two tab lists, left and right.** Every cross-workspace question follows from this. |
| **The pane header height is pinned at 81pt** so its bottom edge shares the 83.5 rule with Organize's `LensHeaderCard`; cards inset by half of a 5pt gutter. | `Modules/Design/Sources/Design/LiquidGlassStyle.swift:392,410` | Nothing may add a row to the header. New pane chrome is a new card in the gutter rhythm. |
| **The rail clamps at 220pt**, the workspace at 340. | `MacApp/ContentView+SplitLayout.swift:148` | Any pane-level bar needs a shedding ladder down to 220pt. |
| **⌘1–⌘4 are the workspaces; ⌘[ / ⌘] are pane back/forward; ⌃⇥ is `switchPaneFocus`.** | `Modules/Design/Sources/Design/AppChord.swift` | No ⌘-digit is available. ⌃⇥ is dead in Browse (one pane), so it can be scoped there. |
| **View-menu switches are `Toggle("<Noun>")` with a checkmark** — Hidden Files, Preview Column, Info Inspector, Differences List — and each is `.disabled` when its focused value is `nil`. Flipping titles are reserved for *actions* with two directions (`FoldAllDifferencesCommand`). | `MacApp/ShortcutCommands.swift:494–535` | New view switches are nouns with a tick. No "Show X" / "Hide X" pairs. |
| **Row drag was removed.** `.draggable` competed with the tap gesture that drives column navigation, and cross-pane drag never started. | `Modules/FileExplorer/Sources/FileExplorer/PaneColumnsView.swift:885` | Anything needing file drag reopens that competition. Schedule it separately, with a proof that a click still opens a column. |

---

## 1. Browse tabs

**Why:** Browse holds one location, and the two real jobs — compare two folders in one tree, move
things between two clouds — need two. In a single-window app there is no other mechanism for it.

### The strip

A **34pt card at the top of the pane**, in the 5pt gutter rhythm, above the pane header. It belongs
to the *pane*, so Browse shows one, Compare shows one per side, and the Organize/Storage rail shows
one; in Browse it looks like window chrome only because there the pane is the window.

Hidden at one tab (Finder's behaviour), so an install that never opens a second tab is unchanged.

Rejected, and why, so they are not re-proposed:

- **Inside the pane header** — the header is pinned at 81pt and shares a line with `LensHeaderCard`.
- **Welded to the toolbar** — reads as a second row of the workspace bar, and breaks the gap model.
- **In the breadcrumb row's empty width** — that row is *per-tab content*; a switcher cannot live
  inside a description of one of its own items.

### What a tab owns

| Per tab | Not per tab (existing shared keys) |
|---|---|
| provider, browse path + column stack, selection, back/forward history, search query + expanded | view mode (`paneViewModeBrowse`, per surface), hidden files, preview column (`paneColumnShowsPreview`), column width (`paneColumnWidth`) |

The **active** tab *is* that side's pane state, so switching workspace behaves exactly as today.
Parked tabs are inert values.

### Anatomy and rungs

Provider mark · leaf folder name (middle-truncated) · ✕ on hover or when active. The mark is
load-bearing: two tabs can both read "Documents" from different clouds. Active tab = raised surface
+ 2pt accent rule beneath; **not** the accent fill, which the workspace bar 40pt above already owns.

Three width rungs, matching the widths the layout produces:

| Rung | Width | Shows |
|---|---|---|
| full | 520+ | tabs at ≤186pt, ＋ at the trailing end |
| compact | ~340 | tabs at a 96pt floor, surplus behind a count chevron |
| chip | 220 (rail) | active tab as a chevron-menu, count for the rest, ＋ |

Tabs never shrink to mark-only — five identical cloud marks name nothing.

### Cold start — exactly one ＋, on the tab bar

At one tab there is no strip and therefore **no ＋ anywhere**. That is accepted rather than patched:
a ＋ on the pane bar would be redundant the moment the strip appears, and every item on that bar acts
on the pane's *contents* (view, sort, hidden files, new folder, delete, search) while a new tab acts
on its container. So the pane bar is untouched — no new `PaneBarItem`, no `PaneBarMigration` step,
nothing new in the customize sheet, and the 250pt snapshots and ladder tests keep asserting the bar
they assert today.

Entry points instead: **right-click a folder ▸ Open in New Tab** (the discovery route, and the one
that creates a second tab *somewhere different*), **File ▸ New Tab (⌘T)**, and **⌘-double-click** a
folder row.

⌘T opens the **current folder**, and the control says so ("New tab here"), because the result is two
tabs with the same name and the strip's arrival is the only feedback. Opening at the provider root
would look more different and throw away the folder you pressed ⌘T from.

**Trade to accept with open eyes:** someone who never right-clicks a folder never learns tabs exist.
Finder accepts the same trade. If the feature should announce itself, the lever is shipping
**View ▸ Tab Bar ticked by default** — one tab, one ＋, permanently — at the cost of a 39pt row that
restates the folder name the header already shows. Recommendation: ship it unticked; the default is
one line to change and the strip already renders correctly at one tab.

### Menus and keyboard

| Chord | Action | Note |
|---|---|---|
| ⌘T | File ▸ New Tab | opens the current folder |
| ⌘W | Close Tab | closes the window on the last tab, as Finder does |
| ⇧⌘] / ⇧⌘[ | next / previous tab | Finder's own mapping; unshifted ⌘[ / ⌘] stay pane back/forward |
| ⌃⇥ / ⌃⇧⇥ | next / previous tab **in Browse only** | `switchPaneFocus` keeps it in Compare, where two panes exist. State the split in the shortcuts sheet. |
| ⇧⌘T | View ▸ **Tab Bar** (checkmark) | one `Toggle("Tab Bar")` — no Show/Hide pair. Ticked **and disabled** while the pane holds a second tab, so it can never hide a strip whose tabs would become unreachable. |
| ⌘-double-click | Open folder in a new tab | plain ⌘-click stays multi-select |
| ⌥-click ✕ | Close other tabs | also in the tab's context menu |
| double-click strip | New tab | the empty stretch needs a `contentShape` to be hit-testable |
| — | Reopen Closed Tab | File-menu item, **no chord** (⇧⌘T is taken above; not an ⌥ chord) |
| — | ⌘1…⌘9 | **unavailable** — the workspaces own every ⌘-digit. Deliberate deviation from Finder and Safari; worth a line in the help. |

Tab context menu: New Tab · Close Tab · Close Other Tabs · Duplicate · Copy Path.

### Cross-workspace behaviour

| Question | Answer |
|---|---|
| Browse → Organize | The rail shows the left list, same active tab, same folder — what the path already does. |
| Browse → Compare | Browse's tabs are the left pane's; the right pane has its own list. |
| ⇄ swap | Swaps the two **lists**, not the two active tabs — it already swaps the paths wholesale. Tooltip needs a line. |
| 🔗 link both | Acts on the two active tabs only. |
| Storage | Rail + lens, same as Organize. |
| Closing the last tab | Never closes a pane. The strip hides; the pane stays. |

### Persistence

One key, `browseTabs` = `[{providerId, relativePath}]`, plus `browseSelectedTab`. Seed from the
stored provider and browse path on first launch, so an upgrading install opens with one tab on the
folder it closed on.

### Out of scope for the first landing

Drag files onto a tab (needs the removed row `.draggable` — see the context table), and dragging a
tab out of the window (there is no second window).

---

## 2. Finder borrowings, ranked

Ordered by value against what Browse already has. Each is independent of tabs unless noted.

| Item | Cost | Where it stands |
|---|---|---|
| **Status bar** (⌘/): item count, selection size, cloud-only count, scan freshness | small | Browse shows none of this; the selection summary is in the Compare-only floating action bar. Highest value per point of work. |
| **↩ renames** | small | Rename is already a row-menu item with a handler; it has no key. |
| **⌘↑ enclosing folder, ⌘↓ open** | small | Back/forward and the breadcrumb exist; "up one level" as a key does not. |
| **Go to Folder** | small | Do not add a sheet — teach ⌘K to accept a typed path. |
| **Pins + recents sidebar** | medium | `FolderJumpStore` already persists pins and tracks session recents per provider root; today they are menu-only. Browse has the width. With tabs: click to switch, ⌘-click for a new tab. **Folders only — the old Left/Right provider sidebar was removed on purpose when the provider became a dropdown.** |
| **⌘C / ⌘V / ⌥⌘V** | medium | No pasteboard code in the app. With tabs this becomes the cross-cloud move: copy in one tab, paste in another. |
| **Gallery view mode** | medium | A third `PaneViewMode` case behind the existing switch; thumbnails are the work. Argue it from the scans folders. |
| **Group by kind / date** | medium | Sort is per pane; grouping does not exist. |
| **Drop files on a tab** | large | Reopens the `.draggable` vs tap-gesture competition. Last. |
| **Tags / coloured labels** | large | Skip. Organize's rules and person machinery already answers "what is this file about"; a parallel labelling system would compete with it. |

---

## Order

1. **Tabs**, all three rungs, so Compare and the rail arrive in the same motion rather than as a
   follow-up.
2. **Status bar** — small, and it makes tabs feel finished because each tab then reports its contents.
3. **Sidebar** of pins and recents, ⌘-click opening a new tab.
4. Everything else on its own merits; drop-on-tab last.

## Open questions

- Ship `View ▸ Tab Bar` ticked or unticked by default (see *Cold start*).
- Whether the tab bar's tick is one app-wide preference or per pane. App-wide matches the other
  reading preferences (`paneColumnShowsPreview`); per pane matches `paneViewModeBrowse`.
- Whether a tab shows a scan/download spinner when work is running in a folder it is not showing.
