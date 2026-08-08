# SyncCloud — Release Notes

User-facing changes, newest first. For the full commit history see the
[repository](https://github.com/agirish/sync-cloud).

---

## v3.2 — DRAFT, not released

> **This section is a draft.** v3.2 has not been cut and this is not final copy.
> Work is still landing — the Restructure lens is in progress — so entries will be
> added and existing ones may change or be withdrawn. Nothing here has been through
> the release audit yet: before this ships, every claim below must be re-checked
> against `v3.1` (`git grep -l "<symbol>" v3.1 -- Modules SyncCloudCLI MacApp`), and
> the fixes made to features that landed *within* this range must stay out — no user
> of v3.1 was ever exposed to them. Covers `v3.1..0dc45725`.

On the v3 line, so it **requires macOS 26** — coming from 2.x, read the v3.0
section first.

The theme so far is that looking should be free. Organize's scan no longer reaches
a paid model at all — that moved to a Refine button you press deliberately — and
Compare, Duplicates and Organize all open on something instead of on an empty
panel. Around that: a Stop button for the longest operation in the app, twelve new
keyboard shortcuts, and a table that finally tells you where a file is.

### Organize: the scan is free, refining is the choice

- **"Suggest homes" no longer spends money.** It used to do everything in one
  click — filename heuristics, an on-device content read, and a classification
  pass that reached Claude whenever the cloud toggle was on. So the only button
  that produced results was also the button that billed you, and you could not ask
  for one without the other. The scan now runs entirely on-device. **Refine**, on
  the results, is what re-asks the model named in Settings about the suggestions
  already on screen.
- **This reverses what v3.1 said about the price.** v3.1 put the estimated cost on
  the setup card because the button beneath it could spend; that button is free
  now, so the card no longer quotes a price. The estimate you approve is the
  Refine pre-flight, which prices a batch it actually has in hand rather than one
  it is predicting.
- **Refining twice on one model costs nothing.** Saved verdicts key on the backend
  that answered, so the free pass and the refine pass cannot serve each other's
  answers, and a second refine on the same model is free.
- **Duplicates and Organize re-scan when you open them, when that cannot cost
  anything.** Both used to show the intro card even for a folder scanned minutes
  earlier. Results are still never restored from disk — every row carries an action
  that writes files — so the scan re-runs against the live filesystem instead.
  An automatic scan can never raise a payment dialog.

### Filing that learns from what you have already filed

- **Loose files can be routed by what a folder already contains.** Organize's
  classifier only ever saw bare folder paths, so it re-derived per file what are
  stable properties of the tree. It can now be given two things about each
  destination — what the folder *is* (its role, naming convention and whether it
  may receive a file at all) and what it has *received* (the distinguishing words
  of documents already filed there) — and rank destinations from those with no
  model call.
- **Measured on 9,558 real filed documents** choosing among ~2,950 folders, from a
  filename plus 400 characters of page 1: a bare folder list gets 12.6% right on
  the first guess, adding what the folder is takes it to 28.9%, and adding what it
  has received takes it to **58.2%** (77.5% within the top three). The gap between
  the top two candidates gives Organize its first honest confidence signal — the
  15% of files it calls high-confidence are 94% correct.
- **This needs a survey of your own tree, and there is no default to ship.** On a
  machine without one, filing behaves exactly as it did in v3.1 — the ranking phase
  is skipped entirely. *(Draft note: the survey is not yet something the app can
  produce for you. This entry should not ship as written until it is, or it
  describes a capability most users cannot reach.)*

### Compare

- **You can stop a scan.** Every lens has had a Cancel since it shipped; the
  Compare scan — which walks two entire trees and is the longest thing the app
  does — had none, so starting one against the wrong pair of roots meant waiting it
  out or quitting. The pane rung becomes **Stop** while a scan runs, and the busy
  card grows one under its title.
- **It says how long it has been running.** Not a percentage: counting the total
  first would mean instrumenting the walk's hottest loop, and a fraction that isn't
  measured is worse than a number that is. Elapsed seconds are padded so the label
  keeps one width instead of nudging its neighbours twice a minute.
- **Compare opens on what the last scan found.** It was the default workspace and
  the only one that still said "Nothing scanned yet" on every launch. It now
  restores the **summary** — a count and a date, in the past tense — and never the
  rows, because every action Compare offers against a row writes files and a
  three-day-old "Copy 412 to →" is exactly the stale-world apply the caches exist
  to prevent. The only button stays **Scan**. The summary appears only for the
  exact comparison the panes are pointed at now, both providers and both paths;
  navigate away and the old cold copy comes back.
- **A partial transfer shows you which rows failed.** The alert used to read
  "Couldn't sync 12 items. The first failure was X; the rest are in the Activity
  Log" — so finding the other eleven of four hundred meant opening a second window
  and reading a text log. The failed rows were in the table the whole time. A
  **Failed to transfer** filter now selects them, the alert names it, and the table
  lands on it when a run fails. The filter appears only while there are failures,
  and a clean run or a rescan clears it.
- **A Path column, and the selection matches the panes.** A file sitting directly
  in the compared root was unplaceable — the Name cell's dimmed parent prefix is
  empty there, and the only remaining location signal was a hover tooltip. The
  table is now Name · Change · Path · Size, with the path anchored at the compared
  folder's name. The **"Copy to" column is gone** — it restated what Change already
  said — and the location moved out of the Name cell, so long names no longer
  truncate their own location away. Selected rows now draw the app accent like
  every pane row, instead of the system's blue bar.

### Keyboard and focus

- **Twelve new menu-bar shortcuts**, all of them showing up as keycaps during the
  ⌥-hold reveal: ⌘1–⌘5 switch workspaces, ⌘[ / ⌘] walk the focused pane's history,
  ⌘R rescans, ⇧⌘N creates a folder, ⇧⌘. and ⇧⌘P toggle hidden files and the
  Columns preview, ⌘⌫ deletes the selection (after the same confirmation as a
  click), ⇧⌘R and ⇧⌘V start Review and Verify, ⌘D shows and hides the differences
  list, ⌥⌘F folds every folder, and ⌘I / ⌘L open the inspector and the Activity
  Log. Chords follow Finder wherever Finder has one.
- **⌃⇥ moves keyboard focus between the panes.** Six shortcuts — ⌘F, ⌘[, ⌘],
  ⇧⌘N, ⇧⌘P and the Columns preview toggle — resolved through whichever pane held
  the selection, which is nothing on a cold window, where the rule fell back to the
  left pane. So the only way to aim any of them at the right-hand pane was to click
  a row in it first: there was no keyboard path to the right pane at all.
- **The focused pane's provider capsule is ringed.** ⌃⇥ shipped changing no pixel —
  the panes' only "which one is active" cue modulates *selected rows*, so it says
  nothing in exactly the case ⌃⇥ exists for, a pane with nothing selected. The ring
  lands on the capsule because that is already the chip saying which pane this is.
  Compare only: on a single-source workspace there is nothing to distinguish.

---

## v3.1

Two questions this release answers that the app used to leave to you: *where is
the file I'm thinking of?* and *what is this scan going to cost me?* The panes
get a real find (⌘F), and the lenses stop re-doing — and, with Claude selected,
re-billing — work they have already done. Around those two: hold ⌥ to see every
shortcut on screen, an inspector answer for "where does this file live?", and
"Find duplicates of this" on every file row.

On the v3 line, so it **requires macOS 26** — coming from 2.x, read the v3.0
section first.

### Find in the panes

- **⌘F searches inside a pane's tree — as a find, not a filter.** Every list in
  the app already had search; the two panes, the hardest and most useful half,
  had none. Matches keep their place in the tree: the matched run is bolded,
  everything off the path to an answer dims but stays readable, and a collapsed
  folder with hits inside says "2 matches" instead of hiding them. Nothing is
  removed, because the tree's shape — where a hit *sits* — is the answer.
- **↩ and ⇧↩ walk the hits**, opening only the folders on the way to each one,
  in Tree and Columns alike; switching view mode mid-search keeps your place.
  Esc puts the field away. In Compare, each hit says **"both sides"** or
  **"left only"** — which side a copy is missing from is usually the reason for
  searching at all.
- **A search never touches the disk.** It runs over the tree the pane has
  already loaded, so a query cannot make a cloud provider download anything.
- **The magnifier joins the pane bar**, including — once — on a bar you had
  customized before it existed. Remove it and it stays removed; ⌘F works either
  way.

### Nothing unchanged is paid for twice

The lenses used to start from zero on every scan: every file re-read, every
Claude classification re-sent, every Storage panel empty until a re-analysis.
Each of those now keeps its work, on disk, across launches.

- **Organize reuses suggestions for files that haven't changed.** A file with
  the same content, under the same model and instructions, gets the suggestion
  it got last time — without asking the model, which with Claude selected means
  **without paying for it**. A "reused" pill on the results says what the scan
  got for free; **Rescan ▸ Ignore saved suggestions** asks afresh (and says that
  it re-runs the paid classification); switching models re-asks everything, and
  Settings ▸ Organize says so, shows how many suggestions are saved, and can
  clear them.
- **The price is on the button that spends it.** Organize's setup card quotes
  your last cloud run — file count, model, cost — before you start, instead of
  after. On a genuine first run it says the run is billed rather than inventing
  a number.
- **Verify and Duplicates stop re-reading gigabytes they have already read.**
  File digests persist across launches, so a rescan of an unchanged tree skips
  the reads entirely — and a cancelled scan keeps what it measured, because the
  reading had already happened. Merges keep their digests too.
- **Storage opens with your last report instead of an empty panel**, marked with
  how old the reading is — "Scanned 2h ago", amber once it is stale — because a
  saved report is a reading, not a live one. Storage is the one lens whose
  results are safe to restore: its only action is Reveal in Finder, so a stale
  row can't misdirect a destructive apply.
- **Everything kept is visible and clearable.** Saved suggestions live under
  Settings ▸ Organize; the file digests and saved Storage reports under
  Settings ▸ Advanced ▸ Saved scan data, each with its size on disk and a Clear.
  Clearing costs time on the next scan and nothing else.

### Hold ⌥ to see every shortcut

- **Hold ⌥ for a fifth of a second and every control with a keyboard shortcut
  grows a key badge**; release and they vanish. The control fades back and an
  opaque keycap takes its place, so nothing shifts and nothing is half-covered.
  Starting a chord, clicking, or typing cancels the reveal — ⌥-click still acts
  on both panes exactly as before.
- **The shortcuts were already there; now they are discoverable in passing**:
  the ⌥ hold is new, and every badged control's tooltip now names the shortcut
  beside the action — joining the ⌘/ reference window that already listed them
  all. VoiceOver hears each control's shortcut unconditionally, since a held
  modifier is not a discovery path a screen reader can use.

### Where a file lives

- **The Info inspector answers "where does this file live?"** — *This Mac
  only*, *This Mac · iCloud*, or *OneDrive only* — as the conclusion of two
  facts shown right above it: the path, and whether the content is downloaded.
  The wording is deliberately literal. "This Mac only" means the path is inside
  no cloud-synced folder — never "unprotected", and never a guess: when the
  answer can't be proved (a file mid-delete, a provider the app never
  discovered), the row shows nothing rather than something plausible.
