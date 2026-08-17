# SyncCloud — v4.x roadmap

**Scope:** the 4.x line after v4.0 ships. **v4.2 is a navigation release.** The toolbar's ⌘K pill
stops being a button and becomes a field you type into (**§7**), and Browse borrows what Finder has
that it does not (**§3**) — tabs gave a pane somewhere to park, and this release is about reaching a
place at all. Beside those sit window chrome that says which window is which (**§8**) and a batch of
small repairs to how already-shipped surfaces read (**§9**). What v4.1 took is recorded as **§1**
(Browse tabs, shipped 2026-08-14, one behaviour still designed and unbuilt) and **§2** (pane-bar
titles, shipped 2026-08-16). `main` only, with one stated exception: §2's code exists on `v2.x` too,
and that item says what follows from it.

**Restructure has moved out, on 2026-08-16.** The storage-layer gaps behind Organize ▸ Restructure,
the plan surface the lens was shipped without, and the first background survey now live in
**`ROADMAP_V5.md`** — moved unchanged, together with the four decisions taken on 2026-08-16 and the
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

Distinct from `ROADMAP.md` (the standing feature backlog across all surfaces),
`DEFERRED_ENHANCEMENTS.md` (accepted limits) and `REFACTOR.md` (internal shape). An item graduates
out of this file the way it does out of `ROADMAP.md`: deleted when it ships, because git history is
the record. §9's items are the exception and are **cited, not restated** — their specifications live
in `ROADMAP.md`'s Interface section and a spec kept in two places drifts in one of them.

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
| **The status bar's chord** | **⌘/ , matching Finder.** `shortcutsReference` gives it up and keeps **no chord at all** — Help ▸ Keyboard Shortcuts stays exactly where it is. | ⌘/ is `shortcutsReference` today (`AppChord.swift:51`). Two replacements were proposed and both are wrong: **⇧⌘/ is ⌘?**, which Help already holds, and **⌥⌘/ is forbidden outright** — see the two notes below. |

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
chord: under this very decision ⌘/ becomes the status bar, so the keystroke a user is most likely
to press while reading the reveal is the one that would have opened the shortcuts reference instead.
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
goes with it. The card lists workspaces, sources, folders and actions at 620pt; a 440pt dropdown
lists the same groups in a narrower column. Before §7 lands, walk the palette's route table and
confirm every entry still has a door — this is the release's one silent-removal risk.

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
already ranked in §3. What follows is the one piece of *design* still open.

### Mirroring tab *switches* on linked panes — not built

The 🔗 link now carries into **opening** a tab: right-click ▸ Open in New Tab, ⌘-double-click and
⌘T each open on the sibling too, on the same predicate a mirrored column drill uses
(`layoutMode == .compare && (isLinked || ⌥)`), pruned to the deepest folder the sibling genuinely
has. Switching between tabs does **not** mirror, so two panes that grew their tabs together
diverge at the first ⇧⌘] — which is the state the link exists to prevent.

Deferred rather than skipped, because it needs a **pairing rule** and the cheap one is wrong:

- **By index** — switch the sibling to the same position. One line, and it silently desyncs: a
  close, a reorder, a pin or a single unlinked ⌘T on either side shifts one list against the other,
  and from then on every switch sends the sibling somewhere unrelated with nothing on screen
  saying so.
- **By path** — switch the sibling to *its* tab on the same relative folder. Correct when there is
  one, undefined when there is not: open a new tab there (a switch that silently grows a list), or
  leave the sibling where it is (the panes stay out of step, which is what this was to fix).
- **By pairing** — record a shared id when a tab is mirrored into existence, and switch by it.
  The only one that survives divergence, and the only one that adds persisted state to a format
  that deliberately stores `{providerId, relativePath, pinned}` and nothing session-shaped.

Two questions come with it, and they are why this is not a follow-up commit:

- **Does closing mirror too?** If switches pair but closes do not, the pairing is stale the first
  time a paired tab is closed on one side, and a switch then has to decide between an id that names
  nothing and falling back to a rule already rejected above.
