# SyncCloud — v4.x roadmap

**Scope:** the 4.x line after v4.0 ships — the **Browse** workspace starting with Finder-style tabs
(§1), pane chrome that spans every workspace (§2), the Finder borrowings worth taking (§3), the
storage-layer gaps behind **Organize ▸ Restructure** (§4) and the plan surface that lens was
deliberately shipped without (§5). `main` only, with one stated exception: §2's code exists on
`v2.x` too, and that item says what follows from it.

Distinct from `ROADMAP.md` (the standing feature backlog across all surfaces),
`DEFERRED_ENHANCEMENTS.md` (accepted limits) and `REFACTOR.md` (internal shape). An item graduates
out of this file the way it does out of `ROADMAP.md`: deleted when it ships, because git history is
the record.

Designed and mocked on **2026-08-12**; every constraint below was read out of the code that day.

An **illustrated companion** covers all five items — same decisions, same Order, same Open
questions, with 24 figures in both appearances:
<https://claude.ai/code/artifact/929eb3d2-d381-4fa5-b456-a0a9c9313cea>. **This file is the one that
ships** — if it disagrees with the companion, the companion is the stale one. Figures are cited by
number below where one settles a question faster than a paragraph. Figures are **appended, never
renumbered**: §2's are 17–20 and its section sits after §3 there, §5's are 21–24, so adding either
could not move a number this file already cites. §4's figures are **real renders** through the
shipping `LensSetupCard`, not re-creations, and are unnumbered for that reason.

§5 has a **second companion** — its own eight-screen mockup set, in more detail than the four
figures the main one carries: <https://claude.ai/code/artifact/73b57ccc-56f2-4437-9f2f-a1e85c47a646>.

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

Illustrated in the companion, Figs. 17–20 — the titled bar (17), the shedding rung (18), the mode
menu (19), and the same thing rendered at true point size rather than drawn (20).

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

## 4. Restructure: a cached answer, and no way to build one

**Why:** the lens opens on its setup card and says its answer is cached (shipped `6c56768a`). It
cannot say *how* cached, and on a machine with no folder survey it cannot offer to build one —
because nothing in the app can. Both are storage-layer gaps behind a view that is already done.

### Context

| Fact | Where | Consequence |
|---|---|---|
| **The survey's `generated` stamp is write-only.** It is set on a private `Encodable` struct; `FilingMemory`, the type actually decoded at launch, has no such field. | `Modules/Sync/Sources/Sync/FilingSurveyStore.swift` | Nothing can read a date back today, which is why the card claims coverage only. |
| **And it means "last changed", not "last surveyed"** — the memory is written only when `memory != previousMemory`. | same, `write(corpus:memory:previousMemory:…)` | A survey run this morning on a settled tree leaves last month's stamp. Showing that would be worse than showing nothing. |
| **The corpus is written unconditionally, and is NOT hashed into the fingerprint** — which covers `folder-profile.json`, `filing-memory.json`, `people.json`. | `FilingProfileStore.fingerprint(id:in:)` | The corpus is the one artifact that moves on every survey *and* costs nothing to move. A per-survey timestamp in a hashed file changes `FilingVerdictKey` and re-bills every cached cloud classification. |
| **`resurveyFilingMemory` cannot bootstrap.** It opens with `guard let profileId = filingMemory?.profileId ?? filingFolderProfile?.profileId` and returns `.none` otherwise. | `Modules/Sync/Sources/Sync/FileSyncManager+FilingSurvey.swift` | The half the app owns cannot produce the half it does not, so a fresh machine has no way in. That is why §4.2 is a new builder rather than "just run the re-survey". |
| **`isAxisValued` already falls back to `isBareYear` and `isInboxPath`** — its own doc says the fallbacks exist "for a profile that records no axes at all". | `Modules/Sync/Sources/Sync/StructureDivergence.swift` | A name-only profile is enough to make **this lens** work. What it misses is exact: non-year axis values (`Family/Mom`, `Finance/US`) read as vocabulary, so two eras can look different when they differ only by whose folder they are. |
| **The folder profile is never written**, deliberately: it records judgements about names a walk cannot re-derive, and `role` / `naming` / `anchors` / `acceptsNewFiles` feed the router, the rename planner and the classifier's destination list. | `FilingSurveyStore` (doc), `FilingRouter`, `RenamePlanner` | A name-only profile must never land on top of a hand-built one — it would degrade To File and Renames with nothing failing. |

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