- **Rows in a folder source carry a small ⌂ when a file is on this Mac only** —
  the mirror of the ☁ cloud-only badge, in the same quiet grey, and free: it is
  pure path arithmetic, no syscall per row. Inside a cloud source's own pane it
  never appears, because there it would mark everything and mean nothing.
- **A disabled source still counts as a second copy.** Its folder is on disk
  whether or not the checkbox is on, so disabling a provider cannot make its
  files report riskier than they are.

### Find duplicates of this

- **Every file row's context menu can ask "does this have copies?"** — the
  question Duplicates answers in bulk, scoped to the one file you're looking
  at. If the current results already cover it, you land on its group, expanded,
  marked, and scrolled into view. If not, the right scan starts first.
- **"No duplicates" is only ever said by a scan that actually looked.** A file
  outside what was last scanned gets "*wasn't in the last scan*" and a button
  that scans its own folder — not a confident all-clear borrowed from results
  that never saw it.

### Appearance

- **The segmented pickers in Settings follow the app's accent.** Choosing Cyan
  used to recolour the rail and leave Theme, Text size and List density in
  system blue. The "None" accent keeps the stock macOS look untouched — that
  being the point of "None".
- **The seam between the panes wears its swap/link capsule in the app hue
  again.** v3.0 had rested it on a neutral grey wash to sit level with the nav
  pills; floating over pane content on an already-tinted window, grey read as
  unstyled rather than as quiet. It is back to a frosted accent capsule, with
  its glyph inks bounded so every hue stays legible on it.

