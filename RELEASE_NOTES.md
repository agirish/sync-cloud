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

## v1.4

The last of the v1 line, and the widest: three new Tidy lenses plus a durable
history you can undo from.

- **Storage Lens** — a treemap of what's actually eating your disk, with
  reclaim-candidate lists.
- **Sync History** — durable and exportable, with **run-level undo**; "Undo Last
  Run" is scoped to the actual run and spells out what it will reverse.
- **Name normalizer** as a batch Tidy lens, with per-row Quick Look and Show in
  Finder on its cards.
- **Automations** arrive as a preview-only lens — rich rule cards, grouped results,
  per-rule preview, and a Browse button for picking a destination folder.
- **Activity Log** gained on-demand "Show older history" paging.
- A per-tab toggle to **hide the top file panes**, and a lifetime cloud-spend cap
  (default $5).
- Re-verification is instant now: SHA-256 is cached by path + mtime + size.

---

## v1.3

Onboarding and visual identity — the release that made SyncCloud explain itself.

- **First-run welcome** — a one-time front door offering scan / choose-providers,
  which grew into an informative **feature tour** with a vector illustration per
  page, brand glyphs, and motion.
- **In-app Help** — a SyncCloud Help overlay plus an enriched Help menu, and
  Help ▸ Welcome to re-summon the first-run card.
- **Provider brand hues** tint provider identity throughout, and are
  appearance-adaptive after a dark-mode contrast audit.
- **Unified empty states** via one shared EmptyStateView, reaching the Differences
  pre-scan / in-sync / scanning states.
- **Comfortable / compact list density.**
- Tidy and Filing cards animate their exits, with a reclaimed-space payoff.

---

## v1.2

AI-assisted filing — SyncCloud learns where your loose files belong.

- **The Filing lens** suggests a destination for every loose file, backed by
  on-device content signals.
- **Two engines** — a hybrid design: on-device Apple LLM first, with an **opt-in
  cloud (Claude) classifier** for the hard cases.
- **Remembered rules** — corrections stick, and learned rules get a legible,
  editable home in plain words with edit / disable / delete.
- **"Try another"** re-suggests with rejection learning.
- **Cost is visible and capped** — per-scan cost was cut ~10–50×, spend is
  surfaced in the UI (last scan, total, history), and pre-flight estimates plus a
  monthly cap guard against surprises. Defaults to Haiku.
- **Confidence meter and legend**, legible content evidence, and a destination peek.
- **Settings ▸ Tidy** — a dedicated tab for Duplicates, Filing, and cloud spend —
  plus a header search that filters across all tabs and jumps.

---

## v1.1

The Tidy tab arrives, alongside a broad UX polish wave.

- **Duplicates lens** — find and resolve duplicate folders and files within one
  provider, including **overlapping-folder merges**.
- **Keeper picker** and a persistent **"Keep separate"** decision.
- **Cancellable scans** with determinate progress through the hashing phase, and
  settings for scan options.
- **Differences polish** — an actionable "No Scan Performed" state, per-side item
  totals beside the pill, per-filter counts on the filter menu, directional
  keyboard copy/move, and a visible toggle for "navigate both panes."
- **One icon vocabulary** — copy/move actions unified behind a single TransferGlyph
  set, so three features stop sharing the same ⇄ arrows.
- Clearer sync error alerts, and VoiceOver values on the Appearance sliders.

---

## v1.0

The foundation: comparing and reconciling the folders you keep across iCloud Drive,
OneDrive, Dropbox, and Google Drive — with a native macOS app, a CLI, and
undo-everything safety.
