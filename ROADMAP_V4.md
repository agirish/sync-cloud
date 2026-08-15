# SyncCloud — v4.x roadmap

**Scope:** the 4.x line after v4.0 ships — the **Browse** workspace, whose Finder-style tabs
(§1) **shipped on 2026-08-14** leaving one behaviour designed and unbuilt, pane chrome that spans
every workspace (§2), the Finder borrowings worth taking (§3), the
storage-layer gaps behind **Organize ▸ Restructure** (§4), the plan surface that lens was
deliberately shipped without (§5) and the **first folder survey**, run in the background, which is
what gives a fresh machine anything to read at all (§6). `main` only, with one stated exception:
§2's code exists on `v2.x` too, and that item says what follows from it.

Distinct from `ROADMAP.md` (the standing feature backlog across all surfaces),
`DEFERRED_ENHANCEMENTS.md` (accepted limits) and `REFACTOR.md` (internal shape). An item graduates
out of this file the way it does out of `ROADMAP.md`: deleted when it ships, because git history is
the record.

§§1–5 were designed and mocked on **2026-08-12**; every constraint in them was read out of the code
that day. **§6 was designed on 2026-08-13**, and its constraints were read out of the code that day —
the day part of §4.2 shipped, which is why §4.2 now carries measurements rather than a plan.

An **illustrated companion** covers all six items — same decisions, same Order, same Open
questions, with 29 figures in both appearances:
<https://claude.ai/code/artifact/929eb3d2-d381-4fa5-b456-a0a9c9313cea>. **This file is the one that
ships** — if it disagrees with the companion, the companion is the stale one. Figures are cited by
number below where one settles a question faster than a paragraph. Figures are **appended, never
renumbered**: §2's are 17–20 and its section sits after §3 there, §5's are 21–24 and §6's are 25–29,
so adding any of them could not move a number this file already cites. §4's figures are **real
renders** through the shipping `LensSetupCard`, not re-creations, and are unnumbered for that reason.

The companion **keeps §1's tab figures after this file dropped its §1 prose**, deliberately: they
are now the record of what the strip was drawn to be, which is worth more beside the shipped thing
than a plan repeating what the code says. It carries a shipped banner on that section saying so.

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

### Two things §1 left for whoever builds this

Tabs landed first, so these are now facts about the screen rather than a boundary to negotiate:

- **At the rail's 220pt the strip's count chevron sits ~34pt above the bar's ⋯** — two overflow
  affordances stacked, with different meanings (a number against three dots). Distinguishable, but
  that is the width to render before deciding the bar's own overflow is fine as it is.
- **Icon Only governs the bar, never the strip.** A tab without its name is nothing — which is the
  same rule that stopped the strip's narrowest rung shedding tabs to mark-only, because five
  identical cloud marks name nothing.

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
| **The folder profile has exactly one write path, and it refuses over an existing profile.** `writeProfile` throws `WriteRefusal.profileExists`, writes atomically, and re-points `profiles.json` only when nothing is active. `FilingSurveyStore` still never writes a profile. | `Modules/Sync/Sources/Sync/FilingProfileStore.swift` (`writeProfile`, shipped `d4280231`) | A derived profile can never land on top of a hand-built one, which is what a walk cannot re-derive: `naming`, `folderSemantics`, the `outbound-pack` refusals. There is deliberately no `overwrite:` parameter — replacing a profile means moving the old file by hand, in the open. |

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
| "the degradation asserted rather than described" — the same synthetic tree with and without axes. | **Restructure returns the identical finding from a derived profile as from the hand-built one.** There is no degradation left for this lens to characterise, which settles that test by removing its subject. What a walk still cannot re-derive is `naming`, `folderSemantics` and the jurisdiction vocabulary — and that, not a degraded profile, is what the store's refusal protects. |

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
  three inventions: it proposes `HPE`, `IT` and `PRD` as *places*. Without its 2–3-character bound
  the strongest candidate on this tree is **`TODO`**, under more parents than `US` — the inbox
  marker the whole filing path exists to refuse. So values are **proposed for confirmation, never
  adopted**, which is what puts them in §6's dialog. The rule also **misses**: `Singapore` is a real
  jurisdiction here (10 folders) and appears under only two parents, below the three-parent bar, so
  the dialog must let a value be **added** as well as ticked or the tree's third jurisdiction can
  never be recorded at all.

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

### 5.7 The two states this adds — no work of its own, but they need their own words

The lens's existing three states are distinct on purpose and **none borrows another's words** — *no
profile* means the detectors have nothing to read, *no findings* means they ran and the tree agrees,
a list means it does not. Two more arrive with the work above, and they ship with §5.1 and §5.5
respectively rather than as an item:

- **Planned, not applied.** The finding card carries the plan's ledger inline and its trigger reads
  `Review 8 operations`. A drafted plan survives the sheet closing; whether it survives a re-survey
  is an Open question, and until that is settled the card says it does not.
