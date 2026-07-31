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
