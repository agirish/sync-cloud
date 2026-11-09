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
- [ ] ~~**Progress overlay animates.**~~ Superseded 2026-10-25: the dialog is gone (BZ); see
  "Long runs in the toolbar capsule" below.

## Single window (Wave 2E)

- [ ] **Reopen keeps state.** Navigate both panes somewhere, toggle hidden files, close
  the window (⌘W), click the Dock icon → the window returns with the same panes,
  navigation, and hidden-files toggle; no provider flip, no rescan spinner.
- [ ] **No New Window.** File menu has no "New Window"; ⌘N is New Text File and never opens a window.
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
  right-click → "Paste Here" is disabled; after Copy/Cut it enables.
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
  the Glass effect setting (Solid = opaque panel; Clear/Frosted = glass).
- [ ] **Sidebar + article.** Topics are grouped into five sections; clicking one shows its
  article on the right. "Reading the list" shows the colored difference-badge legend.
- [ ] **Search narrows.** Type in the sidebar search (e.g. "checksum", "keeper") → the list
  filters to matching topics; clearing it restores all. "No topics found" for gibberish.
- [ ] **Related chips jump.** Click a related-topic chip at the bottom of an article → the
  selection moves to that topic.
- [ ] **Dismissal.** ✕, Esc, and clicking the dimmed backdrop all close it. Opening Settings
  (⌘,) while Help is up closes Help (they never stack).
- [ ] **Help-menu items.** Set Up SyncCloud… opens the setup sheet; Reveal Log File in Finder
  selects ~/sync-cloud.log. Window ▸ Activity (⌘L) and Window ▸ Keyboard Shortcuts (⌘/)
  open their windows; SyncCloud ▸ About SyncCloud shows the standard About panel.

## CLI (Waves 1D, 2F) — spot checks (e2e-verified during the review)

- [ ] `synccloud sync --help` documents `--strategy` default `replace` and Trash
  recoverability.
- [ ] Sync with a failure exits non-zero; the summary explains skipped files.
- [ ] Pointing `-L`/`-R` at a nonexistent path errors clearly (exit 64) instead of
  scanning as "everything missing".

## Ambient surfaces (2026-08-04) — what no fixture can judge

The classifier, the inspector rows and the handoff are all covered by green tests
(`FileLocationTests`, `DetailsWhereItLivesTests`, `DuplicateReveal*Tests`,
`DuplicateRevealCoordinatorTests`, `PaneDoorDelegateTests`). The `⌂` row badge this section once
covered was removed in 5.4; a folder's containment is now the inspector's *Where it lives* row.

The "typing your own query retires the named answer" check that used to sit here is **gone
because it became testable**: the rule was rewritten from clearing-on-every-write-path to a
declarative gate (`DuplicateReveal.namedAnswer`), which is pure and now pinned by
`aQueryTheHandoffDidNotWriteRetiresTheAnswer`. That is the better outcome than a checkbox — if a
manual check can be turned into a gate, turn it into a gate.

- [ ] **Touching a card ends the landing mark.** Right-click a file that has copies → *Find
  duplicates of this* → land with its group expanded and ringed in the accent. Click any card's
  header → the ring goes, and does not come back until the next handoff. (Still manual: `@State`
  written on an uninstalled `LensWorkspaceView` does not persist — probed and confirmed — and a card click
  cannot be driven headlessly.)

One thing worth an eye that no fixture can judge:

- [ ] **The inspector's three rows read top-down as evidence → conclusion.** Path, then *On this
  Mac*, then *Where it lives*. The pill should feel like it follows from the two rows above it
  rather than arriving from nowhere.

## v3.1 review fixes (2026-08-04) — the two that stayed view-level

Everything else from that review is pinned by a mutation-checked test. These two are SwiftUI
wiring, which no `swift test` process can drive (a `Button` is not an `NSControl`, and a sheet's
`onDismiss` needs a real presentation).

- [ ] **Clearing spend history updates the Organize setup card.** Organize ▸ *History* ▸ **Clear
  History** ▸ **Clear Spend** in the question that follows (Cancel is the default, and must clear
  nothing) ▸ close the sheet. The setup card's *last run ~$x.xx* must be gone, not still quoting
  the run you just erased. (The bug: `LensWorkspaceView` cached the figure and presented the sheet with no
  `onDismiss` — `SettingsView` presents the same sheet and always got this right.)
- [ ] **Settings ▸ Advanced ▸ Saved scan data reads and clears.** Both rows show a size after a
  Duplicates/Verify run and a Storage analysis respectively; **Clear** takes each to *None* and
  disables its button. Then run a duplicate scan and re-open the tab — *File digests* has a size
  again, which is the cache doing its job rather than the Clear having failed.

## Round-2 review fixes (2026-08-05) — the one that stayed view-level

Everything else from the second review pass is pinned by tests (the reveal nonce, the request
retirement callback, the recovery button's coordinator entry, the landing gates, the spend-change
signal, the write-queue ordering). One host wiring cannot be:

- [ ] **An answered "Find Duplicates of This" does not replay after a trip through Compare.**
  Right-click a file with copies → *Find Duplicates of This* → land on the ringed group. Set a
  match-type filter and type a query. Switch to Compare, then back to Duplicates. The filter and
  query you set must still be there — no re-scroll to the old group, no re-cleared search. (The
  LensWorkspaceView-side callback is tested; what a unit test cannot reach is `ContentView` actually
  clearing `duplicateRevealRequest` in response — two lines behind `if !isRunningTests`-free but
  view-mounted wiring.)

## Tab-strip persistence (2026-08-15) — the host wiring no fixture reaches

The store side is pinned by `swift test`: the scope/stack cut and its clamp, both back-compat
directions, the seed-state rule, and per-key isolation between the two panes.

`ContentView`'s side is pinned by **`SyncCloudTests/PaneTabWiringTests.swift`**, which `swift test`
does *not* run — `MacApp` is in no SPM package, so those only compile under CI's second step
(`xcodegen` + `xcodebuild test`). They are source scans: they can prove both panes are restored,
that the swap saves both strips, and that the persistence modifier watches both sides. **Run them
locally before claiming this area is green** — `xcodebuild build` alone does not compile them, which
is how a broken call-site scan reached CI once already.

What no scan can judge is whether the restored thing is *right*: the column count, the two strips
not crossing, and a swap surviving a relaunch. Those are below. This change's one regression
(`3f71cb7e`) lived in that same host half, so they are worth walking once.

- [ ] **A drilled column stack comes back.** In Browse, from the source root, click down four or
  five folders so the pane shows that many columns. Quit (⌘Q), relaunch → the same number of
  columns, not one full-width one. The breadcrumb was never the tell here: it reads the same either
  way, so **count the columns**.
- [ ] **…including a tab you never re-rooted.** Do the above with a single unpinned tab, drilling
  straight down from the root and never clicking a breadcrumb crumb above it. That tab's scope is
  empty, which is the shape that made the whole restore skip itself. The strip must come back.
- [ ] **Compare's right pane keeps its own.** In Compare, drill the right pane a few columns deep
  and open a second tab on it. Quit, relaunch → the right pane returns with both its tabs and its
  columns. Previously it seeded one tab at its stored folder.
- [ ] **The two strips do not cross.** With different tabs on each side, quit and relaunch → each
  pane gets its own back. A left tab appearing on the right (or the panes' selected tabs following
  each other) means the two keys have crossed.
- [ ] **Swap, then relaunch.** Set up clearly different strips on the two panes, press ⇄, then quit
  and relaunch **without touching anything else**. Both panes must come back the way the swap left
  them. Restoring one side from before the swap and the other from after is the failure this
  double-save exists to prevent, and only a relaunch shows it.
- [ ] **A pane with nothing stored is unchanged.** Hardest to stage now that both keys exist: delete
  `browseTabsRight` from the app's defaults while it is quit, then launch → the right pane opens at
  its last folder exactly as it did before this shipped, rather than at the root.

## Which pane a tab verb aims at (2026-08-17) — the one destructive outcome in the feature

Every strip-aimed verb calls `noteWorkingIn`, which sets `focusedPaneSide`, which is what ⌘W reads
to decide whether it closes a **tab** or the **window**. Aiming a verb at the wrong pane therefore
does not misplace a highlight — it closes the window out from under a pick the user can still see.