- **What does the sibling do when its paired tab's folder has since gone?** The open-mirror prunes
  at creation time; a *switch* arrives at a tab that already names a folder, so pruning there would
  quietly move a tab off the location its chip claims — the one thing `PaneTabChips` is built to
  prevent.

Recommendation: **pairing, with closes mirrored**, and only once someone has run linked Compare
long enough to say whether an unmirrored switch is actually a nuisance. Nothing about the shipped
behaviour has to change to add it — `mirrorOpenInNewTab` is where a pair id would be minted.

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
| **Status bar** (⌘/) — item count, selection size, cloud-only count, scan freshness | small | Zero `statusBar` hits anywhere. Highest value per point of work. |
| **↩ renames** | small | Rename is a row-menu item with a working handler and no key. |
| **⌘↑ enclosing folder, ⌘↓ open** | small | No `enclosingFolder` / `goUp` in the tree. Both chords free. |
| **Go to Folder** | small | No path parsing in the palette. Do not add a sheet — teach §7's field to accept a typed path. |
| **Pins + recents sidebar** | medium | `FolderJumpStore` persists pins, **not** recents — see the correction below. Menu-only today. |
| **⌘C / ⌘V / ⌥⌘V** ⚠️ | medium | No file pasteboard. All eight `NSPasteboard` sites copy a path *as text*. **⌥⌘V is barred by the ⌥ ban above — spelling unresolved.** |
| **Gallery view mode** | large | `PaneViewMode` has two cases; a third is free, thumbnails are the job. |
| **Group by kind / date** | large | Sort is per-pane `KeyPathComparator`; grouping does not exist. |
| **Drop files on a tab** | large | Needs row drag re-added. **The recorded reason for ranking it last is stale** — see below. |
| **Tags / coloured labels** | large | Ranked *skip* on merit. Scheduled anyway; the objection is unanswered and is restated below. |

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

- **A status bar, on ⌘/.** Item count, selection size, cloud-only count, scan freshness. Browse
  shows none of this: the selection summary lives in the Compare-only floating action bar, so
  browsing a single tree tells you nothing about what you have selected. Two inherited constraints —
  the View-menu entry is a `Toggle` with a noun and a tick, never a Show/Hide pair
  (`ShortcutCommands.swift:494–535`), and it sheds cleanly down to the 220pt rail clamp. In Compare
  it must say which pane it is describing, which is the question the per-pane header already answers
  and §8 is trying to make shorter; settle the two together.
- **↩ renames.** The one chord people try first in any file list, and today it does nothing.
- **⌘↑ / ⌘↓.** Back and forward exist as ⌘[ / ⌘], and the breadcrumb is clickable, but "up one
  level" has no key — and back is not the same gesture: it retraces where you have been rather than
  climbing where you are.
- **Go to Folder.** Finder's ⇧⌘G as a behaviour rather than a surface: §7's field accepts a typed
  path, `~/` and `/` included, resolved against the pane's provider roots. Effectively free once §7
  lands, and pointless before it.

### The two mediums

- **Pins and recents, as a sidebar.** The store already answers both questions —
  `pinnedPaths(forRoot:)` and `recentPaths(forRoot:)` are what fill the palette's Folders group — and
  today they are reachable only through a menu. Browse has the width. With tabs it composes: click
  to switch, ⌘-click to open in a new tab. **Folders only** — the old Left/Right provider sidebar was
  removed on purpose when the provider became a dropdown, and this must not quietly bring it back.
- **⌘C / ⌘V / ⌥⌘V.** ⚠️ **The ⌥⌘V spelling is not available** — see the ⌥ ban above: an ⌥-chord
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
- **Tags and coloured labels.** **The objection against this has not been answered, and it should be
  answered before the work starts rather than after.** The standing argument: Organize's rules and
  the person registry already answer "what is this file about", and a parallel labelling system
  competes with them — two places to say the same thing, drifting apart. The honest reconciliation is
  probably that tags are for what the machinery *cannot* infer, a human judgement with no rule behind
  it, and that they must therefore be visible to rules as a condition the way `personIs()` is, rather
  than sitting beside them. If that integration is out of scope, this is a second filing system and
  should stay unbuilt.

---

