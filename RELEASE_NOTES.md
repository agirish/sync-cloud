# SyncCloud — Release Notes

User-facing changes, newest first. For the full commit history see the
[repository](https://github.com/agirish/sync-cloud).

---

## v2.1

A large reliability and polish release. If v2.0 reshaped the window, v2.1 made it
trustworthy: undo now covers every destructive path, the duplicate finder stops
touching files it shouldn't, and the whole app picked up a proper Theme system.

### Appearance & theming
- **Light / Dark / Follow macOS** — a new Theme control lets you pick the app's
  appearance independent of the system, and switching it live updates everything
  down to the title bar.
- **Bolder Dark mode** — a deeper base, accent glow, and specular-edged cards.
- **Graphite accent** — a new true-neutral, monochrome accent hue.
- **Compare | Tidy in the title bar** — the mode switch moved up into the window's
  empty title bar, and the controls read as frosted glass, letting your desktop
  show through at rest.
- **One consistent look** — badges, pills, and meaning-colors (caution/risk tiers)
  now come from a single shared palette, so the same idea looks the same everywhere.

### Search
- **Token search everywhere** — the Compare pane, Activity Log, and Tidy duplicates
  all gained a chip-based search with removable tokens and suggestions.
- **Filters that mean something** — `kind:image` and similar type filters, size
  tokens ("larger than N MB"), and a Clear Filters affordance.

### Compare
- **"Scanned N ago" freshness pill** on the pane header, so you always know how
  current a comparison is.
- **Selection size** — the action bar now shows the total size of what's selected.
- **Folder quick-jump menu** in the pane header for hopping between subfolders.

### Tidy & duplicates
- **Content thumbnails** in duplicate cards, so you can see what you're about to
  merge or trash.
- **"Compare copies"** — hand a duplicate group straight over to the Compare tab.
- **Safer grouping** — files are only grouped as "versions" when there's a real
  version marker or shared folder, and symlinks and cloud-only placeholders are no
  longer mistaken for real duplicates.

### Cloud-only files
- Cloud-only (not-yet-downloaded) files are now **flagged**, with a best-effort
  Download action; the badge clears once the file actually lands.

### Activity Log
- **Grouped by day**, with per-file operation runs folded together.
- Long messages wrap instead of truncating; severity chips scroll rather than
  getting cut off.

### Automations & filing
- **One rule system** — remembered rules and automations were unified; every newly
  learned rule is surfaced in Automations for review.
- Preview/Reveal inspection on automation surfaces, and honest previews for
  disabled rules.

### Density
- **Compact list density** now threads through the file panes, Activity Log, Sync
  History, and lens cards.

### Safety & correctness (selected)
- **Undo covers everything** — a full move / copy / delete undo-then-redo matrix,
  plus an Undo affordance on completion banners for reversible operations.
- The duplicate finder **never trashes the last copy**, and re-verifies a redundant
  copy right before trashing it.
- Filing no longer misfiles by a year found in a camera filename, and prefers the
  filename's year over modification time.
- **Never** auto-replace a folder from a file's "Apply to all".
- Permanent delete is no longer offered after a merely transient trash failure.
- Fixed OneDrive name-rule false positives and an integer-overflow crash in the
  "Larger than N MB" rule.

### CLI
- Destination names are validated exactly as the app does, and sync skips are
  reported by cause rather than assumed to be collisions.

---

## v2.0

A ground-up restructure of the window. The app moved from a provider-sidebar layout
to a focused, tab-driven workspace.

### A new window shape
- **Persistent tab strip** with a single-source rail replaces the old provider
  sidebar; the tab bar is pinned to a fixed height so switching tabs never nudges
  the layout.
- **Self-contained panes** — the provider sidebar is gone; scanning and per-pane
  actions now live directly on the pane headers.
- **A leaner title bar** — pared down to Logs and Settings.

### Compare (formerly Differences)
- The **Differences** view is now **Compare**, with the old Details panel folded
  into a dedicated Compare inspector.
- **Get Info** is routed to the Compare inspector and added to the differences
  table, and the Info toggle now reads as enabled with a resizable pane.

### Organize & Rename
- The **Name Normalizer** returns as its own **"Rename"** sub-tab under Tidy.
- Organize's loose-files scan defaults to a configurable **TODO inbox**.

### Automations
- Previewed automations are now **filed for real, one file at a time**.
- Filing is anchored at the **provider root**, not the focused subfolder.
- After filing a loose file, SyncCloud **offers a learned rule** — but only prompts
  to learn one when the file actually moved.

### Performance
- The comparison panes no longer re-walk their 40k-node trees on every selection,
  and a dead first-click when selecting in the panes is fixed.

---

## v1.x

The v1 line established SyncCloud's foundation: comparing and reconciling folders
across iCloud Drive, OneDrive, Dropbox, and Google Drive, with duplicate finding,
AI-assisted filing, a storage treemap, and undo-everything safety.