### Fixed

- **Switching providers no longer leaves the previous provider's Storage report
  on screen.** Every other lens cleared its results on a source switch; Storage
  kept showing numbers measured somewhere else, under a folder chip naming a
  root the window no longer showed. Read-only, so nothing could be misapplied —
  but it was a reading attributed to the wrong place.

The package suites stand at 3,034 checks with this release, and the new features
were re-reviewed in two dedicated adversarial passes after landing — nineteen
defects found, fixed, and pinned by mutation-checked tests before any of them
reached you.

---

## v3.0

The first release on the v3 line, and the first one that **requires macOS 26**.

Three things here are new rather than repaired: any folder on this Mac can be a
source, a name the cloud will reject is now reported and marked where you already
are instead of behind a tab you had to remember to visit, and the scan is roughly
twice as fast on a real provider root. The navigation above all of it went from
two levels to one.

Changes that shipped in v2.9 are not repeated here — if you are coming from v2.8,
read that section too.

### Requires macOS 26

- **The app now declares the floor it is actually built against.** `project.yml`
  and all seven packages said macOS 15 while the code had been written against 26
  for some time, so thirteen `#available(macOS 26.0, *)` guards and their fallback
  branches were still being compiled for an OS this app was never going to run on.
  **If you are on macOS 15, stay on the 2.x line** — v2.9 is the current
  maintenance release and continues to get fixes.