### 4.2 Building a survey in the app — medium

Three new files, ~400 lines. Fires only where `filingFolderProfile == nil`, so it is worth nothing
on a tree that already has one.

1. `FolderSurveyBuilder` (new) — pure `[FileNode] → [String: FolderProfileEntry]`: `path`, counts,
   `acceptsNewFiles` and `role: .inbox` from `isInboxPath`. Leaves `naming`, `anchors` and `axes`
   empty rather than guessing; a wrong `naming` would have the rename pass propose renames toward a
   convention nobody has.
2. `FilingProfileStore` — its first write path. Refuses over an existing profile, writes atomically,
   and touches `profiles.json` only when nothing is active.
3. `FileSyncManager+FolderSurvey` (new) — `buildFolderSurvey(root:)` on its own `ScanLifecycle`,
   which is what gets it progress, cancellation and the same scanning dress as every other pass.
4. `RestructureLens` — the no-survey card gets its trigger back, this time wired to something that
   runs. The card's footnote carries the name-only caveat.

**Tests:** builder purity over a fixture tree; the never-overwrite guard **in both directions** (the
refusing one is what a happy-path test skips); and the degradation asserted rather than described —
same synthetic tree with and without axes, identical findings for a bare-year fixture, *different*
for a person-axis one.

### 4.3 Shadow axis values — medium, independent of both

`StructureDivergence` names this gap and explicitly does not claim it: a year-bearing folder name
that is not a *bare* year (`IRS Docs - 2023`) is treated as a role, so it joins its parent's
vocabulary and makes that parent's shape look unique.

The pattern is on the real tree — `Finance/US/Income Tax` reports three shapes, one of which is
`IRS Docs - 2023, IRS Docs - 2024` beside bare years. Its own detector, not a wider `isBareYear`:
widening that would start swallowing real role names containing digits.

**This is one of §5.2's eight detectors.** Build it once, there — it is listed here because it is
storage-side and needs neither the plan surface nor a scoped read.

---

## 5. Restructure: propose the fix, not just the finding

**Why:** the lens reports and stops. A finding names a disagreement and offers `Reveal`; acting on
one means Finder, by hand, for an afternoon. `ROADMAP.md` item 20 designed the plan surface and
deferred it behind six safety invariants — this is that surface, **scoped to the selected folder**,
plus the detectors it needs to be non-empty at a leaf. §4 is the storage underneath the same lens
and is independent of this.

The flagship case has been accumulating for thirteen years, and the whole flow was **run by hand
once** — `immigration_reorg_2026-08-06.json`: 132 file moves, 4 folder renames, 39 empty-folder
removals, 2 of them mistakes. That log is the worked example, and most of the constraints below are
scars from it.

### Context

| Fact | Where | Consequence |
|---|---|---|
| **Restructure compares sibling *families*.** Under a scope pointed at a leaf the `inside` list is frequently empty and the lens falls back to showing the ancestor's findings, faintly — its own doc calls this out. | `RestructureLens.aboutAncestor` | The detectors that read **one subtree alone** (§5.2) are what make a scoped answer non-empty. Without them the plan surface has nothing to open at the depth people scope to. |
| **One detector of eight shipped.** Dead weight, backlog, mirrored inbox, echo names and shadow axes are designed and unbuilt. | `StructureDivergence` | A 1,200-folder branch with 52 pass-throughs gets the same answer as a tidy one: silence. §4.3 is one of these eight — build it as part of §5.2, not twice. |
| **`memberCount` sums the *vouched* schemes only** — a scheme of one is dropped as drift before the card is drawn. | `StructureFinding.memberCount` | The card reads `12 folders` on a 13-year family and the odd year out is invisible. **A scheme dropped as evidence is still a folder the plan must find a home for.** |
| **The rename pass already owns a review-and-apply path** — per-folder plans, "as one undoable change", and a *left alone, for a stated reason* tail. | `RenamePassLens`, `onApply` | The plan shares it rather than growing a second one. `ROADMAP.md` 20 makes that its scheduling constraint. |
| **The one paid control names its model, names its batch size, and raises a spend pre-flight with a real estimate.** Its branch is *is a key stored*, not *is cloud switched on*. | `LensWorkspaceView.refineButton` | §5.6 reuses it verbatim — same slot, same words up to the ellipsis, same billing sentence. Nothing new to design. |
| **Answers and applied plans both invalidate the check that asked them.** | v3.1 review; `Refine` is already a generation-bumper | §5.3 and §5.5 must bump a structure generation and recompute, or the lens re-suggests what it was just told. |

