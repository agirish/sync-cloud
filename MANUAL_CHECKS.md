# Manual checks — 2026-07-10 review waves

Runtime checks for changes landed by the full-codebase review (Waves 1–3, commits
`29f3590..353113f`). Everything below is already covered by green unit tests where
possible; these are the behaviors only a human in the running app can confirm.
Check items off as you verify them, and note anything that misbehaves.

## Keyboard & focus (Wave 1C)

- [ ] **Space opens Quick Look from a pane.** Click a file row in either pane, press
  Space → Quick Look opens on that file. (Known nuance: the pane list must have key
  focus — after clicking a toolbar button, click a row again before Space works.)
- [ ] **Space types normally in text fields.** Type a phrase with spaces into the
  Differences search field, and into a Settings-overlay text field (⌘,) → spaces
  appear in the text; Quick Look does not open.

## Banners & progress (Waves 1C, 2D)

- [ ] **Banner auto-dismiss after ✕.** Hover a success banner, close it with ✕, then
  trigger another operation → the new banner auto-dismisses on its own (previously it
  hung forever).
- [ ] **Progress overlay animates.** Start a bulk copy → the progress dialog slides in
  from the top with a fade, and animates out on completion (no abrupt pop).

## Single window (Wave 2E)

- [ ] **Reopen keeps state.** Navigate both panes somewhere, toggle hidden files, close
  the window (⌘W), click the Dock icon → the window returns with the same panes,
  navigation, and hidden-files toggle; no provider flip, no rescan spinner.
- [ ] **No New Window.** File menu has no "New Window"; ⌘N does nothing.
- [ ] **Unaffected flows.** Settings overlay (⌘,) and the quit-with-operations-running
  warning behave as before.

## Context menus (Wave 2C)

- [ ] **No drag & drop between panes.** Cross-pane drag was removed (`4d55246`) after it
  turned out never to have worked outside one dev-build verification. Press and drag a row
  across to the other pane: **no drag image lifts, no row or pane highlights as a drop
  target, and no file is copied or moved.** Copy/move is the action bar, the context menus,
  and `⌘→ / ⌘←`. Whatever the press-drag now does *within* the source list — most likely
  extending the selection, which is what an AppKit table does once nothing claims the
  gesture — is fine; only the three negatives above are the check.
- [ ] **Tree-row Reveal / Quick Look.** Right-click a pane row → "Reveal in Finder" and
  "Quick Look" work; Quick Look coexists with the spacebar previewer.
- [ ] **Paste-here dims when empty.** With nothing on the internal clipboard,
  right-click → "Paste here" is disabled; after Copy/Cut it enables.