That polarity is now driven by `PaneSideChoice.own` and tested for real, and nineteen mutations of
it are killed by name. What no test reaches is the aim moving under a verb the user did not think of
as a navigation — Copy Path is read-only and moves it too. That is deliberate and consistent with
clicking a chip, but nothing announces it, so it is worth one walk.

**Read this before running any of the three — an earlier version of these checks could not fail.**

- **There is no focus ring to watch.** `focusedPaneSide` (`FileSyncManager.swift`, and its own
  declaration says so) deliberately does not feed the action bar, which draws off
  `PaneLogic.activePane` instead, and nothing else renders it. A check written as "watch the ring
  follow Copy Path" is unfalsifiable: nothing on screen changes whether the code is right or wrong.
  **The only observable is the log line** written by `noteFocusedPane`
  (`FileSyncManager+Navigation.swift`) — *"The pane-scoped chords (⌘W, ⌘T, ⌘F) now aim at … rather
  than …"*. It is Info, the shipped level, so `tail -f ~/sync-cloud.log` while you work is the
  instrument. Note it is deliberately silent on a no-op, so *no line* means
  the aim was already there.
- **Staging the verb also aims the verb.** Every route to a pinned or second right-hand tab runs
  through `tabAction(isLeft:)`, which calls `noteWorkingIn` unconditionally — so by the time you
  reach the verb under test, the aim is already on the right pane and ⌘W closes a right tab whether
  the code is correct or broken. **Every check below therefore has an explicit re-aim step: click a
  row in the LEFT pane after staging and before the verb.** It must select a row — an empty click
  answers with the current side and is a no-op — and the log line is your confirmation it took.
- **Preconditions.** Compare mode with both panes visible; the seam's **🔗 link toggle OFF** (linked
  navigation changes where a folder opens, so it changes what you are staging); and the right strip
  must hold **at least two** tabs before any ⌘W, or you hit `closeTab`'s last-tab branch, which
  closes the window on correct code and looks exactly like the bug.

Checks, each staged so that a broken build and a correct one differ:

- [ ] **Copy Path does not cost you the window.** Put **two** tabs in the right strip. Click a row
  in the **left** pane (log: aim moves left). Now right-click a right-strip chip ▸ **Copy Path**,
  then press ⌘W. Expect: the log says the aim moved to the right pane on Copy Path, the **right**
  pane loses a tab, and the window stays open. Before this landed, Copy Path was the one strip verb
  that never moved the aim, so ⌘W went to the left pane and took the window with it.
- [ ] **Unpin re-aims too.** With two tabs in the right strip, pin one (right-click ▸ **Pin Tab**).
  Click a row in the **left** pane to move the aim back. Then right-click the pinned chip ▸ **Unpin
  Tab** and press ⌘W. Expect: the right pane loses a tab, window stays open. Without the re-aim step
  this check passes on any build, because pinning aimed the chords right in the first place.
- [ ] **The line names the pane and the reason.** While doing either walk, confirm the log line
  actually names the side it moved to and a human reason (*"Copy Path from a browse tab's menu"*,
  *"a browse tab verb was aimed at this pane"*). A move that happens silently, or one that names the wrong
  pane, is the failure — this is the check that the instrument itself is honest.