### One row of workspaces

- **Compare, Organize, Duplicates, Automations and Storage are five segments in
  one bar.** They used to be two levels: a `Compare | Tidy` container picker with
  the lenses nested underneath, which left Duplicates two clicks deep behind a
  word that named no task. The five were peers all along; only the nesting said
  otherwise. The layout rule underneath is now fixed rather than implied — the
  left side is always a file browser, and the right side is either the other
  cloud (Compare) or a lens.
- **Your selection survives the change.** The stored workspace is migrated once
  at launch and every old value maps forward explicitly, so you open where you
  left off instead of being dropped on Compare mid-task.
- **Settings follows the same names.** The Tidy tab — the last place in the
  product still using that word — is now **Organize** and **Duplicates**, each
  wearing the same glyph its workspace wears in the bar. Settings go where the
  work is, so Compare, Automations and Storage get no tab of their own rather
  than an empty one apiece.

### Risky names

- **Names the cloud will reject are reported instead of waiting to be looked
  for.** Rename was a tab you had to remember to visit for a problem you hit a
  few times a year. Organize's scan already walks the whole provider, and the
  name rules are pure, so the names come back on that pass — no second walk, no
  second button. When the scan finds some, a chip appears in Organize's summary
  row with its count; when it doesn't, nothing appears at all. Selecting the chip
  swaps in the same rename list as before — name, reason, proposed fix, **Fix
  all** — without the trip.
- **Both panes, Columns and the Differences table now mark the offender on
  sight**, with the reason on the tooltip. Previously a name that would break a
  sync looked exactly like every other name until you ran Organize.
- **"Fix name…" works.** The row context-menu item had never once appeared: it
  was declared in a protocol *extension*, and since an extension member has no
  witness-table entry, every call through the delegate bound statically to the
  extension's `nil` default. The item was unreachable from the day it was
  written, and nothing caught it — the app built, and a menu item that is merely
  absent looks the same as one correctly withheld.
- **Settings ▸ Organize lists the names you have kept.** Keeping a name has
  always been reversible, but there was no inventory — a kept name draws no
  badge, so nothing on screen led anywhere and "what have I kept?" could only be
  answered by walking your files and reading a context menu per file. There is
  now one row per name with a remove button, plus Clear All.

### Any folder is a source

- **A pane, a scan or a lens can be pointed at any folder on this Mac**, not just
  a cloud account. The source list was built by enumerating `~/Library/CloudStorage`
  plus a hardcoded iCloud entry, so `~` or `~/Projects` could never be a source.
  Two doors, one mechanism: **Settings ▸ Sources ▸ Add Folder…** for deliberate
  setup, and **Choose Folder…** at the foot of every pane's source menu, which
  creates the source and selects it in that pane in one gesture. Choosing a folder
  that is already a source selects it rather than making a second row for it.
- **A new "Check folder names against" setting decides whose rules a folder is
  judged by.** A folder has no naming rules of its own, so judging names against
  it would report an empty all-clear over a folder full of names OneDrive would
  reject. The useful question is "would this survive being put somewhere?", and
  only you know where — the default is OneDrive, the strictest.
- **Reset All Settings says that it removes your folder sources.** It always did;
  the confirmation previously reassured you that files on disk are untouched and
  stopped there.

### Scanning is faster

Measured on two real provider roots of about 40,000 nodes each.

- **94% of path components need no normalizing at all**, and the scan now checks
  that before doing the work rather than normalizing everything: 673,925 of
  719,361 components on those two roots. Name comparison went from about 500 ms
  to about 130 ms, and the whole pass roughly doubled in speed (1.0–1.6 s before,
  0.53–0.82 s after, across four interleaved runs).
