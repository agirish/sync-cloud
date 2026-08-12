# SyncCloud — v4.x roadmap

**Scope:** interface work for the 4.x line — the **Browse** workspace, starting with Finder-style
tabs, plus pane chrome that spans every workspace. `main` only, with one stated exception: §2's code
exists on `v2.x` too, and that item says what follows from it.

Distinct from `ROADMAP.md` (the standing feature backlog across all surfaces),
`DEFERRED_ENHANCEMENTS.md` (accepted limits) and `REFACTOR.md` (internal shape). An item graduates
out of this file the way it does out of `ROADMAP.md`: deleted when it ships, because git history is
the record.

Designed and mocked on **2026-08-12**; every constraint below was read out of the code that day.

An **illustrated companion** covers §1 and §3 — same decisions, same Order, same Open questions,
with 16 figures in both appearances:
<https://claude.ai/code/artifact/929eb3d2-d381-4fa5-b456-a0a9c9313cea>. §2 carries its own mockup,
linked in that section. **This file is the one that ships** — if a companion disagrees with it, the
companion is the stale one. Figures are cited by number below where one settles a question faster
than a paragraph.

---

## Context every item here inherits

| Fact | Where | Consequence for this file |
|---|---|---|
| **One window, deliberately.** `Window`, not `WindowGroup` — two `ContentView`s would share one `FileSyncManager`. No File ▸ New Window, no ⌘N. | `MacApp/SyncCloudApp.swift:460` | Tabs are the *only* way to hold two places at once. No "Move Tab to New Window", no "Merge All Windows" — do not add menu items pointing at a window the app cannot open. |
| **Browse is one pane at full width.** `paneColumn(isLeft: true)` and nothing beside it. | `MacApp/ContentView+SplitLayout.swift` (`browseLayout`) | A tab is a *location for that pane*, not a second pane. |
| **Two browse paths exist in the whole app** — `leftBrowsePath` / `rightBrowsePath`, swapped wholesale by ⇄. Browse is the left one full width; the Organize rail is the left one narrow; Compare is both. | `Modules/Sync/Sources/Sync/FileSyncManager+Navigation.swift:461` | **Two tab lists, left and right.** Every cross-workspace question follows from this. |
| **The pane header height is pinned at 81pt** so its bottom edge shares the 83.5 rule with Organize's `LensHeaderCard`; cards inset by half of a 5pt gutter. | `Modules/Design/Sources/Design/LiquidGlassStyle.swift:392,410` | Nothing may add a row to the header. New pane chrome is a new card in the gutter rhythm. |
| **There is one `PaneHeader` call site**, and the pane bar's preferences are app-wide `@AppStorage` (`paneBarArrangement`, `paneBarIconSize`). Compare's two panes, Browse's one and the Organize/Storage rail are all that same header. | `MacApp/ContentView.swift:2253` (`paneColumn`) | Anything added to the pane bar is identical in every workspace with no plumbing. But `availableItems` already varies it: **Collapse** only on the Organize/Storage rail, **Preview** only in Columns. |
| **The rail clamps at 220pt**, the workspace at 340. | `MacApp/ContentView+SplitLayout.swift:148` | Any pane-level bar needs a shedding ladder down to 220pt. |
| **⌘1–⌘4 are the workspaces; ⌘[ / ⌘] are pane back/forward; ⌃⇥ is `switchPaneFocus`.** | `Modules/Design/Sources/Design/AppChord.swift` | No ⌘-digit is available. ⌃⇥ is dead in Browse (one pane), so it can be scoped there. |
| **View-menu switches are `Toggle("<Noun>")` with a checkmark** — Hidden Files, Preview Column, Info Inspector, Differences List — and each is `.disabled` when its focused value is `nil`. Flipping titles are reserved for *actions* with two directions (`FoldAllDifferencesCommand`). | `MacApp/ShortcutCommands.swift:494–535` | New view switches are nouns with a tick. No "Show X" / "Hide X" pairs. |
| **Row drag was removed.** `.draggable` competed with the tap gesture that drives column navigation, and cross-pane drag never started. | `Modules/FileExplorer/Sources/FileExplorer/PaneColumnsView.swift:885` | Anything needing file drag reopens that competition. Schedule it separately, with a proof that a click still opens a column. |

---

## 1. Browse tabs

**Why:** Browse holds one location, and the two real jobs — compare two folders in one tree, move
things between two clouds — need two. In a single-window app there is no other mechanism for it.

### The strip