**What was here before, and why it is gone.** This section used to assert that "the unpin door sat
inside the `if pinned` branch" until `b1b0a56d`. Both halves are wrong. `git log -S 'if pinned {' --
MacApp/ContentView+PaneTabs.swift` returns exactly one commit, `18babda6`, and there the string is
**prose in a doc comment** recording a mutation that was tried and killed — the shipped code always
called `noteWorkingIn` unconditionally through `tabAction`. A mutation artifact had been written
into a checked-in document as if it were release history. And the call was added by `becf9cbd`, as
that commit's own body says; `b1b0a56d` only gave Copy Path's log line its side and tab. Do not
reintroduce a "regression fixed" note here without a commit that shows the defect shipped.

## Browse's status bar, on a real cloud tree (roadmap RD6, 2026-09-07)

**What the unit tests cannot reach.** `SF_DATALESS` is an `SF_` flag: `chflags` refuses it to
anyone but root, and only a File Provider ever sets one. Every test of the census therefore runs
against a stubbed `lstat`, which proves the walk and the arithmetic and proves nothing at all about
the flag being there to read. The cost of the walk is the other half: 40,000 stats against a
provider's synthetic filesystem is not a thing a mock can time.

Preconditions: Browse (⌘1), pointed at a real iCloud or Dropbox root with a deep tree — the more
cloud-only files the better. `tail -f ~/sync-cloud.log` beside it for the load lines. At the
shipped Info level only a load of 2 s or more, or one with no known ending, writes its `[load]`
line; set Settings ▸ Advanced ▸ Log level to Debug to see every start and outcome.

- [ ] **The cloud-only count lands, and it is not zero.** Point Browse at a provider root with
  files you know are evicted (Finder shows them with the ☁ badge). The segment reads `— in the
  cloud only` while the rows are already usable, then becomes a number. **A `0` that never moves is
  the failure this check exists for**: it means the flag is not being read, and no unit test can
  tell you that. Cross-check the magnitude against Finder — select the folder, ⌘I, or just scroll
  and count badges in a small subfolder.
- [ ] **The rows arrive before the count does.** The whole design is that the census is paid where
  nobody is waiting. If the folder itself feels slower to open than it did before, the walk has
  landed on the load path and that is a regression, not a slow census.
- [ ] **It restarts, and the dash comes back.** Navigate into a subfolder, or press ⌘R. The count
  returns to `—` and then to a new number. A count that stays put across a navigation is describing
  the tree you left.
- [ ] **Downloading a file moves the number.** Right-click a cloud-only file ▸ Download. When the ☁
  badge clears, the census has not re-run (nothing republished the tree), so the total is expected
  to be one stale. Press ⌘R and confirm it drops by one. **This is a known and accepted looseness**
  — recorded here rather than in a test because the honest fix is a census that watches downloads,
  and that was not built.
- [ ] **"Scanned N ago" is about the listing, not about a comparison.** Open a folder, wait a few
  minutes, navigate away and back. It must say the minutes, not "just now" — the cache hit carries the
  walk's age. Then ⌘R and confirm it resets. (In Compare, ⌘R also runs a comparison scan; the bar is
  not there, which is the point.)
- [ ] **The ladder sheds.** Drag the window narrow with three files selected. The freshness goes
  first, then the cloud-only count, then the selection; the item count is still there at the
  narrowest width the window allows, un-truncated.
- [ ] **VoiceOver reads all four at any width.** With the window narrow enough that only the item
  count is drawn, VO-arrow onto the bar: it must still speak the selection, the cloud-only count and
  the freshness — and, on a listing older than an hour, the words "may be out of date". Colour is
  the only other carrier of staleness, which is why this one is on the list.
- [ ] **View ▸ Status Bar, and where it is greyed.** Untick it on Browse: the bar goes, and the pane
  takes the room back with no animation. Switch to Compare, Organize or Edit — the item is greyed,
  because none of them draws the bar. Switch back to Browse and it is live again, still unticked.
  Quit and relaunch: the preference survives.

## The guided setup sheet (v5.4)

**Rehearse it on a fresh machine, not on yours.** Every screen after the first behaves differently
on a Mac that has never been surveyed, and that is the one machine nobody working on this app is
using. Move the profiles directory aside and put it back afterwards; the draft file goes with it:

```sh
defaults delete com.abhishekgirish.SyncCloud hasCompletedSetup
defaults delete com.abhishekgirish.SyncCloud hasSeenFirstRunWelcome
mv ~/Library/Application\ Support/SyncCloud ~/Library/Application\ Support/SyncCloud.aside
open -a SyncCloud && tail -f ~/sync-cloud.log
# afterwards: rm -rf the directory the rehearsal created, mv the .aside back, and set both flags true
```

- [ ] **It opens on Welcome, and the log says so.** `Setup opened on Welcome` within a second of
  the launch line. On a Mac that has been through setup it opens on Locations instead, with the
  answers filled in — that is the re-run path, and Back is absent there.
- [ ] **Learn advances at once.** Press Learn and the sheet moves to You immediately; You shows
  "Reading names…" where the found names go, and the names appear in place when the walk lands.
  **Continue never waits** — People and Countries are reachable before the walk is done.
- [ ] **The walk really runs on a machine with no profile.** `Setup walk read N folder(s)…` in the
  log. This is the check that fresh-install path exists at all: it refused with `no profiles
  directory was configured` until 2026-09-08, because nothing handed the app a profiles directory
  until a profile was already there.
- [ ] **Back from Structure writes nothing.** `ls ~/Library/Application\ Support/SyncCloud/profiles`
  before and after going Back to Countries and forward again — the directory list must be identical.
  Every press of Back rebuilds the preview in memory; a new `walk-…` directory means it did not.
- [ ] **Save writes exactly one profile**, and the log says `Setup saved profile 'walk-…'`. With the
  reading switch on, the button reads "Save and Start Reading" and a survey starts; with it off it
  reads "Save" and nothing is read.
- [ ] **Structure over a reading in progress counts nothing.** Learn a big folder and Continue to
  Structure at once: "Reading names…" in the tree's box, dashes for folders, files, loose files and
  countries, no lens picker or gray-words legend, a greyed-out "Read documents" switch, and Skip
  Saving. Press Skip Saving just as the reading lands: the log says `Skip Saving on Structure`, and
  no `walk-…` profile is written. Learn Again over a finished reading shows the same, never the old
  tree.
- [ ] **A reading that fails says so on Structure.** On a Mac with a folder profile, run setup
  again from Help, Learn a scratch folder made unreadable with `chmod 000`, and Continue to
  Structure: it shows "Couldn’t read that folder" with the reason and Try Another Folder…, not this
  Mac's profile read-only, and its button is Continue. Restore the folder's permissions after.
- [ ] **The reading strip is on every Organize lens.** Switch through To File, Duplicates, Renames,
  Restructure, Rules and Storage while the survey runs: the line is under the header on all six,
  with Pause and Stop. Quit and relaunch mid-survey: it comes back as the interrupted strip with
  Resume.
- [ ] **Skip on Learn drops two screens.** The crumb strip loses Countries and Structure, and
  Locations through People keep the numbers 1 to 4 — no gap, no renumbering. Summary then reads
  "You have not learned a folder tree yet" with a Learn button.
- [ ] **The text-size stepper works on every screen** and moves through all ten sizes, not four.
  Check that View ▸ Text Size ▸ Bigger agrees with it afterwards.
- [ ] **Esc keeps the answers, not the finish.** Type a name on You and press Esc, then reopen
  setup from Help: the name is there. On a Mac that hasn't been set up yet (no folder profile),
  quit and relaunch: setup offers itself again. ✕ and a click outside do the same. A reading that
  was never saved is gone.
- [ ] **Every other way out keeps the answers too.** Type a new name on You, then press ⌘, and
  close Settings; reopen setup from Help: the name is there. Repeat with ⌘?, with closing the
  window, and with ⌘Q and a relaunch.
- [ ] **Settings ▸ General ▸ Run Setup Again…** opens the sheet at Locations.
  **Settings ▸ Advanced ▸ Reset Setup…** asks first, then opens it at Welcome and makes it offer
  itself on the next launch.
- [ ] **Do not time it.** Setup claims no duration anywhere, by decision, so there is no number to
  confirm and none to add. The reading offer's "About N h (or min) for N documents" is a different claim and
  is checked against the count it names.


## Result messages in the pane (Banner Room CA/CB/TE207/TE211, 2026-10-25)

Built and installed with the screen saver up, so nobody has looked at these on screen yet. The
placement maths and the message's layout at 250/400/560pt are covered by tests; this is what is not.

- [ ] **Delete twice from the header.** In Browse, select a file near the top, click the header's
  Delete, confirm → "Deleted …" appears at the list's foot and the header's Delete is clickable at
  once. Select a file near the BOTTOM and delete it → the message docks at the list's top instead,
  never over the row that took the deleted one's place.
- [ ] **Compare: the acting pane only.** Delete in the right pane → the message is in the right
  pane's list, beside the action bar if one is up, never over it; the left pane and the seam's ⇄/🔗
  stay clear.
- [ ] **To File's "Save as Rule…".** File a loose file with File Here → "Filed …" at the lens's foot
  with Undo and Save as Rule…; the cards did not move. Click it → the offer opens in a popover and the
  message stays while it is open. Ignore one → the offer is gone with the message after 5 s.
- [ ] **PDF tool from a pane.** Right-click a PDF ▸ PDF Tools ▸ Rotate All Pages → progress at the
  toolbar's capsule while it runs (BZ, 2026-10-25), then a pane message with Open in Edit and Reveal
  in Browse that leaves after 5 s.
- [ ] **Clicks still land in Edit and Organize.** Both halves now carry the click reporter: select
  text by dragging in Edit, click a PDF's page, drag a card's button in Organize → all behave as before.
- [ ] **VoiceOver.** With VoiceOver on, delete a file → it says "Deleted “…”. Undo available, Command Z".

## Native controls in the app's accent (DS4, 2026-10-25)

Switches and progress bars render grey offscreen, so no test can see their fill; the slider and the
checkbox are render-tested inline and in a sheet, nothing else is. Do each step twice: Settings ▸
Appearance ▸ Accent **Coral**, then **None**. Under Coral every control below fills with the deepened
coral the segmented pickers use; under None, with the Mac's own accent (System Settings ▸
Appearance), and nothing coral is left.

- [ ] **A switch.** Any switch in Settings, on → its track is the accent.
- [ ] **A checkbox.** Any checkbox in Settings (General, a provider's options), ticked → its box is
  the accent, the tick white.
- [ ] **A slider.** Settings ▸ Appearance ▸ Tint → the filled part of the track is the accent, the
  same colour as the selected Coral swatch's ring, not blue.
- [ ] **A progress bar.** Start a long run (Organize ▸ Duplicates ▸ Merge into Keeper on a large
  group) → the toolbar capsule's bar (`ProgressCapsule`) fills with the accent.
- [ ] **A sheet's checkbox.** Organize ▸ Restructure, Plan… on a finding → the Plan sheet's
  checkboxes are the accent, not blue. (Sheets take the hue through `presentedNativeControlAccent`;
  before it they kept the Mac's accent on every hued window.)
- [ ] **The other windows.** Open Activity (each of its tabs) and Keyboard Shortcuts → any switch,
  checkbox, slider or progress bar in them is the accent too.
- [ ] **Button words stay readable.** In both appearances, a bordered button whose words wear the
  accent (Edit's Show Text Files, the PDF tool sheets' Cancel) reads clearly on its bezel; in dark
  its words are white.

## Long runs in the toolbar capsule (Banner Room BZ/TE205/TE206, 2026-10-25)

Built and installed with the screen locked, so nobody has seen the capsule in the real toolbar. The
capsule's two rungs are snapshot-tested, the toolbar's width ladder is swept, and the lock's chords
and key refusals are tested; this is what is not.

- [ ] **Merge, then read.** Organize ▸ Duplicates, Merge into Keeper on a large overlapping group →
  no dimming; the capsule in the toolbar's middle says "Merging “…”" with a bar and a count, and the
  current file while the pointer is over it. Browse another folder, select a file, open Preview and
  Quick Look (Space) — all work while it runs.
- [ ] **Writes wait, and say why.** During that merge, the pane header's Delete and New Folder, the
  row menu's Rename / Move to Trash / Copy to…, and Compare's Copy are greyed; hovering one says
  "Wait for the merge to finish". ⌘⌫ and ⇧⌘N are greyed in the menus; ⌫ in a list or ⌘V puts the
  same sentence in a message instead of acting.
- [ ] **Stop from the capsule.** Click the capsule's ✕, or press ⌘. → the merge stops between copies;
  Esc does not stop it.
- [ ] **Narrow window.** Drag the window to its narrowest (760pt) during a run → the capsule is a ring
  with its ✕, still in the toolbar, with Settings and Activity Log still visible beside it.

## Two runs at once in the capsule (Run Room TE217–TE219, 2026-10-27)

- [ ] **The newest run, and a count.** Save as PDF on six Word or Pages files from a pane's row menu,
  then at once start a duplicate merge in Organize → the capsule shows the merge and, where its ✕ was,
  "2 ⌄". Hover: the tooltip lists both runs, newest first.
- [ ] **Each run has its own Stop.** Click "2 ⌄" → a list under the capsule: the merge with Cancel (the
  blue default button) and the Save as PDF with Stop. Click Save as PDF's Stop → it stops after the
  file in hand, its message says how far it got, and the merge goes on; once it has stopped the list
  shows the merge alone. Close the list → the capsule's ✕ is back for the merge.
- [ ] **⌘. never stops a run unseen.** With both running, press ⌘. → the list opens and nothing stops;
  ⌘. again (or Return) cancels the merge only.
- [ ] **Narrow window.** At 760pt with both running → the ring and a filled "2" badge beside it; a click
  on the badge opens the same list.

## Activity: the popover, Recent and one window (Run Room TE220–TE224, TE232, 2026-10-27)

- [ ] **Click the capsule.** During any run, click the capsule (not its ✕) → a popover under it:
  Running with the run and its Stop, then Recent. Let the run end with the popover open → the
  capsule stays, reading "Nothing running", until the popover closes.
- [ ] **Recent keeps every message.** Delete a file, then rename another within 5 s → the pane shows
  only the rename, but Recent lists both, newest first. During a merge press ⌫ on a file four
  times → one row, "Wait for the merge to finish ×4".
- [ ] **A stale Undo says so.** In Recent, the delete's Undo is greyed: "Undo the newer “Rename”
  first." ⌘Z once in the main window (the rename comes back undone) → the delete's Undo is live
  again; click it → the file is back, and the row says "Already undone".
- [ ] **One window.** Window ▸ Activity, ⌘L, or the toolbar's Activity button → one window with
  Now · History · Log. Window ▸ Sync History opens it on History; there is no Activity Log item.
  Close it on Log, press ⌘L → it opens on Log.
- [ ] **Links down a level.** After a copy from Compare, its Recent row's Show in History → History,
  "One run · N records", only that copy's rows; Show All brings back the rest. Show in Log → Log,
  "Only 14:02:11 – 14:06:07", the lines of those minutes.
- [ ] **A stop is grey.** Save six files as PDF and press Stop after the second → Recent's row has a
  gray stop glyph and "Stopped. Saved 2 of 6 as PDF."; stop a copy while away in another app → no
  red dot.
- [ ] **The dot.** Start a large merge, switch to another app, let it end with a skipped file (or any
  warning) → the toolbar's Activity button has a red dot; opening Activity shows Now and the dot
  goes. A success while away leaves none.
- [ ] **Edit's own results.** In Edit, Compress the open PDF → its banner in Edit, and a row in Recent.
  Fill & Sign → Save a Copy → a row too. A file changed on disk (the reload banner) adds no row.

## Activity: long scans, notifications, VoiceOver (Run Room TE226–TE228, 2026-10-27)

- [ ] **Long scans in Now.** Start Read documents in Organize, then open Activity → Now lists
  "Reading documents · N of M" with Show and no Stop; the toolbar has no capsule for it. Pause it on
  its card → the row says "paused at"; Show brings Organize forward on the card.
- [ ] **A notification opens its row.** General ▸ Notify when operations finish in the background on.
  Start a large copy, switch to another app, let it end → the notification's title is the run
  ("Copying 1,204 items"), its body the message and any skipped files. Click it → SyncCloud comes
  forward with Activity on Now and that row marked.
- [ ] **VoiceOver.** With VoiceOver on, end a Compress and a Save as PDF within a second of each
  other → one announcement, "2 new in Activity: …". A failure interrupts what VoiceOver was reading;
  a success waits. Focus the capsule with two runs → "Activity, 2 running. Merging Photos, …".

## Run endings in the capsule; batch PDF runs leave their sheet (Run Room CG, CH, CU, TE230, 2026-10-27)

- [ ] **Ending elsewhere.** Start a duplicate merge in Organize, switch to Browse before it ends → its
  "Merged …" message shows in the capsule (✓, the words, Undo) for five seconds, not in Browse's
  pane; then the capsule goes. It is in Activity's Recent. Let it end with a skipped file instead →
  ⚠ in the capsule, and afterwards the red dot on the Activity button.
- [ ] **Ending where it started.** The same merge, staying in Organize → the message is Organize's,
  as before; nothing in the capsule.
- [ ] **A message over a run.** Start a Compress of several PDFs from Browse, then a merge in
  Organize; stay in Organize when the Compress ends → the capsule says "Saved N compressed copies ·
  Reveal in Browse" with "1 ⌄"; after 5 s the merge's progress is back.
- [ ] **No jump.** At a width where the workspace bar shows its labels, with nothing running, let a
  run's ending reach the capsule → the labels and ⌘K's "Go to…" stay as they are; at the narrowest
  window it shows as the ring's ✓, its words in the tooltip. Click the capsule while it says it →
  Activity opens under it and the labels still stay as they are.
- [ ] **Batch sheet goes.** Select three PDFs in a pane, PDF Tools ▸ Compress → the sheet asks for the
  strength; Save → the sheet closes and the capsule shows "Compressing 3 PDFs · 1 of 3"; browsing and
  Quick Look work meanwhile; its Stop stops after the file in hand. Rotate All Pages on several opens
  no sheet at all.
- [ ] **Waiting.** Open a large PDF in Edit and start Find, then Compress one PDF from a pane → its row
  in Activity shows a clock and "Compressing — waiting for other PDF work…".

## Undo waits for a long run (Banner Room CF, 2026-10-26)

- [ ] **⌘Z waits.** Delete a file (its message offers Undo), then start a duplicate merge before the
  message goes → the message's Undo greys and says "Wait for the merge to finish" on hover; Edit ▸
  Undo is greyed with the same tooltip; ⌘Z in the file list puts that sentence in a message and
  the file stays in the Trash. When the merge ends, the message's Undo (if still up) and ⌘Z put it back.
- [ ] **Typing undo goes on.** During a merge, type in a document in Edit, then ⌘Z → the typing is
  undone. Edit ▸ Undo reads "Undo Typing" and is live.
- [ ] **Sync History.** During a run, Window ▸ Sync History → Undo Last Run… is greyed with the reason.

## Nothing jumps in Edit or the tab strip (TE210/213/214 follow-ups, 2026-10-26)

- [ ] **Read-only note.** Open a text file in Edit, then from Terminal overwrite it with binary bytes
  (`head -c 2000 /dev/urandom > file`) → the "can't be read as text now" note appears over the
  text's foot, above the status line; the format bar stays, greyed, and the text does not move.
  With the disk banner also up, the two stack, the note on top.
- [ ] **Notice keeps Line/Col.** Change the open file from Terminal while Edit shows it unedited →
  "Reloaded — changed elsewhere" shows at the line's right end for a few seconds; Line/Col and the
  heading menu stay where they were.
- [ ] **Close Tab from a menu.** With two tabs, right-click the pane header ▸ Close Tab → the strip
  stays, showing one tab, until the pointer moves out of where the menu was; then it slides away.
  Same from a row's right-click menu. ⌘W still collapses it at once.

## Filter by Type (RD70, 2026-10-31)

- [ ] **Images only, nested.** In Browse on iCloud ▸ Downloads, Filter ▸ Only beside Images → the
  list keeps the folders holding images, each with a count ("6 images"); opening one shows only its
  images; the status bar reads "N of M items" with an Images chip, and its ✕ shows everything again.
- [ ] **A second extension adds a disclosure.** In a folder with .jpg and .png, Images has a ▸;
  unticking .png leaves Images with a dash, and a .gif added later does not appear.
- [ ] **New Folder while filtered.** With PDFs ticked, ⇧⌘N → the new folder stays in the list until
  you leave the folder or change the filter.
- [ ] **Trash prompt.** With Images ticked, select a folder that also holds a PDF and press Delete →
  the prompt says "Includes 1 item the filter is hiding."
- [ ] **Copy banner.** Copy that folder to the other pane → the banner ends "Includes 1 item the
  filter is hiding".
- [ ] **Columns.** In Columns, open a folder that holds only images, then tick PDFs only → the folder
  stays in its parent column with no count, its column stays open and says "No matching files" (GQ).
  Go back out of it → it disappears.
- [ ] **All but.** With no filter, untick Images → the chip reads "All but Images", and a Word
  document in a subfolder still shows (GR).
- [ ] **Compare.** Each pane's Filter is its own; "Use on Both Panes" copies one to the other; the
  differences list is unchanged by either.
- [ ] **Narrow pane.** Narrow the pane until Filter folds into ⋯ → ⋯ ▸ Filter by Type lists the kinds
  with checkmarks and Show All; View ▸ Filter by Type does the same.
- [ ] **VoiceOver.** The button reads "Filter by type, Off" and then "Filter by type, Images".

## Ask Claude's PDF cards (TE294, 2026-11-02)

Run in the installed app before the `pdf` tool is trusted. The live check covers what Claude
says (`read -s "ASK_CLAUDE_LIVE_KEY?Key: " && export ASK_CLAUDE_LIVE_KEY`, then
`scripts/build-slot swift test --package-path Modules/Sync --filter AskClaudeLivePDFTests`);
these cover what only a person at the app can see.

On 2026-11-03 he skipped the hand run. The items ticked below are covered by tests in
`AskClaudePDFCardRunTests`, which drive a scripted Claude call through to a real PDF, not by hand.
The rest are still open.

- [ ] **Save as PDF, four files, Stop between files.** The card shows progress and Stop; the files
  written stay. A deck whose slides are pictures carries the banner's second sentence on the card.
- [x] **Compress while a duplicate scan holds the PDF reader.** The card says "Checking the file…",
  fills in late, and its button stays off until it has. *By test, not by hand:*
  `AskClaudePDFCardRunTests.aCardWaitsOutAHeldPDFReaderThenFillsIn`.
- [x] **Edit the file between the offer and the click.** The card reads it again and asks for a
  second click. *By test, not by hand:* `AskClaudePDFCardRunTests.aFileChangedSinceTheCardReadItIsNotRun`.
- [x] **Click while Claude is answering.** The button is greyed: "Waits for Claude to finish."
  *By test, not by hand:* `AskClaudePDFCardRunTests.aClickWhileClaudeAnswersWaits`.
- [ ] **Close the panel mid-run and reopen it.** The result is on the card. ⌘Q during a Compress
  card's run asks first (a Save as PDF card's doesn't, as from the menu); after relaunch the card
  says SyncCloud quit while it ran.
- [x] **Undo, on two cards.** One card's own Undo; then, after a second card runs, Edit ▸ Undo with
  the main window in front. Each new file goes to the Trash. (Whether Finder's Put Back returns it
  is not promised: the app moves it with FileManager.) *By test, not by hand:*
  `AskClaudePDFCardRunTests.twoCardsEachUndoTheirOwn`, with a stand-in Trash.
- [ ] **Undo after iCloud or Dropbox has uploaded the copy.** The card still offers Undo.
- [ ] **A file only in the cloud.** The card's Download row, then its run button.
- [ ] **Choose Folder… for a read-only folder, and for a folder hidden from Claude.** Claude is
  told only that the file is in a hidden folder.
- [ ] **Protect.** Return in a password field doesn't send a question; closing the panel clears the
  fields; the password is in neither `chat.json`, `prompts.json` nor `~/sync-cloud.log`. The last
  part is checked by `AskClaudePDFCardRunTests.aPasswordLocksTheCopyAndGoesNowhereElse` (the chat
  file, what Claude hears, the log); the fields still need a hand.
- [ ] **Combine with ↑ and ↓**, and two files of one name in different folders show their folders.
- [ ] **"Fill in the W-9".** The form opens in Edit with Fill & Sign on, and saving a filled copy
  is told to Claude. With unsaved work open in Edit, Edit asks its own question first and Claude
  says the form didn't open yet; ask again once it's answered.

## Ask Claude's tap to talk (TE311, 2026-11-02)

Run in the installed, signed app: a microphone grant survives only a signed install. The tests feed
`say` clips (`AskClaudeVoiceTests`); these are what only a person at the mic can check.

All eight checked by him on 2026-11-02, on the installed signed build. Silence failed first (a
one-second pause sent half a question) and passed on `c2feadce4`, which ends a turn on 1.8 s of
quiet rather than when the transcriber settles words.

- [x] **First mic use.** Open Ask Claude (⌘J) and press ⌥Space. macOS asks to let SyncCloud use the
  microphone, with the reason "Ask Claude listens only after…". Allow: the strip says Listening…,
  and the mic light shows in the menu bar. (Don't Allow instead: the strip goes, and a line over the
  box says where to allow it.)
- [x] **A name on screen.** In a folder with a name dictation gets wrong (Ally, I-797A, 1099-INT),
  say a question naming it. The strip shows the words as you speak, the unsettled end grey, and the
  question's bubble has the name right, with a small mic in it.
- [x] **Second tap.** Talk, then press ⌥Space at once: it sends every word without waiting.
  Clicking the mic does the same.
- [x] **Silence.** Talk and stop: about 2 s later it sends by itself. A pause of about a second
  mid-sentence doesn't.
- [x] **Esc.** Talk, then press Esc: nothing is sent, the box comes back with anything you had typed,
  and the panel stays open. A second Esc closes it.
- [x] **While Claude answers.** ⌥Space beeps and the mic is greyed.
  (Since TE297, 2026-11-03, it listens instead, and what you say waits as Next: see below.)
- [x] **⌥Space in the box** no longer types a non-breaking space.
- [x] **Close mid-sentence.** ⌘J while listening: the mic light goes out, and nothing is sent.

## Ask Claude's rich answers (TE298, 2026-11-02)

Pick Detailed in the menu under the box, so answers carry lists and tables.

Five checked by him on 2026-11-03, on the installed signed build of `32cae53ae`; VoiceOver skipped
for now. After the table check he asked for tables by default when Claude lists files (decision
IQ, built after these checks), so a file list now comes back as a table; he checked that too.

- [x] **A list.** Ask "list the PDFs here, biggest first". Bullets or numbers, not "- " lines;
  a file name in an item is underlined and reveals the file.
- [x] **A table.** Ask "show the files here as a table of name, kind and size". A card with a grey
  header and sizes on the right; a name in a cell reveals its file. Watch it arrive: no row of
  pipes flashes before the table, and nothing jumps as rows come in.
- [x] **Code.** Ask "give me the shell command to list this folder". A grey box; its corner button
  copies the command (paste it in TextEdit) and shows a tick for a moment.
- [x] **Selection.** Drag across a paragraph and ⌘C: the text copies. (A drag can't cross from one
  block into the next.)
- [ ] **VoiceOver** (⌘F5) in the thread: the answer reads in order, the bullet or number before each
  item, and a table as "Table, 3 columns, … rows" then its cells.
- [x] **Dark mode and None accent**: the table card and code box stay readable on the bubble.
- [x] **Files come back as a table (IQ).** Start a New Chat, keep Brief, and ask "list the PDFs
  here, biggest first". The answer is a table, a column per fact (name, size…), not a bulleted
  list. Then ask "how do I file these by year?": the steps stay a numbered list.

## Ask Claude: type while Claude answers (TE297, 2026-11-03)

Queue and One waits checked by him on 2026-11-03, on the installed signed build; he asked that
the rest be checked by the session where it can be.

Ask something that takes Claude a few seconds, such as "which PDFs here are over 1 MB, and why
might they be big?" with Detailed answers.

- [x] **Queue.** While it answers, type "then open the biggest" and press Return. The box empties
  and a line over it reads "Next: then open the biggest · Edit · Cancel". When the answer ends,
  it goes as the next question by itself.
- [x] **One waits.** While it answers, queue one question, then type a second and press Return:
  Next shows both, joined; they go as one question.
- [ ] **Edit and Cancel.** Queue one, click Edit: the text comes back into the box, ahead of
  anything typed. Queue again, click Cancel: it's gone.
- [ ] **Stop.** Queue one, then Stop: the answer ends and Next stays, now with Send. Send asks it.
- [ ] **Chips.** Right-click a file ▸ Ask Claude About This while Claude answers, type a question,
  Return: Next says "about" the file, the chip leaves the box, and the question goes with it.
- [ ] **Talk over an answer.** While it answers, press ⌥Space and say a question: it waits as Next,
  and goes with a mic in its bubble. Stop stays beside the mic while you talk.
- [ ] **Eight lines.** Paste a long paragraph: the box grows to eight lines before it scrolls.
- [ ] **Up.** After queueing, Up in the empty box brings the queued question back.
- [ ] **Key.** While it answers, paste an API key and press Return: the held-back card shows, and
  nothing is queued.

## Ask Claude: Copy, Edit and Retry (TE296, 2026-11-03)

Pick Detailed in the menu under the box, so answers carry lists and tables.

- [ ] **The bar.** Point at an answer: Copy and Retry show beside its receipt line; point away and
  they fade. Point at your question: Copy and Edit show as icons left of its bubble, never on its
  words, and you can reach them with the mouse.
- [ ] **Copy a table.** Ask "show the files here as a table of name, kind and size", Copy its
  answer, paste into Numbers: one cell per name, kind and size. Paste into TextEdit too: a table.
- [ ] **Copy a question.** Copy on a question with a file attached copies only your words.
- [ ] **Retry.** On the last answer, Retry: the answer goes and a new one comes in its place.
  Older answers offer Copy only.
- [ ] **Edit.** Edit an earlier question: it comes back into the box with "Editing your question"
  over it, and its file chips. Change it and press Return: it and everything after it go, and the
  new answer follows the turn before it. Cancel instead puts the box back as it was.
- [ ] **A card stays.** Ask Claude to rename a file, Apply the card, then Edit that question and
  send it: the applied card stays in the chat with its Undo, and Claude's answer knows the file was
  renamed.
- [ ] **Read while it answers.** With VoiceOver on (⌘F5), ask a question and move through the panel
  while Claude answers: the app stays up, and the question reads as "You: …". Fixed 2026-11-03 and
  checked with an agent's accessibility reads (three questions, each read while Claude thought);
  VoiceOver itself not yet.
- [ ] **Right-click and VoiceOver.** Right-click an answer bubble: Copy Answer and Retry. With
  VoiceOver (⌘F5), the Actions rotor on a question offers Copy Question and Edit Question.

## Ask Claude's first run: setup, then starters (TE315, TE299, 2026-11-02)

The tests and renders show both states; these need the real Keychain and the real screen. Your key
is removed and put back here, so have it to hand (or copy it from the Claude Console first).

- [ ] **No key.** In Settings ▸ Intelligence, remove the API key. Open Ask Claude (⌘J) with an empty
  chat (New Chat if needed): "Set Up Ask Claude" shows what it does, platform.claude.com with
  "Open the Console ↗", the Max/Ultra/Team credit line, and the API key card. No question needed.
- [ ] **The link.** "Open the Console ↗" opens the Console's API keys page in your browser.
- [ ] **Save from the panel.** Paste the key into the card and press Save: the setup gives way at
  once to the opening note and three or four questions. The key never appears in the chat.
- [ ] **Settings sees it.** Settings ▸ Intelligence shows the key as saved.
- [ ] **Starters fit the screen.** In Downloads, then a folder with files, then Compare, then a PDF
  open in Edit: the questions change to match. A folder hidden from Claude gets general ones.
- [ ] **A click asks.** Click a starter: it's sent as if typed, the starters go, and ↑ in the box
  brings it back.

## Info in each pane (TE336, 2026-11-08)

The window has no Info column any more: each file pane has its own Info, in a column at its right
edge or a drawer over it. Check in Unified and Cards (Settings ▸ Appearance ▸ Surface), with Ask Claude
closed and open.

- [ ] **Browse, Columns and Tree.** Click ⓘ in the pane bar (or press ⌘I): Info appears as one more
  column. Where it sits and how it resizes are TE337's checks, below.
- [ ] **A narrow pane.** Drag the window narrower until the pane is under 600pt: Info becomes a drawer
  over the pane's right edge with a ✕ and a shadow, the list underneath does not move, and arrow keys
  in the list change what Info shows. Widen it 40pt past the line and it is a column again; dragging
  across the line does not flicker.
- [ ] **The drawer's keys.** With the keyboard in the drawer, Esc closes it; ✕ closes it. VoiceOver reads
  the drawer, not the list under it.
- [ ] **Compare.** Open Info on the left pane: it describes the left selection even while the right
  pane has focus, and the right pane's ⓘ is independent. Get Info on a Differences row opens the
  pane on that row's side.
- [ ] **Organize.** The folder pane's ⓘ opens a drawer over it. Fold the folder pane (the spine): the
  spine's ⓘ opens a drawer from the spine over the lens, ⌘I does the same.
- [ ] **Edit.** With its file pane hidden there is no Info button, Text Files rows have no Get Info and
  ⌘I is italic in Markdown and does nothing elsewhere. Open the file pane: its ⓘ appears.
- [ ] **Downloads.** Select a cloud-only file and click Download in Info: the picture arrives when the
  download ends, and a second pane does not start a second watch.
- [ ] **A customised pane bar.** A bar arranged before this build gains ⓘ right after Scan, once;
  remove it from Customize Pane Bar… and it stays removed after a relaunch.

## Info as a column (TE337, 2026-11-08)

Info looks and resizes like one more column. Check in Unified and Cards, light and dark.

- [ ] **Columns.** Open Info in Browse with Work selected two levels deep: Info sits right after the
  deepest column, with the empty space past it, not at the pane's right edge. No title bar, no fill of
  its own: the same background as the columns, and the same faint line between it and the column
  before it.
- [ ] **Follows the columns.** Click a folder: a new column opens and Info moves right with it. Click
  a file in an earlier column: Info moves back. Drill deep enough to overflow: the stack scrolls so
  Info is at the right edge with the deepest column beside it. Scroll the stack back: Info slides off
  with the columns and never draws past the pane's edge.
- [ ] **Resize.** Drag Info's right edge: it widens and narrows like a column (200–600 pt), the cursor
  is the resize cursor, and the width stays after a relaunch and in every pane (Compare's two match).
  Double-click the edge: back to 300.
- [ ] **Tree.** Switch the pane to Tree: Info is at the right edge, its divider on its left edge; drag
  it, and the rows end where it begins once you let go.
- [ ] **Close.** Hover Info: a ✕ shows at its top right; click it and Info closes. Move away: it hides.
  With Full Keyboard Access, Tab reaches the ✕ and shows it. VoiceOver offers "Hide Info" on Info.
- [ ] **Keys stay the list's.** Select text in Info's details and press Space: nothing previews. Click a
  row and press Space: Quick Look opens.
- [ ] **Action bar.** In Compare at a width where Info is a column, select a file: the action bar centres
  over the columns beside Info, never over Info.
- [ ] **Narrow panes.** Under 600 pt (more if Info is wider) Info is still a drawer with its title bar
  and ✕.

## Ask Claude, docked only (TE336, 2026-11-08)

Ask Claude is the window's right-hand column and nothing else: no floating panel, no 💬 button, no pin.
It opens and closes from the button at the top right (the system's right-sidebar glyph), View ▸ Ask
Claude and ⌘J. Check in Browse, Compare, Organize and Edit, and in Unified and Cards (Settings ▸
Appearance ▸ Surface).

- [ ] **Open and close.** Click the toolbar button: the column slides in, top to bottom, the content
  narrows, the button is tinted, and its header's rule lines up with the panes'. Click again, or ✕ in
  its header: it goes. Both ways it slides, and is instant with Reduce Motion on. The header has the
  shield, New Chat and ✕, and no pin.
- [ ] **Remembered.** Close it, quit and relaunch: it stays closed. Open it, relaunch: it comes back
  open and does not take the keyboard from the file list.
- [ ] **A first launch.** After Reset All, with no API key saved, the window opens with no column. Save a
  key in Settings: when Settings closes, the column opens once, without taking the keyboard. Close it
  and it stays closed.
- [ ] **A narrow window.** Drag the window narrower than Compare needs beside the column (about 1,040
  pt): nothing moves while you drag, and on letting go the column slides over the content's right
  edge with a shadow. A click in the content tucks it away and does its own job; ◨ or ⌘J brings it
  back. Widen the window 40 points past the line and it docks again.
- [ ] **Clicks in the overlaid column.** Click in its text box over the file list: the caret stays in
  the box and no row is selected. Press Delete in the box with text: it deletes text, and no file
  action is offered.
- [ ] **Folds.** At 1,440 pt nothing folds in Organize or Edit. Narrow the window to about 1,270: Organize
  folds its folder pane and sidebar, and Edit its list; the sidebar button brings Organize's sidebar
  back alone. Close the column and they come back.
- [ ] **Keys with the keyboard in the column.** Esc with nothing to stop does nothing; during a spoken
  question it stops it; while editing a question it cancels the edit. ⌘W closes the column (not a
  pane tab or the window). ⌘J with the keyboard elsewhere takes you to the text box, a second ⌘J
  closes, and while talking it does nothing. ⌘Z undoes typing and settings changes, never a file
  move. ⌘A, ⌘C copy or select the answer text; ⌘X, ⌘V, ⌘⌫ beep and touch no file.
- [ ] **Clicks keep the keyboard in the column.** Click an empty part of the thread and press Space,
  an arrow or Delete: nothing happens to the files.
- [ ] **Talking survives a move.** Start a spoken question, then drag the window across the narrow line:
  it keeps listening and sends as before. An answer arriving or voice stopping does not pull the
  keyboard off the file list.
- [ ] **Busy.** Open Settings or Help: the column dims and takes no clicks or keys; close them and it
  carries on. Open a Compare difference's side-by-side: the column pauses under it too.
- [ ] **Info and the column.** Open a pane's Info with the column open in Browse at 1,100 pt: Info is a
  drawer over the pane, the column is beside it, and both work.
- [ ] **VoiceOver.** With VoiceOver on, open the column in each workspace, switch workspaces, open Info,
  drag across the narrow line, and send a question: the app does not hang (the accessibility loop that
  once took it down), and the overlaid column is read, not the content under it.

## Refine's request on the 5.5 models (TE335, E1, 2026-11-07)

Run once, before Refine moves to the chat's model (E2–E4). It sends one 6-file Refine batch and one
3-row folder-name batch to Sonnet 5.5, Opus 5.5 and Haiku 5.5 in each request shape in
`CloudFilingProtocol.RequestShape.variants`, and prints one line per try. A few cents in all. The
key comes from the environment, never the Keychain.

`read -s "ASK_CLAUDE_LIVE_KEY?Key: " && export ASK_CLAUDE_LIVE_KEY`, then
`scripts/build-slot swift test --package-path Modules/Sync --filter CloudFilingLiveShapeTests`.

- [x] **The table prints.** Run 2026-11-07, 18 requests, under 5¢. Without the key the suite is skipped, which is a vacuous green: quote the
  printed lines (`OK`/`FAIL`, model, shape, HTTP status, placements read, tokens, cost).
- [x] **The control fails on 5.5.** "today's, streamed" (forced tool) returns HTTP 400 on Opus 5.5 and
  Sonnet 5.5. Confirmed: HTTP 400 on both (`tool_choice: type "tool" and "any" are not supported for this model`), and `any` fails the same way. Haiku 5.5 accepts both.
- [x] **`RequestShape.current(for:)` works on all three models,** for the Refine batch and the
  folder-name batch (the test asserts it). A model that fails is the one Refine is off on (KQ-C); if
  Opus 5.5 is that model, LA is asked again before any chat step.
- [x] **Pick the winning shape.** The tool left to the model, without `strict`: the only shape that works on all three. `strict` cut answers short (Sonnet 5.5 1 of 6, Haiku 5.5 0 of 3) and `any` is a 400 on two. About 1,600 tokens in and 350 to 400 out for six files, under 1¢, 2 to 5 seconds.

## Refine stops and fails honestly (TE335, E2, 2026-11-08)

Run in the installed app with a Claude key saved, Use Claude on in Settings ▸ Intelligence, and a
To File list of 20 or more suggestions (a Downloads folder works). Nothing here ran by hand: the
tests drive a scripted stream, and the install was checked for launch and signature only.

- [ ] **Stop Refining.** Press “Refine N with …”. While it runs, the button reads “Stop Refining”.
  Press it: the banner says “Stopped. K of N answers arrived and were kept …”, and the cards for
  those K show their new homes. The last refine's cost is in the spend row, so a stopped request is
  recorded.
- [ ] **Stopped, then again.** Press Refine again: the K answers are reused (the banner counts them
  as reused), and only the rest is asked.
- [ ] **No network.** Turn Wi-Fi off, press Refine and confirm the estimate: the banner says Claude
  didn't finish or couldn’t be asked, nothing is marked as refined, and the cards keep the free
  suggestions. `~/sync-cloud.log` has a “Cloud Filing failed” line. Nothing on this Mac answered.
- [ ] **Try Another with no network.** The card keeps its suggestion and the banner names the
  problem; it does not go blank.
- [ ] **Over 150.** With more than 150 suggestions the banner says how many went in the request and to
  press Refine again for the rest.

## Refine on the chat's model and Ask Claude's one limit (TE335, E4, 2026-11-08)

Run in the installed app, with a key saved, Use Claude on in Settings ▸ Intelligence, and a To File
list. The tests drive scripted streams and defaults; the install was checked for launch and signature
only. The Intelligence tab still shows Refine's old model and caps until E5; they no longer do anything.

- [ ] **The chat's model.** Pick Opus 5.5 in the Ask Claude panel's model menu, press “Refine N with
  Claude…”: the dialog reads “Classify N files with Opus 5.5?”. Switch the chat to Haiku 5.5 and press
  it again: the dialog names Haiku 5.5 and the estimate is lower. It does not fail with a 400.
- [ ] **One limit.** The dialog's second paragraph reads “This month: … of your $25 monthly limit for
  Ask Claude and Organize.” After a Refine, Ask Claude's month total (Settings ▸ Ask Claude, or the
  panel's shield) has gone up by about what the receipt says, and by the chat's own questions too.
- [ ] **The limit blocks.** Set the limit to the lowest choice and ask the chat a few questions until it
  stops, then press Refine: the dialog's headline says it would pass your monthly Claude limit and its
  only button is OK. Nothing is sent.
- [ ] **Refine Names.** In a Restructure plan press Ask … About N Folder Names: it returns proposals on the
  chat's model (this was a 400 on Opus 5.5 and Sonnet 5.5 before).
- [ ] **Try Another.** One click on a card: it answers on the chat's model, and its cost shows in the same
  month total.
- [ ] **Organize's share.** `defaults read com.abhishekgirish.SyncCloud | grep -i askClaudeOrganizeSpend`
  shows this month's Organize share, smaller than `askClaudeSpend.<month>`.

## Refine has no switch or limits of its own (TE335, E5, 2026-11-08)

Run in the installed app with a key saved. The tests drive defaults and scripted requests; the install
was checked for launch and signature only. Check the notice on a copy of your real defaults, since it
shows once: before the first launch of this build, `defaults read com.abhishekgirish.SyncCloud | grep -i
tidyFiling` shows the old caps and history.

- [ ] **The notice, once.** First launch of this build: Settings ▸ Ask Claude ▸ Key & Spending shows
  “Refine’s own limits are gone”, naming the old monthly and total caps (a total of $5 if you never
  chose one) and about what Refine had cost, with Got It. Press Got It: it goes and does not return after
  a relaunch. If you had no Refine spend and chose no cap, there is no notice.
- [ ] **This month carried over, once.** “This month” there has gone up by what Refine spent this month,
  and “Of that, Organize” shows that part. Relaunch: neither moves. `defaults read
  com.abhishekgirish.SyncCloud | grep -i tidyFiling` prints nothing now.
- [ ] **No switch.** Settings ▸ Organize ▸ Suggestions has a Refine section with “Key, model and limit”
  and a button to Key & Spending. The Use Claude switch, cloud model menu, caps and spend history are gone
  from Settings, and the spend row and History button are gone from To File.
- [ ] **A saved key turns Refine on.** With a key, results show “Refine N with Claude…”. Remove the key
  and the button becomes the invitation to set Claude up, which opens Key & Spending.
- [ ] **Try Another keeps to the folder.** In a folder set to ask each time, Try Another answers on this
  Mac and asks Claude nothing (no cost line in Activity). In a folder shared without asking, it asks Claude
  and its cost joins the month.
- [ ] **Reset All Settings** keeps the monthly limit, the carried spend and an unread notice.
- [ ] **Search.** Typing “refine” or “cloud” in Settings finds Key & Spending.

## Refine in the Ask Claude chat (TE335, C2–C5, 2026-11-08)

Run in the installed app, with a key saved and a To File list. The tests draw each card state and run
the plan, send, undo and Try Another logic on scripted requests; none of it was clicked in the real app
with the real API. **Never click Send in a test copy of your data you would mind paying for**: a pass is
one request, a few cents.

- [ ] **Refine opens a plan, sends nothing.** “Refine N with Claude…” opens the Ask Claude panel (floating or
  pinned) with a plan card: “Refine N files in …”, what goes (your folder names with Customize…, names,
  types and years, page-1 text from shared folders), what waits for the tick, hidden and answered-before
  files counted but not named, the chat's model and the price, “This month … of $25”. Organize does not
  change. Nothing is billed until you click Send.
- [ ] **The tick.** Tick “Also page-1 text from files in folders that ask each time”: the counts, the price
  and the files change; the line under it said what it buys. Press Refine again: it starts unticked.
- [ ] **Customize….** Untick a folder: the folder-name count drops and “N left out” shows. It stays out for
  Try Another and Refine Names until you quit (a Try Another that asks Claude does not name it).
- [ ] **Send is a click.** Type “go ahead” in the chat: it is an ordinary question and nothing is sent. Click
  Send: the card becomes “Asking …”, Organize keeps working and Stop works; then the answers card lists the
  homes that changed, “Show all N”, a receipt. The Claude badge and “refined” pill show on Organize's cards.
- [ ] **Undo Refine**, on the card and beside the pill in Organize: the on-device suggestions come back, except any
  you changed since. After a rescan Undo is gone. “In chat ↗” beside the pill opens the panel.
- [ ] **Nothing new / the limit.** Press Refine when every file was answered: “Nothing new to ask” with
  “Ask again about the N”. Lower the limit (Settings ▸ Ask Claude) below the quote: Send is off, the card offers
  Change Limit… and “Send the N that fit”.
- [ ] **A plan does not outlive the app.** Quit and relaunch within the hour: the waiting plan comes back as
  out of date and cannot send; an answered card keeps its answers.
- [ ] **No key.** With no key saved, “Refine with Claude…” opens the panel on its key setup; after you save the key
  the plan card appears.
- [ ] **Try Another.** In a folder that asks each time it stays on this Mac, says so under the card, and offers “Ask
  Claude with Page 1…”; the click sends that one page. In a shared folder it asks Claude. One running line
  (“Try Another · 2 files · 3 requests, 1 failed · 3¢ this hour · …”) sits at the bottom of the chat and moves
  down as it updates. A failure or the limit is the card's own sentence, not a banner.
- [ ] **Refine Names.** In a Restructure plan the Ask button shows its price, the model and this month against the
  limit; over the limit it is off and Change Limit… is beside it. After it runs, the chat has a one-line receipt.
- [ ] **Claude knows.** After a pass, ask “why did you move the invoice?”: Claude answers from the reasons of that
  pass and says nothing moved until you File it. (Your next question restarts a chat saved before this
  build, once.)
- [ ] **Not built, on purpose:** the “Claude agrees” badge and a per-card “In chat” link (the link is beside the
  pill); progress is “One request” with no running count.

## The redesigned Refine plan card (TE335, card polish, 2026-11-08)

Drawn first in the "Refine Card Review" mockup; the five choices were settled there. Run in the
installed app with a key saved and a To File list. Nothing here was clicked against the real API.

- [ ] **Short lines, reasons behind ⓘ.** The plan reads: Goes to Claude (files, first pages, folder names with
  Customize…), Needs your OK (one checkbox), Not sent (hidden, answered before), the model and month, and a
  button that carries the price: “Send 4 files · about 4¢”. Hover each ⓘ for its reason.
- [ ] **The tick.** “Send first pages for N more files”, with what it buys beneath. Tick it: the count, the
  price and the button change (“Send 6 files · about 5¢”). The tick is per pass.
- [ ] **Which Files.** Opens a list of each file with “name + first page”, “name only”, “needs your OK”. A file
  hidden from Claude is counted, never named.
- [ ] **Every file waits.** With one file in a folder that is not shared whose home was read from its page: the
  card says “A name alone can’t improve this file.”, names it, Send is off, and “Tick the box to send this file.”
  shows. Tick it: Send turns on as “Send 1 file · about 1¢”.
- [ ] **Over the limit.** “Over your $25 limit by about 1¢. You’ve used $24.97.”, the whole plan and the part that
  fits, Change Limit… and “Send 3 files · about 3¢”.
- [ ] **Old plans.** Press Refine twice: the first plan is gone from the chat, not left as a grey card. Cancel a
  plan: it shrinks to one muted line.
- [ ] **Sending and after.** The card counts seconds while it runs. The answers lead with “N homes changed”, each
  move with the new folder in bold, a Receipt ⓘ and Undo Refine; a stopped or dropped pass says how many answers
  arrived and offers “Try Again for the N”.
- [ ] **Not drawn exactly:** “Ask Again” on the nothing-new card has no price (the plan has no quote when nothing
  is sent); its ⓘ says the usual price applies.

## Ask Claude learns from a card pick (TE331, 2026-11-09)

- [ ] **A pick shows Your pick.** In Downloads, ask “file the loose files” into Documents. Open a
  row and pick its runner-up from Folders, or use Choose Folder…. The row moves to that folder's
  group with a “Your pick” tag, and its details show Was with the folder it had.
- [ ] **Apply offers one rule card.** Click Apply. Under the card, a Save a Rule card names the
  words from the file, the folder (year and month as “year of travel”/“month of travel” for a trip
  folder), where the file went, and “From your pick on …”. No question is sent to Claude.
- [ ] **Two picks to one folder share a card.** Send two tickets to the same trip folder and
  Apply: one card, “Checked on all 2 you moved”.
- [ ] **A later pick adds to the rule.** Save that rule, then on a new card send another airline's
  ticket to the same trip folder and Apply: the card asks “Add to your rule …?” with the new words
  in bold.
- [ ] **Move Here on the runner-up teaches too.** Ask “where should this go?” about a file and
  click Move Here on the runner-up, then Apply: a rule card follows. Move Here on the best folder
  offers none.
- [ ] **Save and Not Now.** Save stores the rule in Organize ▸ Rules; Not Now stores nothing. Ask
  a question after each: Claude knows of a saved one only, by name when the folder is shared
  without asking.

## Ask Claude's Past Chats (TE306, 2026-11-09)

For the after-GA-prep sitting. Ask two short questions in one chat first, then New Chat.

- [ ] **Kept.** Click the clock at the top of the column: the chat you left is under Today, with
  its first question, time, folder, “2 questions” and its cost. The column's title reads Past Chats.
- [ ] **Open.** Click it: the chat reads as it was, its cards as one line each, with New Chat and
  “Continue · N¢” at the bottom. ‹ Past Chats and Esc go back to the list; Esc again, back to the chat.
- [ ] **Continue.** Click Continue: it's the chat you're in again, a line over the box says the
  next question reads it back in, and the next answer's receipt costs about what the button said.
- [ ] **An hour away.** Leave a chat for over an hour (or quit and relaunch after an hour): a line
  under it reads “Your next question starts a new chat” with Continue. Ask without Continue: the old
  chat stays above “Earlier · Claude doesn't see this”, greyed, and the new answer is below.
- [ ] **Search.** Opening the list puts the keyboard in its search field (⌘F still finds in the
  pane). Type a word from an answer: only matching chats stay, each with the matching line. Return
  opens the first. Esc from the field, and from an opened chat, goes back.
- [ ] **Delete and Undo.** Hover a row, click the bin: the chat is deleted, not opened, and
  “Deleted …” shows with Undo; Undo brings it back. Right-click ▸ Delete Chat does the same.
- [ ] **Old cards.** Quit with a card offered (a plan, say), relaunch after an hour: the chat is
  back with the card's buttons off and “From an earlier session, so its buttons are off.”
- [ ] **Hidden later.** Hide a folder a past chat named: its row says “hid 1 item”, the name reads
  “a hidden item” in the chat, search for it finds nothing, and Continue reads “Continue in a New
  Chat · N¢”. Press it: the note over the box has Cancel, and the next question carries only your
  questions.
- [ ] **Settings.** Settings ▸ Ask Claude ▸ Privacy ▸ Past chats: 30 days, the count and size. Pick
  7 days with an older chat present: it asks before deleting. Clear All… asks, then the list is
  empty and says how chats get there.
- [ ] **Empty.** With none kept, the list says “No past chats yet” and how chats get there.
- [ ] **VoiceOver.** Rows read their question and details, with Delete and Continue actions; the
  past chat's question bubbles read “You: …”.