- **Applied.** *8 folders renamed, 92 files carried, none moved*, plus `Undo this reorganisation`
  backed by the inverse plan already on disk. **The finding is gone because the generation bumped
  and the detector re-ran** — never because it was marked done. Those are different states and only
  one of them is true.

---

## 6. The first survey, run in the background

**Why:** the router reads a folder profile the app has never been able to create. It has only ever
come from an out-of-repo script, so a machine that has never run one gets **no routing at all** —
and the guard that proves it is three lines:

```swift
guard let profileId = filingMemory?.profileId ?? filingFolderProfile?.profileId else {
    Logger.shared.info("No filing profile on this machine — nothing to re-survey")
    return .none
}
```

`Modules/Sync/Sources/Sync/FileSyncManager+FilingSurvey.swift:74`. The re-survey refreshes the half
the app owns and cannot produce the half it does not. §4.2 shipped the derivation and the write;
this is the **run**.

**What it is:** an OS-indexer-shaped pass. The user agrees once, in a dialog, and then it runs in the
background — non-blocking, resumable across quits, throttled behind their own work. **It is
acceptable for this to take a long time; it is not acceptable for it to make the app feel slow.**
Every constraint below is that sentence taken literally.

### The setup dialog — Fig. 25

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
  tuned to offer `HPE` rather than to be right about it — and there is a free-text row to **add**
  one, because that is the only way `Singapore` can ever be recorded (§4.2).

Fig. 25 is that dialog as a sheet over Organize: the tree at the top and the household under it,
both stated rather than asked, each with a quiet *Change…* / *Edit…* — they are confirmations of
what the app already holds. Then the one thing it cannot decide alone, under the heading *Places*:
the proposals as tick chips, `US` and `IN` ticked and `HPE`, `IT` and `PRD` not, with an *Add…*
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

### Size — large

Two new files in `Sync` (the run's state machine and its checkpoint, which is the file
`corpus(id:in:)` must never read), one setup sheet in `FileExplorer`, and wiring in
`FileSyncManager`, `RestructureLens` and `ScanLifecycle`. ~900 lines, and **none of it is
derivation** — that shipped. The state machine is the work: pause, resume across a quit, and a
checkpoint that cannot be mistaken for a corpus.

---

## Order

**Everything here is post-v4.0.** §4.1 is the only item that improves a screen already shipping.

1. ~~**Tabs**, all three rungs~~ — **shipped 2026-08-14**, and the "all three rungs in one motion"
   call held up: Compare and the rail needed no follow-up, because one insertion point in
   `paneColumn` serves all three. Only §1's *switch mirroring* is left, and it is not next — it
   wants someone to run linked Compare for a while first.
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
10. Everything else on its own merits. **§6 when a second machine or a second tree makes it real** —
   it cannot fire on this one, which has a profile and where the store would refuse the write;
   drop-on-tab last.

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

- Whether ⋯ takes a title in the titled bar. Finder's » does not; recommendation: leave it unlabelled
  and centred on the pill row.
- Whether `v2.x` is still open when §2 is picked up — it decides which line that work starts on.
- Whether a tab shows a scan/download spinner when work is running in a folder it is not showing.
- **§6: stopgap or replacement?** Settled further than it was: the derivation is not a degraded
  stopgap — role, anchors and axes agree at .997–1.000 and Restructure cannot tell the two profiles
  apart. What stays hand-built is `naming`, `folderSemantics` and the jurisdiction *vocabulary*, and
  the last of those is answered by asking rather than by mining. The open half is whether that is
  enough to stop maintaining the offline builder at all, which only a second tree can answer.
- **§6: should the survey offer itself unprompted on a large unsurveyed tree?** A machine with no
  profile gets no routing and no Restructure, and nothing on screen says why until someone opens the
  lens. Against that: an hours-long background pass that the user did not ask for is exactly the
  thing the *"never make the app feel slow"* rule exists to protect, and the dialog needs three
  answers it cannot guess. Recommendation: offer it in the lens and in Organize's overview, never
  start it.
- **§6: what should the Organize overview ledger count while a survey is running?** Making
  Restructure runnable changes `countedLenses` and `pendingPasses`
  (`Modules/FileExplorer/Sources/FileExplorer/OrganizeOverview.swift:418`, `:468`), and a lens that
  is *going to be* runnable in forty minutes is neither of the two states those were written for. A
  badge that appears mid-survey and a pass card that offers a button pointing at an unfinished
  answer are both worse than counting nothing until the survey lands.
- **§5.4: merges.** Two source folders mapping onto one target inside a single year is refused on
  the row rather than designed. A real family will eventually want one, and it is the case where
  *rename* stops being available and files genuinely have to move.
- **§5.4: does a drafted plan survive a re-survey?** The mockups say no and say so on the card. If
  plans are to be kept, they need identity keyed on **detector × folder path** — the same key
  *never suggest this again* needs (`ROADMAP.md` 20), stored beside `folderSemantics`.
- **§5.2: does the crowding strip render in the clean state?** *The tree agrees with itself* and
  *this scope has 52 pass-through folders* are both true at once; the mockups show both, which means
  the seal is no longer the only thing on that screen.