### 5.1 The scoped read — small

Display-only, no new machinery. Fig. 21.

- Each finding card gains a **kind tag carrying the verb** — *Shape* renames folders, *Series* moves
  files, *Ask* asks — so the class of change is legible before the sheet opens.
- The card states its blast radius: for the flagship family, *a plan here is folder renames, no file
  would move*.
- **The count stops undercounting** (see Context): the subtitle counts the family and renders the
  dropped scheme greyed as drift.
- `Reveal` demotes to a link; `Plan…` takes the primary slot.
- **The rail badge counts only the kinds that carry a plan.** A badge you cannot drive to zero is a
  badge people stop reading, which is why *Ask* is excluded.

### 5.2 The remaining detectors, and the crowding strip — medium

Each is a finding kind before it is a plan, and each is worth landing on its own. Fig. 22.

Detectors, all specified in `ROADMAP.md` 20: **backlog** (the newest instance of a recurring series
has no folders yet — worth saying the month it happens rather than thirteen years later),
**shadow axis** (= §4.3), **echo name** (`PG&E/PGE`), **mirrored inbox** (`Health/TODO/Dental` beside
`Health/Dental`), **dead weight** (52 pass-through folders, 434 single-file leaves).

The crowding strip is the answer to *"it sees a lot of folders"*: three counts above the findings,
each a filter into a list. **Crowding is a property of the scope, not a finding** — always non-zero
on a real tree — so it never takes a badge.

**Only sub-classes with a stated rule get an Apply.** The 434 single-file leaves get a number and
nothing else: a folder can look like debt and be a destination waiting for its next file, and
nothing in its own shape separates the two. That is the same mistake that had
`Supporting Documents/Resume` and `Supporting Docs/HPE/Payslips` put back on 6 Aug.

### 5.3 Ask findings — medium

A finding with **no Apply button**, for a disagreement no fact in the tree settles —
`Health/Kaiser - PG&E` versus `Health/Medical/Kaiser`, coverage-through-an-employer versus care
records. Two answers and a *don't ask again*; the answer is written into the profile's
`folderSemantics` and never asked again, including after a re-survey.

Needs the profile **write** path and the generation bump — which every item after it also needs, so
it is worth doing here rather than inside the plan work.

### 5.4 Choose → map → manifest, with Export and no Apply — large

The whole plan surface, ending in a file rather than in a disk write. Figs. 23–24.

1. **Choose the target shape — nothing pre-selected.** The schemes found, labelled by what they are
   (*the largest group*, *the most recent*), with **Name it myself among them, not behind them**.
   Neither recency nor majority is the authority: the 6 Aug fix went **both ways at once**, because
   H-1B is filed on Form I-129 (a *petition*) and H-4 / H-4 EAD on I-539 / I-765 (*applications*) —
   a fact that exists nowhere in the tree.
2. **Tabulate the family group first** where parallel families share a vocabulary. Fixing H-4 alone
   would have left it disagreeing with its two siblings; laid out as a table the cause was visible
   in one glance (each filing lands flat and is foldered later).
3. **The mapping editor** — one row per distinct source folder name across the family, target
   dropdown, **default keep**, never a guessed mapping. This is where the leverage is: edited once,
   applied to every member. Two sources onto one target inside one year is a **merge** and is
   refused on the row (see Open questions).
4. **The manifest** — ordered typed operations (`create-dir`, `rename-dir`, `move-dir`, `move-file`,
   `keep`), each with its own written justification, and a ledger that separates **files moved from
   files carried** and **folders changed from folders kept**. On the flagship family that reads
   8 renames · 0 files moved · 92 carried · 5 kept.
   **Prefer the rename whenever a mapping is one folder to one folder**: it is atomic, preserves
   file identity and cannot half-finish. The 6 Aug run brought fourteen eras into agreement with
   4 renames carrying 58 files each and moving none.