- **Flattening a cached tree for the scan costs less than half what it did** —
  809 ms → 377 ms and 1,194 ms → 466 ms on the two roots. In the live app the
  scan's flatten phase went from 1.18 s to 0.51 s.
- **File paths are stored as native Swift strings**, so the scan stops paying to
  bridge them back from Foundation on every comparison: about 135 ms and 181 ms
  off a full load-and-scan on the two roots.
- **A debug log line no longer costs a tree walk when logging is off.** It built
  its message — about 5 ms per 40,000 nodes — before the level gate had a chance
  to drop it.

---

## v2.9

A consolidation release. The surfaces v2.8 introduced settle down, one real
data-loss path closes, and the app finally reports the version it actually is.

It is also **the most heavily tested and reviewed release in the 2.x series** —
about 10,700 lines of new tests, close to double any release before it, taking the
suite from 2,628 checks to 2,867 across four adversarial review passes. That is
where most of the work went, and it is why this list is shorter than the size of
the change suggests.

### Data safety
- **Verify All's "copy the identical files" offer can no longer act on a stale
  verdict.** Undoing a file operation while a verify pass was running left the
  offer describing files that had since moved — and confirming it could overwrite
  the bytes the undo had just restored. The offer now carries the state it was
  taken under and is re-checked at the moment the write is ordered, not at the
  click.
- **A cancelled Verify All no longer offers a partial batch.** Cancelling at 40% of
  500 files still published the verdicts it had reached, so the confirmation dialog
  opened over the top of the "cancelled" banner, offering a bulk write of whatever
  it had got through.

### Cloud files
- **A pane watches every download it starts**, not just the most recent one, so a
  second download no longer leaves the first one's row badged cloud-only forever.
- **The ☁ badge stops answering from a stale memo** — a file that has landed reads
  as local, and a path the app could not stat is no longer remembered as though it
  had answered.

### Columns
- **Opening the preview no longer hides the column it is describing.** The preview
  takes its width off the stack, which covered the deepest column — the one holding
  the file you selected — so you had to scroll right by hand to read what the
  preview was about.

### Appearance
- **The accent picker shows what it does.** Under the twelve swatches there is now
  a live preview — a filled transfer button beside a differences pill — and a
  caption naming what the colour is actually used for. It was the only section on
  the tab that explained itself neither in words nor by example.

### Settings
- **The app reports its real version.** Every release from v0.10 to v2.8 installed
  an app that called itself 1.0 (build 1) — in Settings, in `~/sync-cloud.log`, and
  in Finder's Version column. This one says 2.9.
- **Tidy's loose-files inbox is searchable.** Searching "inbox", "loose files", or
  "TODO" in Settings found nothing, in every 2.x release the control has shipped in.

### Launch at login
- **A login-item update that fails no longer discards the toggle you set while it
  was in flight.** The failure path re-read the service's real state and overwrote
  your switch with it, silently throwing the change away.

### Automations
- **A rule imported, bulk-toggled, or undone no longer re-writes itself.** An
  external change to a rule's enabled state was echoed back as though you had
  flipped the switch — at worst re-entering the very undo that caused it.

### Performance
- **The comparison bar lays out nearly three times faster, and you feel it wherever
  the comparison redraws.** It used to work out which layout fit by building six
  whole toolbars and measuring them — each one materialising both menus, the
  per-filter counts and every transfer label. It now computes the width
  arithmetically and offers the layout engine two. Measured at 900pt: **68.4ms →
  23.9ms per layout pass**, about 44ms of main-thread work removed. The bar's body
  re-evaluates on every render, so that saving lands every time the comparison is
  redrawn — when you point a pane somewhere new, when the selection changes, and
  once per copied file during a bulk sync.

### Fixes
- The destination picker's search says when it is showing a partial answer instead
  of presenting the first N matches as all of them, and its cards stop
  double-bordering.