- [ ] **⌘ decides at click time.** Open a Differences row/bulk context menu, then press
  or release ⌘ before clicking Copy/Move → the action follows the modifier state at
  the click (labels keep their open-time snapshot; that's expected).
- [ ] **Sort menu & filter menu show native checkmarks** on the selected option, with no
  "No symbol named ''" console spam.

## Search (Wave 2C)

- [ ] **Search field focuses on reveal.** Click the magnifier in the Differences header
  → the field appears already focused. Escape clears the text and collapses it.

## Visuals (Waves 2C, 2D, D7)

- [ ] **Bundle icons.** A `.app` or `.photoslibrary` in a pane shows its real icon, not
  a plain folder; plain folders unchanged.
- [ ] **Cards glass on macOS 26.** Appearance → surface style "Cards": panes and the
  bottom section render native Liquid Glass matching the toolbar (no mixed frosted
  idioms in one window).
- [ ] **Multi-select Details.** Select several files → Details shows "N items selected"
  with file/folder counts and a files-only size total; single selection shows the full
  detail view as before.
- [ ] **Folder size recomputes.** Select a folder, note its Size, copy/delete something
  inside it, refresh → Size shows "Calculating…" then the new total.
- [ ] **Narrow-window truncation.** With two long provider names, shrink the window →
  the Differences header labels truncate instead of clipping or pushing out the
  search button.

## Error handling (Waves 2A, 2C, 2B)

- [ ] **Retry on single-row failures.** Force a single-row sync failure (e.g. sync onto
  a read-only destination) → the error alert offers Retry, and Retry re-runs that row.
- [ ] **Redo failure surfaces.** Copy a file, undo (⌘Z), delete the source externally,
  redo (⌘⇧Z) → a warning banner reports the failed redo, and a subsequent ⌘Z does
  NOT prompt to permanently delete a phantom file.

## Settings (Wave 3D)

- [ ] **Launch-at-login approval refresh.** Toggle launch-at-login on, approve it in
  System Settings → Login Items, switch back to SyncCloud → the "Approval needed"
  footer clears without reopening the tab. If the system rejects registration, the
  toggle snaps back.

## Help feature (2026-07-13) — HelpBook + overlay + Help menu

Logic is green (HelpBookTests: 11 pins over structure + search); build + crash-free
launch confirmed. Live overlay rendering is the human-only part.

- [ ] **SyncCloud Help opens the overlay.** Help ▸ SyncCloud Help (or ⌘?) → a centered
  frosted card appears over a dimmed window (no more "Help isn't available"). It obeys
  the current surface style (Solid = opaque panel; Unified/Cards = glass).
- [ ] **Sidebar + article.** Topics are grouped into five sections; clicking one shows its
  article on the right. "Reading the list" shows the colored difference-badge legend.
- [ ] **Search narrows.** Type in the sidebar search (e.g. "checksum", "keeper") → the list
  filters to matching topics; clearing it restores all. "No topics found" for gibberish.
- [ ] **Related chips jump.** Click a related-topic chip at the bottom of an article → the
  selection moves to that topic.
- [ ] **Dismissal.** ✕, Esc, and clicking the dimmed backdrop all close it. Opening Settings
  (⌘,) while Help is up closes Help (they never stack).
- [ ] **New Help-menu items.** Open Activity Log opens the log window; Reveal Log File in
  Finder selects ~/sync-cloud.log; About SyncCloud shows the standard About panel;
  Keyboard Shortcuts (⌘/) and Welcome to SyncCloud still work.

## CLI (Waves 1D, 2F) — spot checks (e2e-verified during the review)

- [ ] `synccloud sync --help` documents `--strategy` default `replace` and Trash
  recoverability.
- [ ] Sync with a failure exits non-zero; the summary explains skipped files.
- [ ] Pointing `-L`/`-R` at a nonexistent path errors clearly (exit 64) instead of
  scanning as "everything missing".

## Ambient surfaces (2026-08-04) — what no fixture can judge

The classifier, the badge, the inspector rows and the handoff are all covered by green tests
(`FileLocationTests`, `HomeOnlyBadge*Tests`, `DetailsWhereItLivesTests`, `DuplicateReveal*Tests`,
`DuplicateRevealCoordinatorTests`, `PaneHomeBadgeDelegateTests`).

The "typing your own query retires the named answer" check that used to sit here is **gone
because it became testable**: the rule was rewritten from clearing-on-every-write-path to a
declarative gate (`DuplicateReveal.namedAnswer`), which is pure and now pinned by
`aQueryTheHandoffDidNotWriteRetiresTheAnswer`. That is the better outcome than a checkbox — if a
manual check can be turned into a gate, turn it into a gate.

- [ ] **Touching a card ends the landing mark.** Right-click a file that has copies → *Find
  duplicates of this* → land with its group expanded and ringed in the accent. Click any card's
  header → the ring goes, and does not come back until the next handoff. (Still manual: `@State`
  written on an uninstalled `TidyView` does not persist — probed and confirmed — and a card click
  cannot be driven headlessly.)

Two things worth an eye that no fixture can judge:

- [ ] **⌂ density in a Home-folder pane reads as information, not alarm.** Most rows will carry
  it. It is drawn in the same grey as ☁ deliberately — if it reads as a wall of warnings, that is
  the call to revisit.
- [ ] **The inspector's three rows read top-down as evidence → conclusion.** Path, then *On this
  Mac*, then *Where it lives*. The pill should feel like it follows from the two rows above it
  rather than arriving from nowhere.

## v3.1 review fixes (2026-08-04) — the two that stayed view-level

Everything else from that review is pinned by a mutation-checked test. These two are SwiftUI
wiring, which no `swift test` process can drive (a `Button` is not an `NSControl`, and a sheet's
`onDismiss` needs a real presentation).

- [ ] **Clearing spend history updates the Organize setup card.** Organize ▸ *History* ▸ **Clear
  History** ▸ close the sheet. The setup card's *last run ~$x.xx* must be gone, not still quoting
  the run you just erased. (The bug: `TidyView` cached the figure and presented the sheet with no
  `onDismiss` — `SettingsView` presents the same sheet and always got this right.)
- [ ] **Settings ▸ Advanced ▸ Saved scan data reads and clears.** Both rows show a size after a
  Duplicates/Verify run and a Storage analysis respectively; **Clear** takes each to *None* and
  disables its button. Then run a duplicate scan and re-open the tab — *File digests* has a size
  again, which is the cache doing its job rather than the Clear having failed.

## Round-2 review fixes (2026-08-05) — the one that stayed view-level

Everything else from the second review pass is pinned by tests (the reveal nonce, the request
retirement callback, the recovery button's coordinator entry, the landing gates, the spend-change
signal, the write-queue ordering). One host wiring cannot be:

- [ ] **An answered "Find duplicates of this" does not replay after a trip through Compare.**
  Right-click a file with copies → *Find duplicates of this* → land on the ringed group. Set a
  match-type filter and type a query. Switch to Compare, then back to Duplicates. The filter and
  query you set must still be there — no re-scroll to the old group, no re-cleared search. (The
  TidyView-side callback is tested; what a unit test cannot reach is `ContentView` actually
  clearing `duplicateRevealRequest` in response — two lines behind `if !isRunningTests`-free but
  view-mounted wiring.)