A **34pt card at the top of the pane** (Fig. 2), in the 5pt gutter rhythm, above the pane header.
It belongs to the *pane*, so Browse shows one, Compare shows one per side, and the Organize/Storage
rail shows one; in Browse it looks like window chrome only because there the pane is the window.

Hidden at one tab (Fig. 6, Finder's behaviour), so an install that never opens a second tab is
unchanged. Past the width that fits them, tabs compress to a 96pt floor and the surplus folds behind
a count chevron (Fig. 7).

Rejected, and why, so they are not re-proposed:

- **Inside the pane header** (Fig. 3) — pinned at 81pt, and it shares a line with `LensHeaderCard`.
- **Welded to the toolbar** (Fig. 4) — reads as a second row of the workspace bar, and breaks the
  gap model.
- **In the breadcrumb row's empty width** — that row is *per-tab content*; a switcher cannot live
  inside a description of one of its own items.

### What a tab owns

| Per tab | Not per tab (existing shared keys) |
|---|---|
| provider, browse path + column stack, selection, back/forward history, search query + expanded | view mode (`paneViewModeBrowse`, per surface), hidden files, preview column (`paneColumnShowsPreview`), column width (`paneColumnWidth`) |

The **active** tab *is* that side's pane state, so switching workspace behaves exactly as today.
Parked tabs are inert values.

### Anatomy and rungs

Fig. 5. Provider mark · leaf folder name (middle-truncated) · ✕ on hover or when active. The mark is
load-bearing: two tabs can both read "Documents" from different clouds. Active tab = raised surface
+ 2pt accent rule beneath; **not** the accent fill, which the workspace bar 40pt above already owns.

Three width rungs (Fig. 15), matching the widths the layout produces:

| Rung | Width | Shows |
|---|---|---|
| full | 520+ | tabs at ≤186pt, ＋ at the trailing end |
| compact | ~340 | tabs at a 96pt floor, surplus behind a count chevron |
| chip | 220 (rail) | active tab as a chevron-menu, count for the rest, ＋ |

Tabs never shrink to mark-only — five identical cloud marks name nothing.

### Cold start — exactly one ＋, on the tab bar

At one tab there is no strip and therefore **no ＋ anywhere** (Fig. 9). That is accepted rather than
patched: a ＋ on the pane bar would be redundant the moment the strip appears, and every item on that
bar acts
on the pane's *contents* (view, sort, hidden files, new folder, delete, search) while a new tab
acts on its container. So the pane bar is untouched — no new `PaneBarItem`, no `PaneBarMigration`
step, nothing new in the customize sheet, and the 250pt snapshots and ladder tests keep asserting
the bar they assert today.

Entry points instead: **right-click a folder ▸ Open in New Tab** (Fig. 11 — the discovery route,
and the one that creates a second tab *somewhere different*), **File ▸ New Tab (⌘T)**, and
**⌘-double-click** a folder row.

⌘T opens the **current folder**, and the control says so ("New tab here"), because the result is two
tabs with the same name (Fig. 10) and the strip's arrival is the only feedback. Opening at the
provider root would look more different and throw away the folder you pressed ⌘T from.

**Trade to accept with open eyes:** someone who never right-clicks a folder never learns tabs exist.
Finder accepts the same trade. If the feature should announce itself, the lever is shipping
**View ▸ Tab Bar ticked by default** (Fig. 12) — one tab, one ＋, permanently — at the cost of a
39pt row that restates the folder name the header already shows. Recommendation: ship it unticked;
the default is one line to change and the strip already renders correctly at one tab.

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

### Cross-workspace behaviour (Figs. 13–15)

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

Drag files onto a tab (Fig. 8, right — needs the removed row `.draggable`; see the context table),
and dragging a tab out of the window (there is no second window).

---

## 2. Pane bar: Icon and Text

**Why:** the pane bar is glyph-only; Finder's toolbar names its controls. The vocabulary already
exists — `PaneBarItem.displayName` is what the ⋯ menu and the customize palette already show — so this
is layout work, not naming work.

**Shape:** Finder's three modes — **Icon and Text** (the new default) / **Icon Only** / **Text Only** —
as an inline `Picker` in the bar's right-click menu beside the existing Icon Size picker. Menu only,
as in Finder; nothing in Settings.

Mockup and measured constraints: <https://claude.ai/code/artifact/6b716126-171c-45a8-8a53-4977986571f3>

### It fits the pinned header with nothing to spare

| | |
|---|---|
| **Row height** | 20pt pill + 2pt + 12pt title = **34pt**, which is exactly the provider capsule's 34pt. The header stays 81pt and the 83.5 line holds. |
| **The one break** | `viewMode` wears a 3pt capsule ground (26pt) → 40pt titled. **Titled, the ground goes** and the shared title groups its two segments, as Finder does. Most fragile part of the change. |
| **Width** | the default 11-item bar goes **453pt → 537pt**. A 640pt pane has ~508pt of track, so two items fold into ⋯; a 900pt Browse pane fits everything. |
| **Short titles** | the bar needs a `barTitle` separate from `displayName` — "Collapse Pane" is 68pt of text under a 33pt pill. Palette and ⋯ menu keep the long name. |

Titles shed **all together as one rung**, ahead of the step down to `.mini` glyphs — the rule
`WorkspaceBarMetrics` already applies to the workspace bar, for the reason written down there: a bar
where some items are words and others are glyphs reads as two controls.

The other header on the same 83.5 line — Organize/Storage's `LensHeaderCard` — already draws
icon+text and sheds its text as it narrows (`HeaderLadder`). Titles make the two agree.

### Text Only: three things the glyph is currently doing

| | |
|---|---|
| **Hidden Files** | swaps `eye` ↔ `eye.slash` to carry its own state. A fixed word carries none of it, so the title has to swap too — both sentences already exist in the tooltip. |
| **Scan → Stop** | the word swap survives; the spinning arrow does not. The title becomes a sixth member of `ScanRungMode`, which already resolves the five differing properties in one place. |
| **`PaneNavChrome`** | takes an `Image` and applies ink, font and pill to it. It has to wrap a label of either kind, or Delete's red lands at the wrong level — recorded there as a measured bug ("painted zero red pixels"). |

View and Preview carry their state in the fill, which survives text-only untouched.

### Prep

1. **The ladder needs the font scale.** `PaneBarLayout.width(of:)` and `PaneBarLadder` are constant
   arithmetic with no `scale`; titles are measured type and the app scales its own. `PaneHeader`
   already reads `@Environment(\.appFontScale)` and never passes it down. `HeaderLadder` is the
   working precedent — a text-carrying ladder priced from `Design.LabelMetrics`.
2. **One more rung, and the searched ladder must grow with it.** Icon+Text → Icon Only sits ahead of
   the `.mini` step, so `terminal` grows by one and `PaneBarLadder.searchedSlotCount` (`maxItems + 1`)
   becomes `maxItems + 2` — and `PaneHeader.searchedLadder` must declare one more **literal** child,
   because a `ForEach` inside `ViewThatFits` collapses to a single child.
   `theSearchedLadderDeclaresOneChildPerSlot` catches it.
3. **Text Only cannot take that rung** — shedding text leaves an empty pill, so it folds into ⋯
   straight away. `maxDepth` becomes mode-aware.
4. **Re-baseline.** `DashboardSnapshotTests` holds three `PaneHeader` reference images (560 / 400 /
   250) × light+dark, machine-pinned; `PaneHeaderHeightTests`, `PaneBarCanvasTests` and
   `PaneBarInkContrastTests` all build the default bar.
5. **`ShortcutKeycapFitTests` needs its premise restated**, not just re-run: it measures the ⌥-keycap's
   overhang against the *pill* width, and a titled item's box is wider than its pill.

### The one item here whose code `v2.x` carries

`LabelMetrics.swift` and `LiquidGlassStyle.swift` are byte-identical across the lines;
`PaneBarArrangement.swift` differs by 116 lines and `DashboardViews.swift` by 583, and `v2.x`'s bar has
no Search and no Delete (a 9-item default, so titles fit it more easily). By `CLAUDE.md` this is a
minor feature on code the maintenance line carries, so it lands on `v2.x` first and is **ported** —
not cherry-picked — to `main`. Settle whether `v2.x` is still open before starting, not after.

---

## 3. Finder borrowings, ranked

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
4. **Pane bar titles** — independent of all of the above and schedulable whenever; it touches the bar
   and the ladder, and nothing tabs touch.
5. Everything else on its own merits; drop-on-tab last.

## Open questions

- Ship `View ▸ Tab Bar` ticked or unticked by default (see *Cold start*).
- Whether ⋯ takes a title in the titled bar. Finder's » does not; recommendation: leave it unlabelled
  and centred on the pill row.
- Whether `v2.x` is still open when §2 is picked up — it decides which line that work starts on.
- Whether the tab bar's tick is one app-wide preference or per pane. App-wide matches the other
  reading preferences (`paneColumnShowsPreview`); per pane matches `paneViewModeBrowse`.
- Whether a tab shows a scan/download spinner when work is running in a folder it is not showing.
