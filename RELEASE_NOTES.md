# SyncCloud — Release Notes

User-facing changes, newest first. For the full commit history see the
[repository](https://github.com/agirish/sync-cloud).

---

## v2.7

Browse your folders in columns.

### Columns
- **A new pane view mode, and the default** — panes render as columns, the way
  Finder does, so you can see the path you took instead of just where you landed.
- **Drilling into a folder mirrors onto the linked pane**, keeping both sides in
  step.
- The header shows **one location**, not two halves of one, and the pane arrows
  understand columns before they consult the focus history.
- A click on empty space **puts the selection down**, and a linked breadcrumb click
  reaches the folder it names.

### Scrolling that behaves
- The column stack now scrolls **the way AppKit scrolls** — bounce is capped rather
  than removed, and the stack is pulled home when the platform's bounce strands it.
- A wheel gesture **locks to its dominant axis**, decided from accumulated travel,
  so a vertical scroll stops nudging the stack sideways.

### Clicks that land
- Clicks are measured **from mouse-up**, a plain column click commits its own
  selection, and a folder's column opens from whichever half of the click fires.
- One pane's deferred clear no longer eats the other pane's next click, and the
  action bar's buttons stop moving when the summary changes.

### Data safety
- **External-volume providers claim their own tree again.** A depth rule introduced
  in v2.6 meant a provider mounted under `/Volumes` claimed nothing — so a
  path-addressed CLI root inside it silently lost its destination-name guard and
  date-noise filter. The test is now what the root *contains*, not how deep it sits.
  *(Regression introduced in v2.6.)*
- **`›` can no longer walk into a folder that no longer exists.** Stepping back out
  of a folder that is then deleted left the forward arrow lit and pointing at a dead
  path — where New Folder, paste, and background drops act.
- A queued column navigation can no longer undo a newer one — the "Back doesn't
  work" shape.

### Tidy accounting
- A group whose copies are all protected no longer **vanishes from the list with its
  bytes credited as reclaimed** while every copy is still on disk.
- Protected copies are no longer counted as reclaimable, so a group stops promising
  bytes its own "Move to Trash" would never deliver — and its Trash button is no
  longer enabled to do nothing.
- A corrupt store stopped rewriting its whole backup on every read — tens of
  thousands of writes per scan, exactly when the disk is least worth hammering.

### Security
- The copied API key is **marked concealed on the pasteboard**, so clipboard
  managers know not to retain it.

**Full changelog:** [`v2.6...v2.7`](https://github.com/agirish/sync-cloud/compare/v2.6...v2.7)

---

## v2.6

Comparisons you can fold up, and Settings you can read.

### Differences
- **Grouped into top-level folder sections**, so a long comparison reads as a
  handful of folders instead of one flat wall of rows.
- **Sections are selectable and collapsible**, with **Collapse All** promoted onto
  the differences bar instead of hiding inside the filter menu.
- Scan staleness moved off the whole count pill onto the age run, so only the part
  that goes stale looks stale.

### Settings
- **Stood on a left rail**, so a tab is never cut in half again.
- More air between sections, a looser vertical rhythm, and room for a provider path
  to actually be read.

### Appearance
- A **Text size** setting.
- The seam pill is quiet at rest, and the accent is reserved for meaning "linked".
- On Clear glass the provider capsule gets a ground to sit on, and chrome ink is
  brighter on a dark appearance.

### Keychain
- **Opening the Tidy tab no longer demands your Keychain password.**
- The API key gains a **reveal**, and a replace that tells you it replaced.

### Performance
- SwiftUI no longer deep-compares 40,000 file nodes on the main thread — a folder
  row's subtree is kept out of row comparison, `OutlineGroup` is no longer handed
  the raw node graph, and the Details sidebar resolves its selection through an
  index rather than walking the tree.

### Data safety
- **A bulk sync could overwrite one file with another and report success.** Each
  destination is now asked about its own volume, rather than every item inheriting
  the answer from whichever happened to be first. When a batch mixed a
  case-sensitive mount with the case-insensitive boot volume, two names differing
  only by case both passed the uniqueness check, the workers wrote to the same file,
  and with a Move both sources were consumed — one file's contents gone, a success
  banner, nothing in the Trash. Which files it hit depended on the table's sort
  order.

### Fixes
- Three states stopped lying: a clipped tab, a deleted key, and a stale scan.
- The transfer buttons spell out **Copy**, and the link-panes toggle folds into the
  swap chip's seam capsule.

> **Known issue, fixed in v2.7:** a depth rule added in this release stopped
> external-volume providers from claiming their own tree, so a path-addressed CLI
> root under `/Volumes` lost its destination-name guard.

**Full changelog:** [`v2.5...v2.6`](https://github.com/agirish/sync-cloud/compare/v2.5...v2.6)

---

## v2.5

A retuned palette and a hardening pass.

### Colour
- **Terracotta** replaces amber as the attention colour.
- **Accent fills deepened** so every filled control can carry a legible white
  label, with on-accent text paired to the fill's own luminance.
- **Freshness badge** redesigned — scan freshness now lives in the status dot, the
  badge carries its own colour, and the scan action follows it.
- **Clear reads as glass**, with its background carrying the accent.

### Chrome
- **Pane nav controls are drawn in-app** rather than fought from outside: levelled
  pill heights, tinted glyphs, and a real hover state on every chrome-less and
  system-chrome button.
- **Differences bar zoned**, with its primary action fixed left-to-right; the
  difference count gained the same capsule a stale badge wears, and the sort menu
  now matches its neighbours.
- **The action bar says which pane** it is about to act on, and places itself from
  rows that are actually on screen.
- The **differences pane stays open** during a guided review.
- The Tidy rail has its own chrome back, and the count pill stops changing dialect.
- The Activity Log's **search reveal is animated**, and its severity chips count the
  history you have actually revealed.

### Filing
- Cloud Filing's Opus option moved to **Opus 5**, with the generation named in the
  model picker.

### Accessibility
- The transfer buttons are **named for VoiceOver**, and the compaction ladder is
  pinned.

### Fixes
- A filing walkthrough no longer resumes over a preview it no longer describes.
- Closed the bulk-sync exclusion in both directions, and let a sweep stand down
  mid-operation.
- Case is folded when deciding a file is already filed; a stranded review pin is
  released.
- A history wipe now asks first, and New Folder's undo no longer swallows its
  outcome.
- A delete that found nothing says so, and a wrapped busy error is no longer
  misread.
- Clearing the log clears the one you can see, not a handle nobody holds; a log the
  app could not read is told apart from one holding nothing.
- A duplicate batch keeps its hands off the folder it just called intact.

**Full changelog:** [`v2.4...v2.5`](https://github.com/agirish/sync-cloud/compare/v2.4...v2.5)

---

## v2.4

Compare actions, and a quieter Activity Log.

- **Redesigned Compare action bar** — it appears the instant a file is clicked,
  positions itself away from the selected row, flips only when it would actually
  cover the selection, and the selection can now be cleared.
- **Instant differences collapse** — the pane collapses without rebuilding, keeps
  the last file visible, and the collapsed diff bar is slimmer.
- **Activity Log chrome** — the title bar is hidden, search collapses behind a
  magnifier, surfaces are translucent and Settings-styled, and long messages wrap
  instead of being cut off.
- **The app accent carries through** the compare chrome and row selection, replacing
  the OS gray.
- **New Folder is gone from the Compare action bar**, and the pane link toggle is
  hidden in Tidy's single-source rail where it had nothing to link.
- A **new flat two-pane app icon**, a rewritten README, and a visual GitHub Pages
  feature site.

**Full changelog:** [`v2.3...v2.4`](https://github.com/agirish/sync-cloud/compare/v2.3...v2.4)

---

## v2.3

Bold dark mode, and a true-neutral accent.

- **Dark mode reworked** — a deeper base, accent glow, specular-edged cards, and a
  bolder translucent veil on Clear glass.
- **Graphite accent** — a new hue for a genuinely neutral, monochrome look.
- **Accessibility** — a caution tier in the semantic colour table, a shared 3:1
  contrast floor, and VoiceOver-proof compact fallbacks.
- **Duplicates hardened again** — cross-folder version groups stop pooling unmarked
  originals, and merges refuse to aim through keeper hard links.
- The unreadable-folder fix from v2.2 is **widened to case- and near-name variants**.
- **A failed replace can no longer lose your file** — the staged temp is preserved
  when the source can't be restored, with a recovery story that survives contact
  with reality.
- **Undo Last Run** is paired with its own run, not whatever name sits on the stack.

**Full changelog:** [`v2.2...v2.3`](https://github.com/agirish/sync-cloud/compare/v2.2...v2.3)

---

## v2.2

One design system, and a Theme to switch it with.

### Theming
- **Light / Dark / Follow macOS** — a Theme control sets the app's appearance
  independent of the system, and switching it updates everything live, down to the
  title bar.
- **Clear glass** lets the desktop through, with frosted controls and carded chrome.
- **Compare | Tidy moved into the window's title bar**, and all five Tidy lenses now
  sit under one header card.

### One visual language
- Unified badge pills, one lens-card surface, one semantic severity table, a shared
  close button and search field, real empty states, and a canonical type ramp — so
  the same idea looks the same everywhere.
- Accent, on-accent, and treemap label colours are derived from **actual luminance**,
  so text stays legible on any hue.

### Density
- **Comfortable / compact list density** extended to the file panes, Activity Log,
  Sync History, lens cards, and the Compare differences table.

### Search & automations
- **Clear Filters**, `kind:` made last-wins, and kind classes shared with Compare.
- A chip's ✕ now removes **every** occurrence of its word.
- Automations gained **Preview / Reveal** inspection.

### Scans that tell the truth
- Phantom "Missing" rows no longer appear when the scan **root itself** is
  unreadable, and permission-denied directories are treated as unexplored rather
  than empty.
- Dataless oversize files are classified as **cloud-only**, not "too large".
- A merge is refused when a source file's modification time changed under it.
- The CLI lists each name-skip's reason inline.

**Full changelog:** [`v2.1...v2.2`](https://github.com/agirish/sync-cloud/compare/v2.1...v2.2)

---

## v2.1

Search that understands what you mean, and scans that tell the truth.

### Search
- **Token search everywhere** — Compare, the Activity Log, and Tidy duplicates all
  gained a chip-based search with removable tokens and suggestions, `kind:` filters,
  and size tokens.

### Compare
- **"Scanned N ago" freshness pill** on the pane header.
- **Selection size** on the action bar, and a **folder quick-jump menu** in the header.

### Tidy & duplicates
- **Content thumbnails** in duplicate cards, and **"Compare copies"** hands a group
  straight to the Compare tab.
- **Safer grouping** — files group as "versions" only with a real marker or shared
  folder; symlinks and cloud-only placeholders are no longer mistaken for duplicates,
  and skipped-file counts are surfaced instead of going silently blind.
- A redundant copy is **re-verified right before** a merge trashes it.

### Cloud-only files
- Not-yet-downloaded files are **flagged**, with a best-effort Download; the badge
  clears once the file lands.

### Activity Log
- **Grouped by day**, with per-file operation runs folded together.

### Automations
- **One rule system** — remembered rules and automations unified, with every newly
  learned rule surfaced for review.

### Safety
- **Undo covers everything** — a full move / copy / delete undo-then-redo matrix,
  plus an Undo affordance on completion banners.
- Never auto-replace a folder from a file's "Apply to all"; no permanent delete
  offered after a merely transient trash failure.
- Fixed OneDrive name-rule false positives and an integer-overflow crash in the
  "Larger than N MB" rule.

### CLI
- Destination names are validated as the app does, and sync skips are reported by
  cause rather than assumed to be collisions.

**Full changelog:** [`v2.0...v2.1`](https://github.com/agirish/sync-cloud/compare/v2.0...v2.1)

---

## v2.0

A ground-up restructure of the window — from a provider-sidebar layout to a focused,
tab-driven workspace.

- **Persistent tab strip** with a single-source rail replaces the provider sidebar,
  pinned to a fixed height so switching tabs never nudges the layout.
- **Self-contained panes** — scanning and per-pane actions moved onto the pane
  headers, and the title bar was pared down to Logs and Settings.
- **Differences is now Compare**, with the old Details panel folded into a dedicated
  Compare inspector; Get Info routes there and the pane is resizable.
- The **Name Normalizer** returns as its own **Rename** sub-tab, and Organize's
  loose-files scan defaults to a configurable TODO inbox.
- Previewed automations are **filed for real**, one file at a time, anchored at the
  provider root.
- After filing a loose file, SyncCloud **offers to learn an Automation rule** — and
  only asks when the file actually moved.
- The comparison panes no longer re-walk their 40k-node trees on every selection,
  and the dead first click when selecting in a pane is fixed.

**Full changelog:** [`v1.4...v2.0`](https://github.com/agirish/sync-cloud/compare/v1.4...v2.0)

---

## v1.4

Three new Tidy lenses, plus a durable history you can undo from.

- **Storage Lens** — a treemap of what's eating your disk, with reclaim-candidate
  lists.
- **Sync History** — durable and exportable, with **run-level undo**; "Undo Last Run"
  is scoped to the actual run and spells out what it will reverse.
- **Name normalizer** as a batch lens, with per-row Quick Look and Show in Finder.
- **Automations** arrive as a preview-only lens — rich rule cards, grouped results,
  per-rule preview, and a Browse button for the destination.
- **Activity Log** gained on-demand "Show older history" paging.
- **Cloud spend guardrails** — a pre-flight estimate before a scan, a monthly cap,
  and a lifetime cap defaulting to $5.
- A **per-tab toggle to hide the top file panes**.
- Re-verification is instant: SHA-256 is cached by path + mtime + size.

**Full changelog:** [`v1.3...v1.4`](https://github.com/agirish/sync-cloud/compare/v1.3...v1.4)

---

## v1.3

Onboarding and visual identity — the release that made SyncCloud explain itself.

- **First-run welcome** grew into an informative **feature tour**, with a vector
  illustration per page, brand glyphs, and motion.
- **In-app Help** — a Help overlay and enriched Help menu, plus Help ▸ Welcome to
  re-summon the first-run card.
- **Provider brand hues** tint provider identity throughout, made appearance-adaptive
  by a dark-mode contrast audit.
- **Unified empty states**, and comfortable / compact list density.

**Full changelog:** [`v1.2...v1.3`](https://github.com/agirish/sync-cloud/compare/v1.2...v1.3)

---

## v1.2

AI-assisted filing — SyncCloud learns where your loose files belong.

- **The Filing lens** suggests a destination for every loose file, backed by
  on-device content signals.
- **Two engines** — on-device Apple LLM first, with an **opt-in cloud (Claude)
  classifier** for the hard cases.
- **Remembered rules** — corrections stick, with a legible, editable home in plain
  words; "Try another" re-suggests with rejection learning.
- **Cost is cut and visible** — per-scan cost reduced ~10–50×, with spend surfaced
  in the UI as last-scan, total, and history. Defaults to Haiku.
- A **confidence meter and legend**, Quick Look on Filing cards, and a rescan after
  you navigate somewhere else.
- **Settings ▸ Tidy** — a dedicated tab for Duplicates, Filing, and cloud spend, plus
  a header search that filters across all tabs.

**Full changelog:** [`v1.1...v1.2`](https://github.com/agirish/sync-cloud/compare/v1.1...v1.2)

---

## v1.1

The Tidy tab arrives, alongside a broad UX polish wave.

- **Duplicates lens** — find and resolve duplicate folders and files within one
  provider, including **overlapping-folder merges**.
- **Keeper picker** and a persistent **"Keep separate"** decision.
- **Cancellable scans** with determinate progress through the hashing phase.
- **Differences polish** — an actionable "No Scan Performed" state, per-side totals,
  per-filter counts, directional keyboard copy/move, and a visible "navigate both
  panes" toggle.
- **One icon vocabulary** for copy/move, so three features stop sharing the same
  arrows.

**Full changelog:** [`v1.0...v1.1`](https://github.com/agirish/sync-cloud/compare/v1.0...v1.1)

---

## v1.0

The first complete release: comparing and reconciling the folders you keep across
iCloud Drive, OneDrive, Dropbox, and Google Drive — a native macOS app plus a CLI.

- **Inline guided review** for working through differences one at a time.
- The action bar moved into the **native window toolbar**; invisible dividers, a
  per-pane hidden-files toggle, expanded Settings (conflict policy, startup restore,
  notifications, shortcuts).
- A **"None" accent** option, for the stock-macOS neutral look.
- **Reveal in Finder** and Quick Look on tree rows.
- **CLI** — `--strategy` defaults to replace, skips are explained, roots are
  validated, and a failure exits nonzero.
- **Safety, which is what makes this 1.0** — atomic destination replacement,
  replaced files kept recoverable, permanent deletes gated on Trash-less volumes,
  and orphaned `.tmp_` files swept.
- **Scan is ~8× faster** on large directories.

**Full changelog:** [`v0.20...v1.0`](https://github.com/agirish/sync-cloud/compare/v0.20...v1.0)

---

## v0.20

The Differences table and a theming pass — the last stop before 1.0.

- **Differences rebuilt as a dense, searchable, sortable table**, with header stat
  pills, a right-click menu, directional arrows, and an aggregate multi-select
  summary.
- **Settings becomes an in-window overlay** with a General tab; failures surface as
  structured errors carrying their own actions.
- Per-pane back/forward history, real file icons and metadata, and a ⇄ pane swap.
- Appearance gains a content surface-style picker, a tint slider, and accent-aware
  toolbars.

**Full changelog:** [`v0.19...v0.20`](https://github.com/agirish/sync-cloud/compare/v0.19...v0.20)

---

## v0.19

Sync-aware panes, and drag & drop.

- **Per-row sync status badges**, and provider names replacing "Left/Right" in
  action labels.
- **Drag & drop between panes**, double-click drill-down, and breadcrumb navigation.
- Streaming checksums, plus symlink and case-variant fixes — including a false
  all-missing diff.

**Full changelog:** [`v0.18...v0.19`](https://github.com/agirish/sync-cloud/compare/v0.18...v0.19)

---

## v0.18

End of the first development era (March 2026). Folder comparison and the CLI.

- **Compare folders** with ignore rules, diff refresh, and Copy / Move in an action
  bar.
- Progress bar, overwrite confirmation, Copy/Move-All with apply-all.
- Provider-branded panes and the first Liquid Glass design pass.
- A headless **SyncCloudCLI**.

**Full changelog:** [`v0.17...v0.18`](https://github.com/agirish/sync-cloud/compare/v0.17...v0.18)

---

## v0.17

Multi-selection and bulk move.

- Select many files at once and move them as a batch.
- Details tab, Move-to-source / Move-to-destination, and the first app icon.

**Full changelog:** [`v0.16...v0.17`](https://github.com/agirish/sync-cloud/compare/v0.16...v0.17)

---

## v0.1 – v0.16

The original March 2026 prototype, versioned by hand in the commit log itself —
`v0.1` through `v0.16.6`, all inside four days. These tags preserve that
self-versioning, one per minor.

- **v0.1 – v0.5** — the dual-pane file manager core: Finder-style cut / copy /
  paste with native paste-conflict handling, context menus, and right-click.
- **v0.6 – v0.8** — Get Info, and **undo / redo** across all file operations.
- **v0.9 – v0.11** — consistent logging and error handling, security fixes, and a
  pass over comments.
- **v0.12 – v0.16** — hidden-file toggle, Quick Look, the app icon, and the first
  real test suite.

**Full changelog:** [`v0.1...v0.16`](https://github.com/agirish/sync-cloud/compare/v0.1...v0.16)