5. **`Export plan…`** writes the manifest beside the profile in the shape the 6 Aug log used —
   reviewable in a text editor with nothing at risk. This is the natural stopping point: everything
   above is worth landing before any Apply exists.

### 5.5 Apply — large, and the only destructive item here

Shares `RenamePassLens`'s review-and-apply path. **Renames first as their own landing** — the
flagship case needs no file to move — then file moves, then the removal step.

The six invariants from `ROADMAP.md` 20 are the acceptance criteria, three of them rendered on the
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

### 5.6 Refine with Claude — small once §5.4 exists

**On the mapping, never on the apply.** The plan is derived mechanically from the mapping, so by
then there is no judgement left; the judgement is *what should these folders be called* — the one
question the tree cannot answer and a model can.

Reuses `LensWorkspaceView.refineButton` wholesale: the invitation when no key is stored, `Ask Opus about N
folder names` when one is, and the existing spend pre-flight. Three things it adds:

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

---

## Order

**Everything here is post-v4.0.** §4.1 is the only item that improves a screen already shipping.

1. **Tabs**, all three rungs, so Compare and the rail arrive in the same motion rather than as a
   follow-up.
2. **Status bar** — small, and it makes tabs feel finished because each tab then reports its contents.
3. **Sidebar** of pins and recents, ⌘-click opening a new tab.
4. **Pane bar titles** — independent of all of the above and schedulable whenever; it touches the bar
   and the ladder, and nothing tabs touch.
5. **§4.1, last surveyed** — small, self-contained, and the only item on this page that improves a
   screen v4.0 ships. Schedulable against any of the above.
6. **§5.1 + §5.2** — the scoped read and the remaining detectors. Pure reporting off a survey
   already in memory, and §5.1 fixes the leaf-scope emptiness on its own. §4.3 lands here rather
   than separately.
7. **§5.3, then §5.4 up to `Export plan…`** — the whole plan surface with no Apply, reviewable
   against the 6 Aug log with nothing at risk.
8. **§5.5, renames only**, then file moves and the removal step. The first destructive landing in
   the app; it waits on the rename pass's review-and-apply path.
9. **§5.6, Claude on the mapping** — last, deliberately.
10. Everything else on its own merits. **§4.2 when a second machine or a second tree makes it real**
   — it cannot fire on this one; drop-on-tab last.

## Open questions

- Ship `View ▸ Tab Bar` ticked or unticked by default (see *Cold start*).
- Whether ⋯ takes a title in the titled bar. Finder's » does not; recommendation: leave it unlabelled
  and centred on the pill row.
- Whether `v2.x` is still open when §2 is picked up — it decides which line that work starts on.
- Whether the tab bar's tick is one app-wide preference or per pane. App-wide matches the other
  reading preferences (`paneColumnShowsPreview`); per pane matches `paneViewModeBrowse`.
- Whether a tab shows a scan/download spinner when work is running in a folder it is not showing.
- **§4.2: should a name-only survey ever be offered where a hand-built profile exists?** It could
  pick up folders added since — only by overwriting judgements the walk cannot re-derive.
  Recommendation: no; `resurveyFilingMemory` already refreshes the half that is safe to refresh.
- **§4.2: stopgap or replacement?** A stopgap for fresh machines is the ~400 lines above. Replacing
  the offline builder means axis inference, role detection and naming-convention mining in-app —
  a different project, and the reason the profile is hand-built today. Recommendation: stopgap.
- **§5.4: merges.** Two source folders mapping onto one target inside a single year is refused on
  the row rather than designed. A real family will eventually want one, and it is the case where
  *rename* stops being available and files genuinely have to move.
- **§5.4: does a drafted plan survive a re-survey?** The mockups say no and say so on the card. If
  plans are to be kept, they need identity keyed on **detector × folder path** — the same key
  *never suggest this again* needs (`ROADMAP.md` 20), stored beside `folderSemantics`.
- **§5.2: does the crowding strip render in the clean state?** *The tree agrees with itself* and
  *this scope has 52 pass-through folders* are both true at once; the mockups show both, which means
  the seal is no longer the only thing on that screen.
