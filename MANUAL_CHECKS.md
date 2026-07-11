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

## Drag & drop / context menus (Wave 2C)

- [ ] **File-row drop targets the enclosing folder.** Expand a subfolder in one pane,
  drag a file from the other pane onto a *file* row inside it → the file lands in that
  file's folder (not the pane root), and the file row itself shows no drop highlight.
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

## CLI (Waves 1D, 2F) — spot checks (e2e-verified during the review)

- [ ] `synccloud sync --help` documents `--strategy` default `replace` and Trash
  recoverability.
- [ ] Sync with a failure exits non-zero; the summary explains skipped files.
- [ ] Pointing `-L`/`-R` at a nonexistent path errors clearly (exit 64) instead of
  scanning as "everything missing".