## 4, 5 and 6 — moved

**Moved to `ROADMAP_V5.md` on 2026-08-16, unchanged.** §4 *Restructure: a cached answer, and no way
to run one*; §5 *Restructure: propose the fix, not just the finding*; §6 *The first survey, run in
the background*. Their figures (21–34), the four decisions taken on 2026-08-16 and the open
questions belonging to them went across too.

**These numbers are not reused** — new work below starts at §7. The reason is the same one that
makes figures append-only: "§4.2 shipped" and "§5.5 step 6" are written in both companions, in
commit messages and in the audit notes, and renumbering would silently repoint every one of them.
Nothing in this file depends on any of the moved sections.

---

## 7. Go to, expanded in place — the ⌘K field

**Why:** ⌘K is a button that opens a 620pt card over a dimmed window. The card is a place you go to
in order to go somewhere, and it hides the tree you are navigating while you type the name of
another folder in it. The pill in the title bar is already the control you click; it should be the
control you type into.

### Context

| Fact | Where | Consequence |
|---|---|---|
| **The card's real numbers**: 620pt wide, list capped at 420pt, field set at 19pt. | `CommandPaletteView.swift:47`, `:48`, `:148` | The list cap survives unchanged; 620 becomes the *ceiling* of a clamp, not a fixed width; 19 cannot live in a 32pt-tall toolbar row. |
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
  roots.
- **The narrow case is not free.** At a 760pt window the field can take about 400 of ~406 available
  points, and only because the workspace bar has already shed its labels for glyphs. Below the 320pt
  floor it opens as wide as it can and the placeholder shortens.

### Two spikes before committing to the shape

Neither is answerable from a mockup, both are about twenty minutes, and both are cheaper now than
halfway through:

1. Does a toolbar item animate its width smoothly under macOS 26's grouped toolbar?
2. Does a non-key panel under a focused toolbar field draw its selection highlight the way the card
   does?

---

## 8. Window chrome: saying which window is which

- **Name the compared pair in the title bar.** `window.subtitle` is set nowhere in `MacApp`. The
  title bar is hidden, so two windows side by side are indistinguishable, Mission Control shows two
  identical thumbnails, and the Window menu lists "SyncCloud" twice. A subtitle naming the pair —
  `iCloud/Documents ⇄ Dropbox/Documents` — shown beside the tab strip **and** set as the real
  `window.subtitle`, which is what those two surfaces read. On a single-source workspace it names
  that source. Middle-truncates as the window narrows, matching the pane breadcrumb. **Small.**
- **One-line pane headers.** Fold each pane's two-row header to one — provider chip, breadcrumb,
  link glyph — and reveal the bar on hover or keyboard focus. Roughly 44pt back, three more file
  rows per pane, on every window, permanently. **Medium, and the constraint hardened since it was
  first proposed:** the header is pinned at 81pt so its bottom edge shares the 83.5 rule with
  Organize's `LensHeaderCard` (`LiquidGlassStyle.swift:410`, `:403`), and `PaneHeaderHeightTests`
  guards it from the other side. Two further rules: the fold must respect the user's own
  `PaneBarArrangement` rather than a hardcoded cluster, and an expanded ⌘F field **cannot** hide on
  hover-out — a field someone is typing into is not chrome.

---

## 9. The polish batch — cited, not restated

Four items from `ROADMAP.md`'s Interface section, scheduled into 4.2 because each is genuinely
small, none has a dependency, and all four were re-checked against the code at `c604321e` and are
still unbuilt. **Their specifications stay in `ROADMAP.md`** — a spec kept in two places drifts in
one of them — so what follows is only the citation and the evidence that the item still applies.

| Item | Still unbuilt because | Evidence |
|---|---|---|
| **Magnitude bars behind the largest-files list** | the ranked lists are plain rows | `StorageLensView.swift:357` — `case largest, stale, reclaim` |
| **One sequential ramp for the treemap** | the palette is assigned **by index**, and the light entries still force a per-tile label-colour table | `TreemapView.swift:24` `palette[index % count]`, `:21` the luminance table |
| **Drop the "Identical" badge from the majority row** | the badge still fires on the majority case | `LensWorkspaceView.swift` — `.identical` → `checkmark.seal.fill`, `SemanticColor.success` |
| **Make the stat pills the filter** | the pills are still inert and the real filter is still a separate control | `LensWorkspaceView.swift:2532`, `:2538`, `:2545` pills; `:2680` the `Picker` |