**Full changelog:** [`v2.8...v2.9`](https://github.com/agirish/sync-cloud/compare/v2.8...v2.9)

---

## v2.8

A destination picker of our own, a preview beside the columns, and a pane bar you
arrange yourself.

### Removed
- **Cross-pane drag & drop is gone.** In practice it had not worked for a long time
  — the drag would lift, but no target ever accepted the drop — so what was on
  screen was an affordance that did nothing. Rather than leave it there, it is
  removed outright in v2.8, and Help and the shortcuts panel no longer teach it. Use
  the transfer buttons or the new destination picker.

### Data safety
- **Three ways a mutation path could destroy what it was saving** are closed.

### Sending files somewhere
- **Organize gets a destination picker of its own** instead of the system panel,
  floated over the window and dressed in the app's own surfaces. It names what a
  move is about to collide with *before* you confirm it.
- **The Tidy rail can send a file somewhere**, and a cross-pane transfer now says
  where it actually puts things.

### Preview
- **A selected file previews beside the columns** — in the Tidy rail and in the
  comparison panes, with the toggle in the pane header.
- The Tidy rail draws columns, a lone column fills its area, and columns are lifted
  off their width floor.

### A pane bar you arrange
- **The pane bar is a canvas you arrange yourself** — drag the controls you use
  onto it, drop the ones you don't, from a customize sheet.

### Performance
- **The file panes stop re-rendering on unrelated state**, the inspector's stat
  moves off the main thread, and the panes stop re-arming a timer and re-statting
  every frame.
- **Tidy and the merge planner now use the content-hash cache**, so neither pays
  again for hashing the other already did, and the merge planner stops re-asking
  what the directory walk already told it.
- A row's fonts are resolved once per pane instead of once per row, bulk-operation
  progress is throttled to one update per percent, and the pane bar computes the
  rung it needs instead of building ten to find it.

### Fixes
- The Tidy rail stops striking out and badging rows with comparison state it has no
  business showing.
- **Space previews the file the app says is current.**
- The overlay cards stop throwing away the Clear setting, and a superseded metadata
  load can no longer claim the memo ahead of the current one.

**Full changelog:** [`v2.7...v2.8`](https://github.com/agirish/sync-cloud/compare/v2.7...v2.8)

---

## v2.7

Browse your folders in columns.

### Columns
- **A new pane view mode, and the default** — panes render as columns, the way
  Finder does, so you can see the path you took instead of just where you landed.
- **Drilling into a folder mirrors onto the linked pane**, keeping both sides in
  step.
- The header shows **one location** for the pane, and the pane arrows understand
  columns before they consult the focus history.
- A click on empty space **puts the selection down**, and a linked breadcrumb click
  reaches the folder it names.

### Scrolling that behaves
- The column stack scrolls **the way AppKit scrolls**, bounce included, and is
  pulled home when the platform's bounce strands it.
- A wheel gesture **locks to its dominant axis**, so a vertical scroll does not
  nudge the stack sideways.

### Clicks
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
- **Sections are selectable and collapsible**, with **Collapse All** on the
  differences bar.

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
- Clearing the stored API key now reports whether it actually succeeded.
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
  positions itself away from the selected row, and the selection can now be cleared.
- **The differences pane can be collapsed** — a show/hide chevron replaces the
  drag-only divider, and the last file stays visible.
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
  when the source can't be restored.
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
- **Unreadable directories no longer mint phantom "Missing" rows** — a
  permission-denied directory is treated as unexplored rather than empty, the scan
  root included.
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
  at a fixed height.
- **Self-contained panes** — scanning and per-pane actions moved onto the pane
  headers, and the title bar was pared down to Logs and Settings.
- **Differences is now Compare**, with the old Details panel folded into a dedicated
  Compare inspector; Get Info routes there and the pane is resizable.
- The **Name Normalizer** returns as its own **Rename** sub-tab, and Organize's
  loose-files scan defaults to a configurable TODO inbox.
- Previewed automations are **filed for real**, one file at a time, anchored at the
  provider root.
- After filing a loose file, SyncCloud **offers to learn an Automation rule** — and
  asks only when the file actually moved.
- The comparison panes no longer re-walk their 40k-node trees on every selection,
  and the dead first click when selecting in a pane is fixed.

**Full changelog:** [`v1.4...v2.0`](https://github.com/agirish/sync-cloud/compare/v1.4...v2.0)

---

## v1.4

Three new Tidy lenses, plus a durable history you can undo from.

- **Storage Lens** — a treemap of what's eating your disk, with reclaim-candidate
  lists.
- **Sync History** — durable and exportable, with **run-level undo**: "Undo Last
  Run" names the run it will reverse and itemizes it before it fires.
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

- **A first-run feature tour**, with a vector illustration per page, brand glyphs,
  and motion.
- **In-app Help** — a Help overlay and enriched Help menu, plus Help ▸ Welcome to
  re-summon the first-run card.
- **Provider brand hues** tint provider identity throughout, adapting to light and
  dark.
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
- **Cost is visible and cheap** — spend is surfaced as last-scan, total, and
  history, and the classifier defaults to Haiku to keep a scan to cents.
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