The treemap ramp is the one that **deletes** code rather than adding it: the contrast problem the
label table exists to solve dissolves when the ramp's pale end lands on the small tiles, which carry
no labels anyway.

One constraint the stat-pill item must not lose: **not every pill is a subset.** The reclaim figure,
Organize's *reused* and Storage's freshness marker are scan-level facts, not filters, and they must
stay visibly inert or the header teaches that clicking pills sometimes does nothing.

---

## Order

**v4.2 is a navigation release, and §§3 and 7 are one piece of work rather than two.** The field is
what makes Go to Folder possible and what makes the recents question urgent; the chords and the
status bar are independent of it and of each other.

**The build order.** 1–11 are the release; 12–15 are in scope by decision and are where to cut if it
runs long — see the note under the list.

1. **Persist recents in `FolderJumpStore`** (§3's second correction). A prerequisite, not a
   follow-up: everything about the field opening on your last four folders is false without it.
   Ships with its cap, its order, and its answer for a folder that has since gone.
2. **The two spikes** (§7). Forty minutes that decide whether §7's shape holds at all.
3. **The field, and its width in the reserve** (§7). One commit — the reserve arithmetic has no
   symptom when it is wrong until the toolbar is behind a chevron. The route-table walk from the
   decisions block happens here, before the card is deleted.
4. **Go to Folder** (§3). Nearly free once 3 lands, pointless before it.
5. **The chords and the status bar** (§3). ↩, ⌘↑/⌘↓, the status bar, and ⌘/ moving to it — the
   shortcuts reference gives the chord up rather than take a replacement.
   Independent of everything above; schedulable against anything.
6. **The polish batch** (§9). Four small items, no dependencies.
7. **Title-bar subtitle** (§8). Small, and the only item here that answers a question the app
   currently cannot answer at all.
8. **Pins and recents sidebar** (§3). Reads the store step 1 made durable.
9. **The pasteboard** (§3). ⌘C/⌘V + a paste-as-move whose chord is still to be chosen (**not ⌥⌘V** —
   the ⌥ ban above) — the cross-cloud move, and the largest user-facing gain left.
10. **§1's switch mirroring** — or delete it, having now run tabs for a release. It has been
    designed twice and carried twice; a third carry is the signal to drop it.
11. **One-line pane headers** (§8). Medium, and it argues with a pinned constant and its test.
12. **Gallery view** (§3) — thumbnail infrastructure.
13. **Group by kind or date** (§3) — touches every row-rendering path.
14. **Drop files on a tab** (§3) — after 9, with the proof that a click still opens a column.
15. **Tags** (§3) — only with the rules integration that answers the standing objection.

**Where to cut, and why.** Steps 1–11 are already a complete, nameable release: they are the half
that makes the app faster to move around in. 12–15 change what Browse can *display*, not how you get
anywhere, and any one of them is a release on its own — v4.0 was the largest the app has had at 284
commits and it was *one* structural change plus its consequences. **The recommendation is 1–11 as
v4.2 and 12–15 as v4.3**; the plan above is written so either call works without rewriting it.

---

## Open questions

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
- **§3 / §8: what does the status bar say in Compare?** Two panes, one bar or two. A single bar has
  to name which pane it is describing, which is the problem the per-pane header already solves by
  being per-pane — and that header is the surface §8 is trying to make shorter. The two items are
  cheap separately and contradict each other if decided separately.
- **§3: is tags actually wanted, or is it here because it was on a list?** It is the only item in
  this file carrying a standing argument against it that has not been answered. Decide it on merit
  before it is scheduled, not after.
- **§7: does anything reach a route only the 620pt card could show?** The decisions block makes this
  a walk of the palette's route table before the card is deleted, rather than a question — recorded
  here so it is not lost if that walk finds something that needs a door of its own.
